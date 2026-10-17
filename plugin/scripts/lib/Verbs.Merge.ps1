# The merge verb: squash-merges the pull request named by a recorded PASS verdict, only for an item that carries the Auto Merge label.
# It does not approve the pull request (the default-branch ruleset needs 0 approvals). Authorized by the owner on 2026-10-10 for this demo system.
#
# The gateway merges by itself (owner decision of 2026-10-13, config gatewayMerge, default true): under merge policy 'auto' a recorded PASS on an
# item with the Auto Merge label is merged by validation-verdict in the same call, and by the sweep for whatever that call could not finish
# (checks still running, a branch behind its base, a gateway restart, a session that stopped). Both run Verb_merge -Gateway: the same checks in
# the same order, but one step per call and never a long wait. What cannot happen yet is answered as outcome 'waiting' with a reason code,
# recorded in verdict.wait and journaled once per code; the sweep tries again. The session's own merge call then answers 'already-merged'.

function Test-GatewayMerge { $c = Get-Cfg; return (-not (Test-Has $c 'gatewayMerge')) -or [bool]$c.gatewayMerge }

# Is $Head the merge commit GitHub's update-branch made from the verdict head? Exactly two parents, the first the verdict head, the second the
# base branch head or an ancestor of it. Anything else (a push by a worker or a person, a rebase, a racing commit) is not covered by the verdict.
# The parents alone can be forged by a hand-made merge, so the commit must also carry GitHub's own signature (verified, reason valid, committed
# by GitHub's web-flow identity), and when update-branch named the commit it made, be exactly that one.
function Test-GatewayUpdateHead([string]$VerdictSha, [string]$Head, [string]$Expected = '') {
    $c = Get-Cfg
    if ($Expected -and $Expected -ne $Head) { return $false }
    $cm = Invoke-Gh -Path "$(Get-RepoPath)/commits/$Head" -Allow 404, 422
    if ($cm -is [hashtable] -and $cm.ContainsKey('status')) { return $false }
    $v = $cm.commit.verification; $who = $cm.commit.committer
    if (-not $v -or $v.verified -ne $true -or "$($v.reason)" -ne 'valid' -or "$($who.name)" -ne 'GitHub' -or "$($who.email)" -ne 'noreply@github.com') { return $false }
    $ps = @($cm.parents | ForEach-Object { "$($_.sha)" })
    if ($ps.Count -ne 2 -or $ps[0] -ne $VerdictSha) { return $false }
    $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$($c.defaultBranch)...$($ps[1])" -Allow 404, 422
    if ($cmp -is [hashtable] -and $cmp.ContainsKey('status')) { return $false }
    return "$($cmp.status)" -in 'identical', 'behind'
}

function Get-MergeWaitText([string]$Code) {
    switch ($Code) {
        'checks-pending' { return 'its required checks are still running' }
        'branch-updated' { return 'its branch was behind the base branch and has been brought up to date; the checks of the new head run now' }
        'mergeability-unknown' { return 'GitHub has not yet said whether it can be merged' }
        'verdict-head-unknown' { return 'the verdict does not name the head it was given for' }
        'merge-queue' { return 'the merge queue is full (an earlier merge is still waiting for its release candidate)' }
        'checks-rerun' { return 'its checks failed and the failed jobs are re-run once (or a run of the head is still going); the new attempt decides' }
        'master-defect' { return 'its checks fail only where the base branch fails as well (a defect of the base branch, not of this change); it waits for the base branch to pass them again' }
        default { return $Code }
    }
}

# A red head right before the merge, under the one CI rule (issue 102, Prs.ps1): a re-run once, or a run still going, is a wait; a defect of the base
# branch is a wait too and costs no demotion (reported once); only a red of the change's own demotes. Returns @{ wait = code } or @{ result = the
# answer of the demotion }. The state is saved here when the rule recorded something.
# (every answer has every key: the rule scripts run under strict mode)
function Resolve-RedBeforeMerge([int]$n, $info, $st, [int]$PrNum, [string]$Sha, $Chk, [string]$When) {
    $s = $st.state
    $out = @{ wait = ''; result = $null; causes = @(); new = $false; fixed = $false }
    $rule = Get-RedHeadRuling $s $Sha $Chk
    $out.causes = @($rule.causes)
    switch ($rule.ruling) {
        'rerun' {
            Save-State $n $st
            Add-Comment $n "PR #$PrNum checks failed $When at ``$($Sha.Substring(0,7))`` ($($rule.causes -join ', ')) - $($rule.reason); re-running the failed jobs once (workflow run $(($rule.runs | ForEach-Object { $_.id }) -join ', ')) before deciding. No demotion is counted for it."
            $out.wait = 'checks-rerun'; return $out
        }
        { $_ -in 'running', 'rerun-wait', 'deferred' } { $out.wait = 'checks-rerun'; return $out }
        'master-defect' {
            # (cached: judged less than masterDefectCheckMinutes ago, nothing read; fixed: the base branch passes those checks again, the caller updates)
            $out.wait = 'master-defect'
            if ($rule.cached) { return $out }
            $out.new = Register-MasterDefect $n $s $PrNum $Sha $rule.causes; $s.master_defect.checked_at = ConvertTo-Iso (Get-UtcNow); Save-State $n $st
            $out.fixed = [bool]$rule.fixed; return $out
        }
    }
    $d = Invoke-Demote $n $info $st "PR #$PrNum checks are red $When ($($Chk.failed_checks -join ', ')$(if ($rule.reason -match '^still red') { '; still red after one re-run of the failed jobs' }))" 'merge'
    $out.result = @{ ok = $true; id = $n; outcome = $d.outcome; detail = $d }
    return $out
}

function Wait-HeadChange([int]$Pr, [string]$OldSha, [int]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    do { Start-Sleep -Seconds 4; $p = Get-Pr $Pr; if ($p.head.sha -ne $OldSha) { return $p } } while ((Get-Date) -lt $end)
    return $p
}

function Verb_merge($a, [switch]$Gateway) {
    $n = Get-ItemNumber $a; $c = Get-Cfg; $t = $c.timing
    $info = Get-ItemInfo $n
    $st = Get-State $n; $s = $st.state
    # Already merged (by the gateway right after the verdict, by the sweep, or by an earlier call): the call is a no-op that says so, wherever the
    # item is by now (the merged pull request may have closed it, and settle may have moved its card on).
    if ((Test-Has $s 'verdict') -and $s.verdict.passed -and $s.verdict.processed -and (Test-Has $s 'merge') -and (Test-Has $s.merge 'sha') -and (Test-Has $s.merge 'pr') -and [int]$s.merge.pr -eq [int]$s.verdict.pr -and (-not (Test-Has $a 'pr') -or [int]$a.pr -eq [int]$s.merge.pr)) {
        return @{ ok = $true; id = $n; outcome = 'already-merged'; sha = $s.merge.sha }
    }
    Assert-Open $info
    if ($info.column -ine $c.columns.validation) { Reject 10 'wrong-column' "merging happens only from '$($c.columns.validation)'; the item is in '$($info.column)'" }
    if (-not (Test-Has $s 'verdict') -or -not $s.verdict.passed -or $s.verdict.processed) { Reject 10 'no-pass-verdict' 'no unprocessed PASS verdict is recorded for this item' }
    # issue 109: a person holds the item (a hold label): its PASS is not merged, neither by the gateway (the verdict's own merge, the sweep) nor by a
    # session, until the label is removed; the sweep merges it then
    $holdLabel = Get-HoldLabel $info.labels
    if ($holdLabel) {
        if ($Gateway) { return @{ ok = $true; id = $n; outcome = 'waiting'; reason = 'held-by-label' } }
        Reject 10 'held-by-label' "item carries the '$holdLabel' label: a person holds it; the PASS is not merged until the label is removed" @{ label = $holdLabel }
    }
    $prNum = if (Test-Has $a 'pr') { [int]$a.pr } else { [int]$s.verdict.pr }
    if ($prNum -ne [int]$s.verdict.pr) { Reject 10 'pr-mismatch' "the verdict names PR #$($s.verdict.pr), not #$prNum" }
    # Without the Auto Merge label only the QC merge gate lets an item through: owner mode, mergePolicy peer-approved, qc.requireRun / qc.requireApproval
    # (design pr-qc-environment.md 3.6). Everywhere else the label is still required.
    $viaQcGate = $false
    if (-not (Test-Label $info $c.autoMergeLabel)) {
        if (-not (Test-QcGateActive)) { Reject 10 'no-auto-merge-label' "item does not carry '$($c.autoMergeLabel)'" }
        $viaQcGate = $true
    }
    $park = { param($reason, $text) Set-Park $s $reason ($t.parkHours * 60); $s.verdict.processed = $true; $s.Remove('claim'); Remove-ClaimRef $n; Save-State $n $st; Add-Comment $n $text; return @{ ok = $true; id = $n; outcome = 'parked'; reason = $reason } }
    # -Gateway only: the merge cannot happen yet. The code is kept in verdict.wait and journaled once per code of this verdict, so a sweep that finds
    # the same state again writes nothing; a PASS that stays unmerged for timing.verdictTimeoutMinutes is parked for a person instead of waiting forever.
    $wait = { param($code)
        $v = $s.verdict; $at = ConvertFrom-Iso $v.at; $limit = if (Test-Has $t 'verdictTimeoutMinutes') { [double]$t.verdictTimeoutMinutes } else { 180 }
        if ($at -and ((Get-UtcNow) - $at).TotalMinutes -gt $limit) { return & $park 'pass-unmerged' "PR #$prNum has a PASS verdict and could not be merged for $limit min (${code}: $(Get-MergeWaitText $code)); parked for a human." }
        if (-not (Test-Has $v 'wait') -or "$($v.wait.code)" -ne $code) {
            $v.wait = @{ code = $code; since = ConvertTo-Iso (Get-UtcNow) }
            [void](Add-Journal $n $st 'merge-waiting' @{ pr = $prNum; code = $code; reason = (Get-MergeWaitText $code) } "$($v.at)|$code")
            Save-State $n $st
        }
        return @{ ok = $true; id = $n; outcome = 'waiting'; reason = $code; since = $v.wait.since }
    }
    if ($Gateway -and (Get-Park $s)) { return @{ ok = $true; id = $n; outcome = 'waiting'; reason = 'held' } }
    # Merge queue: the Release workflow keeps only one queued run, so merging faster than releases are built drops releases.
    # With mergeQueueDepth N, merge only while fewer than N other merged items are still waiting for master CI or their release candidate.
    $depth = if (Test-Has $c 'mergeQueueDepth') { [int]$c.mergeQueueDepth } else { 0 }
    # A documentation-only change builds no release, so it never waits in the queue and never holds a place in it.
    $thisDocsOnly = try { Test-DocsOnlyFiles (Get-PrFiles $prNum) } catch { $false }
    if ($depth -gt 0 -and -not $thisDocsOnly) {
        $busy = @()
        foreach ($o in (Get-BoardList | Where-Object { $_.open -and $_.number -ne $n -and $_.column -ieq $c.columns.validation -and (Test-NameIn $c.label $_.labels) })) {
            $os = (Get-State $o.number).state
            if ((Test-Has $os 'merge') -and (Test-Has $os.merge 'awaiting') -and $os.merge.awaiting -in 'master-green', 'release-candidate') {
                $oDocs = if (Test-Has $os.merge 'docs_only') { [bool]$os.merge.docs_only } elseif (Test-Has $os.merge 'pr') { try { Test-DocsOnlyFiles (Get-PrFiles ([int]$os.merge.pr)) } catch { $false } } else { $false }
                if (-not $oDocs) { $busy += $o.number }
            }
        }
        if ($busy.Count -ge $depth -and $Gateway) { return & $wait 'merge-queue' }
        if ($busy.Count -ge $depth) { Reject 21 'merge-queue' "merge queue is full: waiting for the release candidate of #$($busy -join ', #') before merging this one" @{ waiting_for = $busy; retryAfterSeconds = 60 } }
    }
    $pr = Get-Pr $prNum
    if (-not (Test-PrBelongs $pr $n)) { return & $park 'pr-mismatch' "PR #$prNum is not a PR belonging to this work item (branch '$($pr.head.ref)'); refusing to merge." }
    if ($pr.merged) {
        # issue 114: the merge recorded before (an item validated again after its merge, 276) keeps its record, merged_at and its wait; a record
        # whose wait an older gateway erased is re-armed instead of starting over at master-green
        if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'sha') -and "$($s.merge.sha)" -eq "$($pr.merge_commit_sha)") { [void](Restore-Settle $s) }
        else { $s.merge = @{ sha = $pr.merge_commit_sha; awaiting = 'master-green'; merged_at = ConvertTo-Iso (Get-UtcNow); pr = $prNum } }
        $s.verdict.processed = $true; $s.Remove('claim'); Remove-ClaimRef $n; Save-State $n $st
        return @{ ok = $true; id = $n; outcome = 'already-merged'; sha = $pr.merge_commit_sha }
    }
    if ($c.mergePolicy -ne 'auto') {
        if (Get-Park $s) { Reject 10 'held' "item is held: $($s.park.reason)" }
        if (-not (Test-Has $s 'approval') -or $s.approval.sha -ne $pr.head.sha) { Reject 10 'approval-missing' "merge policy is '$($c.mergePolicy)': the current head $($pr.head.sha.Substring(0,7)) has no recorded approval" }
        if (-not (Test-GitHubApproval $pr)) { Reject 10 'approval-not-on-github' 'no approval from the inspector or a named person exists on GitHub for the current head' }
        if ($viaQcGate) {
            $gate = Get-QcGate
            # (a) some environment for THIS head reached ready at least once (documentation-only changes need no environment)
            if ($gate.requireRun -and -not $thisDocsOnly) {
                $qrec = Get-QcRec $s $prNum
                if ($null -eq $qrec -or -not (Test-Has $qrec 'ran_sha') -or "$($qrec.ran_sha)" -ne "$($pr.head.sha)") {
                    Reject 10 'qc-not-run' "no QC environment for the current head $($pr.head.sha.Substring(0,7)) has reached ready; a person starts one from the link on the pull request. Wait for the qc.ready or qc.approved event (or a person); do not park." @{ wait_for = 'qc.approved'; sha = "$($pr.head.sha)" }
                }
            }
            # (b) a person in humanApprovers approved the current head on GitHub (the author never counts)
            if ($gate.requireApproval -and -not (Find-HumanApproval $pr)) {
                Reject 10 'qc-approval-missing' "no person in humanApprovers has approved the current head $($pr.head.sha.Substring(0,7)) on GitHub. Wait for the qc.approved event (or a person); do not park." @{ wait_for = 'qc.approved'; sha = "$($pr.head.sha)" }
            }
        }
    }
    if ($pr.state -ne 'open') { return & $park 'pr-mismatch' "PR #$prNum is $($pr.state), not open; refusing to merge." }
    # Under 'auto' nobody looks at the change after the verdict, so the PASS covers the head it was given for and no other: a push after the
    # verdict voids it and the item goes back to Development (under 'peer-approved' the approval of the current head is the same rule). The one
    # head that is accepted without a new verdict is the one this verb made itself when it brought the branch up to date with its base.
    $vsha = if (Test-Has $s.verdict 'head_sha') { "$($s.verdict.head_sha)" } else { '' }
    # fail closed: the gateway never merges a PASS that does not say which head it covers
    if (-not $vsha) { return & $park 'pass-unmerged' "PR #$prNum has a PASS verdict that does not name the head it was given for (verdict-head-unknown); the gateway does not merge it. Parked for a human." }
    if ($c.mergePolicy -eq 'auto' -and $vsha -and $vsha -ne "$($pr.head.sha)") {
        # the one head accepted without a new verdict: the merge commit of the gateway's own update-branch, verified on GitHub (the marker is
        # cleared once the check has run, pass or fail, so it can never vouch for a later push)
        $fromUpdate = (Test-Has $s.verdict 'updated_from') -and "$($s.verdict.updated_from)" -eq $vsha
        $expect = if (Test-Has $s.verdict 'updated_to') { "$($s.verdict.updated_to)" } else { '' }
        if ($fromUpdate) { $s.verdict.Remove('updated_from'); $s.verdict.Remove('updated_to') }
        if ($fromUpdate -and (Test-GatewayUpdateHead $vsha "$($pr.head.sha)" $expect)) { $s.verdict.head_sha = "$($pr.head.sha)"; Save-State $n $st }
        else { $d = Invoke-Demote $n $info $st "the branch of PR #$prNum changed after the validation verdict (verdict for $($vsha.Substring(0, [Math]::Min(7, $vsha.Length))), head now $($pr.head.sha.Substring(0,7))); the PASS verdict no longer applies" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; reason = 'stale-head'; detail = $d } }
    }
    $end = (Get-Date).AddSeconds($(if ($Gateway) { [Math]::Min([double]$t.mergeabilityWaitSeconds, 12) } else { $t.mergeabilityWaitSeconds }))
    while ($null -eq $pr.mergeable -and (Get-Date) -lt $end) { Start-Sleep -Seconds $t.mergeabilityPollSeconds; $pr = Get-Pr $prNum }
    if ($Gateway -and $null -eq $pr.mergeable) { return & $wait 'mergeability-unknown' }
    if ($pr.mergeable -eq $false) { $d = Invoke-Demote $n $info $st "GitHub reports PR #$prNum is NOT mergeable (mergeable_state '$($pr.mergeable_state)')" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; detail = $d } }
    # issue 103: once the gateway brought the branch up to date before its merge, the merge is the gateway's: a session's own merge call (the one the
    # functional-testing skill makes after a PASS) waits as the gateway does, instead of polling the new head's checks and parking it out of date
    $gatewayOwns = $Gateway -or ($c.mergePolicy -eq 'auto' -and (Test-GatewayMerge) -and (Test-Has $s.verdict 'pre_merge_update') -and $s.verdict.pre_merge_update)
    $end = (Get-Date).AddSeconds($t.preMergeChecksWaitSeconds)
    while ($true) {
        $chk = Get-ChecksFor $pr.head.sha
        if ($chk.status -eq 'failure') {
            $red = Resolve-RedBeforeMerge $n $info $st $prNum "$($pr.head.sha)" $chk 'right before merge'
            if (-not $red.wait) { return $red.result }
            # the base branch passes the checks of its defect again: under 'auto' the gateway merges it into the branch once per head (GitHub's update
            # branch, the one head a PASS accepts without a new verdict, as for an out-of-date branch below); the new head's checks decide
            if ($red.wait -eq 'master-defect' -and $red.fixed -and $c.mergePolicy -eq 'auto' -and -not (Test-Has $s.master_defect 'updated_for')) {
                $s.master_defect.updated_for = "$($pr.head.sha)"; $s.master_defect.updated_at = ConvertTo-Iso (Get-UtcNow); $s.verdict.updated_from = "$($pr.head.sha)"; Save-State $n $st
                $u = try { Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$prNum/update-branch" -Body @{ expected_head_sha = "$($pr.head.sha)" } -Allow 202, 422, 409 } catch { @{ status = 0; body = @{ message = "$($_.Exception.Message)" } } }
                if ($u -is [hashtable] -and $u.ContainsKey('status') -and $u.status -ne 202) {
                    # refused: no update to vouch for, and the next look tries again
                    $s.verdict.Remove('updated_from'); $s.master_defect.Remove('updated_for'); $s.master_defect.Remove('updated_at'); Save-State $n $st
                }
                else {
                    if ($u -isnot [hashtable] -and $u.PSObject.Properties.Name -contains 'sha' -and $u.sha) { $s.verdict.updated_to = "$($u.sha)"; Save-State $n $st }
                    Add-Comment $n "**$($c.defaultBranch)** passes $($red.causes -join ', ') again: the gateway merged $($c.defaultBranch) into the branch of PR #$prNum; the checks of the new head decide the merge."
                    if ($Gateway) { return & $wait 'branch-updated' }
                }
            }
            if ($Gateway) { $w = & $wait $red.wait; if ($red.new) { $w.masterDefectNew = $true }; return $w }
            Reject 21 $red.wait "PR #$prNum is not merged yet: $(Get-MergeWaitText $red.wait). Call merge again later; nothing was demoted." @{ retryAfterSeconds = 300 }
        }
        if ($chk.status -eq 'success') { break }
        if ($gatewayOwns) { return & $wait 'checks-pending' }
        if ((Get-Date) -gt $end) { break }
        Start-Sleep -Seconds $t.preMergeChecksPollSeconds
    }
    # issue 103: with baseUpdate.mode conflict-or-merge (the default) a branch is not brought up to date when master moves, but here, right before the
    # gateway merges a PASS under 'auto': once per verdict, when the branch is behind. GitHub's update branch makes the one head a PASS accepts
    # without a new verdict (as for an out-of-date branch below); the next sweep merges once that head's checks are green.
    # baseUpdate.autoUpdateBranch off (the operator's switch of the gateway's own back-merges) switches it off too.
    $autoUpd = -not ((Test-Has $c 'baseUpdate') -and (Test-Has $c.baseUpdate 'autoUpdateBranch') -and $c.baseUpdate.autoUpdateBranch -eq $false)
    if ($Gateway -and $autoUpd -and $c.mergePolicy -eq 'auto' -and (Get-BaseUpdateMode) -eq 'conflict-or-merge' -and -not ((Test-Has $s.verdict 'pre_merge_update') -and $s.verdict.pre_merge_update)) {
        if ((Get-BehindBy "$($pr.head.ref)") -gt 0) {
            $from = "$($pr.head.sha)"
            $s.verdict.pre_merge_update = $true; $s.verdict.updated_from = $from; Save-State $n $st
            $u = try { Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$prNum/update-branch" -Body @{ expected_head_sha = $from } -Allow 202, 422, 409 } catch { @{ status = 0; body = @{ message = "$($_.Exception.Message)" } } }
            if ($u -is [hashtable] -and $u.ContainsKey('status') -and $u.status -ne 202) {
                # GitHub could not update it (the head moved, a conflict GitHub saw only now, or the call failed): merged as it is, as before (the
                # ruleset does not require an up-to-date branch); a conflict is refused by the merge itself below
                $s.verdict.Remove('updated_from'); Save-State $n $st
            }
            else {
                if ($u -isnot [hashtable] -and $u.PSObject.Properties.Name -contains 'sha' -and $u.sha) { $s.verdict.updated_to = "$($u.sha)"; Save-State $n $st }
                # as for an out-of-date branch below: the new head is verified to be GitHub's update of the verdict head and recorded now, so a merge call
                # that reads the branch next (the session's own) finds the head the PASS covers; if GitHub has not made it yet, the next call does that
                $pr = Wait-HeadChange $prNum $from ([Math]::Min([double]$t.updatedHeadWaitSeconds, 12))
                if ("$($pr.head.sha)" -ne $from) {
                    $ok = Test-GatewayUpdateHead $from "$($pr.head.sha)" $(if (Test-Has $s.verdict 'updated_to') { "$($s.verdict.updated_to)" } else { '' }); $s.verdict.Remove('updated_from'); $s.verdict.Remove('updated_to')
                    if (-not $ok) { $d = Invoke-Demote $n $info $st "the branch of PR #$prNum changed after the validation verdict to a commit that is not the gateway's update with the base branch; the PASS verdict no longer applies" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; reason = 'stale-head'; detail = $d } }
                    $s.verdict.head_sha = "$($pr.head.sha)"; Save-State $n $st
                }
                return & $wait 'branch-updated'
            }
        }
    }
    # under 'auto' only the verdict's head may merge; under 'peer-approved' the approval of the current head is the rule (the head may move after the
    # verdict with a new QC run and approval), so the current head is merged and updated as before
    $byVerdict = $c.mergePolicy -eq 'auto'
    for ($attempt = 1; $attempt -le [int]$t.outOfDateMergeAttempts; $attempt++) {
        $mergeSha = if ($byVerdict) { "$($s.verdict.head_sha)" } else { "$($pr.head.sha)" }
        $r = Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$prNum/merge" -Body @{ merge_method = 'squash'; sha = $mergeSha } -Allow 405, 409, 422
        if ($r -is [hashtable] -and $r.ContainsKey('status')) {
            $msg = "$($r.body.message)"
            if ($msg -match 'out of date|out-of-date|Head branch was modified|behind') {
                # the merge was refused for the verdict's head: if the branch now carries any other head, nothing validated it
                $pr = Get-Pr $prNum
                # the gateway's own update before its merge may land between the read of the branch and this merge call: its commit is the verdict's
                if ($byVerdict -and "$($pr.head.sha)" -ne "$($s.verdict.head_sha)" -and (Test-Has $s.verdict 'updated_from') -and "$($s.verdict.updated_from)" -eq "$($s.verdict.head_sha)" -and
                    (Test-GatewayUpdateHead "$($s.verdict.updated_from)" "$($pr.head.sha)" $(if (Test-Has $s.verdict 'updated_to') { "$($s.verdict.updated_to)" } else { '' }))) {
                    $s.verdict.Remove('updated_from'); $s.verdict.Remove('updated_to'); $s.verdict.head_sha = "$($pr.head.sha)"; Save-State $n $st
                    return & $wait 'branch-updated'
                }
                if ($byVerdict -and "$($pr.head.sha)" -ne "$($s.verdict.head_sha)") { $d = Invoke-Demote $n $info $st "the branch of PR #$prNum changed after the validation verdict (stale-head); the PASS verdict no longer applies" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; reason = 'stale-head'; detail = $d } }
                # (bounded: the updates of one verdict are counted in the item state, so the sweep's calls add up to the same limit as this loop)
                $ups = if (Test-Has $s.verdict 'updates') { [int]$s.verdict.updates } else { 0 }
                if ($Gateway -and $ups -ge [int]$t.outOfDateMergeAttempts) { break }
                $s.verdict.updates = $ups + 1; $s.verdict.updated_from = $mergeSha; Save-State $n $st
                if (-not $byVerdict) { $mergeSha = "$($pr.head.sha)"; $s.verdict.updated_from = $mergeSha }
                $u = Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$prNum/update-branch" -Body @{ expected_head_sha = $mergeSha } -Allow 202, 422, 409
                if ($u -isnot [hashtable] -and $u.PSObject.Properties.Name -contains 'sha' -and $u.sha) { $s.verdict.updated_to = "$($u.sha)"; Save-State $n $st }
                if ($u -is [hashtable] -and $u.ContainsKey('status') -and $u.status -ne 202) { $d = Invoke-Demote $n $info $st "could not update PR #${prNum}: $($u.body.message)" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; detail = $d } }
                $pr = Wait-HeadChange $prNum $pr.head.sha $(if ($Gateway) { [Math]::Min([double]$t.updatedHeadWaitSeconds, 12) } else { $t.updatedHeadWaitSeconds })
                if ("$($pr.head.sha)" -ne "$($s.verdict.updated_from)") {
                    $ok = Test-GatewayUpdateHead "$($s.verdict.updated_from)" "$($pr.head.sha)" $(if (Test-Has $s.verdict 'updated_to') { "$($s.verdict.updated_to)" } else { '' }); $s.verdict.Remove('updated_from'); $s.verdict.Remove('updated_to')
                    if (-not $ok) { $d = Invoke-Demote $n $info $st "the branch of PR #$prNum changed after the validation verdict to a commit that is not the gateway's update with the base branch; the PASS verdict no longer applies" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; reason = 'stale-head'; detail = $d } }
                    $s.verdict.head_sha = "$($pr.head.sha)"; Save-State $n $st
                }
                if ($Gateway) { return & $wait 'branch-updated' }
                $end = (Get-Date).AddSeconds($t.preMergeChecksWaitSeconds)
                while ($true) { $chk = Get-ChecksFor $pr.head.sha; if ($chk.status -ne 'pending' -or (Get-Date) -gt $end) { break }; Start-Sleep -Seconds $t.preMergeChecksPollSeconds }
                if ($chk.status -eq 'failure') {
                    $red = Resolve-RedBeforeMerge $n $info $st $prNum "$($pr.head.sha)" $chk 'after updating the branch'
                    if (-not $red.wait) { return $red.result }
                    Reject 21 $red.wait "PR #$prNum is not merged yet: $(Get-MergeWaitText $red.wait). Call merge again later; nothing was demoted." @{ retryAfterSeconds = 300 }
                }
                Start-Sleep -Seconds ([Math]::Min(120, 15 * [Math]::Pow(2, $attempt - 1))); continue
            }
            if ($gatewayOwns -and $r.status -eq 405 -and $msg -match 'status check') { return & $wait 'checks-pending' }
            if ($r.status -eq 405 -and $msg -match 'status check') { Start-Sleep -Seconds ([Math]::Min(120, 15 * [Math]::Pow(2, $attempt - 1))); $pr = Get-Pr $prNum; continue }
            $d = Invoke-Demote $n $info $st "HTTP $($r.status): $msg" 'merge'; return @{ ok = $true; id = $n; outcome = $d.outcome; detail = $d }
        }
        if (-not $r.merged -or -not $r.sha) { return & $park 'merge-refused' "merge of PR #$prNum returned no merge SHA; parked for a human." }
        $s.merge = @{ sha = $r.sha; awaiting = 'master-green'; merged_at = ConvertTo-Iso (Get-UtcNow); pr = $prNum }
        $s.verdict.processed = $true; $s.verdict.Remove('wait'); $s.Remove('claim'); Remove-ClaimRef $n; Save-State $n $st
        Add-Comment $n "$(if ($viaQcGate) { 'validation PASSED, QC run and human approval recorded' } else { "validation PASSED and '$($c.autoMergeLabel)' present" }) - $(if ($Gateway) { 'the gateway ' })squash-merged PR #$prNum as ``$($r.sha.Substring(0,7))``; watching master CI, then the release candidate."
        return @{ ok = $true; id = $n; outcome = 'merged'; sha = $r.sha; by = $(if ($Gateway) { 'gateway' } else { 'session' }) }
    }
    return & $park 'merge-out-of-date' "PR #$prNum kept falling behind master after $($t.outOfDateMergeAttempts) attempts; parked for a human."
}
