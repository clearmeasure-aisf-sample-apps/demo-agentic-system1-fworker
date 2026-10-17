# The backlog keeper session

Status: built, awaiting the owner's review (2026-10-14). Code: `gateway/Keeper.cs`, the keeper parts of `gateway/Auth.cs` and
`gateway/Program.cs`, `plugin/scripts/lib/Verbs.Keeper.ps1` (the rule verbs), `plugin/scripts/lib/Client.Keeper.ps1` (the client), the skill
`plugin/skills/factory-backlog-keeper`, the owner's rules `docs/owner-rules.md`. Scenarios: `tests/scenarios/keeper.ps1` (`keeper: ...`, in the
manager suite). It builds on the plant manager's flow verbs (`docs/design/plant-manager.md` 10e): the priority labels, the owner's hold, the
journal of actions with a policy code.

## 1. What it is

A fourth kind of session next to the workers, the supervisor and the operator session. Before it, an item whose acceptance criterion could not be
met as written, an item too large to finish, a compatibility conflict or a flaky test parked the item until a person rewrote it, and the board ran
dry when nobody wrote new items. The keeper does that work by fixed default policies (its skill), within guard rails the gateway enforces. It
decides about items, never about code: it never merges, approves, records a verdict, clears a hold, claims an item or moves an existing card.

## 2. Settings

`config/instance.json`, block `keeper` (off in the source; the owner turns it on in `config/deploy.overrides.json`):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Needs `messaging.enabled`; the gateway refuses to start otherwise. `FACTORY_KEEPER=0` or `1` overrides it |
| `allowedNames` | `["backlog-keeper"]` | The names a credential can be minted for; reserved while the role is on |
| `tokenGeneration` | `1` | Part of the credential; raising it voids every keeper credential |
| `requiredModelTier`, `requiredEffort` | `premium`, `medium` | The model check of a registration (declared, flagged, never refused) |
| `maxNewItemsPerDay` | `10` | New items in 24 hours: created, split children and follow-ups together |
| `minTechnicalDesign` | `3` | Fewer open factory items in Technical Design send the keeper `backlog-low` (at most once an hour) |
| `newItemColumn` | `Technical Design` | Where a new item's card is put |
| `jobCodes` | the park codes below | Park codes that send the keeper a job |
| `policies` | the codes of the skill | The policy codes a verb may name |
| `protectedCriteria` | security, data loss, "must" | Patterns of criteria that are never amended |

## 3. The credential and what it is admitted to

`k1.<name>.<generation>.<hmac>` (after a revocation `k1.<name>.<generation>-<rev>.<hmac>`), minted only with the operator token:
`POST /api/v1/workers/{name}/credential?role=keeper`; its connect prompt is not generated yet (open: neither `docs/deploy/gen-connect-prompt.sh` nor the dashboard's `buildPrompt` knows the keeper; until then the prompt sets `FACTORY_URL` and `FACTORY_KEEPER_TOKEN` and starts `factory.ps1 subscribe --own --keeper --name backlog-keeper` under Monitor, with the skill `factory-backlog-keeper`). Revoked like any other name. One slot: the same name replaces its older stream; another allowed name is
refused (409 `keeper-active`) while the active one was heard within `timing.mgrTakeoverSeconds`. A credential whose name does not hold the slot is
refused at every endpoint below except the plugin download and the registration (`not-keeper`).

| Endpoint | What |
|---|---|
| `GET /api/v1/events?name=N&keeper=1&model=&effort=` | its stream (`keeper.job` lines) |
| `GET /api/v1/plugin`, `POST /api/v1/presence` | the plugin download and the heartbeat |
| `POST /api/v1/verbs/{verb}` | `get-item`, `pr-checks`, `backlog` and the five verbs of section 4 (Auth.cs `KeeperVerbs`; the body keeps only the listed fields and `by` is the credential's name) |
| `GET /api/v1/metrics` | the cycle times (the median time in Development, for the oversized-item policy) |

Everywhere else it is refused: no message, no question, no traffic, no inbox, no other verb, no credential, no switch.

## 4. The verbs

| Verb | What it changes | Refused when |
|---|---|---|
| `amend-criteria --item N --criterion "..." --replacement "..." [--follow-up] [--unpark]` | The one acceptance criterion above the design section that contains the quoted text is rewritten in place, marked "amended by the backlog keeper, decision K-N-s", and a decision block at the end of the body keeps the original word for word, the new text, the policy and the reason. The item state records the amendment and the criteria records start fresh. `--follow-up` creates an item for the original target (it counts against the day). `--unpark` releases the item's park as the plant manager's unpark does (not the inspector's hold, a PASS waiting for a merge, or the wait for checks). | `hold:owner`; no or several matching criteria; a criterion already amended; a criterion matching `protectedCriteria` (security, data loss, "must") |
| `split-item --item N --children-file F [--chain false]` | 2 to 6 children are created from the design sections (each lists its acceptance criteria; by default each `Depends on #<the one before>`), carrying the parent's `Auto Merge`, test, video and priority labels; an open pull request of the parent is closed without merging, with a comment; the parent is closed as not planned with the list of children | `hold:owner`; a live claim (`owned`); a merge being settled; more children than the day allows |
| `create-item --title T --body-file F [--labels ...] [--priority top\|high] [--pin NAME\|next-free] [--depends-on N,M]` | A new issue with the factory label and the allowed labels (`Auto Merge`, the test and video labels, a priority, a pin), its card in `newItemColumn`. `next-free` is resolved by the gateway to the next worker the plan would offer an unpinned item to | no acceptance criteria in the body; a label outside the list; the day's limit |
| `set-priority --item N --level top\|high\|normal` | the labels `priority:top`, `priority:high` | `hold:owner` |
| `link-dependency --item N --depends-on M [--remove]` | a line `Depends on #M` in the body (the plant holds the item until M is merged or closed) | `hold:owner`; a direct cycle |
| `backlog` | nothing: the board's open factory items by column, with priority, pin and owner hold | |

Every verb that changes something writes one journal line `keeper-action` on the item with who, what, the policy code and the reason. Text the
keeper writes passes the credential patterns (client and gateway), may not carry HTML comment markers or the gateway's own markers, and loses `@`
mentions.

## 5. Jobs

The stream carries `keeper.job` with `code`, `item`, `column`, `detail`, at most once an hour per code and item, the last 200 kept for a reconnect:

- a park of a code in `keeper.jobCodes`: `same-criterion-repeated`, `worker-failure`, `fix-forward-exhausted`, `demotion-limit`,
  `watchdog-relaunch-budget`, `verdict-failed`, `stuck`, `master-broken`; from the trigger the sweep routes (`item.parked`) and from a worker's
  failure report (`complete` that answered parked);
- `backlog-low` after a sweep that counted fewer than `minTechnicalDesign` open factory items in Technical Design.

## 6. Guard rails

Enforced by code: the credential's reach (section 3); `hold:owner` refuses every changing verb; at most `maxNewItemsPerDay` new items in 24 hours
(the gateway, in memory: a restart starts the count again); security, data-loss and "must" criteria are never amended and a criterion is amended
once; a policy code on every verb, journaled; no verb merges, approves, records a verdict, clears a hold, claims or moves an existing card. The
owner's rules (`docs/owner-rules.md`, a code-owner path) are read-only input: the keeper session reads them from a read-only clone and no verb
writes them. Instruction only (the skill): the default policies, and that an owner rule wins over a policy.

Kill switches: revoke the keeper's name on the dashboard, set `keeper.enabled` false in the overrides, or switch messaging off.
