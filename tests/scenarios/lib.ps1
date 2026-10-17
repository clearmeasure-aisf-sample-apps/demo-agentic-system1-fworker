# Tier 1 harness: a fake GitHub/Octopus, the real gateway and rule scripts on test ports, and a scripted worker that calls the real client.
Set-StrictMode -Version Latest
$script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Every port a suite uses derives from ONE base (a private range of 100 ports per suite slot), so any number of suites can run at once:
#   +0 fake GitHub   +10 gateway API   +11 gateway webhooks   +12/+13 a second gateway   +14 the fake's forwarder in front of a gateway
#   +20 a worker-declared QC port (never listened on)   +29 a port nothing listens on
#   +30 a loopback public-URL literal (never listened on)   +40..+89 stub applications of the QC worker scenarios (range 40-59, clash 60-69, flaky 70-79, never 80-89)
# The base comes from TEST_PORT_BASE (run.ps1 sets it from the suite slot); TEST_FAKE_PORT and TEST_API_PORT still override the two main ports.
function Set-TestPorts([int]$Base) {
    $script:PortBase = $Base
    $script:FakePort = $(if ($env:TEST_FAKE_PORT) { [int]$env:TEST_FAKE_PORT } else { $Base }); $script:ApiPort = $(if ($env:TEST_API_PORT) { [int]$env:TEST_API_PORT } else { $Base + 10 }); $script:HookPort = $script:ApiPort + 1
    $script:ReportPort = $Base + 20; $script:DeadPort = $Base + 29; $script:PublicPort = $Base + 30; $script:ProxyPort = $Base + 26   # not 14: qc-pool.ps1 starts a gateway there
}
Set-TestPorts $(if ($env:TEST_PORT_BASE) { [int]$env:TEST_PORT_BASE } else { 6100 })
$script:VerbCalls = 0; $script:VerbSeconds = 0.0; $script:ClientCrashes = 0
$script:Procs = @()
$script:Failures = New-Object System.Collections.ArrayList
$L2 = @('factory worker', 'Auto Merge')
$script:Checks = 0

function Start-TestEnv([hashtable]$Config = @{}) {
    $work = Join-Path ([IO.Path]::GetTempPath()) "factory-worker-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $script:Work = $work
    $cfg = Get-Content -Raw (Join-Path $script:Root 'config/instance.json') | ConvertFrom-Json -AsHashtable
    $cfg.octopus.url = "http://127.0.0.1:$($script:FakePort)/octopus"
    $t = $cfg.timing
    $t.mergeabilityWaitSeconds = 3; $t.mergeabilityPollSeconds = 1; $t.preMergeChecksWaitSeconds = 12; $t.preMergeChecksPollSeconds = 1
    $t.docsOnlyLegacyBefore = '2020-01-01T00:00:00Z'   # every item and state of a test is new; the legacy scenarios date theirs before it
    $t.updatedHeadWaitSeconds = 10; $t.sweepSeenCount = 1; $t.docsOnlyReleaseGraceSeconds = 4; $t.releaseCandidateTimeoutMinutes = 1; $t.masterGreenTimeoutMinutes = 2
    $t.masterDefectCheckMinutes = 0.05   # (cirule.ps1: a master defect is looked at again every 3 s, not every 5 minutes)
    # one item per session (plant.oneItemPerSession) is on in the source defaults; the suites let one scripted session take many items, so it is off here
    # unless a suite sets it. The scenarios of the rule turn it on for their own gateway (FACTORY_ONE_ITEM_PER_SESSION, owner.ps1).
    $cfg.plant = @{ oneItemPerSession = $false }
    # work intake (issue 104) is off in the source defaults (an environment turns it on); the suites create their items in the columns they need, so it is off here unless a
    # scenario switches it on (FACTORY_INTAKE, owner.ps1)
    $cfg.intake = @{ enabled = $false }
    foreach ($k in $Config.Keys) { $cfg[$k] = $Config[$k] }
    # __FAKE_URL__ in a suite's configuration is the fake's address (the fake ARM of the runtime suite)
    $cfgPath = Join-Path $work 'instance.test.json'; ($cfg | ConvertTo-Json -Depth 12).Replace('__FAKE_URL__', "http://127.0.0.1:$($script:FakePort)") | Set-Content $cfgPath
    $fakeDll = Join-Path $script:Root 'tests/FakeGitHub/bin/Release/net10.0/FakeGitHub.dll'
    $gwDll = Join-Path $script:Root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'
    foreach ($d in $fakeDll, $gwDll) { if (-not (Test-Path $d)) { throw "build first: $d is missing" } }
    $env:FAKE_PORT = "$($script:FakePort)"; $env:FACTORY_CONFIG = $cfgPath   # (the fake reads docsOnlyPaths from it)
    $env:FAKE_PROXY_PORT = "$($script:ProxyPort)"   # the fake's TCP forwarder in front of a gateway (leader.ps1): idle until a scenario names a backend
    $script:Procs += Start-Process dotnet -ArgumentList $fakeDll -PassThru -RedirectStandardOutput (Join-Path $work 'fake.out') -RedirectStandardError (Join-Path $work 'fake.err')
    $env:GITHUB_API_URL = "http://127.0.0.1:$($script:FakePort)"; $env:GH_TOKEN = 'fake-operator'; $env:OCTOPUS_API_KEY = 'fake'
    $env:FACTORY_CONFIG = $cfgPath; $env:FACTORY_STATE_DIR = Join-Path $work 'state'; $(if ($env:TEST_REAL_APPS) { Remove-Item Env:FACTORY_FAKE_APPS -ErrorAction SilentlyContinue } else { $env:FACTORY_FAKE_APPS = '1' })
    # a stream client does not accept offers by itself in the suites (the scenarios accept, or let an offer lapse); lease.ps1 switches it on
    $env:FACTORY_AUTO_ACCEPT = '0'
    $env:FACTORY_PLUGIN_SCRIPTS = Join-Path $script:Root 'plugin/scripts'; $env:FACTORY_DEV_TOKEN = 'test-token'; $env:FACTORY_WEBHOOK_SECRET = ('x' * 40)
    $env:FACTORY_API_PORT = "$($script:ApiPort)"; $env:FACTORY_WEBHOOK_PORT = "$($script:HookPort)"; $env:FACTORY_SWEEP_SECONDS = $(if ($env:TEST_SWEEP_SECONDS) { $env:TEST_SWEEP_SECONDS } else { '2' })
    $script:Procs += Start-Process dotnet -ArgumentList $gwDll -PassThru -RedirectStandardOutput (Join-Path $work 'gateway.out') -RedirectStandardError (Join-Path $work 'gateway.err')
    $env:FACTORY_URL = "http://127.0.0.1:$($script:ApiPort)"; $env:FACTORY_TOKEN = 'test-token'
    Wait-Until -Seconds 30 -Message 'fake and gateway to answer' { try { (Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/_fake/state" -TimeoutSec 2) -and (Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/ready" -TimeoutSec 2) } catch { $false } } | Out-Null
}

function Assert-NoServerErrors([string]$Suite) {
    # Invariant: the gateway must never log a sweep error or an internal error, whatever the scenario did.
    $bad = @()
    # every gateway log of the suite, including those of a restarted gateway (gateway-xxxx.out, gateway-restarted.err)
    foreach ($f in @(Get-ChildItem -Path $script:Work -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'gateway*.out' -or $_.Name -like 'gateway*.err' })) { $bad += @(Select-String -Path $f.FullName -Pattern 'sweepError|internal error|"sweep":"error"|"sweep":"failed"' | ForEach-Object { $_.Line.Substring(0, [Math]::Min(220, $_.Line.Length)) }) }
    $script:Current = "$Suite invariants"
    Check 'no sweep or internal errors in the gateway log' ($bad.Count -eq 0) ($bad | Select-Object -First 3 | Out-String)
}
# Stops the suite's gateway and starts it again with the same environment: a new process, so a new epoch and empty memory. Its logs go to
# gateway-xxxx.out and gateway-restarted.err, which Assert-NoServerErrors reads as well.
function Get-GatewayBase { "http://127.0.0.1:$($script:ApiPort)" }
# -Graceful: SIGTERM, as the platform stops a container (the gateway writes its plant snapshot then), and up to 30 s for the process to end;
# without it the process is killed outright, as an out-of-memory kill would.
function Restart-Gateway([switch]$Graceful) {
    if ($Graceful -and -not $IsWindows) {
        $gp = $script:Procs[1]; & kill -s TERM $gp.Id 2>$null
        if (-not $gp.WaitForExit(30000)) { try { Stop-Process -Id $gp.Id -Force } catch { } }
    }
    else { try { Stop-Process -Id $script:Procs[1].Id -Force } catch { } }
    Start-Sleep -Seconds 1
    $gwDll = Join-Path $script:Root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'
    $script:Procs[1] = Start-Process dotnet -ArgumentList $gwDll -PassThru -RedirectStandardOutput (Join-Path $script:Work "gateway-$([guid]::NewGuid().ToString('N').Substring(0,4)).out") -RedirectStandardError (Join-Path $script:Work "gateway-restarted.err")
    [void](Wait-Until -Seconds 30 { try { [bool](Invoke-RestMethod "$(Get-GatewayBase)/ready" -TimeoutSec 2) } catch { $false } })
}
function Stop-TestEnv { Stop-ClientHost; foreach ($p in $script:Procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }; $script:Procs = @() }

function Wait-Until([scriptblock]$Cond, [int]$Seconds = 30, [string]$Message = 'condition') {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 400 }
    return $false
}

function Fake([string]$What, $Body = $null) {
    $u = "http://127.0.0.1:$($script:FakePort)/_fake/$What"
    if ($null -eq $Body) { Invoke-RestMethod $u } else { Invoke-RestMethod $u -Method POST -Body ($Body | ConvertTo-Json -Depth 8) -ContentType 'application/json' }
}
function Get-FakeState { Fake 'state' }
function Get-FakeIssue([int]$n) { (Get-FakeState).issues | Where-Object { $_.number -eq $n } }
function Get-FakePr([int]$n) { (Get-FakeState).prs | Where-Object { $_.number -eq $n } }

# Calls the real client. Returns the parsed JSON with .exit set.
# With $script:UseClientHost (a suite sets it in run.ps1; TEST_CLIENT_HOST=0/1 overrides) the client script runs in ONE long-lived pwsh
# (plugin/scripts/runner-host.ps1: a new runspace per call, this process's environment and directory passed with each call) in place of a new pwsh
# per call. Only F does this, and never for the verbs in $script:RealProcessVerbs: the long-running ones and everything a scenario starts itself
# (subscribe streams, spawned workers, worker-token, calls with their own environment) stay real processes.
$script:UseClientHost = $false; $script:ClientHost = $null; $script:ClientHostCalls = 0
$script:RealProcessVerbs = @('subscribe', 'wait-event', 'plugin-sync', 'worker-token')
# Starts a runner host for one script; Invoke-RunnerHost sends it one call and returns @{ code; out; err }, or $null when it ended or did not answer.
function Start-RunnerHost([string]$Target) {
    $psi = [Diagnostics.ProcessStartInfo]::new('pwsh'); $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $mark = "fwt-$([guid]::NewGuid().ToString('N'))"
    foreach ($a in '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:Root 'plugin/scripts/runner-host.ps1'), $Target, $mark) { $psi.ArgumentList.Add($a) }
    $h = @{ proc = [Diagnostics.Process]::Start($psi); mark = "$mark " }
    if ($null -eq (Read-RunnerHostFrame $h 60)) { Stop-RunnerHost $h; throw "the runner host for $Target did not start" }
    return $h
}
function Stop-RunnerHost($h) { if ($h) { try { $h.proc.StandardInput.Close() } catch { }; try { if (-not $h.proc.WaitForExit(2000)) { $h.proc.Kill($true) } } catch { } } }
# The next response line of the host (lines without its mark are skipped); $null when it ended or did not answer in time.
function Read-RunnerHostFrame($h, [int]$Seconds) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        $t = $h.proc.StandardOutput.ReadLineAsync()
        if (-not $t.Wait([Math]::Max(1, [int]($end - [DateTime]::UtcNow).TotalMilliseconds))) { return $null }
        $line = $t.Result; if ($null -eq $line) { return $null }
        if ($line.StartsWith($h.mark, [StringComparison]::Ordinal)) { return $line.Substring($h.mark.Length) }
    }
}
function Invoke-RunnerHost($h, [string[]]$CallArgs, [string]$Stdin = '', $CallEnv = $null, $Cwd = $null, [int]$Seconds = 240) {
    $id = [guid]::NewGuid().ToString('N')
    $h.proc.StandardInput.WriteLine((@{ id = $id; args = @($CallArgs); stdin = $Stdin; env = $CallEnv; cwd = $Cwd } | ConvertTo-Json -Compress -Depth 3)); $h.proc.StandardInput.Flush()
    $frame = Read-RunnerHostFrame $h $Seconds
    if ($null -eq $frame) { return $null }
    $r = $frame | ConvertFrom-Json -AsHashtable -DateKind String
    if ("$($r.id)" -cne $id) { return $null }   # not the answer to this call
    return $r
}
function Get-ProcessEnv { $e = @{}; $all = [Environment]::GetEnvironmentVariables(); foreach ($k in $all.Keys) { $e["$k"] = "$($all[$k])" }; return $e }
function Stop-ClientHost { $h = $script:ClientHost; $script:ClientHost = $null; Stop-RunnerHost $h }
function Invoke-ClientHost([string[]]$FactoryArgs) {
    if (-not $script:ClientHost -or $script:ClientHost.proc.HasExited) { $script:ClientHost = Start-RunnerHost (Join-Path $script:Root 'plugin/scripts/factory.ps1') }
    $r = Invoke-RunnerHost $script:ClientHost $FactoryArgs '' (Get-ProcessEnv) (Get-Location).ProviderPath
    if ($null -eq $r) {
        $hc = $(try { if ($script:ClientHost.proc.HasExited) { $script:ClientHost.proc.ExitCode } else { 0 } } catch { 0 })
        Stop-ClientHost
        if ($hc -eq 139) { return @{ code = 139; text = '' } }
        return @{ code = 1; text = 'the client host ended or did not answer' }
    }
    $script:ClientHostCalls++
    return @{ code = [int]$r.code; text = ("$($r.out)$($r.err)" -replace "`r`n", "`n").TrimEnd("`n") }
}
function F([string]$Holder, [string[]]$FactoryArgs) {
    $env:FACTORY_HOLDER = $Holder
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hosted = $script:UseClientHost -and $FactoryArgs.Count -gt 0 -and $FactoryArgs[0] -notin $script:RealProcessVerbs
    if ($env:TEST_CLIENT_HOST -eq '0') { $hosted = $false } elseif ($env:TEST_CLIENT_HOST -eq '1' -and $FactoryArgs.Count -gt 0 -and $FactoryArgs[0] -notin $script:RealProcessVerbs) { $hosted = $true }
    if ($hosted) { $hc = Invoke-ClientHost $FactoryArgs; $text = $hc.text; $code = $hc.code }
    else {
        $out = & pwsh -NoProfile -File (Join-Path $script:Root 'plugin/scripts/factory.ps1') @FactoryArgs 2>&1
        $code = $LASTEXITCODE
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
    }
    $script:VerbCalls++; $script:VerbSeconds += $sw.Elapsed.TotalSeconds
    # pwsh exit 139 is a segmentation fault of the client process itself (seen under load): reported as that, so it is not read as a product answer
    if ($code -eq 139) {
        $script:ClientCrashes++
        Write-Host "    CRASH client call '$($FactoryArgs[0])' ended with pwsh exit 139 (segmentation fault): machine load or the runtime, not a product answer"
        return @{ ok = $false; exit = 139; code = 'client-crashed'; reason = 'PWSH EXIT 139 (SEGMENTATION FAULT) OF THE CLIENT PROCESS: machine load or the runtime, not a product answer; run the scenario again'; raw = $text }
    }
    try { $j = $text | ConvertFrom-Json -AsHashtable; if (-not $j.ContainsKey('exit')) { $j.exit = $code }; return $j } catch { return @{ ok = $false; exit = $code; raw = $text } }
}
function Pv($h, [string]$k) { if ($h -is [System.Collections.IDictionary] -and $h.Contains($k)) { return $h[$k] }; return $null }
# A file that starts like an MP4 (an ftyp box), of the given length.
function New-TestMp4([string]$Name, [int]$Size) { $p = Join-Path $script:Work $Name; $b = [byte[]]::new($Size); [byte[]]$h = [byte[]](0, 0, 0, 24) + [Text.Encoding]::ASCII.GetBytes('ftypisom'); [Array]::Copy($h, $b, $h.Length); [IO.File]::WriteAllBytes($p, $b); return $p }
function TmpFile([string]$Name, [string]$Text) { $p = Join-Path $script:Work $Name; Set-Content -Path $p -Value $Text -NoNewline; return $p }

function Check([string]$Name, [bool]$Ok, $Detail = '') {
    $script:Checks++
    if ($Ok) { Write-Host "    ok    $Name" } else { Write-Host "    FAIL  $Name  $Detail"; [void]$script:Failures.Add("$($script:Current): $Name $Detail") }
}
# A check that is known to fail now and then for a cause not yet found (docs/HANDOFF.md names it under -Issue). It runs and reports like any
# check; when it fails it prints QUARANTINED (failed) with the detail and is counted in a total of its own (the suite summary and run-all show it),
# and it does not fail the suite. When it passes it prints as any check. Use it only for a check with an open backlog entry, and remove it with the cause.
$script:Quarantined = New-Object System.Collections.ArrayList
function CheckQuarantined([string]$Name, [bool]$Ok, $Detail = '', [Parameter(Mandatory)][string]$Issue) {
    $script:Checks++
    if ($Ok) { Write-Host "    ok    $Name" } else { Write-Host "    QUARANTINED (failed)  $Name  $Detail  [$Issue]"; [void]$script:Quarantined.Add("$($script:Current): $Name $Detail [$Issue]") }
}
function CheckExit($Name, $r, [int]$Exit, [string]$Code = '') {
    $got = if ($r.ContainsKey('code')) { "$($r.code)" } else { '' }; $why = if ($r.ContainsKey('reason')) { "$($r.reason)" } else { '' }
    $ok = ($r.exit -eq $Exit) -and ((-not $Code) -or $got -eq $Code)
    Check $Name $ok "(wanted exit $Exit $Code, got exit $($r.exit) $got $why)"
}

function New-Item-Fake([string]$Title, [string]$Body, [string[]]$Labels, [string]$Column = 'Technical Design') { (Fake 'issue' @{ title = $Title; body = $Body; labels = $Labels; column = $Column }).number }

# The scripted worker: runs one column the way the skill does, with canned judgement.
function Do-TechnicalDesign([int]$n, [string]$Holder = 'w1', [bool]$DocsOnly = $true) {
    $r = F $Holder @('claim-item', '--item', $n, '--column', 'Technical Design'); CheckExit "TD $n claim" $r 0
    $sec = "## Technical Design`n`n$(if ($DocsOnly) { '<!-- aisf:docs-only -->' })`n- change as described in the item.`n"
    $r = F $Holder @('append-body', '--item', $n, '--column', 'Technical Design', '--content-file', (TmpFile "td$n.md" $sec)); CheckExit "TD $n append" $r 0
    $r = F $Holder @('record-review', '--item', $n, '--column', 'Technical Design', '--role', 'reviewer', '--text-file', (TmpFile "rv-td$n.md" "Section present and complete.`nREVIEW: COMPLETE")); CheckExit "TD $n record-review" $r 0
    $ref = $r.review_ref
    $r = F $Holder @('complete', '--item', $n, '--column', 'Technical Design', '--review-ref', $ref, '--comment', 'REVIEW: COMPLETE - design done'); CheckExit "TD $n complete" $r 0
    if ($r.exit -ne 0) { $iss = Get-FakeIssue $n; Write-Host "    DEBUG item $n comments:"; foreach ($c in $iss.comments) { Write-Host ("      #{0}: {1}" -f $c.id, (($c.body -replace '\s+', ' ')).Substring(0, [Math]::Min(2600, ($c.body -replace "\s+", " ").Length))) } }
}
function Do-Development([int]$n, $Files = @('docs/trial.md'), [string]$Holder = 'w1', [string]$Profile = 'green', [double]$Delay = 0) {
    $r = F $Holder @('claim-item', '--item', $n, '--column', 'Development'); CheckExit "DEV $n claim" $r 0
    Fake 'push-branch' @{ branch = "factory-worker/$n-development"; files = $Files; profile = $Profile; delaySeconds = $Delay } | Out-Null
    $r = F $Holder @('open-pr', '--item', $n, '--head', "factory-worker/$n-development", '--title', "Trial $n", '--body-file', (TmpFile "pr$n.md" 'change')); CheckExit "DEV $n open-pr" $r 0
    return $r.pullRequest.number
}
function Do-DevComplete([int]$n, [string]$Holder = 'w1') {
    $r = F $Holder @('record-review', '--item', $n, '--column', 'Development', '--role', 'reviewer', '--text-file', (TmpFile "rv-dev$n.md" "Diff matches the plan.`nREVIEW: COMPLETE"))
    return F $Holder @('complete', '--item', $n, '--column', 'Development', '--review-ref', $r.review_ref, '--comment', 'PR open, CI green. REVIEW: COMPLETE')
}
function Do-Verdict([int]$n, [int]$pr, [string]$Holder = 'w1', [bool]$Passed = $true) {
    $r = F $Holder @('claim-item', '--item', $n, '--column', 'Functional Testing'); CheckExit "FT $n claim" $r 0
    $rv = F $Holder @('record-review', '--item', $n, '--column', 'Functional Testing', '--role', 'reviewer', '--text-file', (TmpFile "rv-ft$n.md" "Criteria exercised.`nREVIEW: COMPLETE"))
    $args2 = @('validation-verdict', '--item', $n, '--passed', "$($Passed.ToString().ToLower())", '--summary-file', (TmpFile "vs$n.md" 'Both criteria met.'), '--pr', $pr)
    if ($Passed) { $args2 += @('--review-ref', $rv.review_ref) }
    return F $Holder $args2
}

# Tier: a scenario whose name ends in " [full]" belongs to the full tier only (it waits in real time, or repeats a rule another scenario already proves, or has a long setup);
# every other scenario is in the fast tier (the smoke check of its area). run.ps1 -Tier fast skips the [full] ones and counts them; the tag is part of the name, so -Only still matches.
function Get-ScenarioTier([string]$Name) { if ($Name -match '\s\[full\]\s*$') { 'full' } else { 'fast' } }
$script:ScenarioStats = New-Object System.Collections.ArrayList
$script:SuiteName = ''
function Run-Scenario([string]$Name, [scriptblock]$Body) {
    $script:Current = $Name; Write-Host "  $Name"
    $tmStart = [Diagnostics.Stopwatch]::StartNew(); $tmChecks = $script:Checks; $tmFailed = $script:Failures.Count
    try { Fake 'reset' @{} | Out-Null; & $Body } catch { Check 'no unexpected exception' $false $_.Exception.Message }
    $tmCount = $script:Checks - $tmChecks
    Write-Host ("    scenario took {0:N1}s, {1} checks" -f $tmStart.Elapsed.TotalSeconds, $tmCount)
    [void]$script:ScenarioStats.Add([ordered]@{ suite = $script:SuiteName; name = $Name; tier = (Get-ScenarioTier $Name); seconds = [math]::Round($tmStart.Elapsed.TotalSeconds, 1); checks = $tmCount; failed = ($script:Failures.Count - $tmFailed) })
}

function Insp-Text([string]$Verdict, [string]$Notes = 'Read the diff against the item.') { "$Notes`nINSPECTOR: $Verdict" }
function Gh-As([string]$Token, [string]$Path, $Body) {
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/$Path" -Method POST -Headers @{ Authorization = "Bearer $Token" } -Body ($Body | ConvertTo-Json -Depth 5) -ContentType 'application/json'
}
function Get-Head([int]$pr) { (Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/pulls/$pr").head.sha }
function To-Verdict([int]$n, [int]$Pr, $Files = @('docs/a.md'), [bool]$DocsOnly = $true, [string]$Body = 'x', [switch]$HoldMerge) {
    # An item taken to a recorded PASS verdict, ready for the approval step. Under merge policy auto the gateway merges that PASS at once:
    # -HoldMerge lets the checks of the head run again for an hour first, so the PASS stays recorded and unmerged for the scenario.
    $n2 = New-Item-Fake 'Approval trial' $Body $L2
    Do-TechnicalDesign $n2 'w1' $DocsOnly
    $pr2 = Do-Development $n2 $Files
    Do-DevComplete $n2 | Out-Null
    if ($HoldMerge) { Fake 'pr' @{ number = $pr2; delaySeconds = 3600 } | Out-Null }
    $v = Do-Verdict $n2 $pr2
    return @{ n = $n2; pr = $pr2; verdict = $v }
}

# Edits the item's state comment the way a lease end would (the fake keeps it as a comment): $Edit gets the state hashtable.
function Set-ItemState([int]$Item, [scriptblock]$Edit) {
    $sc = @((Get-FakeIssue $Item).comments | Where-Object { $_.body -like '<!-- factory-state:*' })[0]
    $mm = [regex]::Match($sc.body, '(?s)```json\s*(.*?)\s*```'); $st = $mm.Groups[1].Value | ConvertFrom-Json -AsHashtable
    & $Edit $st
    $body = $sc.body.Substring(0, $mm.Groups[1].Index) + ($st | ConvertTo-Json -Depth 12 -Compress) + $sc.body.Substring($mm.Groups[1].Index + $mm.Groups[1].Length)
    [void](Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/comments/$($sc.id)" -Method PATCH -Body (@{ body = $body } | ConvertTo-Json) -ContentType 'application/json')
}
function Get-ItemState([int]$Item) {
    $sc = @((Get-FakeIssue $Item).comments | Where-Object { $_.body -like '<!-- factory-state:*' })[0]
    [regex]::Match($sc.body, '(?s)```json\s*(.*?)\s*```').Groups[1].Value | ConvertFrom-Json -AsHashtable
}
function Expire-Claim([int]$Item, [string]$TakenBack = '') {
    Set-ItemState $Item { param($st) $st.claim.lease_until = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o'); if ($TakenBack) { $st.claim.taken_back = $TakenBack } }
}
