#!/usr/bin/env pwsh
# Stress test of worker messaging and the supervisor (docs/design/worker-messaging.md). NOT part of the Tier 1 suites: run it by hand, alone.
# usage: pwsh tests/stress/messaging-stress.ps1 [-Seconds 600] [-Workers 30] [-PortBase 7900] [-Seed 1] [-NoBuild] [-ReportFile <json>] [-KeepWork]
#
# It starts a fake GitHub and a gateway of its own (test config, own ports and temp directory, messaging and the supervisor on, the runner pool on)
# and drives the gateway over raw HTTP with credentials the gateway itself mints: -Workers worker sessions, one supervisor and the operator.
# Traffic: notes at and above the rate limits, broadcasts, item threads, questions up to their limits, answers (single and batch), directives,
# announcements, inbox long-polls that are dropped at random, event streams that are opened and killed, hostile requests with a known refusal.
# Timeline (fractions of -Seconds): 0.25 the supervisor is taken over by a second name, 0.35 the gateway is killed and started again,
# 0.55 the operator switches messaging off for 20 s and on again. At the end every session drains its inbox and every accepted message is accounted for.
#
# It fails (exit 1) on: an HTTP 5xx, an internal-error line in a gateway log, a request that failed outside the restart window, a refusal code or
# status that the design does not document, an accepted message that was neither received by its recipient nor reported expired (or lost to the
# restart) to its sender, a message delivered again after its delivered-acknowledgement, a message for another recipient, a bounded store above its
# cap, gateway memory that more than doubles after warm-up or grows in every slice of the last five minutes, and a process left behind.
param([int]$Seconds = 600, [int]$Workers = 30, [int]$PortBase = 7900, [int]$Seed = 1, [switch]$NoBuild, [string]$ReportFile = '', [switch]$KeepWork)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $NoBuild) { foreach ($proj in 'tests/FakeGitHub', 'gateway') { Push-Location (Join-Path $root $proj); dotnet build -c Release -v q -nodeReuse:false -p:UseSharedCompilation=false 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "  build $proj : $_" }; Pop-Location } }
$fakeDll = Join-Path $root 'tests/FakeGitHub/bin/Release/net10.0/FakeGitHub.dll'; $gwDll = Join-Path $root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'
foreach ($d in $fakeDll, $gwDll) { if (-not (Test-Path $d)) { throw "build first: $d is missing" } }
$fakePort = $PortBase; $apiPort = $PortBase + 10; $hookPort = $PortBase + 11
foreach ($port in $fakePort, $apiPort, $hookPort) { $sock = $null; try { $sock = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $sock.Start() } catch { Write-Host "port $port is in use"; exit 3 } finally { if ($sock) { $sock.Stop() } } }

# ---- the driver: C#, so that 30 sessions really run at once and every request is timed the same way --------------------------------------------
$driverSource = @'
using System; using System.Collections.Concurrent; using System.Collections.Generic; using System.Diagnostics; using System.IO; using System.Linq;
using System.Net.Http; using System.Text; using System.Text.Json.Nodes; using System.Threading; using System.Threading.Tasks;

public sealed class StressDriver
{
    sealed class Got { public double At; public double AckAt = -1; public string Type = ""; }
    sealed class Sess
    {
        public string Name = "", Token = ""; public Random R = new Random(); public string Epoch = "", Cursor = ""; public long After; public bool Sup, Sleeper;
        public readonly Dictionary<string, Got> Seen = new Dictionary<string, Got>(); public readonly List<string> Sent = new List<string>();
        public CancellationTokenSource Life = new CancellationTokenSource();
    }
    sealed class Acc { public string Id = "", To = "", Sender = "", Type = "", Epoch = ""; public double At; }
    sealed class Resp { public int Status; public JsonNode J; public bool Transport; public string Raw = ""; }

    readonly string baseUrl, admin; readonly int seed;
    readonly HttpClient http, sse;
    readonly CancellationTokenSource stop = new CancellationTokenSource();
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly List<Sess> workers = new List<Sess>(); readonly List<Sess> sups = new List<Sess>(); Sess activeSup;
    readonly ConcurrentDictionary<string, List<double>> lat = new ConcurrentDictionary<string, List<double>>();
    readonly ConcurrentDictionary<string, int> counts = new ConcurrentDictionary<string, int>();
    readonly ConcurrentQueue<string> fivexx = new ConcurrentQueue<string>(), violations = new ConcurrentQueue<string>(), undocumented = new ConcurrentQueue<string>();
    readonly ConcurrentQueue<(double At, string What)> transport = new ConcurrentQueue<(double, string)>();
    readonly ConcurrentDictionary<string, Acc> accepted = new ConcurrentDictionary<string, Acc>();
    readonly ConcurrentDictionary<string, string> questions = new ConcurrentDictionary<string, string>();   // id -> asker
    readonly ConcurrentDictionary<string, int> answersGot = new ConcurrentDictionary<string, int>(), answeredByMe = new ConcurrentDictionary<string, int>();
    readonly List<(double From, double To)> outages = new List<(double, double)>(); double outageFrom = -1; readonly object ol = new object();
    readonly List<Task> tasks = new List<Task>(); int inflight; double takeoverAt = -1, takeoverDone = -1; int takeoverRefused;
    string epochNow = ""; int item0 = 9000;
    public int VerbItem = 1;   // an item of the fake GitHub that the supervisor reads with get-item

    static readonly Dictionary<string, int> Documented = new Dictionary<string, int>
    {
        ["usage"] = 400, ["too-large"] = 413, ["unauthorized"] = 401,
        ["messaging-disabled"] = 403, ["manager-disabled"] = 403, ["not-owner-mode"] = 403, ["not-allowed"] = 403, ["forged-sender"] = 403, ["not-supervisor"] = 403, ["role-cannot-send"] = 403, ["forbidden"] = 403,
        ["no-such-peer"] = 404, ["no-such-question"] = 404, ["no-such-message"] = 404, ["no-such-patrol"] = 404,
        ["muted"] = 409, ["not-accepting"] = 409, ["independence"] = 409, ["queue-full"] = 409, ["too-many-open"] = 409, ["item-has-open-question"] = 409, ["already-answered"] = 409, ["not-a-question"] = 409,
        ["secret-in-message"] = 409, ["supervisor-active"] = 409, ["name-reserved"] = 409, ["name-not-allowed"] = 409,
        ["rate-limited"] = 429, ["pair-limited"] = 429, ["ask-limited"] = 429, ["step-budget"] = 429
    };
    static readonly HashSet<string> FanoutCodes = new HashSet<string> { "off", "not-accepting", "queue-full", "no-such-peer", "independence" };

    public StressDriver(string baseUrl, string admin, Dictionary<string, string> workerTokens, Dictionary<string, string> supervisorTokens, int seed, int sleepers)
    {
        this.baseUrl = baseUrl; this.admin = admin; this.seed = seed;
        http = new HttpClient(new SocketsHttpHandler { MaxConnectionsPerServer = 400, PooledConnectionLifetime = TimeSpan.FromMinutes(2) }) { Timeout = TimeSpan.FromSeconds(90) };
        sse = new HttpClient(new SocketsHttpHandler { MaxConnectionsPerServer = 400 }) { Timeout = Timeout.InfiniteTimeSpan };
        var i = 0;
        foreach (var kv in workerTokens.OrderBy(k => k.Key, StringComparer.Ordinal)) { workers.Add(new Sess { Name = kv.Key, Token = kv.Value, R = new Random(seed * 1000 + i), Sleeper = i >= workerTokens.Count - sleepers }); i++; }
        foreach (var kv in supervisorTokens.OrderBy(k => k.Key, StringComparer.Ordinal)) sups.Add(new Sess { Name = kv.Key, Token = kv.Value, R = new Random(seed * 1000 + 500 + sups.Count), Sup = true });
        activeSup = sups[0];
    }

    double Now => clock.Elapsed.TotalSeconds;
    void Count(string k, int n = 1) => counts.AddOrUpdate(k, n, (_, v) => v + n);
    void Lat(string ep, double ms) { var l = lat.GetOrAdd(ep, _ => new List<double>()); lock (l) l.Add(ms); }
    void Violation(string v) { if (violations.Count < 200) violations.Enqueue($"{Now:F1}s {v}"); Count("violations"); }

    public void OutageBegin() { lock (ol) outageFrom = Now; }
    public void OutageEnd() { lock (ol) { if (outageFrom >= 0) outages.Add((outageFrom - 1, Now + 5)); outageFrom = -1; } }
    bool InOutage(double t) { lock (ol) return (outageFrom >= 0 && t >= outageFrom - 1) || outages.Any(o => t >= o.From && t <= o.To); }

    void CheckRefusal(string ep, int status, JsonNode j, string raw)
    {
        if (status >= 500) { fivexx.Enqueue($"{Now:F1}s {ep} {status} {(raw.Length > 160 ? raw.Substring(0, 160) : raw)}"); return; }
        if (status < 400) return;
        var code = j?["code"]?.ToString();
        if (code == null) { undocumented.Enqueue($"{Now:F1}s {ep} {status} with no code: {(raw.Length > 120 ? raw.Substring(0, 120) : raw)}"); return; }
        Count("refused:" + code);
        if (!Documented.TryGetValue(code, out var want)) undocumented.Enqueue($"{Now:F1}s {ep} {status} {code}");
        else if (want != status) undocumented.Enqueue($"{Now:F1}s {ep} {code} came with {status}, documented is {want}");
    }

    async Task<Resp> Call(string ep, HttpMethod m, string path, string token, JsonNode body = null, CancellationToken ct = default, bool measure = true)
    {
        var r = new Resp(); Interlocked.Increment(ref inflight);
        try
        {
            using var rq = new HttpRequestMessage(m, baseUrl + path); rq.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
            if (body != null) rq.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            var sw = Stopwatch.StartNew();
            using var rs = await http.SendAsync(rq, ct);
            r.Raw = await rs.Content.ReadAsStringAsync();
            if (measure) Lat(ep, sw.Elapsed.TotalMilliseconds);
            r.Status = (int)rs.StatusCode; Count("requests"); Count($"status:{r.Status}");
            try { r.J = r.Raw.Length > 0 && r.Raw[0] == '{' ? JsonNode.Parse(r.Raw) : null; } catch { r.J = null; }
            CheckRefusal(ep, r.Status, r.J, r.Raw);
            var ep2 = r.J?["epoch"]?.ToString(); if (!string.IsNullOrEmpty(ep2)) epochNow = ep2;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { r.Transport = true; Count("dropped by the driver: " + ep); }
        catch (Exception e) { r.Transport = true; transport.Enqueue((Now, $"{ep}: {e.GetType().Name} {e.Message}")); }
        finally { Interlocked.Decrement(ref inflight); }
        return r;
    }

    static JsonObject O(params (string K, JsonNode V)[] kv) { var o = new JsonObject(); foreach (var (k, v) in kv) o[k] = v; return o; }
    static string Text(Random r, int min, int max) { var n = r.Next(min, max); var sb = new StringBuilder(n); const string w = "the item needs a rebase after the shared file changed in the last merge "; while (sb.Length < n) sb.Append(w); return sb.ToString(0, n); }
    void SetEpoch(Sess s, string epoch) { if (string.IsNullOrEmpty(epoch) || s.Epoch == epoch) return; lock (s) { s.Epoch = epoch; s.Cursor = ""; s.After = 0; } }

    // ---- receiving: what a client does with an event, from a stream or a poll (sourceStart: when that stream or poll was requested) ----------
    async Task OnEvent(Sess s, JsonNode j, double sourceStart, bool fromStream)
    {
        var ev = j?["event"]?.ToString() ?? "";
        if (ev == "worker.registered" || ev == "supervisor.registered") { SetEpoch(s, j["epoch"]?.ToString()); Count("registered"); return; }
        if (ev == "stream.replaced") { Count("stream.replaced seen"); return; }
        if (ev != "message.received" && ev != "supervisor.questions" && ev != "supervisor.patrol") { Count("event:" + ev); return; }
        var id = j["id"]?.ToString() ?? ""; var to = j["to"]?.ToString() ?? "";
        if (id == "") { Violation($"{s.Name} got a {ev} without an id"); return; }
        if (to != s.Name && ev != "supervisor.patrol") Violation($"{s.Name} received {id} addressed to '{to}'");   // a patrol names no recipient: it goes to whoever holds the slot
        Got g; bool first;
        lock (s) { first = !s.Seen.TryGetValue(id, out g); if (first) s.Seen[id] = g = new Got { At = Now, Type = ev == "message.received" ? (j["type"]?.ToString() ?? "") : ev }; }
        if (!first)
        {
            Count("redelivered before its acknowledgement (allowed)");
            if (g.AckAt >= 0 && sourceStart > g.AckAt) { Count("redelivered before its acknowledgement (allowed)", -1); Violation($"{s.Name} got {id} again from a {(fromStream ? "stream" : "poll")} started {sourceStart - g.AckAt:F2}s after its delivered-acknowledgement was confirmed"); }
            return;
        }
        Count("received:" + g.Type);
        if (fromStream && j["replayed"]?.GetValue<bool>() != true && DateTime.TryParse(j["sentAt"]?.ToString(), null, System.Globalization.DateTimeStyles.RoundtripKind, out var sent)) Lat("delivery: accepted -> read on an open stream", Math.Max(0, (DateTime.UtcNow - sent.ToUniversalTime()).TotalMilliseconds));
        if (ev == "message.received" && j["inReplyTo"] != null && (g.Type == "answer" || g.Type == "operator-note")) answersGot.AddOrUpdate(j["inReplyTo"].ToString(), 1, (_, v) => v + 1);
        var a = await Call("POST /messages/ack", HttpMethod.Post, "/api/v1/messages/ack", s.Token, O(("ids", new JsonArray(id)), ("state", s.R.Next(2) == 0 ? "delivered" : "handled")));
        if (a.Status == 200 && (a.J?["acked"]?.GetValue<int>() ?? 0) >= 1) lock (s) g.AckAt = Now;
        if (!s.Sup) return;
        if (ev == "supervisor.questions")
        {
            var ids = (j["questions"] as JsonArray ?? new JsonArray()).Select(q => q["id"].ToString()).Where(q => answeredByMe.TryAdd(q, 1)).ToList();
            foreach (var q in j["questions"] as JsonArray ?? new JsonArray()) questions.TryAdd(q["id"].ToString(), q["from"]?.ToString() ?? "");
            if (ids.Count > 0) _ = Track(Task.Run(async () => { await Task.Delay(s.R.Next(200, 1500)); await Answer(s, ids); }));
        }
        else if (ev == "supervisor.patrol")
        {
            var seq = j["seq"]?.GetValue<long>() ?? 0;
            _ = Track(Call("POST /supervisor/patrol-ack", HttpMethod.Post, "/api/v1/supervisor/patrol-ack", s.Token, O(("seq", seq), ("note", "looked at the attention entries"))));
        }
    }
    Task Track(Task t) { lock (tasks) { tasks.RemoveAll(x => x.IsCompleted); tasks.Add(t); } return t; }

    async Task Answer(Sess s, List<string> ids)
    {
        if (ids.Count == 1 || s.R.Next(10) == 0)
        {
            foreach (var q in ids)
            {
                var r = await Call("POST /messages (answer)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "answer"), ("inReplyTo", q), ("text", "Use the criterion as the item states it."), ("note", "answered from the item text")));
                if (r.Status == 200 && questions.TryGetValue(q, out var asker)) AddAccepted(r.J["id"].ToString(), asker, s.Name, "answer", r.J["epoch"]?.ToString());
                else if (r.Status != 200) answeredByMe.TryRemove(q, out _);
            }
            return;
        }
        var arr = new JsonArray(); foreach (var q in ids.Take(5)) arr.Add(O(("inReplyTo", q), ("text", "Use the criterion as the item states it.")));
        var b = await Call("POST /messages (batch answer)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "answer"), ("answers", arr)));
        foreach (var row in b.J?["answers"] as JsonArray ?? new JsonArray())
        {
            var q = row["inReplyTo"]?.ToString() ?? "";
            if (row["ok"]?.GetValue<bool>() == true && questions.TryGetValue(q, out var asker)) AddAccepted(row["id"].ToString(), asker, s.Name, "answer", b.J["epoch"]?.ToString());
            else { var c = row["code"]?.ToString() ?? ""; Count("answer row refused:" + c); if (!Documented.ContainsKey(c)) undocumented.Enqueue($"{Now:F1}s batch answer row code '{c}'"); }
        }
        if (b.Status != 200) foreach (var q in ids) answeredByMe.TryRemove(q, out _);
    }

    void AddAccepted(string id, string to, string sender, string type, string epoch)
    {
        if (to == "operator" || string.IsNullOrEmpty(id)) return;
        if (accepted.TryAdd(id + "|" + to, new Acc { Id = id, To = to, Sender = sender, Type = type, Epoch = epoch ?? "", At = Now })) Count("accepted:" + type);
    }
    void OnSent(Sess s, Resp r, string type)
    {
        if (r.Status == 200 && r.J?["ok"]?.GetValue<bool>() == true && r.J["id"] != null)
        {
            var id = r.J["id"].ToString(); lock (s) { s.Sent.Add(id); if (s.Sent.Count > 50) s.Sent.RemoveAt(0); }
            foreach (var n in r.J["recipients"] as JsonArray ?? new JsonArray()) AddAccepted(id, n.ToString(), s.Name, type, r.J["epoch"]?.ToString());
            foreach (var n in r.J["refused"] as JsonArray ?? new JsonArray()) { var c = n["code"]?.ToString() ?? ""; Count("fan-out refused:" + c); if (!FanoutCodes.Contains(c)) undocumented.Enqueue($"{Now:F1}s fan-out refusal code '{c}'"); }
            if (r.J["duplicate"]?.GetValue<bool>() == true) Count("idempotent retries answered with the first id");
        }
        else if (r.Status == 202 && r.J?["id"] != null) { questions.TryAdd(r.J["id"].ToString(), s.Name); Count("accepted:question"); Count("question answered at once with:" + r.J["code"]); lock (s) s.Sent.Add(r.J["id"].ToString()); }
    }
    // a request whose refusal is known in advance: anything else is a finding (the switch-off is always a possible answer)
    void Expect(string what, Resp r, params string[] codes)
    {
        if (r.Transport) return;
        var code = r.J?["code"]?.ToString() ?? (r.Status == 200 ? "accepted" : "http " + r.Status);
        if (code == "messaging-disabled" || codes.Contains(code)) return;
        Violation($"{what}: expected {string.Join(" or ", codes)}, got {r.Status} {code}");
    }

    async Task StreamOnce(Sess s, int lifeMs)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, s.Life.Token); cts.CancelAfter(lifeMs);
        var started = Now; var ep = s.Sup ? "GET /events (supervisor, connect)" : "GET /events (worker, connect)";
        var q = s.Sup ? $"name={s.Name}&supervisor=1&model=claude-opus-5-5&effort=high&messaging=1" : $"name={s.Name}&type=persistent-local&capabilities=git,pwsh&capacity=1&roles=owner&messaging=1";
        HttpResponseMessage rs = null;
        try
        {
            using var rq = new HttpRequestMessage(HttpMethod.Get, baseUrl + "/api/v1/events?" + q); rq.Headers.TryAddWithoutValidation("Authorization", "Bearer " + s.Token);
            string cur; lock (s) cur = s.Cursor; if (cur != "") rq.Headers.TryAddWithoutValidation("Last-Event-ID", cur);
            var sw = Stopwatch.StartNew();
            rs = await sse.SendAsync(rq, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            Lat(ep, sw.Elapsed.TotalMilliseconds); Count("requests"); Count($"status:{(int)rs.StatusCode}");
            if ((int)rs.StatusCode != 200)
            {
                var raw = await rs.Content.ReadAsStringAsync(); JsonNode j = null; try { j = JsonNode.Parse(raw); } catch { }
                CheckRefusal(ep, (int)rs.StatusCode, j, raw);
                if (s.Sup && j?["code"]?.ToString() == "supervisor-active") { Interlocked.Increment(ref takeoverRefused); await Task.Delay(2000, stop.Token); }
                else await Task.Delay(1000, stop.Token);
                return;
            }
            if (s.Sup && takeoverAt >= 0 && takeoverDone < 0 && s == activeSup) takeoverDone = Now;
            Count("streams opened");
            using var rd = new StreamReader(await rs.Content.ReadAsStreamAsync(cts.Token));
            var pending = "";
            while (true)
            {
                var line = await rd.ReadLineAsync(cts.Token);
                if (line == null) { Count("streams ended by the gateway"); break; }
                if (line.StartsWith("id:")) pending = line.Substring(3).Trim();
                else if (line.StartsWith("data:"))
                {
                    JsonNode j = null; try { j = JsonNode.Parse(line.Substring(5)); } catch { Violation($"{s.Name} got a data line that is not JSON"); }
                    if (j != null) await OnEvent(s, j, started, true);
                    if (pending != "") { lock (s) { if (pending.StartsWith(s.Epoch + ".") || s.Epoch == "") s.Cursor = pending; } pending = ""; }
                }
            }
        }
        catch (OperationCanceledException) { Count("streams killed by the driver"); }
        catch (Exception e) { if (cts.IsCancellationRequested) Count("streams killed by the driver"); else transport.Enqueue((Now, $"{ep} (stream): {e.GetType().Name} {e.Message}")); }
        finally { rs?.Dispose(); }
    }

    async Task PollOnce(Sess s, int timeoutSeconds, bool drop, CancellationToken outer)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(outer); if (drop) cts.CancelAfter(s.R.Next(150, 3000));
        var started = Now; long after; string ep0; lock (s) { after = s.After; ep0 = s.Epoch; }
        var path = $"/api/v1/inbox?after={after}&limit=50" + (timeoutSeconds > 0 ? $"&timeout={timeoutSeconds}" : "") + (ep0 != "" ? "&epoch=" + ep0 : "");
        var r = await Call(timeoutSeconds > 0 ? "GET /inbox (long-poll)" : "GET /inbox", HttpMethod.Get, path, s.Token, null, cts.Token, timeoutSeconds == 0);
        if (drop && r.Transport) Count("long-polls dropped by the driver");
        if (r.Status != 200) return;
        SetEpoch(s, r.J["epoch"]?.ToString());
        foreach (var m in r.J["messages"] as JsonArray ?? new JsonArray()) await OnEvent(s, m, started, false);
        var last = r.J["last"]?.GetValue<long>() ?? 0; lock (s) { if (s.Epoch == (r.J["epoch"]?.ToString() ?? "") && last > s.After) s.After = last; }
    }

    async Task ReceiveLoop(Sess s)
    {
        var ct = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, s.Life.Token).Token;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (s.Sleeper) { await Task.Delay(1000, ct); continue; }
                if (s.Sup || s.R.Next(100) < 55) await StreamOnce(s, s.Sup ? s.R.Next(20000, 60000) : s.R.Next(1500, 30000));
                else { var n = s.R.Next(1, 5); for (var i = 0; i < n && !ct.IsCancellationRequested; i++) { await PollOnce(s, s.R.Next(3, 15), s.R.Next(100) < 30, ct); await Task.Delay(s.R.Next(20, 400), ct); } }
                await Task.Delay(s.R.Next(20, 600), ct);
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Violation($"driver error in the receive loop of {s.Name}: {e.GetType().Name} {e.Message}"); await Task.Delay(500); }
        }
    }

    Sess Peer(Sess s) { Sess p; do { p = workers[s.R.Next(workers.Count)]; } while (p == s); return p; }
    async Task Note(Sess s, string to, string ep = "POST /messages (note)", string type = "note") => OnSent(s, await Call(ep, HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", to), ("text", Text(s.R, 20, 400)), ("item", s.R.Next(100) < 30 ? (JsonNode)(item0 + s.R.Next(20)) : null))), type);

    async Task WorkerAction(Sess s)
    {
        var idx = workers.IndexOf(s); var roll = s.R.Next(1000);
        if (roll < 420) await Note(s, Peer(s).Name);
        else if (roll < 480) { var n = s.R.Next(13, 18); var to = Peer(s).Name; for (var i = 0; i < n; i++) await Note(s, s.R.Next(3) == 0 ? Peer(s).Name : to, "POST /messages (note, burst above the limit)"); Count("bursts above the minute limit"); }
        else if (roll < 520) OnSent(s, await Call("POST /messages (broadcast)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", "*"), ("text", Text(s.R, 20, 300)))), "broadcast");
        else if (roll < 570)
        {   // the thread of an item: sessions 0..4 own items item0+1..5 whose QC worker is session 5..9; any other session is no member
            var it = item0 + 1 + (idx < 5 ? idx : s.R.Next(5));
            OnSent(s, await Call("POST /messages (thread)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("thread", "item-" + it), ("text", Text(s.R, 20, 200)))), "thread");
        }
        else if (roll < 690) OnSent(s, await Call("POST /messages (question)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "question"), ("text", "Which criterion governs here? " + Text(s.R, 10, 200)), ("item", item0 + 100 + s.R.Next(8)), ("context", "development"))), "question");
        else if (roll < 730)
        {   // the same clientId twice: one message
            var cid = "c-" + Guid.NewGuid().ToString("N").Substring(0, 12); var to = Peer(s).Name; var body = O(("to", to), ("text", Text(s.R, 20, 100)), ("clientId", cid));
            var a = await Call("POST /messages (note)", HttpMethod.Post, "/api/v1/messages", s.Token, body.DeepClone()); OnSent(s, a, "note");
            var b = await Call("POST /messages (note)", HttpMethod.Post, "/api/v1/messages", s.Token, body.DeepClone()); OnSent(s, b, "note");
            if (a.Status == 200 && b.Status == 200 && a.J["id"]?.ToString() != b.J["id"]?.ToString()) Violation($"a retry with the same clientId got another id: {a.J["id"]} and {b.J["id"]}");
        }
        else if (roll < 760) Expect("a text over 2,000 characters", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", Peer(s).Name), ("text", new string('x', 2001)))), "too-large");
        else if (roll < 780) Expect("a body that names its sender", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", Peer(s).Name), ("text", "x"), ("from", Peer(s).Name))), "forged-sender");
        else if (roll < 800) Expect("a text that looks like a credential", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", Peer(s).Name), ("text", "the token: " + new string('a', 12) + new string('b', 12)))), "secret-in-message");
        else if (roll < 815) Expect("a note to itself", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", s.Name), ("text", "x"))), "usage");
        else if (roll < 830) Expect("a note to a name that is no session", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", "nobody-here"), ("text", "x"))), "no-such-peer", "rate-limited", "pair-limited");
        else if (roll < 845) Expect("an answer from a worker", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "answer"), ("inReplyTo", "m-00000000-0001"), ("text", "x"))), "not-supervisor");
        else if (roll < 860 && idx >= 10 && idx <= 11) Expect("a note between the owner and the inspector of one item", await Call("POST /messages (refused on purpose)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", workers[idx == 10 ? 11 : 10].Name), ("text", "about the review"))), "independence", "rate-limited", "pair-limited");
        else if (roll < 900) { string id = null; lock (s) { if (s.Sent.Count > 0) id = s.Sent[s.R.Next(s.Sent.Count)]; } if (id != null) await Call("GET /messages/{id}", HttpMethod.Get, "/api/v1/messages/" + id, s.Token); }
        else if (roll < 930) await Call("GET /peers", HttpMethod.Get, "/api/v1/peers", s.Token);
        else if (roll < 960 && !s.Sleeper) await PollOnce(s, 0, false, stop.Token);
        else await Call("POST /presence", HttpMethod.Post, "/api/v1/presence", s.Token, s.R.Next(4) == 0 ? O(("summary", "working on item " + (item0 + s.R.Next(20)))) : new JsonObject());
    }

    async Task SendLoop(Sess s)
    {
        var beat = 0.0;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                if (Now - beat > 15) { beat = Now; await Call("POST /presence", HttpMethod.Post, "/api/v1/presence", s.Token, new JsonObject()); }
                await WorkerAction(s);
                await Task.Delay(s.R.Next(200, 1500), stop.Token);
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Violation($"driver error in the send loop of {s.Name}: {e.GetType().Name} {e.Message}"); await Task.Delay(500); }
        }
    }

    async Task SupervisorLoop(Sess s)
    {
        var ct = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, s.Life.Token).Token; var n = 0;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(s.R.Next(4000, 8000), ct); n++;
                await Call("POST /presence", HttpMethod.Post, "/api/v1/presence", s.Token, new JsonObject(), ct);
                if (n % 4 == 0) OnSent(s, await Call("POST /messages (directive)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "directive"), ("to", workers[s.R.Next(workers.Count)].Name), ("text", "Renew the claim of your item."))), "directive");
                if (n % 14 == 0) OnSent(s, await Call("POST /messages (announcement)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("type", "announcement"), ("to", "*"), ("text", "The plant keeps running during the test."))), "announcement");
                if (n % 5 == 0) await Call("GET /digest", HttpMethod.Get, "/api/v1/digest", s.Token);
                if (n % 6 == 0) await Call("POST /verbs/get-item (supervisor, a rule script)", HttpMethod.Post, "/api/v1/verbs/get-item", s.Token, O(("item", VerbItem)));
                if (n % 7 == 0) OnSent(s, await Call("POST /messages (note)", HttpMethod.Post, "/api/v1/messages", s.Token, O(("to", "operator"), ("text", "A worker looks stuck."))), "note");
                if (n % 3 == 0) await PollOnce(s, 0, false, ct);
                if (n % 9 == 0) await Call("GET /questions", HttpMethod.Get, "/api/v1/questions?state=open", s.Token);
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Violation($"driver error in the supervisor loop: {e.GetType().Name} {e.Message}"); await Task.Delay(500); }
        }
    }

    async Task OperatorLoop()
    {
        var r = new Random(seed * 7 + 3); var n = 0;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(r.Next(1500, 3500), stop.Token); n++;
                var w = workers[r.Next(workers.Count)];
                var a = await Call("POST /messages (operator note)", HttpMethod.Post, "/api/v1/messages", admin, O(("to", w.Name), ("text", "From the operator: " + Text(r, 10, 120))));
                if (a.Status == 200 && a.J?["id"] != null) foreach (var x in a.J["recipients"] as JsonArray ?? new JsonArray()) AddAccepted(a.J["id"].ToString(), x.ToString(), "operator", "operator-note", a.J["epoch"]?.ToString());
                if (n % 2 == 0) await Call("GET /status", HttpMethod.Get, "/api/v1/status", admin);
                if (n % 3 == 0) await Call("GET /dashboard (JSON)", HttpMethod.Get, "/api/v1/dashboard", admin);
                if (n % 4 == 0) await Call("GET /messages (traffic log)", HttpMethod.Get, "/api/v1/messages?limit=200", admin);
                if (n % 5 == 0) await Call("GET /messages (refusal ring)", HttpMethod.Get, "/api/v1/messages?ring=refused&limit=200", admin);
                if (n % 6 == 0) await Call("GET /peers", HttpMethod.Get, "/api/v1/peers?all=1", admin);
                if (n % 8 == 0) await Call("POST /supervisor/budget", HttpMethod.Post, "/api/v1/supervisor/budget?extra=10", admin);
                if (n % 9 == 0) await Call("POST /_test/deliver (a park trigger)", HttpMethod.Post, "/api/v1/_test/deliver", admin, O(("routeItem", item0 + 200 + r.Next(5)), ("park", "master-green-timeout")));
                if (n % 7 == 0)
                {   // the operator answers the oldest open question itself: the supervisor's own answer then meets already-answered
                    var qs = await Call("GET /questions", HttpMethod.Get, "/api/v1/questions?state=open", admin);
                    var first = (qs.J?["questions"] as JsonArray)?.FirstOrDefault();
                    if (first != null)
                    {
                        var qid = first["id"].ToString();
                        var oa = await Call("POST /questions/{id}/answer", HttpMethod.Post, $"/api/v1/questions/{qid}/answer", admin, O(("text", "The operator says: the first criterion.")));
                        if (oa.Status == 200) AddAccepted(oa.J["id"].ToString(), oa.J["to"].ToString(), "operator", "operator-note", epochNow);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { Violation($"driver error in the operator loop: {e.GetType().Name} {e.Message}"); await Task.Delay(500); }
        }
    }

    // who owns, inspects and runs the QC of the thread items (the test seam; the plant forgets it at a restart, so it is set again after one)
    public string SetupRoles()
    {
        var bad = 0;
        for (var i = 0; i < 5 && i + 5 < workers.Count; i++) { var r = Call("POST /_test/roles", HttpMethod.Post, "/api/v1/_test/roles", admin, O(("item", item0 + 1 + i), ("owner", workers[i].Name), ("qc", workers[i + 5].Name))).GetAwaiter().GetResult(); if (r.Status != 200) bad++; }
        if (workers.Count > 11) { var r = Call("POST /_test/roles", HttpMethod.Post, "/api/v1/_test/roles", admin, O(("item", item0 + 11), ("owner", workers[10].Name), ("inspector", workers[11].Name))).GetAwaiter().GetResult(); if (r.Status != 200) bad++; }
        return bad == 0 ? "ok" : bad + " role calls failed";
    }

    public void Start()
    {
        foreach (var w in workers) { tasks.Add(Task.Run(() => ReceiveLoop(w))); tasks.Add(Task.Run(() => SendLoop(w))); }
        tasks.Add(Task.Run(() => ReceiveLoop(activeSup))); tasks.Add(Task.Run(() => SupervisorLoop(activeSup))); tasks.Add(Task.Run(OperatorLoop));
    }

    // the active supervisor goes silent (its stream is cut, no heartbeat); the other name asks for the slot until the gateway hands it over
    public void Takeover()
    {
        if (sups.Count < 2) return;
        var old = activeSup; old.Life.Cancel(); takeoverAt = Now;
        activeSup = sups.First(x => x != old);
        lock (tasks) { tasks.Add(Task.Run(() => ReceiveLoop(activeSup))); tasks.Add(Task.Run(() => SupervisorLoop(activeSup))); }
    }

    public string Progress() => $"requests {counts.GetValueOrDefault("requests")}, accepted {accepted.Count}, questions {questions.Count}, 5xx {fivexx.Count}, violations {violations.Count}, undocumented {undocumented.Count}, transport errors {transport.Count}, epoch {epochNow}";

    // ---- the end: stop the traffic, let every session read what is left, then account for every accepted message ------------------------------
    public string Finish()
    {
        var trafficSeconds = Now;
        stop.Cancel();
        Task[] all; lock (tasks) all = tasks.ToArray();
        Task.WaitAll(all.Select(t => t.ContinueWith(_ => { })).ToArray(), 30000);
        var wait = Stopwatch.StartNew(); while (Volatile.Read(ref inflight) > 0 && wait.Elapsed.TotalSeconds < 20) Thread.Sleep(100);
        var finalEpoch = Call("GET /status", HttpMethod.Get, "/api/v1/status", admin).GetAwaiter().GetResult().J?["messaging"]?["epoch"]?.ToString() ?? "";
        // drain: every inbox from the start, until it holds nothing undelivered
        var undrained = 0;
        foreach (var s in workers.Concat(new[] { activeSup }))
        {
            for (var round = 0; round < 60; round++)
            {
                var started = Now;
                var r = Call("GET /inbox", HttpMethod.Get, "/api/v1/inbox?after=0&limit=50", s.Token).GetAwaiter().GetResult();
                if (r.Status != 200) { Violation($"the final drain of {s.Name} got {r.Status} {r.J?["code"]}"); break; }
                SetEpoch(s, r.J["epoch"]?.ToString());
                var msgs = r.J["messages"] as JsonArray ?? new JsonArray();
                if (msgs.Count == 0) break;
                if (round == 59) undrained++;
                foreach (var m in msgs) OnEvent(s, m, started, false).GetAwaiter().GetResult();
            }
        }
        Task[] late; lock (tasks) late = tasks.ToArray();
        Task.WaitAll(late.Select(t => t.ContinueWith(_ => { })).ToArray(), 20000);
        if (undrained > 0) Violation($"{undrained} inboxes still returned undelivered messages after 60 reads");

        var by = workers.Concat(sups).ToDictionary(s => s.Name, s => s);
        int once = 0, expired = 0, lostToRestart = 0, lost = 0, unknownRecipient = 0;
        var states = new Dictionary<string, int>();
        foreach (var a in accepted.Values.OrderBy(a => a.At))
        {
            if (!by.TryGetValue(a.To, out var rcp)) { unknownRecipient++; Violation($"{a.Id} was accepted for '{a.To}', which is no session of this run"); continue; }
            bool got; lock (rcp) got = rcp.Seen.ContainsKey(a.Id);
            if (got) { once++; continue; }
            var st = Call("GET /messages/{id} (operator, verification)", HttpMethod.Get, "/api/v1/messages/" + a.Id, admin).GetAwaiter().GetResult();
            if (st.Status == 404 && st.J?["epochChanged"]?.GetValue<bool>() == true) { lostToRestart++; continue; }
            var per = st.J?["perRecipient"]?[a.To]?.ToString() ?? (st.Status == 200 ? "absent" : "http " + st.Status + " " + st.J?["code"]);
            states[per] = states.GetValueOrDefault(per) + 1;
            if (per == "expired") { expired++; continue; }
            lost++; Violation($"LOST: {a.Type} {a.Id} from {a.Sender} to {a.To} (accepted at {a.At:F1}s, epoch {a.Epoch}) was never read by its recipient and its state is '{per}'");
        }
        // every message a session read must be one a sender was told was accepted for that session (a send cut off by the restart cannot be known)
        int phantomOld = 0, phantom = 0;
        foreach (var s in workers)
        {
            List<string> ids; lock (s) ids = s.Seen.Keys.ToList();
            foreach (var id in ids)
            {
                if (accepted.ContainsKey(id + "|" + s.Name)) continue;
                if (finalEpoch.Length > 2 && id.StartsWith("m-" + finalEpoch.Substring(2) + "-")) { phantom++; Violation($"{s.Name} read {id}, which no sender was told had been accepted for it"); } else phantomOld++;
            }
        }
        foreach (var kv in answersGot.Where(kv => kv.Value > 1)) Violation($"question {kv.Key} was answered to its asker {kv.Value} times");
        int qAnswered = 0, qOpen = 0, qOther = 0, qRestart = 0; var qStates = new Dictionary<string, int>();
        foreach (var q in questions.Keys)
        {
            var st = Call("GET /messages/{id} (operator, verification)", HttpMethod.Get, "/api/v1/messages/" + q, admin).GetAwaiter().GetResult();
            if (st.Status == 404 && st.J?["epochChanged"]?.GetValue<bool>() == true) { qRestart++; continue; }
            var state = st.J?["state"]?.ToString() ?? "http " + st.Status + " " + st.J?["code"];
            qStates[state] = qStates.GetValueOrDefault(state) + 1;
            if (state == "answered") qAnswered++; else if (state == "open") qOpen++; else if (state == "expired" || state == "moot") qOther++;
            else Violation($"question {q} of {questions[q]} is in state '{state}'");
        }
        var outside = transport.Where(t => !InOutage(t.At)).Select(t => $"{t.At:F1}s {t.What}").ToList();

        var o = new JsonObject
        {
            ["trafficSeconds"] = Math.Round(trafficSeconds, 1), ["requests"] = counts.GetValueOrDefault("requests"), ["finalEpoch"] = finalEpoch,
            ["fivexx"] = new JsonArray(fivexx.Take(20).Select(x => (JsonNode)x).ToArray()), ["fivexxCount"] = fivexx.Count,
            ["violations"] = new JsonArray(violations.Take(40).Select(x => (JsonNode)x).ToArray()), ["violationCount"] = counts.GetValueOrDefault("violations"),
            ["undocumented"] = new JsonArray(undocumented.Take(20).Select(x => (JsonNode)x).ToArray()), ["undocumentedCount"] = undocumented.Count,
            ["transportErrors"] = transport.Count, ["transportOutsideRestart"] = new JsonArray(outside.Take(20).Select(x => (JsonNode)x).ToArray()), ["transportOutsideRestartCount"] = outside.Count,
            ["accepted"] = accepted.Count, ["readOnce"] = once, ["reportedExpired"] = expired, ["lostToRestartReported"] = lostToRestart, ["lost"] = lost, ["unknownRecipient"] = unknownRecipient,
            ["readWithoutKnownAcceptance"] = phantom, ["readFromSendsCutByRestart"] = phantomOld,
            ["questions"] = questions.Count, ["questionsAnswered"] = qAnswered, ["questionsOpen"] = qOpen, ["questionsExpiredOrMoot"] = qOther, ["questionsLostToRestart"] = qRestart,
            ["takeoverSeconds"] = takeoverDone >= 0 ? Math.Round(takeoverDone - takeoverAt, 1) : -1, ["takeoverRefusals"] = takeoverRefused
        };
        var c = new JsonObject(); foreach (var kv in counts.OrderBy(k => k.Key, StringComparer.Ordinal)) c[kv.Key] = kv.Value; o["counts"] = c;
        var ls = new JsonObject();
        foreach (var kv in lat.OrderBy(k => k.Key, StringComparer.Ordinal))
        {
            double[] v; lock (kv.Value) v = kv.Value.OrderBy(x => x).ToArray(); if (v.Length == 0) continue;
            double P(double p) => v[Math.Min(v.Length - 1, (int)Math.Ceiling(p * v.Length) - 1 < 0 ? 0 : (int)Math.Ceiling(p * v.Length) - 1)];
            ls[kv.Key] = new JsonObject { ["count"] = v.Length, ["p50"] = Math.Round(P(0.50), 1), ["p95"] = Math.Round(P(0.95), 1), ["p99"] = Math.Round(P(0.99), 1), ["max"] = Math.Round(v[v.Length - 1], 1) };
        }
        o["latencyMs"] = ls;
        return o.ToJsonString();
    }
}
'@
Add-Type -TypeDefinition $driverSource -Language CSharp -WarningAction SilentlyContinue

# ---- the environment: a fake GitHub and the gateway under test ----------------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) "factory-stress-$([guid]::NewGuid().ToString('N').Substring(0,8))"; New-Item -ItemType Directory -Force -Path $work | Out-Null
$hex = { param($n) -join ([Security.Cryptography.RandomNumberGenerator]::GetBytes($n) | ForEach-Object { $_.ToString('x2') }) }
$adminToken = "stress-$(& $hex 16)"; $names = @(1..$Workers | ForEach-Object { 'w{0:d2}' -f $_ })
$cfg = Get-Content -Raw (Join-Path $root 'config/instance.json') | ConvertFrom-Json -AsHashtable
$cfg.octopus.url = "http://127.0.0.1:$fakePort/octopus"
$cfg.messaging.enabled = $true; $cfg.messaging.allowedWorkers = $names; $cfg.messaging.testHooks = $true
$cfg.manager.enabled = $true; $cfg.manager.allowedNames = @('supervisor', 'supervisor2'); $cfg.manager.allowedAskers = $names
# the supervisor answers for ten minutes without a pause: its step budget is raised so that the answers keep flowing (the limit itself has its scenario)
$cfg.manager.stepBudgetPerHour = 400
$cfg.runner = @{ pool = 3 }
$cfgPath = Join-Path $work 'instance.stress.json'; $cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath
$gwEnv = @{
    FAKE_PORT = "$fakePort"; GITHUB_API_URL = "http://127.0.0.1:$fakePort"; GH_TOKEN = 'fake-operator'; OCTOPUS_API_KEY = 'fake'; FACTORY_FAKE_APPS = '1'
    FACTORY_CONFIG = $cfgPath; FACTORY_STATE_DIR = (Join-Path $work 'state'); FACTORY_PLUGIN_SCRIPTS = (Join-Path $root 'plugin/scripts'); FACTORY_DEV_TOKEN = $adminToken
    FACTORY_WEBHOOK_SECRET = (& $hex 20); FACTORY_API_PORT = "$apiPort"; FACTORY_WEBHOOK_PORT = "$hookPort"; FACTORY_SWEEP_SECONDS = '5'
    FACTORY_OWNER_MODE = '1'; FACTORY_PLANT_SNAPSHOT = '0'; FACTORY_TOKEN_SECRET = (& $hex 24); FACTORY_ASSIGN_ACK_SECONDS = '60'; FACTORY_URL = "http://127.0.0.1:$apiPort"; FACTORY_TOKEN = $adminToken
    FACTORY_TIMING_msgTtlMinutes = '2'; FACTORY_TIMING_mgrTakeoverSeconds = '20'; FACTORY_TIMING_mgrPatrolMinutes = '1'; FACTORY_TIMING_mgrDigestSeconds = '5'; FACTORY_TIMING_mgrBatchSeconds = '3'
    HOME = (Join-Path $work 'home'); TMPDIR = (Join-Path $work 'tmp')
}
foreach ($d in 'home', 'tmp', 'state') { New-Item -ItemType Directory -Force -Path (Join-Path $work $d) | Out-Null }
$base = "http://127.0.0.1:$apiPort"; $adminHeaders = @{ Authorization = "Bearer $adminToken" }
$isProc = Test-Path '/proc/self/status'
# the processes that exist before this run: whatever of ours is alive afterwards and is not in this set was left behind
function Get-OurProcesses {
    if (-not $isProc) { return @(Get-Process -Name pwsh, dotnet -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | ForEach-Object { @{ pid = $_.Id; cmd = $_.ProcessName } }) }
    @(Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' -and [int]$_.Name -ne $PID } | ForEach-Object {
            $c = try { [IO.File]::ReadAllText("/proc/$($_.Name)/cmdline") -replace "`0", ' ' } catch { '' }
            if ($c -match 'runner-host\.ps1|FactoryWorker\.Gateway\.dll|FakeGitHub\.dll|plugin/scripts/factory\.ps1') { @{ pid = [int]$_.Name; cmd = $c.Substring(0, [Math]::Min(160, $c.Length)) } } })
}
$before = @{}; foreach ($p in Get-OurProcesses) { $before[$p.pid] = $true }
$started = New-Object System.Collections.ArrayList; $gwRuns = 0
function Start-With([string]$Dll, [string]$Tag) {
    $saved = @{}; foreach ($k in $gwEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $gwEnv[$k]) }
    try { $p = Start-Process dotnet -ArgumentList $Dll -PassThru -RedirectStandardOutput (Join-Path $work "$Tag.out") -RedirectStandardError (Join-Path $work "$Tag.err") }
    finally { foreach ($k in $gwEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    [void]$started.Add($p); return $p
}
function Wait-Health([int]$Seconds = 40) { $end = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $end) { try { if (Invoke-RestMethod "$base/health" -TimeoutSec 2) { return $true } } catch { }; Start-Sleep -Milliseconds 300 }; return $false }
function Start-Gateway { $script:gwRuns++; $script:gw = Start-With $gwDll "gateway-$($script:gwRuns)"; if (-not (Wait-Health)) { throw 'the gateway did not answer /health' } }
function Get-Sample([double]$T) {
    $s = [ordered]@{ t = [math]::Round($T, 1); run = $script:gwRuns; pid = $script:gw.Id; rssMb = 0.0; threads = 0; handles = 0; children = 0; stores = $null }
    try {
        if ($isProc) {
            $st = Get-Content "/proc/$($script:gw.Id)/status"
            $s.rssMb = [math]::Round([double](($st | Where-Object { $_ -like 'VmRSS:*' }) -replace '\D', '') / 1024, 1); $s.threads = [int](($st | Where-Object { $_ -like 'Threads:*' }) -replace '\D', '')
            $s.handles = @(Get-ChildItem "/proc/$($script:gw.Id)/fd" -ErrorAction SilentlyContinue).Count
            $s.children = @(Get-ChildItem /proc -Directory | Where-Object { $_.Name -match '^\d+$' } | Where-Object { try { ((Get-Content "/proc/$($_.Name)/stat" -ErrorAction Stop) -replace '^.*\) ', '').Split(' ')[1] -eq "$($script:gw.Id)" } catch { $false } }).Count
        } else { $gp = Get-Process -Id $script:gw.Id; $s.rssMb = [math]::Round($gp.WorkingSet64 / 1MB, 1); $s.threads = $gp.Threads.Count; $s.handles = $gp.HandleCount }
    } catch { }
    try { $s.stores = Invoke-RestMethod "$base/api/v1/_test/stores" -Headers $adminHeaders -TimeoutSec 5 } catch { }
    return $s
}

$failures = New-Object System.Collections.ArrayList; $samples = New-Object System.Collections.ArrayList; $report = $null; $events = New-Object System.Collections.ArrayList
try {
    $fake = Start-With $fakeDll 'fake'
    $end = (Get-Date).AddSeconds(30); while ((Get-Date) -lt $end) { try { if (Invoke-RestMethod "http://127.0.0.1:$fakePort/_fake/state" -TimeoutSec 2) { break } } catch { }; Start-Sleep -Milliseconds 300 }
    $verbItem = (Invoke-RestMethod "http://127.0.0.1:$fakePort/_fake/issue" -Method POST -Body (@{ title = 'Stress item'; body = 'x'; labels = @(); column = 'Technical Design' } | ConvertTo-Json) -ContentType 'application/json').number
    Start-Gateway
    # credentials as the operator gets them from the gateway: never printed, never written to a file
    $wt = [Collections.Generic.Dictionary[string, string]]::new(); foreach ($n in $names) { $wt[$n] = (Invoke-RestMethod "$base/api/v1/workers/$n/credential" -Method POST -Headers $adminHeaders).token }
    $stk = [Collections.Generic.Dictionary[string, string]]::new(); foreach ($n in 'supervisor', 'supervisor2') { $stk[$n] = (Invoke-RestMethod "$base/api/v1/workers/$n/credential?role=manager" -Method POST -Headers $adminHeaders).token }
    $driver = [StressDriver]::new($base, $adminToken, $wt, $stk, $Seed, [Math]::Min(3, [Math]::Max(0, $Workers - 12)))
    $driver.VerbItem = [int]$verbItem
    Write-Host "stress: $Workers workers, 1 supervisor, $Seconds s, gateway pid $($gw.Id) on $base, work $work"
    Write-Host "  roles of the thread items: $($driver.SetupRoles())"
    [void]$samples.Add((Get-Sample 0))
    $sw = [Diagnostics.Stopwatch]::StartNew(); $driver.Start()
    $plan = [ordered]@{ takeover = 0.25 * $Seconds; restart = 0.35 * $Seconds; disable = 0.55 * $Seconds; enable = 0.55 * $Seconds + 20 }; $done = @{}
    $nextSample = 10.0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 500; $t = $sw.Elapsed.TotalSeconds
        if ($t -ge $plan.takeover -and -not $done.ContainsKey('takeover')) { $done.takeover = $true; $driver.Takeover(); [void]$events.Add("$([math]::Round($t))s the supervisor goes silent, supervisor2 asks for the slot"); Write-Host "  $($events[-1])" }
        if ($t -ge $plan.restart -and -not $done.ContainsKey('restart')) {
            $done.restart = $true; $driver.OutageBegin(); $oldPid = $gw.Id
            Stop-Process -Id $oldPid -Force; [void]$gw.WaitForExit(10000); Start-Sleep -Milliseconds 500
            Start-Gateway; $driver.OutageEnd()
            [void]$events.Add("$([math]::Round($t))s the gateway (pid $oldPid) was killed and started again (pid $($gw.Id)) in $([math]::Round($sw.Elapsed.TotalSeconds - $t, 1)) s; roles: $($driver.SetupRoles())"); Write-Host "  $($events[-1])"
        }
        if ($t -ge $plan.disable -and -not $done.ContainsKey('disable')) { $done.disable = $true; $r = Invoke-RestMethod "$base/api/v1/messaging/disable" -Method POST -Headers $adminHeaders; [void]$events.Add("$([math]::Round($t))s messaging switched off (changed: $($r.changed))"); Write-Host "  $($events[-1])" }
        if ($t -ge $plan.enable -and -not $done.ContainsKey('enable')) { $done.enable = $true; $r = Invoke-RestMethod "$base/api/v1/messaging/enable" -Method POST -Headers $adminHeaders; [void]$events.Add("$([math]::Round($t))s messaging switched on (changed: $($r.changed))"); Write-Host "  $($events[-1])" }
        if ($t -ge $nextSample) {
            $nextSample += 10; $s = Get-Sample $t; [void]$samples.Add($s)
            if (([int]($t / 10)) % 6 -eq 0) { Write-Host ("  {0,4:N0}s rss {1} MB, threads {2}, handles {3}, children {4}; {5}" -f $t, $s.rssMb, $s.threads, $s.handles, $s.children, $driver.Progress()) }
        }
    }
    Write-Host '  traffic ends; draining every inbox and accounting for every accepted message'
    $report = $driver.Finish() | ConvertFrom-Json -AsHashtable
    [void]$samples.Add((Get-Sample $sw.Elapsed.TotalSeconds))
} catch { [void]$failures.Add("the run itself failed: $($_.Exception.Message)") }
finally {
    foreach ($p in $started) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { } }
}

# ---- what the run must show -----------------------------------------------------------------------------------------------------------------------
Start-Sleep -Seconds 6
$left = @(Get-OurProcesses | Where-Object { -not $before.ContainsKey($_.pid) })
if ($left.Count) { Start-Sleep -Seconds 6; $left = @(Get-OurProcesses | Where-Object { -not $before.ContainsKey($_.pid) }) }
if ($left.Count) { [void]$failures.Add("$($left.Count) processes of this run are still alive: $(($left | ForEach-Object { "$($_.pid) $($_.cmd)" }) -join '; ')") }
$logBad = @(); $logLines = 0
foreach ($f in Get-ChildItem $work -File -Filter 'gateway-*') {
    $logLines += @(Get-Content $f.FullName).Count
    $logBad += @(Select-String -Path $f.FullName -Pattern 'internal error|internal-error|sweepError|"sweep":"error"|"sweep":"failed"|Unhandled exception|^\s*fail:|^\s*crit:' | ForEach-Object { "$($f.Name): $($_.Line.Substring(0, [Math]::Min(220, $_.Line.Length)))" })
}
if ($logBad.Count) { [void]$failures.Add("$($logBad.Count) error lines in the gateway logs, first: $($logBad[0])") }
$mem = [ordered]@{}
if ($report) {
    if ($report.fivexxCount) { [void]$failures.Add("$($report.fivexxCount) responses with a 5xx status, first: $($report.fivexx[0])") }
    if ($report.violationCount) { [void]$failures.Add("$($report.violationCount) violations, first: $($report.violations[0])") }
    if ($report.undocumentedCount) { [void]$failures.Add("$($report.undocumentedCount) refusals outside the documented codes, first: $($report.undocumented[0])") }
    if ($report.transportOutsideRestartCount) { [void]$failures.Add("$($report.transportOutsideRestartCount) requests failed outside the restart window, first: $($report.transportOutsideRestart[0])") }
    if ($report.lost) { [void]$failures.Add("$($report.lost) accepted messages were lost") }
    if ($report.accepted -lt 100) { [void]$failures.Add("only $($report.accepted) messages were accepted: the run proved nothing") }
}
# stores: every sample, every store that has a cap
$storeMax = [ordered]@{}
foreach ($s in $samples) { if ($s.stores) { foreach ($pr in $s.stores.PSObject.Properties) { $v = $pr.Value; $n = if ($v -is [ValueType]) { [long]$v } else { [long]$v.count }; $cap = if ($v -is [ValueType]) { $null } else { [long]$v.cap }
            if (-not $storeMax.Contains($pr.Name) -or $storeMax[$pr.Name].max -lt $n) { $storeMax[$pr.Name] = @{ max = $n; cap = $cap; at = $s.t } }
            if ($null -ne $cap -and $n -gt $cap) { [void]$failures.Add("store $($pr.Name) held $n at $($s.t)s, above its cap of $cap") } } } }
# memory: the gateway process that ran to the end (the one started by the restart)
$lastRun = @($samples | Where-Object { $_.run -eq $gwRuns -and $_.rssMb -gt 0 })
if ($lastRun.Count -ge 6) {
    $t0 = $lastRun[0].t; $life = $lastRun[-1].t - $t0; $warm = [Math]::Min(60, 0.2 * $life)
    $after = @($lastRun | Where-Object { $_.t -ge $t0 + $warm }); $baseRss = $after[0].rssMb; $peak = ($after | ForEach-Object { $_.rssMb } | Measure-Object -Maximum).Maximum
    $mem.warmUpSeconds = [math]::Round($warm); $mem.rssAfterWarmUpMb = $baseRss; $mem.rssPeakMb = $peak; $mem.rssEndMb = $lastRun[-1].rssMb; $mem.peakOverWarm = [math]::Round($peak / $baseRss, 2)
    if ($peak -gt 2 * $baseRss) { [void]$failures.Add("gateway memory grew to $peak MB, more than twice the $baseRss MB after warm-up") }
    $win = [Math]::Min(300, $life - $warm); $from = $lastRun[-1].t - $win; $slices = @()
    foreach ($i in 0..4) { $part = @($lastRun | Where-Object { $_.t -ge $from + $i * $win / 5 -and $_.t -lt $from + ($i + 1) * $win / 5 + $(if ($i -eq 4) { 1 } else { 0 }) } | ForEach-Object { $_.rssMb } | Sort-Object); if ($part.Count) { $slices += $part[[int][Math]::Floor(($part.Count - 1) / 2)] } }
    $mem.lastWindowSeconds = [math]::Round($win); $mem.sliceMediansMb = $slices
    $rising = $slices.Count -eq 5; for ($i = 1; $i -lt $slices.Count; $i++) { if ($slices[$i] -le $slices[$i - 1] * 1.005) { $rising = $false } }
    $mem.monotonic = $rising
    if ($rising) { [void]$failures.Add("gateway memory grew in every one of the five slices of the last $([math]::Round($win)) s: $($slices -join ' -> ') MB") }
} else { [void]$failures.Add('too few memory samples of the last gateway process') }

Write-Host ''
Write-Host '== stress result =='
if ($report) {
    Write-Host ("requests {0} in {1} s ({2:N0}/s); accepted (message, recipient) pairs {3}: read once {4}, reported expired {5}, lost to the restart and reported {6}, LOST {7}" -f $report.requests, $report.trafficSeconds, ($report.requests / $report.trafficSeconds), $report.accepted, $report.readOnce, $report.reportedExpired, $report.lostToRestartReported, $report.lost)
    Write-Host ("questions {0}: answered {1}, open {2}, expired or moot {3}, lost to the restart {4}; takeover after {5} s ({6} refusals supervisor-active)" -f $report.questions, $report.questionsAnswered, $report.questionsOpen, $report.questionsExpiredOrMoot, $report.questionsLostToRestart, $report.takeoverSeconds, $report.takeoverRefusals)
    Write-Host ("5xx {0}; violations {1}; undocumented refusals {2}; transport errors {3}, of them outside the restart window {4}; gateway log lines {5}, error lines {6}" -f $report.fivexxCount, $report.violationCount, $report.undocumentedCount, $report.transportErrors, $report.transportOutsideRestartCount, $logLines, $logBad.Count)
    Write-Host 'refusals by code: ' -NoNewline; Write-Host ((@($report.counts.Keys | Where-Object { $_ -like 'refused:*' }) | ForEach-Object { "$($_.Substring(8)) $($report.counts[$_])" }) -join ', ')
    Write-Host ''
    Write-Host ('{0,-52} {1,7} {2,8} {3,8} {4,8} {5,8}' -f 'endpoint (ms)', 'count', 'p50', 'p95', 'p99', 'max')
    foreach ($k in $report.latencyMs.Keys) { $l = $report.latencyMs[$k]; Write-Host ('{0,-52} {1,7} {2,8:N1} {3,8:N1} {4,8:N1} {5,8:N1}' -f $k, $l.count, $l.p50, $l.p95, $l.p99, $l.max) }
}
Write-Host ''
Write-Host ('{0,-10} {1,6} {2,8} {3,8} {4,8} {5,9}' -f 'gateway', 't (s)', 'rss MB', 'threads', 'handles', 'children')
$pick = @($samples[0]) + @($samples | Where-Object { $_.run -eq 1 } | Select-Object -Last 1) + @($samples | Where-Object { $_.run -eq $gwRuns } | Select-Object -First 1) + @($samples[[int]($samples.Count / 2)]) + @($samples | Where-Object { $_.run -eq $gwRuns } | Select-Object -Last 2 | Select-Object -First 1) + @($samples[-1])
foreach ($s in ($pick | Sort-Object { $_.t } -Unique)) { Write-Host ('{0,-10} {1,6} {2,8} {3,8} {4,8} {5,9}' -f "run $($s.run)", $s.t, $s.rssMb, $s.threads, $s.handles, $s.children) }
if ($mem.Count) { Write-Host ("memory of the last gateway process: {0} MB after {1} s warm-up, peak {2} MB ({3}x), end {4} MB; slice medians of the last {5} s: {6} MB; grows in every slice: {7}" -f $mem.rssAfterWarmUpMb, $mem.warmUpSeconds, $mem.rssPeakMb, $mem.peakOverWarm, $mem.rssEndMb, $mem.lastWindowSeconds, ($mem.sliceMediansMb -join ' -> '), $mem.monotonic) }
Write-Host ('threads max {0}, handles max {1}, child processes max {2}; processes left behind: {3}' -f ($samples | ForEach-Object { $_.threads } | Measure-Object -Maximum).Maximum, ($samples | ForEach-Object { $_.handles } | Measure-Object -Maximum).Maximum, ($samples | ForEach-Object { $_.children } | Measure-Object -Maximum).Maximum, $left.Count)
Write-Host 'stores (largest count seen / cap): ' -NoNewline; Write-Host (($storeMax.Keys | ForEach-Object { "$_ $($storeMax[$_].max)$(if ($null -ne $storeMax[$_].cap) { "/$($storeMax[$_].cap)" })" }) -join ', ')
Write-Host ''
if ($failures.Count) { Write-Host "FAILED ($($failures.Count)):"; $failures | ForEach-Object { Write-Host "  $_" } } else { Write-Host 'PASSED: no 5xx, no error line, nothing lost, nothing delivered twice after its acknowledgement, only documented refusals, stores within their caps, memory bounded, no process left' }
if ($ReportFile) { [ordered]@{ seconds = $Seconds; workers = $Workers; seed = $Seed; failures = @($failures); events = @($events); report = $report; memory = $mem; stores = $storeMax; samples = @($samples | ForEach-Object { [ordered]@{ t = $_.t; run = $_.run; rssMb = $_.rssMb; threads = $_.threads; handles = $_.handles; children = $_.children } }); logErrorLines = @($logBad | Select-Object -First 20); processesLeft = @($left | ForEach-Object { $_.cmd }) } | ConvertTo-Json -Depth 8 | Set-Content $ReportFile }
if (-not $KeepWork -and -not $failures.Count) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue } else { Write-Host "work directory kept: $work" }
exit ([int]($failures.Count -gt 0))
