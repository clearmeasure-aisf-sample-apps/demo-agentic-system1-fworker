# Runbook: add the factory worker gateway as a deployable of cmdemo1

> Record of 2026-10-11 (how the deployable was planned), kept for its history. The source is this repository now; there is no copy or staging step. Current state: `docs/HANDOFF.md`.

Status: research only (2026-10-10). Nothing in this runbook has been run. Every fact below was read from
`clearmeasure-aisf-sample-apps/cmdemo1-system` (PRs #103, #105, #106, #109, #112, `system.json`), from the private
`cmdemo1-scorecard` repository, and from the demo-environment kit (`/home/aiops/demo-environment-kit`, HEAD 7705d50:
`docs/start-a-new-system.md`, decisions 0013/0021/0023/0033, `reference.md` "A container deployable from a repository
of its own", `add-demo-deployable.ps1`, `set-demo-secret.ps1`, `invoke-demo-promotion.ps1`, `invoke-demo-rollout.ps1`,
templates `build-container.yml`, `release-container.yml`, `containerapps.bicep`).

The scorecard is the model. The pattern, as it actually happened:

| PR | Title | Files | What it did |
|---|---|---|---|
| #103 | Deployable scorecard: a container app from cmdemo1-scorecard | `system.json` only | new `deployables[]` entry, `environments: ["tdd"]` |
| #105 | A blob store for the deployable scorecard (infra/own) | `infra/own/main.bicep`, `infra/own/test-blobstore.ps1` | optional storage, not needed by the gateway |
| #106 | scorecard in uat, and two corrections to the blob store checks | `system.json` (+ test script) | `environments` gains `"uat"` |
| #109 | Scorecard in prod, and its build facts at /_build | `system.json` | `environments` gains `"prod"`, adds `buildPath` |
| #112 | The health dashboard links to the scorecard | `system.json` | adds `dashboardLink` |

Every system-repo PR is a one-file change to `system.json`. The system workflow (`.github/workflows/system.yml`) creates
the Octopus project on merge; the environment release (`Apply environment`) creates the container app. No hand-written
workflow, script or bicep is needed in `cmdemo1-system` for a plain container deployable.

## 0. Decisions to settle before step 1

1. Deployable name. `add-demo-deployable.ps1` and `set-demo-secret.ps1` validate `^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,9}$`:
   2 to 10 characters, so `factory-worker` (14) is refused. Proposal: `fworker` (7) -> repository `cmdemo1-fworker`, Octopus
   project `cmdemo1-fworker`, container app `ca-cmdemo1-<env>-fworker[-suffix]`, identity `id-cmdemo1-<env>-fworker`, vault
   secrets `fworker-<name>`. Alternative: `gateway`. Jeffrey picks (repo name is permanent).
2. Environments. Follow the scorecard: tdd first, then uat, then prod (`environments` array in `system.json`).
3. Always-on or scale to zero: see section 5 and 6. The gateway has timers (sweeper, plant ticker) and in-memory state, so
   scale-to-zero is only acceptable for tdd/uat proofs; prod needs `alwaysOn` if it is to do real work.
4. Which GitHub identity the gateway acts as (`GH_TOKEN`). Principle 008 prefers an organization App over a user token
   (the aisf deployable acts as App `cmdemo1-aisf`, app 5231590). Decision for Jeffrey; the runbook below assumes one
   supplied secret `github-token` (App installation token or fine-grained token); a stored long-lived PAT is the weakest option.

## 1. The new repository

Name `clearmeasure-aisf-sample-apps/cmdemo1-<name>` (rule: `<slug>-<name>`). Visibility: private, like `cmdemo1-scorecard` and
`cmdemo1-aisf` (the kit creates it with the operator's rights, then adds the ruleset requiring "Build result" and "secret-scan").
Default branch: the templates trigger on `master` and `main`; the scorecard uses `main`.

Contents the kit's build and release require (all from `templates/app/.github/workflows/` and `add-demo-deployable.ps1 -Container`):

| Item | Contract |
|---|---|
| `Dockerfile` at the repo root | Build context is the repo root. Runs as non-root. Declare `ARG VERSION=0.0.0` (the kit passes `--build-arg VERSION=MAJOR.MINOR.run` only when the Dockerfile declares it). Set `ENV ASPNETCORE_HTTP_PORTS=8080`, `EXPOSE 8080`. No secrets as ARG/ENV (build secrets only via `RUN --mount=type=secret`; the gateway needs none). |
| Image contents the gateway needs (from `gateway/Program.cs`, `Plant.cs`, `run-gateway.sh`) | .NET 10 runtime (aspnet image) plus `pwsh` (the gateway shells out to `pwsh factory.ps1 --server <verb>`), `git`, `gh`; `plugin/scripts/**` at a fixed path exported as `FACTORY_PLUGIN_SCRIPTS`; `config/instance.json` exported as `FACTORY_CONFIG`; a writable state dir (`FACTORY_STATE_DIR`, e.g. `/tmp/factory-state`; there is NO volume, state is lost on restart/revision). |
| `.github/workflows/build.yml` | Name `Build`; env `MAJOR_VERSION`, `MINOR_VERSION`; a job named `Build result`; produces artifact `container-image` (`container-image.tar.gz`). The kit writes it from `build-container.yml`. Tests belong in the Dockerfile stages or an extra job that `Build result` needs (scorecard added a `tests` job). |
| `.github/workflows/release.yml` | Kit text `release-container.yml`, unchanged (the scorecard's is byte-identical to the template). Triggered by a successful push/dispatch Build on master/main. |
| `.github/workflows/secret-scan.yml` | gitleaks; required check of the default-branch ruleset. Kit writes it. |
| Repo variables (set by the kit script, never by hand) | `ACR_LOGIN_SERVER`, `ACR_NAME`, `AZURE_CLIENT_ID_ACR_PUSH`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `DEPLOYABLE_NAME`, `OCTOPUS_SERVICE_ACCOUNT_ID`, `OCTOPUS_SPACE_ID`, `OCTOPUS_SPACE_NAME`, `OCTOPUS_URL` (the exact set on cmdemo1-scorecard). GitHub environment `release`. |
| Registry and tag | Registry `acrcmdemo1chu4gq.azurecr.io`; image `acrcmdemo1chu4gq.azurecr.io/cmdemo1/<name>:<MAJOR>.<MINOR>.<Build run number>` (e.g. `1.0.17`); the tag is write-locked after push (`az acr repository update --write-enabled false`). The same number is the Octopus release number. Bump major/minor in `build.yml` env only for deliberate version changes. |
| Port | 8080 only (see section 5). |
| `GET /health` (system.json `healthPath`) | Must answer 200 when ready. Scorecard uses `/health`; aisf uses `/health`; the existing gateway already serves `/health` -> `ok`. The task prompt said `/_healthcheck`: that is the work-order app's path (`ui`, `app2-ui`); choose either, but it must equal `healthPath` in `system.json`. Do not call third parties from it unless secrets hold real values in every environment (lesson 66). |
| `GET /_build` (system.json `buildPath`) | Serves JSON build facts. Fleet rule FLEET-008 raises a finding for a deployable without `buildPath` (scorecard got issue #107; fixed by PR #109). Today the gateway returns `{name, started, runtime, ownerMode}`. Match the kit's shape: `version, commit, commitUrl, buildUrl, builtAt, tests{unit,integration,acceptance}, code, coverage, complexity, crap, analysis` (unmeasured = null). Copy `scripts/Write-BuildFacts.ps1` from cmdemo1-scorecard (reads `GITHUB_SHA`, `GITHUB_RUN_ID`, `*.trx`), run it in a `tests` job, put `build-facts.json` in the build context, `COPY` it to the content root and serve it (scorecard `OperationsEndpoints.cs`: `Cache-Control: public, max-age=300`, fallback `{version}`). |
| Env var names the app reads (set by `system.json`) | Secrets: `FACTORY_DEV_TOKEN`, `FACTORY_WEBHOOK_SECRET`, `FACTORY_TOKEN_SECRET` (owner mode, min 16 chars), `OCTOPUS_API_KEY`, `GH_TOKEN`. Plain settings: `FACTORY_OWNER_MODE=1`, `FACTORY_ENVIRONMENT=<env>`, `FACTORY_SWEEP_SECONDS`, `FACTORY_API_PORT`/`FACTORY_WEBHOOK_PORT` (see section 5), `FACTORY_PLUGIN_SCRIPTS`, `FACTORY_CONFIG`, `FACTORY_STATE_DIR` (the last three can be Dockerfile ENV). `FACTORY_PUBLIC_URL` should come from the kit's `urlSetting`. The kit also injects `OTEL_SERVICE_NAME` and `APPLICATIONINSIGHTS_CONNECTION_STRING` (telemetry capability). |
| Source of the code | Copy `/home/jeffrey/Projects/factory-worker-next/{gateway,plugin,config,tools?}` as files only (private, like the scorecard import); leave `gateway/bin`, `obj`, `run-gateway.sh` and `tests/FakeGitHub` out of the image. Note `config/instance.json` points at repo `cmdemo1-workorders`, project 679, Octopus project `cmdemo1-ui`. |

## 2. System repo changes, by environment

All changes: branch `cm-ai-ops-bot/...` or similar in `clearmeasure-aisf-sample-apps/cmdemo1-system`, edit `system.json` only,
PR merged by squash (the rollout script merges when "mergeable"). Required checks on a system PR: `env-checks` (runs `scripts/test-system.ps1` on the changed system.json) and others of the ruleset.

### 2a. tdd (PR "Deployable fworker: a container app from cmdemo1-fworker")

Entry added to `deployables[]` (same shape as PR #103; `add-demo-deployable.ps1 -Container -Definition` writes it, do not hand-edit if the script is used):

```json
{
  "name": "fworker",
  "repository": "cmdemo1-fworker",
  "port": 8080,
  "healthPath": "/health",
  "buildPath": "/_build",
  "environments": ["tdd"],
  "database": false,
  "settings": { "FACTORY_OWNER_MODE": "1" },
  "environmentSettings": { "tdd": { "FACTORY_ENVIRONMENT": "tdd" } },
  "urlSetting": "FACTORY_PUBLIC_URL",
  "secrets": [
    { "name": "dev-token",       "env": "FACTORY_DEV_TOKEN" },
    { "name": "webhook-secret",  "env": "FACTORY_WEBHOOK_SECRET" },
    { "name": "token-secret",    "env": "FACTORY_TOKEN_SECRET", "generate": true },
    { "name": "octopus-api-key", "env": "OCTOPUS_API_KEY" },
    { "name": "github-token",    "env": "GH_TOKEN" }
  ]
}
```

`database: false` is mandatory (otherwise the SQL connection string is wired; if it were the last user it would also change SQL).
Having `secrets` gives the app its own identity `id-cmdemo1-tdd-fworker` (Key Vault Secrets User on its secrets only).
`alwaysOn`/`cpu` omitted = scale to zero, environment `appCpu` (tdd is 2 vCPU: set `"cpu": "0.5"` to cut cost).

Order (kit reference.md "Order"; secrets first):
1. Kit, as operator, WITHOUT `-Merge`: `add-demo-deployable.ps1 -Config /home/aiops/demo-environment-kit/fleet/systems/cmdemo1.json -Name fworker -Container -Source <folder|existing repo> -Port 8080 -HealthPath /health -Definition <json>`. Creates the repo (or checks an existing one without changing it), its variables, the GitHub-OIDC trust (Octopus service account, registry push identity, deploy identities), the operator's "Key Vault secret writer" role (via `new-demo-seed.ps1`), and opens the PR to `system.json`. Stops and says so.
2. Secrets (section 3) in tdd's vault.
3. Same command WITH `-Merge`: verifies every supplied secret exists, merges the PR, waits for the system release (container app created with placeholder image), pushes the repo default branch.
4. The repo's Build then Release run: image pushed, Octopus release `<MAJOR>.<MINOR>.<run>` created; lifecycle deploys it to tdd automatically (Pin version, Update deployable, Verify deployable, Revert pin; no migration or acceptance tests).

### 2b. uat (PR "fworker in uat")

`environments` becomes `["tdd","uat"]` (+ `environmentSettings.uat`). Order: write the uat secrets first (section 3; kit 6b80ecc now allows writing ahead of the merge), then PR, merge, then:
`invoke-demo-rollout.ps1 -Config ... -Stage system:<PR>,fworker -Reason "<text>"` or by hand `invoke-demo-promotion.ps1 -Config ... -Project system -Environment uat [-Release <v>] -Wait -Approve -Reason "<text>"` and then `-Project deployable -Deployable fworker -Environment uat -Wait -Approve -Reason ...`. Every environment after the first has a manual "Sign-off" step (approvers list is empty by design: automation signs off with a recorded reason). If the PR merges before the secrets, "Update deployable" fails with exit 255 and no message (kit bug noted in 6b80ecc); fix = write secrets, then `invoke-demo-promotion.ps1 -Project system -Environment uat -Release <same version> -Wait`, then the deployable's release.

### 2c. prod (PR "fworker in prod")

`environments` gains `"prod"`; to run always-on only in prod add `"alwaysOn": true, "alwaysOnEnvironments": ["prod"]` (aisf pattern; add `"cpu":"0.5"`). Add `environmentSettings.prod`. Secrets in prod's vault first (the scorecard's prod secrets were the step the classifier refused). PR #109 shows the shape. Promote system release then the deployable release to prod with `invoke-demo-promotion.ps1 ... -Environment prod ... -Approve -Reason`. The classifier has refused prod promotions and merges before: expect Jeffrey to paste the commands.

### 2d. Dashboard link and build facts (PR "The health dashboard links to fworker")

See section 4. Can ride in the tdd PR (`buildPath`) and a later PR (`dashboardLink`).

### 2e. Written by scripts vs by hand

| By script | By hand |
|---|---|
| Repo creation, variables, ruleset, OIDC trust, seed role, the system.json PR (add-demo-deployable.ps1); Octopus project creation (system.yml on merge); container app, identity, vault references, ingress (Apply environment); image push, tag lock, release (release.yml); pinning (Octopus steps); dashboard link resolution (dashboard deploy) | The gateway source changes (section 5); Dockerfile; `Write-BuildFacts.ps1` and the `tests` job in `build.yml`; `-Definition` JSON; PRs for uat/prod/dashboardLink (can be opened by script with `-Merge`, otherwise by `gh pr create`); secret values (operator, section 3) |

## 3. Secrets

- Names: any set a deployable declares in `system.json` `deployables[].secrets[]` as `{name, env, generate?}`. Vault secret = `<deployable>-<name>` (e.g. `fworker-webhook-secret`), regex `^[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?$`. Supplied = operator writes; `"generate": true` = "Apply environment" creates 64 hex chars (use for `token-secret`; nobody outside the gateway needs it. Not for the webhook secret: GitHub must hold the same value).
- Where: Key Vault of each environment (one vault per environment, named by stack output `keyVaultName` of `stack-cmdemo1-<env>`). tdd and uat are in `rg-cmdemo1-nonprod`, prod in `rg-cmdemo1-prod`. A vault exists only after the environment's first apply (it exists for tdd, uat, prod already).
- Command (kit script, operator account; value on stdin or `-File`, never an argument, nothing printed):
  `sudo -n -u aiops -H bash -lc 'pwsh -NoProfile -File /home/aiops/demo-environment-kit/.claude/skills/demo-environment/scripts/set-demo-secret.ps1 -Config /home/aiops/demo-environment-kit/fleet/systems/cmdemo1.json -Environment tdd -Deployable fworker -Name webhook-secret' < <value-source>`
  `-List` prints names and presence only. `-Restart` runs the "Restart apps" runbook (waits up to 40 min). A changed value reaches a running app within 30 minutes (Container Apps rereads the vault), restart of the revision does not make it sooner.
- Who may write: the operator (Azure service principal `cm-ai-ops`) holding "Key Vault secret writer (cmdemo1)" (set, list, cannot read). The seed grants it once a deployable with supplied secrets is recorded. Only the deploy identity and the app's own identity can read. This session must not read or print values.
- Previously refused by the classifier: writing prod's scorecard harvest key ("Secret-Store Writes", 2026-10-10 evening: Jeffrey ran it), "Permission Grant" (App script), "External System Writes" (creating an item), "Merge Without Review" (PR merges, prod promotions), "Interfere With Workloads" (`gh run cancel`, factory-logs.sh), "Remote Shell Writes" (restart-test.sh). Policy: post the exact command and let Jeffrey approve or paste; do not work around.
- How to ask the operator without exposing values: generate each value into the keyring or a 0600 file on Jeffrey's machine outside any repo (existing local secrets live in `~/.local/share/factory-worker/secrets/{dev-token,webhook-secret}`; OCTOPUS read key = keyring `service demo-operator kind octopus-read-key`), then give Jeffrey this form, one per secret per environment: `secret-tool lookup service demo-operator kind <kind> | sudo -n -u aiops -H bash -lc '<set-demo-secret.ps1 command above>'`. Keyring kinds to create: `fworker-dev-token-<env>`, `fworker-webhook-secret-<env>`, a GitHub credential kind (see decision 4). Do not reuse local dev values in prod; use distinct values per environment (scorecard used `-tdd/-uat/-prod` kinds). The webhook secret value must also be entered in the GitHub webhook configuration (browser or `gh api`, a GitHub write: section 6).
- `octopus-api-key`: use the read-only service account `cmdemo1-reader` key (aisf did the same). It can only read.

## 4. Health dashboard

Dashboard: https://blue-bush-041023510.1.azurestaticapps.net (deployable `dashboard`, static web app, kit template; decisions 0013/0016).
- Container apps have no address by convention, so the dashboard lists no node for them. What appears: (a) `healthPath` and `buildPath` are in `system.json` and the hourly Health report / fleet checks use them; `buildPath` also feeds the "Code" card and silences FLEET-008. (b) An optional link: `deployables[].dashboardLink {text, path}`, resolved per environment from the environment's stack when the dashboard release is deployed (kit commit 7705d50), as old as the last dashboard deployment.
- Exact change from PR #112, in the fworker entry of `system.json`:
  ```json
  "dashboardLink": { "text": "Factory", "path": "/dashboard" }
  ```
  (scorecard: `{"text":"Scorecard","path":"/"}`). The gateway serves `/dashboard` as an HTML page whose data call is bearer-protected; confirm the page is acceptable to expose publicly (section 5). Then redeploy the dashboard release in every environment (`invoke-demo-promotion.ps1 -Project deployable -Deployable dashboard -Environment <env> -Release <same> -Wait`), as the template says to after changes that affect the topology. Changes nothing a system is made of or costs.

## 5. Public exposure and what the gateway must change

Findings:
- Ingress (`templates/system/infra/modules/containerapps.bicep`): every container app gets `external: true`, ONE `targetPort` (system.json `port`, or the placeholder's while no version is deployed), `transport: auto`, `allowInsecure: false`. There is no per-path ingress, no IP restriction, no additional port mappings, no auth setting in the template. Public ingress for only specific paths is not available from system.json. Container Apps itself supports only one HTTP target port per app on this ingress (additionalPortMappings exist for TCP/extra ports but the kit does not use them); treat two HTTP ports as unsupported here.
- Consequence: the gateway's two Kestrel listeners (`ListenLocalhost(5100)` API, `ListenLocalhost(5101)` webhook, middleware filtering by `ctx.Connection.LocalPort`) cannot be exposed. Both also bind to localhost, which a container cannot receive from ingress.
- Authentication the system already uses: aisf puts the dashboard behind Entra sign-in via app settings (`Factory__Dashboard__Access=SignIn`, `AzureAd__TenantId`, `AzureAd__ClientId`) implemented in the aisf app itself; its webhooks use `GitHub__WebhookSecret` (HMAC). The scorecard is public read-only with an operator key for the harvest button. The kit/ingress adds no authentication; each app does its own.

Required gateway changes (code, in the new repo):
1. One listener: `k.ListenAnyIP(8080)` (honour `ASPNETCORE_HTTP_PORTS`); remove `apiPort`/`hookPort` and the port test in the first middleware.
2. Path-based separation in that middleware: `/webhooks/github` POST only with HMAC `X-Hub-Signature-256` verified (already implemented, constant-time, 10-minute delivery de-dup); `/api/*` requires bearer (`Auth.Authenticate`, already used on the API port; keep the 401 behaviour); `/health` and `/_build` anonymous and read-only; `/qc/*` (public click pages protected by nonce and per-IP/PR rate limits, owner mode) and `/dashboard` (static HTML) must be explicitly allowed or denied. Return 404 for every other path. Consider moving `/dashboard` behind sign-in or leaving it static since its data calls need the bearer.
3. Fix `FACTORY_PUBLIC_URL` from the kit's `urlSetting` and set `qc.trustProxy` with the correct proxy handling (ingress terminates TLS; X-Forwarded-For comes from Envoy, whose addresses are not static: `knownProxies` cannot be a fixed list, so decide before enabling QC rate limiting by client IP).
4. Server-sent events for workers (`subscribe`) are long-lived; Container Apps ingress closes idle connections at about 4 minutes, so workers must reconnect (the CLI already uses `--name` sessions; verify). Not verified.
5. State is in memory and in the container filesystem; a revision change or scale-to-zero loses plant/assignment state (the aisf lesson; no volume support in the kit's template). Accept for prod only if sessions re-register after restart. Keep `maxReplicas 1` (kit default) because the state is not shared.
6. Never expose the unauthenticated verbs; keep all `/api` calls requiring the bearer token and role checks (`Auth.AuthorizeVerb`) and keep `FACTORY_DEV_TOKEN` high entropy since the gateway will be reachable from the whole internet at `https://ca-cmdemo1-<env>-fworker-<suffix>.<domain>.azurecontainerapps.io`.
7. Webhook delivery URL becomes `https://<app fqdn>/webhooks/github` (the address is stable per environment only until a placement move; no Front Door in this system).

## 6. Numbered WRITE actions

Tags: SAFE = new files in a new repository; EXTERNAL = anything outside that. Who: S = this session, O = operator account via sudo, J = Jeffrey. "Refused" = the classifier is known to refuse (or is likely to refuse; "likely" is an inference).

| # | Action | Tag | Who | Refused? | Cost | Rollback |
|---|---|---|---|---|---|---|
| 1 | Jeffrey decides name (`fworker`), environments, GitHub identity, always-on policy | decision | J | n/a | none | n/a |
| 2 | Edit gateway source in `/home/jeffrey/Projects/factory-worker-next` (single listener, path auth, `/_build` facts, Dockerfile, build-facts script) | SAFE | S | no | none | git revert in the local repo |
| 3 | Create the private repo `cmdemo1-fworker` and push initial files (kit `add-demo-deployable.ps1 -Container`, or kit `new-app-repository.ps1`); also writes repo variables, `release` environment, ruleset | EXTERNAL | O (J pastes if refused) | likely (External System Writes) | none | `gh repo delete` (needs the delete scope; ask J) |
| 4 | Kit seed/trust update (OIDC subjects, ACR push, operator Key Vault role) done inside step 3 | EXTERNAL (permission grant) | O | "Permission Grant" was refused for an App script; likely here | none | remove role assignment / re-run seed without the deployable |
| 5 | Open the system PR #A for tdd (`system.json` entry) | EXTERNAL | O (script) | possible | none | close PR |
| 6 | Write tdd secrets (5 values) | EXTERNAL | O, J pastes the commands | yes ("Secret-Store Writes") | negligible | `az keyvault secret delete` by the operator (soft-deleted); entry removal from system.json |
| 7 | Merge PR #A | EXTERNAL | O or J | yes (Merge Without Review) | none | revert PR, merge (stack removes the app at next apply) |
| 8 | System release deploys to tdd (creates container app, identity, vault references, Octopus project) | EXTERNAL (deploys) | automatic | no | ~$0 scale to zero (see below) | revert PR #A; the stack deletes the app |
| 9 | Push repo default branch; Build + Release push image to ACR (tag locked) and create Octopus release; auto-deploy to tdd | EXTERNAL | automatic (O pushes) | possible | ACR storage of a few hundred MB: cents | "Revert pin"/previous tag (kit rolls back on failed Verify); old tags are locked, not deleted |
| 10 | Create GitHub webhook(s) on `cmdemo1-workorders` pointing at the tdd app, with the tdd webhook secret | EXTERNAL | J or O | likely | none | delete the hook (`gh api -X DELETE`) |
| 11 | Open PR #B "fworker in uat", write uat secrets, merge, promote system release then deployable release to uat with sign-off | EXTERNAL | O, J for secret/merge/promote | yes for secrets and merge; promotions: nonprod unknown | ~$0 | revert PR; redeploy previous release |
| 12 | Open PR #C "fworker in prod", write prod secrets, merge, promote system then deployable release to prod with sign-off | EXTERNAL (deploys, changes cost if always-on) | O, J | yes (prod promotion and merge refused before) | see cost | revert PR; or promote previous release; `alwaysOn` off |
| 13 | PR #D `dashboardLink` and redeploy the dashboard in each environment | EXTERNAL | O | possible | none | revert PR, redeploy dashboard |
| 14 | Update webhook URL/secret for the prod gateway; point worker sessions at the new gateway URL with their credentials | EXTERNAL | J | likely | none | repoint to the local gateway |
| 15 | Optional: blob store for state via `infra/own` (PR #105 pattern; module is scorecard-specific and must be edited to a second deployable) | EXTERNAL (cost) | O | possible | storage account LRS: well under $1/month at this size | remove from the module (deletes the data at next apply) |

Cost estimates (Azure list prices, Consumption; the first 180,000 vCPU-s and 360,000 GiB-s a month are free for the whole subscription and are shared with aisf and the other apps; estimates, not read from Azure):
- Scale to zero (tdd, uat): billed only while serving requests; idle replica = $0. With `cpu 0.5`, a few hours a month: pennies. Cold starts of 10 s or more (the gateway's timers do not run while zero).
- Always-on prod, 0.5 vCPU / 1 GiB: 2.63 M seconds a month; at idle rates (about $0.000003 per vCPU-s and GiB-s) roughly $8 to $12 a month, up to about $35 if the replica is billed active (CPU busy, long SSE connections keep it active). The free grant covers part of it; aisf already always-on in prod uses it. Container Apps environments already exist (tdd/uat share one; prod has its own), so no new environment fee.
- Storage: ACR is shared (Basic, already paid); Key Vault 5 secrets x 3 envs: pennies. Log Analytics/App Insights ingestion: pennies at gateway log volume.
- Unchanged: SQL (`database:false`), Front Door (none).

## 7. Gaps (not determined)

- Whether the operator may create a repository and whether `new-app-repository.ps1` or `add-demo-deployable.ps1 -Container -Source` is the right entry for a repo whose files exist elsewhere (scorecard's repo was imported first, then "used as it is"; its files are checked, never changed).
- The scorecard's exact PR sequence for system/octopus beyond `system.json`: the system repo's `octopus/*.tf` and workflows were not read; PR diffs show nothing else changes.
- Whether `/_healthcheck` or `/health` is preferred: both work if `healthPath` matches; the system's other container deployables use `/health`.
- Real behaviour of long-lived SSE (`subscribe`) through Container Apps ingress with a single replica; not tested.
- Whether Container Apps' default ingress allows more than one HTTP target port: documented as one target port per app for HTTP; additional ports are TCP-only. The kit template has no way to set them anyway.
- Octopus Insights, quota: standard Container Apps environment slots (tdd and uat share one) are unaffected since no new environment is needed.
- Free-grant remainder this month, actual cost of the scorecard and aisf (use `write-cost.ps1` output / Azure Cost Management; not read).
- Which GitHub identity (App vs token) the gateway uses in a container; the existing local gateway uses `gh auth token`, unsuitable for prod (principle 005/008).
- Whether the kit's secrets writer role is still in place for the operator (list with `set-demo-secret.ps1 -List` before relying on it).
- Whether the GitHub Actions flag on `cm-ai-ops-bot` (2026-10-07) has recurred: check before long pipeline runs (`curl -s -o /dev/null -w '%{http_code}' https://github.com/cm-ai-ops-bot`).
