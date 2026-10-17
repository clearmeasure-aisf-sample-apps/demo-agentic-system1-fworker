using System.Globalization;
using System.Text.Json.Nodes;

// One acting gateway across releases (issue 94). In single-revision mode the platform starts the new revision before it stops the old one, so for a
// while two processes run: before this, both swept the board, the new one restored no plant (the old one wrote it only at its SIGTERM, later), and
// sessions kept their stream on the old one while their calls reached the new one (#68). The item lock is a file of one container and excludes
// nothing across the two.
//
// The lease (plugin/scripts/lib/Leader.ps1) is a ref in the work-orders repository whose commit message is the lease record; every change is a
// compare-and-swap with an epoch that only grows. A starting process takes the lease at once with the next epoch (the newest process acts). Only
// the holder acts: it sweeps, ticks (offers that lapse, lease take-backs, QC), runs the back-merge trigger and writes its plant snapshot. It renews
// the lease every timing.leaderRenewSeconds (120; the lease runs timing.leaderLeaseSeconds, 360) and between renewals checks it every
// timing.leaderCheckSeconds (15) with one conditional read (an unchanged ref answers 304, which GitHub does not count against the rate limit).
//
// A holder that finds a later epoch is superseded: it stops acting, writes its final snapshot (tagged with its epoch), ends its streams with
// stream.replaced (reconnect: the session's client connects again, and the platform routes it to the new process) and answers every further call
// 503 gateway-replaced. It stays a standby: when the lease is released (a graceful stop of the holder) or runs out (the holder died), it takes the
// lease again, so the last process standing always acts. A process that stops gracefully while it holds the lease writes its final snapshot and
// releases the lease, so its successor does not wait.
sealed class LeaderSettings
{
    public bool On;
    public double LeaseSeconds = 360, RenewSeconds = 120, CheckSeconds = 15, HandoverSeconds = 90, GapRenewMaxMinutes = 120, SnapshotDebounceSeconds = 30, SnapshotRefreshMinutes = 10;

    public static LeaderSettings Load(string scriptsDir, bool on)
    {
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? t = null; try { t = JsonNode.Parse(File.ReadAllText(path))?["timing"]; } catch { }
        static bool Num(string? text, out double v) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && double.IsFinite(v) && v > 0;
        double D(string k, double d) => Num(Environment.GetEnvironmentVariable("FACTORY_TIMING_" + k), out var e) ? e : Num(t?[k]?.ToString(), out var v) ? v : d;
        var s = new LeaderSettings
        {
            On = on, LeaseSeconds = D("leaderLeaseSeconds", 360), RenewSeconds = D("leaderRenewSeconds", 120), CheckSeconds = D("leaderCheckSeconds", 15),
            HandoverSeconds = D("leaderHandoverSeconds", 90), GapRenewMaxMinutes = D("gapRenewMaxMinutes", 120),
            SnapshotDebounceSeconds = D("plantSnapshotDebounceSeconds", 30), SnapshotRefreshMinutes = D("plantSnapshotRefreshMinutes", 10)
        };
        // a renewal must come well inside the lease
        if (s.RenewSeconds > s.LeaseSeconds / 2) s.RenewSeconds = s.LeaseSeconds / 2;
        return s;
    }
}

sealed class GatewayLeader(Runner runner, LeaderSettings cfg, string version)
{
    public enum Role { Off, Starting, Acting, Superseded, Stopping }
    readonly object gate = new();
    Role role = cfg.On ? Role.Starting : Role.Off;
    // this process: unique per start; the platform's revision and replica names make the log lines readable
    public readonly string Holder = $"{Clean(Environment.MachineName)}:{Environment.ProcessId}:{Guid.NewGuid().ToString("N")[..6]}";
    readonly string revision = Clean(Environment.GetEnvironmentVariable("CONTAINER_APP_REVISION") ?? ""), replica = Clean(Environment.GetEnvironmentVariable("CONTAINER_APP_REPLICA_NAME") ?? Environment.MachineName);
    long epoch; string sha = "", tree = "", etag = "";
    DateTime acquiredAt, renewedAt, until;
    JsonObject? predecessor, supersededBy, standbyCurrent;
    DateTime? supersededAt;
    long renewals, checks, failures, acquisitions;
    readonly TaskCompletionSource acting = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public LeaderSettings Settings => cfg;

    static string Clean(string s) { var c = new string(s.Where(ch => char.IsAsciiLetterOrDigit(ch) || ch is '.' or '_' or '-').ToArray()); return c.Length > 40 ? c[..40] : c == "" ? "gw" : c; }

    public bool On => cfg.On;
    public Role State { get { lock (gate) return role; } }
    // the sweep, the ticks and the back-merge trigger run only while this is true (always, when the lease is off)
    public bool MayAct { get { lock (gate) return role is Role.Off or Role.Acting; } }
    public bool Replaced { get { lock (gate) return role == Role.Superseded; } }
    public long Epoch { get { lock (gate) return epoch; } }
    public Task ActingTask => acting.Task;
    // called when this process finds itself superseded (stop, final snapshot, streams) and when a standby takes the lease again (restore)
    public Func<JsonObject?, Task>? OnSuperseded { get; set; }
    public Func<JsonObject?, Task>? OnReacquired { get; set; }

    JsonObject Args(string action)
    {
        var o = new JsonObject { ["action"] = action, ["holder"] = Holder, ["ttl_seconds"] = cfg.LeaseSeconds, ["version"] = version, ["revision"] = revision, ["replica"] = replica };
        lock (gate) { if (epoch > 0) o["epoch"] = epoch; if (tree != "") o["tree"] = tree; if (sha != "") o["sha"] = sha; if (etag != "") o["etag"] = etag; }
        return o;
    }
    static DateTime? Time(JsonNode? n) => DateTime.TryParse(n?.ToString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : null;
    static void Log(JsonObject o) { o["at"] = DateTime.UtcNow.ToString("o"); Console.WriteLine(o.ToJsonString()); }

    // Takes the lease with the next epoch; tries until it has it (a gateway that cannot write the lease cannot act anyway). Returns the
    // predecessor's record (null: there was none).
    public async Task<JsonObject?> AcquireAsync(CancellationToken ct)
    {
        var pause = 2.0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var (code, output) = await runner.RunAsync("leader-lease", Args("acquire").ToJsonString(), TimeSpan.FromSeconds(60));
            JsonNode? j = null; try { j = JsonNode.Parse(output); } catch { }
            if (code == 0 && j?["epoch"] is JsonValue ev && ev.TryGetValue<long>(out var e))
            {
                var pred = j["predecessor"] as JsonObject;
                lock (gate)
                {
                    epoch = e; sha = j["sha"]?.ToString() ?? ""; tree = j["tree"]?.ToString() ?? tree; etag = "";
                    acquiredAt = renewedAt = DateTime.UtcNow; until = Time(j["until"]) ?? DateTime.UtcNow.AddSeconds(cfg.LeaseSeconds);
                    predecessor = pred?.DeepClone() as JsonObject; acquisitions++;
                }
                Log(new JsonObject { ["gateway"] = "leader", ["acquired"] = e, ["holder"] = Holder, ["predecessor"] = pred?.DeepClone() });
                return pred;
            }
            lock (gate) failures++;
            Log(new JsonObject { ["gateway"] = "leader", ["acquire"] = "failed", ["exit"] = code });
            await Task.Delay(TimeSpan.FromSeconds(pause), ct); pause = Math.Min(30, pause * 2);
        }
    }

    public void StartActing()
    {
        lock (gate) { if (role is Role.Starting or Role.Superseded) role = Role.Acting; }
        acting.TrySetResult();
    }

    // The lease's own loop: renew or check while acting, watch the lease while superseded.
    public async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(cfg.CheckSeconds), ct); } catch (OperationCanceledException) { return; }
            try
            {
                var r = State;
                if (r == Role.Acting) await Hold();
                else if (r == Role.Superseded) await Watch(ct);
            }
            catch (Exception e) when (!ct.IsCancellationRequested) { lock (gate) failures++; Console.Error.WriteLine($"leader loop: {e.Message}"); }
        }
    }

    // Before a process acts for the first time: is it still the holder? A process superseded while it restored stands by instead.
    public async Task<bool> ConfirmAsync()
    {
        var (code, output) = await runner.RunAsync("leader-lease", Args("check").ToJsonString(), TimeSpan.FromSeconds(60));
        JsonNode? j = null; try { j = JsonNode.Parse(output); } catch { }
        if (code != 0 || j == null || (j["leader"] is JsonValue lv && lv.TryGetValue<bool>(out var lb) && lb)) return true;   // unreadable: as Hold does, it keeps the lease
        var cur = j["current"] as JsonObject;
        lock (gate) { role = Role.Superseded; supersededAt = DateTime.UtcNow; supersededBy = cur?.DeepClone() as JsonObject; standbyCurrent = cur?.DeepClone() as JsonObject; etag = ""; sha = j["sha"]?.ToString() ?? ""; }
        Log(new JsonObject { ["gateway"] = "leader", ["superseded"] = Epoch, ["by"] = cur?.DeepClone(), ["before"] = "acting" });
        if (OnSuperseded is { } f) await f(cur);
        return false;
    }

    async Task Hold()
    {
        bool due; lock (gate) due = (DateTime.UtcNow - renewedAt).TotalSeconds >= cfg.RenewSeconds;
        var (code, output) = await runner.RunAsync("leader-lease", Args(due ? "renew" : "check").ToJsonString(), TimeSpan.FromSeconds(60));
        JsonNode? j = null; try { j = JsonNode.Parse(output); } catch { }
        if (code != 0 || j == null) { lock (gate) failures++; return; }   // GitHub did not answer: nobody else can take the lease meanwhile either
        var leader = j["leader"] is JsonValue lv && lv.TryGetValue<bool>(out var lb) && lb;
        if (leader)
        {
            lock (gate)
            {
                if (due) { renewals++; renewedAt = DateTime.UtcNow; until = Time(j["until"]) ?? until; etag = ""; } else checks++;
                if (j["sha"]?.ToString() is { Length: > 0 } s) sha = s;
                if (j["etag"]?.ToString() is { Length: > 0 } et) etag = et;
                if (j["tree"]?.ToString() is { Length: > 0 } tr) tree = tr;
            }
            return;
        }
        var cur = j["current"] as JsonObject;
        lock (gate)
        {
            if (role != Role.Acting) return;
            role = Role.Superseded; supersededAt = DateTime.UtcNow; supersededBy = cur?.DeepClone() as JsonObject; standbyCurrent = cur?.DeepClone() as JsonObject; etag = ""; sha = j["sha"]?.ToString() ?? "";
        }
        Log(new JsonObject { ["gateway"] = "leader", ["superseded"] = Epoch, ["by"] = cur?.DeepClone() });
        if (OnSuperseded is { } f) await f(cur);
    }

    // A standby takes the lease when it was released or ran out; until then it reads the record (conditionally) at every check.
    async Task Watch(CancellationToken ct)
    {
        var (code, output) = await runner.RunAsync("leader-lease", Args("check").ToJsonString(), TimeSpan.FromSeconds(60));
        JsonNode? j = null; try { j = JsonNode.Parse(output); } catch { }
        if (code != 0 || j == null) { lock (gate) failures++; return; }
        JsonObject? cur;
        lock (gate)
        {
            if (j["unchanged"] is null) { standbyCurrent = j["current"]?.DeepClone() as JsonObject; sha = j["sha"]?.ToString() ?? ""; }
            if (j["etag"]?.ToString() is { Length: > 0 } et) etag = et;
            cur = standbyCurrent;
        }
        var released = cur?["released"] is JsonValue rv && rv.TryGetValue<bool>(out var rb) && rb;
        var lapsed = cur == null || (Time(cur["until"]) is { } u && u < DateTime.UtcNow);
        if (!released && !lapsed) return;
        lock (gate) { sha = ""; etag = ""; }
        JsonObject? pred;
        try { pred = await AcquireAsync(ct); } catch (OperationCanceledException) { return; }
        Log(new JsonObject { ["gateway"] = "leader", ["reacquired"] = Epoch, ["after"] = released ? "released" : "lapsed" });
        if (OnReacquired is { } f) await f(pred);
        StartActing();
    }

    // At a graceful stop: nothing acts any more. Returns the role the process had (a superseded process stays superseded).
    public Role BeginStop() { lock (gate) { var was = role; if (role is Role.Acting or Role.Starting) role = Role.Stopping; return was; } }
    // ... and the holder releases the lease (until now), naming whose snapshot holds the plant (-1: none), so its successor does not wait
    public async Task<bool> ReleaseAsync(long plantEpoch, TimeSpan timeout)
    {
        if (Epoch == 0) return false;
        var a = Args("release"); a["plant_epoch"] = plantEpoch;
        var (code, _) = await runner.RunAsync("leader-lease", a.ToJsonString(), timeout);
        Log(new JsonObject { ["gateway"] = "leader", ["released"] = Epoch, ["plantEpoch"] = plantEpoch, ["exit"] = code });
        return code == 0;
    }

    public JsonObject? Predecessor { get { lock (gate) return predecessor?.DeepClone() as JsonObject; } }

    public JsonObject Status()
    {
        lock (gate)
            return new JsonObject
            {
                ["enabled"] = cfg.On, ["role"] = role.ToString().ToLowerInvariant(), ["holder"] = Holder, ["epoch"] = epoch, ["revision"] = revision, ["replica"] = replica,
                ["acquiredAt"] = acquiredAt == default ? null : acquiredAt.ToString("o"), ["renewedAt"] = renewedAt == default ? null : renewedAt.ToString("o"),
                ["until"] = until == default ? null : until.ToString("o"), ["acquisitions"] = acquisitions, ["renewals"] = renewals, ["checks"] = checks, ["failures"] = failures,
                ["predecessor"] = predecessor?.DeepClone(), ["supersededAt"] = supersededAt?.ToString("o"), ["supersededBy"] = supersededBy?.DeepClone(),
                ["leaseSeconds"] = cfg.LeaseSeconds, ["renewSeconds"] = cfg.RenewSeconds, ["checkSeconds"] = cfg.CheckSeconds, ["handoverSeconds"] = cfg.HandoverSeconds
            };
    }
}
