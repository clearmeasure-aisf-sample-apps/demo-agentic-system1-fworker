#!/usr/bin/env bash
# fwrunner.sh: the entrypoint of the fwrunner image. One Container Apps Job execution = one factory worker session = one work item
# (docs/design/cloud-worker-runtimes.md, section 2.2). There is no loop: the next item is a new execution.
#
#   1. redeem the one-time nonce at POST <gateway>/api/v1/runtime/redeem for the worker token (w2) of this execution;
#   2. download the plugin (GET /api/v1/plugin) and clone the work-orders repository shallowly;
#   3. write the connect prompt from the template (it names the variable that holds the credential, never the credential);
#   4. run the agent headless, FACTORY_SESSION_END_FILE set. FWRUNNER_AGENT chooses it:
#        claude (default)  `claude -p` with the reviewed settings file, the model and effort the gateway chose;
#        codex             `codex exec --json` on Azure OpenAI (AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT), keyless: Codex gets an Entra
#                          token of the job's managed identity from /usr/local/bin/fwrunner-entra-token and refreshes it itself; the policy
#                          is runner/codex/ (config, execpolicy rules) and the skills reach Codex as a generated $CODEX_HOME/AGENTS.md;
#   5. end marker seen: wait 5 s, TERM, KILL after 10 s, exit 0. The agent ended without the marker, or the watchdog fired: exit 1.
#
# Watchdog (the launcher's codes, without screen checks): stream-disconnected = the client's stream-alive file not touched for
# FWRUNNER_STREAM_STALE seconds; no-output-while-owning = no new transcript bytes for FWRUNNER_SILENT seconds while the session holds an item.
# stdout carries one redacted, shortened line per stream-json event; the full transcript stays on the ephemeral disk and goes only to the
# private blob container (FWRUNNER_TRANSCRIPT_CONTAINER) at exit.
#
# Environment (set per execution by the gateway's adapter on the job template; none is a credential):
#   FWRUNNER_GATEWAY_URL   gateway base URL (required)            FWRUNNER_NONCE   one-time nonce (required; spent by the redeem)
#   FWRUNNER_NAME          worker name cae-<item>-<hex> (required) FWRUNNER_ENV     environment name for the prompt (default tdd)
#   FWRUNNER_AGENT         claude (default) or codex
#   FWRUNNER_MODEL, FWRUNNER_EFFORT   model and effort for claude (optional); codex takes the effort (max -> xhigh) and uses the deployment
#   AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT   codex only (required for it); AZURE_CLIENT_ID picks the managed identity
#   FWRUNNER_CODEX_SANDBOX  codex sandbox_mode (default danger-full-access: the container is the boundary, as for claude's auto mode)
#   FWRUNNER_REPO          repository to clone (default the demo-agentic-system1-workorders GitHub URL)
#   FWRUNNER_TRANSCRIPT_CONTAINER     blob container URL for the transcript upload (optional; managed identity of the job)
#   FWRUNNER_STREAM_STALE (600), FWRUNNER_SILENT (1800), FWRUNNER_MAX_SECONDS (0 = off; the job's replicaTimeout is the hard end)
#   FWRUNNER_HOME (/work), FWRUNNER_SETTINGS (/etc/fworker/settings.json), FWRUNNER_TEMPLATE (/etc/fworker/connect-prompt.template.md),
#   FWRUNNER_CLAUDE (claude), FWRUNNER_CODEX (codex), FWRUNNER_CODEX_DIR (/etc/fworker/codex), FWRUNNER_TOKEN_CMD
#   (/usr/local/bin/fwrunner-entra-token): overridable for tests/runner/fwrunner.test.sh.
set -u
set -o pipefail

say() { printf '%s fwrunner %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${FWRUNNER_NAME:-?}" "$*"; }
fail() { say "FAILED: $*"; finish 1; }

home=${FWRUNNER_HOME:-/work}
settings=${FWRUNNER_SETTINGS:-/etc/fworker/settings.json}
template=${FWRUNNER_TEMPLATE:-/etc/fworker/connect-prompt.template.md}
agent=${FWRUNNER_AGENT:-claude}
case "$agent" in
    claude) agentCmd=${FWRUNNER_CLAUDE:-claude} ;;
    codex) agentCmd=${FWRUNNER_CODEX:-codex} ;;
    *) agentCmd='' ;;
esac
codexDir=${FWRUNNER_CODEX_DIR:-/etc/fworker/codex}
tokenCmd=${FWRUNNER_TOKEN_CMD:-/usr/local/bin/fwrunner-entra-token}
# the runtime adapter of the gateway (gateway/Runtimes/CaeJobRuntime.cs) names the execution's values FWORKER_*; FWRUNNER_* wins when both are set
: "${FWRUNNER_GATEWAY_URL:=${FWORKER_GATEWAY_URL:-}}" "${FWRUNNER_NAME:=${FWORKER_NAME:-}}" "${FWRUNNER_NONCE:=${FWORKER_NONCE:-}}"
unset FWORKER_NONCE
url=${FWRUNNER_GATEWAY_URL:-}; url=${url%/}
name=${FWRUNNER_NAME:-}
repo=${FWRUNNER_REPO:-https://github.com/clearmeasure-aisf-sample-apps/demo-agentic-system1-workorders.git}
streamStale=${FWRUNNER_STREAM_STALE:-600}; silent=${FWRUNNER_SILENT:-1800}; maxSeconds=${FWRUNNER_MAX_SECONDS:-0}
marker="$home/session-ended"; alive="$home/stream-alive"; owning="$home/session-owning"
transcript="$home/transcript.jsonl"; runlog="$home/fwrunner.log"
child=0; pump=0; finished=0

# the mask applied to everything this script prints that came from the session: w1./w2./i1. worker and item tokens, GitHub installation
# tokens (ghs_) and Anthropic keys (sk-ant-)
redact() { sed -u -E 's/\b(w1|w2|i1)\.[A-Za-z0-9._~+\/=-]+/\1.***/g; s/(ghs_|ghp_|gho_|ghu_|github_pat_|sk-ant-)[A-Za-z0-9_-]+/\1***/g; s/(Bearer )[A-Za-z0-9._~+\/=-]+/\1***/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/eyJ***/g'; }

# the transcript to the private blob container, with the job's managed identity (Container Apps: IDENTITY_ENDPOINT, IDENTITY_HEADER)
upload_transcript() {
    local container=${FWRUNNER_TRANSCRIPT_CONTAINER:-}
    [ -n "$container" ] && [ -s "$transcript" ] || return 0
    if [ -z "${IDENTITY_ENDPOINT:-}" ] || [ -z "${IDENTITY_HEADER:-}" ]; then say "transcript not uploaded: no managed identity endpoint"; return 0; fi
    local q="api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F" at
    [ -n "${AZURE_CLIENT_ID:-}" ] && q="$q&client_id=$AZURE_CLIENT_ID"
    at=$(curl -fsS --max-time 30 -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" "$IDENTITY_ENDPOINT?$q" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).access_token||"")}catch{}})') || at=''
    if [ -z "$at" ]; then say "transcript not uploaded: no storage token for the managed identity"; return 0; fi
    local blob="${container%/}/$(date -u +%Y-%m-%d)/${name}-${CONTAINER_APP_JOB_EXECUTION_NAME:-local}.jsonl"
    if curl -fsS --max-time 300 -X PUT -H @<(printf 'Authorization: Bearer %s\n' "$at") -H "x-ms-version: 2021-08-06" -H "x-ms-blob-type: BlockBlob" \
        -H "Content-Type: application/x-ndjson" --data-binary "@$transcript" "$blob" -o /dev/null; then
        say "transcript uploaded ($(wc -c < "$transcript") bytes)"
    else say "transcript upload failed"; fi
}

# stop the agent: TERM, KILL after 10 s
stop_child() {
    [ "$child" -gt 0 ] || return 0
    kill -TERM "$child" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
    if kill -0 "$child" 2>/dev/null; then say "$agent did not stop on TERM within 10 s: KILL"; kill -KILL "$child" 2>/dev/null; fi
    wait "$child" 2>/dev/null; child=0
}

finish() {
    [ "$finished" -eq 0 ] || exit "$1"; finished=1
    trap '' INT TERM     # a second TERM must not cut the stop and the upload short (the job's termination grace should be 60 s or more)
    stop_child
    [ "$pump" -gt 0 ] && { wait "$pump" 2>/dev/null; pump=0; }
    # the agent's stderr (auth errors, a refused flag, a crash): its last lines, redacted, reach the log destination
    [ -s "$runlog" ] && { say "$agent stderr (last 50 lines):"; tail -n 50 "$runlog" | redact; }
    upload_transcript
    say "exit $1"
    exit "$1"
}
trap 'say "signal: stopping"; finish 1' INT TERM

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
size() { stat -c %s "$1" 2>/dev/null || echo 0; }
json_field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(v==null?"":String(v))}catch{}})' "$1"; }

[ -n "$url" ] || fail "FWRUNNER_GATEWAY_URL is not set"
[ -n "$name" ] || fail "FWRUNNER_NAME is not set"
[ -n "${FWRUNNER_NONCE:-}" ] || fail "FWRUNNER_NONCE is not set"
case "$FWRUNNER_NONCE" in *[!A-Za-z0-9_.~-]*) fail "FWRUNNER_NONCE has characters outside [A-Za-z0-9_.~-]" ;; esac
case "$name" in *[!A-Za-z0-9._-]*) fail "FWRUNNER_NAME has characters outside [A-Za-z0-9._-]" ;; esac
case "$streamStale$silent$maxSeconds" in *[!0-9]*) fail "FWRUNNER_STREAM_STALE, FWRUNNER_SILENT and FWRUNNER_MAX_SECONDS are whole seconds" ;; esac
[ -f "$settings" ] || fail "no settings file at $settings"
[ -f "$template" ] || fail "no prompt template at $template"
[ -n "$agentCmd" ] || fail "FWRUNNER_AGENT must be claude or codex, not $agent"
command -v "$agentCmd" >/dev/null 2>&1 || fail "$agentCmd is not on the PATH"
if [ "$agent" = codex ]; then
    [ -n "${AZURE_OPENAI_ENDPOINT:-}" ] || fail "AZURE_OPENAI_ENDPOINT is not set (codex)"
    [ -n "${AZURE_OPENAI_DEPLOYMENT:-}" ] || fail "AZURE_OPENAI_DEPLOYMENT is not set (codex)"
    # the Entra token goes to this host: only an Azure OpenAI or Cognitive Services host, without characters that could break config.toml
    case "$AZURE_OPENAI_ENDPOINT" in *[!A-Za-z0-9./:-]*) fail "AZURE_OPENAI_ENDPOINT has characters outside [A-Za-z0-9./:-]" ;; esac
    [[ "$AZURE_OPENAI_ENDPOINT" =~ ^https://[a-z0-9-]+\.(openai\.azure\.com|cognitiveservices\.azure\.com)/?$ ]] \
        || fail "AZURE_OPENAI_ENDPOINT must be https://<resource>.openai.azure.com/"
    case "$tokenCmd" in *[!A-Za-z0-9./_-]*) fail "FWRUNNER_TOKEN_CMD has characters outside [A-Za-z0-9./_-]" ;; esac
    case "$AZURE_OPENAI_DEPLOYMENT" in *[!A-Za-z0-9._-]*) fail "AZURE_OPENAI_DEPLOYMENT has characters outside [A-Za-z0-9._-]" ;; esac
    for f in config.toml.template fworker.rules agents-preamble.md; do [ -f "$codexDir/$f" ] || fail "no $f in $codexDir"; done
    [ -x "$tokenCmd" ] || fail "no token command at $tokenCmd"
    # keyless only: an API key in the environment is refused, never used
    [ -z "${AZURE_OPENAI_API_KEY:-}${OPENAI_API_KEY:-}${CODEX_API_KEY:-}${AZURE_OPENAI_AD_TOKEN:-}" ] || fail "an API key is set; codex authenticates with the managed identity only"
fi
mkdir -p "$home/data" "$home/plugin" || fail "cannot create $home"
rm -f "$marker" "$marker.reason" "$alive" "$owning"
say "starts (gateway $url)"

# 1. redeem the nonce: the response carries the worker token; the nonce is spent, so a copy read from ARM afterwards is worthless
body=$(printf '{"nonce":"%s","name":"%s"}' "$FWRUNNER_NONCE" "$name")
unset FWRUNNER_NONCE
# retried only while the gateway refuses connections: a retry after a timeout could meet a nonce the first attempt already spent
resp=$(curl -sS --max-time 30 --retry 5 --retry-connrefused --retry-max-time 60 -X POST -H 'Content-Type: application/json' --data-binary @- \
    -w '\n%{http_code}' "$url/api/v1/runtime/redeem" <<< "$body") || fail "redeem: the gateway did not answer"
code=${resp##*$'\n'}; resp=${resp%$'\n'*}
[ "$code" = 200 ] || fail "redeem: HTTP $code $(printf '%s' "$resp" | json_field code)"
token=$(printf '%s' "$resp" | json_field token)
rname=$(printf '%s' "$resp" | json_field name)
[ -n "$token" ] || fail "redeem: no token in the answer"
[ -z "$rname" ] || [ "$rname" = "$name" ] || fail "redeem: the token is for $rname, not $name"
say "nonce redeemed"

# the session's environment: the credential by variable name only; no model key ever (the model is reached with the managed identity)
export FACTORY_URL="$url" FACTORY_TOKEN="$token" FACTORY_HOLDER="$name" FACTORY_DATA_DIR="$home/data" FACTORY_SESSION_END_FILE="$marker"
export GIT_TERMINAL_PROMPT=0     # no credential from the helper (no item owned yet) must fail the git command, not wait for a prompt
# Claude Code telemetry tags (design 2.9); the item is not known until it is offered, the worker name carries it
export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:+$OTEL_RESOURCE_ATTRIBUTES,}fworker.worker=$name,fworker.runtime=cae-job,fworker.agent=$agent"
unset token resp body ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN AZURE_OPENAI_API_KEY OPENAI_API_KEY CODEX_API_KEY AZURE_OPENAI_AD_TOKEN

# 2. the plugin, in exactly the gateway's version
curl -fsS --max-time 120 --retry 3 -H @<(printf 'Authorization: Bearer %s\n' "$FACTORY_TOKEN") "$url/api/v1/plugin" -o "$home/plugin.tgz" \
    || fail "plugin download failed"
tar -xzf "$home/plugin.tgz" -C "$home/plugin" || fail "plugin archive did not unpack"
rm -f "$home/plugin.tgz"
[ -f "$home/plugin/scripts/factory.ps1" ] || fail "the plugin has no scripts/factory.ps1"
say "plugin downloaded"

# 2b. the repository, shallow (pushes authenticate through git-credential-fworker once an item is owned)
repoDir="$home/repo"
git clone --quiet --depth 1 "$repo" "$repoDir" 2>&1 | redact || fail "clone of the repository failed"
[ -d "$repoDir/.git" ] || fail "clone of the repository failed"
say "repository cloned"

# 3. the connect prompt; written to a file of the execution's disk, never to stdout
prompt="$home/connect-prompt.md"
esc() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }
sed -e "s|{{ENV}}|$(esc "${FWRUNNER_ENV:-tdd}")|g" -e "s|{{BASE}}|$(esc "$home")|g" -e "s|{{SCRIPTS}}|$(esc "$home/plugin/scripts")|g" \
    -e "s|{{REPO_DIR}}|$(esc "$repoDir")|g" -e "s|{{REPO}}|$(esc "$repo")|g" -e "s|{{NAME}}|$(esc "$name")|g" \
    "$template" > "$prompt" || fail "cannot write the connect prompt"
grep -q '{{' "$prompt" && fail "the connect prompt has an unfilled placeholder"

# 3b. codex: its home with the filled config, the execpolicy rules and AGENTS.md (the plugin's skills and the connect prompt); the prompt on
# stdin only starts the session. The token command is tried once here, so a missing role assignment fails before the session starts.
if [ "$agent" = codex ]; then
    export CODEX_HOME="$home/codex"
    mkdir -p "$CODEX_HOME/rules" || fail "cannot create $CODEX_HOME"
    case "${FWRUNNER_EFFORT:-high}" in minimal|low|medium|high|xhigh) effort=${FWRUNNER_EFFORT:-high} ;; max) effort=xhigh ;; *) effort=high ;; esac
    sandbox=${FWRUNNER_CODEX_SANDBOX:-danger-full-access}
    case "$sandbox" in read-only|workspace-write|danger-full-access) ;; *) fail "FWRUNNER_CODEX_SANDBOX must be read-only, workspace-write or danger-full-access" ;; esac
    base="${AZURE_OPENAI_ENDPOINT%/}/openai/v1"
    sed -e "s|{{DEPLOYMENT}}|$(esc "$AZURE_OPENAI_DEPLOYMENT")|g" -e "s|{{EFFORT}}|$effort|g" -e "s|{{SANDBOX}}|$sandbox|g" \
        -e "s|{{BASE_URL}}|$(esc "$base")|g" -e "s|/usr/local/bin/fwrunner-entra-token|$(esc "$tokenCmd")|g" \
        "$codexDir/config.toml.template" > "$CODEX_HOME/config.toml" || fail "cannot write the codex config"
    cp "$codexDir/fworker.rules" "$CODEX_HOME/rules/fworker.rules" || fail "cannot copy the codex rules"
    {
        sed -e "s|{{BASE}}|$(esc "$home")|g" "$codexDir/agents-preamble.md"
        printf '## Connect prompt\n\n'; cat "$prompt"; printf '\n\n## Skills of the factory plugin\n\n'
        for f in "$home"/plugin/skills/*/SKILL.md; do
            [ -f "$f" ] || continue
            d=$(sed -n 's/^description: *//p' "$f" | head -n 1)
            printf -- '- %s (%s): %s\n' "$(basename "$(dirname "$f")")" "$f" "$d"
        done
        if [ -f "$home/plugin/skills/factory-owner-session/SKILL.md" ]; then
            printf '\n## The skill factory-owner-session, in full\n\n'; awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{f=0;next} !f' "$home/plugin/skills/factory-owner-session/SKILL.md"
        fi
    } > "$CODEX_HOME/AGENTS.md" || fail "cannot write AGENTS.md"
    grep -q '{{' "$CODEX_HOME/config.toml" && fail "the codex files have an unfilled placeholder"
    # read-only for the session: the policy files cannot be changed for a later re-read
    chmod 0444 "$CODEX_HOME/config.toml" "$CODEX_HOME/rules/fworker.rules" "$CODEX_HOME/AGENTS.md" && chmod 0555 "$CODEX_HOME/rules" || fail "cannot protect the codex files"
    "$tokenCmd" > /dev/null 2>> "$runlog" || fail "no Entra token for Azure OpenAI from the managed identity (see the stderr lines)"
    say "codex home ready (deployment $AZURE_OPENAI_DEPLOYMENT, effort $effort, sandbox $sandbox)"
fi

# 4. the session
if [ "$agent" = codex ]; then
    args=(exec --json --strict-config -C "$repoDir" -m "$AZURE_OPENAI_DEPLOYMENT" -)
    printf 'Follow the section "Connect prompt" of your AGENTS.md now, starting at CONNECT step 1. You are worker %s.\n' "$name" > "$prompt.start"
    input="$prompt.start"
else
    args=(-p --output-format stream-json --verbose --settings "$settings")
    [ -n "${FWRUNNER_MODEL:-}" ] && args+=(--model "$FWRUNNER_MODEL")
    [ -n "${FWRUNNER_EFFORT:-}" ] && args+=(--effort "$FWRUNNER_EFFORT")
    input="$prompt"
fi
: > "$transcript"
started=$(date +%s)
if [ "$agent" = codex ]; then say "codex starts (deployment $AZURE_OPENAI_DEPLOYMENT)"; else say "claude starts (model ${FWRUNNER_MODEL:-default}, effort ${FWRUNNER_EFFORT:-default})"; fi
( cd "$repoDir" && exec "$agentCmd" "${args[@]}" < "$input" ) >> "$transcript" 2>> "$runlog" &
child=$!
# one short, redacted line per stream-json event on stdout (Log Analytics); the full transcript stays in the file
( tail -n +1 -F --pid="$child" "$transcript" 2>/dev/null \
    | sed -u -E 's/^\{"type":"([a-z_.]+)"(,"subtype":"([a-z_]+)")?.*$/[\1 \3] &/' | redact | sed -u -E 's/^(.{240}).+$/\1 .../' ) &
pump=$!

why=''; ok=0; lastSize=0; lastGrowth=$started
while kill -0 "$child" 2>/dev/null; do
    now=$(date +%s)
    if [ -e "$marker" ]; then
        why=$(cat "$marker.reason" 2>/dev/null); [ -n "$why" ] || why='end-session: the worker ended its session'
        say "end marker: $why"; ok=1
        sleep 5     # the worker's last lines are written
        break
    fi
    s=$(size "$transcript"); if [ "$s" -ne "$lastSize" ]; then lastSize=$s; lastGrowth=$now; fi
    if [ "$streamStale" -gt 0 ]; then
        ref=$started; [ -e "$alive" ] && ref=$(mtime "$alive"); [ "$ref" -ge "$started" ] || ref=$started
        if [ $((now - ref)) -ge "$streamStale" ]; then why="watchdog stream-disconnected: no line on the event stream for $((now - ref)) s"; break; fi
    fi
    if [ "$silent" -gt 0 ] && [ -e "$owning" ] && [ $((now - lastGrowth)) -ge "$silent" ]; then
        why="watchdog no-output-while-owning: no transcript bytes for $((now - lastGrowth)) s while the session holds item $(cat "$owning" 2>/dev/null)"; break
    fi
    if [ "$maxSeconds" -gt 0 ] && [ $((now - started)) -ge "$maxSeconds" ]; then why="watchdog max-seconds: the session ran $((now - started)) s"; break; fi
    sleep 2
done
if [ -z "$why" ]; then
    wait "$child" 2>/dev/null; code=$?; child=0
    if [ -e "$marker" ]; then ok=1; say "$agent exited ($code) after the end marker"
    else say "$agent exited by itself ($code) without the end marker"; fi
else
    [ "$ok" -eq 1 ] || say "$why"
fi
finish $((1 - ok))
