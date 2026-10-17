# The factory inspector's rules: facts and mandatory escalations computed by script, the approval itself (made as the reviewer App, a different
# identity from the one that authors and merges), and the hold that only a named person can clear. The inspector (a subagent) judges; this decides.

function Get-Prop($o, [string]$n, $d = $null) { if ($null -ne $o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n) { return $o.$n }; return $d }

function Get-InspectFacts([int]$n, $info, $state, $pr) {
    $c = Get-Cfg; $i = $c.inspector
    $files = @(Get-PrFiles $pr.number)
    $lines = 0; foreach ($f in $files) { $lines += [int](Get-Prop $f 'additions' 0) + [int](Get-Prop $f 'deletions' 0) }
    $docs = Test-DocsOnlyFiles $files
    $marker = Test-ItemDocsOnly $state $info
    $chk = Get-ChecksFor $pr.head.sha
    $mand = New-Object System.Collections.ArrayList
    $add = { param($code, $reason, $evidence) [void]$mand.Add(@{ code = $code; reason = $reason; evidence = @($evidence) }) }
    $match = { param($list, $name) foreach ($p in $list) { if ($name -match $p) { return $true } }; return $false }

    $e = @($files | Where-Object { & $match $i.protectedPaths $_.filename } | ForEach-Object { $_.filename })
    if ($e.Count) { & $add 'protected-path' 'the change touches pipeline, build, deployment or repository-control files' $e }
    $e = @($files | Where-Object { & $match $i.packagePaths $_.filename } | ForEach-Object { $_.filename })
    if ($e.Count) { & $add 'package-change' 'project or package files changed; packages and SDK versions need explicit approval' $e }
    $e = @($files | Where-Object { & $match $i.migrationPaths $_.filename } | ForEach-Object { $_.filename })
    if ($e.Count) { & $add 'database-migration' 'a database migration script changed' $e }
    $maxFiles = if ($docs) { [int]$i.docsMaxFiles } else { [int]$i.maxFiles }
    if ($files.Count -gt $maxFiles -or $lines -gt [int]$i.maxLines) { & $add 'too-large' "too large to inspect reliably ($($files.Count) files, $lines lines; limits $maxFiles files, $($i.maxLines) lines)" @("$($files.Count) files", "$lines lines") }
    $e = @($files | Where-Object { $ext = ([IO.Path]::GetExtension($_.filename)).TrimStart('.').ToLowerInvariant(); $ext -and ($i.binaryExtensions -contains $ext) } | ForEach-Object { $_.filename })
    if ($e.Count) { & $add 'binary-file' 'binary files cannot be inspected' $e }
    $e = @()
    foreach ($f in $files) { $patch = "$(Get-Prop $f 'patch' '')"; foreach ($sp in $i.secretPatterns) { if ($patch -match $sp) { $e += "$($f.filename) (pattern $([array]::IndexOf($i.secretPatterns, $sp)))"; break } } }
    if ($e.Count) { & $add 'secret-like' 'a secret-like string appears in the diff' $e }
    $e = @($files | Where-Object { (Get-Prop $_ 'status' '') -eq 'removed' -and $_.filename -match '(?i)test' } | ForEach-Object { $_.filename })
    if ($e.Count) { & $add 'deleted-tests' 'test files were deleted' $e }
    if (($marker -and -not $docs) -or ($docs -and -not $marker)) { & $add 'docs-marker-mismatch' 'the docs-only marker and the files changed disagree' @("marker=$marker", "docsOnlyFiles=$docs") }
    $dem = if (Test-Has $state 'demotions') { [int]$state.demotions } else { 0 }
    if ($dem -ge 2) { & $add 'repeated-demotions' "this item has failed validation or merge $dem times" @("demotions=$dem") }
    $vsha = if ((Test-Has $state 'verdict') -and (Test-Has $state.verdict 'head_sha')) { "$($state.verdict.head_sha)" } else { '' }
    if ($vsha -and $vsha -ne $pr.head.sha) { & $add 'stale-head' 'the branch changed after the validation verdict' @("verdict=$($vsha.Substring(0,7))", "head=$($pr.head.sha.Substring(0,7))") }
    if ($chk.status -ne 'success') { & $add 'checks-not-green' 'required checks are not all successful' (@("status=$($chk.status)") + @($chk.failed_checks) + @($chk.pending_checks)) }
    if (-not (Test-PrBelongs $pr $n)) { & $add 'pr-not-item' 'the pull request does not belong to this work item' @($pr.head.ref) }
    $texts = @($info.title, $info.body, "$($pr.title)", "$(Get-Prop $pr 'body' '')")
    $e = @(); foreach ($t in $texts) { foreach ($p in $i.aiDirectedText) { if ("$t" -match $p) { $e += "matches $([array]::IndexOf($i.aiDirectedText, $p))" } } }
    if ($e.Count) { & $add 'ai-directed-text' 'item or pull request text is addressed to an AI reviewer' ($e | Select-Object -Unique) }

    return @{
        facts = @{ head_sha = $pr.head.sha; branch = $pr.head.ref; author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"; file_count = $files.Count; line_count = $lines
            docs_only_files = $docs; docs_marker = $marker; checks = (Get-PublicChecks $chk); demotions = $dem
            files = @($files | Select-Object -First 50 | ForEach-Object { @{ name = $_.filename; additions = [int](Get-Prop $_ 'additions' 0); deletions = [int](Get-Prop $_ 'deletions' 0); status = "$(Get-Prop $_ 'status' '')" } }) }
        mandatory = @($mand)
    }
}

function Get-VerdictState($n) {
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    if (-not (Test-Has $s 'verdict') -or -not $s.verdict.passed -or $s.verdict.processed) { Reject 10 'no-pass-verdict' 'no unprocessed PASS verdict is recorded for this item' }
    return @{ info = $info; st = $st; s = $s; pr = (Get-Pr ([int]$s.verdict.pr)) }
}

function Verb_inspect_facts($a) {
    $n = Get-ItemNumber $a
    $v = Get-VerdictState $n
    $r = Get-InspectFacts $n $v.info $v.s $v.pr
    return @{ ok = $true; id = $n; facts = $r.facts; mandatory = $r.mandatory; must_escalate = ($r.mandatory.Count -gt 0); item = @{ title = $v.info.title; body = (Remove-DerivedBlocks "$($v.info.body)") } }
}

# Reviews of a pull request, latest state per reviewer.
function Get-LatestReviews($pr) {
    $latest = @{}
    foreach ($r in @(Invoke-Gh -Path "$(Get-RepoPath)/pulls/$($pr.number)/reviews?per_page=100")) { $latest["$($r.user.login)"] = $r }
    return $latest
}

function Find-HumanApproval($pr) {
    $humans = @((Get-Cfg).humanApprovers); $author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"
    if ($humans.Count -eq 0) { return $null }
    $latest = Get-LatestReviews $pr
    foreach ($login in $latest.Keys) {
        $r = $latest[$login]
        if ((Test-NameIn $login $humans) -and $login -ne $author -and $r.state -eq 'APPROVED' -and "$($r.commit_id)" -eq $pr.head.sha) { return $login }
    }
    return $null
}

function Test-GitHubApproval($pr) {
    $latest = Get-LatestReviews $pr
    $allowed = @((Get-AppLogin 'reviewer')) + @((Get-Cfg).humanApprovers)
    foreach ($login in $latest.Keys) { $r = $latest[$login]; if ((Test-NameIn $login $allowed) -and $r.state -eq 'APPROVED' -and "$($r.commit_id)" -eq $pr.head.sha) { return $true } }
    return $false
}

function Invoke-ClearHoldIfApproved([int]$n, $info, $st, $pr) {
    $s = $st.state; $c = Get-Cfg
    $by = Find-HumanApproval $pr
    if (-not $by) { return $false }
    $s.Remove('park'); if (Test-Has $s 'escalation') { $s.Remove('escalation') }
    $s.approval = @{ sha = $pr.head.sha; by = $by; kind = 'human'; at = ConvertTo-Iso (Get-UtcNow) }
    Save-State $n $st
    Invoke-Gh -Method DELETE -Path "$(Get-RepoPath)/issues/$n/labels/$([uri]::EscapeDataString('Needs Human Review'))" -Allow 404 | Out-Null
    Add-Comment $n "hold cleared: $by approved ``$($pr.head.sha.Substring(0,7))``. The merge may proceed."
    return $true
}

function Verb_clear_hold($a) {
    $n = Get-ItemNumber $a; $info = Get-ItemInfo $n; Assert-Open $info
    $st = Get-State $n; $s = $st.state
    if (-not (Test-Has $s 'park') -or $s.park.reason -ne 'inspector-escalated') { Reject 10 'not-held' 'the item is not held by the inspector' }
    $pr = Get-Pr ([int]$s.verdict.pr)
    if (Invoke-ClearHoldIfApproved $n $info $st $pr) { return @{ ok = $true; id = $n; cleared = $true } }
    Reject 10 'no-human-approval' "the hold clears only on an approval of $($pr.head.sha.Substring(0,7)) from one of: $(((Get-Cfg).humanApprovers) -join ', ') (a label change does not clear it)"
}

function Verb_approve_pr($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    $text = "$(Need $a 'text')"
    if ($c.mergePolicy -eq 'auto') { Reject 10 'not-required' "merge policy is 'auto'; no inspection is needed" }
    $v = Get-VerdictState $n; $info = $v.info; $st = $v.st; $s = $v.s; $pr = $v.pr
    if ($info.column -ine $c.columns.validation) { Reject 10 'wrong-column' "approval happens in '$($c.columns.validation)'; the item is in '$($info.column)'" }
    $prNum = if (Test-Has $a 'pr') { [int]$a.pr } else { [int]$s.verdict.pr }
    if ($prNum -ne [int]$s.verdict.pr) { Reject 10 'pr-mismatch' "the verdict names PR #$($s.verdict.pr), not #$prNum" }
    if ((Test-Has $s 'park') -and (Get-Park $s)) { Reject 10 'held' "item is held: $($s.park.reason)" }
    $last = ($text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Last 1)
    $verdict = switch -CaseSensitive -Regex ($last) { '^INSPECTOR: APPROVE$' { 'APPROVE' } '^INSPECTOR: REQUEST CHANGES$' { 'REQUEST CHANGES' } '^INSPECTOR: ESCALATE$' { 'ESCALATE' } default { $null } }
    if (-not $verdict) { Reject 10 'no-verdict-line' 'the last line must be exactly INSPECTOR: APPROVE, INSPECTOR: REQUEST CHANGES or INSPECTOR: ESCALATE' }
    $facts = Get-InspectFacts $n $info $s $pr
    $sha = $pr.head.sha
    $summary = if ($text.Length -gt 1500) { $text.Substring(0, 1500) + ' [truncated]' } else { $text }

    if ($verdict -eq 'APPROVE') {
        if ($facts.mandatory.Count -gt 0) { Reject 10 'escalation-required' 'mandatory escalation reasons exist; the inspector may not approve' @{ mandatory = $facts.mandatory } }
        $reviewer = Get-AppLogin 'reviewer'
        $author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"
        if ($author -and $author -ieq $reviewer) { Reject 10 'approver-is-author' "the approver '$reviewer' authored the pull request" }
        Use-GhAs 'reviewer' { Invoke-Gh -Method POST -Path "$(Get-RepoPath)/pulls/$prNum/reviews" -Body @{ event = 'APPROVE'; commit_id = $sha; body = "Factory inspector approval of $sha.`n`n$summary" } | Out-Null }
        $s.approval = @{ sha = $sha; by = $reviewer; kind = 'inspector'; at = ConvertTo-Iso (Get-UtcNow) }
        if (Test-OwnerMode) { $s.Remove('bot'); Save-State $n $st } else { $s.Remove('claim'); Save-State $n $st; Remove-ClaimRef $n }
        Add-Comment $n "inspector approved PR #$prNum at ``$($sha.Substring(0,7))`` as $reviewer."
        return @{ ok = $true; id = $n; verdict = 'APPROVE'; approved_sha = $sha; by = $reviewer; next = 'merge' }
    }
    if ($verdict -eq 'REQUEST CHANGES') {
        Use-GhAs 'reviewer' { Invoke-Gh -Method POST -Path "$(Get-RepoPath)/pulls/$prNum/reviews" -Body @{ event = 'REQUEST_CHANGES'; commit_id = $sha; body = "Factory inspector requests changes at $sha.`n`n$summary" } -Allow 422 | Out-Null }
        $s.verdict.processed = $true
        $d = Invoke-Demote $n $info $st "inspector requested changes: $summary" 'verdict'
        return @{ ok = $true; id = $n; verdict = 'REQUEST CHANGES'; outcome = $d.outcome; detail = $d }
    }
    # ESCALATE: hold for a person. The script's mandatory reasons are a floor; the inspector's own reasons are in its text.
    Invoke-Gh -Method POST -Path "$(Get-RepoPath)/labels" -Body @{ name = 'Needs Human Review'; color = 'd93f0b'; description = 'The factory inspector holds this pull request for a person' } -Allow 422 | Out-Null
    Invoke-Gh -Method POST -Path "$(Get-RepoPath)/issues/$n/labels" -Body @{ labels = @('Needs Human Review') } | Out-Null
    $s.escalation = @{ sha = $sha; at = ConvertTo-Iso (Get-UtcNow); mandatory = @($facts.mandatory | ForEach-Object { $_.code }) }
    Set-Park $s 'inspector-escalated' ([double]$c.inspector.holdDays * 1440)
    if (Test-OwnerMode) { $s.Remove('bot'); Save-State $n $st } else { $s.Remove('claim'); Save-State $n $st; Remove-ClaimRef $n }
    $mention = if ($c.escalationMention) { "$($c.escalationMention) " } else { '' }
    $why = ($facts.mandatory | ForEach-Object { "- **$($_.code)**: $($_.reason) ($(($_.evidence | Select-Object -First 5) -join ', '))" }) -join "`n"
    Add-Comment $n "${mention}the factory inspector is **holding PR #$prNum** (``$($sha.Substring(0,7))``) for a person.`n`n$(if ($why) { "Mandatory reasons:`n$why`n`n" })Inspector's notes:`n$summary`n`nApprove the pull request on GitHub (from one of: $(($c.humanApprovers) -join ', ')) to release the hold. Removing the label does not."
    return @{ ok = $true; id = $n; verdict = 'ESCALATE'; outcome = 'held'; mandatory = @($facts.mandatory | ForEach-Object { $_.code }) }
}
