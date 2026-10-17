#!/bin/bash
# Writes the connect prompt of one gateway environment to a private file (mode 600), using the dashboard's own generator, so the file is
# exactly what the dashboard's "Create prompt" button produces for the same gateway state (messaging and the supervisor on or off, as the
# gateway's dashboard JSON says). The credential is minted by the gateway and never printed.
# usage: gen-connect-prompt.sh <tdd|uat|prod> <name> <type> <capacity> <out-file> [gateway-url]
#        gen-connect-prompt.sh <tdd|uat|prod> <name> supervisor - <out-file> [gateway-url]
#        gen-connect-prompt.sh <tdd|uat|prod> <name> operator - <out-file> [gateway-url]
#   type operator: the operator session's prompt, as the "Factory operator" kind of the dashboard writes it; the name must be in operator.allowedNames
#   (default operator-session) and the credential is minted with role=operator. It is an operator SESSION credential, not the admin token.
#   type supervisor: the supervisor's prompt, as the "Create supervisor prompt" button writes it; the name must be in manager.allowedNames and the
#   credential is minted with role=manager (the capacity argument is not used).
# The operator token comes from the environment variable FACTORY_OPERATOR_TOKEN (a session without a keyring, such as a cloud session, gets
# it as an environment secret) or, when that is not set, from the keyring (service factory-worker, kind fworker-dev-token-<env>). It is in no
# file of this repository. Needs curl and node on THIS machine (the operator's); the worker machine needs nothing but what the prompt downloads.
set -euo pipefail
ENVN=$1; NAME=$2; TYPE=$3; CAP=$4; OUT=$5; URL=${6:-}
if ! printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9_-]{1,40}$'; then echo "name: letters, digits, - and _ (40 at most)" >&2; exit 2; fi
if [ -z "$URL" ]; then
  case "$ENVN" in
    tdd)  URL=https://ca-cmdemo1-tdd-fworker.graybush-19a6e13b.southcentralus.azurecontainerapps.io ;;
    prod) URL=https://ca-cmdemo1-prod-fworker-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io ;;
    *) echo "give the gateway url for $ENVN" >&2; exit 2 ;;
  esac
fi
URL=${URL%/}
TOK=${FACTORY_OPERATOR_TOKEN:-}
if [ -z "$TOK" ]; then TOK=$(secret-tool lookup service factory-worker kind "fworker-dev-token-$ENVN" 2>/dev/null || true); fi
[ -n "$TOK" ] || { echo "no operator token: set FACTORY_OPERATOR_TOKEN or store it in the keyring" >&2; exit 2; }
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"; T=$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}"); trap 'rm -rf "$T"' EXIT
auth() { curl -fsS -H @<(printf 'Authorization: Bearer %s' "$TOK") "$@"; }
# RENDER_SOURCE=<path to gateway/Program.cs> renders with the generator of a source tree that is not deployed yet
if [ -n "${RENDER_SOURCE:-}" ]; then cp "$RENDER_SOURCE" "$T/dashboard.html"; else curl -fsS "$URL/dashboard" -o "$T/dashboard.html"; fi
SUP=0; if [ "$TYPE" = supervisor ]; then SUP=1; fi; if [ "$TYPE" = operator ]; then SUP=2; fi
if [ "$SUP" = 2 ]; then auth -X POST "$URL/api/v1/workers/$NAME/credential?role=operator" -o "$T/cred.json"; elif [ "$SUP" = 1 ]; then auth -X POST "$URL/api/v1/workers/$NAME/credential?role=manager" -o "$T/cred.json"; else auth -X POST "$URL/api/v1/workers/$NAME/credential" -o "$T/cred.json"; fi
auth "$URL/api/v1/dashboard" -o "$T/info.json"
auth "$URL/api/v1/qc" -o "$T/qc.json" || echo '{}' > "$T/qc.json"
T="$T" NAME="$NAME" TYPE="$TYPE" CAP="$CAP" OUT="$OUT" SUP="$SUP" node -e '
const fs=require("fs"),e=process.env,rd=f=>fs.readFileSync(e.T+"/"+f,"utf8");
const m=rd("dashboard.html").match(/\/\*render-start\*\/([\s\S]*)\/\*render-end\*\//);
if(!m){console.error("no render block in the dashboard");process.exit(1)}
const info=JSON.parse(rd("info.json")),cred=JSON.parse(rd("cred.json")),qc=JSON.parse(rd("qc.json"));
const f=new Function(m[1]+"\nreturn buildPrompt;");
if(!cred.token){console.error("the gateway issued no credential");process.exit(1)}
// the argument objects of the two dashboard buttons (gateway/Program.cs, DashboardPage: mk and mksup)
const on=!!(info.messaging&&info.messaging.enabled);
const arg=e.SUP==="2"?{env:info.environment,url:info.url,token:cred.token,name:e.NAME,operator:true}:e.SUP==="1"?{env:info.environment,url:info.url,token:cred.token,name:e.NAME,supervisor:true}
:{env:info.environment,url:info.url,token:cred.token,name:e.NAME,type:e.TYPE,cap:e.CAP,repo:qc.repo_url||"",qcProfile:"",qcAddress:"",qcCapacity:"",messaging:on,asking:!!(on&&info.manager&&info.manager.enabled)};
const text=f()(arg);
fs.writeFileSync(e.OUT,text+"\n",{mode:0o600});
'
chmod 600 "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes, $ENVN, $NAME)"
