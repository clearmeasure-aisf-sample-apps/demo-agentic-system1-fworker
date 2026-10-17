# Handoff: state of the factory worker gateway

Written 2026-10-13, when the source moved into this repository. It is the starting point of a session that has only a clone of
`clearmeasure-aisf-sample-apps/cmdemo1-fworker`. How to build, test and release: `CLAUDE.md`. Designs: `docs/design/`.
Keep this file current: a change that closes a backlog entry or changes an environment edits it in the same pull request.

## 1. What the system is

A software factory for the work-order application (`clearmeasure-aisf-sample-apps/cmdemo1-workorders`, public, project board 679).
A work item labelled `factory worker` that is moved to Technical Design is taken by an AI session and carried through
Technical Design, Development and Functional Testing to a merged pull request, a release and Done.

- **Gateway** (this repository, `gateway/`): holds every GitHub and Octopus credential, runs the rule scripts
  (`plugin/scripts/factory.ps1 --server <verb>`), sweeps the board, keeps the plant (workers, assignments, owners), serves the dashboard,
  the connect prompt and the plugin download, and carries worker messaging. Workers never hold a GitHub credential: they call verbs.
- **Workers**: AI sessions (Claude Code local or cloud, Cursor cloud) started by a person with the connect prompt of the dashboard.
  The prompt downloads PowerShell and the plugin and runs `subscribe --own` under the Monitor tool (loaded first where it is deferred; a
  background command only where there is no Monitor tool); the session owns each item it is given until its pull request is merged (the
  gateway settles it from there, issue #107). Label `worker:<name>` pins an item to one worker; `Auto Merge` lets it merge without a person;
  `factory test` selects the cheapest model profile.
- **Plant manager / supervisor**: one session (name `supervisor`) that answers the questions workers ask, reads the gateway's patrol
  digest and keeps the flow moving with the flow verbs of `manager-action` (unpark, release-owner, pin and unpin, requeue, prioritize,
  rerun-failed, drain and resume, restart-session) within guard rails the gateway enforces (`docs/design/plant-manager.md` 10e). It never
  merges, approves, records a verdict or clears a hold; `manager.mode` `advise` turns its verbs off.
- **Operator**: the person (or script) with the operator token: dashboard, credentials for workers, revoke, messaging on and off,
  notes to any session.
- **Operator session**: one AI session (name `operator-session`) with a credential of its own kind, not the operator token. It watches
  every item and improves the factory worker and the gateway within its guard rails (`docs/design/operator-session.md`, section 6a).
- **Messaging**: notes, broadcasts, item threads, questions and answers between workers, the supervisor and the operator
  (`docs/design/worker-messaging.md`). All of it is in the memory of the gateway process.

## 2. Environments and how to check them

| Environment | URL | State |
|---|---|---|
| tdd | `https://ca-cmdemo1-tdd-fworker.graybush-19a6e13b.southcentralus.azurecontainerapps.io` | The acting gateway: sweeps the board. Version 1.0.37 on 2026-10-13 (pull request 18). Every merge to `master` deploys here |
| uat | not recorded in this repository; ask the operator | Receives a release only by a manual promotion |
| prod | `https://ca-cmdemo1-prod-fworker-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io` | Inert: its GitHub credential is the placeholder, so it does not act. `docs/deploy/activate-prod.sh` (run by the owner) would make prod the acting gateway and tdd inert. Only one gateway may sweep the board |

Checks that need no credential:

```bash
U=https://ca-cmdemo1-tdd-fworker.graybush-19a6e13b.southcentralus.azurecontainerapps.io
curl -s $U/_build                                  # version, pluginHash, started (a new start time means a restart), environment
curl -s $U/ready                                   # 200 "ok" when the revoked credentials are read; before that 503 and
                                                   # {"ready":false,"waitingFor":"revocations","attempts":N,"since":"..."}
curl -s -o /dev/null -w '%{http_code}\n' $U/health # liveness (also /alive)
# dashboard, in a browser: $U/dashboard  (asks for the operator token)
```

Checks with the operator token (`Authorization: Bearer $FACTORY_OPERATOR_TOKEN`): `GET /api/v1/status` (plant, workers, assignments,
messaging and manager counters), `GET /api/v1/messages?limit=200` (traffic), `GET /api/v1/questions?state=all`, `GET /api/v1/peers?all=1`.

### Credentials are NOT in this repository

A new session must be given them as environment secrets. Names the scripts read:

| Variable | What | Read by |
|---|---|---|
| `FACTORY_OPERATOR_TOKEN` | Operator token of the gateway of one environment (tdd for daily work) | `docs/deploy/gen-connect-prompt.sh`, the status calls above |
| `GH_TOKEN` | GitHub token with push to this repository (pull requests, `gh pr merge`, `gh run`) and, for live proofs, issues and the board of cmdemo1-workorders | `gh`, `run-*.sh` |
| `OCTOPUS_API_KEY` | Read-only key of the Octopus space `Spaces-355` at `https://clearmeasure.octopus.app` (releases and deployments of project `cmdemo1-fworker`) | `run-*.sh` |
| `FACTORY_DEV_TOKEN`, `FACTORY_WEBHOOK_SECRET`, `FACTORY_TOKEN_SECRET` | Only for a gateway started locally with `run-owner-gateway.sh`: any values of your own | `run-*.sh` |

On the owner's machine the same values are in the keyring (`secret-tool`, service `factory-worker`; the Octopus key under service
`demo-operator`); the scripts above fall back to it. `tests/live` and `tests/fullrun` read `gh auth token` and the keyring only.
Deployed gateways read theirs from the environment's vault, set by the operator with the demo-environment kit. The GitHub App keys
(author App `factory-worker-author`, reviewer and test-person Apps) exist only in the keyring and the vaults. Tier 1 needs none of this.

Octopus access is read-only for a session: deployments to tdd come from the release workflow, promotions to uat and prod from the operator.

## 3. Decisions of the owner (binding)

Made by the owner, 2026-10-10 to 2026-10-13.

- **Source of truth is this repository** (public). Tests, the fake GitHub and the stress script live here, pull request checks run the
  suites, there is no staging step and no local-only copy.
- **Pull requests of this repository merge automatically when every check is green**; no GitHub review is required. Speed of iteration
  is the goal; this is a demo system.
- **Review before every commit** by a fresh subagent that reads only the staged diff. Subagents run on Opus 5.5 at low effort unless he
  names another model.
- **Operator session role** (built, 2026-10-13): a third kind of session next to worker and supervisor, with its own connect prompt
  and skill, one slot, on **Opus 5.5 at low effort**.
- **Autonomy in tdd**: the operator session may fix, merge and redeploy to tdd by itself. Guard rails, all of them:
  1. tests and review before every merge;
  2. deploy only when the plant is quiet; announce the restart to the connected sessions, verify that they reconnect, roll back otherwise;
  3. protected areas need the owner: credentials and tokens, authorization, revoke, the deploy pipeline, the operator's own skill and
     guard rails, uat and prod;
  4. a daily limit of self-merged releases, with a report (12 a day since 2026-10-14, with small changes batched; 3 before);
  5. every change is recorded as an issue in this repository.
- **The operator session acts without a person inside its guard rails** (2026-10-14, pull request "operator authority", owner review): it takes
  the recommended option and builds it, the owner hearing of it in the changelog issue; it merges its own green, unprotected pull requests
  as soon as guard rails a to e allow, without waiting; it may drain, resume and set the capacity of a worker name as the operator does, and read the
  cycle-time metrics. It still cannot mint, revoke, switch messaging or call a verb, and container logs stay with the operator (no read-only
  wrapper exists).
- **uat and prod stay manual.**
- **One work item per worker session** (2026-10-14): when its item ends the session ends (the skill says so, and the worker connect prompt says an item is owned until its pull request is merged; changing that text changes a hash pinned by the operator suite, a protected path, so it needs the owner's review), and a launcher loop starts a new session from the
  connect prompt. The gateway offers a session that held an item no other (`plant.oneItemPerSession`); `docs/launcher.md`.
- **Messaging and the supervisor are on for every registered worker** (`allowedWorkers` and `allowedAskers` are `*`), set in
  `config/deploy.overrides.json`; the source default stays off.
- **The operator reaches every session**, the supervisor included (shipped in 1.0.37).
- **The plant manager reports problems to the operator proactively** (backlog a): a stalled item, the last review round, a blocked
  worker note, repeated verb errors; one concise note per new problem.
- **Docs-only fast path** (shipped in 1.0.37): Technical Design is one pass and one review round (a second only for a concrete defect
  against an acceptance criterion); Development without the private build; a command that a subagent's shell refuses is run by the owner
  session. Target: about 10 minutes for a one-line documentation item.
- **The worker prompt and the plugin assume nothing about the machine** (2026-10-11): any OS and CPU, only what is downloaded or cloned.
- **Reports are short**: outcomes only. Hung or failed things are restarted without asking and reported afterwards. Questions to the
  owner one at a time.

## 4. Verification to date

| What | When | Result |
|---|---|---|
| Tier 1, 18 suites, full tier | 2026-10-12 | 3,110 checks, 0 failed (before the fix releases; the suites have grown since, the pull request checks give the current count) |
| Messaging stress, local, `tests/stress/messaging-stress.ps1` | 2026-10-12 | Passed. 600 s, 30 workers, 51,745 requests, no 5xx, 7,117 messages accepted and all accounted for (0 lost, none delivered twice after acknowledgement), supervisor takeover in 21 s, gateway killed and restarted in 1 s, messaging switched off and on, memory bounded (peak 166 MB), no process left |
| Tier 2 on tdd, two worker sessions | 2026-10-12 | Passed. Items 189 and 190 (pull requests 191 and 192): two sessions that edit the same file agreed on the order by notes and merged without help |
| Load on tdd | 2026-10-12 | Passed. 304 s, 10 sessions, 5,103 requests (16 per second), no 5xx, no transport error; 435 messages accepted, each read once, none missing; only documented refusals (429 rate and pair limits); p95 below 100 ms for ordinary calls |
| Tier 2b on tdd, two workers and the supervisor | 2026-10-13 | Supervisor answered worker questions and wrote two patrol notes to the operator about nine items pinned to a worker that was not connected |
| Team test on tdd: `team-cloud-1`, `team-cloud-2` (Claude cloud), `Cursor-worker-1` (Cursor cloud), supervisor | 2026-10-13 | Items 198 to 202 (docs-only) all merged and closed within 27 to 51 minutes. Findings: three review rounds on one-line changes, an item blocked on a build it did not need, no channel from the operator to the supervisor. All three addressed in 1.0.37 |
| 30-item live run (local gateway, before the cloud deployment) | 2026-10-11 | 25 Done, 5 held for a person |
| Image configuration after the move | 2026-10-13 | The image built from this repository carries exactly the configuration tdd ran before (compared key by key) |

Not verified: see backlog i, j and k. The docs-only fast path and operator-to-supervisor messaging are covered by Tier 1 and deployed,
but have not had a live proof on tdd since 1.0.37.

Raw evidence (logs, prompts, traffic) stays on the owner's machine and is not committed: prompts and logs can contain credentials.

### Agents, roles and launch modes: what is built (2026-10-17)

Design: `docs/design/agents-roles-launch.md` (approved by the owner 2026-10-16). Built so far, steps 1 to 3, 4 (worker prompts only) and 9
(the api mode with Cursor Cloud Agents, off by default):

- **`/mcp`** (`gateway/Mcp/`): Streamable HTTP, stateless, `ModelContextProtocol.AspNetCore` 1.0.0. Bearer credential as at `/api`.
  `tools/list` and `tools/call` are filtered by role (`gateway/Mcp/RoleTools.cs`, code-owner path). Each tool calls its `/api/v1` endpoint
  in-process (`InProcess.cs`), so refusals, exit codes and journaling are the endpoint's. 240 tool calls a minute per credential.
  - **owner** (the admin token, or an owner r1): `factory_status`, `workers_and_runs`, `item_detail`, `metrics` (read only).
  - **worker** (a worker r1, or a legacy owner i1): `item_get`, `item_accept`, `item_claim`, `item_append_body`, `item_comment`,
    `item_release`, `item_record_review`, `item_complete`, `pr_open`, `pr_update`, `pr_checks`, `pr_wait_checks`,
    `item_validation_verdict` (functional-testing phase only), `send_note`, `ask`, `next_event`, `session_end`, `get_prompt`.
  - A worker r1 session is registered with the plant at its first call (`WorkerSessions.cs`); the item token of its offer stays in the
    gateway; `next_event` long-polls (at most 50 s) the same events the stream client gets. Idle sessions end after `timing.mcpIdleMinutes`
    (30).
- **`r1` role tokens** (`gateway/Auth.cs`): `r1.<payload>.<hmac over "role:"+payload>`, bound to name, role, mode, agent, environment,
  expiry, item, phase and the name's revocation generation. `Auth.RoleOf` maps the legacy kinds; `auth.legacyKinds` (default true)
  refuses w1, w2, m1, o1, k1 and i1 when false. Minted today only by the Cursor adapter (and a test seam).
- **Prompts** (`prompts/`): `bootstrap/api.md`, `common/rules.md`, `worker/technical-design.md`, `worker/development.md`,
  `worker/functional-testing.md` (migrated from the plugin skills, docs-only path included). Served by `get_prompt`; `/_build` reports
  `promptsHash`; `/ready` answers 503 `waitingFor: prompts` while one does not parse. Lint: `tests/smoke.ps1`, section "prompts".
- **api mode, Cursor Cloud Agents** (`gateway/Runtimes/CursorCloudRuntime.cs`): an item labelled `runtime:cursor-cloud` gets one Cursor
  agent per phase: `POST https://api.cursor.com/v1/agents` with the bootstrap prompt, `repos[0]` cmdemo1-workorders at `master` (Technical
  Design and Development; Functional Testing at `factory-worker/N-development`), `autoCreatePR` false and `mcpServers` =
  `[{name: "fworker", type: "http", url: "<gateway>/mcp", headers: {Authorization: "Bearer <r1>"}}]`. Followed by `GET /v1/agents/{id}`
  and its run; cancelled and deleted at `session_end`, at `api.cursor.maxMinutes` (60) and on revoke; the worker name is revoked when its
  agent ends, so the r1 Cursor stored is dead with it. v1 routes docs-only items only: the sweep ignores the label (action
  `runtime-label-ignored`, reason `not-docs-only`) for an item past Technical Design whose design does not carry the docs-only marker.
  Model: Auto with the cost preference (owner decision 2026-10-17): `auto-smart` with `optimize_for: cost` when `GET /v1/models`
  lists it, else `auto`; never the account default. Settings `api.cursor.*` in `config/instance.json` (`enabled` false,
  `maxConcurrent` 1, `maxMinutes` 60, `maxExecutionsPerDay` 10, `ackSeconds` 900, `model` auto, `optimizeFor` cost, `environments`);
  the deployed image turns it on in tdd only, with 6 launches a day (`config/deploy.overrides.json`). Tier 1: suite `cursor` against the fake Cursor API of `tests/FakeGitHub`.

To run a first live test of a Cursor agent on tdd:

1. The tdd gateway app (`ca-cmdemo1-tdd-fworker`) reads `CURSOR_API_KEY` (Key Vault secret `aisf-cursor-api-key` of kvcmdemo1tddvq464,
   wired by the cmdemo1 session; uat and prod have it unset). `config/deploy.overrides.json` turns `api.cursor` on for tdd only
   (`environments.tdd.gatewayUrl` is its public URL). The start log line `{"runtime":"cursor-cloud","enabled":true,...}` confirms it,
   and `/api/v1/status` shows `runtimes."cursor-cloud"`.
2. Install the Cursor GitHub App on `clearmeasure-aisf-sample-apps/cmdemo1-workorders` for the Cursor account of that key, with push to
   branches other than `master` (owner decision 16.4: the second push identity).
3. Create a docs-only work item (only files under `docs/`) labelled `factory worker` and `runtime:cursor-cloud` (and `Auto Merge` if it
   should merge by itself), and move it to Technical Design. Do not pin it with `worker:<name>` (a pin skips the runtime routing).
4. Watch `/api/v1/status` (`runtimes."cursor-cloud".executions`), the item's journal and the Cursor dashboard. The agent's worker is named
   `cur-<item>-<6 hex>`.

Not built yet: hosted runner on MCP (step 5), Copilot and Cursor CLI adapters (6), manual seats and `request_role` (7), role runs (8),
removing `type` (10), the inspector, qc, manager, operator and keeper prompts and tools, `prompt_pin`, the gateway-side lease renewal
beyond `next_event` and item tool calls.

## 5. Open defects and backlog, in priority order

Done 2026-10-13 (issues 33, 30 and 31 of this repository): **the gateway finishes an approved item by itself.** A PASS on an `Auto Merge`
item under policy `auto` is merged by the verdict call, or by the sweep as soon as it can be (checks green, branch brought up to date, after a
restart or with no owner); the item is never offered while it waits, `/status` lists it under `passUnmerged` and the digest names it
`pass-unmerged`. A pull request a person merged settles the item from any state. A late accept of a withdrawn offer is refused
(`stale-assignment`), and a session that lets two offers in a row lapse cools down for 5 minutes. Design: `docs/design/plant-manager.md` 10b
and 10c; config `gatewayMerge`, `timing.passMergeGraceSeconds`, `passUnmergedDigestMinutes`, `offerMissLimit`, `offerCoolDownMinutes`.
The suites `auto` and `merge-queue` run with `gatewayMerge` false: they test the session's `merge` verb as it was.

a. **Done (2026-10-13): the plant manager reports problems to the operator proactively.** The patrol digest carries seven more codes
   (`item-quiet`, `last-review-round`, `review-rounds-exhausted`, `worker-blocked-note`, `verb-errors`, `merge-refused`,
   `gateway-restarted`; `docs/design/worker-messaging.md` 3.9 "Reported conditions") and the supervisor's skill sends the operator one
   note per new problem and one reminder when it persists. Not yet seen live: watch the first run on tdd for `item-quiet` notes about
   workers that are busy without calling a verb (raise `timing.mgrQuietMinutes` if they are noise), and run the stress test once.
b. **The operator session role.** Done 2026-10-13: credential kind `o1.`, one slot, connect prompt, skill `factory-operator`, the
   quiet-plant check and the daily limit enforced by the gateway (`docs/design/operator-session.md`). Open: it has not run live on tdd
   (section 6a). Since 2026-10-13 a ruleset of the default branch requires the owner's review for the paths of `.github/CODEOWNERS`.
   Open items of the review of the role:
   - a second operator name gets a fresh note allowance (the limit on notes is kept per name, so `operator.allowedNames` with two names
     doubles it);
   - the answers of the operator session to questions are not rate limited;
   - the caps on notes and on budget grants are in memory and start again at every restart of the gateway (a self-merged release is a
     restart).
t. **Done (2026-10-14): escalate earlier** (`docs/design/plant-manager.md` 10b). Two consecutive findings reviews or FAIL verdicts that
   quote the same acceptance criterion park the item (`same-criterion-repeated`) with a question to the owner; timing or statistical
   criteria are flagged at Technical Design (a comment and `timing_criteria` in the claim answer). Open: not yet seen live on tdd; the
   supervisor's digest reports the park as `parked` with that code, and its skill (owner review) does not describe the code yet.
u. **Done (2026-10-14): a person releases a park early** (`docs/design/plant-manager.md` 10d). `POST /api/v1/items/{n}/unpark` with a
   reason, operator token only (client: `factory.ps1 unpark --item N --reason "..."`); the park leaves the state comment, the journal records
   the reason, and the sweep offers the item again in its column. Open: not yet used live on tdd; the operator session's credential cannot
   call it (by design), and the supervisor's and operator session's skills (owner review) do not mention it.
r. **Done (2026-10-13): a session can read why a pull request check failed.** `pr-checks` (and `wait-for-checks` when it answers
   `checks-red`) returns, next to the status it always returned, `checks`: every check of the head and, for a failed or cancelled one,
   the output title and summary, the annotations split by where they point (`onChangedLines`, `onChangedFiles`, `elsewhere`), for a
   GitHub Actions job the failed steps and an excerpt of the log (the last 200 lines of each failed step plus the error lines, 60,000
   characters for all jobs together, with what was cut), the artifacts of the run, and `baseline` (the same check on the last 5 commits
   of the base branch) with `likelyPreexisting`. Flags: `--check`, `--tail`, `--brief`, `--full-log [--page]`, `--artifact [--entry]
   [--page]`, and the client's `--save FILE` (pages of 48,000 characters; 5 MB of text and 25 MB of archive at most). All of that text is
   in `data` or `content` fields marked `author_trust: "untrusted"`, cleaned and redacted (`plugin/scripts/lib/Checks.ps1`). A call that
   names an item now reads that item's own pull request only (`pr-not-own`, `sha-not-own`): before, an item token could name any pull
   request or commit. GitHub permissions of the gateway's identity: `Checks: read` and `Actions: read`; both are in the manifest of the
   author App (`tools/github-app-setup/serve.ps1`), and whether the installed App has them was not checked from this repository. Without
   one the answer carries `logs-not-permitted`, `annotations-not-permitted` or `artifacts-not-permitted` and the verb still answers.
   Collecting the detail never changes the old fields or the exit code: each GitHub call for it is one attempt of at most 10 s, an
   answer spends at most 60 s on it (25 s inside `wait-for-checks`), and what was not read is `available: false` with a code or named
   in `detailNotShownFor`.
   Open: (1) **the supervisor** gets the default answer only: `Auth.ManagerBodyFields` passes `item`, `pr` and `sha` for `pr-checks`, so
   `check`, `tail`, `full_log`, `page`, `artifact`, `entry` and `brief` are dropped for it. To give it one check, the whole log or an
   artifact, add those names to that list (`gateway/Auth.cs`, owner review) and a line to its skill; until then it reads any pull
   request with `pr-checks --pr P` and no `--item`. (2) The reads of a job, its log, its annotations and an artifact archive (with the redirect to the signed address) were tried once
   against the real GitHub with a personal token on this repository; with the App identity of a deployed gateway they are not yet seen. (3) The
   baseline reads the last 5 commits of the base branch, so a check that runs only on pull requests (Qodana may) is `absent` there:
   then `annotationCounts.elsewhere` is the evidence.
s. **Done (2026-10-13): the standing back-merge trigger** (`docs/design/plant-manager.md` 6a). A pull request merged into master (webhook
   `pull_request` closed and merged, debounced 20 s; fallback: the sweep compares master's head, at most every 60 s) sends `base.updated`
   to every owner whose branch is behind, with the overlapping files; the owner merges master into its branch at once (skill rule). After
   120 s the gateway itself calls GitHub's update branch for a clean pull request the owner has not updated; a conflicting one stays with
   the owner. Config: `timing.baseUpdateDebounceSeconds`, `baseUpdate.*`; counts in `/status` (`baseUpdate`). Open: (1) whether the
   installed author App has contents write and pull requests write was not checked from this repository (the manifest has both; without
   them the update branch call fails and the owners still do the back-merge); (2) the peer-messaging skill (owner review) does not list
   `base.updated`; it is a plant trigger, not a message, so nothing depends on it; (3) not yet seen live on tdd.
t. **Done (2026-10-14): SSE keepalive** (enhancement 11). Every event stream (worker, supervisor, operator session, the operator's broadcast)
   writes a `: ping` comment every 25 s, busy or idle (`FACTORY_SSE_PING_SECONDS`); before, a ping came only after 15 s without an event.
   The stream clients (`Client.Subscribe.ps1`, `Client.Own.ps1`) ignore comment lines and print `stream.error` only from the third failed
   attempt in a row (after a drop by error: the drop and 2 failed reconnects; after a clean end of the stream: 3 failed reconnects). Open: `Client.Operator.ps1` (code-owner path) still reports the first failure.
u. **Done (2026-10-14): the plant survives a graceful restart** (enhancement 5, `gateway/PlantSnapshot.cs`, `plugin/scripts/lib/PlantSnapshot.ps1`).
   At SIGTERM the gateway writes its offers, assignments (not QC environments), owners and leases as the message of a parentless commit held by
   `refs/factory/<instance>/plant-snapshot`; the next start reads it back before its first sweep and restores it (an unanswered offer gets a fresh
   window and is pushed again when its worker reconnects, or at once to a worker already reconnected). The start removes the ref after reading it,
   so a snapshot is restored once. A snapshot older than `timing.plantSnapshotMaxAgeMinutes` (30) is ignored, and an
   outright kill (out of memory) writes none. `/status` shows `plantSnapshot.restore`. `FACTORY_PLANT_SNAPSHOT=0` switches it off. Messages,
   questions and presence are still in memory only. That was the behaviour without the leader lease (`FACTORY_LEADER_LEASE=0`); with it,
   entry x.
x. **Done (2026-10-14, issue 94): one acting gateway across releases** (`gateway/Leader.cs`, `plugin/scripts/lib/Leader.ps1`). In single-revision
   mode the new revision starts before the old one stops: before, both swept, the new one restored nothing (the old one's snapshot came at its
   SIGTERM, later) and sessions kept their stream on the old process while their calls reached the new one (#68).
   - The leader lease is the ref `refs/factory/<instance>/gateway-leader`: a commit whose message is the record (epoch, holder, version,
     revision, replica, until, released). Every change is a compare-and-swap (the new commit's parent is the one read, the ref moved without
     force; GitHub refuses a non-fast-forward, 422). A starting process takes epoch+1 at once; only the holder acts (sweep, ticks, back-merge
     trigger, snapshots). It renews every `timing.leaderRenewSeconds` (120) a lease of `leaderLeaseSeconds` (360) and checks every
     `leaderCheckSeconds` (15) with one conditional read (304 when unchanged, not counted by GitHub).
   - A holder that finds a later epoch stands down: it writes its final snapshot (never over a later epoch's), ends its streams with
     `stream.replaced` (`reconnect`, code `gateway-replaced`; only for clients that registered with `handover=1`, the others' streams are just
     ended) and answers every call and webhook 503 `gateway-replaced` (`/ready` 503) except the operator's `/status` and dashboard. The stream
     client prints `stream.handover` and connects again. It stays a standby and takes the lease again when it is released or runs out.
   - The plant snapshot is written on every change (a change of offers, acceptances, owners, drains or bot holders at most every
     `plantSnapshotDebounceSeconds`, 30; anything else at most every `plantSnapshotRefreshMinutes`, 10), tagged with the writer's epoch. A
     start accepts only its predecessor's epoch (the released lease names it as `plant_epoch`): at once when the predecessor released the
     lease or its lease ran out, else after waiting up to `leaderHandoverSeconds` (90) for the predecessor's final snapshot (then its latest).
     An outright kill loses at most the debounce. A graceful stop of the holder writes its final snapshot and releases the lease.
   - The gap: the first full sweep after a start renews the owners' claims whose lease ran out between the predecessor's release (or its last
     renewal, when it died or handed nothing over) and that sweep, not taken back, and at most `gapRenewMaxMinutes` (120) ago (journal
     `gap-renewed`, sweep action `claim-renewed-after-gap`).
   - `/api/v1/status` shows `leader` (role starting, acting, superseded or stopping; epoch; predecessor; superseded by) and
     `plantSnapshot.restore.how` (`handover`, `handover-timeout`, `released`, `lapsed`, `no-predecessor`). `FACTORY_LEADER_LEASE=0` turns it
     off (the suites run with it off; `tests/scenarios/leader.ps1` turns it on).
   Limits: the first release with this change still overlaps (the old process has no lease); a process superseded before its own restore
   finished hands nothing over; the operator session's stream client (`Client.Operator.ps1`, code-owner path) gets no `stream.replaced`,
   only the end of its stream, and reconnects as after any drop; the supervisor's and operator session's skills (code-owner paths) do not
   mention `stream.handover`. Not yet seen live on tdd: at the next release check `leader` and `plantSnapshot.restore.how` on the new
   process and that no sweep line of the old one follows its `handed-over` line.
v. **Done (2026-10-14): lasting cycle-time metrics** (enhancement 13). `GET /api/v1/metrics?since=7d|24h|30m|<ISO>[&max=100][&fresh=1]`
   (operator token) runs the admin rule script `metrics` (plugin/scripts/lib/Metrics.ps1). It reads the board's `factory worker` items, newest
   first, and from each item's journal comments (`matched`, `offered`, the owner `assigned`) and state comment (`dispatched_at` per column,
   `merge.merged_at`, `merge.done_at`) answers per item and in aggregate (count, median, p90, min, max, in seconds): match to accept, accept
   to merge, match to merge, merge to done, match to done, and the time in each column. Nothing comes from the gateway's memory, so a restart
   changes nothing. One computation reads every item's comments: answers are cached 120 s per query and computed one at a time. The dashboard
   section "Cycle times" loads it when opened. Limits: `dispatched_at` keeps the last dispatch of a column (a column visited twice counts from
   its last visit); items worked before the journal existed have no match or accept time; at most 300 items and 90 days.
w. **Built (2026-10-14), awaiting the owner's review: the plant manager acts on the flow** (`docs/design/plant-manager.md` 10e). The supervisor's
   `manager-action` (`factory.ps1 act`): unpark, release-owner, pin, unpin, requeue, prioritize (labels `priority:top`, `priority:high`; the plan
   offers them first after the pins), rerun-failed (failed jobs only, once per head), drain, resume, restart-session (`session.restart`, the
   client writes the launcher's end marker). Guard rails in code: never merge, approve, record a verdict or clear a hold; the label `hold:owner`
   refuses every action (and a restart of a session that owns such an item); 3 actions per item in 24 hours (in the item state), 3 drains or
   restarts per session name in 24 hours and 30 actions an hour (both in memory); a policy code from `manager.actions.policies` on every
   action, journaled; `manager.mode` `advise` (any unknown value too) turns them off; the operator token can switch it at run time, and a
   graceful restart brings back an `advise`, never an `act`. Once a day `supervisor.summary-due` (`manager.dailySummaryHourUtc`; the day is
   kept in the plant snapshot): the skill sends one summary from `GET /api/v1/metrics` and `act-log` instead of a note per event. Open: not yet
   seen live on tdd; the hourly and per-name counts and the log of actions are in memory (the per-item count is not); `mode: act` and the
   summary hour ship in `config/instance.json`, so the one image carries them to uat and prod; the supervisor's skill and its connect prompt
   changed (owner review).
z. **Done (2026-10-14, issue 93): the journal folds its repeats** (`plugin/scripts/lib/Journal.ps1`, `docs/design/plant-manager.md` 8). 23
   items had filled their 30 journal comments with `matched`, `waiting` and `reassigned` lines while they waited for a worker, and then
   journaled nothing more. A repeat of one of these kinds now edits the comment its kind last posted (the latest line, how often, from when to
   when, the latest 5 lines), as long as only these kinds or `offered` came after it; any other line ends the folds. Only new comments count
   against the cap. The state keeps `journal.kinds.<event>` (count, first, last) and `journal.fold.<event>`. `waiting` lines are written at
   most once per `timing.journalWaitingMinutes` (30). The metrics read the first line of a kind as before (the folded comment keeps the first
   line's marker and time). Open: the items that are already full stay full.
y. **Done (2026-10-14, issue 92): the sweep is throttled and the gateway keeps a GitHub budget.**
   - Before, every webhook with an event and every `complete`, `validation-verdict`, `claim-item`, `accept`, `settle`, `merge` and
     `approve-pr` started a full sweep 2 s later (about 50 REST calls), so a busy plant swept about once a minute. Now a full sweep runs every
     `FACTORY_SWEEP_SECONDS` (180) and, when a trigger asks for one, at most every `timing.sweepMinSeconds` (60, `FACTORY_SWEEP_MIN_SECONDS`;
     never more than the interval). A trigger of one item queues the item: between full sweeps the queued items get an incremental pass
     (`sync-board` with `items`: the same rules for those items, each read by itself, no claim-ref reaping and no QC sync; at most 50, the
     rest stay queued, and the items of a failed pass are queued again). A trigger of no item (master moved, a build of master, a new
     session) and a pull request event (the QC offers and teardowns are made only in a full sweep) ask for a full sweep. The second look at
     new items (sweepSeenCount) is such a pass after 20 s. `/api/v1/status` `sweep`: full and incremental passes, requests, coalesced,
     queued, last of each.
   - Every rule-script answer carries what GitHub said of the rate limit (`_github`, from the `x-ratelimit-*` headers, per resource);
     `Runner` takes it out of the answer and the budget (`gateway/GitHubBudget.cs`) keeps the latest numbers per resource (`core`,
     `graphql`) and window, of the gateway's own identity only (calls made as the reviewer App are not counted). Below
     `github.budgetReserve` (300, `FACTORY_GITHUB_RESERVE`) of a resource whose window has not ended: the full sweep skips its claim-ref
     reaping and QC sync and the back-merge check; the gateway's journal lines, back-merge calls and metrics are not made (a journal line
     is dropped, as any failed one); verbs other than `accept`, `claim-item`, `release` and `my-items` answer 503, exit 20 `github-budget`
     with `retryAfterSeconds` and `resetAt` (an owner told to wait still counts as active). `/api/v1/status` `github`: per resource limit,
     remaining, reset; low; refusals.
   - A 403 or 429 is a rate limit (`github-rate-limited`, exit 20, `retryAfterSeconds` from `Retry-After` or the reset) only when GitHub
     says so: `x-ratelimit-remaining: 0`, a `Retry-After`, or the message of a primary or secondary rate limit; GraphQL's `RATE_LIMITED`
     error too. Any other 403 is `github-forbidden`, exit 30, with GitHub's message (before, every 403 was a rate limit and retried).
   - The fake GitHub sends the rate-limit headers (a limit no suite reaches) and `/_fake/rate` sets what is left.
f. **Cause of the gateway restart at 03:56 UTC on 2026-10-13 on tdd: not confirmed** (the container logs are the operator's). What the
   code allows, and what was fixed, is in "Gateway restarts: what can end the process" below; the operator confirms the cause there.
i. **Worker-to-worker messaging is not yet proven with the owner's own sessions** (it is proven with test sessions).
j. **pwsh crashes (exit 134 or 139) under machine load in the test suites.** Not a product answer, but it costs reruns; find out whether
   it is memory, the runtime or the long-lived client host.
t. **Done (2026-10-14): the Release Queue age** (enhancement 9). The sweep lists the items waiting in the Release Queue (`release_queue`:
   item, release, since); the patrol digest carries `release-queue-aged` when the oldest waits over `timing.mgrReleaseQueueMinutes` (60) or
   `manager.digest.releaseQueueCount` (3) items wait; the operator stream gets one `release.ready` line per release whose items changed
   ("ready to promote <release> to UAT: items ..."); the dashboard's "Request promotion to UAT" button (`POST /api/v1/release-queue/
   promotion-request`, operator token only) records the request in memory and announces it (`release.promotion-requested`). Nothing in
   the gateway promotes: uat and prod stay with the owner and the cmdemo1 session. Open: the supervisor's skill (owner review) does not
   yet say what to do with `release-queue-aged`; not yet seen live on tdd.
k. **The dashboard has never been tested in a real browser**; Tier 1 checks its HTML and its JavaScript render block only.
m. **Done (2026-10-15, #117): the sweep saves no state it read without the item lock.** Settle (`Invoke-SettleLocked`) and the end of a
   wait for checks (`Invoke-AwaitingChecksLocked`) run under the item lock on a fresh read; a lock still busy after 3 s skips the item for
   one sweep. A verb of the same item waits for them at most its own 45 s.
n. **Done (2026-10-14, issue 89): at most `runner.maxProcesses` (6) rule scripts run at once** (`gateway/RunnerGate.cs`). Every call of
   `Runner`, pooled or a process of its own, holds a slot; waiting calls start by class: the sweep, `accept`, `claim-item`, `expire-claim`
   (take-backs) and the gateway's own start and stop calls first (one slot is kept for them), other verbs next, long polls
   (`wait-for-checks`, `metrics`, `publish-demo`) at most half the slots, the journal last. A call that waits too long is answered exit 20
   `runner-busy`: an ordinary or long-poll verb after 2 minutes, a critical call after its own timeout (at most 150 s), a journal line after
   5 minutes; the wait is taken from the time the call may run. `/api/v1/status` shows `runner`: limit, running and waiting by class, peaks,
   refusals, the last starts, and `memory` (the gateway, its live rule-script processes, the container's cgroup current, peak and limit).
   Under saturation two things follow from the order: a webhook whose intake is refused busy is lost (its delivery id is already seen; the
   sweep catches up), and an `accept` that waited its bounded time for the item's earlier journal lines may be journaled before them.
   Open: `runner.pool` is still 0 in the deployed configuration; turning it on is `config/deploy.overrides.json`, a code-owner path (pull
   request for the owner).
d. **The state comment can be edited by anyone with write access; the gateway trusts it by author login only.** A signed state was
   built and taken out again on 2026-10-13 (pull request 22, three review rounds). What a next attempt must have from the start:
   1. one shared guard that refuses every verb that reads the state BEFORE the verb acts on GitHub (claim ref, board move, pull request,
      body, comment): refusing at the save is too late (`validation-verdict` and its demotion, `open-pr`, `append-body`, `complete`);
   2. a state that cannot be verified is never overwritten, never adopted (the `stateAuthors` path) and never shadowed by a new state
      comment beside it; the sweep leaves the item alone and says so once;
   3. a key id in the signature and a previous key accepted for reading, so "signed by another key" (a changed secret, another
      environment's gateway on the same board, `activate-prod.sh`) is told apart from "edited" and a rotation orphans nothing;
   4. unsigned states accepted only when `created_at` and `updated_at` are both before a cutoff, and a deployment order that leaves no
      window in which the old version still writes unsigned;
   5. a decided, documented way for the operator to recover an item (restore the comment, supply the key, or start the item anew).
p. **Flaky check, quarantined, cause not found**: qc suite, scenario "qc: a QC accept and a refused release leave the owner of the item
   alone", check "the owner assignment is still accepted next to the QC one". It failed the first check run of the hotfix of the incident
   below and so lengthened the outage. It is a `CheckQuarantined` (tests/scenarios/lib.ps1): it runs, a failure prints
   `QUARANTINED (failed)` with its detail and is counted under "quarantined failures" in the summary of the suite and of `run-all.ps1`,
   and it does not fail the suite. What is known: in the failed run the plant listed only the QC assignment for the item while `owners`
   still named the owner; the scenario passes locally also with 25 s added before the check, so time alone is not the cause; no claim is
   in the item state at that point (the PASS verdict without `Auto Merge` parks the item and ends the claim), so the owner is then kept
   by the plant's memory only. The one path of `Plant.cs` that removes an accepted own-item assignment without a release or a merge is
   "the session is gone" in the plan (an offer for an item whose assignment was accepted more than 20 s ago); it also drops the owner, and
   a later sweep that still reads the live claim names the owner again. Suspected, not shown: a sweep that read the item before the accept
   was saved and whose plan was applied more than 20 s after it. The check now prints the item's journal: a `reassigned` line in the next
   failure confirms this. Remove the quarantine with the cause.
q. **Item state signing is still open**: entry d. Until then the state comment is trusted by its author login only.

Done on 2026-10-15 (worker sessions carry out their instructions; from 45 worker transcripts of 14 and 15 October):

- **Outside blockers.** No session is held for the base branch: on red checks the worker calls `complete` once and the one CI rule of master
  (`Get-RedHeadRuling`, Prs.ps1, issue 102) re-runs once and, for a master defect, waits for master without counting a round (exit 21 to the
  worker).
- **`factory.ps1 private-build --item N --worktree <path> [--dotnet <path>] [--log <file>]`** (client side, lib/Client.Build.ps1): the host's
  build slot (waited for up to `--slot-wait-minutes`, 30; then exit 21 `build-slot-busy`, nothing built), `DATABASE_ENGINE=SQLite`, the
  dotnet of `ensure-tools.ps1` first on PATH, no credential of the session in the build's environment, `. ./build.ps1 ; Build` with its output in
  `<work>/build-N.log`, the slot given back in finally, answer `{ok, failed[], log, tail}` (exit 10 `build-failed`). Without `--worktree` the name stays free for the push gate's server verb (`private-build --attest SHA`, pull request 61);
  a passing build of a clean worktree on the item's branch attests through it where the gateway has it.
- **`--max-chars N`** on any client verb but subscribe: a longer answer is saved whole to the work directory and printed as one JSON line
  (`ok`, `exit`, `code`, `truncated`, `saved`, the start of the answer in `text`), so a session never pipes a verb (`| head`).
- **Skills**: one bare absolute-path command per factory verb (through the `<BASE>/fw` wrapper when the prompt names one) and a classifier
  refusal is final (comment, release, end the session); no `merge` call after a PASS (`next: "merge"` ends the session); the already-merged
  guard of Functional Testing; evidence from the running app only, and reviews recorded as the reviewer subagent wrote them; the Qodana and
  code-style check before the first push; the reviewer of a design checks every sentence of Notes, Constraints and Out-of-scope and flags a new
  value of a shared enumeration; `Depends on: #M` with a release when a design needs an unmerged item.

Closed on 2026-10-15 (issue #106):

- **#106 Stream sidecar.** The launchers run the session's event stream (`subscribe --own`, from step 7 of the prompt file with the credentials of
  step 4 or the environment) as a sidecar for the session's whole lifetime and append its lines to `<BASE>/work/events.log`; the session's first
  message carries a launcher note: do not start `subscribe`, Monitor `tail -n0 -F` of that file (the first arm from line 1), so a re-arm neither
  registers nor replays. A dead sidecar is started again (not after exit 30 or 40). The client leaves out replayed triggers of items the name no
  longer owns (`worker.registered` now says `owned`) and prints `peers.snapshot` and `supervisor.joined` only when they changed.
  `--sidecar auto|on|off`, `docs/launcher.md`. Open: not yet run live on tdd; batch 3's connect-prompt change (PR 121, owner review) and this note
  must agree on step 7.

Closed on 2026-10-15 (issue #103):

- **#103 Base updates restarted CI on every open pull request.** New setting `baseUpdate.mode`, default `conflict-or-merge`: an owner gets
  `base.updated` only when its pull request has a merge conflict with master (`reason: "conflict"`, also covers the silent wait of #56), and the
  gateway brings a behind branch up to date only right before it merges a PASS (once per verdict). `every-move` keeps the old behaviour (the owner
  suite runs with it; `FACTORY_BASE_UPDATE_MODE` overrides). `docs/design/plant-manager.md` 6a. Open: not yet seen live on tdd.
Closed on 2026-10-15 (issue #102):

- **#102 One CI rule for flakes and pre-existing failures** (about 18 rejected rounds a day, 13 on acceptance shards). Only the gates (`ciGates`)
  decide a head; a red head whose runs completed is re-run once when its failures are non-gate checks, known flaky (`masterFlakyChecks`, now both
  shard families) or failing on master too (`pr.rerun[sha]`, judged on the new attempt); a failure master has as well costs no fix-forward round
  and no demotion, is reported once (comment, operator `plant.event` `master-defect`), and once master passes it again the gateway merges master
  into the branch. A park that ends by expiry or unpark resets `fix_forward_rounds` and `demotions`. `docs/design/plant-manager.md` 10e; scenarios
  `ci rule: ...` (tests/scenarios/cirule.ps1, suites auto and owner). Open: the code-owner documents that list the operator stream's `plant.event`
  codes (`docs/design/operator-session.md`, the factory-operator skill) do not name `master-defect` yet (owner pull request).
Closed on 2026-10-15 (issue #105):

- **#105 Digest noise.** `gateway-restarted` is reported only while an owner has not reconnected (`notReconnected` > 0); what the patrol reported
  (keys, buckets, acknowledged) is carried over a graceful restart in the plant snapshot, so persisting conditions are not new again
  (`gateway/DigestCarry.cs`); a question whose text the same session asked about the same item within `timing.questionDedupeMinutes` (60) and that is
  still open is not relayed again (`202` with the first question's id, `duplicate: true`, `/status` `messaging.questionsDeduped`; it still counts for
  the watchdog's `repeated-question`). The trust-mapping lines are
  unchanged. Open: the supervisor's skill (owner review) does not describe `duplicate`; nothing depends on it.
Closed on 2026-10-15 (issue #101):

- **#101 Busy owners were taken back as quiet** (about 10 items a day, 308, 296 and 310 among them): lease rule 3 counted only verbs and a changed
  summary, so an owner waiting on a long subagent was taken back about 18 min after its last verb. The stream client now watches its machine
  (`plugin/scripts/lib/Progress.ps1`: a progress file `<work>/progress/<N>.txt`, files of the work directory, commits and changed files of the
  item's worktrees, on Linux a build or test process at work there) and sends the latest per owned item with its heartbeat (`progress`, each
  entry's age in seconds); rule 3 counts it like a verb, it renews the lease, and it answers an open `item.check`. An `item.check` that arrives
  anyway is answered by the client itself (`claim-item --renew` with `renewed_by: "client"`) when it saw work within 10 minutes. Progress counts
  only while the session itself was active within `schedule.progressMaxMinutes` (180), so a busy machine cannot hold a stuck session's item for
  ever. `/status` `lease.progress`. `docs/design/plant-manager.md` 6b rule 4.
  Open: not yet seen live on tdd; #83 (renewals that did not reach the lease watchdog) is a separate cause.

Closed on 2026-10-15 (the settle and plant fixes after the overnight run):

- **#87 A code change was moved to Done when its master Build had been re-run** (272, 276). The Release and Architecture workflows start when a
  Build completes and GitHub attaches their check runs to master's head at that moment, so a merge commit whose first attempt failed keeps the
  skipped `release` check of that attempt; settle read it as docs-only. Docs-only is now decided from the merge commit's own Build
  (`masterCodeChecks`, the jobs that run only for code: all skipped means docs-only) or else the pull request's files, and recorded as
  `merge.docs_only` with `docs_only_from`; only then may a skipped or missing release check finish an item. The master-green verdict ignores
  `masterIgnoredChecks` (`release`, `packages`, `architecture`), which could also park an item master-broken.
- **#100 A blocked session kept winning items.** Its stream client accepted every offer by itself, which reset the session's missed offers,
  and the take-back five minutes later counted as nothing. Now the client's own accept (`accepted_by: client`) is no answer, every take-back is
  a miss, and `timing.offerMissLimit` (2) misses in a row with a take-back among them block the session: it is offered nothing, pinned items
  included, until it calls a verb of its own or a new session of the name registers (a reconnect of the same session keeps the block). Lapsed
  offers alone still give the timed cool-down. A block is a `session-blocked` plant event on the operator stream and a `session-blocked` entry
  of the patrol digest (worker, item, `blockedMinutes`); `/status` shows `blocked`, `blockedSince` and `takenBackInRow` per worker and
  `sessionsBlocked`. QC environments are not part of the rule (they run outside the model session). Open: the supervisor's and operator
  session's skills and `docs/design/operator-session.md` (owner review) do not list the new digest kind and the plant event codes
  `session-blocked` and `session-unblocked`; the block is in memory and a restart forgets it.
- **#107 The owner session idled from the merge to the Release Queue.** The owner was kept until `item.complete` (master green, release,
  production), doing nothing while the gateway settled the item, so its session was neither free nor told to end. Now the owner hears
  `item.merged` and is released at once (`Plant.Merged`, also on the merge verb and the gateway's merge after a PASS); the Sweeper no longer
  keeps the owners of settling items. The spent session gets `session.end` after `timing.sessionEndGraceSeconds` and settle carries the item.
  The owner skill says the item ends for the session at `item.merged`.
- **#109 `hold:owner` was ignored** (296). A setting `holdLabels` (default `["hold:owner"]`) is honoured like `Demo`: the sweep offers nothing
  for an item that carries one (its open offer is dropped at the next plan), its PASS is not merged (`merge` answers exit 10 `held-by-label`,
  the gateway's merge waits), and `claim-item` (so `accept` and a live owner's `--renew`, whose lease then lapses as with `Demo`) answers exit 10
  `held-by-label`. A merge the person makes is still picked up and settled. Remove the label to hand the item back.
- **#114 (and #70, #77) The settle state was erased on a master-broken, master-green-timeout or late release-candidate park** (262 and 280
  stranded closed in Functional Testing, 276 and 272 validated again after their merge). The wait now stays (`merge.awaiting` `master-broken`
  or `master-timeout`, with the park for a person) and settle keeps polling: the item goes on once the merge commit's latest attempt, or a
  later master commit that contains it (compare: ahead or identical, at most `timing.masterContainsLookback` (10) commits back), is green
  (`merge.green_via`); the late release-candidate search keeps looking after `lateReleaseCandidateHours` and says so once. An item with
  `merge.sha` is never offered to a worker: the sweep re-arms a settle state an older gateway erased (journal `settle-rearmed`; closed items
  too, instead of only removing their park), an unpark re-arms it and hands nothing off (`reoffer` false, `awaiting` in the answer), and the
  merge verb's already-merged path keeps the original record and `merged_at`. `POST /api/v1/items/{n}/resettle` (operator token, a reason)
  puts a finished merged item back into the settle step, for an item a person reopened because no release carried it. No auto-revert.

- **#117 Two sweep passes moved an unmerged item to the Release Queue** (290: Development, Functional Testing, Release Queue 5 s apart, its
  pull request unmerged). Settle and the end of a wait for checks run under the item lock on a fresh read (entry m). A card is moved only
  from the column the step expects: the wait for checks ends without a move when the card left the column it began in
  (`awaiting_checks.column`), and settle moves a card to the Release Queue only from Functional Testing. An open Release Queue card without a
  merge record is flagged once (journal `flagged`, code `release-queue-without-merge`, and a plant event on the operator stream); nothing
  moves it.

w. **Built, off (2026-10-15): the cloud worker runtime adapter** (`docs/design/cloud-worker-runtimes.md` phase 3; `gateway/Runtimes/`,
   `gateway/Plant.Runtimes.cs`, credentials in `gateway/Auth.cs`). An item labelled `runtime:cae-job` (or matched by `runtimes.routing`) is
   given to a new execution of the Container Apps job `runtimes.caeJob.jobResourceId`, started through ARM with the gateway's managed identity
   (package `Azure.Identity`); the execution redeems a one-time nonce for a `w2` credential, registers as `cae-<item>-<6 hex>` and is offered the
   item with `runtimes.caeJob.ackSeconds`. Capacity, a daily budget, health, take-back of failed executions, park `runtime-failed` after
   `maxFailuresPerPhase`, re-list at start, `/api/v1/status` and dashboard block `runtimes`, span and metric `fworker.runtime.executions`. The
   operator marks an unhealthy runtime healthy again with `POST /api/v1/runtimes/cae-job/reset`. Every `runtimes.*` setting is off in
   `config/instance.json` (smoke check). Open: the job, its identity and the Foundry deployment (rollout step 2), the runner image, the real job
   resource id in `config/deploy.overrides.json`, and a live proof on tdd; unredeemed nonces are lost at a gateway restart (that execution
   fails its redemption and is replaced).
- **#108 Build slots were freed only by their release or their ttl** (30 min). Now an item's slots go when it is taken back, released or
  completed and whenever its owner is dropped, and a name's slots go when it is revoked, when its session is told `session.end`, and when it
  stays disconnected for `schedule.buildSlotDisconnectSeconds` (120). `/status` `hosts.buildFreed` counts them; each free is one log line
  (`"buildSlot":"freed"`) with its reason.

Closed on 2026-10-15 (issues #79 and #82):

- **#79 A flaky master Build parked merged items as master-broken** (276, 272, 280). The settle step asked GitHub to re-run the failed jobs
  while the Build run was still in progress (GitHub refuses that; the answer was ignored), then parked the item a minute later. Now it waits
  until every workflow run of the merge commit has completed, re-runs the failed ones once, records the runs and attempts (`merge.rerun_runs`,
  `rerun_at`) and judges only a newer, completed attempt; the master-green timeout counts again from the re-run. The comment says whether the
  failure looks flaky (`masterFlakyChecks` patterns, or the same check failed on one of the last 5 master commits). The fake GitHub now lists
  workflow runs per commit and refuses a re-run of a run in progress, as GitHub does.
- **#82 A closed item stayed parked.** The sweep removes the park of a closed item whose flow has ended (journal `unparked`, by the sweep), and
  `POST /api/v1/items/{n}/unpark` accepts a closed item, removing only the park (no hand-off, no offer). Released parks leave the digest's
  parks list at once.

Closed on 2026-10-15 (issues #80, #81 and #74):

- **#80 An operator drain was lost when the name's next session registered.** The operator's drain (`POST /api/v1/workers/{name}/drain` with
  the operator token) belongs to the name: it holds across reconnects, new sessions and a graceful restart (the plant snapshot carries
  `drained`) until the operator resumes the name. A session's own drain (end-session) stays the session's, so the launcher's next session is
  offered work; a session cannot lift the operator's drain.
- **#81 An owner whose assignment event was lost was never told about its item again** (274). Every registration of a name, a new session
  included, and the snapshot restore resend `item.assigned` (mode `resume`, `resent: true`, `accepted: true`) for each accepted own-item
  assignment of an item the name still owns. The client saves the token and does not accept or spawn for it; the owner skill says what to do.
- **#74 An accepted assignment outlived its dropped owner.** Where the sweep drops an owner it no longer lists, the owner's accepted
  own-item assignment goes too, so "accepted" means "owned" and a dropped owner is never resent a finished item.

Closed on 2026-10-14 (issue #42):

- **#42 A video item could not pass Functional Testing without a person.** `factory.ps1 publish-demo --item N --file <mp4>` (item token,
  owner role) streams the MP4 as the raw body of `POST /api/v1/demo/{item}`; the gateway writes it to a temp file (at most 100 MB, must
  start with an `ftyp` box), then the rule verb `publish-demo` creates release `demo-N` if missing (pre-release, default branch, "Demo video
  for #N") and uploads or replaces `demo-N.mp4` with the author App (contents: write), and answers the release URL and size. Allowed in
  Development and Functional Testing on items with the `video` label. Not through `/api/v1/verbs` (that route pipes JSON text to the
  script; Kestrel's default body cap is about 30 MB). The owner's right comes from `validation-verdict` until `publish-demo` is listed in
  `Auth.OwnerVerbs` (separate pull request, needs the owner).

Closed on 2026-10-13 (pull request "hardening"):

- **Three more checks that read too early on slow runners** (each failed once in that pull request's own check runs; scenarios only, the
  product was right): messaging "a message never changes an item" took its first reading between the journal comment and the state save;
  owner "journal: matched, offered, assigned" read the journal before the gateway had written `offered`; qc-gate-lease "the plant holds no
  QC assignment" read the plant before the failing call had returned. Each now waits for the condition.

- **(c) One revocation ref per name, paging reader.** A revoke writes the higher generation, reads it back, then removes the name's lower
  refs; a removal that fails leaves a ref and nothing else (the reader takes the highest). The reader read pages until one was empty:
  that was the cause of the incident of 2026-10-13 below, and it now also ends on a page that brings nothing new and after 200 pages.
- **(d, first half) Fast path fallback.** The body marker counts only for items created before `timing.docsOnlyLegacyBefore`
  (2026-10-16T00:00:00Z; it depends on nothing that is deployed, so there is no deadline). `.cursor/` is no longer documentation; a
  finding's quote ends at the first separator; the fake GitHub uses the product's `docsOnlyPaths`. The editable state comment is open:
  entry d below.
- **(e) Dashboard**: an answer that arrives after Disconnect is dropped; Disconnect and a refused token clear every section and hide QC; a
  refused token is forgotten, so the timer stops asking until the next Connect.
- **(g) Slow first pickup: found.** tdd's webhook is a repository webhook (`create-webhook.sh`: issues, workflow_run, pull_request,
  pull_request_review); a card moved on the board is a `projects_v2_item` event, which only an organization webhook or an App delivers, so
  the gateway never hears of the move. And an item new in a column is offered by the SECOND sweep that sees it (`timing.sweepSeenCount` 2,
  so a card dragged across starts nothing): up to two intervals, 6 minutes at 180 s. That is the wait seen, and the sweep "that did not
  match" was the first look. Fixed: after a sweep that saw such an item a pass over it runs 20 s later (`FACTORY_SWEEP_CONFIRM_SECONDS`; an incremental pass since issue 92), so
  the first offer comes at most one interval plus 20 s after the move. To make it seconds: deliver `projects_v2_item` (organization
  webhook); the gateway already turns it into a sweep.
- **(h) `factory.ps1 update-pr --item N --body-file <file>`** replaces the body of the item's own open pull request (item token, owner role),
  only while the item is in Development (`wrong-column` afterwards).
- **Manager suite, "dashboard Sessions panel" check, flaky on slow runners: a test order assumption** (closed in the follow-up of the
  incident). The check wanted the scenario's worker as the first row of the Workers group. A client that an earlier scenario of the same
  group left running connects to the scenario's second gateway as well (same port) and is then listed first; the failed run shows such
  a row before the expected one. The check now accepts other rows before it.
- **(l) Manager suite, revoke scenario, flaky on slow runners: a test order assumption.** The scenario's second gateway reads the fake
  GitHub, so its start-up sweep plans the whole board; when that sweep ended between the session's second registration and the scenario's
  own plan, another item was offered first and the session (capacity 1) was not offered the expected one. The scenario now waits for the
  start-up sweep before a session connects and reads the offer of its own item. Reproduced with `/_fake/latency` (fails before, passes after).
- **qc-gate suite, flaky on slow runners: a product defect, now fixed.** "requireRun false: the missing person approval stops it" answered
  `approval-missing` once. The sweep's QC step (`Invoke-QcSync`, Qc.ps1) read the item state without the item lock, posted the two offer
  comments, then saved the state it had read: an inspector approval recorded in between was lost, and `merge` then rightly said that no
  approval was recorded. The sweep now writes only its journal line, under the item lock on a fresh read (`Save-JournalKeys`,
  Journal.ps1). A scenario holds the offer comments back with `/_fake/latency` and records the approval in between. The order of the
  merge gate is unchanged and deterministic: recorded inspector approval, approval on GitHub, QC run, person's approval. Same pattern
  elsewhere: entry m.

Closed on 2026-10-14 (operator-session notes in the inbox, stream lines whole):

- **Operator-session notes and the inbox.** The gateway already stored them like operator notes (`Plant.SendMessage` delivers every
  message with `Operator` set, the operator's and the operator session's alike, into each recipient's inbox); nothing in the client, the
  skill or the scenarios said or proved it. The peer-messaging skill now says it (handle once, `ack`), `docs/design/worker-messaging.md` 3.4
  states it, and scenarios of the operator suite prove it: a worker offline at the send, a note to all, `--from-message`, an answer.
- **Stream lines arrive whole.** The Monitor of Claude Code shows at most 500 characters of one line (measured: 500 arrive, 501 end in
  `...(truncated)`); a message line was up to about 1,650 characters, and over 500 with a two-letter text for every sender but the
  operator (the long warnings come before the text), so a session saw the warning and little or none of the text, and the supervisor saw
  part of the first question of a batch. Every stream line now fits `FACTORY_STREAM_LINE_MAX` (500): a message keeps a short warning and
  its text is cut with `truncated` and `read` (`factory.ps1 inbox --id <id>`); a batch, a patrol or another event that does not fit says
  so and names the command that reads it whole (`docs/design/worker-messaging.md` 5.2). `inbox` and `wait-event --messages` stop at about
  24,000 characters (`more`). Open: the operator skill (code-owner path, another pull request in flight) does not yet mention that a long
  `operator.inbox` line is cut; the line itself names the command (`read`).

### Flaky qc-gate-lease scenario (fixed 2026-10-14)

Cause: the QC lease was renewed only when a verb of the worker had finished (accept, qc-progress, qc-report), so a worker whose verb was still
running counted as silent for the whole verb. With the suite's 6 s lease and verbs of 3.4 to 5.4 s on hosted runners, the sweep relaunched an
environment whose worker was answering, and the next report got stale-assignment (exit 11). Reproduced locally by slowing the client 5.2 s
between verbs. Fix: the gateway renews the lease when a verb of the current QC assignment arrives (`Qc.Arrived`), and the scenario lease is
18 s (qcLeaseMinutes 0.3). The grace suite had the same shape (a Reset verb had to land inside 6 s) and now uses 15 s.

### Gateway restarts: what can end the process (entry f)

Every start prints `started` in `/_build`. Since this change the console log says how a process ended; read the last lines before the
new start in the Container Apps console log, and the system log of the revision at that time.

| Cause | In the code or platform | How to confirm |
|---|---|---|
| Scale-in (tdd and uat scale to zero) or a replica move | The platform's HTTP scale rule decides; whether an open event stream counts as a request for it is not visible in this repository. A new revision or a node drain does the same | Console log ends with `"gateway":"stopping"` (with `upSeconds`); the system log has a scale, revision or replica event at that time. If streams do not count, set a minimum of one replica for tdd (operator, the demo-environment kit) |
| Out of memory | One `pwsh` per rule-script call, at most `runner.maxProcesses` at once since issue 89 (entry n); `/api/v1/status` `runner.memory` shows the container's current and peak | No `stopping` and no `unhandled-exception` line before the new start; the system log says OOMKilled or exit code 137 |
| A probe failing | `/health` and `/alive` answer 200 from the first moment and wait on nothing; `/ready` is 503 until the revoked credentials are read (each read has 45 s, a failed one is tried again after 5 s doubling to 60 s; after 3 minutes one `"level":"error"` line with `"waitingFor":"revocations"`). `/ready` must not be the liveness probe | The system log shows failed probes, then a restart; the console log has `stopping` |
| An unhandled exception | Fixed here: the sweeper let a cancellation that was not the shutdown escape (the default of .NET then stops the host); the runner pool's exit handler ran unguarded. A background service that throws no longer stops the host | A `"gateway":"unhandled-exception"` or `"unobserved-task-exception"` line, or a `crit:` line of the host |

HTTP 503 after any start is by design: no worker, supervisor or item credential is answered until the revoked credentials are read (a
request waits up to 20 s, then 503 `starting` with `retryAfterSeconds`). The operator token does not wait. A start that stays there is a
defect to act on: `/ready` says what it waits for and how many reads failed.

### Incident of 2026-10-13: release 1.0.58 never became ready on tdd (18:09 to 18:58 UTC)

- **What.** After the release `/ready` answered 503 `starting` and no worker, supervisor or item credential was accepted for 49 minutes.
  `/health` stays 200 in that state, so liveness alone did not show it.
- **Cause.** The reader of the revocation refs (`Get-RevokedRefs`, plugin/scripts/lib/Owner.ps1, the paging reader of pull request 22) asked GitHub's
  `git/matching-refs` for page after page until one came back empty. GitHub takes no page number there: it answers the same refs every
  time, so the loop never ended, every read ran into its time limit and was started again.
- **Why the tests and the review missed it.** The fake GitHub did page that endpoint, so the scenario of the paging reader passed against a
  behaviour GitHub does not have. The review read the reader against the fake's behaviour too. Nothing checked `/ready` after the release.
- **The fix.** Hotfix (pull request 26): the reader ends on an empty page, on a page that brings nothing new, and after 200 pages. Its own
  first check run failed on an unrelated flaky check (entry p), which lengthened the outage. Follow-up: the fake answers every ref on
  every page as GitHub does (it pages only for the scenario that asks, `/_fake/ref-page`); a scenario starts a gateway against more than
  100 refs on the non-paging fake and fails on the reader of 1.0.58; the read at start has a time limit per attempt, backs off, logs one
  error line after 3 minutes and `/ready` says `waitingFor: revocations` with the number of failed reads; a scenario covers a GitHub that
  does not answer. The gateway still does not fail open.
- **The lessons.** (1) A release is done when `/_build` shows the new version AND `/ready` is 200, not before (`CLAUDE.md`, Release).
  (2) The fake must behave like GitHub wherever the product depends on GitHub's behaviour: before relying on paging, ordering, a status
  code or a limit of an endpoint, check GitHub's documentation or the real answer, and make the fake do the same by default.
- **Same pattern elsewhere.** `Verb_operator_releases` (plugin/scripts/lib/OperatorRelease.ps1, a protected path) pages the same endpoint
  and stops on a page of fewer than 100 rows or after 10 pages. With 100 or more release refs of one day GitHub would answer the same
  list ten times: nine wasted calls, no endless loop, and the count stays right because a pull request is counted once. Left as it is;
  the owner may bound it like the revocation reader.


Smaller, known: the Octopus project's uat and prod run older versions than tdd until the operator promotes; `docs/deploy/MORNING.md` and
`runbook-add-deployable.md` are records of 2026-10-11 and describe paths that no longer exist; `tests/live` and `tests/fullrun` have not
been run from this repository layout.

## 6. A live proof on tdd

Needs `FACTORY_OPERATOR_TOKEN` and `GH_TOKEN` (section 2). It changes the real board and merges a real documentation change into
cmdemo1-workorders: use documentation-only items, and add the label `factory test` for the cheapest model profile.

1. tdd is healthy and runs the version under test: `/_build`, `/ready`.
2. The plant is quiet: `GET /api/v1/status` shows no owner and no accepted assignment you do not expect.
3. A worker is connected. Either the owner starts one, or write a connect prompt to a private file outside any repository:
   `FACTORY_OPERATOR_TOKEN=... docs/deploy/gen-connect-prompt.sh tdd <name> claude-cloud 1 <out-file>` (type `supervisor` for the
   supervisor's prompt), and paste the file into a new session. The file holds a credential: never commit, print or post it; delete it
   afterwards. A name whose credential is no longer wanted is revoked from the dashboard.
4. Create the item: `pwsh tests/fullrun/create-item.ps1 -Title "..." -BodyFile body.md -Label 'factory worker','Auto Merge','factory test' -HandOver`
   (needs `gh` signed in). The body names the file, the exact text and the acceptance criteria. Check the text against the unit tests of
   the work-orders repository first: a documentation change can break a test that reads the file.
5. Watch: `GET /api/v1/status` (the assignment is accepted, then the owner appears), the traffic and the questions, the item's comments
   and its pull request. For messaging, give two workers items that touch the same file and read the notes they exchange.
6. Pass: the pull request is merged by the author App, the item is closed and its card is in Done, no 5xx in the traffic, no item
   left waiting, and (docs-only) about 10 minutes from hand-over to merge.
7. Record the result in section 4 and the defects as issues in this repository.

## 6a. Starting the operator session

The role is on in the deployed image (`operator.enabled` in `config/deploy.overrides.json`); the source default is off.

1. Write its connect prompt to a private file outside any repository:
   `FACTORY_OPERATOR_TOKEN=... docs/deploy/gen-connect-prompt.sh tdd operator-session operator - <out-file>`, or use the dashboard
   ("Connect a new session", kind "Factory operator"). The file holds a credential: never commit, print or post it.
2. Paste it into a new Claude Code session that runs on Opus at low effort. The session needs two secrets and no other:
   - its operator session credential, which is in the prompt (`FACTORY_OPERATOR_SESSION_TOKEN`). It is not the operator token: it
     cannot mint or revoke credentials, and the gateway admits it only at the endpoints listed in the design;
   - a GitHub connection that can push branches, open issues and pull requests and merge pull requests in `cmdemo1-fworker`.
   It does not get the operator token, the Octopus key or any GitHub App key.
3. The prompt clones this repository, has the session read `CLAUDE.md` and this file, and hands over to
   `plugin/skills/factory-operator/SKILL.md`. The dashboard shows it in the group "Factory operator" with its model check and the
   self-merged releases of today against the limit (`operator.maxSelfMergesPerDay`, 12).
4. To stop it: revoke the name `operator-session` on the dashboard, or switch messaging off (both act at once). To stop the role: set
   `operator.enabled` false in the overrides. Its GitHub connection is removed on GitHub.

Enforced by the gateway: where its credential is admitted; that its notes and answers carry its own name and kind, never the
operator's; the limits on its notes and budget grants; the quiet-plant check (a question it answered itself does not count as quiet
for ten minutes); the daily limit; the release records. By the session's skill only: everything about the merge (green checks, review,
protected areas, announcement, verification, rollback, recording), because merging happens on GitHub. For real enforcement there the
owner sets (`docs/design/operator-session.md` section 5):

- done 2026-10-13: `.github/CODEOWNERS` and a ruleset of the default branch that requires a code-owner review for those paths;
- for the session's GitHub account: one that is not an organization admin (an admin can bypass the ruleset) and has no bypass right;
- no push access for that account to the work-orders repository (`cmdemo1-workorders`): the session improves the factory, it never
  works on the application.

## 7. History in one paragraph

2026-10-10: plugin, rule scripts and a local gateway; ten trial items. 2026-10-11: owner sessions, plant manager, dashboard, PR QC
environment, 30-item live run; the gateway became the container deployable `fworker` of cmdemo1 and went live in tdd; first cloud worker.
2026-10-12: worker messaging and the supervisor (eleven steps of the design) live in tdd 1.0.31; fix release 1.0.35 (pins wait for their
worker, 120 s accept window, operator revoke). 2026-10-13: team test with three cloud sessions; 1.0.37 (docs-only fast path, operator
reaches every session, clearer dashboard, ordered journal); the source moved into this repository.
