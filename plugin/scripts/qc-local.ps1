#!/usr/bin/env pwsh
# qc-local.ps1 <prepare|build|run|watch|stop|logs|status> --env-id E [...]
# Runs on the worker's own computer, no model involved. Builds and runs one pull request head as the QC environment E.
# Design: docs/design/pr-qc-environment.md sections 4.3 to 4.6. The profile (qc-profile.json, written by the operator for this machine)
# is the only machine-specific input; nothing in the pull request supplies a command. The application runs with a scrubbed environment
# (no FACTORY_*, no GitHub, Octopus or gateway credentials), detached, in E/src under a base directory outside the session's working tree.
#
#   prepare --env-id E --sha S --pr P [--item N] [--repo URL-or-path] [--source-dir D]   fetch the PR head, verify the sha, write E/app.env
#   build   --env-id E [--cap-seconds N]                                                  profile build command, log E/build.log, 8 minute cap
#   run     --env-id E [--sha S]                                                                  free port, detached start, local health, URL, starts the watcher
#   watch   --env-id E                                                                    (started by run) heartbeat every 60 s, acts on the answer
#   stop    --env-id E                                                                    kills app and watcher, removes E
#   logs    --env-id E [--which build|app|watch] [--tail 40]                              redacted tail; also written to E/log-tail.txt (1,500 characters)
#   status  --env-id E
# Common: --profile FILE (else $FACTORY_QC_PROFILE, else <state dir>/qc-profile.json|.md), --base-dir DIR (else profile, else ~/.local/share/factory-worker/qc)
# Exit codes: 0 ok, 2 usage, 10 refused, 11 stale (sha moved), 12 not found, 20 retryable (timeout, port), 30 profile or config missing.
# Linux and macOS only (setsid or nohup, kill, /proc where present). No secret is ever printed: the QC item token is only read from the token directory.
$Rest = [string[]]$args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Paths.ps1')
if ($IsWindows) { [Console]::Out.WriteLine('{"ok":false,"code":"unsupported-os","reason":"QC environments run on Linux or macOS workers"}'); exit 30 }
$script:Self = $PSCommandPath

function Write-Out($obj, [int]$code) { $obj.exit = $code; [Console]::Out.WriteLine(($obj | ConvertTo-Json -Depth 8 -Compress)); exit $code }
function Fail([int]$code, [string]$Code2, [string]$Reason, [hashtable]$Extra = @{}) { $o = @{ ok = $false; code = $Code2; reason = $Reason }; foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }; Write-Out $o $code }
function Test-Has($h, [string]$k) { $h -is [System.Collections.IDictionary] -and $h.Contains($k) }

$sub = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
if ($sub -notin 'prepare', 'build', 'run', 'watch', 'stop', 'logs', 'status') { Fail 2 'usage' 'usage: qc-local.ps1 <prepare|build|run|watch|stop|logs|status> --env-id E [--flag value]' }
$A = @{}
for ($i = 1; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -notmatch '^--(.+)$') { Fail 2 'usage' "unexpected argument '$($Rest[$i])'" }
    $k = ($Matches[1] -replace '-', '_').ToLowerInvariant()
    $A[$k] = if (($i + 1 -lt $Rest.Count) -and ($Rest[$i + 1] -notmatch '^--')) { $Rest[++$i] } else { 'true' }
}
if (-not (Test-Has $A 'env_id') -or $A.env_id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$' -or $A.env_id -match '\.\.') { Fail 2 'usage' '--env-id is required (letters, digits, - _ . ; 80 at most)' }
$EnvId = $A.env_id

# ---------------------------------------------------------------- profile
function Get-ProfilePath {
    if (Test-Has $A 'profile') { return $A.profile }
    if ($env:FACTORY_QC_PROFILE) { return $env:FACTORY_QC_PROFILE }
    $sd = Get-FwSubDir 'state' $env:FACTORY_WORKER_STATE_DIR
    foreach ($n in 'qc-profile.json', 'qc-profile.md') { $p = Join-Path $sd $n; if (Test-Path -LiteralPath $p) { return $p } }
    return (Join-Path $sd 'qc-profile.json')
}
# Keys are case-insensitive, aliases are folded. JSON, or "key: value" lines (the free text the connect prompt asks the operator for).
function Read-Profile {
    $path = Get-ProfilePath
    if (-not (Test-Path -LiteralPath $path)) { Fail 30 'profile-incomplete' 'no QC profile on this machine (qc-profile.json in the worker state directory)' }
    $raw = Get-Content -Raw -LiteralPath $path
    $src = @{}
    if ($raw.TrimStart().StartsWith('{')) { try { $src = $raw | ConvertFrom-Json -AsHashtable } catch { Fail 30 'profile-incomplete' 'the QC profile is not valid JSON' } }
    else { foreach ($line in ($raw -split "`n")) { if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_ ]*?)\s*[:=]\s*(.*?)\s*$') { $src[$Matches[1]] = $Matches[2] } } }
    $alias = @{ health = 'healthpath'; ports = 'portrange'; scripts = ''; sdk = ''; capacity = ''; 'port range' = 'portrange'; 'health path' = 'healthpath'; 'base dir' = 'basedir' }
    $p = @{}
    foreach ($k in $src.Keys) { $n = "$k".Trim().ToLowerInvariant(); if ($alias.ContainsKey($n)) { $n = $alias[$n] }; if ($n) { $p[$n] = $src[$k] } }
    return $p
}
function Pf($p, [string]$k, $default) { if ((Test-Has $p $k) -and "$($p[$k])".Length -gt 0) { return $p[$k] }; return $default }
function Test-Truthy($v) { "$v".ToLowerInvariant() -in 'true', '1', 'yes' }

function Get-BaseDir($p) {
    $b = if (Test-Has $A 'base_dir') { $A.base_dir } elseif ($env:FACTORY_QC_BASE_DIR) { $env:FACTORY_QC_BASE_DIR } else { Pf $p 'basedir' (Join-Path (Get-FwDataDir) 'qc') }
    New-Item -ItemType Directory -Force -Path $b | Out-Null
    return (Resolve-Path -LiteralPath $b).Path
}
function Get-EnvDir($p) { Join-Path (Get-BaseDir $p) $EnvId }

# ---------------------------------------------------------------- small helpers
function Read-Json([string]$f) { if (Test-Path -LiteralPath $f) { try { return (Get-Content -Raw -LiteralPath $f | ConvertFrom-Json -AsHashtable) } catch { } }; return @{} }
function Write-Json([string]$f, $o) { Set-Content -LiteralPath $f -Value ($o | ConvertTo-Json -Depth 6) }
function Sq([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }
function Test-PidAlive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    if (Test-Path "/proc/$ProcId/stat") { try { return ((Get-Content -Raw "/proc/$ProcId/stat") -notmatch '^\d+ \(.*\) Z') } catch { return $false } }
    try { $null = Get-Process -Id $ProcId -ErrorAction Stop; return $true } catch { return $false }
}
function Read-Pid([string]$f) { if (Test-Path -LiteralPath $f) { $t = (Get-Content -Raw -LiteralPath $f).Trim(); $n = 0; if ([int]::TryParse($t, [ref]$n)) { return $n } }; return 0 }
function Redact([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text -replace '\b[wiq]1\.[A-Za-z0-9_.-]{16,}', '[redacted]' -replace 'gh[pousr]_[A-Za-z0-9]{20,}', '[redacted]' -replace '(?i)\bBearer\s+\S+', 'Bearer [redacted]' `
        -replace '(?i)\b(token|secret|password|api[_-]?key)(\s*[=:]\s*)\S+', '$1$2[redacted]'
    return $t.Replace('`', "'")
}
function Get-TailText([string]$File, [int]$Lines) { if (-not (Test-Path -LiteralPath $File)) { return '' }; return ((Get-Content -LiteralPath $File -Tail $Lines -ErrorAction SilentlyContinue) -join "`n") }
function Test-LoopbackHost([string]$h) {
    $h = $h.Trim().Trim('[', ']').ToLowerInvariant()
    return ($h -in 'localhost', '0.0.0.0', '::1', '::') -or $h.EndsWith('.localhost') -or ($h -match '^127\.') -or ($h -match '^169\.254\.') -or ($h -eq 'metadata.google.internal')
}
function Test-PortFree([int]$Port) {
    try { $c = [Net.Sockets.TcpClient]::new(); $ar = $c.BeginConnect('127.0.0.1', $Port, $null, $null); $up = $ar.AsyncWaitHandle.WaitOne(300) -and $c.Connected; $c.Close(); if ($up) { return $false } } catch { }
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port); $l.Start(); $l.Stop(); return $true } catch { return $false }
}
function Test-Health([string]$Url) {
    try { $r = Invoke-WebRequest -Uri $Url -TimeoutSec 3 -SkipHttpErrorCheck -NoProxy -MaximumRedirection 0 -ErrorAction Stop; return ([int]$r.StatusCode -eq 200) } catch { return $false }
}

# The scrubbed process environment: an allowlist, HOME inside the environment directory. The profile may add variables except credentials.
function Get-ScrubbedEnv([string]$E, $p) {
    $m = [ordered]@{}
    foreach ($k in 'PATH', 'LANG', 'LC_ALL', 'DOTNET_ROOT') { $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $m[$k] = $v } }
    $m['HOME'] = Join-Path $E 'home'; $m['TMPDIR'] = Join-Path $E 'tmp'
    $m['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'; $m['DOTNET_NOLOGO'] = '1'; $m['DOTNET_SKIP_FIRST_TIME_EXPERIENCE'] = '1'; $m['ASPNETCORE_ENVIRONMENT'] = 'Development'
    $db = "$(Pf $p 'database' 'sqlite')".ToLowerInvariant()
    if ($db -eq 'sqlite') { $m['ConnectionStrings__DefaultConnection'] = "Data Source=$(Join-Path $E 'data/app.db')" }
    elseif ($db -eq 'sqlserver') {
        $tpl = "$(Pf $p 'dbconnection' '')"
        if (-not $tpl) { Fail 30 'profile-incomplete' 'database: sqlserver needs a dbConnection template in the profile' }
        $m['ConnectionStrings__DefaultConnection'] = $tpl.Replace('{db}', ('qc_' + ($EnvId -replace '[^A-Za-z0-9_]', '_')))
    }
    $extra = Pf $p 'env' @{}
    if ($extra -is [System.Collections.IDictionary]) {
        foreach ($k in $extra.Keys) { if ("$k" -match '^[A-Za-z_][A-Za-z0-9_]*$' -and "$k" -notmatch '^(?i)(FACTORY_|GH_|GITHUB_|OCTOPUS|ANTHROPIC|AWS_|AZURE_|SSH_|HOME$)') { $m["$k"] = "$($extra[$k])" } }
    }
    return $m
}
function Write-EnvFile([string]$E, $m) { Set-Content -LiteralPath (Join-Path $E 'app.env') -Value (($m.Keys | ForEach-Object { "$_=$($m[$_])" }) -join "`n") }
function Read-EnvFile([string]$E) {
    $m = [ordered]@{}; $f = Join-Path $E 'app.env'
    if (Test-Path -LiteralPath $f) { foreach ($l in (Get-Content -LiteralPath $f)) { $ix = $l.IndexOf('='); if ($ix -gt 0) { $m[$l.Substring(0, $ix)] = $l.Substring($ix + 1) } } }
    return $m
}

# Starts a shell command in its own session with the given environment (null: inherit). Output goes to $Log, stdin from /dev/null, pid written by the launcher.
# -Detach: setsid -f (returns at once); else the call waits through the returned Process.
function Start-Launcher([string]$E, [string]$Name, [string]$Cwd, [string]$Cmd, [string]$Log, [string]$PidFile, $EnvMap, [switch]$Detach, [switch]$Exec) {
    $sh = Join-Path $E "launch-$Name.sh"
    $body = "#!/bin/sh`nexec >> $(Sq $Log) 2>&1 < /dev/null`ncd $(Sq $Cwd) || exit 1`necho `$`$ > $(Sq $PidFile)`n$(if ($Exec) { 'exec ' })$Cmd`n"
    Set-Content -LiteralPath $sh -Value $body -NoNewline
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $setsid = (Get-Command setsid -ErrorAction SilentlyContinue)
    if ($setsid) { $psi.FileName = $setsid.Source; if ($Detach) { $psi.ArgumentList.Add('-f') } } else { $psi.FileName = (Get-Command nohup).Source }
    $psi.ArgumentList.Add('/bin/sh'); $psi.ArgumentList.Add($sh)
    $psi.WorkingDirectory = $E; $psi.UseShellExecute = $false
    if ($null -ne $EnvMap) { $psi.Environment.Clear(); foreach ($k in $EnvMap.Keys) { $psi.Environment[$k] = [string]$EnvMap[$k] } }
    $pr = [Diagnostics.Process]::Start($psi)
    return $pr
}
function Wait-PidFile([string]$PidFile, [int]$Seconds = 8) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) { $n = Read-Pid $PidFile; if ($n -gt 0) { return $n }; Start-Sleep -Milliseconds 100 }
    return 0
}
function Stop-Group([int]$ProcId, [string]$E) {
    if ($ProcId -le 1 -or -not (Test-PidAlive $ProcId)) { return }
    # Never signal a process that is not ours: on Linux its working directory must lie inside the environment directory.
    if (Test-Path "/proc/$ProcId/cwd") { try { $cwd = (Get-Item -LiteralPath "/proc/$ProcId/cwd").ResolvedTarget; if ($cwd -and -not $cwd.StartsWith($E)) { return } } catch { } }
    & kill -TERM -- "-$ProcId" 2>$null; if ($LASTEXITCODE -ne 0) { & kill -TERM $ProcId 2>$null }
    $end = (Get-Date).AddSeconds(6)
    while ((Test-PidAlive $ProcId) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 200 }
    if (Test-PidAlive $ProcId) { & kill -KILL -- "-$ProcId" 2>$null; & kill -KILL $ProcId 2>$null; Start-Sleep -Milliseconds 300 }
}
function Invoke-Capture([string]$File, [string[]]$ArgList, [string]$Cwd, [int]$TimeoutSec, [hashtable]$Env2 = @{}) {
    $psi = [Diagnostics.ProcessStartInfo]::new($File); foreach ($x in $ArgList) { $psi.ArgumentList.Add($x) }
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
    foreach ($k in $Env2.Keys) { $psi.Environment[$k] = $Env2[$k] }
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch { }; return @{ exit = 124; out = ''; err = 'timeout' } }
    $p.WaitForExit()
    return @{ exit = $p.ExitCode; out = $so.GetAwaiter().GetResult(); err = $se.GetAwaiter().GetResult() }
}

# ---------------------------------------------------------------- environments left by a dead session (marked by watch when the app died)
function Remove-DeadEnvs([string]$Base, [string]$Keep) {
    foreach ($d in @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq $Keep -or -not (Test-Path (Join-Path $d.FullName 'dead'))) { continue }
        if (Test-PidAlive (Read-Pid (Join-Path $d.FullName 'app.pid'))) { continue }
        if (Test-PidAlive (Read-Pid (Join-Path $d.FullName 'watch.pid'))) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
}

function Remove-EnvDir([string]$E) {
    # E must be a direct child of a QC base directory and carry our marker, else nothing is removed.
    if (-not (Test-Path -LiteralPath (Join-Path $E 'state.json')) -and -not (Test-Path -LiteralPath (Join-Path $E 'prepared'))) { return }
    Set-Location -LiteralPath (Split-Path -Parent $E)   # a process cannot remove its own working directory
    for ($k = 0; $k -lt 3; $k++) { try { Remove-Item -LiteralPath $E -Recurse -Force -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 300 } }
}

# ================================================================ prepare
function Do-Prepare {
    $p = Read-Profile; $E = Get-EnvDir $p
    if (-not (Test-Has $A 'sha') -or $A.sha -notmatch '^[0-9a-fA-F]{7,64}$') { Fail 2 'usage' '--sha is required (the head sha of the job)' }
    if (-not (Test-Has $A 'pr') -or $A.pr -notmatch '^\d+$') { Fail 2 'usage' '--pr is required (a number)' }
    $sha = $A.sha.ToLowerInvariant()
    Remove-DeadEnvs (Split-Path -Parent $E) $EnvId
    $created = $false
    if (Test-Path -LiteralPath $E) {
        $st = Read-Json (Join-Path $E 'state.json')
        if (-not (Test-Has $st 'sha') -or "$($st.sha)" -ne $sha) { Fail 10 'env-exists-other-sha' 'this environment directory exists for another commit; run stop first' }
        Write-Out @{ ok = $true; env_id = $EnvId; dir = $E; src = (Join-Path $E 'src'); sha = $sha; reused = $true } 0
    }
    $repo = if (Test-Has $A 'repo') { $A.repo } else { "$(Pf $p 'repo' '')" }
    if (-not $repo) {
        $sd = if (Test-Has $A 'source_dir') { $A.source_dir } else { (Get-Location).Path }
        $r = Invoke-Capture 'git' @('-C', $sd, 'remote', 'get-url', 'origin') '' 20
        if ($r.exit -eq 0) { $repo = $r.out.Trim() }
    }
    if (-not $repo) { Fail 30 'profile-incomplete' 'no repository to fetch: set repo in the profile or pass --repo' }
    $src = Join-Path $E 'src'
    foreach ($d in 'home', 'data', 'tmp', 'src') { New-Item -ItemType Directory -Force -Path (Join-Path $E $d) | Out-Null }
    Set-Content -LiteralPath (Join-Path $E 'prepared') -Value '1'; $created = $true
    $g = @{ GIT_TERMINAL_PROMPT = '0' }
    $steps = @(
        @('-C', $src, 'init', '-q'),
        @('-C', $src, '-c', 'core.hooksPath=/dev/null', 'fetch', '-q', '--no-tags', $repo, "pull/$($A.pr)/head"))
    foreach ($s in $steps) {
        $r = Invoke-Capture 'git' $s '' 300 $g
        if ($r.exit -ne 0) { Remove-EnvDir $E; Fail 20 'fetch-failed' "git could not fetch the pull request head: $(Redact ($r.err.Trim() -split "`n" | Select-Object -Last 2 | Out-String))" @{ retryAfterSeconds = 30 } }
    }
    $rp = Invoke-Capture 'git' @('-C', $src, 'rev-parse', 'FETCH_HEAD') '' 30
    $got = $rp.out.Trim().ToLowerInvariant()
    if ($rp.exit -ne 0 -or $got -ne $sha) { Remove-EnvDir $E; Fail 11 'stale-head' 'the fetched head is not the commit of the job' @{ fetched_sha = $got; job_sha = $sha } }
    $co = Invoke-Capture 'git' @('-C', $src, '-c', 'core.hooksPath=/dev/null', 'checkout', '-q', '--detach', 'FETCH_HEAD') '' 300 $g
    if ($co.exit -ne 0) { Remove-EnvDir $E; Fail 20 'fetch-failed' 'git could not check out the head' }
    $build = "$(Pf $p 'build' 'dotnet build src/UI/Server -c Release')"
    if ($build.TrimStart() -match '^dotnet\b') {
        $dv = Invoke-Capture 'dotnet' @('--version') '' 30
        if ($dv.exit -ne 0) { Remove-EnvDir $E; Fail 10 'no-dotnet' 'the .NET SDK is not available on this machine' }
    }
    $m = Get-ScrubbedEnv $E $p; Write-EnvFile $E $m
    Write-Json (Join-Path $E 'state.json') @{ env_id = $EnvId; sha = $sha; pr = [int]$A.pr; item = $(if (Test-Has $A 'item') { "$($A.item)" } else { '' }); created = [DateTime]::UtcNow.ToString('o') }
    Write-Out @{ ok = $true; env_id = $EnvId; dir = $E; src = $src; sha = $sha; base_dir = (Split-Path -Parent $E); build_log = (Join-Path $E 'build.log'); reused = $false } 0
}

# ================================================================ build
function Get-Prepared($p) {
    $E = Get-EnvDir $p
    if (-not (Test-Path -LiteralPath (Join-Path $E 'state.json'))) { Fail 12 'no-environment' 'run prepare first' }
    return $E
}
function Do-Build {
    $p = Read-Profile; $E = Get-Prepared $p
    $cmd = "$(Pf $p 'build' 'dotnet build src/UI/Server -c Release')"
    $cap = if (Test-Has $A 'cap_seconds') { [int]$A.cap_seconds } else { [int]([double](Pf $p 'buildminutes' 8) * 60) }
    $log = Join-Path $E 'build.log'; $pidf = Join-Path $E 'build.pid'
    $t0 = Get-Date
    $pr = Start-Launcher $E 'build' (Join-Path $E 'src') $cmd $log $pidf (Read-EnvFile $E)
    if (-not $pr.WaitForExit($cap * 1000)) {
        $id = Read-Pid $pidf; if ($id -le 0) { $id = $pr.Id }
        & kill -TERM -- "-$id" 2>$null; Start-Sleep -Seconds 2; & kill -KILL -- "-$id" 2>$null; try { $pr.Kill($true) } catch { }
        Fail 20 'build-timeout' "the build did not finish within $cap seconds" @{ tail = (Redact (Get-TailText $log 30)) }
    }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    if ($pr.ExitCode -ne 0) { Fail 10 'build-failed' "the build command exited with $($pr.ExitCode)" @{ tail = (Redact (Get-TailText $log 30)); seconds = $secs } }
    Write-Out @{ ok = $true; env_id = $EnvId; seconds = $secs; build_log = $log } 0
}

# ================================================================ run
function Do-Run {
    $p = Read-Profile; $E = Get-Prepared $p
    $st = Read-Json (Join-Path $E 'state.json')
    if (Test-PidAlive (Read-Pid (Join-Path $E 'app.pid'))) { Fail 10 'already-running' 'this environment is already running; run stop first' }
    $range = "$(Pf $p 'portrange' '5400-5499')"
    if ($range -notmatch '^(\d{2,5})\s*-\s*(\d{2,5})$' -or [int]$Matches[1] -gt [int]$Matches[2]) { Fail 30 'profile-incomplete' "port range '$range' is not like 5400-5499" }
    $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
    $address = "$(Pf $p 'address' '')"
    $tunnel = "$(Pf $p 'tunnel' '')"
    if (($address -in '', 'none') -and -not $tunnel) { Fail 10 'no-reachable-url' 'the profile has no address others can reach this computer on (address: none)' }
    $bind = "$(Pf $p 'bind' '')"; if (-not $bind) { $bind = if ($address -in '', 'none') { '127.0.0.1' } else { $address } }
    $healthPath = "$(Pf $p 'healthpath' '/_healthcheck')"; if (-not $healthPath.StartsWith('/')) { $healthPath = "/$healthPath" }
    $healthHost = if ($bind -in '0.0.0.0', '::') { '127.0.0.1' } else { $bind }
    $runTpl = "$(Pf $p 'run' 'dotnet run -c Release --no-build --project src/UI/Server --urls http://{bind}:{port}')"
    $healthTimeout = [int](Pf $p 'healthtimeoutseconds' 120)
    $tried = New-Object System.Collections.ArrayList; $log = Join-Path $E 'app.log'; $pidf = Join-Path $E 'app.pid'
    $port = 0; $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        $port = 0
        for ($c = $lo; $c -le $hi; $c++) { if ($tried -notcontains $c -and (Test-PortFree $c)) { $port = $c; break } }
        if ($port -eq 0) { Fail 20 'port-busy' "no free port in $range" @{ tried = @($tried) } }
        [void]$tried.Add($port)
        $m = Read-EnvFile $E; $m['ASPNETCORE_URLS'] = "http://${bind}:$port"; $m['QC_PORT'] = "$port"; $m['QC_BIND'] = $bind
        Write-EnvFile $E $m
        Remove-Item -LiteralPath $pidf -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $log -Value ''
        $cmd = $runTpl.Replace('{port}', "$port").Replace('{bind}', $bind).Replace('{dir}', (Join-Path $E 'src'))
        [void](Start-Launcher $E 'app' (Join-Path $E 'src') $cmd $log $pidf $m -Detach)
        $appPid = Wait-PidFile $pidf
        if ($appPid -le 0) { Fail 10 'start-failed' 'the application did not start' @{ tail = (Redact (Get-TailText $log 30)) } }
        $end = (Get-Date).AddSeconds($healthTimeout); $died = $false
        while ((Get-Date) -lt $end) {
            if (-not (Test-PidAlive $appPid)) { $died = $true; break }
            if (Test-Health "http://${healthHost}:$port$healthPath") { $ok = $true; break }
            Start-Sleep -Milliseconds 400
        }
        if ($ok) { break }
        if ($died) {
            $tail = Get-TailText $log 30
            if ($tail -match '(?i)address already in use|EADDRINUSE|Errno 98|port.*(in use|busy)|Only one usage') { continue }
            Fail 10 'start-failed' 'the application exited before it was healthy' @{ tail = (Redact $tail); port = $port }
        }
        Stop-Group $appPid $E
        Fail 20 'health-timeout' "the application did not answer $healthPath within $healthTimeout seconds" @{ tail = (Redact (Get-TailText $log 30)); port = $port }
    }
    if (-not $ok) { Fail 20 'port-busy' 'three ports in a row were taken' @{ tried = @($tried); tail = (Redact (Get-TailText $log 30)) } }
    $appPid = Read-Pid $pidf
    # URL: decided here from the profile, never by the model.
    $url = ''
    if ($tunnel) {
        $tr = Invoke-Capture '/bin/sh' @('-c', $tunnel.Replace('{port}', "$port")) $E 40 @{}
        $mt = [regex]::Match(($tr.out + "`n" + $tr.err), 'https?://[^\s''"<>]+')
        if ($mt.Success) { $url = $mt.Value }
    } else { $url = "http://${address}:$port" }
    $uri = $null
    if (-not $url -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https' -or $uri.UserInfo) {
        Stop-Group $appPid $E; Fail 10 'no-reachable-url' 'no usable URL could be built from the profile address'
    }
    if ((Test-LoopbackHost $uri.Host) -and -not (Test-Truthy (Pf $p 'allowloopback' $false))) {
        Stop-Group $appPid $E; Fail 10 'loopback-url' "the address $($uri.Host) is not reachable by anyone else; set a LAN or tailnet address in the profile"
    }
    $item = "$($st.item)"; if (Test-Has $A 'item') { $item = "$($A.item)" }
    $repSha = if (Test-Has $A 'sha') { $A.sha.ToLowerInvariant() } else { "$($st.sha)" }   # --sha: the sha the gateway knows (equal to the fetched one in production)
    $rep = @{ item = $item; pr = "$($st.pr)"; sha = $repSha; env_id = $EnvId; url = $url; port = $port; local_health = 'ok' }
    Write-Json (Join-Path $E 'report.json') $rep
    Write-Json (Join-Path $E 'app.json') @{ pid = $appPid; port = $port; bind = $bind; url = $url; health_url = "http://${healthHost}:$port$healthPath"; started = [DateTime]::UtcNow.ToString('o') }
    $tokDir = Get-FwSubDir 'tokens' $env:FACTORY_TOKEN_DIR
    Write-Json (Join-Path $E 'watch.json') @{ gateway = "$env:FACTORY_URL".TrimEnd('/'); token_dir = $tokDir; item = $item
        interval = [int](Pf $p 'heartbeatseconds' 60); gateway_lost_seconds = [int](Pf $p 'gatewaylostseconds' 900); profile = (Get-ProfilePath) }
    $base = Split-Path -Parent $E
    $wcmd = "pwsh -NoProfile -File $(Sq $script:Self) watch --env-id $(Sq $EnvId) --base-dir $(Sq $base) --profile $(Sq (Get-ProfilePath))"
    [void](Start-Launcher $E 'watch' $E $wcmd (Join-Path $E 'watch.log') (Join-Path $E 'watch.pid') $null -Detach -Exec)
    [void](Wait-PidFile (Join-Path $E 'watch.pid'))
    Write-Out @{ ok = $true; env_id = $EnvId; port = $port; url = $url; pid = $appPid; local_health = 'ok'; report = $rep; port_attempts = @($tried) } 0
}

# ================================================================ watch (detached heartbeat, no model)
function Do-Watch {
    $p = Read-Profile; $E = Get-EnvDir $p
    $w = Read-Json (Join-Path $E 'watch.json'); $app = Read-Json (Join-Path $E 'app.json')
    if (-not (Test-Has $w 'item') -or -not (Test-Has $app 'pid')) { exit 0 }
    $logf = Join-Path $E 'watch.log'
    function WLog([string]$s) { try { Add-Content -LiteralPath $logf -Value "$([DateTime]::UtcNow.ToString('o')) $s" } catch { } }
    $interval = [Math]::Max(1, [int]$w.interval); $lostMax = [int]$w.gateway_lost_seconds
    $item = "$($w.item)"; $gw = "$($w.gateway)"; $tokFile = Join-Path "$($w.token_dir)" "$item.qc"
    $appPid = [int]$app.pid; $lostSince = $null; $deadReported = $false
    # A newer assignment for the same item (reset, relaunch) replaces the token file: this environment is then superseded and must go.
    function Get-TokenStamp { if (Test-Path -LiteralPath $tokFile) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((Get-Content -Raw -LiteralPath $tokFile)))) }; return '' }
    $stamp0 = Get-TokenStamp
    WLog "watch started for $EnvId, interval ${interval}s"
    function Call([string]$Verb, $Body) {
        if (-not (Test-Path -LiteralPath $tokFile)) { return @{ status = 0; json = $null } }
        $tok = (Get-Content -Raw -LiteralPath $tokFile).Trim()
        try {
            $r = Invoke-WebRequest -Uri "$gw/api/v1/verbs/$Verb" -Method POST -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ Authorization = "Bearer $tok" } -SkipHttpErrorCheck -NoProxy -TimeoutSec 20
            $j = try { $r.Content | ConvertFrom-Json -AsHashtable } catch { $null }
            return @{ status = [int]$r.StatusCode; json = $j }
        } catch { return @{ status = 0; json = $null } }
    }
    function Finish([bool]$Notify) {
        if ($Notify) { $r = Call 'qc-stopped' @{ item = $item; env_id = $EnvId }; WLog "qc-stopped answered $($r.status)" }
        & pwsh -NoProfile -File $script:Self stop --env-id $EnvId --base-dir (Split-Path -Parent $E) --profile $w.profile --from-watch *> $null
        exit 0
    }
    while ($true) {
        for ($s = 0; $s -lt $interval; $s++) { Start-Sleep -Seconds 1; if (-not (Test-Path -LiteralPath $E) -or (Test-Path -LiteralPath (Join-Path $E 'stopping'))) { exit 0 } }
        if ($stamp0 -and (Get-TokenStamp) -ne $stamp0) { WLog 'a newer assignment replaced the item token; this environment is superseded, stopping'; Finish $false }
        $alive = Test-PidAlive $appPid
        $health = if ($alive -and (Test-Health "$($app.health_url)")) { 'ok' } else { 'fail' }
        $body = @{ item = $item; env_id = $EnvId; app_alive = $alive; local_health = $health }
        if (Test-Path /proc/meminfo) { $mm = Select-String -Path /proc/meminfo -Pattern '^MemAvailable:\s+(\d+)' | Select-Object -First 1; if ($mm) { $body.mem_free_mb = [int]([long]$mm.Matches[0].Groups[1].Value / 1024) } }
        $r = Call 'qc-heartbeat' $body
        if ($r.status -eq 200 -and $r.json) {
            $lostSince = $null
            $act = "$($r.json.action)"
            if (-not $alive) {
                if (-not $deadReported) { WLog 'the application died; reported to the gateway'; $deadReported = $true }
                Set-Content -LiteralPath (Join-Path $E 'dead') -Value '1'
                exit 0
            }
            switch ($act) {
                'teardown' { WLog 'teardown requested'; Finish $true }
                're-report' {
                    $rep = Read-Json (Join-Path $E 'report.json'); $rr = Call 'qc-report' $rep
                    WLog "re-report answered $($rr.status)"
                }
                'reset' { WLog 'reset requested; waiting for the session to stop this environment' }
            }
        } elseif ($r.status -in 11, 401, 403, 409 -or ($r.json -and "$($r.json.code)" -in 'stale-assignment', 'forbidden')) {
            WLog "the assignment is no longer current (HTTP $($r.status)); stopping"; Finish $false
        } else {
            if (-not $alive -and -not $deadReported) { $deadReported = $true; Set-Content -LiteralPath (Join-Path $E 'dead') -Value '1' }
            if ($null -eq $lostSince) { $lostSince = Get-Date }
            WLog "the gateway did not answer (status $($r.status))"
            if (((Get-Date) - $lostSince).TotalSeconds -ge $lostMax) { WLog 'the gateway has been gone too long; stopping'; Finish $false }
            if (-not $alive) { exit 0 }
        }
    }
}

# ================================================================ stop
function Do-Stop {
    $p = Read-Profile; $E = Get-EnvDir $p
    if (-not (Test-Path -LiteralPath $E)) { Write-Out @{ ok = $true; env_id = $EnvId; removed = $false; note = 'nothing to remove' } 0 }
    Set-Content -LiteralPath (Join-Path $E 'stopping') -Value '1'
    $wp = Read-Pid (Join-Path $E 'watch.pid')
    if ($wp -gt 0 -and $wp -ne $PID -and -not (Test-Has $A 'from_watch')) { Stop-Group $wp $E; if (Test-PidAlive $wp) { & kill -TERM $wp 2>$null } }
    Stop-Group (Read-Pid (Join-Path $E 'app.pid')) $E
    Stop-Group (Read-Pid (Join-Path $E 'build.pid')) $E
    $alive = Test-PidAlive (Read-Pid (Join-Path $E 'app.pid'))
    Remove-EnvDir $E
    Write-Out @{ ok = (-not $alive); env_id = $EnvId; removed = (-not (Test-Path -LiteralPath $E)); app_stopped = (-not $alive) } $(if ($alive) { 20 } else { 0 })
}

# ================================================================ logs, status
function Do-Logs {
    $p = Read-Profile; $E = Get-EnvDir $p
    if (-not (Test-Path -LiteralPath $E)) { Fail 12 'no-environment' 'no such environment' }
    $n = if (Test-Has $A 'tail') { [Math]::Max(1, [Math]::Min(200, [int]$A.tail)) } else { 40 }
    $which = if (Test-Has $A 'which') { $A.which } else { $(if ((Test-Path (Join-Path $E 'app.log')) -and (Get-Item (Join-Path $E 'app.log')).Length -gt 0) { 'app' } else { 'build' }) }
    if ($which -notin 'build', 'app', 'watch') { Fail 2 'usage' 'which is build, app or watch' }
    $text = Redact (Get-TailText (Join-Path $E "$which.log") $n)
    if ($text.Length -gt 1500) { $text = $text.Substring($text.Length - 1500) }
    $out = Join-Path $E 'log-tail.txt'; Set-Content -LiteralPath $out -Value $text -NoNewline
    Write-Out @{ ok = $true; env_id = $EnvId; which = $which; file = $out; text = $text } 0
}
function Do-Status {
    $p = Read-Profile; $E = Get-EnvDir $p
    if (-not (Test-Path -LiteralPath $E)) { Write-Out @{ ok = $true; env_id = $EnvId; exists = $false } 0 }
    $st = Read-Json (Join-Path $E 'state.json'); $app = Read-Json (Join-Path $E 'app.json')
    $appAlive = Test-PidAlive (Read-Pid (Join-Path $E 'app.pid')); $watchAlive = Test-PidAlive (Read-Pid (Join-Path $E 'watch.pid'))
    $health = if ($appAlive -and (Test-Has $app 'health_url') -and (Test-Health "$($app.health_url)")) { 'ok' } else { 'fail' }
    Write-Out @{ ok = $true; env_id = $EnvId; exists = $true; dir = $E; sha = $(if (Test-Has $st 'sha') { $st.sha } else { '' }); port = $(if (Test-Has $app 'port') { $app.port } else { 0 })
        url = $(if (Test-Has $app 'url') { $app.url } else { '' }); app_alive = $appAlive; watch_alive = $watchAlive; local_health = $health; reported = (Test-Path (Join-Path $E 'report.json')); dead = (Test-Path (Join-Path $E 'dead')) } 0
}

try {
    switch ($sub) { 'prepare' { Do-Prepare } 'build' { Do-Build } 'run' { Do-Run } 'watch' { Do-Watch } 'stop' { Do-Stop } 'logs' { Do-Logs } 'status' { Do-Status } }
} catch {
    Fail 20 'internal-error' "qc-local $sub failed: $(Redact $_.Exception.Message)"
}
