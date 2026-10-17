#!/usr/bin/env pwsh
# Tier 1, all suites in parallel: one pwsh process per suite (run.ps1 -Suite <name>), each with its own ports, HOME and TMPDIR, so none can touch another.
# usage: pwsh tests/scenarios/run-all.ps1 [-Tier fast|full] [-Parallel 4] [-Suites a,b] [-Only <scenario substring>] [-NoBuild] [-KeepWork] [-LogDir <dir>] [-MinAvailableMb 1500] [-MinFreeDiskMb 2048] [-Force]
#   Start guards (guard.ps1): refuses with exit 4 when another run-all.ps1 or run.ps1 is active on this machine, or when the temp filesystem has less than
#   -MinFreeDiskMb free; with less than -MinAvailableMb of memory at the start it runs one suite at a time, and during the run no further suite is started
#   while memory or disk is below its floor. -Force starts anyway.
#   -Tier fast (default)  the curated subset: every scenario not tagged " [full]" in its name; the end of the run says how many scenarios and checks were left to the full tier
#   -Tier full            everything
#   Longest suite first, from suite-times.json (last known seconds per tier; rewritten at the end of every run). One line per suite as it finishes, a combined summary, exit 1 if anything failed.
#   A full run (no -Only) also rewrites scenario-stats.json (seconds and checks per scenario), which is where the "checks skipped" figure of a fast run comes from.
param([ValidateSet('fast', 'full')][string] $Tier = 'fast', [int] $Parallel = 4, [string[]] $Suites = @(), [string] $Only = '', [switch] $NoBuild, [switch] $KeepWork, [string] $LogDir = '', [int] $MinAvailableMb = 1500, [int] $MinFreeDiskMb = 2048, [switch] $Force)
$Suites = @($Suites | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # pwsh -File passes "a,b" as one string
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'guard.ps1')
if (Assert-TestRunMayStart 'run-all.ps1' ([bool]$Force) $MinFreeDiskMb $MinAvailableMb) { $Parallel = 1 }
$env:FACTORY_TEST_RUN_HELD = "$PID"
$root = Split-Path -Parent (Split-Path -Parent $here)
$timesFile = Join-Path $here 'suite-times.json'; $statsFile = Join-Path $here 'scenario-stats.json'
$baseTmp = [IO.Path]::GetTempPath()
if (-not $LogDir) { $LogDir = Join-Path $baseTmp "factory-run-all-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$wall = [Diagnostics.Stopwatch]::StartNew()

if (-not $NoBuild) {
    foreach ($proj in 'tests/FakeGitHub', 'gateway') {
        Push-Location (Join-Path $root $proj)
        try { $out = & dotnet build -c Release --no-restore -nodeReuse:false -p:UseSharedCompilation=false -v q 2>&1; if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }; throw "build of $proj failed" } } finally { Pop-Location }
        Write-Host "built $proj"
    }
}

$scen = @(& pwsh -NoProfile -File (Join-Path $here 'run.ps1') -ListScenarios | Where-Object { $_ } | ForEach-Object { $f = $_ -split "`t"; [pscustomobject]@{ suite = $f[0]; name = $f[1]; tier = $f[2] } })
$names = @($scen | ForEach-Object { $_.suite } | Select-Object -Unique)
if ($names.Count -eq 0) { throw 'run.ps1 -ListScenarios listed no scenarios' }
$timesAll = @{}; if (Test-Path $timesFile) { $timesAll = Get-Content -Raw $timesFile | ConvertFrom-Json -AsHashtable }
$known = @{}; if ($timesAll.ContainsKey($Tier)) { foreach ($e in $timesAll[$Tier].GetEnumerator()) { $known[$e.Key] = [double]$e.Value } }
$todo = @($names | Where-Object { -not $Suites.Count -or $Suites -contains $_ })
if ($Suites.Count -and $todo.Count -ne $Suites.Count) { throw "unknown suite in -Suites; known: $($names -join ', ')" }
# scenarios this run leaves out: the full-tier ones (only when -Tier fast), and the suites that have nothing left to run are not started at all
$leftOut = @(); if ($Tier -eq 'fast') { $leftOut = @($scen | Where-Object { $_.tier -eq 'full' -and $todo -contains $_.suite -and (-not $Only -or $_.name -match $Only) }) }
if ($Tier -eq 'fast' -and -not $Only) { $todo = @($todo | Where-Object { $sn = $_; @($scen | Where-Object { $_.suite -eq $sn -and $_.tier -eq 'fast' }).Count -gt 0 }) }
# longest first; a suite without a known duration goes first (it could be the long one)
$queue = [System.Collections.Generic.List[string]]::new(); foreach ($n in ($todo | Sort-Object { if ($known.ContainsKey($_)) { -$known[$_] } else { -1e9 } })) { $queue.Add($n) }

function Get-StatKey([string]$Name) { $Name -replace '\s\[full\]\s*$', '' }   # the tier tag is not part of a scenario's identity
function Get-MemAvailableMb { try { [int]((Select-String -Path /proc/meminfo -Pattern '^MemAvailable:\s+(\d+)').Matches[0].Groups[1].Value) / 1024 } catch { 99999 } }
function Stop-Tree([int]$ProcId) {
    foreach ($c in @(& ps -o pid= --ppid $ProcId 2>$null)) { if ("$c".Trim()) { Stop-Tree ([int]"$c".Trim()) } }
    try { Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue } catch { }
}

$running = @{}      # name -> @{ proc; sw; result; log; work }
$results = [ordered]@{}
$minAvail = Get-MemAvailableMb; $startAvail = $minAvail; $peakRunning = 0
Write-Host "run-all: tier $Tier, $($todo.Count) suites, $Parallel at a time, logs in $LogDir, memory available $([int]$startAvail) MB"
try {
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        $avail = Get-MemAvailableMb; if ($avail -lt $minAvail) { $minAvail = $avail }
        # start the next suite while there is a free slot (and memory: a suite is ~0.5 GB)
        while ($queue.Count -gt 0 -and $running.Count -lt $Parallel -and ($running.Count -eq 0 -or ((Get-MemAvailableMb) -ge $MinAvailableMb -and (Get-TempFreeDiskMb) -ge $MinFreeDiskMb))) {
            $name = $queue[0]; $queue.RemoveAt(0)
            $work = Join-Path $LogDir "work-$name"; New-Item -ItemType Directory -Force -Path $work | Out-Null
            $resultFile = Join-Path $LogDir "$name.result.json"; $log = Join-Path $LogDir "$name.log"
            $args2 = @('-NoProfile', '-File', (Join-Path $here 'run.ps1'), '-Suite', $name, '-Tier', $Tier, '-Groups', 1, '-NoBuild', '-ResultFile', $resultFile); if ($Only) { $args2 += @('-Only', $Only) }
            $oldTmp = $env:TMPDIR; $env:TMPDIR = $work; Remove-Item Env:TEST_PORT_BASE -ErrorAction SilentlyContinue
            try { $p = Start-Process pwsh -ArgumentList $args2 -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $LogDir "$name.err") } finally { $env:TMPDIR = $oldTmp }
            $running[$name] = @{ proc = $p; sw = [Diagnostics.Stopwatch]::StartNew(); result = $resultFile; log = $log; work = $work }
            if ($running.Count -gt $peakRunning) { $peakRunning = $running.Count }
        }
        Start-Sleep -Milliseconds 1000
        foreach ($name in @($running.Keys)) {
            $r = $running[$name]
            if (-not $r.proc.HasExited) { continue }
            $secs = [math]::Round($r.sw.Elapsed.TotalSeconds, 1)
            $res = if (Test-Path $r.result) { Get-Content -Raw $r.result | ConvertFrom-Json -AsHashtable } else { $null }
            if (-not $res) { $res = [ordered]@{ suite = $name; checks = 0; failed = 1; failures = @("${name}: the suite process ended without a result (exit $($r.proc.ExitCode)); see $($r.log)"); seconds = $secs; verbCalls = 0; verbSeconds = 0; gatewayVerbLines = 0 } }
            $results[$name] = $res; $running.Remove($name)
            $perVerb = if ($res.verbCalls -gt 0) { '{0:N2}s/verb' -f ($res.verbSeconds / $res.verbCalls) } else { '-' }
            Write-Host ("  {0,-4} {1,-18} checks {2,4}  failed {3,2}  {4,6:N0}s  verbs {5,4} ({6})" -f $(if ($res.failed -eq 0) { 'done' } else { 'FAIL' }), $name, $res.checks, $res.failed, $res.seconds, $res.verbCalls, $perVerb)
            if ($res.failed -eq 0 -and -not $KeepWork) { Remove-Item -Recurse -Force -Path $r.work -ErrorAction SilentlyContinue }
        }
    }
} finally {
    foreach ($r in $running.Values) { Stop-Tree $r.proc.Id }   # only what this run started
}
$wall.Stop()

# ---- combined summary ----------------------------------------------------------------------------------------------------
$sumSecs = 0.0; $checks = 0; $failed = 0; $verbs = 0; $verbSecs = 0.0
foreach ($n in $results.Keys) { $x = $results[$n]; $sumSecs += $x.seconds; $checks += $x.checks; $failed += $x.failed; $verbs += $x.verbCalls; $verbSecs += $x.verbSeconds }
Write-Host ""
Write-Host ("{0,-18} {1,5} {2,7} {3,7} {4,8} {5,7} {6,9}" -f 'suite', 'scen.', 'checks', 'failed', 'seconds', 'verbs', 's/verb')
foreach ($n in $names) { if (-not $results.Contains($n)) { continue }; $x = $results[$n]; Write-Host ("{0,-18} {1,5} {2,7} {3,7} {4,8:N0} {5,7} {6,9}" -f $n, @($x.scenarios).Count, $x.checks, $x.failed, $x.seconds, $x.verbCalls, $(if ($x.verbCalls -gt 0) { '{0:N2}' -f ($x.verbSeconds / $x.verbCalls) } else { '-' })) }
Write-Host ("total: {0} checks, {1} failed; wall-clock {2:N0}s, serial-equivalent (sum of suites) {3:N0}s, speed-up {4:N1}x; {5} verb calls, {6:N2}s per call" -f $checks, $failed, $wall.Elapsed.TotalSeconds, $sumSecs, $(if ($wall.Elapsed.TotalSeconds -gt 0) { $sumSecs / $wall.Elapsed.TotalSeconds } else { 0 }), $verbs, $(if ($verbs) { $verbSecs / $verbs } else { 0 }))
# CPU actually used by this run's processes (waited-for children and their descendants: /proc/self/stat cutime+cstime): the share of the wall-clock that other users of the machine cannot distort
$cpuSec = 0.0; try { $st = (Get-Content -Raw /proc/self/stat); $f = ($st.Substring($st.LastIndexOf(')') + 2)) -split ' '; $cpuSec = ([double]$f[13] + [double]$f[14]) / 100.0 } catch { }
Write-Host ("cpu: {0:N0} CPU-seconds in the run's processes = {1:N0}s wall-clock on 4 idle cores at best; machine load average now {2}" -f $cpuSec, ($cpuSec / 4), ((Get-Content /proc/loadavg) -split ' ')[0])
Write-Host ("memory: available {0:N0} MB at start, lowest {1:N0} MB (peak use by the run {2:N0} MB), at most {3} suites at once" -f $startAvail, $minAvail, ($startAvail - $minAvail), $peakRunning)
$crashes = 0; foreach ($n in $results.Keys) { if ($results[$n].Contains('clientCrashes')) { $crashes += [int]$results[$n].clientCrashes } }
if ($crashes -gt 0) { Write-Host "client crashes: $crashes client calls ended with pwsh exit 139 (segmentation fault): machine load or the runtime, not a product answer; run the failed scenarios again on a quiet machine before reading them as defects" }
$quar = @(); foreach ($n in $results.Keys) { if ($results[$n].Contains('quarantined')) { foreach ($f in @($results[$n].quarantined | Where-Object { $_ })) { $quar += "[$n] $f" } } }
Write-Host "quarantined failures: $($quar.Count) (checks with an open backlog entry that failed; reported, not counted as failed)"; $quar | ForEach-Object { Write-Host "  $_" }
if ($failed -gt 0) { Write-Host ""; Write-Host 'FAILURES:'; foreach ($n in $results.Keys) { foreach ($f in @($results[$n].failures)) { Write-Host "  [$n] $f" } } }

$allRun = @(); foreach ($n in $results.Keys) { $allRun += @($results[$n].scenarios) }
if ($Tier -eq 'fast') {
    $stats = @{}; if (Test-Path $statsFile) { $stats = Get-Content -Raw $statsFile | ConvertFrom-Json -AsHashtable }
    $skipChecks = 0; $noStat = 0; foreach ($sc in $leftOut) { if ($stats.ContainsKey($sc.suite) -and $stats[$sc.suite].ContainsKey((Get-StatKey $sc.name))) { $skipChecks += [int]$stats[$sc.suite][(Get-StatKey $sc.name)].checks } else { $noStat++ } }
    Write-Host ("skipped as full-tier: {0} scenarios, {1} checks (from the last full run{2}); run -Tier full for them" -f $leftOut.Count, $skipChecks, $(if ($noStat) { "; $noStat have no recorded count yet" } else { '' }))
}
Write-Host "slowest scenarios:"; foreach ($sc in ($allRun | Sort-Object { -[double]$_.seconds } | Select-Object -First 8)) { Write-Host ("  {0,6:N1}s {1,4} checks  {2}: {3}" -f $sc.seconds, $sc.checks, $sc.suite, $sc.name) }

# ---- remember the durations (clean suites only, a failed or cut-short one says nothing about its length) ----------------------------
if (-not $Only) {
    $mine = @{}; if ($timesAll.ContainsKey($Tier)) { foreach ($e in $timesAll[$Tier].GetEnumerator()) { $mine[$e.Key] = $e.Value } }
    foreach ($n in $results.Keys) { if ($results[$n].failed -eq 0) { $mine[$n] = [math]::Round($results[$n].seconds, 0) } }
    $ordered = [ordered]@{}; foreach ($n in $names) { if ($mine.ContainsKey($n)) { $ordered[$n] = $mine[$n] } }
    $out = [ordered]@{}; foreach ($t in 'fast', 'full') { if ($t -eq $Tier) { $out[$t] = $ordered } elseif ($timesAll.ContainsKey($t)) { $out[$t] = $timesAll[$t] } }
    $out["wall-$Tier"] = [math]::Round($wall.Elapsed.TotalSeconds, 0)
    foreach ($t in 'fast', 'full') { $k2 = "wall-$t"; if ($t -ne $Tier -and $timesAll.ContainsKey($k2)) { $out[$k2] = $timesAll[$k2] } }
    ($out | ConvertTo-Json -Depth 4) | Set-Content -Path $timesFile
}
if ($Tier -eq 'full' -and -not $Only) {
    $stats = @{}; if (Test-Path $statsFile) { $stats = Get-Content -Raw $statsFile | ConvertFrom-Json -AsHashtable }
    foreach ($sc in $allRun) { if ($sc.failed -eq 0) { if (-not $stats.ContainsKey($sc.suite)) { $stats[$sc.suite] = @{} }; $stats[$sc.suite][(Get-StatKey $sc.name)] = @{ tier = $sc.tier; seconds = $sc.seconds; checks = $sc.checks } } }
    ($stats | ConvertTo-Json -Depth 4) | Set-Content -Path $statsFile
}
exit ([int]($failed -gt 0))
