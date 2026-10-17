# Tier 1 scenarios for the PR QC environment, slice S4 (merge gate, approval trigger, sweep teardown, gateway race). Design: docs/design/pr-qc-environment.md 3.5, 3.6, 8.
# Names start with "qc: gate"; run them alone with -Only "qc: gate". They reuse the helpers of qc.ps1 and owner.ps1.
#   $QcGateScenarios          peer-approved, owner mode, default timing: the merge gate, qc.approved, label change
#   $QcGateAutoScenarios      run inside the main QC suite (mergePolicy auto): the auto policy is unchanged
#   $QcGateIdleScenarios ... one gateway each, with short timing.* values (FACTORY_TIMING_* in run.ps1): idle, lifetime, stale grace, lease loss, qc-waiting
#   $QcGateRaceScenarios      one gateway with qc.testReconcileDelayMs: a qc-stopped between a sweep's read and the gateway acting on it

function Gate-Head([int]$pr) { Get-Head $pr }
# Starts a person's run through the admin verb (no link needed) and drives the scripted worker to the given step: 'accepted', 'building', 'running', 'ready'.
# Worker '' means whichever of qw1 and qw2 is offered the job.
function Gate-Run($x, [string]$Worker = 'qw1', [string]$Upto = 'ready') {
    $names = if ($Worker) { @($Worker) } else { @('qw1', 'qw2') }
    $before = @{}; foreach ($w in $names) { $before[$w] = (Qc-Events $w $x.n).Count }
    $r0 = F 'op' @('qc-request', '--item', $x.n, '--pr', $x.pr)
    Check "a QC run for PR $($x.pr) was started" ($r0.exit -in 0, 21) "exit $($r0.exit) $(Pv $r0 'code') $(Pv $r0 'reason')"
    $script:gateGot = ''
    [void](Wait-Until -Seconds 30 { foreach ($w in $names) { if ((Qc-Events $w $x.n).Count -gt $before[$w]) { $script:gateGot = $w; return $true } }; return $false })
    if (-not $script:gateGot) { Check 'a worker was offered the job' $false; return $x }
    $got = $script:gateGot
    $all = Qc-Events $got $x.n; $ev = $all[$all.Count - 1]
    $x.asg = $ev.assignment; $x.sha = $ev.sha; $x.env = $ev.env_id; $x.worker = $got
    return (Gate-Drive $x $got $Upto)
}
$script:gateGot = ''
# Accepts the offered job and reports progress up to the step.
function Gate-Drive($x, [string]$Worker, [string]$Upto = 'ready') {
    $a = Fo $Worker @('accept', '--item', $x.n, '--assignment', $x.asg, '--role', 'qc'); CheckExit "accept by $Worker" $a 0
    if ($Upto -eq 'accepted') { return $x }
    [void](Fo $Worker @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'building'))
    if ($Upto -eq 'building') { return $x }
    [void](Fo $Worker @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'running'))
    if ($Upto -eq 'running') { return $x }
    $r0 = Qc-Report $x "http://$(Qc-Fake)" 'ok' $Worker; CheckExit 'the environment is reported ready' $r0 0
    return $x
}
function Gate-Inspect($x) {
    $r0 = F 'w1' @('approve-pr', '--item', $x.n, '--pr', $x.pr, '--text-file', (TmpFile "gi$($x.n).md" (Insp-Text 'APPROVE'))); CheckExit "inspector approves PR $($x.pr)" $r0 0
}
function Gate-Merge($x) { F 'w1' @('merge', '--item', $x.n, '--pr', $x.pr) }
# A person in humanApprovers approves the given commit on GitHub.
function Gate-Human($x, [string]$Commit = '') { Gh-As 'fake-testperson' "pulls/$($x.pr)/reviews" @{ event = 'APPROVE'; commit_id = $(if ($Commit) { $Commit } else { Get-Head $x.pr }) } | Out-Null }
function Gate-ReviewHook($x, [string]$Action = 'submitted', [string]$State = 'approved') {
    $c = (Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable); $repo = @{ full_name = "$($c.owner)/$($c.repo)" }; $sha = Get-Head $x.pr
    $rv = @{ action = $Action; repository = $repo; review = @{ state = $State; commit_id = $sha; user = @{ login = 'factory-worker-testperson[bot]' } }; pull_request = @{ number = $x.pr; head = @{ ref = "factory-worker/$($x.n)-development"; sha = $sha } } }
    return (Qc-Hook 'pull_request_review' $rv)
}
# The owner's mailbox for an item (what Plant.Route delivers), as a list of events.
function Gate-Mailbox([int]$n) {
    $r0 = Invoke-RestMethod "$(Qc-Base)/api/v1/wait?item=$n&after=0&timeout=1" -Headers @{ Authorization = 'Bearer test-token' }
    return @($r0.events)
}
function Gate-MailCount([int]$n, [string]$Event) { return @(Gate-Mailbox $n | Where-Object { $_.event -eq $Event }).Count }
function Gate-TeardownCount([string]$Worker, [int]$pr) { return @(Get-WorkerEvents $Worker | Where-Object { $_.event -eq 'qc.teardown' -and $_.pr -eq $pr }).Count }
function Gate-LastSweep { "$((Invoke-RestMethod "$(Qc-Base)/api/v1/status" -Headers @{ Authorization = 'Bearer test-token' }).lastSweep)" }
# The worker confirms the stop it was told about and the record ends torn-down.
function Gate-Stop($x, [string]$Worker = 'qw1') {
    $s = Fo $Worker @('qc-stopped', '--item', $x.n, '--env-id', $x.env); CheckExit 'qc-stopped' $s 0
    Check 'the record is torn-down' ((Qc-RecState $x.n $x.pr) -eq 'torn-down') (Qc-RecState $x.n $x.pr)
}
# The reason the record gives for a teardown that was asked for ('' when none was).
function Gate-TdReason($x) { $r0 = Qc-Rec $x.n $x.pr; if ($r0 -and $r0.ContainsKey('teardown')) { return "$($r0.teardown.reason)" }; return '' }
function Gate-Journal([int]$n, [string]$Event, [string]$Text = '') { return @((Get-FakeIssue $n).comments | Where-Object { $_.body -match "plant event=$Event" -and ((-not $Text) -or $_.body -match $Text) }).Count }

$QcGateScenarios = [ordered]@{

'qc: gate a non-auto-merge PASS stays on the approval path; merge needs a QC run, then a person, then merges' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $st = Qc-State $x.n
    Check 'the PASS verdict is not parked for a person (peer-approved with the QC gate)' (-not ($st.ContainsKey('park') -and "$($st.park.reason)" -eq 'pass-without-auto-merge') -and -not $st.verdict.processed) ((Pv $st 'park') | ConvertTo-Json -Compress)
    $r0 = Gate-Merge $x; CheckExit 'merge before any approval' $r0 10 'approval-missing'
    Gate-Inspect $x
    $r0 = Gate-Merge $x; CheckExit 'inspector approved, no QC run: merge refused' $r0 10 'qc-not-run'
    Check 'the refusal tells the owner to wait for the event, not park' ("$(Pv $r0 'wait_for')" -eq 'qc.approved' -and "$($r0.reason)" -match 'do not park')
    $x = Gate-Run $x 'qw1' 'building'
    Check 'the run is recorded only when the environment reaches ready: not yet' (-not (Qc-Rec $x.n $x.pr).ContainsKey('ran_sha'))
    $r0 = Gate-Merge $x; CheckExit 'an environment that is only building does not count' $r0 10 'qc-not-run'
    $rep = Qc-Report $x "http://$(Qc-Fake)"; CheckExit 'ready' $rep 0
    $head = Get-Head $x.pr
    Check 'ready wrote qc.ran_sha = the head' ((Qc-Rec $x.n $x.pr).ran_sha -eq $head) "$((Qc-Rec $x.n $x.pr).ran_sha)"
    $r0 = Gate-Merge $x; CheckExit 'a run exists, no person has approved: merge refused' $r0 10 'qc-approval-missing'
    Gh-As 'fake-reviewer' "pulls/$($x.pr)/reviews" @{ event = 'APPROVE'; commit_id = $head } | Out-Null
    $r0 = Gate-Merge $x; CheckExit 'the inspector identity is not a person in humanApprovers' $r0 10 'qc-approval-missing'
    Gate-Human $x 'deadbeef'
    $r0 = Gate-Merge $x; CheckExit 'a person approving another commit does not count' $r0 10 'qc-approval-missing'
    Gate-Human $x
    $r0 = Gate-Merge $x; CheckExit 'a person approved the current head: merge' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
    $td = Wait-Until -Seconds 60 { @(Get-WorkerEvents 'qw1' | Where-Object { $_.event -eq 'qc.teardown' -and $_.pr -eq $x.pr }).Count -gt 0 }
    Check 'after the merge the sweep tells the worker to tear the environment down' $td
}

'qc: gate documentation-only items are exempt from the QC run but not from the approval [full]' = {
    Ensure-QcWorker
    $d = New-QcPr $QcLabels @('docs/a.md') $true
    Gate-Inspect $d
    $r0 = Gate-Merge $d; CheckExit 'docs-only: no qc-not-run, the missing approval is what stops it' $r0 10 'qc-approval-missing'
    Gate-Human $d
    $r0 = Gate-Merge $d; CheckExit 'docs-only with a person approval: merge' $r0 0
    Check 'merged without a QC environment' ((Pv $r0 'outcome') -eq 'merged' -and $null -eq (Qc-Rec $d.n $d.pr)) "$(Pv $r0 'outcome')"
}

'qc: gate Auto Merge items are unaffected under peer-approved [full]' = {
    Ensure-QcWorker
    $a = New-QcPr @('factory worker', 'Auto Merge')
    Gate-Inspect $a
    $r0 = Gate-Merge $a; CheckExit 'Auto Merge item: no QC run and no person needed' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
    Check 'and no record or offer was made for it' ($null -eq (Qc-Rec $a.n $a.pr) -and (Qc-OfferComments $a.pr).Count -eq 0)
}

'qc: gate a push to a new head needs a new QC run and a new approval [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    Gate-Inspect $x
    $x = Gate-Run $x 'qw1'
    Gate-Human $x
    $old = Get-Head $x.pr
    Check 'ready for the first head, a person approved it: the gate would pass' ((Qc-Rec $x.n $x.pr).ran_sha -eq $old)
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('src/a.cs', 'src/c.cs') } | Out-Null
    $new = Get-Head $x.pr
    Check 'the head moved' ($new -ne $old)
    $r0 = Gate-Merge $x; CheckExit 'new head: the inspector approval of the old head is gone' $r0 10 'approval-missing'
    $r0 = F 'w1' @('approve-pr', '--item', $x.n, '--pr', $x.pr, '--text-file', (TmpFile "gp$($x.n).md" (Insp-Text 'APPROVE'))); CheckExit 'the inspector may not approve a head that changed after validation' $r0 10 'escalation-required'
    $r0 = F 'w1' @('approve-pr', '--item', $x.n, '--pr', $x.pr, '--text-file', (TmpFile "ge$($x.n).md" (Insp-Text 'ESCALATE' 'The branch changed after validation.'))); CheckExit 'the inspector escalates' $r0 0
    $r0 = Gate-Merge $x; CheckExit 'held: the old approval of the person does not release it' $r0 10 'held'
    Gate-Human $x
    $cleared = Wait-Until -Seconds 40 { -not ((Get-FakeIssue $x.n).labels -contains 'Needs Human Review') }
    Check 'the person''s approval of the NEW head released the hold' $cleared
    $r0 = Gate-Merge $x; CheckExit 'approved, but the run belongs to the old head: it does not count' $r0 10 'qc-not-run'
    Check 'the record still names the old run' ((Qc-Rec $x.n $x.pr).ran_sha -eq $old)
    $x = Gate-Run $x 'qw1'
    Check 'a run for the new head carries the new ran_sha' ((Qc-Rec $x.n $x.pr).ran_sha -eq $new -and (Qc-Rec $x.n $x.pr).sha -eq $new)
    $r0 = Gate-Merge $x; CheckExit 'new run and the approval of the new head: merge' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
}

'qc: gate a reset keeps the record of the run for the same head [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Gate-Run $x 'qw1'
    $r0 = F 'op' @('qc-reset', '--item', $x.n, '--pr', $x.pr); CheckExit 'reset' $r0 0
    Check 'the new attempt carries ran_sha over (an environment for this head did reach ready)' ((Qc-Rec $x.n $x.pr).ran_sha -eq (Get-Head $x.pr) -and (Qc-Rec $x.n $x.pr).attempt -eq 2) "$((Qc-Rec $x.n $x.pr) | ConvertTo-Json -Compress -Depth 4)"
}

'qc: gate a person''s approval wakes the owner with qc.approved (webhook and sweep), a dismissal clears it, and the retried merge succeeds [full]' = {
    Ensure-QcWorker
    # webhook path
    $x = New-QcOffered
    Gate-Inspect $x
    $r0 = Gate-Merge $x; CheckExit 'owner asks to merge: no run yet' $r0 10 'qc-not-run'
    $x = Gate-Run $x 'qw1'
    $r0 = Gate-Merge $x; CheckExit 'owner retries: the run exists, nobody approved' $r0 10 'qc-approval-missing'
    Check 'no qc.approved yet' ((Gate-MailCount $x.n 'qc.approved') -eq 0)
    Gate-Human $x
    Check 'the review webhook is accepted' ((Gate-ReviewHook $x) -eq 202)
    $got = Wait-Until -Seconds 30 { (Gate-MailCount $x.n 'qc.approved') -ge 1 }
    Check 'the owner mailbox got qc.approved' $got
    $ev = @(Gate-Mailbox $x.n | Where-Object { $_.event -eq 'qc.approved' })[0]
    Check 'the event names the PR, the head and the approver, and no URL' ($ev -and $ev.pr -eq $x.pr -and $ev.sha -eq (Get-Head $x.pr) -and $ev.by -eq 'factory-worker-testperson[bot]' -and $ev.ran -eq $true -and (($ev | ConvertTo-Json -Compress) -notmatch 'http')) ($ev | ConvertTo-Json -Compress)
    $rec = Qc-Rec $x.n $x.pr
    Check 'the approval is kept in the QC record (a persisted transition)' ($rec.approved.by -eq 'factory-worker-testperson[bot]' -and $rec.approved.sha -eq (Get-Head $x.pr)) ($rec.approved | ConvertTo-Json -Compress)
    # a dismissal clears it
    Fake 'review-state' @{ number = $x.pr; user = 'factory-worker-testperson[bot]'; state = 'DISMISSED' } | Out-Null
    Check 'the dismissal webhook is accepted' ((Gate-ReviewHook $x 'dismissed' 'dismissed') -eq 202)
    $cleared = Wait-Until -Seconds 30 { -not (Qc-Rec $x.n $x.pr).ContainsKey('approved') }
    Check 'the dismissed review clears qc.approved from the record' $cleared
    $r0 = Gate-Merge $x; CheckExit 'merge is refused again after the dismissal' $r0 10 'qc-approval-missing'
    # approve again: the owner is woken again, and the retry merges
    Gate-Human $x
    Check 'the second review webhook is accepted' ((Gate-ReviewHook $x) -eq 202)
    $again = Wait-Until -Seconds 30 { (Gate-MailCount $x.n 'qc.approved') -ge 2 }
    Check 'a new approval after a dismissal wakes the owner again' $again
    $r0 = Gate-Merge $x; CheckExit 'the retried merge succeeds' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
    # sweep path: no webhook at all
    $y = New-QcOffered
    Gate-Inspect $y
    Gate-Human $y
    $none = Gate-MailCount $y.n 'qc.approved'
    $sweepSaw = Wait-Until -Seconds 40 { (Gate-MailCount $y.n 'qc.approved') -ge 1 }
    Check 'the sweep alone sees the approval and wakes the owner (even before the QC run)' ($none -eq 0 -and $sweepSaw)
    $r0 = Gate-Merge $y; CheckExit 'approved but not run: merge refused qc-not-run' $r0 10 'qc-not-run'
    $y = Gate-Run $y 'qw1'
    $runSeen = Wait-Until -Seconds 40 { @(Gate-Mailbox $y.n | Where-Object { $_.event -eq 'qc.approved' -and $_.ran -eq $true }).Count -ge 1 }
    Check 'when the QC run completes after the approval the owner is woken again (ran = true)' $runSeen
    $r0 = Gate-Merge $y; CheckExit 'the retried merge succeeds' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
}

'qc: gate the requirements can be switched off in the configuration [full]' = {
    $c = Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable
    $x = New-QcPr
    Gate-Inspect $x
    $cfg = Join-Path $script:Work 'cfg-gate.json'
    $c.qc.requireRun = $false; $c | ConvertTo-Json -Depth 12 | Set-Content $cfg
    $r0 = Qc-Server 'merge' @{ item = $x.n; pr = $x.pr } @{ FACTORY_CONFIG = $cfg }
    CheckExit 'requireRun false: the missing person approval stops it, not the missing run' $r0 10 'qc-approval-missing'
    $c.qc.requireApproval = $false; $c | ConvertTo-Json -Depth 12 | Set-Content $cfg
    $r0 = Qc-Server 'merge' @{ item = $x.n; pr = $x.pr } @{ FACTORY_CONFIG = $cfg }
    CheckExit 'both off: the gate is off and the label is required again, as before S4' $r0 10 'no-auto-merge-label'
    $y = New-QcPr
    Gate-Inspect $y
    $c.qc.requireRun = $true; $c.qc.requireApproval = $false; $c | ConvertTo-Json -Depth 12 | Set-Content $cfg
    $r0 = Qc-Server 'merge' @{ item = $y.n; pr = $y.pr } @{ FACTORY_CONFIG = $cfg }
    CheckExit 'requireRun true, requireApproval false: the run is what is missing' $r0 10 'qc-not-run'
}

'qc: gate a sweep that is still writing the QC offer does not undo an approval recorded meanwhile [full]' = {
    # the flaky check of the hosted runners, made certain: the sweep read the item's state, GitHub is slow while it posts the two offer comments,
    # and the inspector's approval is recorded in between. The sweep must not save what it read before.
    $x = $null
    try {
        Fake 'latency' @{ ms = 12000; match = '(?s)^POST /repos/[^\n]+/issues/\d+/comments\n.*qc link pr=' } | Out-Null
        $x = New-QcPr
        $inside = Wait-Until -Seconds 90 { (Qc-OfferComments $x.pr).Count -gt 0 -and (Qc-ItemOffer $x.n).Count -eq 0 }
        Check 'the sweep is between its two offer comments (it read the state before the approval)' $inside
        Gate-Inspect $x
        $posted = Wait-Until -Seconds 90 { (Qc-ItemOffer $x.n).Count -gt 0 }
    } finally { Fake 'latency' @{ ms = 0 } | Out-Null }
    $key = "qc-offered|$($x.pr)|$(Get-Head $x.pr)"
    $saved = Wait-Until -Seconds 60 { $s0 = Qc-State $x.n; $s0 -and $s0.ContainsKey('journal') -and (@($s0.journal.keys) -contains $key) }
    Check 'the sweep finished the offer and recorded its journal line in the state' ($posted -and $saved)
    $s0 = Qc-State $x.n
    Check 'the approval recorded during the sweep is still in the state' ($s0.ContainsKey('approval') -and "$($s0.approval.sha)" -eq (Get-Head $x.pr)) ($s0 | ConvertTo-Json -Depth 4 -Compress)
    $r0 = Gate-Merge $x; CheckExit 'merge is refused for the missing QC run, not for a missing approval' $r0 10 'qc-not-run'
}

'qc: gate an Auto Merge label added to an item with a live environment tears the environment down [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Gate-Run $x 'qw1'
    Gh-As 'fake-operator' "issues/$($x.n)/labels" @{ labels = @('Auto Merge') } | Out-Null
    $td = Wait-Until -Seconds 60 { (Gate-TeardownCount 'qw1' $x.pr) -gt 0 }
    Check 'the worker is told to tear the environment down' $td
    Check 'the record names the reason label-changed' ((Gate-TdReason $x) -eq 'label-changed') (Gate-TdReason $x)
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); Check 'the heartbeat is answered teardown' ($hb.action -eq 'teardown') "$($hb.action)"
    Gate-Stop $x
    Check 'journal: qc-torn-down (label-changed)' ((Gate-Journal $x.n 'qc-torn-down' 'label-changed') -eq 1)
    Qc-Sweeps 2
    Check 'the offer is withdrawn: no new environment and no new job' ((Qc-QcAssignments $x.n).Count -eq 0)
    Gate-Inspect $x
    $r0 = Gate-Merge $x; CheckExit 'the item is an Auto Merge item now: merge needs neither run nor person' $r0 0
    Check 'merged' ((Pv $r0 'outcome') -eq 'merged') "$(Pv $r0 'outcome') $(Pv $r0 'reason')"
}

}

# Run inside the main QC suite (mergePolicy auto).
$QcGateAutoScenarios = [ordered]@{

'qc: gate under the auto policy nothing changed: the label is required and QC is not a gate [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $r0 = F 'w1' @('merge', '--item', $x.n, '--pr', $x.pr)
    Check 'no label: merge is refused as before (the PASS was parked for a person)' ($r0.exit -eq 10 -and ("$($r0.code)" -in 'no-auto-merge-label', 'no-pass-verdict')) "$($r0.exit) $($r0.code)"
    $st = Qc-State $x.n
    Check 'the verdict was parked for a person as before' ($st.verdict.processed -and "$($st.park.reason)" -eq 'pass-without-auto-merge') ($st.park | ConvertTo-Json -Compress)
    $a = New-QcPr @('factory worker', 'Auto Merge')
    $m = F 'w1' @('merge', '--item', $a.n, '--pr', $a.pr); CheckExit 'an Auto Merge item merges without QC' $m 0
    Check 'merged (by the gateway at the verdict; the session''s merge confirms it)' ((Pv $m 'outcome') -in 'merged', 'already-merged' -and (Get-FakePr $a.pr).merged) "$(Pv $m 'outcome')"
}

}

# ---- one gateway each, short timing.* values ------------------------------------------------------------------------------------------
$QcGateIdleScenarios = [ordered]@{

'qc: gate an idle environment is torn down after timing.qcIdleMinutes, and a touch restarts the idle timer [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Gate-Run $x 'qw1'
    $t0 = Get-Date
    Start-Sleep -Seconds 3
    $go = Qc-Get $x.pr $x.tok '/go'; Check 'opening the environment (/go) touches it' ($go.status -eq 302) "$($go.status)"
    $tTouch = ((Get-Date) - $t0).TotalSeconds
    Start-Sleep -Seconds 3
    Check 'a touch younger than the idle limit keeps the environment (no teardown yet)' ((Gate-TeardownCount 'qw1' $x.pr) -eq 0 -and (Qc-RecState $x.n $x.pr) -eq 'ready')
    $td = Wait-Until -Seconds 40 { (Gate-TeardownCount 'qw1' $x.pr) -gt 0 }
    $since = ((Get-Date) - $t0).TotalSeconds - $tTouch
    Check 'the worker is told to tear the idle environment down' $td
    Check "only after the idle limit since the touch (waited $([Math]::Round($since,1)) s of 6)" ($since -ge 5.5) "$since"
    Check 'the record names the reason idle' ((Gate-TdReason $x) -eq 'idle') (Gate-TdReason $x)
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); Check 'the heartbeat is answered teardown' ($hb.action -eq 'teardown') "$($hb.action)"
    Gate-Stop $x
    Check 'journal: qc-torn-down (idle)' ((Gate-Journal $x.n 'qc-torn-down' 'idle') -eq 1)
    Check 'the plant holds no QC assignment for it' ((Qc-QcAssignments $x.n).Count -eq 0)
    Qc-Sweeps 3
    Check 'teardown only stops: no new job, no new record' ((Qc-QcAssignments $x.n).Count -eq 0 -and (Qc-Rec $x.n $x.pr).attempt -eq 1 -and (Gate-Journal $x.n 'qc-requested') -eq 1)
}

}

$QcGateLifetimeScenarios = [ordered]@{

'qc: gate an environment is torn down at the lifetime cap even when it is in use [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Gate-Run $x 'qw1'
    $t0 = Get-Date
    $td = Wait-Until -Seconds 60 { [void](Qc-Get $x.pr $x.tok '/go'); (Gate-TeardownCount 'qw1' $x.pr) -gt 0 }
    $at = ((Get-Date) - $t0).TotalSeconds
    Check 'the worker is told to tear it down although somebody keeps opening it' $td
    Check "not before the cap (after $([Math]::Round($at,1)) s of 6)" ($at -ge 4) "$at"
    Check 'the record names the reason lifetime' ((Gate-TdReason $x) -eq 'lifetime') (Gate-TdReason $x)
    Gate-Stop $x
    Check 'journal: qc-torn-down (lifetime)' ((Gate-Journal $x.n 'qc-torn-down' 'lifetime') -eq 1)
}

}

$QcGateGraceScenarios = [ordered]@{

'qc: gate a stale environment is torn down after timing.qcGraceMinutes unless a Reset comes first [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Gate-Run $x 'qw1'
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('src/a.cs', 'src/c.cs') } | Out-Null
    $stale = Wait-Until -Seconds 40 { (Qc-RecState $x.n $x.pr) -eq 'stale' }
    Check 'the record is marked stale' $stale
    $t0 = Get-Date
    Check 'no teardown while the grace runs' ((Gate-TeardownCount 'qw1' $x.pr) -eq 0)
    $td = Wait-Until -Seconds 60 { (Gate-TeardownCount 'qw1' $x.pr) -gt 0 }
    Check 'the worker is told to tear it down once the grace is over' $td
    Check 'the record names the reason head-changed' ((Gate-TdReason $x) -eq 'head-changed') (Gate-TdReason $x)
    Gate-Stop $x
    Check 'journal: qc-torn-down (head-changed)' ((Gate-Journal $x.n 'qc-torn-down' 'head-changed') -eq 1)
    Qc-Sweeps 2
    Check 'nothing was started for the new head' ((Qc-QcAssignments $x.n).Count -eq 0 -and (Gate-Journal $x.n 'qc-requested') -eq 1)
    # a Reset before the grace ends keeps the person's environment
    $y = New-QcOffered
    $y = Gate-Run $y 'qw1'
    Fake 'push-branch' @{ branch = "factory-worker/$($y.n)-development"; files = @('src/a.cs', 'src/d.cs') } | Out-Null
    [void](Wait-Until -Seconds 40 { (Qc-RecState $y.n $y.pr) -eq 'stale' })
    $r0 = F 'op' @('qc-reset', '--item', $y.n, '--pr', $y.pr); CheckExit 'the person presses Reset on the stale environment' $r0 0
    Start-Sleep -Seconds 20   # past the grace (15 s, longer than one slow verb so the Reset can land inside it)
    Check 'after the grace the reset environment was not torn down' ((Gate-TeardownCount 'qw1' $y.pr) -eq 0 -and (Qc-RecState $y.n $y.pr) -ne 'torn-down' -and -not (Qc-Rec $y.n $y.pr).ContainsKey('teardown')) "$(Qc-RecState $y.n $y.pr)"
}

}

$QcGateLeaseScenarios = [ordered]@{

'qc: gate a lost lease relaunches the environment on another worker, up to timing.qcMaxRelaunches, then fails no-worker [full]' = {
    Ensure-QcWorker
    Ensure-QcWorker 'qw2'
    [void](Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw2/resume" -Method POST -Headers @{ Authorization = 'Bearer test-token' })
    $x = New-QcOffered
    $x = Gate-Run $x '' 'ready'
    $w1 = $x.worker; $w2 = $(if ($w1 -eq 'qw1') { 'qw2' } else { 'qw1' }); $asg1 = $x.asg
    Check 'ready on the first worker' ((Qc-RecState $x.n $x.pr) -eq 'ready')
    # no heartbeat: the lease (18 s, three times the slowest verb seen on hosted runners, so it never lapses between two verbs of one step) runs out
    $moved = Wait-Until -Seconds 60 { $r0 = Qc-Rec $x.n $x.pr; $r0 -and "$($r0.state)" -eq 'assigned' -and $r0.ContainsKey('relaunches') -and "$($r0.assignment)" -ne '' -and "$($r0.assignment)" -ne $asg1 }
    Check 'the record went back to assigned with a new assignment (relaunch 1)' $moved ((Qc-Rec $x.n $x.pr) | ConvertTo-Json -Compress -Depth 4)
    $rec = Qc-Rec $x.n $x.pr
    Check 'it is on the other worker, mode relaunch, relaunches = 1' ($rec.worker -eq $w2 -and $rec.relaunches -eq 1 -and $rec.mode -eq 'relaunch') "$($rec.worker) $($rec.relaunches) $($rec.mode)"
    $evs = Qc-Events $w2 $x.n
    Check 'the other worker was offered a qc-env job with mode relaunch and a new assignment' ($evs.Count -ge 1 -and $evs[$evs.Count - 1].mode -eq 'relaunch' -and $evs[$evs.Count - 1].assignment -ne $asg1) (($evs | ConvertTo-Json -Compress -Depth 3))
    Check 'the lost worker was told to stop what it still runs' ((Gate-TeardownCount $w1 $x.pr) -ge 1)
    $hb = Fo $w1 @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); CheckExit 'the lost worker coming back finds a stale assignment' $hb 11 'stale-assignment'
    $x.asg = $evs[$evs.Count - 1].assignment; $x.worker = $w2
    $x = Gate-Drive $x $w2 'ready'
    Check 'the relaunched environment became ready on the second worker' ((Qc-RecState $x.n $x.pr) -eq 'ready' -and (Qc-Rec $x.n $x.pr).worker -eq $w2)
    Check 'the run record survived the relaunch' ((Qc-Rec $x.n $x.pr).ran_sha -eq (Get-Head $x.pr))
    # lost again: relaunch 2 goes to the first worker again (the lost one is excluded only for that assignment)
    $n2 = (Qc-Events $w1 $x.n).Count
    $moved = Wait-Until -Seconds 60 { (Qc-Events $w1 $x.n).Count -gt $n2 }
    Check 'relaunch 2: the first worker is offered the job' $moved
    $evs = Qc-Events $w1 $x.n; $x.asg = $evs[$evs.Count - 1].assignment; $x.worker = $w1
    Check 'relaunches = 2' ((Qc-Rec $x.n $x.pr).relaunches -eq 2) "$((Qc-Rec $x.n $x.pr).relaunches)"
    $a = Fo $w1 @('accept', '--item', $x.n, '--assignment', $x.asg, '--role', 'qc'); CheckExit 'accepted, then silence' $a 0
    # lost a third time: the budget (2) is spent
    $failed = Wait-Until -Seconds 60 { (Qc-RecState $x.n $x.pr) -eq 'failed' }
    Check 'after the budget the record is failed' $failed (Qc-RecState $x.n $x.pr)
    Check 'with the code no-worker' ((Qc-Rec $x.n $x.pr).fail.code -eq 'no-worker') "$((Qc-Rec $x.n $x.pr).fail | ConvertTo-Json -Compress)"
    # (the record is written by the rule script; the plant lets its assignment go when that call has returned)
    Check 'the plant holds no QC assignment for it' (Wait-Until -Seconds 30 { (Qc-QcAssignments $x.n).Count -eq 0 })
    Check 'journal: qc-failed once' ((Gate-Journal $x.n 'qc-failed' 'no-worker') -eq 1)
    Check 'the owner mailbox got qc.failed' ((Gate-MailCount $x.n 'qc.failed') -ge 1)
    Qc-Sweeps 2
    Check 'nothing started again by itself' ((Qc-QcAssignments $x.n).Count -eq 0 -and (Qc-RecState $x.n $x.pr) -eq 'failed')
}

}

$QcGateWaitingScenarios = [ordered]@{

'qc: gate a Start that finds no worker journals qc-waiting after the delay and then once per repeat interval [full]' = {
    $x = New-QcOffered
    $r0 = F 'op' @('qc-request', '--item', $x.n, '--pr', $x.pr); CheckExit 'Start finds no qualified worker' $r0 21 'waiting-for-worker'
    $t0 = Get-Date
    Check 'nothing is journaled at once (the delay is 3 s)' ((Gate-Journal $x.n 'qc-waiting') -eq 0)
    $first = Wait-Until -Seconds 30 { (Gate-Journal $x.n 'qc-waiting') -ge 1 }
    $t1 = ((Get-Date) - $t0).TotalSeconds
    Check "the first qc-waiting comes after the delay (at $([Math]::Round($t1,1)) s)" ($first -and $t1 -ge 2.0) "$t1"
    Start-Sleep -Seconds 4
    Check 'no second one inside the repeat interval (9 s)' ((Gate-Journal $x.n 'qc-waiting') -eq 1)
    $second = Wait-Until -Seconds 30 { (Gate-Journal $x.n 'qc-waiting') -ge 2 }
    $t2 = ((Get-Date) - $t0).TotalSeconds
    Check "the second comes once the interval has passed (at $([Math]::Round($t2,1)) s, $([Math]::Round($t2 - $t1,1)) s after the first)" ($second -and ($t2 - $t1) -ge 6.5) "$t1 $t2"
    $wl = @((Get-FakeIssue $x.n).comments | Where-Object { $_.body -match 'plant event=qc-waiting' })[0].body
    Check 'the comment says why: no qualified worker' ($wl -match 'no worker session is subscribed|qc role') $wl
    Start-Sleep -Seconds 3
    Check 'and no third one yet' ((Gate-Journal $x.n 'qc-waiting') -eq 2)
    Ensure-QcWorker
    $placed = Wait-Until -Seconds 30 { (Qc-Events 'qw1' $x.n).Count -gt 0 }
    Check 'a qualified worker connects: the earlier Start is served' $placed
    $n = Gate-Journal $x.n 'qc-waiting'
    Start-Sleep -Seconds 12
    Check 'nothing more is journaled once it is served' ((Gate-Journal $x.n 'qc-waiting') -eq $n)
}

}

$QcGateRaceScenarios = [ordered]@{

'qc: gate a teardown racing a sweep never brings the assignment back and capacity is freed (repeated) [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $runs = 4
    for ($i = 1; $i -le $runs; $i++) {
        $x = Gate-Run $x 'qw1'
        Check "round ${i}: ready, one QC assignment held" ((Qc-RecState $x.n $x.pr) -eq 'ready' -and (Qc-QcAssignments $x.n).Count -eq 1)
        # two sweeps complete after ready: the second one read the record after it was ready, and now sits in the (lengthened) gap before the gateway acts on it
        $base = Gate-LastSweep; $seen = 0; $end = (Get-Date).AddSeconds(90)
        while ($seen -lt 2 -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 80; $cur = Gate-LastSweep; if ($cur -ne $base) { $seen++; $base = $cur } }
        $s = Fo 'qw1' @('qc-stopped', '--item', $x.n, '--env-id', $x.env); CheckExit "round ${i}: qc-stopped lands inside the sweep's gap" $s 0
        Start-Sleep -Seconds 5
        Check "round ${i}: the record stays torn-down" ((Qc-RecState $x.n $x.pr) -eq 'torn-down') (Qc-RecState $x.n $x.pr)
        Check "round ${i}: the plant holds no QC assignment for it (not restored from the sweep's older read)" ((Qc-QcAssignments $x.n).Count -eq 0) ((Qc-QcAssignments $x.n) | ConvertTo-Json -Compress)
        $w = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'qw1' })[0]
        Check "round ${i}: the worker's QC capacity is free" ($w.qcActive -eq 0) "qcActive $($w.qcActive)"
    }
    $x = Gate-Run $x 'qw1'
    Check 'a further run is placed and ready' ((Qc-RecState $x.n $x.pr) -eq 'ready')
}

}
