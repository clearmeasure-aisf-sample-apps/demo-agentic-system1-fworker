#!/usr/bin/env bash
# Local run: each secret comes from the environment when it is set there (GH_TOKEN, OCTOPUS_API_KEY, FACTORY_DEV_TOKEN, FACTORY_WEBHOOK_SECRET),
# otherwise from the files and the keyring of the maintainer's machine; nothing is printed. Build first (see CLAUDE.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$HOME/.local/share/factory-worker/secrets"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
export OCTOPUS_API_KEY="${OCTOPUS_API_KEY:-$(secret-tool lookup service demo-operator kind octopus-read-key)}"
export FACTORY_DEV_TOKEN="${FACTORY_DEV_TOKEN:-$(cat "$S/dev-token")}"
export FACTORY_WEBHOOK_SECRET="${FACTORY_WEBHOOK_SECRET:-$(cat "$S/webhook-secret")}"
: "${GH_TOKEN:?no GitHub token}" "${FACTORY_DEV_TOKEN:?no operator token}" "${FACTORY_WEBHOOK_SECRET:?no webhook secret}"
export FACTORY_PLUGIN_SCRIPTS="$here/plugin/scripts"
export FACTORY_CONFIG="$here/config/instance.json"
export FACTORY_SWEEP_SECONDS="${FACTORY_SWEEP_SECONDS:-30}"
exec dotnet "$here/gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll"
