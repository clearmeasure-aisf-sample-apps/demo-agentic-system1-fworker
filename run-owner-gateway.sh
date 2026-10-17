#!/usr/bin/env bash
# Local owner-mode gateway (plant manager + PR QC + dashboard) for this machine. Each secret comes from the environment when it is set
# there (GH_TOKEN, OCTOPUS_API_KEY, FACTORY_DEV_TOKEN, FACTORY_WEBHOOK_SECRET, FACTORY_TOKEN_SECRET), otherwise from files and the keyring
# of the maintainer's machine; nothing is printed. Build first (see CLAUDE.md). API and webhook listen on localhost (5500/5501). Open http://127.0.0.1:5500/dashboard on this
# machine and paste the operator token (do not share it).
# Only one gateway may sweep the board: stop any other first (tests/fullrun/stop.ps1 stops the full-run services).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$HOME/.local/share/factory-worker/secrets"
[ -n "${FACTORY_TOKEN_SECRET:-}" ] || [ -s "$S/token-secret" ] || { mkdir -p "$S"; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$S/token-secret"; chmod 600 "$S/token-secret"; }
export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
export OCTOPUS_API_KEY="${OCTOPUS_API_KEY:-$(secret-tool lookup service demo-operator kind octopus-read-key)}"
export FACTORY_DEV_TOKEN="${FACTORY_DEV_TOKEN:-$(cat "$S/dev-token")}"
export FACTORY_WEBHOOK_SECRET="${FACTORY_WEBHOOK_SECRET:-$(cat "$S/webhook-secret")}"
export FACTORY_TOKEN_SECRET="${FACTORY_TOKEN_SECRET:-$(cat "$S/token-secret")}"
export FACTORY_OWNER_MODE=1
export FACTORY_ENVIRONMENT="${FACTORY_ENVIRONMENT:-local}"
export FACTORY_API_PORT="${FACTORY_API_PORT:-5500}" FACTORY_WEBHOOK_PORT="${FACTORY_WEBHOOK_PORT:-5501}"
: "${GH_TOKEN:?no GitHub token}" "${FACTORY_DEV_TOKEN:?no operator token}" "${FACTORY_WEBHOOK_SECRET:?no webhook secret}"
export FACTORY_PLUGIN_SCRIPTS="$here/plugin/scripts"
export FACTORY_STATE_DIR="${FACTORY_STATE_DIR:-$HOME/.local/share/factory-worker/state-owner}"
mkdir -p "$FACTORY_STATE_DIR"
# owner mode needs ownerSessions=true in the instance config as well as FACTORY_OWNER_MODE; derive it, leave the repo file alone
python3 - "$here/config/instance.json" "$FACTORY_STATE_DIR/instance.owner.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c["ownerSessions"]=True; json.dump(c,open(sys.argv[2],"w"),indent=2)
PY
export FACTORY_CONFIG="${FACTORY_CONFIG:-$FACTORY_STATE_DIR/instance.owner.json}"
export FACTORY_SWEEP_SECONDS="${FACTORY_SWEEP_SECONDS:-30}"
exec dotnet "$here/gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll"
