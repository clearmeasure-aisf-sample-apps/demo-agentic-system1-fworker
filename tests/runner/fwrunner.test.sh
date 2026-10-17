#!/usr/bin/env bash
# Shell test of the fwrunner image's entrypoint and credential helper (runner/fwrunner.sh, runner/git-credential-fworker) against a stub gateway
# (stub-gateway.js) a fake claude (fake-claude.sh) and a fake codex (fake-codex.sh). Needs bash, node, git, curl, tar. No network beyond 127.0.0.1, no secret.
#   bash tests/runner/fwrunner.test.sh                 # against runner/ of this checkout
#   docker run --rm -v "$PWD:/src:ro" --entrypoint bash fwrunner /src/tests/runner/fwrunner.test.sh   # inside the image
# FWRUNNER_TEST_SHOW=1 prints the stdout of the normal run. Exit 0 when every check passes.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
runner=${FWRUNNER_SH:-$root/runner/fwrunner.sh}; helper=$root/runner/git-credential-fworker
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fwrunner-test.XXXXXX"); stub=0
cleanup() { [ "$stub" -gt 0 ] && kill "$stub" 2>/dev/null; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
pass=0; failed=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1"; fi; }

# a fake plugin and a local repository to clone
mkdir -p "$tmp/plugin-src/scripts" "$tmp/plugin-src/skills/factory-owner-session" "$tmp/origin"
echo '# fake' > "$tmp/plugin-src/scripts/factory.ps1"
printf -- '---\nname: factory-owner-session\ndescription: Use when a factory assignment arrives.\n---\n\nOWNER-SESSION-BODY\n' > "$tmp/plugin-src/skills/factory-owner-session/SKILL.md"
tar -czf "$tmp/plugin.tgz" -C "$tmp/plugin-src" .
git -C "$tmp/origin" init -q -b master && git -C "$tmp/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
node "$here/stub-gateway.js" "$tmp/port" "$tmp/plugin.tgz" & stub=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
gw="http://127.0.0.1:$(cat "$tmp/port")"
secret() { curl -s "$gw/_stub/secrets" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s)[process.argv[1]]||""))' "$1"; }
nonce=$(secret nonce)

# run NAME MODE [NONCE] [extra env...]: one execution in its own home; stdout in $tmp/NAME.out, exit code in $tmp/NAME.code
run() {
    local n=$1 mode=$2 nn=${3:-$nonce}; shift 3 2>/dev/null || shift $#
    mkdir -p "$tmp/$n"
    ( env FWRUNNER_HOME="$tmp/$n/work" FWRUNNER_GATEWAY_URL="$gw" FWRUNNER_NAME="cae-42-$n" FWRUNNER_NONCE="$nn" \
        FWRUNNER_REPO="file://$tmp/origin" FWRUNNER_SETTINGS="$root/runner/settings.json" FWRUNNER_TEMPLATE="$root/runner/connect-prompt.template.md" \
        FWRUNNER_CLAUDE="$here/fake-claude.sh" FAKE_MODE="$mode" FWRUNNER_MODEL=claude-sonnet-5-5 FWRUNNER_EFFORT=high ANTHROPIC_API_KEY=should-be-unset "$@" \
        bash "$runner" > "$tmp/$n.out" 2>&1; echo $? > "$tmp/$n.code" )
}
code() { cat "$tmp/$1.code"; }

echo "end marker: redeem, plugin, clone, prompt, session, exit 0"
run normal end
w="$tmp/normal/work"
check "exit 0" '[ "$(code normal)" = 0 ]'
check "nonce redeemed, plugin downloaded" 'grep -q "nonce redeemed" "$tmp/normal.out" && grep -q "plugin downloaded" "$tmp/normal.out" && [ -f "$w/plugin/scripts/factory.ps1" ]'
check "repository cloned" '[ -d "$w/repo/.git" ]'
check "claude ran in the checkout with the token in its env, no model key" 'grep -qx token-set "$w/seen-env" && ! grep -q api-key-set "$w/seen-env" && grep -qx "$w/repo" "$w/seen-env"'
check "FACTORY_SESSION_END_FILE is the marker" 'grep -qx "$w/session-ended" "$w/seen-env"'
check "claude args: -p, stream-json, settings, model, effort" 'grep -qx -- -p "$w/seen-args" && grep -qx stream-json "$w/seen-args" && grep -qx "$root/runner/settings.json" "$w/seen-args" && grep -qx claude-sonnet-5-5 "$w/seen-args" && grep -qx high "$w/seen-args"'
check "prompt filled, names the worker, holds no credential" 'grep -q "cae-42-normal" "$w/seen-prompt" && ! grep -q "{{" "$w/seen-prompt" && ! grep -q "w2\." "$w/seen-prompt"'
check "end marker handled" 'grep -q "end marker: end-session: item 42 ended" "$tmp/normal.out"'
check "stdout redacted: no w2 token, no ghs_, no sk-ant- value" '! grep -q "$(secret workerToken)" "$tmp/normal.out" && grep -q "w2\.\*\*\*" "$tmp/normal.out" && grep -q "ghs_\*\*\*" "$tmp/normal.out" && grep -q "sk-ant-\*\*\*" "$tmp/normal.out" && ! grep -q ZZZZ "$tmp/normal.out"'
check "full transcript kept on the execution disk" 'grep -q ZZZZ "$w/transcript.jsonl"'
check "nonce is single use" '[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "{\"nonce\":\"$nonce\",\"name\":\"x\"}" "$gw/api/v1/runtime/redeem")" = 410 ]'

[ -z "${FWRUNNER_TEST_SHOW:-}" ] || sed 's/^/    | /' "$tmp/normal.out"

echo "spent nonce: exit 1 before claude"
run spent end
check "exit 1, refused at redeem" '[ "$(code spent)" = 1 ] && grep -q "redeem: HTTP 410 nonce-spent" "$tmp/spent.out" && [ ! -e "$tmp/spent/work/seen-args" ]'

echo "unknown nonce: exit 1 before claude"
run stuck end-stuck "$nonce-unknown"
check "exit 1, refused at redeem" '[ "$(code stuck)" = 1 ] && grep -q "bad-nonce" "$tmp/stuck.out"'

# the stub has one nonce; the next runs reuse the redeem by a fresh stub per run
restart_stub() { kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null; rm -f "$tmp/port"; node "$here/stub-gateway.js" "$tmp/port" "$tmp/plugin.tgz" & stub=$!; for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done; gw="http://127.0.0.1:$(cat "$tmp/port")"; }
echo "claude ignores TERM after the end marker: KILL after 10 s, exit 0"
restart_stub; t0=$(date +%s); run stuck2 end-stuck; t1=$(date +%s)
check "exit 0 and KILL logged" '[ "$(code stuck2)" = 0 ] && grep -q "did not stop on TERM within 10 s: KILL" "$tmp/stuck2.out"'
check "ended within 2 + 5 + 10 s (plus start)" '[ $((t1 - t0)) -le 30 ]'

echo "claude exits without the marker: exit 1"
restart_stub; run noend exit
check "exit 1" '[ "$(code noend)" = 1 ] && grep -q "exited by itself (3) without the end marker" "$tmp/noend.out"'

echo "watchdog: no stream"
restart_stub; run stale stale "$nonce" FWRUNNER_STREAM_STALE=3
check "exit 1 stream-disconnected" '[ "$(code stale)" = 1 ] && grep -q "watchdog stream-disconnected" "$tmp/stale.out"'

echo "watchdog: no transcript bytes while owning"
restart_stub; run mute mute "$nonce" FWRUNNER_SILENT=4
check "exit 1 no-output-while-owning" '[ "$(code mute)" = 1 ] && grep -q "watchdog no-output-while-owning" "$tmp/mute.out"'

# codex: runc NAME MODE [extra env...]: one codex execution against a fresh stub, with the stub's identity endpoint
runc() {
    local n=$1 mode=$2; shift 2
    restart_stub
    run "$n" "$mode" "$(secret nonce)" FWRUNNER_AGENT=codex FWRUNNER_CODEX="$here/fake-codex.sh" FWRUNNER_CODEX_DIR="$root/runner/codex" \
        FWRUNNER_TOKEN_CMD="$root/runner/fwrunner-entra-token" AZURE_OPENAI_ENDPOINT=https://aif-test.openai.azure.com/ AZURE_OPENAI_DEPLOYMENT=gpt-6.1-sol \
        AZURE_CLIENT_ID=45fb5295-b075-4e74-a1dc-569dda4b62a1 IDENTITY_ENDPOINT="$gw/msi/token" IDENTITY_HEADER="$(secret idHeader)" "$@"
}
echo "codex: keyless Azure OpenAI, AGENTS.md from the skills, exit 0"
runc cx end
w="$tmp/cx/work"
check "exit 0, codex ran in the checkout with the worker token and no key" '[ "$(code cx)" = 0 ] && grep -qx token-set "$w/seen-env" && ! grep -q api-key-set "$w/seen-env" && grep -qx "$w/repo" "$w/seen-env"'
check "codex args: exec --json --strict-config -C repo -m deployment, prompt on stdin" 'grep -qx exec "$w/seen-args" && grep -qx -- --json "$w/seen-args" && grep -qx -- --strict-config "$w/seen-args" && grep -qx "$w/repo" "$w/seen-args" && grep -qx gpt-6.1-sol "$w/seen-args" && grep -qx -- - "$w/seen-args" && grep -q "cae-42-cx" "$w/seen-prompt"'
check "config: v1 base_url, deployment, approval never, auth command, no key variable, effort high" 'c="$w/codex/config.toml"; grep -qx "base_url = \"https://aif-test.openai.azure.com/openai/v1\"" "$c" && grep -qx "model = \"gpt-6.1-sol\"" "$c" && grep -qx "approval_policy = \"never\"" "$c" && grep -qx "command = \"$root/runner/fwrunner-entra-token\"" "$c" && ! grep -q "^env_key" "$c" && grep -qx "model_reasoning_effort = \"high\"" "$c" && ! grep -q "{{" "$c"'
check "execpolicy rules in CODEX_HOME/rules" 'cmp -s "$root/runner/codex/fworker.rules" "$w/codex/rules/fworker.rules"'
check "AGENTS.md: preamble, connect prompt, skill index, owner-session body, no credential" 'a="$w/codex/AGENTS.md"; grep -q "There are no subagents in this session" "$a" && grep -q "cae-42-cx" "$a" && grep -q "^- factory-owner-session (" "$a" && grep -q OWNER-SESSION-BODY "$a" && ! grep -q "^name: factory-owner-session" "$a" && ! grep -q "w2\." "$a" && ! grep -q "{{" "$a"'
check "the auth command returns the managed identity token for cognitiveservices" 'grep -qx "bearer=$(secret msiToken)" "$w/seen-env"'
check "stdout redacted: no worker token, no Entra token" '! grep -q "$(secret workerToken)" "$tmp/cx.out" && ! grep -q "$(secret msiToken)" "$tmp/cx.out" && grep -q "eyJ\*\*\*" "$tmp/cx.out" && grep -q "codex home ready" "$tmp/cx.out"'
check "full transcript kept, JSONL events on stdout" 'grep -q thread.started "$w/transcript.jsonl" && grep -q "\[thread.started" "$tmp/cx.out"'

check "no worker or Entra token in AGENTS.md or config.toml; both read-only" '! grep -qF "$(secret workerToken)" "$w/codex/AGENTS.md" "$w/codex/config.toml" && ! grep -qF "$(secret msiToken)" "$w/codex/AGENTS.md" "$w/codex/config.toml" && [ ! -w "$w/codex/config.toml" ] && [ ! -w "$w/codex/rules/fworker.rules" ]'

echo "adapter variable names (FWORKER_*) are accepted"
restart_stub
( env FWRUNNER_HOME="$tmp/fw/work" FWORKER_GATEWAY_URL="$gw" FWORKER_NAME=cae-42-fw FWORKER_NONCE="$(secret nonce)" FWRUNNER_REPO="file://$tmp/origin" \
    FWRUNNER_SETTINGS="$root/runner/settings.json" FWRUNNER_TEMPLATE="$root/runner/connect-prompt.template.md" FWRUNNER_CLAUDE="$here/fake-claude.sh" FAKE_MODE=end \
    bash "$runner" > "$tmp/fw.out" 2>&1; echo $? > "$tmp/fw.code" )
check "exit 0 with FWORKER_GATEWAY_URL, FWORKER_NAME, FWORKER_NONCE" '[ "$(code fw)" = 0 ] && grep -q "nonce redeemed" "$tmp/fw.out"'

echo "codex: effort max maps to xhigh"
runc cxmax end FWRUNNER_EFFORT=max
check "model_reasoning_effort xhigh" 'grep -qx "model_reasoning_effort = \"xhigh\"" "$tmp/cxmax/work/codex/config.toml"'

echo "codex: refusals before the session"
runc cxkey end AZURE_OPENAI_API_KEY=some-key
check "an API key in the environment: exit 1, no session" '[ "$(code cxkey)" = 1 ] && grep -q "an API key is set" "$tmp/cxkey.out" && [ ! -e "$tmp/cxkey/work/seen-args" ]'
runc cxnoid end IDENTITY_HEADER=wrong
check "identity endpoint refuses: exit 1, no session" '[ "$(code cxnoid)" = 1 ] && grep -q "no Entra token" "$tmp/cxnoid.out" && [ ! -e "$tmp/cxnoid/work/seen-args" ]'
runc cxnodep end AZURE_OPENAI_DEPLOYMENT=
check "no deployment: exit 1" '[ "$(code cxnodep)" = 1 ] && grep -q "AZURE_OPENAI_DEPLOYMENT is not set" "$tmp/cxnodep.out"'
runc cxhost end AZURE_OPENAI_ENDPOINT=https://evil.example.com/
check "an endpoint outside Azure OpenAI: exit 1 before any token" '[ "$(code cxhost)" = 1 ] && grep -q "must be https://<resource>.openai.azure.com/" "$tmp/cxhost.out" && [ ! -e "$tmp/cxhost/work/seen-args" ]'
runc cxbad end FWRUNNER_AGENT=gemini
check "unknown agent: exit 1" '[ "$(code cxbad)" = 1 ] && grep -q "FWRUNNER_AGENT must be claude or codex" "$tmp/cxbad.out"'
runc cxexit exit
check "codex exits without the marker: exit 1" '[ "$(code cxexit)" = 1 ] && grep -q "codex exited by itself (3) without the end marker" "$tmp/cxexit.out"'

echo "git-credential-fworker"
h="$tmp/cred"; mkdir -p "$h/data/tokens"; echo 42 > "$h/session-owning"; secret i1 > "$h/data/tokens/42.owner"
cred() { printf 'protocol=%s\nhost=%s\n\n' "$1" "$2" | FWRUNNER_HOME="$h" FACTORY_DATA_DIR="$h/data" FACTORY_URL="$gw" bash "$helper" get 2>"$h/err"; }
out=$(cred https github.com)
check "github.com gets the item's installation token" '[ "$out" = "$(printf "username=x-access-token\npassword=%s" "$(secret ghs)")" ]'
before=$(curl -s "$gw/_stub/stats")
out2=$(cred https github.com)
check "second call answered from the private cache" '[ "$out2" = "$out" ] && [ "$(curl -s "$gw/_stub/stats")" = "$before" ] && [ "$(stat -c %a "$h/data/.git-credential.cache")" = 600 ]'
check "other hosts get nothing" '[ -z "$(cred https example.com)" ]'
printf 'protocol=https\nhost=github.com\n\n' | FWRUNNER_HOME="$h" bash "$helper" erase
echo 7 > "$h/session-owning"
check "no owner token for the item: nothing, and says why" '[ -z "$(cred https github.com)" ] && grep -q "no owner token for item 7" "$h/err"'

echo
echo "fwrunner tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
