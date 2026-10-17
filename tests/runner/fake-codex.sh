#!/usr/bin/env bash
# A stand-in for `codex exec --json` in tests/runner/fwrunner.test.sh. It records its args, stdin, environment facts and CODEX_HOME files,
# runs the provider's auth command from the config as Codex would, then behaves like fake-claude.sh's FAKE_MODE=end (JSONL events, the
# stream-alive file, the end marker after 2 s, exits on TERM) or FAKE_MODE=exit.
home=${FWRUNNER_HOME:?}
cat > "$home/seen-prompt"
printf '%s\n' "$@" > "$home/seen-args"
cmd=$(sed -n 's/^command = "\(.*\)"$/\1/p' "$CODEX_HOME/config.toml")
tok=$("$cmd" 2>/dev/null)
{ [ -n "${FACTORY_TOKEN:-}" ] && echo token-set; [ -n "${AZURE_OPENAI_API_KEY:-}${OPENAI_API_KEY:-}" ] && echo api-key-set; pwd
  echo "${FACTORY_SESSION_END_FILE:-}"; echo "codex-home=$CODEX_HOME"; echo "bearer=$tok"; } > "$home/seen-env"
line() { printf '{"type":"%s","text":"%s"}\n' "$1" "$2"; }
line thread.started "session starts"
line item.completed "the worker token is $FACTORY_TOKEN and an Entra token $tok"
case "${FAKE_MODE:-end}" in
    end)
        touch "$home/stream-alive"; echo 42 > "$home/session-owning"
        sleep 2; line item.completed "end-session"
        echo 'end-session: item 42 ended' > "$FACTORY_SESSION_END_FILE.reason"; date -u +%FT%TZ > "$FACTORY_SESSION_END_FILE"
        while :; do sleep 1; done ;;
    exit) sleep 1; exit 3 ;;
esac
