# The AI software plant manager and its workers

Status: decisions of 2026-10-10/11. **Implemented now: local workers** (persistent-local and ephemeral-local). **Designed, not built: cloud workers**
(Cursor cloud, Claude cloud). Sections say which is which.

## 1. Vocabulary

| Term | Meaning |
|---|---|
| Plant manager | The gateway in its role of matching triggers to jobs and jobs to workers, and journaling each decision on the work item. |
| Worker | A registered Claude session able to own work items. It has a name, a type, capabilities, a capacity and a delivery channel. |
| Owner session | The one worker session that owns a work item from first assignment until the item is complete. |
| Bot | A separate session with its own credentials for an independent check: the inspector now; quality-control and release bots later. |
| Job | A unit the plant manager assigns: `own-item` (a work item) or `bot-job` (a bot run on a pull request). |
| Trigger | A normalized event (webhook, sweep decision, CI result, approval, delivery) that concerns an item. |

## 2. The rule

1. A work item is dispatched to **one** owner session, which stays open and owns it to completion.
2. The owner's main thread only orchestrates. **Every prompt and every trigger is handled by subagents** in that session (analyst, implementer, reviewer, and later roles).
3. **Bots that must be independent run in their own session**, with their own identity and credentials. They are never subagents of the owner.
4. Scripts enforce, skills decide. Every gate is a verb that exits nonzero with a machine-readable reason. The session can advance, merge or close an item only through a verb.
5. The board and GitHub are the source of truth. A restarted or compacted session, or a restarted gateway, loses nothing.

"Complete" (decided): **the pull request is merged and master CI is green.** Everything after is deterministic (`settle`: release candidate, Release Queue, production, Done) and needs no session.

## 3. Worker types

| Type | Runs | Gets work by | Capacity | Status |
|---|---|---|---|---|
| persistent-local | The user's running Claude session on their own machine | Directed assignment over its stream | Set by the user, default 1 | **implement now** |
| ephemeral-local | A headless `claude -p` the launcher starts on a machine (tests, unattended) | The launcher spawns one per assignment | 1 | **implement now** |
| claude-cloud | One Claude cloud session per item | The gateway launches it | 1 | designed (section 11) |
| cursor-cloud | One Cursor cloud agent per item | The gateway launches it | 1 | designed (section 11) |

All types share the registry, the assignment protocol, tokens and journaling. Only how a session comes to exist, and how it receives triggers, differs.

## 4. Registry and assignment (local types)

### Registration
`factory.ps1 subscribe --own --name <name> [--capabilities dotnet,git,...] [--capacity N] [--roles owner,inspector]`

- Opens the event stream and announces: name, type, capabilities, capacity, roles, current model. A stable `name` means a restart is the same worker.
- Authenticated with the **worker credential** (one per worker, issued once by `factory.ps1 worker-token --name <name>`, kept in the user's keyring). The credential can register, receive assignments and call `accept`/`my-items`/`wait-event`. It cannot act on an item.
- The gateway keeps the registry in memory. Durable truth is the claim in each item's state comment (`claim.holder` = worker name), so a gateway restart is rebuilt as workers reconnect.

### Choosing a worker
For each job the plant manager takes the workers that: hold the `owner` (or bot) role, have every capability the item needs, have free capacity, and are not draining. A `worker:<name>` label on the item pins it: the item is offered to that worker and to no other. If that worker is not connected, is draining, is at capacity or lets the accept window pass, the item waits (journal `waiting`, the assignment without a worker on the dashboard) and is offered to the same worker again when it can take it. A pinned item comes first: a sweep offers its pinned items before the unpinned ones, and a free slot of a worker that a pinned item waits for is held for that item, so an unpinned item is offered to a worker only when no pinned item waits for it (issue 46). Among candidates the order is: persistent-local, then cloud, then ephemeral-local; ties go to the worker with the fewest owned items. Since 2026-10-15 (issue 98) a pinned item that has waited for its worker (away, at capacity, spent) for `timing.pinFallbackMinutes` (default 30, 0 off) is offered to any eligible worker instead, journalled `pin-fallback`; the pin stays set aside (`plant.pinsSetAside` in the status) while the label names the same worker, and a new label pins it again.

### Directed assignment
`item.assigned` is sent to **one** worker, not broadcast:
```json
{ "event": "item.assigned", "item": 101, "column": "Development", "mode": "first|fix-forward|relaunch|resume",
  "job": "own-item", "assignment": "a-4f2c", "token": "<item+role scoped>", "ackBySeconds": 120 }
```
- The worker confirms with `factory.ps1 accept --item N --assignment a-4f2c` within `ackBySeconds` (120 by default: `timing.assignAckSeconds`, overridden by `FACTORY_TIMING_assignAckSeconds` or `FACTORY_ASSIGN_ACK_SECONDS`; an offer nobody confirms goes to the next worker, a pinned one waits for its worker). `accept` is the claim: it creates the claim ref, writes the claim into the state comment and returns the item-scoped token's details.
- No confirmation in time: the plant manager offers the item to the next candidate and journals it. A worker that accepts late is refused (`assignment-expired`).
- Verbs: `register` (via `subscribe`), `accept`, `my-items` (everything this worker owns, to rebuild a session after compaction or restart), `drain` (stop new assignments, finish owned items), `resume` (a restarted worker takes back what it owned), `wait-event`.

### Ownership lifetime
- The claim is **per item** and spans columns: `complete` moves the column and keeps the claim; the lease is renewed by the session's heartbeat.
- It ends when: the item's pull request is merged (the gateway settles it from there and releases the owner at `item.merged`, so its session ends; issue 107), is parked or held and the idle limit passes, the session releases it, or the lease expires.
- **Idle limit:** an owner waiting on a hold longer than 60 minutes releases ownership (journaled); the next trigger assigns it again and a new owner **resumes** from the item state.
- **Lost session:** the lease expires, the item is offered again with `mode: resume`, and the relaunch budget applies.

## 4a. Host capacity and the build slot (owner decision 2026-10-14)

Code: `gateway/Hosts.cs`; settings `schedule.*` in `config/instance.json`; counts and holders in `/status` (`hosts`).

- A worker declares its host at registration: `subscribe --own --host H` (else `FACTORY_HOST`, else the computer's name, lower case; `host=` on the
  stream). Sessions that name the same host share its limits; a session that names none has no host limit.
- Owned items per host: `schedule.hosts.<host>.owned`, else `schedule.hostOwnedDefault` (0: no host limit). An offer out counts, as for a worker's
  capacity. A worker whose host is at its limit is passed over (waiting code `host-at-capacity`); a pinned item waits for room on its worker's host.
- Private builds at once per host: `schedule.hosts.<host>.builds`, else `schedule.hostBuildsDefault` (1). `factory.ps1 build-slot --item N [--ttl S]`
  (`POST /api/v1/build-slot`, an owner's item token or a worker credential) takes a slot or extends the caller's own; exit 21 `build-slot-busy`
  (HTTP 429) with `retryAfterSeconds` and the holders when the host's slots are held. `--release` gives it back; a slot not given back frees itself
  after its ttl (`schedule.buildSlotTtlSeconds`, 1800; at most `buildSlotMaxTtlSeconds`, 7200). The slots are in memory: a restart frees them all.
  The plant also frees them when their work ends (issue 108): an item's slots when it is taken back, released or completed or its owner is
  dropped; a name's slots when it is revoked, told `session.end`, or disconnected for `schedule.buildSlotDisconnectSeconds` (120).
- A session that registers with effort `low` gets capacity `schedule.lowEffortCapacity` (1), whatever it declared, unless the operator set its
  capacity on the dashboard.

## 5. Tokens and roles

| Credential | Held by | Can do |
|---|---|---|
| Worker credential | A registered worker | Register, receive assignments, `accept`, `my-items`, `drain`, `wait-event` |
| Item token, role `owner` | The owner of one item | `get-item`, `append-body`, `open-pr`, `complete`, `record-review`, `validation-verdict`, `merge`, `claim` renewal, `comment` — **for that item only** |
| Item token, role `inspector` | The inspector bot session for one item | `get-item`, `inspect-facts`, `approve-pr` — for that item only |
| Gateway secrets | The gateway only | The GitHub token, the reviewer and test-person App keys, the Octopus read key |

Revocation: `POST /api/v1/workers/{name}/revoke` (operator token only; the `revoke` button of a session row on the dashboard). Every credential minted so far for that name is refused with 401 on every endpoint: the worker credential, the item tokens issued to it and, for a supervisor name, the supervisor credential. Its open stream ends, an offer it has not answered goes back to the plan, and what it owns is handed on as for any owner that is gone (its claims are no longer renewed). A credential minted afterwards for the same name works. Tokens are stateless, so each name has a generation that every token of it is bound to (0, the original token format, until the first revocation); the generation is kept in GitHub as refs `refs/factory/<instance>/revoked/<name>/<generation>` (the highest counts) and read back when the gateway starts, before any session credential is answered (`GET /ready` says when; until then such a request waits up to 20 s and is then answered 503). The offline `factory.ps1 worker-token` mints the original (generation 0) form only: after a name was revoked, its new credential comes from the dashboard, `POST /api/v1/workers/{name}/credential` or `docs/deploy/gen-connect-prompt.sh`.

An item token is an HMAC of `{item, role, expiry}` made with a gateway secret (the idea of AISF's callback token, with a role added). The gateway refuses a verb when the token's item differs from the call's item or the verb is outside the role. This turns "the author never approves its own work" into a gate.

## 6. Triggers

The plant manager routes every trigger that concerns an item to **that item's owner**, never to a new session. Triggers: checks settled, branch build finished, inspector approved / requested changes / escalated, hold cleared, master green, release candidate found, a deployment finished, a human comment (delivered as untrusted data), an unexpected column change by a person.

Delivery per type: persistent-local receives them on its stream (the same `Monitor` that delivered the assignment); ephemeral-local and cloud sessions call `wait-event --item N [--timeout S]`, an outbound long-poll that costs no tokens while idle. Each owner has its own buffer with `Last-Event-ID` replay, so a dropped connection loses nothing. Triggers are hints; the session re-reads the item before acting.

## 6a. Master moved: the standing back-merge trigger (owner decision 2026-10-13)

Owner's words: "there needs to be a standing rule and standing trigger. workers need to receive the trigger when a PR is merged to the master
branch so that they can backmerge from master into the feature branch to avoid difficult merge conflicts." Code: `gateway/BaseUpdate.cs`,
`plugin/scripts/lib/BaseUpdate.ps1`.

**When a branch is updated: `baseUpdate.mode` (issue 103, 2026-10-15).** The ruleset of the work-orders repository does not require an
up-to-date branch, and every back-merge restarts the pull request's checks, so the default no longer updates a branch on every master move:

| Mode | The owner gets `base.updated` | The gateway updates a branch itself |
|---|---|---|
| `conflict-or-merge` (default) | only when the item's pull request has a merge conflict with master (`reason: "conflict"`, `conflict: true`), once per pull request head, master head and owner, at the first look of `base-watch` (after a sweep, at most every `sweepCheckSeconds`) once GitHub has computed the mergeability (GitHub runs no checks for a conflicting pull request, issue 56; `overlap` is often empty then; a restart of the gateway tells a standing conflict once more) | right before it merges a PASS under `auto`, once per verdict, when the branch is behind (`Verb_merge -Gateway`: update branch, the new head verified and recorded as the verdict's, then `merge-waiting` `branch-updated`; the next sweep merges once its checks are green, and a session's own `merge` call waits meanwhile instead of polling). Off with `baseUpdate.autoUpdateBranch` false |
| `conflict` | as above | never |
| `every-move` | as described below: on every master move, when the branch is behind | after `autoUpdateDelaySeconds`, for a clean branch the owner did not update |

`FACTORY_BASE_UPDATE_MODE` overrides the setting (gateway and rule scripts). In the conflict modes `base-watch` reads each owned pull request once
per pull request head and master head (`mergeable`; `null` until GitHub has computed it, then the next look gets it). `/status` `baseUpdate`
shows `mode`, `conflictsTold` and `conflicting`. The rest of this section describes `every-move`.

**Detection.** (1) The webhook: every `pull_request` delivery with `action: closed`, `merged: true` and `base.ref` the default branch
becomes the event `base.merged` (`ingest-event`, any branch, not only factory branches). The repository webhook already delivers
`pull_request` (`docs/deploy/create-webhook.sh`) and the gateway verifies its HMAC; `push` is not needed and not subscribed. (2) The
fallback: after a sweep, at most every `baseUpdate.sweepCheckSeconds` (60), the verb `base-watch` reads the head of the default branch (one
call) and compares it with the last head the gateway saw. Both feed one debounce: merges within `timing.baseUpdateDebounceSeconds` (20) of
each other (at most three windows in all) give one trigger with the latest head and every merged pull request number. The first look after
a start only records the head.

**The trigger.** For every item the plant has an owner for, `base-watch` reads the state, the item's open pull request (branch
`factory-worker/N-...`), how many commits the branch is behind master (compare API) and, when master moved, the files the new master
commits changed that the item's pull request changes too (`overlap`, at most 20; master's side is bounded at 300 files). No event for an
item whose branch is not behind, whose pull request is the one just merged or is closed, that has no branch, or that is in a state the
gateway owns (a PASS verdict waiting for its merge, a merge being settled). The owner gets:

```json
{"provider":"gateway","event":"base.updated","item":12,"base":"master","sha":"<new head>","prs":[41,42],"pr":37,
 "branch":"factory-worker/12-development","behind":2,"overlap":["src/Core/Model/WorkOrder.cs"],"via":"webhook","at":"..."}
```

It is a plant trigger like `item.assigned`, not a message: it goes to the owner's stream and to the item's mailbox (`wait-event`), with
messaging on or off. Replay: a newer `base.updated` replaces the older one of the same item in the replay buffer and the mailbox, so a
session that reconnects gets the latest master, not a backlog. It does not become the item's "last trigger" for the digest. Journal line
`base-updated` on the item once per trigger (key: the new head); the operator stream gets `plant.event` code `base-updated` with detail
`sent-<n>-behind-<m>`.

**The standing rule** (skill `factory-owner-session`, referenced by `factory-development` and `factory-follow-through`): on `base.updated`,
as soon as the current step allows (never in the middle of a subagent's edit), fetch, `git merge origin/master` into the item branch (merge,
not rebase: an open pull request keeps its history), resolve keeping both changes where they do not contradict, run what the column requires
(none for docs-only), push, comment one line. Ask the supervisor only when the two changes genuinely contradict; never wait for a person.

**The gateway's own back-merge.** When `baseUpdate.autoUpdateBranch` is on (default), `baseUpdate.autoUpdateDelaySeconds` (120) after the
trigger the gateway runs `base-update-branch` for each pull request it told an owner about: only when the pull request is open, its head is
still the one the trigger saw (the owner has not pushed), GitHub reports it mergeable (not `dirty`), it is behind, and no `pr.head_changed`
webhook came in the last `baseUpdate.quietSeconds` (60). The item state is read fresh first: any verdict on record (passed or not), a merge being settled, the item in its validation column, or a QC record for that head means `skip` (moving the head would make a verdict's or a QC run's sha stale); such items get no trigger either. Then `PUT /repos/{o}/{r}/pulls/{n}/update-branch` with `expected_head_sha`
(journal `branch-updated`, operator `plant.event` `branch-updated`). A conflicting pull request is never touched: it stays the owner's job.
The switch can be changed at run time: `POST /api/v1/base-update?autoUpdateBranch=false` (operator token; until the next restart).
GitHub permission: contents write and pull requests write, both in the manifest of the author App (`tools/github-app-setup/serve.ps1`).

**Visibility.** `/api/v1/status` and the dashboard JSON carry `baseUpdate`: `head`, `triggers`, `eventsSent`, `gatewayUpdates`,
`gatewayConflicts`, `workerBackMerges` (an owner that was told and whose branch is up to date at a later look, without the gateway's
update), `itemsBehind` and `behind` per owned item (refreshed by each `base-watch`). The dashboard shows a summary line and, per owned
item in Assignments, how many commits it is behind master.

## 6b. Owner leases kept by the plant (owner decision 2026-10-14)

Code: `gateway/Lease.cs`; settings `schedule.*` in `config/instance.json` (each overridable by `FACTORY_TIMING_<key>`). Counts in `/status` (`lease`).

1. **The client accepts an owner offer itself.** `subscribe --own` answers an `item.assigned` of job `own-item` with `accept` (body `accepted_by: "client"`) on
   a thread of its own, and prints `item.accepted` (`acceptedBy: "client"`, the lease) or `item.accept-failed` with the gateway's code. The plant offers
   only into a free slot, so the client does not count slots itself. The journal line `assigned` says "accepted by its client". If the session calls no
   verb and no `wait` for the item within `schedule.clientStartMinutes` (5; 0 means the lease the accept answered), the item is taken back. A deployed client accepts by itself from this release on unless it is started with `--no-auto-accept` or `FACTORY_AUTO_ACCEPT=0`.
   `--no-auto-accept`, `FACTORY_AUTO_ACCEPT=0` and `--spawn` leave the accept to the session (the Tier 1 suites run with it off).
2. **The lease is renewed by the gateway** (issue 48): after any verb call of the owner for the item, and at every heartbeat (`POST /presence`) of the
   owner while its activity summary names the item as `#N`; at most once per `schedule.leaseRenewMinutes` (5) per item. The renewal is the rule
   script `claim-item --renew` run as the owner.
3. **A quiet owner is asked, then replaced.** An owned item with no verb or `wait` of its owner and an unchanged activity summary for
   `schedule.staleItemMinutes` (15) gets one `item.check` trigger. Any verb for the item (or a new summary) answers it; nothing within
   `schedule.staleConfirmMinutes` (3) and the item is taken back. Not while the item waits for something else: parked, or its last trigger was
   `item.parked`, `qc.requested`, `qc.reset`, `item.merged` or `inspector.escalated`. Watched are the owners the plant saw accept, and the owners a
   sweep listed with a lease; never an owner set by a test seam.
4. **A busy owner is not quiet** (issue 101, 2026-10-15). An owner that waits on a long subagent (a private build, an app run, a functional test)
   calls no verb for many minutes. Its stream client (`plugin/scripts/lib/Progress.ps1`) looks at its own machine and sends the latest work it saw
   per owned item with the heartbeat (`POST /presence` body `progress: [{ item, ageSeconds, source }]`, at most 20; the age by the client's clock,
   so a client whose clock is off still reports what is recent): `marker` (a file `<work>/progress/<N>.txt` a subagent wrote), `work` (any other
   file written in the work directory), `commit` (a worktree's index or HEAD log changed), `files` (a file of the worktree changed; builds write
   `obj/` and `bin/`), `process` (Linux: a build or test process in the worktree that used CPU since the last look). A time in the future is no work.
   A place is the item's when its path or branch names the item number as a token; while the session owns one item, every worktree of its
   checkouts and its whole work directory are. Only items the name owns count. Progress counts for rule 3 like a verb (the quiet spell starts at the
   latest of the last call, the last summary change and the last progress), renews the lease like a summary that names the item (rule 2), and
   progress newer than the start of the quiet spell answers an open `item.check`. **Cap**: progress counts only while the session itself (a verb or
   poll of its own, or a changed summary) was active within `schedule.progressMaxMinutes` (180; 0 is no cap): a machine that stays busy (an orphaned
   browser, a spinning test host) while the session is stuck does not hold the item for ever; past it the `item.check` carries
   `progressCounts: false` and only the session itself answers it. When an `item.check` arrives within the cap (no heartbeat, messaging off) and
   the client saw work on the item within `FACTORY_PROGRESS_RECENT_MINUTES` (10), it answers the check itself with `claim-item --renew`
   (`renewed_by: "client"`: progress, not the session's own verb; the line carries `answeredBy: "client"`, then `item.check-answered`).
   `/status` `lease` shows `progress`, `progressReports` and `checksAnsweredByProgress`. `FACTORY_PROGRESS=0` switches the client's watching off.

Taking back: the plant lets go only after the rule script `expire-claim` (gateway only) succeeded (a failure keeps the owner and is tried again later). It ends the claim's lease and marks it `taken_back` (journal `lease-expired`), so
`claim-item --renew` of the old owner is refused; the old owner gets `item.taken_back`; the plant forgets the owner (journal `reassigned`) and asks
for a sweep, which offers the item again with mode `resume`. That offer goes to another session first when one is connected. Since 2026-10-15
(issue 91) a take-back is session trouble, not a failure of the item: the relaunch after it does not count against `timing.maxRelaunches` (only a
lease that lapsed by itself does). It counts against `timing.maxSessionRelaunches` (default 10) of take-backs in a row instead (a lapse by itself or a finished stage starts the run again); past that the item is
parked `session-relaunch-budget` (with `last_take_back`), a park the sweep lifts once a worker session is free. A Functional Testing round that spends
`maxRelaunches` without a verdict is parked `validation-no-verdict`, not `watchdog-relaunch-budget`.

## 7. Bots (separate sessions)

When a PASS verdict is recorded under the `peer-approved` policy, the plant manager creates a `bot-job` of kind `inspector` and assigns it to a worker registered with the `inspector` role. That session has a clean context, gets an inspector-role item token, runs `inspect-facts`, judges, and submits `approve-pr`. The owner is told the result by a trigger. Quality-control and release bots follow the same shape: a job kind, a role, a token scope, a result trigger. The inspector rules (mandatory escalations computed by script, three verdicts, holds cleared only by a named person's approval of the current head) are unchanged; see `plugin/scripts/lib/Verbs.Inspect.ps1`.

## 8. The journal

The plant manager writes a comment on the work item at each decision, as AISF does for `matched` and `Agent session created`, but with every decision covered. Prefix `🏭 Plant manager:`; verb outcomes keep `🤖 factory-worker:`.

| # | Event | Posted when |
|---|---|---|
| 1 | matched | A trigger (webhook or sweep) is matched to a job; names the trigger (event and delivery id) |
| 2 | offered | The job is sent to a chosen worker (or, for a cloud type, a launch is requested) |
| 3 | assigned | The worker accepted: worker name, type, mode, attempt, model and effort, lease; a **link** for cloud types |
| 4 | routed | A trigger was delivered to the owner (one line, only for state changes people care about) |
| 5 | reassigned | The lease expired, the worker declined or did not confirm, or ownership was released and resumed |
| 6 | tier raised | The model ladder climbed, with the reason |
| 7 | waiting | No worker qualifies (none subscribed, no capability, capacity full, merge queue full); at most once per column per 30 minutes after a 5-minute delay |
| 8 | skipped | A rule excludes the item (ambiguous owner, demo exclusion, not an AI column) |

Order: the lines of one item are written one after the other, in the order the decisions were made (`matched`, then `waiting` if no worker can take it yet, then `offered`, then `assigned`); `matched` is written once per job, also for an item that first waits. The offer itself never waits for its journal line; an acceptance waits for the lines before it, for a bounded time.

Rules: hidden machine marker on every comment (`<!-- plant event=assigned key=… -->`) and a journal ledger in the state comment, so redelivered webhooks and repeated sweeps never duplicate; best-effort with one retry and never blocks a dispatch; redacts token-like strings; at most ~1,500 characters; never includes item bodies or raw payloads; a per-item cap of 30 comments, then one final "journal full" note; no `@mention`. Worker names and model/effort are shown; machine names and user names are not.

Folding (issue 93): `matched`, `waiting` and `reassigned` repeat while an item waits for a worker (23 items filled their 30 comments with them). A repeat of one of these kinds edits the comment its kind last posted instead of posting a new one, as long as only lines of these kinds or `offered` came after that comment: the comment shows the latest line, how many times and from when to when, and the latest 5 lines with their times; its marker stays the one of the first line (`fold=N` is added), so a reader of the markers (the metrics) sees one line of the kind at the time it first happened. Any other line (`assigned`, `released`, `lease-expired`, `unparked`, a QC line...) ends the folds, so the next `matched` after it is a new comment in its place. Only a new comment counts against the cap. The state keeps `journal.kinds.<event>` (count, first, last) for every kind and `journal.fold.<event>` (the comment, its count, the latest lines) for the open folds. A `waiting` line is written at most once per `timing.journalWaitingMinutes` (30) per item.

## 9. Model selection

- A machine's `models.json` maps ladder rungs to models; the gateway decides when to climb (`model-tier`: relaunches, repeated review findings, demotions, fix-forward rounds, refused gate calls; never lowered within a column). Default: haiku 5.5 `xhigh` → sonnet 5.5 `medium` → opus 5.5 `medium`.
- `profiles.testing` (`claude-haiku-5-5`, `low`) is pinned and never climbs; items labelled `factory test`, or `FACTORY_MODEL_PROFILE=testing`, use it.
- The inspector uses at least the standard rung for real items, and the testing profile for `factory test` items.
- A long-lived owner cannot change its own model. When the gateway raises the tier, the owner finishes the step, releases, and a new session resumes on the higher rung.

## 10. Merge queue, policy, and CI rules (already built)

`mergeQueueDepth` limits merged items waiting for their release candidate (the Release workflow keeps one queued run). `mergePolicy` is `auto` or `peer-approved`. A merged docs-only change finishes after master has been green for a grace period even if no release run appears. CI is classified strictly: zero check runs is pending, and each configured gate must be present and successful.

### 10e. One CI rule for flakes and pre-existing failures (issue 102, 2026-10-15)

Code: `plugin/scripts/lib/Prs.ps1` (`Get-ChecksFor`, `Get-RedCauses`, `Get-RedHeadRuling`, `Register-MasterDefect`), used by `complete`
(Verbs.Item.ps1), the sweep's wait for checks (`Complete-AwaitingChecks`, Verbs.Sweep.ps1) and `merge` (Verbs.Merge.ps1, also as the gateway's
merge after a PASS).

1. **Only the gates decide.** A head is red when a gate (`ciGates`, the checks the ruleset requires) failed, pending while a gate is absent or
   running, green when every gate succeeded. A failed check that is not a gate is listed (`failed_checks`, and `nongate_failed` in the public
   answer) and never makes the head red by itself. Without configured gates any failed check is red, as before. `-Ignore` (master's
   `masterIgnoredChecks`) still leaves checks out of the verdict.
2. **The causes.** The checks that made a head red: the failed or cancelled checks that are not gates, and failed gates that are not aggregating
   ones (`ciAggregateGates`, default `Build result`, which fails because a job it needs failed; `secret-scan` is a cause of its own); when there are
   none of those, the failed gates themselves.
3. **A red head is judged once its workflow runs completed.** Then, once per head, the failed jobs are re-run (`rerun-failed-jobs` of each failed
   or cancelled run) when the causes include checks other than the gates, match `masterFlakyChecks` (both acceptance shard families,
   `Acceptance Tests [shard n/6]` and `Acceptance Tests (ARM SQLite) [shard n/6]`), or fail on master too. The runs and attempts are recorded in the
   item state, `pr.rerun[<sha>]` (the last 5 heads), and the head is judged again on the newer, completed attempt of each run. A re-run started from
   the sweep's wait restarts its timeout (`devChecksTimeoutMinutes`). `complete` on such a head answers 21 `accepted-checks-pending` and leaves the
   rest to the sweep; `merge` waits (`checks-rerun`). When master's checks cannot be read, the head is judged later (no round for a GitHub blip).
4. **A master defect costs nothing.** A head still red whose causes all fail on master as well (the newest finished run of each on the last 5
   master commits failed) costs no fix-forward round and no demotion. It is reported once per set of checks: a comment on the item, the state
   `master_defect`, and one `plant.event` `master-defect` on the operator stream. The item waits (`merge` with reason `master-defect`); the gateway
   looks at master again every `timing.masterDefectCheckMinutes` (5). Once master passes those checks the ruling says so (fixed), once per defect:
   the gateway merges master into the branch (GitHub's update branch; for a PASS this is the one head accepted without a new verdict, as for an
   out-of-date branch), and the new head is judged as any head. If GitHub reports a conflict, Development is dispatched to merge master, without
   counting a round; a PASS that waits for its merge waits for a person then. A defect that outlasts `timing.parkHours` in Development parks the item
   (`master-defect`) for a person; a waiting PASS is parked after `timing.verdictTimeoutMinutes` as any unmerged PASS. A green head, the end of a park and `unpark` clear `master_defect`.
5. **Anything else is red, as before**: a fix-forward round in Development (the comment says when it was still red after the re-run), or a
   demotion at the merge.
6. **A park that ends gives a fresh start.** When a park ends by expiry (the sweep removes it, journal `unparked` by `expiry`) or by `unpark`,
   `fix_forward_rounds` and `demotions` are counted from 0 again (and with them the model tier's and the inspector's counts). Not for the gateway's
   own wait for checks (`development:awaiting-checks`).

### 10b. The verdict and the merge: the gateway merges (owner decision 2026-10-13)

Under merge policy `auto` (config `gatewayMerge`, default true) the step from a PASS to the merge belongs to the gateway, not to a session:

1. `validation-verdict` records the PASS and, for an item with `Auto Merge`, continues into the merge in the same call (`Verb_merge -Gateway`
   in `plugin/scripts/lib/Verbs.Merge.ps1`). The checks are exactly those of the `merge` verb: the item's own pull request, open, its head
   equal to the head the verdict was given for (a push after the verdict voids the PASS and demotes the item; the one head accepted without a
   new verdict is the one the gateway made itself when it brought the branch up to date with its base), the required checks green, GitHub
   says mergeable, the merge queue has room, no hold. The answer carries `merge: {outcome, reason}`; `next` stays `merge`, and the session's
   one `merge` call afterwards answers `already-merged`. Green checks: merged in the same call, about 20 s as before.
2. What cannot happen yet answers `outcome: "waiting"` with a reason code (`checks-pending`, `branch-updated`, `mergeability-unknown`,
   `merge-queue`, `held`), kept in `verdict.wait` and journaled once per code (`merge-waiting`). The sweep runs the same step again under the
   item lock on a fresh read for every unprocessed PASS: at once when the verdict call already tried, otherwise after
   `timing.passMergeGraceSeconds` (60), so a gateway restart, a lapsed lease or an item without an owner changes nothing. Nothing loops: a
   branch behind its base is updated at most `timing.outOfDateMergeAttempts` times per verdict, a red check or an unmergeable pull request takes
   the demote path (bounded by `maxDemotions`), and a PASS still unmerged after `timing.verdictTimeoutMinutes` is parked for a person.
3. An item in this state is never offered to a worker (a claim would be refused `verdict-already-recorded`). `/status` lists it under
   `passUnmerged`, and the patrol digest reports it as `pass-unmerged` with the reason code once it has waited
   `timing.passUnmergedDigestMinutes` (5).
4. The verdict's `processed` flag and the item lock make the step idempotent: two sweeps, or the session's call racing the sweep, merge once.
5. A pull request merged by a person is picked up by the sweep whatever state the item was in (a PASS waiting for the gateway, a PASS parked
   for a person because the item has no `Auto Merge`, an item still in Development): the merge is recorded, the verdict closed, claim, park and
   hand-off end, the card moves to Functional Testing if it was earlier, and `settle` takes it from there. A merge that a FAIL verdict already
   judged (residual gaps) is not picked up.

Without `Auto Merge`, or under `peer-approved`, nothing changes: the gateway does not merge.

### 10c. Offers (owner decision 2026-10-13)

- An accept is honoured only for the offer that stands for that session now: a late accept of an offer the gateway withdrew (it lapsed and
  went back to the plan or to another session), or of one it no longer knows (dropped, made before a restart), is refused with exit 11
  `stale-assignment`. While an accept runs, its offer does not lapse. A session therefore never holds more than its capacity.
- A session that let `timing.offerMissLimit` (2) offers in a row lapse is offered nothing new (unpinned) for `timing.offerCoolDownMinutes`
  (5), or until it calls a verb successfully. The `reassigned` journal line says so; `/status` shows `missedOffers` and `coolDownUntil` per
  worker and the dashboard a `cool-down` pill. 0 for the limit turns the rule off.
- Issue 100: an item taken back from a session (lease rule 1 or 3, section 6b) is a miss too, and the accept the stream client makes by itself
  (`accepted_by: client`) is no answer. `offerMissLimit` misses in a row with a take-back among them block the session: no offer at all, pinned
  items included, until the session calls a verb of its own or a new session of the name registers. The plant event `session-blocked` and the
  digest kind `session-blocked` report it; `/status` shows `blocked` and `blockedSince`.

### 10a. Docs-only fast path (owner decision 2026-10-12)

A one-line documentation item should go from accepted to merged in about 10 minutes with small-model subagents. Docs-only is decided once, in Technical Design: the design's `Files:` line names every file; all are under `docs/` or `.md` outside `src/`, and no code, build, workflow or test reads them; the design then carries `docsOnlyMarker`. `append-body` records the decision in the item state (`design.docs_only`) only when the marker arrives inside the design section while the item is in its design column, and refuses the marker anywhere else (`docs-only-marker-not-allowed`); completing the design column writes `false` when no design append set the field. Once the field exists the body text is ignored, so a marker typed into the issue gives nothing; only a state with no field on an item already past its design column (written by an older version) falls back to the marker in the body. Items without the marker are untouched by everything below.

| Stage | Rule | Enforced by |
|---|---|---|
| Technical Design | one review round; a second only for a finding that quotes the item (`FINDING: criterion "<text above the design section>" - ...` or `FINDING: file "<path in the design>" - ...`) | `record-review`: `timing.docsOnlyMaxReviewRounds` (2) instead of `maxReviewRounds`; a findings review with no grounded finding is refused with `finding-without-criterion` and uses no round |
| Development | no private build, no SDK; change, push, pull request; its checks are the gate | `open-pr`, `get-item` and `complete` answer `build_owed` (`Get-BuildOwed`, Prs.ps1): false only when the design recorded docs-only AND every changed file matches `docsOnlyPaths`; a marked item with any other file owes the build. `complete` still refuses a docs pull request without the marker and anything but green checks |
| Functional Testing | verdict against the acceptance criteria and the diff; nothing is built or started | `get-item` answers `verification: "diff"` under the same two facts (and no video label), otherwise `"app"` |

A command that a subagent's shell refuses inside its worktree is run by the owner session from the worktree path (`factory-development`, "A command refused in a subagent's shell"); the item is not parked for it.

Floor that remains: one design review round; the checks of the pull request (`ciGates`, run by the target repository's workflow, including for documentation); `complete` answers `accepted-checks-pending` while they run and the sweep (every `FACTORY_SWEEP_SECONDS`, default 180) advances the item when they are green; the merge verb waits for mergeability and pre-merge checks (`mergeabilityWaitSeconds` 90, `preMergeChecksWaitSeconds` up to 300); a docs-only change neither waits in the merge queue nor holds a place in it; after the merge the item reaches Done when master is green, at once if the master build skipped its publish step, else `docsOnlyReleaseGraceSeconds` (120) later, on the next sweep.

### 10b. Escalate earlier (owner decision 2026-10-14)

A criterion that fails twice in a row is usually ambiguous or untestable as written; another round costs time and finds nothing new.

| Rule | Enforced by |
|---|---|
| Two consecutive findings reviews of one column that quote the same acceptance criterion (`FINDING: criterion "<text above the design section>" - ...`) park the item (`same-criterion-repeated`) with a question to the owner on the item | `record-review` (`Test-RepeatedCriteria`, Verbs.Item.ps1): the round is recorded, the claim released, exit 10 `same-criterion-repeated`. A `REVIEW: COMPLETE` clears the column's record |
| Two consecutive FAIL verdicts whose summaries quote the same criterion (`criterion "<text>"`) park the item instead of demoting it, with the same question | `validation-verdict` (Verbs.Pr.ps1): answers `next: "parked"`, `reason: "same-criterion-repeated"`. A PASS clears the record |
| Acceptance criteria worded in time or statistics (`within 2 seconds`, `p95`, `%`, `average`, `latency`, `under load`, `at least N times`, ...) are flagged at Technical Design: one comment on the item and `timing_criteria` in the claim answer; nothing is blocked | `claim-item` in the design column (`Get-TimingCriteria`) |

A quote counts only when, whitespace folded, it is found word for word in the item above its design section and is at least 8 characters long. The records live in the item state (`cited`, `timing_flagged`), so they survive a restart of the gateway. Parking clears every `cited` record, so the first round after the owner answers (or after the park expires on `parkHours`) starts fresh. Timing flags cover every list item above the design section that matches the wording, context bullets included.

### 10d. A person releases a park early (2026-10-14)

A park holds an item for `timing.parkHours` (24) and `claim-item` refuses it meanwhile. When the owner has answered sooner (relaxed or reworded a
criterion, fixed what the worker reported), the operator releases the park instead of waiting:

```bash
pwsh plugin/scripts/factory.ps1 unpark --item 212 --reason "criterion 2 relaxed: 3 seconds, not 2"   # FACTORY_URL, FACTORY_TOKEN = the operator token
curl -X POST -H "Authorization: Bearer $FACTORY_OPERATOR_TOKEN" -H 'Content-Type: application/json' -d '{"reason":"..."}' $U/api/v1/items/212/unpark
```

| Rule | Enforced by |
|---|---|
| Only the operator token (the gateway's admin credential) is accepted; a worker, item, supervisor or operator-session credential is refused 403 | `POST /api/v1/items/{n}/unpark` (Program.cs). No change to Auth.cs: the rule verb `unpark-item` is in no role's verb list, and `POST /api/v1/verbs/unpark-item` answers 400 `use-endpoint` even for the operator, so the reason is always checked |
| A reason of 1 to 500 characters is required | the endpoint (400 `usage`) and the verb |
| The park leaves the item's state comment, written by the gateway's own author; a journal line names the park's code, who released it and the reason (redacted like every journal line) | `unpark-item` (Verbs.Item.ps1), event `unparked` |
| With no live claim and the item in an AI column (`columns.ai`), it gets a handoff to its current column and the plant forgets the assignment of the session that held it before the park (as for a `release`), so the sweep that the call requests offers it again at once, in that column | the verb (`reoffer: true`) and the endpoint |
| Not a park for a person, so refused (exit 10): `development:awaiting-checks` (`gateway-wait`: the sweep ends it when the checks finish) and `inspector-escalated` (`needs-approval`: only a human approval of the head clears it, `clear-hold`). An item with no park: `not-parked` | `unpark-item` |

An expired park (past its `until`) is removed the same way (`expired: true` in the answer); the two refused codes are refused even then. In a column outside `columns.ai` the park is removed with no handoff (`reoffer: false`). The item's column is not changed: to send it back to
an earlier column, move the card as before.

### 10e. The plant manager acts on the flow (owner decision 2026-10-14)

The supervisor session (the plant manager) used to advise only: every stuck item waited for a person. It now holds flow verbs that move an item
without deciding about the work itself, within guard rails the gateway enforces. Code: `gateway/Manager.cs`, the `manager-action` parts of
`gateway/Program.cs` and `gateway/Auth.cs`, `plugin/scripts/lib/Verbs.Manager.ps1` (the rule verb), `plugin/scripts/lib/Client.Manager.ps1` (the
client), the skill `plugin/skills/factory-supervisor`. Scenarios: `tests/scenarios/manager-actions.ps1` (`act: ...`, in the manager suite).

One verb, `manager-action` (`POST /api/v1/verbs/manager-action`, client `factory.ps1 act <action> ...`), with the supervisor credential of the
active supervisor (each call is a step of its hourly budget) or the operator token. Auth.cs keeps `item`, `action`, `policy`, `reason`, `worker`
and `level` of the body and stamps `by` with the credential's name.

| Action | What it changes | Refused when |
|---|---|---|
| `unpark --item N` | removes the park from the state; an item with no live claim in a working column gets a hand-off to its column, so the sweep this call requests offers it again; the plant forgets the earlier assignment and the park leaves the digest | not parked (`not-parked`); the parks that only a person or the gateway ends: `inspector-escalated` (`needs-approval`, clear-hold), `development:awaiting-checks` (`gateway-wait`), any park of an item with a PASS verdict on record (`needs-merge`) |
| `release-owner --item N` | ends the owner's lease as a take-back does (`taken_back: released-by-plant-manager`, the old owner cannot renew); the plant lets the owner go at once (`item.taken_back` to it, journal `reassigned`) and the item is offered again in resume mode (a relaunch, counted against `maxRelaunches`) | no owner with a live lease (`no-owner`) |
| `pin --item N --worker W`, `unpin --item N` | the label `worker:<name>` (one at most) | a closed item; `already-pinned`, `not-pinned` |
| `requeue --item N` | a hand-off to its column; the plant drops the item's unanswered offers, so it is offered afresh | not in a working column, a live claim (`owned`), a live park (`parked`), a PASS waiting for the gateway's merge, a merge being settled |
| `prioritize --item N --level top\|high\|normal` | the labels `priority:top` and `priority:high` (`priorityLabels`); the sweep reports them (`priorities`) and the plan offers pinned items first, then top, then high, then the rest, each in the sweep's order | a closed item; `already` |
| `rerun-failed --item N` | GitHub's re-run of the failed jobs of every completed, failed workflow run of the head of the item's open pull request; recorded per head (`manager_reruns`) | no open pull request, nothing failed, a run still in progress (`run-in-progress`), the same head a second time (`already-rerun`: a second failure is not a flake) |
| `drain --name W`, `resume --name W` | the name is offered no new work; the drain holds across reconnects, new sessions of the name and a graceful restart (plant snapshot `managerDrained`) until the supervisor or the operator resumes it. A session that is spent (its one item ended) stays drained after a resume; its next session registers undrained | the operator's drain of the name wins (`operator-drain`); a session's own drain is not lifted (`not-drained-by-manager`); a drain past the name limit (`name-action-limit`; a resume is never limited by it) |
| `restart-session --name W` | `session.restart` on the session's stream; its client writes the launcher's end marker (as for `session.end`, `docs/launcher.md`); the next session of the name is resent what the name owns. A journal line on each item it owns | no connected session of the name (`not-connected`); the name owns an item labelled `hold:owner` (`owner-hold`, from the last sweep's `holds`; before the first sweep after a start `sweep-pending`, exit 20); the name limit (`name-action-limit`) |

Guard rails, all enforced in code:

| Rule | Enforced by |
|---|---|
| Never merge, approve, record a verdict or clear a hold | `Auth.ManagerVerbs` holds the three reads and `manager-action` only (merge, approve-pr, validation-verdict, clear-hold, complete, move-next, claim-item and accept are refused "the manager role cannot call ..."); `unpark` refuses the parks only those end |
| The owner's hold wins | the rule verb: an item labelled `hold:owner` (`ownerHoldLabel`) refuses every action, exit 10 `owner-hold`, before anything is written; `restart-session` refuses a name that owns such an item (the sweep reports the held items, `holds`) |
| At most 3 actions per item in 24 hours | the rule verb counts `manager_actions` in the item state (so a restart does not reset it): exit 10 `item-action-limit` with `retryAfterSeconds` (`manager.actions.perItemPerDay`) |
| At most 30 actions an hour over every item | the gateway, in memory (a restart starts the hour again): HTTP 429 `action-limit` with `retryAfterSeconds` (`manager.actions.perHour`). An action the rule verb refused does not count, and a resume is never held by it |
| At most 3 name actions per session name in 24 hours | the gateway, in memory: drain and restart-session on one name, exit 10 `name-action-limit` (`manager.actions.perItemPerDay`); a resume is not counted, so a drain can always be lifted |
| A pin names a real session | the gateway: `pin` refuses a name that has not registered with this gateway since its start (exit 12 `no-such-worker`) |
| A policy code on every action, journaled | the gateway and the rule verb refuse a code outside `manager.actions.policies` (`unknown-policy`); each item action writes one journal line `manager-action` that names who, what, the code and the reason (one line, at most 300 characters, checked against the credential patterns); every action goes to the operator stream as `plant.event` code `manager-<action>`, and into the log of `GET /api/v1/manager/actions` (24 hours) |
| Advise mode turns the verbs off | `manager.mode` (`act` by default, `advise`; any other value is advise): every action answers exit 10 `advise-mode`. The owner sets it in the configuration; the operator token can switch it at run time (`POST /api/v1/manager/mode?value=act\|advise`; the plant snapshot brings back an `advise` after a graceful restart, never an `act`, and until the snapshot is read the mode is `advise`); neither the supervisor nor the operator session can |

The daily summary: once per UTC day, at or after `manager.dailySummaryHourUtc` (7; absent: none), the supervisor's stream gets
`supervisor.summary-due` (no message, no delivery of the budget; the plant snapshot keeps the day, so a release does not send it twice). The skill
then reads `factory.ps1 metrics --since 24h` (the active supervisor may read `GET /api/v1/metrics` with `since=24h` or `7d` and never `fresh`, one
step) and `factory.ps1 act-log`, and sends the operator one note instead of a line per event. `/status` carries
`managerActions` (mode, limits, the hour's count, the drains, the held items of the last sweep `ownerHeld`, the summary's day).

The answer of an item action carries `journaled`: false when its journal line could not be posted (GitHub refused it, or the item's journal is
full: `manager-action` shares the four extra slots past the cap with `qc-ready`, `qc-failed` and `question-escalated`); the gateway's log then has
a line `"journaled":false` with the item and the action. The reason of an action loses `<`, `>` and `@` and is one line.

## 11. Cloud workers (designed, NOT implemented)

### Shape
The gateway **launches** one cloud session per item through an adapter, then journals the assigned event with the session URL (as AISF does with its Cursor agent URL). Routing is per column with a fallback, like AISF's `AiToolColumnRouting`:
```json
"workers": {
  "routing":   { "Technical Design": "claude-cloud", "Development": "cursor-cloud", "default": "persistent-local" },
  "providers": { "cursor-cloud": { "apiKeySecret": "cursor-api-key", "model": "auto-smart" },
                 "claude-cloud": { "environmentId": "<ccpool_…>", "routineFire": "<token secret>" } },
  "maxConcurrent": { "cursor-cloud": 3, "claude-cloud": 3 }
}
```

### Cursor (known)
AISF's client launches through Cursor's API with repository URL, branch, prompt and model, remembers a claim for a window (default 30 minutes), and can ask the run state (`GET /v1/agents/{id}/runs/{runId}`) to detect a dead run. Needs: Cursor's GitHub App installed on `cmdemo1-workorders`, and `cursor-api-key` on the gateway.

### Claude cloud (to verify)
The CLI has `--cloud [description|session_id|url]` (create or attach to a cloud session) and `--environment <ccpool_…>` (run on a self-hosted environment); a routine's `/fire` endpoint starts a new session per fire (30 fires an hour per routine, 100 per account, text labelled untrusted). **Unknown until a one-session probe:** what `--cloud` prints, whether it runs unattended and returns the `claude.ai/code` URL. Decision: use routine tokens on the gateway (narrow) and not a full Claude login on the server.

### What cloud adds
1. Reachability: a cloud session reaches the gateway over public HTTPS (the container app; the tunnel for a pilot).
2. Credentials: the cloud session gets only an item-scoped token at launch (section 5).
3. Git: it pushes with its provider's GitHub access; a ruleset limits new branches to `factory-worker/*`.
4. Tooling: an environment with the .NET SDK (and Playwright if acceptance tests run) — **open: does one exist, and who creates it.**
5. Capacity and liveness: a script-owned cap per provider (journaled as waiting), the same lease and heartbeat, plus the provider's run status to spot a dead session.
6. Triggers arrive through `wait-event` (outbound), so nothing needs to reach into the cloud.
7. Model: the testing profile is pinned per launch; otherwise the provider's default.

## 12. Testing

Tier 0 unit; Tier 1 against a fake GitHub and fake Octopus, with scripted workers registering and receiving assignments; Tier 2 against the real repo with the real Apps and a scripted worker; Tier 3 with real Claude workers on the testing profile and an adversarial explorer. Invariants checked on every run: no sweep or internal errors in the gateway log; every assignment has a preceding "matched"; no comment contains a secret; no merge without an approval on the current head; no verb accepted with a token for another item or role. Cloud adapters get a fake launcher in Tier 1 (URL comment, redacted failure, refused wrong-item token, concurrency cap, re-offer after a dead session).

## 13. Implementation order

Local first, in this order: (1) worker registry, `subscribe --own`, `accept`, `my-items`, `drain`, `resume`, `wait-event`, directed assignment and acknowledgment timeout; (2) item-scoped, role-scoped tokens and the worker credential; (3) the owner-session skill (per-item ownership across columns, all prompts and triggers via subagents); (4) the inspector as a bot job in its own session; (5) the journal events; (6) Tier 1 scenarios for each, then a Tier 2 run. Cloud adapters are a later phase behind the same interfaces.

## 14. Decision 2026-10-11: cloud sessions are created by hand

Open question closed: nobody provisions a cloud environment automatically. A person starts a Claude cloud session (or a Cursor cloud agent) and gives it the connect prompt; from then on it behaves exactly like a persistent local session (`subscribe --own`, same credentials, same skills). The registry only labels it `claude-cloud` / `cursor-cloud` (assignment preference: persistent-local, then cloud, then ephemeral-local). No cloud adapter is built.

The worker dashboard (`GET /dashboard`, data from `GET /api/v1/dashboard`, operator token) shows the connected sessions of one running factory (the gateway's `FACTORY_ENVIRONMENT`: tdd, uat or prod), their state, load and assignments, drain/resume, and generates the connect prompt. Creating the prompt issues a one-time worker credential for the chosen name (`POST /api/v1/workers/{name}/credential`); the gateway does not store it. `revoke` on a session row refuses every credential issued so far for that name (section 5).

## 15. Board guard (2026-10-15, issue 88)

An open issue with the factory label (`label` in `config/instance.json`) that has no card on the project board, or a card with no column, is
invisible to the sweep: on 2026-10-14 nine new items sat unseen until a person added them. Every sweep (`sync-board`, `Invoke-BoardGuard` in
`Verbs.Sweep.ps1`) lists the open labelled issues through the REST API (paged; pull requests and issues with the rival label skipped). For each one
the board snapshot shows without a column it reads the issue again, since a person may have placed it meanwhile: a card in a column is left
alone, a card without a column gets the intake column (the first column of `columns.ai`, Technical Design), and an issue without a card is added
there. Each placement is journalled once (`board-added`); from there the item is offered like any new item, after `timing.sweepSeenCount`
sightings. At most 20 attempts per sweep (the rest follow at the next sweeps); a rate limit, or three failures in a row, end the pass. A failed listing is reported in the
sweep's `errors` (item 0), a failed placement in its `actions` (`board-add-failed`); both are tried again at the next sweep.

## 16. Auto-unpark (2026-10-15, issue 90)

A park whose cause has cleared is lifted by the sweep (`Test-AutoUnpark` and `Invoke-AutoUnpark` in `Verbs.Sweep.ps1`), under the item lock on a
fresh read (only the same park), with a journal line `unparked` "by the sweep" and the reason; the gateway forgets the park (`unparked` of
`sync-board`). An open item without a live claim is handed to its column, so it is offered at that sweep; an owner that still holds the claim gets
the trigger `item.unparked`.

| Park | Lifted when |
|---|---|
| `master-broken` | master's head is green and every check that failed at the park (`park.failed`, recorded since this change) passed on it; a skipped job (a docs-only head) does not count. The item waits for master green again; when its own merge commit is still not green (issue 70), master's green head is judged instead (`merge.judge_sha`). |
| `verdict-failed`, `fix-forward-exhausted` | the item's open pull request is green on a head newer than the one the park judged (`park.pr`, `park.head`, recorded since this change). |
| `session-relaunch-budget`, and `watchdog-relaunch-budget` with `last_take_back` | a worker session could take the item now (`free_workers`, which the gateway passes to `sync-board`: connected owner sessions, not draining or cooling, with a free slot, not spent, with room on their host); one lift per free session in a sweep. |

A park written before its facts were recorded (`park.failed`, `park.head`) is left to a person. No item is lifted more than
`timing.autoUnparkMax` times (default 3) per park code (`state.auto_unparks`): an item that breaks every session or every build is not retried for
ever. Every other park (worker-failure, demotion-limit, same-criterion-repeated, inspector-escalated, stuck, the release-candidate timeouts) stays
a decision for a person (`POST /api/v1/items/{n}/unpark`).
## 17. Work already started first; why every unowned item waits (2026-10-15, issues 97 and 99)

`Plan` offers, after pinned items, the offers of columns past the intake column (`columns.ai[0]`, Technical Design) before new work: an item
orphaned in Development, Functional Testing or Review by a take-back, a park or a lost session takes a free worker before a new item does.
`/api/v1/status` shows:

- `plant.orphans`: each unowned item past the intake column that waits for an owner, with its column, since when and `minutes`.
- `plant.unowned`: every unowned item the factory knows of with why it waits, one row each, the first that applies: `parked` (code, since,
  until; from the sweep's `parks`), `held` (`depends-on`, `on`), `offered` (worker, until), `waiting` (the waiting code, since); an orphan,
  offered or waiting, also has `orphanSince` and `orphanMinutes`; `pass-unmerged` (a PASS the gateway is to merge, with its reason code),
  `unconfirmed` (seen once on the board, offered at the next sweep), `release-queue` (merged, waiting for production). Column names and codes are
  gated like the digest's. The lists are rebuilt by every sweep and are in memory.
