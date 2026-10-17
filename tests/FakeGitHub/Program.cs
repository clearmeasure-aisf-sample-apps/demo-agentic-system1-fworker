using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

// A fake GitHub (REST + GraphQL, only what the factory-worker rule scripts call) and a fake Octopus, in memory, for Tier 1 tests.
// Test control lives under /_fake/*: create items, push branches, set CI profiles, inject faults, read the whole state.
// Octopus lives under /octopus/*. No secret is checked: any token is accepted.

var port = int.TryParse(Environment.GetEnvironmentVariable("FAKE_PORT"), out var p0) ? p0 : 5200;
var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls($"http://127.0.0.1:{port}");
builder.Logging.SetMinimumLevel(LogLevel.Warning);
var app = builder.Build();
var world = new World();
var gate = new object();
// FAKE_PROXY_PORT: a TCP forwarder in front of a gateway, as the platform's ingress is (the leader scenarios, issue 94). A connection goes to the
// backend that /_fake/proxy { port } named when it was opened and stays there (as a stream stays on the old revision); 0 refuses connections.
if (int.TryParse(Environment.GetEnvironmentVariable("FAKE_PROXY_PORT"), out var proxyPort) && proxyPort > 0)
{
    var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, proxyPort); listener.Start();
    _ = Task.Run(async () =>
    {
        while (true)
        {
            System.Net.Sockets.TcpClient inbound; try { inbound = await listener.AcceptTcpClientAsync(); } catch { return; }
            int backend; lock (gate) backend = world.ProxyBackend;
            _ = Task.Run(async () =>
            {
                using var a = inbound; if (backend <= 0) return;
                using var b = new System.Net.Sockets.TcpClient();
                try { await b.ConnectAsync(System.Net.IPAddress.Loopback, backend); } catch { return; }
                var sa = a.GetStream(); var sb = b.GetStream();
                await Task.WhenAny(sa.CopyToAsync(sb), sb.CopyToAsync(sa));
            });
        }
    });
}

app.Run(async ctx =>
{
    var method = ctx.Request.Method; var path = ctx.Request.Path.Value ?? "/"; var query = ctx.Request.Query;
    // the uploads host of GitHub (a release asset): the body is binary, only its length is kept
    if (path.StartsWith("/_uploads/") && method == "POST")
    {
        int uw; lock (gate) { uw = world.LatencyFor(method, path, ""); } if (uw > 0) await Task.Delay(uw);
        long len = 0; var buf = new byte[65536]; int k; while ((k = await ctx.Request.Body.ReadAsync(buf)) > 0) len += k;
        (int, string) up; lock (gate) { up = world.UploadAsset(path, query["name"].ToString(), ctx.Request.ContentType ?? "", len, port); }
        ctx.Response.StatusCode = up.Item1; ctx.Response.ContentType = "application/json"; await ctx.Response.WriteAsync(up.Item2); return;
    }
    string body; using (var rd = new StreamReader(ctx.Request.Body)) body = await rd.ReadToEndAsync();
    JsonNode? json = null; try { if (body.Length > 0) json = JsonNode.Parse(body); } catch { }
    (int, object?) res;
    // /_fake/latency: the answer to a matching request is held back, as a slow GitHub would (the test control itself is never slowed)
    int wait; lock (gate) { wait = world.LatencyFor(method, path, body); }
    if (wait > 0) await Task.Delay(wait);
    string? etag = null;
    // as GitHub: every answer of the API carries the rate limit of the caller's resource (core, or graphql for /graphql); an exhausted one answers
    // 403 with x-ratelimit-remaining 0 and the documented message (/_fake/rate sets what is left)
    (string Resource, int Limit, int Remaining, long Reset, int Used)? rate = null;
    lock (gate)
    {
        rate = world.RateFor(path);
        // (GraphQL answers 200 with an error of type RATE_LIMITED, REST 403)
        if (rate is { Remaining: <= 0, Resource: "graphql" }) res = (200, "{\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"API rate limit exceeded for installation ID 7.\"}]}");
        else if (rate is { Remaining: <= 0 }) res = (403, "{\"message\":\"API rate limit exceeded for installation ID 7. If you reach out to GitHub Support for help, please include the request ID.\",\"documentation_url\":\"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting\"}");
        else { world.IfNoneMatch = ctx.Request.Headers.IfNoneMatch.ToString(); world.Etag = null; res = world.Handle(method, path, query, json, ctx.Request.Headers.Authorization.ToString()); etag = world.Etag; }
    }
    if (rate is { } rl)
    {
        ctx.Response.Headers["x-ratelimit-limit"] = rl.Limit.ToString(); ctx.Response.Headers["x-ratelimit-remaining"] = Math.Max(0, rl.Remaining).ToString();
        ctx.Response.Headers["x-ratelimit-used"] = rl.Used.ToString(); ctx.Response.Headers["x-ratelimit-reset"] = rl.Reset.ToString(); ctx.Response.Headers["x-ratelimit-resource"] = rl.Resource;
    }
    if (etag != null) ctx.Response.Headers.ETag = etag;
    ctx.Response.StatusCode = res.Item1;
    // as GitHub: a job log and an artifact archive are answered with a redirect to a signed address of another store
    if (res.Item2 is Redirect go) { ctx.Response.Headers.Location = $"http://127.0.0.1:{port}{go.To}"; return; }
    if (res.Item2 is PlainText pt) { ctx.Response.ContentType = "text/plain; charset=utf-8"; await ctx.Response.WriteAsync(pt.Text); return; }
    if (res.Item2 is byte[] bin) { ctx.Response.ContentType = "application/zip"; await ctx.Response.Body.WriteAsync(bin); return; }
    if (res.Item2 is not null) { ctx.Response.ContentType = "application/json"; await ctx.Response.WriteAsync(res.Item2 is string s ? s : JsonSerializer.Serialize(res.Item2)); }
});
app.Run();

sealed class Issue { public int Number; public string Node = ""; public string Title = ""; public string Body = ""; public bool Open = true; public List<string> Labels = new(); public string? Column; public string? Card; public List<Comment> Comments = new(); public DateTime Created = DateTime.UtcNow; }
sealed class Comment { public long Id; public string Body = ""; public string User = "factory-bot"; public DateTime At = DateTime.UtcNow; }
sealed class Pr { public int Number; public string Ref = ""; public string Sha = ""; public string Title = ""; public string Body = ""; public bool Open = true; public bool Merged; public string? MergeSha; public int MergeableNullReads; public int Behind; public bool Conflict; public List<string> Files = new(); public List<JsonObject> FileObjs = new(); public List<Rev> Reviews = new(); public int? Issue; public string Author = "factory-bot"; public string Profile = "green"; public double DelaySeconds; public bool Fork, Draft, UpdateNoop; public List<Comment> Comments = new(); }
sealed record Redirect(string To);
sealed record PlainText(string Text);
// App "github-actions": the check run is a job of a workflow run (its id is the job id), with steps, a log and the artifacts of the run.
// Another App (a Qodana-like tool) has no job: it reports through its output and its annotations.
sealed class Check { public string Name = ""; public string Status = "completed"; public string? Conclusion = "success"; public DateTime Started = DateTime.UtcNow; public DateTime? CompleteAt; public int Id;
    public string App = "github-actions"; public string? OutputTitle, OutputSummary; public List<JsonObject> Annotations = new(); public List<JsonObject> Steps = new(); public string? Log; public long RunId = 1; }
sealed class Artifact { public long Id; public long RunId; public string Name = ""; public bool Expired; public long? Size; public byte[] Zip = Array.Empty<byte>(); }
sealed class Rev { public long Id; public string State = ""; public string Commit = ""; public string User = ""; public string Body = ""; }
sealed class Fault { public Regex Match = null!; public int Status; public int Remaining; public string Body = "{\"message\":\"injected fault\"}"; }
sealed class GhRel { public long Id; public string Tag = "", Name = "", Body = "", Target = ""; public bool Prerelease; public List<GhAsset> Assets = new(); }
sealed class GhAsset { public long Id; public string Name = "", ContentType = ""; public long Size; }
sealed class Rel { public string Id = ""; public string Version = ""; public string Notes = ""; public DateTime At; public double ProdDelay; }

// A Container Apps job execution of the fake ARM (cloud worker runtimes): its name, status, env and times.
sealed class ArmExec { public string Name = "", Job = ""; public string Status = "Running"; public JsonArray Containers = new(); public DateTime Start = DateTime.UtcNow; public DateTime? End; }

// A Cloud Agent of the fake Cursor API (agents-roles-launch.md 10): its id, the launch body as sent, its status and its run.
sealed class CursorAgent { public string Id = "", RunId = "", Status = "ACTIVE", RunStatus = "RUNNING"; public JsonObject Body = new(); public bool Deleted, Cancelled; public DateTime Created = DateTime.UtcNow; }

sealed class World
{
    // The fake Cursor Cloud Agents API v1: POST /v1/agents, GET /v1/agents/{id}, GET .../runs/{runId}, POST .../runs/{runId}/cancel, DELETE /v1/agents/{id}.
    // It wants the bearer key "fake-cursor". Not cleared by /_fake/reset; /_fake/cursor-reset does.
    readonly List<CursorAgent> cursorAgents = new(); long cursorSeq; int cursorLaunchFailures;
    (int, object?) Cursor(string method, string path, JsonNode? b, string auth)
    {
        if (auth != "Bearer fake-cursor") return (401, "{\"error\":\"unauthorized\"}");
        if (path == "/v1/agents" && method == "POST")
        {
            if (cursorLaunchFailures > 0) { cursorLaunchFailures--; return (500, "{\"error\":\"internal\"}"); }
            var a = new CursorAgent { Id = "bc-" + (++cursorSeq).ToString("x8"), RunId = "run-" + cursorSeq.ToString("x8"), Body = b as JsonObject ?? new JsonObject() };
            cursorAgents.Add(a);
            return (201, J(("agent", J(("id", a.Id), ("status", a.Status), ("latestRunId", a.RunId))), ("run", J(("id", a.RunId), ("status", "CREATING")))));
        }
        if (path == "/v1/models" && method == "GET") return (200, J(("items", new JsonArray(J(("id", "claude-4-sonnet-thinking")), J(("id", "auto")), J(("id", "auto-smart"), ("params", new JsonArray(J(("id", "optimize_for"), ("values", new JsonArray("cost", "balanced", "intelligence"))))))))));
        if (Regex.IsMatch(path, "^/v1/agents/[^/]+/usage$") && method == "GET")
            return (200, J(("totalUsage", J(("inputTokens", 1200), ("outputTokens", 340), ("cacheWriteTokens", 0), ("cacheReadTokens", 800), ("totalTokens", 2340))), ("runs", new JsonArray())));
        if (path == "/v1/agents" && method == "GET")
            return (200, J(("items", new JsonArray(cursorAgents.Where(x => !x.Deleted).Select(x => (JsonNode)J(("id", x.Id), ("name", x.Body["name"]?.ToString() ?? ""), ("status", x.Status), ("createdAt", x.Created.ToString("o")))).ToArray()))));
        var m = Regex.Match(path, "^/v1/agents/([^/]+)(/runs/([^/]+)(/cancel)?)?$");
        if (!m.Success) return (404, null);
        var ag = cursorAgents.FirstOrDefault(x => x.Id == m.Groups[1].Value && !x.Deleted);
        if (ag == null) return (404, "{\"error\":\"not found\"}");
        if (!m.Groups[2].Success && method == "GET") return (200, J(("agent", J(("id", ag.Id), ("status", ag.Status), ("latestRunId", ag.RunId), ("model", ag.Body["model"]?.DeepClone())))));
        if (!m.Groups[2].Success && method == "DELETE") { ag.Deleted = true; return (200, J(("id", ag.Id))); }
        if (m.Groups[4].Success && method == "POST") { ag.Cancelled = true; ag.RunStatus = "CANCELLED"; ag.Status = "IDLE"; return (200, J(("id", ag.RunId))); }
        if (m.Groups[2].Success && method == "GET") return (200, J(("run", J(("id", ag.RunId), ("status", ag.RunStatus)))));
        return (405, null);
    }
    JsonObject CursorState() => J(("agents", new JsonArray(cursorAgents.Select(a => (JsonNode)J(("id", a.Id), ("status", a.Status), ("run", a.RunStatus), ("deleted", a.Deleted), ("cancelled", a.Cancelled), ("body", a.Body.DeepClone()))).ToArray())));

    // The fake ARM (Microsoft.App/jobs of cloud-worker-runtimes.md 2.1): GET the job, POST start with a container override, GET executions, POST
    // stop. It wants the bearer token "fake-arm". It is not cleared by /_fake/reset (a gateway keeps its executions across scenarios); /_fake/arm-reset does.
    readonly List<ArmExec> armExecs = new(); int armStarts, armStops; long armSeq; int armStartFailures;
    (int, object?) Arm(string method, string path, JsonNode? b, string auth)
    {
        if (auth != "Bearer fake-arm") return (401, "{\"error\":{\"code\":\"InvalidAuthenticationToken\"}}");
        var m = Regex.Match(path, "^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.App/jobs/[^/]+)(/start|/executions(/([^/]+)/stop)?)?$");
        if (!m.Success) return (404, "{\"error\":{\"code\":\"ResourceNotFound\"}}");
        var tail = m.Groups[2].Value;
        if (tail == "" && method == "GET")
        {
            var env = new JsonArray(J(("name", "CLAUDE_CODE_USE_FOUNDRY"), ("value", "1")), J(("name", "FWORKER_NAME"), ("value", "from-the-job-template")));
            var container = J(("name", "fwrunner"), ("image", "fake.azurecr.io/fwrunner:1"), ("env", env));
            return (200, J(("id", m.Groups[1].Value), ("properties", J(("template", J(("containers", new JsonArray(container))))))));
        }
        if (tail == "/start" && method == "POST")
        {
            if (armStartFailures > 0) { armStartFailures--; return (500, "{\"error\":{\"code\":\"InternalServerError\"}}"); }
            armStarts++;
            var e = new ArmExec { Name = "caj-test-" + (++armSeq).ToString("x6"), Job = m.Groups[1].Value.Split('/')[^1], Containers = b?["containers"]?.DeepClone() as JsonArray ?? new JsonArray() };
            armExecs.Add(e);
            return (202, J(("id", m.Groups[1].Value + "/executions/" + e.Name), ("name", e.Name)));
        }
        if (tail == "/executions" && method == "GET")
            return (200, J(("value", new JsonArray(armExecs.Select(e => (JsonNode)J(("name", e.Name), ("properties", J(("status", e.Status), ("startTime", e.Start.ToString("o")), ("endTime", e.End?.ToString("o")),
                ("template", J(("containers", e.Containers.DeepClone()))))))).ToArray()))));
        if (m.Groups[4].Success && method == "POST")
        {
            var e = armExecs.FirstOrDefault(x => x.Name == m.Groups[4].Value); if (e == null) return (404, null);
            armStops++; if (e.Status is "Running" or "Processing") { e.Status = "Stopped"; e.End = DateTime.UtcNow; }
            return (200, J(("name", e.Name)));
        }
        return (405, null);
    }
    static string EnvOf(ArmExec e, string n) => e.Containers.SelectMany(c => c?["env"] as JsonArray ?? new JsonArray()).LastOrDefault(x => x?["name"]?.ToString() == n)?["value"]?.ToString() ?? "";
    JsonObject ArmState() => J(("starts", armStarts), ("stops", armStops), ("executions", new JsonArray(armExecs.Select(e => (JsonNode)J(("name", e.Name), ("job", e.Job), ("status", e.Status),
        ("worker", EnvOf(e, "FWORKER_NAME")), ("item", EnvOf(e, "FWORKER_ITEM")), ("phase", EnvOf(e, "FWORKER_PHASE")), ("nonce", EnvOf(e, "FWORKER_NONCE")), ("profile", EnvOf(e, "FWORKER_MODEL_PROFILE")),
        ("image", e.Containers.FirstOrDefault()?["image"]?.ToString()), ("env", e.Containers.FirstOrDefault()?["env"]?.DeepClone()))).ToArray())));

    const string Owner = "clearmeasure-aisf-sample-apps", Repo = "cmdemo1-workorders", Master = "master";
    readonly string[] columns = { "Todo", "In Progress", "Technical Design", "Development", "Functional Testing", "Release Queue", "Done" };
    readonly Dictionary<int, Issue> issues = new();
    readonly Dictionary<int, Pr> prs = new();
    readonly Dictionary<string, List<Check>> checks = new();
    readonly HashSet<string> refs = new();
    // what a ref points at (a ref created before this was kept points at master's head) and the commits written through git/commits (the plant snapshot)
    readonly Dictionary<string, string> refSha = new();
    readonly Dictionary<string, (string Message, string Tree, List<string> Parents)> commits = new();
    // a conditional read (If-None-Match of the request) and the ETag of the answer, for the one ref by its path (as GitHub: 304 when unchanged)
    public string IfNoneMatch = ""; public string? Etag;
    readonly Dictionary<string, (string Sha, List<string> Files, List<JsonObject> Objs)> branches = new();
    long nextReview = 1;
    readonly Dictionary<string, (string Profile, double Delay)> branchProfile = new();
    readonly List<Fault> faults = new();
    readonly List<Rel> releases = new();
    readonly List<string> log = new();
    readonly List<Artifact> artifacts = new();
    readonly List<string> masterHistory = new();   // the commits of the base branch, oldest first; the last one is masterSha
    readonly Dictionary<string, List<string>> masterFiles = new();   // the files each commit of the base branch changed (for compare)
    long nextArtifact = 1;
    readonly HashSet<string> labelNames = new() { "factory worker", "AI Factory", "Auto Merge", "video", "Demo", "Ready To Move", "Needs Human Review" };
    string masterSha = Sha("master0");
    readonly Dictionary<string, List<string>> parents = new();
    readonly HashSet<string> webFlow = new();                     // commits GitHub itself made and signed (update-branch)   // commits/{sha}: the parents of the branch commits the fake made
    int nextNumber = 1, nextComment = 1000, nextCheck = 1, nextPr = 1;
    int healthStatus = 200;
    bool masterRed; double prodDelay = 0;
    // masterFlaky: the master Build fails one acceptance shard at once while "Build result" is still running (it fails seconds later), as a flaky shard
    // does on GitHub. rerunSeconds / rerunConclusion: how long a re-run of failed jobs takes and how it ends (default: 3 s, success).
    bool masterFlaky; double flakyRunSeconds = 4, rerunSeconds = 3; string rerunConclusion = "success";
    long nextRun = 1000; readonly Dictionary<long, int> runAttempts = new(); readonly Dictionary<long, string> pendingRelease = new(); int rerunRefusals, reruns; string releaseMode = "auto"; string docsRelease = "skipped"; bool masterHold; string? masterArchitecture;
    long counter = 0; int appMints; readonly List<string> scopedMints = new();

    static string Sha(string seed) => Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(seed))).ToLowerInvariant();
    string NewSha() => Sha("c" + (++counter) + DateTime.UtcNow.Ticks);
    // The product's own documentation rule (docsOnlyPaths of the instance configuration, as Test-DocsOnlyFiles reads it), not a copy that can drift:
    // from FACTORY_CONFIG when the fake is started with it, else from config/instance.json above the binary.
    static Regex[]? docPats;
    static Regex[] DocPats()
    {
        if (docPats != null) return docPats;
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG");
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); (path == null || !File.Exists(path)) && d != null; d = d.Parent) { var c = Path.Combine(d.FullName, "config", "instance.json"); if (File.Exists(c)) path = c; }
        if (path == null || !File.Exists(path)) throw new InvalidOperationException("the fake needs the instance configuration for docsOnlyPaths: set FACTORY_CONFIG");
        return docPats = JsonNode.Parse(File.ReadAllText(path))!["docsOnlyPaths"]!.AsArray().Select(x => new Regex(x!.ToString(), RegexOptions.IgnoreCase)).ToArray();
    }
    static bool DocsOnly(IEnumerable<string> files) { var l = files.ToList(); var pats = DocPats(); return l.Count > 0 && l.All(f => pats.Any(p => p.IsMatch(f))); }
    static JsonObject J(params (string, JsonNode?)[] kv) { var o = new JsonObject(); foreach (var (k, v) in kv) o[k] = v; return o; }

    // GitHub adds the App's mandatory metadata: read to the permissions a token is narrowed to
    static JsonObject Granted(JsonObject? asked) { var g = asked?.DeepClone() as JsonObject ?? J(("contents", "write")); g["metadata"] = "read"; return g; }
    static string Who(string auth)
    {
        var t = auth.StartsWith("Bearer ") ? auth[7..] : auth;
        if (t.StartsWith("fake-app-")) return "factory-worker-author[bot]";
        return t switch { "fake-reviewer" => "factory-worker-reviewer[bot]", "fake-testperson" => "factory-worker-testperson[bot]", _ => "factory-bot" };
    }

    public (int, object?) Handle(string method, string path, Microsoft.AspNetCore.Http.IQueryCollection q, JsonNode? b, string auth = "")
    {
        log.Add($"{method} {path}");
        if (path.StartsWith("/_fake/")) return Control(method, path[7..], q, b);
        foreach (var f in faults.ToList())
            if (f.Remaining > 0 && f.Match.IsMatch($"{method} {path}")) { f.Remaining--; return (f.Status, f.Body); }
        if (path.StartsWith("/octopus/")) return Octopus(path[9..], q);
        if (path.StartsWith("/subscriptions/")) return Arm(method, path, b, auth);
        if (path.StartsWith("/v1/")) return Cursor(method, path, b, auth);
        var root = $"/repos/{Owner}/{Repo}";
        Match m;
        if ((m = Regex.Match(path, "^/_blob/(logs|artifacts)/(\\d+)$")).Success)
        {   // the signed address a redirect points to: it refuses a request that still carries the GitHub credential, as the real store does
            if (auth.Length > 0) return (403, "{\"message\":\"InvalidAuthenticationInfo: the signed address takes no Authorization header\"}");
            var bid = long.Parse(m.Groups[2].Value);
            if (m.Groups[1].Value == "logs") { var bc = checks.Values.SelectMany(x => x).FirstOrDefault(c => c.Id == bid); return bc == null ? (404, null) : (200, new PlainText(bc.Log ?? DefaultLog(bc))); }
            var ba = artifacts.FirstOrDefault(x => x.Id == bid); return ba == null ? (404, null) : (200, ba.Zip);
        }
        if (path == "/user") return (200, J(("login", "factory-bot")));
        if (path == "/_healthcheck") return (healthStatus, healthStatus == 200 ? "ok" : null);        // stands in for the QC environment's app in the QC scenarios
        if (path == "/graphql") return GraphQl(b!);
        if (path == root && method == "GET") return (200, J(("permissions", J(("push", true), ("admin", true)))));
        if (path == root + "/labels" && method == "POST") { var nm = b!["name"]!.ToString(); return labelNames.Add(nm) ? (201, J(("name", nm))) : (422, "{\"message\":\"Validation Failed\"}"); }
        var am = Regex.Match(path, "^/app/installations/(\\d+)/access_tokens$");
        if (am.Success && method == "POST")
        {   // GitHub App installation token: the request must carry an RS256-shaped JWT whose iss is the App id
            var parts = (auth.StartsWith("Bearer ") ? auth[7..] : auth).Split('.');
            if (parts.Length != 3) return (401, "{\"message\":\"A JSON web token could not be decoded\"}");
            string iss; try { var pl = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(parts[1].Replace('-', '+').Replace('_', '/').PadRight((parts[1].Length + 3) / 4 * 4, '='))); iss = JsonNode.Parse(pl)!["iss"]!.ToString(); } catch { return (401, "{\"message\":\"bad payload\"}"); }
            appMints++;
            // as GitHub: a request may narrow the token to repositories and permissions, and the answer names the scope granted
            if (b?["repositories"] is JsonArray want)
            {
                scopedMints.Add(b.ToJsonString());
                return (201, J(("token", "fake-app-" + iss), ("expires_at", DateTime.UtcNow.AddHours(1).ToString("o")),
                    ("permissions", Granted(b["permissions"] as JsonObject)), ("repositories", new JsonArray(want.Select(r => (JsonNode)J(("name", r!.ToString()), ("full_name", $"{Owner}/{r}"))).ToArray()))));
            }
            return (201, J(("token", "fake-app-" + iss), ("expires_at", DateTime.UtcNow.AddHours(1).ToString("o"))));
        }
        if ((m = Regex.Match(path, $"^{root}/issues/(\\d+)/labels(/(.+))?$")).Success && issues.TryGetValue(int.Parse(m.Groups[1].Value), out var li))
        {
            if (method == "POST") { foreach (var l in b!["labels"]!.AsArray()) if (!li.Labels.Contains(l!.ToString())) li.Labels.Add(l!.ToString()); return (200, new JsonArray(li.Labels.Select(x => (JsonNode)J(("name", x))).ToArray())); }
            if (method == "DELETE") return li.Labels.Remove(Uri.UnescapeDataString(m.Groups[3].Value)) ? (200, new JsonArray()) : (404, "{\"message\":\"Label does not exist\"}");
        }
        if (path == root + "/labels" && method == "GET") return (200, new JsonArray(labelNames.Select(n => (JsonNode)J(("name", n))).ToArray()));
        if (path == root + "/issues" && method == "POST")
        {   // as GitHub: a new open issue with its labels (a label that does not exist yet is created with it), on no board until it is added
            var ni = new Issue { Number = nextNumber++, Title = b!["title"]!.ToString(), Body = b["body"]?.ToString() ?? "" };
            ni.Node = "I_" + ni.Number; foreach (var l in b["labels"]?.AsArray() ?? new JsonArray()) { if (!ni.Labels.Contains(l!.ToString())) ni.Labels.Add(l.ToString()); labelNames.Add(l.ToString()); }
            issues[ni.Number] = ni;
            return (201, J(("number", ni.Number), ("node_id", ni.Node), ("state", "open"), ("title", ni.Title), ("html_url", $"https://fake/issues/{ni.Number}")));
        }
        if (path == $"{root}/issues" && method == "GET")
        {   // the repository's issues, as GitHub lists them: state (default open), labels (all of a comma list), per_page (default 30, at most 100), page
            var st = q["state"].ToString() is { Length: > 0 } sv ? sv : "open";
            var want = q["labels"].ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            int per = Math.Clamp(int.TryParse(q["per_page"], out var pp) ? pp : 30, 1, 100), pg = Math.Max(1, int.TryParse(q["page"], out var pq) ? pq : 1);
            var rows = issues.Values.Where(i => st == "all" || (st == "open") == i.Open).Where(i => want.All(w => i.Labels.Contains(w, StringComparer.OrdinalIgnoreCase)))
                .OrderByDescending(i => i.Number).Skip((pg - 1) * per).Take(per)
                .Select(i => (JsonNode)J(("number", i.Number), ("node_id", i.Node), ("state", i.Open ? "open" : "closed"), ("title", i.Title), ("labels", new JsonArray(i.Labels.Select(x => (JsonNode)J(("name", x))).ToArray())))).ToArray();
            return (200, new JsonArray(rows));
        }
        if ((m = Regex.Match(path, $"^{root}/issues/(\\d+)$")).Success)
        {
            if (!issues.ContainsKey(int.Parse(m.Groups[1].Value))) return (404, "{\"message\":\"Not Found\"}");
            var i = issues[int.Parse(m.Groups[1].Value)];
            if (method == "PATCH") { if (b?["body"] is { } bb) i.Body = bb.ToString(); if (b?["state"]?.ToString() == "closed") i.Open = false; return (200, J(("number", i.Number))); }
            return (200, J(("number", i.Number), ("state", i.Open ? "open" : "closed"), ("title", i.Title), ("body", i.Body)));
        }
        if ((m = Regex.Match(path, $"^{root}/issues/(\\d+)/comments$")).Success)
        {
            // a pull request is an issue to the comments API: its comments are kept on the PR
            var cn = int.Parse(m.Groups[1].Value);
            var thread = issues.TryGetValue(cn, out var ci) ? ci.Comments : prs.TryGetValue(cn, out var cp) ? cp.Comments : null;
            if (thread == null) return (404, "{\"message\":\"Not Found\"}");
            if (method == "POST") { var c = new Comment { Id = nextComment++, Body = b!["body"]!.ToString() }; thread.Add(c); return (201, J(("id", c.Id))); }
            int page = int.TryParse(q["page"], out var pg) ? pg : 1;
            return (200, new JsonArray(thread.Skip((page - 1) * 100).Take(100).Select(c => (JsonNode)J(("id", c.Id), ("body", c.Body), ("user", J(("login", c.User))), ("created_at", c.At.ToString("o")))).ToArray()));
        }
        if ((m = Regex.Match(path, $"^{root}/issues/comments/(\\d+)$")).Success && method == "PATCH")
        {
            var id = long.Parse(m.Groups[1].Value);
            foreach (var thread in issues.Values.Select(x => x.Comments).Concat(prs.Values.Select(x => x.Comments))) { var c = thread.FirstOrDefault(x => x.Id == id); if (c != null) { c.Body = b!["body"]!.ToString(); return (200, J(("id", id))); } }
            return (404, "{\"message\":\"Not Found\"}");
        }
        if (path == root + $"/git/ref/heads/{Master}") return (200, J(("object", J(("sha", masterSha)))));
        if (path == root + "/git/refs" && method == "POST")
        {
            var r = b!["ref"]!.ToString();
            if (!refs.Add(r)) return (422, "{\"message\":\"Reference already exists\"}");
            if (b["sha"]?.ToString() is { } rs) refSha[r] = rs;
            return (201, J(("ref", r)));
        }
        // As GitHub: one ref by its path (404 when there is none), an update of an existing ref (422 "Reference does not exist" otherwise), a commit
        // written with a message, a tree and parents, and a commit read back with its message and tree; an unknown commit is 404.
        if ((m = Regex.Match(path, $"^{root}/git/ref/(.+)$")).Success && method == "GET")
        {
            var r = "refs/" + m.Groups[1].Value;
            if (!refs.Contains(r)) return (404, "{\"message\":\"Not Found\"}");
            var rsha0 = refSha.TryGetValue(r, out var rsha) ? rsha : masterSha;
            Etag = $"W/\"{rsha0}\"";
            if (IfNoneMatch != "" && IfNoneMatch == Etag) return (304, null);
            return (200, J(("ref", r), ("object", J(("sha", rsha0), ("type", "commit")))));
        }
        if ((m = Regex.Match(path, $"^{root}/git/refs/(.+)$")).Success && method == "PATCH")
        {
            var r = "refs/" + m.Groups[1].Value;
            if (!refs.Contains(r)) return (422, "{\"message\":\"Reference does not exist\"}");
            if (b?["sha"]?.ToString() is not { Length: > 0 } ns) return (422, "{\"message\":\"Invalid request.\"}");
            // as GitHub: without force the ref moves only to a commit that descends from the one it points at (a fast forward)
            var force = b["force"] is JsonValue fv && fv.TryGetValue<bool>(out var fb) && fb;
            var curSha = refSha.TryGetValue(r, out var cs0) ? cs0 : masterSha;
            if (!force && ns != curSha && !Descends(ns, curSha)) return (422, "{\"message\":\"Update is not a fast forward\"}");
            refSha[r] = ns; return (200, J(("ref", r), ("object", J(("sha", ns), ("type", "commit")))));
        }
        if (path == root + "/git/commits" && method == "POST")
        {
            if (b?["tree"]?.ToString() is not { Length: > 0 } tree || b["message"] is null) return (422, "{\"message\":\"Invalid request.\"}");
            var sha = NewSha(); commits[sha] = (b["message"]!.ToString(), tree, (b["parents"] as JsonArray ?? new JsonArray()).Select(x => x!.ToString()).ToList());
            return (201, J(("sha", sha), ("message", commits[sha].Message), ("tree", J(("sha", tree)))));
        }
        if ((m = Regex.Match(path, $"^{root}/git/commits/([0-9a-f]+)$")).Success && method == "GET")
        {
            var sha = m.Groups[1].Value;
            if (commits.TryGetValue(sha, out var cm)) return (200, J(("sha", sha), ("message", cm.Message), ("tree", J(("sha", cm.Tree)))));
            if (sha == masterSha || masterFiles.ContainsKey(sha)) return (200, J(("sha", sha), ("message", "master"), ("tree", J(("sha", Sha("tree" + sha))))));
            return (404, "{\"message\":\"Not Found\"}");
        }
        if ((m = Regex.Match(path, $"^{root}/git/matching-refs/(.+)$")).Success && method == "GET")
        {
            // As GitHub: matching-refs takes no page number. It answers every matching ref whatever "page" says, so a reader that asks for page
            // after page until one is empty gets the same refs for ever (the outage of 2026-10-13: the fake paged, GitHub did not).
            // Only /_fake/ref-page { size } makes this a paging server, for the scenario of a reader against one.
            var match = refs.Where(r => r.StartsWith("refs/" + m.Groups[1].Value, StringComparison.Ordinal)).OrderBy(r => r, StringComparer.Ordinal);
            if (refPage <= 0) return (200, new JsonArray(match.Select(r => (JsonNode)J(("ref", r))).ToArray()));
            int rp = int.TryParse(q["page"], out var rpg) ? rpg : 1; int per = Math.Min(Math.Clamp(int.TryParse(q["per_page"], out var pp) ? pp : 30, 1, 100), refPage);
            return (200, new JsonArray(match.Skip((rp - 1) * per).Take(per).Select(r => (JsonNode)J(("ref", r))).ToArray()));
        }
        if ((m = Regex.Match(path, $"^{root}/git/refs/(.+)$")).Success && method == "DELETE")
            { refSha.Remove("refs/" + m.Groups[1].Value); return refs.Remove("refs/" + m.Groups[1].Value) ? (204, null) : (422, "{\"message\":\"Reference does not exist\"}"); }
        if (path == root + "/branches/" + Master && method == "GET") return (200, J(("name", Master), ("commit", J(("sha", masterSha)))));
        if ((m = Regex.Match(path, $"^{root}/compare/([^.]+)\\.\\.\\.(.+)$")).Success && method == "GET") return Compare(m.Groups[1].Value, m.Groups[2].Value);
        if (path == root + "/pulls" && method == "GET")
            return (200, new JsonArray(prs.Values.Where(x => x.Open).Select(x => (JsonNode)PrJson(x)).ToArray()));
        if (path == root + "/pulls" && method == "POST")
        {
            var head = b!["head"]!.ToString();
            if (!branches.TryGetValue(head, out var br) || br.Files.Count == 0) return (422, "{\"message\":\"Validation Failed\",\"errors\":[{\"message\":\"No commits between master and " + head + "\"}]}");
            var bp = branchProfile.TryGetValue(head, out var bpv) ? bpv : ("green", 0.0);
            var pr = new Pr { Profile = bp.Item1, DelaySeconds = bp.Item2, Number = nextNumber++, Ref = head, Sha = br.Sha, Title = b["title"]!.ToString(), Body = b["body"]?.ToString() ?? "", Files = br.Files.ToList(), FileObjs = br.Objs.ToList() };
            var mm = Regex.Match(head, @"/(\d+)-"); if (mm.Success) pr.Issue = int.Parse(mm.Groups[1].Value);
            prs[pr.Number] = pr; ApplyProfile(pr, pr.Sha);
            return (201, PrJson(pr));
        }
        if ((m = Regex.Match(path, $"^{root}/pulls/(\\d+)(/(files|reviews|merge|update-branch))?$")).Success)
        {
            if (!prs.TryGetValue(int.Parse(m.Groups[1].Value), out var pr)) return (404, "{\"message\":\"Not Found\"}");
            switch (m.Groups[3].Value)
            {
                case "files": return (200, new JsonArray(pr.FileObjs.Select(o => (JsonNode)JsonNode.Parse(o.ToJsonString())!).ToArray()));
                case "reviews":
                    if (method == "POST")
                    {
                        var who = Who(auth); var ev = b!["event"]!.ToString();
                        if (ev == "APPROVE" && who == pr.Author) return (422, "{\"message\":\"Unprocessable Entity: Can not approve your own pull request\"}");
                        var rv = new Rev { Id = nextReview++, State = ev == "APPROVE" ? "APPROVED" : ev == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED", Commit = b["commit_id"]?.ToString() ?? pr.Sha, User = who, Body = b["body"]?.ToString() ?? "" };
                        pr.Reviews.Add(rv); return (200, J(("id", rv.Id), ("state", rv.State)));
                    }
                    return (200, new JsonArray(pr.Reviews.Select(r => (JsonNode)J(("id", r.Id), ("state", r.State), ("commit_id", r.Commit), ("user", J(("login", r.User))), ("body", r.Body))).ToArray()));
                case "update-branch":
                    // as GitHub: expected_head_sha that is not the head is refused (the head moved meanwhile)
                    if (b?["expected_head_sha"] is { } ehs && ehs.ToString() != pr.Sha) return (422, "{\"message\":\"expected head sha didn't match current head ref.\"}");
                    if (pr.Conflict) return (422, "{\"message\":\"merge conflict between base and head\"}");
                    if (pr.UpdateNoop) return (202, "{\"message\":\"Updating pull request branch.\"}");   // accepted, not done yet
                    { var old = pr.Sha; pr.Behind = 0; pr.Sha = NewSha(); parents[pr.Sha] = new() { old, History()[^1] }; webFlow.Add(pr.Sha); ApplyProfile(pr, pr.Sha); }
                    return (202, "{\"message\":\"Updating pull request branch.\"}");
                case "merge": return Merge(pr, b);
                default:
                    if (method == "PATCH")
                    {   // title and body only, and only while open (as GitHub: a closed pull request's text can be edited there, the product never does);
                        // state "closed" closes an open pull request without merging it, as GitHub does
                        if (b?["body"] is { } nb) pr.Body = nb.ToString();
                        if (b?["title"] is { } nt) pr.Title = nt.ToString();
                        if (b?["state"]?.ToString() == "closed" && !pr.Merged) pr.Open = false;
                    }
                    return (200, PrJson(pr, true));
            }
        }
        if ((m = Regex.Match(path, $"^{root}/commits/([0-9a-f]+)$")).Success)
        {
            var ps = parents.TryGetValue(m.Groups[1].Value, out var known) ? known : new List<string> { History()[^1] };
            var gh = webFlow.Contains(m.Groups[1].Value);
            var commit = J(("committer", gh ? J(("name", "GitHub"), ("email", "noreply@github.com")) : J(("name", "factory-bot"), ("email", "bot@example.invalid"))),
                ("verification", J(("verified", gh), ("reason", gh ? "valid" : "unsigned"))));
            return (200, J(("sha", m.Groups[1].Value), ("commit", commit), ("parents", new JsonArray(ps.Select(p => (JsonNode)J(("sha", p))).ToArray()))));
        }
        if ((m = Regex.Match(path, $"^{root}/commits/([0-9a-f]+)/check-runs$")).Success)
        {
            var sha = m.Groups[1].Value; var list = checks.TryGetValue(sha, out var l) ? l : new();
            foreach (var c in list) if (c.CompleteAt is { } at && DateTime.UtcNow >= at) { c.Status = "completed"; c.CompleteAt = null; }
            return (200, J(("check_runs", new JsonArray(list.Select(c => (JsonNode)J(("id", c.Id), ("name", c.Name), ("status", c.Status), ("conclusion", c.Conclusion), ("started_at", c.Started.ToString("o")),
                ("completed_at", c.Status == "completed" ? c.Started.AddSeconds(30).ToString("o") : null), ("details_url", c.App == "github-actions" ? $"https://fake/actions/runs/{c.RunId}/job/{c.Id}" : $"https://fake/checks/{c.Id}"),
                ("html_url", $"https://fake/runs/{c.Id}"), ("app", J(("slug", c.App))),
                ("output", J(("title", c.OutputTitle), ("summary", c.OutputSummary), ("text", null), ("annotations_count", c.Annotations.Count), ("annotations_url", $"https://fake/check-runs/{c.Id}/annotations"))))).ToArray()))));
        }
        if (path == root + "/commits" && method == "GET")
        {   // the commits of a branch, newest first (only the base branch has a history here)
            int per = Math.Clamp(int.TryParse(q["per_page"], out var cpp) ? cpp : 30, 1, 100);
            if (q["sha"].ToString() is { Length: > 0 } br0 && br0 != Master) return (404, "{\"message\":\"Not Found\"}");
            return (200, new JsonArray(History().AsEnumerable().Reverse().Take(per).Select(x => (JsonNode)J(("sha", x))).ToArray()));
        }
        if ((m = Regex.Match(path, $"^{root}/check-runs/(\\d+)/annotations$")).Success)
        {
            var c = FindCheck(long.Parse(m.Groups[1].Value)); if (c == null) return (404, "{\"message\":\"Not Found\"}");
            int per = Math.Clamp(int.TryParse(q["per_page"], out var app0) ? app0 : 30, 1, 100); int pg = int.TryParse(q["page"], out var apg) ? apg : 1;
            return (200, new JsonArray(c.Annotations.Skip((pg - 1) * per).Take(per).Select(o => JsonNode.Parse(o.ToJsonString())).ToArray()));
        }
        if ((m = Regex.Match(path, $"^{root}/actions/jobs/(\\d+)(/logs)?$")).Success && method == "GET")
        {
            var c = FindCheck(long.Parse(m.Groups[1].Value)); if (c == null || c.App != "github-actions") return (404, "{\"message\":\"Not Found\"}");
            if (m.Groups[2].Success) return (302, new Redirect($"/_blob/logs/{c.Id}"));
            var steps = c.Steps.Count > 0 ? c.Steps : new List<JsonObject> { J(("name", "Run"), ("number", 1), ("status", "completed"), ("conclusion", c.Conclusion), ("started_at", c.Started.ToString("o")), ("completed_at", c.Started.AddSeconds(30).ToString("o"))) };
            return (200, J(("id", c.Id), ("run_id", c.RunId), ("name", c.Name), ("status", c.Status), ("conclusion", c.Conclusion), ("workflow_name", "Build"),
                ("steps", new JsonArray(steps.Select(o => JsonNode.Parse(o.ToJsonString())).ToArray()))));
        }
        if ((m = Regex.Match(path, $"^{root}/actions/runs/(\\d+)/artifacts$")).Success && method == "GET")
        {
            var mine = artifacts.Where(x => x.RunId == long.Parse(m.Groups[1].Value)).ToList();
            return (200, J(("total_count", mine.Count), ("artifacts", new JsonArray(mine.Select(x => (JsonNode)J(("id", x.Id), ("name", x.Name), ("size_in_bytes", x.Size ?? x.Zip.Length), ("expired", x.Expired))).ToArray()))));
        }
        if ((m = Regex.Match(path, $"^{root}/actions/artifacts/(\\d+)/zip$")).Success && method == "GET")
        {
            var x = artifacts.FirstOrDefault(y => y.Id == long.Parse(m.Groups[1].Value)); if (x == null) return (404, "{\"message\":\"Not Found\"}");
            return x.Expired ? (410, "{\"message\":\"Artifact has expired\"}") : (302, new Redirect($"/_blob/artifacts/{x.Id}"));
        }
        if ((m = Regex.Match(path, $"^{root}/actions/jobs/(\\d+)/rerun$")).Success && method == "POST")
        {   // as GitHub: the job runs again; here it passes at once (rerunJobs counts the reruns, for the scenarios)
            var id = long.Parse(m.Groups[1].Value);
            var c = checks.Values.SelectMany(l => l).FirstOrDefault(c => c.Id == id);
            if (c == null) return (404, "{\"message\":\"Not Found\"}");
            c.Conclusion = "success"; rerunJobs++;
            return (201, null);
        }
        if (path == root + "/actions/runs" && method == "GET")
        {   // the workflow runs of a commit (head_sha), as GitHub lists them: one per run id of its check runs, judged on the latest attempt of each job
            var sha = q["head_sha"].ToString();
            var list = checks.TryGetValue(sha, out var rl) ? rl : new();
            foreach (var c in list) if (c.CompleteAt is { } at && DateTime.UtcNow >= at) { c.Status = "completed"; c.CompleteAt = null; }
            var runsOut = list.GroupBy(c => c.RunId).Select(g =>
            {
                var jobs = g.GroupBy(c => c.Name).Select(n => n.OrderBy(c => c.Started).Last()).ToList();
                var done = jobs.All(c => c.Status == "completed");
                var failed = jobs.Any(c => c.Conclusion is "failure" or "timed_out");
                return (JsonNode)J(("id", g.Key), ("head_sha", sha), ("status", done ? "completed" : "in_progress"), ("conclusion", done ? (failed ? "failure" : "success") : null), ("run_attempt", runAttempts.GetValueOrDefault(g.Key, 1)));
            }).ToArray();
            return (200, J(("total_count", runsOut.Length), ("workflow_runs", new JsonArray(runsOut))));
        }
        if ((m = Regex.Match(path, $"^{root}/actions/runs/(\\d+)/rerun-failed-jobs$")).Success && method == "POST")
        {   // as GitHub: a run that is still in progress is refused (403); otherwise its failed jobs start again as a new attempt of the run
            var rid = long.Parse(m.Groups[1].Value);
            var all = checks.Values.SelectMany(x => x).Where(c => c.RunId == rid).ToList();
            if (all.Count == 0) return (404, "{\"message\":\"Not Found\"}");
            foreach (var c in all) if (c.CompleteAt is { } at && DateTime.UtcNow >= at) { c.Status = "completed"; c.CompleteAt = null; }
            var jobs = all.GroupBy(c => c.Name).Select(n => n.OrderBy(c => c.Started).Last()).ToList();
            if (jobs.Any(c => c.Status != "completed")) { rerunRefusals++; return (403, "{\"message\":\"This workflow is already running\"}"); }
            var failedJobs = jobs.Where(c => c.Conclusion is "failure" or "timed_out").ToList();
            if (failedJobs.Count == 0) return (403, "{\"message\":\"This workflow run has no failed jobs\"}");
            runAttempts[rid] = runAttempts.GetValueOrDefault(rid, 1) + 1; reruns++;
            var listOf = checks.First(kv => kv.Value.Any(c => c.RunId == rid)).Value;
            var now = DateTime.UtcNow.AddMilliseconds(5);
            foreach (var f in failedJobs) listOf.Add(new Check { Id = nextCheck++, Name = f.Name, RunId = rid, App = f.App, Started = now, Status = "in_progress", CompleteAt = now.AddSeconds(rerunSeconds), Conclusion = rerunConclusion });
            // a code change whose first attempt failed: the Release workflow that the re-run's completion starts makes the release (it appears then)
            if (rerunConclusion == "success" && pendingRelease.Remove(rid, out var relSha))
                releases.Add(new Rel { Id = "Releases-" + (releases.Count + 1), Version = "2.4." + (100 + releases.Count), Notes = $"Build https://fake/run/{rid} of {relSha}", At = now.AddSeconds(rerunSeconds + 1), ProdDelay = prodDelay });
            return (201, null);
        }
        if ((m = Regex.Match(path, $"^{root}/releases/tags/(demo-\\d+)$")).Success && method == "GET")
            return ghReleases.TryGetValue(m.Groups[1].Value, out var gr) ? (200, GhRelJson(gr)) : (404, "{\"message\":\"Not Found\"}");
        if (path == root + "/releases" && method == "POST")
        {
            var tag = b?["tag_name"]?.ToString() ?? "";
            if (ghReleases.ContainsKey(tag)) return (422, "{\"message\":\"Validation Failed\",\"errors\":[{\"code\":\"already_exists\",\"field\":\"tag_name\"}]}");
            var nr = new GhRel { Id = nextGhRel++, Tag = tag, Name = b?["name"]?.ToString() ?? "", Body = b?["body"]?.ToString() ?? "", Target = b?["target_commitish"]?.ToString() ?? "", Prerelease = b?["prerelease"]?.GetValue<bool>() ?? false };
            ghReleases[tag] = nr; return (201, GhRelJson(nr));
        }
        if ((m = Regex.Match(path, $"^{root}/releases/assets/(\\d+)$")).Success && method == "DELETE")
        {
            var aid = long.Parse(m.Groups[1].Value);
            foreach (var r0 in ghReleases.Values) if (r0.Assets.RemoveAll(x => x.Id == aid) > 0) return (204, null);
            return (404, "{\"message\":\"Not Found\"}");
        }
        if (Regex.IsMatch(path, $"^{root}/compare/")) return (200, J(("status", "ahead")));
        return (404, "{\"message\":\"fake has no route " + method + " " + path + "\"}");
    }

    // GitHub releases of the demo videos (issue #42): create, read by tag, delete an asset, upload an asset on the uploads host
    readonly Dictionary<string, GhRel> ghReleases = new(); long nextGhRel = 1, nextGhAsset = 1;
    JsonObject GhRelJson(GhRel r) => J(("id", r.Id), ("tag_name", r.Tag), ("name", r.Name), ("body", r.Body), ("target_commitish", r.Target), ("prerelease", r.Prerelease), ("draft", false),
        ("html_url", $"https://github.com/{Owner}/{Repo}/releases/tag/{r.Tag}"),
        ("upload_url", $"http://127.0.0.1:{Environment.GetEnvironmentVariable("FAKE_PORT") ?? "5200"}/_uploads/repos/{Owner}/{Repo}/releases/{r.Id}/assets{{?name,label}}"),
        ("assets", new JsonArray(r.Assets.Select(x => (JsonNode)AssetJson(r, x)).ToArray())));
    JsonObject AssetJson(GhRel r, GhAsset x) => J(("id", x.Id), ("name", x.Name), ("size", x.Size), ("content_type", x.ContentType), ("browser_download_url", $"https://github.com/{Owner}/{Repo}/releases/download/{r.Tag}/{x.Name}"));
    public (int, string) UploadAsset(string path, string name, string contentType, long size, int port)
    {
        var m = Regex.Match(path, $"^/_uploads/repos/{Owner}/{Repo}/releases/(\\d+)/assets$");
        var r = m.Success ? ghReleases.Values.FirstOrDefault(x => x.Id == long.Parse(m.Groups[1].Value)) : null;
        if (r == null) return (404, "{\"message\":\"Not Found\"}");
        if (name == "" || r.Assets.Any(x => x.Name == name)) return (422, "{\"message\":\"Validation Failed\",\"errors\":[{\"code\":\"already_exists\",\"field\":\"name\"}]}");
        var a = new GhAsset { Id = nextGhAsset++, Name = name, Size = size, ContentType = contentType }; r.Assets.Add(a);
        log.Add($"POST {path}");
        return (201, AssetJson(r, a).ToJsonString());
    }

    Check? FindCheck(long id) => checks.Values.SelectMany(x => x).FirstOrDefault(c => c.Id == id);
    // whether commit `sha` has `ancestor` among its parents, their parents and so on (the commits written through git/commits)
    bool Descends(string sha, string ancestor)
    {
        var todo = new Stack<string>(); todo.Push(sha); var seen = new HashSet<string>();
        while (todo.Count > 0) { var c = todo.Pop(); if (!seen.Add(c) || !commits.TryGetValue(c, out var cm)) continue; foreach (var p in cm.Parents) { if (p == ancestor) return true; todo.Push(p); } }
        return false;
    }
    // the log of a job nobody wrote a log for: what a runner prints at the least
    static string DefaultLog(Check c) => $"{c.Started:yyyy-MM-ddTHH:mm:ss.fffffff}Z ##[group]Run {c.Name}\n{c.Started.AddSeconds(1):yyyy-MM-ddTHH:mm:ss.fffffff}Z ##[endgroup]\n"
        + (c.Conclusion == "failure" ? $"{c.Started.AddSeconds(2):yyyy-MM-ddTHH:mm:ss.fffffff}Z ##[error]Process completed with exit code 1.\n" : "");
    // GET compare/base...head. Two commits of the base branch: the files changed between them (ahead_by commits). The base branch against a pull
    // request's branch: behind_by is the pull request's Behind (what /_fake/master-merge and /_fake/pr set), ahead_by 1, and the pull request's files.
    (int, object?) Compare(string bas, string head)
    {
        var h = History();
        int bi = bas == Master ? h.Count - 1 : h.IndexOf(bas), hi = head == Master ? h.Count - 1 : h.IndexOf(head);
        if (bi >= 0 && hi >= 0)
        {
            var files = new List<string>(); for (int k = bi + 1; k <= hi; k++) if (masterFiles.TryGetValue(h[k], out var f)) foreach (var x in f) if (!files.Contains(x)) files.Add(x);
            return (200, J(("status", hi > bi ? "ahead" : hi < bi ? "behind" : "identical"), ("ahead_by", Math.Max(0, hi - bi)), ("behind_by", 0), ("files", new JsonArray(files.Select(x => (JsonNode)J(("filename", x))).ToArray()))));
        }
        var pr = prs.Values.Where(x => x.Ref == head).OrderByDescending(x => x.Open).FirstOrDefault();
        if (bi < 0 || (pr == null && !branches.ContainsKey(head))) return (200, J(("status", "ahead"), ("ahead_by", 1), ("behind_by", 0)));   // commits the fake does not track (the release scenarios)
        var behind = pr?.Behind ?? 0;
        return (200, J(("status", behind > 0 ? "diverged" : "ahead"), ("ahead_by", 1), ("behind_by", behind), ("files", new JsonArray((pr?.Files ?? branches[head].Files).Select(x => (JsonNode)J(("filename", x))).ToArray()))));
    }
    List<string> History() { if (masterHistory.Count == 0 || masterHistory[^1] != masterSha) masterHistory.Add(masterSha); return masterHistory; }

    JsonObject PrJson(Pr p, bool detail = false)
    {
        var o = J(("number", p.Number), ("title", p.Title), ("state", p.Open ? "open" : "closed"), ("html_url", $"https://fake/pull/{p.Number}"), ("merged", p.Merged), ("user", J(("login", p.Author))), ("body", p.Body), ("base", J(("ref", Master))),
            ("head", J(("ref", p.Ref), ("sha", p.Sha), ("repo", J(("full_name", p.Fork ? "someone-else/cmdemo1-workorders" : $"{Owner}/{Repo}"))))), ("draft", p.Draft), ("changed_files", p.Files.Count), ("merge_commit_sha", p.MergeSha));
        if (detail)
        {
            if (p.MergeableNullReads > 0) { p.MergeableNullReads--; o["mergeable"] = null; o["mergeable_state"] = "unknown"; }
            else { o["mergeable"] = !p.Conflict; o["mergeable_state"] = p.Conflict ? "dirty" : (p.Behind > 0 ? "behind" : "clean"); }
        }
        return o;
    }

    void ApplyProfile(Pr p, string sha)
    {
        var l = new List<Check>(); checks[sha] = l;
        var done = p.DelaySeconds > 0 ? (DateTime?)DateTime.UtcNow.AddSeconds(p.DelaySeconds) : null;
        string st = done is null ? "completed" : "in_progress";
        l.Add(new Check { Id = nextCheck++, Name = "Detect code changes" });
        l.Add(new Check { Id = nextCheck++, Name = "secret-scan", Status = st, CompleteAt = done, Conclusion = "success" });
        var build = new Check { Id = nextCheck++, Name = "Build result", Status = st, CompleteAt = done, Conclusion = p.Profile == "red" ? "failure" : "success" };
        if (p.Profile == "stuck") { build.Status = "in_progress"; build.CompleteAt = null; build.Conclusion = null; }
        l.Add(build);
    }

    (int, object?) Merge(Pr pr, JsonNode? b)
    {
        if (!pr.Open) return (405, "{\"message\":\"Pull Request is not open\"}");
        if (pr.Conflict) return (405, "{\"message\":\"Pull Request is not mergeable\"}");
        if (b?["sha"] is { } want && want.ToString() != pr.Sha) return (409, "{\"message\":\"Head branch was modified. Review and try the merge again.\"}");
        if (pr.Behind > 0) { pr.Behind--; return (409, "{\"message\":\"Head branch is out of date. Update the branch and try again.\"}"); }
        var cs = checks.TryGetValue(pr.Sha, out var l) ? l : new();
        foreach (var req in new[] { "Build result", "secret-scan" })
            if (!cs.Any(c => c.Name == req && c.Conclusion == "success" && (c.CompleteAt is null || DateTime.UtcNow >= c.CompleteAt) && c.Status == "completed"))
                return (405, "{\"message\":\"Required status check \\\"" + req + "\\\" is expected.\"}");
        pr.Merged = true; pr.Open = false; masterSha = NewSha(); pr.MergeSha = masterSha;
        var docs = DocsOnly(pr.Files);
        // the jobs of one Build workflow run share its run id; secret-scan is a workflow of its own
        var buildRun = nextRun++; var scanRun = nextRun++; runAttempts[buildRun] = 1; runAttempts[scanRun] = 1;
        var mc = new List<Check> { new() { Id = nextCheck++, Name = "Build result", RunId = buildRun, Status = masterHold ? "in_progress" : "completed", Conclusion = masterHold ? null : (masterRed ? "failure" : "success") }, new() { Id = nextCheck++, Name = "secret-scan", RunId = scanRun } };
        if (masterFlaky && !masterHold)
        {
            mc.Add(new Check { Id = nextCheck++, Name = "Acceptance Tests [shard 1/6]", RunId = buildRun, Conclusion = "failure" });
            mc[0].Status = "in_progress"; mc[0].CompleteAt = DateTime.UtcNow.AddSeconds(flakyRunSeconds); mc[0].Conclusion = "failure";
        }
        // masterArchitecture: the Architecture workflow (started by the Build's completion) fails on the merge commit
        if (masterArchitecture != null) mc.Add(new Check { Id = nextCheck++, Name = "architecture", RunId = nextRun++, Conclusion = masterArchitecture });
        // the Build's jobs that run only for a code change (build.yml's job "Detect code changes" skips them for documentation)
        mc.Add(new Check { Id = nextCheck++, Name = "Integration Build (SQL container)", RunId = buildRun, Conclusion = docs ? "skipped" : (masterRed ? "failure" : "success") });
        if (docs) { if (docsRelease != "absent") mc.Add(new Check { Id = nextCheck++, Name = "release", RunId = buildRun, Conclusion = "skipped" }); }
        else if (releaseMode != "none" && (masterRed || masterFlaky) && !masterHold)
        {   // as on GitHub: the Release workflow runs when the Build completes, and skips its jobs because the first attempt failed. Its check runs are
            // attached to master's head when it starts, so after a successful re-run the merge commit keeps that skipped release check, while the
            // release made by the second run of the Release workflow does carry the commit (Octopus, from the re-run's packages)
            mc.Add(new Check { Id = nextCheck++, Name = "release", RunId = nextRun++, Conclusion = "skipped" });
            pendingRelease[buildRun] = masterSha;
        }
        else if (releaseMode != "none")
        {
            mc.Add(new Check { Id = nextCheck++, Name = "release", RunId = buildRun });
            releases.Add(new Rel { Id = "Releases-" + (releases.Count + 1), Version = "2.4." + (100 + releases.Count), Notes = $"Build https://fake/run/1 of {masterSha}", At = DateTime.UtcNow, ProdDelay = prodDelay });
        }
        checks[masterSha] = mc; masterFiles[masterSha] = pr.Files.ToList();
        return (200, J(("merged", true), ("sha", masterSha), ("message", "Pull Request successfully merged")));
    }

    (int, object?) GraphQl(JsonNode b)
    {
        var q = b["query"]!.ToString(); var v = b["variables"] ?? new JsonObject();
        JsonObject Data(JsonNode n) => J(("data", n));
        if (q.Contains("updateProjectV2ItemFieldValue"))
        {
            var card = v["i"]!.ToString(); var opt = v["o"]!.ToString();
            var col = columns.First(c => "opt_" + c.Replace(' ', '_') == opt);
            var iss = issues.Values.FirstOrDefault(x => x.Card == card); if (iss == null) return (200, "{\"errors\":[{\"message\":\"card not found\"}]}");
            iss.Column = col; return (200, Data(J(("updateProjectV2ItemFieldValue", J(("projectV2Item", J(("id", card))))))));
        }
        if (q.Contains("addProjectV2ItemById"))
        {
            var node = v["c"]!.ToString(); var iss = issues.Values.First(x => x.Node == node); iss.Card ??= "card_" + iss.Number;
            return (200, Data(J(("addProjectV2ItemById", J(("item", J(("id", iss.Card))))))));
        }
        if (q.Contains("issue(number"))
        {
            var n = v["n"]!.GetValue<int>(); if (!issues.TryGetValue(n, out var i)) return (200, Data(J(("repository", J(("issue", null))))));
            var card = i.Card == null ? new JsonArray() : new JsonArray(J(("id", i.Card), ("project", J(("number", 679))), ("fieldValueByName", i.Column == null ? null : J(("name", i.Column)))));
            return (200, Data(J(("repository", J(("issue", J(("id", i.Node), ("number", i.Number), ("state", i.Open ? "OPEN" : "CLOSED"), ("title", i.Title), ("body", i.Body), ("url", $"https://fake/issues/{i.Number}"), ("createdAt", i.Created.ToString("o")),
                ("labels", J(("nodes", new JsonArray(i.Labels.Select(x => (JsonNode)J(("name", x))).ToArray())))), ("projectItems", J(("nodes", card))))))))));
        }
        if (q.Contains("items(first"))
        {
            var nodes = issues.Values.Where(i => i.Card != null).Select(i => (JsonNode)J(("id", i.Card), ("fieldValueByName", i.Column == null ? null : J(("name", i.Column))),
                ("content", J(("number", i.Number), ("state", i.Open ? "OPEN" : "CLOSED"), ("title", i.Title), ("body", i.Body), ("labels", J(("nodes", new JsonArray(i.Labels.Select(x => (JsonNode)J(("name", x))).ToArray())))))))).ToArray();
            return (200, Data(J(("organization", J(("projectV2", J(("items", J(("pageInfo", J(("hasNextPage", false), ("endCursor", null))), ("nodes", new JsonArray(nodes)))))))))));
        }
        if (q.Contains("fields(first"))
        {
            var opts = new JsonArray(columns.Select(c => (JsonNode)J(("id", "opt_" + c.Replace(' ', '_')), ("name", c))).ToArray());
            return (200, Data(J(("organization", J(("projectV2", J(("id", "PVT_fake"), ("fields", J(("nodes", new JsonArray(J(("id", "FIELD_status"), ("name", "Status"), ("options", opts)))))))))))));
        }
        return (200, "{\"errors\":[{\"message\":\"fake graphql: unrecognised query\"}]}");
    }

    (int, object?) Octopus(string path, Microsoft.AspNetCore.Http.IQueryCollection q)
    {
        if (path == "api/users/me") return (200, J(("Id", "Users-1")));
        if (Regex.IsMatch(path, @"^api/Spaces-355/projects/(cmdemo1-ui|Projects-1)$")) return (200, J(("Id", "Projects-1"), ("Name", "cmdemo1-ui")));
        var made = releases.Where(r => r.At <= DateTime.UtcNow).ToList();   // a release appears once the workflow that makes it has run
        if (path == "api/Spaces-355/projects/Projects-1/releases")
            return (200, J(("Items", new JsonArray(made.AsEnumerable().Reverse().Select(r => (JsonNode)J(("Id", r.Id), ("Version", r.Version), ("ReleaseNotes", r.Notes), ("Assembled", r.At.ToString("o")))).ToArray()))));
        if (path == "api/Spaces-355/environments") return (200, J(("Items", new JsonArray(J(("Id", "E-tdd"), ("Name", "tdd")), J(("Id", "E-uat"), ("Name", "uat")), J(("Id", "E-prod"), ("Name", "prod"))))));
        if (path == "api/Spaces-355/deployments")
        {
            var items = new JsonArray();
            foreach (var r in made) foreach (var (env, idx) in new[] { ("E-tdd", 0), ("E-uat", 1), ("E-prod", 2) })
                items.Add(J(("Id", $"Deployments-{r.Id}-{env}"), ("ReleaseId", r.Id), ("EnvironmentId", env), ("TaskId", $"{r.Id}|{env}"), ("Created", r.At.AddSeconds(idx).ToString("o"))));
            return (200, J(("Items", items)));
        }
        var m = Regex.Match(path, @"^api/Spaces-355/tasks/(.+)$");
        if (m.Success)
        {
            var parts = m.Groups[1].Value.Split('|'); var r = made.FirstOrDefault(x => x.Id == parts[0]);
            if (r == null) return (404, null);
            var due = parts[1] == "E-prod" ? r.At.AddSeconds(r.ProdDelay) : r.At;
            var done = DateTime.UtcNow >= due;
            return (200, J(("State", done ? "Success" : "Executing"), ("IsCompleted", done)));
        }
        return (404, null);
    }

    public int ProxyBackend;   // the gateway port the proxy forwards new connections to (FAKE_PROXY_PORT)
    // The rate limit of the caller's identity per resource (core, graphql), counted per request as GitHub does within its hourly window. The default
    // limit is far above what a suite spends, so nothing runs out unless a scenario says so with /_fake/rate { resource, remaining, resetSeconds, limit }.
    sealed class Rate { public int Limit = 1_000_000, Remaining = 1_000_000; public long Reset; }
    readonly Dictionary<string, Rate> rates = new();
    public (string, int, int, long, int)? RateFor(string path)
    {
        if (path.StartsWith("/_fake/") || path.StartsWith("/octopus/") || path.StartsWith("/_blob/") || path.StartsWith("/_uploads/") || path == "/_healthcheck") return null;
        var res = path == "/graphql" ? "graphql" : "core";
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (!rates.TryGetValue(res, out var r)) rates[res] = r = new Rate { Reset = now + 3600 };
        if (now >= r.Reset) { r.Remaining = r.Limit; r.Reset = now + 3600; }
        if (r.Remaining > 0) r.Remaining--;
        else return (res, r.Limit, 0, r.Reset, r.Limit);
        return (res, r.Limit, r.Remaining, r.Reset, r.Limit - r.Remaining);
    }
    int latencyMs; Regex? latencyMatch; int refPage; int rerunJobs;   // refPage 0: matching-refs does not page (GitHub)
    public int LatencyFor(string method, string path, string body) => latencyMs > 0 && !path.StartsWith("/_fake/") && latencyMatch!.IsMatch(method + " " + path + "\n" + body) ? latencyMs : 0;
    (int, object?) Control(string method, string what, Microsoft.AspNetCore.Http.IQueryCollection q, JsonNode? b)
    {
        switch (what)
        {
            case "latency":   // { ms, match }: every request whose "METHOD path" line plus body matches the regular expression waits ms first; ms 0 ends it
                latencyMs = b?["ms"]?.GetValue<int>() ?? 0; latencyMatch = latencyMs > 0 ? new Regex(b?["match"]?.ToString() ?? ".") : null; return (200, J(("ok", true)));
            case "proxy":   // { port }: new connections of the proxy (FAKE_PROXY_PORT) go to this port; 0 refuses them
                ProxyBackend = b?["port"]?.GetValue<int>() ?? 0; return (200, J(("ok", true), ("port", ProxyBackend)));
            case "rate":   // { resource (core), remaining, resetSeconds (3600), limit }: what is left of the rate limit; remaining 0 makes every request of it a 403
            {
                var res = b?["resource"]?.ToString() ?? "core"; var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                if (!rates.TryGetValue(res, out var r)) rates[res] = r = new Rate();
                if (b?["limit"] is { } lim) r.Limit = lim.GetValue<int>();
                r.Remaining = b?["remaining"]?.GetValue<int>() ?? r.Limit; r.Reset = now + (long)(b?["resetSeconds"]?.GetValue<double>() ?? 3600);
                return (200, J(("ok", true), ("resource", res), ("remaining", r.Remaining), ("reset", r.Reset)));
            }
            case "ref-page":   // { size }: matching-refs pages, with at most size refs a page (1 to 100); size 0 or none: it does not page, as GitHub
                refPage = Math.Clamp(b?["size"]?.GetValue<int>() ?? 0, 0, 100); return (200, J(("ok", true)));
            case "arm": return (200, ArmState());
            case "cursor": return (200, CursorState());
            case "cursor-reset": cursorAgents.Clear(); cursorLaunchFailures = 0; return (200, J(("ok", true)));
            case "cursor-add":   // an agent this gateway did not launch in this process: {"name"}
            {
                var a = new CursorAgent { Id = "bc-" + (++cursorSeq).ToString("x8"), RunId = "run-" + cursorSeq.ToString("x8"), Body = J(("name", b?["name"]?.ToString() ?? "")), Created = DateTime.UtcNow.AddMinutes(-(b?["ageMinutes"]?.GetValue<double>() ?? 0)) };
                cursorAgents.Add(a); return (200, J(("ok", true), ("id", a.Id)));
            }
            case "cursor-launch-failures": cursorLaunchFailures = b?["count"]?.GetValue<int>() ?? 1; return (200, J(("ok", true)));
            case "cursor-agent":
            {   // sets an agent's state as Cursor would: {"id", "status": ACTIVE | IDLE | ARCHIVED, "run": RUNNING | FINISHED | ERROR}
                var a = cursorAgents.LastOrDefault(x => x.Id == b?["id"]?.ToString()); if (a == null) return (404, J(("ok", false)));
                if (b?["status"] is { } st) a.Status = st.ToString(); if (b?["run"] is { } rs) a.RunStatus = rs.ToString();
                return (200, J(("ok", true)));
            }
            case "arm-reset": armExecs.Clear(); armStarts = 0; armStops = 0; armStartFailures = 0; return (200, J(("ok", true)));
            case "arm-start-failures": armStartFailures = b?["count"]?.GetValue<int>() ?? 1; return (200, J(("ok", true)));
            case "arm-exec":
            {   // ends an execution as the platform would: {"worker" or "name", "status": Succeeded | Failed | Stopped}
                var e = armExecs.LastOrDefault(x => x.Name == b?["name"]?.ToString() || (b?["worker"] != null && EnvOf(x, "FWORKER_NAME") == b["worker"]!.ToString()));
                if (e == null) return (404, J(("ok", false)));
                e.Status = b!["status"]!.ToString(); if (e.Status is not ("Running" or "Processing")) e.End = DateTime.UtcNow;
                return (200, J(("ok", true), ("name", e.Name)));
            }
            case "reset":
                latencyMs = 0; latencyMatch = null; refPage = 0; rerunJobs = 0; rates.Clear();
                artifacts.Clear(); masterHistory.Clear(); masterFiles.Clear(); issues.Clear(); prs.Clear(); checks.Clear(); refs.Clear(); refSha.Clear(); commits.Clear(); branches.Clear(); faults.Clear(); releases.Clear(); ghReleases.Clear(); log.Clear(); scopedMints.Clear();
                masterSha = Sha("master0"); healthStatus = 200; masterRed = false; prodDelay = 0; releaseMode = "auto"; docsRelease = "skipped"; masterHold = false;
                masterFlaky = false; flakyRunSeconds = 4; rerunSeconds = 3; rerunConclusion = "success"; runAttempts.Clear(); pendingRelease.Clear(); masterArchitecture = null; rerunRefusals = 0; reruns = 0; return (200, J(("ok", true)));
            case "issue":
            {
                var i = new Issue { Number = nextNumber++, Title = b!["title"]!.ToString(), Body = b["body"]?.ToString() ?? "", Column = b["column"]?.ToString() };
                if (b["createdAt"] is { } ca) i.Created = DateTime.Parse(ca.ToString(), null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);   // an item of an earlier date
                i.Node = "I_" + i.Number; foreach (var l in b["labels"]?.AsArray() ?? new JsonArray()) i.Labels.Add(l!.ToString());
                issues[i.Number] = i; if (i.Column != null || b["onBoard"]?.GetValue<bool>() == true) i.Card = "card_" + i.Number;
                return (200, J(("number", i.Number)));
            }
            case "move":
            {   // { number, column }: a person moves the card (null: no column); an issue without a card gets one
                var i = issues[b!["number"]!.GetValue<int>()]; i.Column = b["column"]?.ToString(); i.Card ??= "card_" + i.Number;
                return (200, J(("ok", true)));
            }
            case "push-branch":
            {
                var br = b!["branch"]!.ToString(); var objs = new List<JsonObject>();
                foreach (var x in b["files"]!.AsArray())
                {
                    if (x is JsonValue) objs.Add(J(("filename", x.ToString()), ("additions", 3), ("deletions", 0), ("status", "added"), ("patch", "@@ -0,0 +1,3 @@\n+content")));
                    else { var o = x!.AsObject(); objs.Add(J(("filename", o["name"]!.ToString()), ("additions", o["additions"]?.GetValue<int>() ?? 3), ("deletions", o["deletions"]?.GetValue<int>() ?? 0), ("status", o["status"]?.ToString() ?? "added"), ("patch", o["patch"]?.ToString() ?? "@@ -0,0 +1,3 @@\n+content"))); }
                }
                var files = objs.Select(o => o["filename"]!.ToString()).ToList();
                var sha = NewSha(); branches[br] = (sha, files, objs);
                { var prev = prs.Values.FirstOrDefault(x => x.Ref == br && x.Open); parents[sha] = b["parents"] is JsonArray hp ? hp.Select(x => x!.ToString() == "base" ? History()[^1] : x.ToString() == "head" ? (prev?.Sha ?? History()[^1]) : x.ToString()).ToList() : new() { prev?.Sha ?? History()[^1] }; }
                var existing = prs.Values.FirstOrDefault(x => x.Ref == br && x.Open);
                var prof = b["profile"]?.ToString() ?? "green"; var dly = b["delaySeconds"]?.GetValue<double>() ?? 0; branchProfile[br] = (prof, dly);
                if (existing != null) { existing.Sha = sha; existing.Files = files; existing.FileObjs = objs; existing.Profile = prof; existing.DelaySeconds = dly; ApplyProfile(existing, sha); }
                return (200, J(("sha", sha)));
            }
            case "pr":
            {
                var pr = prs[b!["number"]!.GetValue<int>()];
                if (b["profile"] != null) { pr.Profile = b["profile"]!.ToString(); ApplyProfile(pr, pr.Sha); }
                if (b["behind"] != null) pr.Behind = b["behind"]!.GetValue<int>();
                if (b["author"] != null) pr.Author = b["author"]!.ToString();
                if (b["open"] != null) pr.Open = b["open"]!.GetValue<bool>();
                if (b["fork"] != null) pr.Fork = b["fork"]!.GetValue<bool>();
                if (b["draft"] != null) pr.Draft = b["draft"]!.GetValue<bool>();
                if (b["merged"] != null) { pr.Merged = b["merged"]!.GetValue<bool>(); if (pr.Merged) { pr.Open = false; pr.MergeSha ??= NewSha(); } }
                if (b["updateNoop"] != null) pr.UpdateNoop = b["updateNoop"]!.GetValue<bool>();
                if (b["conflict"] != null) pr.Conflict = b["conflict"]!.GetValue<bool>();
                if (b["mergeableNullReads"] != null) pr.MergeableNullReads = b["mergeableNullReads"]!.GetValue<int>();
                if (b["delaySeconds"] != null) { pr.DelaySeconds = b["delaySeconds"]!.GetValue<double>(); ApplyProfile(pr, pr.Sha); }
                return (200, J(("ok", true)));
            }
            case "master-merge":
            {   // { files, ref }: a pull request of someone else is merged into the base branch: a closed merged pull request with those files, a new
                // head of the base branch, and every open pull request one commit further behind (as GitHub, they are not changed; their branch is behind)
                History();
                // { number }: that open pull request is the one merged (its files)
                if (b?["number"] is { } mn && prs.TryGetValue(mn.GetValue<int>(), out var own))
                {
                    own.Merged = true; own.Open = false; masterSha = NewSha(); own.MergeSha = masterSha; History(); masterFiles[masterSha] = own.Files.ToList();
                    checks[masterSha] = new List<Check> { new() { Id = nextCheck++, Name = "Build result" }, new() { Id = nextCheck++, Name = "secret-scan" } };
                    foreach (var o in prs.Values.Where(x => x.Open)) o.Behind++;
                    return (200, J(("number", own.Number), ("sha", masterSha), ("ref", own.Ref)));
                }
                var files = (b?["files"]?.AsArray() ?? new JsonArray()).Select(x => x!.ToString()).ToList();
                var pr = new Pr { Number = nextNumber++, Ref = b?["ref"]?.ToString() ?? $"someone/change-{nextNumber}", Open = false, Merged = true, Files = files, FileObjs = files.Select(f => J(("filename", f), ("additions", 1), ("deletions", 0), ("status", "modified"))).ToList(), Author = "a-person" };
                masterSha = NewSha(); pr.MergeSha = masterSha; pr.Sha = NewSha(); prs[pr.Number] = pr; History(); masterFiles[masterSha] = files;
                checks[masterSha] = new List<Check> { new() { Id = nextCheck++, Name = "Build result" }, new() { Id = nextCheck++, Name = "secret-scan" } };
                foreach (var o in prs.Values.Where(x => x.Open)) o.Behind++;
                return (200, J(("number", pr.Number), ("sha", masterSha), ("ref", pr.Ref)));
            }
            case "review-state":
            {   // a dismissed review: every review of the PR by that user takes the given state (default DISMISSED)
                var pr = prs[b!["number"]!.GetValue<int>()];
                foreach (var r in pr.Reviews.Where(r => b["user"] == null || r.User == b["user"]!.ToString())) r.State = b["state"]?.ToString() ?? "DISMISSED";
                return (200, J(("ok", true)));
            }
            case "checks":
            {
                var sha = b!["sha"]!.ToString(); var l = checks.TryGetValue(sha, out var x) ? x : (checks[sha] = new());
                var c = l.FirstOrDefault(y => y.Name == b["name"]!.ToString()); if (c == null) { c = new Check { Id = nextCheck++, Name = b["name"]!.ToString() }; l.Add(c); }
                c.Status = b["status"]?.ToString() ?? "completed"; c.Conclusion = b["conclusion"]?.ToString(); c.CompleteAt = null;
                // why it failed: app (default github-actions), outputTitle, outputSummary, annotations [{ path, start_line, end_line, annotation_level, message, title }],
                // steps [{ name, number, conclusion, started_at, completed_at }], log (the text of the job log) or logLines { count, prefix } for a long one, runId
                if (b["app"] != null) c.App = b["app"]!.ToString();
                if (b["outputTitle"] != null) c.OutputTitle = b["outputTitle"]!.ToString();
                if (b["outputSummary"] != null) c.OutputSummary = b["outputSummary"]!.ToString();
                if (b["annotations"] is JsonArray ans) c.Annotations = ans.Select(o => (JsonObject)JsonNode.Parse(o!.ToJsonString())!).ToList();
                if (b["steps"] is JsonArray sts) c.Steps = sts.Select(o => { var so = (JsonObject)JsonNode.Parse(o!.ToJsonString())!; so["status"] ??= "completed"; return so; }).ToList();
                if (b["log"] != null) c.Log = b["log"]!.ToString();
                if (b["logLines"] is JsonObject ll)
                {   // count lines "<time> <prefix> <number>", one a millisecond from the start of the check
                    var sbl = new System.Text.StringBuilder(); int cnt = ll["count"]!.GetValue<int>(); var pre = ll["prefix"]?.ToString() ?? "line";
                    for (int k = 1; k <= cnt; k++) sbl.Append(c.Started.AddMilliseconds(k).ToString("yyyy-MM-ddTHH:mm:ss.fffffff")).Append("Z ").Append(pre).Append(' ').Append(k).Append('\n');
                    c.Log = sbl.ToString() + (ll["end"]?.ToString() ?? "");
                }
                if (b["runId"] != null) c.RunId = b["runId"]!.GetValue<long>();
                return (200, J(("ok", true), ("id", c.Id), ("started", c.Started.ToString("o"))));
            }
            case "artifact":
            {   // { runId, name, files { path: text }, binary { path: base64 }, sizeBytes (what the listing claims), expired }: an artifact of a workflow run
                using var ms = new MemoryStream();
                using (var zip = new System.IO.Compression.ZipArchive(ms, System.IO.Compression.ZipArchiveMode.Create, true))
                {
                    foreach (var kv in b!["files"]?.AsObject() ?? new JsonObject()) { using var w = new StreamWriter(zip.CreateEntry(kv.Key).Open()); w.Write(kv.Value!.ToString()); }
                    foreach (var kv in b["binary"]?.AsObject() ?? new JsonObject()) { using var e = zip.CreateEntry(kv.Key).Open(); var bytes = Convert.FromBase64String(kv.Value!.ToString()); e.Write(bytes, 0, bytes.Length); }
                }
                var art = new Artifact { Id = nextArtifact++, RunId = b["runId"]?.GetValue<long>() ?? 1, Name = b["name"]!.ToString(), Expired = b["expired"]?.GetValue<bool>() ?? false, Size = b["sizeBytes"]?.GetValue<long>(), Zip = ms.ToArray() };
                artifacts.Add(art); return (200, J(("ok", true), ("id", art.Id)));
            }
            case "base-history":
            {   // { name, conclusions [newest first; null = the check did not run on that commit] }: the same check on the last commits of the base branch
                var cons = b!["conclusions"]!.AsArray(); var h = History();
                while (h.Count < cons.Count) h.Insert(0, NewSha());
                for (int k = 0; k < cons.Count; k++)
                {
                    var sha = h[h.Count - 1 - k]; var l = checks.TryGetValue(sha, out var x) ? x : (checks[sha] = new());
                    l.RemoveAll(y => y.Name == b["name"]!.ToString());
                    if (cons[k] != null) l.Add(new Check { Id = nextCheck++, Name = b["name"]!.ToString(), Conclusion = cons[k]!.ToString(), App = b["app"]?.ToString() ?? "github-actions" });
                }
                return (200, J(("ok", true)));
            }
            case "config":
                if (b?["masterRed"] != null) masterRed = b["masterRed"]!.GetValue<bool>();
                if (b?["prodDelaySeconds"] != null) prodDelay = b["prodDelaySeconds"]!.GetValue<double>();
                if (b?["releaseMode"] != null) releaseMode = b["releaseMode"]!.ToString();
                if (b?["docsRelease"] != null) docsRelease = b["docsRelease"]!.ToString();
                if (b?["masterHold"] != null) masterHold = b["masterHold"]!.GetValue<bool>();
                if (b?["masterArchitecture"] != null) masterArchitecture = b["masterArchitecture"]!.ToString();
                if (b?["masterFlaky"] != null) masterFlaky = b["masterFlaky"]!.GetValue<bool>();
                if (b?["flakyRunSeconds"] != null) flakyRunSeconds = b["flakyRunSeconds"]!.GetValue<double>();
                if (b?["rerunSeconds"] != null) rerunSeconds = b["rerunSeconds"]!.GetValue<double>();
                if (b?["rerunConclusion"] != null) rerunConclusion = b["rerunConclusion"]!.ToString();
                return (200, J(("ok", true)));
            case "fault":
                faults.Add(new Fault { Match = new Regex(b!["match"]!.ToString()), Status = b["status"]!.GetValue<int>(), Remaining = b["count"]?.GetValue<int>() ?? 1, Body = b["body"]?.ToString() ?? "{\"message\":\"injected fault\"}" });
                return (200, J(("ok", true)));
            case "state":
                return (200, J(
                    ("issues", new JsonArray(issues.Values.Select(i => (JsonNode)J(("number", i.Number), ("title", i.Title), ("body", i.Body), ("open", i.Open), ("column", i.Column), ("labels", new JsonArray(i.Labels.Select(x => (JsonNode)x).ToArray())),
                        ("comments", new JsonArray(i.Comments.Select(c => (JsonNode)J(("id", c.Id), ("body", c.Body))).ToArray())))).ToArray())),
                    ("appMints", appMints), ("scopedMints", new JsonArray(scopedMints.Select(x => (JsonNode)x).ToArray())), ("reruns", reruns), ("rerunRefusals", rerunRefusals), ("prs", new JsonArray(prs.Values.Select(p => (JsonNode)J(("number", p.Number), ("ref", p.Ref), ("body", p.Body), ("sha", p.Sha), ("open", p.Open), ("merged", p.Merged), ("mergeSha", p.MergeSha), ("comments", new JsonArray(p.Comments.Select(c => (JsonNode)J(("id", c.Id), ("body", c.Body))).ToArray())), ("reviews", new JsonArray(p.Reviews.Select(r => (JsonNode)J(("user", r.User), ("state", r.State), ("commit", r.Commit))).ToArray())), ("files", new JsonArray(p.Files.Select(f => (JsonNode)f).ToArray())))).ToArray())),
                    ("refs", new JsonArray(refs.Select(r => (JsonNode)r).ToArray())), ("masterSha", masterSha), ("rerunJobs", rerunJobs), ("releases", releases.Count), ("requests", log.Count)));
            case "health": healthStatus = b?["status"]?.GetValue<int>() ?? 200; return (200, J(("ok", true)));
            case "log": return (200, new JsonArray(log.Select(l => (JsonNode)l).ToArray()));
        }
        return (404, "{\"message\":\"unknown control\"}");
    }
}
