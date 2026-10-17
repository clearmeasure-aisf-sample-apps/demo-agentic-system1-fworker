# Environment test factories: a gateway that owns every role, in tdd, uat and prod

Status: design, not built (2026-10-16). Owner decisions of 2026-10-16 (Jeffrey) are fixed and listed in section 1. Builds on
`docs/design/cloud-worker-runtimes.md` (the runtime adapter and the Codex Container Apps jobs), `docs/design/plant-manager.md`,
`docs/design/operator-session.md` and `docs/design/backlog-keeper.md`. Diagrams: `docs/design/diagrams/etf-*.puml` and their SVG renders.

## 0. Summary

The frame: **the gateway owns every role of execution and starts each one on demand in the cloud.** No role depends on a local session. Today
a worker, the supervisor (plant manager), the operator session, the backlog keeper and the owner's own supervising session are long-lived AI
sessions that a person starts on a machine (omarchy tmux, a Claude Code session). After this design each is a short cloud run that the gateway
starts when a condition or an event asks for it, that does one job and exits, and that scales to zero when nothing asks. Local sessions remain
possible, as optional clients with the same credentials, and nothing waits for them.

On that frame, three gateways run side by side, one per environment (tdd, uat, prod), on the same work-order repository
(`clearmeasure-aisf-sample-apps/cmdemo1-workorders`), each with its own board, its own `env:<env>` label, its own claim refs, its own branch
prefix and its own Codex jobs. tdd and uat test the gateway itself with a **synthetic test catalog**, seeded on demand; there a PASS ends the
item without a merge. Only prod merges to `master`. Code, not instruction, enforces each separation, and Tier 1 scenarios prove it.

1. Every factory item carries `env:tdd`, `env:uat` or `env:prod`; a gateway acts only on its own; unlabelled items are nobody's (section 3).
2. A board per environment, set by environment variables, never baked into the image (section 4).
3. `mergePolicy` per environment, `none` outside prod by default; PASS under `none` closes the PR and ends the item (section 5).
4. Every role runs as a Container Apps job execution started by the gateway on a trigger; the gateway's code holds what must be deterministic (sections 7 to 9).
5. A test catalog of twelve scenarios, a seed verb and a catalog report (section 6).
6. Start/Stop per environment, deterministic dispatch closest to Done first (16); an Owner actions panel and an MCP server at `/mcp` over the
   same endpoints (17, 18).

## 1. Owner decisions (2026-10-16, fixed)

1. One work-order repository for all three environments: `clearmeasure-aisf-sample-apps/cmdemo1-workorders`.
2. Every factory item carries exactly one environment label, `env:tdd`, `env:uat` or `env:prod`. A gateway picks up only items labelled for its
   own `FACTORY_ENVIRONMENT`; an unlabelled item is picked up by nobody. The existing open factory items are labelled `env:prod` (migration, 12).
3. Each environment has its own GitHub project board with the columns of board 679; 679 stays prod's. The board id is a setting per environment.
4. Only prod merges to `master`. In tdd and uat a PASS ends the item: record PASS, comment "<env> run complete, not merged by policy", close the
   pull request, delete the branch, move the card to Done.
5. Test work in tdd and uat is a synthetic test catalog, run on demand, re-run as the gateway's regression suite.
6. Workers in tdd and uat are cloud jobs only (each environment's own Codex Container Apps jobs); no local sessions.
7. The plant manager and the operator run as cloud jobs too, per environment, with that environment's tokens.
8. (Widened the same day) Everything is on demand and none of it relies on a local session: the gateway provisions every role (workers, plant
   manager, operator, backlog keeper) in all three environments, prod included, and starts each on a trigger.
9. (Same day) No stand-in owner role. The plant manager unsticks, merges green pull requests within policy and keeps things moving.
10. Start factory and Stop factory buttons per environment, admin-authenticated; Start begins a plant-manager run that dispatches closest to
    Done first; Stop drains; the running or stopped state survives a restart (section 16).
11. The owner's interventions become deterministic Owner actions on the dashboard, with no model, each journaled (section 17).
12. Every Owner action is also an MCP tool of the gateway and a CLI verb: one endpoint, three surfaces (section 18).

## 2. The three environments

| | tdd | uat | prod |
|---|---|---|---|
| Purpose | Test of each new gateway build (every merge to fworker `master` deploys here) | Test of a promoted build before prod | The factory that delivers work orders |
| Items it acts on | `env:tdd` | `env:uat` | `env:prod` |
| Item source | the test catalog (seed verb) | the test catalog | people and the backlog keeper |
| Board | its own (`cmdemo1 factory tdd`) | its own (`cmdemo1 factory uat`) | 679 |
| `mergePolicy` | `none` | `none` | `auto` |
| Settle, Release Queue, Octopus delivery | off | off | on |
| Instance name (`name`) | `factory-worker-tdd` | `factory-worker-uat` | `factory-worker` (unchanged) |
| Branch prefix | `factory-worker/tdd/` | `factory-worker/uat/` | `factory-worker/` (unchanged) |
| Codex jobs | `caj-cmdemo1-tdd-fwrunner-codex`, `caj-cmdemo1-tdd-fwrole` | `caj-cmdemo1-uat-fwrunner-codex`, `caj-cmdemo1-uat-fwrole` | `caj-cmdemo1-prod-fwrunner-codex`, `caj-cmdemo1-prod-fwrole` |
| Model | `gpt-6.1-sol` in `aif-cmdemo1-tdd` | `gpt-6.1-sol` in `aif-cmdemo1-uat` | `gpt-6.1-sol` in prod's own Foundry resource |
| GitHub App installation | its own App (section 10) | its own App | its own App |

The rule "only one gateway may sweep the board" (CLAUDE.md) becomes "only one gateway per board and per label". prod stops being inert when
`docs/deploy/activate-prod.sh` runs; that script no longer makes tdd inert, because tdd then acts only on `env:tdd` items and its own board.

## 3. The environment label

### 3.1 Rule

A setting `environment` (from `FACTORY_ENVIRONMENT`, already read by `gateway/Program.cs` and `gateway/Messaging.cs`; default `tdd`) gives the
label `env:<environment>`. An item is **in scope** when it has the factory label (`label`, "factory worker") AND exactly one `env:` label AND that
label is the gateway's. An item with two `env:` labels is out of scope for every gateway and gets one journal line from each gateway's board
guard ("conflicting environment labels"), once.

### 3.2 Where it is enforced

One function, `Test-ItemInScope($labels)` in `plugin/scripts/lib/Board.ps1`, used at every entry point that today tests `$c.label` alone:

- `Verb_sync_board` (Verbs.Sweep.ps1, the item loop at the `$c.label` test), so the sweep never plans, offers, settles or unparks another
  environment's item;
- `Invoke-BoardGuard` (the open-issues query), which also stops it from moving cards of out-of-scope items;
- `Verb_ingest_event` (the `labeled` and the check-run branches), so a webhook about another environment's item makes no event;
- the item verbs that act on GitHub (`claim-item`, `accept`, `open-pr`, `complete`, `validation-verdict`, `merge`, `settle`, the manager and keeper
  verbs): a shared guard at the top of the verb dispatch refuses exit 10 `out-of-scope` before anything is written. This is the "refuse before
  acting" rule of backlog entry d.1 applied to scope;
- the gateway's `/api/v1/items/{n}/...` endpoints, which call those verbs.

A label removed while a claim is live: the next sweep sees the item out of scope, releases the claim as `out-of-scope`, ends the offer and
leaves the card alone. Changing an item's environment is therefore remove-then-add, and the new gateway starts it from its state comment
(section 4.3 says why it cannot see the old one).

### 3.3 Labels on new items

The seed verb (6.3) and the keeper's `create-item`/`split-item` set the gateway's own `env:` label; the keeper verb refuses a request that names
another environment (`env-mismatch`). A person who creates a prod item adds `env:prod` (the issue template of cmdemo1-workorders gets the label
as a default; a change to that repository, section 14).

## 4. Board, instance, refs and branches per environment

### 4.1 Settings, from the environment, never baked

`config/deploy.overrides.json` is merged into the one image that is promoted tdd to uat to prod; any environment value in it is wrong in two of
three environments. Today `runtimes.caeJob.jobs` and `gatewayUrl` are tdd's in that file. The design moves every environment value to
environment variables of the container app, set per environment by the demo-environment kit (Octopus project variables scoped by environment),
read by one loader, `gateway/EnvironmentSettings.cs`, applied over the merged configuration before anything else reads it:

| Variable | Overrides | Example (tdd) |
|---|---|---|
| `FACTORY_ENVIRONMENT` | `environment` (new) | `tdd` |
| `FACTORY_BOARD_PROJECT` | `project` | the number of the tdd board |
| `FACTORY_INSTANCE_NAME` | `name` (claim refs, state marker, journal marker) | `factory-worker-tdd` |
| `FACTORY_BRANCH_PREFIX` | `branchPrefix` (new; default `name`) | `factory-worker/tdd` |
| `FACTORY_MERGE_POLICY` | `mergePolicy` | `none` |
| `FACTORY_DELIVERY` | `delivery.enabled` (new: settle, Release Queue, Octopus) | `0` |
| `FACTORY_RUNTIME_CAEJOB_JOBS_CODEX` | `runtimes.caeJob.jobs.codex` | `/subscriptions/.../jobs/caj-cmdemo1-tdd-fwrunner-codex` |
| `FACTORY_RUNTIME_CAEJOB_MI_CLIENT_ID` | `runtimes.caeJob.managedIdentityClientId` | the tdd launcher identity |
| `FACTORY_RUNTIME_CAEJOB_GATEWAY_URL` | `runtimes.caeJob.gatewayUrl` | `http://ca-cmdemo1-tdd-fworker` |
| `FACTORY_RUNTIME_ROLEJOB_ID` | `runtimes.roleJob.jobResourceId` (new, section 8) | `/subscriptions/.../jobs/caj-cmdemo1-tdd-fwrole` |
| `FACTORY_APP_<KIND>_ID`, `_INSTALLATION`, `_SLUG`, `_KEY` | the GitHub Apps (exists, `Apps.ps1`) | |

These variables are new except `FACTORY_ENVIRONMENT` and the `FACTORY_APP_*` ones. Rules of the loader: the gateway refuses to start (a clear message, `/ready` never 200) when `FACTORY_ENVIRONMENT` is set but
`FACTORY_BOARD_PROJECT` or `FACTORY_INSTANCE_NAME` is missing, when the environment is not prod and `FACTORY_BOARD_PROJECT` is 679, when it is
not prod and the instance name is `factory-worker`, or when it is not prod and `FACTORY_MERGE_POLICY` is anything but `none`. The values that
leave `config/deploy.overrides.json` are removed from it in the same change (a code-owner path). `GET /_build` adds `board`, `instance` and
`mergePolicy` so a check with no credential sees what a gateway acts on.

### 4.2 Boards

Two new organization project boards, `cmdemo1 factory tdd` and `cmdemo1 factory uat`, created by copying 679 (GitHub's "copy project" keeps
fields, the Status options and views, not items), so the columns match exactly. `Get-ProjectMeta` already reads the Status options by name
from `$c.project`; it caches them in `project-meta.json` under the state directory, which is per container and so per environment. An item is
added to its environment's board only (`Add-ToBoard` with `$c.project`). Each board gets its own repository-level webhook target, or one
organization webhook per gateway filtered by project number in `Verb_ingest_event` (`projects_v2_item` events carry the project node id).

### 4.3 Claim refs and state per environment

Everything named by the instance name becomes per environment by giving each its own `name`:

- `refs/factory/factory-worker-tdd/claims/<n>`, `.../revoked/...`, `.../plant-snapshot`, `.../operator-release/...`;
- the state marker `<!-- factory-state:factory-worker-tdd v1 -->` and the journal marker: a tdd gateway never reads or writes prod's state
  comment, and `stateAuthors` adoption is limited to the gateway's own marker;
- prod keeps `factory-worker`, so its refs, states and in-flight items are untouched by the rollout.

Revocations are per environment by the same rule: a credential revoked in tdd is not revoked in prod, which is right, because credentials are
minted per environment with each environment's `FACTORY_TOKEN_SECRET`.

### 4.4 Branches and pull requests

`branchPrefix` (default `name` for the existing behaviour) gives `factory-worker/tdd/<n>-<slug>`, `factory-worker/uat/<n>-<slug>` and, for
prod, the unchanged `factory-worker/<n>-<slug>`. Every place that builds or matches a branch uses it (`Prs.ps1`, `BaseUpdate.ps1`,
`Verb_ingest_event`). The matching is tightened at the same time: `Prs.ps1` falls back to any branch matching `/<n>-` when none has the
prefix; that fallback is limited to branches that carry no other environment's prefix (prod's `^factory-worker/(?!tdd/|uat/)`), so a
tdd branch is never taken for a prod item; the same tightening applies to the loose `/$Item-` match of the PR-belongs check (Prs.ps1). Setting
`FACTORY_INSTANCE_NAME` alone would turn branches into `factory-worker-tdd/...`; `FACTORY_BRANCH_PREFIX` is therefore required outside prod. Issue numbers are unique in the repository, so the prefix is a second line of defence, not the
only one. Pull request titles start with `[tdd]` or `[uat]` outside prod (people reading the repository see at once what is a test), and the
pull request carries the item's `env:` label.

## 5. Merge policy: only prod merges

### 5.1 The setting

`mergePolicy` has `auto` and `peer-approved` today and gets a third value, `none`. Under `none` the `next` that `validation-verdict` returns
for a PASS is `done` (today every non-`auto` policy answers `approve`, Verbs.Pr.ps1), so no session waits for an approval. Its default comes from the environment: `auto` (today's prod value) when `FACTORY_ENVIRONMENT` is `prod`,
`none` for every other value and when the variable is missing on a container (a local gateway without `FACTORY_ENVIRONMENT` keeps the
configuration's value, so the Tier 1 suites run as today). The loader of 4.1 refuses any other value outside prod, and the rule script refuses
again at the merge (two layers: the gateway's start-up check and the verb).

### 5.2 Enforcement in code

- `Verb_merge` (Verbs.Merge.ps1): first statement after the scope guard: `if ($c.mergePolicy -eq 'none') { Reject 10 'merge-disabled' ... }`.
  It is the only path that calls the GitHub merge endpoint, for the session's merge and the gateway's (`-Gateway`), so one check covers both.
- `Test-GatewayMerge` answers false under `none`, so the sweep never schedules a gateway merge and `/status` never lists `passUnmerged`.
- `Invoke-MergePickup` and `Invoke-Settle` (a merge a person made) do nothing under `none` except the end of section 5.3: a person's merge of a
  tdd pull request is reported as `merged-outside-policy` to the operator stream, the item is ended, and nothing settles.
- The GitHub App of tdd and uat is not given the bypass of the default-branch ruleset and the ruleset requires the `Build result` check; the
  real stop is the code above, the App permission is the backstop (section 10).

### 5.3 What a PASS does under `none`

`validation-verdict` with PASS, after recording it as today, calls `Complete-NoMerge` (so do the merge endpoint of 17 and the manager's `merge-now` under `none`):

1. records `verdict = PASS`, `ended = no-merge-policy` in the state;
2. comments on the item and the pull request: "<env> run complete, not merged by policy";
3. closes the pull request (not merged), deletes the branch (`DELETE /git/refs/heads/<branch>`);
4. deletes the claim ref, moves the card to Done on its own board, closes the issue;
5. ends the owner's session (`session.end`) as settle does today;
6. writes the catalog result if the item is a catalog item (6.4).

A FAIL verdict and every other path (findings review, park, unpark, split) are unchanged: the catalog wants those exercised.

### 5.4 What tdd and uat therefore never exercise, and what covers it

The merge itself, the settle step (master green, `merge.rerun_runs`, master-broken parks), the Release Queue, the Octopus delivery check and the
`release.ready` stream line never run in tdd or uat. They stay covered by:

- Tier 1: the `auto`, `merge-queue`, `settle`/delivery scenarios run against the fake GitHub and the fake Octopus at every pull request of this
  repository; they keep `mergePolicy auto` (the suites set no `FACTORY_ENVIRONMENT`);
- prod itself: the first prod items after each promotion are the live check; the operator role (8.3) watches `merge-refused`,
  `master-broken` and `release-queue-aged` there;
- an optional sandbox lane later (section 15, open question 2): a fork of cmdemo1-workorders where tdd may merge.

## 6. The test catalog

### 6.1 Shape

`catalog/` at the root of the fworker repository (next to `config/`, shipped in the image), one directory per scenario:

```
catalog/
  catalog.json                      # version, the order, defaults (timeouts)
  docs-only/
    item.md                         # the issue body template ({{env}}, {{run}}, {{n:dep}} placeholders)
    expect.json                     # expected outcome (6.2)
    fixture/                        # optional: files the seed verb commits to a fixture branch first
  ...
```

`expect.json` names the end the scenario must reach and the facts the report checks: `end` (`pass-no-merge`, `parked`, `split`, `fail-then-pass`,
...), `parkCode`, `maxMinutes`, `minReviewRounds`/`maxReviewRounds`, `mustSee` (journal codes that must appear, e.g. `flaky-rerun`),
`mustNotSee` (e.g. `merge`, `merge-refused`). The report checks facts from the item's state comment and the journal only, never model text.

Catalog items change only documentation and a dedicated test area of cmdemo1-workorders (`docs/factory-catalog/` and
`src/UnitTests/FactoryCatalog/`), so they cannot damage the product and two runs never touch the same file: every run writes under
`.../<run-id>/`.

### 6.2 The scenarios

| # | Scenario | Item | Purpose | Expected outcome |
|---|---|---|---|---|
| 1 | `docs-only` | Add a paragraph to `docs/factory-catalog/<run>/notes.md` | The docs-only fast path end to end | PASS, one Technical Design pass, one review round, no private build; `pass-no-merge` within 15 min |
| 2 | `small-fix` | Fix a one-line bug in a catalog helper class (a fixture commits the bug and a failing-by-design unit test marked `[Ignore]`; the item says remove the ignore and fix) | A code change with a real build and unit tests | PASS, checks green, `pass-no-merge` within 40 min |
| 3 | `red-checks` | Add a method with acceptance criteria whose first natural implementation fails a fixture test that checks an edge case | Failing checks are read (`pr-checks`, job log) and fixed by the worker | at least one red run of the PR's own checks, then green, PASS; `mustSee: checks-red` |
| 4 | `flaky-test` | A docs change on a fixture branch where `src/UnitTests/FactoryCatalog/FlakyCatalogTest` fails on its first attempt per run (a run-id file decides) | The CI rule of `plant-manager.md` 10e: re-run once, never demote for a flake | PASS; `mustSee: flaky-rerun`; no demotion |
| 5 | `dependent-pair` | Two items; B's body says `Depends on: #A` | `Get-ItemDependencies` holds B until A ends | B is not offered before A's `pass-no-merge`; both PASS. Note: under `none` A's change never reaches `master`, so B's fixture must not need A's code; "A ended" counts as met (6.5) |
| 6 | `criterion-dispute` | A criterion that cannot be met as written ("the page loads in under 1 ms on every run") | Escalate earlier: timing criteria flagged at Technical Design, the park, the keeper's default decision | park `same-criterion-repeated` or `timing_criteria` flag, then a keeper default decision (amended criterion) and PASS; `mustSee: keeper-amend` |
| 7 | `oversized` | Nine unrelated documentation pages and three helper classes in one item | The keeper's split policy | item `split`; its children (env-labelled, catalog-tagged) each `pass-no-merge` |
| 8 | `merge-conflict` | Two items that edit the same lines of one fixture file, seeded together | Base update and conflict handling while both are open; under `none` the conflict is between the two branches, so the fixture puts the conflicting line on a fixture base branch that the seed verb advances after the first PR opens | the second item's branch is behind and conflicting; under `none` the merge path (where `baseUpdate` runs today under `auto`) never runs, so `Complete-NoMerge` first calls the base update (`BaseUpdate.ps1`) when the PR is behind or conflicting and hands a conflict back to the owner as a findings round; PASS for both after the resolution |
| 9 | `blocked-session` | An item whose Development step needs a command the runner's auto-mode settings refuse (a fixture asks for `curl` to a host outside the egress allow-list) | A permission refusal is reported, not looped on; the plant manager unsticks | `worker-blocked-note` in the digest, a plant-manager run, then either PASS by another route or park `blocked` with a note; never a hung execution past `replicaTimeoutSeconds` |
| 10 | `runtime-failure` | An item labelled `catalog:fail-exec` that makes the runner exit before registration (a fixture env var the runner honours only in tdd and uat) | Take-back and `runtime-failed` park after `maxFailuresPerPhase` | park `runtime-failed` after 2 executions; runtime marked unhealthy, then reset by the operator role |
| 11 | `review-findings` | A change whose first draft predictably misses a criterion (the criterion names a file the natural fix forgets) | Findings review round and a second round | `minReviewRounds: 2`, PASS |
| 12 | `out-of-scope` | One item labelled with the gateway's environment and a twin labelled with another environment (and one unlabelled) | Live proof of section 3 (the only exception to 3.3: the seed verb may label this twin with another environment, and only for a `catalog:out-of-scope` item) | the twin and the unlabelled item are never claimed, never moved; only the own item ends |

Scenarios 9 and 10 can be simulated only because the runner image and its auto-mode settings are ours (`runner/`, a code-owner path): the
fixture switch is honoured only when `FACTORY_ENVIRONMENT` is not prod, and the runner refuses the switch in prod.

### 6.3 Seeding: the verb and the endpoint

`POST /api/v1/catalog/runs` (operator token, or the operator role's `o1` credential with the `catalog` right; body
`{ "scenarios": ["*"] | [names], "reason": "..." }`) runs the admin rule verb `catalog-seed`:

1. refuses in prod (`catalog-prod`: the catalog never runs on prod's board) and when a catalog run of this environment is still open
   (`catalog-busy`), unless `force` with a reason;
2. makes a run id `<env>-<yyyyMMddHHmm>`;
3. for each scenario: commits the fixture under `.../<run-id>/` on a branch `factory-catalog/<env>/<run-id>` (never `master`; the items'
   branches start from it, so the fixture base is per run), creates the issue from `item.md` with labels `factory worker`, `env:<env>`,
   `catalog`, `catalog:<scenario>`, `catalog-run:<run-id>`, `Auto Merge` (harmless under `none`, keeps the PASS path identical to prod's),
   adds it to the environment's board in Technical Design;
4. writes `refs/factory/<instance>/catalog/<run-id>` holding `catalog.json` version, the scenario-to-issue map and the start time.

Base branch: catalog items set `base: factory-catalog/<env>/<run-id>` in their state at seeding, and `open-pr` uses the state's base when present.
This keeps catalog fixtures off `master` entirely (the only write to the repository outside branches is the issue).

An operator CLI verb wraps it: `factory.ps1 catalog seed --env tdd [--only docs-only,small-fix]`, calling the endpoint with the operator token.

### 6.4 The catalog report

`GET /api/v1/catalog/runs/{run-id}` and the dashboard block "Catalog" show, per scenario: issue, end reached, expected end, the facts of
`expect.json` checked one by one (each `ok`/`failed` with the fact read), duration, executions and model tokens spent, and a verdict:
`pass` (every fact met), `fail`, `running`, `timed-out` (`maxMinutes` exceeded). The run is `pass` when every scenario is. The report reads the
state comments and the journal; it is recomputed on read (cached 120 s like `metrics`) and the final report is written as a comment on a tracking
issue of the run (`catalog-run:<run-id>`, in the fworker repository) when the last scenario ends, so the result survives a restart.

Use as a regression gate: after each tdd release, the operator role (8.3) seeds the catalog once (trigger, 7.2); a failed scenario opens an issue
in this repository with the report. Promotion to uat is requested only after a passing tdd run; the uat run is the check before prod.

### 6.5 Dependencies under no-merge

`Test-DependencyMet` (Verbs.Sweep.ps1) counts a dependency as met when its issue is not open, or its card is in a hold column or in Done.
`Complete-NoMerge` closes the issue and moves the card to Done, so the dependent pair works under `none` with no change to the rule.

### 6.6 Cleanup

`DELETE /api/v1/catalog/runs/{run-id}` (and automatic after `catalog.retainDays`, 7): closes open catalog issues of the run as "not planned",
closes their pull requests, deletes their branches and the `factory-catalog/<env>/<run-id>` branch, removes the cards from the board,
deletes the run's claim refs and its catalog ref. Issues are not deleted (GitHub issue deletion needs an admin and erases history); they are
closed and filtered out by the labels. A run older than `retainDays` with open items is first ended (claims released, executions stopped).
Cleanup runs only on `catalog-run:` labels of the gateway's own environment.

## 7. Every role on demand: the frame

### 7.1 Roles

| Role | Today | After |
|---|---|---|
| Worker | local Claude Code sessions in a launcher loop; Codex job built, off | a `cae-job` execution per item and phase (exists, `cloud-worker-runtimes.md`) |
| Plant manager (supervisor) | one long-lived session, `m1` credential | a role run per attention batch |
| Operator session | one long-lived session, `o1` credential | a role run per operator condition |
| Backlog keeper | one long-lived session, `k1` credential | a role run per keeper job |
| (Owner's supervising local session) | unsticks items, merges green pull requests, re-runs CI, refills the backlog by hand | no role: the plant manager does it automatically while the factory runs (8.4), the owner by Owner actions (17) |

### 7.2 Triggers

The gateway already computes every condition below (patrol digest codes, keeper jobs, release state). A trigger table maps condition to role:

| Condition (already computed) | Role started |
|---|---|
| item offered to `runtime:cae-job` (routing, or `preferConnected` with nobody connected) | worker |
| patrol digest has attention entries (`item-quiet`, `parked`, `worker-blocked-note`, `release-queue-aged`, `verb-errors`, ...) not handled in the last `roles.manager.cooldownMinutes` | plant manager |
| a question from a worker that no connected session answers within `timing.questionAnswerSeconds` | plant manager |
| keeper job codes (park codes of `keeper.jobCodes`), `backlog-low` | backlog keeper (`backlog-low` only in prod; tdd and uat refill from the catalog, never the keeper) |
| `gateway-restarted` with errors, a release of fworker whose `/ready` is not 200 after 5 min, repeated `verb-errors` of one verb, a runtime marked unhealthy, a failed catalog scenario | operator |
| a new tdd release live and ready (tdd only); an owner's request on the endpoint | catalog seed (deterministic, no model, 6.3) |
| an item `pass-unmerged` (prod) or a PASS not yet ended (tdd, uat) for over 30 min; the board ran dry; the owner pressed Start (16) | plant manager |
| `POST /api/v1/roles/{role}/runs` with a reason (operator token) | that role, by hand |

A trigger is level-based and de-duplicated: a role has at most `roles.<role>.maxConcurrent` runs (1 for manager, operator, keeper),
a condition that is still being handled by a running execution does not start another, and a daily execution budget per role
(`roles.<role>.maxExecutionsPerDay`) and per environment caps cost. When nothing triggers, no execution exists: scale to zero.

### 7.3 One run, one job

A role run gets a **job ticket** at start: the condition(s) that triggered it, the items concerned, the digest entries, its deadline. It does
that job with its verbs, reports `done` (`POST /api/v1/roles/runs/{id}/done` with a summary that goes to the operator stream and the journal)
and exits. A run that finds the condition already gone reports `nothing-to-do` and exits. New conditions that arise while it runs are added
to its ticket by the stream (it holds the stream for its lifetime, 8.2) up to `roles.<role>.maxTicketMinutes`, after which they wait for the
next run. Memory across runs is what the gateway keeps: the board, state comments, the journal, the role's last ticket summaries
(`GET /api/v1/roles/{role}/history`, last 20, also persisted in the plant snapshot).

## 8. The role runtime

### 8.1 Job, not long-lived app

| | Long-lived container app per role | Scheduled job | Event job started by the gateway (chosen) |
|---|---|---|---|
| Cost when idle | a replica always (min 1, or the stream drops at scale to zero) | an execution per tick even when nothing to do | zero |
| Latency to act | none | up to the schedule interval | container start, about 60 to 90 s (measured for the worker job) |
| Matches "one job, then exit" | no | partly | yes |
| Fits the existing adapter | no (a new lifecycle) | no (ARM timer, not the gateway's condition) | yes: `gateway/Runtimes/` starts executions through ARM with the gateway's identity |

Each environment gets **one role job** `caj-cmdemo1-<env>-fwrole`, manual trigger, `replicaTimeout` 3600 s, 2 vCPU / 4 GiB (no build), from the
same fwrunner image as the worker job with `FWRUNNER_ROLE=<role>`. One job for all four roles rather than four jobs: the image and identity are
the same and the role is a per-execution environment variable set in the ARM start body (the adapter already overrides env per execution for
the nonce). A periodic safety net exists in the gateway, not ARM: the patrol tick that already computes the digest also evaluates the triggers.

### 8.2 Stream, identity, credential

- Start: the adapter starts an execution with `FACTORY_ROLE=<role>`, `FACTORY_URL` (the environment's internal gateway URL), a one-time nonce and
  the ticket id. The execution redeems the nonce for a credential of the role's existing kind (`m1`, `o1`, `k1`),
  name `<role>-<6 hex>`, valid until `replicaTimeout` + 15 min, revoked at `done` or at execution end (the adapter lists executions every 30 s
  and revokes the credential of one that ended).
- The slot rules stay: the manager, operator and keeper roles have one slot each; a cloud run takes the slot, a local session holding the slot
  makes the trigger hand the ticket to it instead (the local session is an optional client, 11).
- Stream: the run opens the same SSE stream the long-lived sessions use, for its lifetime only; the 25 s ping keeps the ingress open. The
  gateway is the long-lived side; the run never needs to survive a gateway restart: at a restart the adapter re-lists executions, a run that
  lost its stream reconnects with its credential (valid across restarts, like `w2`), and a run that cannot reconnect in 2 minutes exits and
  the trigger fires again.
- Identity in Azure: the role job has its own user-assigned identity with only "Cognitive Services OpenAI User" on the environment's Foundry
  resource (the model); it has no GitHub, Octopus or ARM right. The gateway's identity holds "Container Apps Jobs Operator" on the role job,
  as on the worker job. No role run ever holds a GitHub token: it calls verbs, as workers do.

### 8.3 Model and skills under Codex

Claude is off (owner, 2026-10-15), so every role runs Codex CLI 0.155.1 against `gpt-6.1-sol` in the environment's Foundry resource, Entra
auth by command (as the worker job, `cloud-worker-runtimes.md` 3.4). Skills are Claude Code skills today (`plugin/skills/factory-*/SKILL.md`).
Under Codex:

- `fwrunner.sh` with `FWRUNNER_ROLE` builds the run's `AGENTS.md` from the role's `SKILL.md` (front matter stripped, the body verbatim) plus the
  ticket, and starts `codex exec` with the role prompt template (`runner/prompts/<role>.md`, code-owner path);
- the plugin's tool calls are `pwsh factory.ps1 <verb>` commands, which Codex runs through its shell tool exactly as the worker does; the
  auto-mode settings of the role allow `pwsh` on the plugin path and nothing else that reaches the network;
- skills that name Claude-only features (subagents, `AskUserQuestion`) get a Codex section: one agent, no subagents (multi-agent Codex is not
  validated on `gpt-6.1-sol`), questions to the owner go through `ask` verbs of the gateway;
- a skill check in `tests/smoke.ps1` asserts every role skill parses into an `AGENTS.md` and names only verbs that exist.

### 8.4 What each role may do

| Role | Credential | Verbs (existing unless marked) | Caps |
|---|---|---|---|
| Worker | `w2` | item verbs of its item | one item, one phase |
| Plant manager | `m1` | `manager-action` flow verbs (`plant-manager.md` 10e), answer questions, notes; new: `merge-now` (asks the gateway's own merge of a recorded PASS, the same endpoint as the owner's action, 17), `rerun-failed` on an item's PR, `move-back` one column, `dispatch-hint` (16.3) | the 10e guard rails; a merge only through the gateway's policy check (prod `auto`; tdd and uat end by policy, 5.3); never approve, record a verdict, clear a hold, touch the fworker repository or a protected path; `roles.manager.maxMergesPerDay` |
| Operator | `o1` | `operator.md` 3; `catalog` (new, seed and cleanup); `roles/runs` (new, start a run by hand); runtime reset | the daily release limit; protected paths need the owner; never mint or revoke |
| Backlog keeper | `k1` | keeper verbs; new items carry the gateway's `env:` | `maxNewItemsPerDay`; prod only for `backlog-low` |

### 8.5 What stays deterministic in gateway code

A model run decides only what needs judgement (which item to unpark first, how to word a split, whether a red check is a flake when the
journal is ambiguous, what a fix to the gateway is). The gateway, not a run, owns:

- scope (3), board and instance (4), the merge policy (5) and every merge;
- triggers, de-duplication, budgets and caps (7.2), the start and stop of executions, credential minting and revocation;
- the catalog seed, report and cleanup (6), which are verbs without a model;
- the settle step, re-runs of flaky checks once, the Release Queue, auto-unpark rules, offers and take-backs (already gateway code);
- the guard rails of every role (refused in the verb, never only in the skill).

## 9. Prod under the same frame

prod runs the same image, the same role triggers and its own jobs, with `mergePolicy auto`, delivery on, no catalog. Its first role runs
come after `activate-prod.sh` (owner) and after the owner presses Start on prod (16). The plant manager's `merge-now` stays off in prod
(`roles.manager.mergeNow`, from `FACTORY_MANAGER_MERGE_NOW`) until its runs have gone a week in tdd and uat without an owner intervention.

## 10. GitHub Apps and rate limits

One App per environment (`factory-worker-author-tdd`, `-uat`, and the existing one for prod), each installed on cmdemo1-workorders only,
so each gateway has its own installation token and its own 5,000 requests per hour (15,000 for larger installations). Sharing one App across
three gateways would put three sweeps on one installation budget and make one environment's catalog run throttle prod. Permissions: contents
and pull requests write, issues write, projects write (organization projects: the App is granted the two test boards or 679 only through the
project's access settings); no administration, no ruleset bypass. Reviewer and test-person Apps are per environment by the same rule.
The sweep interval stays 180 s per gateway; tdd and uat lengthen it to 600 s when no catalog run is open (`FACTORY_SWEEP_SECONDS` already exists).

GitHub's secondary limits (content-creating requests per minute) are per App and per user; the seed verb creates at most one issue per 3 s.

## 11. Local sessions become optional clients

Local sessions (omarchy tmux, the owner's Claude Code sessions, the launcher loop) keep working: they connect with a connect prompt and the
same credential kinds. None is required. A role slot held by a local session receives the trigger's ticket instead of a new execution. When the
owner's supervising session goes away, the plant manager and the operator role do its work automatically and the owner intervenes through
Owner actions (17), from the dashboard or from any AI session through MCP (18). In tdd and uat local workers are refused
(`runtime-required`: the plant offers items only to `cae-job` workers there; owner decision 6), the other local roles are allowed.

## 12. Migration and rollout (ordered)

1. **Label migration (prod first, before any code):** create labels `env:tdd`, `env:uat`, `env:prod` in cmdemo1-workorders; add `env:prod` to
   every open issue with the factory label (`gh issue list --label "factory worker" --state open` then `gh issue edit --add-label env:prod`,
   by the operator); add `env:prod` to the issue template. Closed items are left unlabelled (nobody's, correct).
2. **Scope code (3) with `FACTORY_ENVIRONMENT=tdd` on today's tdd:** before this step tdd acts on board 679 and prod items. The release that
   adds scope makes tdd see nothing (all items are `env:prod`): intended. The change ships together with step 3's settings so tdd never acts on
   679 again.
3. **Boards and settings (4):** create the tdd and uat boards; set the `FACTORY_*` variables of 4.1 per environment in Octopus (kit); move the
   tdd job ids out of `config/deploy.overrides.json`. The gateway's start-up check refuses a non-prod gateway pointed at 679.
4. **Merge policy `none` and `Complete-NoMerge` (5)**, with their Tier 1 tests.
5. **Catalog v1 (6)**: scenarios 1, 2, 3, 5, 12, the seed and report endpoints, cleanup. Run in tdd by hand.
6. **Role job and triggers (7, 8) in tdd**: plant manager first, then operator, keeper (with catalog 6, 7); Start/Stop and dispatch (16); Owner actions and MCP (17, 18). Catalog 4, 8, 9, 10,
   11 as their roles arrive.
7. **uat**: create its jobs, identities and App; promote; run the catalog.
8. **prod**: `activate-prod.sh` (owner) now only gives prod its credentials and board 679; tdd is no longer made inert. Roles on one by one;
   the manager's `merge-now` last (9).
9. **Local roles retired:** the owner's supervising session and tmux workers are stopped once their cloud roles have run a week; they remain
   usable as optional clients.

## 13. Tier 1 tests (safety)

New scenarios in a suite `environments` (appended at the end of `$SuiteDefs`, added to a job of `tests.yml`). Each starts the gateway with
`FACTORY_ENVIRONMENT` and the variables of 4.1 against the fake GitHub, whose fake board and labels hold items of all three environments:

1. a tdd gateway never claims, offers or moves the card of an `env:prod` item, an unlabelled item or an item with two `env:` labels, across a
   full sweep, a webhook for each, and a direct call of `claim-item`, `accept`, `merge`, `settle` and the manager flow verbs (all `out-of-scope`);
2. a tdd gateway never writes to board 679: the fake GitHub records every `updateProjectV2ItemFieldValue` and `addProjectV2ItemById` by project;
   the test asserts none names 679 (and, symmetrically, a prod gateway never writes to the tdd board);
3. a tdd gateway never calls the merge endpoint: PASS on an `Auto Merge` item gives `pass-no-merge`, the comment, a closed unmerged PR, a deleted
   branch, the card in Done; the fake's merge endpoint records zero calls; a direct `merge` verb call is refused `merge-disabled`;
4. the start-up check: a gateway with `FACTORY_ENVIRONMENT=uat` and `FACTORY_BOARD_PROJECT=679`, or `FACTORY_MERGE_POLICY=auto`, or the prod
   instance name, never reaches `/ready` 200 and logs why;
5. default policy: `FACTORY_ENVIRONMENT=tdd` with no `FACTORY_MERGE_POLICY` gives `none`; `prod` gives `auto`;
6. refs and branches: a tdd claim writes `refs/factory/factory-worker-tdd/claims/<n>` and branch `factory-worker/tdd/<n>-...`; `Prs.ps1` does
   not take a `factory-worker/tdd/` branch for a prod item;
7. catalog: `catalog-seed` is refused on prod; seeded issues carry the gateway's `env:` and catalog labels; cleanup touches only its run;
8. roles: a trigger starts at most one execution per role; budgets stop the next; a role credential is refused for a verb outside its table (8.4);
   the manager's `merge-now` in tdd ends the item by policy and never calls the merge endpoint;
9. start/stop: Stop refuses every new offer and execution start, lets running ones end, and survives a gateway restart (the snapshot ref);
   dispatch order is Functional Testing, Development, Technical Design, intake from Todo (16.2), and the capacity is never exceeded;
10. owner actions: each action endpoint answers the same with the dashboard, the CLI and an MCP call (one journal line each, `via` differs);
   `merge` in tdd ends the item by policy and never calls GitHub's merge endpoint; a destructive MCP tool without `confirm` is refused; an `m1` credential is refused at `/mcp`.

## 14. Code-owner paths touched

| Path | Why |
|---|---|
| `config/deploy.overrides.json` | tdd job ids and URLs leave it (4.1) |
| `gateway/Runtimes/` | role job start, per-execution role env (8) |
| `runner/`, `Dockerfile.fwrunner` | `FWRUNNER_ROLE`, role prompts, the catalog fixture switches honoured outside prod only (6.2, 8.3) |
| `gateway/Auth.cs` | role credentials from nonces (8.2); `/mcp` authentication (18.4) |
| `gateway/Operator.cs`, `plugin/skills/factory-operator/`, `plugin/scripts/lib/Client.Operator.ps1` | catalog and roles rights; Codex section of the skill |
| `gateway/Manager.cs`, `plugin/scripts/lib/Verbs.Manager.ps1` | scope guard in flow verbs; ticketed runs |
| `gateway/Keeper.cs`, `plugin/scripts/lib/Verbs.Keeper.ps1`, `plugin/skills/factory-backlog-keeper/` | `env:` on created items, `env-mismatch` |
| `plugin/skills/factory-supervisor/` | Codex section, ticket handling |
| `.github/workflows/tests.yml` | the new `environments` suite |
| `docs/deploy/activate-prod.sh` | no longer makes tdd inert (12.8) |

Ordinary paths: `plugin/scripts/lib/Board.ps1`, `Verbs.Sweep.ps1`, `Verbs.Merge.ps1`, `Verbs.Delivery.ps1`, `Prs.ps1`, `BaseUpdate.ps1`,
`gateway/Program.cs` (dashboard panel), new `gateway/EnvironmentSettings.cs`, `gateway/Roles.cs`, `gateway/Factory.cs` (start/stop, dispatch), `gateway/OwnerActions.cs`, `gateway/Mcp.cs`, `catalog/`, `tests/scenarios/environments.ps1`,
`tests/FakeGitHub` (project-scoped write log). Outside this repository: labels and the issue template of cmdemo1-workorders, two boards,
three Apps, the role jobs and identities (the demo-environment kit, owner).

## 15. CI cost and open questions

**CI on test pull requests.** cmdemo1-workorders' workflows run on every pull request whatever its branch, so tdd and uat pull requests run
prod's full CI (build, unit, integration, acceptance where the workflow runs them). A full catalog run is 12 to 14 pull requests and about two
CI runs each. That is real minutes on the organization's bill; it is also the point, because the catalog's red-check and flaky scenarios need
real checks. Mitigations: docs-only scenarios already skip the code jobs through the repository's paths filters; the catalog runs on demand
(after a tdd release, before a promotion), not on a schedule; cleanup cancels runs of closed catalog pull requests.

Open questions for the owner:

1. One role job for all roles (chosen) or one job per role for separate identities and quotas?
2. A sandbox fork where tdd may merge, to exercise settle and the Release Queue live outside prod?
3. Should uat run the whole catalog or only the cheap half (1, 2, 5, 12) to save CI minutes?
4. Adding the `ModelContextProtocol.AspNetCore` package to the gateway (18.1) needs the owner's yes; the fallback is a hand-written JSON-RPC route.
5. Entra for `/mcp`: an app registration per environment with app role `Factory.Owner` (18.1), or the operator token only?
6. `/_build` shows `running` or `stopped` without a credential (16.1): acceptable, or behind the token?

## 16. Start and stop the factory, and dispatch

### 16.1 The factory state

Each gateway has a factory state, `running` or `stopped` (new default: `stopped` on a new environment; prod's first start sets it). It is
held in `refs/factory/<instance>/factory-state` (a parentless commit whose message is `{state, since, by, reason}`, the plant-snapshot
technique), read before the first sweep, so it survives a restart and a redeploy. `/_build` shows it without a credential.

- **Start** (`POST /api/v1/factory/start`, operator token or MCP, with a reason): sets `running`, journals it, and starts a plant-manager run
  with ticket `factory-started`. The gateway dispatches (16.2) from that moment; the manager run handles what needs judgement on the board
  it reads (parked items, stale questions, the order of ties) and exits.
- **Stop** (`POST /api/v1/factory/stop`): sets `stopped` (drain). No new offer, no new worker, manager or keeper execution, no trigger of theirs fires. The operator
  role's triggers (7.2: failed release, unhealthy runtime) still fire, and the owner's actions work. Running executions finish their current phase and end; a PASS still ends or merges by policy so nothing is left
  half-merged. When the last execution ends every role is at zero; `/status` shows `drained: true`. The sweep keeps running read-only for
  the dashboard and for settle in prod.

### 16.2 Dispatch lives in the gateway (recommended)

Two options were weighed:

| | Gateway schedules deterministically, a manager run for judgement (recommended) | The plant manager dispatches through verbs |
|---|---|---|
| Order "closest to Done first" | a sort in code, tested in Tier 1 | an instruction in a skill, not provable |
| Cost | no model run per dispatch | a model run for every free slot |
| Behaviour when the model is down or over quota | dispatch continues | the factory stops |
| Judgement | the manager can reorder with `dispatch-hint` (pin, prioritize, skip for N minutes), within the same order rules | all |

Admin authentication everywhere in sections 16 to 18 means the gateway's `admin` credential kind, the operator token.

Recommendation: **the gateway dispatches.** At every sweep and every execution end, while `running` and below capacity
(`runtimes.caeJob.maxConcurrent` and the daily cap), it offers the next ready item in this order: Functional Testing, Development, Technical Design, then intake from Todo. Intake is new gateway behaviour: it moves one in-scope card (own `env:` label) to Technical Design per free slot,
within `keeper.maxNewItemsPerDay`. The Release Queue is not dispatched: its items wait for a promotion, which stays with the owner
(`ReleaseQueue.cs`); the manager only reports `release-queue-aged`. That is the owner's ordering with the one column no worker can move. Within a column: `priority:top`, `priority:high`, then a manager `dispatch-hint`, then the oldest move into the column. Blocked items
(dependencies, holds, parks, out of scope) are skipped. This is today's offer loop with the sort made explicit and an intake step added.

Pull requests of the fworker repository that an operator run opens: merged by the operator run itself under its existing rules
(`operator-session.md`, guard rails a to e, daily limit), as today; a protected path waits for the owner. No other role merges there.

### 16.3 The plant manager while running

It is started on Start, on the digest triggers of 7.2 and on PASS items waiting too long. It unsticks (unpark, release-owner, requeue,
restart a run), asks the gateway's merge of a green PASS (`merge-now`; the gateway checks policy: a merge in prod, the end by policy in tdd and
uat), re-runs failed CI jobs once, moves a card back a column when its phase must be redone, sets `dispatch-hint`s, and exits. Every one of
these is the same endpoint as an Owner action (17), with the manager's caps.

## 17. Owner actions panel

A panel "Owner actions" on the dashboard of each gateway, shown only after the operator token is entered, one button per action. No model is
involved: each button calls one gateway endpoint, which checks policy, acts, and writes one journal line (`owner-action <name> by <who> via
<dashboard|mcp|cli>: <reason>`) on the item, or on the operator stream for factory-wide actions. Destructive actions ask for confirmation in
the dashboard and a reason in every surface.

| Action | Endpoint (existing or new) | Replaces what the local session did by hand |
|---|---|---|
| Start / Stop factory | `POST /api/v1/factory/start`, `/stop` (new) | starting and stopping tmux workers and the supervisor |
| Unpark item | `POST /api/v1/items/{n}/unpark` (exists) | unparking closed or wrongly parked items (#82) |
| Re-run failed CI jobs of the item's PR | `POST /api/v1/items/{n}/rerun-failed` (new; the manager's `rerun-failed` exists as a flow verb) | re-running flaky Builds by hand (#79) |
| Merge a green PR now | `POST /api/v1/items/{n}/merge` (new; the gateway's own merge path of the sweep under `auto` in prod, `Complete-NoMerge` in tdd and uat (5.3); refused `no-pass` without a recorded PASS) | merging item 239's green PR behind an unprocessed PASS |
| Resettle | `POST /api/v1/items/{n}/resettle` (exists) | putting a merged item back in settle (#114) |
| Release or reassign an item | `POST /api/v1/items/{n}/release`, `/reassign?to=` (new, over the manager's `release-owner` and `pin`) | releasing items held by dropped owners (#74, #101) |
| Pin / unpin an item to a worker | `POST /api/v1/items/{n}/pin?worker=`, `/unpin` (new over the flow verbs) | adding and removing `worker:` labels |
| Drain / resume a worker | `POST /api/v1/workers/{name}/drain`, `/resume` (exists) | re-applying lost drains (#80) |
| Restart a worker run | `POST /api/v1/runs/{id}/restart` (new: stops the execution through ARM; the item is re-offered) | killing a blocked session (#100) |
| Move a card back a column | `POST /api/v1/items/{n}/move-back` (new; one column, never into or out of Done or the Release Queue in prod) | dragging cards on the board |
| Seed / clean the test catalog | `POST /api/v1/catalog/runs`, `DELETE .../{run}` (6.3, 6.6; tdd and uat only) | writing test items by hand |
| Set capacity and daily cap | `POST /api/v1/runtimes/cae-job/capacity` (new; `maxConcurrent`, `maxExecutionsPerDay`, in memory and in the factory-state ref; bounded by the configured maximum) | editing the overrides and redeploying |
| Reset an unhealthy runtime | `POST /api/v1/runtimes/{kind}/reset` (exists) | |

The plant manager does the same things automatically while the factory runs; the buttons are the owner's manual override and work also while
the factory is stopped.

## 18. MCP server: the factory from any AI session

### 18.1 Endpoint

The gateway has no MCP endpoint today (no `ModelContextProtocol` reference, no `/mcp` route). Design: Streamable HTTP at `/mcp` on each
gateway (`<gateway url>/mcp`, one per environment), stateless JSON-RPC, through the `ModelContextProtocol.AspNetCore` package already used
by the work-order application (adding it to the gateway needs the owner's yes, open question 4). Authentication: `Authorization: Bearer`
with the operator token, or an Entra token of a named owner identity (app role `Factory.Owner` on an app registration per environment).
Worker, manager, keeper and operator-session credentials are refused at `/mcp`.

### 18.2 One implementation, three surfaces

Every action is one gateway endpoint (17). The dashboard button, the MCP tool and the CLI verb (`factory.ps1 owner <action>`) call that
endpoint; policy checks, caps, journaling and refusals live only there. The MCP handler maps a tool call to the endpoint in-process and
returns its JSON. A Tier 1 check (13.10) proves the three surfaces give the same result.

### 18.3 Tools

Read tools (no confirmation, no reason):

| Tool | Parameters | Returns |
|---|---|---|
| `factory_status` | none | `{environment, state, drained, board, mergePolicy, capacity:{max,running,today,cap}, roles:[{role,running,lastRun}]}` |
| `board_by_column` | `column?` | `{columns:[{name, items:[{n,title,labels,owner,park?}]}]}` |
| `item_detail` | `item` | `{n,title,column,labels,state,journal:[{at,text}],pr?:{number,head,checks}}` |
| `workers_and_runs` | none | `{workers:[{name,presence,items,drained}], runs:[{id,role,item?,started,status}]}` |
| `patrol_digest` | none | `{entries:[{code,item?,since,detail}]}` |
| `metrics` | `days?` (default 7) | the `metrics` verb's JSON (cycle times by column) |
| `catalog_report` | `run?` (default latest) | the report of 6.4 |

Action tools (every one takes `reason`; those marked * also need `confirm: true`):

| Tool | Parameters | Returns |
|---|---|---|
| `factory_start` | `reason` | `{state:"running", since}` |
| `factory_stop` * | `reason, confirm` | `{state:"stopped", draining:N}` |
| `item_unpark` | `item, reason` | `{ok, park:null}` |
| `item_rerun_ci` | `item, reason` | `{ok, runs:[id]}` |
| `item_merge` * | `item, reason, confirm` | `{ok, merged_sha}` in prod, `{ok, ended:"no-merge-policy"}` in tdd and uat; refusals `checks-not-green`, `no-pass` |
| `item_release` * | `item, reason, confirm` | `{ok, released:owner}` |
| `item_reassign` | `item, worker, reason` | `{ok, pinned:worker}` |
| `item_pin` / `item_unpin` | `item, worker?, reason` | `{ok}` |
| `worker_drain` / `worker_resume` | `name, reason` | `{ok, drained}` |
| `run_restart` * | `run, reason, confirm` | `{ok, stopped:run}` |
| `card_move_back` * | `item, reason, confirm` | `{ok, from, to}` |
| `catalog_seed` | `scenarios?, reason` | `{run, items:[{scenario,n}]}`; refused `catalog-prod` in prod |
| `catalog_cleanup` * | `run, reason, confirm` | `{ok, closed:N}` |
| `capacity_set` | `maxConcurrent?, maxExecutionsPerDay?, reason` | `{capacity:{max,cap}}` (bounded by the configured maximum) |

Refusals come back as MCP tool errors carrying the gateway's exit code and refusal code, unchanged.

### 18.4 Safety

- An MCP client is an untrusted model: it gets exactly the endpoint's guard rails, the same as the plant manager's (8.4), plus the owner's
  wider set of actions. It cannot mint or revoke credentials, switch messaging, change a protected path, approve, record a verdict or merge
  on a pull request without a recorded PASS; those have no tool.
- Destructive tools need `confirm: true` in the call; without it they answer a preview (`{wouldDo: ...}`) and change nothing. The tool
  descriptions say so, so a client shows the user the preview first.
- Rate limits per token (`mcp.readPerMinute` 60, `mcp.actionsPerMinute` 10, `mcp.actionsPerDay` 100 per environment); `item_merge` follows the
  manager's merge cap; refused with 429 and `retryAfter`.
- Every call is journaled with `via mcp` and the caller (token kind or Entra object id); MCP tool text from item titles or journals is
  returned as data inside JSON, never as instructions, and the inspector's AI-directed-text patterns (`inspector.aiDirectedText`) mark it.
- Per environment: the tdd `/mcp` acts only on tdd (scope, 3), so a client connected to tdd cannot touch prod.
