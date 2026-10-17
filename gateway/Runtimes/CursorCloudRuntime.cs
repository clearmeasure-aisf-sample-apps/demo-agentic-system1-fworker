using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

// The api launch mode, v1: Cursor Cloud Agents (docs/design/agents-roles-launch.md 10). One agent per worker: POST /v1/agents with the bootstrap
// prompt, the work-orders repository at the phase's starting branch, autoCreatePR false (the gateway's pr_open opens the pull request) and one MCP
// server, the gateway's public /mcp, with the worker's r1 in its Authorization header. The run is followed with GET /v1/agents/{id}; the agent
// is cancelled and deleted at session_end, at the deadline (api.cursor.maxMinutes) and on revoke, so the r1 Cursor stored goes with it.
// The API key (CURSOR_API_KEY; api.cursor.apiKey only for a local gateway, never in a committed file) never leaves this class; nothing here
// logs a request body. A process start deletes the fworker-* agents a former process left (their workers went with it).
sealed class CursorCloudSettings
{
    public bool Enabled;
    public int MaxConcurrent = 1, MaxExecutionsPerDay = 10, MaxFailuresPerPhase = 2, UnhealthyAfterFailures = 2;
    public double MaxMinutes = 60;
    public double AckSeconds = 900, ListSeconds = 30, IdleGraceSeconds = 60;
    // Model "auto": Cursor's Auto model (owner decision 2026-10-17, cost first); the adapter resolves it against GET /v1/models once and never
    // falls back to the account's default (which may be a premium model): a launch with a model Cursor refuses fails visibly instead
    public string Environment = "tdd", OptimizeFor = "cost";
    public string ApiUrl = "https://api.cursor.com", ApiKey = "", GatewayUrl = "", Model = "auto",
        Repository = "https://github.com/clearmeasure-aisf-sample-apps/demo-agentic-system1-workorders", DefaultBranch = "master";
    public bool On => Enabled && MaxConcurrent > 0 && ApiKey != "" && GatewayUrl != "";

    // api.cursor of the instance configuration, then the variables of the gateway app: CURSOR_API_KEY (the key), FACTORY_CURSOR_ENABLED,
    // FACTORY_CURSOR_GATEWAY_URL (default FACTORY_PUBLIC_URL), FACTORY_CURSOR_MAX_CONCURRENT, FACTORY_CURSOR_MAX_MINUTES.
    public static CursorCloudSettings Load(string scriptsDir, Func<string, string?> get)
    {
        var s = new CursorCloudSettings();
        var path = get("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? root = null; try { root = JsonNode.Parse(File.ReadAllText(path)); } catch { }
        var c = root?["api"]?["cursor"];
        if (c is JsonObject)
        {
            static bool Num(string? t, out double v) => double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && double.IsFinite(v) && v >= 0;
            double D(string k, double d) => Num(c[k]?.ToString(), out var v) ? v : d;
            string S(string k, string d) => c[k] is JsonValue sv && sv.TryGetValue<string>(out var str) ? str : d;
            s.Enabled = c["enabled"] is JsonValue ev && ev.TryGetValue<bool>(out var eb) && eb;
            s.MaxConcurrent = (int)D("maxConcurrent", 1); s.MaxExecutionsPerDay = (int)D("maxExecutionsPerDay", 10); s.MaxMinutes = Math.Max(0.1, D("maxMinutes", 60));
            s.MaxFailuresPerPhase = Math.Max(1, (int)D("maxFailuresPerPhase", 2)); s.UnhealthyAfterFailures = Math.Max(1, (int)D("unhealthyAfterFailures", 2));
            s.AckSeconds = D("ackSeconds", 900); s.ListSeconds = Math.Max(1, D("listSeconds", 30)); s.IdleGraceSeconds = D("idleGraceSeconds", 60);
            s.ApiUrl = S("apiUrl", s.ApiUrl).TrimEnd('/'); s.ApiKey = S("apiKey", ""); s.GatewayUrl = S("gatewayUrl", "").TrimEnd('/'); s.Model = S("model", "auto").Trim(); if (s.Model == "") s.Model = "auto";
            var of = S("optimizeFor", "cost"); s.OptimizeFor = of is "cost" or "balanced" or "intelligence" ? of : "cost";
            s.Repository = S("repository", s.Repository); s.DefaultBranch = S("defaultBranch", s.DefaultBranch);
        }
        string? V(string n) => get(n) is { } v && v.Trim() != "" ? v.Trim() : null;
        s.Environment = (V("FACTORY_ENVIRONMENT") ?? "tdd").ToLowerInvariant();
        // api.cursor.environments: when it names any, the mode is on only in those, each with its gateway's public URL (one image runs everywhere)
        if (c?["environments"] is JsonObject { Count: > 0 } envs)
        {
            if (envs[s.Environment] is JsonObject me) { if (me["gatewayUrl"] is JsonValue gv && gv.TryGetValue<string>(out var g) && g != "") s.GatewayUrl = g.TrimEnd('/'); }
            else s.Enabled = false;
        }
        if (V("CURSOR_API_KEY") is { } key) s.ApiKey = key;
        if (bool.TryParse(V("FACTORY_CURSOR_ENABLED"), out var en)) s.Enabled = en;
        if (s.GatewayUrl == "") s.GatewayUrl = (V("FACTORY_CURSOR_GATEWAY_URL") ?? V("FACTORY_PUBLIC_URL") ?? "").TrimEnd('/');
        else if (V("FACTORY_CURSOR_GATEWAY_URL") is { } gu) s.GatewayUrl = gu.TrimEnd('/');
        if (int.TryParse(V("FACTORY_CURSOR_MAX_CONCURRENT"), NumberStyles.None, CultureInfo.InvariantCulture, out var mc)) s.MaxConcurrent = mc;
        if (double.TryParse(V("FACTORY_CURSOR_MAX_MINUTES"), NumberStyles.Float, CultureInfo.InvariantCulture, out var mm) && double.IsFinite(mm) && mm > 0) s.MaxMinutes = mm;
        return s;
    }

    public RuntimeLimits Limits(Func<string, int, string, long, string> mint) => new()
    {
        Kind = "cursor-cloud", Prefix = "cur", IsOn = () => On, MaxConcurrent = MaxConcurrent, MaxExecutionsPerDay = MaxExecutionsPerDay, AckSeconds = AckSeconds,
        MaxFailuresPerPhase = MaxFailuresPerPhase, UnhealthyAfterFailures = UnhealthyAfterFailures, ListSeconds = ListSeconds,
        // the r1 expires 15 minutes after the deadline (agents-roles-launch.md 4)
        TokenSeconds = (long)(MaxMinutes * 60) + 900, MintCredential = mint, RevokeOnEnd = true
    };
}

sealed class CursorCloudRuntime : IWorkerRuntime, IRuntimeDetail
{
    sealed class Agent { public string Id = "", RunId = "", Worker = "", Phase = ""; public int Item; public DateTime Started = DateTime.UtcNow; public string Status = "Running"; public DateTime? Ended, IdleSince; public bool Deleted, ModelLogged; public JsonNode? Model, ReportedModel, Usage; }

    readonly CursorCloudSettings cfg;
    readonly HttpClient http;
    readonly Func<int, string, string> prompt;   // item, phase -> the bootstrap text
    readonly Dictionary<string, Agent> agents = new(StringComparer.Ordinal);   // by worker name
    bool swept;   // the agents a former process left behind were looked for (first List)
    JsonObject? model;   // the resolved model selection (Model "auto" resolved against GET /v1/models)
    // agent names carry the environment, so a key shared by two gateways never lets one delete the other's agents
    string Prefix => $"fworker-{cfg.Environment}-";

    public CursorCloudRuntime(CursorCloudSettings cfg, Func<int, string, string> prompt, HttpClient? http = null)
    { this.cfg = cfg; this.prompt = prompt; this.http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(60) }; }

    public string Kind => "cursor-cloud";

    public JsonObject? Detail(string workerName)
    {
        lock (agents)
            return agents.TryGetValue(workerName, out var a) ? new JsonObject { ["agent"] = a.Id, ["model"] = a.Model?.DeepClone(), ["reportedModel"] = a.ReportedModel?.DeepClone(), ["usage"] = a.Usage?.DeepClone(), ["deleted"] = a.Deleted } : null;
    }
    double IdleGraceSeconds => cfg.IdleGraceSeconds;
    public int MaxConcurrent => cfg.MaxConcurrent;

    async Task<(int Status, JsonNode? Body)> Send(HttpMethod m, string path, JsonNode? body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(m, cfg.ApiUrl + path);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", cfg.ApiKey);
        if (body != null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var resp = await http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        JsonNode? j = null; try { if (text.Length > 0) j = JsonNode.Parse(text); } catch { }
        return ((int)resp.StatusCode, j);
    }

    // The branch an agent starts on: the default branch for Technical Design and a first Development pass (the agent creates
    // factory-worker/N-development), the item's branch for Functional Testing.
    string StartingRef(int item, string phase) => phase.Equals("Functional Testing", StringComparison.OrdinalIgnoreCase) ? $"factory-worker/{item}-development" : cfg.DefaultBranch;

    public JsonObject LaunchBody(ProvisionRequest r) => new()
    {
        ["name"] = Prefix + r.WorkerName,
        ["prompt"] = new JsonObject { ["text"] = prompt(r.Item, r.Phase) },
        ["repos"] = new JsonArray(new JsonObject { ["url"] = cfg.Repository, ["startingRef"] = StartingRef(r.Item, r.Phase) }),
        ["autoCreatePR"] = false,
        ["mcpServers"] = new JsonArray(new JsonObject
        {
            ["name"] = "fworker", ["type"] = "http", ["url"] = cfg.GatewayUrl + "/mcp",
            ["headers"] = new JsonObject { ["Authorization"] = "Bearer " + r.Nonce }
        })
    };

    public async Task<ProvisionResult> Provision(ProvisionRequest r, CancellationToken ct)
    {
        var body = LaunchBody(r);
        JsonObject? sel; try { sel = await Model(ct); } catch (Exception e) { return new(false, "", "models-" + e.GetType().Name); }
        if (sel == null) return new(false, "", "model-unavailable");
        body["model"] = sel;
        int s; JsonNode? j;
        try { (s, j) = await Send(HttpMethod.Post, "/v1/agents", body, ct); }
        catch (Exception e) { await DeleteNamed(Prefix + r.WorkerName, ct); return new(false, "", "launch-" + e.GetType().Name); }
        var id = j?["agent"]?["id"]?.ToString() ?? j?["id"]?.ToString() ?? "";
        // a launch that failed may still have created the agent (a timeout, an odd answer): it is looked up by its name and deleted
        if (s is not (200 or 201) || id == "") { await DeleteNamed(Prefix + r.WorkerName, ct); return new(false, "", s is 200 or 201 ? "launch-no-id" : $"launch-{s}"); }
        lock (agents) agents[r.WorkerName] = new Agent { Model = sel.DeepClone(), Id = id, RunId = j?["run"]?["id"]?.ToString() ?? j?["agent"]?["latestRunId"]?.ToString() ?? "", Worker = r.WorkerName, Item = r.Item, Phase = r.Phase };
        return new(true, id, "");
    }

    // cancel the run, then delete the agent (its stored MCP configuration and the r1 in it go with it); idempotent, and retried by List until done
    public async Task Deprovision(string workerName, string reason, CancellationToken ct)
    {
        Agent? a; lock (agents) agents.TryGetValue(workerName, out a);
        if (a == null || a.Deleted) return;
        string id, run; lock (agents) { id = a.Id; run = a.RunId; }
        if (run != "") { try { await Send(HttpMethod.Post, $"/v1/agents/{Uri.EscapeDataString(id)}/runs/{Uri.EscapeDataString(run)}/cancel", null, ct); } catch { } }
        var (s, _) = await Send(HttpMethod.Delete, $"/v1/agents/{Uri.EscapeDataString(id)}", null, ct);
        if (s is not (200 or 202 or 204 or 404)) throw new HttpRequestException($"delete of agent answered {s}");
        await LogUsage(a, ct);   // before the end is visible to the manager, so its record of the end carries the usage
        lock (agents) { a.Deleted = true; a.Ended ??= DateTime.UtcNow; if (a.Status == "Running") a.Status = "Stopped"; }
    }

    // The model of a launch (owner decision 2026-10-17: Auto with the cost preference). Model "auto" is resolved against GET /v1/models once per
    // process: the Cursor Router "auto-smart" with params [{id: optimize_for, value: cost}] where the catalog offers it (Cursor SDK docs,
    // cursor.com/docs/sdk/python: "Always pass optimize_for"), else the plain "auto" (which carries no cost preference). Never the account's
    // default: with neither in the catalog the launch is refused (model-unavailable) rather than run on a model nobody chose.
    async Task<JsonObject?> Model(CancellationToken ct)
    {
        if (model != null) return (JsonObject)model.DeepClone();
        if (!cfg.Model.Equals("auto", StringComparison.OrdinalIgnoreCase)) return (JsonObject)(model = new JsonObject { ["id"] = cfg.Model }).DeepClone();
        var (s, j) = await Send(HttpMethod.Get, "/v1/models", null, ct);
        var arr = (j?["items"] ?? j?["models"] ?? j?["data"] ?? j) as JsonArray ?? new JsonArray();
        var ids = arr.Select(x => x is JsonValue ? x.ToString() : x?["id"]?.ToString() ?? "").Where(x => x != "").ToList();
        Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["runtime"] = "cursor-models", ["status"] = s, ["ids"] = new JsonArray(ids.Take(80).Select(x => (JsonNode)x).ToArray()) }.ToJsonString());
        if (s != 200) return null;
        if (ids.Contains("auto-smart"))
            model = new JsonObject { ["id"] = "auto-smart", ["params"] = new JsonArray(new JsonObject { ["id"] = "optimize_for", ["value"] = cfg.OptimizeFor }) };
        else if (ids.Contains("auto")) model = new JsonObject { ["id"] = "auto" };
        else return null;
        return (JsonObject)model.DeepClone();
    }

    // the agents of this environment at Cursor (GET /v1/agents, every page), as (id, name); throws when a page cannot be read
    async Task<List<(string Id, string Name, DateTime? Created)>> Remote(CancellationToken ct)
    {
        var all = new List<(string, string, DateTime?)>(); string? next = null;
        for (var page = 0; page < 20; page++)
        {
            var (s, j) = await Send(HttpMethod.Get, "/v1/agents?limit=100" + (next != null ? "&cursor=" + Uri.EscapeDataString(next) : ""), null, ct);
            if (s != 200) throw new HttpRequestException($"list of agents answered {s}");
            var arr = (j?["items"] ?? j?["agents"] ?? j?["data"]) as JsonArray ?? new JsonArray();
            all.AddRange(arr.Select(x => (x?["id"]?.ToString() ?? "", x?["name"]?.ToString() ?? "",
                DateTime.TryParse(x?["createdAt"]?.ToString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var cd) ? cd : (DateTime?)null)).Where(x => x.Item1 != ""));
            next = j?["nextCursor"]?.ToString(); if (string.IsNullOrEmpty(next)) break;
        }
        return all;
    }

    // the tokens an agent used (GET /v1/agents/{id}/usage), logged when it ends, for the cycle metrics
    async Task LogUsage(Agent a, CancellationToken ct)
    {
        try
        {
            var (s, j) = await Send(HttpMethod.Get, $"/v1/agents/{Uri.EscapeDataString(a.Id)}/usage", null, ct);
            if (s == 200) lock (agents) a.Usage = j?["totalUsage"]?.DeepClone();
            if (s == 200) Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["runtime"] = "cursor-usage", ["worker"] = a.Worker, ["item"] = a.Item, ["phase"] = a.Phase, ["agent"] = a.Id,
                ["minutes"] = Math.Round((DateTime.UtcNow - a.Started).TotalMinutes, 1), ["usage"] = j?["totalUsage"]?.DeepClone() }.ToJsonString());
        }
        catch { }
    }

    async Task DeleteNamed(string name, CancellationToken ct)
    {
        try { foreach (var (id, n, _) in await Remote(ct)) if (n == name) await Send(HttpMethod.Delete, $"/v1/agents/{Uri.EscapeDataString(id)}", null, ct); }
        catch (Exception e) { Console.Error.WriteLine($"cursor: cleanup of {name}: {e.GetType().Name}"); }
    }

    // The agents this process started, with Container Apps job states: ACTIVE is Running; IDLE (its turn ended), ARCHIVED or a deleted agent
    // ended; a run in ERROR or EXPIRED failed. An agent past its deadline is cancelled and deleted here and reported Failed.
    public async Task<IReadOnlyList<RuntimeInstance>> List(CancellationToken ct)
    {
        // a former process's agents (fworker-<environment>-* names this process does not track) are deleted: their workers are gone with that process
        if (!swept)
        {
            try
            {
                HashSet<string> mine; lock (agents) mine = agents.Values.Select(x => x.Id).ToHashSet();
                // only agents past any deadline: during a revision rollover the former process still runs its live ones, and ends them itself
                var stale = DateTime.UtcNow.AddMinutes(-(cfg.MaxMinutes + 15));
                foreach (var (id, n, created) in await Remote(ct))
                    if (n.StartsWith(Prefix) && !mine.Contains(id) && (created == null || created < stale)) { await Send(HttpMethod.Delete, $"/v1/agents/{Uri.EscapeDataString(id)}", null, ct); Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["runtime"] = "cursor-orphan-deleted", ["agent"] = id }.ToJsonString()); }
                swept = true;
            }
            catch (Exception e) { Console.Error.WriteLine($"cursor: orphan sweep: {e.GetType().Name}"); }
        }
        List<Agent> all; lock (agents) { foreach (var k in agents.Where(kv => kv.Value.Deleted && kv.Value.Ended < DateTime.UtcNow.AddHours(-2)).Select(kv => kv.Key).ToList()) agents.Remove(k); all = agents.Values.ToList(); }
        var list = new List<RuntimeInstance>();
        foreach (var a in all)
        {
            try
            {
                if (!a.Deleted && a.Ended == null && (DateTime.UtcNow - a.Started).TotalMinutes > cfg.MaxMinutes)
                {   // the deadline: a failure of the item's phase; the delete is retried below until it is done
                    lock (agents) { a.Status = "Failed"; a.Ended = DateTime.UtcNow; }
                }
                else if (a.Ended == null)
                {
                    var (s, j) = await Send(HttpMethod.Get, $"/v1/agents/{Uri.EscapeDataString(a.Id)}", null, ct);
                    if (s is not (200 or 404)) throw new HttpRequestException($"read of agent answered {s}");
                    var st = s == 404 ? "ARCHIVED" : j?["agent"]?["status"]?.ToString() ?? j?["status"]?.ToString() ?? "";
                    // the model Cursor reports for the agent, once: the check that the launch ran on the model asked for
                    if (!a.ModelLogged && (j?["agent"]?["model"] ?? j?["model"]) is { } rm) { a.ModelLogged = true; lock (agents) a.ReportedModel = rm.DeepClone(); Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["runtime"] = "cursor-agent-model", ["agent"] = a.Id, ["model"] = rm.DeepClone() }.ToJsonString()); }
                    var runId = j?["agent"]?["latestRunId"]?.ToString() ?? j?["latestRunId"]?.ToString() ?? "";
                    var runStatus = "";
                    if (runId != "") { try { var (rs, rj) = await Send(HttpMethod.Get, $"/v1/agents/{Uri.EscapeDataString(a.Id)}/runs/{Uri.EscapeDataString(runId)}", null, ct); if (rs == 200) runStatus = rj?["run"]?["status"]?.ToString() ?? rj?["status"]?.ToString() ?? ""; } catch { } }
                    lock (agents)
                    {
                        if (runId != "") a.RunId = runId;
                        if (s == 404) a.Deleted = true;
                        // IDLE (the turn ended) counts as the end once it lasted a minute: a short pause between turns is no end
                        if (st == "IDLE") a.IdleSince ??= DateTime.UtcNow; else a.IdleSince = null;
                        var idleOver = a.IdleSince is { } isn && (DateTime.UtcNow - isn).TotalSeconds >= IdleGraceSeconds;
                        a.Status = runStatus is "ERROR" or "EXPIRED" ? "Failed" : st switch { "ACTIVE" => "Running", "IDLE" => idleOver ? "Succeeded" : "Running", "ARCHIVED" => "Stopped", _ => "Running" };
                        if (a.Status != "Running") a.Ended ??= DateTime.UtcNow;
                    }
                }
                // an agent that ended (by itself, at the deadline, or a delete that failed before) is deleted, again at every reading until it is gone
                if (a.Ended != null && !a.Deleted) { try { await Deprovision(a.Worker, "ended", ct); } catch (Exception e) { Console.Error.WriteLine($"cursor: delete of {a.Worker}: {e.GetType().Name}"); } }
            }
            catch (Exception e) { Console.Error.WriteLine($"cursor: read of {a.Worker}: {e.GetType().Name}"); }
            list.Add(new RuntimeInstance(a.Id, a.Worker, a.Item, a.Phase, a.Status, a.Started, a.Ended));
        }
        return list;
    }
}
