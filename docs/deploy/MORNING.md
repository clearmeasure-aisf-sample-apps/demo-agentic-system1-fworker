# Morning pack (written 2026-10-11, overnight)

> Record of 2026-10-11, kept for its history. The paths it names (`~/Projects/factory-worker-next`, a staged copy in `~/Projects/cmdemo1-fworker`) no longer exist: this repository is the source. Current state: `docs/HANDOFF.md`.

## Where things stand
- Live 30-item run on the real board: 25 Done, 5 waiting for a person (see below), 1 stray duplicate card for #107 left in Todo. Releases up to 2.4.218 went tdd, uat, prod with sign-off.
- Bugs found and fixed in the run: see README "Findings".
- Deployment of the gateway to tdd/uat/prod: NOT done. The permission check denied the first external step (creating the repository `cmdemo1-fworker`, granting its trust and opening the tdd system PR: "Modify Shared Resources"). Nothing was created. The repository content is ready in `~/Projects/cmdemo1-fworker` (staged copy for the operator at `/var/tmp/cmdemo1-fworker-src`, definition at `/var/tmp/fworker-def/definition.json`).

## Verified overnight
- The container image builds from `~/Projects/cmdemo1-fworker/Dockerfile` (tested locally, then removed): non-root, PowerShell inside, `/health`, `/_build` (version), `/dashboard`, bearer-protected `/api`, single port 8080.
- All four PR QC slices are built in `factory-worker-next`: 1813 Tier 1 checks, 0 failed. `factory-worker` (the older copy) was NOT synced again; `factory-worker-next` is the current source and the owner gateway runs from it.

## Decisions needed before deploying (defaults chosen, change any)
1. Name: `fworker` (the kit allows 2 to 10 characters; `factory-worker` is refused).
2. GitHub identity of the cloud gateway: an organization GitHub App (preferred) instead of a stored personal token. The two Apps from the local setup (reviewer, testperson) exist; the gateway also needs an author identity. Until it exists the `github-token` secret has no value to write.
3. Always-on in prod (about $8 to $35 a month, an estimate); tdd and uat scale to zero.

## Commands to run (each is one step; run them yourself with `!` or tell me to retry)
Step 1, repository + trust + tdd system PR (no merge):
```
sudo -n -u aiops -H bash -lc 'cd /home/aiops/demo-environment-kit && pwsh -NoProfile -File .claude/skills/demo-environment/scripts/add-demo-deployable.ps1 -Config /home/aiops/demo-environment-kit/fleet/systems/cmdemo1.json -Name fworker -Container -Source /var/tmp/cmdemo1-fworker-src -Port 8080 -HealthPath /health -Definition /var/tmp/fworker-def/definition.json'
```
Step 2, secrets for tdd (values come from your keyring or a generator, never printed): see runbook section 3 (`docs/deploy/runbook-add-deployable.md`).
Step 3, same command as step 1 with `-Merge`, then the repo's Build and Release deploy to tdd. uat and prod follow the runbook (PRs "fworker in uat", "fworker in prod", then `invoke-demo-promotion.ps1`). The dashboard link is the last PR.

## The 5 items that need a person (real hold rules working as designed)
- #140, #142, #144: held by the factory inspector (repeated demotions), PR approval by a person in `humanApprovers`.
- #106, #127: parked after repeated failed Functional Testing verdicts.

## Running your own AI session against the gateway
See README "Connect a session". Local gateway for this machine (owner mode, new code) is started with `~/Projects/factory-worker-next/run-owner-gateway.sh` (written overnight; not started so it does not sweep the board twice).

## Status at the end of the night
- The pilot services are stopped. The owner-mode gateway is RUNNING from `factory-worker-next` (pid in `~/.local/share/factory-worker/owner-gateway.pid`, log `~/.local/share/factory-worker/owner-gateway.log`), API and dashboard on `http://127.0.0.1:5500` (this machine only; a tailnet link needs your decision because other people's devices are on the tailnet). No worker is connected yet. Open the dashboard, paste the operator token (`cat ~/.local/share/factory-worker/secrets/dev-token`), create a prompt and start your session.
- Stop it with `kill $(cat ~/.local/share/factory-worker/owner-gateway.pid)`.
- Disk: `/` is at 96% and `/tmp` (2 GB tmpfs) is full from other projects; builds need `TMPDIR` on disk.

## Deployment status (2026-10-11 daytime)
- DONE: repo `cmdemo1-fworker`; PRs #115 (tdd), #116 (uat + build facts + dashboard link), #118 (prod, always-on) merged; secrets written to the three vaults (github-token is the placeholder `unset`); fworker 1.0.1 runs in tdd, uat and prod (health, build facts, dashboard and token-protected API verified in each).
- Addresses: tdd `ca-cmdemo1-tdd-fworker.graybush-19a6e13b.southcentralus.azurecontainerapps.io`, uat `ca-cmdemo1-uat-fworker-fccv.graybush-19a6e13b.southcentralus.azurecontainerapps.io`, prod `ca-cmdemo1-prod-fworker-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io`. Operator tokens: keyring service `factory-worker`, kind `fworker-dev-token-<env>`.
- DENIED by the permission check: creating the webhook. Run `! bash docs/deploy/create-webhook.sh`.
- PENDING: a real GitHub identity (App) for the cloud gateways; until then they cannot act on the board. System workflow `capabilities` job failed once on CAP-076 (a Health report still executing); re-run queued.
