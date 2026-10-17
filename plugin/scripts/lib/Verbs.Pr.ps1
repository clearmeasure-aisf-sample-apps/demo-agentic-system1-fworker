# Verbs on pull requests and the validation flow: open-pr, update-pr, pr-checks, wait-for-checks, validation-verdict.
# The merge verb is in Verbs.Merge.ps1.

# The body of an item's pull request as the gateway writes it, for open-pr and update-pr alike: the worker's text, then the reference to the item.
function Get-PrBodyText([string]$Body, [int]$Item) {
    $t = "$Body".TrimEnd(); $ref = "Refs #$Item"
    if ($t -match "(^|\n)$([regex]::Escape($ref))\s*$") { return $t }
    return "$t`n`n$ref"
}

# ---- push gate after repeated red checks -------------------------------------------------------------------------------
# Every head of an item's pull request whose checks went red is counted once (state checks_red). From timing.redChecksGate (2) red heads on,
# open-pr and update-pr are refused until the session attests with private-build --attest <sha> that the private build passed on the head of the
# branch; an item that owes no private build (docs-only, Get-BuildOwed) is not gated. A red check alone on one platform that the base branch fails
# too (likelyPreexisting) is not counted at first: wait-for-checks reruns its job once.
function Get-RedChecksGate { $t = (Get-Cfg).timing; if (Test-Has $t 'redChecksGate') { [int]$t.redChecksGate } else { 2 } }
function Get-ChecksRedCount($s) { if ((Test-Has $s 'checks_red') -and (Test-Has $s.checks_red 'count')) { [int]$s.checks_red.count } else { 0 } }

# counts a red head once; true when it was not counted before
function Add-ChecksRed($s, [string]$Sha) {
    if (-not $Sha) { return $false }
    if (-not (Test-Has $s 'checks_red')) { $s.checks_red = @{ count = 0; shas = @() } }
    $shas = @($s.checks_red.shas | Where-Object { $_ })
    if ($shas -contains $Sha) { return $false }
    $s.checks_red.shas = @(@($shas + $Sha) | Select-Object -Last 10); $s.checks_red.count = (Get-ChecksRedCount $s) + 1; $s.checks_red.last_at = ConvertTo-Iso (Get-UtcNow)
    return $true
}

# for a verb that holds no item lock (wait-for-checks): counted under the lock on a fresh read
function Save-ChecksRed([int]$n, [string]$Sha) {
    Use-ItemLock $n { $st = Get-State $n; if (Add-ChecksRed $st.state $Sha) { Save-State $n $st } }
}

# $HeadSha: the head the pull request has (or would have); empty for a pull request not yet created, where an attestation newer than the last red
# head is enough (the head of a branch that is not a pull request is not read)
function Assert-PushGate([int]$n, $info, $s, [string]$HeadSha, $PrNumber) {
    $limit = Get-RedChecksGate; $count = Get-ChecksRedCount $s
    if ($limit -le 0 -or $count -lt $limit) { return }
    if (Test-Has $s 'private_build') {
        $pb = $s.private_build
        if ($HeadSha -and "$($pb.sha)" -eq $HeadSha) { return }
        if (-not $HeadSha -and (ConvertFrom-Iso $pb.at) -ge (ConvertFrom-Iso $s.checks_red.last_at)) { return }
    }
    if ($PrNumber) { $bo = Get-BuildOwed $info ([int]$PrNumber) $s; if (-not $bo.build_owed) { return } }
    $shown = if ($HeadSha) { $HeadSha.Substring(0, [Math]::Min(7, $HeadSha.Length)) } else { 'the head of the branch' }
    Reject 10 'private-build-required' "the checks of this item's pull request went red on $count heads: run the private build on $shown until it passes, then record it with private-build --item $n --attest <full sha of that commit>, and call this again. No push without a passing private build." @{ checks_red = $count; head_sha = $HeadSha; gate = $limit }
}

# private-build --attest SHA: the session states that the private build passed on that commit. Recorded in the item's state for the push gate.
function Verb_private_build($a) {
    $n = Get-ItemNumber $a
    $sha = "$(Need $a 'attest')".Trim().ToLowerInvariant()
    if ($sha -notmatch '^[0-9a-f]{40}$') { Reject 2 'usage' 'attest takes the full 40-character sha of the commit the private build passed on' }
    $info = Get-ItemInfo $n; Assert-Open $info
    $holder = if (Test-Has $a 'holder') { "$($a.holder)" } else { 'anonymous' }
    $st = Get-State $n; $s = $st.state
    $s.private_build = @{ sha = $sha; at = ConvertTo-Iso (Get-UtcNow); holder = $holder }
    Save-State $n $st
    return @{ ok = $true; id = $n; attested = $true; sha = $sha; checks_red = (Get-ChecksRedCount $s); gate = (Get-RedChecksGate) }
}

# update-pr: replaces the body of the item's own open pull request (a worker corrects what open-pr wrote; nothing else of the pull request changes).
# The pull request is the open one on the item's branch; --pr may name it, and any other number is refused.
function Verb_update_pr($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    $body = "$(Need $a 'body')"; if (-not $body.Trim()) { Reject 2 'usage' 'missing argument: body' }
    $info = Get-ItemInfo $n; Assert-Open $info
    # only while the item is in Development, the owner's column: after that the pull request has been read and approved as it is
    if ("$($info.column)" -ine "$($c.columns.development)") { Reject 10 'wrong-column' "the body of the pull request is changed only while the item is in '$($c.columns.development)'; it is in '$($info.column)'" }
    $own = Find-ItemPr $n
    if ($own -and $own.head.ref -notmatch "^$([regex]::Escape($c.name))/$n-") { $own = $null }
    if (Test-Has $a 'pr') {
        $want = [int]$a.pr
        if (-not $own -or [int]$own.number -ne $want) {
            $p = try { Get-Pr $want } catch [FactoryReject] { $null }
            if ($p -and "$($p.head.ref)" -match "^$([regex]::Escape($c.name))/$n-") { Reject 10 'pr-not-open' "pull request #$want of this item is $(if ($p.merged) { 'merged' } else { "$($p.state)" }); only an open pull request is changed" }
            Reject 10 'pr-not-own' "pull request #$want is not the pull request of item #$n"
        }
    }
    if (-not $own) {
        $s = (Get-State $n).state
        if ((Test-Has $s 'pr') -and (Test-Has $s.pr 'number')) { Reject 10 'pr-not-open' "pull request #$($s.pr.number) of this item is no longer open; only an open pull request is changed" }
        Reject 10 'no-open-pr' 'no open pull request linked to this work item'
    }
    Assert-PushGate $n $info (Get-State $n).state "$($own.head.sha)" $own.number
    $r = Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/pulls/$($own.number)" -Body @{ body = (Get-PrBodyText $body $n) }
    return @{ ok = $true; id = $n; updated = $true; pullRequest = @{ number = $own.number; url = $own.html_url; head_sha = $own.head.sha; branch = $own.head.ref } }
}

function Verb_open_pr($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    $head = "$(Need $a 'head')"; $title = "$(Need $a 'title')"
    $info = Get-ItemInfo $n; Assert-Open $info
    if ($info.column -ine $c.columns.development) { Reject 10 'wrong-column' "pull requests are opened from '$($c.columns.development)'; the item is in '$($info.column)'" }
    if ($head -notmatch "^$([regex]::Escape($c.name))/$n-") { Reject 10 'bad-branch-name' "the branch must be named '$($c.name)/$n-<something>' so the pull request belongs to the item" }
    if ($title -notmatch "(^|[^0-9])#$n([^0-9]|$)") { $title = "$title (#$n)" }
    $base = if (Test-Has $a 'base') { "$($a.base)" } else { $c.defaultBranch }
    $body = if (Test-Has $a 'body') { "$($a.body)" } else { '' }
    $existing = Find-ItemPr $n
    $gs = (Get-State $n).state
    if ($existing -and $existing.head.ref -eq $head) {
        Assert-PushGate $n $info $gs "$($existing.head.sha)" $existing.number
        $bo = Get-BuildOwed $info $existing.number $gs
        return @{ ok = $true; id = $n; created = $false; pullRequest = @{ number = $existing.number; url = $existing.html_url; head_sha = $existing.head.sha; branch = $head }; build_owed = $bo.build_owed; build_reason = $bo.build_reason }
    }
    Assert-PushGate $n $info $gs '' $null
    $r = Invoke-Gh -Method POST -Path "$(Get-RepoPath)/pulls" -Allow 422 -Body @{ title = $title; head = $head; base = $base; body = (Get-PrBodyText $body $n); draft = $false }
    if ($r -is [hashtable] -and $r.ContainsKey('status')) {
        $msg = try { ($r.body.errors | ForEach-Object { $_.message }) -join '; ' } catch { '' }
        Reject 10 'pr-not-created' "GitHub refused to create the pull request: $($r.body.message) $msg. This usually means '$head' has no commits ahead of '$base' or was not pushed. Do not push an empty commit; if the item is already satisfied, report complete with succeeded=false." @{ detail = $msg }
    }
    $st = Get-State $n; $st.state.pr = @{ number = $r.number; branch = $head; url = $r.html_url }; Save-State $n $st
    $bo = Get-BuildOwed $info ([int]$r.number) $st.state
    return @{ ok = $true; id = $n; created = $true; pullRequest = @{ number = $r.number; url = $r.html_url; head_sha = $r.head.sha; branch = $head }; build_owed = $bo.build_owed; build_reason = $bo.build_reason }
}

# pr-checks: the status of the checks of a head and, for every failed or cancelled check, why it failed and whether the base branch fails it
# too (lib/Checks.ps1). Read-only.
#   --item N | --pr P | --sha S   which head (a call that names an item reads that item's pull request only)
#   --check NAME                  one check only, with its detail whatever its conclusion
#   --tail N                      lines of each failed step in the log excerpt (default 200, at most 5000; the excerpt stays inside the budget)
#   --brief                       the status only, as before: no detail, no extra GitHub calls
#   --full-log [--check NAME] [--page N]            one page of the whole log of one job (the client's --save FILE writes every page to a file)
#   --artifact NAME [--entry PATH] [--page N]       the files of an artifact of the failed run, or one page of a text file in it
# The status fields and the exit code are what they always were, whatever happens while the detail is collected: a failure there becomes
# detail = { available: false } in the answer. Only a wrong argument (exit 2) or an unknown check name (exit 12) of the call itself is refused.
function Verb_pr_checks($a, [int]$DetailSeconds = 60) {
    $t = Resolve-ChecksTarget $a
    $chk = Get-ChecksFor $t.sha
    if ((Test-Has $a 'full_log') -and "$($a.full_log)" -ne 'False') { return Get-FullLogPage $chk $a $t.sha }
    if (Test-Has $a 'artifact') { return Get-ArtifactPage $chk $a $t.sha }
    $pub = Get-PublicChecks $chk; $pub.ok = $true; $pub.sha = $t.sha
    if ((Test-Has $a 'brief') -and "$($a.brief)" -ne 'False') { return $pub }
    try { Add-CheckDetail $pub $chk $t $a $DetailSeconds }
    catch [FactoryReject] { if ($_.Exception.Exit -in 2, 12) { throw }; $pub.detail = @{ available = $false; code = 'detail-failed'; reason = "the detail of the checks could not be collected ($($_.Exception.Code)); the status above is complete" } }
    catch { $pub.detail = @{ available = $false; code = 'detail-failed'; reason = 'the detail of the checks could not be collected; the status above is complete' } }
    return $pub
}

function Verb_wait_for_checks($a) {
    $cap = if (Test-Has $a 'timeoutSeconds') { [Math]::Min([int]$a.timeoutSeconds, 100) } else { 60 }
    $end = (Get-Date).AddSeconds($cap)
    # the polls ask for the status only; the detail (logs, annotations, baseline) is read once, when the checks are red
    $poll = @{}; foreach ($k in $a.Keys) { if ($k -notin 'full_log', 'artifact', 'entry', 'page', 'check') { $poll[$k] = $a[$k] } }; $poll.brief = $true
    do {
        $r = Verb_pr_checks $poll
        if ($r.status -eq 'success') { return $r }
        if ($r.status -eq 'failure') {
            $poll.Remove('brief'); $poll.Remove('tail')   # (a wrong --tail must not change this answer)
            $d = try { Verb_pr_checks $poll 25 } catch { $r }   # 25 s: the gateway ends this verb 40 s after the longest wait
            if (Test-Has $a 'item') {
                $n = [int]$a.item
                if (Invoke-PreexistingRerun $n $r $d) { Reject 21 'rerun-started' "the one failed check ($(@($r.failed_checks) -join ', ')) fails on the base branch too (likelyPreexisting): the gateway reran its job once. Call wait-for-checks again." @{ checks = $d } }
                Save-ChecksRed $n "$($r.sha)"
            }
            Reject 10 'checks-red' "checks failed: $($r.failed_checks -join ', '). 'checks' holds, per failed check, its log excerpt or annotations (data.*) and its baseline on the base branch (likelyPreexisting)." @{ checks = $d }
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $end)
    Reject 21 'still-pending' 'checks are still running; call again' @{ checks = $r }
}

# One failed check, red on the base branch as well, an Actions job: its job is rerun once per head (state preexisting_reruns). True when the rerun
# was started; a rerun GitHub refuses (no Actions write permission, a run still going) leaves the red as it is.
function Invoke-PreexistingRerun([int]$n, $r, $d) {
    $failed = @($r.failed_checks | Where-Object { $_ })
    if ($failed.Count -ne 1 -or -not "$($r.sha)") { return $false }
    $ck = @(@($d.checks) | Where-Object { $_ -and "$($_.name)" -eq "$($failed[0])" }) | Select-Object -First 1
    if (-not $ck -or -not $ck.likelyPreexisting -or -not $ck.job -or -not $ck.job.available -or -not $ck.job.id) { return $false }
    return [bool](Use-ItemLock $n {
        $st = Get-State $n; $s = $st.state
        $done = @(if (Test-Has $s 'preexisting_reruns') { $s.preexisting_reruns | Where-Object { $_ } })
        if ($done -contains "$($r.sha)") { return $false }
        $x = Invoke-Gh -Method POST -Path "$(Get-RepoPath)/actions/jobs/$($ck.job.id)/rerun" -Allow 403, 404, 409, 422
        if ($x -is [hashtable] -and $x.ContainsKey('status') -and $x.status -in 403, 404, 409, 422) { return $false }
        $s.preexisting_reruns = @(@($done + "$($r.sha)") | Select-Object -Last 10); Save-State $n $st
        return $true
    })
}

function Invoke-Demote([int]$n, $info, $st, [string]$Reason, [string]$Cause) {
    $s = $st.state; $c = Get-Cfg
    $d = if (Test-Has $s 'demotions') { [int]$s.demotions } else { 0 }
    $s.demotions = $d + 1
    $owned = Test-OwnedClaim $s
    $s.Remove('verdict'); $s.Remove('bot')
    if (-not $owned -or $s.demotions -gt [int]$c.timing.maxDemotions) { $s.Remove('claim'); Remove-ClaimRef $n }
    if ($s.demotions -gt [int]$c.timing.maxDemotions) {
        Set-Park $s $(if ($Cause -eq 'verdict') { 'verdict-failed' } else { 'demotion-limit' }) ($c.timing.parkHours * 60)
        Save-State $n $st
        Add-Comment $n "failed $($s.demotions) time(s), over the demotion limit of $($c.timing.maxDemotions); parked for human review: $Reason"
        return @{ outcome = 'parked'; reason = $s.park.reason }
    }
    Move-Card $info $c.columns.development
    if (-not (Test-Has $s 'pr')) { $s.pr = @{} }
    $s.pr.rejection = $Reason
    if ($owned) { Move-OwnerTo $n $s $c.columns.development } else { $s.handoff = @{ column = $c.columns.development; at = ConvertTo-Iso (Get-UtcNow) } }
    Save-State $n $st
    Add-Comment $n "$(if ($Cause -eq 'verdict') {'validation FAILED'} else {'merge failed'}): $Reason - demoting to **Development** (round-trip $($s.demotions) of $($c.timing.maxDemotions))."
    return @{ outcome = 'demoted'; reason = $Reason; round_trip = $s.demotions }
}

# The demo video of a `video` item (issue #42). Called only by the gateway's POST /api/v1/demo/{item}, which has streamed the MP4 to a temp file,
# checked its size and its header, and authorized the caller. Creates release demo-<n> if missing (pre-release, on the default branch, the shape
# of the demo releases a person published) and uploads the asset demo-<n>.mp4, replacing one of that name. Idempotent.
function Verb_publish_demo($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    $file = "$(Need $a 'file')"
    $tmpRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $full = [IO.Path]::GetFullPath($file)
    if (-not $full.StartsWith($tmpRoot, [StringComparison]::Ordinal) -or [IO.Path]::GetFileName($full) -notmatch "^demo-$n-[0-9a-f]{32}\.mp4$" -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Reject 2 'use-endpoint' 'send the MP4 as the body of POST /api/v1/demo/{item} (client: factory.ps1 publish-demo --item N --file F)'
    }
    $info = Get-ItemInfo $n; Assert-Open $info
    if (-not (Test-Label $info $c.videoLabel)) { Reject 10 'not-video-item' "item #$n does not carry the '$($c.videoLabel)' label: it owes no demo video" }
    if ($info.column -notin @($c.columns.development, $c.columns.validation)) { Reject 10 'wrong-column' "item is in '$($info.column)'; a demo video is published in $($c.columns.development) or $($c.columns.validation)" }
    $st = Get-State $n; $s = $st.state
    $holder = if (Test-Has $a 'holder') { "$($a.holder)" } else { 'anonymous' }
    if ((Test-Has $s 'claim') -and (Test-ClaimLive $s) -and $s.claim.holder -ne $holder -and $holder -ne 'anonymous') { Reject 40 'claim-held' "the claim is held by $($s.claim.holder)" }
    $tag = "demo-$n"; $assetName = "demo-$n.mp4"
    $rel = Invoke-Gh -Path "$(Get-RepoPath)/releases/tags/$tag" -Allow 404
    $created = $false
    if ($rel -is [hashtable] -and $rel.status -eq 404) {
        $r = Invoke-GhRaw -Method POST -Path "$(Get-RepoPath)/releases" -Body @{ tag_name = $tag; target_commitish = $c.defaultBranch; name = "Demo video for #$n"
            body = "Functional Validation demo media for #$n (published by the factory worker gateway)."; prerelease = $true; draft = $false }
        if ($r.status -eq 201) { $rel = $r.body; $created = $true }
        elseif ($r.status -eq 422) { $rel = Invoke-Gh -Path "$(Get-RepoPath)/releases/tags/$tag" }   # created at the same moment by another call
        else { Reject 20 'github-error' "GitHub $($r.status) creating release $tag" @{ retryAfterSeconds = 30 } }
    }
    $replaced = $false
    foreach ($old in @($rel.assets | Where-Object { $_ -and $_.name -eq $assetName })) {
        Invoke-Gh -Method DELETE -Path "$(Get-RepoPath)/releases/assets/$($old.id)" -Allow 404 | Out-Null; $replaced = $true
    }
    $up = ("$($rel.upload_url)" -replace '\{.*$', '') + "?name=$assetName"
    $h = @{ Authorization = "Bearer $(Get-GhToken)"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'factory-worker-gateway' }
    $sc = 0; $asset = $null
    for ($try = 1; $try -le 2; $try++) {
        try { $asset = Invoke-RestMethod -Uri $up -Method POST -Headers $h -ContentType 'video/mp4' -InFile $full -SkipHttpErrorCheck -StatusCodeVariable 'sc' -OperationTimeoutSeconds 480 -ConnectionTimeoutSeconds 30 }
        catch { if ($try -ge 2) { Reject 20 'upload-failed' "the upload to GitHub did not finish: $($_.Exception.Message)" @{ retryAfterSeconds = 60 } }; continue }
        if ($sc -eq 201) { break }
        if ($try -ge 2 -or $sc -notin 502, 503, 504) { Reject 20 'upload-failed' "GitHub $sc on the asset upload" @{ retryAfterSeconds = 60 } }
    }
    Add-Comment $n "demo video $(if ($replaced) {'replaced'} else {'published'}): [$assetName]($($asset.browser_download_url)) on release [$tag]($($rel.html_url)) ($([Math]::Round([double]$asset.size / 1MB, 1)) MB)."
    return @{ ok = $true; id = $n; release = $tag; release_url = "$($rel.html_url)"; asset = $assetName; asset_url = "$($asset.browser_download_url)"; size = [long]$asset.size; created = $created; replaced = $replaced }
}

function Verb_validation_verdict($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    if (-not (Test-Has $a 'passed') -or -not (Test-Has $a 'summary') -or "$($a.summary)".Trim() -eq '') {
        Reject 2 'verdict-fields' 'the body must hold "passed": true or false and "summary": a one-paragraph verdict. Nothing was recorded.'
    }
    $passed = "$($a.passed)" -ieq 'true'
    $summary = "$($a.summary)".Trim()
    $pr = if (Test-Has $a 'pr') { [int]$a.pr } else { 0 }
    $info = Get-ItemInfo $n; Assert-Open $info
    if ($info.column -ine $c.columns.validation) { Reject 10 'wrong-column' "item is in '$($info.column)'" }
    if ($passed -and $pr -le 0) { Reject 2 'pass-requires-prNumber' 'a PASS verdict requires a valid prNumber' }
    $st = Get-State $n; $s = $st.state
    $holder = if (Test-Has $a 'holder') { "$($a.holder)" } else { 'anonymous' }
    if ((Test-Has $s 'claim') -and (Test-ClaimLive $s) -and $s.claim.holder -ne $holder) { Reject 40 'claim-held' "the claim is held by $($s.claim.holder)" }
    if ($passed) {
        $ref = if (Test-Has $a 'review_ref') { "$($a.review_ref)" } else { '' }
        $rv = if ((Test-Has $s 'reviews') -and (Test-Has $s.reviews $info.column)) { $s.reviews[$info.column] } else { $null }
        if (-not $rv -or -not $rv.ref -or $rv.ref -ne $ref) { Reject 10 'review-ref-invalid' 'a PASS needs a recorded REVIEW: COMPLETE (record-review) and its review_ref' }
    }
    $downgraded = $false
    if ($passed -and (Test-Label $info $c.videoLabel)) {
        $rel = Invoke-Gh -Path "$(Get-RepoPath)/releases/tags/demo-$n" -Allow 404
        $hasMp4 = ($rel -isnot [hashtable]) -and @($rel.assets | Where-Object { $_.name -like '*.mp4' }).Count -gt 0
        if (-not $hasMp4) {
            $passed = $false; $downgraded = $true
            $summary += " FACTORY GATE: this item carries the '$($c.videoLabel)' label, but no MP4 is published on the 'demo-$n' release. PASS downgraded to FAIL."
        }
    }
    $headSha = ''; if ($pr -gt 0) { try { $headSha = (Get-Pr $pr).head.sha } catch { } }
    # the head the validator tested (--head-sha): a PASS for another head than the current one is refused; without it (older skills) the head
    # read here is recorded, and a head that could not be read leaves the verdict without one, which the gateway never merges
    if ($passed -and (Test-Has $a 'head_sha') -and "$($a.head_sha)") {
        if (-not $headSha -or "$($a.head_sha)" -ne $headSha) { Reject 10 'head-mismatch' "the PASS was given for $("$($a.head_sha)".Substring(0, [Math]::Min(7, "$($a.head_sha)".Length))), but the head of PR #$pr is $(if ($headSha) { $headSha.Substring(0,7) } else { 'unknown' }); test the current head. Nothing was recorded." }
    }
    $s.verdict = @{ passed = $passed; pr = $pr; head_sha = $headSha; summary = $summary; at = ConvertTo-Iso (Get-UtcNow); round = $(if (Test-Has $s 'demotions') { [int]$s.demotions } else { 0 }); processed = $false }
    Add-Comment $n "validation verdict for **$($info.column)**: $(if ($passed) {'PASS'} else {'FAIL'}) - $summary"
    $res = @{ ok = $true; id = $n; recorded = $true; passed = $passed; downgraded = $downgraded; column = $info.column }
    if (-not $passed) {
        $s.verdict.processed = $true
        # escalate earlier (enhancement 10): two consecutive FAIL verdicts that cite the same acceptance criterion park the item with a question
        $repeated = @(Test-RepeatedCriteria $s 'verdict' @(Get-CitedCriteria $info $summary))
        if ($repeated.Count -gt 0) {
            Invoke-ParkRepeatedCriterion $n $st 'FAIL verdicts' $repeated
            $res.next = 'parked'; $res.reason = 'same-criterion-repeated'; $res.criteria = $repeated
            return $res
        }
        if ($pr -gt 0) {
            $prd = try { Get-Pr $pr } catch { $null }
            $cause = if ($prd -and $prd.merged) { "PR #$pr already merged as $($prd.merge_commit_sha) - residual gaps only (open a NEW branch from master): $summary" } else { $summary }
            # (a merge that a FAIL verdict judged is not picked up by the sweep as a finished change: the gaps are still to be closed)
            if ($prd -and $prd.merged) { if (-not (Test-Has $s 'pr')) { $s.pr = @{} }; $s.pr.residual = $true }
            $d = Invoke-Demote $n $info $st $cause 'verdict'
            # auto-unpark (Verbs.Sweep.ps1): the head this park judged, so the sweep can lift it once the pull request is green on a newer head
            if ($d.outcome -eq 'parked' -and $prd -and -not $prd.merged -and (Test-Has $s 'park')) { $s.park.pr = $pr; $s.park.head = $(if ($headSha) { "$headSha" } else { "$($prd.head.sha)" }); Save-State $n $st }
            $res.next = $d.outcome; $res.detail = $d
        } else {
            Set-Park $s 'verdict-failed' ($c.timing.parkHours * 60); $s.Remove('claim'); Remove-ClaimRef $n; Save-State $n $st
            Add-Comment $n 'validation FAILED with no pull request to fix; parked for human review.'
            $res.next = 'parked'
        }
        return $res
    }
    [void](Test-RepeatedCriteria $s 'verdict' @() -Clear)
    # Without the Auto Merge label a PASS is parked for a person to merge, except under the QC merge gate (peer-approved): there the item stays on the
    # approval path and the merge verb enforces the QC run and the human approval.
    if (-not (Test-Label $info $c.autoMergeLabel) -and -not (Test-QcGateActive)) {
        $s.verdict.processed = $true
        Set-Park $s 'pass-without-auto-merge' ($c.timing.parkHours * 60); $s.Remove('claim'); Remove-ClaimRef $n; Save-State $n $st
        Add-Comment $n "validation PASSED - awaiting human merge (no '$($c.autoMergeLabel)' label; the worker will not merge)."
        $res.next = 'parked'; return $res
    }
    Save-State $n $st
    $res.next = if ($c.mergePolicy -eq 'auto') { 'merge' } else { 'approve' }
    # The gateway merges an approved change itself (Verbs.Merge.ps1): in this call when nothing stands in the way, otherwise the sweep does it as
    # soon as it can. 'merge' in the answer says what happened; 'next' stays "merge" so the session's one merge call (answered already-merged)
    # still confirms it, and names the new state only when the merge sent the item back or parked it.
    if ($c.mergePolicy -eq 'auto' -and (Test-GatewayMerge) -and (Test-Label $info $c.autoMergeLabel)) {
        $m = try { Verb_merge @{ item = $n; pr = $pr } -Gateway } catch [FactoryReject] { @{ ok = $true; id = $n; outcome = 'waiting'; reason = $_.Exception.Code } }
        $res.merge = $m
        if ($m.outcome -in 'demoted', 'parked') { $res.next = $m.outcome; if (Test-Has $m 'detail') { $res.detail = $m.detail } }
    }
    return $res
}
