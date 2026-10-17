using System.Text.Json.Nodes;

// Plant state survives a restart (enhancement 5). The plant is in memory; a release, a scale-in or a replica move restarts the process. On SIGTERM the
// gateway writes what it would otherwise lose of the hand-over to GitHub (rule script plant-snapshot-save, one ref in the work-orders repository):
// the offers and assignments of items (not QC environments: QcHub rebuilds those from the item states), the owners and bot holders, and what the
// last sweep said of each owned item's lease. The next start reads it back before its first sweep (plant-snapshot-load) and restores it:
//   - an accepted assignment keeps its worker, its id (the item token the worker holds names it) and its time of acceptance;
//   - an offer that waited for its answer is given a fresh window, so the worker that reconnects is offered it again (RegisterWorker pushes every
//     unanswered offer of its name) and accepts with the token it gets then; one that does not come back lapses as any offer does;
//   - an item that waited for a worker keeps its matched line (no second one in the journal) and its pin.
// The durable truth stays the board, the claim refs and the item state comments: the first sweep after the restore corrects anything the snapshot
// got wrong (an owner whose claim is gone, an item that moved). The ref is in a public repository and anyone with write access can change it, so
// nothing in it is trusted beyond what the sweep would accept: names must be valid session names, numbers positive, codes pass the digest's gate,
// and it carries no token and no secret. A snapshot older than timing.plantSnapshotMaxAgeMinutes (30) is ignored: a process that was killed
// outright (no SIGTERM) leaves the previous one behind.
sealed partial class Plant
{
    public JsonObject Snapshot()
    {
        lock (gate)
        {
            static string Iso(DateTime d) => d == default ? "" : d.ToString("o");
            return new JsonObject
            {
                ["v"] = 1, ["at"] = DateTime.UtcNow.ToString("o"),
                ["assignments"] = new JsonArray(assignments.Values.Where(a => !IsQc(a)).OrderBy(a => a.Item).Select(a => (JsonNode)new JsonObject
                {
                    ["id"] = a.Id, ["item"] = a.Item, ["kind"] = a.Kind, ["role"] = a.Role, ["column"] = a.Column, ["mode"] = a.Mode, ["reason"] = a.Reason, ["worker"] = a.Worker,
                    ["pr"] = a.Pr, ["pin"] = a.Pin, ["accepted"] = a.Accepted, ["acceptedAt"] = Iso(a.AcceptedAt), ["createdAt"] = Iso(a.CreatedAt)
                }).ToArray()),
                ["owners"] = new JsonObject(ownerOf.OrderBy(kv => kv.Key).Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)kv.Value))),
                ["drained"] = new JsonArray(drainedNames.OrderBy(x => x, StringComparer.Ordinal).Select(x => (JsonNode)x).ToArray()),   // issue 80
                ["managerDrained"] = new JsonArray(mgrDrained.OrderBy(x => x, StringComparer.Ordinal).Select(x => (JsonNode)x).ToArray()),   // the plant manager's drains (Manager.cs)
                ["managerMode"] = mgrModeOverride, ["managerSummaryDay"] = summaryDay,   // the operator's run-time mode and the day the summary was due (Manager.cs)
                ["bots"] = new JsonObject(botOf.OrderBy(kv => kv.Key).Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)kv.Value))),
                ["ownedSince"] = new JsonObject(ownedSince.OrderBy(kv => kv.Key).Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)kv.Value.ToString("o")))),
                ["owned"] = new JsonObject(ownedInfo.OrderBy(kv => kv.Key).Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)new JsonObject
                {
                    ["holder"] = kv.Value.Holder, ["column"] = kv.Value.Column, ["leaseUntil"] = kv.Value.LeaseUntil?.ToString("o"), ["heartbeat"] = kv.Value.Heartbeat?.ToString("o"), ["parked"] = kv.Value.Parked
                }))),
                ["digest"] = DigestSnapshotLocked()   // issue 105: what the patrol digest already reported (DigestCarry.cs)
            };
        }
    }

    // Restores a snapshot read at start. Returns what was restored, or why nothing was ("" when it was read). Merged key by key: an assignment, owner
    // or bot holder that a verb or a sweep set before the restore ran has fresher facts and wins. A worker that reconnected before the restore is
    // told at once what it owns and which offers wait for it, as its registration would have told it.
    public (int Assignments, int Owners, string Skipped) Restore(JsonNode? snap, double maxAgeMinutes)
    {
        if (snap is not JsonObject s || s["v"]?.ToString() != "1") return (0, 0, "unreadable");
        var at = Time(s["at"]); var now = DateTime.UtcNow;
        if (at is not { } when || when > now.AddMinutes(5)) return (0, 0, "no-time");
        if ((now - when).TotalMinutes > maxAgeMinutes) return (0, 0, "too-old");
        static int Num(JsonNode? n) => int.TryParse(n?.ToString(), out var v) && v > 0 && v < 10_000_000 ? v : 0;
        static string Name(JsonNode? n) => n?.ToString() is { } x && Auth.ValidName(x) ? x : "";
        lock (gate)
        {
            var na = 0; var no = 0;
            foreach (var n in s["assignments"] as JsonArray ?? new JsonArray())
            {
                if (n is not JsonObject o) continue;
                var item = Num(o["item"]); var kind = o["kind"]?.ToString(); var role = GatedCode(o["role"]?.ToString()); var id = o["id"]?.ToString() ?? "";
                if (item == 0 || kind is not ("own-item" or "bot-job") || role == "" || (kind == "own-item" && role != "owner") || !System.Text.RegularExpressions.Regex.IsMatch(id, @"^a-[0-9a-f]{1,32}\z")) continue;
                var key = $"{item}|{kind}|{role}";
                if (assignments.ContainsKey(key)) continue;
                var worker = Name(o["worker"]); var accepted = o["accepted"] is JsonValue av && av.TryGetValue<bool>(out var ab) && ab;
                if (accepted && worker == "") continue;
                var a = new Assignment
                {
                    Id = id, Key = key, Item = item, Kind = kind, Role = role, Column = Gated(o["column"]?.ToString()), Mode = GatedCode(o["mode"]?.ToString()) is { Length: > 0 } md ? md : "first",
                    Reason = GatedCode(o["reason"]?.ToString()), Pr = Num(o["pr"]), Pin = Name(o["pin"]), Worker = worker, CreatedAt = Time(o["createdAt"]) ?? now, MatchedNoted = true
                };
                if (accepted) { a.Accepted = true; a.AcceptedAt = Time(o["acceptedAt"]) ?? now; }
                else if (worker != "") { a.AckBy = now.AddSeconds(ackSeconds); a.AckExtended = false; }
                else { a.WaitingSince = now; a.WaitingCode = a.Pin != "" ? "pinned-unavailable" : "no-session"; }
                assignments[key] = a; na++;
            }
            foreach (var kv in s["owners"] as JsonObject ?? new JsonObject())
                if (Num(JsonValue.Create(kv.Key)) is var item and > 0 && Name(kv.Value) is { Length: > 0 } name && !ownerOf.ContainsKey(item)) { ownerOf[item] = name; no++; }
            foreach (var kv in s["bots"] as JsonObject ?? new JsonObject())
                if (Num(JsonValue.Create(kv.Key)) is var item and > 0 && Name(kv.Value) is { Length: > 0 } name && !botOf.ContainsKey(item)) botOf[item] = name;
            // issue 80: the operator's drains of names (an older snapshot has none); a name already registered is draining at once
            foreach (var d in s["drained"] as JsonArray ?? new JsonArray())
                if (Name(d) is { Length: > 0 } dn && drainedNames.Add(dn) && workers.TryGetValue(dn, out var dw)) dw.Draining = true;
            // only an operator's advise comes back: the snapshot is a ref others can write, and nothing in it may turn the plant manager's actions on
            if (s["managerMode"]?.ToString() == "advise" && mgrModeOverride == "") mgrModeOverride = "advise";
            if (s["managerSummaryDay"]?.ToString() is { Length: 10 } sd && System.Text.RegularExpressions.Regex.IsMatch(sd, @"^\d{4}-\d{2}-\d{2}\z") && string.CompareOrdinal(sd, summaryDay) > 0 && string.CompareOrdinal(sd, DateTime.UtcNow.ToString("yyyy-MM-dd")) <= 0) summaryDay = sd;
            foreach (var d in s["managerDrained"] as JsonArray ?? new JsonArray())
                if (Name(d) is { Length: > 0 } dn && mgrDrained.Add(dn) && workers.TryGetValue(dn, out var dw)) dw.Draining = true;
            if (Msg.On)
            {
                foreach (var kv in s["ownedSince"] as JsonObject ?? new JsonObject())
                    if (Num(JsonValue.Create(kv.Key)) is var item and > 0 && ownerOf.ContainsKey(item) && Time(kv.Value) is { } since && since <= now) ownedSince[item] = since;
                foreach (var kv in s["owned"] as JsonObject ?? new JsonObject())
                    if (Num(JsonValue.Create(kv.Key)) is var item and > 0 && kv.Value is JsonObject oi && Name(oi["holder"]) is { Length: > 0 } holder && ownerOf.TryGetValue(item, out var on) && on == holder)
                        ownedInfo[item] = new OwnedInfo(holder, Gated(oi["column"]?.ToString()), Time(oi["leaseUntil"]), Time(oi["heartbeat"]), oi["parked"] is JsonValue pv && pv.TryGetValue<bool>(out var pb) && pb, now);
            }
            if (Msg.On) RestoreDigestLocked(s["digest"], now);   // issue 105 (DigestCarry.cs)
            foreach (var w in workers.Values.Where(w => w.Out != null))
            {
                var mine = ownerOf.Where(kv => kv.Value == w.Name).Select(kv => kv.Key).ToList();
                if (mine.Count > 0) Push(w, new JsonObject { ["provider"] = "gateway", ["event"] = "ownership.restored", ["items"] = new JsonArray(mine.Select(i => (JsonNode)i).ToArray()) }.ToJsonString(), false);
                foreach (var a in assignments.Values.Where(a => a.Worker == w.Name && !a.Accepted && !IsQc(a))) Push(w, AssignedJson(a), false);
                ResendAccepted(w);   // issue 81
            }
            return (na, no, "");
        }
    }
}
