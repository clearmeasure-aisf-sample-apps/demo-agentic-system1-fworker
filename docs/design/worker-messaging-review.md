# Review of worker-messaging.md (Opus 5.5, 2026-10-11)

Verdict: ready after BLOCKERs 1 to 8 are fixed. Apply every finding below to the design.

Reviewed: the version with the manager cost model (706 lines, sections 3.9 and 5a included), against the current `gateway/` (Program.cs, Plant.cs, Auth.cs, Qc.cs), `plugin/scripts` (factory.ps1, lib/Client.Own.ps1, Client.Subscribe.ps1, Client.Plugin.ps1, Owner.ps1, Journal.ps1, Core.ps1, Models.ps1, Verbs.Item.ps1, Verbs.Sweep.ps1), the skills, `config/instance.json` and `tests/scenarios`.

1. BLOCKER, 3.4 and 3.5 (replay after a gateway restart). The epoch is only on the poll cursor. The SSE `id:` is a bare number. `/events` parses `Last-Event-ID` as a `long` (Program.cs:243). The client keeps `$lastId` for the life of its process, across gateway restarts (Client.Own.ps1:127, 138, 145). `w.Next` starts at 1 again in a new process (Plant.cs:16, 97). So a client that held id 500 reconnects with `Last-Event-ID: 500` and "replay unacknowledged messages with seq > 500" skips every message (and trigger, Plant.cs:70) queued with seq 1 to 500 after the restart. A `manager.questions` batch and the post-restart announcement are exactly those messages. Fix: send `id: <epoch>.<seq>` on every event (messages and triggers). `Register` parses both parts. Another epoch means no cursor: replay every unacknowledged message, and the whole trigger `Buffer`. The client stores the id as an opaque string (it already does). Test: restart, queue 3 messages, reconnect with a stale numeric id, receive all 3.
2. BLOCKER, 3 and step 3 (two locks: lost messages, deadlock). `Messenger` has "its own lock", but delivery needs Plant's `gate`: `w.Next`, `w.Out` (Plant.cs:95-101), and the directory (`ownerOf`, `botOf`, `qcOf`). Step 3 also puts the "replay merge in `Register`", which runs under `gate` (Plant.cs:62-76). Send (Messenger lock, then gate) and Register (gate, then Messenger lock) take the locks in opposite orders, so they can deadlock. If the locks are split instead, a message can be given its seq, then `Register` takes its replay snapshot and completes the old channel (Plant.cs:68-69), then the message lands in the inbox and is `TryWrite`n to the dead channel. It is then neither replayed nor pushed, and it surfaces only on a header-less reconnect or a manual `inbox`. Fix: inboxes, seq allocation and the replay merge live under the one `gate` (Messenger keeps only rate counters and the traffic log). Document the lock order: Messenger never holds its lock while calling Plant. Merge `Buffer` and the inbox by id in the replay. Test: 200 sends racing 20 reconnects lose nothing.
3. BLOCKER, 4.6 (the manager's "read-only" verbs write state). `model-tier` is not read-only. `Verb_model_tier` takes `column` from the body (Models.ps1:17), keeps the ratchet per column (Models.ps1:32), and calls `Save-State` whenever column or tier differ (Models.ps1:33-36). It also takes the item lock, because it is not in `$NoLockVerbs` (factory.ps1:18). A manager calling `model-tier --item N --column X` therefore overwrites `state.model_tier` and resets the "never lower a tier" ratchet of the real column. That is a state change by the manager, against 1 and 5.6. Fix: drop `model-tier` from `ManagerVerbs`. Or have `AuthorizeVerb` strip `column` and set `readonly: true`, which makes `Verb_model_tier` skip `Save-State`. Add a scenario: the state comment is byte-identical after each manager verb.
4. BLOCKER, 4.6 and 6.4 (manager liveness, takeover, flapping). There are several problems.
   - "Silent longer than `takeoverSeconds`" has no meaning. The stream carries no traffic from client to server. The gateway's `: ping` (Program.cs:262-264) goes into the TCP buffer even on a half-open connection. `LastSeen` is written only at `Register` (Plant.cs:67). An idle healthy manager is always "silent", so another allowed name can take it over after 60 s, or a dead manager is never replaced.
   - Same-name replacement plus the client's endless reconnect (Client.Own.ps1:159-166, with the backoff reset to 2 s at line 142) makes two manager processes (an old Monitor after `plugin-sync`, a new one) kick each other every few seconds. Each flap pushes `manager.joined`/`left` to every worker. Each flap also sends a new `baseline` digest, which spends budget (3.9).
   - `subscribe --own --manager` cannot "exit 40 `manager-active`". The loop throws on any non-success status, prints `stream.error`, and retries for ever (Client.Own.ps1:140, 159-166). It never reads the refusal body.

   Fix: the manager posts a heartbeat (`POST /presence`) every 20 s, and takeover is allowed only after `takeoverSeconds` without one. When a stream is replaced, the gateway writes a `stream.replaced` event before it completes the old channel, and the client exits 40 on that event instead of reconnecting. The client exits on 401/403/409 with the body's `exit`. `manager.joined`/`left` are debounced (an absence under 2 min is not "left"). A baseline is sent at most once per 30 min.
5. BLOCKER, 3.7 and 9 #7 (the recipient cap starves answers). "100 unacknowledged; the sender is refused" applies to every sender. Acknowledging is a model step (3.5) that models forget. A single peer at the pair limit (10 per 10 min) adds 60 an hour. Once the cap is reached, the manager's `answer` and directives and the operator's notes are refused `queue-full`. The asker's `--wait` then never returns, and the fallback of 3.8 is the only path left. Fix:
   - Count the cap per sender (for example 20 per sender per recipient).
   - Exempt `answer`, `directive`, `announcement` and `operator-note` from it.
   - Split "delivered" (the client acknowledges automatically once it has printed the line) from "handled" (the model's `ack`). Replay and the cap count only undelivered messages; `inbox` still shows delivered, unhandled messages for 24 h.
6. BLOCKER, 3.8 "what the asker does", 5.1 and 8 (trust laundering through the item). The fallback has the asker write the assumption with `append-body` or `comment`, and post the blocker with `comment`. Comments by the factory login are labelled `author_trust: factory` (Verbs.Item.ps1:34), and the body carries no label at all (Verbs.Item.ps1:36, 42). An answer from a steered manager, or a peer note the worker paraphrases, becomes text the next owner, reviewer and inspector read as trusted specification. The section 8 invariant "no item state differs because of a message" is false by design in Tier 2/3, where a directive is meant to change what a worker does. Fix:
   - Write such text only inside a marked block (`<!-- aisf:assumption source=m-... -->`, fenced, backticks stripped).
   - Have `get-item` label that block `author_trust: derived-from-message`, and keep it out of `inspect-facts`.
   - Restate the invariant at gateway level: no Messenger code path reaches `Runner` or a Plant mutator, and the verb count does not change in the hostile-message scenarios.
7. BLOCKER, 3.9 (no-change suppression does not suppress). A patrol is sent when an attention entry is "new or worse". `idleMinutes` and `ageMinutes` grow and `leaseLeftMinutes` shrinks at every recompute, so a stall that persists is "worse" at every interval. One stuck worker, already nudged, then costs 6 turns an hour. This contradicts the scenario "the following interval, unchanged, is suppressed" (10, `mgr: a stalled worker appears`). The attention rules also flag normal waits:
   - an owner in `wait-event` makes no verb calls for hours, because `/api/v1/wait` is not a verb (Program.cs:210-221);
   - `qc-not-run` and `qc-approval-missing` are expected waits (owner-session SKILL.md step 3), and the design's own example reports `qc-not-run` count 4.

   Fix:
   - Compare on a key of kind, worker, item and severity bucket (stall at 45, 90 and 180 min; lease under 5 min), never on raw minutes.
   - Mute an entry the manager acknowledged (`patrol-ack --seq`) until its bucket changes.
   - Count `/wait` polls and verbs in `LastActivityAt`.
   - Drop "stalled" when the item's last routed event is a known wait (`item.parked`, hold, `qc.*`, waiting for the inspector).
   - Exclude the refusal codes the skills define as waits (`qc-not-run`, `qc-approval-missing`, `held`).
8. BLOCKER, 3.9 content rule and 2.2 (the digest is not "enumerated values only"). `type`, `roles` and `capabilities` are taken raw from the registration query (Program.cs:250-252), with no check and no length limit. Only the client validates `type` (Client.Own.ps1:115). A session can therefore register `type=IGNORE%20PREVIOUS...` and that text goes into the digest's `changed[].type`, into `peers`, and into the dashboard. The `model=` and `effort=` declarations add two more free strings. Fix: the gateway validates `type` against the four known values, `roles` against `owner|inspector|qc`, `capabilities` and `model`/`effort` against `^[a-z0-9._-]{1,60}$` (lists capped at 10), and refuses 400 `usage` otherwise. Test: a registration with hostile `type`/`model` is refused, and no digest field is outside the schema.
9. SHOULD-FIX, 4.6 (`/wait` is not default-deny). `/api/v1/wait` refuses only `worker`, and an `item` principal of another item (Program.cs:214-215). A `manager` principal falls through and can long-poll any item's mailbox. `AuthorizeVerb` does deny a manager, but with the reason "the  role cannot call" (empty role, Auth.cs:104-105), not "the manager role cannot call", which is the text the test expects. Fix: an explicit manager branch in `/wait` (refuse), and `if (p.Kind == "manager") return ManagerVerbs.Contains(verb) ? (body, null) : (null, "the manager role cannot call ...")` before the role switch. Correct the claim in 4.6.
10. SHOULD-FIX, 3.1 and 6 (a muted worker un-mutes itself). `POST /workers/{name}/{action}` admits `who.Kind == "worker" && who.Name == name` (Program.cs:226). Only `capacity` adds an admin guard (Program.cs:227-229). A new `messaging` action in that handler therefore lets a worker set its own mode back to `on`. Fix: admin-only guard, like capacity. Test with the worker's own `w1.`.
11. SHOULD-FIX, 2, 4.2 and 4.6 (reserved names and revocation).
    - Worker tokens are deterministic and cannot be revoked. The credential endpoint (Program.cs:138-141) and `worker-token` (Client.Own.ps1:32-40) mint any valid name today, so a `w1.operator` or `w1.plant-manager` minted earlier stays valid.
    - `ValidName` accepts `Operator` and `PLANT-MANAGER` (Auth.cs:36).

    Fix: enforce the reserved set, case-insensitively, in `Auth.Authenticate` (a `w1.` token for a reserved name is null), at `/events`, at the credential endpoint and in `worker-token`. A leaked `m1.` can only be revoked by rotating `FACTORY_TOKEN_SECRET`, which revokes every worker. Add a generation: `m1.<name>.<gen>.<mac>`, with `manager.tokenGeneration` in config.
12. SHOULD-FIX, 2.2 and 3.9 "derived from" (data Plant does not have). Several fields the design calls existing or derived are missing or wrong in Plant today.
    - "owned (items with column)": `ownerOf` is item to name only (Plant.cs:42). `Assignment.Column` is the column at offer time and goes stale when `Move-OwnerTo` moves the claim (Owner.ps1:9-15).
    - `lastSeen`: written only at `Register` (Plant.cs:13, 67). `Disconnect` does not stamp a time (Plant.cs:79).
    - `ownerOf` is never pruned from the sweep: `Plan` only adds `owners` (Plant.cs:266), while the sweep emits only live claims (Verbs.Sweep.ps1:62) and releases idle holds itself (Verbs.Sweep.ps1:96-98). The digest would report stale owners.
    - "The reason and since-time `Plant.Plan` already computes": the reason is journalled, not stored (Plant.cs:289-290).
    - `LastVerbAt` per worker name hides a stall on item B behind activity on item A.

    Fix: `sync-board` returns per owned item `{holder, column, lease_until, heartbeat}` (Verbs.Sweep.ps1:154), and `Plan` replaces the own-item entries of `ownerOf` from it. Take `lease_until` from verb responses (`accept` and `claim-item` return it: Verbs.Item.ps1:103, 113) instead of computing it. Keep `LastActivityAt` per (name, item). Stamp `LastSeen` on every stream write, poll, verb and `Disconnect`. Store `WaitingSince` and `WaitingWhy` on the assignment. Add `Verbs.Sweep.ps1` to step 5a.
13. SHOULD-FIX, 4.5 (owner mode is required). With `FACTORY_OWNER_MODE` off, `/events?name=` answers `not-owner-mode` (Program.cs:246) and nothing registers, yet the design never says messaging needs owner mode. Fix: the loader refuses `messaging.enabled` or `manager.enabled` without owner mode (like the QC guard, Qc.cs:41-47), and the endpoints answer 403 `not-owner-mode`.
14. SHOULD-FIX, 3.5 (waking long-polls). "The gateway wakes pollers at once" cannot reuse `mailboxSignal`. It is one semaphore for all waiters (Plant.cs:54). One `Release` per `Route` wakes a single waiter (Plant.cs:115), and counts pile up while nobody waits, so later waits spin through them (Plant.cs:126). Fix: a per-recipient async signal (a TaskCompletionSource swapped under `gate`). `/wait?messages=1` waits on both the item signal and the inbox signal. Test: five pollers each woken in under 500 ms.
15. SHOULD-FIX, 4.1, 4.4 and 12 Q3 (independence and per-token rules leak). There are three holes.
    - 4.4 covers direct messages and threads, but a broadcast (`to: "*"`) reaches the inspector of the sender's item.
    - The restrictions on the inspector and qc item tokens are cosmetic. `Start-OwnerWorker` and `Start-QcWorker` export the worker credential as `FACTORY_TOKEN` to the headless inspector and QC processes (Client.Own.ps1:100, 64), so those processes can send as their worker.
    - `Choose` does not exclude the owner from a `bot-job` (Plant.cs:134-146), so owner and inspector can be one name, which makes the rule void.

    Fix: apply independence by name to broadcasts too. Stop exporting `w1.` to headless inspector and QC processes (this extends Q5 to inspectors). Exclude `ownerOf[item]` in `Choose` for bot jobs, or state that the rule does not apply when the names are the same. Say plainly that per-token limits are defence in depth.
16. SHOULD-FIX, 5.4 (the secret patterns are not as described).
    - `Protect-JournalText` covers `[wi]1\.` only, not `m1.` or `q1.` (Journal.ps1:10-11).
    - `config/instance.json:148` keeps a second, different list (`inspector.secretPatterns`).
    - The keyword pattern `(bearer|token|secret|password|api[_-]?key)(\s*[:=]\s*|\s+)[A-Za-z0-9._~+/=-]{12,}` matches ordinary prose such as "token authentication", "password reset-functionality" and "api_key configuration". Used for refusal rather than redaction, it blocks normal discussion of the work-orders app's auth features.

    Fix: one catalogue (`secrets.patterns` in instance.json) used by the gateway in C#, by the client, and by the journal. Add `m1.` and `q1.`. For keyword-plus-value, refuse only with `[:=]` and a quoted or high-entropy value. Test that ordinary sentences pass.
17. SHOULD-FIX, 5.2 (the envelope as the client would build it). The client builds its lines from `@{}` hashtables (Client.Own.ps1:154, and every `@{...} | ConvertTo-Json`). Their key order is not guaranteed, so "`warning` precedes `text`; `text` is last" holds only with `[ordered]`. "Control characters stripped" (category Cc) leaves U+2028/2029, U+0085, the bidi controls U+202A-202E and U+2066-2069, and zero-width characters, all of which can split or disguise a line in a reader. Fix: `[ordered]` dictionaries, a stated strip set, and a test with each of these characters.
18. SHOULD-FIX, 6.2, 6.5 step 1 and 3.2 (poll-only sessions). "`inbox --wait 60` in a loop, which costs no tokens while idle" is false when the model drives the loop: every iteration is a tool call plus its output, so for the manager this is exactly the cost 3.9 tries to avoid. A poll-only manager is also never `present` ("no manager stream open", 3.2), so every ask returns `no-manager`. Fix: the poll loop is a background shell loop appending to a log (the pattern of connect prompt step 7), and its polls count as heartbeat. Define the manager as present when it has a stream or has polled or sent a heartbeat within 90 s.
19. SHOULD-FIX, 3.6, 9 #1 and 12 Q2 (restarts are not rare on Container Apps). On Container Apps, tdd and uat scale to zero, the timers stop while at zero, and every revision change loses memory (docs/deploy/runbook-add-deployable.md:154, 181). The image carries the plugin, so every plugin release restarts the gateway. "Queued up to TTL (24 h)", the escalation timer and the batch window all fail in an environment that scaled to zero overnight. Fix: messaging and the manager require `minReplicas: 1`, and the loader warns when `FACTORY_ENVIRONMENT` is a scale-to-zero environment. State the restart-per-release fact in 3.6. For Q2, see Open questions.
20. SHOULD-FIX, 3.7 and 10 (configuration keys and overrides).
    - The prefix `FACTORY_MANAGER_<KEY>` collides with `FACTORY_MANAGER` (4.5) and `FACTORY_MANAGER_TOKEN` (6.4): the token would be read as config key `token`.
    - The suites use `FACTORY_MESSAGING_TTLSECONDS`, `FACTORY_MANAGER_ESCALATEAFTERSECONDS`, `_PATROLSECONDS`, `_STALLSECONDS` and `_BATCHSECONDS`, but the keys are `ttlHours`, `escalateAfterMinutes`, `patrolMinutes` and so on.
    - The earlier review (#17) already set the convention: durations go under `timing` so that `FACTORY_TIMING_*` applies in both `Get-Cfg` (Core.ps1:30-33) and the gateway (Qc.cs:28).

    Fix: `timing.msgTtlMinutes`, `timing.mgrEscalateMinutes`, `timing.mgrPatrolMinutes`, `timing.mgrStallMinutes`, `timing.mgrBatchSeconds`, `timing.mgrTakeoverSeconds` (fractions allowed). The test-only floor below 5 min is honoured only under the loopback guard. Rename the credential variable `FACTORY_SUPERVISOR_TOKEN`, or similar.
21. SHOULD-FIX, 3.8 and 8 (the escalation comment can be lost silently). Escalation goes through the `journal` verb in pwsh (Program.cs:50-53). `journal` is not a no-lock verb, so it waits up to 45 s for the item lock and then rejects `item-busy` (Core.ps1:102-108; an owner's `merge` can hold the lock for minutes). The delegate ignores the exit code, so the person-facing signal disappears without trace. At 30 comments the next slot reads "journal full" (Journal.ps1:55-58). Fix: `PlantTicker` retries escalation on exit 20, and the failure is logged to stdout with its `code`. Add `question-escalated` to the extra-slot list next to `qc-ready`/`qc-failed`.
22. SHOULD-FIX, 2.1 against step 2 (the manager inside `workers`). 2.1 says the manager is separate from workers in the registry. Step 2 registers it through `WorkerInfo`/`Register`, which would:
    - apply `capOverride` to it (Plant.cs:65);
    - push it `ownership.restored` for the items its name owns (Plant.cs:72-74);
    - list it in `Status()` (Plant.cs:380) and give it a drain button on the dashboard (Program.cs:459).

    Also, `Register` resets `Draining` on every reconnect (Plant.cs:67), so per-worker messaging modes must be kept by name, like `capOverride` (Plant.cs:82), or they vanish on reconnect. The messaging mode `drain` also clashes with the existing worker drain: the panel shows two "[drain]" buttons. Fix: a separate `ManagerSlot` in Plant, modes keyed by name, and the messaging `drain` renamed `inbound-off`.
23. SHOULD-FIX, 2.2 and 3.1 (`/overview` leaks what 2.2 forbids). The manager no longer receives `plant.Status()` itself, but the digest will be built next to it. `Status()` carries `qcAddress`, `qcProfile` and assignment ids (Plant.cs:380-382), which 2.2 lists as never shown. Fix: a dedicated `DigestSource()` projection with an explicit field list, and a test that it carries no address or id field.
24. SHOULD-FIX, 4.2 against 6.1 (`holder`). 4.2 refuses `holder` in a body (`forged-sender`), but the generic client adds `holder` to every body (factory.ps1:121), and 6.1 says the holder flag "is ignored". Fix: `Client.Messages.ps1` builds its own body without `holder`, and 6.1 says "refused".
25. SHOULD-FIX, 2 against 4.3 (thread membership). 2 says thread recipients include "sessions that already posted there". 4.3 says a worker token cannot use threads of items it does not own, and qc item tokens cannot send at all. Only the owner can ever post, so the "prior poster" rule is dead. The QC worker as a recipient also contradicts Q5's advice that QC names are not in `allowedWorkers`. Fix: members are the owner and the QC worker, if allowed. Drop prior posters.
26. SHOULD-FIX, 3.9 (the budget counts deliveries, not cost). One `manager.questions` batch of 5 means up to 5 × (3 reads + 1 `answer`), plus a `patrol-ack`, plus any subagents. That is about 20 steps on the most expensive model, and the subagents default to the session's own model. Also, `asksPerHour` 6 times 10 workers is 60 asks an hour, about 12 batches, so questions alone use up the 12-turn budget and patrols get none. And "a question that arrives while the manager is mid-turn" needs a gateway definition of mid-turn. Fix:
    - Count manager `/verbs` calls and `answer`/`direct` sends against a second limit (for example 60 an hour).
    - Reserve 2 turns an hour for patrols.
    - Define in-flight as "the last batch has unanswered entries and is under 10 min old".
    - Have the skill run subagents on `model-for --role subagent`.
    - Give `answer` a `--batch-file` that answers several questions in one call.
27. NIT, consistency left by the amendment. 9 #20 says "6 per 10 minutes", while 3.7 and 10 say 6 per hour. 4.6 still claims `/wait` denies by default (#9). 6.2 and 6.5 step 1 still say polling "costs nothing" (#18). Section 0 item 1 and section 1 still promise coordination that the manager can no longer see (see the cost model below).
28. NIT, naming. Every journal comment already starts "🏭 Plant manager:" (Journal.ps1:62), written by the gateway's dispatcher. A session also called "plant manager" makes "has waited N min for the plant manager" ambiguous on the issue. Call the session "supervisor" in names, events and prompts.
29. NIT, files and harness.
    - Step 7 lists `Client.Own.ps1` twice.
    - Step 11 "sync to factory-worker, both trees" is obsolete: there is a single working tree (commit d9f3345).
    - `Restart-Gateway` lives in `tests/scenarios/qc.ps1:105` and uses `Qc-Base`, so move it to lib.ps1.
    - `Assert-NoServerErrors` scans only `gateway.out` and `gateway.err` (lib.ps1:45-50), while a restart writes `gateway-xxxx.out` and `gateway-restarted.err`. The new text check must glob both.
30. NIT, wording and semantics.
    - `delivered` means "written to an open channel" (`TryWrite`, Plant.cs:99), not "received"; call it `pushed`.
    - seq is shared with triggers and with unbuffered pushes, so inbox seqs have gaps; say so.
    - `peer.disabled` (9 #11) has no mechanism; define a `messaging.disabled` push.
    - One sender at 12 a minute overwrites the 1,000-entry traffic log in about 83 min. Keep refusals and flagged messages in their own ring.

## Plant manager cost model

The direction is right. The gateway does the looking, the model only judges, an idle plant costs nothing, and no worker text reaches the digest. These points need work before the model can deliver what 1 promises:
- **Digest content and size.** 4 KB is about 1,000 tokens, which is fine. Ten sessions fit with `ok` dropped. The free-string leak through `type`, `roles`, `caps` and `model` is BLOCKER 8, and the projection must exclude QC addresses and assignment ids (#23). Add a `schemaVersion` and an explicit field list so the content rule can be tested by schema rather than by marker strings only.
- **Stall detection from data the gateway actually has.** Today Plant has `Connected`, `Draining`, assignments with `CreatedAt`, `AckBy` and `AcceptedAt`, `Declined`, `ownerOf`/`botOf`/`qcOf`, `lastTrigger` (text with no time), per-item mailboxes (no timestamps), the QC memory (lease, heartbeat, last touch) and the sweep output (`owners` of live claims, `offers` with reasons, `triggers` including `item.parked`). It does not have:
  - the claim lease or heartbeat (they live in the state comment);
  - the column of an owned item;
  - per-item activity;
  - any time for `lastSeen` beyond registration;
  - the journal, which is on GitHub, so the gateway cannot use it as a source.

  `disconnected-owner`, `waiting`, `refusals`, `parked` and `late-question` are cheap and reliable once #12 is done. `stalled` is reliable only with the sweep's per-item lease and heartbeat, activity per (name, item) that counts `/wait` polls, and suppression of known waits (BLOCKER 7). Without those it is mostly false positives, and each one costs a `get-item` on the strong model.
- **Patrol interval and no-change suppression.** A 10 min interval with a 5 min floor is sound. Suppression must use severity buckets and acknowledgment muting (BLOCKER 7), otherwise a persistent stall costs 6 turns an hour. The baseline must be rate-limited across reconnects (BLOCKER 4). Recomputing every 30 s is cheap (C# over memory). Make sure it never calls `Runner`.
- **Question batching.** The 20 s window is well inside the 120 s answer target, and a 5-question cap bounds the input. A gateway-side definition of "mid-turn" is needed (#26). A replay after the manager restarts can exceed `batchMax`, so say that it splits and that each part counts once. The asker's `--wait 90` is fine.
- **Budget limits.** The hourly and daily caps with an operator grant are sound, and the hard stop matches the owner's cost rule. But a turn here is a delivery: the real cost is the tool steps per delivery, and the gateway can see those as manager verb calls and sends. Cap those too, reserve patrol turns, and show "steps this hour" on the dashboard (#26). The behaviour at exhaustion (questions queue, `manager-budget`, red badge, no push) is right.
- **Does the manager still have what it needs to supervise?** For questions, yes: `get-item`, `pr-checks` and the skills. For patrol, mostly: it sees stalls, disconnections, waits, refusal loops and parks. It has lost the one coordination case the old design gave it (6.5 step 5 before the amendment: two owners touching one file). It sees neither traffic nor files, so `direct` becomes nudges only. Either add a gateway-computed `overlap` attention kind (open PRs whose changed-file sets intersect, refreshed on `pr.synchronize` from `ingest-event`, names and numbers only), or drop that coordination promise from 0 and 1. Its directive to a stalled worker ("report the blocker with ask") also tends to turn into another question. That is fine, but count it.

## Missing failure modes (add to 9)

- A half-open stream (laptop sleep): messages counted `delivered`, never seen, replayed only on reconnect.
- Two client processes with the same worker name flapping (as in #4, but for workers).
- `plugin.updated` with `restart_needed`: the restarted client has an empty seen set, so it reprints unhandled directives and the model may act twice. Persist the seen ids per epoch in the worker directory.
- The asker releases the item (or the idle release fires) before the answer arrives: route the answer to the current owner of the item, or mark it moot.
- An owner change while a question is open, and escalation then journalling on an item the asker no longer owns.
- The gateway restarts between `ask` 202 and the answer, with the asker in `--wait`.
- A broadcast or directive to `"*"` where some recipients are full or `off`: say whether it is all-or-nothing or partial, and what `delivered`/`queued` report.
- Two senders sending the same `clientId`: key idempotency by (sender, clientId).
- The manager's `get-item` calls during a bad hour use GitHub API quota (several calls each), on top of sweep and QC polling.
- Scale-to-zero overnight (#19).
- An ingress cut during a deploy while a long-poll is pending: the client sees a 502/504 body without `exit` and maps it to 20 (factory.ps1:135). Say that the inbox client retries.
- The epoch changes in the middle of a long-poll.

## Test plan gaps (add to 10)

- A stale numeric `Last-Event-ID` after `Restart-Gateway` still delivers the messages queued after the restart (#1).
- Sends racing reconnects lose nothing (#2).
- The state comment is unchanged after manager `get-item`, `pr-checks`, `get-delivery` and `model-tier` (#3).
- An idle healthy manager is not taken over after `takeoverSeconds`; a manager with no heartbeat is. Two same-name manager clients do not flap, and the replaced one exits 40. `subscribe` exits on `manager-active` (#4).
- A manager answer reaches an inbox that is full of peer notes (#5).
- A fallback `comment`/`append-body` is labelled `derived-from-message` by `get-item` (#6).
- A persistent stall is reported once per bucket. An owner in `wait-event` on a hold is not stalled. `qc-not-run` refusals are not attention (#7).
- A hostile `type`, `model`, `roles` or `caps` value is refused at registration (#8).
- `/wait` with an `m1.` token is refused, with the exact refusal text (#9).
- A muted worker cannot un-mute itself (#10).
- Old `w1.operator` and `w1.Plant-Manager` tokens are refused at `Authenticate` (#11).
- The digest owner list follows a sweep idle-release (#12).
- Messaging with owner mode off refuses to load (#13).
- Pollers wake in under 500 ms (#14).
- A broadcast does not reach the inspector of the sender's item (#15).
- Natural sentences about tokens and passwords pass, and `m1.`/`q1.` are refused (#16).
- The envelope's key order is fixed, and U+2028 and bidi characters are stripped (#17).
- A poll-only manager is `present` (#18).
- An escalation retried while the item lock is busy, and an escalation posted when the journal is full (#21).
- The thread scenario (owner plus QC worker) needs the `qc` environment (`allowLoopbackForTests`, a loopback `FACTORY_PUBLIC_URL`, the dotnet capability), not Env `owner` as written.
- `Start-ManagerClient` needs an `m1.` minting helper; `New-WorkerToken` (owner.ps1:6-11) mints only `w1.`.
- A cost scenario with 10 workers asking at the per-worker limit shows that patrols still get their reserved turns (#26).

## Implementation order (11)

- Steps 1 to 6 each "ship with their scenarios", but section 10 drives everything through the real client, and the client verbs arrive only in step 7. Either move a minimal `Client.Messages.ps1` (`send`, `inbox`, `ack`, `ask`) into step 3, or let steps 1 to 6 test over raw HTTP.
- The id format (#1) and the lock design (#2) must be decided in step 2. Step 3's replay merge depends on both.
- Step 1 must also carry the registration validation (#8), the reserved-name check in `Authenticate` (#11), the explicit manager branches (#9) and the `model-tier` fix (#3).
- Step 5a depends on step 2's presence stamps and on a change to `sync-board` that no step lists (`Verbs.Sweep.ps1`, plus `Plan`'s `ownerOf` replacement, #12).
- Step 5's journal work must include the lock retry (#21).
- Step 4's thread scenarios need the qc test environment.
- Step 8's connect prompts live in `DashboardPage`, which step 9 rewrites: merge the prompt changes into step 9, or do step 9 before step 8.
- Step 11's two-tree sync is obsolete.

Estimate: 11 days is optimistic. `Messaging.cs` alone covers about 17 endpoints, inbox and cursor, question table and batching, digest and suppression, two budgets, rate limits and the traffic log; that is likely more C# than `Plant.cs` and `Program.cs` together today (905 lines). With the BLOCKER fixes, plan 14 to 16 days. Steps 1 to 7 plus 5a come to about 11 days rather than 8.5.

## Open questions (12)

1. Delegations: the recommendation (none in v1) is sound. Before (a) drain is delegated, note that `Register` clears `Draining` on every reconnect (Plant.cs:67), so a manager's drain is undone by the worker's next reconnect. Fix that first. Keep `model-tier` out until it is read-only (#3).
2. Persistence: "a restart is rare" is not true on Container Apps (#19). Do not move questions into the state comment; that costs a GitHub write per question. Instead, the client keeps the text of its own open questions in the worker directory and re-asks once, automatically, on `epochChanged`. The gateway needs `minReplicas: 1` whenever the manager is on.
3. Independence: the right question, but the recommendation misses the broadcast hole, the `w1.` exported to headless inspectors, and the owner/inspector same-name case (#15).
4. Patrol, stall and budget defaults: 10 min and 12 per hour are reasonable. 45 min holds only with wait suppression and buckets (BLOCKER 7). The hard stop is right, but split the budget so questions cannot starve patrols, and add the step cap (#26).
5. QC credentials: right, and approve it. Extend the same change to `Start-OwnerWorker` for headless inspector sessions (Client.Own.ps1:100).

Missing questions for the owner:
- (a) May the manager run in scale-to-zero environments (tdd, uat) at all?
- (b) What is the monthly cost ceiling, in money or tokens, behind "12 turns an hour"? The gateway counts deliveries, not tokens.
- (c) Should the gateway compute file-overlap attention (`overlap`) so the manager keeps the coordination role, or is that role dropped?
- (d) Should workers be told which session answered: the operator, or the manager at a given model? It changes how much weight an answer gets.

## Summary

1. Verdict: ready after BLOCKERs 1 to 8 are fixed.
2. Replay breaks after a gateway restart: the SSE id carries no epoch and the client keeps its numeric `Last-Event-ID` (Program.cs:243, Client.Own.ps1:127-145).
3. Splitting locks between `Messenger` and Plant's `gate` deadlocks or loses messages during reconnect (Plant.cs:62-101).
4. `model-tier` writes state and takes `column` from the body, so the manager is not read-only (Models.ps1:17-36).
5. Manager liveness, takeover and same-name replacement are undefined or flap; `subscribe` never exits on 409 (Client.Own.ps1:140-166).
6. The 100-message cap and model-driven ack can block manager answers. Fallback writes launder message text into `author_trust: factory` (Verbs.Item.ps1:34).
7. The cost model is sound in shape, but "new or worse" suppression never suppresses, and `wait-event` and qc waits read as stalls.
8. Registration strings (`type`, `roles`, `caps`, `model`) are unvalidated and reach the digest, breaking its "enumerated values only" rule.
9. 18 SHOULD-FIX items cover auth edge cases, missing Plant data (lease, column, lastSeen, pruning), patterns, the envelope, ACA restarts and config keys. Four NITs cover consistency, naming and the harness.
10. Plan 14 to 16 days rather than 11. Reorder client verbs, sweep output and prompts. Review file: /home/jeffrey/Projects/factory-worker/docs/design/worker-messaging-review.md
