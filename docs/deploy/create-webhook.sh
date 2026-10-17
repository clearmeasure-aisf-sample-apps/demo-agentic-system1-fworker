#!/usr/bin/env bash
# Creates the GitHub webhook of cmdemo1-workorders that delivers to the prod fworker gateway, and removes the dead tunnel hook.
# The secret is read from the keyring at run time and never printed. Run it yourself: ! bash docs/deploy/create-webhook.sh
set -euo pipefail
R=clearmeasure-aisf-sample-apps/cmdemo1-workorders
HOST=ca-cmdemo1-prod-fworker-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io
python3 - "$HOST" <<'PY' | gh api -X POST "repos/$R/hooks" --input - --jq '"created hook \(.id)"'
import sys,json,subprocess
secret=subprocess.run(['secret-tool','lookup','service','factory-worker','kind','fworker-webhook-secret-prod'],capture_output=True,text=True,check=True).stdout.strip()
print(json.dumps({"name":"web","active":True,"events":["issues","workflow_run","pull_request","pull_request_review"],
 "config":{"url":f"https://{sys.argv[1]}/webhooks/github","content_type":"json","secret":secret,"insecure_ssl":"0"}}))
PY
gh api -X DELETE "repos/$R/hooks/695397284" 2>/dev/null && echo "removed the old tunnel hook" || echo "old tunnel hook already gone"
