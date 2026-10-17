using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;

// How many rule-script calls run at once (issue 89). Every call of Runner, pooled or a process of its own, holds one slot of this gate while it runs.
// The container ran out of memory with one pwsh per call and no limit (#69: five kills at 1 GiB, about 1.1 GB peaks at 2 GiB): a burst of verbs,
// webhooks and journal lines was a burst of processes. Config: runner.maxProcesses (default 6, 1 to 32); FACTORY_RUNNER_MAX overrides.
//
// Waiting calls start in the order of their class, then of their arrival:
//   critical  the sweep (sync-board), accept, claim-item (a claim and the gateway's renewal of an owner lease), expire-claim (a take-back), the
//             gateway's own reads and writes at start and stop (revocations, revoke, plant snapshot, operator release records): may use every slot
//   normal    every other verb, webhook intake, QC and base-update calls: may use all but one slot, so a critical call never waits behind them
//   slow      long polls (wait-for-checks, metrics, publish-demo): normal, and together at most half of the slots
//   journal   the plant manager's journal lines: last, and at most all but two slots
// A call that waits longer than its class allows is not started: Runner answers exit 20 runner-busy with retryAfterSeconds; the time a call waited
// is taken from the time it may run (Runner). Nothing is ever started twice and a slot is always given back (also when the call throws).
// runner.maxProcesses below 1 counts as 1: the gate cannot be switched off.
sealed class RunnerGate
{
    public enum Cls { Critical = 0, Normal = 1, Slow = 2, Journal = 3 }
    static readonly string[] ClsNames = { "critical", "normal", "slow", "journal" };
    static readonly HashSet<string> CriticalVerbs = new(StringComparer.Ordinal) { "sync-board", "accept", "claim-item", "expire-claim", "revocations", "revoke-worker", "plant-snapshot-save", "plant-snapshot-load", "plant-snapshot-clear", "operator-releases", "operator-release", "leader-lease", "plant-snapshot-await" };
    static readonly HashSet<string> SlowVerbs = new(StringComparer.Ordinal) { "wait-for-checks", "metrics", "publish-demo" };
    public static Cls ClassOf(string verb) => CriticalVerbs.Contains(verb) ? Cls.Critical : verb == "journal" ? Cls.Journal : SlowVerbs.Contains(verb) ? Cls.Slow : Cls.Normal;

    sealed class Waiter { public required Cls C; public required long Seq; public required string Verb; public required DateTime Since; public readonly TaskCompletionSource<bool> Go = new(TaskCreationOptions.RunContinuationsAsynchronously); }

    readonly object gate = new();
    readonly List<Waiter> waiting = new();
    readonly int[] runningBy = new int[4];
    readonly long[] startedBy = new long[4], busyBy = new long[4];
    readonly double[] waitedMsMax = new double[4];
    int running, slowRunning, peakRunning, peakWaiting; long seq;
    // the last starts, for /status: which verb of which class started, after how long a wait (a scenario reads the order of a freed slot)
    readonly Queue<JsonObject> recent = new();
    public int Limit { get; }

    public RunnerGate(int limit) { Limit = Math.Clamp(limit, 1, 32); }

    public static RunnerGate Create(string entry)
    {
        var dir = Path.GetDirectoryName(entry)!;
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(dir, "..", "..", "config", "instance.json");
        int n = 6;
        try { if (System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(path))?["runner"]?["maxProcesses"] is JsonNode v && int.TryParse(v.ToString(), out var c)) n = c; } catch { }
        if (int.TryParse(Environment.GetEnvironmentVariable("FACTORY_RUNNER_MAX"), out var e)) n = e;
        return new RunnerGate(n);
    }

    // the most calls of a class that may run at once (all classes together); slow calls are further capped among themselves
    int LimitOf(Cls c) => c switch { Cls.Critical => Limit, Cls.Journal => Math.Max(1, Limit - 2), _ => Math.Max(1, Limit - 1) };
    int SlowCap => Math.Max(1, Limit / 2);
    bool CanStart(Cls c) => running < LimitOf(c) && (c != Cls.Slow || slowRunning < SlowCap);

    // How long a call may wait for its slot: a critical call as long as its own timeout allows but at most 150 s (accept and claim-item come from a
    // client that gives up after about 170 s), a verb at most 2 minutes (its caller retries on exit 20), a journal line 5 minutes (nobody waits for
    // it; it is best-effort). FACTORY_RUNNER_MAX_WAIT_SECONDS (tests) caps the wait of a verb.
    static readonly double? verbWaitCap = double.TryParse(Environment.GetEnvironmentVariable("FACTORY_RUNNER_MAX_WAIT_SECONDS"), NumberStyles.Float, CultureInfo.InvariantCulture, out var vw) && vw >= 0 ? vw : null;
    public static TimeSpan MaxWait(Cls c, TimeSpan timeout)
    {
        if (c == Cls.Critical) return timeout < TimeSpan.FromSeconds(150) ? timeout : TimeSpan.FromSeconds(150);
        if (c == Cls.Journal) return TimeSpan.FromMinutes(5);
        var cap = verbWaitCap is { } s ? TimeSpan.FromSeconds(s) : TimeSpan.FromMinutes(2);
        return timeout < cap ? timeout : cap;
    }

    // A slot, or null when none came free within maxWait. Dispose the slot when the call has ended.
    public async Task<IDisposable?> EnterAsync(string verb, TimeSpan maxWait)
    {
        var c = ClassOf(verb);
        var w = new Waiter { C = c, Seq = Interlocked.Increment(ref seq), Verb = verb, Since = DateTime.UtcNow };
        lock (gate)
        {
            // every call joins the queue and the queue is served at once: a call that may start starts now, and never ahead of an earlier
            // waiter of its own class or of a class before it
            waiting.Add(w); waiting.Sort((a, b) => a.C != b.C ? a.C.CompareTo(b.C) : a.Seq.CompareTo(b.Seq));
            Dispatch();
            if (w.Go.Task.IsCompleted) return new Slot(this, c);
            if (waiting.Count > peakWaiting) peakWaiting = waiting.Count;
        }
        if (maxWait > TimeSpan.Zero)
        {
            using var cts = new CancellationTokenSource();
            await Task.WhenAny(w.Go.Task, Task.Delay(maxWait, cts.Token));
            cts.Cancel();   // a call that got its slot leaves no timer behind
        }
        lock (gate)
        {
            if (w.Go.Task.IsCompleted) return new Slot(this, c);
            waiting.Remove(w); busyBy[(int)c]++;
            Dispatch();   // a waiter that gave up may have held back a later one of a class with a higher limit
        }
        return null;
    }

    // under gate: the call starts now
    void Start(Cls c, string verb, TimeSpan waited)
    {
        running++; runningBy[(int)c]++; startedBy[(int)c]++; if (c == Cls.Slow) slowRunning++;
        if (running > peakRunning) peakRunning = running;
        if (waited.TotalMilliseconds > waitedMsMax[(int)c]) waitedMsMax[(int)c] = waited.TotalMilliseconds;
        recent.Enqueue(new JsonObject { ["verb"] = verb, ["class"] = ClsNames[(int)c], ["at"] = DateTime.UtcNow.ToString("o"), ["waitedMs"] = (long)waited.TotalMilliseconds });
        while (recent.Count > 30) recent.Dequeue();
    }

    // under gate: start the waiters that may start now, first by class, then by arrival. A waiter that may not start (its class is at its limit)
    // does not hold back a waiter of a class with a higher limit; within a class the order of arrival is kept.
    void Dispatch()
    {
        var blocked = new bool[4];
        foreach (var w in waiting.ToList())
        {
            if (blocked[(int)w.C]) continue;
            if (!CanStart(w.C)) { blocked[(int)w.C] = true; continue; }
            waiting.Remove(w); Start(w.C, w.Verb, DateTime.UtcNow - w.Since); w.Go.TrySetResult(true);
        }
    }

    void Leave(Cls c) { lock (gate) { running--; runningBy[(int)c]--; if (c == Cls.Slow) slowRunning--; Dispatch(); } }

    sealed class Slot(RunnerGate g, Cls c) : IDisposable
    {
        int done;
        public void Dispose() { if (Interlocked.Exchange(ref done, 1) == 0) g.Leave(c); }
    }

    public JsonObject Status()
    {
        lock (gate)
        {
            JsonObject By(Func<int, JsonNode?> f) { var o = new JsonObject(); for (var i = 0; i < 4; i++) o[ClsNames[i]] = f(i); return o; }
            return new JsonObject
            {
                ["limit"] = Limit, ["running"] = running, ["waiting"] = waiting.Count, ["peakRunning"] = peakRunning, ["peakWaiting"] = peakWaiting,
                ["limits"] = By(i => i == (int)Cls.Slow ? Math.Min(LimitOf(Cls.Slow), SlowCap) : LimitOf((Cls)i)),
                ["runningByClass"] = By(i => runningBy[i]), ["waitingByClass"] = By(i => waiting.Count(x => (int)x.C == i)),
                ["started"] = By(i => startedBy[i]), ["busyRefusals"] = By(i => busyBy[i]), ["longestWaitMs"] = By(i => (long)waitedMsMax[i]),
                ["oldestWaitingSeconds"] = waiting.Count == 0 ? 0 : (long)(DateTime.UtcNow - waiting.Min(x => x.Since)).TotalSeconds,
                ["recent"] = new JsonArray(recent.Select(x => (JsonNode)x.DeepClone()).ToArray())
            };
        }
    }
}

// Memory of the gateway, of its live rule-script processes and of the container (cgroup v2, else v1), for /status. Never throws.
static class RunnerMemory
{
    static long? ReadLong(string path)
    {
        try { var t = File.ReadAllText(path).Trim(); return t == "max" ? null : long.TryParse(t, NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : null; }
        catch { return null; }
    }
    static JsonNode? Mb(long? bytes) => bytes is { } b && b > 0 && b < (1L << 50) ? (JsonNode)Math.Round(b / 1048576.0, 1) : null;

    public static JsonObject Read(IEnumerable<Process> processes)
    {
        long sum = 0; var count = 0;
        foreach (var p in processes)
        {
            try { if (p.HasExited) continue; p.Refresh(); sum += p.WorkingSet64; count++; } catch { }
        }
        long gatewayBytes = 0; try { using var me = Process.GetCurrentProcess(); gatewayBytes = me.WorkingSet64; } catch { }
        var v2 = File.Exists("/sys/fs/cgroup/memory.current");
        var cur = v2 ? ReadLong("/sys/fs/cgroup/memory.current") : ReadLong("/sys/fs/cgroup/memory/memory.usage_in_bytes");
        var max = v2 ? ReadLong("/sys/fs/cgroup/memory.max") : ReadLong("/sys/fs/cgroup/memory/memory.limit_in_bytes");
        var peak = v2 ? ReadLong("/sys/fs/cgroup/memory.peak") : ReadLong("/sys/fs/cgroup/memory/memory.max_usage_in_bytes");
        return new JsonObject
        {
            ["processes"] = count, ["processesMb"] = Mb(sum) ?? 0, ["gatewayMb"] = Mb(gatewayBytes) ?? 0,
            ["containerMb"] = Mb(cur), ["containerPeakMb"] = Mb(peak), ["containerLimitMb"] = Mb(max)
        };
    }
}
