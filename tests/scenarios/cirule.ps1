# One CI rule for flakes and pre-existing failures (issue 102, plugin/scripts/lib/Prs.ps1): only the gates (ciGates) decide; a red head is re-run
# once when its failures are checks other than the gates, known flaky or failing on master too; a failure master has as well costs no fix-forward
# round and no demotion and is reported once; a park that ends (expiry or unpark) starts the fix-forward rounds and demotions from 0. The
# scenarios join the suite 'auto' (the session's own verbs and the sweep; the gateway's merge after a PASS is off there).

# The checks of a head as one Build workflow run (runId) plus secret-scan: $Fail are the jobs that failed (and with them "Build result").
function Ci-SetHead([string]$Sha, [string[]]$Fail, [long]$Run, [string[]]$Pass = @()) {
    foreach ($f in $Fail) { Fake 'checks' @{ sha = $Sha; name = $f; conclusion = 'failure'; runId = $Run } | Out-Null }
    foreach ($p in $Pass) { Fake 'checks' @{ sha = $Sha; name = $p; conclusion = 'success'; runId = $Run } | Out-Null }
    Fake 'checks' @{ sha = $Sha; name = 'Build result'; conclusion = $(if ($Fail.Count -gt 0) { 'failure' } else { 'success' }); runId = $Run } | Out-Null
    Fake 'checks' @{ sha = $Sha; name = 'secret-scan'; conclusion = 'success'; runId = $Run + 1 } | Out-Null
}
function Ci-State([int]$n) {
    $c = @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') }) | Select-Object -First 1
    if (-not $c) { return @{} }
    $m = [regex]::Match("$($c.body)", '```json\s*([\s\S]*?)```'); if (-not $m.Success) { return @{} }
    return ($m.Groups[1].Value | ConvertFrom-Json -AsHashtable)
}
function Ci-Comments([int]$n, [string]$Like) { , @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)" -like $Like }) }
# An item through Technical Design and an open pull request in Development; returns @{ n; pr; sha }.
function Ci-Item([string]$Title) {
    $n = New-Item-Fake $Title 'x' $L2; Do-TechnicalDesign $n
    $pr = Do-Development $n @('docs/ci.md')
    return @{ n = $n; pr = $pr; sha = (Get-Head $pr) }
}

$CiRuleScenarios = [ordered]@{}

$CiRuleScenarios['ci rule: a check that is not a gate failing alone leaves the head green; the column completes'] = {
    $i = Ci-Item 'Non-gate red'
    Fake 'checks' @{ sha = $i.sha; name = 'QDNETC'; conclusion = 'failure'; app = 'qodana' } | Out-Null
    $r = Do-DevComplete $i.n; CheckExit 'complete is accepted although a non-gate check failed' $r 0
    Check 'the item moved on to Functional Testing' ((Get-FakeIssue $i.n).column -eq 'Functional Testing') "column $((Get-FakeIssue $i.n).column)"
    $g = F 'w1' @('pr-checks', '--item', $i.n, '--brief')
    Check 'pr-checks says success and still lists the failed non-gate check' ($g.status -eq 'success' -and @($g.failed_checks) -contains 'QDNETC') ($g | ConvertTo-Json -Compress -Depth 4)
}

$CiRuleScenarios['ci rule: a failed acceptance shard is re-run once; the green re-run completes the column without a fix-forward round'] = {
    Fake 'config' @{ rerunSeconds = 4; rerunConclusion = 'success' } | Out-Null
    $i = Ci-Item 'Flaky shard'
    Ci-SetHead $i.sha @('Acceptance Tests (ARM SQLite) [shard 2/6]') 9001
    $r = Do-DevComplete $i.n; CheckExit 'complete is accepted while the rule re-runs the failed jobs' $r 21 'accepted-checks-pending'
    Check 'the answer says why' ("$($r.reason)" -like '*CI rule (rerun:*') "$($r.reason)"
    Check 'the failed jobs were re-run once' ((Get-FakeState).reruns -eq 1) "reruns $((Get-FakeState).reruns)"
    Check 'the re-run is recorded for the head (pr.rerun)' ((Ci-State $i.n)['pr']['rerun'].Contains($i.sha)) ((Ci-State $i.n)['pr'] | ConvertTo-Json -Compress -Depth 5)
    Check 'the sweep completes the column once the re-run is green' (Wait-Until -Seconds 60 { (Get-FakeIssue $i.n).column -eq 'Functional Testing' }) "column $((Get-FakeIssue $i.n).column)"
    Check 'no fix-forward round and no REJECTED comment' (-not (Ci-State $i.n).Contains('fix_forward_rounds') -and (Ci-Comments $i.n '*REJECTED*').Count -eq 0)
    Check 'still exactly one re-run' ((Get-FakeState).reruns -eq 1)
}

$CiRuleScenarios['ci rule: a red of the change''s own is re-run once, then it is a fix-forward round that says so [full]'] = {
    Fake 'config' @{ rerunSeconds = 4; rerunConclusion = 'failure' } | Out-Null
    $i = Ci-Item 'Own red'
    Ci-SetHead $i.sha @('Integration Build (SQLite)') 9101
    $r = Do-DevComplete $i.n; CheckExit 'complete is accepted while the failed jobs are re-run' $r 21 'accepted-checks-pending'
    # (the sweep saves the round, then posts the comment: both are waited for)
    Check 'the sweep counts one fix-forward round after the re-run failed again' (Wait-Until -Seconds 60 { (Ci-State $i.n)['fix_forward_rounds'] -eq 1 -and (Ci-Comments $i.n '*REJECTED a Development completion*').Count -eq 1 }) ((Ci-State $i.n) | ConvertTo-Json -Compress -Depth 5)
    $rej = Ci-Comments $i.n '*REJECTED a Development completion*'
    Check 'the REJECTED comment says it is still red after one re-run' ($rej.Count -eq 1 -and $rej[0].body -like '*still red after one re-run*') ($rej | ForEach-Object { $_.body } | Out-String)
    Check 'one re-run only' ((Get-FakeState).reruns -eq 1)
}

$CiRuleScenarios['ci rule: a failure master has too costs no round; it is reported once, and when master passes again the gateway updates the branch and the new head completes the column'] = {
    Fake 'config' @{ rerunSeconds = 3; rerunConclusion = 'failure' } | Out-Null
    $shard = 'Acceptance Tests [shard 3/6]'
    Fake 'base-history' @{ name = $shard; conclusions = @('failure', 'success', 'success') } | Out-Null
    $i = Ci-Item 'Master defect'
    Ci-SetHead $i.sha @($shard) 9201
    $r = Do-DevComplete $i.n; CheckExit 'complete is accepted: the rule takes over' $r 21 'accepted-checks-pending'
    # (the sweep posts the comment, then saves the state: both are waited for)
    Check 'the sweep reports a master defect once the re-run failed again' (Wait-Until -Seconds 60 { (Ci-Comments $i.n '*a defect of master, not of this change*').Count -ge 1 -and (Ci-State $i.n).Contains('master_defect') }) (((Get-FakeIssue $i.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(160, $_.body.Length)) }) -join ' | ')
    $st = Ci-State $i.n
    Check 'no fix-forward round, no demotion; the state names the defect' (-not $st.Contains('fix_forward_rounds') -and -not $st.Contains('demotions') -and $st.Contains('master_defect') -and @($st['master_defect']['checks']) -contains $shard) ($st | ConvertTo-Json -Compress -Depth 5)
    Check 'the item still waits in Development (no REJECTED comment)' ((Get-FakeIssue $i.n).column -eq 'Development' -and (Ci-Comments $i.n '*REJECTED*').Count -eq 0)
    Start-Sleep -Seconds 8
    Check 'reported once, though the sweep looked again' ((Ci-Comments $i.n '*a defect of master, not of this change*').Count -eq 1)
    # master is fixed: its newest commit passes the shard again
    Fake 'base-history' @{ name = $shard; conclusions = @('success', 'failure', 'success') } | Out-Null
    Check 'the gateway merges master into the branch' (Wait-Until -Seconds 60 { (Ci-Comments $i.n '*passes Acceptance Tests `[shard 3/6`] again: the gateway merged master into the branch*').Count -eq 1 }) (((Get-FakeIssue $i.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(160, $_.body.Length)) }) -join ' | ')
    Check 'the new head is green and the column completes' (Wait-Until -Seconds 60 { (Get-FakeIssue $i.n).column -eq 'Functional Testing' }) "column $((Get-FakeIssue $i.n).column)"
    Check 'the head changed (the branch was updated)' ((Get-Head $i.pr) -ne $i.sha)
    Check 'still no fix-forward round, and the defect is cleared with the green head' (-not (Ci-State $i.n).Contains('fix_forward_rounds') -and -not (Ci-State $i.n).Contains('master_defect'))
}

$CiRuleScenarios['ci rule: a park that expires, and one an operator releases, start the demotions from 0 [full]'] = {
    # three FAIL verdicts (maxDemotions 2) park the item for a person
    $park3 = {
        param($title)
        $n = New-Item-Fake $title 'x' $L2; Do-TechnicalDesign $n
        $pr = Do-Development $n @('docs/p.md')
        for ($k = 1; $k -le 3; $k++) {
            if ($k -gt 1) { $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Development'); CheckExit "claim Development again ($k)" $r 0 }
            $r = Do-DevComplete $n; CheckExit "development complete ($k)" $r 0
            $v = Do-Verdict $n $pr 'w1' $false; CheckExit "FAIL verdict $k" $v 0
        }
        $ps = Ci-State $n
        Check "item $n is parked with its demotions counted" ($ps.Contains('park') -and "$($ps['park']['reason'])" -eq 'verdict-failed' -and [int]$ps['demotions'] -eq 3) ($ps | ConvertTo-Json -Compress -Depth 4)
        return $n
    }
    $a = & $park3 'Park expires'
    # the park ends: its until is moved into the past (the state comment is the gateway's own; the fake lets its author edit it)
    $sc = @((Get-FakeIssue $a).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') })[0]
    $past = [DateTime]::UtcNow.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $body = [regex]::Replace("$($sc.body)", '("until"\s*:\s*")[^"]+(")', "`${1}$past`${2}")
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/comments/$($sc.id)" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ body = $body } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    Check 'the sweep removes the expired park and the demotions' (Wait-Until -Seconds 60 { $s = Ci-State $a; -not $s.Contains('park') -and -not $s.Contains('demotions') }) ((Ci-State $a) | ConvertTo-Json -Compress -Depth 4)
    Check 'the journal says the park expired and the counts start again' ((Ci-Comments $a '*expired*count from 0 again*plant event=unparked*').Count -eq 1) (((Get-FakeIssue $a).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(200, $_.body.Length)) }) -join ' | ')
    $b = & $park3 'Park released'
    $r = F 'op' @('unpark', '--item', $b, '--reason', 'the criterion was reworded')
    CheckExit 'the operator releases the park' $r 0
    Check 'unpark says the counters were reset, and the state has none' ($r.countersReset -eq $true -and -not (Ci-State $b).Contains('demotions') -and -not (Ci-State $b).Contains('fix_forward_rounds')) ($r | ConvertTo-Json -Compress -Depth 4)
    Check 'its journal line says so' ((Ci-Comments $b '*released early*count from 0 again*plant event=unparked*').Count -eq 1)
}

# The merge path (the owner suite: the gateway merges a PASS by itself). A PASS whose head turns red on a check master fails too is re-run once,
# then waits as a master defect without a demotion; once master passes the check again the gateway updates the branch and merges the new head.
$CiRuleOwnerScenarios = [ordered]@{}
$CiRuleOwnerScenarios['ci rule (gateway merge): a PASS whose head is red on a defect of master waits without a demotion, and is merged once master is fixed [full]'] = {
    Fake 'config' @{ rerunSeconds = 3; rerunConclusion = 'failure' } | Out-Null
    $shard = 'Acceptance Tests [shard 4/6]'
    Fake 'base-history' @{ name = $shard; conclusions = @('failure', 'success', 'success') } | Out-Null
    $x = Pm-ToValidation
    # the checks of the head run for an hour, so the PASS is not merged in the verdict call; then they end red on the shard
    Fake 'pr' @{ number = $x.pr; delaySeconds = 3600 } | Out-Null
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Ci-SetHead (Get-Head $x.pr) @($shard) 9301
    Check 'the gateway re-runs the failed jobs once before deciding' (Wait-Until -Seconds 60 { (Ci-Comments $x.n '*re-running the failed jobs once*before deciding*').Count -eq 1 }) (((Get-FakeIssue $x.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(160, $_.body.Length)) }) -join ' | ')
    Check 'still red after it: reported once as a defect of master, the merge waits (master-defect)' (Wait-Until -Seconds 60 { (Ci-Comments $x.n '*a defect of master, not of this change*').Count -eq 1 -and (Ci-Comments $x.n '*master-defect*plant event=merge-waiting*').Count -eq 1 }) (((Get-FakeIssue $x.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(200, $_.body.Length)) }) -join ' | ')
    Start-Sleep -Seconds 6
    $st = Ci-State $x.n
    Check 'no demotion: the item stays in Functional Testing with its PASS unmerged' ((Get-FakeIssue $x.n).column -eq 'Functional Testing' -and -not $st.Contains('demotions') -and -not (Get-FakePr $x.pr).merged -and (Ci-Comments $x.n '*a defect of master, not of this change*').Count -eq 1) ($st | ConvertTo-Json -Compress -Depth 5)
    # master is fixed: the gateway merges master into the branch; the new head's checks (made green here) decide
    Fake 'base-history' @{ name = $shard; conclusions = @('success', 'failure', 'success') } | Out-Null
    Check 'the gateway merges master into the branch' (Wait-Until -Seconds 60 { (Ci-Comments $x.n '*again: the gateway merged master into the branch*').Count -eq 1 }) (((Get-FakeIssue $x.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(160, $_.body.Length)) }) -join ' | ')
    Fake 'pr' @{ number = $x.pr; delaySeconds = 0 } | Out-Null
    Check 'the new head is merged by the gateway, with no demotion' (Wait-Until -Seconds 60 { (Get-FakePr $x.pr).merged }) "column $((Get-FakeIssue $x.n).column)"
    Check 'never demoted' (-not (Ci-State $x.n).Contains('demotions'))
}
$CiRuleOwnerScenarios['ci rule (gateway merge): a PASS whose head is red for a reason of its own is re-run once, then demoted as before [full]'] = {
    Fake 'config' @{ rerunSeconds = 3; rerunConclusion = 'failure' } | Out-Null
    $x = Pm-ToValidation
    Fake 'pr' @{ number = $x.pr; delaySeconds = 3600 } | Out-Null
    $v = Do-Verdict $x.n $x.pr; CheckExit 'the PASS verdict' $v 0
    Ci-SetHead (Get-Head $x.pr) @('Integration Build (SQLite)') 9401
    Check 'the failed jobs are re-run once before deciding' (Wait-Until -Seconds 60 { (Ci-Comments $x.n '*re-running the failed jobs once*before deciding*').Count -eq 1 })
    Check 'still red after it, with master passing that check: demoted to Development as before' (Wait-Until -Seconds 60 { (Get-FakeIssue $x.n).column -eq 'Development' -and [int](Ci-State $x.n)['demotions'] -eq 1 }) "column $((Get-FakeIssue $x.n).column)"
    Check 'the demotion says it was still red after the re-run; nothing was merged' ((Ci-Comments $x.n '*merge failed*still red after one re-run*').Count -eq 1 -and -not (Get-FakePr $x.pr).merged) (((Get-FakeIssue $x.n).comments | ForEach-Object { $_.body.Substring(0, [Math]::Min(200, $_.body.Length)) }) -join ' | ')
}
