#!/usr/bin/env bash
# Makes the PROD fworker gateway the one that acts on the board, and the TDD gateway inert (only one gateway may sweep the board).
# Values come from the keyring and are never printed. Run it yourself: ! bash docs/deploy/activate-prod.sh
set -euo pipefail
SS=/home/aiops/demo-environment-kit/.claude/skills/demo-environment/scripts/set-demo-secret.ps1
CFG=/home/aiops/demo-environment-kit/fleet/systems/cmdemo1.json
# 1. tdd stops acting: its copy of the App key becomes the placeholder (a clean 'secret missing').
printf unset | sudo -n -u aiops -H bash -lc "pwsh -NoProfile -File $SS -Config $CFG -Environment tdd -Deployable fworker -Name github-token" 2>&1 | tail -1
# 2. prod gets the App key (factory-worker-author, app 5275650, installed on cmdemo1-workorders only).
secret-tool lookup service factory-worker kind github-app-private-key app author | sudo -n -u aiops -H bash -lc "pwsh -NoProfile -File $SS -Config $CFG -Environment prod -Deployable fworker -Name github-token" 2>&1 | tail -1
# 3. restart the apps so they read the vault now (otherwise Container Apps picks it up within 30 minutes).
for env in prod tdd; do
  sudo -n -u aiops -H bash -lc "pwsh -NoProfile -File $SS -Config $CFG -Environment $env -Deployable fworker -Restart" 2>&1 | tail -2
done
