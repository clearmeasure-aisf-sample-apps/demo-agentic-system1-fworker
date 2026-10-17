# One work item per session, and the launcher loop

Owner decision of 2026-10-14: a worker session must not carry the context of one work item into the next. When its item ends, the session ends,
and a new Claude session started from the connect prompt takes the next item.

## How it works

| Part | What it does |
|---|---|
| Gateway (`gateway/Plant.cs`) | Setting `plant.oneItemPerSession` (default `true` in `config/instance.json`; `FACTORY_ONE_ITEM_PER_SESSION=1` or `0` overrides it). A session that has accepted a work item (an `own-item`), or has an open offer of one, is offered no other: not while it holds the item, not after the item ended. A pinned item that waits for such a session has the waiting code `session-spent`. Bot jobs (inspector) and QC jobs are not work items and are not limited. |
| Session identity | A stream opened without a cursor (no `Last-Event-ID`) is a new session of that name; a reconnect of the same client sends its cursor and stays the same session. A new session starts with the items the name still owns (it resumes that item and is offered nothing else) and no longer drains. |
| Status | `GET /api/v1/status`: `plant.oneItemPerSession`, and for each worker `session` (a number per name), `sessionStarted`, `sessionItems`, `sessionSpent` and `itemsPerSession` (the last 10 sessions of the name, each with its items). The state is in memory: a gateway restart starts every name again at session 1. |
| Worker skill (`plugin/skills/factory-owner-session`, section "One item per session") | When the item ends (complete, released, demoted or reassigned) the session runs `factory.ps1 end-session --name N --marker <BASE>/work/session-ended`, stops its event stream and ends. It never accepts a second item. |
| `factory.ps1 end-session` | Drains the name at the gateway with the session's own credential and writes the end marker (`FACTORY_SESSION_END_FILE` when a launcher set it, else `--marker`). |
| `session.end` (issue 72) | The gateway's tick sends it on the stream of a session that is spent and has owned nothing (no owned item, no accepted or open offer of its item, no QC or bot job held or offered) for `timing.sessionEndGraceSeconds` (default 90; `FACTORY_TIMING_sessionEndGraceSeconds`), once per session (again after a reconnect). The stream client (`subscribe --name`) then writes `FACTORY_SESSION_END_FILE` itself, so a session whose item was taken back is ended by the launcher even when the model never runs `end-session`. A take-back is seen when the gateway drops the owner (release, complete, or the sweep no longer finding the holder). An accepted assignment whose worker no longer owns the item is dropped after two sweeps (issue 96), and an item that two sweeps found in the Release Queue loses its owner and assignments, so neither holds `session.end` back. |
| Launcher (`plugin/launcher/`) | Starts `claude` with the connect prompt, waits for the end marker, ends that session and starts the next one after a pause. It also restarts a stuck session (watchdog, below) and runs the session's event stream as a sidecar (below). |
| `session.restart` (launcher watchdog) | The gateway's tick sends it, once per session (again after a reconnect), to a session that is stuck: code `spent-idle` when the session is spent and has owned nothing (no owned item, no QC or bot job held or offered; unlike `session.end` an accepted own-item offer, possibly stale, does not hold it back) for `timing.sessionRestartMinutes` (default 10, 0 is off) while still connected, and code `repeated-question` when it asked the same question (case and spacing ignored) about the same item, or about none, more than `timing.sessionRepeatQuestionLimit` times (default 2, 0 is off). The stream client writes the end marker and `<marker>.reason`, so the launcher restarts the session and logs the gateway's reason. `GET /api/v1/status`: `plant.sessionRestarts` (count and the last 20) and per worker `stuckSince`, `restartSent`. |
| `session.restart` (plant manager) | The plant manager's `restart-session` (`docs/design/plant-manager.md` 10e) sends it on the stream of a connected session. The stream client writes `FACTORY_SESSION_END_FILE` as for `session.end` (`markerWritten` on the printed line); the launcher ends the session and starts the next one, which is resent the items the name owns and resumes them. Without a launcher the line tells the session to end. |

Without a launcher (a cloud session, Cursor) the session says it is finished and stops; a person starts the next session from the connect prompt.
The gateway rule holds either way.

Limits: a session's identity is its stream. If the session restarts its stream command (a Monitor that expired) after its item ended and before
`end-session`, the gateway sees a new session and may offer it another item; the skill's rule (never accept a second item) is the guard then, and
the offer lapses to another session after `assignAckSeconds`. `sessionSpent` in the status counts accepted items only, not open offers.

## The launchers

Both do the same thing and need nothing but their shell and `claude` on the PATH. They are in the plugin (`<BASE>/plugin/launcher/` once the
plugin is downloaded) and in this repository.

```bash
# Linux, macOS (bash)
bash <BASE>/plugin/launcher/fworker-loop.sh --dir <BASE> --prompt-file <BASE>/start-prompt.txt -- --model claude-sonnet-5-5 --effort low
```

```powershell
# any system with PowerShell 7 (Windows included)
pwsh -File <BASE>/plugin/launcher/fworker-loop.ps1 -Dir <BASE> -PromptFile <BASE>/start-prompt.txt -ClaudeArgs '--model claude-sonnet-5-5 --effort low'
```

- `<BASE>` is the worker's directory of the connect prompt (`<home>/factory-worker/<name>`); the prompt file holds the connect prompt. The prompt
  contains a credential: keep the file readable by its user only and never commit it.
- Everything after `--` (bash) or in `-ClaudeArgs` goes to `claude` before the prompt (model, effort, permission mode, remote-control name). Do not
  end it with an option that takes several values (`--add-dir`, `--allowed-tools`): it would take the prompt as one. The prompt is a process argument,
  visible to other users of the machine in the process list: run workers on a machine or account of their own.
- Each round: the end marker `<BASE>/work/session-ended` is removed, `FACTORY_SESSION_END_FILE` is set to it, and `claude` starts with the prompt.
  When the marker appears the launcher waits 5 s, ends the session (TERM, then KILL after 10 s) and starts the next after `--backoff` seconds
  (default 10). A session that exits without the marker (a crash, or a person quit it) is started again after a pause that doubles up to
  `--max-backoff` (default 300).
- Stop: create `<BASE>/work/STOP` (or the file of `--stop-file`). A running session finishes its item first; no new one starts. Delete the file
  before starting the launcher again. Ctrl-C stops the launcher during the pause between sessions; while a session runs, the keys go to that session.
- On Windows an npm-installed `claude` is a `.cmd` shim that cannot take a multi-line argument: the PowerShell launcher then gives the session a short
  first message that names the prompt file instead of the prompt itself.

## The watchdog

Besides the gateway's `session.end` and `session.restart`, each launcher checks the running session every 5 s and restarts it when:

| Code | Condition | Option (bash / PowerShell), default |
|---|---|---|
| `stream-disconnected` | The stream client showed no sign of life for this long: it stamps `<BASE>/work/stream-alive` at every connect attempt (a failed one too, so a gateway outage restarts nobody) and at most every 20 s while lines arrive (events and the `: ping` of every 25 s). Before the first stamp the session's start counts. So the check means the client is dead, hung or was never started (a Monitor that expired). | `--stream-stale` / `-StreamStale`, 600 s |
| `no-output-while-owning` | The session's screen did not change for this long while it holds an item (`<BASE>/work/session-owning`, written by the stream client on an owner offer, acceptance or restored ownership, removed on `session.end`, `session.restart` and `item.taken_back`). | `--silent` / `-Silent`, 1800 s |
| `unsent-input` | The live prompt line holds typed text and the screen did not change for this long. Only the bottom-most line starting with `>` or `❯` (after a box border) among the last 8 lines of the screen counts, since earlier messages in the transcript carry the same marker; the `Try "..."` placeholder and numbered menu rows (`❯ 1. Yes`) are no typed input. | `--unsent` / `-Unsent`, 600 s |

The screen is read with `--screen-cmd` / `-ScreenCmd` (a command whose output is the screen); inside tmux the default is `tmux capture-pane -p -t $TMUX_PANE`. Without
one the two screen checks are off; the stream check and the gateway's events still work. 0 switches a check off. Every restart, its cause and the
gateway's reason, is printed and appended to `<BASE>/work/launcher.log`. A restarted session is a new session of the name: it resumes what the name
still owns (the gateway resends the accepted assignment) and takes nothing else. The launcher prints "restarted by the watchdog" for its own restarts.

## The stream sidecar (issue 106)

A session used to start its own event stream (`factory.ps1 subscribe --own`, step 7 of the connect prompt) under a Monitor. A Monitor expires after
minutes; every re-arm registered the name again and had the whole buffer replayed, and the session read old lines again (assignments of earlier
items, `peers.snapshot`, `supervisor.joined`). Now the launcher runs the stream itself, for exactly as long as the session runs:

| Part | What it does |
|---|---|
| What it runs | The command of step 7 of the prompt file (`subscribe --own --name ... --type ... --capacity ...`), with `FACTORY_URL`, `FACTORY_TOKEN` and `FACTORY_HOLDER` from step 4 of the prompt file or, when it has none, from the launcher's environment; read again at the start of every session, so a refreshed prompt (a new credential) is used by the next one. Also `FACTORY_DATA_DIR` (default `<BASE>/data`), `FACTORY_WORK_DIR=<BASE>/work` and the launcher's `FACTORY_SESSION_END_FILE` (which the `claude` process gets as before). The credential variables are set for the sidecar only, never for the `claude` process, and never on a command line; `FACTORY_SUPERVISOR_TOKEN`, `FACTORY_WORKER_TOKEN` and `FACTORY_OPERATOR_SESSION_TOKEN` are removed from its environment, so the client uses exactly the prompt's credential. pwsh comes from `--pwsh` / `-Pwsh`, else the PATH, else `<BASE>/pwsh/pwsh`; `factory.ps1` is the one next to the launcher (`<BASE>/plugin/scripts`). |
| Where its lines go | Appended to `<BASE>/work/events.log` (written through, so a tail sees each line at once); its stderr to `<BASE>/work/events.err`. Each session gets a fresh `events.log`; the previous one is kept as `events.log.1`. |
| Lifetime | Started 5 s before the session; one that ends within those 5 s (pwsh cannot start, a malformed command) gives that session no sidecar and no note: it starts its own stream as before. Stopped (TERM, then KILL) when the session ends or is restarted, and when the launcher exits (bash: an EXIT trap). A sidecar that ends while its session runs is started again after a pause that doubles from 2 s up to 60 s (back to 2 s after one lived a minute), except after a refusal, exit 2, 10, 30 (the credential) or 40 (a newer stream of the name replaced it: the session started its own stream after all), which would only repeat; that is logged in `launcher.log`. Each sidecar opens its stream without a cursor, so the gateway sees a new session of the name, as before. |
| The session | Its first message is the prompt plus a launcher note (also written to `<BASE>/work/launcher-note.txt`; a Windows `.cmd` or `.ps1` shim takes one short line only, so there the first message names both files): the stream already runs; do not start `subscribe`; Monitor `tail -n +1 -F '<BASE>/work/events.log'` (the first arm reads from the first line, which may have arrived during setup), and on every expiry re-arm with `tail -n0 -F '<BASE>/work/events.log'` and read the last lines once for anything missed. A re-arm registers nothing and replays nothing. On Windows the note gives `Get-Content -LiteralPath <file> -Wait` (and `-Tail 0` to re-arm). |
| Switch | `--sidecar auto` / `-Sidecar auto` (default): on when the prompt names a worker's `subscribe --own` command and the credentials, pwsh and `factory.ps1` are found; otherwise off, and the session starts its own stream as before. `on` refuses to start without them (exit 2); `off` never runs it. |

Less noise for every session, with or without the launcher: a new session of a name (a stream opened without a cursor) is not replayed the triggers
of items the name no longer owns (the gateway leaves them out; a reconnect with a cursor still gets every trigger it missed, and messages are always
replayed), and the stream client prints `peers.snapshot` and `supervisor.joined` only when they changed since it printed them last (peers' names,
roles and items, the supervisor's presence and model; the joining supervisor's name, model and effort), so a reconnect does not repeat them.

With the sidecar the watchdog's `stream-disconnected` watches the sidecar (it stamps `stream-alive`), no longer the session's own Monitor: a session
that does not re-arm its Monitor is seen by the screen checks only.

## Tests

`tests/scenarios/owner.ps1`, scenario "owner: one item per session": a session with capacity 5 is offered one item at a time, is offered nothing
after it accepted one and after it released it, `end-session` drains it and writes the marker, and the next registration of the name is a new
session that is offered an item again, with `itemsPerSession` keeping the earlier session's one item. The other suites run with the rule off
(`tests/scenarios/lib.ps1`), because their scripted sessions take many items each.

`tests/scenarios/owner.ps1`, "owner: launcher watchdog: ...": the gateway's `session.restart` (`spent-idle`) after an ignored `session.end`, with the
client's reason file and the status; and both launchers, with a fake `claude`, restarting on each watchdog cause and on a gateway reason, each logged.
`tests/scenarios/messaging.ps1` (manager suite), "mgr: a session that asks the same question a third time is told session.restart".

`tests/scenarios/owner.ps1`, "owner: stream sidecar: ...": both launchers with a fake `claude` and a prompt in the shape of the connect prompt run the
real stream client against the suite's gateway: `events.log` gets `worker.registered`, the first message carries the launcher note, a killed sidecar is
started again, and the sidecar is stopped with its session. `tests/scenarios/messaging.ps1`, "msg: a reconnect does not repeat ...": the replayed
history of an item the name no longer owns is left out, and an unchanged `peers.snapshot` is not printed again.
