using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

// The prompt files (prompts/, docs/design/agents-roles-launch.md 5): loaded once at start, hashed (/_build promptsHash) and served by the
// get_prompt tool with their includes and the agent's override resolved. A file that does not parse is not served, and the gateway is not ready
// (/ready 503 waitingFor prompts) while one does not: the same rules as the lint of tests/smoke.ps1, which checks them before a merge.
sealed record PromptFile(string Path, string Role, string Phase, int Version, string[] Tools, string[] Includes, Dictionary<string, string> Agents, string Body);

sealed class PromptStore
{
    public string Dir { get; }
    public string Hash { get; private set; } = "";
    public List<string> Errors { get; } = new();
    readonly Dictionary<string, PromptFile> files = new(StringComparer.Ordinal);   // by relative path, "worker/development.md"

    public PromptStore(string dir) { Dir = dir; Load(); }

    void Load()
    {
        if (!Directory.Exists(Dir)) { Errors.Add($"no prompts directory at {Dir}"); return; }
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var f in Directory.GetFiles(Dir, "*.md", SearchOption.AllDirectories).OrderBy(x => x, StringComparer.Ordinal))
        {
            var rel = Path.GetRelativePath(Dir, f).Replace('\\', '/');
            var text = File.ReadAllText(f);
            sha.AppendData(Encoding.UTF8.GetBytes(rel + "\n" + text + "\n"));
            if (rel == "README.md") continue;
            var (p, err) = Parse(rel, text);
            if (p == null) { Errors.Add($"{rel}: {err}"); continue; }
            files[rel] = p;
        }
        Hash = Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant()[..16];
        foreach (var p in files.Values)
        {
            foreach (var i in p.Includes) if (!files.ContainsKey(i)) Errors.Add($"{p.Path}: include {i} does not exist");
            foreach (var t in p.Tools)
            {
                var set = p.Role is "bootstrap" ? "worker" : p.Role;
                if (!RoleTools.Allows(set, t)) Errors.Add($"{p.Path}: tool {t} is not in the {set} role's tool set");
            }
        }
    }

    // The front matter: key: value lines, lists in [a, b], and one map "agents:" of indented name: "text" lines.
    public static (PromptFile? File, string Error) Parse(string rel, string text)
    {
        text = text.Replace("\r\n", "\n");
        if (!text.StartsWith("---\n")) return (null, "no front matter");
        var end = text.IndexOf("\n---\n", 4, StringComparison.Ordinal); if (end < 0) return (null, "front matter not closed");
        var head = text[4..end]; var body = text[(end + 5)..].Trim('\n') + "\n";
        var kv = new Dictionary<string, string>(StringComparer.Ordinal); var agents = new Dictionary<string, string>(StringComparer.Ordinal);
        string? map = null;
        foreach (var raw in head.Split('\n'))
        {
            if (raw.Trim() == "" || raw.TrimStart().StartsWith('#')) continue;
            var line = raw; var hash = line.IndexOf("  #", StringComparison.Ordinal); if (hash >= 0 && !line.Contains('"')) line = line[..hash];
            var c = line.IndexOf(':'); if (c <= 0) return (null, $"cannot read the front matter line '{raw.Trim()}'");
            var k = line[..c].Trim(); var v = line[(c + 1)..].Trim();
            if (raw.StartsWith(' ') && map == "agents") { agents[k] = Unquote(v); continue; }
            map = null;
            if (k == "agents" && v == "") { map = "agents"; continue; }
            kv[k] = v;
        }
        foreach (var req in new[] { "role", "phase", "version", "tools", "includes" }) if (!kv.ContainsKey(req)) return (null, $"front matter needs {req}");
        if (!int.TryParse(kv["version"], out var ver) || ver < 1) return (null, "version is a positive number");
        static string[] List(string v) => v.StartsWith('[') && v.EndsWith(']') ? v[1..^1].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) : Array.Empty<string>();
        if (!(kv["tools"].StartsWith('[') && kv["tools"].EndsWith(']')) || !(kv["includes"].StartsWith('[') && kv["includes"].EndsWith(']'))) return (null, "tools and includes are lists [a, b]");
        var tools = List(kv["tools"]);
        if (body.Contains("factory.ps1", StringComparison.Ordinal)) return (null, "the body names factory.ps1: agents act through the tools");
        if (System.Text.RegularExpressions.Regex.IsMatch(body, @"\$[A-Za-z_][A-Za-z0-9_]*")) return (null, "the body holds a shell variable");
        return (new PromptFile(rel, kv["role"], kv["phase"], ver, tools, List(kv["includes"]), agents, body), "");
    }

    static string Unquote(string v) => v.Length >= 2 && v[0] == '"' && v[^1] == '"' ? v[1..^1].Replace("\\\"", "\"") : v;

    public PromptFile? Find(string role, string phase) => files.Values.FirstOrDefault(p => p.Role == role && p.Phase == phase);
    public PromptFile? ByPath(string rel) => files.TryGetValue(rel, out var p) ? p : null;
    public IEnumerable<PromptFile> All => files.Values;

    // The text a session reads: the includes, the body, and the section for its agent.
    public JsonObject Render(PromptFile p, string agent)
    {
        var sb = new StringBuilder();
        foreach (var i in p.Includes) if (files.TryGetValue(i, out var inc)) sb.Append(inc.Body).Append('\n');
        sb.Append(p.Body);
        if (agent != "" && p.Agents.TryGetValue(agent, out var extra)) sb.Append("\n## For this agent (").Append(agent).Append(")\n\n").Append(extra).Append('\n');
        return new JsonObject { ["ok"] = true, ["prompt"] = $"{p.Role}/{p.Phase}", ["version"] = p.Version, ["promptsHash"] = Hash, ["text"] = sb.ToString() };
    }
}
