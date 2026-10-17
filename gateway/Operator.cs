using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;

// The factory operator SESSION (docs/design/operator-session.md): a third kind of session next to the workers and the supervisor. It watches the
// plant and improves the factory worker and the gateway themselves. One slot, like the supervisor's (the same ManagerSlot record: the same name
// replaces its older stream, another allowed name is refused while the active one was heard within timing.mgrTakeoverSeconds and takes over after).
// It is held apart from the workers and from the message store's recipients: it has no inbox, no presence entry, no place in the directory or the
// digest, and is never assigned work. What it receives on its stream:
//   message.received   every note addressed to "operator" (the same note the dashboard lists; marking it read is shared with the dashboard)
//   question.escalated a question the supervisor did not answer in time: id, item, worker, minutes; never its text
//   plant.event        one line per item milestone: code, item, worker, column, detail. Codes and names only, never free text.
// What the gateway enforces for it is here as well: the quiet-plant check and the bounded record of self-merged releases with the daily limit.
// Everything is in memory except the release records, which the rule scripts keep as refs (they must survive the restart a release causes).
sealed partial class Plant
{
    ManagerSlot? opSlot;
    DateTime? opHeard;
    long opNext = 1;
    readonly List<(long Id, string Json)> opBuffer = new();
    const int OpBufferCap = 200;
    // item-token verb calls that have not answered yet: (name, item, verb) by a ticket, for the quiet-plant check
    readonly Dictionary<long, (string Name, int Item, string Verb, DateTime At)> inFlight = new();
    long flightNext;
    // self-merged releases, newest last, at most ReleaseCap; counted per UTC day against operator.maxSelfMergesPerDay
    readonly List<(DateTime At, int Pr, string Version)> opReleases = new();
    public const int ReleaseCap = 100;
    static readonly Regex VersionRx = new(@"^[0-9]{1,6}(\.[0-9]{1,9}){1,3}\z", RegexOptions.CultureInvariant);
    public static bool ValidVersion(string v) => VersionRx.IsMatch(v);

    public string ActiveOperator() { lock (gate) return opSlot?.Name ?? ""; }
    public void OperatorHeard(string name) { lock (gate) { if (opSlot?.Name == name) opHeard = DateTime.UtcNow; } }

    public (bool Ok, string Active, DateTime Since, Channel<(long, string)>? Ch, List<(long, string)> Replay) RegisterOperator(string name, string model, string effort, long after)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var s = opSlot;
            if (s != null && s.Name != name && MessageStore.Within(opHeard, now, Msg.TakeoverSeconds)) return (false, s.Name, s.Since, null, new());
            if (s?.Out != null) { s.Out.Writer.TryWrite((0, ReplacedJson(s.Name))); s.Out.Writer.TryComplete(); }
            if (s == null || s.Name != name) opSlot = s = new ManagerSlot { Name = name, Since = now };
            s.Model = model; s.Effort = effort; s.ModelCheck = Msg.OperatorModelCheck(model, effort); s.RegisteredAt = now;
            s.Out = Channel.CreateUnbounded<(long, string)>();
            opHeard = now;
            // a reconnect with a cursor of this epoch gets what it missed; a new client starts from now (it reads the unread notes with its verbs)
            var replay = after > 0 ? opBuffer.Where(b => b.Id > after).Select(b => (b.Id, b.Json)).ToList() : new List<(long, string)>();
            return (true, name, s.Since, s.Out, replay);
        }
    }
    public void DisconnectOperator(Channel<(long, string)> ch) { lock (gate) { if (opSlot is { } s && s.Out == ch) s.Out = null; } }
    bool RevokeOperator(string name)
    {
        if (opSlot is not { } s || s.Name != name) return false;
        var open = s.Out != null;
        s.Out?.Writer.TryComplete(); opSlot = null; opHeard = null;
        return open;
    }

    void OperatorPush(JsonObject evt)
    {
        if (!Msg.OperatorEnabled) return;
        lock (gate)
        {
            var id = opNext++; var json = evt.ToJsonString();
            opBuffer.Add((id, json)); if (opBuffer.Count > OpBufferCap) opBuffer.RemoveAt(0);
            opSlot?.Out?.Writer.TryWrite((id, json));
        }
    }
    // A note addressed to the operator, as SendMessage accepted it.
    void OperatorNote(JsonObject template, string id)
    {
        if (!Msg.OperatorEnabled) return;
        var evt = (JsonObject)template.DeepClone();
        evt["to"] = "operator"; evt["id"] = id; evt["epoch"] = store.Epoch; evt["replayed"] = false;
        OperatorPush(evt);
    }
    // One item milestone. Every field is a number, a session name, or passes the code patterns of the digest (Gated, GatedCode): no free text.
    public void OperatorPlantEvent(string code, int item, string worker = "", string column = "", string detail = "")
    {
        if (!Msg.OperatorEnabled) return;
        OperatorPush(new JsonObject { ["provider"] = "gateway", ["event"] = "plant.event", ["code"] = GatedCode(code), ["item"] = item, ["worker"] = Auth.ValidName(worker) ? worker : "",
            ["column"] = Gated(column), ["detail"] = GatedCode(detail), ["at"] = DateTime.UtcNow.ToString("o") });
    }
    // The triggers the plant routes for an item (called under the gate by Route): parked, merged, done.
    void OperatorRouted(int item, JsonObject evt)
    {
        if (!Msg.OperatorEnabled) return;
        var code = evt["event"]?.ToString() switch { "item.parked" => "parked", "item.merged" => "merged", "item.complete" => "done", _ => null };
        if (code == null) return;
        ownerOf.TryGetValue(item, out var owner);
        OperatorPlantEvent(code, item, owner ?? "", ownedInfo.TryGetValue(item, out var oi) ? oi.Column : "", code == "parked" ? evt["reason"]?.ToString() ?? "" : "");
    }
    // After a verb of an item token answered: accepted, column completed, merge refused (merged arrives through Route).
    public void OperatorVerbEvent(string verb, int exit, Principal who, JsonObject request, string output)
    {
        if (!Msg.OperatorEnabled || who.Kind != "item") return;
        var code = verb == "accept" && exit == 0 ? "accepted" : verb == "complete" && exit == 0 ? "column-completed" : verb == "merge" && exit is 10 or 11 ? "merge-refused" : null;
        if (code == null) return;
        JsonNode? j = null; try { j = JsonNode.Parse(output); } catch { }
        // a failure report is a `complete` that answers exit 0 with parked true: the item did not advance, it waits for a person. The sweep routes
        // no item.parked for it (the worker parked it, not the sweep), so this is the only line the operator session gets.
        var parked = code == "column-completed" && j?["parked"] is JsonValue pv && pv.TryGetValue<bool>(out var pb) && pb;
        if (parked) code = "parked";
        // a `complete` that answered exit 0 has checked the column of its request against the board (stale-column otherwise), and a successful one
        // answers the board's own spelling. The plant's column is as old as the last sweep: a completion in Development seconds after the one in
        // Technical Design would still name the latter. Only `complete`: accept and merge do not check the column a session sends, so for them
        // the plant's own knowledge comes first, as before.
        var column = "";
        if (verb == "complete") { column = Gated(j?["column"]?.ToString()); if (column == "") column = Gated(request["column"]?.ToString()?.Trim()); }
        if (column == "") lock (gate) column = ownedInfo.TryGetValue(who.Item, out var oi) ? oi.Column : "";
        if (column == "") column = j?["column"]?.ToString() ?? request["column"]?.ToString() ?? "";
        OperatorPlantEvent(code, who.Item, who.Name, column, code == "merge-refused" ? j?["code"]?.ToString() ?? "" : parked ? j?["reason"]?.ToString() ?? "" : who.Role);
    }
    public void OperatorQuestionEscalated(EscalationJob job)
    {
        if (!Msg.OperatorEnabled) return;
        OperatorPush(new JsonObject { ["provider"] = "gateway", ["event"] = "question.escalated", ["id"] = job.Id, ["item"] = job.Item, ["worker"] = Auth.ValidName(job.Worker) ? job.Worker : "", ["minutes"] = job.Minutes, ["at"] = DateTime.UtcNow.ToString("o") });
    }

    // ---- the quiet-plant check (guard rail b) and the daily limit (guard rail d) ---------------------------------------------------------
    public long VerbStarted(string name, int item, string verb) { lock (gate) { var t = ++flightNext; inFlight[t] = (name, item, verb, DateTime.UtcNow); return t; } }
    public void VerbEnded(long ticket) { lock (gate) inFlight.Remove(ticket); }

    // the hourly cap of the session's own budget grants, and the cap on release records written in one day
    readonly List<(DateTime At, int N)> opGrants = new();
    public const int GrantsPerHour = 12, ReleaseWritesPerDay = 20;
    public bool OperatorGrant(int n)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; opGrants.RemoveAll(g => (now - g.At).TotalHours >= 1);
            if (opGrants.Sum(g => g.N) + n > GrantsPerHour) return false;
            opGrants.Add((now, n)); return true;
        }
    }
    public int ReleaseRecordsToday() { lock (gate) return ReleasesToday(DateTime.UtcNow); }
    int ReleasesToday(DateTime now) => opReleases.Count(r => r.At.Date == now.Date);
    public bool HasRelease(int pr) { lock (gate) return opReleases.Any(r => r.Pr == pr); }
    public void AddRelease(DateTime at, int pr, string version)
    {
        lock (gate)
        {
            if (opReleases.Any(r => r.Pr == pr)) return;
            opReleases.Add((at, pr, version)); if (opReleases.Count > ReleaseCap) opReleases.RemoveAt(0);
        }
    }
    JsonArray ReleaseRows(DateTime now) => new(opReleases.Where(r => r.At.Date == now.Date).Select(r => (JsonNode)new JsonObject { ["at"] = r.At.ToString("o"), ["pr"] = r.Pr, ["version"] = r.Version }).ToArray());

    public const int RecentOfferSeconds = 60;
    // quiet: no item-token verb call in flight, no open question, no offer waiting for its answer, no offer answered in the last RecentOfferSeconds.
    // allowed: quiet and under the daily limit.
    public JsonObject ReleaseCheck()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var reasons = new JsonArray();
            foreach (var f in inFlight.Values.OrderBy(f => f.At))
                reasons.Add(new JsonObject { ["code"] = "owner-mid-verb", ["worker"] = f.Name, ["item"] = f.Item, ["verb"] = f.Verb, ["seconds"] = (int)(now - f.At).TotalSeconds });
            foreach (var q in store.Records.Values.Where(q => q.Type == "question" && q.QState == "open").OrderBy(q => q.At))
                reasons.Add(new JsonObject { ["code"] = "open-question", ["id"] = q.Id, ["worker"] = q.From, ["item"] = q.Item });
            // a question the operator session answered itself a moment ago is not a quiet plant of its own making: it counts for timing.opSelfAnswerMinutes
            foreach (var q in store.Records.Values.Where(q => q.Type == "question" && q.QState == "answered" && q.AnsweredBy == Messenger.OpSession && q.AnsweredAt is { } at && (now - at).TotalMinutes < Msg.OperatorSelfAnswerMinutes).OrderBy(q => q.At))
                reasons.Add(new JsonObject { ["code"] = "answered-by-self", ["id"] = q.Id, ["worker"] = q.From, ["item"] = q.Item, ["minutesLeft"] = (int)Math.Ceiling(Msg.OperatorSelfAnswerMinutes - (now - q.AnsweredAt!.Value).TotalMinutes) });
            foreach (var a in assignments.Values.Where(a => !a.Accepted && a.Worker != "").OrderBy(a => a.Item))
                reasons.Add(new JsonObject { ["code"] = "pending-offer", ["worker"] = a.Worker, ["item"] = a.Item });
            // an offer that was answered less than RecentOfferSeconds ago: the session is still starting on it (its first verbs, its claim), and a restart
            // now loses the hand-over (enhancement 5). The offer's moment is its window's start: AckBy less the window (a window lengthened once for a
            // journal wait makes it look younger, which only holds the release back longer); an acceptance counts from AcceptedAt when that is later.
            foreach (var a in assignments.Values.Where(a => a.Accepted && a.Worker != "").OrderBy(a => a.Item))
            {
                var offeredAt = a.AckBy == default ? a.AcceptedAt : a.AckBy.AddSeconds(-ackSeconds);
                var last = a.AcceptedAt > offeredAt ? a.AcceptedAt : offeredAt;
                var age = Math.Max(0, (now - last).TotalSeconds);   // a window lengthened past now reads as just offered, never as more than the full wait
                if (age < RecentOfferSeconds) reasons.Add(new JsonObject { ["code"] = "recent-offer", ["worker"] = a.Worker, ["item"] = a.Item, ["secondsLeft"] = (int)Math.Ceiling(RecentOfferSeconds - age) });
            }
            var today = ReleasesToday(now); var limit = Msg.OperatorMaxSelfMergesPerDay; var quiet = reasons.Count == 0;
            var code = !quiet ? "not-quiet" : today >= limit ? "daily-limit" : "";
            var o = new JsonObject { ["ok"] = code == "", ["quiet"] = quiet, ["allowed"] = code == "", ["reasons"] = reasons, ["releasesToday"] = today, ["limit"] = limit,
                ["connected"] = new JsonArray(workers.Values.Where(w => w.Connected).OrderBy(w => w.Name, StringComparer.Ordinal).Select(w => (JsonNode)new JsonObject { ["name"] = w.Name, ["owned"] = new JsonArray(ownerOf.Where(kv => kv.Value == w.Name).Select(kv => (JsonNode)kv.Key).ToArray()) }).ToArray()),
                ["supervisor"] = store.Slot is { Out: not null } sl ? sl.Name : null };
            if (code != "")
            {
                o["code"] = code;
                o["reason"] = code == "not-quiet" ? "the plant is not quiet: do not merge now; wait and check again" : $"{today} self-merged releases are recorded today and the limit is {limit}: no further self-merge today; open the pull request and leave it for the owner";
            }
            o["exit"] = code == "" ? 0 : 10;
            return o;
        }
    }

    // The operator block of /status and of the dashboard JSON: names, states and counts.
    public JsonObject OperatorStatus()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var s = opSlot;
            return new JsonObject
            {
                ["enabled"] = Msg.OperatorEnabled, ["allowedNames"] = new JsonArray(Msg.OperatorNames.Select(n => (JsonNode)n).ToArray()),
                ["requiredModelTier"] = Msg.OperatorRequiredModelTier, ["requiredEffort"] = Msg.OperatorRequiredEffort,
                ["session"] = s == null ? null : new JsonObject { ["name"] = s.Name, ["connected"] = s.Out != null, ["present"] = MessageStore.Within(opHeard, now, Msg.OnlineSeconds), ["model"] = s.Model, ["effort"] = s.Effort,
                    ["modelCheck"] = s.ModelCheck, ["since"] = s.Since.ToString("o"), ["lastHeard"] = opHeard?.ToString("o") },
                ["releasesToday"] = ReleasesToday(now), ["limit"] = Msg.OperatorMaxSelfMergesPerDay, ["releases"] = ReleaseRows(now)
            };
        }
    }
}
