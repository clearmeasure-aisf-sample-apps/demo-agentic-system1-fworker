#!/usr/bin/env pwsh
# Tier 1: runs the scenarios against the fake GitHub.
# usage: pwsh tests/scenarios/run.ps1 [-Only <substring>] [-NoBuild] [-Suite <name>] [-ListSuites] [-ResultFile <json>]
#   no -Suite    every suite, one after the other, in this process (as before)
#   -Suite name  exactly one suite, with its own port slot (see Set-TestPorts in lib.ps1), its own HOME and TMPDIR; run-all.ps1 starts many of these at once
#   -Tier fast   skips the scenarios tagged [full] (lib.ps1 Get-ScenarioTier) and reports how many; the default here is full (everything), run-all.ps1 defaults to fast
#   -ListScenarios  prints suite, scenario and tier, tab separated
#   -Groups n / -Group g  the scenarios of a suite split over n independent children (own fake, gateway, ports, HOME, TMPDIR), balanced by scenario-stats.json (owner: contiguous runs in suite order, as its scenarios build on each other); the suites 'qc', 'messaging' and 'manager' default to 4 groups and 'owner' to 2, -Groups 1 runs one in one process; a child is started with -Group g (0-based); -GroupTimeoutMinutes (default 30) ends and fails groups that are still running
#   -ListSuites  prints the suite names, one per line, in slot order (slot = line number, from 0)
#   Start guards (guard.ps1): refuses with exit 4 when another run.ps1 or run-all.ps1 is active on this machine, or when the temp filesystem has less than
#   -MinFreeDiskMb (default 2048) free; with less than -MinAvailableMb (default 1500) of memory a suite runs in half its groups. -Force starts anyway.
param([string] $Only = '', [switch] $NoBuild, [string] $Suite = '', [switch] $ListSuites, [switch] $ListScenarios, [string] $ResultFile = '', [ValidateSet('full', 'fast')][string] $Tier = 'full', [int] $Groups = 0, [int] $Group = -1, [double] $GroupTimeoutMinutes = 30, [switch] $Force, [int] $MinFreeDiskMb = 2048, [int] $MinAvailableMb = 1500)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'guard.ps1')
$lowMemory = $false
if (-not $ListSuites -and -not $ListScenarios) { $lowMemory = Assert-TestRunMayStart 'run.ps1' ([bool]$Force) $MinFreeDiskMb $MinAvailableMb; $env:FACTORY_TEST_RUN_HELD = "$PID" }
if (-not $NoBuild -and -not $ListSuites -and -not $ListScenarios) {
    foreach ($proj in 'tests/FakeGitHub', 'gateway') { Push-Location (Join-Path $root $proj); dotnet build -c Release -v q 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "  build $proj : $_" }; Pop-Location }
}
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'scenarios.ps1')
. (Join-Path $PSScriptRoot 'owner.ps1')
. (Join-Path $PSScriptRoot 'author.ps1')
. (Join-Path $PSScriptRoot 'messaging.ps1')   # worker messaging steps 1 to 6: suites 'messaging' and 'manager'
. (Join-Path $PSScriptRoot 'operator.ps1')    # the factory operator session: suite 'operator' (uses the helpers of messaging.ps1)
. (Join-Path $PSScriptRoot 'checks.ps1')      # why a check failed (pr-checks): its scenarios join the suites 'auto', 'owner' and 'manager'
foreach ($k in $CheckScenarios.Keys) { $Scenarios[$k] = $CheckScenarios[$k] }
foreach ($k in $CheckOwnerScenarios.Keys) { $OwnerScenarios[$k] = $CheckOwnerScenarios[$k] }
foreach ($k in $CheckManagerScenarios.Keys) { $ManagerScenarios[$k] = $CheckManagerScenarios[$k] }
. (Join-Path $PSScriptRoot 'cirule.ps1')      # one CI rule for flakes and pre-existing failures (issue 102): its scenarios join the suite 'auto'
foreach ($k in $CiRuleScenarios.Keys) { $Scenarios[$k] = $CiRuleScenarios[$k] }
foreach ($k in $CiRuleOwnerScenarios.Keys) { $OwnerScenarios[$k] = $CiRuleOwnerScenarios[$k] }   # (the gateway's merge after a PASS: the owner suite)
. (Join-Path $PSScriptRoot 'qc.ps1')
. (Join-Path $PSScriptRoot 'qc-dashboard.ps1')
. (Join-Path $PSScriptRoot 'qc-worker.ps1')   # S3: own gateway and workers, scenarios named "qc: worker ..."
. (Join-Path $PSScriptRoot 'qc-gate.ps1')     # S4: merge gate, approval trigger, sweep teardown, the race; scenarios named "qc: gate ..."
foreach ($k in $QcDashScenarios.Keys) { $QcScenarios[$k] = $QcDashScenarios[$k] }   # S2 scenarios run in the main QC suite, after the S1 ones
foreach ($k in $QcGateAutoScenarios.Keys) { $QcScenarios[$k] = $QcGateAutoScenarios[$k] }   # S4: the auto policy is unchanged
. (Join-Path $PSScriptRoot 'qc-pool.ps1')     # the rule-script worker pool; scenarios named "qc: runner pool ..."
foreach ($k in $QcPoolScenarios.Keys) { $QcScenarios[$k] = $QcPoolScenarios[$k] }
. (Join-Path $PSScriptRoot 'budget.ps1')      # the sweep throttle and the GitHub budget (GitHubBudget.cs): scenarios named "sweep throttle: ..." and "github budget: ..." join the owner suite
. (Join-Path $PSScriptRoot 'baseupdate.ps1')  # master moved: base.updated and the gateway's update branch; scenarios named "base update: ..." join the owner suite
. (Join-Path $PSScriptRoot 'runner-gate.ps1') # the gate of the rule scripts (gateway/RunnerGate.cs): scenarios named "runner gate: ..." join the owner suite
. (Join-Path $PSScriptRoot 'lease.ps1')       # owner leases kept by the plant (gateway/Lease.cs): scenarios named "lease: ..." join the manager suite
foreach ($k in $LeaseScenarios.Keys) { $ManagerScenarios[$k] = $LeaseScenarios[$k] }
. (Join-Path $PSScriptRoot 'leader.ps1')      # one acting gateway (Leader.cs): the leader lease, the hand-over, the gap; scenarios named "leader: ..." join the owner suite
. (Join-Path $PSScriptRoot 'runtime.ps1')     # cloud worker runtimes: w2, the nonce, git-credential; suite 'runtime' (uses the helpers of owner.ps1)
. (Join-Path $PSScriptRoot 'journal-fold.ps1') # the journal folds its repeats (Journal.ps1): scenarios named "journal fold: ..." join the owner suite
. (Join-Path $PSScriptRoot 'manager-actions.ps1')   # the plant manager's flow verbs (gateway/Manager.cs): scenarios named "act: ..." join the manager suite
foreach ($k in $ManagerActionScenarios.Keys) { $ManagerScenarios[$k] = $ManagerActionScenarios[$k] }
. (Join-Path $PSScriptRoot 'mcp.ps1')               # the MCP server at /mcp (gateway/Mcp/): suite 'mcp' (uses the helpers of owner.ps1)
. (Join-Path $PSScriptRoot 'cursor.ps1')            # the api mode, Cursor Cloud Agents against the fake Cursor API: suite 'cursor'
. (Join-Path $PSScriptRoot 'keeper.ps1')            # the backlog keeper session (gateway/Keeper.cs): scenarios named "keeper: ..." join the manager suite
foreach ($k in $KeeperScenarios.Keys) { $ManagerScenarios[$k] = $KeeperScenarios[$k] }

# ---- the suites. ORDER IS THE PORT SLOT: append new suites at the end, never reorder (a slot is 100 ports from 6100, see lib.ps1). ----------
# Env names the environment a suite needs (set before it, removed after it); Timing sets FACTORY_TIMING_* for the suite; Extra is merged into the gateway config.
$script:OwnerSecret = ('owner-test-secret-' + '0123456789abcdef')   # a fixture, composed so the secret scan does not read it as a credential
# PR QC environment (owner mode, qc roles): the main gateway has the click rate limit lifted, one has the default limits, one is behind a known proxy.
$qcBase = @{ allowLoopbackForTests = $true; probeTimeoutSeconds = 2; maxEnvironments = 50 }
# The qc suite runs its gateway with a pool of rule-script workers (runner.pool, gateway/RunnerPool.cs); the other suites, owner among them, keep one process per call, so both paths stay tested.
$qcOpen = @{ qc = ($qcBase + @{ rateLimitPerIp = 100000; rateLimitPerPr = 100000 }); runner = @{ pool = $(if ($env:TEST_RUNNER_POOL) { [int]$env:TEST_RUNNER_POOL } else { 3 }) } }
# S4: the merge gate needs mergePolicy peer-approved; the teardown timers each need their own short timing.* values (applied by Get-Cfg and the gateway from FACTORY_TIMING_*)
$msgPool = @{ pool = $(if ($env:TEST_RUNNER_POOL) { [int]$env:TEST_RUNNER_POOL } else { 3 }) }
$gateQc = @{ qc = ($qcBase + @{ rateLimitPerIp = 100000; rateLimitPerPr = 100000; minFreeMb = 1 }) }
function New-Gate([hashtable]$Qc = @{}) { @{ qc = ($gateQc.qc + $Qc) } }
$SuiteDefs = @(
    # auto and merge-queue test the session's own merge verb, so the gateway's merge after a PASS is off there (owner.ps1 tests that one)
    @{ Name = 'auto'; Policy = 'auto'; Set = $Scenarios; Extra = @{ gatewayMerge = $false } }
    @{ Name = 'peer-approved'; Policy = 'peer-approved'; Set = $ApprovalScenarios }
    @{ Name = 'merge-queue'; Policy = 'auto'; Set = $QueueScenarios; Extra = @{ mergeQueueDepth = 1; gatewayMerge = $false } }
    @{ Name = 'owner'; Policy = 'auto'; Set = $OwnerScenarios; Extra = @{ ownerSessions = $true; baseUpdate = @{ mode = 'every-move'; autoUpdateDelaySeconds = 6; quietSeconds = 3; sweepCheckSeconds = 3 }; schedule = @{ hosts = @{ 'lab-1' = @{ owned = 1; builds = 1 } } } }; Env = 'owner'; Timing = @{ baseUpdateDebounceSeconds = 4; passMergeGraceSeconds = 8; staleItemMinutes = 600; continueMinutes = 0 } }
    @{ Name = 'qc'; Policy = 'auto'; Set = $QcScenarios; Extra = $qcOpen; Env = 'qc'; ClientHost = $true }   # ClientHost: F runs the client in one long-lived pwsh (lib.ps1)
    @{ Name = 'qc-worker'; Policy = 'auto'; Set = $QcWorkerScenarios; Extra = (New-Gate); Env = 'qc' }
    @{ Name = 'qc-gate'; Policy = 'peer-approved'; Set = $QcGateScenarios; Extra = (New-Gate); Env = 'qc' }
    @{ Name = 'qc-gate-idle'; Policy = 'auto'; Set = $QcGateIdleScenarios; Extra = (New-Gate); Env = 'qc'; Timing = @{ qcIdleMinutes = 0.1 } }
    @{ Name = 'qc-gate-lifetime'; Policy = 'auto'; Set = $QcGateLifetimeScenarios; Extra = (New-Gate); Env = 'qc'; Timing = @{ qcLifetimeMinutes = 0.1 } }
    @{ Name = 'qc-gate-grace'; Policy = 'auto'; Set = $QcGateGraceScenarios; Extra = (New-Gate); Env = 'qc'; Timing = @{ qcGraceMinutes = 0.25 } }
    @{ Name = 'qc-gate-lease'; Policy = 'auto'; Set = $QcGateLeaseScenarios; Extra = (New-Gate); Env = 'qc'; Timing = @{ qcLeaseMinutes = 0.3; qcMaxRelaunches = 2 } }
    @{ Name = 'qc-gate-waiting'; Policy = 'auto'; Set = $QcGateWaitingScenarios; Extra = (New-Gate @{ waitingDelaySeconds = 3 }); Env = 'qc'; Timing = @{ qcWaitingRepeatMinutes = 0.15 } }
    @{ Name = 'qc-gate-race'; Policy = 'auto'; Set = $QcGateRaceScenarios; Extra = (New-Gate @{ testReconcileDelayMs = 3000 }); Env = 'qc'; Timing = @{} }
    @{ Name = 'qc-rate'; Policy = 'auto'; Set = $QcRateScenarios; Extra = @{ qc = ($qcBase + @{ rateLimitPerIp = 10; rateLimitPerPr = 20 }) }; Env = 'qc' }
    @{ Name = 'qc-proxy'; Policy = 'auto'; Set = $QcProxyScenarios; Extra = @{ qc = ($qcBase + @{ rateLimitPerIp = 10; rateLimitPerPr = 20; trustProxy = $true; knownProxies = @('127.0.0.1') }) }; Env = 'qc' }
    @{ Name = 'author'; Policy = 'auto'; Set = $AuthorScenarios; Extra = @{ stateAuthors = @('factory-bot') }; Env = 'author' }
    # messaging and manager run on the fast path of qc: the suite's gateway has the rule-script pool (the second gateways of the scenarios do not, see
    # Msg-StartGateway), F runs the client in one long-lived pwsh, and each suite is split over 4 groups. The owner suite keeps one process per call.
    # the limits of the main gateway are lifted, so one scenario's sends never count against another's; the scenarios that test the limits start a
    # second gateway of their own (Msg-OnGateway). "dave" is on no list: it is the name that is refused.
    @{ Name = 'messaging'; Policy = 'auto'; Set = $MessagingScenarios; Extra = @{ messaging = @{ enabled = $true; allowedWorkers = @('alice', 'bob', 'carol', 'erin', 'frank', 'gina', 'hank', 'ivan', 'judy', 'kate', 'liam', 'racer', 'poller'); testHooks = $true }; runner = $msgPool }; Env = 'owner'; ClientHost = $true
        Timing = @{ ratePerMinute = 100000; pairPer10Min = 100000; perSenderQueueCap = 1000; recipientQueueCap = 1000; broadcastPer10Min = 100000; staleItemMinutes = 600; continueMinutes = 0 } }
    @{ Name = 'manager'; Policy = 'auto'; Set = $ManagerScenarios; Extra = @{ ownerSessions = $true; messaging = @{ enabled = $true; testHooks = $true }; manager = @{ enabled = $true; allowedNames = @('supervisor', 'supervisor2'); allowedAskers = @('alice', 'bob', 'carol', 'erin', 'frank', 'gina', 'ivan', 'judy', 'kate'); tokenGeneration = 1; turnBudgetPerHour = 100000; turnBudgetPerDay = 100000; stepBudgetPerHour = 100000 }; runner = $msgPool }; Env = 'owner'; ClientHost = $true
        # the delivery and step budgets are lifted like the other limits (the budget scenarios set their own); an owner the sweep stops listing is dropped after 5 s
        # (an owner that a scenario leaves behind on the suite's gateway is not reported as quiet, and a client that an earlier scenario left running, which
        # reconnects to the next gateway with the cursor of the last one, is not reported as a restart: the scenarios of those conditions set their own times)
        Timing = @{ mgrTakeoverSeconds = 6; ratePerMinute = 100000; pairPer10Min = 100000; broadcastPer10Min = 100000; mgrOwnedGraceSeconds = 5; mgrQuietMinutes = 600; mgrRestartMinutes = 0.0001; staleItemMinutes = 600; continueMinutes = 0 } }
    # the factory operator session (operator.ps1): one process per rule-script call, so a verb call is in flight long enough to be seen by release-check
    @{ Name = 'operator'; Policy = 'auto'; Set = $OperatorScenarios; Extra = @{ ownerSessions = $true; messaging = @{ enabled = $true; allowedWorkers = @('alice', 'bob'); testHooks = $true }; manager = @{ enabled = $true; allowedNames = @('supervisor'); allowedAskers = @('alice', 'bob'); tokenGeneration = 1; turnBudgetPerHour = 100000; turnBudgetPerDay = 100000; stepBudgetPerHour = 100000 }
            operator = @{ enabled = $true; allowedNames = @('operator-session', 'operator-two'); tokenGeneration = 1; requiredModelTier = 'premium'; requiredEffort = 'low'; maxSelfMergesPerDay = 2 } }; Env = 'owner'
        Timing = @{ mgrTakeoverSeconds = 4; ratePerMinute = 100000; pairPer10Min = 100000; broadcastPer10Min = 100000; opSelfAnswerMinutes = 0.1; staleItemMinutes = 600; continueMinutes = 0 } }
    # cloud worker runtimes (runtime.ps1): the w2 credential, the one-time nonce (minted through the messaging test seam) and git-credential
    # and the adapter against the fake ARM: items opt in by the runtime:cae-job label (no routing rule), a 15 s window for runtime workers (8 s for local ones)
    @{ Name = 'runtime'; Policy = 'auto'; Set = $RuntimeScenarios; Env = 'runtime'; Timing = @{ staleItemMinutes = 600; continueMinutes = 0; sessionEndGraceSeconds = 3 }
        Extra = @{ ownerSessions = $true; messaging = @{ enabled = $true; allowedWorkers = @('*'); testHooks = $true }
            runtimes = @{ preferConnected = $true; routing = @(); caeJob = @{ enabled = $true; maxConcurrent = 3; maxExecutionsPerDay = 1000; ackSeconds = 15; replicaTimeoutSeconds = 3600; maxFailuresPerPhase = 2; unhealthyAfterFailures = 2; listSeconds = 1
                jobResourceId = '/subscriptions/s1/resourceGroups/rg-test/providers/Microsoft.App/jobs/caj-test-claude'; armEndpoint = '__FAKE_URL__'; apiVersion = '2024-03-01'; managedIdentityClientId = ''; image = ''; containerName = 'fwrunner'; cpu = 4; memory = '8Gi'; gatewayUrl = 'http://ca-test-fworker'
                agent = 'codex'; jobs = @{ codex = '/subscriptions/s1/resourceGroups/rg-test/providers/Microsoft.App/jobs/caj-test' } } } } }
    # the MCP server (mcp.ps1, docs/design/agents-roles-launch.md 6): owner mode, messaging on for every name
    @{ Name = 'mcp'; Policy = 'auto'; Set = $McpScenarios; Env = 'owner'; Timing = @{ staleItemMinutes = 600 }
        Extra = @{ ownerSessions = $true; messaging = @{ enabled = $true; allowedWorkers = @('*'); testHooks = $true } } }
    # the api mode (cursor.ps1, agents-roles-launch.md 10): the fake Cursor API, a 0.25-minute deadline, a 20 s window for the agent
    @{ Name = 'cursor'; Policy = 'auto'; Set = $CursorScenarios; Env = 'cursor'; Timing = @{ staleItemMinutes = 600; sessionEndGraceSeconds = 3 }
        Extra = @{ ownerSessions = $true; messaging = @{ enabled = $true; allowedWorkers = @('*'); testHooks = $true }
            api = @{ cursor = @{ enabled = $true; maxConcurrent = 2; maxMinutes = 0.25; maxExecutionsPerDay = 1000; ackSeconds = 20; listSeconds = 1; idleGraceSeconds = 2; model = 'auto'; apiUrl = '__FAKE_URL__'; gatewayUrl = 'http://gw.test'; repository = 'https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders' } } } }
)
if ($ListSuites) { $SuiteDefs | ForEach-Object { $_.Name }; exit 0 }
if ($ListScenarios) { foreach ($d0 in $SuiteDefs) { foreach ($k0 in $d0.Set.Keys) { "$($d0.Name)`t$k0`t$(Get-ScenarioTier $k0)" } }; exit 0 }
if ($Suite -and -not @($SuiteDefs | Where-Object { $_.Name -eq $Suite }).Count) { Write-Host "unknown suite '$Suite'; known: $(($SuiteDefs | ForEach-Object { $_.Name }) -join ', ')"; exit 2 }

# ---- qc runs as independent groups: this process starts them, waits (at most -GroupTimeoutMinutes), and adds up their results ---------------
if ($Groups -le 0) { $Groups = $(if ($Suite -in 'qc', 'messaging', 'manager') { 4 } elseif ($Suite -eq 'owner') { 2 } else { 1 }); if ($lowMemory -and $Groups -gt 1) { $Groups = [int]($Groups / 2); Write-Host "memory is short: $Groups groups at once" } }
if ($Groups -gt 10) { Write-Host "-Groups ${Groups}: at most 10 (each group has a port range of 100 inside the 1000 of its suite)"; exit 2 }
if ($Group -ge $Groups) { Write-Host "-Group $Group is outside -Groups $Groups (groups are numbered from 0)"; exit 2 }
if ($Groups -gt 1 -and $Suite -and $Group -lt 0) {
    # Group port ranges lie above every suite slot (6100 + 100 * slot, up to 7899): 10000 + 1000 * slot + 100 * group. TEST_PORT_BASE moves the first group; TEST_FAKE_PORT and TEST_API_PORT name one port each, so they cannot apply to several groups and are not passed on.
    $base0 = $(if ($env:TEST_PORT_BASE) { [int]$env:TEST_PORT_BASE } else { 10000 + 1000 * @($SuiteDefs | ForEach-Object { $_.Name }).IndexOf($Suite) })
    $gDir = Join-Path ([IO.Path]::GetTempPath()) "factory-groups-$([guid]::NewGuid().ToString('N').Substring(0,6))"; New-Item -ItemType Directory -Force -Path $gDir | Out-Null
    $swAll = [Diagnostics.Stopwatch]::StartNew(); $kids = @(); $tot = 0; $fails = @(); $sc = @(); $skip = [ordered]@{}; $vc = 0; $vs = 0.0; $gv = 0; $cc = 0; $bad = $false; $quar = @()
    $oB = $env:TEST_PORT_BASE; $oF = $env:TEST_FAKE_PORT; $oA = $env:TEST_API_PORT
    try {
        try {
            Remove-Item Env:TEST_FAKE_PORT, Env:TEST_API_PORT -ErrorAction SilentlyContinue
            foreach ($g in 0..($Groups - 1)) {
                $a2 = @('-NoProfile', '-File', $PSCommandPath, '-NoBuild', '-Suite', $Suite, '-Tier', $Tier, '-Groups', $Groups, '-Group', $g, '-ResultFile', (Join-Path $gDir "g$g.json")); if ($Only) { $a2 += @('-Only', $Only) }
                $env:TEST_PORT_BASE = "$($base0 + 100 * $g)"
                $kids += ,@{ g = $g; log = (Join-Path $gDir "g$g.log"); err = (Join-Path $gDir "g$g.err"); json = (Join-Path $gDir "g$g.json"); timedOut = $false; proc = (Start-Process pwsh -ArgumentList $a2 -PassThru -RedirectStandardOutput (Join-Path $gDir "g$g.log") -RedirectStandardError (Join-Path $gDir "g$g.err")) }
            }
        } finally { foreach ($e in @(@('TEST_PORT_BASE', $oB), @('TEST_FAKE_PORT', $oF), @('TEST_API_PORT', $oA))) { if ($e[1]) { Set-Item "Env:$($e[0])" $e[1] } else { Remove-Item "Env:$($e[0])" -ErrorAction SilentlyContinue } } }
        $deadline = [DateTime]::UtcNow.AddMinutes($GroupTimeoutMinutes)
        while (@($kids | Where-Object { -not $_.proc.HasExited }).Count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        foreach ($k in $kids) { if (-not $k.proc.HasExited) { $k.timedOut = $true; try { $k.proc.Kill($true) } catch { } }; [void]$k.proc.WaitForExit(10000) }
        foreach ($k in $kids) {
            Write-Host "=== group $($k.g) of $Groups ==="; if (Test-Path $k.log) { Get-Content $k.log | ForEach-Object { Write-Host $_ } }
            if ((Test-Path $k.err) -and (Get-Item $k.err).Length -gt 0) { Write-Host "--- group $($k.g) stderr ---"; Get-Content $k.err | ForEach-Object { Write-Host $_ } }
            if ($k.timedOut) { $bad = $true; $fails += "group $($k.g) timed out (after $GroupTimeoutMinutes minutes)"; continue }
            $code = $k.proc.ExitCode; if ($code -ne 0) { $bad = $true; $fails += "group $($k.g) exited $code" }
            $r = $null; try { if (Test-Path $k.json) { $r = Get-Content -Raw $k.json | ConvertFrom-Json -AsHashtable } } catch { }
            if (-not $r -or -not $r.ContainsKey('checks')) { $bad = $true; $fails += "group $($k.g) produced no readable result file"; continue }
            $tot += $r.checks; $fails += @($r.failures); $sc += @($r.scenarios); $vc += $r.verbCalls; $vs += $r.verbSeconds; $gv += $r.gatewayVerbLines; if ($r.ContainsKey('clientCrashes')) { $cc += [int]$r.clientCrashes }; if ($r.ContainsKey('quarantined')) { $quar += @($r.quarantined | Where-Object { $_ }) }
            foreach ($x in @($r.skipped)) { if ($x) { $skip["$($x.suite)`t$($x.name)"] = $x } }
        }
        if ($tot -eq 0) { $bad = $true; $fails += 'no checks ran' }
        Write-Host ""; Write-Host "$tot checks, $($fails.Count) failed"; $fails | ForEach-Object { Write-Host "  FAILED: $_" }
        if ($quar.Count) { Write-Host "quarantined failures: $($quar.Count) (reported, not counted as failed)"; $quar | ForEach-Object { Write-Host "  QUARANTINED: $_" } }
        if ($Tier -eq 'fast') { Write-Host "skipped as full-tier: $($skip.Count) scenarios" }
        Write-Host ("verbs: {0} client calls, {1:N1}s in them; groups: {2}; suite took {3:N0}s" -f $vc, $vs, $Groups, $swAll.Elapsed.TotalSeconds)
        if ($cc) { Write-Host "client crashes: $cc client calls ended with pwsh exit 139 (segmentation fault): machine load or the runtime, not a product answer" }
        if ($ResultFile) { [ordered]@{ suite = $Suite; checks = $tot; failed = $fails.Count; quarantined = @($quar); clientCrashes = $cc; failures = @($fails); seconds = [math]::Round($swAll.Elapsed.TotalSeconds, 1); verbCalls = $vc; verbSeconds = [math]::Round($vs, 1); tier = $Tier; skipped = @($skip.Values); scenarios = @($sc); gatewayVerbLines = $gv; groups = $Groups; portBase = $base0 } | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultFile }
    } finally {
        foreach ($k in $kids) { try { if (-not $k.proc.HasExited) { $k.proc.Kill($true) } } catch { } }
        Remove-Item -Recurse -Force $gDir -ErrorAction SilentlyContinue
    }
    exit ([int]($bad -or $fails.Count -gt 0))
}

# ---- isolation: this process has its own ports, HOME (client configs, worker and token dirs, App tokens) and TMPDIR (every work dir) ----------
$slot = 0; if ($Suite) { for ($i = 0; $i -lt $SuiteDefs.Count; $i++) { if ($SuiteDefs[$i].Name -eq $Suite) { $slot = $i } } }
if (-not $env:TEST_PORT_BASE) { $env:TEST_PORT_BASE = "$(6100 + 100 * $slot)" }
Set-TestPorts ([int]$env:TEST_PORT_BASE)
# Less CPU per dotnet process (the fake, the gateway, every pwsh): no profile-guided tiering, no background GC thread. About 10% of the CPU of a suite, and CPU is what parallel suites compete for.
if (-not $env:DOTNET_TieredPGO) { $env:DOTNET_TieredPGO = '0' }; if (-not $env:DOTNET_gcConcurrent) { $env:DOTNET_gcConcurrent = '0' }
$label = if ($Suite) { $Suite } else { 'all' }
$script:SuiteRoot = Join-Path ([IO.Path]::GetTempPath()) "factory-suite-$label-$([guid]::NewGuid().ToString('N').Substring(0,6))"
foreach ($d in 'home', 'tmp') { New-Item -ItemType Directory -Force -Path (Join-Path $script:SuiteRoot $d) | Out-Null }
$env:HOME = Join-Path $script:SuiteRoot 'home'; $env:TMPDIR = Join-Path $script:SuiteRoot 'tmp'
Write-Host "suite $label : ports $($script:PortBase)-$($script:PortBase + 99) (fake $($script:FakePort), api $($script:ApiPort), hooks $($script:HookPort)), work $($script:SuiteRoot)"
# (variable names here must not collide, case-insensitively, with the globals of the scenario files: $L, $L2, ...)
# A suite needs its ports free (a leftover process of an earlier run would answer in place of this suite's own fake and gateway).
foreach ($port in $script:FakePort, $script:ApiPort, $script:HookPort) {
    $probeSock = $null; try { $probeSock = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $probeSock.Start() } catch { Write-Host "port $port is already in use: another run, or a process outside the tests"; exit 3 } finally { if ($probeSock) { $probeSock.Stop() } }
}

function Get-SuiteEnv([string]$Kind) {
    switch ($Kind) {
        # 8 s: a late accept is refused now (stale-assignment), and a loaded runner takes several seconds per client call
        # the plant snapshot (PlantSnapshot.cs) is off in the suites: its read at start would hold every first sweep back; its own scenario switches it on
        # the leader lease (Leader.cs) is off as well: a restarted suite gateway would wait for its predecessor's hand-over; its own scenarios switch it on
        'owner' { return @{ FACTORY_OWNER_MODE = '1'; FACTORY_PLANT_SNAPSHOT = '0'; FACTORY_LEADER_LEASE = '0'; FACTORY_TOKEN_SECRET = $script:OwnerSecret; FACTORY_ASSIGN_ACK_SECONDS = '8' } }
        # the runtime suite: owner mode and the bearer token of the fake ARM (taken by the gateway only for a loopback ARM endpoint)
        # the cursor suite: owner mode and the key of the fake Cursor API (CURSOR_API_KEY, as the deployed gateway reads it)
        'cursor' { return @{ FACTORY_OWNER_MODE = '1'; FACTORY_PLANT_SNAPSHOT = '0'; FACTORY_LEADER_LEASE = '0'; FACTORY_TOKEN_SECRET = $script:OwnerSecret; FACTORY_ASSIGN_ACK_SECONDS = '8'; CURSOR_API_KEY = 'fake-cursor' } }
        'runtime' { return @{ FACTORY_OWNER_MODE = '1'; FACTORY_PLANT_SNAPSHOT = '0'; FACTORY_LEADER_LEASE = '0'; FACTORY_TOKEN_SECRET = $script:OwnerSecret; FACTORY_ASSIGN_ACK_SECONDS = '8'; FACTORY_TEST_ARM_TOKEN = 'fake-arm' } }
        'qc' {
            $adminTokens = Join-Path $script:SuiteRoot 'qc-admin-tokens'; New-Item -ItemType Directory -Force -Path $adminTokens | Out-Null
            return @{ FACTORY_OWNER_MODE = '1'; FACTORY_PLANT_SNAPSHOT = '0'; FACTORY_LEADER_LEASE = '0'; FACTORY_TOKEN_SECRET = $script:OwnerSecret; FACTORY_ASSIGN_ACK_SECONDS = '60'; FACTORY_PUBLIC_URL = "http://127.0.0.1:$($script:ApiPort)"; FACTORY_TOKEN_DIR = $adminTokens }
        }
        'author' {
            $pem = (& openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>$null) -join "`n"
            return @{ TEST_REAL_APPS = '1'; FACTORY_AUTHOR_APP = '1'; FACTORY_APP_AUTHOR_ID = '4242'; FACTORY_APP_AUTHOR_INSTALLATION = '7'; FACTORY_APP_AUTHOR_SLUG = 'factory-worker-author'; FACTORY_APP_AUTHOR_KEY = $pem; GH_TOKEN = 'unset' }
        }
    }
    return @{}
}

$script:GwVerbs = 0
function Count-GatewayVerbs { foreach ($f in Get-ChildItem -Path $script:Work -Filter 'gateway*.out' -ErrorAction SilentlyContinue) { $script:GwVerbs += @(Select-String -Path $f.FullName -Pattern '"verb":"').Count } }
$script:Skipped = New-Object System.Collections.ArrayList
function Run-Suite([string]$Policy, $Set, [hashtable]$Extra = @{}) {
    $names = @($Set.Keys | Where-Object { -not $Only -or $_ -match $Only })
    $runNames = @($names | Where-Object { $Tier -eq 'full' -or (Get-ScenarioTier $_) -eq 'fast' })
    foreach ($n in $names) { if ($runNames -notcontains $n) { [void]$script:Skipped.Add(@{ suite = $script:SuiteName; name = $n }) } }
    if ($Groups -gt 1 -and $Group -ge 0) {   # this child's share (seconds from scenario-stats.json), kept in suite order: owner in contiguous runs, the others longest scenario first onto the least loaded group
        $st = @{}; try { $st = (Get-Content -Raw (Join-Path $PSScriptRoot 'scenario-stats.json') | ConvertFrom-Json -AsHashtable)[$script:SuiteName] } catch { }
        $load = New-Object double[] $Groups; $mine = @{}
        if ($script:SuiteName -eq 'owner') {
            # owner: contiguous runs in suite order, cut at even shares of the seconds. Its scenarios lean on workers and state that earlier ones
            # left behind (alice, bob, carol...), so a balanced pick from anywhere in the suite breaks them; a contiguous run keeps the order intact.
            $secs = @($runNames | ForEach-Object { $k = $_ -replace '\s\[full\]\s*$', ''; $(if ($st -and $st.ContainsKey($k)) { [double]$st[$k].seconds } else { 30.0 }) })
            $total = ($secs | Measure-Object -Sum).Sum; if (-not ($total -gt 0)) { $secs = @($secs | ForEach-Object { 1.0 }); $total = [double]$secs.Count }; $acc = 0.0
            for ($i = 0; $i -lt $runNames.Count; $i++) { $gi = [math]::Min($Groups - 1, [int][math]::Floor(($acc + $secs[$i] / 2) / $total * $Groups)); $acc += $secs[$i]; if ($gi -eq $Group) { $mine[$runNames[$i]] = $true } }
        } else {
        foreach ($n in ($runNames | Sort-Object { $k = $_ -replace '\s\[full\]\s*$', ''; if ($st -and $st.ContainsKey($k)) { -[double]$st[$k].seconds } else { -30.0 } })) {
            $k = $n -replace '\s\[full\]\s*$', ''; $sec = $(if ($st -and $st.ContainsKey($k)) { [double]$st[$k].seconds } else { 30.0 }); $gi = 0; for ($i = 1; $i -lt $Groups; $i++) { if ($load[$i] -lt $load[$gi]) { $gi = $i } }
            $load[$gi] += $sec; if ($gi -eq $Group) { $mine[$n] = $true }
        }
        }
        $runNames = @($runNames | Where-Object { $mine.ContainsKey($_) })
    }
    if ($runNames.Count -eq 0) { return }
    $cfg = @{ mergePolicy = $Policy; humanApprovers = @('factory-worker-testperson[bot]') }; foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
    Start-TestEnv $cfg
    try {
        Write-Host "scenarios (merge policy: $Policy, tier: $Tier)"
        foreach ($name in $runNames) { Run-Scenario $name $Set[$name] }
    } finally { try { Start-Sleep -Seconds $(if ($Tier -eq 'fast') { 1 } else { 3 }); Assert-NoServerErrors $Policy } finally { Count-GatewayVerbs; Stop-TestEnv } }
}
function Invoke-SuiteDef($Def) {
    $script:SuiteName = $Def.Name
    $script:UseClientHost = $Def.ContainsKey('ClientHost') -and [bool]$Def.ClientHost
    $envKind = $(if ($Def.ContainsKey('Env')) { $Def.Env } else { '' }); $envs = Get-SuiteEnv $envKind; $timing = if ($Def.ContainsKey('Timing')) { $Def.Timing } else { @{} }
    foreach ($k in $envs.Keys) { Set-Item "Env:$k" ([string]$envs[$k]) }
    foreach ($k in $timing.Keys) { Set-Item "Env:FACTORY_TIMING_$k" ([string]$timing[$k]) }
    try { Run-Suite $Def.Policy $Def.Set $(if ($Def.ContainsKey('Extra')) { $Def.Extra } else { @{} }) }
    finally {
        foreach ($k in $envs.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        foreach ($k in $timing.Keys) { Remove-Item "Env:FACTORY_TIMING_$k" -ErrorAction SilentlyContinue }
        if ($envKind -eq 'author') { $env:GH_TOKEN = 'fake-operator' }
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($def in $SuiteDefs) { if ($Suite -and $def.Name -ne $Suite) { continue }; Invoke-SuiteDef $def }
$sw.Stop()
Write-Host ""
Write-Host "$($script:Checks) checks, $($script:Failures.Count) failed"
$script:Failures | ForEach-Object { Write-Host "  FAILED: $_" }
if ($script:Quarantined.Count) { Write-Host "quarantined failures: $($script:Quarantined.Count) (reported, not counted as failed)"; $script:Quarantined | ForEach-Object { Write-Host "  QUARANTINED: $_" } }
if ($Tier -eq 'fast') { Write-Host "skipped as full-tier: $($script:Skipped.Count) scenarios" }
if ($script:ClientCrashes) { Write-Host "client crashes: $($script:ClientCrashes) client calls ended with pwsh exit 139 (segmentation fault). That is the machine (load, memory) or the runtime, not an answer of the product: run the failed scenarios again on a quiet machine before reading them as defects." }
if ($script:VerbCalls) { Write-Host ("verbs: {0} client calls, {1:N1}s in them ({2:N2}s per call); gateway logged {3} verb lines; suite took {4:N0}s" -f $script:VerbCalls, $script:VerbSeconds, ($script:VerbSeconds / $script:VerbCalls), $script:GwVerbs, $sw.Elapsed.TotalSeconds) }
if ($ResultFile) {
    [ordered]@{ suite = $label; slot = $slot; checks = $script:Checks; failed = $script:Failures.Count; quarantined = @($script:Quarantined); failures = @($script:Failures); seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        verbCalls = $script:VerbCalls; verbSeconds = [math]::Round($script:VerbSeconds, 1); clientCrashes = $script:ClientCrashes; tier = $Tier; skipped = @($script:Skipped); scenarios = @($script:ScenarioStats); gatewayVerbLines = $script:GwVerbs; portBase = $script:PortBase } | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultFile
}
exit ([int]($script:Failures.Count -gt 0))
