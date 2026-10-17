# CLAUDE.md

Guidance for an AI session that works in this repository. This repository is the single source of the factory worker gateway: everything
needed to build, test, change and release it is here. Project state, environments, the owner's decisions and the backlog: `docs/HANDOFF.md`
(read it before the first change).

## What this is

A gateway (ASP.NET Core minimal API, .NET 10) that holds the GitHub and Octopus credentials, runs the PowerShell rule scripts of the
plugin (`pwsh factory.ps1 --server <verb>`), sweeps the board of `clearmeasure-aisf-sample-apps/demo-agentic-system1-workorders` and hands work items to
AI sessions (workers) that connect with a prompt from its dashboard. It ships as one container image, deployable `fworker` of the cmdemo1
demo system.

## Layout

| Path | Content |
|---|---|
| `gateway/` | The gateway: `Program.cs` (routes, dashboard, connect prompt), `Plant.cs` (workers, assignments), `Messaging.cs`, `Qc.cs`, `Auth.cs`, `RunnerPool.cs`, `Operator.cs` (the operator session) |
| `plugin/` | What a worker downloads from the gateway (`GET /api/v1/plugin`): `scripts/` (`factory.ps1`, `lib/*`), `skills/`, `agents/`, `tools/shot`, `launcher/` (the session loop, `docs/launcher.md`) |
| `config/instance.json` | The source defaults. The tests run on these: messaging off, supervisor off, `ownerSessions` false |
| `config/deploy.overrides.json` | The settings of the deployed image, merged over the defaults by `config/apply-overrides.ps1` when the image is built |
| `tests/scenarios/` | Tier 1: scenario suites against the fake GitHub (`run.ps1`, `run-all.ps1`, one file per area) |
| `tests/FakeGitHub/` | The fake GitHub the suites talk to |
| `tests/smoke.ps1` | Parses every script and checks the pure rule functions; no network |
| `tests/stress/` | `messaging-stress.ps1`: 10 minute stress of messaging and the supervisor; run by hand, alone |
| `tests/live/`, `tests/fullrun/` | Tier 2 and the fully connected run against the real GitHub and board. They need the operator's machine (see below) |
| `tools/github-app-setup/` | One-page app that creates the test GitHub Apps |
| `docs/design/` | Designs: `plant-manager.md`, `worker-messaging.md`, `pr-qc-environment.md` and their reviews, `operator-session.md` |
| `docs/deploy/` | `gen-connect-prompt.sh`, `activate-prod.sh`, `create-webhook.sh`; `MORNING.md` and `runbook-add-deployable.md` are records of 2026-10-11 |
| `Dockerfile`, `.dockerignore` | The image: `gateway/`, `plugin/`, `config/` only |
| `.github/workflows/` | `build.yml` (image + tests, the required check `Build result`), `tests.yml`, `release.yml`, `secret-scan.yml`, `architecture.yml` |
| `run-gateway.sh`, `run-owner-gateway.sh` | A local gateway against the real GitHub; they need credentials (environment or the maintainer's keyring) |

## Build

Needs the .NET 10 SDK and PowerShell 7.5 or later (the image and the workers run 7.5.4), plus `openssl`, `tar` and `curl`.

```bash
dotnet build tests/FakeGitHub -c Release -nodeReuse:false -p:UseSharedCompilation=false
dotnet build gateway          -c Release -nodeReuse:false -p:UseSharedCompilation=false
```

The image (optional locally; the pull request builds it): `docker build -t fworker --build-arg VERSION=0.0.1 .`

## Test

Build first (above); the suites start the built binaries. Nothing here needs a secret or the network.

```bash
pwsh -NoProfile -File tests/smoke.ps1                                                  # seconds; "all passed"
pwsh -NoProfile -File tests/scenarios/run.ps1 -Suite owner -Tier full -NoBuild         # one suite
pwsh -NoProfile -File tests/scenarios/run.ps1 -Suite messaging -Tier full -NoBuild     # qc, messaging and manager split into 4 groups by themselves
pwsh -NoProfile -File tests/scenarios/run-all.ps1 -Tier fast -NoBuild                  # the curated subset of every suite, 4 suites at a time
pwsh -NoProfile -File tests/scenarios/run-all.ps1 -Tier full -NoBuild                  # everything (about 30 minutes on 4 cores)
pwsh -NoProfile -File tests/scenarios/run.ps1 -Suite auto -Only 'substring of a scenario name' -NoBuild
pwsh -NoProfile -File tests/scenarios/run.ps1 -ListSuites
```

Rules of the runners:

- One run at a time on a machine. A second `run.ps1` or `run-all.ps1` exits 4: wait and start again. Do not pass `-Force`.
  Wait with `while pgrep -x pwsh -a | grep -q 'tests/scenarios/run'; do sleep 5; done`.
- A run needs 2 GB free on the filesystem of the temp directory and 1.5 GB of memory for full parallelism. Where `/tmp` is a small tmpfs,
  set `TMPDIR` to a directory on disk before building and testing.
- A `pwsh` that ends with exit 134 or 139 is the machine (load, memory), not the product: run the failed suite again, alone.
- Never stop processes by a name pattern (`pkill -f`): the runners stop what they started.
- `run-all.ps1` without `-NoBuild` builds with `--no-restore`: on a fresh clone run the two `dotnet build` commands above first.
- A new suite is appended at the END of `$SuiteDefs` in `tests/scenarios/run.ps1` (the position is its port slot) and added to a job of
  `.github/workflows/tests.yml` (the workflow fails when one is missing). A scenario tagged ` [full]` in its name is left out of the fast tier.
- `run-all.ps1` rewrites `tests/scenarios/suite-times.json` (and a full run `scenario-stats.json`): commit them only when the timings
  really changed.

The pull request runs the smoke test and every suite at the full tier (`tests.yml`, six jobs). The stress test is not part of it:
`pwsh -NoProfile -File tests/stress/messaging-stress.ps1 -NoBuild` (10 minutes, alone on the machine).

## Deployed settings

`config/instance.json` holds the defaults and is what the tests read. The image gets `config/deploy.overrides.json` merged over it
(`Dockerfile`, `config/apply-overrides.ps1`): owner sessions on, merge queue depth 2, messaging and the supervisor on for every registered
worker. To change what a deployed gateway runs with, change the overrides file in a pull request; an override that names no existing
setting fails the image build. To see the effective configuration without docker:
`pwsh -NoProfile -File config/apply-overrides.ps1 -Base config/instance.json -Overrides config/deploy.overrides.json -Out /tmp/effective.json`.
The same image is promoted to uat and prod, so the settings travel with it. Runtimes are the exception: `runtimes.environments.<name>`
holds one whole runtimes block per environment, the gateway uses the entry named by `FACTORY_ENVIRONMENT`, and an environment without an
entry has every runtime off. Only tdd has one today.

## Release

1. Branch `{user}/{description}` from `master`; never push to `master`.
2. Change, build, run the smoke test and the suites of the area you touched.
3. Review before every commit: a fresh subagent (Opus 5.5, low effort) reads `git status` and `git diff --cached` only and approves or
   lists blockers; commit on approval.
4. Push and open a pull request. Required checks: `Build result` (the image and, through `tests.yml`, every suite) and `secret-scan`
   (gitleaks over the history).
5. When every check is green on the head commit: `gh pr merge N --squash --match-head-commit <full sha>`. Pull requests of this
   repository merge without a GitHub review once green (owner decision); the review of step 3 is the review.
6. The merge is the release to tdd: Build of `master` (image only), then `release.yml` pushes that image to the registry and creates the
   Octopus release of project `demo-agentic-system1-fworker`, whose lifecycle deploys it to tdd. About 4 minutes from merge to live.
   **A release is done only when both are true**: `curl -s <tdd url>/_build` shows the new version (`1.0.<Build run number>`,
   `pluginHash`) AND `curl -s -o /dev/null -w '%{http_code}' <tdd url>/ready` answers 200. `/health` 200 is not enough: on 2026-10-13 a
   release was live and never ready for 49 minutes. A 503 of `/ready` says what the start waits for
   (`{"ready":false,"waitingFor":"revocations","attempts":N,"since":"..."}`); if it has not turned 200 a few minutes after the
   deployment, treat it as an outage: find the cause or roll back.
7. uat and prod are manual promotions by the operator (Octopus sign-off, the demo-environment kit). A session does not promote to them.

A gateway restart drops the in-memory state (below) except the plant: the process that holds the leader lease (`gateway/Leader.cs`) snapshots it
to GitHub on every change and at its stop, and hands it over to the next process (which waits for that snapshot before its first sweep, and
renews the owners' claims that ran out while no gateway was up). Deploy to tdd only when the plant is quiet, say so beforehand, and check
afterwards that the workers reconnected (`/api/v1/status`: `leader.role` acting, `plantSnapshot.restore.how`). Roll back by reverting the pull request.

## Rules

- **Never commit a secret.** The repository is public. No token, key, webhook secret, connect prompt (it contains a credential) or raw log
  of a live run. Test fixtures that look like credentials are composed at run time (`'ghp_' + ('A' * 26)`) so the secret scan stays
  meaningful; do not add an allowlist for them. Scan before pushing: `gitleaks git . --redact --no-banner --log-opts=HEAD`.
- **Credentials are not here.** The operator token of a gateway, the Octopus key and the GitHub App keys live in the owner's keyring and
  in the environments' vaults. A session gets what it needs as environment secrets (names in `docs/HANDOFF.md`). Never print one.
- **Tests green before merge**; a red suite is investigated, not retried until green (except a pwsh crash, see above).
  A check whose failure has an open backlog entry and no known cause may be a `CheckQuarantined` (tests/scenarios/lib.ps1): it reports
  and is counted as a quarantined failure without failing the suite. Read that count in every summary.
- **The fake GitHub behaves like GitHub.** Where the product depends on how an endpoint pages, orders, limits or refuses, the default of
  `tests/FakeGitHub` is what GitHub really does; another behaviour is a test control a scenario switches on.
- **Messaging state is in memory.** Messages, questions, presence, the worker registry and the supervisor slot live in the gateway process;
  a restart loses them (senders are told what was lost, workers register again). The durable truth is the board, the item state comments
  and the revocation refs in the work-orders repository. Do not design a feature that assumes a message survives a restart.
- **The plugin assumes nothing about the worker's machine**: any OS, x64 or arm64, only what the prompt downloads or clones; no fixed
  paths, no preinstalled `gh`, `jq`, `python` or `dotnet`, no shell variables in commands of skills and agents. The author suite checks this.
- **Only one gateway may sweep the board.** The leader lease enforces it: the newest process with a GitHub identity takes the lease and the
  one before stands down. So do not start `run-gateway.sh` or `run-owner-gateway.sh` against the real repository while tdd is the acting
  gateway: it would take the plant over from tdd (`FACTORY_LEADER_LEASE=0` turns the lease off for a local gateway, and then two would sweep).
- **Protected areas need the owner**: credentials and tokens, authorization, revoke, the deploy pipeline (`.github/workflows/`,
  `Dockerfile`, `config/deploy.overrides.json`), uat and prod. `build.yml`, `release.yml`, `secret-scan.yml` and `architecture.yml` come
  from the demo-environment kit: the only local addition is the `tests` job of `build.yml`.
- Code style: follow the file you are in (long lines, comments that say why). Documentation is plain and exact; no emojis.

## What needs the operator's machine

`tests/live/run.ps1`, `tests/fullrun/*`, `docs/deploy/activate-prod.sh`, `docs/deploy/create-webhook.sh` and
`tools/github-app-setup/serve.ps1` use the keyring (`secret-tool`), a signed-in `gh`, a sandbox clone of demo-agentic-system1-workorders
(`FACTORY_SANDBOX_REPO`, default `~/Projects/factory-worker-sandbox/demo-agentic-system1-workorders`) and, for promotions, the demo environment kit
(`FACTORY_KIT_DIR` and `FACTORY_KIT_USER`). They are kept for the operator; a cloud session does not need them for build, test or release.
