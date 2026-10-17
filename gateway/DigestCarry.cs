using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

// The patrol digest's memory survives a graceful restart (issue 105). What the digest pushed to the supervisor, per entry key and at which bucket
// (MessageStore.Reported), lives in memory; a restart emptied it, so every condition that persisted through the restart was reported as new again.
// The plant snapshot (PlantSnapshot.cs) now carries it: Snapshot writes it as "digest", Restore puts it back for the keys it does not know yet.
// Like the rest of the snapshot it is read from a public repository, so nothing is trusted beyond its shape: a key is a known kind followed by at
// most three gated parts, a bucket is 1 to 9, a time is not in the future. An entry whose condition no longer holds is forgotten by the first
// digest after the restore (FlaggedAttention), as any cleared condition is.
sealed partial class Plant
{
    static readonly Regex DigestKeyRx = new(@"^[a-z-]{1,40}(\|[A-Za-z0-9:._-]{1,60}){0,3}\z", RegexOptions.CultureInvariant);

    // (gateway-restarted is about one process's start: it is never carried, or the report of the next restart would not be new)
    JsonArray DigestSnapshotLocked() => new(store.Reported.Where(kv => !kv.Key.StartsWith("gateway-restarted", StringComparison.Ordinal)).OrderBy(kv => kv.Key, StringComparer.Ordinal).Take(500).Select(kv => (JsonNode)new JsonObject
    {
        ["key"] = kv.Key, ["bucket"] = kv.Value.Bucket, ["at"] = kv.Value.At.ToString("o"), ["seen"] = kv.Value.Seen == default ? null : kv.Value.Seen.ToString("o"),
        ["acked"] = kv.Value.Acked, ["reminded"] = kv.Value.Reminded
    }).ToArray());

    public int DigestReportedCount() { lock (gate) return store.Reported.Count; }

    // issue 105: a question the Messenger did not relay again (the same open question about the same item asked again) still counts for the launcher
    // watchdog's repeated-question (Plant.cs NoteRepeatedQuestion)
    public void NoteDuplicateQuestion(string name, string id)
    {
        lock (gate)
        {
            if (!store.Records.TryGetValue(id, out var rec) || rec.From != name) return;
            rec.Repeats++;
            NoteRepeatedQuestion(name, rec);
        }
    }

    int RestoreDigestLocked(JsonNode? digest, DateTime now)
    {
        var n = 0;
        foreach (var e in digest as JsonArray ?? new JsonArray())
        {
            if (n >= 500) break;
            if (e is not JsonObject o) continue;
            var key = o["key"]?.ToString() ?? "";
            var kind = key.Split('|')[0];
            if (!DigestKeyRx.IsMatch(key) || kind == "gateway-restarted" || !DigestBuilder.Kinds.Contains(kind) || store.Reported.ContainsKey(key)) continue;
            if (!int.TryParse(o["bucket"]?.ToString(), out var bucket) || bucket is < 1 or > 9) continue;
            if (Time(o["at"]) is not { } at || at > now.AddMinutes(5)) continue;
            var seen = Time(o["seen"]) is { } s && s <= now.AddMinutes(5) ? s : default;
            store.Reported[key] = new MessageStore.ReportedEntry
            {
                Bucket = bucket, At = at, Seen = seen, Acked = o["acked"] is JsonValue av && av.TryGetValue<bool>(out var ab) && ab,
                Reminded = o["reminded"] is JsonValue rv && rv.TryGetValue<bool>(out var rb) && rb
            };
            n++;
        }
        return n;
    }
}
