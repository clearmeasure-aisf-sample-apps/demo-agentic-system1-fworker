using System.Globalization;
using System.Text.Json.Nodes;

// The gateway's GitHub budget (issue 92). Every rule-script call reports the rate limit GitHub answered it with (x-ratelimit-* headers, per resource:
// core for REST, graphql), in the field _github of its answer (factory.ps1 --server, Core.ps1 Add-GhRate); Runner takes the field out and hands it
// here. The budget keeps the latest numbers of each resource for its window (a lower remaining of the same reset wins over a call that ended later
// with an older reading). Below github.budgetReserve (300) of a resource whose reset has not passed, the budget is low: the sweep skips its
// non-essential reads (claim-ref reaping, the QC sync, the back-merge check), the gateway's own non-essential calls (journal lines, back-merge,
// metrics) are not started, and verbs other than the essential ones are answered exit 20 github-budget with retryAfterSeconds and resetAt.
// A reading older than its window says nothing: when the reset time has passed the resource counts as full again until a call reports otherwise.
sealed class GitHubBudget
{
    sealed class Reading { public int? Limit; public int Remaining; public long Reset; public DateTime At; }
    readonly object gate = new();
    readonly Dictionary<string, Reading> res = new(StringComparer.Ordinal);
    long reports, verbRefusals, callRefusals, lowSweeps;
    public int Reserve { get; }

    // verbs a session may still call when the budget is low: taking an offered item, renewing or giving back its claim, and asking what it owns
    public static readonly HashSet<string> EssentialVerbs = new(StringComparer.Ordinal) { "accept", "claim-item", "release", "my-items" };
    // calls of the gateway itself that wait when the budget is low (nothing depends on them at once; the journal is best-effort)
    public static readonly HashSet<string> DeferredCalls = new(StringComparer.Ordinal) { "journal", "base-watch", "base-update-branch", "metrics" };

    static readonly System.Text.Json.JsonSerializerOptions Relaxed = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public GitHubBudget(int reserve) { Reserve = Math.Max(0, reserve); }

    public static GitHubBudget Load(string scriptsDir)
    {
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        var reserve = 300;
        try { if (JsonNode.Parse(File.ReadAllText(path))?["github"]?["budgetReserve"] is JsonNode v && int.TryParse(v.ToString(), out var r)) reserve = r; } catch { }
        if (int.TryParse(Environment.GetEnvironmentVariable("FACTORY_GITHUB_RESERVE"), out var e)) reserve = e;
        return new GitHubBudget(reserve);
    }

    // The answer of a rule script without its _github field, which is recorded. An answer that is not a JSON object, or has no such field, is
    // returned as it is.
    public string Take(string output)
    {
        if (output.Length == 0 || output[0] != '{' || !output.Contains("\"_github\"", StringComparison.Ordinal)) return output;
        JsonObject? o; try { o = JsonNode.Parse(output) as JsonObject; } catch { return output; }
        if (o == null || !o.ContainsKey("_github")) return output;
        var g = o["_github"] as JsonObject; o.Remove("_github");
        if (g != null) Observe(g);
        // written as the rule script wrote it: no escaping of <, >, & or of letters outside ASCII (journal text, comments)
        try { return o.ToJsonString(Relaxed); } catch { return output; }
    }

    public void Observe(JsonObject report)
    {
        lock (gate)
        {
            reports++;
            foreach (var kv in report)
            {
                // the resources the gateway spends: REST (core) and GraphQL; a small one such as search would read as low for good
                if (kv.Key is not ("core" or "graphql") || kv.Value is not JsonObject r) continue;
                if (!int.TryParse(r["remaining"]?.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var rem)) continue;
                var reset = long.TryParse(r["reset"]?.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var rs) ? rs : 0;
                int? limit = int.TryParse(r["limit"]?.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var lm) ? lm : null;
                if (res.TryGetValue(kv.Key, out var cur) && (cur.Reset > reset || (cur.Reset == reset && cur.Remaining <= rem))) continue;
                res[kv.Key] = new Reading { Limit = limit, Remaining = rem, Reset = reset, At = DateTime.UtcNow };
            }
        }
    }

    // Low: a resource below the reserve whose window has not ended. Returns the resource with the latest reset among the low ones (the time to wait).
    public (bool Low, string Resource, DateTime ResetAt) Low()
    {
        lock (gate)
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var low = res.Where(kv => kv.Value.Remaining < Reserve && kv.Value.Reset > now).OrderByDescending(kv => kv.Value.Reset).FirstOrDefault();
            return low.Key == null ? (false, "", default) : (true, low.Key, DateTimeOffset.FromUnixTimeSeconds(low.Value.Reset).UtcDateTime);
        }
    }

    public void CountVerbRefusal() { lock (gate) verbRefusals++; }
    public void CountCallRefusal() { lock (gate) callRefusals++; }
    public void CountLowSweep() { lock (gate) lowSweeps++; }

    public JsonObject Status()
    {
        var (low, which, resetAt) = Low();
        lock (gate)
        {
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var o = new JsonObject
            {
                ["reserve"] = Reserve, ["low"] = low, ["lowResource"] = low ? which : null, ["resetAt"] = low ? resetAt.ToString("o") : null,
                ["reports"] = reports, ["verbRefusals"] = verbRefusals, ["callRefusals"] = callRefusals, ["lowSweeps"] = lowSweeps
            };
            var rs = new JsonObject();
            foreach (var kv in res.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                rs[kv.Key] = new JsonObject
                {
                    ["limit"] = kv.Value.Limit, ["remaining"] = kv.Value.Remaining, ["resetAt"] = kv.Value.Reset > 0 ? DateTimeOffset.FromUnixTimeSeconds(kv.Value.Reset).UtcDateTime.ToString("o") : null,
                    ["windowEnded"] = kv.Value.Reset > 0 && kv.Value.Reset <= now, ["observedAt"] = kv.Value.At.ToString("o")
                };
            o["resources"] = rs;
            return o;
        }
    }
}
