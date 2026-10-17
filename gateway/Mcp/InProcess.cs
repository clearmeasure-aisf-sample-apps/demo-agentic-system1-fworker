using System.Text;
using Microsoft.AspNetCore.Routing;

// One implementation, several surfaces (docs/design/agents-roles-launch.md 6.1, environment-test-factories.md 18.2): an MCP tool calls the very
// endpoint handler that /api/v1 maps, in this process, with the caller's principal. No HTTP hop, no copy of a rule: the refusals, the exit codes,
// the journal lines and the plant hooks are the endpoint's own. The middleware's per-principal work (presence, the operator's in-flight count) is
// applied by the Admit function the gateway passes in, the same one its middleware runs.
sealed class InProcess
{
    readonly IEndpointRouteBuilder routes;
    readonly IServiceProvider services;
    readonly Func<Principal, string, Func<Task>, Task> admit;
    Dictionary<(string Method, string Pattern), RouteEndpoint>? map;

    public InProcess(IEndpointRouteBuilder routes, Func<Principal, string, Func<Task>, Task> admit) { this.routes = routes; services = routes.ServiceProvider; this.admit = admit; }

    RouteEndpoint? Find(string method, string pattern)
    {
        map ??= routes.DataSources.SelectMany(s => s.Endpoints).OfType<RouteEndpoint>()
            .SelectMany(e => (e.Metadata.GetMetadata<IHttpMethodMetadata>()?.HttpMethods ?? new[] { "GET" }).Select(m => (Key: (m, e.RoutePattern.RawText ?? ""), E: e)))
            .GroupBy(x => x.Key).ToDictionary(g => g.Key, g => g.First().E);
        return map.TryGetValue((method, pattern), out var ep) ? ep : null;
    }

    // pattern: the route as mapped ("/api/v1/verbs/{verb}"); route: its values; query without "?"; body: JSON text or null.
    // Returns the endpoint's status and body exactly as an HTTP caller would get them.
    public async Task<(int Status, string Body)> Call(string method, string pattern, Principal who, IReadOnlyDictionary<string, string>? route = null,
        string query = "", string? body = null, CancellationToken ct = default)
    {
        var ep = Find(method, pattern) ?? throw new InvalidOperationException($"no endpoint {method} {pattern}");
        using var scope = services.CreateScope();
        var ctx = new DefaultHttpContext { RequestServices = scope.ServiceProvider, RequestAborted = ct };
        var path = pattern;
        if (route != null) foreach (var (k, v) in route) { ctx.Request.RouteValues[k] = v; path = path.Replace("{" + k + "}", Uri.EscapeDataString(v)).Replace("{" + k + ":int}", Uri.EscapeDataString(v)); }
        ctx.Request.Method = method; ctx.Request.Scheme = "http"; ctx.Request.Host = new HostString("localhost"); ctx.Request.Path = path;
        if (query != "") ctx.Request.QueryString = new QueryString("?" + query);
        var bytes = Encoding.UTF8.GetBytes(body ?? "");
        ctx.Request.Body = new MemoryStream(bytes); ctx.Request.ContentLength = bytes.Length;
        if (body != null) ctx.Request.ContentType = "application/json";
        ctx.Items["principal"] = who;
        ctx.Items["via"] = "mcp";
        var outStream = new MemoryStream();
        ctx.Response.Body = outStream;
        ctx.SetEndpoint(ep);
        await admit(who, path, () => ep.RequestDelegate!(ctx));
        return (ctx.Response.StatusCode, Encoding.UTF8.GetString(outStream.ToArray()));
    }
}
