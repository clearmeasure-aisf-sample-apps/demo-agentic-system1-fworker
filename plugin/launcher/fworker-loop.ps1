#!/usr/bin/env pwsh
# fworker-loop.ps1: runs factory worker sessions one after another, one work item per session (docs/launcher.md). PowerShell 7 or later
# on any system (the connect prompt installs it where it is missing; Windows PowerShell 5.1 lacks what this script uses).
#
#   fworker-loop.ps1 -Dir BASE -PromptFile FILE [-Backoff 10] [-MaxBackoff 300] [-StopFile FILE] [-Claude claude] [-ClaudeArgs '--model ID --effort low']
#                    [-StreamStale 600] [-Silent 1800] [-Unsent 600] [-ScreenCmd CMD] [-Sidecar auto|on|off] [-Pwsh PWSH]
#
# Each round starts a new `claude` session with the connect prompt (the content of FILE) as its first message. When the worker's item has ended the
# worker runs `factory.ps1 end-session`, which writes BASE/work/session-ended (this script sets FACTORY_SESSION_END_FILE to that path); the script
# then ends that session and starts the next one after a short pause. A session that exits by itself (a crash, or a person quit it) is started again
# too, with a pause that doubles up to -MaxBackoff.
# Stop: create the stop file (default BASE/work/STOP; the session that runs finishes its item first), or press Ctrl-C while no session runs.
# Watchdog (as fworker-loop.sh): the session is ended and restarted when its event stream showed no line for -StreamStale seconds, when its screen did
# not change for -Silent seconds while it holds an item, or when its prompt holds typed, unsent input for -Unsent seconds. The screen is read with
# -ScreenCmd (a command line whose output is the screen), default `tmux capture-pane -p` inside tmux; without one the screen checks are off. 0 switches
# a check off. Every restart and its reason is written to BASE/work/launcher.log.
# Stream sidecar (issue 106, as fworker-loop.sh): the launcher runs the session's event stream (the `factory.ps1 subscribe --own ...` of step 7 of the
# connect prompt, with the credentials of its step 4 or of FACTORY_URL, FACTORY_TOKEN and FACTORY_HOLDER) for the session's whole lifetime and appends
# every line to BASE/work/events.log; the session's Monitor only tails that file. -Sidecar auto (default) runs it when the prompt names the command,
# on requires it, off leaves the stream to the session.
param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$PromptFile,
    [int]$Backoff = 10,
    [int]$MaxBackoff = 300,
    [string]$StopFile = '',
    [string]$Claude = 'claude',
    [string[]]$ClaudeArgs = @(),
    [int]$StreamStale = 600,
    [int]$Silent = 1800,
    [int]$Unsent = 600,
    [string]$ScreenCmd = '',
    [ValidateSet('auto', 'on', 'off')][string]$Sidecar = 'auto',
    [string]$Pwsh = ''
)
$ErrorActionPreference = 'Stop'
# pwsh -File passes an array as one string: one string is split at spaces (a value with a space needs the array form under pwsh -Command)
if ($ClaudeArgs.Count -eq 1) { $ClaudeArgs = @($ClaudeArgs[0] -split '\s+' | Where-Object { $_ }) }
function Say([string]$Text) { Write-Host "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) fworker-loop: $Text" }

if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Say "no prompt file at $PromptFile"; exit 2 }
$cmd = Get-Command $Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) { Say "$Claude is not on the PATH"; exit 2 }
$work = Join-Path $Dir 'work'; New-Item -ItemType Directory -Force -Path $work | Out-Null
$marker = Join-Path $work 'session-ended'
if (-not $StopFile) { $StopFile = Join-Path $work 'STOP' }
$env:FACTORY_SESSION_END_FILE = $marker
$alive = Join-Path $work 'stream-alive'; $owning = Join-Path $work 'session-owning'; $log = Join-Path $work 'launcher.log'
if (-not $ScreenCmd -and $env:TMUX_PANE -and (Get-Command tmux -ErrorAction SilentlyContinue)) { $ScreenCmd = "tmux capture-pane -p -t $($env:TMUX_PANE)" }
function Write-Restart([string]$Why) {
    Say "restart session ${round}: $Why"
    try { Add-Content -LiteralPath $log -Value "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) session $round restart: $Why" } catch { }
}
# the watchdog's verdict for the running session, or '': stream silence, screen silence while it holds an item, typed input left unsent
function Test-Watchdog {
    $now = [DateTime]::UtcNow
    if ($StreamStale -gt 0) {
        $ref = $script:started
        if (Test-Path -LiteralPath $alive) { $m = (Get-Item -LiteralPath $alive).LastWriteTimeUtc; if ($m -gt $ref) { $ref = $m } }
        $q = [int]($now - $ref).TotalSeconds
        if ($q -ge $StreamStale) { return "stream-disconnected: no line on the event stream for $q s" }
    }
    if (-not $ScreenCmd) { return '' }
    $scr = try { if ($IsWindows) { ($null | & cmd /d /c $ScreenCmd 2>$null) -join "`n" } else { ($null | & sh -c $ScreenCmd 2>$null) -join "`n" } } catch { return '' }
    if ($scr -ne $script:lastScreen) { $script:lastScreen = $scr; $script:screenAt = $now; return '' }
    $quiet = [int]($now - $script:screenAt).TotalSeconds
    # only the bottom-most prompt line among the last 8 non-blank lines counts (tmux pads the capture to the pane height) (the transcript above shows earlier messages with the same marker), without the
    # box border, the "Try ..." placeholder or a numbered menu row
    $line = @(@($scr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) | Where-Object { $_ -match '^( |│|\|)*(>|❯)( |$)' } | Select-Object -Last 1)
    $text = if ($line.Count) { ($line[0] -replace '^( |│|\|)*(>|❯) *', '' -replace '( |│|\|)*$', '') } else { '' }
    $typed = $text -and $text -notmatch '^Try "' -and $text -notmatch '^\d+\.'
    if ($Unsent -gt 0 -and $quiet -ge $Unsent -and $typed) { return "unsent-input: typed input sat unsent in the prompt for $quiet s" }
    if ($Silent -gt 0 -and (Test-Path -LiteralPath $owning) -and $quiet -ge $Silent) { return "no-output-while-owning: the screen did not change for $quiet s while the session holds item $("$(Get-Content -Raw -LiteralPath $owning -ErrorAction SilentlyContinue)".Trim())" }
    return ''
}
$promptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)

# ---- the stream sidecar: what it runs, worked out from the options, the environment and the connect prompt at the start of every round -----------
$Dir = (Resolve-Path -LiteralPath $Dir).Path; $work = Join-Path $Dir 'work'
$events = Join-Path $work 'events.log'; $noteFile = Join-Path $work 'launcher-note.txt'
$sc = $null; $scCopy = @(); $scFinal = $false; $scDelay = 2; $scNextAt = [DateTime]::MinValue; $scOn = $false; $scWhy = ''
$scScripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/factory.ps1'
if (-not $Pwsh) { $Pwsh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh | Select-Object -First 1).Source } elseif (Test-Path (Join-Path $Dir 'pwsh/pwsh.exe')) { Join-Path $Dir 'pwsh/pwsh.exe' } elseif (Test-Path (Join-Path $Dir 'pwsh/pwsh')) { Join-Path $Dir 'pwsh/pwsh' } else { (Get-Process -Id $PID).Path } }
# the command and credentials of this round (a refreshed prompt file is read again): the prompt's first, else the environment's
function Read-SidecarPlan {
    $script:scOn = $false; $script:scWhy = ''
    if ($Sidecar -eq 'off') { $script:scWhy = '-Sidecar off'; return }
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path)
    $m = [regex]::Match($text, 'factory\.ps1 (subscribe --own[^\r\n]*)')
    $script:scArgs = if ($m.Success) { @($m.Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ }) } else { @() }
    $val = { param($k, $envValue) $v = [regex]::Match($text, "FACTORY_$k=(\S+)"); if ($v.Success) { $v.Groups[1].Value } else { $envValue } }
    $script:scUrl = & $val 'URL' $env:FACTORY_URL; $script:scTok = & $val 'TOKEN' $env:FACTORY_TOKEN; $script:scName = & $val 'HOLDER' $env:FACTORY_HOLDER
    if ($script:scArgs.Count -eq 0) { $script:scWhy = 'the prompt names no subscribe --own command' }
    elseif (@($script:scArgs | Where-Object { $_ -in '--supervisor', '--operator', '--spawn' }).Count) { $script:scWhy = 'the prompt is not the one of a worker session' }
    elseif (-not $script:scUrl -or -not $script:scTok) { $script:scWhy = 'no FACTORY_URL and FACTORY_TOKEN in the prompt or the environment' }
    elseif (-not (Test-Path -LiteralPath $scScripts)) { $script:scWhy = "no factory.ps1 next to the launcher ($scScripts)" }
    $script:scOn = -not $script:scWhy
}
if ($Sidecar -eq 'on') { Read-SidecarPlan; if (-not $scOn) { Say "-Sidecar on, but $scWhy"; exit 2 } }
# starts the sidecar of this session: stdout appended to events.log, stderr to events.err, both written through so a tail sees every line at once.
# Its credentials go to it alone, never to the session; the other credential variables are taken out, so the client uses exactly these
function Start-Sidecar {
    $psi = [Diagnostics.ProcessStartInfo]::new($Pwsh); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    foreach ($x in @('-NoProfile', '-File', $scScripts) + $script:scArgs) { $psi.ArgumentList.Add([string]$x) }
    foreach ($k in 'FACTORY_SUPERVISOR_TOKEN', 'FACTORY_WORKER_TOKEN', 'FACTORY_OPERATOR_SESSION_TOKEN') { [void]$psi.Environment.Remove($k) }
    $psi.Environment['FACTORY_URL'] = $script:scUrl; $psi.Environment['FACTORY_TOKEN'] = $script:scTok; $psi.Environment['FACTORY_WORK_DIR'] = $work
    if ($script:scName) { $psi.Environment['FACTORY_HOLDER'] = $script:scName }
    if (-not $env:FACTORY_DATA_DIR) { $psi.Environment['FACTORY_DATA_DIR'] = Join-Path $Dir 'data' }
    $script:sc = [Diagnostics.Process]::Start($psi); $script:sc.StandardInput.Close(); $script:scStartedAt = [DateTime]::UtcNow
    $o = [IO.FileStream]::new($events, 'Append', 'Write', 'ReadWrite', 1); $e = [IO.FileStream]::new((Join-Path $work 'events.err'), 'Append', 'Write', 'ReadWrite', 1)
    $script:scCopy = @(@{ s = $o; t = $script:sc.StandardOutput.BaseStream.CopyToAsync($o, 4096) }, @{ s = $e; t = $script:sc.StandardError.BaseStream.CopyToAsync($e, 4096) })
}
function Stop-Sidecar {
    if ($script:sc) { if (-not $script:sc.HasExited) { try { $script:sc.Kill($true) } catch { } }; [void]$script:sc.WaitForExit(10000) }
    foreach ($c in $script:scCopy) { try { [void]$c.t.Wait(5000) } catch { }; try { $c.s.Dispose() } catch { } }
    $script:sc = $null; $script:scCopy = @()
}
# a sidecar that ended while its session runs is started again, after a pause that doubles up to 60 s (back to 2 s once one lived a minute); not
# after a refusal (exit 2 usage, 10, 30 credential, 40 a newer stream of the name replaced it: the session started its own stream after all)
function Test-Sidecar {
    if (-not $script:scOn -or $script:scFinal) { return }
    if ($script:sc) {
        if (-not $script:sc.HasExited) { return }
        $c = $script:sc.ExitCode; $lived = ([DateTime]::UtcNow - $script:scStartedAt).TotalSeconds; Stop-Sidecar
        if ($lived -ge 60) { $script:scDelay = 2 }
        if ($c -in 2, 10, 30, 40) {
            $script:scFinal = $true; Say "the stream sidecar ended (exit $c): not started again in this session"
            try { Add-Content -LiteralPath $log -Value "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) session $round sidecar ended: exit $c" } catch { }
            return
        }
        Say "the stream sidecar ended (exit $c): starting it again in $($script:scDelay) s"
        $script:scNextAt = [DateTime]::UtcNow.AddSeconds($script:scDelay); $script:scDelay = [Math]::Min(60, $script:scDelay * 2)
        return
    }
    if ([DateTime]::UtcNow -ge $script:scNextAt) {
        try { Start-Sidecar; Say "stream sidecar started again (pid $($script:sc.Id))" }
        catch { Say "the stream sidecar did not start ($($_.Exception.Message)): trying again in $($script:scDelay) s"; Stop-Sidecar; $script:scNextAt = [DateTime]::UtcNow.AddSeconds($script:scDelay); $script:scDelay = [Math]::Min(60, $script:scDelay * 2) }
    }
}
function Get-SidecarNote {
    $q = { param($p) if ($IsWindows) { "'$($p -replace "'", "''")'" } else { "'$($p -replace "'", "'\''")'" } }
    $pw = if ($IsWindows) { "& $(& $q $Pwsh) -NoProfile -Command `"Get-Content -LiteralPath $(& $q $events) -Wait`"" } else { "tail -n +1 -F $(& $q $events)" }
    $pw0 = if ($IsWindows) { "& $(& $q $Pwsh) -NoProfile -Command `"Get-Content -LiteralPath $(& $q $events) -Wait -Tail 0`"" } else { "tail -n0 -F $(& $q $events)" }
    "LAUNCHER NOTE (fworker-loop, stream sidecar): this launcher already runs the event stream of this session, the command of step 7, as a sidecar process for the whole session, and appends every line it prints to $events . Do not start factory.ps1 subscribe yourself: a second stream of this name would replace it. Step 7 instead: Monitor on   $pw   (from the first line: lines arrived while you set up), with the longest time limit the tool allows. Whenever that Monitor ends, start Monitor on   $pw0   at once (a re-arm registers nothing and replays nothing), then read the last lines of that file once and handle any line you have not handled yet. Without a Monitor tool, read the new lines of that file every 30 seconds. Everything else in the steps above is unchanged."
}

# A .cmd or .ps1 shim (an npm install on Windows) cannot take a long argument with line breaks: that session gets a short first message that names the
# prompt file instead. An executable gets the prompt itself.
$exe = $cmd.Source; $pre = @()
if ($exe -match '\.(cmd|bat)$') { $pre = @('/d', '/c', $exe); $exe = $env:ComSpec; $promptText = "Read the file $((Resolve-Path -LiteralPath $PromptFile).Path) and follow it exactly: it is the connect prompt of this factory worker session." }
elseif ($exe -match '\.ps1$') { $pre = @('-NoProfile', '-File', $exe); $exe = (Get-Process -Id $PID).Path; $promptText = "Read the file $((Resolve-Path -LiteralPath $PromptFile).Path) and follow it exactly: it is the connect prompt of this factory worker session." }

$delay = $Backoff; $round = 0; $proc = $null
try {
    while ($true) {
        if (Test-Path -LiteralPath $StopFile) { Say "stop file $StopFile is present: not starting another session"; break }
        foreach ($f in $marker, "$marker.reason", $alive, $owning) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        $script:started = [DateTime]::UtcNow; $script:screenAt = $script:started; $script:lastScreen = $null; $checkAt = [DateTime]::MinValue; $restarted = ''; $script:scFinal = $false; $script:scDelay = 2; $script:scNextAt = [DateTime]::MinValue
        $round++; Say "session $round starts"
        if (-not $pre) { $promptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $PromptFile).Path) }     # a refreshed prompt is used by the next session
        $firstMessage = $promptText
        # the sidecar of this session: a fresh events.log (the last session's is kept as events.log.1); its stream registers as a new session
        Read-SidecarPlan
        if ($scOn) {
            try { if (Test-Path -LiteralPath $events) { Move-Item -LiteralPath $events -Destination "$events.1" -Force } } catch { }   # (a reader may still hold it)
            try { Set-Content -LiteralPath $events -Value '' -NoNewline } catch { }
            $scFailed = $false
            try { Start-Sidecar; Say "stream sidecar started (pid $($script:sc.Id)): $events"; [void]$script:sc.WaitForExit(5000) } catch { Say "the stream sidecar did not start: $($_.Exception.Message)"; $scFailed = $true }
            # one that cannot even start (no ICU, a malformed command line) is no stream: this session gets none and starts its own as before
            if ($scFailed) { Stop-Sidecar; $scOn = $false }
            elseif ($script:sc.HasExited) { Say "the stream sidecar ended at once (exit $($script:sc.ExitCode)): this session starts its own stream"; Stop-Sidecar; $scOn = $false }
            else {
                $note = Get-SidecarNote
                try { Set-Content -LiteralPath $noteFile -Value $note } catch { }
                # a .cmd shim's first message is one short line (cmd.exe cannot carry line breaks; a .ps1 shim gets ArgumentList quoting and can): it names the note's file instead
                $firstMessage = if ($pre -and $pre[0] -eq '/d') { "$promptText Then read the file $noteFile before step 7: the launcher runs the event stream for you." } else { "$promptText`n`n$note" }
            }
        }
        elseif ($Sidecar -ne 'off') { Say "no stream sidecar: $scWhy" }
        # ProcessStartInfo.ArgumentList quotes each argument for the system; no redirection, so the session has this console
        $psi = [Diagnostics.ProcessStartInfo]::new($exe); $psi.UseShellExecute = $false
        foreach ($x in @($pre) + @($ClaudeArgs) + @($firstMessage)) { $psi.ArgumentList.Add([string]$x) }
        $proc = [Diagnostics.Process]::Start($psi)
        $ended = $false
        while (-not $proc.HasExited) {
            $why = ''
            if (Test-Path -LiteralPath $marker) {
                $why = "$(Get-Content -Raw -LiteralPath "$marker.reason" -ErrorAction SilentlyContinue)".Trim()
                if (-not $why) { $why = 'end-session: the worker ended its session' }
                Write-Restart $why
                Start-Sleep -Seconds 5
            } elseif ([DateTime]::UtcNow -ge $checkAt) {
                $checkAt = [DateTime]::UtcNow.AddSeconds(5); $why = Test-Watchdog
                if ($why) { $why = "watchdog $why"; Write-Restart $why }
            }
            if ($why) {
                $ended = $true; $restarted = $why
                # the whole tree: a shim's child is the real session
                if (-not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
                [void]$proc.WaitForExit(10000)
                break
            }
            Test-Sidecar
            Start-Sleep -Seconds 2
        }
        $code = if ($proc.HasExited) { $proc.ExitCode } else { -1 }; $proc = $null
        Stop-Sidecar     # the stream lives exactly as long as its session
        if (Test-Path -LiteralPath $marker) { $ended = $true }
        if ($ended) { $delay = $Backoff; Say $(if ($restarted -like 'watchdog*') { "session $round was restarted by the watchdog" } else { "session $round finished its item" }) } else { Say "session $round exited by itself (exit $code)" }
        Say "next session in $delay s (Ctrl-C or the stop file $StopFile to stop)"
        Start-Sleep -Seconds $delay
        if (-not $ended) { $delay = [Math]::Min($delay * 2, $MaxBackoff) }
    }
} finally {
    # Ctrl-C ends this script here: a session still running is stopped with it
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
    Stop-Sidecar
    Say 'stopped'
}
