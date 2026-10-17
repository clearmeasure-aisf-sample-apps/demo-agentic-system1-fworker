using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// A bounded pool of long-lived pwsh processes (plugin/scripts/runner-host.ps1) that run the rule script without a new process per call.
// Config: runner.pool (0 = off, the default: one process per call as before; at most 16), runner.poolMaxCalls (a worker is replaced after this many
// calls, default 200); FACTORY_RUNNER_POOL overrides runner.pool.
//
// A call takes an idle worker; when none is idle the call runs as a process of its own (Runner), so the pool never makes a call wait and never runs
// more than its size. A worker that ends, does not answer in time or answers with something that is not a response is killed and replaced; the call
// that was on it fails as a failed process does (its exit code, or the timeout answer of Runner). A call is never run twice.
// Every request carries a random id that the response must repeat; a response with another id, or any line on the worker's stdout that is not a
// response, ends the worker and fails the call: nothing a worker writes outside a matching response ever reaches a caller, and it is not logged.
// FACTORY_RUNNER_TEST_TIMEOUT_SECONDS (tests only) caps the time a pooled call may take.
// Nothing of a request is logged; what the script writes to stderr is logged as before. Workers end when the gateway ends: they are killed at
// process exit, and a worker whose input closes (the gateway was killed) ends by itself.
sealed class RunnerPool
{
    sealed class Worker
    {
        public required Process P; public required string Mark; public int Calls; public int Dead; public volatile bool Busy; public DateTime ReadyAt;
        public readonly StringBuilder Err = new();
        public string TakeErr() { lock (Err) { var s = Err.ToString(); Err.Clear(); return s; } }
    }

    readonly string entry, host; readonly int size, maxCalls;
    readonly ConcurrentQueue<Worker> idle = new();
    readonly ConcurrentDictionary<int, Worker> all = new();
    int live, spawnFailures; volatile bool stopping;
    readonly double capSeconds = double.TryParse(Environment.GetEnvironmentVariable("FACTORY_RUNNER_TEST_TIMEOUT_SECONDS"), out var cap) && cap > 0 ? cap : 0;

    public static RunnerPool? Create(string entry)
    {
        var dir = Path.GetDirectoryName(entry)!;
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(dir, "..", "..", "config", "instance.json");
        JsonNode? r = null; try { r = JsonNode.Parse(File.ReadAllText(path))?["runner"]; } catch { }
        int Int(string k, int d) => r?[k] is JsonNode n && int.TryParse(n.ToString(), out var v) ? v : d;
        var size = int.TryParse(Environment.GetEnvironmentVariable("FACTORY_RUNNER_POOL"), out var e) ? e : Int("pool", 0);
        var host = Path.Combine(dir, "runner-host.ps1");
        if (size <= 0) return null;
        if (!File.Exists(host)) { Console.Error.WriteLine($"runner pool: {host} is missing; running one process per call"); return null; }
        return new RunnerPool(entry, host, Math.Min(size, 16), Math.Max(1, Int("poolMaxCalls", 200)));
    }

    RunnerPool(string entry, string host, int size, int maxCalls)
    {
        this.entry = entry; this.host = host; this.size = size; this.maxCalls = maxCalls;
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Stop();
        Fill();
    }

    void Stop() { stopping = true; foreach (var w in all.Values) Kill(w); }
    public int Size => size;
    // the live workers' processes (the memory of /status, gateway/RunnerGate.cs)
    public IEnumerable<Process> Processes() => all.Values.Select(w => w.P).ToList();
    static void Kill(Worker w) { try { if (!w.P.HasExited) w.P.Kill(true); } catch { } }

    // Ends a worker (once) and starts its replacement.
    void Retire(Worker w)
    {
        if (Interlocked.Exchange(ref w.Dead, 1) != 0) return;
        Kill(w); foreach (var kv in all) if (ReferenceEquals(kv.Value, w)) all.TryRemove(kv.Key, out _);   // not w.P.Id: it throws for a process that could not be read
        Interlocked.Decrement(ref live);
        try { w.P.Dispose(); } catch { }
        Fill();
    }

    void Fill()
    {
        while (!stopping)
        {
            var n = Volatile.Read(ref live); if (n >= size) return;
            if (Interlocked.CompareExchange(ref live, n + 1, n) == n) _ = Task.Run(Spawn);
        }
    }

    async Task Spawn()
    {
        Worker? w = null;
        try
        {
            var failures = Volatile.Read(ref spawnFailures);
            if (failures > 0) await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(failures, 5))));   // a host that cannot start is not retried in a loop
            if (stopping) { Interlocked.Decrement(ref live); return; }
            var mark = "fw-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(12));
            var psi = new ProcessStartInfo("pwsh") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-File", host, entry, mark }) psi.ArgumentList.Add(a);
            var p = Process.Start(psi)!;
            w = new Worker { P = p, Mark = mark + " " };
            all[p.Id] = w;
            if (stopping) Kill(w);
            p.ErrorDataReceived += (_, a) => { if (a.Data is not null) lock (w.Err) { if (w.Err.Length < 65536) w.Err.AppendLine(a.Data); } };
            p.BeginErrorReadLine();
            p.EnableRaisingEvents = true; // an idle worker that ends is replaced; one that ends soon after it was ready, before any call, counts as a failed start, so a host that keeps dying is not restarted in a loop
            // (an exception in this handler would be unhandled on a pool thread and end the gateway: it is caught)
            p.Exited += (_, _) => { try { if (w.Busy) return; if (w.Dead == 0 && w.Calls == 0 && w.ReadyAt != default && (DateTime.UtcNow - w.ReadyAt).TotalSeconds < 30) Interlocked.Increment(ref spawnFailures); Retire(w); } catch (Exception e) { Console.Error.WriteLine($"runner pool: exit handler: {e.GetType().Name}"); } };
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            string? line; do { line = await p.StandardOutput.ReadLineAsync(cts.Token); } while (line is not null && !line.StartsWith(w.Mark, StringComparison.Ordinal));
            if (line is null) throw new InvalidOperationException($"the host ended before it was ready: {w.TakeErr().Trim()}");
            w.ReadyAt = DateTime.UtcNow;   // spawnFailures is cleared by the first call a worker answers, not here
            idle.Enqueue(w);
        }
        catch (Exception e)
        {
            Interlocked.Increment(ref spawnFailures);
            if (!stopping) Console.Error.WriteLine($"runner pool: a worker did not start: {e.Message}");
            if (w is not null) Retire(w); else { Interlocked.Decrement(ref live); if (!stopping) Fill(); }
        }
    }

    // null: no worker is free (or the pool is stopping); the caller runs the call as a process of its own.
    public async Task<(int Code, string Output)?> TryRunAsync(string verb, string stdin, TimeSpan timeout)
    {
        Worker? w = null;
        while (!stopping && idle.TryDequeue(out var c))
        {
            bool gone; try { gone = c.Dead != 0 || c.P.HasExited; } catch { gone = true; }
            if (gone) { Retire(c); continue; }
            c.Busy = true; w = c; break;
        }
        if (w is null) return null;

        string? frame = null; var stray = false;
        var id = Convert.ToHexString(RandomNumberGenerator.GetBytes(8));
        if (capSeconds > 0 && timeout.TotalSeconds > capSeconds) timeout = TimeSpan.FromSeconds(capSeconds);
        (int, string) TimedOut() { Retire(w); return (20, JsonSerializer.Serialize(new { ok = false, verb, code = "timeout", reason = "the rule script did not finish in time", retryAfterSeconds = 30, exit = 20 })); }
        using var cts = new CancellationTokenSource(timeout);
        using var reg = cts.Token.Register(() => Kill(w));   // the timeout ends the worker itself: a pipe read is not reliably cancelled on every platform
        try
        {
            var req = new JsonObject { ["id"] = id, ["args"] = new JsonArray("--server", verb), ["stdin"] = stdin }.ToJsonString();
            try { await w.P.StandardInput.WriteLineAsync(req.AsMemory(), cts.Token); await w.P.StandardInput.FlushAsync(cts.Token); }
            catch (Exception) when (!cts.IsCancellationRequested) { Retire(w); return null; }   // the request did not reach the worker: nothing ran, so the call runs as a process
            var line = await w.P.StandardOutput.ReadLineAsync(cts.Token);
            if (line is null) { if (cts.IsCancellationRequested) return TimedOut(); }
            else if (line.StartsWith(w.Mark, StringComparison.Ordinal)) frame = line[w.Mark.Length..];
            else stray = true;   // something wrote past the host: not a response, never a caller's output, not logged
        }
        catch (Exception) when (cts.IsCancellationRequested) { return TimedOut(); }
        catch (Exception e) { Console.Error.WriteLine($"[{verb}] runner pool: {e.GetType().Name}"); }

        int code; string output = "", err = "";
        JsonNode? resp = null; if (frame is not null) { try { resp = JsonNode.Parse(frame); } catch { } }
        if (!stray && resp?["id"]?.ToString() == id && resp["code"] is JsonValue cv && cv.TryGetValue<int>(out var rc))
        {
            code = rc; output = resp["out"]?.ToString() ?? ""; err = resp["err"]?.ToString() ?? "";
            err += w.TakeErr(); Interlocked.Exchange(ref spawnFailures, 0);
            reg.Dispose();   // waits for a running timeout callback: after this it can no longer end a worker another call has taken
            if (++w.Calls >= maxCalls || cts.IsCancellationRequested) Retire(w); else { w.Busy = false; idle.Enqueue(w); }
        }
        else
        {
            // the worker ended, or answered with something that is not a response: the call failed, as a process that died does
            code = 1;
            if (frame is null && !stray) { try { if (w.P.WaitForExit(2000)) { w.P.WaitForExit(); code = w.P.ExitCode == 0 ? 1 : w.P.ExitCode; } } catch { } }
            err = w.TakeErr() + (frame is null && !stray ? $"runner pool: the worker ended during the call (exit {code})" : "runner pool: the worker wrote something that is not the answer to this call; it was ended");
            Retire(w);
        }
        if (!string.IsNullOrWhiteSpace(err)) Console.Error.WriteLine($"[{verb}] {err.Trim()}");
        return (code, output.Trim());
    }
}
