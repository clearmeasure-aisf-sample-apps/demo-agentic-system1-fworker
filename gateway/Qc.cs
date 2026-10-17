using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

// PR QC environment, gateway side (design: docs/design/pr-qc-environment.md). Click pages and endpoints, the in-memory half of the QC state
// (lease, heartbeat, URL, client address, probe result, log tail, page nonces, rate counters) and the checks on a URL a worker reports.
// The persisted half (the record in the work item's state comment) is written only by the rule scripts (plugin/scripts/lib/Qc.ps1).

sealed class QcSettings
{
    public bool TrustProxy, AllowLoopback;
    public string[] KnownProxies = Array.Empty<string>();
    public string RepoUrl = "";
    public int RatePerIp = 10, RatePerPr = 20, ProbeTimeoutSeconds = 5, MaxEnvironments = 3, WaitingDelaySeconds = 300, NonceMinutes = 10, TestReconcileDelayMs;
    public double MinFreeMb = 3500, LeaseMinutes = 5, TokenHours = 16, LifetimeHours = 8, BuildCapMinutes = 8, IdleMinutes = 120, GraceMinutes = 30, MaxRelaunches = 3, WaitingRepeatMinutes = 30;

    public static QcSettings Load(string scriptsDir, string publicUrl, bool ownerMode)
    {
        var s = new QcSettings();
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? root = null; try { root = JsonNode.Parse(File.ReadAllText(path)); } catch { }
        var q = root?["qc"]; var t = root?["timing"];
        double Timing(string k, double d) { var env = Environment.GetEnvironmentVariable("FACTORY_TIMING_" + k); if (double.TryParse(env, out var ev)) return ev; return t?[k] is JsonNode n && double.TryParse(n.ToString(), out var v) ? v : d; }
        int Int(string k, int d) => q?[k] is JsonNode n && int.TryParse(n.ToString(), out var v) ? v : d;
        if (root?["owner"]?.ToString() is { Length: > 0 } ow && root?["repo"]?.ToString() is { Length: > 0 } rp) s.RepoUrl = $"https://github.com/{ow}/{rp}";
        s.TrustProxy = q?["trustProxy"]?.GetValue<bool>() ?? false;
        s.AllowLoopback = q?["allowLoopbackForTests"]?.GetValue<bool>() ?? false;
        s.KnownProxies = q?["knownProxies"] is JsonArray kp ? kp.Select(x => x!.ToString()).ToArray() : Array.Empty<string>();
        s.RatePerIp = Int("rateLimitPerIp", 10); s.RatePerPr = Int("rateLimitPerPr", 20); s.ProbeTimeoutSeconds = Int("probeTimeoutSeconds", 5);
        s.MaxEnvironments = Int("maxEnvironments", 3); s.WaitingDelaySeconds = Int("waitingDelaySeconds", 300); s.MinFreeMb = Int("minFreeMb", 3500);
        s.LeaseMinutes = Timing("qcLeaseMinutes", 5); s.TokenHours = Timing("qcTokenHours", 16); s.BuildCapMinutes = Timing("qcBuildCapMinutes", 8);
        // the lifetime cap: timing.qcLifetimeMinutes, else timing.qcLifetimeHours, else 8 hours
        var lifeMin = Timing("qcLifetimeMinutes", double.NaN); s.LifetimeHours = double.IsNaN(lifeMin) ? Timing("qcLifetimeHours", 8) : lifeMin / 60;
        s.IdleMinutes = Timing("qcIdleMinutes", 120); s.GraceMinutes = Timing("qcGraceMinutes", 30); s.MaxRelaunches = Timing("qcMaxRelaunches", 3); s.WaitingRepeatMinutes = Timing("qcWaitingRepeatMinutes", 30);
        // test-only seam, honoured only together with allowLoopbackForTests: lengthens the gap between a sweep's read of the QC records and the gateway acting on it
        if (s.AllowLoopback) s.TestReconcileDelayMs = Int("testReconcileDelayMs", 0);
        if (ownerMode)
        {
            if (s.AllowLoopback && !(Uri.TryCreate(publicUrl, UriKind.Absolute, out var pu) && QcUrl.IsLoopbackHost(pu.Host)))
                throw new InvalidOperationException("qc.allowLoopbackForTests is for tests only and loads only when FACTORY_PUBLIC_URL is a loopback address");
            if (s.TokenHours <= s.BuildCapMinutes / 60 + s.LifetimeHours)
                throw new InvalidOperationException("timing.qcTokenHours must be above the build cap plus timing.qcLifetimeMinutes");
        }
        return s;
    }
}

// What the gateway knows about one pull request's environment and does not write to GitHub.
sealed class QcMem
{
    public int Pr, Item;
    public string Assignment = "", Url = "", From = "", Probe = "", LogTail = "", LocalHealth = "";
    public JsonObject? Rec;
    public DateTime? LeaseUntil, LastTouch, LastHeartbeat, StopDeadline;
    public double? MemFreeMb;
    public bool? AppAlive;
    public bool StopPending, Relaunching;
    public HashSet<string> Old = new();
    public string LastNotified = "";
}

static class QcUrl
{
    public static bool IsLoopbackHost(string host)
    {
        var h = host.Trim('[', ']').ToLowerInvariant();
        if (h is "localhost" or "0.0.0.0" or "::1" or "::" || h.EndsWith(".localhost")) return true;
        return IPAddress.TryParse(h, out var ip) && (IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any) || ip.Equals(IPAddress.IPv6Any));
    }

    static bool IsLinkLocalOrMetadata(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (ip.AddressFamily == AddressFamily.InterNetworkV6) return ip.IsIPv6LinkLocal;
        var b = ip.GetAddressBytes(); return b[0] == 169 && b[1] == 254;
    }

    // Test-only exception (qc.allowLoopbackForTests): the literal 127.0.0.1, and only when the worker declared exactly that address.
    static bool TestLoopbackOk(QcSettings cfg, string host, string declared) => cfg.AllowLoopback && host == "127.0.0.1" && declared.Equals("127.0.0.1", StringComparison.OrdinalIgnoreCase);

    // The URL rules of design 4.3 step 8, applied at report, at probe and at /go. Returns null when the URL passes.
    public static (string Code, string Reason)? Check(QcSettings cfg, string? url, string declared, out Uri? uri)
    {
        uri = null;
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url, UriKind.Absolute, out var u)) return ("url-host-not-allowed", "the URL is not an absolute http or https address");
        if (u.Scheme is not ("http" or "https")) return ("url-host-not-allowed", "only http and https URLs are allowed");
        if (!string.IsNullOrEmpty(u.UserInfo)) return ("url-host-not-allowed", "a URL with a user name or password is not allowed");
        var host = u.Host.Trim('[', ']');
        if (IsLoopbackHost(host) && !TestLoopbackOk(cfg, host, declared)) return ("loopback-url", $"{host} is a loopback address: nobody else can open it; report an address of this computer that other people can reach");
        if (IPAddress.TryParse(host, out var ip) && IsLinkLocalOrMetadata(ip)) return ("url-host-not-allowed", "link-local and metadata addresses are not allowed");
        if (string.IsNullOrEmpty(declared)) return ("url-host-not-allowed", "this worker declared no address at registration (--qc-address)");
        var ok = declared.StartsWith("*.") ? host.EndsWith(declared[1..], StringComparison.OrdinalIgnoreCase)
               : declared.StartsWith('.') ? host.EndsWith(declared, StringComparison.OrdinalIgnoreCase)
               : host.Equals(declared.Trim('[', ']'), StringComparison.OrdinalIgnoreCase);
        if (!ok) return ("url-host-not-allowed", $"the host {host} is not the address this worker declared at registration");
        uri = u; return null;
    }

    public enum ProbeKind { Verified, BadAnswer, CannotConnect, Blocked }

    // Best effort GET /_healthcheck. DNS is resolved once, every address is checked against the rules, the connection goes to that address (no rebinding),
    // and no redirect is followed.
    public static async Task<(ProbeKind Kind, int Status)> Probe(QcSettings cfg, Uri uri, string declared)
    {
        var host = uri.Host.Trim('[', ']');
        IPAddress[] addrs;
        try { addrs = IPAddress.TryParse(host, out var lit) ? new[] { lit } : await Dns.GetHostAddressesAsync(host); }
        catch { return (ProbeKind.CannotConnect, 0); }
        if (addrs.Length == 0) return (ProbeKind.CannotConnect, 0);
        foreach (var a in addrs)
        {
            var loop = IPAddress.IsLoopback(a) || a.Equals(IPAddress.Any) || a.Equals(IPAddress.IPv6Any);
            if ((loop && !(TestLoopbackOk(cfg, a.ToString(), declared) && host == "127.0.0.1")) || IsLinkLocalOrMetadata(a)) return (ProbeKind.Blocked, 0);
        }
        var pinned = addrs[0]; var timeout = TimeSpan.FromSeconds(Math.Max(1, cfg.ProbeTimeoutSeconds));
        using var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false, UseProxy = false, ConnectTimeout = timeout,
            ConnectCallback = async (ctx, ct) =>
            {
                var sock = new Socket(pinned.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try { await sock.ConnectAsync(new IPEndPoint(pinned, ctx.DnsEndPoint.Port), ct); return new NetworkStream(sock, true); }
                catch { sock.Dispose(); throw; }
            }
        };
        using var http = new HttpClient(handler) { Timeout = timeout };
        try
        {
            using var resp = await http.GetAsync(new Uri(uri.GetLeftPart(UriPartial.Authority) + "/_healthcheck"));
            var code = (int)resp.StatusCode;
            return (code == 200 ? ProbeKind.Verified : ProbeKind.BadAnswer, code);
        }
        catch { return (ProbeKind.CannotConnect, 0); }
    }
}

sealed class QcHub
{
    readonly Runner runner; readonly Plant plant; readonly EventHub events; readonly QcSettings cfg; readonly string publicUrl, secret;
    readonly ConcurrentDictionary<int, QcMem> mems = new();
    readonly ConcurrentDictionary<string, (int Pr, DateTime Exp)> nonces = new();
    readonly object rateGate = new();
    readonly Dictionary<string, List<DateTime>> ipHits = new(), prHits = new();
    public static readonly HashSet<string> Handled = new() { "qc-request", "qc-reset", "qc-teardown", "qc-report", "qc-heartbeat", "qc-reassign", "qc-touch" };

    public QcHub(Runner runner, Plant plant, EventHub events, QcSettings cfg, string publicUrl, string secret)
    {
        this.runner = runner; this.plant = plant; this.events = events; this.cfg = cfg; this.publicUrl = publicUrl; this.secret = secret;
        plant.OnQcPlaced = Persist;
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------------------------
    static int Int(JsonNode? n, int d = 0) => int.TryParse(n?.ToString(), out var v) ? v : d;
    static string Str(JsonNode? n) => n?.ToString() ?? "";
    static JsonObject? RecOf(JsonObject o) => o["record"] as JsonObject;
    static string StateOf(JsonObject? rec) => Str(rec?["state"]);
    public QcMem Mem(int pr) => mems.GetOrAdd(pr, p => new QcMem { Pr = p });
    QcMem? FindByAssignment(string assignment) => mems.Values.FirstOrDefault(m => m.Assignment == assignment && assignment != "");

    static string ErrJson(string code, string reason, int exit, JsonObject? extra = null)
    {
        var o = new JsonObject { ["ok"] = false, ["code"] = code, ["reason"] = reason, ["exit"] = exit };
        if (extra != null) foreach (var kv in extra) o[kv.Key] = kv.Value?.DeepClone();
        return o.ToJsonString();
    }
    static int HttpFor(int exit) => exit switch { 0 => 200, 21 => 202, 2 => 400, 12 => 404, 10 or 11 or 40 => 409, 20 => 503, _ => 500 };

    async Task<(int Exit, JsonObject Out)> Ps(string verb, JsonObject body, int seconds = 120)
    {
        var (code, output) = await runner.RunAsync(verb, body.ToJsonString(), TimeSpan.FromSeconds(seconds));
        JsonObject o; try { o = JsonNode.Parse(output) as JsonObject ?? new JsonObject(); } catch { o = new JsonObject { ["ok"] = false, ["code"] = "no-output", ["reason"] = "the rule script produced no output", ["exit"] = code == 0 ? 20 : code }; }
        return (code, o);
    }

    // The mirror of the persisted record, kept so /status and heartbeats cost no GitHub call. A newer revision, or a different attempt, replaces it.
    void Mirror(QcMem m, JsonObject? rec)
    {
        if (rec == null) return;
        lock (m)
        {
            var same = m.Rec != null && Str(m.Rec["sha"]) == Str(rec["sha"]) && Int(m.Rec["attempt"]) == Int(rec["attempt"]);
            // an older record (a sweep's snapshot read before a reset or a new Start) never replaces a newer one
            if (m.Rec != null && !same && string.CompareOrdinal(Str(rec["requested_at"]), Str(m.Rec["requested_at"])) < 0) return;
            if (!same || m.Rec == null || Int(rec["rev"]) >= Int(m.Rec["rev"])) m.Rec = (JsonObject)rec.DeepClone();
            m.Item = Int(rec["item"], m.Item);
            var asg = Str(m.Rec["assignment"]);
            if (m.Assignment != "" && asg != m.Assignment) m.Old.Add(m.Assignment);
            m.Assignment = asg;
            if (m.Rec["old_assignments"] is JsonArray old) foreach (var x in old) m.Old.Add(Str(x));
        }
    }

    void Notify(QcMem m, string evt, string reason = "")
    {
        if (m.Rec == null) return;
        var o = new JsonObject { ["provider"] = "gateway", ["event"] = evt, ["item"] = m.Item, ["pr"] = m.Pr, ["sha"] = Str(m.Rec["sha"]), ["state"] = StateOf(m.Rec), ["reason"] = reason };
        try { plant.Route(m.Item, (JsonObject)JsonNode.Parse(o.ToJsonString())!); events.Publish(o.ToJsonString()); } catch { }
    }

    void ClearRuntime(QcMem m) { lock (m) { m.Url = ""; m.Probe = ""; m.LeaseUntil = null; m.LastTouch = null; m.AppAlive = null; m.LocalHealth = ""; m.StopPending = false; m.StopDeadline = null; } }

    // ---- placing a job and persisting it -----------------------------------------------------------------------------------------------------
    async Task<(bool Placed, string Why)> PlaceAndPersist(QcMem m, JsonObject rec, string mode, string only = "")
    {
        var (a, why) = plant.PlaceQc(Int(rec["item"]), Int(rec["pr"]), Str(rec["sha"]), Str(rec["env_id"]), Int(rec["attempt"]), mode, only: only);
        if (a.Worker == "") return (false, why);
        await Persist(a);
        return (true, "");
    }

    // Writes the worker and assignment into the record (a state transition: requested/reset to assigned).
    async Task Persist(Assignment a)
    {
        var m = Mem(a.Pr);
        var (code, o) = await Ps("qc-transition", new JsonObject { ["item"] = a.Item, ["pr"] = a.Pr, ["to"] = "assigned", ["worker"] = a.Worker, ["assignment"] = a.Id, ["mode"] = a.Mode, ["sha"] = a.Sha });
        if (code == 0) { Mirror(m, RecOf(o)); lock (m) { m.Item = a.Item; } }
        else
        {
            // The record would not take this assignment (it moved on: torn down, failed, reset, or GitHub did not answer). A job that stays in the plant for a
            // record that does not hold it keeps a worker's QC capacity for nothing; a record still waiting is placed again by the next sweep.
            plant.DropQcIf(a.Pr, a.Id);
            Console.Error.WriteLine($"qc persist #{a.Item} PR {a.Pr}: {Str(o["code"])} {Str(o["reason"])}");
        }
    }

    // ---- Start, Reset, Teardown (page and operator) ------------------------------------------------------------------------------------------------
    public async Task<(int Exit, JsonObject Out)> DoRequest(JsonObject body, string from, bool op)
    {
        InvalidateList();
        body["operator"] = op; if (!op) body.Remove("confirm");
        var (code, o) = await Ps("qc-request", body);
        if (code != 0) return (code, o);
        var rec = RecOf(o); var m = Mem(Int(o["pr"]));
        if (Str(o["outcome"]) == "existing") { Mirror(m, rec); o["code"] = "existing"; o["state"] = StateOf(rec); return (0, o); }
        ClearRuntime(m); lock (m) { m.From = from; m.Old.Clear(); m.Rec = null; m.Assignment = ""; m.LogTail = ""; }
        if (o["previous"] is JsonObject prev) StopOld(prev, Str(o["pr"]), "qc.teardown");
        Mirror(m, rec); Notify(m, "qc.requested");
        var (placed, why) = await PlaceAndPersist(m, rec!, "first");
        o["state"] = StateOf(m.Rec);
        if (!placed) { o["code"] = "waiting-for-worker"; o["reason"] = why; return (21, o); }
        o["code"] = "started"; return (0, o);
    }

    // Tells the worker that ran an earlier environment of this PR to stop it.
    void StopOld(JsonObject prev, string pr, string evt)
    {
        var worker = Str(prev["worker"]); if (worker == "" || !(prev["accepted"]?.GetValue<bool>() ?? true)) return;
        plant.SendTo(worker, new JsonObject { ["provider"] = "gateway", ["event"] = evt, ["pr"] = Int(pr), ["env_id"] = Str(prev["env_id"]), ["assignment"] = Str(prev["assignment"]), ["sha"] = Str(prev["sha"]) });
    }

    public async Task<(int Exit, JsonObject Out)> DoReset(JsonObject body, string from, string only = "")
    {
        InvalidateList();
        var (code, o) = await Ps("qc-reset", body);
        if (code != 0) return (code, o);
        var rec = RecOf(o)!; var m = Mem(Int(o["pr"]));
        if (o["previous"] is JsonObject prev) StopOld(prev, Str(o["pr"]), "qc.reset");
        ClearRuntime(m); lock (m) { m.From = from; m.Rec = null; m.Assignment = ""; m.LogTail = ""; }
        Mirror(m, rec); Notify(m, "qc.requested", "reset");
        var (placed, why) = await PlaceAndPersist(m, rec, "reset", only);
        o["state"] = StateOf(m.Rec);
        if (!placed) { o["code"] = "waiting-for-worker"; o["reason"] = why; return (21, o); }
        o["code"] = "reset"; return (0, o);
    }

    public async Task<(int Exit, JsonObject Out)> DoTeardown(JsonObject body)
    {
        InvalidateList();
        var (code, o) = await Ps("qc-teardown", body);
        if (code != 0) return (code, o);
        var pr = Int(o["pr"]); var m = Mem(pr);
        if (Str(o["outcome"]) == "already") { plant.DropQc(pr); ClearRuntime(m); o["code"] = "already"; return (0, o); }
        var rec = RecOf(o); Mirror(m, rec);
        if (!(o["needs_stop"]?.GetValue<bool>() ?? false))
        {
            plant.DropQc(pr); ClearRuntime(m); Notify(m, "qc.torn_down", Str(rec?["teardown"]?["reason"])); o["code"] = "torn-down"; return (0, o);
        }
        var env = (JsonObject)o["env"]!; var worker = Str(env["worker"]);
        lock (m) { m.StopPending = true; m.StopDeadline = m.LeaseUntil ?? DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); }
        if (worker != "" && plant.IsConnected(worker))
        {
            plant.SendTo(worker, new JsonObject { ["provider"] = "gateway", ["event"] = "qc.teardown", ["pr"] = pr, ["env_id"] = Str(env["env_id"]), ["assignment"] = Str(env["assignment"]), ["sha"] = Str(env["sha"]), ["item"] = m.Item });
            o["code"] = "torn-down"; return (0, o);
        }
        o["code"] = "waiting-for-worker-stop"; o["reason"] = "the worker is not connected; the environment is recorded as torn down when its lease runs out"; return (21, o);
    }

    // Operator action: rebuild the environment on a worker the operator picked. A reset whose placement is limited to that worker; the old worker is told to
    // stop at once (the old assignment is then stale), not after the new one is ready, because a PR has one record and one assignment at a time.
    public async Task<(int Exit, JsonObject Out)> DoReassign(JsonObject body)
    {
        var worker = Str(body["worker"]); var pr = Int(body["pr"]);
        if (worker == "") return (2, new JsonObject { ["ok"] = false, ["code"] = "usage", ["reason"] = "worker is required" });
        var chk = plant.QcReassignCheck(worker, pr);
        if (chk.Exit != 0) return (chk.Exit, new JsonObject { ["ok"] = false, ["code"] = chk.Code, ["reason"] = chk.Reason });
        body.Remove("worker");
        var (code, o) = await DoReset(body, "operator", worker);
        if (code is 0 or 21) { o["worker"] = worker; if (code == 0) o["code"] = "reassigned"; }
        return (code, o);
    }

    // Someone opened the environment: the idle timer restarts and the lease is kept at least a full lease ahead. Memory only, no GitHub call.
    public (int Exit, JsonObject Out) Touch(int pr)
    {
        if (!mems.TryGetValue(pr, out var m) || m.Rec == null || StateOf(m.Rec) == "torn-down") return (12, new JsonObject { ["ok"] = false, ["code"] = "no-environment", ["reason"] = "no QC environment is running for this pull request" });
        lock (m)
        {
            var now = DateTime.UtcNow; m.LastTouch = now;
            if (m.LeaseUntil != null) { var want = now.AddMinutes(cfg.LeaseMinutes); if (m.LeaseUntil < want) m.LeaseUntil = want; }
            return (0, new JsonObject { ["ok"] = true, ["code"] = "touched", ["pr"] = pr, ["last_touch"] = now.ToString("o"), ["lease_until"] = m.LeaseUntil?.ToString("o") });
        }
    }

    // ---- the dashboard list --------------------------------------------------------------------------------------------------------------------------
    // qc-list reads GitHub, so its answer is kept for a few seconds (the dashboard polls every 4 s) and dropped by every action.
    JsonObject? listCache; DateTime listAt; readonly SemaphoreSlim listGate = new(1, 1);
    void InvalidateList() { listCache = null; }

    async Task<(int Exit, JsonObject Out)> RawList()
    {
        await listGate.WaitAsync();
        try
        {
            if (listCache != null && (DateTime.UtcNow - listAt).TotalSeconds < 5) return (0, listCache);
            var (code, o) = await Ps("qc-list", new JsonObject { ["include"] = "all" });
            if (code == 0) { listCache = o; listAt = DateTime.UtcNow; }
            return (code, o);
        }
        finally { listGate.Release(); }
    }

    static double? AgeSeconds(string iso) => DateTime.TryParse(iso, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var at) ? Math.Max(0, (DateTime.UtcNow - at).TotalSeconds) : null;

    JsonObject Row(int pr, JsonObject rec, string title, string head)
    {
        QcMem? m = mems.TryGetValue(pr, out var mm) ? mm : null;
        var state = StateOf(rec); var sha = Str(rec["sha"]);
        var row = new JsonObject
        {
            ["pr"] = pr, ["item"] = Int(rec["item"]), ["title"] = title, ["sha"] = sha, ["head"] = head, ["stale"] = state == "stale" || (head != "" && head != sha),
            ["author"] = Str(rec["author"]), ["state"] = state, ["attempt"] = Int(rec["attempt"]), ["worker"] = Str(rec["worker"]), ["assignment"] = Str(rec["assignment"])
        };
        if (AgeSeconds(Str(rec["requested_at"])) is double age) row["age_seconds"] = (int)age;
        if (rec["fail"] is JsonObject f) row["fail"] = f.DeepClone();
        if (m != null)
        {
            lock (m)
            {
                if (state == "ready" && m.Url != "")
                {
                    var bad = QcUrl.Check(cfg, m.Url, plant.DeclaredAddress(Str(rec["worker"])), out _);
                    if (bad == null) row["url"] = m.Url; else row["url_note"] = bad.Value.Reason;
                    row["probe"] = m.Probe;
                }
                else if (state == "ready") row["url_note"] = "ready, address being re-reported";
                if (m.LastTouch != null) row["last_touch"] = m.LastTouch.Value.ToString("o");
            }
        }
        if (state is "requested" or "reset" && plant.QcAssignment(pr) is { Worker: "" }) row["waiting"] = "no connected worker has a QC profile with the .NET SDK, or all are busy";
        row["reassign_to"] = new JsonArray(plant.QcReassignable(pr).Select(x => (JsonNode)x).ToArray());
        return row;
    }

    /// <summary>Rows of the dashboard's "Waiting for PR QC" table, oldest first: every PR with a PASS verdict and no environment (state available) and every record not yet torn down.</summary>
    public async Task<(int Exit, JsonObject Out)> ListRows()
    {
        var (code, o) = await RawList();
        if (code != 0) return (code, o);
        var rows = new List<JsonObject>(); var seen = new HashSet<int>();
        foreach (var n in o["records"] as JsonArray ?? new JsonArray())
        {
            if (n is not JsonObject r) continue;
            var pr = Int(r["pr"]); if (pr == 0 || !seen.Add(pr)) continue;
            JsonObject rec = r;
            if (mems.TryGetValue(pr, out var m) && m.Rec != null) lock (m) { rec = (JsonObject)m.Rec.DeepClone(); }
            if (StateOf(rec) == "torn-down") { seen.Remove(pr); continue; }
            rows.Add(Row(pr, rec, Str(r["title"]), Str(r["head_sha"])));
        }
        foreach (var n in o["available"] as JsonArray ?? new JsonArray())
        {
            if (n is not JsonObject a) continue;
            var pr = Int(a["pr"]); if (pr == 0 || seen.Contains(pr)) continue;
            JsonObject? live = null;
            if (mems.TryGetValue(pr, out var m) && m.Rec != null) lock (m) { live = (JsonObject)m.Rec.DeepClone(); }
            if (live != null && StateOf(live) != "torn-down") { rows.Add(Row(pr, live, Str(a["title"]), Str(a["sha"]))); continue; }
            var row = new JsonObject { ["pr"] = pr, ["item"] = Int(a["item"]), ["title"] = Str(a["title"]), ["sha"] = Str(a["sha"]), ["head"] = Str(a["sha"]), ["stale"] = false, ["author"] = Str(a["author"]), ["state"] = "available", ["worker"] = "", ["attempt"] = 0, ["assignment"] = "" };
            if (AgeSeconds(Str(a["created_at"])) is double age) row["age_seconds"] = (int)age;
            rows.Add(row);
        }
        rows = rows.OrderByDescending(x => x["age_seconds"] is JsonNode an ? an.GetValue<int>() : -1).ThenBy(x => x["pr"]!.GetValue<int>()).ToList();
        return (0, new JsonObject { ["ok"] = true, ["repo_url"] = cfg.RepoUrl, ["rows"] = new JsonArray(rows.Select(x => (JsonNode)x).ToArray()), ["at"] = DateTime.UtcNow.ToString("o") });
    }

    async Task<int> ResolveItem(int pr, JsonObject body)
    {
        var it = Int(body["item"]); if (it != 0) return it;
        if (mems.TryGetValue(pr, out var m) && m.Item != 0) return m.Item;
        var (code, o) = await RawList(); if (code != 0) return 0;
        foreach (var key in new[] { "records", "available" })
            foreach (var n in o[key] as JsonArray ?? new JsonArray()) if (n is JsonObject r && Int(r["pr"]) == pr) return Int(r["item"]);
        return 0;
    }

    static async Task WriteJson(HttpContext c, int status, JsonObject o) { c.Response.StatusCode = status; c.Response.Headers["Cache-Control"] = "no-store"; c.Response.ContentType = "application/json"; await c.Response.WriteAsync(o.ToJsonString()); }
    static bool IsAdmin(HttpContext c) => c.Items["principal"] is Principal { Kind: "admin" };

    async Task ApiList(HttpContext c)
    {
        if (!IsAdmin(c)) { await WriteJson(c, 403, JsonNode.Parse(ErrJson("forbidden", "the QC list is for the operator", 30))!.AsObject()); return; }
        var (code, o) = await ListRows();
        if (code != 0) { o["ok"] = false; o["exit"] = code; }
        await WriteJson(c, code == 0 ? 200 : HttpFor(code), o);
    }

    async Task ApiAct(HttpContext c, string prText, string action)
    {
        if (!IsAdmin(c)) { await WriteJson(c, 403, JsonNode.Parse(ErrJson("forbidden", "QC actions from the dashboard need the operator token", 30))!.AsObject()); return; }
        if (action is not ("start" or "reset" or "teardown" or "reassign" or "touch")) { c.Response.StatusCode = 404; return; }
        if (!int.TryParse(prText, out var pr)) { await WriteJson(c, 404, JsonNode.Parse(ErrJson("no-such-pr", "no such pull request", 12))!.AsObject()); return; }
        string text; using (var rd = new StreamReader(c.Request.Body)) text = await rd.ReadToEndAsync();
        JsonObject body; try { body = string.IsNullOrWhiteSpace(text) ? new JsonObject() : (JsonNode.Parse(text) as JsonObject ?? new JsonObject()); } catch { await WriteJson(c, 400, JsonNode.Parse(ErrJson("bad-json", "the body is not JSON", 2))!.AsObject()); return; }
        var item = await ResolveItem(pr, body);
        if (item == 0) { await WriteJson(c, 404, JsonNode.Parse(ErrJson("no-such-pr", "no work item with a verdict for this pull request is known", 12))!.AsObject()); return; }
        body["item"] = item; body["pr"] = pr;
        (int Exit, JsonObject Out) r = action switch
        {
            "start" => await DoRequest(body, "operator", true),
            "reset" => await DoReset(body, "operator"),
            "teardown" => await DoTeardown(new JsonObject { ["item"] = item, ["pr"] = pr, ["reason"] = "person" }),
            "reassign" => await DoReassign(body),
            _ => Touch(pr)
        };
        InvalidateList();
        r.Out["exit"] = r.Exit; if (!r.Out.ContainsKey("ok")) r.Out["ok"] = r.Exit is 0 or 21;
        await WriteJson(c, StatusFor(r.Exit, Str(r.Out["code"])), r.Out);
    }

    public async Task Teardown(int pr, string reason)
    {
        var m = Mem(pr); var item = m.Item != 0 ? m.Item : Int(m.Rec?["item"]);
        if (item == 0) return;
        lock (m) { if (m.StopPending) return; }       // the worker was told already and has not confirmed yet
        await DoTeardown(new JsonObject { ["item"] = item, ["pr"] = pr, ["reason"] = reason });
    }

    // ---- verbs reached through /api/v1/verbs ----------------------------------------------------------------------------------------------------
    public async Task<(int Status, string Json)> HandleVerb(string verb, JsonObject body, Principal who)
    {
        (int Exit, JsonObject Out) r;
        switch (verb)
        {
            case "qc-request": if (who.Kind != "admin") return (403, ErrJson("forbidden", "only the operator may call this verb here", 30)); r = await DoRequest(body, "operator", true); break;
            case "qc-reset": if (who.Kind != "admin") return (403, ErrJson("forbidden", "only the operator may call this verb here", 30)); r = await DoReset(body, "operator"); break;
            case "qc-teardown": if (who.Kind != "admin") return (403, ErrJson("forbidden", "only the operator may call this verb here", 30)); r = await DoTeardown(body); break;
            case "qc-reassign": if (who.Kind != "admin") return (403, ErrJson("forbidden", "only the operator may call this verb here", 30)); { var it = await ResolveItem(Int(body["pr"]), body); if (it == 0) { r = (12, new JsonObject { ["ok"] = false, ["code"] = "no-environment", ["reason"] = "no work item is known for this pull request" }); break; } body["item"] = it; } r = await DoReassign(body); break;
            case "qc-touch": if (who.Kind != "admin") return (403, ErrJson("forbidden", "only the operator may call this verb here", 30)); r = Touch(Int(body["pr"])); break;
            case "qc-report": r = await Report(body, who); break;
            case "qc-heartbeat": r = await Heartbeat(body, who); break;
            default: return (404, ErrJson("unknown-verb", verb, 2));
        }
        r.Out["verb"] = verb; if (!r.Out.ContainsKey("ok")) r.Out["ok"] = r.Exit is 0 or 21; r.Out["exit"] = r.Exit;
        return (HttpFor(r.Exit), r.Out.ToJsonString());
    }

    // The mirror says who holds the environment: a token for any other assignment is stale (11) or not yours (40).
    (QcMem? Mem, (int Exit, JsonObject Out)? Refusal) ForCaller(Principal who)
    {
        var m = FindByAssignment(who.Assignment);
        if (m != null) return (m, null);
        if (mems.Values.Any(x => x.Old.Contains(who.Assignment))) return (null, (11, new JsonObject { ["ok"] = false, ["code"] = "stale-assignment", ["reason"] = "this assignment was replaced by a reset or a newer attempt; stop and remove what it built" }));
        return (null, (20, new JsonObject { ["ok"] = false, ["code"] = "recovering", ["reason"] = "the gateway has not rebuilt this environment yet; retry in a few seconds", ["retryAfterSeconds"] = 10 }));
    }

    static bool HealthOk(JsonNode? n) { var s = Str(n).ToLowerInvariant(); return s is "ok" or "true" or "yes" or "1"; }

    async Task<(int, JsonObject)> Report(JsonObject body, Principal who)
    {
        var (m, refusal) = ForCaller(who); if (m == null) return refusal!.Value;
        Arrived(who);
        var url = Str(body["url"]); var declared = plant.DeclaredAddress(who.Name);
        var bad = QcUrl.Check(cfg, url, declared, out var uri);
        if (bad != null) return (10, new JsonObject { ["ok"] = false, ["code"] = bad.Value.Code, ["reason"] = bad.Value.Reason });
        var (kind, status) = await QcUrl.Probe(cfg, uri!, declared);
        if (kind == QcUrl.ProbeKind.Blocked) return (10, new JsonObject { ["ok"] = false, ["code"] = "url-host-not-allowed", ["reason"] = "the address the host name resolves to is not allowed" });
        if (kind == QcUrl.ProbeKind.BadAnswer) return (20, new JsonObject { ["ok"] = false, ["code"] = "unreachable", ["reason"] = $"the gateway reached the address and /_healthcheck answered {status}", ["retryAfterSeconds"] = 10 });
        if (!HealthOk(body["local_health"])) return (20, new JsonObject { ["ok"] = false, ["code"] = "unreachable", ["reason"] = "the worker has not seen its own local health check succeed", ["retryAfterSeconds"] = 10 });
        var probe = kind == QcUrl.ProbeKind.Verified ? "verified" : "unverified";
        body["probe"] = probe;
        var (code, o) = await Ps("qc-report", body);
        if (code != 0) return (code, o);
        Mirror(m, RecOf(o));
        lock (m) { m.Url = url; m.Probe = probe; m.LeaseUntil = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); m.LastTouch ??= DateTime.UtcNow; m.LastHeartbeat = DateTime.UtcNow; }
        if (m.LastNotified != "ready") { m.LastNotified = "ready"; Notify(m, "qc.ready"); }
        o["probe"] = probe; return (0, o);
    }

    async Task<(int, JsonObject)> Heartbeat(JsonObject body, Principal who)
    {
        var (m, refusal) = ForCaller(who); if (m == null) return refusal!.Value;
        if (double.TryParse(Str(body["mem_free_mb"]), out var mb)) plant.SetMemFree(who.Name, mb);
        bool? alive = Str(body["app_alive"]) is var al && al != "" ? al.ToLowerInvariant() is "true" or "ok" or "1" : null;
        string state; bool stop, reReport;
        lock (m)
        {
            m.LeaseUntil = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); m.LastHeartbeat = DateTime.UtcNow; m.AppAlive = alive; m.LocalHealth = Str(body["local_health"]);
            state = StateOf(m.Rec); stop = m.Rec?["teardown"] != null && state != "torn-down" || state == "torn-down";
            reReport = state is "running" or "ready" && m.Url == "" && !stop;
        }
        if (alive == false && state is "running" or "ready")
        {
            var (code, o) = await Ps("qc-transition", new JsonObject { ["item"] = m.Item, ["pr"] = m.Pr, ["to"] = "failed", ["code"] = "app-down", ["reason"] = "the worker reported that the application is not running", ["sha"] = Str(m.Rec?["sha"]) });
            if (code == 0) { Mirror(m, RecOf(o)); lock (m) { m.Url = ""; } Notify(m, "qc.failed", "app-down"); state = "failed"; }
        }
        var action = stop ? "teardown" : reReport ? "re-report" : "continue";
        return (0, new JsonObject { ["ok"] = true, ["action"] = action, ["state"] = state, ["lease_until"] = m.LeaseUntil?.ToString("o") });
    }

    // A verb of the current QC assignment has arrived: the worker is alive, so its lease runs from now, not from when the (possibly slow) verb finishes.
    // Without this a verb that takes longer than what is left of the lease lets the sweep relaunch an environment whose worker is answering.
    public void Arrived(Principal who)
    {
        if (who.Kind != "item" || who.Role != "qc") return;
        var m = FindByAssignment(who.Assignment); if (m == null) return;
        lock (m) { if (m.LeaseUntil != null) { var want = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); if (m.LeaseUntil < want) m.LeaseUntil = want; } }
    }

    // After a rule-script verb succeeded: keep the memory half in step.
    public async Task AfterVerb(string verb, JsonObject body, Principal who, JsonObject output)
    {
        if (who.Kind != "item" || who.Role != "qc") return;
        var rec = RecOf(output); var pr = Int(output["pr"], Int(rec?["pr"]));
        if (pr == 0) { var f = FindByAssignment(who.Assignment); pr = f?.Pr ?? 0; }
        if (pr == 0) return;
        var m = Mem(pr);
        switch (verb)
        {
            case "accept":
                Mirror(m, rec); lock (m) { m.LeaseUntil = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); m.LastHeartbeat = DateTime.UtcNow; } break;
            case "qc-progress":
                Mirror(m, rec); lock (m) { m.LeaseUntil = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); if (Str(output["log_tail"]) != "") m.LogTail = Str(output["log_tail"]); } break;
            case "qc-fail":
                Mirror(m, rec); lock (m) { m.Url = ""; m.LogTail = Str(output["log_tail"]); } m.LastNotified = "failed"; Notify(m, "qc.failed", Str(rec?["fail"]?["code"])); break;
            case "qc-stopped":
                Mirror(m, rec);
                if (Str(output["outcome"]) == "torn-down") { plant.DropQc(pr); ClearRuntime(m); Notify(m, "qc.torn_down", Str(rec?["teardown"]?["reason"])); }
                break;
        }
        await Task.CompletedTask;
    }

    // ---- sweep: rebuild after a restart, tear down what the sweep found closed ---------------------------------------------------------------------------
    public async Task Reconcile(JsonNode? records, JsonNode? teardowns, JsonNode? approvals = null)
    {
        // the records are what the sweep read some time ago; anything that moved on since (qc-stopped, a reset, a teardown) is newer in the mirror
        if (cfg.TestReconcileDelayMs > 0 && records is JsonArray { Count: > 0 }) await Task.Delay(cfg.TestReconcileDelayMs);
        foreach (var n in records as JsonArray ?? new JsonArray())
        {
            if (n is not JsonObject rec) continue;
            var pr = Int(rec["pr"]); if (pr == 0) continue;
            var m = Mem(pr); var before = StateOf(m.Rec);
            Mirror(m, rec);
            var state = StateOf(rec);
            if (state == "stale" && before != "stale" && before != "") Notify(m, "qc.stale");
            if (plant.QcAssignment(pr) != null) continue;
            if (SnapshotIsStale(m, rec)) continue;
            var item = Int(rec["item"]); var sha = Str(rec["sha"]); var env = Str(rec["env_id"]); var attempt = Int(rec["attempt"]);
            if (state is "requested" or "reset") { await PlaceAndPersist(m, rec, state == "reset" ? "reset" : "first"); continue; }
            var worker = Str(rec["worker"]); var asg = Str(rec["assignment"]);
            if (worker == "" || asg == "") continue;
            var (placed, why) = plant.PlaceQc(item, pr, sha, env, attempt, Str(rec["mode"]) is { Length: > 0 } md ? md : "first", asg, worker, rec["accepted_at"] != null);
            if (placed.Worker == "") continue;      // refused: the job was torn down after the sweep read this record
            lock (m) { m.LeaseUntil = DateTime.UtcNow.AddMinutes(cfg.LeaseMinutes); m.LastTouch = DateTime.UtcNow; m.Item = item; }
        }
        foreach (var n in teardowns as JsonArray ?? new JsonArray())
            if (n is JsonObject t) await Teardown(Int(t["pr"]), Str(t["reason"]));
        foreach (var n in approvals as JsonArray ?? new JsonArray())
            if (n is JsonObject ap) NotifyApproved(Int(ap["item"]), Int(ap["pr"]), Str(ap["sha"]), Str(ap["by"]), ap["ran"]?.GetValue<bool>() ?? false);
    }

    // A snapshot from the sweep is stale when the mirror already holds a newer revision of the same attempt, or the mirrored record is over (torn down, failed).
    bool SnapshotIsStale(QcMem m, JsonObject snap)
    {
        lock (m)
        {
            if (m.Rec == null) return false;
            if (Str(m.Rec["sha"]) != Str(snap["sha"]) || Int(m.Rec["attempt"]) != Int(snap["attempt"])) return true;     // Mirror kept a newer record than the snapshot
            if (StateOf(m.Rec) is "torn-down" or "failed") return true;
            return Int(m.Rec["rev"]) > Int(snap["rev"]);
        }
    }

    // ---- human approval of the head (design 3.6): the owner is woken to retry merge ------------------------------------------------------------
    readonly HashSet<string> approvalsSent = new();

    /// <summary>A person's approval of the PR head. The owner gets qc.approved once per approval (and once more when the QC run completes after it), so it retries merge.</summary>
    void NotifyApproved(int item, int pr, string sha, string by, bool ran)
    {
        if (item == 0 || pr == 0) return;
        var key = $"{item}|{pr}|{sha}|{by}|{(ran ? "ran" : "norun")}";
        lock (approvalsSent) { if (!approvalsSent.Add(key)) return; if (approvalsSent.Count > 500) approvalsSent.Clear(); }
        var o = new JsonObject { ["provider"] = "gateway", ["event"] = "qc.approved", ["item"] = item, ["pr"] = pr, ["sha"] = sha, ["state"] = "approved", ["reason"] = ran ? "approved by " + by + "; the QC run is recorded" : "approved by " + by + "; no QC run is recorded for this head yet", ["by"] = by, ["ran"] = ran };
        try { plant.Route(item, (JsonObject)JsonNode.Parse(o.ToJsonString())!); events.Publish(o.ToJsonString()); } catch { }
    }

    void ForgetApprovals(int item, int pr) { lock (approvalsSent) { approvalsSent.RemoveWhere(k => k.StartsWith($"{item}|{pr}|")); } }

    /// <summary>A pull_request_review webhook event: ask the rule script what GitHub says now (a dismissal clears, an approval of the current head counts), then wake the owner.</summary>
    public async Task OnReview(JsonObject evt)
    {
        var item = Int(evt["item"]); var pr = Int(evt["pr"]); if (item == 0 || pr == 0) return;
        var (code, o) = await Ps("qc-approval", new JsonObject { ["item"] = item, ["pr"] = pr });
        if (code != 0) { Console.Error.WriteLine($"qc approval #{item} PR {pr}: {Str(o["code"])} {Str(o["reason"])}"); return; }
        if (o["approved"]?.GetValue<bool>() ?? false) NotifyApproved(item, pr, Str(o["sha"]), Str(o["by"]), o["ran"]?.GetValue<bool>() ?? false);
        else ForgetApprovals(item, pr);
    }

    public async Task Tick()
    {
        var now = DateTime.UtcNow;
        foreach (var kv in nonces.Where(k => k.Value.Exp < now).ToList()) nonces.TryRemove(kv.Key, out _);
        foreach (var m in mems.Values.Where(x => x.StopPending && x.StopDeadline < now).ToList())
        {
            lock (m) { m.StopPending = false; }
            var (code, o) = await Ps("qc-transition", new JsonObject { ["item"] = m.Item, ["pr"] = m.Pr, ["to"] = "torn-down", ["reason"] = Str(m.Rec?["teardown"]?["reason"]) is { Length: > 0 } r ? r : "person" });
            if (code == 0) { Mirror(m, RecOf(o)); plant.DropQc(m.Pr); ClearRuntime(m); Notify(m, "qc.torn_down"); }
        }
        // What only the gateway knows: nobody opened a ready environment for timing.qcIdleMinutes (idle teardown), or its worker stopped heartbeating for
        // timing.qcLeaseMinutes (lease loss: the environment goes back to assigned on another worker). Both only stop or move a person's earlier Start; nothing is started here.
        foreach (var m in mems.Values.ToList())
        {
            string state; DateTime? lease, touch; bool busy; DateTime? readyAt;
            lock (m)
            {
                state = StateOf(m.Rec); lease = m.LeaseUntil; touch = m.LastTouch; busy = m.StopPending || m.Relaunching || m.Rec?["teardown"] != null;
                readyAt = DateTime.TryParse(Str(m.Rec?["ready_at"]), null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var ra) ? ra : null;
            }
            if (busy || state is not ("assigned" or "building" or "running" or "ready")) continue;
            var asg = plant.QcAssignment(m.Pr);
            if (asg == null || !asg.Accepted) continue;                  // not accepted yet: the acknowledgement timer places it again
            if (state == "ready" && (touch ?? readyAt) is DateTime since && (now - since).TotalMinutes >= cfg.IdleMinutes) { await Teardown(m.Pr, "idle"); continue; }
            if (lease != null && lease < now) await Relaunch(m);
        }
    }

    async Task Relaunch(QcMem m)
    {
        lock (m) { if (m.Relaunching) return; m.Relaunching = true; }
        try
        {
            var asg = plant.QcAssignment(m.Pr); if (asg == null) return;
            var lost = asg.Worker; var item = m.Item;
            var (code, o) = await Ps("qc-transition", new JsonObject { ["item"] = item, ["pr"] = m.Pr, ["to"] = "assigned", ["relaunch"] = true, ["assignment_was"] = asg.Id, ["max_relaunches"] = cfg.MaxRelaunches });
            if (code != 0) { Console.Error.WriteLine($"qc relaunch #{item} PR {m.Pr}: {Str(o["code"])} {Str(o["reason"])}"); return; }
            var rec = RecOf(o)!;
            // the lost worker is told to stop whatever it still runs; if it never comes back, its own watcher stops it
            plant.SendTo(lost, new JsonObject { ["provider"] = "gateway", ["event"] = "qc.teardown", ["pr"] = m.Pr, ["env_id"] = asg.EnvId, ["assignment"] = asg.Id, ["sha"] = asg.Sha, ["item"] = item });
            if (Str(o["outcome"]) == "failed")
            {
                plant.DropQc(m.Pr); Mirror(m, rec); ClearRuntime(m); m.LastNotified = "failed"; Notify(m, "qc.failed", "no-worker"); return;
            }
            ClearRuntime(m); lock (m) { m.LogTail = ""; m.Url = ""; }
            Mirror(m, rec);
            var (a, _) = plant.RelaunchQc(item, m.Pr, Str(rec["sha"]), Str(rec["env_id"]), Int(rec["attempt"]), lost);
            if (a.Worker != "") await Persist(a);        // else it waits; the plant tick offers it as soon as another qualified worker is free
            Notify(m, "qc.requested", "relaunch");
        }
        finally { lock (m) { m.Relaunching = false; } }
    }

    // ---- the click pages ---------------------------------------------------------------------------------------------------------------------------------
    string ClientIp(HttpContext c)
    {
        var ip = c.Connection.RemoteIpAddress; if (ip == null) return "unknown";
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        return ip.ToString();
    }

    string Origin(HttpContext c) => publicUrl != "" && Uri.TryCreate(publicUrl, UriKind.Absolute, out var u) ? u.GetLeftPart(UriPartial.Authority) : $"{c.Request.Scheme}://{c.Request.Host}";

    string NewNonce(int pr)
    {
        var n = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        nonces[n] = (pr, DateTime.UtcNow.AddMinutes(cfg.NonceMinutes)); return n;
    }
    bool NonceOk(string? n, int pr) => !string.IsNullOrEmpty(n) && nonces.TryGetValue(n, out var e) && e.Pr == pr && e.Exp > DateTime.UtcNow;

    bool RateOk(string ip, int pr)
    {
        lock (rateGate)
        {
            var now = DateTime.UtcNow; var cut = now.AddHours(-1);
            if (!ipHits.TryGetValue(ip, out var a)) ipHits[ip] = a = new();
            if (!prHits.TryGetValue(pr.ToString(), out var b)) prHits[pr.ToString()] = b = new();
            a.RemoveAll(t => t < cut); b.RemoveAll(t => t < cut);
            if (a.Count >= cfg.RatePerIp || b.Count >= cfg.RatePerPr) return false;
            a.Add(now); b.Add(now); return true;
        }
    }

    static int StatusFor(int exit, string code) => code switch
    {
        "bad-link" or "bad-origin" or "bad-nonce" => 403, "link-expired" or "stale-head" => 410, "rate-limited" => 429, "no-such-pr" or "no-environment" => 404,
        "not-eligible" or "trust-confirm-needed" or "not-ready" or "url-host-not-allowed" => 409, "waiting-for-worker" or "waiting-for-worker-stop" => 202,
        "started" or "existing" or "reset" or "torn-down" or "already" or "viewed" => 200, "bad-content-type" => 415, _ => HttpFor(exit)
    };

    JsonObject StatusJson(int pr, string token)
    {
        if (!mems.TryGetValue(pr, out var m) || m.Rec == null) return new JsonObject { ["ok"] = true, ["state"] = "available", ["pr"] = pr };
        lock (m)
        {
            var state = StateOf(m.Rec);
            var o = new JsonObject { ["ok"] = true, ["pr"] = pr, ["state"] = state, ["sha"] = Str(m.Rec["sha"]), ["worker"] = Str(m.Rec["worker"]), ["attempt"] = Int(m.Rec["attempt"]), ["probe"] = m.Probe, ["log_tail"] = m.LogTail };
            if (DateTime.TryParse(Str(m.Rec["requested_at"]), null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var at)) o["elapsed_seconds"] = (int)(DateTime.UtcNow - at).TotalSeconds;
            if (m.Rec["fail"] is JsonObject f) o["fail"] = f.DeepClone();
            if (state == "ready" && m.Url != "") { o["url"] = m.Url; o["go"] = $"/qc/{pr}/go?t={Uri.EscapeDataString(token)}"; }
            else if (state == "ready") o["note"] = "ready, address being re-reported";
            if (state is "requested" or "reset" && plant.QcAssignment(pr) is { Worker: "" }) o["waiting"] = "no connected worker has a QC profile with the .NET SDK, or all are busy";
            return o;
        }
    }

    async Task Reply(HttpContext c, int status, string code, string reason, JsonObject? data = null, Func<string>? html = null)
    {
        c.Response.StatusCode = status; c.Response.Headers["X-Qc-Reason"] = code; c.Response.Headers["Cache-Control"] = "no-store";
        var wantJson = html == null || c.Request.Headers.Accept.ToString().Contains("application/json");
        if (wantJson)
        {
            var o = new JsonObject { ["ok"] = status < 400, ["code"] = code, ["reason"] = reason };
            if (data != null) foreach (var kv in data) o[kv.Key] = kv.Value?.DeepClone();
            c.Response.ContentType = "application/json"; await c.Response.WriteAsync(o.ToJsonString());
        }
        else { c.Response.ContentType = "text/html; charset=utf-8"; await c.Response.WriteAsync(html!()); }
    }

    (QcClaims? Claims, string? Error) Verify(HttpContext c, int pr)
    {
        var (claims, err) = Auth.VerifyQcToken(secret, c.Request.Query["t"].ToString());
        if (err != null) return (null, err);
        return claims!.Pr != pr ? (null, "bad-link") : (claims, null);
    }

    public void Map(WebApplication app)
    {
        app.MapGet("/qc/{pr}", async (string pr, HttpContext c) => await View(c, pr));
        app.MapGet("/qc/{pr}/status", async (string pr, HttpContext c) =>
        {
            if (!int.TryParse(pr, out var n)) { await Reply(c, 404, "no-such-pr", "no such pull request"); return; }
            var (claims, err) = Verify(c, n); if (err != null) { await Reply(c, StatusFor(0, err), err, "this link is not valid"); return; }
            c.Response.Headers["Cache-Control"] = "no-store"; c.Response.ContentType = "application/json"; await c.Response.WriteAsync(StatusJson(n, c.Request.Query["t"].ToString()).ToJsonString());
        });
        app.MapGet("/qc/{pr}/go", async (string pr, HttpContext c) =>
        {
            if (!int.TryParse(pr, out var n)) { await Reply(c, 404, "no-such-pr", "no such pull request"); return; }
            var (claims, err) = Verify(c, n); if (err != null) { await Reply(c, StatusFor(0, err), err, "this link is not valid"); return; }
            if (!mems.TryGetValue(n, out var m) || m.Url == "" || StateOf(m.Rec) != "ready") { await Reply(c, 409, "not-ready", "the environment is not ready"); return; }
            var bad = QcUrl.Check(cfg, m.Url, plant.DeclaredAddress(Str(m.Rec!["worker"])), out _);
            if (bad != null) { await Reply(c, 409, "url-host-not-allowed", bad.Value.Reason); return; }
            Touch(n);
            c.Response.StatusCode = 302; c.Response.Headers.Location = m.Url; c.Response.Headers["X-Qc-Reason"] = "go";
        });
        app.MapGet("/api/v1/qc", async (HttpContext c) => await ApiList(c));
        app.MapPost("/api/v1/qc/{pr}/{action}", async (string pr, string action, HttpContext c) => await ApiAct(c, pr, action));
        app.MapPost("/qc/{pr}/{action}", async (string pr, string action, HttpContext c) => await Post(c, pr, action));
    }

    async Task View(HttpContext c, string prText)
    {
        if (!int.TryParse(prText, out var pr)) { await Reply(c, 404, "no-such-pr", "no such pull request"); return; }
        var (claims, err) = Verify(c, pr);
        if (err != null) { await Reply(c, StatusFor(0, err), err, err == "link-expired" ? "this link has expired; ask for a new one in the pull request" : "this link is not valid", null, () => QcPage.Message(pr, err == "link-expired" ? "This link has expired" : "This link is not valid", "Ask for a current link in the pull request or on the work item.")); return; }
        var token = c.Request.Query["t"].ToString();
        var (code, o) = await Ps("qc-view", new JsonObject { ["item"] = claims!.Item, ["pr"] = pr, ["sha"] = claims.Sha });
        if (code == 11)
        {
            var next = Str(o["current_token"]);
            await Reply(c, 410, "stale-head", "this link is for an older commit", o, () => QcPage.Stale(pr, o, next)); return;
        }
        if (code != 0) { var rc = Str(o["code"]); await Reply(c, StatusFor(code, rc), rc, Str(o["reason"]), null, () => QcPage.Message(pr, "Not available", Str(o["reason"]))); return; }
        var nonce = NewNonce(pr);
        var status = StatusJson(pr, token);
        if (status["state"]?.ToString() == "available" && o["record"] is JsonObject rr) { status["state"] = StateOf(rr); status["worker"] = Str(rr["worker"]); }
        o["page_nonce"] = nonce; o["status"] = status;
        await Reply(c, 200, "viewed", "", o, () => QcPage.Render(pr, token, nonce, o, status));
    }

    async Task Post(HttpContext c, string prText, string action)
    {
        if (action is not ("start" or "reset" or "teardown")) { c.Response.StatusCode = 404; return; }
        if (!int.TryParse(prText, out var pr)) { await Reply(c, 404, "no-such-pr", "no such pull request"); return; }
        var (claims, err) = Verify(c, pr);
        if (err != null) { await Reply(c, StatusFor(0, err), err, err == "link-expired" ? "this link has expired" : "this link is not valid"); return; }
        var origin = c.Request.Headers.Origin.ToString();
        if (!origin.Equals(Origin(c), StringComparison.OrdinalIgnoreCase)) { await Reply(c, 403, "bad-origin", "the request did not come from this site"); return; }
        if (!(c.Request.ContentType ?? "").StartsWith("application/x-www-form-urlencoded", StringComparison.OrdinalIgnoreCase)) { await Reply(c, 415, "bad-content-type", "expected a form post"); return; }
        var form = await c.Request.ReadFormAsync();
        if (!NonceOk(form["nonce"].ToString(), pr)) { await Reply(c, 403, "bad-nonce", "the page is out of date; reload it and press the button again"); return; }
        var ip = ClientIp(c);
        if (!RateOk(ip, pr)) { c.Response.Headers["Retry-After"] = "3600"; await Reply(c, 429, "rate-limited", "too many requests from this address or for this pull request; try again later"); return; }
        var body = new JsonObject { ["item"] = claims!.Item, ["pr"] = pr, ["sha"] = claims.Sha, ["from"] = ip, ["link_nonce"] = claims.Nonce };
        var principal = new Principal("qc-click", "", claims.Item, "", "", 0, pr, claims.Sha, ip);
        var verb = action == "start" ? "qc-request" : action == "reset" ? "qc-reset" : "qc-teardown";
        var (authorized, refusal) = Auth.AuthorizeVerb(principal, verb, body);
        if (authorized == null) { await Reply(c, 403, "forbidden", refusal ?? "refused"); return; }
        (int Exit, JsonObject Out) r = action switch { "start" => await DoRequest(authorized, ip, false), "reset" => await DoReset(authorized, ip), _ => await DoTeardown(authorized) };
        var rc = r.Exit == 0 || r.Exit == 21 ? Str(r.Out["code"]) : Str(r.Out["code"]);
        var st = StatusFor(r.Exit, rc);
        var token = c.Request.Query["t"].ToString();
        var status = StatusJson(pr, token); var nonce = NewNonce(pr);
        r.Out["status"] = status;
        await Reply(c, st, rc, Str(r.Out["reason"]), r.Out, () => QcPage.Render(pr, token, nonce, r.Out, status, banner: $"{rc}: {Str(r.Out["reason"])}".TrimEnd(' ', ':')));
    }
}

static class QcPage
{
    static string E(string? s) => WebUtility.HtmlEncode(s ?? "");
    static string Css => """
<style>:root{--bg:#fff;--fg:#1b1f24;--mut:#59636e;--line:#d1d9e0;--card:#f6f8fa;--ok:#1a7f37;--bad:#cf222e}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#9198a1;--line:#30363d;--card:#161b22;--ok:#3fb950;--bad:#f85149}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}main{max-width:720px;margin:0 auto;padding:16px}
h1{font-size:20px;margin:0 0 4px}.mut{color:var(--mut)}.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:12px 0}
button,.btn{font:inherit;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:6px 12px;cursor:pointer;text-decoration:none;display:inline-block}
pre{white-space:pre-wrap;word-break:break-word;font:12px/1.4 ui-monospace,monospace;max-height:240px;overflow:auto}form{display:inline-block;margin:4px 4px 4px 0}</style>
""";

    static string Shell(int pr, string title, string inner, string script = "") =>
        $"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>QC environment for PR #{pr}</title>{Css}</head><body><main><h1>{E(title)}</h1>{inner}</main>{script}</body></html>";

    public static string Message(int pr, string title, string text) => Shell(pr, title, $"<p>{E(text)}</p>");

    public static string Stale(int pr, JsonObject o, string nextToken)
    {
        var link = nextToken != "" ? $"<p><a class=\"btn\" href=\"/qc/{pr}?t={Uri.EscapeDataString(nextToken)}\">Get the current link</a></p>" : "";
        return Shell(pr, "This link is for an older commit", $"<p>PR #{pr} has new commits since this link was made. Nothing was queued.</p>{link}");
    }

    public static string Render(int pr, string token, string nonce, JsonObject o, JsonObject status, string banner = "")
    {
        string S(JsonNode? n) => n?.ToString() ?? "";
        var state = S(status["state"]); var rec = o["record"] as JsonObject;
        var worker = S(status["worker"]); var who = worker != "" ? $"{E(worker)}'s computer" : "the computer of the worker chosen at Start";
        var sb = new StringBuilder();
        sb.Append($"<p class=\"mut\">{E(S(o["title"]))} &middot; by {E(S(o["author"]))} &middot; head <code>{E(S(o["head_sha"]).Length >= 7 ? S(o["head_sha"])[..7] : S(o["head_sha"]))}</code></p>");
        if (banner != "") sb.Append($"<div class=\"card\" id=\"banner\">{E(banner)}</div>");
        sb.Append($"<div class=\"card\"><div>State: <b id=\"state\">{E(state)}</b> <span id=\"worker\" class=\"mut\">{(worker != "" ? "on " + E(worker) : "")}</span></div><div id=\"detail\" class=\"mut\"></div>");
        if (state == "ready" && S(status["url"]) != "")
            sb.Append($"<p><a id=\"open\" class=\"btn\" href=\"{E(S(status["go"]))}\">Open the environment</a> <code id=\"url\">{E(S(status["url"]))}</code></p>{(S(status["probe"]) == "unverified" ? "<p class=\"mut\">The gateway could not check this address; the worker reports it healthy.</p>" : "")}");
        if (state == "ready") sb.Append($"<p class=\"mut\">Reachable only from networks that can reach {who}.</p>");
        if (rec?["fail"] is JsonObject f) sb.Append($"<p>Failed: <b>{E(S(f["code"]))}</b> {E(S(f["reason"]))}</p>");
        sb.Append($"<pre id=\"log\">{E(S(status["log_tail"]))}</pre></div>");
        var live = state is "requested" or "reset" or "assigned" or "building" or "running" or "ready" or "stale";
        string Form(string act, string label) => $"<form method=\"post\" action=\"/qc/{pr}/{act}?t={Uri.EscapeDataString(token)}\"><input type=\"hidden\" name=\"nonce\" value=\"{E(nonce)}\"><button>{label}</button></form>";
        if (!live || state is "failed" or "torn-down" or "available")
        {
            var eligible = o["eligible"]?.GetValue<bool>() ?? true;
            if (eligible)
            {
                sb.Append($"<div class=\"card\"><p>Press Start to run this branch on {who}. Nothing runs until then. The environment is reachable only from networks that can reach that computer.</p>{Form("start", "Start QC environment")}");
                if (o["needs_confirmation"] is JsonArray nc && nc.Count > 0) sb.Append($"<p class=\"mut\">Needs operator confirmation first: {E(string.Join(", ", nc.Select(x => x!.ToString())))}</p>");
                sb.Append("</div>");
            }
            else sb.Append($"<div class=\"card\"><p>This pull request is not eligible for a QC environment: {E(string.Join(", ", (o["reasons"] as JsonArray ?? new JsonArray()).Select(x => x!.ToString())))}.</p></div>");
        }
        if (live || state == "failed") sb.Append(Form("reset", "Reset (rebuild at the current head)"));
        if (live) sb.Append(Form("teardown", "Tear down"));
        sb.Append("<p class=\"mut\">Approve the pull request on GitHub after testing. Only a GitHub review by a listed approver counts toward merge.</p>");
        var script = $"<script>const t={JsonSerializer.Serialize(token)},first={JsonSerializer.Serialize(state)};setInterval(async()=>{{try{{const r=await fetch('/qc/{pr}/status?t='+encodeURIComponent(t));const j=await r.json();document.getElementById('state').textContent=j.state;if(j.log_tail!==undefined)document.getElementById('log').textContent=j.log_tail;if(j.state!==first)location.reload()}}catch(e){{}}}},3000)</script>";
        return Shell(pr, $"QC environment for PR #{pr}", sb.ToString(), script);
    }
}
