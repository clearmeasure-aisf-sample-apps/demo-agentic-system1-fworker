using System.Globalization;
using System.Text.Json.Nodes;

// The Release Queue (enhancement 9 of 2026-10-14). Items whose change is merged, green on master and carried by a release candidate wait in the
// Release Queue column until production has it; the promotion to uat and prod belongs to the owner and the demo-agentic-system1 owner session, never to the gateway.
// What the gateway does about the queue:
//   - the sweep (sync-board) lists the waiting items with their release and since when (`release_queue`); SetReleaseQueue keeps that list;
//   - the patrol digest carries release-queue-aged when the oldest item waits too long or too many wait (DigestBuilder);
//   - the operator stream gets one line per release whose set of waiting items changed: "ready to promote <release> to UAT: items ...";
//   - the dashboard's button records a promotion request and announces it on the operator stream. It promotes nothing: no Octopus call, no
//     deployment. The request is in memory, like every message, and is forgotten when its release leaves the queue.
sealed partial class Plant
{
    readonly List<(int Item, string Release, DateTime Since)> releaseQueue = new();
    // the item set last announced per release, so a release is announced once per change of its items, not at every sweep
    readonly Dictionary<string, string> rqAnnounced = new(StringComparer.Ordinal);
    // the promotion requests, per release: who asked and when
    readonly Dictionary<string, (string By, DateTime At, List<int> Items)> promotionRequests = new(StringComparer.Ordinal);
    public const int ReleaseQueueCap = 200;

    static string QueueRelease(string? v) => v != null && ValidVersion(v) ? v : "";

    // One sweep's `release_queue`: [{ item, release, since }]. An entry without a valid item is dropped; a release that is not a version is kept as "".
    public void SetReleaseQueue(JsonArray? list)
    {
        if (list == null) return;
        lock (gate)
        {
            var now = DateTime.UtcNow;
            var next = new List<(int Item, string Release, DateTime Since)>();
            foreach (var x in list)
            {
                if (x is not JsonObject o || !(o["item"] is JsonValue iv && iv.TryGetValue<int>(out var item) && item >= 1)) continue;
                if (next.Any(q => q.Item == item)) continue;
                var since = Time(o["since"]) is { } t && t <= now ? t : releaseQueue.FirstOrDefault(q => q.Item == item) is { Item: > 0 } seen ? seen.Since : now;
                next.Add((item, QueueRelease(o["release"]?.ToString()), since));
                if (next.Count >= ReleaseQueueCap) break;
            }
            // issue 96: an item that two sweeps in a row found in the Release Queue has no owner work left (item.complete was due when it got there):
            // a missed item.complete must not leave its owner and accepted assignment behind, holding the session back from session.end
            foreach (var q in next.Where(q => releaseQueue.Any(p => p.Item == q.Item)))
            {
                var had = ownerOf.TryGetValue(q.Item, out var ow) ? ow : null;
                var gone = assignments.Where(kv => kv.Value.Item == q.Item && !IsQc(kv.Value)).Select(kv => kv.Key).ToList();
                rqOwnerDropped.Add(q.Item);
                if (had == null && gone.Count == 0 && !botOf.ContainsKey(q.Item)) continue;
                DropOwner(q.Item); botOf.Remove(q.Item); foreach (var k in gone) assignments.Remove(k); staleDropped += gone.Count;
                Console.WriteLine(new JsonObject { ["at"] = now.ToString("o"), ["plant"] = "release-queue-owner-dropped", ["item"] = q.Item, ["owner"] = had ?? "", ["assignments"] = gone.Count }.ToJsonString());
            }
            releaseQueue.Clear(); releaseQueue.AddRange(next.OrderBy(q => q.Item));
            rqOwnerDropped.IntersectWith(releaseQueue.Select(q => q.Item));
            foreach (var k in promotionRequests.Keys.Where(r => releaseQueue.All(q => q.Release != r)).ToList()) promotionRequests.Remove(k);
            // one operator line per release whose waiting items changed; a release that left the queue is forgotten, so its return is announced again
            var byRelease = releaseQueue.Where(q => q.Release != "").GroupBy(q => q.Release).ToDictionary(g => g.Key, g => g.Select(q => q.Item).OrderBy(i => i).ToList(), StringComparer.Ordinal);
            foreach (var k in rqAnnounced.Keys.Where(r => !byRelease.ContainsKey(r)).ToList()) rqAnnounced.Remove(k);
            foreach (var (release, items) in byRelease.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                var sig = string.Join(",", items);
                if (rqAnnounced.TryGetValue(release, out var was) && was == sig) continue;
                rqAnnounced[release] = sig;
                OperatorReleaseLine("release.ready", release, items, $"ready to promote {release} to UAT: items {ItemList(items)}", "");
            }
        }
    }

    static string ItemList(IEnumerable<int> items) => string.Join(", ", items.Select(i => "#" + i.ToString(CultureInfo.InvariantCulture)));

    // A line of the operator stream about the queue. Every part is a version, numbers or a session name: no free text reaches the stream.
    void OperatorReleaseLine(string evt, string release, List<int> items, string line, string by)
    {
        if (!Msg.OperatorEnabled) return;
        var o = new JsonObject { ["provider"] = "gateway", ["event"] = evt, ["release"] = release, ["environment"] = "uat",
            ["items"] = new JsonArray(items.Select(i => (JsonNode)i).ToArray()), ["line"] = line, ["at"] = DateTime.UtcNow.ToString("o") };
        if (by != "") o["by"] = by;
        OperatorPush(o);
    }

    // POST /release-queue/promotion-request: records that the operator asks for the promotion of a release to uat and announces it. It changes
    // nothing anywhere else. Without a release it is the release of the oldest waiting item. Idempotent per release while the release waits.
    public (int Status, JsonObject Body) RequestPromotion(string? release, string by)
    {
        lock (gate)
        {
            if (release != null && release != "" && !ValidVersion(release))
                return (400, new JsonObject { ["ok"] = false, ["code"] = "usage", ["reason"] = "release is a version (digits and dots), or leave it out for the oldest waiting release", ["exit"] = 2 });
            var waiting = releaseQueue.Where(q => q.Release != "").OrderBy(q => q.Since).ThenBy(q => q.Item).ToList();
            var rel = release is { Length: > 0 } ? release : waiting.FirstOrDefault().Release;
            var items = waiting.Where(q => q.Release == rel).Select(q => q.Item).OrderBy(i => i).ToList();
            if (string.IsNullOrEmpty(rel) || items.Count == 0)
                return (409, new JsonObject { ["ok"] = false, ["code"] = "release-not-queued", ["reason"] = "no item waits in the Release Queue for that release", ["exit"] = 10 });
            var who = Auth.ValidName(by) ? by : "operator";
            var again = promotionRequests.TryGetValue(rel, out var prev);
            if (!again)
            {
                prev = (who, DateTime.UtcNow, items);
                promotionRequests[rel] = prev;
                OperatorReleaseLine("release.promotion-requested", rel, items, $"promotion of {rel} to UAT requested by {who} for items {ItemList(items)}: recorded only; the owner and the demo-agentic-system1 owner session promote", who);
            }
            return (200, new JsonObject { ["ok"] = true, ["release"] = rel, ["environment"] = "uat", ["items"] = new JsonArray(items.Select(i => (JsonNode)i).ToArray()),
                ["requestedBy"] = prev.By, ["requestedAt"] = prev.At.ToString("o"), ["already"] = again, ["promoted"] = false,
                ["note"] = "recorded and announced only; the gateway never promotes to uat or prod", ["exit"] = 0 });
        }
    }

    // The queue for /status and the dashboard: items with release and minutes, and the requests.
    public JsonObject ReleaseQueueStatus()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            return new JsonObject
            {
                ["items"] = new JsonArray(releaseQueue.OrderBy(q => q.Since).ThenBy(q => q.Item).Select(q => (JsonNode)new JsonObject { ["item"] = q.Item, ["release"] = q.Release, ["since"] = q.Since.ToString("o"), ["minutes"] = (int)Math.Max(0, (now - q.Since).TotalMinutes) }).ToArray()),
                ["requests"] = new JsonArray(promotionRequests.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => (JsonNode)new JsonObject { ["release"] = kv.Key, ["by"] = kv.Value.By, ["at"] = kv.Value.At.ToString("o"), ["items"] = new JsonArray(kv.Value.Items.Select(i => (JsonNode)i).ToArray()) }).ToArray()),
                ["agedMinutes"] = Msg.ReleaseQueueMinutes, ["agedCount"] = Msg.ReleaseQueueCount
            };
        }
    }

    // Called by DigestInputLocked, under the gate.
    void ReleaseQueueDigestLocked(DigestInput d)
    {
        d.ReleaseQueue.AddRange(releaseQueue);
        d.PromotionRequested = promotionRequests.Count > 0;
    }

    // Issue 65: the items the sweep holds back because an item they depend on is neither merged nor closed (sync-board `held`), with since when the
    // gateway has seen each held (kept across sweeps while the item stays held). Replaced by every sweep; shown in the status as plant.held.
    readonly Dictionary<int, (string Code, string Column, int[] On, DateTime Since)> held = new();
    // scope (issue 92): the items of an incremental pass; the held items outside it are kept as they were
    public void SetHeld(JsonArray? list, IReadOnlyCollection<int>? scope = null)
    {
        if (list == null) return;
        lock (gate)
        {
            var now = DateTime.UtcNow; var next = new Dictionary<int, (string, string, int[], DateTime)>();
            if (scope != null) foreach (var kv in held) if (!scope.Contains(kv.Key)) next[kv.Key] = kv.Value;
            foreach (var x in list)
            {
                if (x is not JsonObject o || !(o["item"] is JsonValue iv && iv.TryGetValue<int>(out var item) && item >= 1)) continue;
                var on = (o["on"] as JsonArray ?? new JsonArray()).Select(v => int.TryParse(v?.ToString(), out var d) ? d : 0).Where(d => d > 0).ToArray();
                var code = o["code"]?.ToString() ?? "depends-on";
                next[item] = (code, o["column"]?.ToString() ?? "", on, held.TryGetValue(item, out var was) && was.Code == code ? was.Since : now);
            }
            held.Clear(); foreach (var kv in next) held[kv.Key] = kv.Value;
        }
    }
    public JsonArray HeldJson()
    {
        lock (gate)
            return new JsonArray(held.OrderBy(kv => kv.Key).Select(kv => (JsonNode)new JsonObject { ["item"] = kv.Key, ["code"] = GatedCode(kv.Value.Code), ["column"] = Gated(kv.Value.Column),
                ["on"] = new JsonArray(kv.Value.On.Select(d => (JsonNode)d).ToArray()), ["since"] = kv.Value.Since.ToString("o") }).ToArray());
    }

    // Issue 99: what the sweep read of parks and of items it saw once (unconfirmed), for the status's list of unowned items and why each waits
    readonly Dictionary<int, (string Column, string Code, string Since, string Until)> sweepParks = new();
    readonly HashSet<int> sweepUnconfirmed = new();
    public void SetSweepFacts(JsonArray? parks, JsonArray? unconfirmed)
    {
        lock (gate)
        {
            if (parks != null)
            {
                sweepParks.Clear();
                foreach (var x in parks)
                    if (x is JsonObject o && o["item"] is JsonValue iv && iv.TryGetValue<int>(out var item) && item >= 1 && sweepParks.Count < ReleaseQueueCap)
                        sweepParks[item] = (Gated(o["column"]?.ToString()), GatedCode(o["code"]?.ToString()), Time(o["since"])?.ToString("o") ?? "", Time(o["until"])?.ToString("o") ?? "");
            }
            if (unconfirmed != null)
            {
                sweepUnconfirmed.Clear();
                foreach (var x in unconfirmed) if (int.TryParse(x?.ToString(), out var u) && u >= 1) sweepUnconfirmed.Add(u);
            }
        }
    }

    // Issue 99: every unowned item the factory knows of, with why it waits, so nobody has to read the item's comments. One row per item, the first
    // that applies: parked (code, since, until), held (depends-on), offered (to whom, until when), waiting (the waiting code), unconfirmed (seen once
    // on the board, offered at the next sweep), release-queue (merged, waiting for production). Orphans (issue 97): an unowned item past the intake
    // column, with how long it has been without an owner.
    public JsonArray UnownedJson()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var rows = new SortedDictionary<int, JsonObject>();
            void Add(int item, JsonObject o) { if (!ownerOf.ContainsKey(item) && !rows.ContainsKey(item)) { o["item"] = item; rows[item] = o; } }
            foreach (var (item, h) in held) Add(item, new JsonObject { ["state"] = "held", ["code"] = GatedCode(h.Code), ["column"] = Gated(h.Column), ["on"] = new JsonArray(h.On.Select(d => (JsonNode)d).ToArray()), ["since"] = h.Since.ToString("o") });
            foreach (var a in assignments.Values.Where(a => a.Kind == "own-item" && !a.Accepted && !IsQc(a)).OrderBy(a => a.Item))
            {
                var o = a.Worker != ""
                    ? new JsonObject { ["state"] = "offered", ["worker"] = a.Worker, ["until"] = a.AckBy.ToString("o"), ["column"] = Gated(a.Column) }
                    : new JsonObject { ["state"] = "waiting", ["code"] = GatedCode(a.WaitingCode) is { Length: > 0 } wc ? wc : "not-yet-offered", ["since"] = a.WaitingSince?.ToString("o"), ["column"] = Gated(a.Column) };
                if (orphanSince.TryGetValue(a.Item, out var os)) { o["orphanSince"] = os.ToString("o"); o["orphanMinutes"] = (int)(now - os).TotalMinutes; }
                Add(a.Item, o);
            }
            // (an assignment means the sweep offered the item, so its park is gone: a park row of the same sweep may be stale)
            foreach (var (item, p) in sweepParks) Add(item, new JsonObject { ["state"] = "parked", ["code"] = p.Code, ["column"] = p.Column, ["since"] = p.Since, ["until"] = p.Until });
            // (the sweep's unconfirmed also holds items whose PASS waits for the gateway's merge: those say so)
            foreach (var (item, p) in passUnmerged) Add(item, new JsonObject { ["state"] = "pass-unmerged", ["code"] = p.Code, ["since"] = p.Since.ToString("o"), ["pr"] = p.Pr });
            foreach (var item in sweepUnconfirmed) Add(item, new JsonObject { ["state"] = "unconfirmed", ["code"] = "seen-once" });
            foreach (var q in releaseQueue) Add(q.Item, new JsonObject { ["state"] = "release-queue", ["release"] = q.Release, ["since"] = q.Since.ToString("o") });
            return new JsonArray(rows.Values.Select(r => (JsonNode)r).ToArray());
        }
    }
}
