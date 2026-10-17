// The tool set of each role at /mcp (docs/design/agents-roles-launch.md 6.2): the one table that decides what tools/list shows a caller and what
// tools/call admits. A tool outside the caller's role is refused before its handler runs, and every handler then goes through the same
// authorization the /api/v1 endpoint applies (Auth.AuthorizeVerb and the endpoint's own checks): the table narrows, it never widens.
// Code-owner path (.github/CODEOWNERS: /gateway/Mcp/).
static class RoleTools
{
    public static readonly IReadOnlyDictionary<string, string[]> Sets = new Dictionary<string, string[]>(StringComparer.Ordinal)
    {
        // the owner (environment-test-factories.md 18.3): the read tools; action tools follow in their own step
        ["owner"] = ["factory_status", "workers_and_runs", "item_detail", "metrics"],
        // the worker of an item (owner of the item in the plant's words), in every phase; validation-verdict only in Functional Testing (the verb checks the
        // column). git_credential, build_slot and merge are not here: the first api agents push with their own identity.
        ["worker"] = ["item_get", "item_accept", "item_claim", "item_append_body", "item_comment", "item_release", "item_record_review", "item_complete", "pr_open", "pr_update", "pr_checks", "pr_wait_checks",
            "item_validation_verdict", "send_note", "ask", "next_event", "session_end", "get_prompt"],
    };

    // The role a principal plays at /mcp, or "" when it has none there. The admin token is the owner (agents-roles-launch.md 4).
    // The legacy kinds are mapped in Auth.RoleOf; only a role with a tool set plays at /mcp.
    public static string RoleOf(Principal p) => Auth.RoleOf(p).Role is var r && Sets.ContainsKey(r) ? r : "";

    public static bool Allows(string role, string tool) => Sets.TryGetValue(role, out var s) && s.Contains(tool);

    // One phase per session (owner decision 2026-10-17): a worker r1 that names its phase sees and may call only that phase's tools, so a
    // session cannot drift into the next column's work; an unknown phase gets no tool. A legacy item token (no phase) keeps the whole worker set.
    static readonly string[] Common = ["item_get", "item_accept", "item_claim", "item_release", "ask", "send_note", "next_event", "session_end", "get_prompt"];
    public static readonly IReadOnlyDictionary<string, string[]> PhaseSets = new Dictionary<string, string[]>(StringComparer.Ordinal)
    {
        ["technical-design"] = [.. Common, "item_append_body", "item_record_review", "item_complete"],
        ["development"] = [.. Common, "item_comment", "item_record_review", "item_complete", "pr_open", "pr_update", "pr_checks", "pr_wait_checks"],
        ["functional-testing"] = [.. Common, "item_record_review", "item_validation_verdict", "pr_checks"],
    };

    public static bool Allows(Principal who, string role, string tool) =>
        Allows(role, tool) && !(role == "worker" && who.Kind == "role" && who.Phase != "" && !(PhaseSets.TryGetValue(who.Phase, out var ps) && ps.Contains(tool)));
}
