# The private build of one worktree, on the session's own machine: factory.ps1 private-build --item N --worktree <path> [--dotnet <path>] [--log <file>]
# [--slot-wait-minutes M] [--timeout-minutes M].
# A session runs it as ONE command in the background and reads the answer when it ends: nothing of it needs a pipe, a loop or a shell variable.
#   1. the .NET SDK: --dotnet <path>, else ensure-tools.ps1 dotnet --repo <worktree> (installs it on demand), before the slot is taken: an install
#      takes minutes and must not hold the host's slot
#   2. the host's build slot (POST /api/v1/build-slot, gateway/Hosts.cs, docs/design/plant-manager.md 4a). While the host's slots are held it asks
#      again after retryAfterSeconds, for --slot-wait-minutes (30) at most (the session runs this in the background, so the wait costs it nothing);
#      a slot still held then is exit 21 build-slot-busy with the holders, and nothing is built. A gateway that keeps no slots (not in owner mode)
#      builds without one.
#   3. `. ./build.ps1 ; Build` in a pwsh of its own, in the worktree, with DATABASE_ENGINE=SQLite, the folder of that dotnet first on PATH (and
#      DOTNET_ROOT when that folder is a real SDK root, one with host/fxr, not a shim), and no credential of this session in its environment: the
#      build runs the pull request's code. All it prints goes to <work>/build-N.log (or --log) while it runs. Every 10 minutes the slot and the
#      item's lease are renewed; after --timeout-minutes (90) the build is stopped.
#   4. the slot is given back in finally, whatever happened
#   5. the answer: ok, failed (the failed tests and the compile errors the log names, at most 50), log, exitCode, seconds, head (the commit of the
#      worktree), dirty, and for a failed build the last 40 lines of the log (tail). A passing build of a clean worktree on the item's own branch
#      is recorded for the push gate where the gateway has that verb (private-build --attest SHA; attested says whether it was).
# Exit 0 passed, 2 usage, 10 build-failed or build-timeout, 20 or 30 when the SDK could not be had, 21 build-slot-busy.

# One POST to the gateway with the call's credential; the answer as a hashtable that always has ok, code and exit.
function Invoke-BuildCall($Cfg, [string]$Token, [string]$Path, $Body, [int]$TimeoutSec = 30) {
    try {
        $resp = Invoke-WebRequest -Uri "$($Cfg.url)$Path" -Method POST -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ Authorization = "Bearer $Token" } -SkipHttpErrorCheck -TimeoutSec $TimeoutSec
    } catch { return @{ ok = $false; code = 'gateway-unreachable'; reason = $_.Exception.Message; retryAfterSeconds = 15; exit = 20 } }
    $j = $null; try { $j = $resp.Content | ConvertFrom-Json -AsHashtable } catch { }
    if ($j -isnot [System.Collections.IDictionary]) { return @{ ok = $false; code = 'gateway-error'; reason = "HTTP $([int]$resp.StatusCode)"; exit = $(if ([int]$resp.StatusCode -in 401, 403) { 30 } else { 20 }) } }
    if ($null -eq $j['ok']) { $j.ok = $false }
    if ($null -eq $j['exit']) { $j.exit = $(if ($j.ok) { 0 } else { 20 }) }
    return $j
}

# The failed tests and the compile errors a build log names, in order and each once: dotnet test prints "  Failed <test> [12 ms]", MSBuild prints
# "<file>(<line>,<col>): error <code>: <text> [<project>]" (twice: where it happened and in the summary). Paths are shown relative to the worktree.
function Get-BuildFailures([string]$Log, [string]$Root) {
    $out = [Collections.Generic.List[string]]::new()
    $prefix = $Root.TrimEnd('/', '\')
    foreach ($l in ($Log -split "`r?`n")) {
        $x = $null
        if ($l -match '^\s*Failed\s+(\S.*?)\s+\[[^\]]*\]\s*$') { $x = "test $($Matches[1])" }
        elseif ($l -match '^\s*(.+?\(\d+(?:,\d+)*\)):\s+error\s+([A-Za-z]+\d+)\s*:\s*(.*?)(?:\s+\[[^\]]*\])?\s*$') {
            $where = $Matches[1]; if ($where.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $where = $where.Substring($prefix.Length).TrimStart('/', '\') }
            $x = "${where}: error $($Matches[2]): $($Matches[3])"
        }
        if ($x -and -not $out.Contains($x)) { $out.Add($x); if ($out.Count -ge 50) { break } }
    }
    return , @($out)
}

function Invoke-PrivateBuild($a, $Cfg, [string]$Token, [string]$ScriptsDir) {
    $verb = 'private-build'
    $wt = "$($a.worktree)"
    if (-not $a.ContainsKey('item') -or "$($a.item)" -notmatch '^\d+$' -or -not $wt -or $wt -eq 'True') { Write-Out @{ ok = $false; verb = $verb; code = 'usage'; reason = 'private-build --item N --worktree <path of the item''s worktree> [--dotnet <path of dotnet>] [--log <file>] [--slot-wait-minutes M] [--timeout-minutes M]' } 2 }
    $item = [int]$a.item
    $wt = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($wt)
    if (-not (Test-Path -LiteralPath (Join-Path $wt 'build.ps1') -PathType Leaf)) { Write-Out @{ ok = $false; verb = $verb; item = $item; code = 'no-build-script'; reason = "there is no build.ps1 in $wt : name the root of the item's worktree" } 2 }
    $limit = 90.0; $slotWait = 30.0
    if ($a.ContainsKey('timeout_minutes') -and -not [double]::TryParse("$($a.timeout_minutes)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$limit)) { Write-Out @{ ok = $false; verb = $verb; code = 'usage'; reason = '--timeout-minutes takes a number' } 2 }
    if ($a.ContainsKey('slot_wait_minutes') -and -not [double]::TryParse("$($a.slot_wait_minutes)", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$slotWait)) { Write-Out @{ ok = $false; verb = $verb; code = 'usage'; reason = '--slot-wait-minutes takes a number' } 2 }
    $pwsh = (Get-Process -Id $PID).Path
    # 1. the SDK
    if ($a.ContainsKey('dotnet') -and "$($a.dotnet)" -ne 'True') {
        $dotnet = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("$($a.dotnet)")
        if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) { Write-Out @{ ok = $false; verb = $verb; item = $item; code = 'usage'; reason = "there is no dotnet at $dotnet" } 2 }
    } else {
        $etOut = (& $pwsh -NoProfile -NonInteractive -File (Join-Path $ScriptsDir 'ensure-tools.ps1') dotnet --repo $wt 2>$null) -join "`n"; $etCode = $LASTEXITCODE
        $et = $null; try { $et = $etOut | ConvertFrom-Json -AsHashtable } catch { }
        if (-not $et -or -not $et.ok -or -not $et.dotnet) {
            Write-Out @{ ok = $false; verb = $verb; item = $item; code = $(if ($et -and $et.code) { "$($et.code)" } else { 'dotnet-unavailable' }); reason = "ensure-tools.ps1 could not provide the .NET SDK: $(if ($et -and $et.reason) { $et.reason } else { $etOut })" } $(if ($etCode -in 20, 30) { $etCode } else { 20 })
        }
        $dotnet = "$($et.dotnet)"
    }
    $dotDir = Split-Path -Parent $dotnet
    $log = if ($a.ContainsKey('log') -and "$($a.log)" -ne 'True') { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("$($a.log)") } else { Join-Path (Get-FwWorkDir) "build-$item.log" }
    # 2. the slot: asked for again while it is busy, up to --slot-wait-minutes, with the item's lease renewed meanwhile
    $ttl = 2400; $waited = [Diagnostics.Stopwatch]::StartNew(); $renewWait = 10.0
    while ($true) {
        $g = Invoke-BuildCall $Cfg $Token '/api/v1/build-slot' @{ action = 'acquire'; ttlSeconds = $ttl; item = $item }
        if ($g.ok -eq $true -or "$($g.code)" -ne 'build-slot-busy') { break }
        $pause = [Math]::Max(5, [int]"0$($g.retryAfterSeconds)")
        if ($waited.Elapsed.TotalSeconds + $pause -gt $slotWait * 60) { break }
        if ($waited.Elapsed.TotalMinutes -ge $renewWait) { $renewWait += 10; [void](Invoke-BuildCall $Cfg $Token '/api/v1/verbs/claim-item' @{ item = $item; renew = $true; holder = "$($a.holder)" }) }
        Start-Sleep -Seconds $pause
    }
    $slot = $g.ok -eq $true
    if (-not $slot -and "$($g.code)" -ne 'not-owner-mode') { $g.verb = $verb; $g.item = $item; $g.waitedSeconds = [int]$waited.Elapsed.TotalSeconds; Write-Out $g ([int]$g.exit) }
    # 3. the build
    $sw = [Diagnostics.Stopwatch]::StartNew(); $exitCode = -1; $timedOut = $false
    try {
        [void](Invoke-BuildCall $Cfg $Token '/api/v1/verbs/claim-item' @{ item = $item; renew = $true; holder = "$($a.holder)" })
        $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($x in '-NoProfile', '-NonInteractive', '-Command', '. ./build.ps1 ; Build *>&1') { $psi.ArgumentList.Add($x) }
        $psi.WorkingDirectory = $wt; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        # the build runs the pull request's code: no credential of this session goes into its environment
        foreach ($k in @($psi.Environment.Keys)) { if ($k -like 'FACTORY_*' -or $k -like 'GH_*' -or $k -like 'GITHUB_*' -or $k -like 'ANTHROPIC_*' -or $k -like 'CLAUDE*' -or $k -like 'AWS_*' -or $k -like 'AZURE_*' -or $k -like 'OCTOPUS_*' -or $k -like '*TOKEN*' -or $k -like '*SECRET*' -or $k -like '*PASSWORD*' -or $k -like '*API_KEY*' -or $k -like '*APIKEY*') { [void]$psi.Environment.Remove($k) } }
        $psi.Environment['DATABASE_ENGINE'] = 'SQLite'
        $psi.Environment['PATH'] = $dotDir + [IO.Path]::PathSeparator + $env:PATH
        if (Test-Path -LiteralPath (Join-Path $dotDir 'host/fxr') -PathType Container) { $psi.Environment['DOTNET_ROOT'] = $dotDir }
        $fs = [IO.FileStream]::new($log, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $p = [Diagnostics.Process]::Start($psi)
            $copy = $p.StandardOutput.BaseStream.CopyToAsync($fs)
            $err = $p.StandardError.ReadToEndAsync()
            $renewAt = 10.0
            while (-not $p.WaitForExit(5000)) {
                if ($sw.Elapsed.TotalMinutes -ge $limit) { $timedOut = $true; try { $p.Kill($true) } catch { }; break }
                if ($sw.Elapsed.TotalMinutes -ge $renewAt) {
                    $renewAt += 10
                    if ($slot) { [void](Invoke-BuildCall $Cfg $Token '/api/v1/build-slot' @{ action = 'acquire'; ttlSeconds = $ttl; item = $item }) }
                    [void](Invoke-BuildCall $Cfg $Token '/api/v1/verbs/claim-item' @{ item = $item; renew = $true; holder = "$($a.holder)" })
                }
            }
            $p.WaitForExit()
            [void]$copy.Wait(30000)
            $exitCode = if ($timedOut) { -1 } else { $p.ExitCode }
            $errText = if ($err.Wait(10000)) { $err.Result } else { '' }
            if ($errText) { $b = [Text.UTF8Encoding]::new($false).GetBytes("`n$errText"); $fs.Write($b, 0, $b.Length) }
        } finally { $fs.Dispose() }
    } finally {
        # 4. the slot goes back whatever happened
        if ($slot) { [void](Invoke-BuildCall $Cfg $Token '/api/v1/build-slot' @{ action = 'release'; item = $item }) }
    }
    # 5. the answer
    $text = try { [IO.File]::ReadAllText($log) } catch { '' }
    $failed = Get-BuildFailures $text $wt
    $ok = $exitCode -eq 0 -and -not $timedOut
    $head = try { "$(@(& git -C $wt rev-parse HEAD 2>$null)[0])".Trim() } catch { '' }
    $dirty = try { (@(& git -C $wt status --porcelain 2>$null) -join '').Trim() -ne '' } catch { $false }
    $res = [ordered]@{ ok = $ok; verb = $verb; item = $item; worktree = $wt; log = $log; exitCode = $exitCode; seconds = [int]$sw.Elapsed.TotalSeconds; slotWaitedSeconds = [int]$waited.Elapsed.TotalSeconds - [int]$sw.Elapsed.TotalSeconds; failed = $failed
        head = $head; dirty = $dirty; dotnet = $dotnet; database = 'SQLite'; slot = $(if ($slot) { 'held and given back' } else { 'none: the gateway keeps no build slots' }) }
    if (-not $ok) {
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        $res.tail = @($lines | Select-Object -Last 40 | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) } else { $_ } })
        $res.code = if ($timedOut) { 'build-timeout' } else { 'build-failed' }
        $res.reason = if ($timedOut) { "the build ran longer than $limit min and was stopped" } elseif ($failed.Count -gt 0) { "the build failed: $($failed.Count) failed test(s) or compile error(s) in failed; the whole output is in the file named by log" } else { 'the build failed; the log names no failed test and no compile error: read tail and the file named by log' }
        Write-Out $res 10
    }
    # recorded for the push gate only for the item's own branch (factory-worker/N-...): a build of a master worktree proves nothing about the branch
    $branch = try { "$(@(& git -C $wt rev-parse --abbrev-ref HEAD 2>$null)[0])".Trim() } catch { '' }
    $res.attested = $false
    if ($branch -notmatch "(^|/)$item-") { $res.attestCode = 'not-the-item-branch' }
    elseif ($head -match '^[0-9a-f]{40}$' -and -not $dirty) {
        $at = Invoke-BuildCall $Cfg $Token '/api/v1/verbs/private-build' @{ item = $item; attest = $head; holder = "$($a.holder)" }
        $res.attested = $at.ok -eq $true; if (-not $res.attested) { $res.attestCode = "$($at.code)" }
    }
    Write-Out $res 0
}
