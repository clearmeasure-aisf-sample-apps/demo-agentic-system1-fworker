# Tier 1 scenarios of the cloud worker runtimes (docs/design/cloud-worker-runtimes.md): the w2 credential, the one-time nonce and the
# git-credential verb (gateway/Auth.cs). Suite 'runtime' (owner mode, messaging test hooks for the nonce seam). Uses the helpers of owner.ps1.

function Rt-Api([string]$Method, [string]$Path, $Body = $null, [string]$Token = 'test-token') {
    $h = @{}; if ($Token) { $h.Authorization = "Bearer $Token" }
    $p = @{ Uri = "http://127.0.0.1:$($script:ApiPort)$Path"; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true; StatusCodeVariable = 'sc' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 6 -Compress); $p.ContentType = 'application/json' }
    $r = Invoke-RestMethod @p
    return @{ status = [int]$sc; body = $r }
}
function Rt-Nonce([string]$Name, [double]$TokenSeconds = 3600, [string]$Runtime = 'cae-job') { (Rt-Api POST '/api/v1/_test/runtime-nonce' @{ name = $Name; runtime = $Runtime; tokenSeconds = $TokenSeconds }).body.nonce }
function Rt-Redeem([string]$Nonce) { Rt-Api POST '/api/v1/runtime/redeem' @{ nonce = $Nonce } '' }

# A worker session that holds a w2: the real client (subscribe --own) with that credential, as fwrunner.sh starts it.
function Start-RuntimeClient([string]$Name, [string]$Token) {
    $dir = Join-Path $script:Work "tokens-$Name"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $script:Work "worker-$Name.out"
    $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN }
    $env:FACTORY_TOKEN_DIR = $dir; $env:FACTORY_WORKER_TOKEN = $Token
    $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $script:Root 'plugin/scripts/factory.ps1'), 'subscribe', '--own', '--name', $Name, '--type', 'claude-cloud') -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work "worker-$Name.err")
    $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w
    $script:Procs += $p
    $script:Workers[$Name] = @{ proc = $p; dir = $dir; out = $out; token = $Token }
    [void](Wait-Until -Seconds 20 { @(Get-WorkerEvents $Name | Where-Object { $_.event -eq 'worker.registered' }).Count -gt 0 })
}
# Offers the item to the worker (pinned by label) and accepts it with the worker's item token.
function Rt-Own([string]$Name, [int]$Item) {
    if (-not (Wait-Until -Seconds 40 { (Get-Assigned $Name $Item).Count -gt 0 })) { return @{ exit = -1; code = 'no-offer' } }
    for ($try = 0; $try -lt 5; $try++) {
        $r = Fo $Name @('accept', '--item', $Item, '--assignment', (Get-Assigned $Name $Item)[-1].assignment)
        if ($r.exit -ne 11) { return $r }
        $seen = (Get-Assigned $Name $Item).Count; [void](Wait-Until -Seconds 30 { (Get-Assigned $Name $Item).Count -gt $seen })
    }
    return $r
}

$RuntimeScenarios = [ordered]@{

'runtime: a nonce is redeemed once for a w2 bound to its name and runtime; a second redemption and an unknown nonce are refused' = {
    $nonce = Rt-Nonce 'cae-1-a1b2c3'
    Check 'the seam mints a nonce' ("$nonce" -like 'n1.*')
    $r = Rt-Redeem $nonce
    Check 'the first redemption answers a w2 for the name and runtime' ($r.status -eq 200 -and $r.body.name -eq 'cae-1-a1b2c3' -and $r.body.runtime -eq 'cae-job' -and "$($r.body.token)" -like 'w2.cae-1-a1b2c3.cae-job.*') ($r | ConvertTo-Json -Compress)
    $w2 = "$($r.body.token)"
    $again = Rt-Redeem $nonce
    Check 'a second redemption of the same nonce is refused' ($again.status -eq 401 -and $again.body.code -eq 'unauthorized') ($again | ConvertTo-Json -Compress)
    $unknown = Rt-Redeem ('n1.' + ('0' * 64))
    Check 'an unknown nonce is refused alike' ($unknown.status -eq 401)
    Check 'the log tells a spent nonce from an unknown one' (Wait-Until -Seconds 5 { @(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -Pattern '"runtime":"redeem-refused","code":"nonce-spent"').Count -gt 0 })
    $mi = Rt-Api POST '/api/v1/verbs/my-items' @{} $w2
    Check 'the w2 is a worker credential: my-items answers' ($mi.status -eq 200) ($mi | ConvertTo-Json -Compress -Depth 5)
    $forged = $w2.Substring(0, $w2.LastIndexOf('.')) + '.' + ('0' * 64)
    Check 'a w2 with a forged MAC is refused' ((Rt-Api POST '/api/v1/verbs/my-items' @{} $forged).status -eq 401)
    $parts = $w2.Split('.'); $longer = "w2.$($parts[1]).$($parts[2]).$([long]$parts[3] + 86400).$($parts[4])"
    Check 'a w2 whose expiry was moved is refused' ((Rt-Api POST '/api/v1/verbs/my-items' @{} $longer).status -eq 401)
    $other = "w2.$($parts[1]).local.$($parts[3]).$($parts[4])"
    Check 'a w2 whose runtime was changed is refused' ((Rt-Api POST '/api/v1/verbs/my-items' @{} $other).status -eq 401)
    $vi = Rt-Api POST '/api/v1/verbs/get-item' @{ item = 1 } $w2
    Check 'a w2 cannot act on an item' ($vi.status -eq 403)
}

'runtime: a w2 expires with the execution' = {
    $r = Rt-Redeem (Rt-Nonce 'cae-2-d4e5f6' 3)
    Check 'redeemed' ($r.status -eq 200)
    Check 'the w2 answers before its expiry' ((Rt-Api POST '/api/v1/verbs/my-items' @{} "$($r.body.token)").status -eq 200)
    Start-Sleep -Seconds 5
    Check 'and is refused after it' ((Rt-Api POST '/api/v1/verbs/my-items' @{} "$($r.body.token)").status -eq 401)
    $late = Rt-Redeem (Rt-Nonce 'cae-2-d4e5f7' -5)
    Check 'a nonce whose token would already be expired is refused at redemption' ($late.status -eq 401)
}

'runtime: the runtime of a registration comes from the credential: a w1 cannot claim one, a w2 registers with its own' = {
    $tok = New-WorkerToken 'rtlocal1'
    $h = @{ Authorization = "Bearer $tok" }
    $resp = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/api/v1/events?name=rtlocal1&runtime=cae-job" -Headers $h -SkipHttpErrorCheck -TimeoutSec 10
    Check 'a w1 that claims runtime cae-job is refused' ([int]$resp.StatusCode -eq 403 -and "$($resp.Content)" -match 'runtime-not-trusted') "$([int]$resp.StatusCode) $($resp.Content)"
    $w2 = "$((Rt-Redeem (Rt-Nonce 'cae-3-0a0b0c')).body.token)"
    Start-RuntimeClient 'cae-3-0a0b0c' $w2
    try {
        $row = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'cae-3-0a0b0c' })
        Check 'the w2 worker is registered with its runtime' ($row.Count -eq 1 -and $row[0].runtime -eq 'cae-job' -and $row[0].connected) ($row | ConvertTo-Json -Compress)
        Start-OwnerClient 'rtlocal2'
        $row2 = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'rtlocal2' })
        Check 'a w1 worker is local' ($row2.Count -eq 1 -and $row2[0].runtime -eq 'local')
    } finally { Stop-OwnerClient 'cae-3-0a0b0c'; Stop-OwnerClient 'rtlocal2' }
}

'runtime: git-credential mints a one-repository contents-write token for the owner of a runtime worker, and for nobody else' = {
    $name = 'cae-4-1a2b3c'
    $w2 = "$((Rt-Redeem (Rt-Nonce $name)).body.token)"
    Start-RuntimeClient $name $w2
    Start-OwnerClient 'rtlocal4'
    try {
        $n = New-Item-Fake 'Runtime git credential' 'x' ($OwnerLabels + "worker:$name")
        $r = Rt-Own $name $n; CheckExit 'the runtime worker owns the item' $r 0
        $before = @((Get-FakeState).scopedMints).Count
        $g = Fo $name @('git-credential', '--item', $n)
        CheckExit 'git-credential answers' $g 0
        Check 'with a token, its expiry and the repository' ("$($g.token)" -ne '' -and "$($g.expires_at)" -ne '' -and $g.repository -eq 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' -and $g.username -eq 'x-access-token') ($g | ConvertTo-Json -Compress)
        $mints = @((Get-FakeState).scopedMints)
        $req = $(if ($mints.Count -gt $before) { $mints[-1] | ConvertFrom-Json -AsHashtable } else { @{} })
        Check 'GitHub was asked for this repository only, contents write only' ($mints.Count -eq $before + 1 -and @($req.repositories).Count -eq 1 -and $req.repositories[0] -eq 'cmdemo1-workorders' -and @($req.permissions.Keys).Count -eq 1 -and $req.permissions.contents -eq 'write') ($req | ConvertTo-Json -Compress)
        Check 'the token is not written to the gateway log' (@(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch "$($g.token)").Count -eq 0)
        $m = New-Item-Fake 'Local git credential' 'x' ($OwnerLabels + 'worker:rtlocal4')
        $r = Rt-Own 'rtlocal4' $m; CheckExit 'the local worker owns its item' $r 0
        $l = Fo 'rtlocal4' @('git-credential', '--item', $m)
        Check 'the owner token of a local worker is refused' ($l.exit -eq 30 -and $l.code -eq 'forbidden') ($l | ConvertTo-Json -Compress)
        $o = Fo $name @('git-credential', '--item', $m)
        Check 'a runtime owner cannot ask for another item' ($o.exit -ne 0) ($o | ConvertTo-Json -Compress)
        $wk = Rt-Api POST '/api/v1/verbs/git-credential' @{ item = $n } $w2
        Check 'the w2 itself (no item token) is refused' ($wk.status -eq 403)
        $r = Fo $name @('release', '--item', $n, '--reason', 'scenario: the item leaves the runtime worker'); CheckExit 'the runtime worker releases its item' $r 0
        $rel = Fo $name @('git-credential', '--item', $n)
        Check 'after the release its item token gets no git credential' ($rel.exit -eq 10 -and $rel.code -eq 'not-owner') ($rel | ConvertTo-Json -Compress)
        # a runtime worker runs one item per session, so the offer that is not accepted goes to a second one
        $name2 = 'cae-4-1a2b3d'; Start-RuntimeClient $name2 "$((Rt-Redeem (Rt-Nonce $name2)).body.token)"
        $k = New-Item-Fake 'Offered, not accepted' 'x' ($OwnerLabels + "worker:$name2")
        Check 'a second item is offered to a runtime worker' (Wait-Until -Seconds 40 { (Get-Assigned $name2 $k).Count -gt 0 })
        $na = Fo $name2 @('git-credential', '--item', $k)
        Check 'the item token of an offer not accepted is refused' ($na.exit -eq 10 -and $na.code -eq 'not-owner') ($na | ConvertTo-Json -Compress)
        Check 'no further token was minted for the refused calls' (@((Get-FakeState).scopedMints).Count -eq $before + 1)
    } finally { Stop-OwnerClient $name; Stop-OwnerClient 'rtlocal4'; if ($script:Workers.ContainsKey('cae-4-1a2b3d')) { Stop-OwnerClient 'cae-4-1a2b3d' } }
}
}

# ---- the adapter (gateway/Runtimes/, Plant.Runtimes.cs) against the fake ARM --------------------------------------------------------------
$RtLabels = @('factory worker', 'Auto Merge', 'runtime:cae-job')
function Rt-Arm { Fake 'arm' }
function Rt-Execs([int]$Item) { , @((Rt-Arm).executions | Where-Object { "$($_.item)" -eq "$Item" }) }
function Rt-Owner([int]$n) { $o = (Get-Plant).plant.owners; $p = $o.PSObject.Properties["$n"]; if ($p) { "$($p.Value)" } else { '' } }
function Rt-Status { (Get-Plant).runtimes.'cae-job' }
function Rt-Journal([int]$n, [string]$Pattern) { @((Get-FakeIssue $n).comments | Where-Object { $_.body -match $Pattern }).Count }
function Rt-Close([int]$n) {
    [void](Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/$n" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ state = 'closed' } | ConvertTo-Json) -ContentType 'application/json')
}
# The scenario's items are closed, every execution still running ends, and the runtime is healthy again: the next scenario starts clean.
function Rt-Cleanup([int[]]$Items, [string[]]$Clients = @()) {
    foreach ($n in $Items) { if ($n) { Rt-Close $n } }
    foreach ($c in $Clients) { Stop-OwnerClient $c }
    foreach ($e in @((Rt-Arm).executions | Where-Object { $_.status -in 'Running', 'Processing' })) { [void](Fake 'arm-exec' @{ name = $e.name; status = 'Succeeded' }) }
    [void](Wait-Until -Seconds 20 { (Rt-Status).running -eq 0 })
    [void](Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/runtimes/cae-job/reset" -Method POST -Headers @{ Authorization = 'Bearer test-token' })
}
# The execution's side: redeem the nonce of its environment and register with the w2, as fwrunner.sh does.
function Rt-Launch($Exec) {
    $r = Rt-Redeem "$($Exec.nonce)"
    if ($r.status -eq 200) { Start-RuntimeClient "$($Exec.worker)" "$($r.body.token)" }
    return $r
}

$RuntimeScenarios['runtime: an item labelled runtime:cae-job starts one execution with the job container and its values; the worker redeems, registers and is offered the item with the runtime window'] = {
    $n = 0; $name = ''
    try {
        $before = (Rt-Arm).starts
        $n = New-Item-Fake 'Runtime provision' 'x' ($RtLabels + 'factory test')
        Check 'an execution is started for the item' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -gt 0 })
        $e = (Rt-Execs $n)[0]; $name = "$($e.worker)"
        Check 'its worker name is cae-<item>-<6 hex>' ($name -match "^cae-$n-[0-9a-f]{6}$") $name
        Check 'it carries the item, the phase, the model profile and the gateway address' ($e.phase -eq 'Technical Design' -and $e.profile -eq 'testing' -and @($e.env | Where-Object { $_.name -eq 'FWORKER_GATEWAY_URL' -and $_.value -eq 'http://ca-test-fworker' }).Count -eq 1 -and @($e.env | Where-Object { $_.name -eq 'FWORKER_RUNTIME' -and $_.value -eq 'cae-job' }).Count -eq 1) ($e | ConvertTo-Json -Compress -Depth 5)
        Check 'the job container is kept: its image and its own variables, its FWORKER_ values replaced' ($e.image -eq 'fake.azurecr.io/fwrunner:1' -and @($e.env | Where-Object { $_.name -eq 'CLAUDE_CODE_USE_FOUNDRY' }).Count -eq 1 -and @($e.env | Where-Object { $_.name -eq 'FWORKER_NAME' }).Count -eq 1)
        Check 'the configured agent picks the job (jobs.codex) and is passed as FWRUNNER_AGENT' ($e.job -eq 'caj-test' -and @($e.env | Where-Object { $_.name -eq 'FWRUNNER_AGENT' -and $_.value -eq 'codex' }).Count -eq 1) ($e | ConvertTo-Json -Compress -Depth 5)
        Check 'the environment holds a nonce, no credential' ("$($e.nonce)" -like 'n1.*' -and -not (($e.env | ConvertTo-Json -Compress) -match '"w[12]\.|"i1\.'))
        Check 'the nonce is not in the gateway log' (@(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch "$($e.nonce)").Count -eq 0)
        $st = Rt-Status
        Check 'status: the execution runs and counts against today' ($st.running -ge 1 -and $st.today -ge 1 -and @($st.executions | Where-Object { $_.worker -eq $name -and $_.item -eq $n }).Count -eq 1) ($st | ConvertTo-Json -Compress -Depth 5)
        $r = Rt-Launch $e
        Check 'the execution redeems its nonce' ($r.status -eq 200 -and $r.body.name -eq $name)
        Check 'a second redemption of that nonce is refused' ((Rt-Redeem "$($e.nonce)").status -eq 401)
        Check 'the worker is offered the item with the runtime window' (Wait-Until -Seconds 20 { (Get-Assigned $name $n).Count -gt 0 })
        Check 'ackBySeconds is runtimes.caeJob.ackSeconds' ((Get-Assigned $name $n)[-1].ackBySeconds -eq 15) ((Get-Assigned $name $n)[-1] | ConvertTo-Json -Compress)
        $r = Rt-Own $name $n; CheckExit 'it accepts and owns the item' $r 0
        $row = @((Get-Plant).plant.workers | Where-Object { $_.name -eq $name })
        Check 'status: the worker shows its runtime and execution' ($row.Count -eq 1 -and $row[0].runtime -eq 'cae-job' -and $row[0].execution -eq $e.name) ($row | ConvertTo-Json -Compress)
        $dash = Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/dashboard" -Headers @{ Authorization = 'Bearer test-token' }
        Check 'the dashboard JSON carries the runtimes block' ($dash.runtimes.'cae-job'.running -ge 1 -and (Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/dashboard").Content -match 'id="rtsec"')
        Start-Sleep -Seconds 5
        Check 'no second execution is started for the item' ((Rt-Arm).starts -eq $before + 1)
    } finally { Rt-Cleanup @($n) @($name) }
}

$RuntimeScenarios['runtime: a per-worker ack window; an offer a runtime worker lets lapse stops its execution, one that never registers is stopped, and the second failure parks runtime-failed'] = {
    $n = 0; $m = 0; $name = ''
    try {
        Start-OwnerClient 'rtlocal5'
        $m = New-Item-Fake 'Local window' 'x' ($OwnerLabels + 'worker:rtlocal5')
        Check 'a local worker is offered with the global window' (Wait-Until -Seconds 30 { (Get-Assigned 'rtlocal5' $m).Count -gt 0 })
        Check 'its ackBySeconds is the global 8' ((Get-Assigned 'rtlocal5' $m)[-1].ackBySeconds -eq 8)
        $n = New-Item-Fake 'Runtime lapse' 'x' $RtLabels
        Check 'an execution starts' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -gt 0 })
        $e1 = (Rt-Execs $n)[0]; $name = "$($e1.worker)"
        [void](Rt-Launch $e1)
        Check 'its worker is offered the item' (Wait-Until -Seconds 20 { (Get-Assigned $name $n).Count -gt 0 })
        Start-Sleep -Seconds 9
        Check 'still offered after the local window: its own window is longer' (@((Rt-Arm).executions | Where-Object { $_.name -eq $e1.name -and $_.status -eq 'Running' }).Count -eq 1)
        Check 'the lapsed offer stops the execution' (Wait-Until -Seconds 25 { @((Rt-Arm).executions | Where-Object { $_.name -eq $e1.name -and $_.status -eq 'Stopped' }).Count -eq 1 })
        Check 'and a second execution is started for the item' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -ge 2 })
        $e2 = (Rt-Execs $n)[-1]
        Check 'the second worker never registers: its execution is stopped after the window' (Wait-Until -Seconds 40 { @((Rt-Arm).executions | Where-Object { $_.name -eq $e2.name -and $_.status -eq 'Stopped' }).Count -eq 1 })
        Check 'two failed executions in the phase park the item runtime-failed' (Wait-Until -Seconds 30 { $s = Get-ItemState $n; $s.ContainsKey('park') -and $s.park.reason -eq 'runtime-failed' })
        Check 'the park is journalled' ((Rt-Journal $n 'plant event=parked ') -ge 1)
        $starts = (Rt-Arm).starts; Start-Sleep -Seconds 6
        Check 'no third execution is started' ((Rt-Arm).starts -eq $starts -and (Rt-Execs $n).Count -eq 2)
        Check 'status: the runtime counted an execution that never registered' ((Rt-Status).startFailuresInRow -ge 1)
    } finally { Rt-Cleanup @($n, $m) @($name, 'rtlocal5') }
}

$RuntimeScenarios['runtime: session.end maps to the execution exit: the worker ends, the execution succeeds and the runtime forgets it'] = {
    $n = 0; $name = ''
    try {
        $n = New-Item-Fake 'Runtime session end' 'x' $RtLabels
        Check 'an execution starts' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -gt 0 })
        $e = (Rt-Execs $n)[0]; $name = "$($e.worker)"; [void](Rt-Launch $e)
        $r = Rt-Own $name $n; CheckExit 'its worker owns the item' $r 0
        [void](Gh-As 'fake-operator' "issues/$n/labels" @{ labels = @('hold:owner') })
        $r = Fo $name @('release', '--item', $n, '--reason', 'scenario: the item is done for this execution'); CheckExit 'the item leaves the worker' $r 0
        Check 'the runtime worker is told session.end (one item per session for runtime workers)' (Wait-Until -Seconds 20 { @(Get-WorkerEvents $name | Where-Object { $_.event -eq 'session.end' }).Count -gt 0 })
        [void](Fake 'arm-exec' @{ worker = $name; status = 'Succeeded' })
        Check 'the execution exits and the runtime counts it succeeded' (Wait-Until -Seconds 15 { @((Rt-Status).last | Where-Object { $_.worker -eq $name -and $_.outcome -eq 'succeeded' }).Count -eq 1 }) ((Rt-Status).last | ConvertTo-Json -Compress)
        Check 'it no longer runs and its worker is gone from the plant' ((Rt-Status).running -eq 0 -and @((Get-Plant).plant.workers | Where-Object { $_.name -eq $name }).Count -eq 0)
    } finally { Rt-Cleanup @($n) @($name) }
}

$RuntimeScenarios['runtime: a failed execution: its item is taken back, its claim ends and a new execution is started'] = {
    $n = 0; $name = ''; $name2 = ''
    try {
        $n = New-Item-Fake 'Runtime take-back' 'x' $RtLabels
        Check 'an execution starts' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -gt 0 })
        $e = (Rt-Execs $n)[0]; $name = "$($e.worker)"; [void](Rt-Launch $e)
        $r = Rt-Own $name $n; CheckExit 'its worker owns the item' $r 0
        Check 'the plant names it owner' (Wait-Until -Seconds 10 { (Rt-Owner $n) -eq $name })
        [void](Fake 'arm-exec' @{ worker = $name; status = 'Failed' })
        Check 'the item is taken back from the failed execution' (Wait-Until -Seconds 20 { (Rt-Owner $n) -ne $name })
        Check 'its claim ends' (Wait-Until -Seconds 20 { -not (Get-ItemState $n).ContainsKey('claim') })
        Check 'the take-back is journalled' (Wait-Until -Seconds 20 { (Rt-Journal $n 'plant event=reassigned ') -ge 1 })
        Check 'a new execution is started for the item' (Wait-Until -Seconds 30 { @((Rt-Execs $n) | Where-Object { $_.worker -ne $name }).Count -ge 1 })
        $name2 = "$((Rt-Execs $n)[-1].worker)"
        Check 'with a new worker name' ($name2 -match "^cae-$n-[0-9a-f]{6}$" -and $name2 -ne $name)
        Check 'status: one failure counted for the item and phase' (@((Rt-Status).failures | Where-Object { $_.item -eq $n -and $_.count -eq 1 }).Count -eq 1)
        $wk = Rt-Api POST '/api/v1/verbs/my-items' @{} "$($script:Workers[$name].token)"
        Check 'the failed worker name is revoked' ($wk.status -eq 401) ($wk | ConvertTo-Json -Compress)
    } finally { Rt-Cleanup @($n) @($name, $name2) }
}

$RuntimeScenarios['runtime: the daily budget stops new executions; the item waits with runtime-budget'] = {
    $cfgPath = Join-Path $script:Work 'instance.test.json'; $orig = Get-Content -Raw $cfgPath
    $a = 0; $b = 0
    try {
        $cfg = $orig | ConvertFrom-Json -AsHashtable; $cfg.runtimes.caeJob.maxExecutionsPerDay = 1; $cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath
        Restart-Gateway
        Check 'after the start the budget is 1 and nothing ran today' ((Rt-Status).maxExecutionsPerDay -eq 1 -and (Rt-Status).today -eq 0) (Rt-Status | ConvertTo-Json -Compress -Depth 4)
        $a = New-Item-Fake 'Budget one' 'x' $RtLabels
        Check 'the first item starts an execution' (Wait-Until -Seconds 30 { (Rt-Execs $a).Count -eq 1 })
        $b = New-Item-Fake 'Budget two' 'x' $RtLabels
        Check 'the second item waits: the budget of the day is spent' (Wait-Until -Seconds 30 { @((Get-FakeIssue $b).comments | Where-Object { $_.body -match 'plant event=waiting ' -and $_.body -match 'runtime-budget' }).Count -ge 1 })
        Start-Sleep -Seconds 4
        Check 'and no execution is started for it' ((Rt-Execs $b).Count -eq 0 -and (Rt-Status).today -eq 1)
    } finally {
        Rt-Cleanup @($a, $b)
        Set-Content -Path $cfgPath -Value $orig -NoNewline; Restart-Gateway
    }
}

$RuntimeScenarios['runtime: a gateway restart re-lists the running executions and starts no second one for their items'] = {
    $n = 0
    try {
        $n = New-Item-Fake 'Runtime restart' 'x' $RtLabels
        Check 'an execution starts' (Wait-Until -Seconds 30 { (Rt-Execs $n).Count -eq 1 })
        $e = (Rt-Execs $n)[0]
        Start-Sleep -Seconds 9    # with the restart and the wait below, older than the window: the adopted execution counts from its adoption, not its start
        Restart-Gateway
        Check 'the new gateway re-lists the running execution' (Wait-Until -Seconds 15 { $s = Rt-Status; $s.relisted -and @($s.executions | Where-Object { $_.worker -eq $e.worker -and $_.item -eq $n -and $_.execution -eq $e.name }).Count -eq 1 }) (Rt-Status | ConvertTo-Json -Compress -Depth 5)
        Check 'and counts it against today' ((Rt-Status).today -ge 1)
        Start-Sleep -Seconds 6
        Check 'no second execution is started for the item' ((Rt-Execs $n).Count -eq 1)
        Check 'the adopted execution is not stopped while its worker reconnects (its window starts at adoption)' (@((Rt-Arm).executions | Where-Object { $_.name -eq $e.name -and $_.status -eq 'Running' }).Count -eq 1)
        $r = Rt-Launch $e
        Check 'the nonce of the old process is gone with it: the execution cannot redeem' ($r.status -eq 401)
    } finally { Rt-Cleanup @($n) }
}

# cloud-worker-runtimes.md 5.1: the baked caeJob applies only in tdd (or with no environment named); elsewhere the FACTORY_RUNTIME_* variables
# of that environment's gateway app switch it on, and only with a job and an identity.
$RuntimeScenarios['runtime: outside tdd the baked caeJob is off; the FACTORY_RUNTIME_ variables switch it on with a job and an identity'] = {
    $vars = 'FACTORY_ENVIRONMENT', 'FACTORY_RUNTIME_ENABLED', 'FACTORY_RUNTIME_AGENT', 'FACTORY_RUNTIME_JOB_CLAUDE', 'FACTORY_RUNTIME_JOB_CODEX', 'FACTORY_RUNTIME_IDENTITY_CLIENT_ID', 'FACTORY_RUNTIME_GATEWAY_URL', 'FACTORY_RUNTIME_MAX_CONCURRENT', 'FACTORY_RUNTIME_MAX_PER_DAY'
    $n = 0
    try {
        $env:FACTORY_ENVIRONMENT = 'tdd'; $env:FACTORY_RUNTIME_MAX_PER_DAY = '5'; Restart-Gateway
        Check 'in tdd a variable overrides the baked value' ((Rt-Status).enabled -eq $true -and (Rt-Status).maxExecutionsPerDay -eq 5) (Rt-Status | ConvertTo-Json -Compress -Depth 4)
        Remove-Item env:FACTORY_RUNTIME_MAX_PER_DAY
        $env:FACTORY_ENVIRONMENT = 'uat'; Restart-Gateway
        function Rt-On { $r = (Get-Plant).runtimes; $c = if ($r -and $r.PSObject.Properties['cae-job']) { $r.'cae-job' } else { $r }; [bool]($c -and $c.enabled -eq $true) }
        Check 'in uat the baked caeJob is off' (-not (Rt-On)) ((Get-Plant).runtimes | ConvertTo-Json -Compress -Depth 4)
        $env:FACTORY_RUNTIME_ENABLED = 'true'; $env:FACTORY_RUNTIME_JOB_CODEX = '/subscriptions/s1/resourceGroups/rg-test/providers/Microsoft.App/jobs/caj-test'; Restart-Gateway
        Check 'enabled with a job but no identity stays off' (-not (Rt-On)) ((Get-Plant).runtimes | ConvertTo-Json -Compress -Depth 4)
        $env:FACTORY_RUNTIME_IDENTITY_CLIENT_ID = 'test-client'; $env:FACTORY_RUNTIME_AGENT = 'codex'; $env:FACTORY_RUNTIME_GATEWAY_URL = 'http://ca-uat-fworker'
        $env:FACTORY_RUNTIME_MAX_CONCURRENT = '2'; $env:FACTORY_RUNTIME_MAX_PER_DAY = '7'; Restart-Gateway
        $s = Rt-Status
        Check 'with a job and an identity it is on, sized by the variables' ($s.enabled -eq $true -and $s.maxConcurrent -eq 2 -and $s.maxExecutionsPerDay -eq 7) ($s | ConvertTo-Json -Compress -Depth 4)
        $n = New-Item-Fake 'Runtime by variables' 'x' $RtLabels
        Check 'an execution is started with the gateway address of the variables' (Wait-Until -Seconds 30 { $e = Rt-Execs $n; $e.Count -gt 0 -and @($e[0].env | Where-Object { $_.name -eq 'FWORKER_GATEWAY_URL' -and $_.value -eq 'http://ca-uat-fworker' }).Count -eq 1 })
    } finally {
        Rt-Cleanup @($n)
        foreach ($v in $vars) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        Restart-Gateway
    }
}
