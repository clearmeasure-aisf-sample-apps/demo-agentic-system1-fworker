using System.Globalization;
using System.Text.Json.Nodes;

// The plant manager's flow verbs (docs/design/plant-manager.md 10e): what the gateway keeps for them. The supervisor calls one verb, manager-action,
// with one action per call (Auth.cs ManagerItemActions and ManagerNameActions). The item actions run as the rule verb manager-action
// (plugin/scripts/lib/Verbs.Manager.ps1), which enforces the owner's hold (label hold:owner) and the limit per item on the item itself, so a restart
// does not reset them. Kept here, in the gateway's memory:
//   - the mode: manager.mode "act" (the default) or "advise", which turns every action off (any other value is advise); the operator may set it at
//     run time (POST /api/v1/manager/mode, the operator token only); the plant snapshot carries it across a graceful restart, an outright kill loses it;
//   - the limit per hour over every item (manager.actions.perHour, 30), counted from the moment an action is let through;
//   - the log of the actions of the last 24 hours (for /status, GET /api/v1/manager/actions and the daily summary); each action also goes to the
//     operator stream as a plant.event and, for an item, into the item's journal with its policy code;
//   - the names the supervisor drained (an operator's drain of a name wins: the supervisor cannot resume it, and the operator's resume lifts both);
//   - the limit of the name actions: drain, resume and restart-session on one name at most manager.actions.perItemPerDay times in 24 hours (the item
//     actions count on the item); restart-session refuses a name that owns an item labelled hold:owner (the sweep reports those, Plan);
//   - the restart of a session (session.restart on its stream; the stream client writes the launcher's end marker, docs/launcher.md);
//   - the day's supervisor.summary-due, pushed once a day at manager.dailySummaryHourUtc, so the supervisor sends the operator one summary.
sealed class ManagerActionSettings
{
    public string Mode = "act";
    public int PerHour = 30, PerItemPerDay = 3;
    // manager.actions.policies: the policy codes an action may name (the rule script checks the item actions against the same list)
    public static readonly string[] DefaultPolicies = { "park-resolved", "stalled-owner", "pinned-worker-absent", "stuck-offer", "outside-blocker", "flaky-check", "repeated-question", "backlog-order", "load-balance", "operator-request" };
    public string[] Policies = DefaultPolicies;
    // the hour (UTC, 0 to 23) of the day's supervisor.summary-due; -1 (and a config without the key) sends none
    public int SummaryHourUtc = -1;

    public static ManagerActionSettings Load(string scriptsDir)
    {
        var s = new ManagerActionSettings();
        JsonNode? root = null;
        try { root = JsonNode.Parse(File.ReadAllText(Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json"))); } catch { }
        var m = root?["manager"]; var a = m?["actions"];
        // a mode that is neither act nor advise fails closed: advise, with a warning (an owner who wrote "off" or "Advise" meant no actions)
        if (m?["mode"] is JsonNode mn) { var mv = mn.ToString(); s.Mode = mv == "act" ? "act" : "advise"; if (mv is not ("act" or "advise")) Console.Error.WriteLine($"manager.mode '{mv}' is neither act nor advise: the plant manager runs in advise mode"); }
        static int Num(JsonNode? n, int d, int min, int max) => n != null && int.TryParse(n.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? Math.Clamp(v, min, max) : d;
        s.PerHour = Num(a?["perHour"], 30, 0, 1000); s.PerItemPerDay = Num(a?["perItemPerDay"], 3, 0, 100);
        s.SummaryHourUtc = Num(m?["dailySummaryHourUtc"], -1, -1, 23);
        if (a?["policies"] is JsonArray pa && pa.Count > 0) s.Policies = pa.Select(x => x?.ToString() ?? "").Where(x => System.Text.RegularExpressions.Regex.IsMatch(x, @"^[a-z][a-z0-9-]{1,39}\z")).ToArray();
        // FACTORY_TIMING_mgrSummaryHourUtc: the suites set the hour of their gateway (0: due at once)
        if (int.TryParse(Environment.GetEnvironmentVariable("FACTORY_TIMING_mgrSummaryHourUtc"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var h)) s.SummaryHourUtc = Math.Clamp(h, -1, 23);
        return s;
    }
}

sealed partial class Plant
{
    public ManagerActionSettings MgrActions { get; set; } = new();
    string mgrModeOverride = "";
    sealed class MgrAction { public DateTime At; public string Action = "", Worker = "", Policy = "", By = "", Code = ""; public int Item; public bool Ok = true, Done; }
    readonly List<MgrAction> mgrLog = new();
    readonly HashSet<string> mgrDrained = new();
    string summaryDay = "";
    // the items the last sweep found labelled hold:owner (ownerHoldLabel), for the name actions, which do not read GitHub; until the first sweep after
    // a start has reported them, restart-session waits (sweep-pending)
    readonly HashSet<int> ownerHeld = new();
    bool ownerHeldKnown;
    public void SetOwnerHeld(IEnumerable<int> items) { lock (gate) { ownerHeld.Clear(); foreach (var i in items) if (i > 0) ownerHeld.Add(i); ownerHeldKnown = true; } }
    public bool KnowsWorker(string name) { lock (gate) return workers.ContainsKey(name); }
    // The plant snapshot is restored after the listener is up (Program.cs): until then the operator's run-time mode and the day of the last summary are
    // not known, so the mode is advise and no summary is due. At most 60 s after the start, as the Sweeper waits.
    public Task? RestoredTask { get; set; }
    bool Restored => RestoredTask == null || RestoredTask.IsCompleted || (DateTime.UtcNow - startedAt).TotalSeconds > 60;

    public string ManagerMode() { lock (gate) return !Restored ? "advise" : mgrModeOverride != "" ? mgrModeOverride : MgrActions.Mode; }
    public void SetManagerMode(string mode) { lock (gate) mgrModeOverride = mode; }

    // Lets one action through the limits and records it; the caller reports how it ended (ManagerActionDone). An action that failed or was refused by
    // its rule script no longer counts. The hourly limit covers every action; a name action (item 0) on one name counts against perItemPerDay in 24
    // hours as well, except resume, so a drain can always be lifted. Returns the record, or the code and the seconds until one is free.
    public (object? Ticket, int RetryAfter, string Code) ManagerActionBegin(string action, int item, string worker, string policy, string by)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            mgrLog.RemoveAll(x => (now - x.At).TotalHours >= 24);
            var hour = mgrLog.Where(x => x.Ok && (now - x.At).TotalHours < 1).Select(x => x.At).OrderBy(x => x).ToList();
            if (action != "resume" && hour.Count >= MgrActions.PerHour)
                return (null, MgrActions.PerHour == 0 ? 3600 : Math.Max(1, (int)Math.Ceiling((hour[hour.Count - MgrActions.PerHour].AddHours(1) - now).TotalSeconds)), "action-limit");
            if (item == 0 && action != "resume")
            {
                var mine = mgrLog.Where(x => x.Item == 0 && x.Worker == worker && x.Ok && x.Action != "resume").Select(x => x.At).OrderBy(x => x).ToList();
                if (mine.Count >= MgrActions.PerItemPerDay)
                    return (null, MgrActions.PerItemPerDay == 0 ? 86400 : Math.Max(60, (int)Math.Ceiling((mine[mine.Count - MgrActions.PerItemPerDay].AddHours(24) - now).TotalSeconds)), "name-action-limit");
            }
            var t = new MgrAction { At = now, Action = action, Item = item, Worker = Auth.ValidName(worker) ? worker : "", Policy = GatedCode(policy), By = Auth.ValidName(by) ? by : "operator" };
            mgrLog.Add(t); if (mgrLog.Count > 1000) mgrLog.RemoveAt(0);
            return (t, 0, "");
        }
    }
    public void ManagerActionDone(object? ticket, bool ok, string code = "", string worker = "")
    {
        if (ticket is not MgrAction t) return;
        lock (gate) { t.Ok = ok; t.Done = true; t.Code = GatedCode(code); if (worker != "" && Auth.ValidName(worker)) t.Worker = worker; }
        if (ok) OperatorPlantEvent("manager-" + t.Action, t.Item, t.Worker, "", t.Policy);
    }

    // drain and resume of a name by the supervisor. Its drain holds like the operator's (across reconnects and new sessions of the name, and a
    // graceful restart) until the supervisor or the operator resumes it. The operator's drain wins: the supervisor cannot resume it. A session's own
    // drain (end-session: its one item ended) is the session's, and the supervisor does not resume it either.
    public (int Exit, string Code, string Reason) ManagerDrain(string name, bool on)
    {
        lock (gate)
        {
            if (!workers.TryGetValue(name, out var w)) return (12, "no-such-worker", $"no worker session named {name} has registered");
            if (on)
            {
                if (drainedNames.Contains(name) || mgrDrained.Contains(name)) return (10, "already-draining", $"{name} is drained already");
                mgrDrained.Add(name); w.Draining = true;
                return (0, "", "");
            }
            if (drainedNames.Contains(name)) return (10, "operator-drain", $"the operator drained {name}: only the operator resumes it");
            if (!mgrDrained.Remove(name)) return (10, "not-drained-by-manager", w.Draining ? $"{name} drained itself (its one item ended): a new session of the name is offered work by itself" : $"{name} is not draining");
            // a spent session (one item per session) may have drained itself meanwhile: its drain stays; its next session registers undrained
            if (!(OneItemPerSession && w.SessionItems.Count > 0)) w.Draining = false;
            return (0, "", "");
        }
    }

    // restart-session: the session of a name is told to end (session.restart); its stream client writes the launcher's end marker (docs/launcher.md),
    // the launcher starts a new session from the connect prompt, and that session is resent the items the name owns (issue 81). Returns the items the
    // name owns, for their journals.
    public (int Exit, string Code, string Reason, List<int> Items) ManagerRestart(string name, string policy)
    {
        lock (gate)
        {
            if (!ownerHeldKnown) return (20, "sweep-pending", "the first sweep since the gateway started has not reported the owner's holds yet; try again in a minute", new());
            if (!workers.TryGetValue(name, out var w) || !w.Connected || w.Out == null) return (12, "not-connected", $"no session of {name} is connected", new());
            var items = ownerOf.Where(kv => kv.Value == name).Select(kv => kv.Key).OrderBy(i => i).ToList();
            if (items.FirstOrDefault(i => ownerHeld.Contains(i)) is var held and > 0) return (10, "owner-hold", $"{name} owns item #{held}, which carries the owner's hold: its session is left alone", new());
            Push(w, new JsonObject { ["provider"] = "gateway", ["event"] = "session.restart", ["name"] = name, ["session"] = w.Session, ["policy"] = GatedCode(policy),
                ["items"] = new JsonArray(items.Select(i => (JsonNode)i).ToArray()),
                ["reason"] = "the plant manager restarts this session: end it now (the launcher starts a new one, which resumes the items this name owns from their state)" }.ToJsonString(), false);
            return (0, "", "", items);
        }
    }
    public void JournalManagerAction(int item, JsonObject fields, string key) => Journal(item, "manager-action", fields, key);

    // release-owner after its rule script ended the claim's lease: the plant lets the owner go as a take-back does (Lease.cs Finish)
    public void ManagerReleased(int item, string holder) => Finish(item, holder, "released-by-plant-manager", true);

    // requeue after its rule script wrote the handoff: an offer of the item that waits for an answer, or for a worker, is dropped (with the sessions that
    // let it lapse), so the sweep this call requests offers it afresh
    public void ManagerRequeued(int item)
    {
        lock (gate)
        {
            foreach (var k in assignments.Keys.Where(k => k.StartsWith(item + "|", StringComparison.Ordinal) && !IsQc(assignments[k]) && !assignments[k].Accepted).ToList()) assignments.Remove(k);
            takenBackFrom.Remove(item);
        }
    }

    // Called by the ticker about once a second: the day's supervisor.summary-due, once per UTC day at or after the configured hour, to the supervisor's
    // stream (it is no message: no inbox entry, no delivery of the budget). A supervisor that connects later in the day gets it then.
    public void ManagerTick()
    {
        if (!Msg.ManagerEnabled || !Msg.Enabled || MgrActions.SummaryHourUtc < 0 || !Restored) return;
        lock (gate)
        {
            var now = DateTime.UtcNow; var day = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (summaryDay == day || now.Hour < MgrActions.SummaryHourUtc || store.Slot is not { Out: not null } slot) return;
            if (!slot.Out.Writer.TryWrite((0, new JsonObject { ["provider"] = "gateway", ["event"] = "supervisor.summary-due", ["day"] = day, ["since"] = now.AddHours(-24).ToString("o"),
                ["actions"] = mgrLog.Count(x => x.Ok && x.Done && (now - x.At).TotalHours < 24), ["mode"] = mgrModeOverride != "" ? mgrModeOverride : MgrActions.Mode,
                ["reason"] = "send the operator one summary of the last 24 hours: factory.ps1 metrics --since 24h and factory.ps1 act-log, in a few lines" }.ToJsonString()))) return;
            summaryDay = day;
        }
    }

    // GET /api/v1/manager/actions and the manager block of /status: the mode, the limits and the actions of the last 24 hours (names, numbers, codes).
    public JsonObject ManagerActionsStatus(bool withList)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            var done = mgrLog.Where(x => x.Done && (now - x.At).TotalHours < 24).ToList();
            var o = new JsonObject
            {
                ["mode"] = mgrModeOverride != "" ? mgrModeOverride : MgrActions.Mode, ["modeSource"] = mgrModeOverride != "" ? "operator" : "config",
                ["perHour"] = MgrActions.PerHour, ["perItemPerDay"] = MgrActions.PerItemPerDay, ["lastHour"] = mgrLog.Count(x => x.Ok && (now - x.At).TotalHours < 1),
                ["last24h"] = done.Count(x => x.Ok), ["refused24h"] = done.Count(x => !x.Ok),
                ["drained"] = new JsonArray(mgrDrained.OrderBy(x => x, StringComparer.Ordinal).Select(x => (JsonNode)x).ToArray()),
                ["ownerHeld"] = new JsonArray(ownerHeld.OrderBy(x => x).Select(x => (JsonNode)x).ToArray()),
                ["summaryHourUtc"] = MgrActions.SummaryHourUtc, ["summarySent"] = summaryDay == "" ? null : summaryDay
            };
            if (withList)
                o["actions"] = new JsonArray(done.TakeLast(200).Select(x => (JsonNode)new JsonObject { ["at"] = x.At.ToString("o"), ["action"] = x.Action, ["item"] = x.Item == 0 ? null : x.Item,
                    ["worker"] = x.Worker == "" ? null : x.Worker, ["policy"] = x.Policy, ["by"] = x.By, ["ok"] = x.Ok, ["code"] = x.Code == "" ? null : x.Code }).ToArray());
            return o;
        }
    }
}
