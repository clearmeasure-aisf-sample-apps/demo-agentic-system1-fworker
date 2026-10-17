---
name: factory-setup
description: Use when asked to set up, verify or troubleshoot the factory worker on this machine: gateway reachability, plugin download, secrets check, tools needed to build.
---

# Setup

Nothing is assumed to be on the machine. The connect prompt (from the gateway dashboard) is the whole setup; it needs only a shell with `curl` (or `wget`) and `tar`, and network access to the gateway, `github.com` and `objects.githubusercontent.com`.
1. PowerShell 7: the prompt downloads it into the base directory when `pwsh` is missing (the architecture is read from `uname -m`).
2. The plugin: downloaded from the gateway (`<url>/api/v1/plugin`) into the base directory, in exactly the gateway's version. `factory.ps1 plugin-sync` keeps it equal to the gateway's later.
3. The variables `FACTORY_URL`, `FACTORY_TOKEN`, `FACTORY_HOLDER` come from the prompt (or `client.json` under the user's config directory when it exists). Never print, write or commit token values.
4. `factory.ps1 check-secrets` (the gateway runs the read-only probes; names and pass/fail only).
5. Tools a task needs are installed on demand by the plugin (`ensure-tools.ps1`), never assumed. The machine holds no GitHub or Octopus secret; branch pushes use the git credentials the session already has for the work-orders clone.
6. Subscribe: start `pwsh <scripts>/factory.ps1 subscribe --own ...` under the Monitor tool (one event per line), or in the background writing to a file in the work directory. `subscribe --spawn` and `--own` with the local spawner also need the `claude` command line tool; a session that is itself the worker does not.
