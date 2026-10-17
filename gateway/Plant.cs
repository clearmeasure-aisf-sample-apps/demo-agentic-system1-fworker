using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;

// The plant manager: a registry of workers, directed assignment of jobs to them, ownership of items, and routing of triggers to the owner.
// Design: docs/design/plant-manager.md sections 3 to 8.

sealed class WorkerInfo
{
    public string Name = "", Type = "persistent-local";
    public HashSet<string> Caps = new(), Roles = new() { "owner" };
    public int Capacity = 1;
    public bool Draining, Connected;
    public DateTime LastSeen = DateTime.UtcNow;
    public Channel<(long, string)>? Out;
    public int Missed;                                        // offers in a row this session let lapse (issue 31); any successful verb resets it
    public DateTime CoolUntil = DateTime.MinValue;            // until then it is offered no new work (unpinned)
    // issue 100: an item taken back from the session (its client accepted it and the session never started, or it did not answer item.check) is a
    // miss too; TakeBackMisses counts those among the misses in a row. A streak of OfferMissLimit misses with a take-back in it blocks the session:
    // it is offered nothing, pinned items included, until it calls a verb of its own (the client's own accept is not one) or a new session of the
    // name registers. BlockedItem is the item of the take-back that blocked it (for the plant event and the digest).
    public int TakeBackMisses;
    public DateTime? BlockedSince;
    public int BlockedItem;
    public List<(long Id, string Json)> Buffer = new();      // item triggers for replay; the event counter itself is the name's Recipient.Next
    public string Model = "", Effort = "";                   // declared at registration (worker-messaging.md 2.2), never verified
    public string Runtime = "local";                          // from the credential: a w2 names its runtime, a w1 is always local (cloud-worker-runtimes.md 4.1)
    // QC (design pr-qc-environment.md 4.2): environments this session may run at once, the address it declared for URL checks, free memory from its heartbeat
    public int QcCapacity = 1;
    public string QcAddress = "";
    public bool QcProfile;
    public double? MemFreeMb;
    // One work item per session (docs/launcher.md): a registration without a stream cursor starts a new session of this name.
    // SessionItems are the own-items this session accepted (and, from its start, the items the name still owned); once it holds one, nothing else is
    // offered to it. Sessions keeps the last few sessions of the name for the status.
    public int Session;
    public DateTime SessionStarted;
    public HashSet<int> SessionItems = new();
    public List<(int No, DateTime Started, List<int> Items)> Sessions = new();
    // issue 72: since when this session is spent and owns nothing (its item was taken back, released, demoted or reassigned), and the session
    // number a session.end event was sent for; the client writes the launcher's end marker on that event, so the loop does not rely on the model
    public DateTime? SpentIdleSince;
    public int SessionEndSent;
    public DateTime? DisconnectedAt;                          // when its stream ended (cleared by the next registration): its build slots go after a while
    // the launcher watchdog (docs/launcher.md): since when this session is spent and owns nothing, counted across reconnects (a reconnect is no
    // progress), the session number a session.restart was sent for, and a reason noted elsewhere (a repeated question) for the next tick to send
    public DateTime? StuckSince;
    public int RestartSent;
    public string RestartReason = "", RestartDetail = "";
}

sealed class Assignment
{
    public string Id = "", Key = "", Column = "", Kind = "own-item", Role = "owner", Mode = "first", Reason = "", Worker = "";
    public int Item, Pr;
    public DateTime CreatedAt, AckBy, AcceptedAt;
    public HashSet<string> Declined = new();
    public bool Accepted, AckExtended;   // AckExtended: the offer's window was lengthened once for a journal wait
    public DateTime? Accepting;          // the accept verb of the offered session is running (BeginAccept): the window does not lapse meanwhile
    public bool MatchedNoted;                      // its "matched" journal line is queued: once per assignment
    public string Sha = "", EnvId = "";            // qc-env only
    public int Attempt;
    public string Only = "";                       // qc-env: the one worker an operator chose (reassign); empty means the usual selection
    // own-item and bot-job: the worker named by the item's `worker:<name>` label, as the last sweep read it; empty means none. A pinned item is
    // only ever offered to that worker; PinRetryAt holds the next offer back after the pinned worker let one lapse.
    public string Pin = "";
    public DateTime PinRetryAt;
    public DateTime LastWaiting;
    // why no worker was chosen, as an enumerated code, and since when (worker-messaging.md 3.9); cleared by an offer
    public DateTime? WaitingSince;
    public string WaitingCode = "";
}

// What the sweep reports of one owned item (sync-board `owned`), or what a verb answer said of its lease until the next sweep (worker-messaging.md 3.9).
sealed record OwnedInfo(string Holder, string Column, DateTime? LeaseUntil, DateTime? Heartbeat, bool Parked, DateTime At);

sealed partial class Plant(string secret, Func<int, string, JsonObject, string, Task> journal, double ackSeconds)
{
    // The one lock (worker-messaging.md 3.5): workers, assignments, the directory maps, and the MessageStore (counters, inboxes, presence, modes,
    // the supervisor slot). Lock order: nothing is called under it that takes another lock, except a channel TryWrite and a signal completion,
    // which never run the reader's code inline.
    readonly object gate = new();
    readonly MessageStore store = new();
    public MessagingSettings Msg { get; set; } = new();
    public Revocations Rev { get; set; } = new();
    // plant.oneItemPerSession: a worker session holds at most one work item (own-item) in its life; the next item goes to a new session
    public bool OneItemPerSession { get; set; } = true;
    // issue 72: how long a spent session may own nothing (and have no offer of its item open) before it is told session.end; the pause covers a
    // column move in which the same session is offered its item again (timing.sessionEndGraceSeconds, FACTORY_TIMING_sessionEndGraceSeconds)
    public double SessionEndGraceSeconds { get; set; } = 90;
    // issue 97: the first column of the factory (new work); offers of later columns (work already started, orphaned by a take-back, a park or a lost
    // session) go first, and an unowned item past it is an orphan whose age the status shows
    public string IntakeColumn { get; set; } = "Technical Design";
    readonly Dictionary<int, DateTime> orphanSince = new();
    // issue 98: a pinned item that has waited this long for its pinned worker (away, at capacity, spent) is offered to any eligible worker, once
    // per pin, with a journal line (timing.pinFallbackMinutes; 0 is off). pinFallback: the items whose pin is set aside, with the pin it was.
    public double PinFallbackMinutes { get; set; } = 30;
    readonly Dictionary<int, string> pinFallback = new();
    // since when each pinned item has waited with its current pin (the wait counts from the pin, not from an unpinned wait before it)
    readonly Dictionary<int, (string Pin, DateTime Since)> pinWaitSince = new();

    // the launcher watchdog: a session still connected this long after it became spent and owns nothing (session.end was not acted on, or a stale
    // accepted offer kept it from being sent) is told session.restart; 0 switches it off (timing.sessionRestartMinutes)
    public double SessionRestartMinutes { get; set; } = 10;
    // a session that asks the same question more than this many times is told session.restart (timing.sessionRepeatQuestionLimit); 0 is off
    public int RepeatQuestionLimit { get; set; } = 2;
    readonly List<(DateTime At, string Name, int Session, string Reason)> restarts = new();
    long restartsSent;
    public string Epoch => store.Epoch;
    readonly Dictionary<string, WorkerInfo> workers = new();
    readonly Dictionary<string, Assignment> assignments = new();
    // issue 96: the accepted assignments (ids) the last sweep saw stale, and how many were dropped
    readonly HashSet<string> staleSeen = new();
    long staleDropped;
    // issue 96: items whose owner was dropped because they sit in the Release Queue (SetReleaseQueue); forgotten when they leave it
    readonly HashSet<int> rqOwnerDropped = new();
    // when an item's owner released it (kept an hour): a sweep that read the claim before the release does not put the owner back (as mergedAt, issue 107)
    readonly Dictionary<int, DateTime> releasedAt = new();
    readonly Dictionary<int, string> ownerOf = new(), botOf = new(), lastTrigger = new();
    // Plant data the digest is computed from (worker-messaging.md 3.9, step 5a), kept only while messaging or the supervisor is on: when an owner was
    // recorded (the grace of the sweep's replacement), what the sweep said of each owned item, the last request per (name, item), and the rings of
    // gate refusals and parks. Owners set through the test seam are never replaced by a sweep.
    readonly Dictionary<int, DateTime> ownedSince = new();
    readonly Dictionary<int, OwnedInfo> ownedInfo = new();
    readonly HashSet<int> seamOwned = new();
    // how many sweeps in a row did not list an owner: one sweep that misses a live claim (a slow read, a claim being rewritten) drops nobody
    readonly Dictionary<int, int> ownedMisses = new();
    readonly Dictionary<(string Name, int Item), DateTime> activity = new();
    readonly List<(DateTime At, int Item, string Name, string Code)> refusals = new();
    readonly List<(DateTime At, int Item, string Code)> parks = new();
    // the last trigger routed for an item, by its event name: a known wait (item.parked, hold.*, qc.*) is no stall (3.9)
    readonly Dictionary<int, string> lastRouted = new();
    string chooseCode = "";
    // The facts behind the conditions the supervisor reports (3.9 "Reported conditions"), kept only while messaging or the supervisor is on and all
    // bounded: the last verb call per (name, item); the verbs that failed (exit 20 or a crash) per item; the notes a worker sent the operator
    // about an item it owns (the id, never the text); the last review round a FINDINGS verdict recorded per item; the merges that ended in a
    // demotion; and the names that came back with a cursor of an earlier process, which is how this process knows it is a restart.
    readonly Dictionary<(string Name, int Item), DateTime> progress = new();
    readonly List<(DateTime At, int Item, string Name, string Code)> verbErrors = new();
    readonly List<(DateTime At, int Item, string Name, string Id)> operatorNotes = new();
    readonly Dictionary<int, (string Column, int Round, int Max, DateTime At)> reviews = new();
    readonly Dictionary<int, (int RoundTrip, DateTime At)> mergeRefused = new();
    readonly HashSet<string> returned = new();
    readonly DateTime startedAt = DateTime.UtcNow;
    // An item loses its owner: everything the plant kept about that ownership goes with it, so the next owner starts clean (it must not inherit a
    // sweep that missed the previous one, nor its lease).
    // Its build slots go too (issue 108): a take-back, a release, the item's completion and every drop of an owner come through here.
    void DropOwner(int item) { var was = ownerOf.TryGetValue(item, out var o) ? o : null; ownerOf.Remove(item); ownedMisses.Remove(item); ownedSince.Remove(item); ownedInfo.Remove(item); lastRouted.Remove(item); reviews.Remove(item); if (was != null) FreeItemSlots(item, was, "owner-dropped"); }
    static readonly Regex CodeRx = new(@"^[A-Za-z0-9: ._-]{1,60}\z", RegexOptions.CultureInvariant);
    // A column or code that may enter the digest: the pattern of 3.9, or nothing.
    static string Gated(string? s) => s != null && CodeRx.IsMatch(s) ? s : "";
    // A code (a refusal, a park reason, a waiting reason): no space, so no free text passes as one. Column names keep the space of Gated.
    static readonly Regex CodeOnlyRx = new(@"^[A-Za-z0-9:._-]{1,60}\z", RegexOptions.CultureInvariant);
    static string GatedCode(string? s) => s != null && CodeOnlyRx.IsMatch(s) ? s : "";
    // The triggers after which an owner legitimately waits (3.9); a wake-up (qc.approved, qc.failed, qc.ready, hold.cleared) is none of them.
    static readonly HashSet<string> WaitEvents = new() { "item.parked", "qc.requested", "qc.reset" };
    static DateTime? Time(JsonNode? n) => n != null && DateTime.TryParse(n.ToString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : null;
    // Presence from the last client-originated request (2, 4.6): online within the window, away within 10 minutes, offline after; never from a stream write.
    string PresenceOf(Recipient r, DateTime now) =>
        MessageStore.Within(r.LastHeard, now, Msg.OnlineSeconds) ? "online" : MessageStore.Within(r.LastHeard, now, Msg.AwaySeconds) ? "away" : "offline";
    // A QC job never touches ownerOf/botOf: this map is keyed by the assignment key ("item|qc-env|qc|pr") and holds the worker that accepted.
    readonly Dictionary<string, string> qcOf = new();
    // Assignment ids of QC jobs that were torn down, replaced or released. A path that read the QC records before that and acts on them afterwards
    // (a sweep's Reconcile, a late persist) must not bring such a job back: it would hold the worker's capacity for an environment that is gone.
    readonly HashSet<string> qcDead = new();
    public QcSettings QcCfg { get; set; } = new();
    // Raised (outside the lock) when the tick placed or moved a QC job that nobody asked for at that moment; the hub persists the new worker.
    public Func<Assignment, Task>? OnQcPlaced { get; set; }
    public static bool IsQc(Assignment a) => a.Kind == "qc-env";
    readonly Dictionary<int, List<(long Id, string Json)>> mailboxes = new();
    readonly Dictionary<int, long> mailboxNext = new();
    readonly SemaphoreSlim mailboxSignal = new(0, int.MaxValue);
    long counter;

    static readonly Dictionary<string, int> TypeOrder = new() { ["persistent-local"] = 1, ["claude-cloud"] = 2, ["cursor-cloud"] = 2, ["ephemeral-local"] = 3 };

    // ---- registry ---------------------------------------------------------------------------------------------------------------------
    // after: the cursor of this stream. With messaging off it is today's bare number (-1: nothing is replayed). With messaging on the caller has
    // parsed "<epoch>.<seq>" and passes 0 for another epoch, a bare number or no header, so the whole Buffer and every undelivered message replay.
    public (WorkerInfo W, Channel<(long, string)> Ch, List<(long, string)> Replay) Register(string name, string type, IEnumerable<string> caps, int capacity, IEnumerable<string> roles, long after, int qcCapacity = 1, string qcAddress = "", bool qcProfile = false, bool messagingClient = false, string model = "", string effort = "", bool newSession = true, bool handover = false, string runtime = "local")
    {
        lock (gate)
        {
            if (handover) handoverClients.Add(name); else handoverClients.Remove(name);
            if (!workers.TryGetValue(name, out var w)) workers[name] = w = new WorkerInfo { Name = name };
            // a (re)registration answers: offers lapsed while the gateway or the session was away do not count. A streak with a take-back in it is the
            // session's, not the stream's: a reconnect of the same session keeps it (and a block), a new session of the name starts clean (issue 100).
            if (newSession || w.Session == 0 || w.TakeBackMisses == 0) w.Missed = 0;
            w.CoolUntil = DateTime.MinValue;
            if (newSession || w.Session == 0)
            {   // a new session starts with what the name still owns: it resumes that item and is given no other
                w.TakeBackMisses = 0;
                if (w.BlockedSince != null) Unblock(w, "new-session");
                w.Session++; w.SessionStarted = DateTime.UtcNow;
                w.SessionItems = new(ownerOf.Where(kv => kv.Value == name).Select(kv => kv.Key));
                w.StuckSince = null; w.RestartReason = ""; w.RestartDetail = "";
                w.Sessions.Add((w.Session, w.SessionStarted, w.SessionItems.ToList()));
                if (w.Sessions.Count > 10) w.Sessions.RemoveAt(0);
            }
            w.Type = type; w.Caps = new(caps); w.Capacity = capOverride.TryGetValue(name, out var capSet) ? capSet : Math.Max(1, capacity); w.Roles = new(roles.Any() ? roles : new[] { "owner" });
            w.QcCapacity = Math.Clamp(qcCapacity, 1, 2); w.QcAddress = qcAddress; w.QcProfile = qcProfile;
            w.Connected = true; w.LastSeen = DateTime.UtcNow; w.Draining = drainedNames.Contains(name) || mgrDrained.Contains(name);   // issue 80: only the operator clears its drain (and the plant manager its own, Manager.cs)
            w.DisconnectedAt = null;
            w.SpentIdleSince = null; w.SessionEndSent = 0;   // a reconnect of a spent session is told session.end again after the grace
            w.RestartSent = 0;                                // and session.restart again, if it is still due
            w.Model = model; w.Effort = effort; w.Runtime = runtime;
            if (runtime != "local") RuntimeOf(name)?.Registered(name);
            // the older stream of this name is told it was replaced before it ends, so its client exits instead of reconnecting (4.6, failure mode 30)
            if (Msg.On && w.Out != null) w.Out.Writer.TryWrite((0, ReplacedJson(name)));
            w.Out?.Writer.TryComplete();
            w.Out = Channel.CreateUnbounded<(long, string)>();
            var replay = Msg.On ? MergedReplay(name, w.Buffer, after, messagingClient) : w.Buffer.Where(b => after >= 0 && b.Id > after).ToList();
            // issue 106: a new session (a stream without a cursor) is not replayed the triggers of items the name no longer owns: they are the
            // history of an earlier session's items (a reconnect with a cursor still gets every trigger it missed). Messages are always replayed.
            if (newSession) replay = replay.Where(rp => !StaleTrigger(rp.Item2, name)).ToList();
            if (Msg.On) { var rec = store.Get(name); rec.MessagingClient = messagingClient; rec.GoneAt = null; rec.Via = "stream"; if (Msg.PresenceAllowed(name)) rec.LastHeard = DateTime.UtcNow; }
            // what this name owns, and any assignment still waiting for its answer, is told again after a (re)connect
            var mine = ownerOf.Where(kv => kv.Value == name).Select(kv => kv.Key).ToList();
            if (mine.Count > 0) Push(w, new JsonObject { ["provider"] = "gateway", ["event"] = "ownership.restored", ["items"] = new JsonArray(mine.Select(i => (JsonNode)i).ToArray()) }.ToJsonString(), false);
            foreach (var a in assignments.Values.Where(a => a.Worker == name && !a.Accepted)) Push(w, AssignedJson(a), false);
            ResendAccepted(w);
            return (w, w.Out, replay);
        }
    }

    // Issue 81: an owner whose item.assigned (or the client's item.accepted) was lost, in a gateway restart or a dropped stream, would only renew its
    // claim and never work the item. Every (re)registration of the name, a new session included, and the snapshot restore resend item.assigned
    // for each accepted own-item assignment of an item the name still owns, with mode resume and resent: true (the client saves the token and does
    // not accept again; the session's own accept is idempotent). Only while the name owns the item: an owner that was dropped (merged and done,
    // released, taken back, reassigned) has no accepted assignment left (issue 74) and is told nothing, so a finished item is never revived.
    void ResendAccepted(WorkerInfo w)
    {
        foreach (var a in assignments.Values.Where(a => a.Accepted && a.Worker == w.Name && a.Kind == "own-item" && !IsQc(a) && ownerOf.TryGetValue(a.Item, out var o) && o == w.Name).ToList())
        {
            if (JsonNode.Parse(AssignedJson(a)) is not JsonObject j) continue;
            j["mode"] = "resume"; j["resent"] = true; j["accepted"] = true;
            Push(w, j.ToJsonString(), false);
        }
    }

    public void Disconnect(WorkerInfo w, Channel<(long, string)> ch) { lock (gate) { if (w.Out == ch) { w.Connected = false; w.Out = null; w.DisconnectedAt = DateTime.UtcNow; if (Msg.On) store.Get(w.Name).GoneAt = DateTime.UtcNow; } } }

    // ---- the hand-over to a newer gateway process (Leader.cs, issue 94) -----------------------------------------------------------------------
    // The names whose stream client reconnects on stream.replaced with reconnect (it registered with handover=1); an older client exits on any
    // stream.replaced, so its stream is only ended (it reconnects as after any drop).
    readonly HashSet<string> handoverClients = new(StringComparer.Ordinal);
    public void NoteHandover(string name, bool on) { lock (gate) { if (on) handoverClients.Add(name); else handoverClients.Remove(name); } }
    // Ends every stream of this process: workers and the supervisor get stream.replaced (reconnect) first when their client knows it; the operator
    // session's stream is ended (its client reconnects). Returns how many streams were ended.
    public int HandOver(string reason)
    {
        lock (gate)
        {
            string Json(string name) => new JsonObject { ["provider"] = "gateway", ["event"] = "stream.replaced", ["name"] = name, ["code"] = "gateway-replaced", ["reconnect"] = true, ["reason"] = reason }.ToJsonString();
            var n = 0;
            foreach (var w in workers.Values.Where(w => w.Out != null))
            {
                if (handoverClients.Contains(w.Name)) w.Out!.Writer.TryWrite((0, Json(w.Name)));
                w.Out!.Writer.TryComplete(); n++;
            }
            if (store.Slot is { Out: not null } sl) { if (handoverClients.Contains(sl.Name)) sl.Out.Writer.TryWrite((0, Json(sl.Name))); sl.Out.Writer.TryComplete(); n++; }
            if (opSlot is { Out: not null } op) { op.Out.Writer.TryComplete(); n++; }
            return n;
        }
    }

    // ---- messaging: replay, delivery, presence, the supervisor slot (worker-messaging.md 3.4 to 3.6, 4.6). Every method holds the gate. -----
    static string ReplacedJson(string name) => new JsonObject { ["provider"] = "gateway", ["event"] = "stream.replaced", ["name"] = name, ["reason"] = "a newer stream registered with this name; this one ends", ["exit"] = 40 }.ToJsonString();

    static string WithReplayed(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject o) return json;
        o["replayed"] = true; return o.ToJsonString();
    }

    // issue 106: a trigger of an item this name does not own (a message is never one): an earlier session's history, not replayed to a new session
    bool StaleTrigger(string json, string name)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject o || o["event"]?.ToString() == "message.received") return false;
            return o["item"] is JsonValue iv && iv.TryGetValue<int>(out var item) && item > 0 && !(ownerOf.TryGetValue(item, out var on) && on == name);
        }
        catch { return false; }
    }

    // The replay snapshot of one (re)connect: the Buffer's triggers and the undelivered inbox entries above the cursor, merged by seq. Taken in the
    // same critical section that creates the new channel, so a concurrent delivery lands either here or on the new channel, never between.
    List<(long, string)> MergedReplay(string name, List<(long Id, string Json)> buffer, long after, bool messagingClient)
    {
        var all = buffer.Where(b => b.Id > after).Select(b => (b.Id, b.Json)).ToList();
        if (messagingClient)
        {
            var r = store.Get(name);
            foreach (var e in r.Inbox.Where(e => e.Undelivered && e.Seq > after).ToList()) { SetState(r, e, "pushed"); all.Add((e.Seq, e.Json)); }
        }
        return all.OrderBy(x => x.Item1).Select(x => (x.Item1, WithReplayed(x.Item2))).ToList();
    }

    // ---- messages (worker-messaging.md 3.3 to 3.7). Every method below holds the gate and does the whole of its work in one critical section. ----
    const int InboxKeep = 500;      // delivered, handled or expired entries kept per inbox: a resource bound of this build (not in the design)
    const int RecordKeep = 5000;    // sender-side message records kept for GET /messages/{id}: likewise

    // The channel of a name that has one open: the supervisor's slot or a worker's stream.
    Channel<(long, string)>? ChannelOf(string name) => store.Slot is { } s && s.Name == name ? s.Out : workers.TryGetValue(name, out var w) ? w.Out : null;

    string NewMessageId() => $"m-{store.Epoch[2..]}-{++store.MessageCounter:D4}";

    static int Rank(string state) => state switch { "queued" => 0, "pushed" => 1, "delivered" => 2, "handled" => 3, _ => -1 };

    // One place changes the state of an inbox entry, and keeps the sender's record (which outlives the entry) in step.
    void SetState(Recipient r, InboxEntry e, string state)
    {
        if (e.State != state) switch (state) { case "pushed": store.Pushed++; break; case "delivered": store.Delivered++; break; case "handled": store.Handled++; break; case "expired": store.Expired++; break; }
        e.State = state;
        if (state == "handled") e.HandledAt = DateTime.UtcNow;
        if (e.Rec != null) e.Rec.Per[r.Name] = state;
    }

    MessageRecord NewRecord(string type, string kind, string from, string fromKind, int? item, string clientId, int bytes)
    {
        var rec = new MessageRecord { Id = NewMessageId(), N = store.MessageCounter, Type = type, Kind = kind, From = from, FromKind = fromKind, Item = item, ClientId = clientId, At = DateTime.UtcNow, Bytes = bytes };
        store.Records[rec.Id] = rec; store.RecordOrder.Enqueue(rec.Id);
        // the oldest records go first, but never an open question: it is the question table's only copy (3.8)
        for (var tries = store.RecordOrder.Count; store.Records.Count > RecordKeep && tries > 0 && store.RecordOrder.TryDequeue(out var old); tries--)
        {
            if (store.Records.TryGetValue(old, out var orec) && orec.Type == "question" && orec.QState == "open") store.RecordOrder.Enqueue(old);
            else store.Records.Remove(old);
        }
        return rec;
    }

    // One message into one name's inbox: its seq comes from the name's own counter (shared with triggers), it is not put into the 200-event Buffer, and
    // it is written to the open stream at once if that stream registered with messaging=1; otherwise it waits for the next connect or poll.
    InboxEntry DeliverEntry(Recipient r, JsonObject template, MessageRecord rec, bool peer)
    {
        var seq = r.Next++;
        var evt = (JsonObject)template.DeepClone();
        evt["to"] = r.Name; evt["id"] = rec.Id; evt["seq"] = seq; evt["epoch"] = store.Epoch; evt["replayed"] = false;
        var entry = new InboxEntry { Seq = seq, Id = rec.Id, At = DateTime.UtcNow, From = rec.From, FromKind = rec.FromKind, Type = rec.Type, Peer = peer, Rec = rec };
        r.Inbox.Add(entry);
        rec.Per[r.Name] = "queued";
        evt["unacked"] = r.Inbox.Count(e => e.Undelivered);
        entry.Json = evt.ToJsonString();
        var ch = ChannelOf(r.Name);
        if (ch != null && r.MessagingClient && ch.Writer.TryWrite((seq, entry.Json))) SetState(r, entry, "pushed");
        // wakes every poller of this name at once; the signal is swapped so the next wait gets a fresh one
        r.Signal.TrySetResult(); r.Signal = Recipient.NewSignal();
        if (r.Inbox.Count > InboxKeep)
        {   // keep the undelivered ones; drop the oldest delivered, handled or expired entries first
            var drop = r.Inbox.Where(e => !e.Undelivered).OrderBy(e => e.Seq).Take(r.Inbox.Count - InboxKeep).ToList();
            foreach (var d in drop) r.Inbox.Remove(d);
        }
        return entry;
    }

    // The test seam's way in: a ready-made event for one name (no limits, no checks).
    public (string Id, long Seq, bool Pushed) Deliver(string to, JsonObject evt)
    {
        lock (gate)
        {
            int? item = evt["item"] is JsonValue iv && iv.TryGetValue<int>(out var i) ? i : null;
            var rec = NewRecord(evt["type"]?.ToString() ?? "note", evt["kind"]?.ToString() ?? "direct", evt["from"]?.ToString() ?? "", evt["fromKind"]?.ToString() ?? "", item, "", 0);
            var e = DeliverEntry(store.Get(to), evt, rec, false);
            return (rec.Id, e.Seq, e.State == "pushed");
        }
    }

    // May a message be addressed to this name? An explicit allow-list entry always (the message waits for a name that has not connected since the
    // restart); "*" only for a name that has registered; the operator may also reach a name that only asks the supervisor.
    // trusted: the operator or the supervisor is the sender. operatorNote: the operator alone, whose note is the one message that reaches the
    // supervisor besides question batches and patrols (3.4): the name that holds the slot, or any supervisor name while nobody holds it.
    bool CanReceive(string name, bool trusted, bool operatorNote)
    {
        if (Msg.ManagerNames.Contains(name)) return operatorNote && Msg.ManagerEnabled && (store.Slot == null || store.Slot.Name == name);
        if (Msg.AllowedWorkers.Contains(name)) return true;
        var known = store.Recipients.TryGetValue(name, out var rr) && rr.LastHeard != null;
        if (Msg.AllowedWorkers.Contains("*") && known) return true;
        return trusted && Msg.ManagerEnabled && (Msg.AllowedAskers.Contains(name) || (Msg.AllowedAskers.Contains("*") && known));
    }

    // A note (or a question) from an authenticated, allowed sender: everything that depends on live state is decided here, under the one lock:
    // the sender's mode, the recipient's mode, the queue caps for peer notes, the open questions of an asker. A partial result is possible for
    // several recipients (step 4); with one recipient its refusal is the answer.
    public SendOutcome SendMessage(SendSpec s, int bytes)
    {
        var o = new SendOutcome();
        lock (gate)
        {
            if (s.FromKind == "worker")
            {
                var sm = store.Get(s.From).Mode;
                if (sm == "off" || (sm == "mute" && !s.Question)) { o.Code = "muted"; o.Reason = "the operator set this session's messaging mode to " + sm + (sm == "mute" ? " (questions are still allowed)" : ""); return o; }
            }
            if (s.Question)
            {
                var open = store.Records.Values.Where(q => q.Type == "question" && q.QState == "open" && q.From == s.From).ToList();
                if (s.Item != null && open.Any(q => q.Item == s.Item)) { o.Code = "item-has-open-question"; o.Reason = $"a question about item #{s.Item} is still open; one open question per item"; return o; }
                if (open.Count >= Msg.MaxOpenQuestions) { o.Code = "too-many-open"; o.Reason = $"{open.Count} questions are open; at most {Msg.MaxOpenQuestions} at a time"; return o; }
                var q = NewRecord("question", "question", s.From, s.FromKind, s.Item, s.ClientId, bytes);
                q.QState = "open"; o.Id = q.Id;
                q.QText = s.Event["text"]?.ToString() ?? ""; q.QContext = s.Context;
                q.QFlags = s.Event["flags"] is JsonArray qf ? qf.Select(f => f!.ToString()).ToArray() : Array.Empty<string>();
                // a question of the item's owner becomes moot when it loses the item before the question is delivered (3.8)
                q.OwnedAtAsk = s.Item is int qi && ownerOf.TryGetValue(qi, out var qo) && qo == s.From;
                NoteRepeatedQuestion(s.From, q);
                return o;
            }
            // the recipients: the one named, or derived for a thread (the item's owner and its QC worker, never its inspector) and for a
            // broadcast (every other allowed worker session that is online or away; a session that is off is hidden from a worker here as in the directory). No branch here ever names the supervisor (3.4).
            var fan = s.Broadcast || s.Thread != null;
            IReadOnlyList<string> names = s.To;
            if (s.Thread is int ti)
            {
                ownerOf.TryGetValue(ti, out var own); botOf.TryGetValue(ti, out var bot);
                if (s.FromKind == "worker" && own != s.From) { o.Code = "forbidden"; o.Reason = $"only the owner of item #{ti} posts to its thread"; return o; }
                var set = new List<string>();
                if (own != null) set.Add(own);
                set.AddRange(qcOf.Where(kv => kv.Key.StartsWith(ti + "|qc-env|", StringComparison.Ordinal)).Select(kv => kv.Value));
                names = set.Where(n => n != s.From && n != bot && Msg.WorkerAllowed(n) && !Msg.ManagerNames.Contains(n)).Distinct().OrderBy(n => n, StringComparer.Ordinal).ToList();
            }
            else if (s.Broadcast && s.Supervisor)
            {   // a directive or an announcement to all: every listed worker session once, the offline ones through their inbox (3.8)
                var now = DateTime.UtcNow;
                names = store.Recipients.Values.Where(r => r.LastHeard != null && !Msg.ManagerNames.Contains(r.Name) && (Msg.WorkerAllowed(r.Name) || Msg.AskerAllowed(r.Name))
                    && (now - r.LastHeard!.Value).TotalMinutes <= Msg.OfflineListMinutes).Select(r => r.Name)
                    // a connected session that may only ask has no presence record: it is a worker session all the same
                    .Concat(workers.Values.Where(w => w.Connected && Msg.AskerAllowed(w.Name) && !Msg.ManagerNames.Contains(w.Name)).Select(w => w.Name))
                    .Distinct().OrderBy(n => n, StringComparer.Ordinal).ToList();
            }
            else if (s.Broadcast && s.Operator)
            {   // the operator to everyone: every session that is online or away (a worker on either list, a connected session that may only ask)
                // and the supervisor that holds the slot, each once. The workers' limits, pairs and the broadcast switch do not apply (3.4).
                var now = DateTime.UtcNow;
                var all = store.Recipients.Values.Where(r => r.LastHeard != null && !Msg.ManagerNames.Contains(r.Name) && (Msg.WorkerAllowed(r.Name) || (Msg.ManagerEnabled && Msg.AskerAllowed(r.Name)))
                    && PresenceOf(r, now) != "offline").Select(r => r.Name)
                    .Concat(workers.Values.Where(w => w.Connected && Msg.ManagerEnabled && Msg.AskerAllowed(w.Name) && !Msg.ManagerNames.Contains(w.Name)).Select(w => w.Name)).ToList();
                if (Msg.ManagerEnabled && store.Slot is { } sl && (sl.Out != null || MessageStore.Within(store.Get(sl.Name).LastHeard, now, Msg.OnlineSeconds))) all.Add(sl.Name);
                names = all.Distinct().OrderBy(n => n, StringComparer.Ordinal).ToList();
            }
            else if (s.Broadcast)
            {
                var now = DateTime.UtcNow;
                names = store.Recipients.Values.Where(r => r.Name != s.From && r.LastHeard != null && Msg.WorkerAllowed(r.Name) && !Msg.ManagerNames.Contains(r.Name)
                    && PresenceOf(r, now) != "offline" && !(s.FromKind == "worker" && (Paired(s.From, r.Name) || r.Mode == "off"))).Select(r => r.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();
            }
            var targets = new List<(string Name, Recipient? R)>();
            foreach (var name in names)
            {
                if (name == "operator") { targets.Add((name, null)); continue; }
                if (!CanReceive(name, s.Operator || s.Supervisor, s.Operator)) { o.Refused.Add((name, "no-such-peer")); continue; }
                // the owner and the inspector of one item do not message each other, in either direction (4.4)
                if (s.Peer && Paired(s.From, name)) { o.Refused.Add((name, "independence")); continue; }
                var r = store.Get(name);
                if (r.Mode == "off" || (r.Mode == "inbound-off" && s.Peer)) { o.Refused.Add((name, fan && r.Mode == "off" ? "off" : "not-accepting")); continue; }
                if (s.Peer && (r.Inbox.Count(e => e.Undelivered && e.From == s.From) >= Msg.PerSenderQueueCap || r.Inbox.Count(e => e.Undelivered && e.Peer) >= Msg.RecipientQueueCap))
                { o.Refused.Add((name, "queue-full")); continue; }
                targets.Add((name, r));
            }
            if (targets.Count == 0)
            {
                o.Code = !fan && o.Refused.Count == 1 ? o.Refused[0].Code : "no-such-peer";
                o.Reason = o.Code switch
                {
                    "independence" => "the owner and the inspector of one item do not message each other (worker-messaging.md 4.4)",
                    "not-accepting" => "that session does not accept messages now",
                    "queue-full" => "that session already holds the most undelivered peer notes it will queue; wait for it to read them",
                    _ => fan ? "no session receives this message" : "no session of that name receives messages"
                };
                return o;
            }
            var rec = NewRecord(s.Type, s.Kind, s.From, s.FromKind, s.Item, s.ClientId, bytes);
            o.Id = rec.Id;
            foreach (var (name, r) in targets)
            {
                if (r == null)
                {   // the operator log: no push. A worker's note about an item it owns is a fact of the digest (3.9): the item and the id only
                    rec.Per[name] = "queued"; o.Delivered.Add((name, "queued")); o.Queued++;
                    OperatorNote(s.Event, rec.Id);   // the operator session, if one is connected, gets it on its stream
                    if (s.FromKind == "worker" && (s.Item ?? (ownerOf.Count(kv => kv.Value == s.From) == 1 ? ownerOf.First(kv => kv.Value == s.From).Key : 0)) is var about && about > 0 && ownerOf.TryGetValue(about, out var noteOwner) && noteOwner == s.From)
                    {   // the ring of 200 is shared: one sender keeps at most 10 in it, so a noisy worker cannot push the others' notes out
                        if (operatorNotes.Count(x => x.Name == s.From) >= 10) operatorNotes.RemoveAt(operatorNotes.FindIndex(x => x.Name == s.From));
                        operatorNotes.Add((DateTime.UtcNow, about, s.From, rec.Id)); if (operatorNotes.Count > 200) operatorNotes.RemoveAt(0);
                    }
                    continue;
                }
                var e = DeliverEntry(r, s.Event, rec, s.Peer);
                var pushed = e.State == "pushed";
                o.Delivered.Add((name, pushed ? "pushed" : "queued"));
                if (pushed) o.Pushed++; else o.Queued++;
            }
        }
        return o;
    }

    // ---- the directory (2.2, 3.2, 4.4). Built only from DigestSource(), an explicit field list: never from Status(), which carries the QC address,
    // the QC profile and assignment ids. ----------------------------------------------------------------------------------------------------
    // Owner and inspector of one item, in either order (4.4). One name holding both roles of an item is no pair: there is nobody to separate.
    bool Paired(string a, string b) => a != b && ownerOf.Any(kv => botOf.TryGetValue(kv.Key, out var bot) && ((kv.Value == a && bot == b) || (kv.Value == b && bot == a)));

    sealed record SessionView(string Name, string Type, string[] Roles, string[] Caps, int Capacity, string Model, bool Draining, (int Item, string Column, bool SelfInspected)[] Owned,
        int[] Inspecting, int QcActive, string Presence, string Via, DateTime? LastSeen, string Summary, DateTime SummaryAt, string Mode, bool StreamWithoutMessaging, bool Allowed);

    // Every session that was heard, except the supervisor names. Holds the gate (called under it).
    List<SessionView> DigestSource()
    {
        var now = DateTime.UtcNow; var list = new List<SessionView>();
        foreach (var r in store.Recipients.Values.Where(r => r.LastHeard != null && !Msg.ManagerNames.Contains(r.Name)).OrderBy(r => r.Name, StringComparer.Ordinal))
        {
            workers.TryGetValue(r.Name, out var w);
            var owned = ownerOf.Where(kv => kv.Value == r.Name).OrderBy(kv => kv.Key)
                .Select(kv => (kv.Key, ownedInfo.TryGetValue(kv.Key, out var oi) && oi.Column != "" ? oi.Column : assignments.TryGetValue($"{kv.Key}|own-item|owner", out var a) ? a.Column : "", botOf.TryGetValue(kv.Key, out var b) && b == r.Name)).ToArray();
            list.Add(new SessionView(r.Name, w?.Type ?? "", w?.Roles.OrderBy(x => x, StringComparer.Ordinal).ToArray() ?? Array.Empty<string>(), w?.Caps.OrderBy(x => x, StringComparer.Ordinal).ToArray() ?? Array.Empty<string>(),
                w?.Capacity ?? 0, w?.Model ?? "", w?.Draining ?? false, owned, botOf.Where(kv => kv.Value == r.Name).Select(kv => kv.Key).OrderBy(i => i).ToArray(), QcActive(r.Name),
                PresenceOf(r, now), r.Via, r.LastHeard, r.Summary, r.SummaryAt, r.Mode, w is { Connected: true } && !r.MessagingClient, Msg.WorkerAllowed(r.Name)));
        }
        return list;
    }

    JsonObject? SupervisorBlock(bool brief)
    {
        if (!Msg.ManagerEnabled) return null;
        var slot = store.Slot; var now = DateTime.UtcNow;
        var sr = slot != null ? store.Get(slot.Name) : null;
        var present = sr != null && MessageStore.Within(sr.LastHeard, now, Msg.OnlineSeconds);
        if (brief) return new JsonObject { ["present"] = present, ["model"] = slot?.Model ?? "", ["modelCheck"] = slot?.ModelCheck };
        return new JsonObject { ["name"] = slot?.Name, ["present"] = present, ["model"] = slot?.Model ?? "", ["effort"] = slot?.Effort ?? "", ["modelCheck"] = slot?.ModelCheck, ["since"] = slot?.Since.ToString("o"), ["lastHeard"] = sr?.LastHeard?.ToString("o"),
            ["openQuestions"] = store.Records.Values.Count(q => q.Type == "question" && q.QState == "open"), ["availability"] = QuestionBudgetLeft(now, out _) ? "ok" : "budget-exhausted" };
    }

    // GET /peers. viewer null: the operator, who sees every session (also one that is off or not on the allow-list) and the self-inspected flag.
    // A worker sees the allow-listed sessions that are not off, never itself, and whether it may write to each (canMessage, with the reason).
    // includeOffline adds the sessions not heard for 10 minutes (they are dropped from the list after 60).
    public JsonObject Directory(string? viewer, bool viewerInspectorToken, bool includeOffline)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var peers = new JsonArray();
            var myMode = viewer != null ? store.Get(viewer).Mode : "on";
            foreach (var v in DigestSource())
            {
                if (v.Presence == "offline" && (!includeOffline || (now - v.LastSeen!.Value).TotalMinutes > Msg.OfflineListMinutes)) continue;
                if (viewer != null && (v.Name == viewer || !v.Allowed || v.Mode == "off")) continue;
                var o = new JsonObject
                {
                    ["name"] = v.Name, ["type"] = v.Type, ["roles"] = new JsonArray(v.Roles.Select(x => (JsonNode)x).ToArray()), ["capabilities"] = new JsonArray(v.Caps.Select(x => (JsonNode)x).ToArray()),
                    ["capacity"] = v.Capacity, ["model"] = v.Model,
                    ["owned"] = new JsonArray(v.Owned.Select(x => { var e = new JsonObject { ["item"] = x.Item, ["column"] = x.Column, ["role"] = "owner" }; if (viewer == null && x.SelfInspected) e["selfInspected"] = true; return (JsonNode)e; }).ToArray()),
                    ["inspecting"] = new JsonArray(v.Inspecting.Select(x => (JsonNode)x).ToArray()), ["qcActive"] = v.QcActive, ["draining"] = v.Draining,
                    ["presence"] = v.Presence, ["via"] = v.Via, ["lastSeen"] = v.LastSeen?.ToString("o"),
                    ["summary"] = v.Summary == "" ? null : new JsonObject { ["text"] = v.Summary, ["at"] = v.SummaryAt.ToString("o"), ["untrusted"] = true },
                    ["messaging"] = v.Mode
                };
                if (viewer != null)
                {
                    var reason = myMode is "mute" or "off" ? "muted" : viewerInspectorToken || Paired(viewer, v.Name) ? "independence" : v.Mode == "inbound-off" ? "not-accepting" : v.StreamWithoutMessaging ? "client-too-old" : "";
                    o["canMessage"] = reason == "";
                    if (reason != "") o["reason"] = reason;
                }
                else
                {   // the operator's view only: what waits undelivered in this session's inbox
                    if (!v.Allowed) o["allowed"] = false;
                    o["unacked"] = store.Recipients.TryGetValue(v.Name, out var vr) ? vr.Inbox.Count(e => e.Undelivered) : 0;
                }
                peers.Add(o);
            }
            if (viewer == null)
            {   // the operator also sees the sessions whose names are on no list (they have no presence record): what their stream says, flagged
                foreach (var w in workers.Values.Where(w => !Msg.ManagerNames.Contains(w.Name) && !(store.Recipients.TryGetValue(w.Name, out var wr) && wr.LastHeard != null) && (w.Connected || includeOffline)).OrderBy(w => w.Name, StringComparer.Ordinal))
                    peers.Add(new JsonObject
                    {
                        ["name"] = w.Name, ["type"] = w.Type, ["roles"] = new JsonArray(w.Roles.OrderBy(x => x, StringComparer.Ordinal).Select(x => (JsonNode)x).ToArray()), ["capacity"] = w.Capacity, ["model"] = w.Model,
                        ["owned"] = new JsonArray(ownerOf.Where(kv => kv.Value == w.Name).OrderBy(kv => kv.Key).Select(kv => (JsonNode)new JsonObject { ["item"] = kv.Key, ["role"] = "owner" }).ToArray()),
                        ["draining"] = w.Draining, ["presence"] = w.Connected ? "online" : "offline", ["via"] = "stream", ["messaging"] = store.Get(w.Name).Mode, ["allowed"] = false
                    });
            }
            return new JsonObject { ["ok"] = true, ["epoch"] = store.Epoch, ["self"] = viewer ?? "operator", ["messaging"] = new JsonObject { ["enabled"] = Msg.Enabled, ["broadcast"] = Msg.AllowBroadcast },
                ["supervisor"] = SupervisorBlock(false), ["peers"] = peers, ["exit"] = 0 };
        }
    }

    // The one peers.snapshot line of a registration (3.2): names, roles and items of the sessions a worker may see, and the supervisor block; no
    // summaries. Not buffered, not replayed.
    public string PeersSnapshot(string viewer)
    {
        lock (gate)
        {
            var peers = DigestSource().Where(v => v.Name != viewer && v.Allowed && v.Mode != "off" && v.Presence != "offline")
                .Select(v => (JsonNode)new JsonObject { ["name"] = v.Name, ["roles"] = new JsonArray(v.Roles.Select(x => (JsonNode)x).ToArray()), ["items"] = new JsonArray(v.Owned.Select(x => (JsonNode)x.Item).ToArray()) }).ToArray();
            return new JsonObject { ["provider"] = "gateway", ["event"] = "peers.snapshot", ["supervisor"] = SupervisorBlock(true), ["peers"] = new JsonArray(peers) }.ToJsonString();
        }
    }

    // supervisor.joined and supervisor.left (3.2), to every worker stream that registered with messaging=1; id 0, so never a cursor, never replayed.
    // Debounced: joined only after a left or when the declared model changed, left only after the supervisor was not heard for LeftSeconds.
    bool supAnnounced; string supAnnouncedModel = "";
    void TellWorkers(JsonObject evt)
    {
        var json = evt.ToJsonString();
        foreach (var w in workers.Values) if (w.Out != null && store.Recipients.TryGetValue(w.Name, out var r) && r.MessagingClient) w.Out.Writer.TryWrite((0, json));
    }
    void AnnounceSupervisor(ManagerSlot s)
    {
        if (supAnnounced && supAnnouncedModel == s.Model) return;
        supAnnounced = true; supAnnouncedModel = s.Model;
        TellWorkers(new JsonObject { ["provider"] = "gateway", ["event"] = "supervisor.joined", ["name"] = s.Name, ["model"] = s.Model, ["effort"] = s.Effort, ["modelCheck"] = s.ModelCheck });
    }
    // Called by the ticker while the supervisor is enabled.
    public void SupervisorPresenceTick()
    {
        lock (gate)
        {
            if (store.Slot is not { } s) return;
            var heard = store.Get(s.Name).LastHeard; var now = DateTime.UtcNow;
            if (supAnnounced && !MessageStore.Within(heard, now, Msg.LeftSeconds))
            { supAnnounced = false; TellWorkers(new JsonObject { ["provider"] = "gateway", ["event"] = "supervisor.left", ["name"] = s.Name }); }
            else if (!supAnnounced && MessageStore.Within(heard, now, Math.Min(Msg.OnlineSeconds, Msg.LeftSeconds))) AnnounceSupervisor(s);
        }
    }

    // The test seam's way to give an item an owner, an inspector and a QC worker without a sweep (messaging.testHooks only). An empty name clears.
    // sweepable: the owner is recorded as an accept would record it, so the sweep's replacement applies to it (the scenarios of that replacement).
    public void TestSetRoles(int item, string? owner, string? inspector, string? qcWorker, bool sweepable = false)
    {
        lock (gate)
        {
            if (owner != null) { if (owner == "") { DropOwner(item); seamOwned.Remove(item); } else { ownerOf[item] = owner; if (sweepable) { seamOwned.Remove(item); ownedSince[item] = DateTime.UtcNow; ownedMisses.Remove(item); } else seamOwned.Add(item); } }
            if (inspector != null) { if (inspector == "") botOf.Remove(item); else botOf[item] = inspector; }
            if (qcWorker != null) { var key = $"{item}|qc-env|qc|0"; if (qcWorker == "") qcOf.Remove(key); else qcOf[key] = qcWorker; }
        }
    }

    // The caller's undelivered messages (queued or pushed) above a cursor, ascending by seq, each as its event plus the state; with includeDelivered
    // also the delivered, unhandled ones. A poll never changes a state (3.5).
    List<JsonNode> PageLocked(string name, long after, int limit, bool includeDelivered, out long last)
    {
        var rows = store.Get(name).Inbox.Where(e => e.Seq > after && (e.Undelivered || (includeDelivered && e.State == "delivered"))).OrderBy(e => e.Seq).Take(limit).ToList();
        var list = new List<JsonNode>();
        foreach (var e in rows) { var o = (JsonObject)JsonNode.Parse(e.Json)!; o["state"] = e.State; list.Add(o); }
        last = rows.Count > 0 ? rows[^1].Seq : 0;
        return list;
    }

    public (List<JsonNode> Messages, long Last) InboxPage(string name, long after, int limit, bool includeDelivered)
    {
        lock (gate) { var l = PageLocked(name, after, limit, includeDelivered, out var last); return (l, last); }
    }

    // One message of this inbox in whatever state it is still held (inbox --id).
    public JsonObject? InboxOne(string name, string id)
    {
        lock (gate)
        {
            var e = store.Get(name).Inbox.FirstOrDefault(x => x.Id == id && x.State != "expired");
            if (e == null) return null;
            var o = (JsonObject)JsonNode.Parse(e.Json)!; o["state"] = e.State; return o;
        }
    }

    // GET /wait?item=N&messages=1: the item's triggers above a cursor and the caller's undelivered messages; returns at once when either exists, and
    // otherwise wakes on a delivery to this name, on a trigger for the item, or at the timeout (3.5 "Waking"). The item-level wait keeps its 2 s re-check.
    public async Task<(List<(long, string)> Events, List<JsonNode> Messages, long LastMsg, bool Timeout)> WaitAny(int item, long after, string name, long afterMsg, TimeSpan timeout, CancellationToken ct)
    {
        var end = DateTime.UtcNow + timeout;
        while (true)
        {
            Task sig; List<(long, string)> ev; List<JsonNode> msgs; long last;
            lock (gate)
            {
                sig = store.Get(name).Signal.Task;
                ev = mailboxes.TryGetValue(item, out var box) ? box.Where(b => b.Id > after).Select(b => (b.Id, b.Json)).ToList() : new();
                msgs = PageLocked(name, afterMsg, 50, false, out last);
            }
            if (ev.Count > 0 || msgs.Count > 0) return (ev, msgs, last, false);
            var left = end - DateTime.UtcNow;
            if (left <= TimeSpan.Zero || ct.IsCancellationRequested) return (new(), new(), 0, true);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var sem = mailboxSignal.WaitAsync(left > TimeSpan.FromSeconds(2) ? TimeSpan.FromSeconds(2) : left, cts.Token);
            await Task.WhenAny(sig, sem);
            cts.Cancel();
        }
    }

    // POST /messages/ack: the caller's own inbox only. ids (any of queued, pushed, delivered) or every entry up to a seq; idempotent; a state only
    // moves forward (delivered never undoes handled); an unknown or expired id is counted, not an error.
    public (int Acked, int Unknown) AckMessages(string name, IReadOnlyList<string>? ids, long upTo, string state)
    {
        lock (gate)
        {
            var r = store.Get(name); int acked = 0, unknown = 0;
            void Move(InboxEntry e) { if (Rank(state) > Rank(e.State)) SetState(r, e, state); }
            if (ids != null)
            {
                foreach (var id in ids)
                {
                    var e = r.Inbox.FirstOrDefault(x => x.Id == id && x.State != "expired");
                    if (e == null) { unknown++; continue; }
                    Move(e); acked++;
                }
            }
            else foreach (var e in r.Inbox.Where(x => x.Seq <= upTo && x.State != "expired").ToList()) { Move(e); acked++; }
            return (acked, unknown);
        }
    }

    // The sender's view of one message (null: unknown, or somebody else's). asker null is the operator, who may read any.
    public MessageSnapshot? MessageStatus(string id, string? asker)
    {
        lock (gate)
        {
            if (!store.Records.TryGetValue(id, out var rec) || (asker != null && rec.From != asker)) return null;
            return new MessageSnapshot { Id = rec.Id, Type = rec.Type, Kind = rec.Kind, State = rec.State(), From = rec.From, AnswerJson = rec.AnswerJson, Item = rec.Item, At = rec.At, Per = new(rec.Per),
                Late = rec.Type == "question" && rec.QState == "open" && (DateTime.UtcNow - rec.At).TotalSeconds >= Msg.AnswerSlaSeconds, Escalated = rec.Escalated };
        }
    }

    // The operator's side of the notes addressed to it (3.3): a note to the operator waits as "queued" in its sender's record until the operator
    // marks it read ("handled", which is also what the sender then sees). OperatorStates: id -> that state, for the ids that are still held.
    public Dictionary<string, string> OperatorStates(IEnumerable<string> ids)
    {
        lock (gate)
        {
            var d = new Dictionary<string, string>();
            foreach (var id in ids) if (store.Records.TryGetValue(id, out var rec) && rec.Per.TryGetValue("operator", out var st)) d[id] = st;
            return d;
        }
    }

    // ids null: every note to the operator that is not read yet. Idempotent; an id that is unknown or was not addressed to the operator is counted.
    public (int Marked, int Unknown) MarkOperatorRead(IReadOnlyList<string>? ids)
    {
        lock (gate)
        {
            int marked = 0, unknown = 0;
            if (ids == null) { foreach (var rec in store.Records.Values) if (rec.Per.TryGetValue("operator", out var st) && st != "handled") { rec.Per["operator"] = "handled"; marked++; } }
            else foreach (var id in ids)
            {
                if (!store.Records.TryGetValue(id, out var rec) || !rec.Per.ContainsKey("operator")) { unknown++; continue; }
                if (rec.Per["operator"] != "handled") { rec.Per["operator"] = "handled"; marked++; }
            }
            return (marked, unknown);
        }
    }

    public Dictionary<string, string> MessageStates(IEnumerable<string> ids)
    {
        lock (gate)
        {
            var d = new Dictionary<string, string>();
            foreach (var id in ids) if (store.Records.TryGetValue(id, out var rec)) d[id] = rec.State();
            return d;
        }
    }

    // Is a supervisor present: registered, and heard within the presence window (a poll, a heartbeat or a verb counts; a stream write does not).
    public (bool Present, string Name) SupervisorPresent()
    {
        lock (gate)
        {
            if (store.Slot is not { } s) return (false, "");
            return (MessageStore.Within(store.Get(s.Name).LastHeard, DateTime.UtcNow, Msg.OnlineSeconds), s.Name);
        }
    }

    // Records the answer to an open question and delivers it to the asker, as one step under the lock: the first answer wins (3.8). The callers are
    // the supervisor's answer, the operator's POST /questions/{id}/answer and the Tier 1 test seam. The asker and the item come from the record.
    public (bool Ok, string Code, string Reason, string AnswerId, string Asker, int? Item, bool Pushed) AnswerQuestion(string questionId, JsonObject answer, string note = "")
    {
        lock (gate)
        {
            if (!store.Records.TryGetValue(questionId, out var q)) return (false, "no-such-question", "no question with this id", "", "", null, false);
            if (q.Type != "question") return (false, "not-a-question", "this id is a message, not a question", "", "", q.Item, false);
            if (q.QState == "answered") return (false, "already-answered", "the question was answered before; the first answer wins", "", q.From, q.Item, false);
            if (q.QState != "open") return (false, "no-such-question", $"the question is {q.QState}: it takes no answer any more", "", q.From, q.Item, false);
            var by = answer["fromKind"]?.ToString() ?? "";
            var arec = NewRecord(answer["type"]?.ToString() ?? "answer", "direct", answer["from"]?.ToString() ?? "", by, q.Item, "", 0);
            answer["inReplyTo"] = questionId; answer["item"] = q.Item;
            // the asker owned the item when it asked and does not now: the answer still goes to the asker, marked, and to nobody else (3.8)
            if (q.OwnedAtAsk && q.Item is int qi && !(ownerOf.TryGetValue(qi, out var ow) && ow == q.From)) answer["itemOwner"] = "changed";
            var e = DeliverEntry(store.Get(q.From), answer, arec, false);
            q.QState = "answered"; q.AnswerId = arec.Id; q.AnswerJson = e.Json; q.AnsweredAt = DateTime.UtcNow; q.AnsweredBy = by is "supervisor" or "operator" or Messenger.OpSession ? by : ""; q.Note = note;
            if (note != "") { store.Decisions.Add((DateTime.UtcNow, q.Item, q.AnsweredBy, note, q.Id, 0)); if (store.Decisions.Count > 50) store.Decisions.RemoveAt(0); }
            return (true, "", "", arec.Id, q.From, q.Item, e.State == "pushed");
        }
    }

    // ---- questions (3.8): the table, the batches to the supervisor, late, escalated and moot. Every method holds the gate. -----------------------
    IEnumerable<MessageRecord> OpenQuestions() => store.Records.Values.Where(q => q.Type == "question" && q.QState == "open");
    bool SupervisorHeard(DateTime now) => store.Slot is { } s && MessageStore.Within(store.Get(s.Name).LastHeard, now, Msg.OnlineSeconds);
    void Wake(string name) { var r = store.Get(name); r.Signal.TrySetResult(); r.Signal = Recipient.NewSignal(); }
    void QueueLog(string message, string id, string from, int? item, string code = "", int count = 0)
    {
        var o = new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["message"] = message, ["id"] = id, ["type"] = count > 0 ? "supervisor.questions" : "question", ["from"] = from, ["fromKind"] = count > 0 ? "gateway" : "worker", ["to"] = "supervisor", ["kind"] = "question", ["item"] = item };
        if (count > 0) o["count"] = count;
        if (code != "") o["code"] = code;
        store.LogQueue.Add(o);
    }

    // The delivery budget of the sliding hour and day (3.9). A delivery is a question batch or a patrol. Questions may use the hour's budget less the
    // patrols' reserve, and never more than what is left of the whole; the operator's grants raise both.
    bool QuestionBudgetLeft(DateTime now, out int retryAfter)
    {
        store.Deliveries.RemoveAll(t => (now - t).TotalHours >= 24); store.PatrolDeliveries.RemoveAll(t => (now - t).TotalHours >= 24);
        retryAfter = 0;
        var hour = store.Deliveries.Where(t => (now - t).TotalHours < 1).ToList();
        var extra = ExtraDeliveries(now);
        var cap = Math.Max(0, Msg.TurnBudgetPerHour - Msg.PatrolReservePerHour) + extra; var whole = Msg.TurnBudgetPerHour + extra;
        var asked = hour.Count - store.PatrolDeliveries.Count(t => (now - t).TotalHours < 1);
        if (asked >= cap || hour.Count >= whole)
        {   // the oldest delivery of the hour frees the next one (a patrol's or a batch's: an estimate, never early by more than the patrols' share)
            retryAfter = hour.Count == 0 ? 3600 : Math.Max(1, (int)Math.Ceiling((hour[0].AddHours(1) - now).TotalSeconds)); return false;
        }
        // the day keeps the patrols' reserve as well: 24 hours of it are not for questions
        var day = Math.Max(0, Msg.TurnBudgetPerDay - 24 * Msg.PatrolReservePerHour) + extra;
        if (day == 0) { retryAfter = 3600; return false; }
        // questions only are held to that share (a patrol never uses up the questions' part); the whole day's budget bounds both together
        var askedDay = store.Deliveries.Count - store.PatrolDeliveries.Count;
        if (askedDay >= day || store.Deliveries.Count >= Msg.TurnBudgetPerDay + extra) { retryAfter = Math.Max(1, (int)Math.Ceiling((store.Deliveries[0].AddHours(24) - now).TotalSeconds)); return false; }
        return true;
    }

    // The operator's grants (POST /supervisor/budget?extra=N): extra deliveries, for questions and patrols alike, for one hour from the grant.
    int ExtraDeliveries(DateTime now) { store.Grants.RemoveAll(g => (now - g.At).TotalHours >= 1); return store.Grants.Sum(g => g.N); }
    public int GrantDeliveries(int n) { lock (gate) { var now = DateTime.UtcNow; store.Grants.Add((now, n)); store.BudgetLogged = false; store.PatrolBudgetLogged = false; return ExtraDeliveries(now); } }

    // A patrol may use the whole budget of the hour, the reserve included; questions stop short of the reserve (3.9).
    bool PatrolBudgetLeft(DateTime now)
    {
        store.Deliveries.RemoveAll(t => (now - t).TotalHours >= 24);
        var extra = ExtraDeliveries(now);
        return store.Deliveries.Count(t => (now - t).TotalHours < 1) < Msg.TurnBudgetPerHour + extra && store.Deliveries.Count < Msg.TurnBudgetPerDay + extra;
    }

    // One step of the supervisor (3.9): a read verb, a directive or an announcement stops at stepBudgetPerHour; an answer, a patrol
    // acknowledgement and a note to the operator (essential) run on to the hard limit, so asked questions can still be answered.
    public (bool Ok, int RetryAfter) SupervisorStep(bool essential)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; store.Steps.RemoveAll(t => (now - t).TotalHours >= 1);
            var limit = essential ? Msg.StepHardPerHour : Msg.StepBudgetPerHour;
            if (store.Steps.Count >= limit) return (false, Math.Max(1, (int)Math.Ceiling((store.Steps[store.Steps.Count - limit].AddHours(1) - now).TotalSeconds)));
            store.Steps.Add(now); return (true, 0);
        }
    }

    // ---- the patrol (3.9): the digest input, what is new or worse, the push, the acknowledgement. Every method holds the gate; none calls Runner. ----
    static readonly string[] SessionTypes = { "persistent-local", "ephemeral-local", "claude-cloud", "cursor-cloud" };
    DigestInput DigestInputLocked(DateTime now)
    {
        var d = new DigestInput { Now = now };
        var holders = ownerOf.Values.ToHashSet();
        foreach (var v in DigestSource().Where(v => Auth.ValidName(v.Name) && (v.Presence != "offline" || holders.Contains(v.Name))))
        {
            store.Recipients.TryGetValue(v.Name, out var r);
            d.Sessions.Add(new DigestSession(v.Name, SessionTypes.Contains(v.Type) ? v.Type : "", v.Presence == "online", v.LastSeen, r?.GoneAt));
        }
        // a session whose name has no presence (it is on no list): what its stream says of it
        foreach (var w in workers.Values.Where(w => Auth.ValidName(w.Name) && !Msg.ManagerNames.Contains(w.Name) && d.Sessions.All(x => x.Name != w.Name) && (w.Connected || holders.Contains(w.Name))))
            d.Sessions.Add(new DigestSession(w.Name, SessionTypes.Contains(w.Type) ? w.Type : "", w.Connected, null, store.Recipients.TryGetValue(w.Name, out var wr) ? wr.GoneAt : null));
        foreach (var (item, holder) in ownerOf.OrderBy(kv => kv.Key))
        {
            if (!Auth.ValidName(holder)) continue;
            ownedInfo.TryGetValue(item, out var oi);
            var column = oi != null && oi.Column != "" ? oi.Column : Gated(assignments.TryGetValue($"{item}|own-item|owner", out var a) ? a.Column : "");
            var lastCode = ""; for (var i = refusals.Count - 1; i >= 0; i--) if (refusals[i].Item == item && refusals[i].Name == holder) { lastCode = refusals[i].Code; break; }
            var routed = lastRouted.GetValueOrDefault(item, "");
            // known waits (3.9): parked, a hold or a QC wait as the last trigger, an inspector job pending, or a refusal the skills define as a wait
            var wait = oi is { Parked: true } || WaitEvents.Contains(routed)
                || botOf.ContainsKey(item) || assignments.Values.Any(x => x.Item == item && x.Kind == "bot-job") || (lastCode != "" && Msg.WaitCodes.Contains(lastCode));
            d.Owned.Add(new DigestOwned(item, holder, column, oi?.LeaseUntil, wait, ownedSince.TryGetValue(item, out var sn) ? sn : oi?.At ?? now, activity.TryGetValue((holder, item), out var la) ? la : null,
                progress.TryGetValue((holder, item), out var lp) ? lp : null, wait || routed == "item.merged"));
        }
        // the reported conditions (3.9): each only for an item its worker still owns, except a refused merge, which may have cost the claim
        operatorNotes.RemoveAll(x => (now - x.At).TotalMinutes > Msg.NoteMinutes);
        foreach (var g in operatorNotes.Where(x => ownerOf.TryGetValue(x.Item, out var h) && h == x.Name
                     && !(store.Records.TryGetValue(x.Id, out var nrec) && nrec.Per.TryGetValue("operator", out var st) && st == "handled")).GroupBy(x => x.Item).OrderBy(g => g.Key))
            d.BlockedNotes.Add((g.Key, g.First().Name, g.First().Id, g.Count(), g.First().At));
        foreach (var (item, rv) in reviews.OrderBy(kv => kv.Key))
            if (ownerOf.TryGetValue(item, out var h) && Auth.ValidName(h) && rv.Max >= 1 && (rv.Round >= rv.Max || (rv.Max >= 2 && rv.Round == rv.Max - 1))) d.Reviews.Add((item, h, rv.Column, rv.Round, rv.Max, rv.At));
        verbErrors.RemoveAll(x => (now - x.At).TotalMinutes > Msg.VerbErrorMinutes);
        foreach (var g in verbErrors.Where(x => Auth.ValidName(x.Name) && ownerOf.TryGetValue(x.Item, out var eh) && eh == x.Name).GroupBy(x => (x.Item, x.Name)).OrderBy(g => g.Key.Item))
            d.VerbErrors.Add((g.Key.Item, g.Key.Name, g.Count(), g.GroupBy(x => x.Code).OrderByDescending(c => c.Count()).ThenBy(c => c.Key, StringComparer.Ordinal).Select(c => (c.Key, c.Count())).ToList()));
        foreach (var k in mergeRefused.Where(kv => (now - kv.Value.At).TotalMinutes > Msg.NoteMinutes).Select(kv => kv.Key).ToList()) mergeRefused.Remove(k);
        foreach (var (item, mr) in mergeRefused.OrderBy(kv => kv.Key)) d.MergeRefused.Add((item, mr.RoundTrip, mr.At));
        AddPassUnmerged(d, now);
        // (a blocked session that went away for good is no more news: only the connected ones are reported)
        foreach (var w in workers.Values.Where(w => Blocked(w) && w.Connected && Auth.ValidName(w.Name)).OrderBy(w => w.Name, StringComparer.Ordinal)) d.BlockedSessions.Add((w.Name, w.BlockedItem, w.BlockedSince!.Value));
        if (returned.Count > 0 && (now - startedAt).TotalMinutes < Msg.RestartMinutes)
            d.Restart = (returned.Count, d.Owned.Select(o => o.Holder).Distinct().Count(n => !d.Sessions.Any(x => x.Name == n && x.Connected)), (int)(now - startedAt).TotalMinutes);
        foreach (var a in assignments.Values.Where(a => a.WaitingSince != null && a.Worker == "" && !a.Accepted && !IsQc(a)).OrderBy(a => a.Item)) d.Waiting.Add((a.Item, GatedCode(a.WaitingCode), a.WaitingSince!.Value));
        foreach (var g in refusals.Where(x => (now - x.At).TotalMinutes <= 60).GroupBy(x => (x.Item, x.Code))) d.Refusals.Add((g.Key.Item, GatedCode(g.Key.Code), g.Count()));
        foreach (var g in parks.Where(x => (now - x.At).TotalHours <= 24).GroupBy(x => (x.Item, x.Code))) d.Parks.Add((g.Key.Item, g.Key.Code, g.Min(x => x.At)));
        foreach (var q in OpenQuestions().OrderBy(q => q.N))
        {
            d.OpenQuestions++;
            if (Auth.ValidName(q.From)) d.Questions.Add(new DigestQuestion(q.Id, q.From, q.Item, q.At, (now - q.At).TotalSeconds >= Msg.AnswerSlaSeconds, q.Escalated));
        }
        ReleaseQueueDigestLocked(d);
        return d;
    }

    static string SessionSignature(DigestInput d, DigestSession s) => (s.Connected ? "1|" : "0|") + string.Join(",", d.Owned.Where(o => o.Holder == s.Name).Select(o => o.Item));

    // One supervisor.patrol into the supervisor's inbox and onto its stream: one delivery of the budget. Marks what it carried as reported at its
    // bucket; an entry the cap left out is not marked, so it comes with the next patrol.
    void SendPatrol(ManagerSlot slot, DigestInput d, List<DigestEntry> entries, bool baseline, List<JsonObject> log)
    {
        var now = d.Now; var r = store.Get(slot.Name);
        // a session is "changed" when its connection or its items differ from the last digest; one seen for the first time is only recorded
        var changed = d.Sessions.Where(s => store.SessionState.TryGetValue(s.Name, out var was) && was != SessionSignature(d, s)).Select(s => s.Name).ToHashSet();
        var id = NewMessageId(); var seq = store.PatrolSeq + 1;
        var onlyReminders = entries.Any(e => e.Reminder) && !entries.Any(e => e.New);
        var evt = DigestBuilder.Build(d, entries, changed, id, seq, store.PatrolSeq, store.Epoch, baseline, onlyReminders, Msg, out var kept);
        store.PatrolSeq = seq;
        var rec = new MessageStore.PatrolRecord { Seq = seq, At = now, MessageId = id };
        foreach (var e in kept)
        {
            rec.Entries.Add((e.Key, e.Bucket));
            if (e.New) store.Reported[e.Key] = new MessageStore.ReportedEntry { Bucket = e.Bucket, At = now };
            else if (e.Reminder && store.Reported.TryGetValue(e.Key, out var re)) re.Reminded = true;
        }
        if (kept.Any(e => e.Reminder)) store.PatrolsReminded++;
        store.Patrols[seq] = rec;
        foreach (var old in store.Patrols.Keys.Where(k => k <= seq - 200).ToList()) store.Patrols.Remove(old);
        store.SessionState.Clear(); foreach (var s in d.Sessions) store.SessionState[s.Name] = SessionSignature(d, s);
        var inboxSeq = r.Next++; var json = evt.ToJsonString();
        var entry = new InboxEntry { Seq = inboxSeq, Id = id, At = now, From = "gateway", FromKind = "gateway", Type = "supervisor.patrol", Json = json };
        r.Inbox.Add(entry);
        if (slot.Out != null && slot.Out.Writer.TryWrite((inboxSeq, json))) { entry.State = "pushed"; store.Pushed++; }
        r.Signal.TrySetResult(); r.Signal = Recipient.NewSignal();
        store.Deliveries.Add(now); store.PatrolDeliveries.Add(now); store.PatrolsSent++; store.LastPatrolAt = now; store.SentThisSlot = true; store.LastDigest = json; store.PatrolBudgetLogged = false;
        log.Add(new JsonObject { ["at"] = now.ToString("o"), ["message"] = "sent", ["id"] = id, ["type"] = "supervisor.patrol", ["from"] = "gateway", ["fromKind"] = "gateway", ["to"] = slot.Name, ["seq"] = seq, ["entries"] = kept.Count, ["baseline"] = baseline });
    }

    void PatrolDropped(DateTime now, List<JsonObject> log)
    {
        store.PatrolsDropped++; store.LastPatrolAt = now; store.SentThisSlot = true;
        if (!store.PatrolBudgetLogged) { store.PatrolBudgetLogged = true; log.Add(new JsonObject { ["at"] = now.ToString("o"), ["message"] = "budget-exhausted", ["type"] = "supervisor.patrol" }); }
    }

    // The attention entries of this moment, flagged against what was pushed before: new (never pushed, or pushed at a lower bucket), reminder (pushed
    // at this bucket, never acknowledged, mgrRemindMinutes ago, once). A condition that cleared is forgotten, so a recurrence is new again.
    List<DigestEntry> FlaggedAttention(DigestInput d)
    {
        var all = DigestBuilder.Attention(d, Msg);
        var keys = all.Select(e => e.Key).ToHashSet();
        // verb-errors is a count over a sliding window: it may dip under its threshold and come back within minutes. It is forgotten only after a
        // whole window without it, so the same run of errors is not reported as new at every patrol.
        foreach (var k in keys) if (store.Reported.TryGetValue(k, out var seen)) seen.Seen = d.Now;
        foreach (var k in store.Reported.Where(kv => !keys.Contains(kv.Key) && !(kv.Key.StartsWith("verb-errors|", StringComparison.Ordinal) && (d.Now - (kv.Value.Seen == default ? kv.Value.At : kv.Value.Seen)).TotalMinutes < Msg.VerbErrorMinutes)).Select(kv => kv.Key).ToList()) store.Reported.Remove(k);
        foreach (var e in all)
        {
            if (!store.Reported.TryGetValue(e.Key, out var r) || e.Bucket > r.Bucket) e.New = true;
            else if (!r.Acked && !r.Reminded && (d.Now - r.At).TotalMinutes >= Msg.RemindMinutes) e.Reminder = true;
        }
        return all;
    }

    // Called by the ticker (the Messenger's Tick) about once a second; recomputes every mgrDigestSeconds. At most one patrol per mgrPatrolMinutes, and
    // only when an entry is new, worse or due for its one reminder; an interval in which none left is counted as suppressed. Returns log lines.
    public List<JsonObject> PatrolTick()
    {
        var log = new List<JsonObject>();
        lock (gate)
        {
            var now = DateTime.UtcNow;
            if (!Msg.ManagerEnabled || !Msg.Enabled || (now - store.LastDigestAt).TotalSeconds < Msg.DigestSeconds) return log;
            store.LastDigestAt = now;
            if (store.Slot is not { } slot || !SupervisorHeard(now)) return log;
            var interval = TimeSpan.FromMinutes(Msg.PatrolMinutes);
            if (store.LastSlotAt == default) store.LastSlotAt = now;
            var d = DigestInputLocked(now);
            var all = FlaggedAttention(d);
            if (all.Any(e => e.New || e.Reminder) && now - store.LastPatrolAt >= interval)
            {
                if (!PatrolBudgetLeft(now)) PatrolDropped(now, log);
                // what goes: the new ones, the reminders, and as context what was pushed and not acknowledged; an acknowledged entry is muted at its bucket
                else SendPatrol(slot, d, all.Where(e => e.New || e.Reminder || !store.Reported[e.Key].Acked).ToList(), false, log);
            }
            if (now - store.LastSlotAt >= interval) { if (!store.SentThisSlot) store.PatrolsSuppressed++; store.SentThisSlot = false; store.LastSlotAt = now; }
        }
        return log;
    }

    // The baseline of a registration (3.9): only for a client that holds nothing (no cursor of this epoch), only when the digest holds an attention
    // entry, and at most once per mgrBaselineMinutes however often the client reconnects.
    void Baseline(ManagerSlot slot, DateTime now)
    {
        if (store.LastSlotAt == default) store.LastSlotAt = now;
        if (store.LastBaselineAt is { } lb && (now - lb).TotalMinutes < Msg.BaselineMinutes) return;
        var d = DigestInputLocked(now);
        var all = FlaggedAttention(d);
        if (all.Count == 0) return;
        var log = new List<JsonObject>();
        if (!PatrolBudgetLeft(now)) PatrolDropped(now, log);
        else { store.LastBaselineAt = now; SendPatrol(slot, d, all, true, log); }
        store.LogQueue.AddRange(log);
    }

    // GET /digest: the digest of this moment, on demand (after a restart or a compaction). Nothing is marked reported and no delivery is spent.
    public JsonObject DigestNow()
    {
        lock (gate)
        {
            var d = DigestInputLocked(DateTime.UtcNow);
            return DigestBuilder.Build(d, FlaggedAttention(d), d.Sessions.Select(s => s.Name).ToHashSet(), "", store.PatrolSeq, store.PatrolSeq, store.Epoch, false, false, Msg, out _);
        }
    }

    // POST /supervisor/patrol-ack: the entries of patrol N are acknowledged at the bucket they had in it, and the note goes to the decision log. A
    // second acknowledgement of the same patrol changes nothing.
    public (bool Known, bool Already, int Entries) AckPatrol(long seq, string note)
    {
        lock (gate)
        {
            if (!store.Patrols.TryGetValue(seq, out var p)) return (false, false, 0);
            if (p.Acked) return (true, true, p.Entries.Count);
            p.Acked = true;
            foreach (var (key, bucket) in p.Entries) if (store.Reported.TryGetValue(key, out var r) && r.Bucket == bucket) r.Acked = true;
            if (store.Slot is { } s) foreach (var e in store.Get(s.Name).Inbox.Where(e => e.Id == p.MessageId && e.State != "expired")) { e.State = "handled"; e.HandledAt = DateTime.UtcNow; }
            if (note != "") { store.Decisions.Add((DateTime.UtcNow, null, "supervisor", note, "", seq)); if (store.Decisions.Count > 50) store.Decisions.RemoveAt(0); }
            return (true, false, p.Entries.Count);
        }
    }

    // POST /supervisor/patrol?minutes=N: the operator's interval, in memory.
    public void SetPatrolMinutes(double minutes) { lock (gate) Msg.PatrolMinutes = minutes; }

    // POST /messaging/enable and /messaging/disable (4.5): the operator's switch for the whole gateway, until the other call or a restart. Every
    // session that registered with messaging=1, and the supervisor, gets one event; switching off discards every inbox, and the open questions go
    // back to undelivered so the supervisor gets them again when the switch is on. Returns false when nothing changed.
    public bool SetMessagingEnabled(bool on)
    {
        lock (gate)
        {
            if (Msg.Enabled == on) return false;
            Msg.Enabled = on;
            var evt = new JsonObject { ["provider"] = "gateway", ["event"] = on ? "messaging.enabled" : "messaging.disabled", ["epoch"] = store.Epoch };
            TellWorkers(evt);
            store.Slot?.Out?.Writer.TryWrite((0, evt.ToJsonString()));
            if (on)
            {   // presence was not stamped while the switch was off: a session whose stream is open is heard now, and the digest starts its
                // period again, so the first patrol after a long switch-off does not report every owner as disconnected
                var now = DateTime.UtcNow;
                foreach (var w in workers.Values.Where(w => w.Connected && w.Out != null && Msg.PresenceAllowed(w.Name))) store.Get(w.Name).LastHeard = now;
                if (store.Slot is { Out: not null } sl) store.Get(sl.Name).LastHeard = now;
                store.LastDigestAt = now;
                return true;
            }
            foreach (var r in store.Recipients.Values)
            {
                foreach (var e in r.Inbox.Where(e => e.Undelivered || e.State == "delivered").ToList()) SetState(r, e, "expired");
                r.Inbox.Clear();
                r.Signal.TrySetResult(); r.Signal = Recipient.NewSignal();
            }
            foreach (var q in OpenQuestions()) if (q.DeliveredAt != null) { q.DeliveredAt = null; q.Redeliver = true; }
            store.WindowAt = null;
            return true;
        }
    }

    public (string Name, string Model) ActiveSupervisor() { lock (gate) return store.Slot is { } s ? (s.Name, s.Model) : ("", ""); }

    // For an asker: is a supervisor there, and is its delivery budget spent (with the seconds until a delivery is free again)?
    public (bool Present, bool BudgetExhausted, int RetryAfter) SupervisorAvailability()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            if (!SupervisorHeard(now)) return (false, false, 0);
            return QuestionBudgetLeft(now, out var retry) ? (true, false, 0) : (true, true, retry);
        }
    }

    // One batch to the supervisor: an entry in its inbox (the poll loop reads it there) and a line on its stream. One delivery of the budget.
    void PushBatch(ManagerSlot slot, List<MessageRecord> part, DateTime now)
    {
        var r = store.Get(slot.Name); var seq = r.Next++; var id = NewMessageId(); var batch = ++store.BatchCounter;
        var rows = new JsonArray(); var anyReplayed = false;
        foreach (var q in part)
        {
            var replayed = q.Redeliver || q.At < slot.RegisteredAt; anyReplayed |= replayed;
            var shown = new System.Text.StringBuilder(); var n = 0; var cut = false;
            foreach (var rune in q.QText.EnumerateRunes()) { if (n++ >= Msg.QuestionShownChars) { cut = true; break; } shown.Append(rune.ToString()); }
            rows.Add(new JsonObject
            {
                ["id"] = q.Id, ["from"] = q.From, ["fromKind"] = "worker", ["item"] = q.Item, ["text"] = shown.ToString(), ["truncated"] = cut, ["context"] = q.QContext, ["askedAt"] = q.At.ToString("o"),
                ["ageSeconds"] = (int)(now - q.At).TotalSeconds, ["late"] = (now - q.At).TotalSeconds >= Msg.AnswerSlaSeconds, ["escalated"] = q.Escalated, ["replayed"] = replayed,
                ["flags"] = new JsonArray(q.QFlags.Select(f => (JsonNode)f).ToArray())
            });
            q.DeliveredAt = now; q.Redeliver = false;
        }
        var evt = new JsonObject
        {
            ["provider"] = "peer", ["relay"] = "gateway", ["event"] = "supervisor.questions", ["id"] = id, ["seq"] = seq, ["epoch"] = store.Epoch, ["to"] = slot.Name, ["batch"] = batch,
            ["count"] = part.Count, ["replayed"] = anyReplayed, ["questions"] = rows, ["sentAt"] = now.ToString("o")
        };
        var entry = new InboxEntry { Seq = seq, Id = id, At = now, From = "gateway", FromKind = "gateway", Type = "supervisor.questions", Json = evt.ToJsonString() };
        r.Inbox.Add(entry);
        if (slot.Out != null && slot.Out.Writer.TryWrite((seq, entry.Json))) entry.State = "pushed";
        r.Signal.TrySetResult(); r.Signal = Recipient.NewSignal();
        store.Deliveries.Add(now);
        QueueLog("sent", id, "gateway", null, count: part.Count);
    }

    // Batching and in flight (3.8): the first undelivered question opens a window of mgrBatchSeconds; what arrives in it, up to batchMax, leaves as one
    // batch. While a batch has unanswered entries and is under mgrInflightMinutes old, new questions wait for the next window. A question older than
    // the answer target is never held back by either. all: a registration without a cursor, which sends every open question, split at batchMax.
    void DeliverQuestions(DateTime now, bool all)
    {
        if (store.Slot is not { } slot || !SupervisorHeard(now)) return;
        var pending = OpenQuestions().Where(q => q.DeliveredAt == null).OrderBy(q => q.N).ToList();
        if (pending.Count == 0) { store.WindowAt = null; return; }
        if (!all && !pending.Any(q => (now - q.At).TotalSeconds >= Msg.AnswerSlaSeconds))
        {
            if (OpenQuestions().Any(q => q.DeliveredAt is { } d && (now - d).TotalMinutes < Msg.InflightMinutes)) { store.WindowAt = null; return; }
            store.WindowAt ??= now;
            if (pending.Count < Msg.BatchMax && (now - store.WindowAt.Value).TotalSeconds < Msg.BatchSeconds) return;
        }
        do
        {
            if (!QuestionBudgetLeft(now, out _))
            {   // nothing is pushed to say so (it would cost a turn): one log line, and askers are told supervisor-budget (3.9)
                if (!store.BudgetLogged) { store.BudgetLogged = true; store.LogQueue.Add(new JsonObject { ["at"] = now.ToString("o"), ["message"] = "budget-exhausted", ["queued"] = pending.Count }); }
                return;
            }
            store.BudgetLogged = false;
            var part = pending.Take(Msg.BatchMax).ToList(); pending.RemoveRange(0, part.Count);
            PushBatch(slot, part, now);
        } while (all && pending.Count > 0);
        store.WindowAt = null;
    }

    // Called by the ticker: moot and escalated questions, then the batches. Returns the log lines and the journal jobs for the caller to run outside the lock.
    public QuestionEvents QuestionTick()
    {
        var ev = new QuestionEvents();
        lock (gate)
        {
            var now = DateTime.UtcNow;
            foreach (var q in OpenQuestions().ToList())
            {
                var owns = q.Item is int qi && ownerOf.TryGetValue(qi, out var ow) && ow == q.From;
                if (q.DeliveredAt == null && q.OwnedAtAsk && !owns)
                {   // the asker lost the item before the supervisor saw the question: nobody is asked (3.8)
                    q.QState = "moot"; Wake(q.From); QueueLog("expired", q.Id, q.From, q.Item, "moot"); continue;
                }
                if (q.Escalated || (now - q.At).TotalMinutes < Msg.EscalateMinutes) continue;
                q.Escalated = true; q.EscalatedAt = now;
                QueueLog("escalated", q.Id, q.From, q.Item);
                // one journal comment, only on an item the asker owns at this moment; never the question's text
                if (owns) ev.Escalations.Add(new EscalationJob(q.Id, q.Item!.Value, q.From, (int)Math.Round((now - q.At).TotalMinutes), SupervisorHeard(now) ? "connected" : "absent"));
            }
            DeliverQuestions(now, false);
            ev.Log.AddRange(store.LogQueue); store.LogQueue.Clear();
        }
        return ev;
    }

    public void QuestionJournalFailed(string id, string code) { lock (gate) { if (store.Records.TryGetValue(id, out var q)) q.JournalFailed = code; } }

    // GET /questions (3.1): the questions addressed to the supervisor with their state, oldest first; the operator also gets the decision log.
    public JsonObject Questions(bool all, bool forOperator)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var rows = new JsonArray();
            var qs = store.Records.Values.Where(q => q.Type == "question").OrderBy(q => q.N).ToList();
            bool Late(MessageRecord q) => q.QState == "open" && (now - q.At).TotalSeconds >= Msg.AnswerSlaSeconds;
            foreach (var q in qs.Where(q => all || q.QState == "open"))
            {
                var o = new JsonObject
                {
                    ["id"] = q.Id, ["from"] = q.From, ["item"] = q.Item, ["state"] = q.QState, ["late"] = Late(q), ["escalated"] = q.Escalated, ["delivered"] = q.DeliveredAt != null,
                    ["askedAt"] = q.At.ToString("o"), ["ageSeconds"] = (int)(now - q.At).TotalSeconds, ["text"] = q.QText, ["context"] = q.QContext,
                    ["flags"] = new JsonArray(q.QFlags.Select(f => (JsonNode)f).ToArray())
                };
                if (q.QState == "answered") { o["answeredBy"] = q.AnsweredBy; o["answeredAt"] = q.AnsweredAt?.ToString("o"); o["note"] = q.Note; }
                if (forOperator && q.JournalFailed != "") o["journalFailed"] = q.JournalFailed;
                rows.Add(o);
            }
            var res = new JsonObject
            {
                ["ok"] = true, ["epoch"] = store.Epoch, ["state"] = all ? "all" : "open",
                ["counts"] = new JsonObject { ["open"] = qs.Count(q => q.QState == "open"), ["late"] = qs.Count(Late), ["escalated"] = qs.Count(q => q.QState == "open" && q.Escalated),
                    ["moot"] = qs.Count(q => q.QState == "moot"), ["answered"] = qs.Count(q => q.QState == "answered"), ["expired"] = qs.Count(q => q.QState == "expired") },
                ["count"] = rows.Count, ["questions"] = rows
            };
            if (forOperator) res["decisions"] = new JsonArray(store.Decisions.Select(d => (JsonNode)new JsonObject { ["at"] = d.At.ToString("o"), ["item"] = d.Item, ["by"] = d.By, ["note"] = d.Note, ["question"] = d.Question == "" ? null : d.Question, ["patrol"] = d.Patrol == 0 ? null : d.Patrol }).ToArray());
            res["exit"] = 0;
            return res;
        }
    }

    // from_message (3.8): may this name mark text as derived from this message? Only a message it sent or received. The block must name the
    // message whose text it carries and that message's real sender, so the caller's own question stands for its answer once it has one:
    // Source is then the answer's id, From who answered, InReplyTo the question. An unanswered question is the asker's own text (its assumption).
    // An answer the caller received is itself the source, and InReplyTo names its question.
    public (bool Ok, string Source, string From, string InReplyTo) MessageParty(string id, string name)
    {
        lock (gate)
        {
            if (!store.Records.TryGetValue(id, out var rec) || !(rec.From == name || rec.Per.ContainsKey(name))) return (false, "", "", "");
            string source = id, from, re = "";
            if (rec.Type == "question")
            {
                if (rec.QState == "answered" && rec.AnswerId != "") { source = rec.AnswerId; re = id; from = rec.AnsweredBy != "" ? rec.AnsweredBy : store.Records.TryGetValue(rec.AnswerId, out var ans) ? ans.From : rec.From; }
                else from = rec.From;
            }
            else
            {
                from = rec.FromKind is "supervisor" or "operator" ? rec.FromKind : rec.From;
                if (store.Records.Values.FirstOrDefault(q => q.Type == "question" && q.AnswerId == id) is { } asked) re = asked.Id;
            }
            return (true, source, Auth.ValidName(from) ? from : "unknown", re);
        }
    }

    // ---- plant data for the digest (3.9, step 5a) ----------------------------------------------------------------------------------------------
    // Every verb that names an item and every /wait poll for it stamps (name, item): activity on one item must not hide a stall on another.
    // A verb call is progress as well (the item-quiet condition); a /wait poll is not.
    public void NoteActivity(string name, int item, bool verb = false) { if (!Msg.On || item <= 0) return; lock (gate) { activity[(name, item)] = DateTime.UtcNow; if (verb) progress[(name, item)] = DateTime.UtcNow; } }

    // A verb that failed for an item (exit 20, a crash, no output): the code the rule script gave, or exit-N. A ring of 500, read over mgrVerbErrorMinutes.
    public void NoteVerbError(string name, int item, string code, int exit)
    {
        if (!Msg.On || item <= 0) return;
        lock (gate) { verbErrors.Add((DateTime.UtcNow, item, name, GatedCode(code) is { Length: > 0 } c ? c : "exit-" + exit)); if (verbErrors.Count > 500) verbErrors.RemoveAt(0); }
    }

    // A session presented a cursor of another epoch: it was connected to an earlier process of this gateway, so this process is a restart (3.9).
    public void NoteStaleEpoch(string name, string cursor)
    {
        if (!Msg.On || !Auth.ValidName(name)) return;
        var epoch = cursor.Split('.')[0];
        if (epoch == store.Epoch || !Regex.IsMatch(epoch, @"^e-[0-9a-f]{8}\z")) return;
        lock (gate) { if (returned.Count < 500) returned.Add(name); }
    }

    // A recorded review round with findings, or a refused merge, as the verbs answer them (also the test seam's way in).
    public void NoteReview(int item, string column, string verdict, int round, int max)
    {
        if (!Msg.On || item <= 0) return;
        lock (gate) { if (verdict == "FINDINGS" && round >= 1 && max >= 1) reviews[item] = (Gated(column), round, max, DateTime.UtcNow); else reviews.Remove(item); }
    }
    public void NoteMergeRefused(int item, int roundTrip)
    {
        if (!Msg.On || item <= 0) return;
        lock (gate) { mergeRefused[item] = (Math.Max(1, roundTrip), DateTime.UtcNow); if (mergeRefused.Count > 200) mergeRefused.Remove(mergeRefused.MinBy(kv => kv.Value.At).Key); }
    }

    // A gate refusal (verb exit 10 or 11) of one code on one item, kept for an hour in a ring of 500.
    public void NoteRefusal(string name, int item, string code)
    {
        if (!Msg.On || item <= 0 || GatedCode(code) == "") return;
        lock (gate)
        {
            var now = DateTime.UtcNow;
            refusals.RemoveAll(x => (now - x.At).TotalMinutes > 60);
            refusals.Add((now, item, name, code)); if (refusals.Count > 500) refusals.RemoveAt(0);
            // a review asked for after the last allowed round: the column has failed, whatever round the plant saw recorded
            if (code == "review-rounds-exhausted") reviews[item] = reviews.TryGetValue(item, out var rv) ? rv with { Round = Math.Max(rv.Round, rv.Max) } : ("", 1, 1, now);
        }
    }

    // The projection the digest is built from: an explicit field list of names, item numbers, times and gated columns and codes. No address, token,
    // assignment id, summary, model, title or label text (2.2, 3.9).
    public JsonObject PlantData()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; string? Iso(DateTime? d) => d?.ToString("o");
            return new JsonObject
            {
                ["owned"] = new JsonArray(ownerOf.OrderBy(kv => kv.Key).Select(kv =>
                {
                    ownedInfo.TryGetValue(kv.Key, out var oi);
                    return (JsonNode)new JsonObject { ["item"] = kv.Key, ["holder"] = kv.Value, ["column"] = oi?.Column ?? "", ["leaseUntil"] = Iso(oi?.LeaseUntil), ["heartbeat"] = Iso(oi?.Heartbeat), ["parked"] = oi?.Parked ?? false,
                        ["since"] = Iso(ownedSince.TryGetValue(kv.Key, out var sn) ? sn : null), ["lastActivityAt"] = Iso(activity.TryGetValue((kv.Value, kv.Key), out var la) ? la : null) };
                }).ToArray()),
                ["activity"] = new JsonArray(activity.OrderBy(kv => kv.Key.Item).ThenBy(kv => kv.Key.Name, StringComparer.Ordinal).Select(kv => (JsonNode)new JsonObject { ["name"] = kv.Key.Name, ["item"] = kv.Key.Item, ["at"] = Iso(kv.Value) }).ToArray()),
                ["waiting"] = new JsonArray(assignments.Values.Where(a => a.WaitingSince != null && a.Worker == "" && !a.Accepted && !IsQc(a)).OrderBy(a => a.Item)
                    .Select(a => (JsonNode)new JsonObject { ["item"] = a.Item, ["code"] = a.WaitingCode, ["since"] = Iso(a.WaitingSince) }).ToArray()),
                ["refusals"] = new JsonArray(refusals.Where(x => (now - x.At).TotalMinutes <= 60).GroupBy(x => (x.Item, x.Code)).OrderBy(g => g.Key.Item).ThenBy(g => g.Key.Code, StringComparer.Ordinal)
                    .Select(g => (JsonNode)new JsonObject { ["item"] = g.Key.Item, ["code"] = g.Key.Code, ["count"] = g.Count(), ["worker"] = g.Last().Name, ["last"] = Iso(g.Last().At) }).ToArray()),
                ["parks"] = new JsonArray(parks.Select(x => (JsonNode)new JsonObject { ["item"] = x.Item, ["code"] = x.Code, ["at"] = Iso(x.At) }).ToArray())
            };
        }
    }

    // The sweep's `owned` replaces what the plant believes of own-item owners (3.9): a listed claim refreshes column, lease, heartbeat and park; an
    // owner the sweep no longer lists (an idle release, a card moved away by a person) is dropped once the grace from its accept has passed. Not
    // dropped: an item the sweep could not read this time (`keep`), and an owner set through the test seam. An item whose merge is settling has no
    // owner any more: it was released at item.merged (Merged).
    // scope (issue 92): an incremental pass read only these items; the owners of every other item are not touched (nor their counts of misses)
    void ReplaceOwned(JsonObject owned, IEnumerable<int> keep, DateTime now, IReadOnlyCollection<int>? scope = null)
    {
        var kept = new HashSet<int>(keep);
        var listed = new Dictionary<int, OwnedInfo>();
        foreach (var kv in owned)
        {
            if (!int.TryParse(kv.Key, out var item) || kv.Value is not JsonObject o) continue;
            var holder = o["holder"]?.ToString() ?? ""; if (!Auth.ValidName(holder)) continue;
            listed[item] = new OwnedInfo(holder, Gated(o["column"]?.ToString()), Time(o["lease_until"]), Time(o["heartbeat"]), o["parked"] is JsonValue pv && pv.TryGetValue<bool>(out var pb) && pb, now);
        }
        foreach (var (item, name) in ownerOf.ToList())
        {
            if (scope != null && !scope.Contains(item)) continue;
            if (listed.TryGetValue(item, out var li) && li.Holder == name) { ownedInfo[item] = li; ownedMisses.Remove(item); continue; }
            if (kept.Contains(item) || seamOwned.Contains(item)) { ownedMisses.Remove(item); continue; }
            if (!ownedSince.TryGetValue(item, out var since)) ownedSince[item] = since = now;
            if ((now - since).TotalSeconds < Msg.OwnedGraceSeconds) continue;
            // past the grace, and only when two sweeps in a row omit it: dropping an owner turns its undelivered questions moot for good
            var misses = ownedMisses[item] = ownedMisses.GetValueOrDefault(item) + 1;
            if (misses < 2) continue;
            DropOwner(item);
            // issue 74: an accepted own-item assignment of the dropped owner goes with it, so "accepted" always means "owned": a new session of the name
            // is not resent an item it no longer owns (ResendAccepted), and the next sweep offers the item afresh instead of finding the session gone
            if (assignments.TryGetValue($"{item}|own-item|owner", out var acc) && acc.Accepted && acc.Worker == name) assignments.Remove($"{item}|own-item|owner");
        }
        foreach (var k in ownedInfo.Keys.Where(k => !ownerOf.ContainsKey(k)).ToList()) ownedInfo.Remove(k);
        foreach (var k in ownedSince.Keys.Where(k => !ownerOf.ContainsKey(k)).ToList()) ownedSince.Remove(k);
        foreach (var k in reviews.Keys.Where(k => !ownerOf.ContainsKey(k)).ToList()) reviews.Remove(k);   // (NoteRefusal may add one for an item nobody owns)
        foreach (var k in activity.Where(kv => (now - kv.Value).TotalHours > 24).Select(kv => kv.Key).ToList()) activity.Remove(k);
        foreach (var k in progress.Where(kv => (now - kv.Value).TotalHours > 24).Select(kv => kv.Key).ToList()) progress.Remove(k);
        parks.RemoveAll(x => (now - x.At).TotalHours > 24);
    }

    // Past the TTL an undelivered, pushed or delivered message is expired (its inbox entry goes, the sender's record keeps the state); handled entries
    // go 10 minutes after the ack; open questions expire at the TTL; records are kept for the longer of the TTL and 24 hours.
    public List<(string Id, string To, string From, string Type)> ExpireMessages()
    {
        var gone = new List<(string, string, string, string)>();
        lock (gate)
        {
            if (!Msg.On) return gone;
            var now = DateTime.UtcNow; var ttl = TimeSpan.FromMinutes(Msg.TtlMinutes);
            foreach (var r in store.Recipients.Values)
            {
                for (var i = r.Inbox.Count - 1; i >= 0; i--)
                {
                    var e = r.Inbox[i];
                    if (e.State is "queued" or "pushed" or "delivered" && now - e.At >= ttl) { SetState(r, e, "expired"); gone.Add((e.Id, r.Name, e.From, e.Type)); }
                    if (e.State == "expired" || (e.State == "handled" && e.HandledAt is { } h && now - h >= TimeSpan.FromMinutes(10))) r.Inbox.RemoveAt(i);
                }
            }
            var keep = ttl > TimeSpan.FromHours(24) ? ttl : TimeSpan.FromHours(24);
            foreach (var rec in store.Records.Values.Where(q => q.Type == "question" && q.QState == "open" && now - q.At >= ttl).ToList()) { rec.QState = "expired"; Wake(rec.From); gone.Add((rec.Id, "supervisor", rec.From, "question")); }
            while (store.RecordOrder.TryPeek(out var oldest) && (!store.Records.TryGetValue(oldest, out var orec) || now - orec.At > keep)) { store.RecordOrder.Dequeue(); store.Records.Remove(oldest); }
        }
        return gone;
    }

    // Test seam (messaging.testHooks, GET /api/v1/_test/stores): how many entries each bounded store of the plant holds, with its cap. Counts only.
    public JsonObject StoreStats()
    {
        lock (gate)
        {
            var rs = store.Recipients.Values.ToList();
            JsonObject Row(long n, long cap) => new() { ["count"] = n, ["cap"] = cap };
            return new JsonObject
            {
                ["recipients"] = rs.Count,
                // an inbox keeps InboxKeep entries; only undelivered ones may take it above that
                ["inboxKept"] = Row(rs.Count == 0 ? 0 : rs.Max(r => r.Inbox.Count(e => !e.Undelivered)), InboxKeep),
                ["inboxEntries"] = rs.Count == 0 ? 0 : rs.Max(r => r.Inbox.Count),
                ["undeliveredPeerNotes"] = Row(rs.Count == 0 ? 0 : rs.Max(r => r.Inbox.Count(e => e.Undelivered && e.Peer)), Msg.RecipientQueueCap),
                ["undeliveredPerSender"] = Row(rs.Count == 0 ? 0 : rs.Max(r => r.Inbox.Where(e => e.Undelivered && e.Peer).GroupBy(e => e.From).Select(g => g.Count()).DefaultIfEmpty(0).Max()), Msg.PerSenderQueueCap),
                // open questions are never dropped from the records, so they may stand above the cap
                ["records"] = Row(store.Records.Count, RecordKeep + store.Records.Values.Count(q => q.Type == "question" && q.QState == "open")),
                ["recordOrder"] = Row(store.RecordOrder.Count, 2 * RecordKeep),
                ["decisions"] = Row(store.Decisions.Count, 50), ["patrols"] = Row(store.Patrols.Count, 200),
                ["reported"] = store.Reported.Count, ["sessionStates"] = store.SessionState.Count, ["logQueue"] = store.LogQueue.Count,
                ["deliveries"] = store.Deliveries.Count, ["patrolDeliveries"] = store.PatrolDeliveries.Count, ["steps"] = store.Steps.Count, ["grants"] = store.Grants.Count,
                ["workers"] = workers.Count,
                ["streamBuffer"] = Row(workers.Count == 0 ? 0 : workers.Values.Max(w => w.Buffer.Count), 200),
                ["mailboxes"] = mailboxes.Count, ["mailbox"] = Row(mailboxes.Count == 0 ? 0 : mailboxes.Values.Max(b => b.Count), 100),
                ["refusals"] = Row(refusals.Count, 500), ["parks"] = Row(parks.Count, 200)
            };
        }
    }

    // The task a waiter (inbox long-poll, wait?messages=1) awaits for this name: completed by the next delivery.
    public Task MessageSignal(string name) { lock (gate) return store.Get(name).Signal.Task; }

    // Every client-originated request of a worker, item or supervisor credential stamps the name (2.2): registration, heartbeat, poll, verb.
    // Only names that may have presence are stamped (or created): a request of any other name, refused or not, leaves nothing listed.
    public void Touch(string name) { if (!Msg.PresenceAllowed(name)) return; lock (gate) store.Get(name).LastHeard = DateTime.UtcNow; }

    // A session that polls (inbox, wait) and has never opened a stream is listed via poll (3.2, 6.2).
    public void NotePoll(string name)
    {
        if (!Msg.PresenceAllowed(name)) return;
        lock (gate) { var r = store.Get(name); if (r.Via == "") r.Via = "poll"; }
    }

    // POST /presence: a heartbeat, and optionally the activity summary (one change per 10 s). Returns the presence, or the seconds to wait.
    public (string Presence, int RetryAfter) Heartbeat(string name, string? summary)
    {
        lock (gate)
        {
            var r = store.Get(name); var now = DateTime.UtcNow;
            if (summary != null && summary != r.Summary)
            {
                var wait = 10 - (now - r.SummaryAt).TotalSeconds;
                if (r.SummaryAt != default && wait > 0) return ("", (int)Math.Ceiling(wait));
                r.Summary = summary; r.SummaryAt = now;
            }
            r.LastHeard = now; if (r.Via == "") r.Via = "poll";
            return (PresenceOf(r, now), 0);
        }
    }

    // The supervisor registers into its slot, never into workers (2.1). The same name replaces its older stream; another allowed name is refused
    // while the active one was heard within the takeover window, and takes over after it (4.6). Both ends of a replacement get stream.replaced.
    public (bool Ok, string Active, DateTime Since, Channel<(long, string)>? Ch, List<(long, string)> Replay) RegisterSupervisor(string name, string model, string effort, long after)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; var s = store.Slot;
            if (s != null && s.Name != name && MessageStore.Within(store.Get(s.Name).LastHeard, now, Msg.TakeoverSeconds)) return (false, s.Name, s.Since, null, new());
            if (s?.Out != null) { s.Out.Writer.TryWrite((0, ReplacedJson(s.Name))); s.Out.Writer.TryComplete(); }
            // a client that holds none of the open questions: no cursor of this epoch, or another name taking the slot (whatever cursor it sends)
            var fresh = after == 0 || s == null || s.Name != name;
            if (s != null && s.Name != name) store.Get(s.Name).GoneAt = now;
            if (s != null && s.Name != name) store.Get(s.Name).Inbox.RemoveAll(e => e.Type is "supervisor.questions" or "supervisor.patrol");
            if (s == null || s.Name != name) store.Slot = s = new ManagerSlot { Name = name, Since = now };
            s.Model = model; s.Effort = effort; s.ModelCheck = Msg.ModelCheck(model, effort); s.Out = Channel.CreateUnbounded<(long, string)>();
            var r = store.Get(name); r.LastHeard = now; r.GoneAt = null; r.Via = "stream"; r.MessagingClient = true;
            if (fresh)
            {   // no cursor of this epoch: a new client process, which holds none of the open questions. Its old batches go, and every open question
                // is delivered again, marked replayed, split at batchMax, each part one delivery (3.8, failure mode 16). A reconnect with a cursor of
                // this epoch only replays the batches above it, like any other event, and spends nothing.
                r.Inbox.RemoveAll(e => e.Type is "supervisor.questions" or "supervisor.patrol");
                foreach (var q in OpenQuestions()) if (q.DeliveredAt != null) { q.DeliveredAt = null; q.Redeliver = true; }
                s.RegisteredAt = now;
            }
            var replay = MergedReplay(name, new(), after, true);
            AnnounceSupervisor(s);
            if (Msg.ManagerEnabled && Msg.Enabled) DeliverQuestions(now, fresh);
            if (Msg.ManagerEnabled && Msg.Enabled && fresh) Baseline(s, now);
            return (true, name, s.Since, s.Out, replay);
        }
    }

    public void DisconnectSupervisor(Channel<(long, string)> ch) { lock (gate) { if (store.Slot is { } s && s.Out == ch) { s.Out = null; store.Get(s.Name).GoneAt = DateTime.UtcNow; } } }

    // The messaging and supervisor blocks of /api/v1/status (8), operator only. Names, presence and times; no address, token or assignment id.
    public JsonObject MessagingStatus(bool dashboard = false)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            var qs = store.Records.Values.Where(q => q.Type == "question").ToList();
            store.Deliveries.RemoveAll(t => (now - t).TotalHours >= 24); store.Steps.RemoveAll(t => (now - t).TotalHours >= 1);
            var extra = ExtraDeliveries(now);
            // workers only (the supervisor has its own block), allowed names only, offline ones for 60 minutes
            var listed = store.Recipients.Values.Where(r => r.LastHeard != null && Msg.WorkerAllowed(r.Name) && !Msg.ManagerNames.Contains(r.Name)
                && !(PresenceOf(r, now) == "offline" && (now - r.LastHeard!.Value).TotalMinutes > Msg.OfflineListMinutes)).OrderBy(r => r.Name).ToList();
            string? Iso(DateTime? d) => d?.ToString("o");
            var slot = store.Slot;
            var sr = slot != null ? store.Get(slot.Name) : null;
            var res = new JsonObject
            {
                ["messaging"] = new JsonObject
                {
                    ["enabled"] = Msg.Enabled, ["epoch"] = store.Epoch,
                    ["sessions"] = new JsonObject { ["online"] = listed.Count(r => PresenceOf(r, now) == "online"), ["away"] = listed.Count(r => PresenceOf(r, now) == "away"), ["offline"] = listed.Count(r => PresenceOf(r, now) == "offline") },
                    ["queued"] = store.Recipients.Values.Sum(r => r.Inbox.Count(e => e.Undelivered)),
                    ["pushed"] = store.Pushed, ["delivered"] = store.Delivered, ["handled"] = store.Handled, ["expired"] = store.Expired,
                    ["presence"] = new JsonArray(listed.Select(r => (JsonNode)new JsonObject { ["name"] = r.Name, ["presence"] = PresenceOf(r, now), ["via"] = r.Via, ["lastHeard"] = Iso(r.LastHeard), ["goneAt"] = Iso(r.GoneAt), ["messaging"] = r.Mode, ["messagingClient"] = r.MessagingClient }).ToArray())
                },
                ["manager"] = new JsonObject
                {
                    ["enabled"] = Msg.ManagerEnabled, ["allowedAskers"] = new JsonArray(Msg.AllowedAskers.Select(a => (JsonNode)a).ToArray()),
                    ["supervisor"] = slot == null ? null : new JsonObject { ["name"] = slot.Name, ["model"] = slot.Model, ["effort"] = slot.Effort, ["since"] = Iso(slot.Since), ["connected"] = slot.Out != null,
                        ["present"] = MessageStore.Within(sr!.LastHeard, now, Msg.OnlineSeconds), ["lastHeard"] = Iso(sr.LastHeard), ["goneAt"] = Iso(sr.GoneAt) },
                    // counts and states only (8): never the text of a question, an answer or a note
                    ["present"] = sr != null && MessageStore.Within(sr.LastHeard, now, Msg.OnlineSeconds), ["model"] = slot?.Model ?? "", ["modelCheck"] = slot?.ModelCheck,
                    ["openQuestions"] = qs.Count(q => q.QState == "open"), ["late"] = qs.Count(q => q.QState == "open" && (now - q.At).TotalSeconds >= Msg.AnswerSlaSeconds),
                    ["escalated"] = qs.Count(q => q.QState == "open" && q.Escalated), ["answered"] = qs.Count(q => q.QState == "answered"), ["expired"] = qs.Count(q => q.QState == "expired"), ["moot"] = qs.Count(q => q.QState == "moot"),
                    ["deliveriesHour"] = store.Deliveries.Count(t => (now - t).TotalHours < 1), ["deliveriesDay"] = store.Deliveries.Count, ["stepsHour"] = store.Steps.Count,
                    ["budgetHour"] = Msg.TurnBudgetPerHour + extra, ["budgetDay"] = Msg.TurnBudgetPerDay + extra, ["patrolReserveHour"] = Msg.PatrolReservePerHour, ["stepBudgetHour"] = Msg.StepBudgetPerHour, ["stepHardHour"] = Msg.StepHardPerHour,
                    ["patrolsSent"] = store.PatrolsSent, ["patrolsSuppressed"] = store.PatrolsSuppressed, ["patrolsDropped"] = store.PatrolsDropped, ["patrolsReminded"] = store.PatrolsReminded,
                    ["patrolsUnacknowledged"] = store.Patrols.Values.Count(p => !p.Acked), ["batches"] = store.BatchCounter, ["budgetExhausted"] = Msg.ManagerEnabled && !QuestionBudgetLeft(now, out _),
                    ["patrolMinutes"] = Msg.PatrolMinutes
                }
            };
            // what the digest of this moment holds, as counts per code (3.9): no name, no item and no text
            if (Msg.ManagerEnabled)
            {
                var counts = new JsonObject();
                foreach (var g in DigestBuilder.Attention(DigestInputLocked(now), Msg).GroupBy(e => e.Kind).OrderBy(g => Array.IndexOf(DigestBuilder.Kinds, g.Key))) counts[g.Key] = g.Count();
                ((JsonObject)res["manager"]!)["attention"] = counts;
            }
            // the operator's page (7): the banner of a gateway that scales to zero
            if (dashboard) ((JsonObject)res["messaging"]!)["scaleToZero"] = Msg.ScaleToZero;
            if (dashboard && Msg.ManagerEnabled)
            {   // the operator's page (7): the last digest sent, when the next patrol may leave, and the decision log with its notes
                var m = (JsonObject)res["manager"]!;
                m["lastDigest"] = store.LastDigest == "" ? null : JsonNode.Parse(store.LastDigest);
                m["allowedNames"] = new JsonArray(Msg.ManagerNames.Select(a => (JsonNode)a).ToArray());
                if (!QuestionBudgetLeft(now, out var budgetRetry)) m["budgetResetSeconds"] = budgetRetry;
                m["nextPatrolAt"] = Iso(store.LastPatrolAt == default ? null : store.LastPatrolAt.AddMinutes(Msg.PatrolMinutes));
                m["decisions"] = new JsonArray(store.Decisions.Select(d => (JsonNode)new JsonObject { ["at"] = d.At.ToString("o"), ["item"] = d.Item, ["by"] = d.By, ["note"] = d.Note, ["question"] = d.Question == "" ? null : d.Question, ["patrol"] = d.Patrol == 0 ? null : d.Patrol }).ToArray());
            }
            return res;
        }
    }

    // Per-name messaging mode (on, mute, inbound-off, off), kept by name across reconnects, unlike Draining (2.1). The operator endpoint is step 6.
    public string MessagingMode(string name) { lock (gate) return store.Get(name).Mode; }
    public bool SetMessagingMode(string name, string mode)
    {
        if (mode is not ("on" or "mute" or "inbound-off" or "off")) return false;
        lock (gate)
        {
            var r = store.Get(name); r.Mode = mode;
            // off discards the inbox (4.5); the senders see their messages as expired, not as queued for ever
            if (mode == "off") { foreach (var e in r.Inbox.Where(e => e.Undelivered).ToList()) SetState(r, e, "expired"); r.Inbox.RemoveAll(e => e.State == "expired"); }
            return true;
        }
    }
    // The operator's capacity for a worker name: it wins over what the session declares at registration, and it holds across the worker's reconnects
    // (not across a gateway restart: the session's own --capacity applies again then).
    readonly Dictionary<string, int> capOverride = new();
    public bool SetCapacity(string name, int capacity)
    {
        lock (gate)
        {
            capOverride[name] = Math.Clamp(capacity, 1, 20);
            if (workers.TryGetValue(name, out var w)) w.Capacity = capOverride[name];
            return true;
        }
    }

    // The operator revoked every credential of this name (the caller has raised its generation already): its open stream ends, as a worker's or as
    // the supervisor's, and an offer it has not answered goes back to the plan. What it owns stays recorded: its item tokens are refused from now
    // on, so its claims lapse and the sweep hands the items on, as for any owner that is gone.
    public bool Revoke(string name)
    {
        lock (gate)
        {
            var closed = false;
            if (workers.TryGetValue(name, out var w))
            {
                if (w.Out != null) { closed = true; w.Out.Writer.TryComplete(); w.Out = null; w.Connected = false; w.DisconnectedAt = DateTime.UtcNow; if (Msg.On) store.Get(name).GoneAt = DateTime.UtcNow; }
                foreach (var a in assignments.Values.Where(a => a.Worker == name && !a.Accepted)) { a.Worker = ""; a.WaitingSince ??= DateTime.UtcNow; a.WaitingCode = a.Pin != "" ? "pinned-unavailable" : "no-session"; }
            }
            if (store.Slot is { } s && s.Name == name && s.Out != null) { closed = true; s.Out.Writer.TryComplete(); s.Out = null; store.Get(name).GoneAt = DateTime.UtcNow; }
            if (RevokeOperator(name)) closed = true;
            FreeNameSlots(name, "revoked");   // its credentials are refused from now on: it cannot release them (issue 108)
            if (RevokeKeeper(name)) closed = true;
            return closed;
        }
    }

    // Issue 82: parks released (unpark) or removed from a closed item by the sweep leave the digest's parks list at once, not 24 hours later.
    public void ClearParks(IEnumerable<int> items) { var set = items.Where(i => i > 0).ToHashSet(); if (set.Count == 0) return; lock (gate) parks.RemoveAll(x => set.Contains(x.Item)); }
    // Issue 80: the operator's drain belongs to the name. It holds across reconnects, new sessions of the name (the launcher) and a graceful restart
    // (plant snapshot) until the operator resumes the name. A session's own drain (end-session, docs/launcher.md) is the session's: the next
    // registration of the name clears it, so the launcher's next session is offered work. A session cannot resume an operator's drain.
    readonly HashSet<string> drainedNames = new();
    public bool SetDraining(string name, bool on, bool byOperator = false)
    {
        lock (gate)
        {
            if (!workers.TryGetValue(name, out var w)) return false;
            // the operator's resume lifts the plant manager's drain of the name too (Manager.cs); a session's own resume lifts neither
            if (byOperator) { if (on) drainedNames.Add(name); else { drainedNames.Remove(name); mgrDrained.Remove(name); } }
            w.Draining = on || drainedNames.Contains(name) || mgrDrained.Contains(name);
            return true;
        }
    }
    public bool IsDraining(string name) { lock (gate) return workers.TryGetValue(name, out var w) && w.Draining; }

    long Push(WorkerInfo w, string json, bool toBuffer = true)
    {
        var id = store.Get(w.Name).Next++;
        if (toBuffer) { w.Buffer.Add((id, json)); if (w.Buffer.Count > 200) w.Buffer.RemoveAt(0); }
        w.Out?.Writer.TryWrite((id, json));
        return id;
    }

    // ---- ownership and routing ---------------------------------------------------------------------------------------------------------
    public void NoteWebhook(int item, string eventName, string reference) { lock (gate) lastTrigger[item] = $"webhook {eventName} (delivery {(reference.Length > 8 ? reference[..8] : reference)})"; }

    public void Route(int item, JsonObject evt)
    {
        lock (gate)
        {
            var json = evt.ToJsonString();
            OperatorRouted(item, evt);
            if (evt["event"]?.ToString() == "item.parked") KeeperPark(item, evt["reason"]?.ToString() ?? "");
            if (Msg.On && ownerOf.ContainsKey(item)) lastRouted[item] = evt["event"]?.ToString() ?? "";
            if (Msg.On && evt["event"]?.ToString() == "item.parked") { parks.Add((DateTime.UtcNow, item, GatedCode(evt["reason"]?.ToString()))); if (parks.Count > 200) parks.RemoveAt(0); }
            if (!mailboxes.TryGetValue(item, out var box)) mailboxes[item] = box = new();
            var id = mailboxNext.TryGetValue(item, out var n) ? n : 1; mailboxNext[item] = id + 1;
            box.Add((id, json)); if (box.Count > 100) box.RemoveAt(0);
            if (ownerOf.TryGetValue(item, out var o) && workers.TryGetValue(o, out var w)) Push(w, json);
            try { mailboxSignal.Release(); } catch { }
        }
    }

    // base.updated (BaseUpdate.cs): routed like a trigger (the owner's stream and the item's mailbox, so wait-event sees it and it works with
    // messaging off), but a newer one replaces the older one of the same item in the replay buffer and the mailbox: a session that reconnects
    // gets the latest master, not a backlog. It is not recorded as the item's last trigger: the digest's waits (a park, a hold) stay what they were.
    public bool RouteBaseUpdated(int item, JsonObject evt)
    {
        lock (gate)
        {
            if (!ownerOf.TryGetValue(item, out var o)) return false;
            static bool Old(string j, int n) { try { var x = JsonNode.Parse(j); return x?["event"]?.ToString() == "base.updated" && x?["item"]?.GetValue<int>() == n; } catch { return false; } }
            var json = evt.ToJsonString();
            if (!mailboxes.TryGetValue(item, out var box)) mailboxes[item] = box = new();
            box.RemoveAll(b => Old(b.Json, item));
            var id = mailboxNext.TryGetValue(item, out var mn) ? mn : 1; mailboxNext[item] = id + 1;
            box.Add((id, json)); if (box.Count > 100) box.RemoveAt(0);
            if (workers.TryGetValue(o, out var w)) { w.Buffer.RemoveAll(b => Old(b.Json, item)); Push(w, json); }
            try { mailboxSignal.Release(); } catch { }
            return true;
        }
    }
    public List<(int Item, string Owner)> OwnersSnapshot() { lock (gate) return ownerOf.Select(kv => (kv.Key, kv.Value)).ToList(); }

    public async Task<(List<(long, string)> Events, bool Timeout)> Wait(int item, long after, TimeSpan timeout, CancellationToken ct)
    {
        var end = DateTime.UtcNow + timeout;
        while (true)
        {
            lock (gate) { if (mailboxes.TryGetValue(item, out var box)) { var ev = box.Where(b => b.Id > after).ToList(); if (ev.Count > 0) return (ev.Select(e => (e.Id, e.Json)).ToList(), false); } }
            var left = end - DateTime.UtcNow; if (left <= TimeSpan.Zero) return (new(), true);
            try { await mailboxSignal.WaitAsync(left > TimeSpan.FromSeconds(2) ? TimeSpan.FromSeconds(2) : left, ct); } catch (OperationCanceledException) { return (new(), true); }
        }
    }

    // ---- planning ----------------------------------------------------------------------------------------------------------------------
    int Owned(string name) => ownerOf.Count(kv => kv.Value == name) + botOf.Count(kv => kv.Value == name) + assignments.Values.Count(a => a.Worker == name && !a.Accepted && !IsQc(a));
    // the session already held a work item, owns one (after a gateway restart the sweep fills ownerOf after the registration), or has an open offer of one, and this is another one (an offer of the same item again, to resume it,
    // is not refused); open offers count so that a session with capacity above 1 is never offered two items at once
    bool SessionSpent(WorkerInfo w, Assignment a) => (OneItemPerSession || RuntimeWorker(w)) && a.Kind == "own-item"
        && (w.SessionItems.Any(i => i != a.Item) || ownerOf.Any(kv => kv.Value == w.Name && kv.Key != a.Item) || assignments.Values.Any(o => o != a && o.Kind == "own-item" && o.Worker == w.Name && !o.Accepted && o.Item != a.Item));
    void NoteSessionItem(string name, int item)
    {
        if (!workers.TryGetValue(name, out var w) || !w.SessionItems.Add(item)) return;
        if (w.Sessions.Count > 0 && w.Sessions[^1].No == w.Session) w.Sessions[^1].Items.Add(item);
        if (!OneItemPerSession) return;
        // an offer of another item that this session still has open (sent after an earlier offer lapsed) is taken back: the next sweep or tick
        // offers it elsewhere, or keeps a pinned one waiting for the next session of this name
        foreach (var o in assignments.Values.Where(o => o.Kind == "own-item" && o.Worker == name && !o.Accepted && o.Item != item).ToList())
        {
            o.Worker = ""; o.WaitingSince ??= DateTime.UtcNow; o.WaitingCode = "session-spent";
            if (o.Pin == "") o.Declined.Add(name);
        }
    }
    // auto-unpark (sync-board input free_workers): sessions that could take a work item now, as Choose would see them for an unpinned item
    public int FreeOwnerSessions()
    {
        lock (gate)
            return workers.Values.Count(w => w.Connected && w.Roles.Contains("owner") && !w.Draining && !Cooling(w) && Owned(w.Name) + PinnedWaiting(w.Name) < w.Capacity
                && !(OneItemPerSession && w.SessionItems.Count > 0) && HostHasRoom(w.Name));
    }
    int QcActive(string name) => assignments.Values.Count(a => IsQc(a) && a.Worker == name);
    // pinned items that wait for this worker with no offer out (an offer out is counted by Owned already)
    int PinnedWaiting(string name) => assignments.Values.Count(a => !IsQc(a) && !a.Accepted && a.Worker == "" && a.Pin == name);

    (WorkerInfo? Worker, string Why) Choose(Assignment a, string? pin)
    {
        // a runtime worker takes only the item it was started for (its name is the pin), never an unpinned one
        var ws = workers.Values.Where(w => w.Connected && (!RuntimeWorker(w) || w.Name == pin)).ToList();
        // chooseCode: the reason as one of six codes (session-spent: one item per session), for WaitingCode (the pinned worker's name comes from a GitHub label and is not carried)
        chooseCode = "no-session";
        if (ws.Count == 0) return (null, "no worker session is subscribed");
        var withRole = ws.Where(w => w.Roles.Contains(a.Role)).ToList();
        chooseCode = "no-role";
        if (withRole.Count == 0) return (null, $"no subscribed session has the {a.Role} role");
        // a pinned item goes to its worker or to nobody: not connected, without the role, draining or at capacity all mean it waits. An offer
        // that worker let lapse does not exclude it (Declined is for the unpinned choice): it is the only one that may take the item.
        if (!string.IsNullOrEmpty(pin))
        {
            chooseCode = "pinned-unavailable";
            var p = withRole.FirstOrDefault(w => w.Name == pin && !w.Draining && !Blocked(w));
            if (p != null && SessionSpent(p, a)) { chooseCode = "session-spent"; return (null, $"the pinned worker '{pin}' already held a work item in this session; the item waits for its next session"); }
            return p != null && Owned(p.Name) < p.Capacity && HostHasRoom(p.Name) ? (p, "") : (null, $"the pinned worker '{pin}' is not available");
        }
        var live = withRole.Where(w => !w.Draining && !a.Declined.Contains(w.Name) && !Cooling(w) && !Blocked(w)).ToList();
        chooseCode = "all-draining-or-declined";
        if (live.Count == 0) return (null, "every eligible session is draining, has declined, is cooling down after offers it let lapse, or is blocked after items were taken back from it");
        // a slot that a pinned item waits for is that item's (issue 46): an unpinned item takes only the slots no waiting pin claims
        var free = live.Where(w => Owned(w.Name) + PinnedWaiting(w.Name) < w.Capacity).ToList();
        chooseCode = "at-capacity";
        if (free.Count == 0) return (null, "every eligible session is at capacity");
        free = free.Where(w => !SessionSpent(w, a)).ToList();
        chooseCode = "session-spent";
        if (free.Count == 0) return (null, "every eligible session already held a work item in this session (one item per session)");
        // the host limit (gateway/Hosts.cs): sessions that share a computer share its budget of owned items
        free = free.Where(w => HostHasRoom(w.Name)).ToList();
        chooseCode = "host-at-capacity";
        if (free.Count == 0) return (null, "every eligible session's host is at its limit of owned items");
        return (free.OrderBy(w => TypeOrder.GetValueOrDefault(w.Type, 9)).ThenBy(w => Owned(w.Name)).First(), "");
    }

    string AssignedJson(Assignment a)
    {
        var o = new JsonObject
        {
            ["provider"] = "gateway", ["event"] = "item.assigned", ["item"] = a.Item, ["column"] = a.Column, ["job"] = a.Kind, ["role"] = a.Role, ["mode"] = a.Mode, ["reason"] = a.Reason,
            ["pr"] = a.Pr, ["assignment"] = a.Id, ["ackBySeconds"] = AckFor(a.Worker),
            ["token"] = Auth.MintItemToken(secret, a.Item, a.Role, a.Id, a.Worker, IsQc(a) ? TimeSpan.FromHours(QcCfg.TokenHours) : TimeSpan.FromHours(12), Rev.Of(a.Worker),
                workers.TryGetValue(a.Worker, out var aw) && aw.Runtime != "local" ? aw.Runtime : "")
        };
        if (IsQc(a)) { o["sha"] = a.Sha; o["env_id"] = a.EnvId; }
        return o.ToJsonString();
    }

    // ---- QC jobs (design pr-qc-environment.md 4.1, 4.2) --------------------------------------------------------------------------------------
    (WorkerInfo? Worker, string Why) ChooseQc(Assignment a)
    {
        var ws = workers.Values.Where(w => w.Connected).ToList();
        if (ws.Count == 0) return (null, "no worker session is subscribed");
        var withRole = ws.Where(w => w.Roles.Contains("qc") && w.Caps.Contains("dotnet")).ToList();
        if (withRole.Count == 0) return (null, "no connected worker has the qc role and the .NET SDK");
        var live = withRole.Where(w => !w.Draining && !a.Declined.Contains(w.Name) && (a.Only == "" || w.Name == a.Only)).ToList();
        if (live.Count == 0) return (null, "every eligible session is draining or has declined");
        if (assignments.Values.Count(x => IsQc(x) && x.Worker != "" && x != a) >= QcCfg.MaxEnvironments) return (null, "the plant is at its limit of QC environments");
        var free = live.Where(w => QcActive(w.Name) - (a.Worker == w.Name ? 1 : 0) < w.QcCapacity).ToList();
        if (free.Count == 0) return (null, "every eligible session is running its limit of QC environments");
        var mem = free.Where(w => w.MemFreeMb == null || w.MemFreeMb >= QcCfg.MinFreeMb).ToList();
        if (mem.Count == 0) return (null, $"no eligible session reports {QcCfg.MinFreeMb} MB of free memory");
        return (mem.OrderBy(w => QcActive(w.Name)).ThenBy(w => TypeOrder.GetValueOrDefault(w.Type, 9)).First(), "");
    }

    static string NewId(long n) => "a-" + n.ToString("x") + DateTime.UtcNow.Ticks.ToString("x")[^4..];

    // Called by Start, Reset and the restart rebuild. The key never appears in Plan's offers, and Plan's pruning skips kind qc-env, so a started
    // environment is never dropped by a sweep. restoreWorker: the recorded worker keeps the recorded assignment id (its item token still matches).
    public (Assignment A, string Why) PlaceQc(int item, int pr, string sha, string envId, int attempt, string mode, string? restoreId = null, string? restoreWorker = null, bool restoreAccepted = false, string only = "")
    {
        lock (gate)
        {
            var key = $"{item}|qc-env|qc|{pr}";
            if (restoreId != null && qcDead.Contains(restoreId)) return (new Assignment { Id = restoreId, Key = key, Item = item, Pr = pr, Kind = "qc-env", Role = "qc", Sha = sha, EnvId = envId, Attempt = attempt }, "this environment was torn down");
            if (assignments.TryGetValue(key, out var ex))
            {
                if (ex.Sha == sha && ex.Attempt == attempt) return (ex, ex.Worker == "" ? "waiting for a worker" : "");
                qcDead.Add(ex.Id); assignments.Remove(key); qcOf.Remove(key);
            }
            var a = new Assignment { Id = restoreId ?? NewId(Interlocked.Increment(ref counter)), Key = key, Item = item, Pr = pr, Kind = "qc-env", Role = "qc", Mode = mode, Reason = "qc", Sha = sha, EnvId = envId, Attempt = attempt, Only = only, CreatedAt = DateTime.UtcNow };
            assignments[key] = a;
            if (restoreWorker != null)
            {
                a.Worker = restoreWorker;
                if (restoreAccepted) { a.Accepted = true; a.AcceptedAt = DateTime.UtcNow; qcOf[key] = restoreWorker; }
                else { a.AckBy = DateTime.UtcNow.AddSeconds(ackSeconds); a.AckExtended = false; if (workers.TryGetValue(restoreWorker, out var rw)) Push(rw, AssignedJson(a), false); }
                return (a, "");
            }
            var (w, why) = ChooseQc(a);
            if (w == null) return (a, why);
            Offer(a, w, null);
            return (a, "");
        }
    }

    // Can an operator move this PR's environment to that worker? (exit, code, reason); exit 0 when it can. The PR's own current worker does not count against capacity.
    public (int Exit, string Code, string Reason) QcReassignCheck(string name, int pr)
    {
        lock (gate)
        {
            if (!workers.TryGetValue(name, out var w)) return (12, "no-such-worker", $"no worker named {name} has connected");
            if (!w.Connected || w.Draining || !w.Roles.Contains("qc") || !w.Caps.Contains("dotnet")) return (10, "worker-unqualified", $"{name} is not connected with the qc role and the .NET SDK, or is draining");
            var own = assignments.Values.Count(x => IsQc(x) && x.Pr == pr && x.Worker == name);
            if (QcActive(name) - own >= w.QcCapacity) return (10, "worker-full", $"{name} is running its limit of QC environments");
            return (0, "", "");
        }
    }

    // Names an operator may pick in the dashboard's Reassign select: connected, qc role, dotnet, not draining, free QC capacity.
    public List<string> QcReassignable(int pr)
    {
        lock (gate) return workers.Values.Where(w => w.Connected && !w.Draining && w.Roles.Contains("qc") && w.Caps.Contains("dotnet")
            && QcActive(w.Name) - assignments.Values.Count(x => IsQc(x) && x.Pr == pr && x.Worker == w.Name) < w.QcCapacity).Select(w => w.Name).OrderBy(n => n).ToList();
    }

    public Assignment? QcAssignment(int pr) { lock (gate) return assignments.Values.FirstOrDefault(a => IsQc(a) && a.Pr == pr); }
    public void DropQc(int pr) { lock (gate) { foreach (var k in assignments.Where(kv => IsQc(kv.Value) && kv.Value.Pr == pr).Select(kv => kv.Key).ToList()) { qcDead.Add(assignments[k].Id); assignments.Remove(k); qcOf.Remove(k); } } }
    // Drops the PR's QC assignment only if it is still this one (a persist that failed must not remove a newer placement).
    public void DropQcIf(int pr, string id) { lock (gate) { foreach (var k in assignments.Where(kv => IsQc(kv.Value) && kv.Value.Pr == pr && kv.Value.Id == id).Select(kv => kv.Key).ToList()) { qcDead.Add(id); assignments.Remove(k); qcOf.Remove(k); } } }
    // The worker holding this environment is lost: a new assignment for another worker (the lost one is excluded) replaces it. Mode "relaunch".
    public (Assignment A, string Why) RelaunchQc(int item, int pr, string sha, string envId, int attempt, string lostWorker)
    {
        lock (gate)
        {
            var key = $"{item}|qc-env|qc|{pr}";
            if (assignments.TryGetValue(key, out var ex)) { qcDead.Add(ex.Id); assignments.Remove(key); qcOf.Remove(key); }
            var a = new Assignment { Id = NewId(Interlocked.Increment(ref counter)), Key = key, Item = item, Pr = pr, Kind = "qc-env", Role = "qc", Mode = "relaunch", Reason = "qc", Sha = sha, EnvId = envId, Attempt = attempt, CreatedAt = DateTime.UtcNow };
            if (lostWorker != "") a.Declined.Add(lostWorker);
            assignments[key] = a;
            var (w, why) = ChooseQc(a);
            if (w == null) return (a, why);
            Offer(a, w, null);
            return (a, "");
        }
    }
    public bool IsConnected(string name) { lock (gate) return workers.TryGetValue(name, out var w) && w.Connected; }
    // a name that registered at least once since the start (connected or not)
    // git-credential (cloud-worker-runtimes.md 2.6): only while the name owns the item through an accepted own-item assignment; an item token
    // outlives its offer, its release and its merge, the push credential must not
    public bool OwnsAccepted(string name, int item) { lock (gate) return ownerOf.TryGetValue(item, out var o) && o == name && assignments.Values.Any(a => a.Accepted && a.Item == item && a.Worker == name && a.Kind == "own-item"); }
    public bool IsWorker(string name) { lock (gate) return workers.ContainsKey(name); }
    public string DeclaredAddress(string name) { lock (gate) return workers.TryGetValue(name, out var w) ? w.QcAddress : ""; }
    public void SetMemFree(string name, double mb) { lock (gate) { if (workers.TryGetValue(name, out var w)) w.MemFreeMb = mb; } }
    // A directed event for one worker (qc.reset, qc.teardown).
    public void SendTo(string name, JsonObject evt) { lock (gate) { if (workers.TryGetValue(name, out var w)) Push(w, evt.ToJsonString()); } }

    // The journal lines of one item are written one after the other, in the order the plant decided them (matched, offered, waiting, reassigned):
    // each is a rule-script call of its own that waits for the item lock, and calls started together reach that lock in any order. Called under
    // gate; only the chaining happens here, the call itself runs on the pool after the line before it has ended (ended, not succeeded: the journal
    // is best-effort). Nothing waits for it, so an offer is never held back by GitHub.
    readonly Dictionary<int, Task> journalTail = new();
    readonly HashSet<int> waitingQueued = new();
    void Journal(int item, string ev, JsonObject fields, string key)
    {
        async Task Write() { try { await journal(item, ev, fields, key); } catch (Exception e) { Console.Error.WriteLine($"journal {ev} for #{item} failed: {e.Message}"); } }
        lock (gate)
        {
            // the repeated "waiting" of a sweep or a tick (no key; the rule script posts one per 30 minutes) is not queued behind one that is still to be written
            var repeat = ev == "waiting" && key == "";
            if (repeat && !waitingQueued.Add(item)) return;
            // issue 144: a reassigned line says why (a code, never the journal's text); the code is for the operator stream only, not the journal
            var why = fields["opCode"]?.ToString() ?? ""; fields.Remove("opCode");
            if (ev is "matched" or "offered" or "reassigned") OperatorPlantEvent(ev, item, fields["worker"]?.ToString() ?? "", fields["column"]?.ToString() ?? "", ev == "reassigned" ? why : "");
            var prev = journalTail.TryGetValue(item, out var t) ? t : Task.CompletedTask;
            var next = prev.ContinueWith(_ => Write(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
            journalTail[item] = next;
            next.ContinueWith(_ => { lock (gate) { if (repeat) waitingQueued.Remove(item); if (journalTail.TryGetValue(item, out var cur) && ReferenceEquals(cur, next)) journalTail.Remove(item); } }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        }
    }
    // For the accept verb, whose own line (assigned) is written by the rule script: the lines decided before it, and how long the acceptance may
    // wait for them. Never more than 60 s and never more than half of what is left of the offer's window (live, two lines took 40 s on a loaded
    // gateway; the deployed window is 120 s). The wait is not taken from the window: the offer is accepted only when the rule script returns, so
    // the time granted here is added to the window of the worker that is answering, or the tick would offer the item again meanwhile.
    public (Task Written, TimeSpan AtMost) JournalBefore(int item, string assignment, string name)
    {
        lock (gate)
        {
            if (!journalTail.TryGetValue(item, out var t)) return (Task.CompletedTask, TimeSpan.Zero);
            var a = assignments.Values.FirstOrDefault(x => x.Id == assignment);
            var mine = a is { Accepted: false } && a.Worker != "" && a.Worker == name;
            var wait = Math.Clamp(a is { Accepted: false } && a.Worker != "" ? (a.AckBy - DateTime.UtcNow).TotalSeconds / 2 : 30, 0, 60);
            if (mine)
            {   // once per offer: a worker that calls accept again and again must not hold the item by lengthening its own window each time
                if (a!.AckExtended) return (Task.CompletedTask, TimeSpan.Zero);
                a.AckExtended = true; a.AckBy = a.AckBy.AddSeconds(wait);
            }
            return (t, TimeSpan.FromSeconds(wait));
        }
    }

    void Offer(Assignment a, WorkerInfo w, string? why)
    {
        a.Worker = w.Name; a.AckBy = DateTime.UtcNow.AddSeconds(AckFor(w.Name)); a.AckExtended = false; a.WaitingSince = null; a.WaitingCode = "";
        Push(w, AssignedJson(a), false);
        var trig = lastTrigger.TryGetValue(a.Item, out var t) ? t : "the sweep";
        Journal(a.Item, "offered", new JsonObject { ["worker"] = w.Name, ["type"] = w.Type, ["ackSeconds"] = ackSeconds }, "off|" + a.Id + "|" + w.Name);
    }

    // owned and keep (step 5a): what the sweep says of every owned claim, and the items it must not drop an owner of; used only while messaging or the
    // supervisor is on, so a deployment with both off plans exactly as before.
    // priorities (docs/design/plant-manager.md 10e): the items with a priority label (top, high); after the pins they are offered first, top before high
    // scope (issue 92): the items of an incremental pass. Only they were read, so owners and unanswered assignments of every other item are kept.
    // sweepStarted: when the sweep that made this plan started reading the board. An owner it names for an item that was merged after that is not
    // put back: the sweep read the claim before the merge removed it (issue 107).
    public void Plan(JsonArray offers, JsonObject? owners, JsonObject? pins, JsonObject? owned = null, IEnumerable<int>? keep = null, JsonObject? priorities = null, DateTime? sweepStarted = null, IReadOnlyCollection<int>? scope = null, JsonObject? runtimes = null, JsonObject? profiles = null)
    {
        try { PlanLocked(offers, owners, pins, owned, keep, priorities, sweepStarted, scope, runtimes, profiles); }
        finally { LaunchProvisions(); }
    }
    void PlanLocked(JsonArray offers, JsonObject? owners, JsonObject? pins, JsonObject? owned, IEnumerable<int>? keep, JsonObject? priorities, DateTime? sweepStarted, IReadOnlyCollection<int>? scope, JsonObject? runtimes, JsonObject? profiles)
    {
        lock (gate)
        {
            // runtime labels and model profiles: a full sweep replaces them; an incremental pass (scope) replaces only the items it read
            if (scope == null) { runtimeLabels = runtimes ?? new JsonObject(); itemProfiles = profiles ?? new JsonObject(); }
            else
            {
                static JsonObject Merge(JsonObject old, JsonObject? fresh, IReadOnlyCollection<int> sc)
                {
                    var o = (JsonObject)old.DeepClone();
                    foreach (var i in sc) o.Remove(i.ToString());
                    if (fresh != null) foreach (var kv in fresh) o[kv.Key] = kv.Value?.DeepClone();
                    return o;
                }
                runtimeLabels = Merge(runtimeLabels, runtimes, scope); itemProfiles = Merge(itemProfiles, profiles, scope);
            }
            var planNow = DateTime.UtcNow;
            foreach (var k in mergedAt.Where(kv => (planNow - kv.Value).TotalHours > 1).Select(kv => kv.Key).ToList()) mergedAt.Remove(k);
            foreach (var k in releasedAt.Where(kv => (planNow - kv.Value).TotalHours > 1).Select(kv => kv.Key).ToList()) releasedAt.Remove(k);
            if (owners != null) foreach (var kv in owners)
            {
                var oi = int.Parse(kv.Key); var on = kv.Value!.ToString();
                if (rqOwnerDropped.Contains(oi)) continue;   // issue 96: an item in the Release Queue whose owner was dropped keeps no owner while its claim lives on
                if (sweepStarted is { } ss && mergedAt.TryGetValue(oi, out var ma) && ma >= ss) continue;
                if (sweepStarted is { } rs && releasedAt.TryGetValue(oi, out var ra) && ra >= rs) continue;
                if (Msg.On && !(ownerOf.TryGetValue(oi, out var cur) && cur == on)) { ownedSince[oi] = planNow; seamOwned.Remove(oi); ownedMisses.Remove(oi); ownedInfo.Remove(oi); }
                ownerOf[oi] = on;
            }
            if (Msg.On && owned != null) ReplaceOwned(owned, keep ?? Array.Empty<int>(), planNow, scope);
            var wanted = new HashSet<string>();
            // pinned items first (issue 46): in one sweep the pin takes its worker's free slot before an unpinned item can; then by priority (the
            // order is stable, so items of one rank keep the sweep's order)
            // then (issue 97) work already started before new work: an orphan in a column past the intake (Development, Functional Testing) takes a
            // free worker before an item in the intake column
            static int Rank(string? p) => p == "top" ? 0 : p == "high" ? 1 : 2;
            foreach (var o in offers.OrderBy(x => string.IsNullOrEmpty(pins?[x!["item"]!.ToString()]?.ToString()) ? 1 : 0).ThenBy(x => Rank(priorities?[x!["item"]!.ToString()]?.ToString())).ThenBy(x => string.Equals(x!["column"]?.ToString() ?? "", IntakeColumn, StringComparison.OrdinalIgnoreCase) ? 1 : 0))
            {
                var item = o!["item"]!.GetValue<int>(); var kind = o["kind"]?.ToString() ?? "own-item"; var role = kind == "bot-job" ? (o["role"]?.ToString() ?? "inspector") : "owner";
                var key = $"{item}|{kind}|{role}";
                // issue 97 with incremental passes (issue 92): a pass over a few items does not see the whole plan, so new work in the intake column is
                // not offered by it while started work waits for an owner; the next full sweep orders both
                if (scope != null && kind == "own-item" && string.Equals(o["column"]?.ToString() ?? "", IntakeColumn, StringComparison.OrdinalIgnoreCase)
                    && !(assignments.TryGetValue(key, out var exi) && exi.Accepted)
                    && assignments.Values.Any(x => x.Kind == "own-item" && !x.Accepted && !IsQc(x) && x.Worker == "" && !ownerOf.ContainsKey(x.Item) && !string.Equals(x.Column, IntakeColumn, StringComparison.OrdinalIgnoreCase)))
                    continue;
                wanted.Add(key);
                var pin = pins?[item.ToString()]?.ToString();
                // issue 98: a pin set aside after its long wait stays aside while the label names the same worker (a new label is a new pin)
                if (pinFallback.TryGetValue(item, out var setAside)) { if (setAside == pin) pin = null; else pinFallback.Remove(item); }
                if (assignments.TryGetValue(key, out var ex))
                {
                    // the offer predates the acceptance: the sweep read the board before the accept (issue 75: a sweep takes tens of seconds and reads
                    // without the item lock, so its offer of a just-accepted item is stale), or, without a sweep start (the test seam), within 20 s of it
                    if (ex.Accepted && (sweepStarted is { } st ? st <= ex.AcceptedAt : (DateTime.UtcNow - ex.AcceptedAt).TotalSeconds < 20)) continue;
                    if (ex.Accepted)
                    {   // accepted, yet the item needs a worker again: the session is gone
                        assignments.Remove(key); if (kind == "own-item") DropOwner(item); else botOf.Remove(item);
                        Journal(item, "reassigned", new JsonObject { ["reason"] = $"the session that owned this item ({ex.Worker}) is gone", ["opCode"] = "session-gone" }, "gone|" + ex.Id);
                    }
                    else if (ex.Worker != "") continue;                                                     // waiting for an answer
                }
                var a = ex != null && !ex.Accepted ? ex : new Assignment
                {
                    Id = "a-" + Interlocked.Increment(ref counter).ToString("x") + DateTime.UtcNow.Ticks.ToString("x")[^4..], Key = key, Item = item, Column = o["column"]?.ToString() ?? "",
                    Kind = kind, Role = role, Mode = o["mode"]?.ToString() ?? (o["reason"]?.ToString() == "relaunch" ? "resume" : "first"), Reason = o["reason"]?.ToString() ?? "", Pr = o["pr"]?.GetValue<int>() ?? 0, CreatedAt = DateTime.UtcNow
                };
                if (ReferenceEquals(a, ex) && o["column"]?.ToString() is { Length: > 0 } nc) a.Column = nc;   // a waiting assignment follows its card (issue 97)
                assignments[key] = a;
                if (!ReferenceEquals(a, ex)) DeclineTakenBack(a);      // a new assignment: not first to the worker it was just taken back from
                if (string.IsNullOrEmpty(pin))
                {   // cloud-worker-runtimes.md 4.4: the runtime of an unpinned item (Plant.Runtimes.cs)
                    var (handled, rtPin) = RouteRuntime(a);
                    if (handled) continue;
                    if (rtPin != null) pin = rtPin;
                }
                a.Pin = pin ?? "";
                if (a.Pin != "" && a.PinRetryAt > planNow) continue;                                      // its worker just let an offer lapse: the tick offers it again
                if (!a.MatchedNoted)
                {   // once per assignment, when the trigger is matched to the job and before a worker is looked for: an item that first waits
                    // (no worker, or its pinned worker is away) has the line too, and a sweep that finds it still waiting writes nothing again
                    a.MatchedNoted = true;
                    var trigText = lastTrigger.TryGetValue(item, out var tt) ? tt : "the sweep";
                    Journal(item, "matched", new JsonObject { ["trigger"] = trigText, ["reason"] = a.Reason, ["column"] = a.Column, ["role"] = a.Kind == "bot-job" ? a.Role : "" }, "m|" + a.Id);
                }
                var (w, why) = Choose(a, pin);
                if (w == null && !string.IsNullOrEmpty(pin))
                {
                    if (!(pinWaitSince.TryGetValue(item, out var pw) && pw.Pin == pin)) pinWaitSince[item] = pw = (pin, planNow);
                    if (PinFallbackMinutes > 0 && (planNow - pw.Since).TotalMinutes >= PinFallbackMinutes)
                    {
                        var pinnedCode = chooseCode;
                        var (fw, _) = Choose(a, null);
                        if (fw != null)
                        {
                            pinFallback[item] = pin; a.Pin = ""; pinWaitSince.Remove(item);
                            Journal(item, "pin-fallback", new JsonObject { ["pin"] = pin, ["worker"] = fw.Name, ["minutes"] = (int)(planNow - pw.Since).TotalMinutes, ["code"] = pinnedCode }, "pinfb|" + a.Id + "|" + Regex.Replace(pin, "[^A-Za-z0-9_.-]", ""));   // (the label text is not trusted inside the journal's marker)
                            Console.WriteLine(new JsonObject { ["at"] = planNow.ToString("o"), ["plant"] = "pin-fallback", ["item"] = item, ["pin"] = pin, ["worker"] = fw.Name }.ToJsonString());
                            w = fw;
                        }
                        else chooseCode = pinnedCode;   // the item still waits for its pin: keep the pinned code, not the unpinned one
                    }
                }
                else pinWaitSince.Remove(item);
                if (w == null) { a.WaitingSince ??= planNow; a.WaitingCode = chooseCode; Journal(item, "waiting", new JsonObject { ["reason"] = why }, ""); continue; }
                Offer(a, w, null);
            }
            // a pin set aside is forgotten once the item is no longer wanted (taken, finished or parked)
            foreach (var i in pinFallback.Keys.Where(i => !wanted.Any(k => k.StartsWith(i + "|", StringComparison.Ordinal))).ToList()) pinFallback.Remove(i);
            foreach (var i in pinWaitSince.Keys.Where(i => !wanted.Any(k => k.StartsWith(i + "|", StringComparison.Ordinal))).ToList()) pinWaitSince.Remove(i);
            // an unanswered or unwanted assignment that the sweep no longer asks for is dropped
            foreach (var k in assignments.Keys.Where(k => !wanted.Contains(k) && !assignments[k].Accepted && !IsQc(assignments[k]) && (scope == null || scope.Contains(assignments[k].Item))).ToList()) assignments.Remove(k);
            // issue 96: an accepted own-item assignment whose worker no longer owns the item (another session holds the claim, its owner was dropped
            // without it) is stale. Left in place it keeps a spent session from being told session.end. Dropped when two sweeps in a row see it so,
            // a minute or more after the accept. (An item in the Release Queue loses its owner and assignments in SetReleaseQueue.)
            var staleNow = new HashSet<string>();
            // (a full sweep only: an incremental pass did not read the other items, issue 92)
            if (scope == null) foreach (var (k, a) in assignments.Where(kv => kv.Value.Accepted && kv.Value.Kind == "own-item" && !IsQc(kv.Value) && !wanted.Contains(kv.Key)).ToList())
            {
                var owns = ownerOf.TryGetValue(a.Item, out var ow) && ow == a.Worker;
                if (owns || (keep != null && keep.Contains(a.Item)) || (planNow - a.AcceptedAt).TotalSeconds < 60) continue;
                if (!staleSeen.Contains(a.Id)) { staleNow.Add(a.Id); continue; }
                assignments.Remove(k); staleDropped++;
                Console.WriteLine(new JsonObject { ["at"] = planNow.ToString("o"), ["plant"] = "stale-assignment-dropped", ["item"] = a.Item, ["worker"] = a.Worker, ["owner"] = ow ?? "", ["assignment"] = a.Id }.ToJsonString());
            }
            if (scope == null) { staleSeen.Clear(); staleSeen.UnionWith(staleNow); }
            // issue 97: since when each unowned own-item past the intake column has waited for an owner
            var orphans = assignments.Values.Where(a => a.Kind == "own-item" && !a.Accepted && !IsQc(a) && !ownerOf.ContainsKey(a.Item)
                && !string.Equals(a.Column, IntakeColumn, StringComparison.OrdinalIgnoreCase)).Select(a => a.Item).ToHashSet();
            foreach (var i in orphanSince.Keys.Where(i => !orphans.Contains(i)).ToList()) orphanSince.Remove(i);
            foreach (var i in orphans) orphanSince.TryAdd(i, planNow);
        }
    }

    // Called every couple of seconds: an assignment nobody answered is offered to the next worker.
    public void Tick()
    {
        var placed = new List<Assignment>();
        lock (gate)
        {
            foreach (var a in assignments.Values.Where(a => !a.Accepted && a.Worker != "" && a.AckBy < DateTime.UtcNow && !(a.Accepting is { } ing && (DateTime.UtcNow - ing).TotalSeconds < 90)).ToList())
            {
                var was = a.Worker;
                if (!IsQc(a) && RuntimeOf(was) is { } lapsedRt)
                {   // a runtime worker that did not accept within its window: its execution is stopped and counts as failed; the next plan routes again
                    a.Worker = ""; a.Pin = ""; a.WaitingSince ??= DateTime.UtcNow; a.WaitingCode = "runtime-offer-lapsed";
                    Journal(a.Item, "reassigned", new JsonObject { ["reason"] = $"{was} did not confirm within {lapsedRt.AckSeconds:0} s: its execution is stopped", ["opCode"] = "runtime-offer-lapsed" }, "ack|" + a.Id + "|" + was);
                    lapsedRt.OfferLapsed(was);
                    continue;
                }
                if (!IsQc(a) && a.Pin != "")
                {   // pinned (the item's worker:<name> label): never offered to another worker. It waits, visibly, and is offered to the same worker
                    // again after one more window, or as soon as that worker is back.
                    a.Worker = ""; a.WaitingSince ??= DateTime.UtcNow; a.WaitingCode = "pinned-unavailable"; a.PinRetryAt = DateTime.UtcNow.AddSeconds(ackSeconds);
                    Journal(a.Item, "waiting", new JsonObject { ["reason"] = $"the pinned worker '{a.Pin}' did not confirm within {ackSeconds:0} s; the item waits for it" }, "pinwait|" + a.Id + "|" + a.PinRetryAt.Ticks);
                    continue;
                }
                a.Declined.Add(was); a.Worker = "";
                var cool = IsQc(a) ? "" : NoteMissed(was, a.Item);
                Journal(a.Item, "reassigned", new JsonObject { ["reason"] = $"{was} did not confirm within {ackSeconds:0} s{cool}", ["opCode"] = "offer-lapsed" }, "ack|" + a.Id + "|" + was);
                var (w, why) = IsQc(a) ? ChooseQc(a) : Choose(a, null);
                if (w == null) { if (!IsQc(a)) { a.WaitingSince ??= DateTime.UtcNow; a.WaitingCode = chooseCode; Journal(a.Item, "waiting", new JsonObject { ["reason"] = why }, ""); } continue; }
                Offer(a, w, null);
                if (IsQc(a)) placed.Add(a);
            }
            // a pinned item that waits is offered to its worker as soon as that worker can take it (it reconnected, or has a free slot again)
            foreach (var a in assignments.Values.Where(a => !IsQc(a) && !a.Accepted && a.Worker == "" && a.Pin != "" && a.PinRetryAt <= DateTime.UtcNow).ToList())
            {
                var (w, _) = Choose(a, a.Pin);
                if (w != null) Offer(a, w, null);
            }
            // issue 72: a session that is spent (it held a work item) and no longer owns it, nor has an offer of it open, is told to end, so the
            // client writes the launcher's end marker and a fresh session of the name starts; without it the name sat idle as session-spent
            // a runtime worker always runs one item per session (cloud-worker-runtimes.md 5), whatever plant.oneItemPerSession says
            foreach (var w in workers.Values.Where(w => w.Connected && w.Type != "supervisor" && (OneItemPerSession || RuntimeWorker(w))))
            {
                // a QC or bot job the session holds or is offered keeps it alive: those are outside the one-item rule and run in this client
                var idle = w.SessionItems.Count > 0 && !ownerOf.Values.Contains(w.Name) && !botOf.Values.Contains(w.Name) && !qcOf.Values.Contains(w.Name)
                    && !assignments.Values.Any(o => o.Worker == w.Name && (o.Kind != "own-item" || o.Accepted || w.SessionItems.Contains(o.Item)));
                if (!idle) { w.SpentIdleSince = null; continue; }
                w.SpentIdleSince ??= DateTime.UtcNow;
                if (w.SessionEndSent == w.Session || (DateTime.UtcNow - w.SpentIdleSince.Value).TotalSeconds < SessionEndGraceSeconds) continue;
                w.SessionEndSent = w.Session;
                FreeNameSlots(w.Name, "session-end");   // the session is told to end: its builds end with it (issue 108)
                Push(w, new JsonObject { ["provider"] = "gateway", ["event"] = "session.end", ["name"] = w.Name, ["session"] = w.Session,
                    ["items"] = new JsonArray(w.SessionItems.OrderBy(i => i).Select(i => (JsonNode)i).ToArray()),
                    ["reason"] = "this session held its one work item and no longer owns it (completed, taken back, released, demoted or reassigned): end it; a new session takes the next item" }.ToJsonString(), false);
            }
            FreeSlotsOfGoneSessions(DateTime.UtcNow);
            RestartStuckSessions();
            // a Start that found no worker keeps its place: it is offered as soon as a qualified worker connects (it is the person's earlier Start, not a new automatic one)
            foreach (var a in assignments.Values.Where(a => IsQc(a) && !a.Accepted && a.Worker == "").ToList())
            {
                var (w, why) = ChooseQc(a);
                if (w == null)
                {
                    var now = DateTime.UtcNow;
                    if ((now - a.CreatedAt).TotalSeconds >= QcCfg.WaitingDelaySeconds && (now - a.LastWaiting).TotalMinutes >= QcCfg.WaitingRepeatMinutes)
                    {
                        a.LastWaiting = now;
                        Journal(a.Item, "qc-waiting", new JsonObject { ["pr"] = a.Pr, ["reason"] = why }, "qcw|" + a.Id + "|" + now.Ticks);
                    }
                    continue;
                }
                Offer(a, w, null); placed.Add(a);
            }
        }
        foreach (var a in placed) { try { _ = OnQcPlaced?.Invoke(a); } catch { } }
    }

    // The launcher watchdog (docs/launcher.md): a session that is stuck is told session.restart; its stream client writes the launcher's end marker
    // and the reason, and the launcher starts a new session of the name (which resumes what the name still owns). Once per session, again after a
    // reconnect while it is still due. Two causes are seen here: a spent session that owns nothing for sessionRestartMinutes (unlike session.end an
    // accepted offer does not hold it back: on 2026-10-15 a stale accepted offer kept a spent session idle for hours), and a question the session
    // asked more than RepeatQuestionLimit times (noted by SendMessage). Called under the gate.
    void RestartStuckSessions()
    {
        var now = DateTime.UtcNow;
        foreach (var w in workers.Values.Where(w => w.Type != "supervisor"))
        {
            // an open QC or bot offer holds it back as it holds session.end back; an own-item offer or a stale accepted one does not
            var spentIdle = OneItemPerSession && SessionRestartMinutes > 0 && w.SessionItems.Count > 0
                && !ownerOf.Values.Contains(w.Name) && !botOf.Values.Contains(w.Name) && !qcOf.Values.Contains(w.Name)
                && !assignments.Values.Any(o => o.Worker == w.Name && o.Kind != "own-item" && !o.Accepted);
            if (!spentIdle) w.StuckSince = null; else w.StuckSince ??= now;
            if (!w.Connected || w.RestartSent == w.Session) continue;
            string reason = w.RestartReason, detail = w.RestartDetail;
            if (reason == "" && w.StuckSince is { } st && (now - st).TotalMinutes >= SessionRestartMinutes)
            { reason = "spent-idle"; detail = $"this session held its one work item and has owned nothing for {(now - st).TotalMinutes:0.#} min"; }
            if (reason == "") continue;
            w.RestartSent = w.Session; restartsSent++;
            restarts.Add((now, w.Name, w.Session, reason)); if (restarts.Count > 20) restarts.RemoveAt(0);
            Push(w, new JsonObject { ["provider"] = "gateway", ["event"] = "session.restart", ["name"] = w.Name, ["session"] = w.Session, ["code"] = reason,
                ["reason"] = detail + ": the launcher ends this session and starts a new one, which resumes what the name still owns" }.ToJsonString(), false);
            Console.WriteLine(new JsonObject { ["at"] = now.ToString("o"), ["plant"] = "session-restart", ["worker"] = w.Name, ["session"] = w.Session, ["code"] = reason }.ToJsonString());
        }
    }

    // A question of a worker session: the same text (case and spacing ignored) about the same item asked more than RepeatQuestionLimit times in this session marks the
    // session for session.restart at the next tick (the overnight run of 2026-10-14 had sessions asking one thing again and again). Under the gate.
    void NoteRepeatedQuestion(string name, MessageRecord q)
    {
        if (RepeatQuestionLimit <= 0 || !workers.TryGetValue(name, out var w) || w.RestartReason != "") return;
        static string Norm(string t) => Regex.Replace(t.Trim().ToLowerInvariant(), @"\s+", " ");
        var text = Norm(q.QText); if (text == "") return;
        // about the same item (or about none): a long-lived inspector or QC session may ask one stock question for several items
        // (a repeat the Messenger did not relay again, issue 105, counts on the question it repeated)
        var n = store.Records.Values.Where(r => r.Type == "question" && r.From == name && r.At >= w.SessionStarted && r.Item == q.Item && Norm(r.QText) == text).Sum(r => 1 + r.Repeats);
        if (n > RepeatQuestionLimit) { w.RestartReason = "repeated-question"; w.RestartDetail = $"this session asked the same question {n} times"; }
    }

    // After a verb succeeded: ownership changes, and the triggers that follow from it.
    public void OnVerb(string verb, JsonObject request, Principal who, JsonObject response)
    {
        var item = int.TryParse(request["item"]?.ToString(), out var parsed) ? parsed : who.Item; if (item == 0) return;
        // validation-verdict answers the gateway's own merge after a PASS in `merge` (Verbs.Merge.ps1 -Gateway)
        var vm = response["merge"] as JsonObject; var vmOutcome = vm?["outcome"]?.ToString() ?? ""; var vmDetail = vm?["detail"] as JsonObject;
        lock (gate)
        {
            // the lease as the verb answered it (accept, claim-item, claim-item --renew), until the next sweep says otherwise (3.9)
            if (Msg.On && verb is "accept" or "claim-item" && who.Kind == "item" && who.Role == "owner" && Time(response["lease_until"]) is { } lease)
                ownedInfo[item] = ownedInfo.TryGetValue(item, out var known) ? known with { LeaseUntil = lease, At = DateTime.UtcNow } : new OwnedInfo(who.Name, "", lease, null, false, DateTime.UtcNow);
            if (Msg.On) switch (verb)
            {   // the facts of the reported conditions (3.9), from the verbs' own answers: numbers and gated names only
                case "record-review":
                    if (int.TryParse(response["round"]?.ToString(), out var round) && int.TryParse(response["max_rounds"]?.ToString(), out var maxRounds) && response["verdict"]?.ToString() == "FINDINGS" && round >= 1 && maxRounds >= 1)
                        // the column is the plant's own knowledge of the item (the sweep, else the assignment), never what the request names
                        reviews[item] = (ownedInfo.TryGetValue(item, out var ro) && ro.Column != "" ? ro.Column : Gated(assignments.TryGetValue($"{item}|own-item|owner", out var ra) ? ra.Column : ""), round, maxRounds, DateTime.UtcNow);
                    else reviews.Remove(item);
                    break;
                case "move-next" or "complete": reviews.Remove(item); break;
                case "merge" when response["outcome"]?.ToString() == "demoted":
                    mergeRefused[item] = (int.TryParse(response["detail"]?["round_trip"]?.ToString(), out var trip) ? Math.Max(1, trip) : 1, DateTime.UtcNow);
                    if (mergeRefused.Count > 200) mergeRefused.Remove(mergeRefused.MinBy(kv => kv.Value.At).Key);
                    break;
                case "validation-verdict" when vmOutcome == "demoted":
                    mergeRefused[item] = (int.TryParse(vmDetail?["round_trip"]?.ToString(), out var vtrip) ? Math.Max(1, vtrip) : 1, DateTime.UtcNow);
                    if (mergeRefused.Count > 200) mergeRefused.Remove(mergeRefused.MinBy(kv => kv.Value.At).Key);
                    break;
            }
            switch (verb)
            {
                case "accept" when who.Kind == "item":
                    foreach (var a in assignments.Values.Where(a => a.Id == who.Assignment))
                    {
                        a.Accepted = true; a.AcceptedAt = DateTime.UtcNow;
                        if (a.Pin != "" && a.Worker == "") a.Worker = who.Name;      // a pinned item accepted between two offers: the record names its worker
                        if (IsQc(a)) qcOf[a.Key] = who.Name;            // a QC worker is never the owner of the item
                        else if (a.Kind == "own-item") { ownerOf[item] = who.Name; NoteSessionItem(who.Name, item); if (Msg.On) { ownedSince[item] = DateTime.UtcNow; seamOwned.Remove(item); ownedMisses.Remove(item); } } else botOf[item] = who.Name;
                    }
                    break;
                case "release":
                    releasedAt[item] = DateTime.UtcNow;
                    DropOwner(item); foreach (var k in assignments.Keys.Where(k => k.StartsWith(item + "|") && !IsQc(assignments[k])).ToList()) assignments.Remove(k);
                    break;
                case "merge" when response["outcome"]?.ToString() is "merged" or "already-merged":
                case "validation-verdict" when vmOutcome is "merged" or "already-merged":
                    // the owner hears item.merged, then is released: the gateway settles the item from here (Merged); the open assignments are done
                    Route(item, new JsonObject { ["provider"] = "gateway", ["event"] = "item.merged", ["item"] = item });
                    Merged(item);
                    break;
                case "approve-pr":
                    botOf.Remove(item);
                    foreach (var k in assignments.Keys.Where(k => k.StartsWith(item + "|bot-job")).ToList()) assignments.Remove(k);
                    var v = response["verdict"]?.ToString();
                    Route(item, new JsonObject { ["provider"] = "gateway", ["event"] = v == "APPROVE" ? "inspector.approved" : v == "ESCALATE" ? "inspector.escalated" : "inspector.changes_requested", ["item"] = item });
                    break;
            }
        }
    }

    // The item is merged and master is green (or the item otherwise ended): the owner is done and its slot is free.
    public void Complete(int item)
    {
        lock (gate) { DropOwner(item); foreach (var k in assignments.Keys.Where(k => k.StartsWith(item + "|") && !IsQc(assignments[k])).ToList()) assignments.Remove(k); }
    }

    public JsonObject Status()
    {
        lock (gate)
            return new JsonObject
            {
                ["oneItemPerSession"] = OneItemPerSession,
                ["staleAssignmentsDropped"] = staleDropped,
                ["runtimes"] = RuntimesStatus(),
                ["pinFallbackMinutes"] = PinFallbackMinutes,
                ["pinsSetAside"] = new JsonObject(pinFallback.Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)kv.Value))),
                ["held"] = HeldJson(),
                ["unowned"] = UnownedJson(),
                ["orphans"] = new JsonArray(orphanSince.Where(kv => !ownerOf.ContainsKey(kv.Key)).OrderBy(kv => kv.Value).Select(kv => (JsonNode)new JsonObject { ["item"] = kv.Key,
                    ["column"] = Gated(assignments.Values.FirstOrDefault(a => a.Item == kv.Key && a.Kind == "own-item")?.Column), ["since"] = kv.Value.ToString("o"),
                    ["minutes"] = (int)(DateTime.UtcNow - kv.Value).TotalMinutes }).ToArray()),
                ["sessionRestarts"] = new JsonObject { ["sent"] = restartsSent, ["recent"] = new JsonArray(restarts.Select(r => (JsonNode)new JsonObject { ["at"] = r.At.ToString("o"), ["worker"] = r.Name, ["session"] = r.Session, ["code"] = r.Reason }).ToArray()) },
                ["passUnmerged"] = PassUnmergedJson(DateTime.UtcNow),
                ["sessionsBlocked"] = sessionsBlocked,
                ["workers"] = new JsonArray(workers.Values.Select(w => (JsonNode)new JsonObject { ["name"] = w.Name, ["type"] = w.Type, ["runtime"] = w.Runtime, ["mode"] = w.Runtime == "local" ? "manual" : w.Runtime == "cursor-cloud" ? "api" : "hosted", ["role"] = "seat", ["execution"] = RuntimeOf(w.Name)?.ExecutionOf(w.Name) ?? "", ["connected"] = w.Connected, ["draining"] = w.Draining, ["capacity"] = w.Capacity, ["owned"] = Owned(w.Name), ["qcCapacity"] = w.QcCapacity, ["qcActive"] = QcActive(w.Name), ["qcProfile"] = w.QcProfile, ["qcAddress"] = w.QcAddress,
                    ["missedOffers"] = w.Missed, ["coolDownUntil"] = Cooling(w) ? w.CoolUntil.ToString("o") : null, ["takenBackInRow"] = w.TakeBackMisses,
                    ["blocked"] = Blocked(w), ["blockedSince"] = w.BlockedSince?.ToString("o"),
                    ["session"] = w.Session, ["sessionStarted"] = w.SessionStarted.ToString("o"), ["sessionItems"] = new JsonArray(w.SessionItems.OrderBy(i => i).Select(i => (JsonNode)i).ToArray()),
                    ["sessionSpent"] = OneItemPerSession && w.SessionItems.Count > 0,
                    ["stuckSince"] = w.StuckSince?.ToString("o"), ["restartSent"] = w.RestartSent == w.Session && w.Session > 0,
                    ["itemsPerSession"] = new JsonArray(w.Sessions.Select(x => (JsonNode)new JsonObject { ["session"] = x.No, ["started"] = x.Started.ToString("o"), ["items"] = new JsonArray(x.Items.Select(i => (JsonNode)i).ToArray()) }).ToArray()),
                    ["roles"] = new JsonArray(w.Roles.Select(r => (JsonNode)r).ToArray()) }).ToArray()),
                ["owners"] = new JsonObject(ownerOf.Select(kv => KeyValuePair.Create(kv.Key.ToString(), (JsonNode?)kv.Value))),
                ["assignments"] = new JsonArray(assignments.Values.Select(a => (JsonNode)new JsonObject { ["id"] = a.Id, ["item"] = a.Item, ["kind"] = a.Kind, ["worker"] = a.Worker, ["accepted"] = a.Accepted, ["pr"] = a.Pr }).ToArray())
            };
    }
}
