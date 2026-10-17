using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;

// Peer messaging and the supervisor, gateway side (design: docs/design/worker-messaging.md 3.1 to 3.7, 4.1 to 4.6, 5.1 to 5.4). This file holds the
// settings, their guards and the reserved names, the MessageStore that Plant keeps under its one gate, and the Messenger: request validation,
// authorization by credential, the secret check, rate limits, the traffic log and the refusal ring. Delivery itself is Plant's (one lock).
// Both features are off by default. Questions (3.8): the table is the question records of the MessageStore; Plant batches them to the supervisor,
// marks them late, escalated, moot or expired on the ticker, and the Messenger validates answers, directives and announcements.

sealed class MessagingSettings
{
    public bool Enabled, ManagerEnabled;
    // Configured: messaging.enabled as the gateway loaded it. Enabled is the run-time switch (POST /messaging/disable and enable, 4.5): it can only be
    // switched on a gateway that was loaded with messaging on, so the id format and the stores never change while sessions run.
    public bool Configured;
    public bool ScaleToZero;               // FACTORY_ENVIRONMENT is one that scales to zero: the loader warns, the dashboard shows a banner (3.6)
    public string[] ManagerNames = Array.Empty<string>();
    public int TokenGeneration = 1;
    // The factory operator session (Operator.cs): operator.* of the config. Off by default; needs messaging.enabled.
    public bool OperatorEnabled;
    public string[] OperatorNames = Array.Empty<string>();
    public int OperatorTokenGeneration = 1, OperatorMaxSelfMergesPerDay = 12;
    public string OperatorRequiredModelTier = "premium", OperatorRequiredEffort = "low";
    // timing.opSelfAnswerMinutes: how long a question the operator session answered itself keeps its release-check from answering quiet
    public double OperatorSelfAnswerMinutes = 10;
    public HashSet<string> Reserved = Auth.ReservedNames(Array.Empty<string>());
    // Names that may use peer messaging and presence ("*" allows every name: demo and tests only), and names that may ask the supervisor.
    // Both default to nobody: a session that runs pull request code must be able to stay out of both lists (5.5).
    public string[] AllowedWorkers = Array.Empty<string>(), AllowedAskers = Array.Empty<string>();
    // timing.mgrTakeoverSeconds: a different supervisor name may take the slot once the active one has not been heard for this long (4.6).
    public double TakeoverSeconds = MessageStore.PresenceSeconds;
    // messaging.testHooks: the admin-only test endpoints (/api/v1/_test/*). Never set outside the Tier 1 suites.
    public bool TestHooks;
    // Limits (3.7, 4.5): messaging.<key> in config/instance.json, overridden in tests by FACTORY_TIMING_<key> (there is no FACTORY_MESSAGING_<KEY> prefix).
    public int MaxTextChars = 2000, RatePerMinute = 12, PairPer10Min = 10, PerSenderQueueCap = 20, RecipientQueueCap = 100;
    public int MaxSubjectChars = 80, MaxContextChars = 500, MaxSummaryChars = 140, MaxBodyBytes = 16 * 1024;
    public int AsksPerHour = 6, MaxOpenQuestions = 3, AnswerSlaSeconds = 120;
    // Questions and the supervisor's own sends (3.7, 3.8, 3.9): the note of an answer, the batch, what a batch shows of each question, the
    // supervisor's directives and announcements per 10 minutes, and the delivery budget (the reserve is usable by patrols only).
    public int MaxNoteChars = 300, BatchMax = 5, QuestionShownChars = 800, SupervisorPer10Min = 20;
    public int TurnBudgetPerHour = 12, TurnBudgetPerDay = 96, PatrolReservePerHour = 2;
    // timing.mgrEscalateMinutes, mgrBatchSeconds, mgrInflightMinutes; the retry of the escalation journal (every 30 s for 10 minutes, 3.8)
    public double EscalateMinutes = 10, BatchSeconds = 20, InflightMinutes = 10, EscalateRetrySeconds = 30, EscalateRetryMinutes = 10;
    // timing.msgOnlineSeconds, msgAwaySeconds, msgOfflineListMinutes: the presence windows (2: online 90 s, away 10 min, an offline session listed 60 min)
    public double OnlineSeconds = MessageStore.PresenceSeconds, AwaySeconds = 600, OfflineListMinutes = 60;
    // timing.mgrOwnedGraceSeconds: an owner the sweep no longer lists is dropped this long after its accept (3.9)
    public double OwnedGraceSeconds = 60;
    // a broadcast (3.7): 1,000 characters, 2 per 10 minutes per sender
    public int MaxBroadcastChars = 1000, BroadcastPer10Min = 2;
    // timing.mgrLeftSeconds: supervisor.left is pushed once the supervisor has not been heard for this long (3.2: 2 minutes)
    public double LeftSeconds = 120;
    public bool AllowBroadcast = true;
    public double TtlMinutes = 1440;
    // One catalogue of credential patterns (5.4), the ai-directed patterns of the inspector (5.3), and the gateway's own secrets as literals.
    public Regex[] SecretPatterns = Array.Empty<Regex>(), AiPatterns = Array.Empty<Regex>();
    public string[] SecretLiterals = Array.Empty<string>();
    // Either feature on: event ids carry the epoch, presence is stamped, the supervisor slot exists.
    public bool On => Configured || ManagerEnabled;
    // The patrol and its budgets (3.9): timing.mgrPatrolMinutes (the operator sets 5 to 240 at run time), the recompute period, the stall, lease,
    // disconnect and waiting thresholds (the higher buckets are multiples), the baseline and reminder limits, the step budgets and the digest's own limits.
    public double PatrolMinutes = 10, DigestSeconds = 30, StallMinutes = 45, LeaseWarnMinutes = 5, DisconnectGraceMinutes = 5, WaitingMinutes = 30, BaselineMinutes = 30, RemindMinutes = 60;
    public int StepBudgetPerHour = 60, StepHardPerHour = 90, RefusalCount = 3, DigestMaxBytes = 4096;
    public string[] WaitCodes = { "qc-not-run", "qc-approval-missing", "held" };
    // The conditions the supervisor reports to the operator (3.9 "Reported conditions"): timing.mgrQuietMinutes (an owned item without a verb),
    // mgrNoteMinutes (how long a worker's note to the operator, or a refused merge, stays in the digest), mgrPersistMinutes (after which such an
    // entry is worse once, for the one reminder), mgrVerbErrorMinutes and digest.verbErrorCount (failed verbs of one worker on one item), and
    // mgrRestartMinutes (how long after its start a gateway reports that sessions came back from an earlier process).
    public double QuietMinutes = 20, NoteMinutes = 60, PersistMinutes = 30, VerbErrorMinutes = 10, RestartMinutes = 30;
    public int VerbErrorCount = 3, ChecksRedCount = 2;
    // The Release Queue (enhancement 9): timing.mgrReleaseQueueMinutes (the oldest item waits longer than this) or digest.releaseQueueCount (this many
    // items wait) makes release-queue-aged: the promotion to uat is the owner's, and the digest only says that it is due.
    public double ReleaseQueueMinutes = 60;
    // timing.questionDedupeMinutes (issue 105): the same question text about the same item from the same name within this window, while it is open, is not relayed again
    public double QuestionDedupeMinutes = 60;
    public int ReleaseQueueCount = 3;
    // The model requirement (4.7): the ladder of the gateway host's models.default.json, lowest rung first, as (name, model).
    public string RequiredModelTier = "premium", RequiredEffort = "high";
    public bool EnforceModel;
    public string[] AcceptableModels = Array.Empty<string>();
    public (string Name, string Model)[] Ladder = Array.Empty<(string, string)>();
    static readonly string[] Efforts = { "low", "medium", "high", "xhigh", "max" };
    // ok: the declared model is on the required rung or above (or listed in manager.acceptableModels, as an id or a prefix) and the effort is the
    // required one or higher; undeclared: nothing was sent; weak: anything else. Declared, never verified.
    public string ModelCheck(string model, string effort) => ModelCheck(model, effort, RequiredModelTier, RequiredEffort);
    public string OperatorModelCheck(string model, string effort) => ModelCheck(model, effort, OperatorRequiredModelTier, OperatorRequiredEffort);
    public string ModelCheckFor(string model, string effort, string tier, string needEffort) => ModelCheck(model, effort, tier, needEffort);
    string ModelCheck(string model, string effort, string tier, string needEffort)
    {
        if (model == "" && effort == "") return "undeclared";
        var need = Array.FindIndex(Ladder, r => r.Name == tier); var have = Array.FindIndex(Ladder, r => r.Model == model);
        var modelOk = model != "" && ((need >= 0 && have >= need) || AcceptableModels.Any(a => a.Length > 0 && model.StartsWith(a, StringComparison.Ordinal)));
        var effortOk = Array.IndexOf(Efforts, effort) is var e && e >= 0 && e >= Math.Max(0, Array.IndexOf(Efforts, needEffort));
        return modelOk && effortOk ? "ok" : "weak";
    }
    public int MaxTextBytes => MaxTextChars * 3;
    public bool WorkerAllowed(string name) => AllowedWorkers.Contains("*") || AllowedWorkers.Contains(name);
    public bool AskerAllowed(string name) => AllowedAskers.Contains("*") || AllowedAskers.Contains(name);
    // A name whose presence is recorded: an allowed worker or a supervisor name. Requests of any other name leave no listed entry.
    public bool PresenceAllowed(string name) => WorkerAllowed(name) || ManagerNames.Contains(name);

    // The shipped catalogue, used when config/instance.json has no secrets.patterns (the config is the source of truth).
    static readonly string[] BuiltinSecretPatterns =
    {
        @"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)", @"gh[pousr]_[A-Za-z0-9]{20,}", @"xox[baprs]-[A-Za-z0-9-]{10,}", @"AKIA[0-9A-Z]{16}",
        @"\b(w1|w2|m1|i1|q1|o1|k1|r1|n1)\.[A-Za-z0-9_.-]{20,}", @"(?i)authorization:\s*bearer\s+[A-Za-z0-9._~+/=-]{20,}",
        @"(?i)\b(bearer|token|secret|password|api[_-]?key)\b\s*[:=]\s*([""'][^""']{8,}[""']|[A-Za-z0-9+/_-]{20,}={0,2})"
    };

    public static MessagingSettings Load(string scriptsDir, bool ownerMode)
    {
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? root = null; try { root = JsonNode.Parse(File.ReadAllText(path)); } catch { }
        var m = root?["messaging"]; var g = root?["manager"]; var t = root?["timing"];
        double Timing(string k, double d) { var env = Environment.GetEnvironmentVariable("FACTORY_TIMING_" + k); if (double.TryParse(env, out var ev)) return ev; return t?[k] is JsonNode n && double.TryParse(n.ToString(), out var v) ? v : d; }
        // a limit: FACTORY_TIMING_<key> wins, then the config section, then the default; never below the minimum
        int Limit(JsonNode? section, string k, int d, int min = 1)
        {
            var env = Environment.GetEnvironmentVariable("FACTORY_TIMING_" + k);
            if (double.TryParse(env, NumberStyles.Float, CultureInfo.InvariantCulture, out var ev) && double.IsFinite(ev)) return (int)Math.Clamp(ev, min, 1_000_000_000);
            if (section?[k] is JsonNode n && double.TryParse(n.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) && double.IsFinite(v)) return (int)Math.Clamp(v, min, 1_000_000_000);
            return d;
        }
        static string[] List(JsonNode? n) => n is JsonArray a ? a.Select(x => x!.ToString()).ToArray() : Array.Empty<string>();
        var names = g?["allowedNames"] is JsonArray a ? a.Select(n => n!.ToString()).ToArray() : new[] { "supervisor" };
        var s = new MessagingSettings
        {
            Enabled = m?["enabled"]?.GetValue<bool>() ?? false,
            ManagerEnabled = g?["enabled"]?.GetValue<bool>() ?? false,
            ManagerNames = names,
            TokenGeneration = g?["tokenGeneration"]?.GetValue<int>() ?? 1,
            Reserved = Auth.ReservedNames(names),
            AllowedWorkers = List(m?["allowedWorkers"]),
            AllowedAskers = List(g?["allowedAskers"]),
            TakeoverSeconds = Timing("mgrTakeoverSeconds", MessageStore.PresenceSeconds) is var tk && double.IsFinite(tk) && tk >= 0 ? tk : MessageStore.PresenceSeconds,
            TestHooks = m?["testHooks"]?.GetValue<bool>() ?? false,
            MaxTextChars = Limit(m, "maxTextChars", 2000),
            RatePerMinute = Limit(m, "ratePerMinute", 12),
            PairPer10Min = Limit(m, "pairPer10Min", 10),
            PerSenderQueueCap = Limit(m, "perSenderQueueCap", 20),
            RecipientQueueCap = Limit(m, "recipientQueueCap", 100),
            AsksPerHour = Limit(g, "asksPerHour", 6),
            MaxOpenQuestions = Limit(g, "maxOpenQuestionsPerWorker", 3),
            AnswerSlaSeconds = Limit(g, "answerSlaSeconds", 120),
            MaxBroadcastChars = Limit(m, "maxBroadcastChars", 1000),
            BroadcastPer10Min = Limit(m, "broadcastPer10Min", 2),
            LeftSeconds = Timing("mgrLeftSeconds", 120) is var lf && double.IsFinite(lf) && lf > 0 ? lf : 120,
            AllowBroadcast = m?["allowBroadcast"]?.GetValue<bool>() ?? true,
            BatchMax = Limit(g, "batchMax", 5),
            SupervisorPer10Min = Limit(g, "supervisorPer10Min", 20),
            TurnBudgetPerHour = Limit(g, "turnBudgetPerHour", 12),
            TurnBudgetPerDay = Limit(g, "turnBudgetPerDay", 96),
            PatrolReservePerHour = Limit(g, "patrolReservePerHour", 2, 0),
        };
        // a duration: FACTORY_TIMING_<key>, then timing.<key>, then the default; a value that is not a positive number is the default
        double Span(string k, double d) => Timing(k, d) is var v && double.IsFinite(v) && v > 0 ? v : d;
        s.EscalateMinutes = Span("mgrEscalateMinutes", 10); s.BatchSeconds = Span("mgrBatchSeconds", 20); s.InflightMinutes = Span("mgrInflightMinutes", 10);
        s.EscalateRetrySeconds = Span("mgrEscalateRetrySeconds", 30); s.EscalateRetryMinutes = Span("mgrEscalateRetryMinutes", 10);
        s.OnlineSeconds = Span("msgOnlineSeconds", MessageStore.PresenceSeconds); s.AwaySeconds = Math.Max(s.OnlineSeconds, Span("msgAwaySeconds", 600)); s.OfflineListMinutes = Span("msgOfflineListMinutes", 60);
        s.OwnedGraceSeconds = Span("mgrOwnedGraceSeconds", 60);
        // the floor of the batch window (4.5): a window under 5 seconds is honoured only on a gateway of the Tier 1 suites (messaging.testHooks)
        if (!s.TestHooks) s.BatchSeconds = Math.Max(5, s.BatchSeconds);
        // the patrol (3.9): the same rule for its floor of 5 minutes and for the recompute period
        s.PatrolMinutes = Span("mgrPatrolMinutes", 10); s.DigestSeconds = Span("mgrDigestSeconds", 30);
        if (!s.TestHooks) { s.PatrolMinutes = Math.Clamp(s.PatrolMinutes, 5, 240); s.DigestSeconds = Math.Max(5, s.DigestSeconds); }
        s.StallMinutes = Span("mgrStallMinutes", 45); s.LeaseWarnMinutes = Span("mgrLeaseWarnMinutes", 5); s.DisconnectGraceMinutes = Span("mgrDisconnectGraceMinutes", 5);
        s.WaitingMinutes = Span("mgrWaitingMinutes", 30); s.BaselineMinutes = Span("mgrBaselineMinutes", 30); s.RemindMinutes = Span("mgrRemindMinutes", 60);
        s.StepBudgetPerHour = Limit(g, "stepBudgetPerHour", 60); s.StepHardPerHour = Math.Max(s.StepBudgetPerHour, Limit(g, "stepBudgetHardPerHour", (s.StepBudgetPerHour * 3 + 1) / 2));
        var dg = g?["digest"];
        s.RefusalCount = Limit(dg, "refusalCount", 3); s.DigestMaxBytes = Limit(dg, "maxBytes", 4096, 512);
        s.QuietMinutes = Span("mgrQuietMinutes", 20); s.NoteMinutes = Span("mgrNoteMinutes", 60); s.PersistMinutes = Span("mgrPersistMinutes", 30);
        s.VerbErrorMinutes = Span("mgrVerbErrorMinutes", 10); s.RestartMinutes = Span("mgrRestartMinutes", 30); s.VerbErrorCount = Limit(dg, "verbErrorCount", 3); s.ChecksRedCount = Limit(dg, "checksRedCount", 2);
        s.ReleaseQueueMinutes = Span("mgrReleaseQueueMinutes", 60); s.ReleaseQueueCount = Limit(dg, "releaseQueueCount", 3);
        s.QuestionDedupeMinutes = Span("questionDedupeMinutes", 60);
        if (dg?["waitCodes"] is JsonArray wc) s.WaitCodes = List(wc);
        s.RequiredModelTier = g?["requiredModelTier"]?.ToString() ?? "premium"; s.RequiredEffort = g?["requiredEffort"]?.ToString() ?? "high";
        s.EnforceModel = g?["enforceModel"]?.GetValue<bool>() ?? false; s.AcceptableModels = List(g?["acceptableModels"]);
        var ttl = Timing("msgTtlMinutes", 1440); s.TtlMinutes = double.IsFinite(ttl) && ttl > 0 ? ttl : 1440;
        var on = Environment.GetEnvironmentVariable("FACTORY_MESSAGING"); if (on is "0" or "1") s.Enabled = on == "1";
        var sup = Environment.GetEnvironmentVariable("FACTORY_MANAGER"); if (sup is "0" or "1") s.ManagerEnabled = sup == "1";
        if ((s.Enabled || s.ManagerEnabled) && !ownerMode)
            throw new InvalidOperationException("messaging.enabled and manager.enabled need owner mode (FACTORY_OWNER_MODE=1)");
        if (s.ManagerEnabled && !s.Enabled)
            throw new InvalidOperationException("manager.enabled needs messaging.enabled");
        s.Configured = s.Enabled;
        // the factory operator session: operator.enabled (FACTORY_OPERATOR=0|1 overrides it), only with messaging on; its names are reserved while it is on
        var op = root?["operator"];
        s.OperatorEnabled = op?["enabled"]?.GetValue<bool>() ?? false;
        var opOn = Environment.GetEnvironmentVariable("FACTORY_OPERATOR"); if (opOn is "0" or "1") s.OperatorEnabled = opOn == "1";
        if (s.OperatorEnabled && !s.Enabled) throw new InvalidOperationException("operator.enabled needs messaging.enabled");
        if (s.OperatorEnabled)
        {
            s.OperatorNames = (op?["allowedNames"] is JsonArray oa ? oa.Select(n => n!.ToString()).ToArray() : new[] { "operator-session" }).Where(Auth.ValidName).ToArray();
            s.OperatorTokenGeneration = op?["tokenGeneration"]?.GetValue<int>() ?? 1;
            s.OperatorMaxSelfMergesPerDay = Limit(op, "maxSelfMergesPerDay", 12, 0);
            s.OperatorRequiredModelTier = op?["requiredModelTier"]?.ToString() ?? "premium"; s.OperatorRequiredEffort = op?["requiredEffort"]?.ToString() ?? "low";
            s.Reserved = Auth.ReservedNames(names.Concat(s.OperatorNames));
            s.OperatorSelfAnswerMinutes = Timing("opSelfAnswerMinutes", 10) is var sa && double.IsFinite(sa) && sa > 0 ? sa : 10;
        }
        if (s.ManagerEnabled || s.OperatorEnabled)
        {   // the ladder the model check reads (4.7); a host without the file flags every declared model weak unless manager.acceptableModels lists it
            try { s.Ladder = (JsonNode.Parse(File.ReadAllText(Path.Combine(scriptsDir, "models.default.json")))?["ladder"] as JsonArray ?? new JsonArray()).Select(x => (x?["name"]?.ToString() ?? "", x?["model"]?.ToString() ?? "")).ToArray(); }
            catch { }
        }
        if (s.On)
        {   // the patterns are compiled only when a feature is on: a default deployment never reads them
            var pats = root?["secrets"]?["patterns"] is JsonArray pa ? pa.Select(x => x!.ToString()).Where(x => x.Length > 0).ToArray() : Array.Empty<string>();
            if (pats.Length == 0) pats = BuiltinSecretPatterns;
            var ai = root?["inspector"]?["aiDirectedText"] is JsonArray aa ? aa.Select(x => x!.ToString()).Where(x => x.Length > 0).ToArray() : Array.Empty<string>();
            static Regex Compile(string p) => new(p, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
            try { s.SecretPatterns = pats.Select(Compile).ToArray(); s.AiPatterns = ai.Select(Compile).ToArray(); }
            catch (ArgumentException e) { throw new InvalidOperationException("secrets.patterns or inspector.aiDirectedText holds an invalid pattern: " + e.Message); }
        }
        var env = Environment.GetEnvironmentVariable("FACTORY_ENVIRONMENT") ?? "tdd";
        var scaleToZero = m?["scaleToZeroEnvironments"] is JsonArray z ? z.Select(x => x!.ToString()).ToArray() : new[] { "tdd", "uat" };
        s.ScaleToZero = (s.Enabled || s.ManagerEnabled) && scaleToZero.Contains(env);
        if (s.ScaleToZero)
            Console.Error.WriteLine($"messaging: {env} scales to zero, so messages and questions wait until the gateway is up (worker-messaging.md 4.5)");
        return s;
    }
}

// One message in a recipient's inbox. State: queued (no open channel at send), pushed (written to an open channel; not receipt), delivered (the
// client printed it and said so), handled (the model's ack), expired (past the TTL). Undelivered = queued or pushed.
sealed class InboxEntry
{
    public long Seq;
    public string Id = "", Json = "", State = "queued";
    public DateTime At;
    public DateTime? HandledAt;
    // sender and kind of the message, for the queue caps (3.7); a peer note is counted, an answer, directive or operator note is exempt
    public string From = "", FromKind = "", Type = "";
    public bool Peer;
    public MessageRecord? Rec;
    public bool Undelivered => State is "queued" or "pushed";
}

// The sender's side of one message (3.5 "Sender status", 3.8): its per-recipient states survive the purge of the inbox entries, so GET /messages/{id}
// can still say handled or expired. A question has no recipient inbox: it is this record (the question table of 3.8), and its own state is open,
// answered, expired or moot, with the flags late (computed from its age) and escalated.
sealed class MessageRecord
{
    public string Id = "", Type = "", Kind = "", From = "", FromKind = "", ClientId = "";
    public int? Item;
    public DateTime At;
    public int Bytes;
    public readonly Dictionary<string, string> Per = new();
    public string QState = "", AnswerId = "", AnswerJson = "";
    public long N;                                   // the number in the id: the order of arrival
    // a question (3.8): its text and context for the supervisor's batch, when it was put into a batch, who answered, the decision note
    public string QText = "", QContext = "", AnsweredBy = "", Note = "", JournalFailed = "";
    public int Repeats;   // issue 105: how often the same question was asked again while it was open (not relayed again)
    public string[] QFlags = Array.Empty<string>();
    public DateTime? DeliveredAt, AnsweredAt, EscalatedAt;
    public bool Escalated, OwnedAtAsk, Redeliver;
    static readonly string[] Order = { "queued", "pushed", "delivered", "handled" };
    // The state the sender sees: for several recipients the slowest one (a message is delivered when every recipient delivered it).
    public string State()
    {
        if (Type == "question") return QState == "" ? "open" : QState;
        if (Per.Count == 0) return "queued";
        var live = Per.Values.Where(v => v != "expired").ToList();
        if (live.Count == 0) return "expired";
        return live.OrderBy(v => Array.IndexOf(Order, v)).First();
    }
}

// Per-name record (3.5): the event counter shared by triggers and messages, the inbox, the operator's mode, presence and the wake signal.
// Created on first use, so a message can wait for a name that has not connected since the restart; never removed (like WorkerInfo).
sealed class Recipient
{
    public string Name = "";
    public long Next = 1;
    public readonly List<InboxEntry> Inbox = new();
    public string Mode = "on";
    public DateTime? LastHeard, GoneAt;
    public string Via = "";
    public bool MessagingClient;           // registered with messaging=1: only such a stream receives message events (3.4)
    public string Summary = ""; public DateTime SummaryAt;
    public TaskCompletionSource Signal = NewSignal();
    // Continuations run asynchronously, so completing the signal under the gate never runs a waiter's code inside the lock.
    public static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
}

// The supervisor (2.1, 4.6): held apart from the workers, so it has no capacity, no roles that Choose reads, no assignments and never appears in Status().
sealed class ManagerSlot
{
    public string Name = "", Model = "", Effort = "", ModelCheck = "undeclared";
    public DateTime Since, RegisteredAt;
    public Channel<(long, string)>? Out;
}

// Messaging state. NOT thread-safe by itself: every member is used only by Plant while it holds its gate (3.5, "one lock").
sealed class MessageStore
{
    public readonly string Epoch = "e-" + Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
    public readonly Dictionary<string, Recipient> Recipients = new();
    public readonly Dictionary<string, MessageRecord> Records = new();
    public readonly Queue<string> RecordOrder = new();
    public ManagerSlot? Slot;
    public long MessageCounter, BatchCounter;
    // Questions (3.8): when the batch window opened, the deliveries of the sliding day (3.9), the decision log (last 50) and the log lines that
    // Plant produced under the gate and the Messenger writes outside it.
    public DateTime? WindowAt;
    public readonly List<DateTime> Deliveries = new();
    public readonly List<(DateTime At, int? Item, string By, string Note, string Question, long Patrol)> Decisions = new();
    public readonly List<JsonObject> LogQueue = new();
    public bool BudgetLogged;
    // The patrol (3.9): what was pushed per entry key and at which bucket, the patrols by their seq, when the last one left, the interval slot that
    // counts a suppressed patrol, the last baseline, the session states of the last digest, the last digest for the operator's preview, the
    // supervisor's steps of the sliding hour, and the operator's grants of extra deliveries (each lasts an hour).
    public sealed class ReportedEntry { public int Bucket; public DateTime At, Seen; public bool Acked, Reminded; }
    public sealed class PatrolRecord { public long Seq; public DateTime At; public bool Acked; public string MessageId = ""; public List<(string Key, int Bucket)> Entries = new(); }
    public readonly Dictionary<string, ReportedEntry> Reported = new();
    public readonly Dictionary<long, PatrolRecord> Patrols = new();
    public readonly Dictionary<string, string> SessionState = new();
    public long PatrolSeq, PatrolsSent, PatrolsSuppressed, PatrolsDropped, PatrolsReminded;
    public DateTime LastPatrolAt, LastSlotAt, LastDigestAt;
    public DateTime? LastBaselineAt;
    public bool SentThisSlot, PatrolBudgetLogged;
    public string LastDigest = "";
    public readonly List<DateTime> Steps = new(), PatrolDeliveries = new();
    public readonly List<(DateTime At, int N)> Grants = new();
    // how many inbox entries reached each state since the process started (8): counts only, for /status
    public long Pushed, Delivered, Handled, Expired;
    public Recipient Get(string name) { if (!Recipients.TryGetValue(name, out var r)) Recipients[name] = r = new Recipient { Name = name }; return r; }

    // The presence window (3.7, 4.6): online, and for the supervisor present, while the last request is less than this many seconds old.
    public const double PresenceSeconds = 90;
    public static bool Within(DateTime? heard, DateTime now, double seconds) => heard is { } h && (now - h).TotalSeconds < seconds;
}

// What the Messenger asks Plant to deliver (all state-dependent checks run inside Plant, under its gate) and what Plant answers.
sealed class SendSpec
{
    public string From = "", FromKind = "", Type = "note", Kind = "direct", ClientId = "";
    public int? Item;
    public string[] To = Array.Empty<string>();     // names, or "operator" (logged, not queued anywhere)
    public bool Peer;                                // a worker's peer note: counted by the queue caps, refused by inbound-off
    public bool Operator;                            // from the operator: may reach a name that only asks
    public bool Question;
    public bool Supervisor;                          // a directive or an announcement: reaches a name that only asks, exempt from the queue caps
    public string Context = "";                      // a question's context
    public bool Broadcast;                           // to "*": Plant derives the recipients (2, 4.4)
    public int? Thread;                              // thread item-N: Plant derives the recipients from the item's owner and QC worker
    public JsonObject Event = new();                 // the message.received template; Plant fills to, id, seq, epoch, unacked and replayed
}

sealed class SendOutcome
{
    public string Id = "", Code = "", Reason = "";
    public readonly List<(string Name, string State)> Delivered = new();
    public readonly List<(string Name, string Code)> Refused = new();
    public int Pushed, Queued;
    public bool Ok => Code == "";
}

sealed class MessageSnapshot
{
    public string Id = "", Type = "", Kind = "", State = "", From = "", AnswerJson = "";
    public bool Late, Escalated;
    public int? Item;
    public DateTime At;
    public Dictionary<string, string> Per = new();
}

readonly record struct MsgResult(int Status, JsonObject Body);

// An escalated question whose asker owns its item: one journal comment, posted by the ticker with a retry while the item lock is busy (3.8).
sealed record EscalationJob(string Id, int Item, string Worker, int Minutes, string Supervisor);

sealed class QuestionEvents
{
    public readonly List<JsonObject> Log = new();
    public readonly List<EscalationJob> Escalations = new();
}

// ---- the patrol digest (3.9). Plant takes the input under its gate; the builder is a pure function of it: no model, no Runner, no text of a
// worker, a question, GitHub or a label. Every string it writes is a session name (ValidName), a gated column or code, a gateway id or one of the
// enumerated values below; DigestSchema is the explicit field list the Tier 1 scenario validates every digest against. --------------------------
sealed record DigestSession(string Name, string Type, bool Connected, DateTime? LastHeard, DateTime? GoneAt);
// LastProgress: the last verb call for the item (a /wait poll is activity, not progress); QuietWait: a known wait, or a merge that is settling.
sealed record DigestOwned(int Item, string Holder, string Column, DateTime? LeaseUntil, bool KnownWait, DateTime Since, DateTime? LastActivity, DateTime? LastProgress = null, bool QuietWait = false);
sealed record DigestQuestion(string Id, string From, int? Item, DateTime At, bool Late, bool Escalated);
sealed class DigestInput
{
    public DateTime Now;
    public List<DigestSession> Sessions = new();
    public List<DigestOwned> Owned = new();
    public List<(int Item, string Code, DateTime Since)> Waiting = new();
    public List<(int Item, string Code, int Count)> Refusals = new();
    public List<(int Item, string Code, DateTime At)> Parks = new();
    public List<DigestQuestion> Questions = new();
    public int OpenQuestions;
    // The reported conditions (3.9): numbers, names, gateway ids and gated codes only; never the text of a note, a review or an error.
    public List<(int Item, string Worker, string Id, int Count, DateTime At)> BlockedNotes = new();
    public List<(int Item, string Worker, string Column, int Round, int Max, DateTime At)> Reviews = new();
    public List<(int Item, string Worker, int Count, List<(string Code, int Count)> ByCode)> VerbErrors = new();
    public List<(int Item, int RoundTrip, DateTime At)> MergeRefused = new();
    // a PASS the gateway has not merged yet, after timing.passUnmergedDigestMinutes: the reason code of the wait and since when (the verdict)
    public List<(int Item, string Code, int Pr, DateTime Since)> PassUnmerged = new();
    public double PassUnmergedMinutes = 5;
    // sessions blocked after items were taken back from them (issue 100): offered nothing until they call a verb of their own
    public List<(string Name, int Item, DateTime Since)> BlockedSessions = new();
    public (int Reconnected, int Missing, int UpMinutes)? Restart;
    // the items the sweep found waiting in the Release Queue column for the production deployment, with their release and since when
    public List<(int Item, string Release, DateTime Since)> ReleaseQueue = new();
    public bool PromotionRequested;
}
sealed class DigestEntry
{
    public string Key = "", Kind = "", Worker = "";
    public int Bucket;
    public JsonObject Fields = new();
    public bool New, Reminder;
}

static class DigestBuilder
{
    public const int SchemaVersion = 1;
    public static readonly string[] Kinds = { "stalled", "disconnected-owner", "late-question", "waiting", "refusals", "parked",
        "gateway-restarted", "review-rounds-exhausted", "merge-refused", "worker-blocked-note", "verb-errors", "last-review-round", "item-quiet", "release-queue-aged", "pass-unmerged", "session-blocked" };
    static int Min(TimeSpan t) => (int)Math.Max(0, Math.Floor(t.TotalMinutes));
    static int Step(double value, double unit) => value >= unit * 4 ? 3 : value >= unit * 2 ? 2 : value >= unit ? 1 : 0;

    // Every attention entry of this moment with its key and bucket (3.9 "Buckets" and "Known waits are not stalls"). Minutes are shown and play no
    // part in what is new or worse: that is decided on the buckets alone.
    public static List<DigestEntry> Attention(DigestInput d, MessagingSettings cfg)
    {
        var list = new List<DigestEntry>(); var now = d.Now;
        var sessions = d.Sessions.ToDictionary(s => s.Name, s => s);
        foreach (var o in d.Owned)
        {
            sessions.TryGetValue(o.Holder, out var s);
            int? leaseLeft = o.LeaseUntil is { } l ? (int)Math.Floor((l - now).TotalMinutes) : null;
            var lapsed = o.LeaseUntil is { } l2 && l2 <= now;
            if (s is not { Connected: true })
            {   // a worker that is not connected is reported as disconnected-owner only
                var since = new[] { s?.GoneAt, s?.LastHeard }.Where(x => x != null).Select(x => x!.Value).DefaultIfEmpty(o.Since).Max();
                var gone = (now - since).TotalMinutes;
                var b = gone >= cfg.DisconnectGraceMinutes * 3 ? 2 : gone >= cfg.DisconnectGraceMinutes ? 1 : 0;
                if (b > 0 && lapsed) b = 3;
                if (b > 0) list.Add(new DigestEntry { Key = $"disconnected-owner|{o.Holder}|{o.Item}", Kind = "disconnected-owner", Worker = o.Holder, Bucket = b,
                    Fields = new JsonObject { ["kind"] = "disconnected-owner", ["worker"] = o.Holder, ["item"] = o.Item, ["column"] = o.Column, ["bucket"] = b, ["goneMinutes"] = Min(now - since), ["leaseLeftMinutes"] = leaseLeft } });
                continue;
            }
            if (o.KnownWait) continue;
            var last = o.LastActivity is { } la && la > o.Since ? la : o.Since;
            var sb = Step((now - last).TotalMinutes, cfg.StallMinutes);
            if (lapsed) sb = Math.Max(sb, 2); else if (o.LeaseUntil is { } l3 && (l3 - now).TotalMinutes < cfg.LeaseWarnMinutes) sb = Math.Max(sb, 1);
            if (sb > 0) list.Add(new DigestEntry { Key = $"stalled|{o.Holder}|{o.Item}", Kind = "stalled", Worker = o.Holder, Bucket = sb,
                Fields = new JsonObject { ["kind"] = "stalled", ["worker"] = o.Holder, ["item"] = o.Item, ["column"] = o.Column, ["bucket"] = sb, ["idleMinutes"] = Min(now - last), ["leaseLeftMinutes"] = leaseLeft } });
            else if (!o.QuietWait)
            {   // item-quiet: connected and polling, but no verb for the item (so no journal entry either) for mgrQuietMinutes; a stall replaces it
                var progress = o.LastProgress is { } lp && lp > o.Since ? lp : o.Since;
                var qb = Step((now - progress).TotalMinutes, cfg.QuietMinutes);
                if (qb > 0) list.Add(new DigestEntry { Key = $"item-quiet|{o.Holder}|{o.Item}", Kind = "item-quiet", Worker = o.Holder, Bucket = qb,
                    Fields = new JsonObject { ["kind"] = "item-quiet", ["worker"] = o.Holder, ["item"] = o.Item, ["column"] = o.Column, ["bucket"] = qb, ["quietMinutes"] = Min(now - progress) } });
            }
        }
        foreach (var q in d.Questions.Where(q => q.Late || q.Escalated))
        {
            var b = q.Escalated ? 2 : 1;
            list.Add(new DigestEntry { Key = "late-question|" + q.Id, Kind = "late-question", Worker = q.From, Bucket = b,
                Fields = new JsonObject { ["kind"] = "late-question", ["id"] = q.Id, ["worker"] = q.From, ["item"] = q.Item, ["bucket"] = b, ["ageMinutes"] = Min(now - q.At) } });
        }
        foreach (var w in d.Waiting)
        {
            var b = Step((now - w.Since).TotalMinutes, cfg.WaitingMinutes);
            if (b > 0) list.Add(new DigestEntry { Key = $"waiting|{w.Item}", Kind = "waiting", Bucket = b,
                Fields = new JsonObject { ["kind"] = "waiting", ["item"] = w.Item, ["code"] = w.Code == "" ? "other" : w.Code, ["bucket"] = b, ["waitingMinutes"] = Min(now - w.Since) } });
        }
        foreach (var r in d.Refusals.Where(r => r.Code != "" && !cfg.WaitCodes.Contains(r.Code)))
        {
            var b = Step(r.Count, r.Code is "checks-red" or "checks-not-green" or "private-build-required" ? cfg.ChecksRedCount : cfg.RefusalCount);   // red checks are reported at 2
            if (b > 0) list.Add(new DigestEntry { Key = $"refusals|{r.Item}|{r.Code}", Kind = "refusals", Bucket = b,
                Fields = new JsonObject { ["kind"] = "refusals", ["item"] = r.Item, ["code"] = r.Code, ["bucket"] = b, ["count"] = r.Count, ["windowMinutes"] = 60 } });
        }
        foreach (var p in d.Parks)
        {
            var code = p.Code == "" ? "other" : p.Code;
            list.Add(new DigestEntry { Key = $"parked|{p.Item}|{code}", Kind = "parked", Bucket = 1,
                Fields = new JsonObject { ["kind"] = "parked", ["item"] = p.Item, ["code"] = code, ["bucket"] = 1, ["ageMinutes"] = Min(now - p.At) } });
        }
        // The reported conditions. One that is an event (a note, a review round, a refused merge) is worse once, after mgrPersistMinutes: that is
        // the one reminder of a problem nobody resolved.
        int Persist(DateTime at) => (now - at).TotalMinutes >= cfg.PersistMinutes ? 2 : 1;
        foreach (var n in d.BlockedNotes)
        {
            var b = Persist(n.At);
            list.Add(new DigestEntry { Key = $"worker-blocked-note|{n.Item}", Kind = "worker-blocked-note", Worker = n.Worker, Bucket = b,
                Fields = new JsonObject { ["kind"] = "worker-blocked-note", ["worker"] = n.Worker, ["item"] = n.Item, ["id"] = n.Id, ["bucket"] = b, ["count"] = n.Count, ["ageMinutes"] = Min(now - n.At) } });
        }
        foreach (var r in d.Reviews)
        {
            var kind = r.Round >= r.Max ? "review-rounds-exhausted" : "last-review-round"; var b = Persist(r.At);
            list.Add(new DigestEntry { Key = $"{kind}|{r.Item}", Kind = kind, Worker = r.Worker, Bucket = b,
                Fields = new JsonObject { ["kind"] = kind, ["worker"] = r.Worker, ["item"] = r.Item, ["column"] = r.Column, ["bucket"] = b, ["round"] = r.Round, ["maxRounds"] = r.Max, ["ageMinutes"] = Min(now - r.At) } });
        }
        foreach (var v in d.VerbErrors)
        {
            var b = Step(v.Count, cfg.VerbErrorCount);
            if (b == 0) continue;
            var by = new JsonObject(); foreach (var (code, count) in v.ByCode.Take(4)) by[code] = count;
            list.Add(new DigestEntry { Key = $"verb-errors|{v.Worker}|{v.Item}", Kind = "verb-errors", Worker = v.Worker, Bucket = b,
                Fields = new JsonObject { ["kind"] = "verb-errors", ["worker"] = v.Worker, ["item"] = v.Item, ["bucket"] = b, ["count"] = v.Count, ["byCode"] = by, ["windowMinutes"] = (int)Math.Ceiling(cfg.VerbErrorMinutes) } });
        }
        foreach (var m in d.MergeRefused)
        {
            var b = Math.Clamp(m.RoundTrip, 1, 3);
            list.Add(new DigestEntry { Key = $"merge-refused|{m.Item}", Kind = "merge-refused", Bucket = b,
                Fields = new JsonObject { ["kind"] = "merge-refused", ["item"] = m.Item, ["bucket"] = b, ["roundTrip"] = m.RoundTrip, ["ageMinutes"] = Min(now - m.At) } });
        }
        foreach (var p in d.PassUnmerged)
        {
            var b = Math.Max(1, Step((now - p.Since).TotalMinutes, Math.Max(0.1, d.PassUnmergedMinutes)));
            list.Add(new DigestEntry { Key = $"pass-unmerged|{p.Item}", Kind = "pass-unmerged", Bucket = b,
                Fields = new JsonObject { ["kind"] = "pass-unmerged", ["item"] = p.Item, ["pr"] = p.Pr, ["code"] = p.Code, ["bucket"] = b, ["waitingMinutes"] = Min(now - p.Since) } });
        }
        foreach (var bs in d.BlockedSessions)
        {   // session-blocked (issue 100): worse once after mgrPersistMinutes, the one reminder of a session nobody looked at
            var b = Persist(bs.Since);
            list.Add(new DigestEntry { Key = $"session-blocked|{bs.Name}", Kind = "session-blocked", Worker = bs.Name, Bucket = b,
                Fields = new JsonObject { ["kind"] = "session-blocked", ["worker"] = bs.Name, ["item"] = bs.Item, ["bucket"] = b, ["blockedMinutes"] = Min(now - bs.Since) } });
        }
        if (d.ReleaseQueue.Count > 0)
        {   // release-queue-aged: one entry for the whole queue; worse as the oldest item ages (60, 120, 240 min by default) or the queue grows
            var oldest = d.ReleaseQueue.OrderBy(q => q.Since).ThenBy(q => q.Item).First();
            var age = (now - oldest.Since).TotalMinutes;
            var b = Math.Max(Step(age, cfg.ReleaseQueueMinutes + 1e-9), d.ReleaseQueue.Count >= cfg.ReleaseQueueCount ? 1 : 0);
            if (b > 0) list.Add(new DigestEntry { Key = "release-queue-aged", Kind = "release-queue-aged", Bucket = b,
                Fields = new JsonObject { ["kind"] = "release-queue-aged", ["bucket"] = b, ["count"] = d.ReleaseQueue.Count, ["item"] = oldest.Item, ["oldestMinutes"] = Min(now - oldest.Since),
                    ["releases"] = d.ReleaseQueue.Select(q => q.Release).Distinct().Count(), ["promotionRequested"] = d.PromotionRequested } });
        }
        // issue 105: a restart after which every owner came back is no condition; only owners that did not reconnect are reported
        if (d.Restart is { Missing: > 0 } rs)
        {
            var b = 2;
            list.Add(new DigestEntry { Key = "gateway-restarted", Kind = "gateway-restarted", Bucket = b,
                Fields = new JsonObject { ["kind"] = "gateway-restarted", ["bucket"] = b, ["reconnected"] = rs.Reconnected, ["notReconnected"] = rs.Missing, ["upMinutes"] = rs.UpMinutes } });
        }
        return list.OrderByDescending(e => e.Bucket).ThenBy(e => Array.IndexOf(Kinds, e.Kind)).ThenBy(e => e.Key, StringComparer.Ordinal).ToList();
    }

    // The digest: the attention entries given (flagged new or reminder by the caller), the sessions that appear in them or whose state changed, the
    // others as one short entry each, cut to the cap. Over the cap `ok` goes first, then the entries that are neither new nor a reminder, then the
    // changed sessions, then entries from the lowest bucket up; `truncated` counts what was left out and `kept` returns the entries that stayed.
    public static JsonObject Build(DigestInput d, List<DigestEntry> attention, ISet<string> changedNames, string id, long seq, long sinceSeq, string epoch, bool baseline, bool reminder, MessagingSettings cfg, out List<DigestEntry> kept)
    {
        var now = d.Now; var list = attention.ToList();
        var named = list.Where(e => e.Worker != "").Select(e => e.Worker).ToHashSet();
        var changed = new List<JsonObject>(); var ok = new List<JsonObject>();
        foreach (var s in d.Sessions.OrderBy(s => s.Name, StringComparer.Ordinal))
        {
            var mine = d.Owned.Where(o => o.Holder == s.Name).OrderBy(o => o.Item).ToList();
            if (!(named.Contains(s.Name) || changedNames.Contains(s.Name))) { ok.Add(new JsonObject { ["name"] = s.Name, ["connected"] = s.Connected, ["items"] = new JsonArray(mine.Select(o => (JsonNode)o.Item).ToArray()) }); continue; }
            var acts = mine.Select(o => o.LastActivity is { } la && la > o.Since ? la : o.Since).ToList();
            changed.Add(new JsonObject
            {
                ["name"] = s.Name, ["type"] = s.Type, ["connected"] = s.Connected, ["lastHeardSeconds"] = s.LastHeard is { } lh ? (int)Math.Max(0, (now - lh).TotalSeconds) : null,
                ["activityMinutes"] = acts.Count > 0 ? Min(now - acts.Max()) : null,
                ["owned"] = new JsonArray(mine.Select(o => (JsonNode)new JsonObject { ["item"] = o.Item, ["column"] = o.Column, ["ageMinutes"] = Min(now - o.Since), ["leaseLeftMinutes"] = o.LeaseUntil is { } l ? (int)Math.Floor((l - now).TotalMinutes) : null }).ToArray())
            });
        }
        var truncated = 0;
        JsonObject Make()
        {
            var o = new JsonObject { ["provider"] = "gateway", ["event"] = "supervisor.patrol", ["schemaVersion"] = SchemaVersion };
            if (id != "") o["id"] = id;
            o["seq"] = seq; o["sinceSeq"] = sinceSeq; o["epoch"] = epoch; o["at"] = now.ToString("o"); o["baseline"] = baseline; o["reminder"] = reminder;
            o["plant"] = new JsonObject { ["sessions"] = d.Sessions.Count, ["connected"] = d.Sessions.Count(s => s.Connected), ["itemsOwned"] = d.Owned.Count, ["openQuestions"] = d.OpenQuestions,
                ["lateQuestions"] = d.Questions.Count(q => q.Late || q.Escalated), ["waiting"] = d.Waiting.Count };
            o["attention"] = new JsonArray(list.Select(e => { var f = (JsonObject)e.Fields.DeepClone(); f["new"] = e.New; if (e.Reminder) f["reminder"] = true; return (JsonNode)f; }).ToArray());
            o["changed"] = new JsonArray(changed.Select(c => c.DeepClone()).ToArray());
            o["ok"] = new JsonArray(ok.Select(c => c.DeepClone()).ToArray());
            o["truncated"] = truncated;
            return o;
        }
        var res = Make();
        while (Encoding.UTF8.GetByteCount(res.ToJsonString()) > cfg.DigestMaxBytes)
        {
            if (ok.Count > 0) { truncated += ok.Count; ok.Clear(); }
            else if (list.FindLastIndex(e => !e.New && !e.Reminder) is var i && i >= 0) { list.RemoveAt(i); truncated++; }
            else if (changed.Count > 0) { changed.RemoveAt(changed.Count - 1); truncated++; }
            else if (list.Count > 1) { list.RemoveAt(list.Count - 1); truncated++; }
            else break;
            res = Make();
        }
        kept = list;
        return res;
    }
}

// The traffic log and the refusal ring (5.4, 3.7): the log holds accepted messages with their text for the operator; the ring holds refusals
// (code, sender, recipient and size only, never the text) and flagged messages, so a noisy sender cannot push them out of the log.
sealed class TrafficEntry
{
    public DateTime At;
    public string Id = "", From = "", FromKind = "", To = "", Kind = "", Type = "", Subject = "", Text = "", Code = "", InReplyTo = "";
    public int? Item;
    public int Bytes;
    public string[] Flags = Array.Empty<string>();
}

sealed class Messenger
{
    readonly MessagingSettings cfg;
    readonly Plant plant;
    // Leaf state: rate windows, the idempotency map, the traffic log and the ring. This lock is never held while Plant is called, and Plant never
    // calls the Messenger (worker-messaging.md 3.5, "lock order").
    readonly object leaf = new();
    readonly Dictionary<string, List<DateTime>> sendWin = new(), askWin = new(), pairWin = new(), castWin = new(), supWin = new();
    readonly Dictionary<string, Idem> idem = new();
    // issue 105: the questions relayed lately, by name, item and normalized text: a repeat within questionDedupeMinutes is that question again
    readonly Dictionary<string, (string Id, DateTime At)> recentQuestions = new();
    readonly List<TrafficEntry> log = new(), ring = new();
    const int LogCap = 1000, RingCap = 500, RingPerSender = 100;
    static readonly TimeSpan LogAge = TimeSpan.FromHours(24), IdemAge = TimeSpan.FromMinutes(10);

    // counters of /status (8): how many messages were accepted, refused per code and flagged; never their text
    long sentCount, flaggedCount, questionsDeduped;
    readonly Dictionary<string, long> refusedCount = new();
    public void CountRefusal(string code) { lock (leaf) refusedCount[code] = refusedCount.GetValueOrDefault(code) + 1; }
    public void AddCounters(JsonObject messagingBlock)
    {
        lock (leaf)
        {
            messagingBlock["sent"] = sentCount; messagingBlock["flaggedAiDirected"] = flaggedCount; messagingBlock["questionsDeduped"] = questionsDeduped;
            messagingBlock["refused"] = new JsonObject(refusedCount.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value)));
        }
    }

    sealed class Idem { public DateTime At; public TaskCompletionSource<MsgResult> Done = new(TaskCreationOptions.RunContinuationsAsynchronously); }
    sealed class Ctx { public string From = "", FromKind = "", Type = "", To = "", Kind = "", Id = ""; public int? Item; public int Bytes; }
    sealed class Reservation { public readonly List<(List<DateTime> List, DateTime At)> Items = new(); }

    static readonly Regex IdRx = new(@"^m-([0-9a-f]{8})-(\d{4,})\z", RegexOptions.CultureInvariant);
    static readonly Regex ClientIdRx = new(@"^[A-Za-z0-9_-]{1,64}\z", RegexOptions.CultureInvariant);
    static readonly Regex ThreadRx = new(@"^item-\d{1,9}\z", RegexOptions.CultureInvariant);
    // ANSI escape sequences (CSI, OSC and the two-character forms), removed before the credential patterns run on the displayed form of a text.
    static readonly Regex AnsiRx = new(@"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(\x07|\x1B\\)|\x1B[@-_]", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));

    static readonly string[] NoteFields = { "type", "to", "thread", "subject", "text", "item", "inReplyTo", "clientId" };
    static readonly string[] QuestionFields = { "type", "text", "item", "context", "clientId" };
    static readonly string[] DirectiveFields = { "type", "to", "text", "item", "clientId" };
    static readonly string[] AnswerFields = { "type", "inReplyTo", "text", "note", "answers", "clientId" };
    static readonly string[] OtherFields = { "answers", "note" };

    public Messenger(MessagingSettings cfg, Plant plant) { this.cfg = cfg; this.plant = plant; }

    // A request body as a JSON object. JsonNode reads lazily, and a duplicate key only throws (ArgumentException) when the object is first
    // enumerated, which would be outside the caller's try: the whole tree is walked here, so a malformed body is a usage refusal, never a 500.
    public static JsonObject ParseObject(string text)
    {
        var o = JsonNode.Parse(text) as JsonObject ?? throw new FormatException();
        Walk(o);
        return o;
        static void Walk(JsonNode? n)
        {
            if (n is JsonObject jo) foreach (var kv in jo) Walk(kv.Value);
            else if (n is JsonArray ja) foreach (var x in ja) Walk(x);
        }
    }

    // ---- codes: HTTP status and exit (worker-messaging.md 3.3) ------------------------------------------------------------------------
    static (int Status, int Exit) Map(string code) => code switch
    {
        "usage" => (400, 2),
        "too-large" => (413, 2),
        "messaging-disabled" or "manager-disabled" or "not-owner-mode" or "not-allowed" or "forged-sender" or "not-supervisor" or "role-cannot-send" or "forbidden" => (403, 30),
        "no-such-peer" or "no-such-question" or "no-such-message" => (404, 12),
        "muted" or "not-accepting" or "independence" or "queue-full" or "too-many-open" or "item-has-open-question" or "already-answered" or "not-a-question" or "secret-in-message" => (409, 10),
        "rate-limited" or "pair-limited" or "ask-limited" or "step-budget" => (429, 20),
        _ => (400, 2)
    };

    static void LogLine(string message, Ctx c, int pushed = 0, int queued = 0, string[]? flags = null, string code = "")
    {
        // one JSON line per send, refusal and ack on the gateway's stdout, never the text (5.4)
        var o = new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["message"] = message, ["id"] = c.Id, ["type"] = c.Type, ["from"] = c.From, ["fromKind"] = c.FromKind, ["to"] = c.To, ["kind"] = c.Kind, ["item"] = c.Item, ["bytes"] = c.Bytes };
        if (message == "sent") { o["pushed"] = pushed; o["queued"] = queued; o["flags"] = new JsonArray((flags ?? Array.Empty<string>()).Select(f => (JsonNode)f).ToArray()); }
        if (code != "") o["code"] = code;
        Console.WriteLine(o.ToJsonString());
    }

    MsgResult Refused(Ctx c, string code, string reason, int retryAfter = 0)
    {
        var (st, ex) = Map(code);
        var b = new JsonObject { ["ok"] = false, ["code"] = code, ["reason"] = reason };
        if (retryAfter > 0) b["retryAfterSeconds"] = retryAfter;
        b["exit"] = ex;
        if (c.From != "") AddRing(new TrafficEntry { At = DateTime.UtcNow, From = c.From, FromKind = c.FromKind, To = c.To, Kind = c.Kind, Type = c.Type, Item = c.Item, Bytes = c.Bytes, Code = code });
        CountRefusal(code);
        LogLine("refused", c, code: code);
        return new(st, b);
    }

    // ---- the secret check and the ai-directed flag (5.3, 5.4) ------------------------------------------------------------------------------
    // The displayed form of a text: the client removes ANSI sequences, controls, format characters and line separators before the model sees it
    // (5.2), so a token split by a zero-width character would reach the model whole. The patterns therefore run on this form too.
    public static string Displayed(string s)
    {
        try { s = AnsiRx.Replace(s, ""); } catch (RegexMatchTimeoutException) { }
        var sb = new StringBuilder(s.Length);
        foreach (var r in s.EnumerateRunes())
        {
            if (r.Value is '\n' or '\r' or '\t') { sb.Append(r.ToString()); continue; }
            var cat = Rune.GetUnicodeCategory(r);
            if (cat is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator) continue;
            sb.Append(r.ToString());
        }
        return sb.ToString();
    }

    static bool AnyMatch(Regex[] rx, string s)
    {
        foreach (var r in rx)
        {   // a pattern that times out on a hostile text counts as a match: refusing is the safe side
            try { if (r.IsMatch(s)) return true; } catch (RegexMatchTimeoutException) { return true; }
        }
        return false;
    }

    // True when the text looks like a credential of this system: the catalogue (on the text and on its displayed form), or the gateway's own admin
    // token or token secret verbatim (only values of 16 characters or more, so a short development token cannot refuse ordinary words).
    public bool LooksSecret(string s)
    {
        if (s.Length == 0) return false;
        foreach (var lit in cfg.SecretLiterals) if (s.Contains(lit, StringComparison.Ordinal)) return true;
        if (AnyMatch(cfg.SecretPatterns, s)) return true;
        var d = Displayed(s);
        if (d != s) { foreach (var lit in cfg.SecretLiterals) if (d.Contains(lit, StringComparison.Ordinal)) return true; return AnyMatch(cfg.SecretPatterns, d); }
        return false;
    }

    bool AiDirected(string s) => s.Length > 0 && (AnyMatch(cfg.AiPatterns, s) || (Displayed(s) is var d && d != s && AnyMatch(cfg.AiPatterns, d)));

    static int Runes(string s) { var n = 0; foreach (var _ in s.EnumerateRunes()) n++; return n; }

    // ---- rate limits (3.7). Windows are sliding; a reservation is rolled back when Plant then refuses the message. -----------------------------
    static bool Over(List<DateTime> l, DateTime now, TimeSpan window, int limit, out int retry)
    {
        l.RemoveAll(t => now - t >= window);
        if (l.Count >= limit) { retry = Math.Max(1, (int)Math.Ceiling((l[l.Count - limit] + window - now).TotalSeconds)); return true; }
        retry = 0; return false;
    }

    static List<DateTime> Win(Dictionary<string, List<DateTime>> d, string key) { if (!d.TryGetValue(key, out var l)) d[key] = l = new(); return l; }

    // The operator session's notes (Operator.cs): the person's routing rules, its own sender kind, name, note type and rate limit.
    public const string OpSession = "operator-session";
    const int OpSessionPer10Min = 30;
    readonly Dictionary<string, List<DateTime>> opWin = new();
    static bool IsOp(Ctx c) => c.FromKind is "operator" or OpSession;
    static string NoteType(Ctx c) => c.FromKind == OpSession ? "operator-session-note" : "operator-note";
    // Returns null and a reservation when within the limits, or the refusal code with the seconds to wait. Operators are not limited.
    (string? Code, int Retry, Reservation? Res) Reserve(Ctx c, string? pairOther, bool question, bool broadcast = false, bool supervisorCast = false)
    {
        if (c.FromKind == "operator") return (null, 0, new Reservation());
        var now = DateTime.UtcNow; var res = new Reservation();
        if (c.FromKind == OpSession)
        {   // the operator SESSION is a model, not the person: its notes have a limit of their own (30 per 10 minutes, to all sessions together)
            lock (leaf)
            {
                var ow = Win(opWin, c.From);
                if (Over(ow, now, TimeSpan.FromMinutes(10), OpSessionPer10Min, out var oretry)) return ("rate-limited", oretry, null);
                ow.Add(now); return (null, 0, res);
            }
        }
        lock (leaf)
        {
            if (supervisorCast)
            {   // the supervisor's directives and announcements: 20 per 10 minutes, no pair limit and not the workers' minute (3.7)
                var cw = Win(supWin, c.From);
                if (Over(cw, now, TimeSpan.FromMinutes(10), cfg.SupervisorPer10Min, out var r0)) return ("rate-limited", r0, null);
                cw.Add(now); res.Items.Add((cw, now));
                return (null, 0, res);
            }
            var burst = Math.Max(1, cfg.RatePerMinute / 2);   // "12 per minute (burst 6)": at most half of the minute's allowance in any 10 seconds
            var sw = Win(sendWin, c.From);
            if (Over(sw, now, TimeSpan.FromSeconds(60), cfg.RatePerMinute, out var r1)) return ("rate-limited", r1, null);
            var recent = sw.Where(t => now - t < TimeSpan.FromSeconds(10)).ToList();
            if (recent.Count >= burst) return ("rate-limited", Math.Max(1, (int)Math.Ceiling((recent[recent.Count - burst] + TimeSpan.FromSeconds(10) - now).TotalSeconds)), null);
            if (question)
            {
                var aw = Win(askWin, c.From);
                if (Over(aw, now, TimeSpan.FromHours(1), cfg.AsksPerHour, out var r2)) return ("ask-limited", r2, null);
                aw.Add(now); res.Items.Add((aw, now));
            }
            if (broadcast)
            {
                var bw = Win(castWin, c.From);
                if (Over(bw, now, TimeSpan.FromMinutes(10), cfg.BroadcastPer10Min, out var r4)) { foreach (var (l, t) in res.Items) l.Remove(t); return ("rate-limited", r4, null); }
                bw.Add(now); res.Items.Add((bw, now));
            }
            if (pairOther != null)
            {
                var key = string.CompareOrdinal(c.From, pairOther) < 0 ? c.From + "|" + pairOther : pairOther + "|" + c.From;
                var pw = Win(pairWin, key);
                if (Over(pw, now, TimeSpan.FromMinutes(10), cfg.PairPer10Min, out var r3)) { foreach (var (l, t) in res.Items) l.Remove(t); return ("pair-limited", r3, null); }
                pw.Add(now); res.Items.Add((pw, now));
            }
            sw.Add(now); res.Items.Add((sw, now));
        }
        return (null, 0, res);
    }

    void Rollback(Reservation? res)
    {
        if (res == null || res.Items.Count == 0) return;
        lock (leaf) foreach (var (l, t) in res.Items) l.Remove(t);
    }

    // ---- traffic log and refusal ring --------------------------------------------------------------------------------------------------
    void AddLog(TrafficEntry t)
    {
        lock (leaf)
        {
            log.Add(t); sentCount++; if (t.Flags.Length > 0) flaggedCount++;
            if (log.Count > LogCap) log.RemoveRange(0, log.Count - LogCap);
        }
    }

    void AddRing(TrafficEntry t)
    {
        lock (leaf)
        {
            ring.Add(t);
            // one noisy sender cannot evict the others' entries: at most RingPerSender per sender, the oldest of that sender goes first
            var mine = ring.Count(x => x.From == t.From);
            if (mine > RingPerSender) { var i = ring.FindIndex(x => x.From == t.From); if (i >= 0) ring.RemoveAt(i); }
            if (ring.Count > RingCap) ring.RemoveRange(0, ring.Count - RingCap);
        }
    }

    // Test seam (GET /api/v1/_test/stores): the sizes of the Messenger's own stores with their caps. Counts only.
    public void AddStoreStats(JsonObject o)
    {
        lock (leaf)
        {
            JsonObject Row(long n, long cap) => new() { ["count"] = n, ["cap"] = cap };
            o["trafficLog"] = Row(log.Count, LogCap); o["refusalRing"] = Row(ring.Count, RingCap);
            o["ringPerSender"] = Row(ring.GroupBy(t => t.From).Select(g => g.Count()).DefaultIfEmpty(0).Max(), RingPerSender);
            o["idempotencyKeys"] = idem.Count;
            var wins = new[] { sendWin, askWin, pairWin, castWin, supWin };
            o["rateWindowKeys"] = wins.Sum(d => d.Count); o["rateWindowEntries"] = wins.Sum(d => d.Values.Sum(l => l.Count));
        }
    }

    // Prunes what has outlived its purpose: called by the plant ticker; the same pruning also runs lazily on access.
    public List<EscalationJob> Tick()
    {
        var now = DateTime.UtcNow;
        lock (leaf)
        {
            log.RemoveAll(t => now - t.At > LogAge); ring.RemoveAll(t => now - t.At > LogAge);
            foreach (var k in idem.Where(kv => now - kv.Value.At > IdemAge).Select(kv => kv.Key).ToList()) idem.Remove(k);
            foreach (var k in recentQuestions.Where(kv => (now - kv.Value.At).TotalMinutes >= cfg.QuestionDedupeMinutes).Select(kv => kv.Key).ToList()) recentQuestions.Remove(k);
            foreach (var d in new[] { sendWin, askWin, pairWin, castWin, supWin })
                foreach (var k in d.Where(kv => kv.Value.Count == 0 || now - kv.Value[^1] > TimeSpan.FromHours(1)).Select(kv => kv.Key).ToList()) d.Remove(k);
        }
        if (cfg.ManagerEnabled) plant.SupervisorPresenceTick();
        foreach (var e in plant.ExpireMessages())
            LogLine("expired", new Ctx { Id = e.Id, Type = e.Type, From = e.From, To = e.To, Kind = e.Type == "question" ? "question" : "direct" });
        // nothing is batched or patrolled while the supervisor is off or the operator's switch is off (4.5)
        if (!cfg.ManagerEnabled || !cfg.Enabled) return new();
        // the patrol (3.9): computed by the gateway on its own timer; a line per patrol sent or dropped, with counts only
        foreach (var line in plant.PatrolTick()) Console.WriteLine(line.ToJsonString());
        // the question table (3.8): moot, escalated, and the batches that left for the supervisor; the lines carry ids, names and counts, never text
        var q = plant.QuestionTick();
        foreach (var line in q.Log) Console.WriteLine(line.ToJsonString());
        return q.Escalations;
    }

    // GET /api/v1/messages?worker=&to=&unread=1&item=&limit=&ring= (operator only): the log with each message's current state, or the ring of refusals
    // and flags. to=NAME keeps the messages addressed to that name (to=operator: the operator's inbox), unread=1 of those the notes to the operator
    // that are not marked read. A note to the operator carries `read`; the answer then also carries `unread`, the count of all of them.
    public JsonObject TrafficLog(string? worker, int? item, int limit, bool refused, string? to = null, bool unreadOnly = false)
    {
        List<TrafficEntry> rows, forOp;
        static bool ToOp(TrafficEntry t) => t.Code == "" && t.Id != "" && t.To.Split(',').Contains("operator");
        lock (leaf)
        {
            var now = DateTime.UtcNow;
            rows = (refused ? ring : log).Where(t => now - t.At <= LogAge).Where(t => worker == null || t.From == worker || t.To.Split(',').Contains(worker)).Where(t => to == null || t.To.Split(',').Contains(to))
                .Where(t => item == null || t.Item == item).OrderByDescending(t => t.At).ToList();
            forOp = log.Where(t => now - t.At <= LogAge && ToOp(t)).ToList();
        }
        var opStates = plant.OperatorStates(forOp.Select(t => t.Id));
        bool Unread(TrafficEntry t) => ToOp(t) && opStates.TryGetValue(t.Id, out var os) && os != "handled";
        if (unreadOnly) rows = rows.Where(Unread).ToList();
        rows = rows.Take(limit).ToList();
        var states = plant.MessageStates(rows.Where(t => t.Id != "").Select(t => t.Id));
        var arr = new JsonArray();
        foreach (var t in rows)
        {
            var o = new JsonObject { ["at"] = t.At.ToString("o"), ["id"] = t.Id == "" ? null : t.Id, ["from"] = t.From, ["fromKind"] = t.FromKind, ["to"] = t.To, ["kind"] = t.Kind, ["type"] = t.Type, ["item"] = t.Item, ["bytes"] = t.Bytes };
            o["state"] = t.Code != "" ? "refused:" + t.Code : states.TryGetValue(t.Id, out var st) ? st : "unknown";
            o["flags"] = new JsonArray(t.Flags.Select(f => (JsonNode)f).ToArray());
            if (t.InReplyTo != "") o["inReplyTo"] = t.InReplyTo;
            if (!refused && ToOp(t)) o["read"] = !Unread(t);
            if (t.Code != "") o["code"] = t.Code; else { o["subject"] = t.Subject; o["text"] = t.Text; }
            arr.Add(o);
        }
        var res = new JsonObject { ["ok"] = true, ["ring"] = refused ? "refused" : "traffic", ["count"] = arr.Count };
        if (!refused && (to == "operator" || worker == "operator")) res["unread"] = forOp.Count(Unread);
        res["messages"] = arr; res["exit"] = 0;
        return res;
    }

    // POST /api/v1/messages/read { "ids": [...] } or { "all": true } (operator only): marks notes addressed to the operator read, so they leave the
    // unread list and the dashboard's count; their senders then see the state handled. Idempotent.
    public MsgResult MarkRead(string bodyText)
    {
        var c = new Ctx { From = "operator", FromKind = "operator", Type = "read", To = "operator", Bytes = bodyText.Length };
        JsonObject body;
        try { body = ParseObject(bodyText); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException or ArgumentException or InvalidOperationException)
        { return Refused(c, "usage", "the body is { \"ids\": [...] } or { \"all\": true }"); }
        foreach (var kv in body) if (kv.Key is not ("ids" or "all")) return Refused(c, "usage", $"unknown field '{kv.Key}'");
        var all = body["all"] is JsonValue av && av.TryGetValue<bool>(out var ab) && ab; var hasIds = body.ContainsKey("ids") && body["ids"] is not null;
        if (all == hasIds) return Refused(c, "usage", "marking read needs exactly one of ids and all: true");
        List<string>? ids = null;
        if (hasIds)
        {
            if (body["ids"] is not JsonArray arr || arr.Count == 0 || arr.Count > 100) return Refused(c, "usage", "ids is a list of 1 to 100 message ids");
            ids = new();
            foreach (var n in arr)
            {
                if (n is not JsonValue v || !v.TryGetValue<string>(out var s) || !IdRx.IsMatch(s)) return Refused(c, "usage", "ids holds message ids (m-<epoch>-<number>)");
                ids.Add(s);
            }
        }
        var (marked, unknown) = plant.MarkOperatorRead(ids);
        return new(200, new JsonObject { ["ok"] = true, ["read"] = marked, ["unknown"] = unknown, ["epoch"] = plant.Epoch, ["exit"] = 0 });
    }

    // ---- POST /api/v1/messages ------------------------------------------------------------------------------------------------------------
    // The sender is the verified credential; a body never names it (4.2). Order: credential, allow-list, shape, size, secret, idempotency, rates,
    // then Plant for everything that depends on live state (modes, recipients, queues, open questions).
    public async Task<MsgResult> SendAsync(Principal who, string bodyText, bool tooLarge)
    {
        var c = new Ctx { Bytes = Encoding.UTF8.GetByteCount(bodyText) };
        switch (who.Kind)
        {
            // the admin token is the person: "operator". The operator SESSION (admitted by Program.cs with its name) is never the person: its own kind and name
            case "admin": if (who.Name != "") { c.From = who.Name; c.FromKind = OpSession; } else { c.From = "operator"; c.FromKind = "operator"; } break;
            case "worker": c.From = who.Name; c.FromKind = "worker"; break;
            case "manager": c.From = who.Name; c.FromKind = "supervisor"; break;
            case "item" when who.Role is "owner" or "inspector": c.From = who.Name; c.FromKind = "worker"; break;
            case "item": c.From = who.Name; c.FromKind = "worker"; return Refused(c, "role-cannot-send", $"an item token of role '{who.Role}' cannot send: pull request code and unknown roles have no messaging identity (worker-messaging.md 4.3)");
            default: return Refused(c, "forbidden", "this credential cannot send messages");
        }
        if (c.FromKind == "worker" && !(cfg.WorkerAllowed(c.From) || (cfg.ManagerEnabled && cfg.AskerAllowed(c.From))))
            return Refused(c, "not-allowed", "this name is not in messaging.allowedWorkers");
        if (tooLarge) return Refused(c, "too-large", $"the request body is over {cfg.MaxBodyBytes / 1024} KB");

        JsonObject body;
        try { body = ParseObject(bodyText); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException or ArgumentException or InvalidOperationException)
        { return Refused(c, "usage", "the body is a JSON object with type, to, text and the fields of that type"); }
        foreach (var kv in body)
            if (kv.Key.Equals("from", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("sender", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("holder", StringComparison.OrdinalIgnoreCase)
                || kv.Key.Equals("fromKind", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("role", StringComparison.OrdinalIgnoreCase))
                return Refused(c, "forged-sender", "the sender comes from the credential; a body never names it");

        // field readers: a field that is present must have its type
        string? Str(string k, out bool bad) { bad = false; if (!body.ContainsKey(k) || body[k] is null) return null; if (body[k] is JsonValue v && v.TryGetValue<string>(out var s)) return s; bad = true; return null; }
        string type = "note";
        if (body.ContainsKey("type")) { var t = Str("type", out var bt); if (bt || t == null) return Refused(c, "usage", "type is a string"); type = t; }
        if (type is not ("note" or "question" or "answer" or "directive" or "announcement")) return Refused(c, "usage", "type is note or question here; answer, directive and announcement belong to the supervisor");
        c.Type = type;

        var supModel = "";
        if (type is "answer" or "directive" or "announcement")
        {
            if (who.Kind != "manager") return Refused(c, "not-supervisor", $"only the supervisor credential sends {type}");
            var (activeName, activeModel) = plant.ActiveSupervisor();
            if (activeName != who.Name) return Refused(c, "not-supervisor", "this credential is not the active supervisor: register with subscribe --own --supervisor first");
            supModel = activeModel;
            // every answer, directive and announcement is a step (3.9): directives stop at the step budget, answers run on to the hard limit
            if (StepRefusal(c, type == "answer") is { } noStep) return noStep;
            if (type == "answer") return Answer(c, body, supModel);
            c.Kind = "direct";
        }
        else if (type == "question")
        {
            if (who.Kind == "admin") return Refused(c, "forbidden", "the operator answers questions, it does not ask them");
            if (who.Kind == "manager") return Refused(c, "role-cannot-send", "the supervisor does not ask questions");
            if (!cfg.ManagerEnabled) return Refused(c, "manager-disabled", "the supervisor is not enabled on this gateway (manager.enabled)");
            if (!cfg.AskerAllowed(c.From)) return Refused(c, "not-allowed", "this name is not in manager.allowedAskers");
            c.Kind = "question"; c.To = "supervisor";
        }
        else
        {
            if (who.Kind is "worker" or "item" && !cfg.WorkerAllowed(c.From)) return Refused(c, "not-allowed", "this name is not in messaging.allowedWorkers");
            c.Kind = "direct";
            // the supervisor's note to the operator is a step as well (3.9), one that runs on to the hard limit
            // and only the active supervisor's: another supervisor name's credential is refused before anything is counted
            if (who.Kind == "manager" && plant.ActiveSupervisor().Name != who.Name) return Refused(c, "not-supervisor", "this credential is not the active supervisor: register with subscribe --own --supervisor first");
            if (who.Kind == "manager" && StepRefusal(c, true) is { } noStep) return noStep;
        }

        var cast = type is "directive" or "announcement";
        var allowed = type == "question" ? QuestionFields : cast ? DirectiveFields : NoteFields;
        foreach (var kv in body)
        {
            if (allowed.Contains(kv.Key)) continue;
            var known = NoteFields.Contains(kv.Key) || QuestionFields.Contains(kv.Key) || OtherFields.Contains(kv.Key);
            return Refused(c, "usage", known ? $"the field '{kv.Key}' is not used by type {type}" : $"unknown field '{kv.Key}': a message carries text, subject and the short fields only");
        }

        var text = Str("text", out var badText);
        if (badText) return Refused(c, "usage", "text is a string");
        if (string.IsNullOrWhiteSpace(text)) return Refused(c, "usage", "text is required");
        if (text.Contains('\0')) return Refused(c, "usage", "text is plain text: a NUL character is not text");
        c.Bytes = Encoding.UTF8.GetByteCount(text);
        var subject = Str("subject", out var badSubject); if (badSubject) return Refused(c, "usage", "subject is a string");
        var context = Str("context", out var badCtx); if (badCtx) return Refused(c, "usage", "context is a string");
        var inReplyTo = Str("inReplyTo", out var badRe); if (badRe) return Refused(c, "usage", "inReplyTo is a string");
        var clientId = Str("clientId", out var badCid); if (badCid) return Refused(c, "usage", "clientId is a string");
        foreach (var s in new[] { subject, context }) if (s != null && s.Contains('\0')) return Refused(c, "usage", "subject and context are plain text");
        if (inReplyTo != null && !IdRx.IsMatch(inReplyTo)) return Refused(c, "usage", "inReplyTo is a message id (m-<epoch>-<number>)");
        if (clientId != null && !ClientIdRx.IsMatch(clientId)) return Refused(c, "usage", "clientId is 1 to 64 letters, digits, - and _");

        int? item = null;
        if (body.ContainsKey("item") && body["item"] is not null)
        {
            if (body["item"] is JsonValue iv && iv.TryGetValue<int>(out var iN) && iN >= 1) item = iN;
            else return Refused(c, "usage", "item is a work item number");
        }
        if (who.Kind == "item")
        {
            if (item != null && item != who.Item) { c.Item = item; return Refused(c, "forbidden", $"this token is for item #{who.Item} only"); }
            item = who.Item;
        }
        c.Item = item;

        // the target of a note: a worker name, the operator, every peer ("*") or the thread of one item
        string? to = null; var broadcast = false; int? thread = null;
        if (type == "note")
        {
            var hasTo = body.ContainsKey("to") && body["to"] is not null; var hasThread = body.ContainsKey("thread") && body["thread"] is not null;
            if (hasTo == hasThread) return Refused(c, "usage", "a note needs exactly one of to and thread");
            if (hasThread)
            {
                var th = Str("thread", out var badTh); if (badTh || th == null || !ThreadRx.IsMatch(th)) return Refused(c, "usage", "thread is item-<number>");
                var tn = int.Parse(th[5..], CultureInfo.InvariantCulture);
                if (tn < 1) return Refused(c, "usage", "thread is item-<number>");
                c.To = th; c.Kind = "thread";
                if (who.Kind == "manager") return Refused(c, "role-cannot-send", "the supervisor's only note target is the operator");
                if (who.Kind == "item" && who.Role == "inspector") return Refused(c, "role-cannot-send", "an inspector session may write only to the operator (worker-messaging.md 4.4)");
                if (who.Kind == "item" && tn != who.Item) return Refused(c, "forbidden", $"this token is for item #{who.Item} only");
                if (item != null && item != tn) return Refused(c, "usage", "item and thread name the same work item");
                thread = tn; item = tn; c.Item = tn;
            }
            else
            {
                to = Str("to", out var badTo); if (badTo || to == null) return Refused(c, "usage", "to is a session name, * or operator");
                if (to == "*")
                {
                    c.To = "*"; c.Kind = "broadcast"; broadcast = true; to = null;
                    if (who.Kind == "manager") return Refused(c, "role-cannot-send", "the supervisor's only note target is the operator");
                    if (who.Kind == "item" && who.Role == "inspector") return Refused(c, "role-cannot-send", "an inspector session may write only to the operator (worker-messaging.md 4.4)");
                    if (c.FromKind == "worker" && !cfg.AllowBroadcast) return Refused(c, "forbidden", "broadcast is switched off on this gateway (messaging.allowBroadcast)");
                    if (Runes(text) > cfg.MaxBroadcastChars) return Refused(c, "too-large", $"a broadcast is {cfg.MaxBroadcastChars} characters at most");
                }
                else
                {
                    if (to.Equals("operator", StringComparison.OrdinalIgnoreCase)) to = "operator";
                    else if (!Auth.ValidName(to)) return Refused(c, "usage", "to is a session name of letters, digits, - and _ (40 at most)");
                    c.To = to;
                    if (to == c.From) return Refused(c, "usage", "to names another session");
                    // a supervisor name takes a note from the operator only (3.4): for every other sender it stays a name that receives nothing
                    var operatorToSupervisor = IsOp(c) && cfg.ManagerEnabled && cfg.ManagerNames.Contains(to);
                    if (to != "operator" && cfg.Reserved.Contains(to) && !operatorToSupervisor) return Refused(c, "no-such-peer", "no session of that name receives messages");
                    if (IsOp(c) && to == "operator") return Refused(c, "usage", "the operator does not write to itself");
                    if (!IsOp(c) && to != "operator" && who.Kind == "manager") return Refused(c, "role-cannot-send", "the supervisor's only note target is the operator");
                    if (who.Kind == "item" && who.Role == "inspector" && to != "operator") return Refused(c, "role-cannot-send", "an inspector session may write only to the operator (worker-messaging.md 4.4)");
                }
            }
        }

        else if (cast)
        {   // a directive or an announcement: one worker, or every worker session once ("*")
            to = Str("to", out var badTo); if (badTo || to == null) return Refused(c, "usage", $"a {type} needs to: a session name or *");
            if (to == "*") { c.To = "*"; c.Kind = "broadcast"; broadcast = true; to = null; }
            else
            {
                if (!Auth.ValidName(to)) return Refused(c, "usage", "to is a session name of letters, digits, - and _ (40 at most), or *");
                c.To = to;
                if (cfg.Reserved.Contains(to)) return Refused(c, "no-such-peer", "no session of that name receives messages");
            }
            if ((type == "announcement" || broadcast) && Runes(text) > cfg.MaxBroadcastChars) return Refused(c, "too-large", $"an announcement, or a directive to all, is {cfg.MaxBroadcastChars} characters at most");
        }

        // sizes (3.7): characters and bytes of the text, the short fields in characters
        if (Runes(text) > cfg.MaxTextChars || c.Bytes > cfg.MaxTextBytes) return Refused(c, "too-large", $"text is {cfg.MaxTextChars} characters ({cfg.MaxTextBytes} bytes) at most");
        if (subject != null && Runes(subject) > cfg.MaxSubjectChars) return Refused(c, "too-large", $"subject is {cfg.MaxSubjectChars} characters at most");
        if (context != null && Runes(context) > cfg.MaxContextChars) return Refused(c, "too-large", $"context is {cfg.MaxContextChars} characters at most");

        // the secret check (5.4): refusal, never redaction; nothing of the text is stored or logged
        foreach (var (name, val) in new[] { ("text", text), ("subject", subject), ("context", context) })
            if (val != null && LooksSecret(val)) return Refused(c, "secret-in-message", $"the {name} looks like a credential or token; messages never carry secrets (worker-messaging.md 5.4)");
        var flags = new List<string>();
        if (AiDirected(text) || (subject != null && AiDirected(subject)) || (context != null && AiDirected(context))) flags.Add("ai-directed-text");

        // idempotency (3.3): a retry with the same (sender, clientId) within 10 minutes returns the first answer and delivers nothing again
        Idem? mine = null;
        if (clientId != null)
        {
            var key = c.From + "\n" + clientId; Idem? other = null;
            lock (leaf)
            {
                if (idem.TryGetValue(key, out other) && DateTime.UtcNow - other.At > IdemAge) { idem.Remove(key); other = null; }
                if (other == null) idem[key] = mine = new Idem { At = DateTime.UtcNow };
            }
            if (other != null)
            {
                var first = await Task.WhenAny(other.Done.Task, Task.Delay(TimeSpan.FromSeconds(10)));
                if (first == other.Done.Task) { var r = other.Done.Task.Result; if (r.Body["ok"]?.GetValue<bool>() == true) { var copy = (JsonObject)r.Body.DeepClone(); copy["duplicate"] = true; return new(r.Status, copy); } return r; }
                return Refused(c, "rate-limited", "the first request with this clientId is still being processed", 2);
            }
        }
        MsgResult Finish(MsgResult r)
        {
            if (mine != null)
            {
                if (r.Body["ok"]?.GetValue<bool>() != true) lock (leaf) idem.Remove(c.From + "\n" + clientId);
                mine.Done.TrySetResult(r);
            }
            return r;
        }

        // from here on the claim on the clientId is released whatever happens, so that an exception cannot leave a retry waiting on it
        try
        {
        // issue 105: the same question text about the same item from the same name within questionDedupeMinutes is that question again. It is not
        // relayed to the supervisor a second time and spends no budget: the answer is the first question's state (with its answer, once there is one)
        string? qKey = null;
        if (type == "question" && item != null && cfg.QuestionDedupeMinutes > 0)
        {
            qKey = c.From + "\n" + item + "\n" + Regex.Replace(text.Trim(), @"\s+", " ").ToLowerInvariant();
            (string Id, DateTime At) prev; bool hit;
            lock (leaf) hit = recentQuestions.TryGetValue(qKey, out prev) && (DateTime.UtcNow - prev.At).TotalMinutes < cfg.QuestionDedupeMinutes;
            // only while that question is open: one that was answered, expired or became moot is asked anew
            if (hit && plant.MessageStatus(prev.Id, c.From) is { State: "open" } snap)
            {
                var dup = StatusBody(snap); dup.Remove("answer"); dup["kind"] = "question"; dup["duplicate"] = true; dup["duplicateOf"] = prev.Id;
                dup["reason"] = $"the same question about item #{item} was asked at {prev.At:o} and is still open: it was not relayed again, this is that question";
                lock (leaf) questionsDeduped++;
                // the launcher watchdog still counts the repeat (a session that asks one thing again and again is stuck)
                plant.NoteDuplicateQuestion(c.From, prev.Id);
                c.Id = prev.Id; LogLine("deduped", c);
                return Finish(new(202, dup));
            }
        }
        // rate limits (3.7); a peer note between two workers also counts in the pair's window
        var pairOther = c.FromKind == "worker" && to != null && to != "operator" ? to : null;
        var (rcode, retry, res) = Reserve(c, pairOther, type == "question", broadcast && c.FromKind == "worker", cast);
        if (rcode != null) return Finish(Refused(c, rcode, rcode switch { "pair-limited" => "too many messages between these two sessions in 10 minutes; reply only when it adds information", "ask-limited" => "too many questions in an hour", _ => cast ? "too many directives and announcements in 10 minutes" : "too many messages in a minute" }, retry));

        // what depends on live state is decided inside Plant, under its one lock
        var evt = new JsonObject
        {
            ["provider"] = "peer", ["relay"] = "gateway", ["event"] = "message.received",
            ["type"] = IsOp(c) ? NoteType(c) : type, ["from"] = c.From, ["fromKind"] = c.FromKind, ["kind"] = c.Kind,
            ["thread"] = thread != null ? "item-" + thread : null, ["item"] = item, ["inReplyTo"] = inReplyTo, ["subject"] = subject ?? "", ["text"] = text, ["sentAt"] = DateTime.UtcNow.ToString("o"),
            ["flags"] = new JsonArray(flags.Select(f => (JsonNode)f).ToArray())
        };
        // the model the supervisor declared (declared, never verified), so a worker can weigh its text (3.8, 4.7)
        if (cast && supModel != "") evt["fromModel"] = supModel;
        var spec = new SendSpec
        {
            From = c.From, FromKind = c.FromKind, Type = IsOp(c) ? NoteType(c) : type, Kind = c.Kind, ClientId = clientId ?? "", Item = item,
            To = type == "question" || to == null ? Array.Empty<string>() : new[] { to }, Broadcast = broadcast, Thread = thread, Peer = c.FromKind == "worker" && type == "note", Operator = IsOp(c), Question = type == "question", Supervisor = cast, Context = context ?? "", Event = evt
        };
        var o = plant.SendMessage(spec, c.Bytes);
        if (!o.Ok) { Rollback(res); return Finish(Refused(c, o.Code, o.Reason)); }
        c.Id = o.Id;
        if (qKey != null) lock (leaf) recentQuestions[qKey] = (o.Id, DateTime.UtcNow);

        var body2 = new JsonObject { ["ok"] = true, ["id"] = o.Id, ["type"] = spec.Type == "operator-note" ? "note" : type, ["epoch"] = plant.Epoch };
        int status;
        if (type == "question")
        {
            // answered at once, never waiting for the supervisor (3.8): pending, nobody there, or its delivery budget is spent
            var (present, exhausted, budgetRetry) = plant.SupervisorAvailability();
            body2["kind"] = "question"; body2["state"] = "open";
            body2["supervisor"] = !present ? "absent" : exhausted ? "budget-exhausted" : "connected";
            if (!present) { body2["code"] = "no-supervisor"; body2["retryAfterSeconds"] = 300; }
            else if (exhausted) { body2["code"] = "supervisor-budget"; body2["retryAfterSeconds"] = budgetRetry; }
            else { body2["code"] = "pending"; body2["answerSlaSeconds"] = cfg.AnswerSlaSeconds; }
            body2["exit"] = 21; status = 202;
        }
        else
        {
            body2["kind"] = c.Kind;
            body2["recipients"] = new JsonArray(o.Delivered.Select(d => (JsonNode)d.Name).ToArray());
            body2["pushed"] = o.Pushed; body2["queued"] = o.Queued;
            body2["refused"] = new JsonArray(o.Refused.Select(r => (JsonNode)new JsonObject { ["name"] = r.Name, ["code"] = r.Code }).ToArray());
            body2["exit"] = 0; status = 200;
        }
        var traffic = new TrafficEntry { At = DateTime.UtcNow, Id = o.Id, From = c.From, FromKind = c.FromKind, To = broadcast || thread != null ? string.Join(",", o.Delivered.Select(d => d.Name)) : c.To, Kind = c.Kind, Type = spec.Type, Item = item, Bytes = c.Bytes, Subject = subject ?? "", Text = text, Flags = flags.ToArray(), InReplyTo = inReplyTo ?? "" };
        AddLog(traffic);
        if (flags.Count > 0) AddRing(traffic);
        LogLine("sent", c, o.Pushed, o.Queued, flags.ToArray());
        return Finish(new(status, body2));
        }
        catch
        {
            if (mine != null) { lock (leaf) idem.Remove(c.From + "\n" + clientId); mine.Done.TrySetResult(new(500, new JsonObject { ["ok"] = false, ["code"] = "internal-error", ["reason"] = "the gateway could not process this message", ["retryAfterSeconds"] = 5, ["exit"] = 20 })); }
            throw;
        }
    }

    // One step of the supervisor's sliding hour (3.9), or the refusal: 429 step-budget, exit 20, with the seconds until a step is free again.
    MsgResult? StepRefusal(Ctx c, bool essential)
    {
        var (ok, retry) = plant.SupervisorStep(essential);
        return ok ? null : Refused(c, "step-budget", "the supervisor's step budget of this hour is spent; keep waiting for events and do not work around it (worker-messaging.md 3.9)", retry);
    }

    // POST /api/v1/supervisor/patrol-ack { "seq": N, "note": "..." } (3.9, 6.4): the active supervisor acknowledges patrol N, which mutes its entries at
    // their buckets, and leaves a one-line decision note for the operator's decision log. A step that runs on to the hard limit.
    public MsgResult PatrolAck(Principal who, string bodyText)
    {
        var c = new Ctx { From = who.Name, FromKind = "supervisor", Type = "patrol-ack", To = "gateway", Kind = "direct", Bytes = Encoding.UTF8.GetByteCount(bodyText) };
        JsonObject body;
        try { body = ParseObject(bodyText); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException or ArgumentException or InvalidOperationException)
        { return Refused(c, "usage", "the body is { \"seq\": N, \"note\": \"...\" }"); }
        foreach (var kv in body)
        {
            if (kv.Key.Equals("from", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("sender", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("holder", StringComparison.OrdinalIgnoreCase)
                || kv.Key.Equals("fromKind", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("role", StringComparison.OrdinalIgnoreCase))
                return Refused(c, "forged-sender", "the sender comes from the credential; a body never names it");
            if (kv.Key is not ("seq" or "note")) return Refused(c, "usage", $"unknown field '{kv.Key}'");
        }
        if (body["seq"] is not JsonValue sv || !sv.TryGetValue<long>(out var seq) || seq < 1) return Refused(c, "usage", "seq is the number of a patrol");
        var note = "";
        if (body.ContainsKey("note") && body["note"] is not null)
        {
            if (body["note"] is not JsonValue nv || !nv.TryGetValue<string>(out var ns)) return Refused(c, "usage", "note is a string");
            note = ns.Trim();
        }
        if (note.Contains('\0') || note.Contains('\n') || note.Contains('\r')) return Refused(c, "usage", "note is one line of plain text");
        if (Runes(note) > cfg.MaxNoteChars) return Refused(c, "too-large", $"note is {cfg.MaxNoteChars} characters at most");
        if (LooksSecret(note)) return Refused(c, "secret-in-message", "the note looks like a credential or token; notes never carry secrets (worker-messaging.md 5.4)");
        if (StepRefusal(c, true) is { } noStep) return noStep;
        var (known, already, entries) = plant.AckPatrol(seq, note);
        if (!known) { CountRefusal("no-such-patrol"); return new(404, new JsonObject { ["ok"] = false, ["code"] = "no-such-patrol", ["reason"] = "the gateway knows no patrol with this seq (a restart loses them); drop it", ["exit"] = 12 }); }
        Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["message"] = "patrol-acked", ["from"] = who.Name, ["seq"] = seq, ["entries"] = entries, ["already"] = already }.ToJsonString());
        return new(200, new JsonObject { ["ok"] = true, ["seq"] = seq, ["acknowledged"] = entries, ["already"] = already, ["epoch"] = plant.Epoch, ["exit"] = 0 });
    }

    // ---- answers (3.8): the supervisor's (type answer, one or up to five in one call) and the operator's (POST /questions/{id}/answer) ----------
    sealed record AnswerItem(string InReplyTo, string Text, string Note);

    // One answer's fields, checked as a message's are: text, sizes, the secret catalogue. Returns the refusal code and reason, or the item.
    (AnswerItem? Item, string Code, string Reason) ReadAnswer(JsonObject o, string[] fields)
    {
        foreach (var kv in o) if (!fields.Contains(kv.Key)) return (null, "usage", $"the field '{kv.Key}' is not used by an answer");
        string? S(string k, out bool bad) { bad = false; if (!o.ContainsKey(k) || o[k] is null) return null; if (o[k] is JsonValue v && v.TryGetValue<string>(out var x)) return x; bad = true; return null; }
        var re = S("inReplyTo", out var b1); var text = S("text", out var b2); var note = S("note", out var b3);
        if (b1 || b2 || b3) return (null, "usage", "inReplyTo, text and note are strings");
        if (re == null || !IdRx.IsMatch(re)) return (null, "usage", "inReplyTo is the id of the question (m-<epoch>-<number>)");
        if (string.IsNullOrWhiteSpace(text)) return (null, "usage", "text is required");
        if (text.Contains('\0') || (note != null && note.Contains('\0'))) return (null, "usage", "text and note are plain text");
        if (Runes(text) > cfg.MaxTextChars || Encoding.UTF8.GetByteCount(text) > cfg.MaxTextBytes) return (null, "too-large", $"text is {cfg.MaxTextChars} characters ({cfg.MaxTextBytes} bytes) at most");
        if (note != null && Runes(note) > cfg.MaxNoteChars) return (null, "too-large", $"note is {cfg.MaxNoteChars} characters at most");
        if (LooksSecret(text) || (note != null && LooksSecret(note))) return (null, "secret-in-message", "the text or the note looks like a credential or token; messages never carry secrets (worker-messaging.md 5.4)");
        return (new AnswerItem(re, text, note ?? ""), "", "");
    }

    JsonObject AnswerEvent(string type, string from, string fromKind, string text, string model)
    {
        var flags = new JsonArray(); if (AiDirected(text)) flags.Add("ai-directed-text");
        var e = new JsonObject
        {
            ["provider"] = "peer", ["relay"] = "gateway", ["event"] = "message.received", ["type"] = type, ["from"] = from, ["fromKind"] = fromKind, ["kind"] = "direct",
            ["thread"] = null, ["subject"] = "", ["text"] = text, ["sentAt"] = DateTime.UtcNow.ToString("o"), ["flags"] = flags
        };
        if (model != "") e["fromModel"] = model;
        return e;
    }

    // Records one answer and writes the log: the asker and the item come from the question's record, never from the caller.
    (bool Ok, string Code, string Reason, string AnswerId, string Asker, bool Pushed) Apply(Ctx c, AnswerItem a, string type, string model)
    {
        if (IdRx.Match(a.InReplyTo) is var m && "e-" + m.Groups[1].Value != plant.Epoch) return (false, "no-such-question", "this id belongs to an earlier run of the gateway; questions are kept in memory only (worker-messaging.md 3.6)", "", "", false);
        var evt = AnswerEvent(type, c.From, c.FromKind, a.Text, model);
        var r = plant.AnswerQuestion(a.InReplyTo, evt, a.Note);
        var lc = new Ctx { From = c.From, FromKind = c.FromKind, Type = type, To = r.Asker, Kind = "direct", Id = r.AnswerId, Item = r.Item, Bytes = Encoding.UTF8.GetByteCount(a.Text) };
        if (!r.Ok) { lc.Id = a.InReplyTo; AddRing(new TrafficEntry { At = DateTime.UtcNow, From = c.From, FromKind = c.FromKind, To = r.Asker, Kind = "direct", Type = type, Item = r.Item, Bytes = lc.Bytes, Code = r.Code }); CountRefusal(r.Code); LogLine("refused", lc, code: r.Code); return (false, r.Code, r.Reason, "", r.Asker, false); }
        var flags = evt["flags"]!.AsArray().Select(f => f!.ToString()).ToArray();
        var t = new TrafficEntry { At = DateTime.UtcNow, Id = r.AnswerId, From = c.From, FromKind = c.FromKind, To = r.Asker, Kind = "direct", Type = type, Item = r.Item, Bytes = lc.Bytes, Text = a.Text, Flags = flags };
        AddLog(t); if (flags.Length > 0) AddRing(t);
        LogLine("answered", lc);
        return (true, "", "", r.AnswerId, r.Asker, r.Pushed);
    }

    MsgResult Answer(Ctx c, JsonObject body, string model)
    {
        c.Kind = "direct";
        foreach (var kv in body) if (!AnswerFields.Contains(kv.Key)) return Refused(c, "usage", NoteFields.Contains(kv.Key) || QuestionFields.Contains(kv.Key) ? $"the field '{kv.Key}' is not used by type answer" : $"unknown field '{kv.Key}': an answer carries inReplyTo, text and note, or answers");
        var items = new List<AnswerItem>(); var batch = body.ContainsKey("answers") && body["answers"] is not null;
        if (batch)
        {
            if (body["answers"] is not JsonArray arr || arr.Count == 0 || arr.Count > cfg.BatchMax) return Refused(c, "usage", $"answers is a list of 1 to {cfg.BatchMax} answers");
            if (body.ContainsKey("inReplyTo") || body.ContainsKey("text") || body.ContainsKey("note")) return Refused(c, "usage", "an answer carries either answers or inReplyTo, text and note");
            foreach (var n in arr)
            {
                if (n is not JsonObject ao) return Refused(c, "usage", "each answer is an object with inReplyTo, text and note");
                var (it, code, reason) = ReadAnswer(ao, new[] { "inReplyTo", "text", "note" });
                if (it == null) return Refused(c, code, reason);
                if (items.Any(x => x.InReplyTo == it.InReplyTo)) return Refused(c, "usage", "answers names each question once");
                items.Add(it);
            }
        }
        else
        {
            var (it, code, reason) = ReadAnswer(body, AnswerFields);
            if (it == null) return Refused(c, code, reason);
            items.Add(it);
        }
        if (!batch)
        {
            var r = Apply(c, items[0], "answer", model);
            if (!r.Ok) return new(Map(r.Code).Status, new JsonObject { ["ok"] = false, ["code"] = r.Code, ["reason"] = r.Reason, ["inReplyTo"] = items[0].InReplyTo, ["exit"] = Map(r.Code).Exit });
            return new(200, new JsonObject { ["ok"] = true, ["id"] = r.AnswerId, ["type"] = "answer", ["inReplyTo"] = items[0].InReplyTo, ["epoch"] = plant.Epoch, ["kind"] = "direct",
                ["recipients"] = new JsonArray(r.Asker), ["pushed"] = r.Pushed ? 1 : 0, ["queued"] = r.Pushed ? 0 : 1, ["refused"] = new JsonArray(), ["exit"] = 0 });
        }
        // several answers in one call are partial like a fan-out: each is recorded or refused by itself, and the call fails only when none stood
        var rows = new JsonArray(); var done = 0; (string Code, string Reason) first = ("", "");
        foreach (var it in items)
        {
            var r = Apply(c, it, "answer", model);
            if (r.Ok) { done++; rows.Add(new JsonObject { ["inReplyTo"] = it.InReplyTo, ["ok"] = true, ["id"] = r.AnswerId }); }
            else { if (first.Code == "") first = (r.Code, r.Reason); rows.Add(new JsonObject { ["inReplyTo"] = it.InReplyTo, ["ok"] = false, ["code"] = r.Code, ["reason"] = r.Reason }); }
        }
        if (done == 0) return new(Map(first.Code).Status, new JsonObject { ["ok"] = false, ["code"] = first.Code, ["reason"] = first.Reason, ["answers"] = rows, ["exit"] = Map(first.Code).Exit });
        return new(200, new JsonObject { ["ok"] = true, ["type"] = "answer", ["epoch"] = plant.Epoch, ["answered"] = done, ["answers"] = rows, ["exit"] = 0 });
    }

    // POST /api/v1/questions/{id}/answer (operator only): delivered to the asker as an operator note in reply to the question; the first answer wins.
    public MsgResult OperatorAnswer(string id, string bodyText, string session = "")
    {
        var c = new Ctx { From = session != "" ? session : "operator", FromKind = session != "" ? OpSession : "operator", Kind = "direct", Bytes = Encoding.UTF8.GetByteCount(bodyText) };
        c.Type = NoteType(c);
        JsonObject body;
        try { body = ParseObject(bodyText); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException or ArgumentException or InvalidOperationException)
        { return Refused(c, "usage", "the body is { \"text\": \"...\", \"note\": \"...\" }"); }
        if (!IdRx.IsMatch(id)) return Refused(c, "no-such-question", "no question with this id");
        body["inReplyTo"] = id;
        var (it, code, reason) = ReadAnswer(body, new[] { "inReplyTo", "text", "note" });
        if (it == null) return Refused(c, code, reason);
        var r = Apply(c, it, NoteType(c), "");
        if (!r.Ok) return new(Map(r.Code).Status, new JsonObject { ["ok"] = false, ["code"] = r.Code, ["reason"] = r.Reason, ["exit"] = Map(r.Code).Exit });
        return new(200, new JsonObject { ["ok"] = true, ["id"] = r.AnswerId, ["inReplyTo"] = id, ["to"] = r.Asker, ["exit"] = 0 });
    }

    // ---- GET /api/v1/messages/{id}?wait=S: the state of one message, for its sender (or the operator) ----------------------------------
    public async Task<MsgResult> StatusAsync(Principal who, string id, double waitSeconds, CancellationToken ct)
    {
        var m = IdRx.Match(id);
        if (!m.Success) return NoMessage(false);
        if ("e-" + m.Groups[1].Value != plant.Epoch) return NoMessage(true);
        var asker = who.Kind == "admin" ? null : who.Name;
        var end = DateTime.UtcNow.AddSeconds(Math.Clamp(waitSeconds, 0, 120));
        while (true)
        {
            Task? sig = asker != null ? plant.MessageSignal(asker) : null;
            var snap = plant.MessageStatus(id, asker);
            if (snap == null) return NoMessage(false);
            var left = end - DateTime.UtcNow;
            if (snap.Type != "question" || snap.State != "open" || left <= TimeSpan.Zero || ct.IsCancellationRequested) return new(200, StatusBody(snap));
            // wakes at once when anything is delivered to the asker (the answer is a message in its inbox), and re-reads at least every 2 s
            var slice = left > TimeSpan.FromSeconds(2) ? TimeSpan.FromSeconds(2) : left;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var tick = Task.Delay(slice, cts.Token);
            await Task.WhenAny(sig ?? tick, tick);
            cts.Cancel();
        }

        MsgResult NoMessage(bool epochChanged)
        {
            var b = new JsonObject { ["ok"] = false, ["code"] = "no-such-message", ["reason"] = epochChanged ? "this id belongs to an earlier run of the gateway; messages are kept in memory only (worker-messaging.md 3.6)" : "no message with this id was sent by this session" };
            if (epochChanged) { b["epochChanged"] = true; }
            b["epoch"] = plant.Epoch; b["exit"] = 12;
            return new(404, b);
        }
    }

    JsonObject StatusBody(MessageSnapshot s)
    {
        var o = new JsonObject { ["ok"] = true, ["id"] = s.Id, ["type"] = s.Type == "operator-note" ? "note" : s.Type, ["kind"] = s.Kind, ["state"] = s.State, ["item"] = s.Item, ["createdAt"] = s.At.ToString("o"), ["epoch"] = plant.Epoch };
        if (s.Type == "question")
        {
            var (present, exhausted, _) = plant.SupervisorAvailability();
            o["supervisor"] = !present ? "absent" : exhausted ? "budget-exhausted" : "connected";
            if (s.State == "open") { o["code"] = !present ? "no-supervisor" : exhausted ? "supervisor-budget" : "pending"; o["late"] = s.Late; o["escalated"] = s.Escalated; }
            if (s.State == "answered" && s.AnswerJson != "") o["answer"] = JsonNode.Parse(s.AnswerJson);
        }
        else o["perRecipient"] = new JsonObject(s.Per.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value)));
        o["exit"] = s.Type == "question" && s.State == "open" ? 21 : 0;
        return o;
    }

    // ---- GET /api/v1/inbox ----------------------------------------------------------------------------------------------------------
    // The caller's undelivered messages above a cursor (a poll never acknowledges), long-polled when timeout is set. include=delivered adds the
    // delivered, unhandled ones; id=M reads one message of this inbox in any state still held.
    public async Task<MsgResult> InboxAsync(string name, long after, string? epoch, double timeoutSeconds, int limit, bool includeDelivered, string? id, CancellationToken ct)
    {
        var changed = epoch != null && epoch != plant.Epoch;
        if (changed) after = 0;
        limit = Math.Clamp(limit, 1, 50);
        if (id != null)
        {
            var one = plant.InboxOne(name, id);
            if (one == null) return new(404, new JsonObject { ["ok"] = false, ["code"] = "no-such-message", ["reason"] = "no message with this id is held in this inbox", ["exit"] = 12 });
            return new(200, new JsonObject { ["ok"] = true, ["epoch"] = plant.Epoch, ["epochChanged"] = changed, ["count"] = 1, ["last"] = one["seq"]?.DeepClone(), ["messages"] = new JsonArray(one), ["exit"] = 0 });
        }
        plant.NotePoll(name);
        var wait = timeoutSeconds > 0;
        var end = DateTime.UtcNow.AddSeconds(Math.Clamp(timeoutSeconds, 0, 60));
        while (true)
        {
            var sig = plant.MessageSignal(name);
            var (msgs, last) = plant.InboxPage(name, after, limit, includeDelivered);
            if (msgs.Count > 0 || !wait || ct.IsCancellationRequested)
                return new(200, new JsonObject { ["ok"] = true, ["epoch"] = plant.Epoch, ["epochChanged"] = changed, ["count"] = msgs.Count, ["last"] = last == 0 ? after : last, ["timeout"] = wait && msgs.Count == 0, ["messages"] = new JsonArray(msgs.ToArray()), ["exit"] = wait && msgs.Count == 0 ? 21 : 0 });
            var left = end - DateTime.UtcNow;
            if (left <= TimeSpan.Zero)
                return new(200, new JsonObject { ["ok"] = true, ["epoch"] = plant.Epoch, ["epochChanged"] = changed, ["count"] = 0, ["last"] = after, ["timeout"] = true, ["messages"] = new JsonArray(), ["exit"] = 21 });
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var tick = Task.Delay(left, cts.Token);
            await Task.WhenAny(sig, tick);
            cts.Cancel();
        }
    }

    // ---- POST /api/v1/messages/ack ----------------------------------------------------------------------------------------------------
    public MsgResult Ack(Principal who, string bodyText)
    {
        var c = new Ctx { From = who.Name, FromKind = who.Kind == "manager" ? "supervisor" : "worker", Type = "ack", Bytes = bodyText.Length };
        JsonObject body;
        try { body = ParseObject(bodyText); }
        catch (Exception e) when (e is System.Text.Json.JsonException or FormatException or ArgumentException or InvalidOperationException)
        { return Refused(c, "usage", "the body is { \"ids\": [...], \"state\": \"delivered\" or \"handled\" } or { \"upTo\": N }"); }
        foreach (var kv in body)
        {
            if (kv.Key.Equals("from", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("sender", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("holder", StringComparison.OrdinalIgnoreCase)
                || kv.Key.Equals("fromKind", StringComparison.OrdinalIgnoreCase) || kv.Key.Equals("role", StringComparison.OrdinalIgnoreCase))
                return Refused(c, "forged-sender", "a session acknowledges only its own inbox; a body never names a session");
            if (kv.Key is not ("ids" or "state" or "upTo")) return Refused(c, "usage", $"unknown field '{kv.Key}'");
        }
        var hasIds = body.ContainsKey("ids") && body["ids"] is not null; var hasUp = body.ContainsKey("upTo") && body["upTo"] is not null;
        if (hasIds == hasUp) return Refused(c, "usage", "an acknowledgement needs exactly one of ids and upTo");
        var state = "handled";
        if (body.ContainsKey("state") && body["state"] is not null)
        {
            if (body["state"] is not JsonValue sv || !sv.TryGetValue<string>(out var ss) || ss is not ("delivered" or "handled")) return Refused(c, "usage", "state is delivered or handled");
            state = ss;
        }
        int acked, unknown = 0;
        if (hasIds)
        {
            if (body["ids"] is not JsonArray arr || arr.Count == 0 || arr.Count > 100) return Refused(c, "usage", "ids is a list of 1 to 100 message ids");
            var ids = new List<string>();
            foreach (var n in arr)
            {
                if (n is not JsonValue v || !v.TryGetValue<string>(out var s) || !IdRx.IsMatch(s)) return Refused(c, "usage", "ids holds message ids (m-<epoch>-<number>)");
                ids.Add(s);
            }
            (acked, unknown) = plant.AckMessages(who.Name, ids, 0, state);
        }
        else
        {
            if (state != "handled") return Refused(c, "usage", "upTo marks messages handled");
            if (body["upTo"] is not JsonValue uv || !uv.TryGetValue<long>(out var upTo) || upTo < 0) return Refused(c, "usage", "upTo is a sequence number");
            (acked, unknown) = plant.AckMessages(who.Name, null, upTo, "handled");
        }
        Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["message"] = "acked", ["from"] = who.Name, ["state"] = state, ["count"] = acked, ["unknown"] = unknown }.ToJsonString());
        return new(200, new JsonObject { ["ok"] = true, ["acked"] = acked, ["unknown"] = unknown, ["state"] = state, ["epoch"] = plant.Epoch, ["exit"] = 0 });
    }

    // A refusal of the endpoint itself (credential kind, feature off) is not a message event: no ring entry, no log line.
    public static MsgResult Plain(string code, string reason)
    {
        var (st, ex) = Map(code);
        return new(st, new JsonObject { ["ok"] = false, ["code"] = code, ["reason"] = reason, ["exit"] = ex });
    }

    // A refusal that names a body that was too large for the endpoint (read before the Messenger could see it), counted like any other refusal.
    public MsgResult TooLarge(Principal who, string what)
    {
        var c = new Ctx { From = who.Kind == "admin" ? "operator" : who.Name, FromKind = who.Kind, Type = what };
        return Refused(c, "too-large", $"the request body is over {cfg.MaxBodyBytes / 1024} KB");
    }

    // Admin-only listing and the ring: see TrafficLog(). Filters are parsed by the endpoint.
}
