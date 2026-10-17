# Tier 1 scenarios for the PR QC environment, slice S2 (dashboard). Design: docs/design/pr-qc-environment.md sections 5 and 11.
# Same gateway and scripted worker as qc.ps1 (this file only adds scenarios to $QcScenarios, so they run in that suite, after the S1 ones).
# Scenario names start with "qc: dashboard"; run them alone with -Only "qc: dashboard".
# The page's rendering code sits between /*render-start*/ and /*render-end*/ in the served HTML; where node exists the scenarios run that block on hostile data.

function Dash-Url([string]$Path) { "$(Qc-Base)$Path" }
function Dash-Get([string]$Path, [string]$Token = 'test-token') {
    $h = @{}; if ($Token) { $h.Authorization = "Bearer $Token" }
    return Qc-Http 'GET' (Dash-Url $Path) $h
}
function Dash-Post([string]$Path, $Body = @{}, [string]$Token = 'test-token') {
    $h = @{}; if ($Token) { $h.Authorization = "Bearer $Token" }
    return Qc-Http 'POST' (Dash-Url $Path) $h $null 'application/json' ($Body | ConvertTo-Json -Compress)
}
# Start from the dashboard for a PR whose offer comment has just appeared: the sweep writes the comment before the gateway has taken in that sweep's
# result, so for a moment the gateway answers 404 no-such-pr. Asks again until it knows the PR (at most 15 seconds).
function Dash-Start([int]$Pr) {
    $end = (Get-Date).AddSeconds(15)
    while ($true) { $r0 = Dash-Post "/api/v1/qc/$Pr/start"; if ($r0.status -ne 404 -or (Get-Date) -ge $end) { return $r0 }; Start-Sleep -Milliseconds 300 }
}
function Dash-Rows { $l = Dash-Get '/api/v1/qc'; if ($l.status -ne 200 -or -not $l.json) { return @() }; return , @($l.json.rows) }
function Dash-Row([int]$Pr) { $r0 = @((Dash-Rows) | Where-Object { $_.pr -eq $Pr }); if ($r0.Count -gt 0) { return $r0[0] }; return $null }
# Waits (the list is cached for a few seconds) until the row of the PR satisfies the condition; returns the row or $null.
function Dash-WaitRow([int]$Pr, [scriptblock]$Cond, [int]$Seconds = 25) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) { $r0 = Dash-Row $Pr; if ($r0 -and (& $Cond $r0)) { return $r0 }; Start-Sleep -Milliseconds 700 }
    return $null
}
function Dash-Node([string]$Call, [string]$DataFile = '') {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }
    $html = (Qc-Http 'GET' (Dash-Url '/dashboard')).body
    $m = [regex]::Match($html, '(?s)/\*render-start\*/(.*)/\*render-end\*/')
    if (-not $m.Success) { return 'NO RENDER BLOCK' }
    $f = Join-Path $script:Work "dash-$([guid]::NewGuid().ToString('N').Substring(0,6)).js"
    Set-Content -Path $f -Value ("const fs=require('fs');const DATA=" + $(if ($DataFile) { "JSON.parse(fs.readFileSync('$DataFile','utf8'))" } else { 'null' }) + ";`n" + $m.Groups[1].Value + "`n" + $Call)
    return ((& $node.Source $f 2>&1) -join "`n")
}
function New-QcPrTitled([string]$Title) {
    $n = New-Item-Fake 'Dashboard trial' 'x' $QcLabels
    Do-TechnicalDesign $n 'w1' $false
    Fake 'push-branch' @{ branch = "factory-worker/$n-development"; files = @('src/a.cs'); profile = 'green' } | Out-Null
    $r0 = F 'w1' @('claim-item', '--item', $n, '--column', 'Development'); CheckExit 'claim development' $r0 0
    $r0 = F 'w1' @('open-pr', '--item', $n, '--head', "factory-worker/$n-development", '--title', $Title, '--body-file', (TmpFile "pr$n.md" 'change')); CheckExit 'open-pr' $r0 0
    $pr = $r0.pullRequest.number
    Do-DevComplete $n | Out-Null
    $v = Do-Verdict $n $pr; CheckExit 'verdict' $v 0
    [void](Wait-Until -Seconds 60 { (Qc-Token $pr) -ne '' })
    return @{ n = $n; pr = $pr; tok = (Qc-Token $pr) }
}
function Dash-StopWorker([string]$Name) {
    Stop-OwnerClient $Name
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq $Name -and $_.connected }).Count -eq 0 })
}

$QcDashScenarios = [ordered]@{

'qc: dashboard data calls need the operator token and the page stays anonymous' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $wtok = $script:Workers['qw1'].token
    $itemTok = $x.tok
    $no = Dash-Get '/api/v1/qc' ''; Check 'GET /api/v1/qc without a token: 401' ($no.status -eq 401) "$($no.status)"
    $wk = Dash-Get '/api/v1/qc' $wtok; Check 'with a worker credential: 403' ($wk.status -eq 403) "$($wk.status)"
    $lk = Dash-Get '/api/v1/qc' $itemTok; Check 'with a QC link token as bearer: 401' ($lk.status -eq 401) "$($lk.status)"
    $ok = Dash-Get '/api/v1/qc'; Check 'with the operator token: 200 and ok' ($ok.status -eq 200 -and $ok.json.ok -eq $true) "$($ok.status)"
    foreach ($act in 'start', 'reset', 'teardown', 'reassign', 'touch') {
        $p0 = Dash-Post "/api/v1/qc/$($x.pr)/$act" @{ worker = 'qw1' } ''
        $p1 = Dash-Post "/api/v1/qc/$($x.pr)/$act" @{ worker = 'qw1' } $wtok
        Check "POST $act without a token 401, with a worker credential 403" ($p0.status -eq 401 -and $p1.status -eq 403) "$($p0.status) $($p1.status)"
    }
    Check 'nothing was started by the refused calls' ($null -eq (Qc-Rec $x.n $x.pr) -and (Qc-QcAssignments $x.n).Count -eq 0)
    $pg = Qc-Http 'GET' (Dash-Url '/dashboard')
    Check 'GET /dashboard is anonymous and static HTML' ($pg.status -eq 200 -and $pg.body -match '<title>Factory Workers</title>' -and $pg.body -notmatch 'qc-test-secret')
    $hk = Qc-Http 'GET' "http://127.0.0.1:$($script:HookPort)/api/v1/qc" @{ Authorization = 'Bearer test-token' }
    Check 'the webhook port does not serve /api/v1/qc' ($hk.status -eq 404) "$($hk.status)"
    $b = Qc-Http 'GET' (Dash-Url '/_build')
    Check '/_build gives the environment and the version for the header' ($b.status -eq 200 -and "$($b.json.environment)" -ne '' -and "$($b.json.version)" -ne '')
    Check 'the page header reads /_build' ($pg.body -match "fetch\('/_build'\)" -and $pg.body -match 'id="ver"')
}

'qc: dashboard list shows available, ready, failed and stale rows [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered; $y = New-QcOffered; $z = New-QcOffered
    $row = Dash-WaitRow $x.pr { param($r0) $r0.state -eq 'available' }
    Check 'an eligible PR with a PASS verdict and no environment is listed as available' ($null -ne $row)
    if ($row) {
        Check 'the available row carries the item, the title, the author and the head' ($row.item -eq $x.n -and "$($row.title)" -like "Trial $($x.n)*" -and "$($row.author)" -ne '' -and "$($row.sha)" -eq (Get-Head $x.pr)) ($row | ConvertTo-Json -Compress)
        Check 'an available row is not stale and has no worker' (-not $row.stale -and "$($row.worker)" -eq '')
    }
    Check 'the list names the repository for the links' ((Dash-Get '/api/v1/qc').json.repo_url -eq 'https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders')
    # ready
    $x = Start-QcRun $x 'running'; $rep = Qc-Report $x "http://$(Qc-Fake)"; CheckExit 'x ready' $rep 0
    $row = Dash-WaitRow $x.pr { param($r0) $r0.state -eq 'ready' -and $r0.ContainsKey('url') }
    Check 'a ready environment shows state ready and its URL' ($null -ne $row -and $row.url -eq "http://$(Qc-Fake)")
    if ($row) {
        Check 'ready row: worker, attempt, probe, not stale' ($row.worker -eq 'qw1' -and $row.attempt -eq 1 -and $row.probe -in 'verified', 'unverified' -and -not $row.stale)
        Check 'ready row: head equals the environment sha, age is a number' ($row.head -eq $row.sha -and (Pv $row 'age_seconds') -ge 0)
        Check 'ready row: the dashboard may reassign it to a qualified worker' (@($row.reassign_to) -contains 'qw1')
    }
    Check 'the ready PR is listed once and is no longer an available row' (@((Dash-Rows) | Where-Object { $_.pr -eq $x.pr }).Count -eq 1)
    # failed
    $y = Start-QcRun $y 'running'
    $f = Fo 'qw1' @('qc-fail', '--item', $y.n, '--pr', $y.pr, '--code', 'build-failed', '--reason-file', (TmpFile 'dash-fail.txt' 'compile error CS1002')); CheckExit 'y failed' $f 0
    $row = Dash-WaitRow $y.pr { param($r0) $r0.state -eq 'failed' }
    Check 'a failed environment is a row with its failure code and reason and no URL' ($null -ne $row -and $row.fail.code -eq 'build-failed' -and "$($row.fail.reason)" -match 'CS1002' -and -not $row.ContainsKey('url'))
    Check 'the failed PR is one row (Reset or Tear down apply), not also an available row' (@((Dash-Rows) | Where-Object { $_.pr -eq $y.pr }).Count -eq 1)
    # stale
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('src/a.cs', 'src/dash.cs') } | Out-Null
    $newSha = Get-Head $x.pr
    $row = Dash-WaitRow $x.pr { param($r0) $r0.stale -and $r0.head -eq $newSha } 60
    Check 'after a new push the environment row is flagged stale and shows both heads' ($null -ne $row -and $row.head -eq $newSha -and $row.sha -ne $newSha)
    # a third PR stays available while the others are live
    $row = Dash-Row $z.pr
    Check 'a PR nobody started is still available' ($null -ne $row -and $row.state -eq 'available')
    $rows = @(Dash-Rows)
    $ages = @($rows | Where-Object { $_.ContainsKey('age_seconds') } | ForEach-Object { [int](Pv $_ 'age_seconds') })
    $sorted = @($ages | Sort-Object -Descending)
    Check 'rows are sorted by age, oldest first' (($ages -join ',') -eq ($sorted -join ',')) ($ages -join ',')
}

'qc: dashboard escapes hostile titles, reasons, authors, urls and addresses [full]' = {
    Ensure-QcWorker
    $title = '<img src=x onerror=alert(1)> & "q" <script>alert(2)</script>'
    $x = New-QcPrTitled $title
    $row = Dash-WaitRow $x.pr { param($r0) $r0.state -eq 'available' }
    Check 'the list carries the title as data (raw JSON, no HTML)' ($null -ne $row -and "$($row.title)".StartsWith($title)) "[$($row.title)]"
    $x = Start-QcRun $x 'running'
    $f = Fo 'qw1' @('qc-fail', '--item', $x.n, '--pr', $x.pr, '--code', 'build-failed', '--reason-file', (TmpFile 'dash-evil.txt' '<b onmouseover=alert(3)>bold</b> "quoted"')); CheckExit 'failed with a hostile reason' $f 0
    $l = Dash-Get '/api/v1/qc'
    $pg = Qc-Http 'GET' (Dash-Url '/dashboard')
    Check 'the page escapes every PR and work item string with esc() in the row template' ($pg.body -match 'esc\(x\.title\)' -and $pg.body -match 'esc\(x\.author\)' -and $pg.body -match 'esc\(x\.worker' -and $pg.body -match 'esc\(x\.fail' -and $pg.body -match 'esc\(x\.state\)' -and $pg.body -match 'esc\(x\.item\)')
    $raw = [regex]::Matches(([regex]::Match($pg.body, '(?s)function qcRowHtml.*?\r?\nfunction buildPrompt').Value), '\$\{(x\.[a-z_.]+)[^}]*\}') | ForEach-Object { $_.Value }
    Check 'no row field is put into the template without esc() or a number conversion' (@($raw).Count -eq 0 -or @($raw | Where-Object { $_ -notmatch 'esc\(|\.map\(|\.join\(|\.filter\(' }).Count -eq 0) (($raw | Where-Object { $_ -notmatch 'esc\(' }) -join ' | ')
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host '    skip  rendering checks: node is not installed' }
    else {
        $data = Join-Path $script:Work 'dash-list.json'; Set-Content -Path $data -Value $l.body
        $out = Dash-Node "console.log(DATA.rows.map(r=>qcRowHtml(r,DATA.repo_url)).join('\n'))" $data
        Check 'rendering the real list: the title comes out as text' ($out -match '&lt;img src=x onerror=alert\(1\)&gt; &amp; &quot;q&quot; &lt;script&gt;alert\(2\)&lt;/script&gt;') $out
        Check 'rendering the real list: no raw tag from the title or the failure reason' ($out -notmatch '<img' -and $out -notmatch '<script' -and $out -notmatch '<b onmouseover' -and $out -match '&lt;b onmouseover=alert\(3\)&gt;')
        $synth = Join-Path $script:Work 'dash-synth.json'
        Set-Content -Path $synth -Value (@{ rows = @(@{ pr = 7; item = '9"><i>'; title = "t'<u>"; sha = 'abcdef0123456789'; head = '1234567<s>'; stale = $true; author = '<b>a</b>'; state = 'ready'; worker = 'w<i>'; url = 'javascript:alert(1)'; reassign_to = @('<o>', 'w2'); waiting = '<w>' }); workers = @(@{ name = 'n<b>'; type = 't<i>'; connected = $true; draining = $false; owned = 0; capacity = 1; roles = @('qc', '<r>'); qcActive = 0; qcCapacity = 2; qcProfile = $true; qcAddress = '<a href=x>' }) } | ConvertTo-Json -Depth 6)
        $o2 = Dash-Node "console.log(DATA.rows.map(r=>qcRowHtml(r,'https://github.com/a/b')).join('\n')+'\n'+DATA.workers.map(workerRowHtml).join('\n'))" $synth
        Check 'a javascript: URL never becomes a link' ($o2 -notmatch 'javascript:' -and $o2 -notmatch 'data-a="touch"')
        Check 'a hostile author, item, worker, head, option and session field are text' ($o2 -notmatch '<b>' -and $o2 -notmatch '<i>' -and $o2 -notmatch '<u>' -and $o2 -notmatch '<s>' -and $o2 -notmatch '<o>' -and $o2 -notmatch '<r>' -and $o2 -notmatch '<a href=x>') $o2
        Check 'a quote in the item cannot break out of the link attribute' ($o2 -match 'issues/9&quot;&gt;&lt;i&gt;')
    }
}

'qc: dashboard Start, Reset and Tear down use the operator token and record the operator [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $s1 = Dash-Start $x.pr
    Check 'Start from the dashboard: 200 started' ($s1.status -eq 200 -and $s1.json.code -eq 'started') "$($s1.status) $($s1.body)"
    Check 'the worker is offered the job and the journal says qc-requested' ((Wait-Until -Seconds 30 { (Qc-Events 'qw1' $x.n).Count -eq 1 }) -and (Qc-JournalCount $x.n 'qc-requested') -eq 1)
    $asg1 = "$((Qc-QcAssignments $x.n)[0].id)"
    $s2 = Dash-Post "/api/v1/qc/$($x.pr)/start"
    Check 'Start again finds the live environment: 200 existing' ($s2.status -eq 200 -and $s2.json.code -eq 'existing') "$($s2.status) $($s2.body)"
    $row = Dash-WaitRow $x.pr { param($r0) $r0.state -in 'assigned', 'requested' -and $r0.worker -eq 'qw1' }
    Check 'the row shows the assigned worker' ($null -ne $row)
    $r1 = Dash-Post "/api/v1/qc/$($x.pr)/reset"
    Check 'Reset from the dashboard: 200 reset, attempt 2' ($r1.status -eq 200 -and $r1.json.code -eq 'reset' -and (Qc-Rec $x.n $x.pr).attempt -eq 2) "$($r1.status) $($r1.body)"
    $asg2 = "$((Qc-QcAssignments $x.n)[0].id)"
    Check 'Reset minted a new assignment id' ($asg2 -ne '' -and $asg2 -ne $asg1)
    $t1 = Dash-Post "/api/v1/qc/$($x.pr)/teardown"
    Check 'Tear down from the dashboard: 200' ($t1.status -eq 200 -and $t1.json.code -in 'torn-down', 'already') "$($t1.status) $($t1.body)"
    Check 'the record is torn down (it was never accepted, so no worker has to confirm)' ((Wait-Until -Seconds 20 { (Qc-RecState $x.n $x.pr) -eq 'torn-down' })) (Qc-RecState $x.n $x.pr)
    $e1 = Dash-Post '/api/v1/qc/987654/start'
    Check 'a PR the gateway does not know: 404' ($e1.status -eq 404) "$($e1.status) $($e1.body)"
    $e2 = Dash-Post "/api/v1/qc/$($x.pr)/explode"
    Check 'an unknown action: 404' ($e2.status -eq 404) "$($e2.status)"
}

'qc: dashboard Start by the operator is the only way past a trust confirmation [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    Fake 'pr' @{ number = $x.pr; author = 'stranger-dev' } | Out-Null
    $link = Qc-Click $x.pr $x.tok 'start'
    Check 'the anonymous link is refused: 409 trust-confirm-needed' ($link.status -eq 409 -and $link.reason -eq 'trust-confirm-needed') "$($link.status) $($link.reason)"
    $d1 = Dash-Start $x.pr
    Check 'the dashboard Start without a confirmation: 409 with the reasons' ($d1.status -eq 409 -and $d1.json.code -eq 'trust-confirm-needed' -and (@($d1.json.reasons) -join ',') -match 'author-not-trusted') "$($d1.status) $($d1.body)"
    Check 'nothing was queued yet' ($null -eq (Qc-Rec $x.n $x.pr))
    $d2 = Dash-Post "/api/v1/qc/$($x.pr)/start" @{ confirm = $true }
    Check 'the dashboard Start with confirm: 200 started' ($d2.status -eq 200 -and $d2.json.code -eq 'started') "$($d2.status) $($d2.body)"
    Check 'the record remembers the confirmation' ((Qc-Rec $x.n $x.pr).trust_confirmed -eq $true)
}

'qc: dashboard Reassign moves the assignment and mints a new assignment id [full]' = {
    Ensure-QcWorker
    Ensure-QcWorker 'qw2' '127.0.0.1' '--qc-capacity 1'
    try {
        $x = New-QcOffered
        $x = Start-QcRun $x 'running'; [void](Qc-Report $x "http://$(Qc-Fake)")
        $asg1 = $x.asg
        $row = Dash-WaitRow $x.pr { param($r0) $r0.state -eq 'ready' -and @($r0.reassign_to) -contains 'qw2' }
        Check 'the row offers qw2 as a reassign target' ($null -ne $row)
        $re = Dash-Post "/api/v1/qc/$($x.pr)/reassign" @{ worker = 'qw2' }
        Check 'Reassign: 200 reassigned' ($re.status -eq 200 -and $re.json.code -eq 'reassigned') "$($re.status) $($re.body)"
        $got = Wait-Until -Seconds 30 { (Qc-Events 'qw2' $x.n).Count -gt 0 }
        if (-not $got) { Write-Host ('DEBUG ' + ((Get-Plant).plant.assignments | ConvertTo-Json -Compress -Depth 4)); Write-Host ('DEBUG ' + ((Get-Content $script:Workers['qw2'].out -Raw) -replace '\s+', ' ')) }
        Check 'the other worker is offered the job' $got
        if ($got) {
            $ev = (Qc-Events 'qw2' $x.n)[0]
            Check 'a new assignment id was minted' ($ev.assignment -ne $asg1 -and $ev.assignment -ne '') "$($ev.assignment) vs $asg1"
            $rec = Qc-Rec $x.n $x.pr
            Check 'the record names the new worker and assignment, attempt 2, and keeps the old id as stale' ($rec.worker -eq 'qw2' -and $rec.assignment -eq $ev.assignment -and $rec.attempt -eq 2 -and @($rec.old_assignments) -contains $asg1) ($rec | ConvertTo-Json -Compress)
            Check 'plant: one qc assignment, held by qw2' ((Qc-QcAssignments $x.n).Count -eq 1 -and (Qc-QcAssignments $x.n)[0].worker -eq 'qw2')
        }
        $stop = Wait-Until -Seconds 20 { @(Get-WorkerEvents 'qw1' | Where-Object { $_.event -in 'qc.reset', 'qc.teardown' -and $_.pr -eq $x.pr }).Count -gt 0 }
        Check 'the old worker was told to stop its environment' $stop
        $old = Fo 'qw1' @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'building')
        CheckExit 'the old worker token is now stale' $old 11 'stale-assignment'
        $none = Dash-Post "/api/v1/qc/$($x.pr)/reassign" @{ worker = 'ghost' }
        Check 'an unknown worker: 404 no-such-worker' ($none.status -eq 404 -and $none.json.code -eq 'no-such-worker') "$($none.status) $($none.body)"
        $nw = Dash-Post "/api/v1/qc/$($x.pr)/reassign" @{}
        Check 'no worker named: 400' ($nw.status -eq 400) "$($nw.status)"
        # qw2 has capacity 1 and holds this PR: another PR cannot go there
        $y = New-QcOffered; $y = Start-QcRun $y 'accepted'
        $full = Dash-Post "/api/v1/qc/$($y.pr)/reassign" @{ worker = 'qw2' }
        Check 'a worker at capacity: 409 worker-full' ($full.status -eq 409 -and $full.json.code -eq 'worker-full') "$($full.status) $($full.body)"
        Start-OwnerClient 'qd-owner' 'persistent-local' ''
        $uq = Dash-Post "/api/v1/qc/$($y.pr)/reassign" @{ worker = 'qd-owner' }
        Check 'a worker without the qc role: 409 worker-unqualified' ($uq.status -eq 409 -and $uq.json.code -eq 'worker-unqualified') "$($uq.status) $($uq.body)"
        $verb = F 'op' @('qc-reassign', '--pr', $y.pr, '--worker', 'ghost')
        CheckExit 'the verb qc-reassign gives exit 12 for an unknown worker' $verb 12 'no-such-worker'
    } finally { Dash-StopWorker 'qw2'; Dash-StopWorker 'qd-owner' }
}

'qc: dashboard qc-touch extends the lease only in memory [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'; [void](Qc-Report $x "http://$(Qc-Fake)")
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); CheckExit 'heartbeat' $hb 0
    # what the report and the heartbeat started (the journal comment of "ready" is written after the verb has answered) must be finished before the snapshot: wait until nothing has changed for 1.5 seconds
    $snap = ''; $quietSince = Get-Date; $giveUp = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $giveUp -and ((Get-Date) - $quietSince).TotalSeconds -lt 1.5) { $cur = "$((Qc-StateComment $x.n).body)|$(@((Get-FakeIssue $x.n).comments).Count)|$(@((Get-FakePr $x.pr).comments).Count)"; if ($cur -cne $snap) { $snap = $cur; $quietSince = Get-Date }; Start-Sleep -Milliseconds 300 }
    $stateBefore = (Qc-StateComment $x.n).body; $itemC = @((Get-FakeIssue $x.n).comments).Count; $prC = @((Get-FakePr $x.pr).comments).Count
    $revBefore = (Qc-Rec $x.n $x.pr).rev
    Start-Sleep -Seconds 2
    $t = F 'op' @('qc-touch', '--item', $x.n, '--pr', $x.pr); CheckExit 'qc-touch' $t 0
    Check 'the lease now ends later than at the heartbeat' ([datetime]"$($t.lease_until)" -gt [datetime]"$($hb.lease_until)") "$($t.lease_until) vs $($hb.lease_until)"
    Check 'last_touch is recorded' ("$($t.last_touch)" -ne '')
    Check 'the state comment is byte-for-byte unchanged' ((Qc-StateComment $x.n).body -ceq $stateBefore)
    Check 'the record revision did not move' ((Qc-Rec $x.n $x.pr).rev -eq $revBefore)
    Check 'no comment was written on the item or the PR' (@((Get-FakeIssue $x.n).comments).Count -eq $itemC -and @((Get-FakePr $x.pr).comments).Count -eq $prC)
    $api = Dash-Post "/api/v1/qc/$($x.pr)/touch"
    Check 'POST /api/v1/qc/{pr}/touch (the Open button) also answers 200 touched' ($api.status -eq 200 -and $api.json.code -eq 'touched') "$($api.status) $($api.body)"
    $g = Qc-Get $x.pr $x.tok '/go'
    Check 'the /go link still redirects and touches' ($g.status -eq 302 -and $g.location -eq "http://$(Qc-Fake)")
    $nope = Fo 'qw1' @('qc-touch', '--item', $x.n, '--pr', $x.pr)
    Check 'a qc item token cannot call qc-touch' ($nope.exit -ne 0 -and (Pv $nope 'ok') -ne $true) ($nope | ConvertTo-Json -Compress)
    $none = F 'op' @('qc-touch', '--item', $x.n, '--pr', 999111); CheckExit 'a PR without an environment: 12' $none 12 'no-environment'
    Check 'still no comment written after all the touches' (@((Get-FakeIssue $x.n).comments).Count -eq $itemC -and (Qc-StateComment $x.n).body -ceq $stateBefore)
}

'qc: dashboard worker rows carry the QC column from the registration fields [full]' = {
    Ensure-QcWorker
    Start-OwnerClient 'qd-noprofile' 'persistent-local' '--roles qc --capabilities git --qc-address 10.9.8.7'
    try {
        $d = Dash-Get '/api/v1/dashboard'
        $w1 = @($d.json.plant.workers | Where-Object { $_.name -eq 'qw1' })[0]
        $w3 = @($d.json.plant.workers | Where-Object { $_.name -eq 'qd-noprofile' })[0]
        Check 'qw1 reports capacity 2, a profile and its address' ($w1.qcCapacity -eq 2 -and $w1.qcProfile -eq $true -and $w1.qcAddress -eq '127.0.0.1' -and $w1.qcActive -eq 0) ($w1 | ConvertTo-Json -Compress)
        Check 'a qc worker registered without --qc-profile shows no profile, its address, capacity 1' ($w3.qcProfile -eq $false -and $w3.qcAddress -eq '10.9.8.7' -and $w3.qcCapacity -eq 1) ($w3 | ConvertTo-Json -Compress)
        $x = New-QcOffered; $x = Start-QcRun $x 'accepted'
        $d = Dash-Get '/api/v1/dashboard'; $w1 = @($d.json.plant.workers | Where-Object { $_.name -eq 'qw1' })[0]
        Check 'an accepted environment counts as active QC on its worker' ($w1.qcActive -eq 1) "$($w1.qcActive)"
        Check 'the dashboard reports the gateway environment' ("$($d.json.environment)" -ne '')
        $pg = Qc-Http 'GET' (Dash-Url '/dashboard')
        Check 'the page has a QC column in the session table' ($pg.body -match '<th>QC</th>' -and $pg.body -match 'qcActive' -and $pg.body -match 'profile set' -and $pg.body -match 'no profile')
        if (Get-Command node -ErrorAction SilentlyContinue) {
            $data = Join-Path $script:Work 'dash-workers.json'; Set-Content -Path $data -Value $d.body
            $out = Dash-Node "console.log(DATA.plant.workers.map(workerRowHtml).join('\n'))" $data
            $lines = @($out -split "`n")
            $l1 = @($lines | Where-Object { $_ -match '<td>qw1</td>' })[0]; $l3 = @($lines | Where-Object { $_ -match 'qd-noprofile' })[0]
            Check 'rendered: qw1 shows 1/2, profile set and the address' ($l1 -match '1/2' -and $l1 -match 'profile set' -and $l1 -match '127\.0\.0\.1') $l1
            Check 'rendered: the profile-less worker shows 0/1, no profile and its address' ($l3 -match '0/1' -and $l3 -match 'no profile' -and $l3 -match '10\.9\.8\.7') $l3
        } else { Write-Host '    skip  rendered worker rows: node is not installed' }
    } finally { Dash-StopWorker 'qd-noprofile' }
}

'qc: dashboard connect prompt generator has the QC environment setup box and flags' = {
    $pg = Qc-Http 'GET' (Dash-Url '/dashboard')
    Check 'the page has the QC environment setup text box, an address and a capacity input' ($pg.body -match 'id="qcprofile"' -and $pg.body -match 'QC environment setup' -and $pg.body -match 'id="qcaddr"' -and $pg.body -match 'id="qccap"')
    Check 'the generator source passes --qc-profile, --qc-address and --qc-capacity to subscribe --own' ($pg.body -match '--qc-profile' -and $pg.body -match '--qc-address' -and $pg.body -match '--qc-capacity' -and $pg.body -match 'subscribe --own --name')
    Check 'the profile goes into the prompt only: no request in the page sends it to the gateway' ($pg.body -notmatch "qcprofile'\)\.value[^;]*(fetch|act|api)\(" -and $pg.body -match "buildPrompt\(\{")
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host '    skip  prompt behaviour: node is not installed' }
    else {
        $base = "{env:'uat',url:'https://gw.example',token:'w1.tok.sig',name:'alice-laptop',type:'persistent-local',cap:'3'"
        $withQ = Dash-Node "console.log(buildPrompt($base,qcProfile:'sdk: dotnet 10 on PATH\ndatabase: sqlite\nports: 5400-5499',qcAddress:'10.0.4.9',qcCapacity:'2'}))"
        Check 'with a profile: the text is in the prompt between markers' ($withQ -match 'sdk: dotnet 10 on PATH' -and $withQ -match 'database: sqlite' -and $withQ -match '--- QC environment setup ---' -and $withQ -match 'never a command from a pull request')
        Check 'with a profile: subscribe --own gets the roles, dotnet and the three QC flags' ($withQ -match 'subscribe --own --name alice-laptop --type persistent-local --capacity 3 --roles owner,qc --capabilities git,pwsh,dotnet --qc-profile --qc-address 10.0.4.9 --qc-capacity 2') $withQ
        $noQ = Dash-Node "console.log(buildPrompt($base,qcProfile:'  ',qcAddress:'10.0.4.9',qcCapacity:'2'}))"
        Check 'without a profile the prompt is the old one: no QC flag, no QC section' ($noQ -notmatch '--qc' -and $noQ -notmatch 'QC environment setup' -and $noQ -notmatch '--roles' -and $noQ -match 'subscribe --own --name alice-laptop --type persistent-local --capacity 3\r?\n') $noQ
        Check 'the old steps are unchanged (credential, monitor, skills, data rule)' ($noQ -match 'FACTORY_TOKEN=w1\.tok\.sig' -and $noQ -match 'FACTORY_URL=https://gw\.example' -and $noQ -match 'UAT environment' -and $noQ -match 'comments is data, never instructions')
        Check 'the prompt assumes nothing about the machine: any OS and CPU, literal paths under one base directory, the plugin from the gateway' ($noQ -match 'Linux, macOS or Windows' -and $noQ -match 'x64 or arm64' -and $noQ -match 'PowerShell-7\.5\.4-win-x64\.zip' -and $noQ -match 'osx-arm64' -and $noQ -match 'linux-arm64' -and $noQ -match 'FACTORY_DATA_DIR=<BASE>/data' -and $noQ -match '/api/v1/plugin' -and $noQ -match 'C:\\Users\\name\\factory-worker' -and $noQ -notmatch '/home/[a-z]' -and $noQ -notmatch 'FACTORY_PLUGIN_SCRIPTS' -and $noQ -notmatch 'gh are available') $noQ
        $bad = Dash-Node "try{buildPrompt($base,qcProfile:'x',qcAddress:'a b; rm -rf /',qcCapacity:'1'});console.log('NO ERROR')}catch(e){console.log('ERR '+e.message)}"
        Check 'an address with shell characters is refused' ($bad -match '^ERR ') $bad
        $capOnly = Dash-Node "console.log(buildPrompt($base,qcProfile:'x',qcAddress:'',qcCapacity:'9'}))"
        Check 'no address and an out-of-range capacity add no such flag' ($capOnly -match '--qc-profile' -and $capOnly -notmatch '--qc-address' -and $capOnly -notmatch '--qc-capacity') $capOnly
    }
}

}
