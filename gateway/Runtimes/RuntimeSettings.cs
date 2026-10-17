using System.Globalization;
using System.Text.Json.Nodes;

// The runtimes block of the instance configuration (docs/design/cloud-worker-runtimes.md 4.3 to 4.5 and 5). Every runtime is off in the source
// defaults (config/instance.json, asserted by tests/smoke.ps1); a deployment switches one on only in config/deploy.overrides.json, a code-owner path.
sealed record RoutingRule(string Phase, string Runtime);

sealed class CaeJobSettings
{
    public bool Enabled;
    public int MaxConcurrent, MaxExecutionsPerDay;
    public double AckSeconds = 300;                    // the offer window of a worker of this runtime: it covers the container start (4.4)
    public int ReplicaTimeoutSeconds = 14400;          // the job's replicaTimeout; the w2 expires 15 minutes after it
    public int MaxFailuresPerPhase = 2;                // failed executions of one item in one phase before the item is parked runtime-failed
    public int UnhealthyAfterFailures = 2;             // executions in a row that never registered before the runtime is marked unhealthy
    public double ListSeconds = 30;                    // how often the executions are read from ARM
    public string JobResourceId = "", ArmEndpoint = "https://management.azure.com", ApiVersion = "2024-03-01", ManagedIdentityClientId = "",
        Image = "", ContainerName = "fwrunner", Memory = "8Gi", GatewayUrl = "";
    // The agent the job's container runs (FWRUNNER_AGENT of the fwrunner image): claude or codex. Each agent has its own job (its own identity
    // and model variables); jobs.<agent> names it, and when it does it replaces jobResourceId. One agent is active at a time: the adapter
    // lists and stops executions of the active agent's job only, so switching agents (a redeploy) needs the other job's executions drained first.
    public string Agent = "claude";
    public Dictionary<string, string> Jobs = new(StringComparer.Ordinal);
    public static readonly string[] Agents = { "claude", "codex" };
    public double Cpu = 4;
    public bool On => Enabled && MaxConcurrent > 0 && JobResourceId != "";
}

sealed class RuntimeSettings
{
    public bool PreferConnected = true;
    public List<RoutingRule> Routing = new();
    public CaeJobSettings CaeJob = new();
    public bool AnyOn => CaeJob.On;

    public static RuntimeSettings Load(string scriptsDir)
    {
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? root = null; try { root = JsonNode.Parse(File.ReadAllText(path)); } catch { }
        var env = (Environment.GetEnvironmentVariable("FACTORY_ENVIRONMENT") ?? "").Trim().ToLowerInvariant();
        var s = From(ForEnvironment(root?["runtimes"], env == "" ? "tdd" : env));
        // The baked caeJob (tdd's jobs and identity) applies only in tdd, local (run-owner-gateway.sh) or with no environment named (tests): anywhere else
        // it starts off, and only the FACTORY_RUNTIME_* variables of that environment's app switch it on (cloud-worker-runtimes.md 5.1).
        // What is cleared is what names tdd's resources or switches and sizes it; ARM endpoint, timings and container shape stay.
        if (env is not ("" or "tdd" or "local"))
        {
            var j = s.CaeJob; j.Enabled = false; j.MaxConcurrent = 0; j.MaxExecutionsPerDay = 0; j.JobResourceId = ""; j.Jobs.Clear();
            j.ManagedIdentityClientId = ""; j.GatewayUrl = "";
        }
        ApplyVariables(s.CaeJob, Environment.GetEnvironmentVariable);
        return s;
    }

    // FACTORY_RUNTIME_* set on the gateway app override the baked caeJob. FACTORY_RUNTIME_ENABLED=true switches it on only together with a
    // job of the active agent and an identity client id; a value that does not parse is ignored.
    public static void ApplyVariables(CaeJobSettings j, Func<string, string?> get)
    {
        string? V(string n) => get(n) is { } v && v.Trim() != "" ? v.Trim() : null;
        void Bad(string n) { if (V(n) is { } x) Console.Error.WriteLine($"runtime: {n}='{x}' does not parse; ignored"); }
        if (V("FACTORY_RUNTIME_AGENT")?.ToLowerInvariant() is { } a && CaeJobSettings.Agents.Contains(a)) j.Agent = a; else Bad("FACTORY_RUNTIME_AGENT");
        if (V("FACTORY_RUNTIME_JOB_CLAUDE") is { } jc) j.Jobs["claude"] = jc;
        if (V("FACTORY_RUNTIME_JOB_CODEX") is { } jx) j.Jobs["codex"] = jx;
        if (j.Jobs.TryGetValue(j.Agent, out var job)) j.JobResourceId = job;
        if (V("FACTORY_RUNTIME_IDENTITY_CLIENT_ID") is { } id) j.ManagedIdentityClientId = id;
        if (V("FACTORY_RUNTIME_GATEWAY_URL") is { } gu) j.GatewayUrl = gu;
        if (int.TryParse(V("FACTORY_RUNTIME_MAX_CONCURRENT"), NumberStyles.None, CultureInfo.InvariantCulture, out var mc)) j.MaxConcurrent = mc; else Bad("FACTORY_RUNTIME_MAX_CONCURRENT");
        if (int.TryParse(V("FACTORY_RUNTIME_MAX_PER_DAY"), NumberStyles.None, CultureInfo.InvariantCulture, out var md)) j.MaxExecutionsPerDay = md; else Bad("FACTORY_RUNTIME_MAX_PER_DAY");
        if (bool.TryParse(V("FACTORY_RUNTIME_ENABLED"), out var en))
        {
            j.Enabled = en && j.JobResourceId != "" && j.ManagedIdentityClientId != "";
            if (en && !j.Enabled) Console.Error.WriteLine($"runtime: FACTORY_RUNTIME_ENABLED=true without a job for agent {j.Agent} and an identity client id; caeJob stays off");
        }
        else Bad("FACTORY_RUNTIME_ENABLED");
    }

    // One image runs in every environment, so the runtimes block may carry environments.<name>: when it does, the entry of FACTORY_ENVIRONMENT
    // is the block, and an environment without an entry has every runtime off. Without environments (or with an empty one, as in the source defaults) the block applies
    // as it is. The names are lower case in the file; FACTORY_ENVIRONMENT is matched trimmed and lower-cased, so a mismatch fails closed.
    public static JsonNode? ForEnvironment(JsonNode? r, string environment) =>
        r is JsonObject o && o["environments"] is JsonObject { Count: > 0 } envs ? envs[environment.Trim().ToLowerInvariant()] : r;

    public static RuntimeSettings From(JsonNode? r)
    {
        var s = new RuntimeSettings();
        if (r is not JsonObject) return s;
        static bool Num(string? text, out double v) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && double.IsFinite(v) && v >= 0;
        if (r["preferConnected"] is JsonValue pc && pc.TryGetValue<bool>(out var pcb)) s.PreferConnected = pcb;
        if (r["routing"] is JsonArray rules)
            foreach (var x in rules)
            {
                var rt = x?["runtime"]?.ToString() ?? "";
                if (rt == "local" || Auth.ValidRuntime(rt)) s.Routing.Add(new RoutingRule(x?["phase"]?.ToString() is { Length: > 0 } ph ? ph : "*", rt));
            }
        var c = r["caeJob"]; var j = s.CaeJob;
        if (c is JsonObject)
        {
            double D(string k, double d) => Num(c[k]?.ToString(), out var v) ? v : d;
            string S(string k, string d) => c[k] is JsonValue sv && sv.TryGetValue<string>(out var str) ? str : d;
            j.Enabled = c["enabled"] is JsonValue ev && ev.TryGetValue<bool>(out var eb) && eb;
            j.MaxConcurrent = (int)D("maxConcurrent", 0); j.MaxExecutionsPerDay = (int)D("maxExecutionsPerDay", 0);
            j.AckSeconds = D("ackSeconds", 300); j.ReplicaTimeoutSeconds = (int)D("replicaTimeoutSeconds", 14400);
            j.MaxFailuresPerPhase = Math.Max(1, (int)D("maxFailuresPerPhase", 2)); j.UnhealthyAfterFailures = Math.Max(1, (int)D("unhealthyAfterFailures", 2));
            j.ListSeconds = Math.Max(1, D("listSeconds", 30)); j.Cpu = D("cpu", 4);
            j.JobResourceId = S("jobResourceId", ""); j.ArmEndpoint = S("armEndpoint", j.ArmEndpoint).TrimEnd('/'); j.ApiVersion = S("apiVersion", j.ApiVersion);
            j.ManagedIdentityClientId = S("managedIdentityClientId", ""); j.Image = S("image", ""); j.ContainerName = S("containerName", j.ContainerName);
            j.Memory = S("memory", j.Memory); j.GatewayUrl = S("gatewayUrl", "");
            var agent = S("agent", j.Agent).Trim().ToLowerInvariant(); if (CaeJobSettings.Agents.Contains(agent)) j.Agent = agent;
            if (c["jobs"] is JsonObject jobs)
                foreach (var (k, v) in jobs)
                    if (CaeJobSettings.Agents.Contains(k.Trim().ToLowerInvariant()) && v is JsonValue jv && jv.TryGetValue<string>(out var id) && id != "") j.Jobs[k.Trim().ToLowerInvariant()] = id;
            if (j.Jobs.TryGetValue(j.Agent, out var agentJob)) j.JobResourceId = agentJob;
        }
        return s;
    }

    // The runtime of an item in a phase: the item's runtime: label wins, then the first routing rule whose phase matches ("*" matches any), else local.
    public string RouteFor(string phase, string label)
    {
        if (label != "") return label;
        foreach (var r in Routing) if (r.Phase == "*" || string.Equals(r.Phase, phase, StringComparison.OrdinalIgnoreCase)) return r.Runtime;
        return "local";
    }
}
