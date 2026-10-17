# Tier 1 scenarios for "why did this check fail": the detail and the baseline that pr-checks returns (plugin/scripts/lib/Checks.ps1).
# They join existing suites (run.ps1): the admin-credential ones run in 'auto', the item-token one in 'owner', the supervisor one in 'manager'.
$CkLabels = @('factory worker', 'Auto Merge')
$script:CkSecret = 'ghp_' + ('A' * 30)   # a fixture, composed so the secret scan does not read it as a credential

# An item in Development with an open pull request whose "Build result" check failed.
function New-CkRedPr([string[]]$Files = @('src/App.cs')) {
    $n = New-Item-Fake 'Checks' 'x' $CkLabels; Do-TechnicalDesign $n 'w1' $false
    $pr = Do-Development $n $Files 'w1' 'red'
    return @{ n = $n; pr = $pr; sha = (Get-Head $pr) }
}
function Get-CkCheck($R, [string]$Name) { $c = Pv $R 'checks'; if ($null -eq $c) { return $null }; @($c | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }
# The steps and the log of a job whose step "Build" failed: $Lines build lines, a compiler error on line 5, a credential and a coloured line near the end.
function Get-CkSteps {
    @(@{ name = 'Set up job'; number = 1; conclusion = 'success'; started_at = '2026-01-01T10:00:00Z'; completed_at = '2026-01-01T10:00:05Z' }
      @{ name = 'Build'; number = 2; conclusion = 'failure'; started_at = '2026-01-01T10:00:10Z'; completed_at = '2026-01-01T10:00:40Z' }
      @{ name = 'Post'; number = 3; conclusion = 'success'; started_at = '2026-01-01T10:00:50Z'; completed_at = '2026-01-01T10:00:55Z' })
}
function Get-CkLog([int]$Lines) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("2026-01-01T10:00:01.0000000Z setup line one`n2026-01-01T10:00:02.0000000Z setup line two`n")
    foreach ($i in 1..$Lines) {
        $text = switch ($i) { 5 { 'src/App.cs(10,5): error CS1002: ; expected' } ($Lines - 2) { "$([char]27)[31mred text$([char]27)[0m" } ($Lines - 1) { "pushing with token $($script:CkSecret)" } default { "build line $i." } }
        [void]$sb.Append("2026-01-01T10:00:20.0000000Z $text`n")
    }
    [void]$sb.Append("2026-01-01T10:00:39.0000000Z ##[error]Process completed with exit code 1.`n")
    foreach ($i in 1..6) { [void]$sb.Append("2026-01-01T10:00:5$i.0000000Z post line $i.`n") }
    return $sb.ToString()
}
function Set-CkBuildFailure($T, [int]$Lines = 400) { Fake 'checks' @{ sha = $T.sha; name = 'Build result'; conclusion = 'failure'; steps = (Get-CkSteps); log = (Get-CkLog $Lines) } | Out-Null }
function Set-CkQodana($T) {
    Fake 'checks' @{ sha = $T.sha; name = 'Qodana'; conclusion = 'failure'; app = 'qodana-cloud'; outputTitle = '3 new problems'; outputSummary = "Problems: 3 $([char]27)[1mnew$([char]27)[0m, key $($script:CkSecret)"
        annotations = @(
            @{ path = 'src/Legacy.cs'; start_line = 7; end_line = 7; annotation_level = 'warning'; title = 'RedundantUsing'; message = 'Using directive is not required' }
            @{ path = 'src/App.cs'; start_line = 50; end_line = 51; annotation_level = 'warning'; title = 'InconsistentNaming'; message = 'Name does not match the rule' }
            @{ path = 'src/App.cs'; start_line = 1; end_line = 1; annotation_level = 'failure'; title = 'UnusedVariable'; message = 'Local variable is never used' }) } | Out-Null
}

$CheckScenarios = [ordered]@{

'push gate: after red checks on 2 heads, open-pr and update-pr wait for a private-build attestation' = {
    $t = New-CkRedPr
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'the first head is red' $r 10 'checks-red'
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'the same head asked again' $r 10 'checks-red'
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b1'); CheckExit 'one red head (asked twice) does not gate' $r 0
    $sha2 = (Fake 'push-branch' @{ branch = "factory-worker/$($t.n)-development"; files = @('src/App.cs'); profile = 'red' }).sha
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'the second head is red' $r 10 'checks-red'
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b2'); CheckExit 'update-pr is refused' $r 10 'private-build-required'
    Check 'the refusal names the count and the head' ($r.checks_red -eq 2 -and $r.head_sha -eq $sha2) ($r | ConvertTo-Json -Compress)
    $r = F 'w1' @('open-pr', '--item', $t.n, '--head', "factory-worker/$($t.n)-development", '--title', 'again'); CheckExit 'open-pr is refused' $r 10 'private-build-required'
    $r = F 'w1' @('private-build', '--item', $t.n, '--attest', 'abc'); CheckExit 'an attestation takes a full sha' $r 2 'usage'
    $r = F 'w1' @('private-build', '--item', $t.n, '--attest', ('0' * 40)); CheckExit 'an attestation of another commit is recorded' $r 0
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b3'); CheckExit 'but does not open the gate for this head' $r 10 'private-build-required'
    $r = F 'w1' @('private-build', '--item', $t.n, '--attest', $sha2); CheckExit 'the attestation of the head' $r 0
    Check 'answers the count' ($r.attested -eq $true -and $r.checks_red -eq 2 -and $r.gate -eq 2) ($r | ConvertTo-Json -Compress)
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b4'); CheckExit 'opens the gate for that head' $r 0
    $r = F 'w1' @('open-pr', '--item', $t.n, '--head', "factory-worker/$($t.n)-development", '--title', 'again'); CheckExit 'open-pr as well' $r 0
    Fake 'push-branch' @{ branch = "factory-worker/$($t.n)-development"; files = @('src/App.cs'); profile = 'green' } | Out-Null
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b5'); CheckExit 'a new head needs its own attestation' $r 10 'private-build-required'
}

'push gate: one failed check that the base branch fails too is rerun once by the gateway, and not counted' = {
    $t = New-CkRedPr
    Fake 'base-history' @{ name = 'Build result'; conclusions = @('failure', 'failure', 'success') } | Out-Null
    $before = [int](Get-FakeState).rerunJobs
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'the red is answered as a rerun' $r 21 'rerun-started'
    Check 'the job was rerun once' ([int](Get-FakeState).rerunJobs -eq $before + 1) "$((Get-FakeState).rerunJobs)"
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'the rerun passed' $r 0
    $sha2 = (Fake 'push-branch' @{ branch = "factory-worker/$($t.n)-development"; files = @('src/App.cs'); profile = 'red' }).sha
    Fake 'checks' @{ sha = $sha2; name = 'Other platform'; conclusion = 'failure' } | Out-Null
    $r = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'two failed checks are not rerun' $r 10 'checks-red'
    Check 'no further rerun' ([int](Get-FakeState).rerunJobs -eq $before + 1) "$((Get-FakeState).rerunJobs)"
    $r = F 'w1' @('update-pr', '--item', $t.n, '--body', 'b'); CheckExit 'the rerun head was not counted: one red head, no gate' $r 0
}

'pr-checks: a failed Actions job returns its failed step, the end of its log and the error lines, cleaned and redacted' = {
    $t = New-CkRedPr; Set-CkBuildFailure $t
    $r = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'pr-checks answers' $r 0
    Check 'the status fields are as before' ($r.status -eq 'failure' -and @($r.failed_checks) -contains 'Build result' -and $r.sha -eq $t.sha) ($r | ConvertTo-Json -Compress -Depth 3)
    $c = Get-CkCheck $r 'Build result'; $ok = Get-CkCheck $r 'secret-scan'
    Check 'every check of the head is listed with its conclusion and link' ($c -and $ok -and $c.conclusion -eq 'failure' -and $ok.conclusion -eq 'success' -and "$($c.detailsUrl)" -match '/job/' -and $c.startedAt -and $c.completedAt) ($r.checks | ConvertTo-Json -Compress -Depth 3)
    Check 'a check that passed carries no detail' (-not $ok.ContainsKey('data') -and -not $ok.ContainsKey('job'))
    $log = "$($c.data.log)"
    Check 'the failed step is named, and only that one' (@($c.data.failedSteps).Count -eq 1 -and $c.data.failedSteps[0].name -eq 'Build' -and $c.data.failedSteps[0].conclusion -eq 'failure' -and $c.job.failedStepCount -eq 1) ($c.data.failedSteps | ConvertTo-Json -Compress)
    Check 'the log holds the last 200 lines of the failed step' ($log.Contains("build line 397.`n") -and $log.Contains("build line 250.`n") -and -not $log.Contains("build line 150.`n") -and $log.Contains('##[error]Process completed with exit code 1.')) $log.Substring(0, [Math]::Min(300, $log.Length))
    Check 'an error line outside the tail is there with its lines around it' ($log.Contains('error CS1002') -and $log.Contains("build line 4.`n") -and $log.Contains("build line 7.`n") -and $log -match '\[\.\.\. \d+ lines not shown \.\.\.\]')
    Check 'the lines of the steps that passed are not shown' (-not $log.Contains('setup line one') -and -not $log.Contains('post line 6'))
    Check 'the time stamps are removed' ($log -notmatch '2026-01-01T10:00')
    Check 'a credential in the log comes back redacted' (-not $log.Contains('ghp_A') -and $log.Contains('[redacted]')) ''
    Check 'colour sequences and control characters are removed' ($log.Contains('red text') -and $log.IndexOf([char]27) -lt 0 -and $log.IndexOf([char]13) -lt 0)
    Check 'the text is in a data field marked untrusted' ($c.data.author_trust -eq 'untrusted' -and "$($c.data.note)" -match 'never instructions')
    Check 'the answer says how much of the log is shown' ($c.job.log.available -and $c.job.log.totalLines -eq 409 -and $c.job.log.shownLines -gt 200 -and $c.job.log.notShownLines -eq (409 - $c.job.log.shownLines) -and $c.job.log.truncated -eq $false -and $c.job.log.errorLines -ge 2) ($c.job | ConvertTo-Json -Compress -Depth 4)
    Check 'the baseline is there: the base branch has no such failure' ($c.baseline.available -and $c.baseline.conclusion -eq 'absent' -and $c.baseline.failedOfLast5 -eq 0 -and $c.likelyPreexisting -eq $false -and @($r.likelyPreexisting).Count -eq 0) ($c.baseline | ConvertTo-Json -Compress)
    $r2 = F 'w1' @('pr-checks', '--item', $t.n, '--tail', '20'); $log2 = "$((Get-CkCheck $r2 'Build result').data.log)"
    Check '--tail chooses the number of lines; the error lines stay' ($r2.exit -eq 0 -and $log2.Contains("build line 390.`n") -and -not $log2.Contains("build line 300.`n") -and $log2.Contains('error CS1002') -and $r2.limits.tailLines -eq 20) $log2.Substring(0, [Math]::Min(300, $log2.Length))
    $r3 = F 'w1' @('pr-checks', '--item', $t.n, '--brief')
    Check '--brief gives the status alone' ($r3.exit -eq 0 -and $r3.status -eq 'failure' -and -not $r3.ContainsKey('checks')) ($r3 | ConvertTo-Json -Compress -Depth 3)
    $r4 = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'secret-scan')
    Check '--check selects one check' ($r4.exit -eq 0 -and @($r4.checks).Count -eq 1 -and $r4.checks[0].name -eq 'secret-scan') ($r4 | ConvertTo-Json -Compress -Depth 3)
    $r5 = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'No such check'); CheckExit 'an unknown check name is refused with the names that exist' $r5 12 'check-not-found'
    $w = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'wait-for-checks reports red' $w 10 'checks-red'
    $wc = Get-CkCheck $w.checks 'Build result'
    Check 'and carries the same detail, so no second call is needed' ($wc -and "$($wc.data.log)".Contains('error CS1002') -and $wc.ContainsKey('baseline') -and @($w.checks.failed_checks) -contains 'Build result') ($w | ConvertTo-Json -Compress -Depth 3).Substring(0, 300)
}

'pr-checks: a Qodana-like check returns its annotations, split into those on the change and those elsewhere' = {
    $t = New-CkRedPr; Set-CkQodana $t
    $r = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'Qodana'); CheckExit 'pr-checks answers' $r 0
    $c = Get-CkCheck $r 'Qodana'; $k = $c.annotationCounts
    Check 'it is no Actions job: no job, no log' ($null -eq $c.job -and -not $c.data.ContainsKey('log') -and $c.app -eq 'qodana-cloud')
    Check 'the output title and summary are returned, cleaned and redacted' ($c.data.outputTitle -eq '3 new problems' -and "$($c.data.outputSummary)".StartsWith('Problems: 3 new, key') -and -not "$($c.data.outputSummary)".Contains('ghp_A')) "$($c.data.outputSummary)"
    Check 'the annotations are counted by where they point' ($k.total -eq 3 -and $k.onChangedLines -eq 1 -and $k.onChangedFiles -eq 1 -and $k.elsewhere -eq 1 -and $k.returned -eq 3) ($k | ConvertTo-Json -Compress)
    $a0 = $c.data.annotations[0]; $a2 = $c.data.annotations[2]
    Check 'each annotation has path, line, level and message; the ones on the change come first' ($a0.path -eq 'src/App.cs' -and $a0.line -eq 1 -and $a0.level -eq 'failure' -and $a0.message -eq 'Local variable is never used' -and $a0.where -eq 'changed-line' -and $c.data.annotations[1].where -eq 'changed-file' -and $a2.path -eq 'src/Legacy.cs' -and $a2.where -eq 'elsewhere') ($c.data.annotations | ConvertTo-Json -Compress)
    $r2 = F 'w1' @('pr-checks', '--sha', $t.sha, '--check', 'Qodana'); $k2 = (Get-CkCheck $r2 'Qodana').annotationCounts
    Check 'a call that names only a commit has no diff to compare with, and says so' ($r2.exit -eq 0 -and $k2.total -eq 3 -and -not $k2.ContainsKey('elsewhere') -and "$($k2.diff)" -match 'unknown') ($k2 | ConvertTo-Json -Compress)
    $r3 = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'Qodana', '--full-log'); CheckExit 'a check that is no job has no log to page' $r3 10 'not-an-actions-job'
}

'pr-checks: the baseline tells a check the base branch already fails from one this change broke' = {
    $t = New-CkRedPr; Set-CkBuildFailure $t 30; Set-CkQodana $t
    Fake 'base-history' @{ name = 'Qodana'; app = 'qodana-cloud'; conclusions = @('failure', 'failure', 'success') } | Out-Null
    Fake 'base-history' @{ name = 'Build result'; conclusions = @('success', 'success', 'success', 'failure') } | Out-Null
    $r = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'pr-checks answers' $r 0
    $q = Get-CkCheck $r 'Qodana'; $b = Get-CkCheck $r 'Build result'
    Check 'red on the base branch: likelyPreexisting is true' ($q.likelyPreexisting -eq $true -and $q.baseline.conclusion -eq 'failure' -and $q.baseline.failedOfLast5 -eq 2 -and $q.baseline.ranOfLast5 -eq 3 -and $q.baseline.branch -eq 'master') ($q.baseline | ConvertTo-Json -Compress)
    Check 'green on the base branch: likelyPreexisting is false, an older failure is still counted' ($b.likelyPreexisting -eq $false -and $b.baseline.conclusion -eq 'success' -and $b.baseline.failedOfLast5 -eq 1 -and $b.baseline.ranOfLast5 -eq 4) ($b.baseline | ConvertTo-Json -Compress)
    Check 'the answer names the checks that were red before this change' (@($r.likelyPreexisting).Count -eq 1 -and @($r.likelyPreexisting)[0] -eq 'Qodana') ($r.likelyPreexisting | ConvertTo-Json -Compress)
}

'pr-checks: an oversize log is cut and says so; the whole log is read in pages and saved to a file [full]' = {
    $t = New-CkRedPr
    Fake 'checks' @{ sha = $t.sha; name = 'Build result'; conclusion = 'failure'; logLines = @{ count = 6000; prefix = ('x' * 80) } } | Out-Null
    $r = F 'w1' @('pr-checks', '--item', $t.n, '--tail', '5000'); CheckExit 'pr-checks answers' $r 0
    $c = Get-CkCheck $r 'Build result'; $log = "$($c.data.log)"
    Check 'the excerpt stays inside the budget' ($log.Length -le 60200 -and $log.Length -gt 50000 -and $r.limits.logBudgetChars -eq 60000) "$($log.Length)"
    Check 'the answer says that it was cut and by how much' ($c.job.log.truncated -eq $true -and $c.job.log.cutChars -gt 300000 -and $c.job.log.totalLines -eq 6000 -and $c.job.log.notShownLines -eq 1000 -and $log.StartsWith('[... cut: the first ')) ($c.job.log | ConvertTo-Json -Compress)
    Check 'what is kept is the end of the log' ($log.TrimEnd().EndsWith(' 6000'))
    $p1 = F 'w1' @('pr-checks', '--item', $t.n, '--full-log'); CheckExit 'the first page of the whole log' $p1 0
    $pages = [int]$p1.content.pages
    Check 'a page is bounded and the answer says how many there are' ($pages -ge 10 -and $p1.content.page -eq 1 -and "$($p1.content.text)".Length -eq 48000 -and $p1.content.kind -eq 'job-log' -and $p1.content.author_trust -eq 'untrusted' -and $p1.check -eq 'Build result' -and "$($p1.content.text)" -match ' 1\n') ($p1.content.pages)
    $pl = F 'w1' @('pr-checks', '--item', $t.n, '--full-log', '--page', "$pages")
    Check 'the last page ends the log' ($pl.exit -eq 0 -and "$($pl.content.text)".TrimEnd().EndsWith(' 6000') -and "$($pl.content.text)".Length -le 48000) "$($pl.exit)"
    $po = F 'w1' @('pr-checks', '--item', $t.n, '--full-log', '--page', "$($pages + 1)"); CheckExit 'a page past the end is refused' $po 2 'page-out-of-range'
    $file = Join-Path $script:Work "full-$($t.n).log"
    $s = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'Build result', '--full-log', '--save', $file); CheckExit '--save writes the whole log to a file' $s 0
    $saved = if (Test-Path $file) { @(Get-Content $file) } else { @() }
    Check 'the file holds every line once, and the answer names the file and holds no text' ($saved.Count -eq 6000 -and $saved[0].EndsWith(' 1') -and $saved[5999].EndsWith(' 6000') -and $s.saved -eq $file -and $s.pages -eq $pages -and -not $s.ContainsKey('content')) "$($saved.Count) $($s | ConvertTo-Json -Compress)"
    $s2 = F 'w1' @('pr-checks', '--item', $t.n, '--save', $file); CheckExit '--save without a text to save is a usage error' $s2 2 'usage'
}

'pr-checks: a missing GitHub permission is a clear code in the answer, never an error of the verb [full]' = {
    $t = New-CkRedPr; Set-CkBuildFailure $t 30; Set-CkQodana $t
    $denied = '{"message":"Resource not accessible by integration"}'
    Fake 'fault' @{ match = 'GET .*/actions/jobs/\d+/logs$'; status = 403; count = 20; body = $denied } | Out-Null
    $r = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'pr-checks still answers' $r 0
    $c = Get-CkCheck $r 'Build result'
    Check 'the log is reported as not permitted, with the permission to grant' ($c.job.available -eq $true -and $c.job.log.available -eq $false -and $c.job.log.code -eq 'logs-not-permitted' -and "$($c.job.log.reason)" -match 'Actions: read' -and -not $c.data.ContainsKey('log')) ($c.job | ConvertTo-Json -Compress -Depth 4)
    Check 'what needs no such permission is still there' (@($c.data.failedSteps).Count -eq 1 -and $c.baseline.available -and (Get-CkCheck $r 'Qodana').annotationCounts.total -eq 3)
    $f = F 'w1' @('pr-checks', '--item', $t.n, '--check', 'Build result', '--full-log'); CheckExit 'the whole log is refused with the same code' $f 10 'logs-not-permitted'
    Fake 'fault' @{ match = 'GET .*/actions/jobs/\d+$'; status = 403; count = 20; body = $denied } | Out-Null
    Fake 'fault' @{ match = 'GET .*/check-runs/\d+/annotations'; status = 403; count = 20; body = $denied } | Out-Null
    $r2 = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'with the jobs and the annotations refused as well, pr-checks answers' $r2 0
    $c2 = Get-CkCheck $r2 'Build result'; $q2 = Get-CkCheck $r2 'Qodana'
    Check 'the job is reported as not permitted' ($c2.job.available -eq $false -and $c2.job.code -eq 'logs-not-permitted') ($c2.job | ConvertTo-Json -Compress)
    Check 'the annotations are reported as not permitted' ($q2.annotationCounts.available -eq $false -and $q2.annotationCounts.code -eq 'annotations-not-permitted' -and "$($q2.annotationCounts.reason)" -match 'Checks: read') ($q2.annotationCounts | ConvertTo-Json -Compress)
    Check 'the status of the checks is unchanged by any of it' ($r2.status -eq 'failure' -and @($r2.failed_checks).Count -eq 2)
}

'pr-checks: when the detail cannot be read (GitHub fails or does not answer), the status and the exit code are what they always were [full]' = {
    $t = New-CkRedPr; Set-CkBuildFailure $t 30; Set-CkQodana $t
    $detailCalls = '(commits|pulls/\d+/files|actions/jobs/\d+(/logs)?|actions/runs/\d+/artifacts|check-runs/\d+/annotations)$'
    Fake 'fault' @{ match = "GET \S+/$detailCalls"; status = 500; count = 200 } | Out-Null
    $r = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'GitHub answers 500 to every detail call: pr-checks answers' $r 0
    $c = Get-CkCheck $r 'Build result'
    Check 'the status fields are complete' ($r.status -eq 'failure' -and @($r.failed_checks).Count -eq 2 -and $r.sha -eq $t.sha -and @($r.checks).Count -ge 4) ($r | ConvertTo-Json -Compress -Depth 2)
    Check 'each part of the detail says that it is not available' ($c.baseline.available -eq $false -and $c.job.available -eq $false -and $c.job.code -eq 'github-error' -and $c.likelyPreexisting -eq $false -and (Get-CkCheck $r 'Qodana').annotationCounts.available -eq $false) ($c | ConvertTo-Json -Compress -Depth 3)
    $w = F 'w1' @('wait-for-checks', '--item', $t.n); CheckExit 'wait-for-checks reports red as before' $w 10 'checks-red'
    Check 'with the failed checks named' (@($w.checks.failed_checks) -contains 'Build result') ($w | ConvertTo-Json -Compress -Depth 2)
    Fake 'reset' @{} | Out-Null
    $t = New-CkRedPr; Set-CkBuildFailure $t 30; Set-CkQodana $t
    Fake 'latency' @{ ms = 14000; match = "^GET \S+/$detailCalls\n" } | Out-Null   # longer than one detail call may take
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $w = F 'w1' @('wait-for-checks', '--item', $t.n); $took = $sw.Elapsed.TotalSeconds
    CheckExit 'GitHub does not answer the detail calls: wait-for-checks still reports red' $w 10 'checks-red'
    Check 'inside its time, with the failed checks named' ($took -lt 60 -and @($w.checks.failed_checks).Count -eq 2 -and $w.checks.status -eq 'failure') "$took s $($w | ConvertTo-Json -Compress -Depth 2)"
    $wc = Get-CkCheck $w.checks 'Build result'; $left = @(Pv $w.checks 'detailNotShownFor')
    Check 'what was not collected is said: not available, or named in detailNotShownFor' (($wc -and $wc.ContainsKey('baseline') -and $wc.baseline.available -eq $false) -or $left -contains 'Build result') ($w.checks | ConvertTo-Json -Compress -Depth 3)
    Check 'a check left out for time is named' ($left -contains 'Qodana' -or ((Get-CkCheck $w.checks 'Qodana').annotationCounts.available -eq $false)) ($left -join ',')
    Fake 'latency' @{ ms = 0 } | Out-Null
}

'pr-checks: the artifacts of a failed run are listed, and a text file of one is returned; binary and oversize ones are listed only [full]' = {
    $t = New-CkRedPr; Set-CkBuildFailure $t 30
    Fake 'artifact' @{ runId = 1; name = 'qodana-report'; files = @{ 'results/qodana.sarif.json' = "{`"runs`":[{`"tool`":`"qodana`",`"key`":`"$($script:CkSecret)`"}]}"; 'notes.txt' = 'two files' }; binary = @{ 'shot.png' = [Convert]::ToBase64String([byte[]](137, 80, 78, 71, 0, 1, 2)) } } | Out-Null
    Fake 'artifact' @{ runId = 1; name = 'memory-dump'; files = @{ 'dump.txt' = 'x' }; sizeBytes = 900000000 } | Out-Null
    $r = F 'w1' @('pr-checks', '--item', $t.n); CheckExit 'pr-checks answers' $r 0
    $bc = Get-CkCheck $r 'Build result'; $arts = $bc.artifacts; $alist = @($bc.data.artifacts)
    $rep = @($alist | Where-Object { $_.name -eq 'qodana-report' })[0]; $dump = @($alist | Where-Object { $_.name -eq 'memory-dump' })[0]
    Check 'the artifacts of the run are listed with name and size' ($arts.available -and $arts.total -eq 2 -and $rep.sizeBytes -gt 0 -and $rep.fetchable -eq $true -and $dump.sizeBytes -eq 900000000 -and $dump.fetchable -eq $false) ($alist | ConvertTo-Json -Compress -Depth 4)
    $l = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'qodana-report'); CheckExit 'an artifact with several files lists them' $l 0
    Check 'the files are listed and none is returned' ($l.fileCount -eq 3 -and -not $l.ContainsKey('content') -and $l.data.author_trust -eq 'untrusted' -and $l.data.artifact -eq 'qodana-report' -and @($l.data.files | Where-Object { $_.entry -eq 'shot.png' -and $_.text -eq $false }).Count -eq 1 -and @($l.data.files | Where-Object { $_.entry -eq 'results/qodana.sarif.json' -and $_.text -eq $true }).Count -eq 1) ($l | ConvertTo-Json -Compress -Depth 4)
    $e = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'qodana-report', '--entry', 'results/qodana.sarif.json'); CheckExit 'a text file of the artifact is returned' $e 0
    Check 'as untrusted data, redacted' ($e.content.kind -eq 'artifact-file' -and $e.content.author_trust -eq 'untrusted' -and "$($e.content.text)".Contains('"tool":"qodana"') -and -not "$($e.content.text)".Contains('ghp_A') -and $e.content.pages -eq 1) ($e.content | ConvertTo-Json -Compress)
    $file = Join-Path $script:Work "sarif-$($t.n).json"
    $s = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'qodana-report', '--entry', 'results/qodana.sarif.json', '--save', $file)
    Check '--save writes it to a file' ($s.exit -eq 0 -and (Test-Path $file) -and (Get-Content -Raw $file).Contains('"tool":"qodana"')) ($s | ConvertTo-Json -Compress)
    $b = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'qodana-report', '--entry', 'shot.png'); CheckExit 'a binary file is not returned' $b 10 'artifact-not-text'
    $o = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'memory-dump'); CheckExit 'an oversize artifact is not downloaded' $o 10 'artifact-too-large'
    $x = F 'w1' @('pr-checks', '--item', $t.n, '--artifact', 'no-such'); CheckExit 'an unknown artifact is refused' $x 12 'artifact-not-found'
}

}

$CheckOwnerScenarios = [ordered]@{

'owner: pr-checks with an item token reads the checks of that item''s own pull request and of no other [full]' = {
    # pinned to a session that does not exist, so the plant offers these items to nobody while the verbs are called
    $lab = @('factory worker', 'Auto Merge', 'worker:nobody-here')
    $n = New-Item-Fake 'Checks A' 'x' $lab; $m = New-Item-Fake 'Checks B' 'x' $lab
    Do-TechnicalDesign $n 'w1' $false; $pr = Do-Development $n @('src/A.cs') 'w1' 'red'
    Do-TechnicalDesign $m 'w1' $false; $prM = Do-Development $m @('src/B.cs') 'w1' 'red'
    $headN = Get-Head $pr; $headM = Get-Head $prM
    Fake 'checks' @{ sha = $headM; name = 'Build result'; conclusion = 'failure'; log = "2026-01-01T10:00:20.0000000Z the log of item B`n" } | Out-Null
    $own = Msg-ItemToken $n 'owner' 'alice'; $insp = Msg-ItemToken $n 'inspector' 'alice'
    $call = { param($Tok, $Body) $r0 = Msg-Verb 'pr-checks' $Tok $Body; $j = Msg-Json $r0; $j.status = [int]$r0.StatusCode; $j }
    $r = & $call $own @{ item = $n }
    Check 'the owner''s item token reads its own pull request, with the detail' ($r.status -eq 200 -and $r.exit -eq 0 -and $r.sha -eq $headN -and @($r.checks | Where-Object { $_.name -eq 'Build result' -and $_.ContainsKey('baseline') }).Count -eq 1) ($r | ConvertTo-Json -Compress -Depth 3)
    $r = & $call $own @{ item = $n; pr = $pr; sha = $headN }
    Check 'naming its own pull request and head works as before' ($r.status -eq 200 -and $r.exit -eq 0 -and $r.sha -eq $headN) ($r | ConvertTo-Json -Compress -Depth 2)
    foreach ($case in @(
            @{ name = 'another item''s pull request is refused'; body = @{ item = $n; pr = $prM }; code = 'pr-not-own' }
            @{ name = 'another item''s head commit is refused'; body = @{ item = $n; sha = $headM }; code = 'sha-not-own' }
            @{ name = 'its own pull request with another item''s commit is refused'; body = @{ item = $n; pr = $pr; sha = $headM }; code = 'sha-not-own' }
            @{ name = 'the whole log of another item''s job is refused'; body = @{ item = $n; pr = $prM; check = 'Build result'; full_log = $true }; code = 'pr-not-own' }
            @{ name = 'an artifact of another item''s run is refused'; body = @{ item = $n; sha = $headM; artifact = 'x' }; code = 'sha-not-own' })) {
        $r = & $call $own $case.body
        Check "$($case.name) ($($case.code))" ($r.exit -eq 10 -and $r.code -eq $case.code -and -not $r.ContainsKey('checks') -and -not $r.ContainsKey('content') -and -not ($r | ConvertTo-Json -Compress -Depth 8).Contains('the log of item B')) ($r | ConvertTo-Json -Compress -Depth 3)
    }
    $r = & $call $insp @{ item = $n; pr = $prM }
    Check 'the inspector''s item token is held to its item as well' ($r.exit -eq 10 -and $r.code -eq 'pr-not-own') ($r | ConvertTo-Json -Compress -Depth 3)
    $r = & $call $own @{ item = $m }
    Check 'the token of item A cannot name item B (403)' ($r.status -eq 403 -and -not $r.ContainsKey('checks')) ($r | ConvertTo-Json -Compress -Depth 3)
    $r = F 'w1' @('pr-checks', '--pr', $prM)
    Check 'a call that names no item (the operator) reads any pull request' ($r.exit -eq 0 -and $r.sha -eq $headM -and "$((@($r.checks | Where-Object { $_.name -eq 'Build result' })[0]).data.log)".Contains('the log of item B')) ($r | ConvertTo-Json -Compress -Depth 3)
}

}

# The supervisor's credential passes only item, pr and sha to pr-checks (gateway/Auth.cs keeps those fields and drops the rest): it gets the
# default answer, which holds the detail and the baseline, and cannot ask for one check, another tail, the whole log or an artifact.
$CheckManagerScenarios = [ordered]@{

'mgr: pr-checks gives the supervisor the detail and the baseline of any pull request; the flags it may not send are dropped [full]' = {
    $m1 = Msg-Supervisor
    $n = New-Item-Fake 'Supervised checks' 'x' @('factory worker') 'Development'
    $pr = Do-Development $n @('src/App.cs') 'w1' 'red'; $head = Get-Head $pr
    Fake 'checks' @{ sha = $head; name = 'Build result'; conclusion = 'failure'; steps = (Get-CkSteps); log = (Get-CkLog 30) } | Out-Null
    Fake 'base-history' @{ name = 'Build result'; conclusions = @('failure', 'failure') } | Out-Null
    Mgr-Hold
    $j = Msg-Json (Msg-Verb 'pr-checks' $m1 @{ pr = $pr })
    $c = @(@(Pv $j 'checks') | Where-Object { $_ -and $_.name -eq 'Build result' }) | Select-Object -First 1
    Check 'the supervisor reads a pull request without naming an item' ($j.exit -eq 0 -and $j.sha -eq $head -and $null -ne $c) ($j | ConvertTo-Json -Compress -Depth 3)
    Check 'it gets the log excerpt and the baseline: this check was red before the change' ($c -and "$($c.data.log)".Contains('error CS1002') -and $c.likelyPreexisting -eq $true -and $c.baseline.failedOfLast5 -eq 2) ($c | ConvertTo-Json -Compress -Depth 3)
    $j2 = Msg-Json (Msg-Verb 'pr-checks' $m1 @{ pr = $pr; check = 'Build result'; full_log = $true; brief = $true; tail = 1 })
    Check 'check, tail, brief and full_log are dropped for it: the answer is the default one' ($j2.exit -eq 0 -and -not $j2.ContainsKey('content') -and @(Pv $j2 'checks').Count -ge 3 -and $j2.limits.tailLines -eq 200) ($j2 | ConvertTo-Json -Compress -Depth 2)
}

}
