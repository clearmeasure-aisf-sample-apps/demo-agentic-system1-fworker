using System.Globalization;
using System.Text.Json.Nodes;
using System.Threading.Channels;

// The backlog keeper session (docs/design/backlog-keeper.md): a fourth kind of session next to the workers, the supervisor and the operator session.
// It keeps the backlog workable without a person: it amends an acceptance criterion that cannot be met as written (with a decision block that keeps
// the original), splits an oversized item, creates items, sets priorities and links dependencies (the rule verbs of Verbs.Keeper.ps1). Its
// credential is "k1.<name>.<generation>.<hmac>" (Auth.cs). One slot, like the operator session's: the same name replaces its older stream, another
// allowed name is refused while the active one was heard within timing.mgrTakeoverSeconds. What it receives on its stream:
//   keeper.job   one line per problem it is there for: a park whose code is in keeper.jobCodes (same-criterion-repeated, worker-failure, ...), and
//                backlog-low when fewer than keeper.minTechnicalDesign items wait in Technical Design. Codes, numbers and names only, never free text.
// Kept here, in memory: the slot, the last 200 jobs for a reconnect, and the count of the day's new items against keeper.maxNewItemsPerDay (a
// restart starts that count again; the items themselves are on GitHub).
sealed class KeeperSettings
{
    public bool Enabled;
    public string[] Names = Array.Empty<string>();
    public int TokenGeneration = 1, MaxNewItemsPerDay = 10, MinTechnicalDesign = 3;
    public double BacklogLowMinutes = 60;
    public string RequiredModelTier = "premium", RequiredEffort = "medium", Column = "Technical Design";
    public static readonly string[] DefaultJobCodes = { "same-criterion-repeated", "worker-failure", "fix-forward-exhausted", "demotion-limit", "watchdog-relaunch-budget", "verdict-failed", "stuck", "master-broken" };
    public string[] JobCodes = DefaultJobCodes;

    public static KeeperSettings Load(string scriptsDir, bool messagingConfigured)
    {
        var s = new KeeperSettings();
        JsonNode? root = null;
        try { root = JsonNode.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json"))); } catch { }
        var k = root?["keeper"];
        s.Enabled = k?["enabled"] is JsonValue ev && ev.TryGetValue<bool>(out var eb) && eb;
        var env = Environment.GetEnvironmentVariable("FACTORY_KEEPER"); if (env is "0" or "1") s.Enabled = env == "1";
        if (!s.Enabled) return s;
        if (!messagingConfigured) throw new InvalidOperationException("keeper.enabled needs messaging.enabled");
        static int Num(JsonNode? n, int d, int min, int max) => n != null && int.TryParse(n.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? Math.Clamp(v, min, max) : d;
        s.Names = (k?["allowedNames"] is JsonArray a ? a.Select(x => x?.ToString() ?? "").ToArray() : new[] { "backlog-keeper" }).Where(Auth.ValidName).ToArray();
        s.TokenGeneration = Num(k?["tokenGeneration"], 1, 1, 1_000_000);
        s.MaxNewItemsPerDay = Num(k?["maxNewItemsPerDay"], 10, 0, 100);
        s.MinTechnicalDesign = Num(k?["minTechnicalDesign"], 3, 0, 50);
        s.RequiredModelTier = k?["requiredModelTier"]?.ToString() ?? "premium"; s.RequiredEffort = k?["requiredEffort"]?.ToString() ?? "medium";
        s.Column = k?["newItemColumn"]?.ToString() is { Length: > 0 } col ? col : "Technical Design";
        if (k?["jobCodes"] is JsonArray jc && jc.Count > 0) s.JobCodes = jc.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToArray();
        if (double.TryParse(Environment.GetEnvironmentVariable("FACTORY_TIMING_keeperBacklogLowMinutes"), NumberStyles.Float, CultureInfo.InvariantCulture, out var bl) && bl >= 0) s.BacklogLowMinutes = bl;
        return s;
    }
}

sealed partial class Plant
{
    public KeeperSettings Keeper { get; set; } = new();
    ManagerSlot? kpSlot;
    DateTime? kpHeard;
    long kpNext = 1;
    readonly List<(long Id, string Json)> kpBuffer = new();
    readonly List<(DateTime At, int N)> kpCreated = new();
    readonly Dictionary<string, DateTime> kpJobSent = new();

    public string ActiveKeeper() { lock (gate) return kpSlot?.Name ?? ""; }
    public void KeeperHeard(string name) { lock (gate) { if (kpSlot?.Name == name) kpHeard = DateTime.UtcNow; } }

    public (bool Ok, string Active, DateTime Since, Channel<(long, string)>? Ch, List<(long, string)> Replay) RegisterKeeper(string name, string model, string effort, long after)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var s = kpSlot;
            if (s != null && s.Name != name && MessageStore.Within(kpHeard, now, Msg.TakeoverSeconds)) return (false, s.Name, s.Since, null, new());
            if (s?.Out != null) { s.Out.Writer.TryWrite((0, ReplacedJson(s.Name))); s.Out.Writer.TryComplete(); }
            if (s == null || s.Name != name) kpSlot = s = new ManagerSlot { Name = name, Since = now };
            s.Model = model; s.Effort = effort; s.ModelCheck = Msg.ModelCheckFor(model, effort, Keeper.RequiredModelTier, Keeper.RequiredEffort); s.RegisteredAt = now;
            s.Out = Channel.CreateUnbounded<(long, string)>();
            kpHeard = now;
            // a reconnect with a cursor of this epoch gets what it missed; a new client starts from now (open conditions are raised again by the sweep)
            var replay = after <= 0 ? new List<(long, string)>() : kpBuffer.Where(b => b.Id > after).Select(b => (b.Id, b.Json)).ToList();
            return (true, name, s.Since, s.Out, replay);
        }
    }
    public void DisconnectKeeper(Channel<(long, string)> ch) { lock (gate) { if (kpSlot is { } s && s.Out == ch) s.Out = null; } }
    bool RevokeKeeper(string name)
    {
        if (kpSlot is not { } s || s.Name != name) return false;
        var open = s.Out != null;
        s.Out?.Writer.TryComplete(); kpSlot = null; kpHeard = null;
        return open;
    }

    // One job for the keeper: a code, an item (0 for none), the item's column and a detail code. Never free text. A job of one code and item is sent
    // at most once an hour (a park that is routed again is the same job).
    public void KeeperJob(string code, int item, string column = "", string detail = "")
    {
        if (!Keeper.Enabled) return;
        lock (gate)
        {
            var now = DateTime.UtcNow; var key = $"{code}|{item}";
            if (kpJobSent.TryGetValue(key, out var last) && (now - last).TotalMinutes < 60) return;
            kpJobSent[key] = now;
            foreach (var old in kpJobSent.Where(kv => (now - kv.Value).TotalHours >= 24).Select(kv => kv.Key).ToList()) kpJobSent.Remove(old);
            var id = kpNext++;
            var json = new JsonObject { ["provider"] = "gateway", ["event"] = "keeper.job", ["code"] = GatedCode(code), ["item"] = item, ["column"] = Gated(column), ["detail"] = GatedCode(detail), ["at"] = now.ToString("o") }.ToJsonString();
            kpBuffer.Add((id, json)); if (kpBuffer.Count > 200) kpBuffer.RemoveAt(0);
            kpSlot?.Out?.Writer.TryWrite((id, json));
        }
    }
    // A park: from the trigger the sweep routes (item.parked) or from a failure report (a `complete` that answered parked). Only the codes of
    // keeper.jobCodes become a job.
    public void KeeperPark(int item, string reason, string column = "")
    {
        if (!Keeper.Enabled || item <= 0 || !Keeper.JobCodes.Contains(reason)) return;
        if (column == "") lock (gate) column = ownedInfo.TryGetValue(item, out var oi) ? oi.Column : "";
        KeeperJob(reason, item, column, "parked");
    }
    // After each sweep: how many open factory items wait in Technical Design; below keeper.minTechnicalDesign the keeper is asked to add work
    // (at most once per keeperBacklogLowMinutes, 60).
    public void KeeperBacklog(int waiting)
    {
        if (!Keeper.Enabled) return;
        lock (gate) kpDesignWaiting = waiting;
        if (waiting >= Keeper.MinTechnicalDesign) return;
        lock (gate)
        {
            if (kpJobSent.TryGetValue("backlog-low|0", out var last) && (DateTime.UtcNow - last).TotalMinutes < Keeper.BacklogLowMinutes) return;
            kpJobSent.Remove("backlog-low|0");
        }
        KeeperJob("backlog-low", 0, Keeper.Column, $"waiting-{Math.Max(0, waiting)}-of-{Keeper.MinTechnicalDesign}");
    }

    // A keeper that registers is told the open backlog-low at once from the last full sweep's count: full sweeps are throttled (issue 92), so the
    // next one may be an interval away.
    int? kpDesignWaiting;
    public void KeeperRaiseOpen() { int? w; lock (gate) w = kpDesignWaiting; if (w is { } wv) KeeperBacklog(wv); }

    // The day's new items (create-item, split-item, a follow-up of amend-criteria): how many may still be created, and the record of those that were.
    public int KeeperItemsLeft() { lock (gate) { var now = DateTime.UtcNow; kpCreated.RemoveAll(x => (now - x.At).TotalHours >= 24); return Math.Max(0, Keeper.MaxNewItemsPerDay - kpCreated.Sum(x => x.N)); } }
    public void KeeperCreated(int n) { if (n > 0) lock (gate) kpCreated.Add((DateTime.UtcNow, n)); }

    // The next free worker for a pin of create-item --pin next-free: connected, the owner role, not draining or cooling down, a free slot, not spent.
    public string NextFreeWorker()
    {
        lock (gate)
        {
            var probe = new Assignment { Kind = "own-item", Role = "owner", Item = -1 };
            var (w, _) = Choose(probe, null);
            return w?.Name ?? "";
        }
    }

    public JsonObject KeeperStatus()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var s = kpSlot;
            kpCreated.RemoveAll(x => (now - x.At).TotalHours >= 24);
            return new JsonObject
            {
                ["enabled"] = Keeper.Enabled, ["allowedNames"] = new JsonArray(Keeper.Names.Select(n => (JsonNode)n).ToArray()),
                ["session"] = s == null ? null : new JsonObject { ["name"] = s.Name, ["connected"] = s.Out != null, ["present"] = MessageStore.Within(kpHeard, now, Msg.OnlineSeconds), ["model"] = s.Model, ["effort"] = s.Effort,
                    ["modelCheck"] = s.ModelCheck, ["since"] = s.Since.ToString("o"), ["lastHeard"] = kpHeard?.ToString("o") },
                ["newItemsToday"] = kpCreated.Sum(x => x.N), ["maxNewItemsPerDay"] = Keeper.MaxNewItemsPerDay, ["minTechnicalDesign"] = Keeper.MinTechnicalDesign,
                ["jobsBuffered"] = kpBuffer.Count
            };
        }
    }
}
