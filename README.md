# factory-worker

**demo-agentic-system1 copy.** Copied from `clearmeasure-aisf-sample-apps/cmdemo1-fworker` for the system
demo-agentic-system1 (slug `agentic1`) of the platform `demo-agentic-platform1`: board project 686, app
`demo-agentic-system1-workorders`, Octopus space `demo-agentic-system1`. It runs on Azure Container Apps express and
scales to zero; workflow `wake` calls each gateway every 15 minutes so its sweep runs (express has no always-on timers
and no jobs). Runners are off here (`FACTORY_RUNTIME_ENABLED=false`, routing `cursor-cloud` only): Container Apps
jobs do not exist on express, and runners as express apps are a follow-up.

The factory worker gateway and plugin: a software factory in which AI sessions carry work items of
`clearmeasure-aisf-sample-apps/demo-agentic-system1-workorders` from Technical Design to a merged, released change. The gateway holds the GitHub and
Octopus credentials, runs the rule scripts, sweeps the board and serves a dashboard; workers connect with a prompt and call verbs.
Instance key: label `factory worker` (the earlier factory keys on `AI Factory`). Board: clearmeasure-aisf-sample-apps project 679.

This repository is the single source: gateway, plugin, configuration, tests, the fake GitHub, tools and the container image.

- **Build, test, release, rules:** [`CLAUDE.md`](CLAUDE.md)
- **Project state, environments, decisions, backlog:** [`docs/HANDOFF.md`](docs/HANDOFF.md)
- **Designs:** [`docs/design/`](docs/design/)

| Part | Where |
|---|---|
| Gateway (ASP.NET Core, .NET 10) | `gateway/` |
| Plugin served to workers (rule scripts, skills, agents) | `plugin/` |
| Source defaults and the deployed settings | `config/instance.json`, `config/deploy.overrides.json` |
| Tier 1 suites, fake GitHub, smoke, stress, live runs | `tests/` |
| Container image | `Dockerfile` |
| Checks and release | `.github/workflows/` |

A merge to `master` builds the image and releases it to the tdd environment; uat and prod are manual promotions.
No secret is in this repository; a local gateway takes its credentials from the environment (see the top of `run-owner-gateway.sh`).

## Choosing models (cost first, automatic)

`plugin/scripts/models.default.json` (shipped inside the plugin) is the default; a machine overrides it with `~/.config/factory-worker/models.json` (or `FACTORY_MODELS_CONFIG`).
`mode: auto` walks a ladder; `mode: fixed` pins one model for the orchestrating session and one for subagents.

| Rung | Default model | Effort |
|---|---|---|
| economy (start) | claude-haiku-5-5 | xhigh |
| standard | claude-sonnet-5-5 | medium |
| premium | claude-opus-5-5 | medium |

The gateway decides when to climb (`model-tier`, thresholds in `escalation` in `config/instance.json`): relaunches, repeated review findings, demotions,
fix-forward rounds, and refused gate calls all raise the tier; it never goes back down within a column. `factory.ps1 model-for --role orchestrator|subagent --item N`
returns the model and effort for this machine. Headless workers start on that rung (`claude --model --effort`); subagents take it per call.

**Testing profile.** `profiles.testing` in the models file is the cheapest setting (claude-haiku-5-5 at `low`) for very simple tasks: docs-only
changes, text replacement, automated exploratory and stress testing. It is pinned and never climbs the ladder: a loop in a test is a finding, not a reason to
pay for a dearer model. An item opts in with the `factory test` label (the live tests add it), or a machine forces it with `FACTORY_MODEL_PROFILE=testing`
or `model-for --profile testing`. It wins over both `auto` and `fixed` mode.

## Connect a session (your own AI session as a factory worker)
1. Use the dashboard of a deployed gateway (`<gateway url>/dashboard`), or start the owner-mode gateway on this machine: build (`CLAUDE.md`), then `./run-owner-gateway.sh` (API on localhost:5500). Only one gateway may sweep the board: do not start a local one while a deployed gateway acts on it.
2. Open the dashboard, paste the operator token, choose a name, press "Create prompt" and paste the generated prompt into a new Claude Code session. The session runs `subscribe --own` under a Monitor (loaded first where the tool is deferred) and owns each work item it is given until its pull request is merged (the gateway carries it on from there).
2b. The prompt is self-contained and assumes nothing about the machine (Linux, macOS or Windows; x64 or arm64): it downloads PowerShell 7 and the plugin (exactly the gateway's version, `GET /api/v1/plugin`) into one base directory and uses only literal paths. The machine needs curl, tar, git and a checkout of the work-orders repository; tools a task needs (the .NET SDK) are installed on demand by `plugin/scripts/ensure-tools.ps1`.
3. A hand-made cloud session connects the same way with the type `claude-cloud` or `cursor-cloud`; it must be able to reach the gateway URL.
4. To make a work item eligible: label it `factory worker` (and `Auto Merge` if it may merge without a person) and move it to Technical Design on the board.

## Findings of the live multi-item runs (2026-10-10/11)
- A merged pull request that says "Closes #N" closed the item, and settle gave up: the card stayed in Functional Testing. Settle and the sweep now follow a closed item whose merge is still being settled.
- A PASS verdict whose pull request was closed unmerged blocked every claim. The sweep now demotes the item.
- `needs-approval` and `ready-to-merge` offers were refused by `claim-item` (verdict already recorded). The dispatch skill now runs the approval or the merge without a claim.
- Haiku sessions refuse any command containing `$FACTORY_PLUGIN_SCRIPTS`; spawned workers are now told the literal path.
- Headless workers could not run the app (curl, nohup). Allowed tools widened; the Functional Testing skill says how to start it.
- Development workers polled CI and held a worker slot; they now complete after two more polls and the gateway watches CI.
- A worker that ends without finishing released nothing for 30 minutes; the client now releases its claim on exit.
- Docs-only changes no longer wait in the merge queue; the queue depth for code changes is configurable (`mergeQueueDepth`).
- Capacity on a 4-core 12 GB machine: 26 read-only haiku workers all succeed; 8 to 9 real edit workers are stable; 26 read-only plus about 6 real workers exhausted memory.
