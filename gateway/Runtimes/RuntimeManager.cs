using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Text.Json.Nodes;

// The runtime adapter's bookkeeping (docs/design/cloud-worker-runtimes.md 4.2 to 4.5, 2.11): which executions run for which item and phase, the
// capacity, the daily budget and the health of each runtime, and the failures per item and phase. The plant decides that an item goes to a runtime
// (Plant.Runtimes.cs) and asks here for a worker name and a nonce; the provisioning itself, the stop and the reading of the executions run outside
// the plant's lock. Lock order: the plant's gate, then this one; nothing here calls the plant while holding its own lock.
// The limits of one runtime kind: the caeJob block for cae-job, api.cursor for cursor-cloud (CursorCloudRuntime.cs).
sealed class RuntimeLimits
{
    public string Kind = "cae-job", Prefix = "cae";
    public Func<bool> IsOn = () => false;
    public int MaxConcurrent, MaxExecutionsPerDay, MaxFailuresPerPhase = 2, UnhealthyAfterFailures = 2;
    public double AckSeconds = 300, ListSeconds = 30;
    public long TokenSeconds = 14400 + 900;
    // the credential the execution is started with: null mints a one-time nonce (cae-job); cursor-cloud mints the worker's r1 (name, item, phase, expiry)
    public Func<string, int, string, long, string>? MintCredential;
    // the credential leaves Azure (an r1 stored at Cursor): the name is revoked at every end, not only after a failure
    public bool RevokeOnEnd;

    public static RuntimeLimits Of(CaeJobSettings c) => new()
    {
        Kind = "cae-job", Prefix = "cae", IsOn = () => c.On, MaxConcurrent = c.MaxConcurrent, MaxExecutionsPerDay = c.MaxExecutionsPerDay, MaxFailuresPerPhase = c.MaxFailuresPerPhase,
        UnhealthyAfterFailures = c.UnhealthyAfterFailures, AckSeconds = c.AckSeconds, ListSeconds = c.ListSeconds, TokenSeconds = c.ReplicaTimeoutSeconds + 900
    };
}

sealed class RuntimeManager
{
    public static readonly ActivitySource Source = new("FactoryWorker.Gateway.Runtimes");
    static readonly Meter MeterOf = new("FactoryWorker.Gateway.Runtimes");
    static readonly Counter<long> Executions = MeterOf.CreateCounter<long>("fworker.runtime.executions", description: "Executions of runtime workers by runtime and outcome");

    public sealed class Exec
    {
        public string Name = "", Execution = "", Phase = "", Status = "provisioning", Outcome = "", StopReason = "";
        public int Item;
        public DateTime StartedAt = DateTime.UtcNow;
        public DateTime? RegisteredAt, EndedAt;
        public bool Ended;
    }
    public sealed record Ticket(string Name, int Item, string Phase, string Profile, string Nonce);

    readonly object gate = new();
    readonly RuntimeSettings cfg;
    readonly IWorkerRuntime cae;
    readonly RuntimeNonces nonces;
    readonly Dictionary<string, Exec> execs = new(StringComparer.Ordinal);
    readonly Dictionary<(int Item, string Phase), int> failures = new();
    readonly List<JsonObject> last = new();
    DateTime day = DateTime.UtcNow.Date; int today;
    int startFailuresInRow; bool healthy = true; string unhealthyWhy = "";
    bool relisted;

    public Plant? Plant { get; set; }
    // the gateway's own hands: park an item (rule verb park-item), end a claim the item still carries, revoke a name
    public Func<int, string, Task>? Park { get; set; }
    public Func<int, string, Task>? ReleaseClaim { get; set; }
    public Func<string, Task>? Revoke { get; set; }

    readonly RuntimeLimits lim;
    public RuntimeManager(RuntimeSettings cfg, IWorkerRuntime cae, RuntimeNonces nonces, RuntimeLimits? limits = null)
    { this.cfg = cfg; this.cae = cae; this.nonces = nonces; lim = limits ?? RuntimeLimits.Of(cfg.CaeJob); }

    public RuntimeSettings Settings => cfg;
    public RuntimeLimits Limits => lim;
    public string Kind => cae.Kind;
    public bool On => lim.IsOn();
    public double AckSeconds => lim.AckSeconds;

    // ---- called by the plant, under its gate: no I/O ----------------------------------------------------------------------------------------
    public bool IsRuntimeWorker(string name) { lock (gate) return execs.ContainsKey(name); }
    public string ExistingFor(int item) { lock (gate) return execs.Values.FirstOrDefault(e => e.Item == item && !e.Ended)?.Name ?? ""; }
    public string ExecutionOf(string name) { lock (gate) return execs.TryGetValue(name, out var e) ? e.Execution : ""; }
    public bool Exhausted(int item, string phase) { lock (gate) return failures.GetValueOrDefault((item, phase)) >= lim.MaxFailuresPerPhase; }

    public (bool Ok, string Code) CanStart()
    {
        lock (gate)
        {
            Roll();
            if (!lim.IsOn()) return (false, "runtime-off");
            if (!relisted) return (false, "runtime-relisting");       // until the executions were read at start, a second one could be started
            if (!healthy) return (false, "runtime-unhealthy");
            if (execs.Values.Count(e => !e.Ended) >= lim.MaxConcurrent) return (false, "runtime-at-capacity");
            if (today >= lim.MaxExecutionsPerDay) return (false, "runtime-budget");
            return (true, "");
        }
    }

    public Ticket Begin(int item, string phase, string profile)
    {
        var name = $"{lim.Prefix}-{item}-{Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(3)).ToLowerInvariant()}";
        var expires = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + lim.TokenSeconds;
        var nonce = lim.MintCredential != null ? lim.MintCredential(name, item, phase, expires)
            : nonces.Mint(name, cae.Kind, expires, TimeSpan.FromSeconds(Math.Max(lim.AckSeconds, 60) + 600));
        lock (gate) { Roll(); today++; execs[name] = new Exec { Name = name, Item = item, Phase = phase }; }
        return new Ticket(name, item, phase, profile, nonce);
    }

    public void Registered(string name) { lock (gate) { if (execs.TryGetValue(name, out var e) && e.RegisteredAt == null) { e.RegisteredAt = DateTime.UtcNow; startFailuresInRow = 0; } } }

    void Roll() { var d = DateTime.UtcNow.Date; if (d != day) { day = d; today = 0; } }

    // ---- outside the plant's lock -----------------------------------------------------------------------------------------------------------
    public async Task Provision(Ticket t)
    {
        using var span = Source.StartActivity("runtime.provision");
        span?.SetTag("fworker.runtime", cae.Kind); span?.SetTag("fworker.worker", t.Name); span?.SetTag("fworker.item", t.Item); span?.SetTag("fworker.phase", t.Phase);
        ProvisionResult r;
        try { r = await cae.Provision(new ProvisionRequest(t.Name, t.Item, t.Phase, t.Profile, t.Nonce), CancellationToken.None); }
        catch (Exception e) { r = new ProvisionResult(false, "", "start-error: " + e.GetType().Name); }
        Log("provision", t.Name, t.Item, r.Ok ? r.Execution : r.Error);
        if (r.Ok)
        {
            bool late; lock (gate) { late = !execs.TryGetValue(t.Name, out var e) || e.Ended || e.StopReason != ""; if (execs.TryGetValue(t.Name, out var e2)) { e2.Execution = r.Execution; e2.Status = "Running"; } }
            span?.SetTag("fworker.execution", r.Execution);
            // ended or stopped while the start call ran (a revoke, a lapse): stop it now, or it would run unattended
            if (late) { try { await cae.Deprovision(t.Name, "ended-during-start", CancellationToken.None); } catch (Exception x) { Log("deprovision-failed", t.Name, t.Item, x.Message); } }
            return;
        }
        span?.SetStatus(ActivityStatusCode.Error, r.Error);
        nonces.Forget(t.Name);
        await End(t.Name, "start-failed", failed: true, startFailure: true);
    }

    public async Task Deprovision(string name, string reason)
    {
        using var span = Source.StartActivity("runtime.deprovision");
        span?.SetTag("fworker.runtime", cae.Kind); span?.SetTag("fworker.worker", name); span?.SetTag("fworker.reason", reason);
        lock (gate) { if (!execs.TryGetValue(name, out var e) || e.Ended) return; e.StopReason = reason; }
        nonces.Forget(name);
        try { await cae.Deprovision(name, reason, CancellationToken.None); Log("deprovision", name, 0, reason); }
        catch (Exception e) { span?.SetStatus(ActivityStatusCode.Error, e.Message); Log("deprovision-failed", name, 0, e.Message); }
    }

    // The execution has ended (or was never started): the plant takes back what the worker still held, a failure is counted against the item and
    // phase (the item is parked at the limit), an execution that never registered counts against the runtime's health.
    async Task End(string name, string outcome, bool failed, bool startFailure)
    {
        Exec? e; bool park = false; bool unhealthyNow = false;
        lock (gate)
        {
            if (!execs.TryGetValue(name, out e) || e.Ended) return;
            e.Ended = true; e.EndedAt = DateTime.UtcNow; e.Outcome = outcome;
            // a failure is counted before the plant takes the item back (RuntimeEnded): a plan in between would otherwise see the phase not yet
            // exhausted and start one execution more than maxFailuresPerPhase
            if (failed) { var n0 = failures[(e.Item, e.Phase)] = failures.GetValueOrDefault((e.Item, e.Phase)) + 1; park = n0 == lim.MaxFailuresPerPhase; }
            if (e.RegisteredAt == null && (failed || startFailure))
            {
                startFailuresInRow++;
                if (healthy && startFailuresInRow >= lim.UnhealthyAfterFailures) { healthy = false; unhealthyNow = true; unhealthyWhy = $"{startFailuresInRow} executions in a row ended without their worker registering"; }
            }
            last.Add(new JsonObject { ["worker"] = e.Name, ["item"] = e.Item, ["phase"] = e.Phase, ["execution"] = e.Execution, ["outcome"] = outcome, ["started"] = e.StartedAt.ToString("o"), ["ended"] = e.EndedAt?.ToString("o"), ["detail"] = Detail(e.Name) });
            if (last.Count > 10) last.RemoveAt(0);
            foreach (var k in execs.Where(kv => kv.Value.Ended && kv.Value.EndedAt < DateTime.UtcNow.AddHours(-1)).Select(kv => kv.Key).ToList()) execs.Remove(k);
        }
        if (unhealthyNow) Log("unhealthy", name, e.Item, unhealthyWhy);
        var tookBack = false; try { tookBack = Plant?.RuntimeEnded(name, e.Item, outcome) ?? false; } catch (Exception x) { Log("take-back-failed", name, e.Item, x.Message); }
        // an execution that exited by itself while its worker still held the item did not finish it: a failure like any other
        if (tookBack && !failed && e.StopReason == "" && outcome == "succeeded")
        {
            failed = true; outcome = "ended-with-item";
            lock (gate) { e.Outcome = outcome; var n1 = failures[(e.Item, e.Phase)] = failures.GetValueOrDefault((e.Item, e.Phase)) + 1; park = n1 == lim.MaxFailuresPerPhase; }
        }
        Executions.Add(1, new KeyValuePair<string, object?>("runtime", cae.Kind), new KeyValuePair<string, object?>("outcome", outcome));
        if (tookBack && ReleaseClaim != null) { try { await ReleaseClaim(e.Item, name); } catch (Exception x) { Log("release-claim-failed", name, e.Item, x.Message); } }
        // a failure costs the item one of its executions in this phase: the one that failed, or the one whose offer was lost with it
        if (Revoke != null && ((failed && e.RegisteredAt != null) || lim.RevokeOnEnd)) { try { await Revoke(name); } catch (Exception x) { Log("revoke-failed", name, e.Item, x.Message); } }
        // at the limit the next plan of the item parks it (Plant.RouteRuntime), so the park happens once, on the plant's side
        if (park) Log("failures-exhausted", name, e.Item, e.Phase);
    }

    // An offer to a runtime worker lapsed (Plant.Tick): its execution is stopped and the lapse counts as a failed execution of the item's phase.
    public void OfferLapsed(string name) => _ = Task.Run(async () => { await Deprovision(name, "offer-lapsed"); await End(name, "offer-lapsed", failed: true, startFailure: false); });

    // Under the plant's gate: the park runs on the pool (rule verb park-item), and the plant may queue it again once it has run.
    public void QueuePark(int item, string phase) => _ = Task.Run(async () =>
    {
        Log("park", "", item, "runtime-failed " + phase);
        // after the park the item starts afresh: an unpark by the operator gives its phase maxFailuresPerPhase executions again
        try { if (Park != null) { await Park(item, phase); lock (gate) failures.Remove((item, phase)); } } catch (Exception x) { Log("park-failed", "", item, x.Message); }
        finally { Plant?.RuntimeParked(item, phase); }
    });

    public void ResetHealth() { lock (gate) { healthy = true; startFailuresInRow = 0; unhealthyWhy = ""; } }

    // One reading of the executions: ended ones are settled, and a running one is stopped when its worker never registered, or registered and was
    // never given an item, within the acknowledgement window. The first reading after the start adopts the executions found (restart recovery).
    public async Task Poll(CancellationToken ct)
    {
        IReadOnlyList<RuntimeInstance> list;
        try { list = await cae.List(ct); }
        catch (Exception e) { Log("list-failed", "", 0, e.Message); return; }
        var ends = new List<(string Name, string Outcome, bool Failed)>(); var stops = new List<(string Name, string Why)>();
        var now = DateTime.UtcNow;
        lock (gate)
        {
            if (!relisted)
            {
                foreach (var i in list.Where(i => i.Status is "Running" or "Processing" && !execs.ContainsKey(i.WorkerName)))
                {
                    execs[i.WorkerName] = new Exec { Name = i.WorkerName, Item = i.Item, Phase = i.Phase, Execution = i.Execution, Status = i.Status, StartedAt = now };   // its window starts at adoption: the worker reconnects after the restart
                    if (i.Started is { } st && st.Date == day) today++;
                    Log("relisted", i.WorkerName, i.Item, i.Execution);
                }
                relisted = true;
            }
            foreach (var e in execs.Values.Where(e => !e.Ended && e.Execution != ""))
            {
                var i = list.FirstOrDefault(x => x.Execution == e.Execution);
                if (i == null) { if ((now - e.StartedAt).TotalSeconds > 60) ends.Add((e.Name, "gone", false)); continue; }
                e.Status = i.Status;
                if (i.Status == "Succeeded") ends.Add((e.Name, e.StopReason != "" ? "stopped:" + e.StopReason : "succeeded", false));
                else if (i.Status is "Failed" or "Degraded") ends.Add((e.Name, "failed", true));
                else if (i.Status == "Stopped") ends.Add((e.Name, e.StopReason != "" ? "stopped:" + e.StopReason : "stopped", e.StopReason == ""));
            }
        }
        foreach (var (n, o, f) in ends) await End(n, o, f, false);
        List<Exec> running; lock (gate) running = execs.Values.Where(e => !e.Ended && e.StopReason == "").ToList();
        foreach (var e in running)
        {
            var (registered, owns, offered) = Plant?.RuntimeWorkerState(e.Name) ?? (false, false, false);
            if (registered) Registered(e.Name);
            DateTime? regAt; lock (gate) regAt = e.RegisteredAt;
            if (regAt == null && (now - e.StartedAt).TotalSeconds > lim.AckSeconds) stops.Add((e.Name, "never-registered"));
            else if (regAt != null && !owns && !offered && (now - regAt.Value).TotalSeconds > lim.AckSeconds) stops.Add((e.Name, "no-item"));
        }
        foreach (var (n, why) in stops)
        {
            await Deprovision(n, why);
            if (why == "never-registered") await End(n, why, failed: true, startFailure: true);
        }
    }

    JsonNode? Detail(string name) { try { return (cae as IRuntimeDetail)?.Detail(name); } catch { return null; } }

    public JsonObject Status()
    {
        lock (gate)
        {
            Roll();
            return new JsonObject
            {
                ["preferConnected"] = cfg.PreferConnected,
                ["routing"] = new JsonArray(cfg.Routing.Select(r => (JsonNode)new JsonObject { ["phase"] = r.Phase, ["runtime"] = r.Runtime }).ToArray()),
                [cae.Kind] = new JsonObject
                {
                    ["enabled"] = lim.IsOn(), ["maxConcurrent"] = lim.MaxConcurrent, ["running"] = execs.Values.Count(e => !e.Ended), ["today"] = today, ["maxExecutionsPerDay"] = lim.MaxExecutionsPerDay,
                    ["healthy"] = healthy, ["unhealthyReason"] = unhealthyWhy, ["startFailuresInRow"] = startFailuresInRow, ["ackSeconds"] = lim.AckSeconds, ["relisted"] = relisted,
                    ["executions"] = new JsonArray(execs.Values.Where(e => !e.Ended).Select(e => (JsonNode)new JsonObject { ["worker"] = e.Name, ["item"] = e.Item, ["phase"] = e.Phase, ["execution"] = e.Execution, ["status"] = e.Status, ["started"] = e.StartedAt.ToString("o"), ["registered"] = e.RegisteredAt?.ToString("o"), ["detail"] = Detail(e.Name) }).ToArray()),
                    ["failures"] = new JsonArray(failures.Select(kv => (JsonNode)new JsonObject { ["item"] = kv.Key.Item, ["phase"] = kv.Key.Phase, ["count"] = kv.Value }).ToArray()),
                    ["last"] = new JsonArray(last.Select(x => (JsonNode)x.DeepClone()).ToArray())
                }
            };
        }
    }

    static void Log(string what, string worker, int item, string detail) =>
        Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["runtime"] = what, ["worker"] = worker, ["item"] = item, ["detail"] = detail }.ToJsonString());
}

// Reads the executions every runtimes.caeJob.listSeconds; the first reading at start is the restart recovery (2.11).
sealed class RuntimeLoop(RuntimeManager m) : BackgroundService
{
    // the leader lease (Leader.cs): only the acting gateway parks items and ends claims for the executions it reads
    public Func<bool> MayAct { get; init; } = () => true;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { if (MayAct()) await m.Poll(ct); } catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; } catch (Exception e) { Console.Error.WriteLine($"runtime poll: {e.Message}"); }
            try { await Task.Delay(TimeSpan.FromSeconds(m.Limits.ListSeconds), ct); } catch (OperationCanceledException) { return; }
        }
    }
}
