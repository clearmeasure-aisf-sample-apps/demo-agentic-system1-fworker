using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Azure.Core;
using Azure.Identity;

// Rights of the gateway's identity on the one job: Microsoft.App/jobs/read, jobs/start/action, jobs/executions/read, jobs/executions/stop/action.
// The Container Apps job runtime (docs/design/cloud-worker-runtimes.md 2.1, option A): one execution of the manual-trigger job
// runtimes.caeJob.jobResourceId per worker, started, listed and stopped through ARM with the gateway's managed identity (rights: jobs/start/action,
// jobs/executions/read and executions/stop/action on that one job). The start carries a per-execution override of the job's container: the job's
// own container (image, resources, the Foundry variables of 3.2) with the execution's values added, so nothing of the job template is lost.
// The execution's values are no credential: a one-time nonce, the worker name, the item, the phase and the model profile.
sealed class CaeJobRuntime : IWorkerRuntime
{
    readonly CaeJobSettings cfg;
    readonly HttpClient http;
    readonly Func<CancellationToken, Task<string>> token;
    readonly Dictionary<string, string> execOf = new(StringComparer.Ordinal);   // worker name -> execution name, as far as this process knows

    public CaeJobRuntime(CaeJobSettings cfg, HttpClient? http = null, Func<CancellationToken, Task<string>>? token = null)
    {
        this.cfg = cfg; this.http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        this.token = token ?? DefaultToken(cfg);
    }

    public string Kind => "cae-job";
    public int MaxConcurrent => cfg.MaxConcurrent;

    // The managed identity of the gateway's container app (its user-assigned identity when managedIdentityClientId names one). A test gateway against
    // a loopback ARM endpoint takes FACTORY_TEST_ARM_TOKEN instead; that variable is ignored for any other endpoint.
    static Func<CancellationToken, Task<string>> DefaultToken(CaeJobSettings cfg)
    {
        var test = Environment.GetEnvironmentVariable("FACTORY_TEST_ARM_TOKEN");
        if (!string.IsNullOrEmpty(test) && Uri.TryCreate(cfg.ArmEndpoint, UriKind.Absolute, out var u) && u.IsLoopback) return _ => Task.FromResult(test);
        var cred = cfg.ManagedIdentityClientId != "" ? new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(cfg.ManagedIdentityClientId)) : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
        var scope = new TokenRequestContext(new[] { cfg.ArmEndpoint.TrimEnd('/') + "/.default" });
        return async ct => (await cred.GetTokenAsync(scope, ct)).Token;
    }

    string Url(string suffix) => $"{cfg.ArmEndpoint}{cfg.JobResourceId}{suffix}{(suffix.Contains('?') ? "&" : "?")}api-version={cfg.ApiVersion}";

    async Task<(int Status, JsonNode? Body)> Send(HttpMethod m, string url, JsonNode? body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(m, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await token(ct));
        if (body != null) req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var resp = await http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        JsonNode? j = null; try { if (text.Length > 0) j = JsonNode.Parse(text); } catch { }
        return ((int)resp.StatusCode, j);
    }

    public async Task<ProvisionResult> Provision(ProvisionRequest r, CancellationToken ct)
    {
        // the job's own container is the base of the override (GET of the job resource)
        var (gs, job) = await Send(HttpMethod.Get, Url(""), null, ct);
        if (gs != 200) return new(false, "", $"job-read-{gs}");
        var containers = job?["properties"]?["template"]?["containers"] as JsonArray;
        var jobC = (containers?.FirstOrDefault(c => c?["name"]?.ToString() == cfg.ContainerName) ?? containers?.FirstOrDefault()) as JsonObject ?? new JsonObject();
        // only the fields of a JobExecutionContainer: the template's probes or volume mounts are not accepted in a start override
        var baseC = new JsonObject();
        foreach (var f in new[] { "name", "image", "command", "args", "env", "resources" }) if (jobC[f] is { } fv) baseC[f] = fv.DeepClone();
        baseC["name"] = baseC["name"]?.ToString() ?? cfg.ContainerName;
        if (cfg.Image != "") baseC["image"] = cfg.Image;
        baseC["resources"] = new JsonObject { ["cpu"] = cfg.Cpu, ["memory"] = cfg.Memory };
        var env = (baseC["env"] as JsonArray)?.Where(e => !(e?["name"]?.ToString() ?? "").StartsWith("FWORKER_")).Select(e => e!.DeepClone()).ToList() ?? new List<JsonNode>();
        void Add(string n, string v) => env.Add(new JsonObject { ["name"] = n, ["value"] = v });
        Add("FWORKER_NONCE", r.Nonce); Add("FWORKER_NAME", r.WorkerName); Add("FWORKER_ITEM", r.Item.ToString()); Add("FWORKER_PHASE", r.Phase);
        Add("FWORKER_MODEL_PROFILE", r.ModelProfile); Add("FWORKER_RUNTIME", Kind); if (cfg.GatewayUrl != "") Add("FWORKER_GATEWAY_URL", cfg.GatewayUrl);
        // the agent of the image follows the configuration even when the job template says otherwise
        env.RemoveAll(e => e?["name"]?.ToString() == "FWRUNNER_AGENT"); Add("FWRUNNER_AGENT", cfg.Agent);
        baseC["env"] = new JsonArray(env.ToArray());
        var (ss, started) = await Send(HttpMethod.Post, Url("/start"), new JsonObject { ["containers"] = new JsonArray(baseC) }, ct);
        if (ss is not (200 or 202)) return new(false, "", $"start-{ss}");
        var exec = started?["name"]?.ToString() ?? "";
        // the start is a long-running operation: a 202 may carry no body; the execution is then found by its worker name
        for (var tries = 0; exec == "" && tries < 10; tries++)
        {
            await Task.Delay(TimeSpan.FromSeconds(2), ct);
            try { exec = (await List(ct)).FirstOrDefault(i => i.WorkerName == r.WorkerName)?.Execution ?? ""; } catch { }
        }
        if (exec == "") return new(false, "", "start-no-execution");
        lock (execOf) execOf[r.WorkerName] = exec;
        return new(true, exec, "");
    }

    public async Task Deprovision(string workerName, string reason, CancellationToken ct)
    {
        string? exec; lock (execOf) execOf.TryGetValue(workerName, out exec);
        if (exec == null) { foreach (var i in await List(ct)) if (i.WorkerName == workerName) exec = i.Execution; }
        if (exec == null) return;
        var (s, _) = await Send(HttpMethod.Post, Url($"/executions/{Uri.EscapeDataString(exec)}/stop"), null, ct);
        // 404: the execution is gone already; 409 or 400: it has ended. Either way there is nothing left to stop.
        if (s is not (200 or 202 or 204 or 404 or 409 or 400)) throw new HttpRequestException($"stop of {exec} answered {s}");
    }

    public async Task<IReadOnlyList<RuntimeInstance>> List(CancellationToken ct)
    {
        var list = new List<RuntimeInstance>();
        string? url = Url("/executions");
        for (var page = 0; url != null && page < 10; page++)
        {
            var (s, body) = await Send(HttpMethod.Get, url, null, ct);
            if (s != 200) throw new HttpRequestException($"list of executions answered {s}");
            foreach (var e in body?["value"] as JsonArray ?? new JsonArray())
            {
                var p = e?["properties"];
                var envs = (p?["template"]?["containers"] as JsonArray)?.SelectMany(c => c?["env"] as JsonArray ?? new JsonArray()).ToList() ?? new List<JsonNode?>();
                string Env(string n) => envs.FirstOrDefault(x => x?["name"]?.ToString() == n)?["value"]?.ToString() ?? "";
                var worker = Env("FWORKER_NAME"); if (worker == "") continue;   // an execution this gateway did not start
                list.Add(new RuntimeInstance(e!["name"]?.ToString() ?? "", worker, int.TryParse(Env("FWORKER_ITEM"), out var it) ? it : 0, Env("FWORKER_PHASE"),
                    p?["status"]?.ToString() ?? "Unknown", Time(p?["startTime"]), Time(p?["endTime"])));
            }
            url = body?["nextLink"]?.ToString() is { Length: > 0 } next && next.StartsWith(cfg.ArmEndpoint, StringComparison.OrdinalIgnoreCase) ? next : null;
        }
        lock (execOf) foreach (var i in list) execOf.TryAdd(i.WorkerName, i.Execution);
        return list;
    }

    static DateTime? Time(JsonNode? n) => DateTime.TryParse(n?.ToString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var t) ? t : null;
}
