# The gate of the rule scripts (gateway/RunnerGate.cs, issue 89): at most runner.maxProcesses calls at once, a freed slot to the sweep first and
# to the journal last, one slot kept for the sweep and the take-backs, and a verb that waits too long answered runner-busy. Runs in the owner suite
# (one process per call, as tdd runs today). The scenario starts its own gateway with FACTORY_RUNNER_MAX and gives the suite's back in finally.

# A verb call with the operator token in a thread job: the job's result is { status; body }.
function Rg-Start([string]$Verb, [hashtable]$Body) {
    $u = "http://127.0.0.1:$($script:ApiPort)/api/v1/verbs/$Verb"; $json = $Body | ConvertTo-Json -Compress -Depth 5
    Start-ThreadJob -ArgumentList $u, $json -ScriptBlock {
        param($u, $json)
        $r = Invoke-WebRequest $u -Method POST -Headers @{ Authorization = 'Bearer test-token' } -Body $json -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 200
        @{ status = [int]$r.StatusCode; body = $(try { $r.Content | ConvertFrom-Json -AsHashtable } catch { @{ raw = "$($r.Content)" } }) }
    }
}
function Rg-Runner { (Get-Plant).runner }
# the starts the gate recorded since a mark (the number of starts of every class before it)
function Rg-StartsSince([int]$Mark) { $all = @((Rg-Runner).recent); $total = 0; foreach ($p in (Rg-Runner).started.PSObject.Properties) { $total += [int]$p.Value }; $skip = [Math]::Max(0, $all.Count - ($total - $Mark)); , @($all | Select-Object -Skip $skip) }
function Rg-Total { $t = 0; foreach ($p in (Rg-Runner).started.PSObject.Properties) { $t += [int]$p.Value }; $t }

$RunnerGateScenarios = [ordered]@{}

$RunnerGateScenarios['runner gate: at most runner.maxProcesses rule scripts at once; a freed slot goes to the sweep first, the journal last; a verb that waits too long is runner-busy [full]'] = {
    $old = @{ max = $env:FACTORY_RUNNER_MAX; sweep = $env:FACTORY_SWEEP_SECONDS; wait = $env:FACTORY_RUNNER_MAX_WAIT_SECONDS }
    # two slots; the sweeper quiet (its first sweep runs at start), so only this scenario's calls are in the gate
    $env:FACTORY_RUNNER_MAX = '2'; $env:FACTORY_SWEEP_SECONDS = '600'; $env:FACTORY_RUNNER_MAX_WAIT_SECONDS = '60'
    $jobs = @()
    try {
        Restart-Gateway
        [void](Wait-Until -Seconds 30 { $null -ne (Get-Plant).lastSweep -and (Rg-Runner).running -eq 0 })
        # (the back-merge check runs once after the first sweep)
        Start-Sleep -Seconds 2; [void](Wait-Until -Seconds 30 { (Rg-Runner).running -eq 0 })
        $r0 = Rg-Runner
        Check 'the status shows the gate: limit 2, the classes and their limits, nothing running' ($r0.limit -eq 2 -and $r0.limits.critical -eq 2 -and $r0.limits.normal -eq 1 -and $r0.limits.journal -eq 1 -and $r0.running -eq 0) ($r0 | ConvertTo-Json -Compress -Depth 4)
        Check 'and the memory: the gateway, the rule-script processes, the container where it can be read' ($r0.memory.gatewayMb -gt 0 -and $null -ne $r0.memory.processes) ($r0.memory | ConvertTo-Json -Compress)
        # items that are not factory work (no label): the sweep never reads them, so only these calls touch them
        $x = New-Item-Fake 'Gate slow' 'x' @(); $y = New-Item-Fake 'Gate journal' 'x' @(); $z = New-Item-Fake 'Gate normal' 'x' @()
        Fake 'latency' @{ ms = 10000; match = "^GET \S*/issues/$x/comments" } | Out-Null
        $mark = Rg-Total
        $jobs += Rg-Start 'get-item' @{ item = $x }
        Check 'a slow verb takes one slot' (Wait-Until -Seconds 20 { (Rg-Runner).runningByClass.normal -eq 1 })
        $jobs += Rg-Start 'journal' @{ item = $y; event = 'tier'; fields = @{ name = 'gate-test'; reasons = 'scenario' }; key = 'gate' }
        [void](Wait-Until -Seconds 10 { (Rg-Runner).waitingByClass.journal -eq 1 })
        $jobs += Rg-Start 'get-item' @{ item = $z }
        [void](Wait-Until -Seconds 10 { (Rg-Runner).waitingByClass.normal -eq 1 })
        $st1 = Rg-Runner
        Check 'with one slot free a second verb and the journal wait: that slot is kept for the sweep' ($st1.running -eq 1 -and $st1.waitingByClass.normal -eq 1 -and $st1.waitingByClass.journal -eq 1) ($st1 | ConvertTo-Json -Compress -Depth 4)
        $jobs += Rg-Start 'sync-board' @{}
        Check 'the sweep starts at once in the kept slot while the slow verb still runs' (Wait-Until -Seconds 15 { $s = Rg-Runner; $s.peakRunning -eq 2 -and @(Rg-StartsSince $mark | Where-Object { $_.verb -eq 'sync-board' }).Count -ge 1 }) ((Rg-Runner) | ConvertTo-Json -Compress -Depth 4)
        Fake 'latency' @{ ms = 0 } | Out-Null
        [void]($jobs | Wait-Job -Timeout 120)
        Check 'every call ended' (@($jobs | Where-Object { $_.State -eq 'Completed' }).Count -eq $jobs.Count) (($jobs | ForEach-Object { $_.State }) -join ',')
        $res = @($jobs | Receive-Job)
        Check 'and answered ok' (@($res | Where-Object { $_.status -ne 200 }).Count -eq 0) ($res | ConvertTo-Json -Compress -Depth 4)
        $order = @(Rg-StartsSince $mark | ForEach-Object { $_.verb })
        $ix = [Array]::IndexOf($order, 'get-item'); $iz = [Array]::LastIndexOf($order, 'get-item'); $ij = [Array]::IndexOf($order, 'journal'); $is = [Array]::IndexOf($order, 'sync-board')
        Check 'the order of the starts: the slow verb, the sweep, the waiting verb, the journal last' ($ix -ge 0 -and $ix -lt $is -and $is -lt $iz -and $iz -lt $ij) ($order -join ', ')
        Check 'never more than 2 at once' ((Rg-Runner).peakRunning -le 2) ((Rg-Runner).peakRunning)
        # a burst of verbs: they queue, never more than the limit run, and every one is answered
        $jobs | Remove-Job -Force; $jobs = @()
        $peak = 0
        foreach ($i in 1..6) { $jobs += Rg-Start 'get-item' @{ item = $z } }
        $deadline = (Get-Date).AddSeconds(90)
        while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0 -and (Get-Date) -lt $deadline) { $s = Rg-Runner; if ($s.memory.processes -gt $peak) { $peak = [int]$s.memory.processes }; Start-Sleep -Milliseconds 300 }
        $res = @($jobs | Wait-Job -Timeout 30 | Receive-Job)
        Check 'a burst of 6 verbs: all answered ok' ($res.Count -eq 6 -and @($res | Where-Object { $_.status -ne 200 }).Count -eq 0) ($res | ConvertTo-Json -Compress -Depth 3)
        Check 'with at most 2 rule-script processes alive at once' ($peak -le 2 -and (Rg-Runner).peakRunning -le 2) "processes $peak, peak running $((Rg-Runner).peakRunning)"
        $jobs | Remove-Job -Force; $jobs = @()
        # a verb that cannot get a slot within its wait: exit 20 runner-busy, retryable
        $env:FACTORY_RUNNER_MAX = '1'; $env:FACTORY_RUNNER_MAX_WAIT_SECONDS = '2'; Restart-Gateway
        [void](Wait-Until -Seconds 30 { $null -ne (Get-Plant).lastSweep -and (Rg-Runner).running -eq 0 })
        Start-Sleep -Seconds 2; [void](Wait-Until -Seconds 30 { (Rg-Runner).running -eq 0 })
        Fake 'latency' @{ ms = 10000; match = "^GET \S*/issues/$x/comments" } | Out-Null
        $jobs += Rg-Start 'get-item' @{ item = $x }
        [void](Wait-Until -Seconds 20 { (Rg-Runner).running -eq 1 })
        $busy = Rg-Start 'get-item' @{ item = $z }; $jobs += $busy
        $b = $busy | Wait-Job -Timeout 30 | Receive-Job
        Check 'the second verb is refused after its wait: 503, exit 20 runner-busy with retryAfterSeconds' ($b.status -eq 503 -and $b.body.code -eq 'runner-busy' -and $b.body.exit -eq 20 -and $b.body.retryAfterSeconds -gt 0) ($b | ConvertTo-Json -Compress -Depth 3)
        Check 'and counted' ((Rg-Runner).busyRefusals.normal -ge 1) ((Rg-Runner).busyRefusals | ConvertTo-Json -Compress)
        Fake 'latency' @{ ms = 0 } | Out-Null
    } finally {
        Fake 'latency' @{ ms = 0 } | Out-Null
        $jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        foreach ($k in @(@('FACTORY_RUNNER_MAX', $old.max), @('FACTORY_SWEEP_SECONDS', $old.sweep), @('FACTORY_RUNNER_MAX_WAIT_SECONDS', $old.wait))) { if ($k[1]) { Set-Item "Env:$($k[0])" $k[1] } else { Remove-Item "Env:$($k[0])" -ErrorAction SilentlyContinue } }
        Restart-Gateway
    }
}

foreach ($k in $RunnerGateScenarios.Keys) { $OwnerScenarios[$k] = $RunnerGateScenarios[$k] }
