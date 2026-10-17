# Prompts

The instructions of the factory's AI sessions, one file per role and phase (docs/design/agents-roles-launch.md 5). The gateway ships this
directory in its image, loads it at start and serves each prompt through the `get_prompt` tool at `/mcp`: a merged change is live after the
gateway release, and the next task reads it.

Prompts are not a security control. Every rule that protects something (merges, pushes, credentials, card moves, budgets) is enforced by the
gateway whatever a prompt says; a prompt only says how to do the work well.

## Front matter

```yaml
---
role: worker                 # a role of gateway/Mcp/RoleTools.cs (bootstrap files: role bootstrap)
phase: development           # the phase (worker roles) or the mode (bootstrap: manual, hosted, api)
version: 1                   # raised by every change of the body
tools: [item_get, next_event]  # every tool the body names; each must be in the role's tool set
includes: [common/rules.md]  # files whose body is placed before this one
---
```

## Lint (tests/smoke.ps1, "prompts")

Every file parses; `role`, `phase`, `version` and `tools` are present; every tool in `tools` is in the role's set; every tool named in the
body in backticks is in `tools`; every include exists; no body names `factory.ps1` or holds a shell variable (`$NAME`). The gateway refuses
to serve a prompt that fails its parser.
