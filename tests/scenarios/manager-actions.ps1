# The plant manager's flow verbs (docs/design/plant-manager.md 10e, gateway/Manager.cs, plugin/scripts/lib/Verbs.Manager.ps1): the supervisor
# unparks, releases an owner, pins and unpins, requeues, prioritizes, re-runs failed jobs once per head, drains and resumes a name and restarts a
# session; never merges, approves, records a verdict or clears a hold. Every action names a policy code and is journaled; the label hold:owner
# refuses all of them; at most 3 actions per item a day and manager.actions.perHour over every item; manager.mode advise turns them off.
# The scenarios join the manager suite (run.ps1). Items the suite's own gateway must not offer are pinned to a session that never connects.

function Ma-State([int]$n) {
    $sc = @((Get-FakeIssue $n).comments | Where-Object { $_.body -like '<!-- factory-state:*' })
    if ($sc.Count -eq 0) { return @{} }
    $mm = [regex]::Match($sc[0].body, '(?s)```json\s*(.*?)\s*```'); return ($mm.Groups[1].Value | ConvertFrom-Json -AsHashtable -DateKind String)
}
function Ma-Labels([int]$n) { , @((Get-FakeIssue $n).labels) }
function Ma-Journal([int]$n, [string]$Event) { , @((Get-FakeIssue $n).comments | Where-Object { $_.body -match "<!-- plant event=$Event " }) }
function Ma-Act([string[]]$ActArgs) { Mgr-F (@('act') + $ActArgs) }
function Ma-Worker([string]$Name) { Msg-First @((Msg-Admin '/api/v1/status').plant.workers | Where-Object { $_.name -eq $Name }) }
function Ma-Mode([string]$Value, [string]$Bearer = 'test-token') {
    $r = Invoke-WebRequest (Msg-Url "/api/v1/manager/mode?value=$Value") -Method POST -Headers @{ Authorization = "Bearer $Bearer" } -SkipHttpErrorCheck -TimeoutSec 10
    $j = Msg-Json $r; $j.status = [int]$r.StatusCode; return $j
}
# an item parked by its worker's failure report (park worker-failure), pinned to a session that never connects
function Ma-Parked([string]$Title, [string[]]$Extra = @()) {
    $n = New-Item-Fake $Title 'x' (@('factory worker', 'worker:ghost-act') + $Extra)
    $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Technical Design'); CheckExit "claim $n" $r 0
    $r = F 'w1' @('complete', '--item', $n, '--column', 'Technical Design', '--succeeded', 'false', '--comment', 'the criterion cannot be met as written')
    Check "item $n is parked" ($r.exit -eq 0 -and (Ma-State $n).ContainsKey('park')) ($r | ConvertTo-Json -Compress)
    return $n
}

$ManagerActionScenarios = [ordered]@{}

$ManagerActionScenarios['act: the supervisor unparks, pins and prioritizes an item, each journaled with its policy; the fourth action of a day, hold:owner, advise mode and the never-verbs are refused'] = {
    $n = Ma-Parked 'Act on a parked item'
    $sup = Start-ManagerClient 'act-a'
    # a pin names a session the gateway knows: carol registers once and leaves (she is offered nothing meanwhile: no capacity is free for long)
    $carol = Msg-Open 'name=carol&capacity=1&messaging=1' (Msg-Token 'carol'); Msg-Registered $carol; Msg-Close $carol
    try {
        Check 'the supervisor registers' (Msg-WaitEvent $sup 'supervisor.registered') (Get-Content -Raw $sup.out)
        $r = Ma-Act @('pin', '--item', "$n", '--worker', 'nobody-here', '--policy', 'pinned-worker-absent')
        CheckExit 'a pin to a session that never registered is refused' $r 12 'no-such-worker'
        $r = Ma-Act @('unpark', '--item', "$n", '--policy', 'park-resolved', '--reason', 'the owner reworded criterion 2')
        CheckExit 'unpark' $r 0
        $st = Ma-State $n
        Check 'the park is gone and the item is handed off to its column' (-not $st.ContainsKey('park') -and $st.handoff.column -eq 'Technical Design' -and $r.reoffer -eq $true -and $r.park.reason -eq 'worker-failure') ($r | ConvertTo-Json -Compress -Depth 4)
        $j = @(Ma-Journal $n 'manager-action')
        Check 'one journal line names the supervisor, the action, the policy code and the reason' ($j.Count -eq 1 -and $j[0].body -match 'the plant manager \(\*\*supervisor\*\*\) released the park `worker-failure`' -and $j[0].body -match 'policy `park-resolved`' -and $j[0].body -match 'reworded criterion 2') (($j | ForEach-Object { $_.body }) -join ' | ')
        $r = Ma-Act @('pin', '--item', "$n", '--worker', 'carol', '--policy', 'pinned-worker-absent')
        CheckExit 'pin' $r 0
        $lb = Ma-Labels $n
        Check 'the item is pinned to carol and no longer to the absent worker' (($lb -contains 'worker:carol') -and -not ($lb -contains 'worker:ghost-act') -and @($r.was) -contains 'ghost-act') ($lb -join ',')
        $r = Ma-Act @('prioritize', '--item', "$n", '--level', 'top', '--policy', 'backlog-order')
        CheckExit 'prioritize' $r 0
        Check 'the item carries priority:top' ((Ma-Labels $n) -contains 'priority:top')
        $sw = Msg-Json (Msg-Verb 'sync-board' 'test-token' @{ dry = $true })
        Check 'the sweep reports the priority for the plan' ($sw.ok -eq $true -and "$($sw.priorities["$n"])" -eq 'top') ($sw.priorities | ConvertTo-Json -Compress)
        Check 'three actions are recorded on the item' (@((Ma-State $n).manager_actions).Count -eq 3 -and @((Ma-State $n).manager_actions | Where-Object { $_.by -eq 'supervisor' }).Count -eq 3)
        $r = Ma-Act @('unpin', '--item', "$n", '--policy', 'pinned-worker-absent')
        CheckExit 'the fourth action on one item in a day is refused' $r 10 'item-action-limit'
        Check 'it names the limit and when to try again' ($r.limit -eq 3 -and $r.retryAfterSeconds -gt 3600) ($r | ConvertTo-Json -Compress)
        Check 'and changed nothing' ((Ma-Labels $n) -contains 'worker:carol')
        # the owner's hold wins
        $h = New-Item-Fake 'Held by the owner' 'x' @('factory worker', 'worker:ghost-act', 'hold:owner')
        $r = Ma-Act @('prioritize', '--item', "$h", '--policy', 'backlog-order')
        CheckExit 'an item labelled hold:owner refuses every action' $r 10 'owner-hold'
        Check 'nothing changed on it: no label, no journal line, no action recorded' (-not ((Ma-Labels $h) -contains 'priority:top') -and (Ma-Journal $h 'manager-action').Count -eq 0 -and -not (Ma-State $h).ContainsKey('manager_actions'))
        # a policy code is required and must be one of the list
        $r = Ma-Act @('requeue', '--item', "$h")
        CheckExit 'no policy code: usage' $r 2 'usage'
        $r = Ma-Act @('requeue', '--item', "$h", '--policy', 'because-i-say-so')
        CheckExit 'an unknown policy code is refused' $r 2 'unknown-policy'
        # advise mode: set by the operator token only
        $m = Ma-Mode 'advise' (New-ManagerToken)
        Check 'the supervisor cannot set its own mode' ($m.status -eq 403) ($m | ConvertTo-Json -Compress)
        $m = Ma-Mode 'advise'
        Check 'the operator sets advise' ($m.status -eq 200 -and $m.mode -eq 'advise')
        $p = Ma-Parked 'Parked in advise mode'
        $r = Ma-Act @('unpark', '--item', "$p", '--policy', 'park-resolved')
        CheckExit 'in advise mode every action is refused' $r 10 'advise-mode'
        Check 'and the park stays' ((Ma-State $p).ContainsKey('park'))
        $s = (Msg-Admin '/api/v1/status').managerActions
        Check '/status shows the mode and who set it' ($s.mode -eq 'advise' -and $s.modeSource -eq 'operator') ($s | ConvertTo-Json -Compress)
        $m = Ma-Mode 'act'
        Check 'the operator sets act again' ($m.status -eq 200 -and $m.mode -eq 'act')
        # the verbs that decide about the work itself stay refused
        foreach ($v in @(@('merge', '--item', "$n"), @('approve-pr', '--item', "$n", '--verdict', 'APPROVE'), @('validation-verdict', '--item', "$n", '--passed', 'true'), @('clear-hold', '--item', "$n"))) {
            $r = Mgr-F $v
            Check "$($v[0]) stays refused to the supervisor" ($r.exit -eq 30 -and "$($r.reason)" -ceq "the manager role cannot call '$($v[0])'") ($r | ConvertTo-Json -Compress)
        }
        $w = Msg-Json (Msg-Verb 'manager-action' (Msg-Token 'alice') @{ item = $n; action = 'unpin'; policy = 'pinned-worker-absent' })
        Check 'a worker credential cannot call manager-action' ($w.exit -eq 30 -and $w.code -eq 'forbidden') ($w | ConvertTo-Json -Compress)
        $log = Mgr-F @('act-log')
        Check 'act-log lists the actions with their policy codes and the refused one' ($log.exit -eq 0 -and @($log.actions | Where-Object { $_.ok -and $_.item -eq $n }).Count -eq 3 -and @($log.actions | Where-Object { -not $_.ok -and $_.code -eq 'item-action-limit' }).Count -ge 1 -and $log.perItemPerDay -eq 3 -and $log.perHour -eq 30) ($log | ConvertTo-Json -Compress -Depth 4)
    } finally { [void](Ma-Mode 'act'); Mgr-Stop $sup }
}

$ManagerActionScenarios['act: unpark refuses the parks only a person ends, requeue refuses an owned or parked item, and rerun-failed re-runs the failed jobs of the head once'] = {
    $sup = Start-ManagerClient 'act-b'
    try {
        Check 'the supervisor registers' (Msg-WaitEvent $sup 'supervisor.registered') (Get-Content -Raw $sup.out)
        # a PASS verdict that waits for a person's merge (no Auto Merge): only a merge ends that park
        $n = New-Item-Fake 'PASS without Auto Merge' 'x' @('factory worker', 'worker:ghost-act')
        Do-TechnicalDesign $n 'w1' $true
        $pr = Do-Development $n
        Do-DevComplete $n | Out-Null
        $v = Do-Verdict $n $pr
        Check 'the PASS parks the item for a person''s merge' ((Ma-State $n).park.reason -eq 'pass-without-auto-merge') ((Ma-State $n) | ConvertTo-Json -Compress -Depth 4)
        $r = Ma-Act @('unpark', '--item', "$n", '--policy', 'park-resolved')
        CheckExit 'unpark of a PASS waiting for a merge is refused' $r 10 'needs-merge'
        $r = Ma-Act @('requeue', '--item', "$n", '--policy', 'stuck-offer')
        CheckExit 'requeue of a parked item points to unpark' $r 10 'parked'
        # an owned item: requeue points to release-owner
        $o = New-Item-Fake 'Owned item' 'x' @('factory worker', 'worker:ghost-act')
        $r = F 'w1' @('claim-item', '--item', $o, '--column', 'Technical Design', '--owner', 'true', '--worker', 'w1', '--assignment', 'a-test'); CheckExit 'an owner claims it' $r 0
        $r = Ma-Act @('requeue', '--item', "$o", '--policy', 'stuck-offer')
        CheckExit 'requeue of an item with a live claim is refused' $r 10 'owned'
        $r = Ma-Act @('release-owner', '--item', "$o", '--policy', 'stalled-owner', '--reason', 'no verb for 50 minutes')
        CheckExit 'release-owner ends the claim''s lease' $r 0
        $st = Ma-State $o
        Check 'the claim stays, its lease ended, marked taken_back' ("$($st.claim.taken_back)" -eq 'released-by-plant-manager' -and [DateTime]::Parse("$($st.claim.lease_until)").ToUniversalTime() -lt [DateTime]::UtcNow) ($st | ConvertTo-Json -Compress -Depth 4)
        $r = Ma-Act @('requeue', '--item', "$o", '--policy', 'stuck-offer')
        CheckExit 'requeue of the released item' $r 0
        Check 'it is handed off to its column' ((Ma-State $o).handoff.column -eq 'Technical Design')
        # rerun-failed: a completed failed run of the head is re-run once; the same head again is refused
        $d = New-Item-Fake 'Flaky check' 'x' @('factory worker', 'worker:ghost-act') 'Development'
        $dpr = Do-Development $d; $head = Get-Head $dpr
        $r = Ma-Act @('rerun-failed', '--item', "$d", '--policy', 'flaky-check')
        CheckExit 'nothing failed: refused' $r 10 'nothing-failed'
        Fake 'checks' @{ sha = $head; name = 'Build result'; status = 'in_progress'; runId = 4242 } | Out-Null
        Fake 'checks' @{ sha = $head; name = 'Acceptance'; status = 'completed'; conclusion = 'failure'; runId = 4242 } | Out-Null
        $r = Ma-Act @('rerun-failed', '--item', "$d", '--policy', 'flaky-check')
        CheckExit 'a run still in progress: refused, try later' $r 10 'run-in-progress'
        Fake 'checks' @{ sha = $head; name = 'Build result'; status = 'completed'; conclusion = 'success'; runId = 4242 } | Out-Null
        $before = (Get-FakeState).reruns
        $r = Ma-Act @('rerun-failed', '--item', "$d", '--policy', 'flaky-check')
        CheckExit 'rerun-failed' $r 0
        Check 'the failed jobs of that run are re-run, once' ((Get-FakeState).reruns -eq $before + 1 -and @($r.runs) -contains 4242 -and $r.sha -eq $head) ($r | ConvertTo-Json -Compress -Depth 4)
        $r = Ma-Act @('rerun-failed', '--item', "$d", '--policy', 'flaky-check')
        CheckExit 'the same head a second time is refused' $r 10 'already-rerun'
        Check 'the journal names the pull request and the head' (@(Ma-Journal $d 'manager-action' | Where-Object { $_.body -match "re-ran the failed jobs of PR #$dpr" -and $_.body -match 'policy `flaky-check`' }).Count -eq 1)
    } finally { Mgr-Stop $sup }
}

$ManagerActionScenarios['act: the supervisor drains and resumes a name, the operator''s drain wins, release-owner lets the owner go, restart-session ends the session through its end marker, and the hourly limit holds'] = {
    $n = New-Item-Fake 'Owned on the second gateway' 'x' @('factory worker', 'worker:ghost-act')
    $cfg = Msg-Config 'instance.act-c.json' { param($c) $c.messaging.allowedWorkers = @('alice', 'bob', 'carol'); $c.manager.actions = @{ perHour = 5; perItemPerDay = 3 } }
    Msg-OnGateway (Msg-Merge @{ FACTORY_CONFIG = $cfg; GITHUB_API_URL = "http://127.0.0.1:$($script:FakePort)" } @{}) {
        param($g)
        [void](Wait-Until -Seconds 60 { $null -ne (Msg-Admin '/api/v1/status').lastSweep })
        $sup = Mgr-Open
        $bob = Msg-Open 'name=bob&capacity=5&messaging=1' (Msg-Token 'bob'); Msg-Registered $bob
        $endFile = Join-Path $script:Work 'carol-session-ended'
        $carol = Msg-Client 'carol' 'act-c' '' @{ FACTORY_SESSION_END_FILE = $endFile }
        try {
            Check 'carol registers' (Msg-WaitEvent $carol 'worker.registered' 30) (Get-Content -Raw $carol.out)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{ "$n" = 'bob' }; owned = @{}; keep = @() })
            Msg-Read $bob 20 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' -and $_.data['item'] -eq $n }).Count -ge 1 }
            $ev = Msg-First @(Msg-Of $bob 'item.assigned' | Where-Object { $_.data['item'] -eq $n })
            $r = Msg-Json (Msg-Verb 'accept' "$($ev.data.token)" @{ item = $n })
            Check 'bob accepts the item' ($r.exit -eq 0 -and "$((Msg-Admin '/api/v1/status').plant.owners["$n"])" -eq 'bob') ($r | ConvertTo-Json -Compress)
            # the owner holds the item: the session that owns it is not restarted (a claim call of the same holder asks for a sweep, which reports the hold)
            $ghApi = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders"; $ghAuth = @{ Authorization = 'Bearer fake-operator' }
            Invoke-RestMethod "$ghApi/issues/$n/labels" -Method POST -Body '{"labels":["hold:owner"]}' -ContentType 'application/json' -Headers $ghAuth | Out-Null
            [void](Msg-Verb 'claim-item' 'test-token' @{ item = $n; holder = 'bob' })
            Check 'the sweep reports the held item' (Wait-Until -Seconds 30 { @((Msg-Admin '/api/v1/status').managerActions.ownerHeld) -contains $n })
            $r = Ma-Act @('restart-session', '--name', 'bob', '--policy', 'stalled-owner')
            CheckExit 'restart-session of a session that owns a held item is refused' $r 10 'owner-hold'
            Invoke-RestMethod "$ghApi/issues/$n/labels/hold%3Aowner" -Method DELETE -Headers $ghAuth | Out-Null
            [void](Msg-Verb 'claim-item' 'test-token' @{ item = $n; holder = 'bob' })
            Check 'and no longer once the hold is gone' (Wait-Until -Seconds 30 { @((Msg-Admin '/api/v1/status').managerActions.ownerHeld) -notcontains $n })
            # release-owner: the lease ends in the item, and the plant lets bob go at once
            $r = Ma-Act @('release-owner', '--item', "$n", '--policy', 'stalled-owner')
            CheckExit 'release-owner' $r 0
            Msg-Read $bob 15 { param($e) @($e | Where-Object { $_.data.event -eq 'item.taken_back' }).Count -ge 1 }
            Check 'bob is told item.taken_back and the plant no longer names him' (@(Msg-Of $bob 'item.taken_back' | Where-Object { $_.data['item'] -eq $n -and $_.data.reason -eq 'released-by-plant-manager' }).Count -eq 1 -and -not (Msg-Admin '/api/v1/status').plant.owners.ContainsKey("$n")) ((Msg-Admin '/api/v1/status').plant.owners | ConvertTo-Json -Compress)
            # drain and resume
            $r = Ma-Act @('drain', '--name', 'bob', '--policy', 'load-balance')
            Check 'the supervisor drains bob' ($r.exit -eq 0 -and $r.draining -eq $true -and (Ma-Worker 'bob').draining -eq $true) ($r | ConvertTo-Json -Compress)
            Msg-Close $bob
            $bob = Msg-Open 'name=bob&capacity=5&messaging=1' (Msg-Token 'bob'); Msg-Registered $bob
            Check 'the drain holds for the name''s next session' ((Ma-Worker 'bob').draining -eq $true)
            [void](Invoke-WebRequest (Msg-Url '/api/v1/workers/bob/resume') -Method POST -Headers @{ Authorization = "Bearer $(Msg-Token 'bob')" } -SkipHttpErrorCheck)
            Check 'the session cannot lift it itself' ((Ma-Worker 'bob').draining -eq $true)
            $r = Ma-Act @('resume', '--name', 'bob', '--policy', 'load-balance')
            Check 'the supervisor resumes bob' ($r.exit -eq 0 -and (Ma-Worker 'bob').draining -eq $false) ($r | ConvertTo-Json -Compress)
            [void](Invoke-WebRequest (Msg-Url '/api/v1/workers/bob/drain') -Method POST -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck)
            $r = Ma-Act @('resume', '--name', 'bob', '--policy', 'load-balance')
            CheckExit 'the operator''s drain wins: the supervisor cannot resume it' $r 10 'operator-drain'
            # restart-session: the stream client writes the launcher's end marker
            $r = Ma-Act @('restart-session', '--name', 'carol', '--policy', 'repeated-question', '--reason', 'asked the same question three times')
            CheckExit 'restart-session' $r 0
            Check 'carol''s client prints session.restart and writes the end marker' ((Msg-WaitEvent $carol 'session.restart' 20) -and (Test-Path $endFile) -and @(Msg-ClientEvents $carol | Where-Object { $_.event -eq 'session.restart' -and $_.markerWritten -eq $true }).Count -eq 1) (Get-Content -Raw $carol.out)
            # the hourly limit of this gateway is 5: release-owner, drain, resume and restart-session counted (the refused resume did not)
            $r = Ma-Act @('drain', '--name', 'carol', '--policy', 'load-balance')
            CheckExit 'the fifth action of the hour' $r 0
            $r = Ma-Act @('drain', '--name', 'bob', '--policy', 'load-balance')
            CheckExit 'the sixth is refused by the hourly limit' $r 20 'action-limit'
            Check 'with the time until one is free' ($r.retryAfterSeconds -gt 0) ($r | ConvertTo-Json -Compress)
            $s = (Msg-Admin '/api/v1/status').managerActions
            Check '/status counts the hour''s actions and lists the supervisor''s drains' ($s.lastHour -eq 5 -and $s.perHour -eq 5 -and @($s.drained) -contains 'carol') ($s | ConvertTo-Json -Compress)
            $r = Ma-Act @('resume', '--name', 'carol', '--policy', 'load-balance')
            CheckExit 'a resume is never held by the hourly limit, so a drain can always be lifted' $r 0
        } finally { Msg-Close $sup; Msg-Close $bob; Mgr-Stop $carol }
    }
}

$ManagerActionScenarios['act: the plan offers a top item before a high one before the rest, after the pins; the day''s summary is due once and metrics and act-log answer the supervisor only'] = {
    $a = New-Item-Fake 'Normal' 'x' @('factory worker', 'worker:ghost-act'); $b = New-Item-Fake 'High' 'x' @('factory worker', 'worker:ghost-act'); $c = New-Item-Fake 'Top' 'x' @('factory worker', 'worker:ghost-act')
    $cfg = Msg-Config 'instance.act-d.json' { param($x) $x.messaging.allowedWorkers = @('alice', 'bob', 'carol') }
    Msg-OnGateway (Msg-Merge @{ FACTORY_CONFIG = $cfg; FACTORY_TIMING_mgrSummaryHourUtc = '0' } @{}) {
        param($g)
        $days = @([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        $sup = Mgr-Open
        $alice = Msg-Open 'name=alice&capacity=1&messaging=1' (Msg-Token 'alice'); Msg-Registered $alice
        try {
            Msg-Read $sup 10 { param($e) @($e | Where-Object { $_.data.event -eq 'supervisor.summary-due' }).Count -ge 1 }
            $sd = @(Msg-Of $sup 'supervisor.summary-due')
            $days += [DateTime]::UtcNow.ToString('yyyy-MM-dd')
            Check 'the day''s summary is due, with the day and the count of actions' ($sd.Count -ge 1 -and "$($sd[0].data.day)" -in $days -and $null -ne $sd[0].data['actions']) ($sd | ConvertTo-Json -Compress -Depth 4)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $a; kind = 'own-item'; column = 'Technical Design' }, @{ item = $b; kind = 'own-item'; column = 'Technical Design' }, @{ item = $c; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @(); priorities = @{ "$b" = 'high'; "$c" = 'top' } })
            Msg-Read $alice 15 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' }).Count -ge 1 }
            $first = Msg-First @(Msg-Of $alice 'item.assigned')
            Check 'a session with one free slot is offered the top item first' ($first -and $first.data['item'] -eq $c) ($first | ConvertTo-Json -Compress -Depth 4)
            Msg-Read $sup 4
            Check 'the summary is not sent twice in a day' (@(Msg-Of $sup 'supervisor.summary-due' | Where-Object { "$($_.data.day)" -eq "$($sd[0].data.day)" }).Count -eq 1)
            $m = Mgr-F @('metrics', '--since', '24h')
            Check 'metrics answers the supervisor' ($m.exit -ne 30 -and (Pv $m 'code') -notin 'forbidden', 'not-supervisor') ($m | ConvertTo-Json -Compress -Depth 3)
            $w = Msg-Api 'GET' '/api/v1/metrics?since=24h' (Msg-Token 'alice')
            Check 'and is refused to a worker credential' ($w.StatusCode -eq 403) "$($w.StatusCode)"
            $l = Msg-Api 'GET' '/api/v1/manager/actions' (Msg-Token 'alice')
            Check 'act-log is refused to a worker credential' ($l.StatusCode -eq 403) "$($l.StatusCode)"
            $l = Mgr-F @('act-log')
            Check 'act-log answers the supervisor with the mode and the day of the last summary' ($l.exit -eq 0 -and $l.mode -eq 'act' -and "$($l.summarySent)" -in ($days + [DateTime]::UtcNow.ToString('yyyy-MM-dd'))) ($l | ConvertTo-Json -Compress)
            # the name limit: 3 drains or restarts of one name in 24 hours; a resume is not counted, so a drain can always be lifted
            foreach ($i in 1..3) {
                $r = Ma-Act @('drain', '--name', 'alice', '--policy', 'load-balance'); CheckExit "drain $i of alice" $r 0
                $r = Ma-Act @('resume', '--name', 'alice', '--policy', 'load-balance'); CheckExit "resume $i of alice" $r 0
            }
            $r = Ma-Act @('drain', '--name', 'alice', '--policy', 'load-balance')
            CheckExit 'the fourth drain of one name in a day is refused' $r 10 'name-action-limit'
            $mf = Msg-Api 'GET' '/api/v1/metrics?since=24h&fresh=1' (New-ManagerToken)
            Check 'the supervisor never forces a fresh computation of the metrics' ($mf.StatusCode -eq 400) "$($mf.StatusCode)"
        } finally { Msg-Close $sup; Msg-Close $alice }
    }
}
