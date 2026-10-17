# The standing back-merge trigger (docs/design/plant-manager.md 6a): when master moves, the owners of items with an open branch get base.updated;
# a clean branch that is only behind is updated by the gateway after a delay. Runs in the owner suite (messaging off: base.updated is a plant
# trigger like item.assigned, not a message). The suite sets baseUpdate.autoUpdateDelaySeconds 6, quietSeconds 3, sweepCheckSeconds 3 and
# timing.baseUpdateDebounceSeconds 4 (run.ps1).

function Bu-Worker([string]$Name) {
    if (-not $script:Workers.ContainsKey($Name) -or $script:Workers[$Name].proc.HasExited) { Start-OwnerClient $Name 'persistent-local' '--capacity 20' }
}
# An item owned by $W with an open pull request of $Files, in Development.
function Bu-OwnedPr([string]$W, [string[]]$Files) {
    $n = New-Item-Fake "Back-merge $W" 'x' ($OwnerLabels + "worker:$W")
    [void](Wait-Until -Seconds 40 { (Get-Assigned $W $n).Count -gt 0 })
    $ev = (Get-Assigned $W $n)[0]
    $r = Fo $W @('accept', '--item', $n, '--assignment', $ev.assignment); CheckExit "accept $n" $r 0
    $r = Fo $W @('append-body', '--item', $n, '--column', 'Technical Design', '--content-file', (TmpFile "butd$n.md" "## Technical Design`n`n- change as described.`n")); CheckExit "append $n" $r 0
    $r = Fo $W @('record-review', '--item', $n, '--column', 'Technical Design', '--role', 'reviewer', '--text-file', (TmpFile "burv$n.md" "ok`nREVIEW: COMPLETE")); CheckExit "review $n" $r 0
    $c = Fo $W @('complete', '--item', $n, '--column', 'Technical Design', '--review-ref', $r.review_ref, '--comment', 'REVIEW: COMPLETE - design done'); CheckExit "complete TD $n" $c 0
    $br = "factory-worker/$n-backmerge"
    Fake 'push-branch' @{ branch = $br; files = $Files } | Out-Null
    $o = Fo $W @('open-pr', '--item', $n, '--head', $br, '--title', "Back-merge $n", '--body-file', (TmpFile "bupr$n.md" 'change')); CheckExit "open-pr $n" $o 0
    return @{ item = $n; pr = [int]$o.pullRequest.number; branch = $br }
}
function Bu-Status { (Get-Plant).baseUpdate }
# the gateway has seen the current head of master (its first look, or the last trigger): a merge after this is a change
function Bu-Synced { [void](Wait-Until -Seconds 30 -Message 'the gateway to see the head of master' { (Bu-Status).head -eq (Get-FakeState).masterSha }) }
function Bu-Events([string]$W, [int]$Item) { , @(Get-WorkerEvents $W | Where-Object { $_.event -eq 'base.updated' -and $_.item -eq $Item }) }
function Bu-MergeHook([int]$Pr, [string]$Ref, [string]$Sha) {
    Qc-Hook 'pull_request' @{ action = 'closed'; repository = @{ full_name = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' }; sender = @{ login = 'a-person' }
        pull_request = @{ number = $Pr; merged = $true; merge_commit_sha = $Sha; base = @{ ref = 'master' }; head = @{ ref = $Ref; sha = 'f' * 40; repo = @{ full_name = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' } } } }
}
function Bu-Journal([int]$n, [string]$Event) { @((Get-FakeIssue $n).comments | Where-Object { $_.body -match "<!-- plant event=$Event " }).Count -gt 0 }
function Bu-Puts([int]$Pr) { @((Fake 'log') | Where-Object { $_ -match "^PUT /repos/[^ ]+/pulls/$Pr/update-branch$" }).Count }

# A PASS verdict written into the item's state comment, under the item lock the rule scripts take (as a verdict verb would): a journal line that
# read the state before this edit would otherwise save it back over the verdict (the runner gate runs journal lines last, so one can come late).
function Bu-SetVerdict([int]$Item, [int]$Pr, [switch]$NoHead) {
    $lock = $null; $end = (Get-Date).AddSeconds(45)
    while ($true) {
        try { $lock = [IO.File]::Open((Join-Path $env:FACTORY_STATE_DIR "item-$Item.lock"), 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch { if ((Get-Date) -gt $end) { throw }; Start-Sleep -Milliseconds 200 }
    }
    try {
        $sc = @((Get-FakeIssue $Item).comments | Where-Object { $_.body -like '<!-- factory-state:*' })[0]
        $mm = [regex]::Match($sc.body, '(?s)```json\s*(.*?)\s*```'); $st = $mm.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $st.verdict = @{ passed = $true; processed = $false; pr = $Pr }; if (-not $NoHead) { $st.verdict.head_sha = (Get-FakePr $Pr).sha }
        $body = $sc.body.Substring(0, $mm.Groups[1].Index) + ($st | ConvertTo-Json -Depth 12 -Compress) + $sc.body.Substring($mm.Groups[1].Index + $mm.Groups[1].Length)
        [void](Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/comments/$($sc.id)" -Method PATCH -Body (@{ body = $body } | ConvertTo-Json) -ContentType 'application/json')
    } finally { $lock.Dispose() }
}

$BaseUpdateScenarios = [ordered]@{

'base update: a verdict recorded between the trigger and the delayed update stops the gateway''s update [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/verdict.md')
    Bu-Synced
    [void](Fake 'master-merge' @{ files = @('docs/v.md') })
    Check 'the owner is told' (Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 })
    Bu-SetVerdict $a.item $a.pr
    Start-Sleep -Seconds 14
    Check 'the gateway does not update the branch' ((Bu-Puts $a.pr) -eq 0)
}

'base update: a merge to master tells the other owners of open branches with the overlapping files, not the merged pull request''s own worker' = {
    Bu-Worker 'bm1'; Bu-Worker 'bm2'; Bu-Worker 'bm3'
    $a = Bu-OwnedPr 'bm1' @('docs/a.md', 'src/Shared.cs'); $b = Bu-OwnedPr 'bm2' @('docs/b.md'); $c = Bu-OwnedPr 'bm3' @('src/Shared.cs', 'docs/c.md')
    Bu-Synced
    $before = Bu-Status
    $m = Fake 'master-merge' @{ number = $c.pr }
    Check 'the merge webhook is accepted' ((Bu-MergeHook $c.pr $c.branch $m.sha) -eq 202)
    $got = Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 -and (Bu-Events 'bm2' $b.item).Count -gt 0 }
    Check 'both other owners got base.updated' $got
    $ea = (Bu-Events 'bm1' $a.item)[0]; $eb = (Bu-Events 'bm2' $b.item)[0]
    Check 'the event names the new master, the merged pull request, the item''s pull request and how far it is behind' ($ea.sha -eq $m.sha -and @($ea.prs) -contains $c.pr -and $ea.pr -eq $a.pr -and $ea.behind -ge 1 -and $ea.base -eq 'master') ($ea | ConvertTo-Json -Compress)
    Check 'the files changed on both sides are listed' (@($ea.overlap) -contains 'src/Shared.cs' -and @($ea.overlap).Count -eq 1) ($ea.overlap -join ',')
    Check 'no overlap for a pull request that shares no file' (@($eb.overlap).Count -eq 0) ($eb.overlap -join ',')
    Start-Sleep -Seconds 2
    Check 'the worker whose pull request was merged gets none' ((Bu-Events 'bm3' $c.item).Count -eq 0)
    $w = Fo 'bm1' @('wait-event', '--item', $a.item, '--after', '0', '--timeout', '2')
    Check 'wait-event sees it too (messaging is off in this suite)' (@($w.events | Where-Object { $_.event -eq 'base.updated' }).Count -eq 1) ($w | ConvertTo-Json -Compress -Depth 5)
    Check 'journal: base-updated on the item' (Wait-Until -Seconds 20 { Bu-Journal $a.item 'base-updated' })
    $after = Bu-Status
    Check '/status counts the trigger and the events' ($after.triggers -eq $before.triggers + 1 -and $after.eventsSent -ge $before.eventsSent + 2) ($after | ConvertTo-Json -Compress)
}

'base update: three merges in a burst give one trigger with the latest master [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/burst.md')
    Bu-Synced
    $before = Bu-Status; $prs = @()
    foreach ($k in 1..3) { $m = Fake 'master-merge' @{ files = @("docs/other$k.md") }; $prs += $m.number; [void](Bu-MergeHook $m.number $m.ref $m.sha); Start-Sleep -Milliseconds 500 }
    [void](Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 })
    Start-Sleep -Seconds 8
    $ev = Bu-Events 'bm1' $a.item
    Check 'one base.updated for the burst' ($ev.Count -eq 1) "$($ev.Count)"
    Check 'it carries the latest master and all three pull requests' ($ev[0].sha -eq $m.sha -and @($ev[0].prs).Count -eq 3 -and $ev[0].behind -eq 3) ($ev[0] | ConvertTo-Json -Compress)
    Check 'one trigger counted' ((Bu-Status).triggers -eq $before.triggers + 1)
}

'base update: without the webhook the sweep sees master move and triggers [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/sweep.md')
    Bu-Synced
    $m = Fake 'master-merge' @{ files = @('docs/elsewhere.md') }
    $got = Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 }
    Check 'base.updated arrives from the sweep' ($got -and (Bu-Events 'bm1' $a.item)[0].via -eq 'sweep-confirmed' -and (Bu-Events 'bm1' $a.item)[0].sha -eq $m.sha) ((Bu-Events 'bm1' $a.item) | ConvertTo-Json -Compress)
}

'base update: a clean pull request that is only behind is updated by the gateway when the owner does not act [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/clean.md')
    Bu-Synced
    $before = Bu-Status; $head0 = (Get-FakePr $a.pr).sha
    [void](Fake 'master-merge' @{ files = @('docs/x.md') })
    [void](Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 })
    Check 'not before the delay' ((Bu-Puts $a.pr) -eq 0)
    $done = Wait-Until -Seconds 40 { (Bu-Puts $a.pr) -gt 0 }
    Check 'the gateway called update branch' $done
    Check 'the branch moved' ((Get-FakePr $a.pr).sha -ne $head0)
    Check 'journal: branch-updated' (Wait-Until -Seconds 20 { Bu-Journal $a.item 'branch-updated' })
    Check '/status counts it' ((Bu-Status).gatewayUpdates -eq $before.gatewayUpdates + 1)
}

'base update: a pull request in conflict with master is left to its owner [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/conflict.md')
    Fake 'pr' @{ number = $a.pr; conflict = $true } | Out-Null
    Bu-Synced
    [void](Fake 'master-merge' @{ files = @('docs/conflict.md') })
    $got = Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 }
    Check 'the owner is told' $got
    Check 'the overlap names the file' (@((Bu-Events 'bm1' $a.item)[0].overlap) -contains 'docs/conflict.md')
    Start-Sleep -Seconds 14
    Check 'the gateway does not update the branch' ((Bu-Puts $a.pr) -eq 0)
}

'base update: with autoUpdateBranch off the gateway updates nothing [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/off.md')
    Bu-Synced
    $h = @{ Authorization = 'Bearer test-token' }
    try {
        $s = Invoke-RestMethod "$(Get-GatewayBase)/api/v1/base-update?autoUpdateBranch=false" -Method POST -Headers $h
        Check 'the switch is off' ($s.autoUpdateBranch -eq $false)
        [void](Fake 'master-merge' @{ files = @('docs/y.md') })
        $got = Wait-Until -Seconds 30 { (Bu-Events 'bm1' $a.item).Count -gt 0 }
        Check 'the owner is still told' $got
        Start-Sleep -Seconds 14
        Check 'no update branch' ((Bu-Puts $a.pr) -eq 0)
    } finally { [void](Invoke-RestMethod "$(Get-GatewayBase)/api/v1/base-update?autoUpdateBranch=true" -Method POST -Headers $h) }
}

'base update: an item whose PASS verdict waits for its merge gets no trigger [full]' = {
    Bu-Worker 'bm1'
    $a = Bu-OwnedPr 'bm1' @('docs/pass.md'); $b = Bu-OwnedPr 'bm1' @('docs/pass2.md')
    # the state of a PASS verdict that the gateway has not merged yet (pass-unmerged)
    Bu-SetVerdict $a.item $a.pr -NoHead
    Bu-Synced
    [void](Fake 'master-merge' @{ files = @('docs/z.md') })
    $got = Wait-Until -Seconds 30 { (Bu-Events 'bm1' $b.item).Count -gt 0 }
    Check 'the other item is told' $got
    Check 'the pass-unmerged item is not' ((Bu-Events 'bm1' $a.item).Count -eq 0)
}

'base update: a session that reconnects is replayed the latest base.updated only [full]' = {
    Bu-Worker 'bm4'
    $a = Bu-OwnedPr 'bm4' @('docs/replay.md')
    Bu-Synced
    # (the gateway's own update would bring the branch up to date between the two merges: off for this scenario)
    $h = @{ Authorization = 'Bearer test-token' }; [void](Invoke-RestMethod "$(Get-GatewayBase)/api/v1/base-update?autoUpdateBranch=false" -Method POST -Headers $h)
    try {
    Stop-OwnerClient 'bm4'
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'bm4' -and $_.connected }).Count -eq 0 })
    $t0 = (Bu-Status).eventsSent
    [void](Fake 'master-merge' @{ files = @('docs/r1.md') }); [void](Wait-Until -Seconds 30 { (Bu-Status).eventsSent -ge $t0 + 1 })
    $m = Fake 'master-merge' @{ files = @('docs/r2.md') }; [void](Wait-Until -Seconds 30 { (Bu-Status).eventsSent -ge $t0 + 2 })
    $out = Join-Path $script:Work 'bm4-replay.txt'
    & curl -s -N --max-time 4 -H "Authorization: Bearer $($script:Workers['bm4'].token)" -H 'Last-Event-ID: 0' "$(Get-GatewayBase)/api/v1/events?name=bm4&type=persistent-local&capacity=20&roles=owner" -o $out 2>$null
    $lines = @(Get-Content $out -ErrorAction SilentlyContinue | Where-Object { $_ -like 'data:*' } | ForEach-Object { try { $_.Substring(5).Trim() | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'base.updated' -and $_.item -eq $a.item })
    Check 'one base.updated replayed, the latest' ($lines.Count -eq 1 -and $lines[0].sha -eq $m.sha) "$($lines.Count) $(@($lines | ForEach-Object { $_.sha }) -join ',') want $($m.sha)"
    $w = Fo 'bm4' @('wait-event', '--item', $a.item, '--after', '0', '--timeout', '2')
    Check 'the item''s mailbox holds the latest only' (@($w.events | Where-Object { $_.event -eq 'base.updated' }).Count -eq 1) ($w | ConvertTo-Json -Compress -Depth 5)
    } finally { [void](Invoke-RestMethod "$(Get-GatewayBase)/api/v1/base-update?autoUpdateBranch=true" -Method POST -Headers $h) }
}
}

# issue 103: baseUpdate.mode conflict-or-merge (the default; the owner suite runs with every-move): the owner is told only of a merge conflict, and the
# gateway updates a behind branch only right before it merges a PASS. These scenarios restart the suite's gateway with FACTORY_BASE_UPDATE_MODE.
function Bu-InMode([string]$Mode, [scriptblock]$Body) {
    $old = $env:FACTORY_BASE_UPDATE_MODE; $env:FACTORY_BASE_UPDATE_MODE = $Mode; Restart-Gateway
    try { & $Body } finally { $env:FACTORY_BASE_UPDATE_MODE = $old; Restart-Gateway }
}

$BaseUpdateScenarios['base update (conflict mode): master moves; a clean branch that is behind is left alone, and the owner of a conflicting one is told once, reason conflict'] = {
    Bu-InMode 'conflict-or-merge' {
        Bu-Worker 'bc1'; Bu-Worker 'bc2'
        $a = Bu-OwnedPr 'bc1' @('docs/clean.md'); $b = Bu-OwnedPr 'bc2' @('docs/conflict.md')
        Bu-Synced
        Check 'the gateway runs in the conflict mode' ((Bu-Status).mode -eq 'conflict-or-merge') ((Bu-Status) | ConvertTo-Json -Compress -Depth 3)
        # GitHub has not computed the mergeability of b yet (null twice), then says it conflicts
        Fake 'pr' @{ number = $b.pr; conflict = $true; mergeableNullReads = 2 } | Out-Null
        [void](Fake 'master-merge' @{ files = @('docs/other.md') })
        # told once per pull request head and master head (BaseUpdate.cs, issue 103). Under load a look can find the conflict before the fake's master
        # merge lands: that earlier master head is then told once too. The checks read the line of the moved master, and that no heads are told twice.
        $mh = (Get-FakeState).masterSha
        Check 'the owner of the conflicting pull request is told: base.updated, reason conflict' (Wait-Until -Seconds 45 { @((Bu-Events 'bc2' $b.item) | Where-Object { (Pv $_ 'sha') -eq $mh }).Count -ge 1 }) ((Bu-Status) | ConvertTo-Json -Compress -Depth 3)
        $e = @((Bu-Events 'bc2' $b.item) | Where-Object { (Pv $_ 'sha') -eq $mh })[0]
        Check 'the event names the pull request and the conflict' ($e.reason -eq 'conflict' -and $e.conflict -eq $true -and $e.pr -eq $b.pr -and $e.behind -ge 1) ($e | ConvertTo-Json -Compress)
        Start-Sleep -Seconds 12
        $ev = Bu-Events 'bc2' $b.item; $shas = @($ev | ForEach-Object { "$(Pv $_ 'sha')" })
        Check 'once: later looks at the same heads tell nothing again' ($ev.Count -le 2 -and @($shas | Select-Object -Unique).Count -eq $shas.Count -and $shas[-1] -eq $mh) ($ev | ConvertTo-Json -Compress)
        Check 'the owner of the clean branch, only behind, is told nothing and its branch is not updated' ((Bu-Events 'bc1' $a.item).Count -eq 0 -and (Bu-Puts $a.pr) -eq 0 -and (Bu-Puts $b.pr) -eq 0)
        # the journal line is written by the rule script after the event (gateway Journal, not awaited): wait for it
        [void](Wait-Until -Seconds 30 { @((Get-FakeIssue $b.item).comments | Where-Object { $_.body -like '*has a merge conflict with master*plant event=base-updated*' }).Count -ge $ev.Count })
        $told = @((Get-FakeIssue $b.item).comments | Where-Object { $_.body -like '*has a merge conflict with master*plant event=base-updated*' }).Count
        Check 'the journal says the pull request has a merge conflict, once per line told' ($told -eq $ev.Count) "$told comments, $($ev.Count) lines"
        Check '/status counts it' ((Bu-Status).conflictsTold -ge 1 -and (Bu-Status).conflicting -ge 1) ((Bu-Status) | ConvertTo-Json -Compress -Depth 3)
        # the owner merges master and pushes: a new head that still conflicts is told again, once
        Fake 'push-branch' @{ branch = $b.branch; files = @('docs/conflict.md', 'docs/more.md') } | Out-Null
        Check 'a new head that still conflicts is told again' (Wait-Until -Seconds 30 { (Bu-Events 'bc2' $b.item).Count -eq $ev.Count + 1 })
    }
}

$BaseUpdateScenarios['base update (conflict mode): right before the gateway merges a PASS, a branch behind master is brought up to date once, and the new head is merged [full]'] = {
    Bu-InMode 'conflict-or-merge' {
        $x = Pm-ToValidation
        # the new head's checks take 20 s (the fake applies the delay to the head the update makes)
        Fake 'pr' @{ number = $x.pr; behind = 2; delaySeconds = 20 } | Out-Null
        Fake 'checks' @{ sha = (Get-Head $x.pr); name = 'Build result'; conclusion = 'success' } | Out-Null; Fake 'checks' @{ sha = (Get-Head $x.pr); name = 'secret-scan'; conclusion = 'success' } | Out-Null
        $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
        Check 'the verdict call waits: the branch is being brought up to date' ($v.merge.outcome -eq 'waiting' -and $v.merge.reason -eq 'branch-updated') ($v | ConvertTo-Json -Compress -Depth 5)
        Check 'the update is recorded as the verdict''s head at once' ((Pm-State $x.n).verdict.head_sha -eq (Get-FakePr $x.pr).sha) ((Pm-State $x.n).verdict | ConvertTo-Json -Compress)
        # the session's own merge call (the skill makes one after a PASS) waits for the new head's checks like the gateway, quickly, and parks nothing
        $sw = [Diagnostics.Stopwatch]::StartNew(); $m = F 'w1' @('merge', '--item', $x.n, '--pr', $x.pr)
        Check 'the session''s merge call answers waiting at once (checks of the new head pending)' ($m.exit -eq 0 -and $m.outcome -eq 'waiting' -and $m.reason -eq 'checks-pending' -and $sw.Elapsed.TotalSeconds -lt 40) "$($m | ConvertTo-Json -Compress) in $([int]$sw.Elapsed.TotalSeconds) s"
        Check 'merged on the gateway''s update commit, with no session' (Wait-Until -Seconds 90 { (Get-FakePr $x.pr).merged })
        $st = Pm-State $x.n
        Check 'one update of the branch, recorded as the update before the merge; the verdict names the update commit' ((Bu-Puts $x.pr) -eq 1 -and $st.verdict.pre_merge_update -eq $true -and $st.verdict.head_sha -eq (Get-FakePr $x.pr).sha) ($st.verdict | ConvertTo-Json -Compress)
    }
}
foreach ($k in $BaseUpdateScenarios.Keys) { $OwnerScenarios[$k] = $BaseUpdateScenarios[$k] }
