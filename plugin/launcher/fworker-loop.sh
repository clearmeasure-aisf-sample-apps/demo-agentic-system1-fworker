#!/usr/bin/env bash
# fworker-loop.sh: runs factory worker sessions one after another, one work item per session (docs/launcher.md).
#
#   fworker-loop.sh --dir BASE --prompt-file FILE [--backoff S] [--max-backoff S] [--stop-file FILE] [--claude CMD]
#                   [--stream-stale S] [--silent S] [--unsent S] [--screen-cmd CMD] [--sidecar auto|on|off] [--pwsh PWSH] [-- claude arguments...]
#
# Each round starts a new `claude` session with the connect prompt (the content of FILE) as its first message. When the worker's item has ended the
# worker runs `factory.ps1 end-session`, which writes BASE/work/session-ended (this script exports its path as FACTORY_SESSION_END_FILE); the script
# then ends that session and starts the next one after a short pause. A session that exits by itself (a crash, or a person quit it) is started again
# too, with a pause that doubles up to --max-backoff.
# Stop: create the stop file (default BASE/work/STOP; the session that runs finishes its item first), or press Ctrl-C while no session runs (the
# pause between sessions). Needs only bash and `claude` on the PATH (or --claude).
# Watchdog: the session is also ended and restarted when its event stream showed no line for --stream-stale seconds (default 600), when its screen
# did not change for --silent seconds while it holds an item (default 1800), or when its prompt holds typed, unsent input for --unsent seconds
# (default 600). The screen is read with --screen-cmd, default `tmux capture-pane -p` when the session runs in tmux; without one the screen checks
# are off. 0 switches a check off. Every restart and its reason is written to BASE/work/launcher.log.
# Stream sidecar (issue 106): the launcher runs the session's event stream (`factory.ps1 subscribe --own ...`, the command of step 7 of the connect
# prompt, with the credentials of its step 4 or of FACTORY_URL, FACTORY_TOKEN and FACTORY_HOLDER) for the session's whole lifetime and appends every
# line to BASE/work/events.log; the session's Monitor only tails that file, so re-arming it registers nothing and replays nothing. The first message
# tells the session so. --sidecar auto (default) runs it when the prompt names the command, on requires it, off leaves the stream to the session.
set -u

dir=''; prompt=''; backoff=10; maxBackoff=300; stopFile=''; claudeCmd='claude'; extra=(); streamStale=600; silent=1800; unsent=600; screenCmd=''; sidecar=auto; pwshCmd=''
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) dir="$2"; shift 2 ;;
        --prompt-file) prompt="$2"; shift 2 ;;
        --backoff) backoff="$2"; shift 2 ;;
        --max-backoff) maxBackoff="$2"; shift 2 ;;
        --stop-file) stopFile="$2"; shift 2 ;;
        --claude) claudeCmd="$2"; shift 2 ;;
        --stream-stale) streamStale="$2"; shift 2 ;;
        --silent) silent="$2"; shift 2 ;;
        --unsent) unsent="$2"; shift 2 ;;
        --screen-cmd) screenCmd="$2"; shift 2 ;;
        --sidecar) sidecar="$2"; shift 2 ;;
        --pwsh) pwshCmd="$2"; shift 2 ;;
        --) shift; extra=("$@"); break ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "fworker-loop: unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
done
[ -n "$dir" ] && [ -n "$prompt" ] || { echo "fworker-loop: --dir and --prompt-file are required (see --help)" >&2; exit 2; }
[ -f "$prompt" ] || { echo "fworker-loop: no prompt file at $prompt" >&2; exit 2; }
case "$backoff$maxBackoff$streamStale$silent$unsent" in *[!0-9]*) echo "fworker-loop: --backoff, --max-backoff, --stream-stale, --silent and --unsent are whole seconds" >&2; exit 2 ;; esac
command -v "$claudeCmd" >/dev/null 2>&1 || { echo "fworker-loop: $claudeCmd is not on the PATH" >&2; exit 2; }
mkdir -p "$dir/work"
dir=$(cd "$dir" && pwd)     # absolute: the paths the session is told must not depend on where the launcher was started
marker="$dir/work/session-ended"
[ -n "$stopFile" ] || stopFile="$dir/work/STOP"
export FACTORY_SESSION_END_FILE="$marker"
alive="$dir/work/stream-alive"; owning="$dir/work/session-owning"; log="$dir/work/launcher.log"; events="$dir/work/events.log"
if [ -z "$screenCmd" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then screenCmd="tmux capture-pane -p -t $TMUX_PANE"; fi

# ---- the stream sidecar: what it runs, worked out from the options, the environment and the connect prompt at the start of every round ---------
case "$sidecar" in auto|on|off) ;; *) echo "fworker-loop: --sidecar is auto, on or off" >&2; exit 2 ;; esac
scScripts="$(cd "$(dirname "$0")/../scripts" 2>/dev/null && pwd)/factory.ps1"
scUrl=''; scTok=''; scName=''; scArgs=''; scWhy=''; scOn=0
# the command and credentials of this round (a refreshed prompt file is read again); scOn=1 when the sidecar can run
scPlan() {
    scOn=0; scWhy=''
    [ "$sidecar" != off ] || { scWhy='--sidecar off'; return 0; }
    scArgs=$(grep -o 'factory\.ps1 subscribe --own.*' "$prompt" 2>/dev/null | head -n 1 | sed 's/^factory\.ps1 //; s/[[:space:]]*$//')
    scUrl=$(grep -o 'FACTORY_URL=[^[:space:]]*' "$prompt" 2>/dev/null | head -n 1 | cut -d= -f2-); scUrl=${scUrl:-${FACTORY_URL:-}}
    scTok=$(grep -o 'FACTORY_TOKEN=[^[:space:]]*' "$prompt" 2>/dev/null | head -n 1 | cut -d= -f2-); scTok=${scTok:-${FACTORY_TOKEN:-}}
    scName=$(grep -o 'FACTORY_HOLDER=[^[:space:]]*' "$prompt" 2>/dev/null | head -n 1 | cut -d= -f2-); scName=${scName:-${FACTORY_HOLDER:-}}
    if [ -z "$pwshCmd" ]; then if command -v pwsh >/dev/null 2>&1; then pwshCmd=pwsh; elif [ -x "$dir/pwsh/pwsh" ]; then pwshCmd="$dir/pwsh/pwsh"; fi; fi
    if [ -z "$scArgs" ]; then scWhy='the prompt names no subscribe --own command'
    else case " $scArgs " in *' --supervisor '*|*' --operator '*|*' --spawn '*) scWhy='the prompt is not the one of a worker session' ;; esac; fi
    if [ -z "$scWhy" ] && { [ -z "$scUrl" ] || [ -z "$scTok" ]; }; then scWhy='no FACTORY_URL and FACTORY_TOKEN in the prompt or the environment'; fi
    if [ -z "$scWhy" ] && [ -z "$pwshCmd" ]; then scWhy='no pwsh on the PATH or in BASE/pwsh'; fi
    if [ -z "$scWhy" ] && [ ! -f "$scScripts" ]; then scWhy="no factory.ps1 next to the launcher ($scScripts)"; fi
    [ -n "$scWhy" ] || scOn=1
}
if [ "$sidecar" = on ]; then scPlan; [ "$scOn" -eq 1 ] || { echo "fworker-loop: --sidecar on, but $scWhy" >&2; exit 2; }; fi
scPid=0; scFinal=0; scDelay=2; scNextAt=0; scStartedAt=0
# starts the sidecar of this session (stdout appended to events.log, stderr to events.err). Its credentials go to it alone: never to the session,
# never on a command line; the other credential variables are taken out, so the client uses exactly the prompt's
startSidecar() {
    ( set -f; unset FACTORY_SUPERVISOR_TOKEN FACTORY_WORKER_TOKEN FACTORY_OPERATOR_SESSION_TOKEN
      export FACTORY_URL="$scUrl" FACTORY_TOKEN="$scTok" FACTORY_WORK_DIR="$dir/work"; [ -z "$scName" ] || export FACTORY_HOLDER="$scName"
      [ -n "${FACTORY_DATA_DIR:-}" ] || export FACTORY_DATA_DIR="$dir/data"
      # shellcheck disable=SC2086
      exec "$pwshCmd" -NoProfile -File "$scScripts" $scArgs >> "$events" 2>> "$dir/work/events.err" </dev/null ) &
    scPid=$!; scStartedAt=$(date +%s)
}
stopSidecar() {
    [ "$scPid" -gt 0 ] || return 0
    kill -TERM "$scPid" 2>/dev/null; for _ in 1 2 3 4 5; do kill -0 "$scPid" 2>/dev/null || break; sleep 1; done
    kill -KILL "$scPid" 2>/dev/null; wait "$scPid" 2>/dev/null; scPid=0
}
# a sidecar that ended while its session runs is started again, after a pause that doubles up to 60 s (back to 2 s once one lived a minute); not
# after a refusal (exit 2 usage, 10, 30 credential, 40 a newer stream of the name replaced it: the session started its own stream after all)
scCheck() {
    [ "$scOn" -eq 1 ] && [ "$scFinal" -eq 0 ] || return 0
    local now; now=$(date +%s)
    if [ "$scPid" -gt 0 ]; then
        kill -0 "$scPid" 2>/dev/null && return 0
        wait "$scPid" 2>/dev/null; local c=$?; scPid=0
        if [ $((now - scStartedAt)) -ge 60 ]; then scDelay=2; fi
        case "$c" in
            2|10|30|40) scFinal=1; say "the stream sidecar ended (exit $c): not started again in this session"
                   printf '%s session %s sidecar ended: exit %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$round" "$c" >> "$log" 2>/dev/null || true
                   return 0 ;;
        esac
        say "the stream sidecar ended (exit $c): starting it again in $scDelay s"; scNextAt=$((now + scDelay)); scDelay=$((scDelay * 2)); [ "$scDelay" -le 60 ] || scDelay=60
        return 0
    fi
    if [ "$now" -ge "$scNextAt" ]; then startSidecar; say "stream sidecar started again (pid $scPid)"; fi
}
sidecarNote() {
    printf '\n\nLAUNCHER NOTE (fworker-loop, stream sidecar): this launcher already runs the event stream of this session, the command of step 7, as a sidecar process for the whole session, and appends every line it prints to %s . Do not start factory.ps1 subscribe yourself: a second stream of this name would replace it. Step 7 instead: Monitor on   tail -n +1 -F '"'"'%s'"'"'   (from the first line: lines arrived while you set up), with the longest time limit the tool allows. Whenever that Monitor ends, start Monitor on   tail -n0 -F '"'"'%s'"'"'   at once (a re-arm registers nothing and replays nothing), then read the last lines of that file once and handle any line you have not handled yet. Without a Monitor tool, read the new lines of that file every 30 seconds. Everything else in the steps above is unchanged.' "$events" "$events" "$events"
}

stopping=0; child=0
on_signal() { stopping=1; if [ "$child" -gt 0 ] && kill -0 "$child" 2>/dev/null; then kill -TERM "$child" 2>/dev/null; fi; }
trap on_signal INT TERM HUP
trap 'stopSidecar' EXIT     # no sidecar outlives its launcher (it would stay registered and accept offers)
say() { printf '%s fworker-loop: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# a restart and its reason: on the terminal and in BASE/work/launcher.log
logRestart() { say "restart session $round: $1"; printf '%s session %s restart: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$round" "$1" >> "$log" 2>/dev/null || true; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# the text typed into the live prompt, or nothing: only the bottom-most prompt line among the last 8 non-blank lines of the screen counts (the transcript
# above shows earlier messages with the same marker), without the box border, the "Try ..." placeholder or a numbered menu row. Plain bash string
# operations: some greps mishandle a multibyte character in an alternation, and a C locale has no multibyte bracket expressions.
typedInput() {
    local l last=''
    while IFS= read -r l; do
        l=${l//│/ }; l=${l//❯/>}; l=${l//|/ }
        if [[ $l =~ ^\ *[\>](\ |$) ]]; then last=$l; fi
    done <<EOF_SCREEN
$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 8)
EOF_SCREEN
    last=${last#"${last%%[! ]*}"}; last=${last#>}
    last=${last#"${last%%[! ]*}"}; last=${last%"${last##*[! ]}"}
    case "$last" in ''|'Try "'*) return 0 ;; esac
    [[ $last =~ ^[0-9]+\. ]] && return 0
    printf '%s' "$last"
}
# the watchdog's verdict for the running session in wd, or empty (no subshell: it keeps the screen's last change in globals): stream silence, screen silence while it holds an item, typed input left unsent
watchdog() {
    wd=''; local now; now=$(date +%s)
    if [ "$streamStale" -gt 0 ]; then
        local ref=$started; [ -e "$alive" ] && ref=$(mtime "$alive"); [ "$ref" -ge "$started" ] || ref=$started
        if [ $((now - ref)) -ge "$streamStale" ]; then wd="stream-disconnected: no line on the event stream for $((now - ref)) s"; return; fi
    fi
    [ -n "$screenCmd" ] || return 0
    local scr sum; scr=$(sh -c "$screenCmd" </dev/null 2>/dev/null) || return 0
    sum=$(printf '%s' "$scr" | cksum)
    if [ "$sum" != "$lastSum" ]; then lastSum=$sum; screenAt=$now; return 0; fi
    local quiet=$((now - screenAt))
    if [ "$unsent" -gt 0 ] && [ "$quiet" -ge "$unsent" ] && [ -n "$(typedInput "$scr")" ]; then
        wd="unsent-input: typed input sat unsent in the prompt for $quiet s"; return; fi
    if [ "$silent" -gt 0 ] && [ -e "$owning" ] && [ "$quiet" -ge "$silent" ]; then wd="no-output-while-owning: the screen did not change for $quiet s while the session holds item $(cat "$owning" 2>/dev/null)"; return; fi
}
# a pause that Ctrl-C ends at once (the trap runs while `wait` waits, not only after a foreground sleep)
pause() { sleep "$1" & local s=$!; wait "$s" 2>/dev/null; kill "$s" 2>/dev/null; }

delay=$backoff; round=0
while [ "$stopping" -eq 0 ]; do
    if [ -e "$stopFile" ]; then say "stop file $stopFile is present: not starting another session"; break; fi
    rm -f "$marker" "$marker.reason" "$alive" "$owning"
    started=$(date +%s); screenAt=$started; lastSum=''; checkAt=0; restarted=''; scFinal=0; scDelay=2; scNextAt=0
    round=$((round + 1)); say "session $round starts"
    # the sidecar of this session: a fresh events.log (the last session's is kept as events.log.1); its stream registers as a new session
    msg=$(cat "$prompt")
    scPlan
    if [ "$scOn" -eq 1 ]; then
        if [ -e "$events" ]; then mv -f "$events" "$events.1"; fi; : > "$events"
        startSidecar; say "stream sidecar started (pid $scPid): $events"
        # one that cannot even start (no ICU, a malformed command line) is no stream: this session gets none and starts its own as before
        for _ in 1 2 3 4 5; do sleep 1; kill -0 "$scPid" 2>/dev/null || break; done
        if kill -0 "$scPid" 2>/dev/null; then msg="$msg$(sidecarNote)"
        else wait "$scPid" 2>/dev/null; say "the stream sidecar ended at once (exit $?): this session starts its own stream"; scPid=0; scOn=0; fi
    elif [ "$sidecar" != off ]; then say "no stream sidecar: $scWhy"; fi
    [ "$stopping" -eq 0 ] || { stopSidecar; break; }     # Ctrl-C or TERM while the sidecar started
    # the session reads the terminal: a background job of a script would otherwise get /dev/null as its input
    if [ -t 0 ]; then "$claudeCmd" ${extra[@]+"${extra[@]}"} "$msg" </dev/tty & else "$claudeCmd" ${extra[@]+"${extra[@]}"} "$msg" & fi
    child=$!
    ended=0
    while kill -0 "$child" 2>/dev/null; do
        why=''
        if [ -e "$marker" ]; then
            why=$(cat "$marker.reason" 2>/dev/null); [ -n "$why" ] || why='end-session: the worker ended its session'
            logRestart "$why"
            pause 5     # the worker's last lines are written
        elif [ "$(date +%s)" -ge "$checkAt" ]; then
            checkAt=$(( $(date +%s) + 5 )); watchdog; why=${wd:+watchdog $wd}
            [ -z "$why" ] || logRestart "$why"
        fi
        scCheck
        if [ -n "$why" ]; then
            ended=1; restarted=$why
            kill -TERM "$child" 2>/dev/null
            for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
            kill -KILL "$child" 2>/dev/null
            break
        fi
        sleep 2
    done
    wait "$child" 2>/dev/null; code=$?; child=0
    stopSidecar     # the stream lives exactly as long as its session
    [ -e "$marker" ] && ended=1
    stty sane 2>/dev/null </dev/tty || true     # a session stopped by a signal can leave the terminal in raw mode
    [ "$stopping" -eq 1 ] && break
    if [ "$ended" -eq 1 ]; then delay=$backoff; case "$restarted" in watchdog*) say "session $round was restarted by the watchdog" ;; *) say "session $round finished its item" ;; esac
    else say "session $round exited by itself (exit $code)"; fi
    say "next session in $delay s (Ctrl-C or the stop file $stopFile to stop)"
    pause "$delay"
    [ "$ended" -eq 1 ] || { delay=$((delay * 2)); [ "$delay" -le "$maxBackoff" ] || delay=$maxBackoff; }
done
stopSidecar
say "stopped"
