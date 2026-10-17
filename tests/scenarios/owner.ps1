# Tier 1 scenarios for owner mode (plant manager). Scripted workers register through the real client (subscribe --own), receive assignments,
# hold per-item tokens and call the real verbs. Run with FACTORY_OWNER_MODE=1 and a token secret (run.ps1 sets both).
$OwnerLabels = @('factory worker', 'Auto Merge')
$script:Workers = @{}

function New-WorkerToken([string]$Name) {
    $env:FACTORY_TOKEN_SECRET = $script:OwnerSecret
    $t = (& pwsh -NoProfile -File (Join-Path $script:Root 'plugin/scripts/factory.ps1') worker-token --name $Name) -join ''
    return $t.Trim()
}

# Starts a registered worker session: stdout of the client goes to a file the scenarios read.
function Start-OwnerClient([string]$Name, [string]$Type = 'persistent-local', [string]$Extra = '') {
    $dir = Join-Path $script:Work "tokens-$Name"; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $script:Work "worker-$Name.out"
    $tok = New-WorkerToken $Name
    $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN }
    $env:FACTORY_TOKEN_DIR = $dir; $env:FACTORY_WORKER_TOKEN = $tok
    $argList = @('-NoProfile', '-File', (Join-Path $script:Root 'plugin/scripts/factory.ps1'), 'subscribe', '--own', '--name', $Name, '--type', $Type) + @($Extra -split ' ' | Where-Object { $_ })
    $p = Start-Process pwsh -ArgumentList $argList -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work "worker-$Name.err")
    $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w
    $script:Procs += $p
    $script:Workers[$Name] = @{ proc = $p; dir = $dir; out = $out; token = $tok }
    [void](Wait-Until -Seconds 20 { @(Get-WorkerEvents $Name | Where-Object { $_.event -eq 'worker.registered' }).Count -gt 0 })
}
function Stop-OwnerClient([string]$Name) { try { Stop-Process -Id $script:Workers[$Name].proc.Id -Force } catch { } }
function Get-WorkerEvents([string]$Name) {
    $f = $script:Workers[$Name].out; if (-not (Test-Path $f)) { return @() }
    @(Get-Content $f | ForEach-Object { try { $_ | ConvertFrom-Json -AsHashtable } catch { $null } } | Where-Object { $_ })
}
function Get-Assigned([string]$Name, [int]$Item) { , @(Get-WorkerEvents $Name | Where-Object { $_.event -eq 'item.assigned' -and $_.item -eq $Item }) }
# A verb call as one worker: its token directory and its worker credential.
function Fo([string]$Name, [string[]]$FactoryArgs) {
    $w = $script:Workers[$Name]; $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN }
    $env:FACTORY_TOKEN_DIR = $w.dir; $env:FACTORY_WORKER_TOKEN = $w.token; $old.t = $env:FACTORY_TOKEN; $env:FACTORY_TOKEN = $w.token
    try { return (F $Name $FactoryArgs) } finally { $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w; $env:FACTORY_TOKEN = $old.t }
}
function Get-Journal([int]$n) { , @((Get-FakeIssue $n).comments | Where-Object { $_.body -match '<!-- plant event=' } | ForEach-Object { [regex]::Match($_.body, 'plant event=([\w-]+)').Groups[1].Value }) }
function Get-Plant { Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/status" -Headers @{ Authorization = 'Bearer test-token' } }

$OwnerScenarios = [ordered]@{

'owner: registration, directed assignment, token handling and the journal' = {
    Start-OwnerClient 'alice' 'persistent-local' '--capacity 5'
    $st = Get-Plant; Check 'the worker is registered' (@($st.plant.workers | Where-Object { $_.name -eq 'alice' -and $_.connected }).Count -eq 1)
    $n = New-Item-Fake 'Owned item' 'x' $OwnerLabels
    $got = Wait-Until -Seconds 40 { (Get-Assigned 'alice' $n).Count -gt 0 }
    Check 'the item is assigned to the connected worker' $got
    $ev = (Get-Assigned 'alice' $n)[0]
    Check 'the token never appears on the event stream' (-not ((Get-Content $script:Workers['alice'].out -Raw) -match 'i1\.'))
    Check 'the item token is in the token directory' (Test-Path (Join-Path $script:Workers['alice'].dir "$n.owner"))
    # a loaded runner can answer after the 4 s window: that offer is withdrawn (stale-assignment) and offered again; take the newest
    for ($try = 0; $try -lt 5; $try++) {
        $ev = (Get-Assigned 'alice' $n)[-1]
        $r = Fo 'alice' @('accept', '--item', $n, '--assignment', $ev.assignment)
        if ($r.exit -ne 11) { break }
        $seen = (Get-Assigned 'alice' $n).Count; [void](Wait-Until -Seconds 30 { (Get-Assigned 'alice' $n).Count -gt $seen })
    }
    CheckExit 'accept' $r 0
    Check 'the claim belongs to the worker as owner' ($r.kind -eq 'own-item' -and $r.assignment -eq $ev.assignment)
    $st = Get-Plant; Check 'the plant records the owner' (@($st.plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" -and $_.Value -eq 'alice' }).Count -eq 1)
    # (the gateway writes its own lines in order but not inside the accept: wait for them, as the slow-journal scenario below does)
    [void](Wait-Until -Seconds 30 { $j0 = Get-Journal $n; @(@('matched', 'offered', 'assigned') | Where-Object { $j0 -notcontains $_ }).Count -eq 0 })
    $j = Get-Journal $n
    Check 'journal: matched, offered, assigned, once each' (@(@('matched', 'offered', 'assigned') | Where-Object { $j -notcontains $_ }).Count -eq 0 -and (@($j | Group-Object | Where-Object Count -gt 1).Count -eq 0)) ($j -join ',')
    $all = (Get-FakeIssue $n).comments | ForEach-Object { $_.body }
    Check 'no credential in any comment' (-not (($all -join "`n") -match '\b[wi]1\.[A-Za-z0-9_.-]{20,}'))
    $w = Fo 'alice' @('my-items'); CheckExit 'my-items' $w 0; Check 'my-items lists the item' (@($w.items | Where-Object { $_.item -eq $n }).Count -eq 1)
    $mf = Fo 'alice' @('model-for', '--role', 'subagent', '--item', $n)
    Check 'model-for asks the gateway with the item token, not the worker credential (no refusal note, a model is chosen)' (-not (Pv $mf 'note') -and (Pv $mf 'model')) ($mf | ConvertTo-Json -Compress -Depth 3)
}

# Enhancement 13: the wait from the gateway's match to the session's accept is read back from the journal comments.
'metrics: an accepted owner item has its match-to-accept time from the journal' = {
    Start-OwnerClient 'met-a' 'persistent-local' '--capacity 5'
    $n = New-Item-Fake 'Metrics owner item' 'x' ($OwnerLabels + 'worker:met-a')
    Check 'offered' (Wait-Until -Seconds 40 { (Get-Assigned 'met-a' $n).Count -gt 0 })
    $r = Fo 'met-a' @('accept', '--item', $n, '--assignment', (Get-Assigned 'met-a' $n)[0].assignment); CheckExit 'accept' $r 0
    [void](Wait-Until -Seconds 30 { $j0 = Get-Journal $n; $j0 -contains 'matched' -and $j0 -contains 'offered' -and $j0 -contains 'assigned' })
    $a = Invoke-RestMethod "$(Get-GatewayBase)/api/v1/metrics?since=1h&fresh=1" -Headers @{ Authorization = 'Bearer test-token' }
    $it = @($a.items | Where-Object { $_.item -eq $n })
    Check 'match, offer and accept times and the wait between them' ($it.Count -eq 1 -and $it[0].times.matched -and $it[0].times.offered -and $it[0].times.accepted -and $it[0].durations.matchToAccept -ge 0) ($a | ConvertTo-Json -Depth 6 -Compress)
    Check 'the aggregate counts it' ($a.aggregate.matchToAccept.count -ge 1)
    Stop-OwnerClient 'met-a'
}

'owner: tokens are scoped to one item, one role, one purpose [full]' = {
    $a = New-Item-Fake 'Scope A' 'x' $OwnerLabels; $b = New-Item-Fake 'Scope B' 'x' $OwnerLabels
    [void](Wait-Until -Seconds 40 { (Get-Assigned 'alice' $a).Count -gt 0 -and (Get-Assigned 'alice' $b).Count -gt 0 })
    $ea = (Get-Assigned 'alice' $a)[0]
    $r = Fo 'alice' @('accept', '--item', $a, '--assignment', $ea.assignment); CheckExit 'accept A' $r 0
    # use A's token against B
    Copy-Item (Join-Path $script:Workers['alice'].dir "$a.owner") (Join-Path $script:Workers['alice'].dir "$b.owner") -Force
    $r = Fo 'alice' @('get-item', '--item', $b); CheckExit 'item A token refused for item B' $r 30 'forbidden'
    $r = Fo 'alice' @('approve-pr', '--item', $a, '--pr', 1, '--text-file', (TmpFile 'x.md' "x`nAPPROVE")); CheckExit 'owner role cannot approve' $r 30 'forbidden'
    $r = Fo 'alice' @('sync-board'); CheckExit 'a worker session cannot run admin verbs' $r 30 'forbidden'
    Remove-Item (Join-Path $script:Workers['alice'].dir "$a.owner") -Force; Remove-Item (Join-Path $script:Workers['alice'].dir "$b.owner") -Force
    $r = Fo 'alice' @('get-item', '--item', $a); Check 'a worker credential alone cannot act on an item' ($r.exit -eq 30) "exit $($r.exit)"
    $r = Fo 'alice' @('release', '--item', $a); Check 'release without the item token refused' ($r.exit -eq 30)
}

'owner: the owner publishes the demo video with its item token; another item and a worker credential are refused [full]' = {
    Start-OwnerClient 'vida' 'persistent-local' '--capacity 5'
    $n = New-Item-Fake 'Owner video' 'x' ($OwnerLabels + 'video') 'Functional Testing'; $b = New-Item-Fake 'Other video' 'x' ($OwnerLabels + 'video') 'Functional Testing'
    [void](Wait-Until -Seconds 40 { (Get-Assigned 'vida' $n).Count -gt 0 })
    $ev = (Get-Assigned 'vida' $n)[0]
    $r = Fo 'vida' @('accept', '--item', $n, '--assignment', $ev.assignment); CheckExit 'accept' $r 0
    $mp4 = New-TestMp4 'owner-demo.mp4' 2048
    $r = Fo 'vida' @('publish-demo', '--item', $n, '--file', $mp4); CheckExit 'the owner publishes' $r 0
    Check 'the asset is on the release of its item' ($r.release -eq "demo-$n" -and $r.size -eq 2048) ($r | ConvertTo-Json -Compress)
    $tok = (Get-Content -Raw (Join-Path $script:Workers['vida'].dir "$n.owner")).Trim()
    $w = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/api/v1/demo/$b" -Method POST -InFile $mp4 -ContentType 'video/mp4' -Headers @{ Authorization = "Bearer $tok" } -SkipHttpErrorCheck
    Check "the item token is refused for another item's release" ([int]$w.StatusCode -eq 403 -and ($w.Content | ConvertFrom-Json).code -eq 'forbidden') "$([int]$w.StatusCode) $($w.Content)"
    $w = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/api/v1/demo/$n" -Method POST -InFile $mp4 -ContentType 'video/mp4' -Headers @{ Authorization = "Bearer $($script:Workers['vida'].token)" } -SkipHttpErrorCheck
    Check 'a worker credential (not the item owner) is refused' ([int]$w.StatusCode -eq 403) "$([int]$w.StatusCode) $($w.Content)"
    $rel = try { Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/releases/tags/demo-$b" } catch { $null }
    Check 'no release was made for the other item' ($null -eq $rel)
    Stop-OwnerClient 'vida'
}

'owner: the owner continues from Technical Design into Development without a new assignment [full]' = {
    [void](Fo 'alice' @('my-items'))   # alice let offers of earlier scenarios lapse (cool-down, issue 31): a verb shows it is answering again
    $n = New-Item-Fake 'Continue' 'x' $OwnerLabels
    [void](Wait-Until -Seconds 40 { (Get-Assigned 'alice' $n).Count -gt 0 })
    $ev = (Get-Assigned 'alice' $n)[0]
    $r = Fo 'alice' @('accept', '--item', $n, '--assignment', $ev.assignment); CheckExit 'accept' $r 0
    $sec = "## Technical Design`n`n<!-- aisf:docs-only -->`n- change as described.`n"
    $r = Fo 'alice' @('append-body', '--item', $n, '--column', 'Technical Design', '--content-file', (TmpFile "otd$n.md" $sec)); CheckExit 'append' $r 0
    $r = Fo 'alice' @('record-review', '--item', $n, '--column', 'Technical Design', '--role', 'reviewer', '--text-file', (TmpFile "orv$n.md" "ok`nREVIEW: COMPLETE")); CheckExit 'record-review' $r 0
    $c = Fo 'alice' @('complete', '--item', $n, '--column', 'Technical Design', '--review-ref', $r.review_ref, '--comment', 'REVIEW: COMPLETE - design done'); CheckExit 'complete' $c 0
    Check 'the answer says continue, with the next column' ($c.continue -eq $true -and $c.next_column -eq 'Development') ($c | ConvertTo-Json -Compress -Depth 4)
    Check 'the item moved to Development' ((Get-FakeIssue $n).column -eq 'Development')
    $r2 = Fo 'alice' @('get-item', '--item', $n); CheckExit 'the same token still works in the next column' $r2 0
    Start-Sleep -Seconds 6
    Check 'no second assignment was made' ((Get-Assigned 'alice' $n).Count -eq 1) "$((Get-Assigned 'alice' $n).Count)"
    $wt = Fo 'alice' @('wait-event', '--item', $n, '--timeout', '2')
    Check 'wait-event answers (events or a timeout)' ($wt.exit -in 0, 21) "exit $($wt.exit)"
}

'owner: an assignment nobody accepts is offered to the next worker [full]' = {
    Start-OwnerClient 'bob'
    Stop-OwnerClient 'alice'
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'alice' -and $_.connected }).Count -eq 0 })
    $n = New-Item-Fake 'Ack timeout' 'x' $OwnerLabels
    [void](Wait-Until -Seconds 40 { (Get-Assigned 'bob' $n).Count -gt 0 })
    Check 'the only connected worker is offered the item' ((Get-Assigned 'bob' $n).Count -ge 1)
    Start-OwnerClient 'carol'
    $moved = Wait-Until -Seconds 40 { (Get-Assigned 'carol' $n).Count -gt 0 }
    Check 'after the ack timeout the other worker is offered it' $moved
    $jr = Wait-Until -Seconds 20 { (Get-Journal $n) -contains 'reassigned' }; $j = Get-Journal $n; Check 'journal: reassigned' $jr ($j -join ',')
    $ev = (Get-Assigned 'carol' $n)[0]
    $r = Fo 'carol' @('accept', '--item', $n, '--assignment', $ev.assignment); CheckExit 'carol accepts' $r 0
}

'owner: a worker:<name> label pins the item [full]' = {
    $n = New-Item-Fake 'Pinned' 'x' ($OwnerLabels + 'worker:bob')
    $got = Wait-Until -Seconds 40 { (Get-Assigned 'bob' $n).Count -gt 0 }
    Check 'the pinned worker gets it' $got
    Check 'the other worker does not' ((Get-Assigned 'carol' $n).Count -eq 0)
}

'owner: a draining worker receives nothing new [full]' = {
    Start-OwnerClient 'dave' 'persistent-local' '--capacity 5'
    $null = Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/workers/bob/drain" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    $n = New-Item-Fake 'After drain' 'x' $OwnerLabels
    $got = Wait-Until -Seconds 40 { (Get-Assigned 'dave' $n).Count -gt 0 }
    Check 'the item goes to the worker that is not draining' $got
    Check 'a full worker (capacity 1, one item owned) is not offered a second' ((Get-Assigned 'carol' $n).Count -eq 0)
    Check 'the draining worker was not offered it' ((Get-Assigned 'bob' $n).Count -eq 0)
}

'owner: dashboard: a credential issued from the page connects a hand-made cloud session that then shows up [full]' = {
    $h = @{ Authorization = 'Bearer test-token' }; $base = "http://127.0.0.1:$($script:ApiPort)"
    $page = Invoke-WebRequest "$base/dashboard"; Check 'the dashboard page is served' ($page.StatusCode -eq 200 -and $page.Content -match 'Factory workers')
    $d = Invoke-RestMethod "$base/api/v1/dashboard" -Headers $h; Check 'dashboard data names the environment' ($d.environment -eq 'tdd' -and $d.url -match '^http')
    $denied = try { Invoke-RestMethod "$base/api/v1/dashboard" -Headers @{ Authorization = 'Bearer wrong' }; $false } catch { $true }; Check 'dashboard data needs the operator token' $denied
    $c = Invoke-RestMethod "$base/api/v1/workers/ec2-cloud/credential" -Method POST -Headers $h
    Check 'a credential is issued for the name' ($c.ok -and $c.token -match '^w1\.ec2-cloud\.')
    $bad = try { Invoke-RestMethod "$base/api/v1/workers/bad%20name/credential" -Method POST -Headers $h; $false } catch { $true }; Check 'a bad name is refused' $bad
    $dir = Join-Path $script:Work 'tokens-ec2-cloud'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $script:Work 'worker-ec2-cloud.out'
    $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN }; $env:FACTORY_TOKEN_DIR = $dir; $env:FACTORY_WORKER_TOKEN = $c.token
    $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $script:Root 'plugin/scripts/factory.ps1'), 'subscribe', '--own', '--name', 'ec2-cloud', '--type', 'claude-cloud') -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work 'worker-ec2-cloud.err')
    $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w; $script:Procs += $p
    $seen = Wait-Until -Seconds 20 { @((Invoke-RestMethod "$base/api/v1/dashboard" -Headers $h).plant.workers | Where-Object { $_.name -eq 'ec2-cloud' -and $_.connected -and $_.type -eq 'claude-cloud' }).Count -eq 1 }
    Check 'the cloud session appears on the dashboard as connected' $seen
    $forged = try { Invoke-RestMethod "$base/api/v1/events?name=ec2-cloud&type=claude-cloud" -Headers @{ Authorization = 'Bearer w1.ec2-cloud.0000' } -TimeoutSec 3; $false } catch { $true }; Check 'a forged credential cannot register' $forged
    # the client would otherwise stay connected for the rest of the suite and offer a free owner slot to later scenarios (work intake)
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Check 'the cloud session is gone once its client stops' (Wait-Until -Seconds 20 { @((Invoke-RestMethod "$base/api/v1/dashboard" -Headers $h).plant.workers | Where-Object { $_.name -eq 'ec2-cloud' -and $_.connected }).Count -eq 0 })
}

'owner: a refused credential is visible on the event stream, not only on stderr [full]' = {
    $dir = Join-Path $script:Work 'tokens-refused'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $script:Work 'worker-refused.out'
    $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN }
    $env:FACTORY_TOKEN_DIR = $dir; $env:FACTORY_WORKER_TOKEN = 'w1.nobody.0000000000000000000000000000000000000000'
    $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $script:Root 'plugin/scripts/factory.ps1'), 'subscribe', '--own', '--name', 'refused', '--type', 'persistent-local') -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work 'worker-refused.err')
    $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w
    $script:Procs += $p
    # worker-messaging.md 4.6 (3): a refusal (400, 401, 403, 409) is printed once as stream.refused and ends the client with the body's exit; it is not retried
    $got = Wait-Until -Seconds 25 { (Test-Path $out) -and ((Get-Content $out -Raw) -match '"event":"stream\.refused"') }
    Check 'a refused credential shows up as a stream.refused event on stdout' $got ((Get-Content $out -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')
    $evs = @(Get-Content $out | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'stream.refused' })
    Check 'the event names the refusal, once' ($evs.Count -eq 1 -and "$($evs[0].reason)" -match '401' -and $evs[0].code -eq 'unauthorized' -and $evs[0].exit -eq 30) (($evs | ConvertTo-Json -Compress))
    Check 'the client exits 30 instead of retrying' ($p.WaitForExit(15000) -and $p.ExitCode -eq 30) "exit $(if ($p.HasExited) { $p.ExitCode } else { 'still running' })"
    try { Stop-Process -Id $p.Id -Force } catch { }
}

'owner: the operator sets a worker capacity, a worker cannot, and it survives a reconnect [full]' = {
    Start-OwnerClient 'cap1' 'claude-cloud' '--capacity 1'
    $base = "http://127.0.0.1:$($script:ApiPort)"
    $r = Invoke-WebRequest "$base/api/v1/workers/cap1/capacity?value=10" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck
    Check 'the operator may set it' ($r.StatusCode -eq 200 -and ($r.Content | ConvertFrom-Json).capacity -eq 10) $r.Content
    $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'cap1' })[0]
    Check 'the plant shows capacity 10' ($w.capacity -eq 10) ($w | ConvertTo-Json -Compress)
    $bad = Invoke-WebRequest "$base/api/v1/workers/cap1/capacity?value=99" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck
    Check 'a value outside 1 to 20 is refused' ($bad.StatusCode -eq 400) $bad.Content
    $own = Invoke-WebRequest "$base/api/v1/workers/cap1/capacity?value=5" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers['cap1'].token)" } -SkipHttpErrorCheck
    Check 'the worker itself may not change it' ($own.StatusCode -eq 403) $own.Content
    Stop-OwnerClient 'cap1'
    Start-OwnerClient 'cap1' 'claude-cloud' '--capacity 1'
    $w2 = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'cap1' })[0]
    Check 'a reconnect with --capacity 1 keeps the operator value' ($w2.capacity -eq 10) ($w2 | ConvertTo-Json -Compress)
}

'owner: update-pr replaces the body of the item''s own open pull request, and of no other [full]' = {
    # pinned to a session that does not exist, so the plant offers these items to nobody while the verbs are called
    $lab = @('factory worker', 'Auto Merge', 'worker:nobody-here')
    $n = New-Item-Fake 'Body A' 'x' $lab; $m = New-Item-Fake 'Body B' 'x' $lab
    Do-TechnicalDesign $n; $pr = Do-Development $n
    Do-TechnicalDesign $m; $prM = Do-Development $m
    Check 'open-pr wrote the body with the reference to the item' ((Get-FakePr $pr).body -eq "change`n`nRefs #$n") "$((Get-FakePr $pr).body)"
    $own = Msg-ItemToken $n 'owner' 'alice'; $insp = Msg-ItemToken $n 'inspector' 'alice'
    $call = { param($Tok, $Body) $r0 = Msg-Verb 'update-pr' $Tok $Body; $j = Msg-Json $r0; $j.status = [int]$r0.StatusCode; $j }
    $r = & $call $own @{ item = $n; body = "corrected text`n" }
    Check 'the owner''s item token replaces the body; the reference to the item is kept' ($r.status -eq 200 -and $r.exit -eq 0 -and $r.pullRequest.number -eq $pr -and (Get-FakePr $pr).body -eq "corrected text`n`nRefs #$n") "$($r | ConvertTo-Json -Compress -Depth 4) $((Get-FakePr $pr).body)"
    $r = F 'w1' @('update-pr', '--item', $n, '--pr', $pr, '--body-file', (TmpFile "upr$n.md" "from a file`n`nRefs #$n"))
    CheckExit 'the client verb with --body-file and the pull request named' $r 0
    Check 'a body that already ends with the reference is not given a second one' ((Get-FakePr $pr).body -eq "from a file`n`nRefs #$n") "$((Get-FakePr $pr).body)"
    $r = & $call $own @{ item = $n; pr = $prM; body = 'not mine' }
    Check 'another item''s pull request is refused (pr-not-own) and stays as it was' ($r.exit -eq 10 -and $r.code -eq 'pr-not-own' -and (Get-FakePr $prM).body -eq "change`n`nRefs #$m") "$($r | ConvertTo-Json -Compress) $((Get-FakePr $prM).body)"
    $r = & $call $own @{ item = $m; body = 'wrong item' }
    Check 'the token of item A cannot name item B (403)' ($r.status -eq 403 -and (Get-FakePr $prM).body -eq "change`n`nRefs #$m") "$($r | ConvertTo-Json -Compress)"
    $r = & $call $insp @{ item = $n; body = 'inspector' }
    Check 'the inspector role is refused (403), as for open-pr' ($r.status -eq 403) "$($r | ConvertTo-Json -Compress)"
    $r = & $call (Msg-Token 'alice') @{ item = $n; body = 'worker credential' }
    Check 'a worker credential without the item token is refused (403)' ($r.status -eq 403) "$($r | ConvertTo-Json -Compress)"
    $r = & $call $own @{ item = $n; body = '   ' }
    Check 'an empty body is a usage error' ($r.exit -eq 2 -and $r.code -eq 'usage') "$($r | ConvertTo-Json -Compress)"
    Check 'none of the refusals changed the body' ((Get-FakePr $pr).body -eq "from a file`n`nRefs #$n") "$((Get-FakePr $pr).body)"
    $td = New-Item-Fake 'Body C' 'x' $lab; $r = & $call (Msg-ItemToken $td 'owner' 'alice') @{ item = $td; body = 'too early' }
    Check 'outside Development the body is not changed (wrong-column)' ($r.exit -eq 10 -and $r.code -eq 'wrong-column') "$($r | ConvertTo-Json -Compress)"
    Fake 'pr' @{ number = $pr; merged = $true } | Out-Null
    Check 'the pull request is merged' ((Get-FakePr $pr).merged -eq $true)
    $r = & $call $own @{ item = $n; pr = $pr; body = 'after the merge' }
    # (pr-not-open while the item is still in Development; wrong-column once the sweep has picked the merge up and moved the card on)
    Check 'a merged pull request is refused (pr-not-open), named or not' ($r.exit -eq 10 -and $r.code -in 'pr-not-open', 'wrong-column' -and (& $call $own @{ item = $n; body = 'after the merge' }).code -in 'pr-not-open', 'wrong-column' -and (Get-FakePr $pr).body -eq "from a file`n`nRefs #$n") "$($r | ConvertTo-Json -Compress)"
}

'msg: messaging and the supervisor are off by default' = {
    $base = "http://127.0.0.1:$($script:ApiPort)"
    $c = Msg-Api 'POST' '/api/v1/workers/alice/credential?role=manager'
    Check 'the credential endpoint refuses the supervisor role while it is off' ($c.StatusCode -eq 403 -and (Msg-Json $c).code -eq 'manager-disabled') "$($c.StatusCode) $($c.Content)"
    $m1 = "m1.supervisor.1.$(Msg-Mac 'manager:supervisor:1')"
    $st = Invoke-WebRequest "$base/api/v1/status" -Headers @{ Authorization = "Bearer $m1" } -SkipHttpErrorCheck -TimeoutSec 5
    Check 'a supervisor token is unauthorized while the supervisor is off' ($st.StatusCode -eq 401) "$($st.StatusCode)"
    $wt = F 'msgoff' @('worker-token', '--role', 'manager', '--name', 'supervisor')
    CheckExit 'the client refuses the supervisor role while it is off' $wt 30 'manager-disabled'
    Start-OwnerClient 'msgoff'
    $kinds = @(Get-WorkerEvents 'msgoff' | ForEach-Object { $_.event })
    Check 'the worker stream opened' ($kinds -contains 'worker.registered') ($kinds -join ',')
    Check 'the worker stream carries no message or peers events' (@($kinds | Where-Object { $_ -match '^(message\.|peers\.)' }).Count -eq 0) ($kinds -join ',')
    $reg = @(Get-WorkerEvents 'msgoff' | Where-Object { $_.event -eq 'worker.registered' })[0]
    Check 'worker.registered carries no epoch and no messaging flag' (-not $reg.ContainsKey('epoch') -and -not $reg.ContainsKey('messaging')) ($reg | ConvertTo-Json -Compress)
    $pr = Invoke-WebRequest "$base/api/v1/presence" -Method POST -Headers @{ Authorization = "Bearer $(New-WorkerToken 'msgoff')" } -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 5
    Check 'presence answers 403 messaging-disabled' ($pr.StatusCode -eq 403 -and (Msg-Json $pr).code -eq 'messaging-disabled') "$($pr.StatusCode) $($pr.Content)"
    $td = Invoke-WebRequest "$base/api/v1/_test/deliver" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -Body '{"to":"msgoff"}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 5
    Check 'the test delivery seam does not exist' ($td.StatusCode -eq 404) "$($td.StatusCode)"
    # step 3: every peer verb and endpoint answers messaging-disabled, exit 30; nothing is queued, stored or logged
    foreach ($v in @(@('send', '--to', 'bob', '--text', 'hello'), @('peers'), @('send', '--all', '--text', 'hello'), @('inbox'), @('ack', '--ids', 'm-00000000-0001'), @('ask', '--text', 'a question'), @('presence'), @('message-status', '--id', 'm-00000000-0001'))) {
        $r = Fo 'msgoff' $v
        Check "the $($v[0]) verb answers messaging-disabled, exit 30" ($r.exit -eq 30 -and $r.code -eq 'messaging-disabled') ($r | ConvertTo-Json -Compress)
    }
    foreach ($e in @(@('GET', '/api/v1/messages'), @('GET', '/api/v1/messages?to=operator&unread=1'), @('POST', '/api/v1/messages/read'), @('GET', '/api/v1/peers'), @('GET', '/api/v1/inbox'), @('GET', '/api/v1/messages/m-00000000-0001'), @('POST', '/api/v1/messages/ack'), @('GET', '/api/v1/questions'), @('POST', '/api/v1/questions/m-00000000-0001/answer'),
        @('GET', '/api/v1/digest'), @('POST', '/api/v1/supervisor/patrol-ack'), @('POST', '/api/v1/supervisor/patrol?minutes=10'), @('POST', '/api/v1/supervisor/budget?extra=1'), @('POST', '/api/v1/messaging/enable'), @('POST', '/api/v1/messaging/disable'))) {
        $x = Invoke-WebRequest "$base$($e[1])" -Method $e[0] -Headers @{ Authorization = 'Bearer test-token' } -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 5
        Check "$($e[0]) $($e[1]) answers 403 messaging-disabled" ($x.StatusCode -eq 403 -and (Msg-Json $x).code -eq 'messaging-disabled') "$($x.StatusCode) $($x.Content)"
    }
    $mo = Invoke-WebRequest "$base/api/v1/workers/msgoff/messaging?value=mute" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck -TimeoutSec 5
    Check 'a messaging mode is no action of a worker here: 404, as any unknown action' ($mo.StatusCode -eq 404) "$($mo.StatusCode)"
    $wt = Invoke-WebRequest "$base/api/v1/wait?item=99991&messages=1&timeout=1" -Headers @{ Authorization = "Bearer $(Msg-ItemToken 99991 'owner' 'msgoff')" } -SkipHttpErrorCheck -TimeoutSec 10
    Check 'a wait for messages answers 403 messaging-disabled' ($wt.StatusCode -eq 403 -and (Msg-Json $wt).code -eq 'messaging-disabled') "$($wt.StatusCode) $($wt.Content)"
    $wl = F 'msgoff' @('wait-event', '--item', '99991', '--timeout', '1')
    Check 'and a wait without messages is what it was: the old answer, nothing refused' ($wl.exit -eq 21 -and $wl.timeout -eq $true -and -not $wl.ContainsKey('messages')) ($wl | ConvertTo-Json -Compress)
    # step 5: with messaging off the verbs that write text are what they were: no marker is reserved, and from_message is not looked at
    $offItem = New-Item-Fake 'Messaging off' 'x' @()
    $oc = F 'msgoff' @('comment', '--item', $offItem, '--body', 'the words aisf:assumption are ordinary text here', '--from-message', 'm-00000000-0001')
    Check 'a comment that names the marker, with a from-message, is posted as it is' ($oc.exit -eq 0 -and @((Get-FakeIssue $offItem).comments | Where-Object { $_.body -match 'the words aisf:assumption are ordinary text here' -and $_.body -notmatch '<!-- aisf:assumption' }).Count -eq 1) ($oc | ConvertTo-Json -Compress)
    $sb = F 'msgoff' @('sync-board', '--dry', 'true')
    Check 'the sweep answers as before, and lists what it owns for a gateway that asks' ($sb.exit -eq 0 -and $sb.ContainsKey('owners') -and $sb.ContainsKey('owned') -and $sb.ContainsKey('settling')) ($sb.Keys -join ',')
    # with messaging off nobody guards the marker, so it marks nothing: get-item labels no block and the inspector gets the whole body
    $ov = To-Verdict 0 0 -HoldMerge
    $ob = "<!-- aisf:assumption source=m-00000000-0001 from=alice -->`n> a closed block`n<!-- /aisf:assumption -->`n<!-- aisf:assumption source=m-00000000-0002 from=alice -->`nACCEPTANCE-AFTER-AN-OPEN-MARKER"
    $oa = F 'msgoff' @('append-body', '--item', $ov.n, '--content-file', (TmpFile "off$($ov.n).md" $ob)); CheckExit 'a body with the markers is appended as it is' $oa 0
    $og = F 'msgoff' @('get-item', '--item', $ov.n); $oi = F 'msgoff' @('inspect-facts', '--item', $ov.n)
    Check 'get-item lists no derived block and its note is the old one' ($og.exit -eq 0 -and -not $og.ContainsKey('derived_blocks') -and "$($og.note)" -notmatch 'aisf' -and "$($og.body)" -match 'a closed block') ($og.note)
    Check 'inspect-facts gives the inspector the body exactly as get-item has it' ($oi.exit -eq 0 -and "$($oi.item.body)" -ceq "$($og.body)" -and "$($oi.item.body)" -match 'a closed block' -and "$($oi.item.body)" -match 'ACCEPTANCE-AFTER-AN-OPEN-MARKER') "$($oi.item.body)"
    Check 'the status has no messaging or manager block' (-not ((Get-Plant).PSObject.Properties.Name -contains 'messaging') -and -not ((Get-Plant).PSObject.Properties.Name -contains 'manager'))
    # steps 7 and 9: the supervisor client and the dashboard with messaging off
    $offDash = Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/dashboard" -Headers @{ Authorization = 'Bearer test-token' }
    Check 'the dashboard JSON has no messaging or manager block either' (-not ($offDash.PSObject.Properties.Name -contains 'messaging') -and -not ($offDash.PSObject.Properties.Name -contains 'manager'))
    $offMint = Msg-Api 'POST' '/api/v1/workers/supervisor/credential?role=manager'
    Check 'no supervisor credential is minted for a supervisor prompt: 403 manager-disabled' ($offMint.StatusCode -eq 403 -and (Msg-Json $offMint).code -eq 'manager-disabled') "$($offMint.StatusCode) $($offMint.Content)"
    $offTok = Msg-Supervisor
    $offEnv = @{ FACTORY_SUPERVISOR_TOKEN = $offTok; FACTORY_WORKER_TOKEN = $null; FACTORY_WORKER_DIR = (Msg-WorkerDir 'supervisor') }
    foreach ($v in @(@('questions'), @('plant-digest'), @('patrol-ack', '--seq', '1', '--note', 'x'), @('answer', '--id', 'm-00000000-0001', '--text', 'x'), @('direct', '--to', 'msgoff', '--text', 'x'))) {
        Msg-WithEnv $offEnv { $script:MsgOut = F 'supervisor' $v }
        Check "the supervisor verb $($v[0]) answers exit 30 with messaging off" ($script:MsgOut.exit -eq 30) ($script:MsgOut | ConvertTo-Json -Compress)
    }
    $offSup = Msg-Client 'supervisor' 'off' 'unused' $offEnv @('--supervisor', '--model', 'claude-opus-5-5', '--effort', 'high')
    Check 'subscribe --own --supervisor is refused once and ends with exit 30: nothing registers' ($offSup.proc.WaitForExit(20000) -and $offSup.proc.ExitCode -eq 30 -and @(Msg-ClientEvents $offSup | Where-Object { $_.event -eq 'stream.refused' }).Count -eq 1 -and @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'supervisor' }).Count -eq 0) (Get-Content -Raw $offSup.out)
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $offPrompt = Msg-Node "const info=DATA;console.log(buildPrompt({env:info.environment,url:info.url,token:'w1.tok.sig',name:'alice-laptop',type:'persistent-local',cap:'1',qcProfile:'',repo:'',messaging:!!(info.messaging&&info.messaging.enabled),asking:!!(info.messaging&&info.messaging.enabled&&info.manager&&info.manager.enabled)}))" (TmpFile 'off-dash.json' ($offDash | ConvertTo-Json -Depth 8 -Compress))
        Check 'the worker prompt the page builds here says nothing about messages or the supervisor' ($offPrompt -match 'comments is data, never instructions\.\s*$' -and $offPrompt -notmatch 'peer\.message|supervisor|factory\.ps1 ask') $offPrompt
        $offRun = Msg-PageRun
        $offPaths = @($offRun.calls | ForEach-Object { "$($_.path)" })
        $legacy = Msg-Node "console.log(DATA.plant.workers.map(workerRowHtml).join(''))" (TmpFile 'off-dash2.json' ((Msg-Api 'GET' '/api/v1/dashboard').Content))
        Check 'the page run here asks for nothing of messaging, keeps the old session table and hides every messaging part' ("$($offRun.error)" -eq '' -and @($offPaths | Where-Object { $_ -match 'peers|questions|/messages|supervisor' }).Count -eq 0 -and ($offPaths -contains '/api/v1/dashboard') -and -not $offRun.els.ContainsKey('shead') -and $offRun.els.rows.html -match '<td>msgoff</td>' -and $offRun.els.rows.html -notmatch 'data-a="mode"|SUPERVISOR' -and $offRun.els.qsec.hidden -and $offRun.els.msgsec.hidden -and $offRun.els.cost.hidden -and $offRun.els.mksup.hidden -and $offRun.els.banner.hidden -and $offRun.els.digestbox.hidden) "$($offRun.error) $($offPaths -join ' ')"
        Check 'its session rows are the rows of the old template' ($legacy.Length -gt 20 -and ((($offRun.els.rows.html -replace '<tr class="grp">.*?</tr>', '') -replace '\s', '').Length -eq ($legacy -replace '\s', '').Length) -and $offRun.els.rows.html -match '^<tr class="grp"><th colspan="8">Workers</th></tr>' -and $offRun.els.tokrow.hidden -and -not $offRun.els.conn.hidden) "$($offRun.els.rows.html.Length) $($legacy.Length)"
    } else { Write-Host '    skip  prompt with messaging off: node is not installed' }
    Stop-OwnerClient 'msgoff'
}
}

# A `worker:<name>` label pins an item: it is offered to that worker and to nobody else, whatever that worker does or does not do.
$OwnerScenarios['owner: a pinned item is only ever offered to its worker: after a missed accept, while it is at capacity, and while it is offline'] = {
    Start-OwnerClient 'pin-a' 'persistent-local' '--capacity 1'
    Start-OwnerClient 'pin-b' 'persistent-local' '--capacity 5'
    $asg = { param($Item) @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $Item }) }
    $offersOf = { param($Item) @((Get-FakeIssue $Item).comments | Where-Object { $_.body -match '<!-- plant event=offered' } | ForEach-Object { [regex]::Match($_.body, 'offered to \*\*([^*]+)\*\*').Groups[1].Value }) }
    # 1. the pinned worker lets the accept window (4 s in this suite) pass
    $n1 = New-Item-Fake 'Pinned, accept missed' 'x' ($OwnerLabels + 'worker:pin-a')
    Check 'the pinned item is offered to its worker' (Wait-Until -Seconds 40 { (Get-Assigned 'pin-a' $n1).Count -ge 1 })
    Check 'after the missed window it waits, with no worker (the waiting row of the dashboard)' (Wait-Until -Seconds 20 { $x = @(& $asg $n1); $x.Count -eq 1 -and "$($x[0].worker)" -eq '' -and -not $x[0].accepted }) ((& $asg $n1) | ConvertTo-Json -Compress)
    Check 'and is offered to the same worker again' (Wait-Until -Seconds 30 { (Get-Assigned 'pin-a' $n1).Count -ge 2 })
    Start-Sleep -Seconds 6
    Check 'the idle worker beside it was never offered the item' ((Get-Assigned 'pin-b' $n1).Count -eq 0 -and @((& $offersOf $n1) | Where-Object { $_ -ne 'pin-a' }).Count -eq 0) ((& $offersOf $n1) -join ',')
    $j = Get-Journal $n1
    Check 'the journal says waiting, and never reassigned' ($j -contains 'waiting' -and $j -notcontains 'reassigned' -and @((Get-FakeIssue $n1).comments | Where-Object { $_.body -match "the pinned worker 'pin-a' did not confirm" -and $_.body -notlike '<!-- factory-state:*' }).Count -eq 1) ($j -join ',')
    $ev = (Get-Assigned 'pin-a' $n1)[-1]
    $r = Wait-Until -Seconds 30 { $script:PinAccept = Fo 'pin-a' @('accept', '--item', $n1, '--assignment', ((Get-Assigned 'pin-a' $n1)[-1]).assignment); $script:PinAccept.exit -eq 0 }
    Check 'the pinned worker accepts a later offer and owns the item' ($r -and @((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n1" -and $_.Value -eq 'pin-a' }).Count -eq 1) ($script:PinAccept | ConvertTo-Json -Compress)
    # 2. the pinned worker is at capacity (1, and it owns n1 now)
    $n2 = New-Item-Fake 'Pinned, worker full' 'x' ($OwnerLabels + 'worker:pin-a')
    $free = New-Item-Fake 'Not pinned' 'x' $OwnerLabels
    Check 'an item without a pin goes to the idle worker, so that worker is eligible' (Wait-Until -Seconds 40 { (Get-Assigned 'pin-b' $free).Count -ge 1 })
    Check 'the item pinned to the full worker waits' (Wait-Until -Seconds 30 { $x = @(& $asg $n2); $x.Count -eq 1 -and "$($x[0].worker)" -eq '' })
    # 3. the pinned worker is not connected
    $n3 = New-Item-Fake 'Pinned, worker offline' 'x' ($OwnerLabels + 'worker:pin-c')
    Check 'the item pinned to a worker that is not connected waits' (Wait-Until -Seconds 30 { $x = @(& $asg $n3); $x.Count -eq 1 -and "$($x[0].worker)" -eq '' })
    Start-Sleep -Seconds 10     # more than two accept windows and several sweeps
    Check 'neither waiting item was offered to anybody' ((Get-Assigned 'pin-b' $n2).Count -eq 0 -and (Get-Assigned 'pin-b' $n3).Count -eq 0 -and (Get-Assigned 'pin-a' $n2).Count -eq 0 -and @(& $offersOf $n2).Count -eq 0 -and @(& $offersOf $n3).Count -eq 0) "$((& $offersOf $n2) -join ',') $((& $offersOf $n3) -join ',')"
    Start-OwnerClient 'pin-c' 'persistent-local' '--capacity 2'
    Check 'the pinned worker connects and is offered its item' (Wait-Until -Seconds 30 { (Get-Assigned 'pin-c' $n3).Count -ge 1 })
    $r3 = Fo 'pin-c' @('accept', '--item', $n3, '--assignment', ((Get-Assigned 'pin-c' $n3)[-1]).assignment); CheckExit 'and accepts it' $r3 0
    Check 'the other pinned item still waits for its own worker' ((Get-Assigned 'pin-c' $n2).Count -eq 0 -and (Get-Assigned 'pin-b' $n2).Count -eq 0)
    foreach ($w in 'pin-a', 'pin-b', 'pin-c') { Stop-OwnerClient $w }
}

# Issue 46: a free slot of a worker that a pinned item waits for is the pinned item's. Live, an unpinned item matched in the same sweep took the only
# slot of the idle pinned worker, and the pinned item waited for hours. Here the pinned worker (capacity 1) is the only session: it is offered its
# pinned item first, and while that item waits for it (an offer it let lapse) no unpinned item takes the slot.
$OwnerScenarios['owner: a pinned item gets its worker''s free slot first, and keeps it while it waits for that worker (issue 46)'] = {
    foreach ($w in @($script:Workers.Keys)) { Stop-OwnerClient $w }
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.connected }).Count -eq 0 })
    $u = New-Item-Fake 'Unpinned, matched with a pinned one' 'x' $OwnerLabels
    $p = New-Item-Fake 'Pinned to the only worker' 'x' ($OwnerLabels + 'worker:pin-r')
    $asg = { param($Item) @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $Item }) }
    Check 'both items wait while no session is connected' (Wait-Until -Seconds 40 { @(& $asg $u).Count -eq 1 -and @(& $asg $p).Count -eq 1 }) ((Get-Plant).plant.assignments | ConvertTo-Json -Compress)
    Start-OwnerClient 'pin-r' 'persistent-local' '--capacity 1'
    $others = { @(Get-WorkerEvents 'pin-r' | Where-Object { $_.event -eq 'item.assigned' -and $_.item -ne $p }) }
    Check 'the pinned worker is offered its pinned item' (Wait-Until -Seconds 40 { (Get-Assigned 'pin-r' $p).Count -ge 1 })
    Check 'and no other item' (@(& $others).Count -eq 0) ((& $others) | ConvertTo-Json -Compress)
    # the offer lapses (4 s in this suite) and the pinned item waits for the same worker; the sweeps meanwhile (every 2 s) must not fill the slot
    Check 'after the missed window it is offered to the same worker again' (Wait-Until -Seconds 30 { (Get-Assigned 'pin-r' $p).Count -ge 2 })
    Start-Sleep -Seconds 8
    Check 'while it waited, no unpinned item took the slot' (@(& $others).Count -eq 0) ((& $others) | ConvertTo-Json -Compress)
    $r = Wait-Until -Seconds 30 { $script:PinR = Fo 'pin-r' @('accept', '--item', $p, '--assignment', ((Get-Assigned 'pin-r' $p)[-1]).assignment); $script:PinR.exit -eq 0 }
    Check 'the pinned worker accepts its item' $r ($script:PinR | ConvertTo-Json -Compress)
    Check 'the unpinned item was never offered to it' ((Get-Assigned 'pin-r' $u).Count -eq 0)
    Stop-OwnerClient 'pin-r'
}

# Host capacity (gateway/Hosts.cs): two sessions that declare one host share its limit of owned items (the owner suite sets lab-1 to 1 owned, 1 build),
# a low-effort session gets capacity 1, and a private-build slot is one per host at a time, freed by release or by its ttl (and when its work ends, below).
$OwnerScenarios['owner: sessions of one host share its limit of owned items and its build slot; a low-effort session gets capacity 1'] = {
    foreach ($w in @($script:Workers.Keys)) { Stop-OwnerClient $w }    # only the sessions of this scenario may take its items
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.connected }).Count -eq 0 })
    try {
    Start-OwnerClient 'host-a' 'persistent-local' '--capacity 3 --host lab-1'
    Start-OwnerClient 'host-b' 'persistent-local' '--capacity 3 --host LAB-1'
    $mine = { $pl = (Get-Plant).plant; @($pl.assignments | Where-Object { $_.worker -in 'host-a', 'host-b' -and -not $_.accepted }).Count + @($pl.owners.PSObject.Properties | Where-Object { $_.Value -in 'host-a', 'host-b' }).Count }
    $h = Msg-First @((Get-Plant).hosts.hosts | Where-Object { $_.host -eq 'lab-1' })
    Check 'both sessions are listed under one host (lower case), with its limits' ($h -and @($h.workers).Count -eq 2 -and $h.ownedLimit -eq 1 -and $h.buildLimit -eq 1) ((Get-Plant).hosts | ConvertTo-Json -Compress -Depth 5)
    $n1 = New-Item-Fake 'Host limit one' 'x' $OwnerLabels; $n2 = New-Item-Fake 'Host limit two' 'x' $OwnerLabels
    Check 'one item is offered on the host' (Wait-Until -Seconds 40 { (& $mine) -ge 1 })
    $max = 0; $end = (Get-Date).AddSeconds(10); while ((Get-Date) -lt $end) { $max = [Math]::Max($max, (& $mine)); Start-Sleep -Milliseconds 500 }
    Check 'never more than the host limit (1) at once, although each session has capacity 3' ($max -eq 1) "max $max"
    # accept what was offered (an offer lapses after 4 s in this suite: wait for the one that is out)
    $script:HostAcc = $null
    # (only the offer that is out now: accepting a lapsed one would claim an item the plant already offered elsewhere)
    [void](Wait-Until -Seconds 40 { $out = Msg-First @((Get-Plant).plant.assignments | Where-Object { $_.worker -in 'host-a', 'host-b' -and -not $_.accepted }); if ($out) { $r = Fo $out.worker @('accept', '--item', $out.item, '--assignment', $out.id); if ($r.exit -eq 0) { $script:HostAcc = @{ w = "$($out.worker)"; item = [int]$out.item }; return $true } }; $false })
    $acc = $script:HostAcc
    Check 'a session of the host accepts it and owns it' ($acc -and @((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$($acc.item)" -and $_.Value -eq $acc.w }).Count -eq 1 -and (& $mine) -le 1) ($acc | ConvertTo-Json -Compress)
    if (-not $acc) { return }
    Start-Sleep -Seconds 8
    Check 'while it owns it, nothing more is offered on that host' ((& $mine) -eq 1) ((Get-Plant).plant | ConvertTo-Json -Compress -Depth 5)
    # the build slot of the host
    $other = if ($acc.w -eq 'host-a') { 'host-b' } else { 'host-a' }
    $slot = { param($Name, $Body) $r = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/build-slot" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers[$Name].token)" } -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -SkipHttpErrorCheck; $j = $r.Content | ConvertFrom-Json -AsHashtable; $j.status = [int]$r.StatusCode; $j }
    $g = Fo $acc.w @('build-slot', '--item', $acc.item, '--ttl', '600'); CheckExit 'the owner takes the build slot of its host' $g 0
    $b = & $slot $other @{ action = 'acquire' }
    Check 'the other session of the host is told busy: 429, exit 21, the holder and when to ask again' ($b.status -eq 429 -and $b.exit -eq 21 -and $b.code -eq 'build-slot-busy' -and $b.retryAfterSeconds -ge 5 -and @($b.holders | Where-Object { $_.name -eq $acc.w }).Count -eq 1) ($b | ConvertTo-Json -Compress -Depth 4)
    Start-OwnerClient 'host-c' 'persistent-local' '--capacity 1 --host lab-2'
    $c = & $slot 'host-c' @{ action = 'acquire' }
    Check 'a session of another host builds at the same time' ($c.status -eq 200 -and $c.granted -eq $true) ($c | ConvertTo-Json -Compress)
    $rel = Fo $acc.w @('build-slot', '--item', $acc.item, '--release'); CheckExit 'release' $rel 0
    $b2 = & $slot $other @{ action = 'acquire'; ttlSeconds = 2 }
    Check 'after the release the other session gets it' ($b2.status -eq 200 -and $b2.granted -eq $true) ($b2 | ConvertTo-Json -Compress)
    Start-Sleep -Seconds 4
    $g2 = Fo $acc.w @('build-slot', '--item', $acc.item); CheckExit 'a slot not released frees itself after its ttl' $g2 0
    [void](Fo $acc.w @('build-slot', '--item', $acc.item, '--release')); [void](& $slot 'host-c' @{ action = 'release' })
    Start-OwnerClient 'host-low' 'persistent-local' '--capacity 4 --model claude-haiku-5-5 --effort low --host lab-3'
    Check 'a session that registers with effort low gets capacity 1' (@((Get-Plant).plant.workers | Where-Object { $_.name -eq 'host-low' -and $_.capacity -eq 1 }).Count -eq 1) ((Get-Plant).plant.workers | ConvertTo-Json -Compress -Depth 4)
    } finally { foreach ($w in 'host-a', 'host-b', 'host-c', 'host-low') { if ($script:Workers.ContainsKey($w)) { Stop-OwnerClient $w } } }
}

# Issue 108: a build slot is freed when the work it was for ends, not only by its release or its ttl: the item's slots when the item is released
# (and on a take-back, at its completion and at every drop of its owner), the name's slots when the name is revoked, its session is told
# session.end, or it stays disconnected for schedule.buildSlotDisconnectSeconds. lab-4 has no limit of owned items and one build slot (the default).
$OwnerScenarios['owner: a build slot is freed when its work ends: the item released, the session disconnected for good, the name revoked'] = {
    foreach ($w in @($script:Workers.Keys)) { Stop-OwnerClient $w }
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.connected }).Count -eq 0 })
    $old = $env:FACTORY_TIMING_buildSlotDisconnectSeconds
    try {
        $env:FACTORY_TIMING_buildSlotDisconnectSeconds = '3'; Restart-Gateway
        Start-OwnerClient 'slot-a' 'persistent-local' '--capacity 1 --host lab-4'
        Start-OwnerClient 'slot-b' 'persistent-local' '--capacity 1 --host lab-4'
        $slot = { param($Name, $Body) $r = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/build-slot" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers[$Name].token)" } -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -SkipHttpErrorCheck; $j = $r.Content | ConvertFrom-Json -AsHashtable; $j.status = [int]$r.StatusCode; $j }
        $held = { [int](Get-Plant).hosts.buildSlotsHeld }
        $n = New-Item-Fake 'Build slot freed' 'x' ($OwnerLabels + 'worker:slot-a')
        Check 'the item is offered to slot-a' (Wait-Until -Seconds 40 { (Get-Assigned 'slot-a' $n).Count -gt 0 })
        # (an offer lapses after a few seconds in this suite: accept the one that stands, as often as one lapsed before the call)
        for ($try = 0; $try -lt 5; $try++) {
            $r = Fo 'slot-a' @('accept', '--item', $n, '--assignment', (Get-Assigned 'slot-a' $n)[-1].assignment)
            if ($r.exit -ne 11) { break }
            $seen = (Get-Assigned 'slot-a' $n).Count; [void](Wait-Until -Seconds 30 { (Get-Assigned 'slot-a' $n).Count -gt $seen })
        }
        CheckExit 'slot-a accepts it' $r 0
        $g = Fo 'slot-a' @('build-slot', '--item', $n, '--ttl', '600'); CheckExit 'the owner takes the build slot of lab-4' $g 0
        $b = & $slot 'slot-b' @{ action = 'acquire' }
        Check 'the other session of lab-4 is told busy' ($b.status -eq 429 -and $b.code -eq 'build-slot-busy') ($b | ConvertTo-Json -Compress -Depth 4)
        $r = Fo 'slot-a' @('release', '--item', $n, '--reason', 'scenario: the item is given up'); CheckExit 'the owner releases the item without releasing the slot' $r 0
        Check 'the release freed the slot of the item' (Wait-Until -Seconds 10 { (& $held) -eq 0 }) ((Get-Plant).hosts | ConvertTo-Json -Compress -Depth 5)
        $b = & $slot 'slot-b' @{ action = 'acquire'; ttlSeconds = 600 }
        Check 'so the other session of the host builds at once' ($b.status -eq 200 -and $b.granted -eq $true) ($b | ConvertTo-Json -Compress)
        # slot-b goes away without releasing it: after buildSlotDisconnectSeconds (3 s here) its slot is free
        Stop-OwnerClient 'slot-b'
        Check 'the slot of a session that stays disconnected is freed' (Wait-Until -Seconds 30 { (& $held) -eq 0 }) ((Get-Plant).hosts | ConvertTo-Json -Compress -Depth 5)
        $a = & $slot 'slot-a' @{ action = 'acquire'; ttlSeconds = 600 }
        Check 'and slot-a gets it' ($a.status -eq 200 -and $a.granted -eq $true) ($a | ConvertTo-Json -Compress)
        # a revoked name's credentials are refused from then on, so it can never release: its slots go with the revoke
        $rv = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/workers/slot-a/revoke" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck
        Check 'the operator revokes slot-a' ([int]$rv.StatusCode -eq 200) "$([int]$rv.StatusCode) $($rv.Content)"
        Check 'its slot is freed' ((& $held) -eq 0) ((Get-Plant).hosts | ConvertTo-Json -Compress -Depth 5)
        Check 'the frees are counted' ([int](Get-Plant).hosts.buildFreed -ge 3) ((Get-Plant).hosts | ConvertTo-Json -Compress -Depth 5)
    } finally {
        foreach ($w in 'slot-a', 'slot-b') { if ($script:Workers.ContainsKey($w)) { Stop-OwnerClient $w } }
        $env:FACTORY_TIMING_buildSlotDisconnectSeconds = $old; Restart-Gateway
    }
}

# factory.ps1 private-build (lib/Client.Build.ps1): one command builds a worktree under the host's build slot. The worktree's build.ps1 here only
# prints what it was given; --dotnet names a stand-in SDK, so ensure-tools.ps1 downloads nothing. A worker credential holds the slot for the item.
$OwnerScenarios['owner: private-build builds a worktree under the host''s build slot with SQLite and the dotnet path, writes the log and gives the slot back'] = {
    $oldWork = $env:FACTORY_WORK_DIR; $env:FACTORY_WORK_DIR = Join-Path $script:Work 'work'   # (the log goes to the scenario's own work directory)
    try {
    Start-OwnerClient 'pb-a' 'persistent-local' '--capacity 1 --host lab-pb'
    Start-OwnerClient 'pb-b' 'persistent-local' '--capacity 1 --host lab-pb'
    $n = New-Item-Fake 'Private build' 'x' @('Auto Merge')
    $wt = Join-Path $script:Work "pb-wt-$n"; New-Item -ItemType Directory -Force -Path $wt | Out-Null
    Set-Content -LiteralPath (Join-Path $wt 'build.ps1') -Value @'
function Build {
    Set-Content -LiteralPath ./ran.txt -Value 'built'
    "engine=$env:DATABASE_ENGINE"
    "first-path=$(@($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and $_.TrimEnd('/', '\') -ne $PSHOME.TrimEnd('/', '\') })[0])"   # (pwsh puts its own folder first)
    "dotnet-root=$env:DOTNET_ROOT"
    "credential=$([bool]$env:FACTORY_TOKEN)$([bool]$env:FACTORY_WORKER_TOKEN)"
    if (Test-Path ./fail.txt) { '  Failed Some.Tests.WorkOrderTests.Should_Fail [12 ms]'; "$PWD/src/A.cs(3,4): error CS1002: ; expected [$PWD/src/A.csproj]"; throw 'the build failed here' }
    'BUILD SUCCEEDED'
}
'@
    $sdk = Join-Path $script:Work "pb-sdk-$n"; New-Item -ItemType Directory -Force -Path $sdk | Out-Null; Set-Content -LiteralPath (Join-Path $sdk 'dotnet') -Value ''
    New-Item -ItemType Directory -Force -Path (Join-Path $sdk 'host/fxr') | Out-Null   # an SDK root, so DOTNET_ROOT is set to it
    $pb = @('private-build', '--item', $n, '--worktree', $wt, '--dotnet', (Join-Path $sdk 'dotnet'))
    $slot = { param($Name, $Body) $r = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/build-slot" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers[$Name].token)" } -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json' -SkipHttpErrorCheck; $j = $r.Content | ConvertFrom-Json -AsHashtable; $j.status = [int]$r.StatusCode; $j }
    $h = & $slot 'pb-b' @{ action = 'acquire'; ttlSeconds = 120 }
    Check 'another session of the host holds the build slot' ($h.status -eq 200 -and $h.granted -eq $true) ($h | ConvertTo-Json -Compress)
    $r = Fo 'pb-a' ($pb + @('--slot-wait-minutes', '0')); CheckExit 'the slot is busy and no wait is allowed: exit 21 build-slot-busy' $r 21 'build-slot-busy'
    Check 'it says when to run it again, and nothing was built' ($r.verb -eq 'private-build' -and $r.retryAfterSeconds -ge 5 -and -not (Test-Path -LiteralPath (Join-Path $wt 'ran.txt'))) ($r | ConvertTo-Json -Compress -Depth 4)
    [void](& $slot 'pb-b' @{ action = 'release' })
    $h = & $slot 'pb-b' @{ action = 'acquire'; ttlSeconds = 7 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Fo 'pb-a' $pb; CheckExit 'the slot is busy for some seconds: the verb waits for it, then the build runs and passes' $r 0
    Check 'it waited for the slot' ($h.granted -eq $true -and [int]$r.slotWaitedSeconds -ge 3) "slotWaitedSeconds $($r.slotWaitedSeconds), $([int]$sw.Elapsed.TotalSeconds) s in all" 
    $log = if ($r.log -and (Test-Path -LiteralPath $r.log)) { Get-Content -Raw -LiteralPath $r.log } else { '' }
    Check 'ok, nothing failed, and the log of this item in the work directory' ($r.ok -eq $true -and @($r.failed).Count -eq 0 -and "$($r.log)" -like "*build-$n.log" -and (Split-Path -Leaf (Split-Path -Parent $r.log)) -eq 'work' -and $r.database -eq 'SQLite') ($r | ConvertTo-Json -Compress -Depth 4)
    Check 'the build ran in the worktree with DATABASE_ENGINE=SQLite and the dotnet folder first on PATH (after the folder of pwsh)' ($log -match 'engine=SQLite' -and $log.Contains("first-path=$sdk") -and $log.Contains("dotnet-root=$sdk") -and $log.Contains('BUILD SUCCEEDED')) $log
    Check 'no credential of the session reaches the build' ($log.Contains('credential=FalseFalse')) $log
    Check 'not the item''s branch (no git here): nothing is attested' ($r.attested -eq $false -and $r.attestCode -eq 'not-the-item-branch') ($r | ConvertTo-Json -Compress -Depth 3)
    $b = & $slot 'pb-b' @{ action = 'acquire'; ttlSeconds = 60 }
    Check 'the slot was given back' ($b.status -eq 200 -and $b.granted -eq $true) ($b | ConvertTo-Json -Compress)
    [void](& $slot 'pb-b' @{ action = 'release' })
    Set-Content -LiteralPath (Join-Path $wt 'fail.txt') -Value 'x'
    $r = Fo 'pb-a' $pb; CheckExit 'a failing build: exit 10 build-failed' $r 10 'build-failed'
    Check 'failed names the failed test and the compile error, relative to the worktree' (@($r.failed) -contains 'test Some.Tests.WorkOrderTests.Should_Fail' -and @($r.failed) -contains 'src/A.cs(3,4): error CS1002: ; expected') ($r.failed | ConvertTo-Json -Compress)
    Check 'the end of the log is in the answer, the error with it' ((@($r.tail) -join "`n") -match 'the build failed here') ($r.tail | ConvertTo-Json -Compress)
    $b = & $slot 'pb-b' @{ action = 'acquire'; ttlSeconds = 60 }
    Check 'the slot was given back after the failed build as well' ($b.status -eq 200 -and $b.granted -eq $true) ($b | ConvertTo-Json -Compress)
    [void](& $slot 'pb-b' @{ action = 'release' })
    $u = Fo 'pb-a' @('private-build', '--item', $n, '--worktree', (Join-Path $script:Work 'no-such-worktree'), '--dotnet', (Join-Path $sdk 'dotnet')); CheckExit 'a folder without build.ps1 is refused' $u 2 'no-build-script'
    } finally { foreach ($w in 'pb-a', 'pb-b') { if ($script:Workers.ContainsKey($w)) { Stop-OwnerClient $w } }; $env:FACTORY_WORK_DIR = $oldWork }
}

# The journal of one item reads in event order. Each line is a rule-script call of its own (the plant's matched and offered, the worker's accept),
# and with a GitHub that answers slowly those calls used to reach the item lock in any order: live, "offered" was written 40 s after the offer
# and after "accepted". The fake holds every matched and offered comment back, and the worker accepts the moment the offer arrives.
$OwnerScenarios['owner: with a slow GitHub the journal of an item still reads matched, offered, assigned, and the offer is not held back by it [full]'] = {
    $oldAck = $env:FACTORY_ASSIGN_ACK_SECONDS
    try {
        $env:FACTORY_ASSIGN_ACK_SECONDS = '60'; Restart-Gateway      # an accept window in which a slow journal fits, as the deployed 120 s
        Start-OwnerClient 'slow-j' 'persistent-local' '--capacity 5'
        $orders = @(); $offerDelays = @()
        foreach ($round in 1..3) {
            Fake 'latency' @{ ms = 1500; match = 'plant event=(matched|offered)' } | Out-Null
            $n = New-Item-Fake "Slow journal $round" 'x' ($OwnerLabels + 'worker:slow-j')      # pinned: clients of earlier scenarios reconnect to the restarted gateway
            $got = Wait-Until -Seconds 40 { (Get-Assigned 'slow-j' $n).Count -gt 0 }
            $offerDelays += @((Get-Journal $n) | Where-Object { $_ -eq 'offered' }).Count      # the offer reached the worker before its journal line existed
            if (-not $got) { $orders += 'no offer'; continue }
            $r = Fo 'slow-j' @('accept', '--item', $n, '--assignment', (Get-Assigned 'slow-j' $n)[0].assignment)
            [void](Wait-Until -Seconds 30 { @((Get-Journal $n) | Where-Object { $_ -in 'matched', 'offered', 'assigned' }).Count -ge 3 })
            $orders += "$($r.exit):" + (@((Get-Journal $n) | Where-Object { $_ -in 'matched', 'offered', 'assigned' }) -join ',')
            Fake 'latency' @{ ms = 0 } | Out-Null
        }
        Check 'every item was accepted and its journal reads matched, offered, assigned, once each' (@($orders | Where-Object { $_ -ne '0:matched,offered,assigned' }).Count -eq 0) ($orders -join ' | ')
        Check 'no offer waited for its journal line' (@($offerDelays | Where-Object { $_ -ne 0 }).Count -eq 0) ($offerDelays -join ',')
    } finally {
        try { Fake 'latency' @{ ms = 0 } | Out-Null } catch { }
        Stop-OwnerClient 'slow-j'
        $env:FACTORY_ASSIGN_ACK_SECONDS = $oldAck; Restart-Gateway
    }
}

# The acceptance waits for the journal lines before it, and an offer counts as accepted only when the rule script has returned: that wait must not
# be taken from the offer's window. Here "offered" and "assigned" each take 10 s to post in an 18 s window: the accept ends after the window.
$OwnerScenarios['owner: an accept that waited for a slow journal does not let its offer lapse: the item is not offered again while it is being accepted [full]'] = {
    $oldAck = $env:FACTORY_ASSIGN_ACK_SECONDS; $oldSweep = $env:FACTORY_SWEEP_SECONDS
    try {
        # no sweep while the accept runs, as with the deployed 180 s: a sweep that sees the claim the accept has just written drops the open
        # offer, and then nothing can lapse
        $env:FACTORY_ASSIGN_ACK_SECONDS = '18'; $env:FACTORY_SWEEP_SECONDS = '30'; Restart-Gateway
        Start-OwnerClient 'slow-k' 'persistent-local' '--capacity 5'
        Fake 'latency' @{ ms = 10000; match = 'plant event=(offered|assigned)' } | Out-Null
        $n = New-Item-Fake 'Slow accept' 'x' ($OwnerLabels + 'worker:slow-k')      # pinned: a lapsed offer shows as "waiting" and a second offer to the same worker
        Check 'the item is offered' (Wait-Until -Seconds 70 { (Get-Assigned 'slow-k' $n).Count -gt 0 })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Fo 'slow-k' @('accept', '--item', $n, '--assignment', (Get-Assigned 'slow-k' $n)[0].assignment)
        Check 'the accept succeeds, after the 18 s window of the offer had passed' ($r.exit -eq 0 -and $sw.Elapsed.TotalSeconds -gt 18) "$($r.exit) $($sw.Elapsed.TotalSeconds)"
        Fake 'latency' @{ ms = 0 } | Out-Null
        Start-Sleep -Seconds 6     # ticks, sweeps and any journal line still on its way
        $j = Get-Journal $n
        Check 'the offer did not lapse: no waiting or reassigned line, one offer, and the journal in order' ((($j -join ',') -eq 'matched,offered,assigned') -and (Get-Assigned 'slow-k' $n).Count -eq 1) "$($j -join ',') offers: $((Get-Assigned 'slow-k' $n).Count)"
        Check 'the plant records the owner' (@((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" -and $_.Value -eq 'slow-k' }).Count -eq 1)
    } finally {
        try { Fake 'latency' @{ ms = 0 } | Out-Null } catch { }
        Stop-OwnerClient 'slow-k'
        $env:FACTORY_ASSIGN_ACK_SECONDS = $oldAck; $env:FACTORY_SWEEP_SECONDS = $oldSweep; Restart-Gateway
    }
}

# An item that cannot be offered at once (its pinned worker is away) is matched all the same: live, such an item's journal began with "waiting".
$OwnerScenarios['owner: an item that waits for its pinned worker has matched first, once however many sweeps pass, and offered after it when the worker comes'] = {
    $n = New-Item-Fake 'Pinned waiting' 'x' ($OwnerLabels + 'worker:pin-late')
    Check 'the item waits, without a worker' (Wait-Until -Seconds 30 { @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $n -and "$($_.worker)" -eq '' }).Count -eq 1 })
    Check 'its journal says matched, then waiting' (Wait-Until -Seconds 20 { ((Get-Journal $n) -join ',') -eq 'matched,waiting' }) ((Get-Journal $n) -join ',')
    Start-Sleep -Seconds 7     # three sweeps and more
    Check 'more sweeps add no line' (((Get-Journal $n) -join ',') -eq 'matched,waiting') ((Get-Journal $n) -join ',')
    Start-OwnerClient 'pin-late' 'persistent-local' '--capacity 5'
    Check 'the pinned worker connects and is offered the item' (Wait-Until -Seconds 30 { (Get-Assigned 'pin-late' $n).Count -ge 1 })
    Check 'the journal reads matched, waiting, offered: one matched, before the offer' (Wait-Until -Seconds 20 { ((Get-Journal $n) -join ',') -eq 'matched,waiting,offered' }) ((Get-Journal $n) -join ',')
    Stop-OwnerClient 'pin-late'
}

# The start guards of the test runners (guard.ps1), and how a crashed client process is reported.
# ---- the docs-only marker in the body counts only for items from before the cutoff (backlog d) ----
$OwnerScenarios['docs-only: the body marker of an item without the state field counts only for items created before the cutoff [full]'] = {
    $lab = @('factory worker', 'worker:nobody-here')   # pinned to a session that does not exist: the plant offers these items to nobody
    $get = { param($i) Qc-Server 'get-item' @{ item = $i } }
    # the docs-only marker in the body of an item without the state field: only for items created before the cutoff
    $mk = "x`n`n## Technical Design`n<!-- aisf:docs-only -->`n- a sentence."
    $d0 = (Fake 'issue' @{ title = 'Old docs item'; body = $mk; labels = $lab; column = 'Development'; createdAt = '2019-06-01T00:00:00Z' }).number
    $d1 = (Fake 'issue' @{ title = 'New docs item'; body = $mk; labels = $lab; column = 'Development' }).number
    $g0 = & $get $d0; $g1 = & $get $d1
    Check 'an item created before the cutoff, past its design and without the field, is docs-only by the marker in its body' ($g0.exit -eq 0 -and $g0.docs_only -eq $true) ($g0 | ConvertTo-Json -Compress -Depth 2)
    Check 'an item created after it is not, whatever its body says' ($g1.exit -eq 0 -and $g1.docs_only -eq $false)
    $ship = (Get-Content -Raw (Join-Path $script:Root 'config/instance.json') | ConvertFrom-Json -AsHashtable -DateKind String).timing.docsOnlyLegacyBefore
    Check 'the shipped cutoff is 2026-10-16T00:00:00Z' ("$ship" -eq '2026-10-16T00:00:00Z') "$ship"
}

$OwnerScenarios['runner: a second run is refused while one is active, a short disk is refused, -Force overrides, and pwsh exit 139 is reported as a crash'] = {
    $pwshExe = (Get-Command pwsh).Source
    # a child of this suite is inside a run (FACTORY_TEST_RUN_HELD): the guard is tried as a person's shell would start it, without that variable
    $run = { param([string]$Script, [string[]]$More)
        $out = Join-Path $script:Work "guard-$([guid]::NewGuid().ToString('N').Substring(0, 6)).out"
        $old = @{ h = $env:FACTORY_TEST_RUN_HELD; b = $env:TEST_PORT_BASE; a = $env:TEST_API_PORT; f = $env:TEST_FAKE_PORT }
        $env:FACTORY_TEST_RUN_HELD = $null; $env:TEST_PORT_BASE = "$($script:PortBase + 90)"; $env:TEST_FAKE_PORT = "$($script:PortBase + 90)"; $env:TEST_API_PORT = "$($script:PortBase + 92)"
        try { $p = Start-Process $pwshExe -ArgumentList (@('-NoProfile', '-File', (Join-Path $script:Root "tests/scenarios/$Script"), '-NoBuild') + $More) -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err" }
        finally { $env:FACTORY_TEST_RUN_HELD = $old.h; $env:TEST_PORT_BASE = $old.b; $env:TEST_API_PORT = $old.a; $env:TEST_FAKE_PORT = $old.f }
        if (-not $p.WaitForExit(120000)) { try { $p.Kill($true) } catch { }; return @{ code = -1; text = 'did not end' } }
        return @{ code = $p.ExitCode; text = "$(Get-Content -Raw $out -ErrorAction SilentlyContinue)$(Get-Content -Raw "$out.err" -ErrorAction SilentlyContinue)" }
    }
    $none = @('-Suite', 'auto', '-Only', 'zz-no-such-scenario-zz')
    # a process that looks like another run to the guard: pwsh with the runner's path on its command line (it only sleeps)
    $decoy = Start-Process $pwshExe -ArgumentList @('-NoProfile', '-Command', '"Start-Sleep -Seconds 120 # tests/scenarios/run-all.ps1 -Tier full"') -PassThru
    $script:Procs += $decoy
    try {
        Start-Sleep -Milliseconds 800
        $a = & $run 'run.ps1' $none
        Check 'run.ps1 refuses to start beside another run: exit 4, a clear message that names the other process' ($a.code -eq 4 -and $a.text -match 'refused, another test run is active' -and $a.text -match "pid $($decoy.Id)\b" -and $a.text -match '-Force') $a.text
        $b = & $run 'run-all.ps1' @('-Suites', 'auto', '-Only', 'zz-no-such-scenario-zz')
        Check 'run-all.ps1 refuses the same way' ($b.code -eq 4 -and $b.text -match 'run-all\.ps1: refused, another test run is active' -and $b.text -notmatch 'run-all: tier') $b.text
        $c = & $run 'run.ps1' ($none + '-Force')
        Check 'with -Force it starts, and says so' ($c.code -eq 0 -and $c.text -match '-Force, starting although another test run is active' -and $c.text -match '0 checks, 0 failed') $c.text
        $d = & $run 'run.ps1' ($none + @('-Force', '-MinFreeDiskMb', '2000000000'))
        Check 'and -Force also overrides the disk floor' ($d.code -eq 0 -and $d.text -match '-Force, starting with \d+ MB free') $d.text
    } finally { try { Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue } catch { } }
    [void]$decoy.WaitForExit(5000)
    $others = @(Get-OtherTestRuns | Where-Object { $_.cmd -match 'Start-Sleep -Seconds 120' })
    Check 'the stand-in process is gone' ($others.Count -eq 0)
    $e = & $run 'run.ps1' ($none + @('-MinFreeDiskMb', '2000000000'))
    $f = & $run 'run-all.ps1' @('-Suites', 'auto', '-Only', 'zz-no-such-scenario-zz', '-MinFreeDiskMb', '2000000000')
    # (beside a run-all with other suites these two are refused for the other run first: either refusal is exit 4)
    Check 'a temp filesystem below the free-disk floor is refused: exit 4, with the figures' ($e.code -eq 4 -and $f.code -eq 4 -and ($e.text -match 'MB free on the filesystem of .* below the floor of 2000000000 MB' -or $e.text -match 'another test run is active')) "$($e.text) $($f.text)"
    Check 'the default floor is 2 GB in both runners' ((Get-Content -Raw (Join-Path $script:Root 'tests/scenarios/run.ps1')) -match '\$MinFreeDiskMb = 2048' -and (Get-Content -Raw (Join-Path $script:Root 'tests/scenarios/run-all.ps1')) -match '\$MinFreeDiskMb = 2048')
    # a client process that dies with a segmentation fault: a stand-in pwsh that exits 139
    $stub = Join-Path $script:Work 'stub-bin-crash'; New-Item -ItemType Directory -Force -Path $stub | Out-Null
    Set-Content (Join-Path $stub 'pwsh') "#!/bin/sh`nexit 139`n"; & chmod +x (Join-Path $stub 'pwsh')
    $oldPath = $env:PATH; $oldHost = $env:TEST_CLIENT_HOST; $crashes = $script:ClientCrashes
    $env:PATH = "$stub$([IO.Path]::PathSeparator)$oldPath"; $env:TEST_CLIENT_HOST = '0'
    try { $x = F 'w1' @('get-item', '--item', '1') } finally { $env:PATH = $oldPath; $env:TEST_CLIENT_HOST = $oldHost }
    Check 'a client call that ends with exit 139 is reported as a crash of the process, not as an answer' ($x.exit -eq 139 -and $x.code -eq 'client-crashed' -and "$($x.reason)" -match 'EXIT 139 \(SEGMENTATION FAULT\)' -and "$($x.reason)" -match 'not a product answer' -and $script:ClientCrashes -eq $crashes + 1) ($x | ConvertTo-Json -Compress)
    $script:ClientCrashes = $crashes     # the stand-in is no crash of this run
}

# ---- the gateway merges after a PASS (Verbs.Merge.ps1 -Gateway, the sweep), a merge by a person settles the item, and the offer rules of issues 30
# and 31. The owner suite runs with timing.passMergeGraceSeconds 8 (run.ps1): long enough to see that the sweep waits, short enough to wait for it.
function Pm-State([int]$n) {
    $c = @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') }) | Select-Object -First 1
    if (-not $c) { return @{} }
    $m = [regex]::Match("$($c.body)", '```json\s*([\s\S]*?)```'); if (-not $m.Success) { return @{} }
    return ($m.Groups[1].Value | ConvertFrom-Json -AsHashtable)
}
# An item taken to Functional Testing with an open pull request (checks green), by the scripted holder w1.
function Pm-ToValidation([string[]]$Labels = $OwnerLabels) {
    $n = New-Item-Fake 'Gateway merge trial' 'x' $Labels
    Do-TechnicalDesign $n
    $pr = Do-Development $n
    Do-DevComplete $n | Out-Null
    [void](Wait-Until -Seconds 40 { (Get-FakeIssue $n).column -eq 'Functional Testing' })
    return @{ n = $n; pr = $pr }
}
# The rule script run directly with a copy of the suite's config (as an older gateway, or one that stopped right after recording, would leave it).
function Pm-Server([string]$Verb, $Body, [hashtable]$Cfg = @{}) {
    $cfgObj = Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable; foreach ($k in $Cfg.Keys) { $cfgObj[$k] = $Cfg[$k] }
    $path = Join-Path $script:Work "pm-$([guid]::NewGuid().ToString('N').Substring(0,6)).json"; $cfgObj | ConvertTo-Json -Depth 12 | Set-Content $path
    $old = $env:FACTORY_CONFIG; $env:FACTORY_CONFIG = $path
    try {
        $out = ($Body | ConvertTo-Json -Depth 8 -Compress) | & pwsh -NoProfile -File (Join-Path $script:Root 'plugin/scripts/factory.ps1') --server $Verb 2>$null
        $j = try { ($out -join "`n") | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $j.ContainsKey('exit')) { $j.exit = $LASTEXITCODE }; return $j
    } finally { $env:FACTORY_CONFIG = $old }
}
# A PASS recorded by the rule script alone, with the gateway's merge off for that one call: nothing merged it, as after a session that stopped.
function Pm-QuietPass($x) {
    $r = F 'w1' @('claim-item', '--item', $x.n, '--column', 'Functional Testing'); CheckExit 'FT claim' $r 0
    $rv = F 'w1' @('record-review', '--item', $x.n, '--column', 'Functional Testing', '--role', 'reviewer', '--text-file', (TmpFile "pmrv$($x.n).md" "Criteria exercised.`nREVIEW: COMPLETE"))
    return Pm-Server 'validation-verdict' @{ item = $x.n; passed = $true; summary = 'Both criteria met.'; pr = $x.pr; review_ref = $rv.review_ref; holder = 'w1' } @{ gatewayMerge = $false }
}
function Pm-MergeComments([int]$n, [int]$pr) { @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)" -match "squash-merged PR #$pr " }).Count }

$OwnerScenarios['pass-merge: a PASS on an Auto Merge item with green checks is merged by the verdict call itself; the session''s merge call answers already-merged'] = {
    $x = Pm-ToValidation
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'the verdict answer carries the merge: merged, and next is still merge' ((Pv $v 'merge') -and $v.merge.outcome -eq 'merged' -and $v.next -eq 'merge') ($v | ConvertTo-Json -Compress -Depth 5)
    Check 'the pull request is merged without a further call' ((Get-FakePr $x.pr).merged)
    $st = Pm-State $x.n
    Check 'the verdict is processed, the merge recorded and the claim released' ($st.verdict.processed -and $st.merge.awaiting -and -not $st.ContainsKey('claim')) ($st | ConvertTo-Json -Compress -Depth 4)
    $m = F 'w1' @('merge', '--item', $x.n, '--pr', $x.pr)
    Check 'the session''s own merge call is a no-op: exit 0, already-merged' ($m.exit -eq 0 -and $m.outcome -eq 'already-merged') ($m | ConvertTo-Json -Compress)
    Check 'merged once' ((Pm-MergeComments $x.n $x.pr) -eq 1)
}

$OwnerScenarios['pass-merge: a PASS nobody merged (the session stopped after the verdict) is merged by the sweep after the grace, with no call'] = {
    $x = Pm-ToValidation
    $v = Pm-QuietPass $x
    Check 'the PASS is recorded and nothing merged it' ($v.exit -eq 0 -and -not (Pv $v 'merge') -and -not (Get-FakePr $x.pr).merged) ($v | ConvertTo-Json -Compress -Depth 4)
    Start-Sleep -Seconds 3
    Check 'the sweep leaves it alone during the grace' (-not (Get-FakePr $x.pr).merged)
    Check 'the sweep merges it after the grace' (Wait-Until -Seconds 60 { (Get-FakePr $x.pr).merged })
    # the comment is written after the verdict is marked processed: wait for both
    $ok = Wait-Until -Seconds 20 { (Pm-State $x.n).verdict.processed -and @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match "the gateway squash-merged PR #$($x.pr) " }).Count -ge 1 }
    Check 'the verdict is processed and the merge comment says the gateway merged it' ($ok -and @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match "the gateway squash-merged PR #$($x.pr) " }).Count -eq 1)
}

$OwnerScenarios['pass-merge: a PASS recorded just before the gateway restarts is merged after the restart [full]'] = {
    $x = Pm-ToValidation
    $v = Pm-QuietPass $x; CheckExit 'the PASS verdict' $v 0
    Restart-Gateway
    Check 'the restarted gateway merges it' (Wait-Until -Seconds 60 { (Get-FakePr $x.pr).merged })
    Check 'merged once' ((Wait-Until -Seconds 20 { (Pm-MergeComments $x.n $x.pr) -eq 1 }))
}

$OwnerScenarios['pass-merge: checks still running at the verdict: the answer is waiting, the item is not offered to anyone, and it is merged when they go green'] = {
    Start-OwnerClient 'pmw' 'persistent-local' '--capacity 3'
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; delaySeconds = 20 } | Out-Null    # the checks of the head run again, for 20 s
    # the handoff offer of the item's arrival in Functional Testing (before the verdict) may still be on its way: let it land, then count from here
    [void](Wait-Until -Seconds 8 { @((Get-Assigned 'pmw' $x.n) | Where-Object { (Pv $_ 'column') -eq 'Functional Testing' }).Count -gt 0 })
    $offersBefore = (Get-Assigned 'pmw' $x.n).Count
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'the verdict answer: merge waiting for checks-pending' ((Pv $v 'merge') -and $v.merge.outcome -eq 'waiting' -and $v.merge.reason -eq 'checks-pending') ($v | ConvertTo-Json -Compress -Depth 5)
    [void](F 'w1' @('claim-item', '--item', $x.n, '--release', 'true'))     # the session is gone: no live claim
    Start-Sleep -Seconds 6
    $pu = @((Get-Plant).plant.passUnmerged | Where-Object { $_.item -eq $x.n })
    Check '/status lists it as pass-unmerged with its reason' ($pu.Count -eq 1 -and $pu[0].code -eq 'checks-pending' -and $pu[0].pr -eq $x.pr) ((Get-Plant).plant.passUnmerged | ConvertTo-Json -Compress)
    # (an offer before the verdict, while the scripted holder moved the item between columns, is not one of this state)
    $offersAfter = @((Get-Assigned 'pmw' $x.n) | Select-Object -Skip $offersBefore)
    Check 'no offer for it reached a worker (it is the gateway''s to merge)' (@($offersAfter | Where-Object { (Pv $_ 'column') -eq 'Functional Testing' }).Count -eq 0) ($offersAfter | ConvertTo-Json -Compress)
    Check 'merged when the checks are green, with no session' (Wait-Until -Seconds 60 { (Get-FakePr $x.pr).merged })
    $mw = @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match '<!-- plant event=merge-waiting ' }).Count
    Check 'journal: merge-waiting once, however many sweeps found it waiting' ($mw -eq 1) "$mw"
    # the merge comment follows the merge after the state write (Verbs.Merge.ps1): wait for it, then make sure no second merge adds another
    [void](Wait-Until -Seconds 20 { (Pm-MergeComments $x.n $x.pr) -ge 1 }); Start-Sleep -Seconds 3
    Check 'merged once' ((Pm-MergeComments $x.n $x.pr) -eq 1) "$(Pm-MergeComments $x.n $x.pr)"
    Stop-OwnerClient 'pmw'
}

$OwnerScenarios['pass-merge: a pull request that cannot be merged takes the existing demote path once, and the sweep does not loop'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; conflict = $true } | Out-Null
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'the verdict answer: demoted, and next says so' ($v.merge.outcome -eq 'demoted' -and $v.next -eq 'demoted') ($v | ConvertTo-Json -Compress -Depth 5)
    Start-Sleep -Seconds 8
    $st = Pm-State $x.n
    Check 'back in Development once, not merged' ((Get-FakeIssue $x.n).column -eq 'Development' -and $st.demotions -eq 1 -and -not (Get-FakePr $x.pr).merged) "$((Get-FakeIssue $x.n).column) $($st.demotions)"
    Check 'one merge-failed comment after several sweeps' (@((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match 'merge failed' }).Count -eq 1)
}

$OwnerScenarios['pass-merge: an item without the Auto Merge label, or a verdict under another merge policy, is not merged by the gateway'] = {
    $x = Pm-ToValidation @('factory worker')
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'no label: parked for a person, no merge attempted' ($v.next -eq 'parked' -and -not (Pv $v 'merge')) ($v | ConvertTo-Json -Compress -Depth 4)
    $y = Pm-ToValidation
    $r = F 'w1' @('claim-item', '--item', $y.n, '--column', 'Functional Testing'); CheckExit 'FT claim' $r 0
    $rv = F 'w1' @('record-review', '--item', $y.n, '--column', 'Functional Testing', '--role', 'reviewer', '--text-file', (TmpFile "pmrv$($y.n).md" "ok`nREVIEW: COMPLETE"))
    $pv = Pm-Server 'validation-verdict' @{ item = $y.n; passed = $true; summary = 'ok'; pr = $y.pr; review_ref = $rv.review_ref; holder = 'w1' } @{ mergePolicy = 'peer-approved' }
    Check 'peer-approved: the verdict asks for the approval and merges nothing' ($pv.exit -eq 0 -and $pv.next -eq 'approve' -and -not (Pv $pv 'merge') -and -not (Get-FakePr $y.pr).merged) ($pv | ConvertTo-Json -Compress -Depth 4)
    Start-Sleep -Seconds 6
    Check 'the item without the label is still not merged after several sweeps' (-not (Get-FakePr $x.pr).merged)
}

$OwnerScenarios['pass-merge: a push after the verdict voids it: not merged, the item goes back to Development'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; delaySeconds = 30 } | Out-Null
    $v = Do-Verdict $x.n $x.pr; Check 'the verdict waits for the checks' ($v.merge.outcome -eq 'waiting') ($v | ConvertTo-Json -Compress -Depth 5)
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('docs/trial.md', 'docs/later.md'); profile = 'green' } | Out-Null
    Check 'the sweep sends it back to Development' (Wait-Until -Seconds 40 { (Get-FakeIssue $x.n).column -eq 'Development' })
    [void](Wait-Until -Seconds 20 { @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match 'changed after the validation verdict' }).Count -ge 1 })
    $why = @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)" -match 'changed after the validation verdict' -and -not "$($_.body)".StartsWith('<!-- factory-state:') }).Count
    Check 'not merged, and the reason names the change after the verdict, once' (-not (Get-FakePr $x.pr).merged -and $why -eq 1) "merged=$((Get-FakePr $x.pr).merged) comments=$why"
}

$OwnerScenarios['pass-merge: the session''s merge call racing the sweep merges once [full]'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; delaySeconds = 6 } | Out-Null
    $v = Pm-QuietPass $x; CheckExit 'the PASS verdict' $v 0
    Start-Sleep -Seconds 7     # the grace is nearly over: the sweep and the session's call meet while the checks finish
    $m = F 'w1' @('merge', '--item', $x.n, '--pr', $x.pr)
    Check 'the session''s merge: merged or already-merged' ($m.exit -eq 0 -and $m.outcome -in 'merged', 'already-merged') ($m | ConvertTo-Json -Compress -Depth 4)
    Start-Sleep -Seconds 6
    Check 'merged once' ((Get-FakePr $x.pr).merged -and (Pm-MergeComments $x.n $x.pr) -eq 1) "$(Pm-MergeComments $x.n $x.pr)"
}

$OwnerScenarios['pass-merge: a pull request merged by a person settles the item from Development and from a PASS parked for a person'] = {
    $n = New-Item-Fake 'Merged by hand' 'x' $OwnerLabels
    Do-TechnicalDesign $n
    $pr = Do-Development $n
    Fake 'pr' @{ number = $pr; merged = $true } | Out-Null
    Check 'the sweep picks the merge up while the item is in Development' (Wait-Until -Seconds 40 { (Pm-State $n).ContainsKey('merge') })
    # (the sweep saves the merge record before it moves the card: wait for both)
    Check 'the merge is recorded, the claim released, the card moved on from Development' (Wait-Until -Seconds 20 { $st = Pm-State $n; $st.merge.pr -eq $pr -and -not $st.ContainsKey('claim') -and (Get-FakeIssue $n).column -ne 'Development' }) "$((Get-FakeIssue $n).column) $(Pm-State $n | ConvertTo-Json -Compress -Depth 3)"
    Check 'the journal says a person merged it' (Wait-Until -Seconds 20 { @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)" -match "PR #$pr was merged as .* by a person" }).Count -eq 1 })
    $x = Pm-ToValidation @('factory worker')
    $v = Do-Verdict $x.n $x.pr; Check 'parked for a person' ($v.next -eq 'parked')
    Fake 'pr' @{ number = $x.pr; merged = $true } | Out-Null
    Check 'the parked item is settled when the person merges' (Wait-Until -Seconds 40 { $s2 = Pm-State $x.n; $s2.ContainsKey('merge') -and -not $s2.ContainsKey('park') })
}

$OwnerScenarios['offers: a late accept of a withdrawn offer is refused (stale-assignment) and never takes a worker over its capacity'] = {
    foreach ($k in @($script:Workers.Keys)) { Stop-OwnerClient $k }
    Start-OwnerClient 'late1' 'persistent-local' '--capacity 1'
    $a = New-Item-Fake 'Late accept A' 'x' $OwnerLabels
    Check 'A is offered to late1' (Wait-Until -Seconds 30 { (Get-Assigned 'late1' $a).Count -gt 0 })
    $offA = (Get-Assigned 'late1' $a)[0]
    Check 'the offer of A lapses' (Wait-Until -Seconds 30 { (Get-Journal $a) -contains 'reassigned' })
    $b = New-Item-Fake 'Late accept B' 'x' $OwnerLabels
    Check 'B is offered to late1 in the slot A held' (Wait-Until -Seconds 30 { (Get-Assigned 'late1' $b).Count -gt 0 })
    $late = Fo 'late1' @('accept', '--item', $a, '--assignment', $offA.assignment)
    Check 'the late accept of A is refused: exit 11 stale-assignment' ($late.exit -eq 11 -and $late.code -eq 'stale-assignment') ($late | ConvertTo-Json -Compress)
    $rb = Fo 'late1' @('accept', '--item', $b, '--assignment', (Get-Assigned 'late1' $b)[0].assignment); CheckExit 'the standing offer of B is accepted' $rb 0
    $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'late1' })[0]
    Check 'late1 owns no more than its capacity' ($w.owned -le $w.capacity) ($w | ConvertTo-Json -Compress)
    [void](Fo 'late1' @('release', '--item', $b, '--reason', 'scenario done'))
    Stop-OwnerClient 'late1'
}

$OwnerScenarios['offers: a session that let two offers in a row lapse is not offered more until it calls a verb, and the status shows the cool-down'] = {
    foreach ($k in @($script:Workers.Keys)) { Stop-OwnerClient $k }
    Start-OwnerClient 'cool1' 'persistent-local' '--capacity 3'
    $x1 = New-Item-Fake 'Cool-down 1' 'x' $OwnerLabels; $x2 = New-Item-Fake 'Cool-down 2' 'x' $OwnerLabels
    Check 'both are offered to cool1' (Wait-Until -Seconds 30 { (Get-Assigned 'cool1' $x1).Count -gt 0 -and (Get-Assigned 'cool1' $x2).Count -gt 0 })
    Check 'both offers lapse and the status shows the cool-down' (Wait-Until -Seconds 30 { $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'cool1' })[0]; $w -and $w.coolDownUntil })
    $x3 = New-Item-Fake 'Cool-down 3' 'x' $OwnerLabels
    Start-Sleep -Seconds 8
    Check 'a new item is not offered to it while it cools down' ((Get-Assigned 'cool1' $x3).Count -eq 0)
    $mi = Fo 'cool1' @('my-items'); CheckExit 'the session calls a verb' $mi 0
    Check 'the cool-down ends with it' (Wait-Until -Seconds 10 { $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'cool1' })[0]; $w -and -not $w.coolDownUntil })
    Check 'and the new item is offered to it' (Wait-Until -Seconds 30 { (Get-Assigned 'cool1' $x3).Count -gt 0 })
    Stop-OwnerClient 'cool1'
}

$OwnerScenarios['pass-merge: a branch behind its base is brought up to date by the gateway, its merge commit is verified and merged'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; behind = 1 } | Out-Null
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'merged on the gateway''s update commit, with no session' (Wait-Until -Seconds 60 { (Get-FakePr $x.pr).merged })
    Check 'the verdict now names the update commit' ((Pm-State $x.n).verdict.head_sha -eq (Get-FakePr $x.pr).sha -and -not (Pm-State $x.n).verdict.ContainsKey('updated_from'))
}

$OwnerScenarios['pass-merge: a push that lands while the gateway''s update of the branch is still pending is not merged: demoted (stale-head)'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; behind = 1; updateNoop = $true } | Out-Null     # GitHub accepts the update and has not made it yet
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'the verdict waits for the update' ($v.merge.outcome -eq 'waiting' -and -not (Get-FakePr $x.pr).merged) ($v | ConvertTo-Json -Compress -Depth 5)
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('docs/trial.md', 'docs/sneak.md'); profile = 'green' } | Out-Null
    Check 'the sweep sends it back to Development' (Wait-Until -Seconds 40 { (Get-FakeIssue $x.n).column -eq 'Development' })
    Check 'the pushed head is not merged' (-not (Get-FakePr $x.pr).merged)
}

$OwnerScenarios['pass-merge: a PASS for a head other than the current one is refused, and a verdict without a head is never merged by the gateway'] = {
    $x = Pm-ToValidation
    $r = F 'w1' @('claim-item', '--item', $x.n, '--column', 'Functional Testing'); CheckExit 'FT claim' $r 0
    $rv = F 'w1' @('record-review', '--item', $x.n, '--column', 'Functional Testing', '--role', 'reviewer', '--text-file', (TmpFile "hs$($x.n).md" "ok`nREVIEW: COMPLETE"))
    $bad = F 'w1' @('validation-verdict', '--item', $x.n, '--passed', 'true', '--summary-file', (TmpFile "hsv$($x.n).md" 'ok'), '--pr', $x.pr, '--review-ref', $rv.review_ref, '--head-sha', ('0' * 40))
    Check 'another head: exit 10 head-mismatch, nothing recorded' ($bad.exit -eq 10 -and $bad.code -eq 'head-mismatch' -and -not (Pm-State $x.n).ContainsKey('verdict')) ($bad | ConvertTo-Json -Compress)
    $ok = F 'w1' @('validation-verdict', '--item', $x.n, '--passed', 'true', '--summary-file', (TmpFile "hsv2$($x.n).md" 'ok'), '--pr', $x.pr, '--review-ref', $rv.review_ref, '--head-sha', (Get-FakePr $x.pr).sha)
    Check 'the tested head: merged' ($ok.exit -eq 0 -and $ok.merge.outcome -eq 'merged') ($ok | ConvertTo-Json -Compress -Depth 4)
    $y = Pm-ToValidation
    $q = Pm-QuietPass $y; CheckExit 'a PASS recorded quietly' $q 0
    # a verdict recorded before this change, or whose head GitHub could not tell: the head is missing
    $st = Pm-State $y.n; $cm = @((Get-FakeIssue $y.n).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') })[0]
    $st.verdict.Remove('head_sha'); $json = $st | ConvertTo-Json -Depth 12
    $nb = "$($cm.body)" -replace '(?s)```json.*```', "``````json`n$json`n``````"
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/comments/$($cm.id)" -Method PATCH -Headers @{ Authorization = "Bearer $env:GH_TOKEN" } -Body (@{ body = $nb } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    Check 'the gateway parks it instead of merging (verdict-head-unknown)' (Wait-Until -Seconds 40 { $ps0 = Pm-State $y.n; (Pv $ps0 'park') -and "$($ps0.park.reason)" -eq 'pass-unmerged' })
    Check 'not merged' (-not (Get-FakePr $y.pr).merged)
}

$OwnerScenarios['pass-merge: a hand-made two-parent merge pushed by a worker while the gateway''s update is pending is not merged: demoted (stale-head)'] = {
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; behind = 1; updateNoop = $true } | Out-Null
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('docs/trial.md', 'docs/sneak.md'); profile = 'green'; parents = @('head', 'base') } | Out-Null
    Check 'the sweep sends it back to Development' (Wait-Until -Seconds 40 { (Get-FakeIssue $x.n).column -eq 'Development' })
    Check 'the hand-made merge is not merged' (-not (Get-FakePr $x.pr).merged)
}

$OwnerScenarios['owner: the plant survives a graceful restart: owner, accepted assignment and an unanswered offer come back, and the offer is accepted after it [full]'] = {
    # the suite's accept window is 4 s: the offer would lapse before the restart. This scenario runs on a gateway with a 60 s window (started
    # by an outright kill, which writes no snapshot) and the suite's window comes back in finally, the same way.
    # The suites run with the snapshot off (run.ps1); it is on for this scenario's gateways.
    $oldAck = $env:FACTORY_ASSIGN_ACK_SECONDS; $env:FACTORY_ASSIGN_ACK_SECONDS = '60'; $oldSnap = $env:FACTORY_PLANT_SNAPSHOT; $env:FACTORY_PLANT_SNAPSHOT = '1'; Restart-Gateway
    try {
        Start-OwnerClient 'sara' 'persistent-local' '--capacity 2'
        # pinned: a worker left connected by an earlier scenario must not take them
        $a = New-Item-Fake 'Snapshot owned' 'x' ($OwnerLabels + 'worker:sara'); $b = New-Item-Fake 'Snapshot offered' 'x' ($OwnerLabels + 'worker:sara')
        [void](Wait-Until -Seconds 40 { (Get-Assigned 'sara' $a).Count -gt 0 -and (Get-Assigned 'sara' $b).Count -gt 0 })
        $ea = (Get-Assigned 'sara' $a)[0]; $eb = (Get-Assigned 'sara' $b)[0]
        $r = Fo 'sara' @('accept', '--item', $a, '--assignment', $ea.assignment); CheckExit 'sara accepts the first item' $r 0
        $before = Get-Plant
        Restart-Gateway -Graceful
        $logs = Get-ChildItem -Path $script:Work -File -Filter 'gateway*.out' | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_ -match '"gateway":"plant-(snapshot|restore)"' }
        $saved = $logs | Where-Object { $_ -match '"gateway":"plant-snapshot"' -and $_ -match '"exit":0' }
        Check 'at SIGTERM the gateway wrote its plant to GitHub: exit 0' (@($saved).Count -ge 1) (($logs -join "`n") + ' ' + (((Get-FakeState).refs) -join ' '))
        [void](Wait-Until -Seconds 60 { $null -ne (Get-Plant).plantSnapshot.restore })
        $st = Get-Plant; $rs = $st.plantSnapshot.restore
        Check 'the next start restored it before its first sweep: assignments and the owner' ($rs.skipped -eq '' -and $rs.assignments -ge 2 -and $rs.owners -ge 1) ($rs | ConvertTo-Json -Compress)
        Check 'the snapshot is used once: the start removed the ref after reading it' ((Wait-Until -Seconds 30 { @((Get-FakeState).refs | Where-Object { $_ -match '/plant-snapshot$' }).Count -eq 0 })) (((Get-FakeState).refs) -join ' ')
        Check 'the owner of the accepted item is the same' (@($st.plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$a" -and $_.Value -eq 'sara' }).Count -eq 1) ($st.plant.owners | ConvertTo-Json -Compress)
        $ra = @($st.plant.assignments | Where-Object { $_.item -eq $a }); $rb = @($st.plant.assignments | Where-Object { $_.item -eq $b })
        Check 'the accepted assignment keeps its id and stays accepted' ($ra.Count -eq 1 -and $ra[0].id -eq $ea.assignment -and $ra[0].accepted -eq $true -and $ra[0].worker -eq 'sara') ($ra | ConvertTo-Json -Compress)
        Check 'the unanswered offer keeps its id and its worker' ($rb.Count -eq 1 -and $rb[0].id -eq $eb.assignment -and $rb[0].accepted -eq $false -and $rb[0].worker -eq 'sara') "$($rb | ConvertTo-Json -Compress) before: $(@($before.plant.assignments | Where-Object { $_.item -eq $b }) | ConvertTo-Json -Compress)"
        # the client reconnects by itself; its registration pushes the offer again, with the same assignment
        [void](Wait-Until -Seconds 45 { (Get-Assigned 'sara' $b).Count -ge 2 })
        $eb2 = (Get-Assigned 'sara' $b)[-1]
        Check 'the reconnected worker is offered the item again, the same assignment' ((Get-Assigned 'sara' $b).Count -ge 2 -and $eb2.assignment -eq $eb.assignment) ((Get-Assigned 'sara' $b) | ConvertTo-Json -Compress)
        $r2 = Fo 'sara' @('accept', '--item', $b, '--assignment', $eb2.assignment); CheckExit 'and accepts it' $r2 0
        $st2 = Get-Plant
        Check 'both items are owned by sara after the restart' (@($st2.plant.owners.PSObject.Properties | Where-Object { $_.Name -in "$a", "$b" -and $_.Value -eq 'sara' }).Count -eq 2) ($st2.plant.owners | ConvertTo-Json -Compress)
        Check 'the journal has one matched line for the offered item: the restore wrote none' (@(Get-Journal $b | Where-Object { $_ -eq 'matched' }).Count -eq 1) ((Get-Journal $b) -join ',')
        # issue 81: the accepted item is resent to the reconnected owner (mode resume, resent), so a session that lost its event still works it
        $ra2 = @((Get-Assigned 'sara' $a) | Where-Object { $_['resent'] -eq $true })
        Check 'the reconnected owner is resent its accepted item: same assignment, mode resume, a token saved' ($ra2.Count -ge 1 -and $ra2[-1].assignment -eq $ea.assignment -and $ra2[-1].mode -eq 'resume' -and $ra2[-1]['accepted'] -eq $true) ((Get-Assigned 'sara' $a) | ConvertTo-Json -Compress)
        Check 'the client does not accept a resent item again' (@(Get-WorkerEvents 'sara' | Where-Object { $_.event -eq 'item.accepted' -and $_.item -eq $a }).Count -le 1) (@(Get-WorkerEvents 'sara' | Where-Object { $_.item -eq $a }) | ConvertTo-Json -Compress)
    } finally {
        Stop-OwnerClient 'sara'
        # the next restart of this suite must not restore this scenario's plant
        foreach ($ref in @((Get-FakeState).refs | Where-Object { $_ -match '/plant-snapshot$' })) {
            try { Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/git/$ref" -Method DELETE -Headers @{ Authorization = 'Bearer fake-operator' } | Out-Null } catch { }
        }
        $env:FACTORY_ASSIGN_ACK_SECONDS = $oldAck; $env:FACTORY_PLANT_SNAPSHOT = $oldSnap; Restart-Gateway
    }
}

# One work item per worker session (docs/launcher.md): a session that held an item is offered no other, even after that item is
# released; a new registration of the same name (a stream without a cursor, as the launcher's next session opens it) is a new session and is offered one.
$OwnerScenarios['owner: one item per session: a session that held an item is offered no second one; the next session of the name is, and the status counts items per session'] = {
    $oldOne = $env:FACTORY_ONE_ITEM_PER_SESSION
    try {
        # this scenario's waits are timed for a 4 s accept window (the suite runs with 8)
        $oldAckOne = $env:FACTORY_ASSIGN_ACK_SECONDS; $env:FACTORY_ASSIGN_ACK_SECONDS = '4'
        $env:FACTORY_ONE_ITEM_PER_SESSION = '1'; Restart-Gateway
        Start-OwnerClient 'fresh1' 'persistent-local' '--capacity 5'      # capacity 5: what holds the second item back is the rule, not the capacity
        $me = { @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'fresh1' })[0] }
        $w0 = & $me
        Check 'the status says the rule is on and shows the session of the worker, with no item yet' ((Get-Plant).plant.oneItemPerSession -eq $true -and $w0.session -ge 1 -and @($w0.sessionItems).Count -eq 0 -and $w0.sessionSpent -eq $false) ($w0 | ConvertTo-Json -Compress -Depth 4)
        $s0 = [int]$w0.session
        # pinned: clients of earlier scenarios reconnect to the restarted gateway and must not take these items
        $a = New-Item-Fake 'Fresh session A' 'x' ($OwnerLabels + 'worker:fresh1')
        Check 'the first item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'fresh1' $a).Count -gt 0 })
        $b = New-Item-Fake 'Fresh session B' 'x' ($OwnerLabels + 'worker:fresh1')
        Start-Sleep -Seconds 6
        $openOffers = @((Get-Plant).plant.assignments | Where-Object { $_.worker -eq 'fresh1' -and -not $_.accepted })
        Check 'the session has at most one open offer at a time' ($openOffers.Count -le 1) ($openOffers | ConvertTo-Json -Compress)
        $r = Fo 'fresh1' @('accept', '--item', $a, '--assignment', (Get-Assigned 'fresh1' $a)[-1].assignment); CheckExit 'the session accepts the first item' $r 0
        $sinceAccept = (Get-Assigned 'fresh1' $b).Count
        $w1 = & $me
        Check 'the status lists the item under this session and marks it spent' (@($w1.sessionItems) -contains $a -and $w1.sessionSpent -eq $true -and [int]$w1.session -eq $s0) ($w1 | ConvertTo-Json -Compress -Depth 4)
        Start-Sleep -Seconds 6
        $ob = @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $b })
        Check 'the second item is not offered to the session that holds the first (an offer sent before the accept is taken back)' ((Get-Assigned 'fresh1' $b).Count -eq $sinceAccept -and $ob.Count -eq 1 -and "$($ob[0].worker)" -eq '') ($ob | ConvertTo-Json -Compress)
        $r = Fo 'fresh1' @('release', '--item', $a, '--reason', 'scenario: the item ends'); CheckExit 'the session releases its item' $r 0
        Start-Sleep -Seconds 8     # sweeps and ticks: the session is no longer at any capacity
        Check 'after its item was released the same session is still offered no other item' ((Get-Assigned 'fresh1' $b).Count -eq $sinceAccept)
        $wb = @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $b })
        Check 'the second item waits, without a worker' ($wb.Count -eq 1 -and "$($wb[0].worker)" -eq '') ($wb | ConvertTo-Json -Compress)
        $mk = Join-Path $script:Work 'fresh1-session-ended'
        $e = Fo 'fresh1' @('end-session', '--name', 'fresh1', '--marker', $mk); CheckExit 'end-session' $e 0
        Check 'end-session drains the name and writes the end marker for the launcher' ($e.drained -eq $true -and $e.markerWritten -eq $true -and (Test-Path $mk) -and (& $me).draining -eq $true) ($e | ConvertTo-Json -Compress)
        # the launcher's next session: a new process registers the same name without a cursor
        Stop-OwnerClient 'fresh1'
        [void](Wait-Until -Seconds 20 { -not (& $me).connected })
        Start-OwnerClient 'fresh1' 'persistent-local' '--capacity 5'
        $got = Wait-Until -Seconds 40 { (Get-Assigned 'fresh1' $b).Count -gt 0 -or (Get-Assigned 'fresh1' $a).Count -gt 1 }
        $w2 = & $me
        Check 'a new registration of the name is a new session, no longer draining, offered a work item again' ($got -and [int]$w2.session -eq $s0 + 1 -and $w2.draining -eq $false) ($w2 | ConvertTo-Json -Compress -Depth 4)
        $prev = @($w2.itemsPerSession | Where-Object { [int]$_.session -eq $s0 })
        Check 'itemsPerSession keeps the earlier session with its one item' ($prev.Count -eq 1 -and @($prev[0].items).Count -eq 1 -and @($prev[0].items)[0] -eq $a) ($w2.itemsPerSession | ConvertTo-Json -Compress -Depth 4)
        Start-Sleep -Seconds 6
        $open = @((Get-Plant).plant.assignments | Where-Object { $_.worker -eq 'fresh1' -and -not $_.accepted })
        Check 'the new session has one open offer, not two' ($open.Count -eq 1) ($open | ConvertTo-Json -Compress)
    } finally {
        Stop-OwnerClient 'fresh1'
        $env:FACTORY_ASSIGN_ACK_SECONDS = $oldAckOne
        $env:FACTORY_ONE_ITEM_PER_SESSION = $oldOne; Restart-Gateway
    }
}

# Issue 72: a session whose item ended without the model running end-session (taken back, released, demoted, reassigned) is told session.end by
# the gateway, and its stream client writes the launcher's end marker itself, so the launcher starts a fresh session instead of the name idling.
$OwnerScenarios['owner: one item per session: a spent session that owns nothing is told session.end and its client writes the launcher marker'] = {
    $oldOne = $env:FACTORY_ONE_ITEM_PER_SESSION; $oldGrace = $env:FACTORY_TIMING_sessionEndGraceSeconds; $oldEnd = $env:FACTORY_SESSION_END_FILE
    $mk = Join-Path $script:Work 'spent1-work/session-ended'
    try {
        $env:FACTORY_ONE_ITEM_PER_SESSION = '1'; $env:FACTORY_TIMING_sessionEndGraceSeconds = '3'; Restart-Gateway
        $env:FACTORY_SESSION_END_FILE = $mk
        Start-OwnerClient 'spent1' 'persistent-local'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        $a = New-Item-Fake 'Spent session' 'x' ($OwnerLabels + 'worker:spent1')
        Check 'the item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'spent1' $a).Count -gt 0 })
        $r = Fo 'spent1' @('accept', '--item', $a, '--assignment', (Get-Assigned 'spent1' $a)[-1].assignment)
        Check 'the session holds the item (the client or the session accepted it)' ($r.exit -eq 0 -or (Wait-Until -Seconds 20 { @(Get-WorkerEvents 'spent1' | Where-Object { $_.event -eq 'item.accepted' }).Count -gt 0 })) ($r | ConvertTo-Json -Compress)
        Start-Sleep -Seconds 6
        Check 'while it owns its item the session is not told to end' (@(Get-WorkerEvents 'spent1' | Where-Object { $_.event -eq 'session.end' }).Count -eq 0 -and -not (Test-Path $mk))
        $r = Fo 'spent1' @('release', '--item', $a, '--reason', 'scenario: the item is taken from this session'); CheckExit 'the item leaves the session' $r 0
        Check 'the gateway tells the spent session to end' (Wait-Until -Seconds 30 { @(Get-WorkerEvents 'spent1' | Where-Object { $_.event -eq 'session.end' }).Count -gt 0 })
        $se = @(Get-WorkerEvents 'spent1' | Where-Object { $_.event -eq 'session.end' })
        Check 'session.end names the session and its item, and the client wrote the marker' ($se.Count -eq 1 -and @($se[0].items) -contains $a -and $se[0].markerWritten -eq $true -and (Test-Path $mk)) ($se | ConvertTo-Json -Compress -Depth 4)
        Start-Sleep -Seconds 6
        Check 'it is sent once per session' (@(Get-WorkerEvents 'spent1' | Where-Object { $_.event -eq 'session.end' }).Count -eq 1)
    } finally {
        Stop-OwnerClient 'spent1'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        $env:FACTORY_ONE_ITEM_PER_SESSION = $oldOne; $env:FACTORY_TIMING_sessionEndGraceSeconds = $oldGrace; Restart-Gateway
    }
}

# Issue 96: an accepted assignment whose worker no longer owns the item is dropped at sweep time (two sweeps in a row), so it does not keep a spent
# session from session.end. Two ways: another session took the claim over (the sweep names it the owner), and an item that sits in the Release
# Queue (its item.complete was missed: owner and assignment are dropped once two sweeps found it queued).
$OwnerScenarios['owner: a stale accepted assignment is dropped by the sweep and the spent session is told session.end [full]'] = {
    $oldOne = $env:FACTORY_ONE_ITEM_PER_SESSION; $oldGrace = $env:FACTORY_TIMING_sessionEndGraceSeconds
    $acc = { param($w, $i) @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $i -and $_.accepted -and $_.worker -eq $w }).Count }
    $ends = { param($w) @(Get-WorkerEvents $w | Where-Object { $_.event -eq 'session.end' }).Count }
    try {
        $env:FACTORY_ONE_ITEM_PER_SESSION = '1'; $env:FACTORY_TIMING_sessionEndGraceSeconds = '3'; Restart-Gateway
        # another session holds the claim now (a take-over the plant did not see)
        Start-OwnerClient 'stale1' 'persistent-local'
        $n = New-Item-Fake 'Stale assignment' 'x' ($OwnerLabels + 'worker:stale1')
        Check 'the item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'stale1' $n).Count -gt 0 })
        $r = Fo 'stale1' @('accept', '--item', $n, '--assignment', (Get-Assigned 'stale1' $n)[-1].assignment)
        Check 'stale1 holds it' (Wait-Until -Seconds 20 { (& $acc 'stale1' $n) -eq 1 })
        Set-ItemState $n { param($st) $st.claim.holder = 'other1'; $st.claim.worker = 'other1'; $st.claim.lease_until = (Get-Date).ToUniversalTime().AddHours(1).ToString('o') }
        Check 'the sweep names the other session the owner' (Wait-Until -Seconds 40 { "$((Get-Plant).plant.owners."$n")" -eq 'other1' })
        Check 'the stale accepted assignment is dropped' (Wait-Until -Seconds 120 { (& $acc 'stale1' $n) -eq 0 }) ((Get-Plant).plant.assignments | ConvertTo-Json -Compress)
        Check 'and the spent session is told session.end' (Wait-Until -Seconds 30 { (& $ends 'stale1') -ge 1 })
        Check 'the status counts it' ([int](Get-Plant).plant.staleAssignmentsDropped -ge 1)

        # an item in the Release Queue whose item.complete was missed
        Start-OwnerClient 'stale2' 'persistent-local'
        $m = New-Item-Fake 'Queued item' 'x' ($OwnerLabels + 'worker:stale2')
        Check 'the second item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'stale2' $m).Count -gt 0 })
        $r = Fo 'stale2' @('accept', '--item', $m, '--assignment', (Get-Assigned 'stale2' $m)[-1].assignment)
        Check 'stale2 holds it' (Wait-Until -Seconds 20 { (& $acc 'stale2' $m) -eq 1 })
        $at = (Get-Date).ToUniversalTime().ToString('o')
        Set-ItemState $m { param($st) $st.merge = @{ sha = ('d' * 40); merged_at = $at; awaiting = 'release-queue'; release = '1.0.1'; queued_at = $at } }
        [void](Fake 'move' @{ number = $m; column = 'Release Queue' })
        Check 'owner and assignment are dropped' (Wait-Until -Seconds 180 { (& $acc 'stale2' $m) -eq 0 -and "$m" -notin @((Get-Plant).plant.owners.PSObject.Properties.Name) }) (@{ releaseQueue = (Get-Plant).releaseQueue; owners = (Get-Plant).plant.owners; state = (Get-ItemState $m) } | ConvertTo-Json -Compress -Depth 6)
        Check 'and the spent session is told session.end' (Wait-Until -Seconds 30 { (& $ends 'stale2') -ge 1 })
    } finally {
        Stop-OwnerClient 'stale1'; Stop-OwnerClient 'stale2'
        $env:FACTORY_ONE_ITEM_PER_SESSION = $oldOne; $env:FACTORY_TIMING_sessionEndGraceSeconds = $oldGrace; Restart-Gateway
    }
}

# Issue 109: a hold label (holdLabels, default hold:owner) is honoured like Demo: a person holds the item, so nothing is offered for it, its open offer
# is dropped and claim-item is refused; without the label it is offered again.
$OwnerScenarios['owner: a hold:owner label holds the item for a person: no offer, the open one dropped, claim-item refused; offered again without it'] = {
    $api = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders"; $gh = @{ Authorization = 'Bearer fake-operator' }
    try {
        Start-OwnerClient 'hld1' 'persistent-local'
        $n = New-Item-Fake 'Held by the owner' 'x' ($OwnerLabels + 'worker:hld1')
        Check 'the item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'hld1' $n).Count -gt 0 })
        $open = { @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $n }) }
        Check 'its offer is open in the plant' (@(& $open).Count -eq 1)
        Invoke-RestMethod "$api/issues/$n/labels" -Method POST -Headers $gh -Body (@{ labels = @('hold:owner') } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        Check 'with the label the next sweep drops the open offer' (Wait-Until -Seconds 30 { @(& $open).Count -eq 0 }) ((& $open) | ConvertTo-Json -Compress)
        $seen = (Get-Assigned 'hld1' $n).Count
        Start-Sleep -Seconds 8
        Check 'and offers it to nobody' ((Get-Assigned 'hld1' $n).Count -eq $seen -and @(& $open).Count -eq 0)
        $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Technical Design'); CheckExit 'claim-item is refused' $r 10 'held-by-label'
        $r = Fo 'hld1' @('accept', '--item', $n, '--assignment', (Get-Assigned 'hld1' $n)[-1].assignment)
        Check 'an accept of the old offer is refused: it is no longer standing' ($r.exit -eq 11 -and $r.code -eq 'stale-assignment') ($r | ConvertTo-Json -Compress)
        Invoke-RestMethod "$api/issues/$n/labels/hold%3Aowner" -Method DELETE -Headers $gh | Out-Null
        Check 'without the label it is offered again' (Wait-Until -Seconds 40 { (Get-Assigned 'hld1' $n).Count -gt $seen })
    } finally { Stop-OwnerClient 'hld1' }
}

# Issue 107: the owner is released at item.merged. The gateway settles the item from the merge on (master green, release, Done), so the owner's
# session is spent and owns nothing at once: it is told session.end instead of idling until the item reaches the Release Queue or Done.
$OwnerScenarios['owner: the owner is released at item.merged, its session is told session.end, and the gateway settles the item to Done'] = {
    $oldOne = $env:FACTORY_ONE_ITEM_PER_SESSION; $oldGrace = $env:FACTORY_TIMING_sessionEndGraceSeconds; $oldEnd = $env:FACTORY_SESSION_END_FILE
    $mk = Join-Path $script:Work 'mrg1-work/session-ended'
    try {
        $env:FACTORY_ONE_ITEM_PER_SESSION = '1'; $env:FACTORY_TIMING_sessionEndGraceSeconds = '3'; Restart-Gateway
        # the item is taken to Functional Testing by the scripted holder first, with no session connected, so its first offer is the FT hand-off
        $x = Pm-ToValidation ($OwnerLabels + 'worker:mrg1')
        $env:FACTORY_SESSION_END_FILE = $mk
        Start-OwnerClient 'mrg1' 'persistent-local'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        Check 'the item is offered in Functional Testing' (Wait-Until -Seconds 40 { (Get-Assigned 'mrg1' $x.n).Count -gt 0 })
        $r = Fo 'mrg1' @('accept', '--item', $x.n, '--assignment', (Get-Assigned 'mrg1' $x.n)[-1].assignment); CheckExit 'the session accepts it' $r 0
        Check 'the plant names mrg1 its owner' (@((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$($x.n)" -and $_.Value -eq 'mrg1' }).Count -eq 1)
        $v = Do-Verdict $x.n $x.pr 'mrg1'; CheckExit 'the PASS verdict' $v 0
        Check 'the gateway merged it' (Wait-Until -Seconds 40 { (Get-FakePr $x.pr).merged })
        Check 'the owner heard item.merged' (Wait-Until -Seconds 20 { @(Get-WorkerEvents 'mrg1' | Where-Object { $_.event -eq 'item.merged' -and $_.item -eq $x.n }).Count -ge 1 })
        $owned = { @((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$($x.n)" }).Count -gt 0 }
        Check 'and is released at once: the plant names no owner for the merged item' (Wait-Until -Seconds 10 { -not (& $owned) }) ((Get-Plant).plant.owners | ConvertTo-Json -Compress)
        # (sampled while it settles: a sweep that read the claim before the merge must not name the owner again)
        $back = $false; foreach ($i in 1..6) { if (& $owned) { $back = $true }; Start-Sleep -Seconds 1 }
        Check 'no sweep gives the merged item an owner again' (-not $back)
        Check 'its spent session is told session.end and its client writes the launcher marker' (Wait-Until -Seconds 30 { @(Get-WorkerEvents 'mrg1' | Where-Object { $_.event -eq 'session.end' }).Count -gt 0 -and (Test-Path $mk) })
        Check 'the gateway settles the item to Done without an owner' (Wait-Until -Seconds 60 { (Get-FakeIssue $x.n).column -eq 'Done' }) "column $((Get-FakeIssue $x.n).column)"
    } finally {
        Stop-OwnerClient 'mrg1'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        $env:FACTORY_ONE_ITEM_PER_SESSION = $oldOne; $env:FACTORY_TIMING_sessionEndGraceSeconds = $oldGrace; Restart-Gateway
    }
}

# Issue 98: a pinned item whose worker cannot take it (away here) is offered to any eligible worker after timing.pinFallbackMinutes, with a journal
# line, and the pin stays set aside while the label names the same worker.
$OwnerScenarios['owner: a pin that waits too long falls back to another worker and is journalled'] = {
    $old = $env:FACTORY_TIMING_pinFallbackMinutes
    try {
        $env:FACTORY_TIMING_pinFallbackMinutes = '0.2'; Restart-Gateway
        $n = New-Item-Fake 'Pinned to an absent worker' 'x' ($OwnerLabels + 'worker:ghost1')
        Start-OwnerClient 'fb1' 'persistent-local'
        Start-Sleep -Seconds 5
        Check 'at first the item waits for its pinned worker' ((Get-Assigned 'fb1' $n).Count -eq 0)
        Check 'after the fallback time it is offered to another worker' (Wait-Until -Seconds 60 { (Get-Assigned 'fb1' $n).Count -gt 0 })
        Check 'the fallback is journalled once' (Wait-Until -Seconds 15 { @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=pin-fallback ' }).Count -eq 1 })
        $st = (Get-Plant).plant
        Check 'the status shows the pin set aside' ("$($st.pinsSetAside."$n")" -eq 'ghost1') ($st.pinsSetAside | ConvertTo-Json -Compress)
    } finally {
        Stop-OwnerClient 'fb1'
        $env:FACTORY_TIMING_pinFallbackMinutes = $old; Restart-Gateway
    }
}

# Auto-unpark (issue 90): the sweep lifts a park once its cause has cleared and journals it.
function New-TestPark([string]$Code, [hashtable]$Extra = @{}) {
    $now = (Get-Date).ToUniversalTime(); $p = @{ reason = $Code; at = $now.ToString('o'); until = $now.AddHours(24).ToString('o') }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }; return $p
}
function Get-SweepUnparks([int]$n) { @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=unparked ' -and $_.body -match 'by the sweep' }).Count }

$OwnerScenarios['owner: auto-unpark: a red-shard park is lifted once the pull request is green on a newer head, not on the head it judged'] = {
    $n = New-Item-Fake 'Auto-unpark red shard' 'x' $OwnerLabels 'Development'
    $pr = Do-Development $n
    $old = Get-Head $pr
    Set-ItemState $n { param($st) $st.Remove('claim'); $st.park = (New-TestPark 'fix-forward-exhausted' @{ pr = $pr; head = $old }) }
    Start-Sleep -Seconds 12
    Check 'green on the head the park judged: still parked' ((Get-ItemState $n).ContainsKey('park'))
    [void](Fake 'push-branch' @{ branch = "factory-worker/$n-development"; files = @('docs/trial.md') })
    Check 'a newer green head: the sweep lifts the park' (Wait-Until -Seconds 40 { -not (Get-ItemState $n).ContainsKey('park') }) ((Get-ItemState $n) | ConvertTo-Json -Compress -Depth 5)
    $st = Get-ItemState $n
    Check 'journalled once as unparked by the sweep, and counted' ((Get-SweepUnparks $n) -eq 1 -and [int]$st.auto_unparks.'fix-forward-exhausted' -eq 1) ($st.auto_unparks | ConvertTo-Json -Compress)
    Check 'handed to its column, so it is offered at once' ($st.handoff.column -eq 'Development' -or $st.ContainsKey('claim'))
    # at the limit (autoUnparkMax 3) a park is a person's again
    Set-ItemState $n { param($st) $st.Remove('claim'); $st.Remove('handoff'); $st.auto_unparks = @{ 'fix-forward-exhausted' = 3 }; $st.park = (New-TestPark 'fix-forward-exhausted' @{ pr = $pr; head = $old }) }
    Start-Sleep -Seconds 12
    Check 'lifted three times already: left parked' ((Get-ItemState $n).ContainsKey('park'))
}

$OwnerScenarios['owner: auto-unpark: a park of session trouble is lifted once a worker session is free, and the item is offered to it'] = {
    try {
        $m = New-Item-Fake 'Auto-unpark session trouble' 'x' $OwnerLabels
        $r = F 'w1' @('claim-item', '--item', $m, '--column', 'Technical Design'); CheckExit 'a claim writes the state' $r 0
        Set-ItemState $m { param($st) $st.Remove('claim'); $st.park = (New-TestPark 'session-relaunch-budget' @{ last_take_back = 'client-accepted-not-started' }) }
        # sessions left connected by earlier scenarios may be free already: the "still parked" check holds only when none is
        $freeBefore = @((Get-Plant).plant.workers | Where-Object { $_.connected -and -not $_.draining -and [int]$_.owned -lt [int]$_.capacity -and "$($_.name)" -ne 'unpark1' }).Count
        if ($freeBefore -eq 0) {
            Start-Sleep -Seconds 12
            Check 'no free worker: still parked' ((Get-ItemState $m).ContainsKey('park'))
        }
        Start-OwnerClient 'unpark1' 'persistent-local'
        Check 'a free worker: the park is lifted' (Wait-Until -Seconds 40 { -not (Get-ItemState $m).ContainsKey('park') })
        if ($freeBefore -eq 0) { Check 'and the item is offered to it' (Wait-Until -Seconds 40 { (Get-Assigned 'unpark1' $m).Count -gt 0 }) }
        Check 'journalled as unparked by the sweep' ((Get-SweepUnparks $m) -eq 1)
    } finally { Stop-OwnerClient 'unpark1' }
}

$OwnerScenarios['owner: auto-unpark: master-broken is lifted only once the checks that failed passed on master, then judged on that head'] = {
    $k = New-Item-Fake 'Auto-unpark master broken' 'x' $OwnerLabels 'Functional Testing'
    $r = F 'w1' @('claim-item', '--item', $k, '--column', 'Functional Testing'); CheckExit 'a claim writes the state' $r 0
    $mm = Fake 'master-merge' @{ files = @('docs/other.md') }
    $red = ('e' * 40); $at = (Get-Date).ToUniversalTime().ToString('o')
    # a check that has no passing run on master's head (a skipped or absent job, as on a docs-only head) keeps the park
    Set-ItemState $k { param($st) $st.Remove('claim'); $st.merge = @{ sha = $red; merged_at = $at; awaiting = $null; rerun_attempted = $true }; $st.park = (New-TestPark 'master-broken' @{ failed = @('Acceptance shard 1'); sha = $red }) }
    Start-Sleep -Seconds 12
    Check 'master green but the failed check has not passed on it: still parked' ((Get-ItemState $k).ContainsKey('park'))
    Set-ItemState $k { param($st) $st.park = (New-TestPark 'master-broken' @{ failed = @('Build result'); sha = $red }) }
    Check 'the failed check passed on master: the park is lifted' (Wait-Until -Seconds 40 { -not (Get-ItemState $k).ContainsKey('park') }) ((Get-ItemState $k) | ConvertTo-Json -Compress -Depth 5)
    $ms = (Get-ItemState $k).merge
    Check "the item is judged on master's green head, not its merge commit" ($ms.judge_sha -eq $mm.sha -and $null -ne $ms.awaiting) ($ms | ConvertTo-Json -Compress)
    Check 'journalled as unparked by the sweep' ((Get-SweepUnparks $k) -eq 1)
}

# The board guard: an open issue with the factory label that has no card is put on the board in the intake column by the sweep, journalled once, and
# then offered like any new item; an issue without the label, and a closed one, are left alone.
$OwnerScenarios['owner: board guard: a labelled issue missing from the board is added in Technical Design and offered'] = {
    try {
        $n = (Fake 'issue' @{ title = 'Created without a card'; body = 'x'; labels = ($OwnerLabels + 'worker:guard1') }).number
        $other = (Fake 'issue' @{ title = 'Not a factory item'; body = 'x'; labels = @('bug') }).number
        $rival = (Fake 'issue' @{ title = 'Two owners'; body = 'x'; labels = ($OwnerLabels + 'AI Factory') }).number
        $closed = (Fake 'issue' @{ title = 'Closed factory item'; body = 'x'; labels = $OwnerLabels }).number
        [void](Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/$closed" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ state = 'closed' } | ConvertTo-Json) -ContentType 'application/json')
        $stranded = (Fake 'issue' @{ title = 'A card without a column'; body = 'x'; labels = $OwnerLabels; onBoard = $true }).number
        Check 'the sweep puts the labelled issue on the board in Technical Design' (Wait-Until -Seconds 40 { (Get-FakeIssue $n).column -eq 'Technical Design' }) ((Get-FakeIssue $n) | ConvertTo-Json -Compress -Depth 3)
        Check 'a card without a column gets the intake column' (Wait-Until -Seconds 20 { (Get-FakeIssue $stranded).column -eq 'Technical Design' })
        Check 'a closed issue and one with the rival label are left alone' ($null -eq (Get-FakeIssue $closed).column -and $null -eq (Get-FakeIssue $rival).column)
        Check 'it is journalled once' (Wait-Until -Seconds 10 { @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=board-added ' }).Count -eq 1 })
        Check 'the unlabelled issue stays off the board' ($null -eq (Get-FakeIssue $other).column)
        Start-OwnerClient 'guard1' 'persistent-local'
        Check 'the added item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'guard1' $n).Count -gt 0 })
        Start-Sleep -Seconds 5
        Check 'still journalled only once' (@((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=board-added ' }).Count -eq 1)
    } finally { Stop-OwnerClient 'guard1' }
}

# Issue 65: an item whose body says "Depends on #N" is offered to nobody while #N is neither merged nor closed; the status shows it held with the code
# depends-on and what it waits for; once #N is closed the next sweep offers it (a dependency off the board is read through the REST API).
$OwnerScenarios['owner: an item waits for the items it depends on and is offered once they are closed'] = {
    try {
        Start-OwnerClient 'dep1' 'persistent-local' '--capacity 3'
        $d1 = New-Item-Fake 'Dependency on the board' 'x' $OwnerLabels 'Todo'
        $d2 = (Fake 'issue' @{ title = 'Dependency off the board'; body = 'x'; labels = @('bug') }).number
        $n = New-Item-Fake 'Dependent item' "Builds on the others.`n`nDepends on #$d1 and #$d2`n" ($OwnerLabels + 'worker:dep1')
        $free = New-Item-Fake 'Unrelated item' "depends on nothing" ($OwnerLabels + 'worker:dep1')
        Check 'an item without dependencies is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'dep1' $free).Count -gt 0 })
        $script:HeldRow = $null
        Check 'the dependent is held: code depends-on, waiting for both' (Wait-Until -Seconds 30 { $script:HeldRow = @((Get-Plant).plant.held | Where-Object { $_.item -eq $n })[0]; $script:HeldRow -and $script:HeldRow.code -eq 'depends-on' -and @($script:HeldRow.on).Count -eq 2 }) ($script:HeldRow | ConvertTo-Json -Compress)
        Check 'it is not offered' ((Get-Assigned 'dep1' $n).Count -eq 0)
        $repo = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues"
        [void](Invoke-RestMethod "$repo/$d1" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ state = 'closed' } | ConvertTo-Json) -ContentType 'application/json')
        Check 'one dependency closed: still held, waiting for the other only' (Wait-Until -Seconds 30 { $h = @((Get-Plant).plant.held | Where-Object { $_.item -eq $n })[0]; $h -and @($h.on).Count -eq 1 -and @($h.on)[0] -eq $d2 })
        Check 'still not offered' ((Get-Assigned 'dep1' $n).Count -eq 0)
        [void](Invoke-RestMethod "$repo/$d2" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ state = 'closed' } | ConvertTo-Json) -ContentType 'application/json')
        Check 'both closed: the item is offered and no longer held' (Wait-Until -Seconds 40 { (Get-Assigned 'dep1' $n).Count -gt 0 -and @((Get-Plant).plant.held | Where-Object { $_.item -eq $n }).Count -eq 0 }) ((Get-Plant).plant | ConvertTo-Json -Compress -Depth 5)
    } finally { Stop-OwnerClient 'dep1' }
}

# The launcher watchdog (docs/launcher.md): a spent session that owns nothing and is still connected sessionRestartMinutes later (it did not act on
# session.end) is told session.restart; its client writes the end marker and the reason next to it for the launcher's log.
$OwnerScenarios['owner: launcher watchdog: a spent session still idle after session.end is told session.restart and the client writes the reason'] = {
    $oldOne = $env:FACTORY_ONE_ITEM_PER_SESSION; $oldGrace = $env:FACTORY_TIMING_sessionEndGraceSeconds; $oldRs = $env:FACTORY_TIMING_sessionRestartMinutes; $oldEnd = $env:FACTORY_SESSION_END_FILE
    $mk = Join-Path $script:Work 'stuck1-work/session-ended'
    try {
        $env:FACTORY_ONE_ITEM_PER_SESSION = '1'; $env:FACTORY_TIMING_sessionEndGraceSeconds = '2'; $env:FACTORY_TIMING_sessionRestartMinutes = '0.4'; Restart-Gateway
        $env:FACTORY_SESSION_END_FILE = $mk
        Start-OwnerClient 'stuck1' 'persistent-local'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        $a = New-Item-Fake 'Stuck session' 'x' ($OwnerLabels + 'worker:stuck1')
        Check 'the item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'stuck1' $a).Count -gt 0 })
        $r = Fo 'stuck1' @('accept', '--item', $a, '--assignment', (Get-Assigned 'stuck1' $a)[-1].assignment)
        Check 'the session holds the item' ($r.exit -eq 0 -or (Wait-Until -Seconds 20 { @(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'item.accepted' }).Count -gt 0 })) ($r | ConvertTo-Json -Compress)
        Check 'the client noted that the session holds an item' (Wait-Until -Seconds 10 { Test-Path (Join-Path (Split-Path $mk) 'session-owning') })
        Check 'the client stamps the stream as alive' (Test-Path (Join-Path (Split-Path $mk) 'stream-alive'))
        Start-Sleep -Seconds 4
        Check 'while it owns its item it is not restarted' (@(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'session.restart' }).Count -eq 0)
        $r = Fo 'stuck1' @('release', '--item', $a, '--reason', 'scenario: the item leaves the session'); CheckExit 'the item leaves the session' $r 0
        Check 'session.end comes first' (Wait-Until -Seconds 30 { @(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'session.end' }).Count -gt 0 })
        Remove-Item $mk -Force -ErrorAction SilentlyContinue   # the session did not act on it: no launcher ended it
        Check 'the session, still connected, is told session.restart' (Wait-Until -Seconds 40 { @(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'session.restart' }).Count -gt 0 })
        $ev = @(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'session.restart' })
        Check 'code spent-idle, the marker written with the reason next to it' ($ev[0].code -eq 'spent-idle' -and $ev[0].markerWritten -eq $true -and (Test-Path $mk) -and (Get-Content -Raw "$mk.reason") -like 'gateway-spent-idle*') ($ev | ConvertTo-Json -Compress -Depth 4)
        Check 'the owning note is gone after the session was told to end' (-not (Test-Path (Join-Path (Split-Path $mk) 'session-owning')))
        $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'stuck1' })[0]
        Check 'the status shows the restart' ($w.restartSent -eq $true -and @((Get-Plant).plant.sessionRestarts.recent | Where-Object { $_.worker -eq 'stuck1' -and $_.code -eq 'spent-idle' }).Count -eq 1) ($w | ConvertTo-Json -Compress -Depth 4)
        Start-Sleep -Seconds 5
        Check 'once per session' (@(Get-WorkerEvents 'stuck1' | Where-Object { $_.event -eq 'session.restart' }).Count -eq 1)
    } finally {
        Stop-OwnerClient 'stuck1'
        $env:FACTORY_SESSION_END_FILE = $oldEnd
        $env:FACTORY_ONE_ITEM_PER_SESSION = $oldOne; $env:FACTORY_TIMING_sessionEndGraceSeconds = $oldGrace; $env:FACTORY_TIMING_sessionRestartMinutes = $oldRs; Restart-Gateway
    }
}

# The launchers' own watchdog, with a fake claude (it only sleeps, or writes what a session or its client would): each cause ends the session, a new
# one starts, and the reason is in BASE/work/launcher.log. Both launchers; the bash one where bash is.
function Invoke-LauncherCase([string]$Kind, [string]$Mode, [string[]]$Opts, [string]$Expect, [string]$Screen = '', [switch]$None) {
    $base = Join-Path $script:Work "launch-$Kind-$Mode"; Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $base | Out-Null
    $prompt = Join-Path $base 'prompt.txt'; Set-Content $prompt 'connect prompt'
    $fake = Join-Path $base 'fake-claude.ps1'
    Set-Content $fake @"
`$d = Split-Path -Parent `$env:FACTORY_SESSION_END_FILE
switch ('$Mode') {
    'owning' { Set-Content (Join-Path `$d 'session-owning') '77'; Set-Content (Join-Path `$d 'stream-alive') 'x' }
    'gateway' { Set-Content "`$(`$env:FACTORY_SESSION_END_FILE).reason" 'gateway-repeated-question: asked 3 times'; Set-Content `$env:FACTORY_SESSION_END_FILE 'x' }
}
Start-Sleep -Seconds 40
"@
    $log = Join-Path $base 'work/launcher.log'
    if ($Screen) {   # the screen the watchdog reads: a file, printed by a command without spaces in its quoting (Start-Process joins arguments with spaces)
        $sf = Join-Path $base 'screen.txt'; Set-Content $sf $Screen
        $Opts += @($(if ($Kind -eq 'sh') { '--screen-cmd' } else { '-ScreenCmd' }), "`"$(if ($IsWindows) { 'type' } else { 'cat' }) $sf`"")
    }
    if ($Kind -eq 'sh') {
        $sh = Join-Path $base 'fake-claude.sh'; Set-Content $sh "#!/usr/bin/env bash`nexec pwsh -NoProfile -File '$fake'"; & chmod +x $sh
        $p = Start-Process bash -ArgumentList (@((Join-Path $script:Root 'plugin/launcher/fworker-loop.sh'), '--dir', $base, '--prompt-file', $prompt, '--claude', $sh, '--backoff', '1') + $Opts) -PassThru -RedirectStandardOutput (Join-Path $base 'out.txt') -RedirectStandardError (Join-Path $base 'err.txt')
    } else {
        $p = Start-Process pwsh -ArgumentList (@('-NoProfile', '-File', (Join-Path $script:Root 'plugin/launcher/fworker-loop.ps1'), '-Dir', $base, '-PromptFile', $prompt, '-Claude', $fake, '-Backoff', '1') + $Opts) -PassThru -RedirectStandardOutput (Join-Path $base 'out.txt') -RedirectStandardError (Join-Path $base 'err.txt')
    }
    $script:Procs += $p
    try {
        if ($None) {
            Start-Sleep -Seconds 14
            Check "launcher ($Kind) ${Mode}: no restart" (-not (Test-Path $log) -and (Get-Content -Raw (Join-Path $base 'out.txt')) -notmatch 'session 2 starts') "$(Get-Content -Raw $log -ErrorAction SilentlyContinue) | $(Get-Content -Raw (Join-Path $base 'out.txt') -ErrorAction SilentlyContinue)"
        } else {
            $ok = Wait-Until -Seconds 40 { (Test-Path $log) -and ((Get-Content -Raw $log) -match [regex]::Escape($Expect)) -and (Get-Content -Raw (Join-Path $base 'out.txt')) -match 'session 2 starts' }
            Check "launcher ($Kind) ${Mode}: the session is restarted and the log names '$Expect'" $ok "$(Get-Content -Raw $log -ErrorAction SilentlyContinue) | $(Get-Content -Raw (Join-Path $base 'out.txt') -ErrorAction SilentlyContinue)"
        }
    } finally {
        New-Item -ItemType File -Force -Path (Join-Path $base 'work/STOP') | Out-Null
        try { Stop-Process -Id $p.Id -Force } catch { }
    }
}
$OwnerScenarios['owner: launcher watchdog: stream silence, unsent input, screen silence while owning and a gateway reason each restart the session'] = {
    $kinds = @('ps1'); if (-not $IsWindows -and (Get-Command bash -ErrorAction SilentlyContinue)) { $kinds += 'sh' }
    foreach ($k in $kinds) {
        $o = if ($k -eq 'sh') { @{ stale = '--stream-stale'; silent = '--silent'; unsent = '--unsent' } } else { @{ stale = '-StreamStale'; silent = '-Silent'; unsent = '-Unsent' } }
        Invoke-LauncherCase $k 'quiet' @($o.stale, '3', $o.silent, '0', $o.unsent, '0') 'watchdog stream-disconnected'
        Invoke-LauncherCase $k 'typed' @($o.stale, '0', $o.silent, '0', $o.unsent, '3') 'watchdog unsent-input' '│ > please go on'
        Invoke-LauncherCase $k 'padded' @($o.stale, '0', $o.silent, '0', $o.unsent, '3') 'watchdog unsent-input' ("> Connect to the factory`n│ > typed text   │" + ("`n" * 12))
        # an earlier message in the transcript above an empty prompt box, the placeholder and a menu row are no typed input
        Invoke-LauncherCase $k 'transcript' @($o.stale, '0', $o.silent, '0', $o.unsent, '3') '' "> Connect to the factory`n❯ 1. Yes`nwaiting for an offer`n│ > Try `"fix lint`"   │" -None
        Invoke-LauncherCase $k 'emptybox' @($o.stale, '0', $o.silent, '0', $o.unsent, '3') '' "> Connect to the factory`nwaiting`n│ >          │" -None
        Invoke-LauncherCase $k 'owning' @($o.stale, '0', $o.silent, '3', $o.unsent, '0') 'watchdog no-output-while-owning' 'working on it'
        Invoke-LauncherCase $k 'gateway' @($o.stale, '0') 'gateway-repeated-question: asked 3 times'
    }
}

# Issue 80: the operator's drain belongs to the name; a new session of the name (the launcher's next one) is still draining until the operator resumes.
$OwnerScenarios['owner: an operator drain holds across a new session of the name until the operator resumes it'] = {
    $me = { @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'drn1' })[0] }
    $hdr = @{ Authorization = 'Bearer test-token' }
    try {
        Start-OwnerClient 'drn1' 'persistent-local'
        $null = Invoke-RestMethod "$(Get-GatewayBase)/api/v1/workers/drn1/drain" -Method POST -Headers $hdr
        Check 'the operator drains the name' ((& $me).draining -eq $true)
        Stop-OwnerClient 'drn1'; [void](Wait-Until -Seconds 20 { -not (& $me).connected })
        Start-OwnerClient 'drn1' 'persistent-local'
        Check 'the next session of the name registers still draining' ((& $me).connected -eq $true -and (& $me).draining -eq $true) ((& $me) | ConvertTo-Json -Compress -Depth 3)
        $n = New-Item-Fake 'Drained name' 'x' ($OwnerLabels + 'worker:drn1')
        Start-Sleep -Seconds 8
        Check 'the drained name is offered nothing' ((Get-Assigned 'drn1' $n).Count -eq 0)
        $d = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/workers/drn1/resume" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers['drn1'].token)" } -SkipHttpErrorCheck
        Check 'the session itself cannot lift the operator drain' ([int]$d.StatusCode -eq 200 -and (& $me).draining -eq $true) "$([int]$d.StatusCode) $($d.Content)"
        $null = Invoke-RestMethod "$(Get-GatewayBase)/api/v1/workers/drn1/resume" -Method POST -Headers $hdr
        Check 'the operator resumes it' ((& $me).draining -eq $false)
        Check 'then it is offered the item' (Wait-Until -Seconds 40 { (Get-Assigned 'drn1' $n).Count -gt 0 })
        # a session's own drain (end-session) stays the session's: the next session of the name is not draining
        $null = Invoke-RestMethod "$(Get-GatewayBase)/api/v1/workers/drn1/drain" -Method POST -Headers @{ Authorization = "Bearer $($script:Workers['drn1'].token)" }
        Check 'the session drains itself' ((& $me).draining -eq $true)
        Stop-OwnerClient 'drn1'; [void](Wait-Until -Seconds 20 { -not (& $me).connected })
        Start-OwnerClient 'drn1' 'persistent-local'
        Check 'its next session is not draining' ((& $me).connected -eq $true -and (& $me).draining -eq $false) ((& $me) | ConvertTo-Json -Compress -Depth 3)
    } finally { Stop-OwnerClient 'drn1' }
}

# Issue 81: an owner whose item.assigned was lost is resent its accepted item when a new session of the name registers.
$OwnerScenarios['owner: a new session of an owner is resent its accepted item; an item whose owner was dropped is not'] = {
    try {
        Start-OwnerClient 'rsd1' 'persistent-local' '--no-auto-accept'
        $n = New-Item-Fake 'Resent item' 'x' ($OwnerLabels + 'worker:rsd1')
        Check 'the item is offered' (Wait-Until -Seconds 40 { (Get-Assigned 'rsd1' $n).Count -gt 0 })
        $e = (Get-Assigned 'rsd1' $n)[-1]
        $r = Fo 'rsd1' @('accept', '--item', $n, '--assignment', $e.assignment); CheckExit 'the session accepts' $r 0
        Stop-OwnerClient 'rsd1'; [void](Wait-Until -Seconds 20 { -not @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'rsd1' })[0].connected })
        $before = (Get-Assigned 'rsd1' $n).Count
        Start-OwnerClient 'rsd1' 'persistent-local' '--no-auto-accept'
        Check 'the new session is resent the item' (Wait-Until -Seconds 20 { @((Get-Assigned 'rsd1' $n) | Where-Object { $_['resent'] -eq $true }).Count -gt 0 })
        $x = @((Get-Assigned 'rsd1' $n) | Where-Object { $_['resent'] -eq $true })[-1]
        Check 'with the accepted assignment, mode resume' ($x.assignment -eq $e.assignment -and $x.mode -eq 'resume' -and $x['accepted'] -eq $true) ($x | ConvertTo-Json -Compress)
        $r = Fo 'rsd1' @('accept', '--item', $n, '--assignment', $x.assignment); CheckExit 'accepting it again is harmless' $r 0
        $r = Fo 'rsd1' @('release', '--item', $n, '--reason', 'scenario: the item ends'); CheckExit 'the item is released' $r 0
        Stop-OwnerClient 'rsd1'; [void](Wait-Until -Seconds 20 { -not @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'rsd1' })[0].connected })
        Start-OwnerClient 'rsd1' 'persistent-local' '--no-auto-accept'
        Start-Sleep -Seconds 3
        Check 'a released item is never resent (the output of the new client starts empty)' (@((Get-Assigned 'rsd1' $n) | Where-Object { $_['resent'] -eq $true }).Count -eq 0)
    } finally { Stop-OwnerClient 'rsd1' }
}

# Issue 82: a closed item keeps no park. The sweep removes it; unpark accepts a closed item and removes only the park.
$OwnerScenarios['unpark: a closed item keeps no park: the sweep removes it, and unpark of a closed item removes only the park'] = {
    $api = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders"; $gh = @{ Authorization = 'Bearer fake-operator' }
    $park = {
        param($title)
        $n = New-Item-Fake $title 'x' ($OwnerLabels + 'worker:cpk')
        [void](Wait-Until -Seconds 40 { (Get-Assigned 'cpk' $n).Count -gt 0 })
        $r = Fo 'cpk' @('accept', '--item', $n, '--assignment', (Get-Assigned 'cpk' $n)[-1].assignment); CheckExit "accept $n" $r 0
        $r = Fo 'cpk' @('complete', '--item', $n, '--column', 'Technical Design', '--succeeded', 'false', '--comment', 'cannot be met as written')
        Check "item $n is parked" ($r.exit -eq 0 -and $r.parked -eq $true -and (Pm-State $n).ContainsKey('park')) ($r | ConvertTo-Json -Compress)
        return $n
    }
    try {
        Start-OwnerClient 'cpk' 'persistent-local' '--capacity 3'
        # unpark of a closed item: the label is taken off first, so the sweep leaves it alone and the endpoint is what removes the park
        $a = & $park 'Closed unpark'
        Invoke-RestMethod "$api/issues/$a/labels/factory%20worker" -Method DELETE -Headers $gh | Out-Null
        Invoke-RestMethod "$api/issues/$a" -Method PATCH -Body '{"state":"closed"}' -ContentType 'application/json' -Headers $gh | Out-Null
        $r = F 'op' @('unpark', '--item', $a, '--reason', 'the item was closed by a person')
        CheckExit 'unpark accepts a closed item' $r 0
        Check 'it removes only the park: no re-offer, and says the item is closed' ($r.unparked -eq $true -and $r.reoffer -eq $false -and $r.closed -eq $true -and -not (Pm-State $a).ContainsKey('park') -and -not (Pm-State $a).ContainsKey('handoff')) ($r | ConvertTo-Json -Compress -Depth 4)
        Check 'the journal records it' (@((Get-FakeIssue $a).comments | Where-Object { $_.body -match 'plant event=unparked' -and $_.body -like '*The item is closed*' }).Count -eq 1)
        # the sweep removes the park of a closed item by itself
        $b = & $park 'Closed park sweep'
        Invoke-RestMethod "$api/issues/$b" -Method PATCH -Body '{"state":"closed"}' -ContentType 'application/json' -Headers $gh | Out-Null
        Check 'the next sweep removes the park of the closed item' (Wait-Until -Seconds 60 { -not (Pm-State $b).ContainsKey('park') }) ((Pm-State $b) | ConvertTo-Json -Compress -Depth 4)
        Check 'and journals it once, as removed by the sweep' (@((Get-FakeIssue $b).comments | Where-Object { $_.body -match 'plant event=unparked' -and $_.body -like '*by the sweep*' -and $_.body -like '*The item is closed*' }).Count -eq 1) (((Get-FakeIssue $b).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(120, $_.body.Length)) }) -join ' | ')
        Start-Sleep -Seconds 6
        $j = [string[]](Get-Journal $b); $u = [array]::LastIndexOf($j, 'unparked')
        Check 'nothing is offered after it' ($u -ge 0 -and @($j | Select-Object -Skip ($u + 1) | Where-Object { $_ -in 'matched', 'offered' }).Count -eq 0) ($j -join ',')
    } finally { Stop-OwnerClient 'cpk' }
}

# A person releases a park early (POST /api/v1/items/{n}/unpark, operator token): docs/design/plant-manager.md 10d
$OwnerScenarios['unpark: the operator releases a park early with a reason; the next sweep offers the item again in its column'] = {
    Start-OwnerClient 'una' 'persistent-local' '--capacity 3'
    $n = New-Item-Fake 'Unpark' 'x' $OwnerLabels
    [void](Wait-Until -Seconds 40 { (Get-Assigned 'una' $n).Count -gt 0 })
    for ($try = 0; $try -lt 5; $try++) {
        $ev = (Get-Assigned 'una' $n)[-1]
        $r = Fo 'una' @('accept', '--item', $n, '--assignment', $ev.assignment)
        if ($r.exit -ne 11) { break }
        $seen = (Get-Assigned 'una' $n).Count; [void](Wait-Until -Seconds 30 { (Get-Assigned 'una' $n).Count -gt $seen })
    }
    CheckExit 'accept' $r 0
    $r = Fo 'una' @('complete', '--item', $n, '--column', 'Technical Design', '--succeeded', 'false', '--comment', 'the criterion cannot be met as written')
    Check 'a failure report parks the item' ($r.exit -eq 0 -and $r.parked -eq $true) ($r | ConvertTo-Json -Compress)
    Check 'the park is in the state comment' ((Pm-State $n).ContainsKey('park'))
    $r = Fo 'una' @('unpark', '--item', $n, '--reason', 'mine'); CheckExit 'a worker credential cannot unpark' $r 30 'forbidden'
    $r = F 'op' @('unpark', '--item', $n); CheckExit 'a reason is required' $r 2 'usage'
    $d = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/items/$n/unpark" -Method POST -Body '{"reason":"x"}' -ContentType 'application/json' -SkipHttpErrorCheck
    Check 'no credential: 401' ([int]$d.StatusCode -eq 401) "$([int]$d.StatusCode)"
    $d = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/verbs/unpark-item" -Method POST -Body (@{ item = $n; reason = 'x' } | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck
    Check 'the rule verb is reached only through the endpoint' ([int]$d.StatusCode -eq 400 -and ($d.Content | ConvertFrom-Json).code -eq 'use-endpoint') "$([int]$d.StatusCode) $($d.Content)"
    Check 'the refused calls left the park in place' ((Pm-State $n).ContainsKey('park'))
    $r = F 'op' @('unpark', '--item', $n, '--reason', 'the owner relaxed the criterion')
    CheckExit 'the operator unparks' $r 0
    Check 'the answer names the park it released and the column' ($r.unparked -eq $true -and $r.park.reason -eq 'worker-failure' -and $r.column -eq 'Technical Design' -and $r.reoffer -eq $true) ($r | ConvertTo-Json -Compress -Depth 4)
    $st = Pm-State $n
    Check 'the park is gone from the state comment' (-not $st.ContainsKey('park')) ($st | ConvertTo-Json -Compress -Depth 4)
    Check 'a journal line records the release' ((Get-Journal $n) -contains 'unparked')
    Check 'with the reason and who released it' (@((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=unparked' -and $_.body -like '*the owner relaxed the criterion*' -and $_.body -like '*by the operator*' -and $_.body -like '*worker-failure*' }).Count -eq 1)
    Check 'the next sweep offers the item again in its column, at once' (Wait-Until -Seconds 30 { $j = [string[]](Get-Journal $n); $u = [array]::LastIndexOf($j, 'unparked'); $u -ge 0 -and $u + 2 -lt $j.Count -and $j[$u + 1] -eq 'matched' -and $j[$u + 2] -eq 'offered' }) ((Get-Journal $n) -join ',')
    Check 'the item stayed in its column' ((Get-FakeIssue $n).column -eq 'Technical Design')
    $r = F 'op' @('unpark', '--item', $n, '--reason', 'again'); CheckExit 'an item with no park' $r 10 'not-parked'
    Stop-OwnerClient 'una'
}

# Issue 104: work intake. With a worker slot free and nothing waiting in Technical Design, the sweep pulls the top Todo item that is not held, pinned
# or waiting on another item, at most intake.wipLimit items in the AI columns. The suites run with intake off; this scenario restarts the gateway
# with FACTORY_INTAKE=1 and a limit of 2 (FACTORY_INTAKE_WIP).
$OwnerScenarios['intake: a free slot and an empty Technical Design pull the top Todo item that is not held, pinned or waiting, up to the WIP limit [full]'] = {
    $old = @{ i = $env:FACTORY_INTAKE; w = $env:FACTORY_INTAKE_WIP }; $env:FACTORY_INTAKE = '1'; $env:FACTORY_INTAKE_WIP = '2'
    $col = { param($n) "$((Get-FakeIssue $n).column)" }
    try {
        # Todo, top first: one held, one pinned, one that depends on an open item, then the two that may come, then one for after the limit
        $other = New-Item-Fake 'Intake: an open item elsewhere' 'x' $OwnerLabels 'In Progress'
        $held = New-Item-Fake 'Intake: held' 'x' ($OwnerLabels + 'hold:owner') 'Todo'
        $pinned = New-Item-Fake 'Intake: pinned' 'x' ($OwnerLabels + 'worker:nobody-here') 'Todo'
        $waits = New-Item-Fake 'Intake: waits' "Depends on #$other" $OwnerLabels 'Todo'
        $a = New-Item-Fake 'Intake: first' 'x' $OwnerLabels 'Todo'
        $b = New-Item-Fake 'Intake: second' 'x' $OwnerLabels 'Todo'
        $c3 = New-Item-Fake 'Intake: third' 'x' $OwnerLabels 'Todo'
        # clients left running by earlier scenarios reconnect after the restart and would offer a free slot: stop them all first
        foreach ($w in @($script:Workers.Keys)) { Stop-OwnerClient $w }
        Restart-Gateway
        Start-Sleep -Seconds 6
        Check 'with no session connected nothing is pulled' ((& $col $a) -eq 'Todo' -and (& $col $b) -eq 'Todo') "a: $(& $col $a), b: $(& $col $b); connected: $(@((Get-Plant).plant.workers | Where-Object { $_.connected } | ForEach-Object { $_.name }) -join ', ')"
        Start-OwnerClient 'in1' 'persistent-local' '--capacity 1 --no-auto-accept'
        Check 'a free slot pulls the top item that may come: moved to Technical Design and offered' (Wait-Until -Seconds 60 { (& $col $a) -eq 'Technical Design' -and (Get-Assigned 'in1' $a).Count -gt 0 }) "a: $(& $col $a)"
        Check 'the held, the pinned and the waiting item stay in Todo' ((& $col $held) -eq 'Todo' -and (& $col $pinned) -eq 'Todo' -and (& $col $waits) -eq 'Todo')
        Check 'the journal says why it was pulled' (@((Get-FakeIssue $a).comments | Where-Object { $_.body -like '*pulled from **Todo** into*plant event=pulled*' }).Count -eq 1)
        Start-Sleep -Seconds 6
        Check 'while it waits for its session nothing more is pulled' ((& $col $b) -eq 'Todo')
        $r = Fo 'in1' @('accept', '--item', $a, '--assignment', (Get-Assigned 'in1' $a)[-1].assignment); CheckExit 'in1 accepts it' $r 0
        Start-OwnerClient 'in2' 'persistent-local' '--capacity 1 --no-auto-accept'
        Check 'the next free slot pulls the next item' (Wait-Until -Seconds 60 { (& $col $b) -eq 'Technical Design' -and (Get-Assigned 'in2' $b).Count -gt 0 }) "b: $(& $col $b)"
        $r = Fo 'in2' @('accept', '--item', $b, '--assignment', (Get-Assigned 'in2' $b)[-1].assignment); CheckExit 'in2 accepts it' $r 0
        Start-OwnerClient 'in3' 'persistent-local' '--capacity 1 --no-auto-accept'
        Start-Sleep -Seconds 10
        Check 'at the WIP limit (2 items in the AI columns) a free slot pulls nothing' ((& $col $c3) -eq 'Todo' -and (Get-Assigned 'in3' $c3).Count -eq 0) "third: $(& $col $c3)"
    } finally {
        foreach ($w in 'in1', 'in2', 'in3') { Stop-OwnerClient $w }
        $env:FACTORY_INTAKE = $old.i; $env:FACTORY_INTAKE_WIP = $old.w; Restart-Gateway
    }
}

# Issue 106: the launcher runs the session's event stream as a sidecar for the session's lifetime (docs/launcher.md). Both launchers, with a fake
# claude that only records its first message, and a prompt in the shape of the connect prompt (step 4's credentials, step 7's stream command): the
# real stream client registers with the suite's gateway and its lines land in BASE/work/events.log.
function Invoke-SidecarCase([string]$Kind) {
    $name = "sidecar-$Kind"; $base = Join-Path $script:Work "launch-sidecar-$Kind"; Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $base | Out-Null
    $tok = New-WorkerToken $name
    $prompt = Join-Path $base 'prompt.txt'
    Set-Content $prompt @"
4. Credentials (never print them). Set in your shell, and again in any new shell: FACTORY_URL=http://127.0.0.1:$($script:ApiPort) FACTORY_TOKEN=$tok FACTORY_HOLDER=$name FACTORY_DATA_DIR=<BASE>/data
7. Start the event stream. With a Monitor tool: Monitor on <PWSH> <SCRIPTS>/factory.ps1 subscribe --own --name $name --type persistent-local --capacity 1
   Without a Monitor tool: run the same command in the background writing to <BASE>/work/events.log.
"@
    $fake = Join-Path $base 'fake-claude.ps1'
    Set-Content $fake "Set-Content -LiteralPath '$(Join-Path $base 'first-message.txt')' -Value `$args[-1]; Set-Content -LiteralPath '$(Join-Path $base 'claude-env.txt')' -Value `$(if (`$env:FACTORY_TOKEN) { 'token' } else { 'none' }); Start-Sleep -Seconds 90"
    $events = Join-Path $base 'work/events.log'; $out = Join-Path $base 'out.txt'
    $saved = @{}; foreach ($k in 'FACTORY_URL', 'FACTORY_TOKEN', 'FACTORY_HOLDER', 'FACTORY_WORKER_TOKEN', 'FACTORY_TOKEN_DIR') { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
    try {
        if ($Kind -eq 'sh') {
            $sh = Join-Path $base 'fake-claude.sh'; Set-Content $sh "#!/usr/bin/env bash`nexec pwsh -NoProfile -File '$fake' `"`$@`""; & chmod +x $sh
            $p = Start-Process bash -ArgumentList @((Join-Path $script:Root 'plugin/launcher/fworker-loop.sh'), '--dir', $base, '--prompt-file', $prompt, '--claude', $sh, '--backoff', '1', '--stream-stale', '0') -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $base 'err.txt')
        } else {
            $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $script:Root 'plugin/launcher/fworker-loop.ps1'), '-Dir', $base, '-PromptFile', $prompt, '-Claude', $fake, '-Backoff', '1', '-StreamStale', '0') -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $base 'err.txt')
        }
    } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $script:Procs += $p
    $lines = { if (Test-Path $events) { @(Get-Content $events | ForEach-Object { try { $_ | ConvertFrom-Json -AsHashtable } catch { $null } } | Where-Object { $_ }) } else { @() } }
    # the sidecars this launcher started, by the process ids it prints (never by a name pattern)
    $pids = { @([regex]::Matches("$(Get-Content -Raw $out -ErrorAction SilentlyContinue)", 'stream sidecar started[^(]*\(pid (\d+)\)') | ForEach-Object { [int]$_.Groups[1].Value }) }
    $sidecars = { @(& $pids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Where-Object { $_ -and -not $_.HasExited }) }
    try {
        Check "sidecar ($Kind): the launcher's stream client registers and its lines go to events.log" (Wait-Until -Seconds 40 { @(& $lines | Where-Object { $_.event -eq 'worker.registered' -and $_.name -eq $name }).Count -ge 1 }) "$(Get-Content -Raw $out -ErrorAction SilentlyContinue) | $(Get-Content -Raw (Join-Path $base 'work/events.err') -ErrorAction SilentlyContinue)"
        Check "sidecar ($Kind): the gateway lists the name as connected" (Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq $name -and $_.connected }).Count -eq 1 })
        $fm = Join-Path $base 'first-message.txt'
        [void](Wait-Until -Seconds 20 { Test-Path $fm })
        $m = if (Test-Path $fm) { Get-Content -Raw $fm } else { '' }
        Check "sidecar ($Kind): the session's first message carries the launcher note: do not start subscribe, tail events.log" ($m -match 'LAUNCHER NOTE' -and $m -match 'Do not start factory\.ps1 subscribe' -and $m.Contains($events) -and ($m -match 'tail -n0 -F' -or $m -match 'Get-Content')) $m
        Check "sidecar ($Kind): the credential reaches the sidecar only, not the claude process" ((Get-Content -Raw (Join-Path $base 'claude-env.txt') -ErrorAction SilentlyContinue).Trim() -eq 'none')
        # a sidecar that dies while the session runs is started again (the scenario stops it by its process id)
        $before = @(& $sidecars)
        Check "sidecar ($Kind): one sidecar runs" ($before.Count -eq 1) ($before | ForEach-Object { $_.CommandLine } | Out-String)
        foreach ($sp in $before) { Stop-Process -Id $sp.Id -Force }
        Check "sidecar ($Kind): a sidecar that died is started again and registers again" (Wait-Until -Seconds 40 { @(& $lines | Where-Object { $_.event -eq 'worker.registered' }).Count -ge 2 -and (Get-Content -Raw $out) -match 'started again \(pid' }) "$(Get-Content -Raw $out -ErrorAction SilentlyContinue)"
        # the session ends (end marker): its sidecar ends with it
        New-Item -ItemType File -Force -Path (Join-Path $base 'work/STOP') | Out-Null
        Set-Content (Join-Path $base 'work/session-ended') 'x'
        Check "sidecar ($Kind): the sidecar ends with its session" (Wait-Until -Seconds 40 { @(& $sidecars).Count -eq 0 -and $p.HasExited }) "$(@(& $sidecars).Count) $(Get-Content -Raw $out -ErrorAction SilentlyContinue)"
        Check "sidecar ($Kind): the gateway sees the stream go" (Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq $name -and $_.connected }).Count -eq 0 })
    } finally {
        New-Item -ItemType File -Force -Path (Join-Path $base 'work/STOP') | Out-Null
        try { Stop-Process -Id $p.Id -Force } catch { }
        foreach ($sp in @(& $sidecars)) { try { Stop-Process -Id $sp.Id -Force } catch { } }
    }
}
$OwnerScenarios['owner: stream sidecar: the launcher runs the session''s stream into events.log, tells the session so, restarts a dead sidecar and stops it with the session [full]'] = {
    $kinds = @('ps1'); if (-not $IsWindows -and (Get-Command bash -ErrorAction SilentlyContinue)) { $kinds += 'sh' }
    foreach ($k in $kinds) { Invoke-SidecarCase $k }
}

# Issue 114: the settle state of a merged item is kept when master stays red or does not finish (items 262, 280 stranded closed, 272 and 276
# validated again). The item keeps awaiting master-broken or master-timeout, is never offered to a worker (not by the sweep, not after unpark),
# and goes on once the merge commit's latest attempt or a later master commit that contains it is green.
$OwnerScenarios['settle: a merged item whose master Build stays red keeps its settle state, is never offered, and goes on when a later master commit that contains it is green [full]'] = {
    try {
        Fake 'config' @{ masterFlaky = $true; flakyRunSeconds = 2; rerunSeconds = 2; rerunConclusion = 'failure' } | Out-Null
        Start-OwnerClient 'stl1' 'persistent-local' '--capacity 3'
        $x = Pm-ToValidation
        $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
        Check 'the gateway merged it' (Wait-Until -Seconds 40 { (Get-FakePr $x.pr).merged })
        Check 'master stays red after the re-run: master is BROKEN' (Wait-Until -Seconds 90 { @((Get-FakeIssue $x.n).comments | Where-Object { $_.body -like '*master is BROKEN*' }).Count -eq 1 })
        $mg = Pv (Pm-State $x.n) 'merge'
        Check 'the settle state is kept: awaiting master-broken, with the merge commit' ("$(Pv $mg 'awaiting')" -eq 'master-broken' -and "$(Pv $mg 'sha')" -eq "$((Get-FakePr $x.pr).mergeSha)") ($mg | ConvertTo-Json -Compress)
        $j0 = (Get-Journal $x.n).Count; $a0 = (Get-Assigned 'stl1' $x.n).Count
        $r = F 'op' @('unpark', '--item', $x.n, '--reason', 'scenario: master is red, a person looks')
        Check 'unpark removes the park but offers nothing: the item is merged' ($r.exit -eq 0 -and $r.reoffer -eq $false -and "$((Pv (Pv (Pm-State $x.n) 'merge') 'awaiting'))" -eq 'master-broken') ($r | ConvertTo-Json -Compress -Depth 4)
        Start-Sleep -Seconds 10
        $after = @((Get-Journal $x.n) | Select-Object -Skip $j0)
        Check 'no sweep offers the merged item to a worker' (@($after | Where-Object { $_ -in 'matched', 'offered' }).Count -eq 0 -and (Get-Assigned 'stl1' $x.n).Count -eq $a0) ($after -join ',')
        Check 'it still waits: the card is not moved on' ((Get-FakeIssue $x.n).column -in 'Functional Testing')
        # a later commit on master that contains the merge builds green
        Fake 'master-merge' @{ files = @('docs/later.md') } | Out-Null
        Check 'a green later master commit that contains it carries the item on to Done' (Wait-Until -Seconds 60 { (Get-FakeIssue $x.n).column -eq 'Done' }) "column $((Get-FakeIssue $x.n).column)"
        Check 'the comment names the later commit' (@((Get-FakeIssue $x.n).comments | Where-Object { $_.body -match 'master is GREEN at `[0-9a-f]{7}`, which contains' }).Count -eq 1)
    } finally { Stop-OwnerClient 'stl1' }
}

# Issue 114: an item an older gateway stranded (its wait erased at a master-broken park, then closed by its merged pull request: 262, 280) is
# re-armed by the sweep and settled; a finished item that was never released (272, 276) is settled again through POST /items/{n}/resettle.
$OwnerScenarios['settle: a stranded merged item is re-armed by the sweep and settled; a finished one is settled again through resettle [full]'] = {
    $api = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders"; $gh = @{ Authorization = 'Bearer fake-operator' }
    Fake 'config' @{ masterFlaky = $true; flakyRunSeconds = 2; rerunSeconds = 2; rerunConclusion = 'failure' } | Out-Null
    $x = Pm-ToValidation
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Check 'master is BROKEN for it' (Wait-Until -Seconds 90 { "$(Pv (Pv (Pm-State $x.n) 'merge') 'awaiting')" -eq 'master-broken' })
    # what an older gateway left: no wait, and the issue closed by the merged pull request
    $st = Pm-State $x.n; $cm = @((Get-FakeIssue $x.n).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') })[0]
    $st.merge.Remove('awaiting'); $json = $st | ConvertTo-Json -Depth 12
    $nb = "$($cm.body)" -replace '(?s)```json.*```', "``````json`n$json`n``````"
    Invoke-RestMethod "$api/issues/comments/$($cm.id)" -Method PATCH -Headers @{ Authorization = "Bearer $env:GH_TOKEN" } -Body (@{ body = $nb } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    Invoke-RestMethod "$api/issues/$($x.n)" -Method PATCH -Body '{"state":"closed"}' -ContentType 'application/json' -Headers $gh | Out-Null
    Check 'the sweep re-arms its settle step' (Wait-Until -Seconds 40 { "$(Pv (Pv (Pm-State $x.n) 'merge') 'awaiting')" -eq 'master-broken' -and (Get-Journal $x.n) -contains 'settle-rearmed' }) ((Pm-State $x.n).merge | ConvertTo-Json -Compress)
    # the park stands until auto-unpark's rule holds: each check that failed (here the acceptance shard) passed on a green master head
    $later = Fake 'master-merge' @{ files = @('docs/later2.md') }
    Fake 'checks' @{ sha = $later.sha; name = 'Acceptance Tests [shard 1/6]'; conclusion = 'success' } | Out-Null
    Check 'and settles it to Done once master is green for it' (Wait-Until -Seconds 60 { (Get-FakeIssue $x.n).column -eq 'Done' }) "column $((Get-FakeIssue $x.n).column)"
    # settled again on purpose: the operator reopens it, moves its card back to the Release Queue and calls resettle
    Invoke-RestMethod "$api/issues/$($x.n)" -Method PATCH -Body '{"state":"open"}' -ContentType 'application/json' -Headers $gh | Out-Null
    $mut = 'mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){ projectV2Item{ id } } }'
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/graphql" -Method POST -Headers $gh -Body (@{ query = $mut; variables = @{ p = 'p'; i = "card_$($x.n)"; f = 'f'; o = 'opt_Release_Queue' } } | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
    Check 'the card is back in the Release Queue' ((Get-FakeIssue $x.n).column -eq 'Release Queue')
    $d = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/verbs/resettle-item" -Method POST -Body (@{ item = $x.n; reason = 'x' } | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck
    Check 'the rule verb is reached only through the endpoint' ([int]$d.StatusCode -eq 400 -and ($d.Content | ConvertFrom-Json).code -eq 'use-endpoint') "$([int]$d.StatusCode) $($d.Content)"
    $d = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/items/$($x.n)/resettle" -Method POST -Body '{"reason":"x"}' -ContentType 'application/json' -Headers @{ Authorization = "Bearer $(New-WorkerToken 'rsx1')" } -SkipHttpErrorCheck
    Check 'a worker credential cannot resettle' ([int]$d.StatusCode -eq 403) "$([int]$d.StatusCode)"
    $rs = { param($n, $reason) $r = Invoke-WebRequest "$(Get-GatewayBase)/api/v1/items/$n/resettle" -Method POST -Body (@{ reason = $reason } | ConvertTo-Json -Compress) -ContentType 'application/json' -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck; $j = $r.Content | ConvertFrom-Json -AsHashtable; $j.status = [int]$r.StatusCode; $j }
    $r = & $rs $x.n 'scenario: the release never carried it'
    Check 'resettle sets the wait from the merge record (master was green: the release candidate)' ($r.status -eq 200 -and $r.awaiting -eq 'release-candidate' -and -not ((Pm-State $x.n).merge.ContainsKey('done_at'))) ($r | ConvertTo-Json -Compress)
    Check 'a journal line records it' (@((Get-FakeIssue $x.n).comments | Where-Object { $_.body -match 'plant event=settle-rearmed' -and $_.body -like '*the release never carried it*' }).Count -eq 1)
    Check 'the item is settled again to Done' (Wait-Until -Seconds 60 { (Get-FakeIssue $x.n).column -eq 'Done' -and -not (Get-FakeIssue $x.n).open })
    $o = New-Item-Fake 'Not merged' 'x' $OwnerLabels 'Todo'
    $r = & $rs $o 'x'; Check 'an item without a merge record is refused' ($r.status -eq 409 -and $r.code -eq 'not-merged') ($r | ConvertTo-Json -Compress)
}
