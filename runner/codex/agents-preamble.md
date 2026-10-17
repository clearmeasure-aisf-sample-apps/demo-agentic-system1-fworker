# Factory worker instructions for Codex

This file is generated at the start of the container by fwrunner.sh from the factory plugin's skills and the connect prompt. The skills
were written for Claude Code; this section says how a Codex session follows them. Where a skill and this section differ, this section wins.

## How the Claude Code skills map to Codex

- A skill is a file: "run the skill X" or "follow X" means read {{BASE}}/plugin/skills/X/SKILL.md with a shell command and follow it.
  The index of skills is at the end of this file.
- There are no subagents in this session. Where a skill says to start a subagent (analyst, implementer, reviewer, inspector) or to use the
  Agent tool, do that role's work yourself, inline and in order: read its definition in {{BASE}}/plugin/agents/<role>.md, do the role's
  work, write the result file the skill names, then continue as the orchestrator. Do one role at a time and finish it before the next.
  Skip `factory.ps1 model-for --role subagent`: the model of this session is fixed by the container.
- The reviewer role still reviews: before completing a column, re-read the whole diff with the reviewer definition's checklist as if
  someone else wrote it, and fix what it finds. Never skip a review because the same session wrote the code.
- Background commands: start the event stream with `nohup ... > {{BASE}}/events.log 2>&1 &` and poll the file with `sleep 30; tail`.
- There is no ToolSearch, no Monitor, no AskUserQuestion and no slash command. Nobody answers questions in this session: questions go
  to the supervisor through factory.ps1, as factory-peer-messaging says.
- Commands are not sandboxed per command and nothing asks for approval; some commands are refused by policy (env, printenv, force pushes,
  pushes to master or main, wget, nc, ssh, scp, sudo). A refused command is final: do not look for another way to run it.

