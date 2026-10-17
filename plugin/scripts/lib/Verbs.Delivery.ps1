# Delivery: Octopus reads (GET only), release-candidate match, and settle (the post-merge state machine, no model needed).

function Invoke-Octo([string]$Path) {
    if (-not $env:OCTOPUS_API_KEY) { Reject 30 'secret-missing' 'OCTOPUS_API_KEY is not set on the gateway' }
    $o = (Get-Cfg).octopus
    $uri = "$($o.url.TrimEnd('/'))/$($Path.TrimStart('/'))"
    try { Invoke-RestMethod -Uri $uri -Headers @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY; 'User-Agent' = 'factory-worker-gateway' } -TimeoutSec 30 }
    catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 404) { return $null }
        Reject 20 'octopus-error' "Octopus answered $code to GET $Path" @{ retryAfterSeconds = 30 }
    }
}

function Get-ReleaseCommit($Release) {
    $text = "$($Release.ReleaseNotes)"
    $bi = $Release.PSObject.Properties['BuildInformation']
    if ($bi -and $bi.Value) { foreach ($b in $bi.Value) { if ("$($b.VcsCommitNumber)" -match '^[0-9a-fA-F]{40}$') { return $b.VcsCommitNumber.ToLower() } } }
    $m = [regex]::Match($text, '\b[0-9a-fA-F]{40}\b'); if ($m.Success) { return $m.Value.ToLower() }
    return $null
}

function Get-Delivery([string]$Sha) {
    $o = (Get-Cfg).octopus; $sp = $o.space
    $proj = Invoke-Octo "api/$sp/projects/$($o.project)"
    if (-not $proj) { Reject 12 'octopus-project-not-found' "project '$($o.project)' not found in $sp" }
    $rels = @((Invoke-Octo "api/$sp/projects/$($proj.Id)/releases?take=30").Items)
    $cand = $null
    foreach ($r in $rels) { if ((Get-ReleaseCommit $r) -eq $Sha.ToLower()) { $cand = $r; break } }
    if (-not $cand -and $rels.Count -gt 0) {
        $newest = $rels | Sort-Object { [DateTime]$_.Assembled } -Descending | Select-Object -First 1
        $nc = Get-ReleaseCommit $newest
        if ($nc) {
            $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$($Sha)...$nc" -Allow 404, 422
            if ($cmp -isnot [hashtable] -and $cmp.status -in 'ahead', 'identical') { $cand = $newest }
        }
    }
    $res = @{ candidate = $null; deployments = @{}; prod_success = $false }
    if (-not $cand) { return $res }
    $res.candidate = @{ version = $cand.Version; release_id = $cand.Id; commit = (Get-ReleaseCommit $cand); assembled = $cand.Assembled }
    $envs = @{}; foreach ($e in (Invoke-Octo "api/$sp/environments?take=1000").Items) { $envs[$e.Id] = $e.Name }
    $deps = @((Invoke-Octo "api/$sp/deployments?projects=$($proj.Id)&take=30").Items | Where-Object { $_.ReleaseId -eq $cand.Id } | Sort-Object { [DateTime]$_.Created } -Descending)
    foreach ($d in $deps) {
        $name = $envs[$d.EnvironmentId]; if (-not $name -or $res.deployments.ContainsKey($name)) { continue }
        $task = Invoke-Octo "api/$sp/tasks/$($d.TaskId)"
        $res.deployments[$name] = @{ state = "$($task.State)"; completed = [bool]$task.IsCompleted; at = $d.Created; deployment = $d.Id }
    }
    $prodName = $o.environments.prod
    foreach ($k in $res.deployments.Keys) { if ($k -ieq $prodName -and $res.deployments[$k].state -eq 'Success') { $res.prod_success = $true } }
    return $res
}

# The newest releases to prod that contain the change (releases are cumulative on master): used when the item's own release has
# scrolled out of the recent list or was never promoted itself because a later release carried it to prod.
function Get-ProdContaining([string]$Sha) {
    $o = (Get-Cfg).octopus; $sp = $o.space
    $proj = Invoke-Octo "api/$sp/projects/$($o.project)"; if (-not $proj) { return $null }
    $envs = @{}; foreach ($e in (Invoke-Octo "api/$sp/environments?take=1000").Items) { $envs[$e.Id] = $e.Name }
    $prodName = $o.environments.prod
    foreach ($d in @((Invoke-Octo "api/$sp/deployments?projects=$($proj.Id)&take=30").Items)) {
        if (-not $envs[$d.EnvironmentId] -or $envs[$d.EnvironmentId] -ine $prodName) { continue }
        $task = Invoke-Octo "api/$sp/tasks/$($d.TaskId)"; if (-not $task -or "$($task.State)" -ne 'Success') { continue }
        $rel = Invoke-Octo "api/$sp/releases/$($d.ReleaseId)"; if (-not $rel) { continue }
        $c = Get-ReleaseCommit $rel; if (-not $c) { continue }
        if ($c -eq $Sha.ToLower()) { return "$($rel.Version)" }
        $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$($Sha)...$c" -Allow 404, 422
        if ($cmp -isnot [hashtable] -and $cmp.status -in 'ahead', 'identical') { return "$($rel.Version)" }
    }
    return $null
}

function Verb_get_delivery($a) {
    $sha = if (Test-Has $a 'commit') { "$($a.commit)" } else {
        $st = Get-State (Get-ItemNumber $a)
        if (-not (Test-Has $st.state 'merge')) { Reject 10 'not-merged' 'the item has no merge commit yet' }
        $st.state.merge.sha }
    $d = Get-Delivery $sha; $d.ok = $true; $d.commit = $sha
    return $d
}

# Issue 79: why a failure on master looks flaky, for the item's comment: a check named in masterFlakyChecks (patterns), or the same check failed on
# another of the last 5 master commits. Only the wording depends on it; the re-run happens either way. Never throws.
function Get-FlakyReason([string]$Sha, $Failed) {
    $c = Get-Cfg
    $pats = if (Test-Has $c 'masterFlakyChecks') { @($c.masterFlakyChecks) } else { @() }
    $known = @(@($Failed) | Where-Object { $f = "$_"; @($pats | Where-Object { $f -match $_ }).Count -gt 0 })
    if ($known.Count -gt 0) { return "known flaky: $($known -join ', ')" }
    try {
        $elsewhere = @()
        foreach ($cm in @(Invoke-Gh -Path "$(Get-RepoPath)/commits?sha=$($c.defaultBranch)&per_page=6" | Where-Object { $_ -and "$($_.sha)" -ne $Sha } | Select-Object -First 5)) {
            $o = Get-ChecksFor "$($cm.sha)" -Ignore (Get-MasterIgnoredChecks)
            $elsewhere += @(@($Failed) | Where-Object { $o.failed_checks -contains $_ -and $_ -notin $elsewhere })
        }
        if ($elsewhere.Count -gt 0) { return "also failed on a recent master commit: $($elsewhere -join ', ')" }
    } catch { }
    return 'not known to be flaky'
}

# Whether the merged change is documentation only, and from what. First the merge commit's own Build: the jobs in masterCodeChecks run only for a
# code change (build.yml's job "Detect code changes" skips them otherwise), so all of them skipped means no code changed and no release will be
# built. Without those checks, the files of the pull request (docsOnlyPaths). Never the release check: the Release workflow attaches its check runs
# to master's head when it starts, so a merge commit whose Build failed and was re-run keeps the skipped release check of its first attempt
# (items 272 and 276 were moved to Done that way, with code that was never released). $null when neither can be read.
function Get-MergeDocsOnly($m, $Chk) {
    $c = Get-Cfg
    $names = if (Test-Has $c 'masterCodeChecks') { @($c.masterCodeChecks | ForEach-Object { "$_" }) } else { @() }
    $seen = @($names | Where-Object { $Chk.runs.ContainsKey($_) -and "$($Chk.runs[$_].status)" -eq 'completed' } | ForEach-Object { $Chk.runs[$_] })
    if ($seen.Count -gt 0) { return @{ docs_only = (@($seen | Where-Object { "$($_.conclusion)" -ne 'skipped' }).Count -eq 0); from = 'build' } }
    if (Test-Has $m 'pr') { try { return @{ docs_only = [bool](Test-DocsOnlyFiles (Get-PrFiles ([int]$m.pr))); from = 'pr-files' } } catch { } }
    return $null
}

# Issue 114: master is green for a merge when the merge commit's latest attempt is green, or when a later commit of the default branch that
# contains it (compare: ahead or identical) is: a flaky or broken Build of the merge commit itself never turns green, but the next green master
# carries the change all the same. Reads the newest commits first and stops at the first green one, at most timing.masterContainsLookback (10)
# commits after the merge commit. Returns @{ sha; own } of the green commit, or $null.
function Find-GreenMaster([string]$Sha) {
    $c = Get-Cfg; $ign = Get-MasterIgnoredChecks
    if ((Get-ChecksFor $Sha -Ignore $ign).status -eq 'success') { return @{ sha = $Sha; own = $true } }
    $max = if (Test-Has $c.timing 'masterContainsLookback') { [Math]::Max(1, [int]$c.timing.masterContainsLookback) } else { 10 }
    foreach ($cm in @(Invoke-Gh -Path "$(Get-RepoPath)/commits?sha=$($c.defaultBranch)&per_page=$([Math]::Min(100, $max + 1))" | Where-Object { $_ })) {
        $later = "$($cm.sha)"
        if ($later -eq $Sha) { break }   # the merge commit itself: the commits after it in the list are older and cannot contain it
        if ((Get-ChecksFor $later -Ignore $ign).status -ne 'success') { continue }
        $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$($Sha)...$later`?per_page=1" -Allow 404, 422
        if ($cmp -isnot [hashtable] -and "$($cmp.status)" -in 'ahead', 'identical') { return @{ sha = $later; own = $false } }
    }
    return $null
}

# Issue 114: re-arms the settle step of an item that has a merge record but no wait and is not done: an older gateway erased the wait when it parked
# the item master-broken, master-green-timeout or late (262 and 280 were left closed in Functional Testing, 272 and 276 were validated again).
# The wait is set from where the record says the item was; such an item is settled again and never handed to a worker. Works on the state in
# hand, the caller saves it. Returns the wait it set, or '' (no merge record, a wait already set, or done; -Force re-arms a done one too).
function Restore-Settle($s, [switch]$Force) {
    if (-not (Test-Has $s 'merge') -or -not (Test-Has $s.merge 'sha') -or -not $s.merge.sha) { return '' }
    $m = $s.merge
    if ((Test-Has $m 'awaiting') -and $m.awaiting) { return '' }
    if ((Test-Has $m 'done_at') -and $m.done_at) { if (-not $Force) { return '' }; $m.Remove('done_at') }
    $t = (Get-Cfg).timing; $now = Get-UtcNow
    if ((Test-Has $m 'release') -and $m.release) { $m.awaiting = 'release-queue' }
    elseif ((Test-Has $m 'green_at') -and $m.green_at) { $m.awaiting = 'release-candidate'; $m.rc_deadline = ConvertTo-Iso ($now.AddMinutes($t.releaseCandidateTimeoutMinutes)) }
    elseif ((Get-Park $s) -and "$($s.park.reason)" -eq 'master-green-timeout') { $m.awaiting = 'master-timeout' }
    else { $m.awaiting = 'master-broken' }   # polled: it goes on as soon as master is green for it (Find-GreenMaster), with no re-run
    $m.rearmed_at = ConvertTo-Iso $now
    return "$($m.awaiting)"
}

# One idempotent step of the post-merge flow for one item: master green, release candidate, docs-only skip, Release Queue, Done.
function Invoke-Settle([int]$n) {
    $c = Get-Cfg; $t = $c.timing
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    if (-not (Test-Has $s 'merge') -or -not (Test-Has $s.merge 'awaiting') -or -not $s.merge.awaiting) { return @{ outcome = 'nothing-to-settle' } }
    # A merged pull request that says "Closes #N" closes the item itself: that is not the end of the flow. Only an item closed without a merge stops here.
    if (-not $info.open -and -not (Test-Has $s.merge 'sha')) { $s.merge.awaiting = $null; Save-State $n $st; return @{ outcome = 'closed' } }
    $m = $s.merge; $sha = $m.sha; $now = Get-UtcNow
    $finish = {
        param($text)
        Add-Comment $n $text
        Move-Card $info (Get-LastColumn); Close-Issue $n
        $m.awaiting = $null; $m.done_at = ConvertTo-Iso (Get-UtcNow); Save-State $n $st
    }
    if ($m.awaiting -eq 'master-green') {
        # judge_sha: an auto-unpark found master green on a later head while the merge commit's own run stayed red (issue 70): that head is judged
        $chk = Get-ChecksFor $(if ((Test-Has $m 'judge_sha') -and "$($m.judge_sha)") { "$($m.judge_sha)" } else { $sha }) -Ignore (Get-MasterIgnoredChecks)
        $mergedAt = ConvertFrom-Iso $m.merged_at
        $rerunAt = if (Test-Has $m 'rerun_at') { ConvertFrom-Iso $m.rerun_at } else { $null }
        if ($chk.status -eq 'failure') {
            # Issue 79: the failed jobs are re-run once before master is declared broken (a flaky acceptance shard must not park a merged item).
            # GitHub refuses rerun-failed-jobs for a workflow run that is still in progress, so the re-run waits until every run of the commit has
            # completed; the runs and attempts re-run are recorded, and the verdict waits for a newer, completed attempt of each of them.
            $runs = @((Invoke-Gh -Path "$(Get-RepoPath)/actions/runs?head_sha=$sha&per_page=50").workflow_runs | Where-Object { $_ })
            $running = @($runs | Where-Object { "$($_.status)" -ne 'completed' })
            if (-not (Test-Has $m 'rerun_attempted') -or -not $m.rerun_attempted) {
                if ($running.Count -gt 0 -or $chk.pending_checks.Count -gt 0) {
                    if (-not ($mergedAt -and ($now - $mergedAt).TotalMinutes -gt $t.masterGreenTimeoutMinutes)) { return @{ outcome = 'waiting'; awaiting = 'master-green'; reason = 'failed-run-in-progress'; checks = (Get-PublicChecks $chk) } }
                }
                $flaky = Get-FlakyReason $sha $chk.failed_checks
                $started = @(); $refused = @()
                foreach ($r in @($runs | Where-Object { "$($_.status)" -eq 'completed' -and "$($_.conclusion)" -in 'failure', 'timed_out', 'startup_failure' })) {
                    $res = Invoke-GhRaw -Method POST -Path "$(Get-RepoPath)/actions/runs/$($r.id)/rerun-failed-jobs"
                    if ([int]$res.status -in 200, 201) { $started += @{ id = [long]$r.id; attempt = $(if ($r.run_attempt) { [int]$r.run_attempt } else { 1 }) } } else { $refused += "$($r.id): $([int]$res.status)" }
                }
                $m.rerun_attempted = $true; $m.rerun_at = ConvertTo-Iso $now; $m.rerun_runs = $started
                if ($started.Count -gt 0) {
                    Add-Comment $n "master checks failed at ``$($sha.Substring(0,7))`` ($($chk.failed_checks -join ', ')) - $flaky; re-running the failed jobs once (workflow run $(($started | ForEach-Object { $_.id }) -join ', ')), then judging the new attempt."
                    Save-State $n $st; return @{ outcome = 'rerun'; failed = $chk.failed_checks; runs = $started }
                }
                Add-Comment $n "master checks failed at ``$($sha.Substring(0,7))`` ($($chk.failed_checks -join ', ')) - $flaky; the failed jobs could not be re-run ($(if ($refused.Count) { 'GitHub refused: ' + ($refused -join ', ') } else { 'no failed workflow run found' }))."
            }
            elseif (@($m.rerun_runs).Count -gt 0) {
                # the old attempt's results stand until each re-run has a newer attempt that completed
                $inFlight = @(@($m.rerun_runs) | Where-Object { $rr = $_; $cur = @($runs | Where-Object { [long]$_.id -eq [long]$rr.id }) | Select-Object -First 1
                    (-not $cur) -or ([int]$cur.run_attempt -le [int]$rr.attempt) -or ("$($cur.status)" -ne 'completed') })
                if ($inFlight.Count -gt 0 -and -not ($rerunAt -and ($now - $rerunAt).TotalMinutes -gt $t.masterGreenTimeoutMinutes)) {
                    return @{ outcome = 'waiting'; awaiting = 'master-green'; reason = 'rerun-in-progress'; checks = (Get-PublicChecks $chk) }
                }
            }
            if ($chk.pending_checks.Count -eq 0) {
                # issue 114: the wait stays (master-broken) and is polled; the item goes on once master is green for it, and is never offered meanwhile
                Set-Park $s 'master-broken' ($t.parkHours * 60); $s.park.failed = @($chk.failed_checks); $s.park.sha = "$sha"; $m.awaiting = 'master-broken'; $m.broken_at = ConvertTo-Iso $now; Save-State $n $st
                Add-Comment $n "**master is BROKEN** at ``$($sha.Substring(0,7))`` after the merge ($($chk.failed_checks -join ', '))$(if ((Test-Has $m 'rerun_runs') -and @($m.rerun_runs).Count -gt 0) { ', also after one re-run of the failed jobs' }) - parked for a human. The gateway keeps watching: the park is lifted by itself once each check that failed has passed on a green master head, which is then judged. Auto-revert is out of scope."
                return @{ outcome = 'parked'; reason = 'master-broken' }
            }
        }
        if ($chk.status -eq 'success') {
            $m.green_at = ConvertTo-Iso $now
            $m.awaiting = 'release-candidate'; $m.rc_deadline = ConvertTo-Iso ($now.AddMinutes($t.releaseCandidateTimeoutMinutes))
            Add-Comment $n "master is GREEN at ``$($sha.Substring(0,7))`` - waiting for the release candidate that carries it."
            Save-State $n $st
            return @{ outcome = 'advanced'; awaiting = 'release-candidate' }
        }
        # a re-run started counts the timeout again from the re-run (issue 79): an acceptance re-run takes as long as the first run
        $since = if ($rerunAt -and $mergedAt -and $rerunAt -gt $mergedAt) { $rerunAt } else { $mergedAt }
        if ($since -and ($now - $since).TotalMinutes -gt $t.masterGreenTimeoutMinutes) {
            Set-Park $s 'master-green-timeout' ($t.parkHours * 60); $m.awaiting = 'master-timeout'; Save-State $n $st
            Add-Comment $n "master CI did not go green within $($t.masterGreenTimeoutMinutes) min of the merge - parked for a human. The gateway keeps watching: the item goes on by itself once this commit, or a later master commit that contains it, is green."
            return @{ outcome = 'parked'; reason = 'master-green-timeout' }
        }
        return @{ outcome = 'waiting'; awaiting = 'master-green'; checks = (Get-PublicChecks $chk) }
    }
    if ($m.awaiting -in 'master-broken', 'master-timeout') {
        # issue 114: the wait stays through the park. A master-broken park is lifted only by auto-unpark (Verbs.Sweep.ps1: every check that failed
        # passed on master, then judged on that head, issue 116) or by a person; while it stands the item just waits. Once it is gone (a person
        # released it, or it expired), and for a master-green-timeout park, the item goes on when master is green for the merge (its own latest
        # attempt, or a later master commit that contains it).
        $live = Get-Park $s   # (an expired park no longer holds the item)
        if ($m.awaiting -eq 'master-broken' -and $live -and "$($live.reason)" -eq 'master-broken') { return @{ outcome = 'waiting'; awaiting = 'master-broken' } }
        $g = Find-GreenMaster $sha
        if (-not $g) { return @{ outcome = 'waiting'; awaiting = "$($m.awaiting)" } }
        $was = "$($m.awaiting)"
        $m.green_at = ConvertTo-Iso $now; $m.green_via = "$($g.sha)"
        $m.awaiting = 'release-candidate'; $m.rc_deadline = ConvertTo-Iso ($now.AddMinutes($t.releaseCandidateTimeoutMinutes))
        if ((Test-Has $s 'park') -and "$($s.park.reason)" -in 'master-broken', 'master-green-timeout') { $s.Remove('park') }   # (only an expired master-broken park reaches here)
        $green7 = "$($g.sha)".Substring(0, 7); $contains = if ($g.own) { '' } else { ", which contains ``$($sha.Substring(0,7))``" }
        Add-Comment $n "master is GREEN at ``$green7``$contains - waiting for the release candidate that carries it."
        Save-State $n $st
        return @{ outcome = 'advanced'; awaiting = 'release-candidate'; recovered = $was }
    }
    if ($m.awaiting -in 'release-candidate', 'late-rc') {
        $chk = Get-ChecksFor $sha
        $rel = $chk.runs[$c.releaseCheckName]
        # docs-only is decided from the merge commit's own Build or the pull request's files (Get-MergeDocsOnly), once, before the release check is
        # read; an item that is not known to be docs-only always goes on to look for its release candidate
        if (-not (Test-Has $m 'docs_only')) { $dk = Get-MergeDocsOnly $m $chk; if ($dk) { $m.docs_only = [bool]$dk.docs_only; $m.docs_only_from = "$($dk.from)" } }
        $docsOnly = (Test-Has $m 'docs_only') -and $m.docs_only
        if ($docsOnly -and $rel -and $rel.status -eq 'completed' -and $rel.conclusion -eq 'skipped') {
            & $finish "the master build published no release candidate for ``$($sha.Substring(0,7))`` - its publish step was skipped because no code changed. A docs-only change has nothing to deploy, so it is moved straight to **$(Get-LastColumn)**."
            return @{ outcome = 'done'; path = 'docs-only' }
        }
        # A docs-only change builds no release. If the Release workflow never produced a 'release' check (for instance its run was dropped by the
        # workflow's concurrency group), do not wait for one: finish once master has been green for the grace period.
        $since = if (Test-Has $m 'green_at') { ConvertFrom-Iso $m.green_at } else { ConvertFrom-Iso $m.merged_at }
        if ($docsOnly -and -not $rel -and $since -and ($now - $since).TotalSeconds -ge [double]$t.docsOnlyReleaseGraceSeconds) {
            & $finish "the change is documentation only and no release was built for ``$($sha.Substring(0,7))`` ($($t.docsOnlyReleaseGraceSeconds) s after master went green). A docs-only change has nothing to deploy, so it is moved straight to **$(Get-LastColumn)**."
            return @{ outcome = 'done'; path = 'docs-only-no-release' }
        }
        $d = Get-Delivery $sha
        if ($d.candidate) {
            # issue 117: the card moves on only from Functional Testing; one that is elsewhere (already in the Release Queue, or moved by a person) stays
            $next = if ("$($info.column)" -ieq "$($c.columns.validation)") { Get-NextColumn $info.column } else { $null }
            if ($next -and $next -ine (Get-LastColumn)) { Move-Card $info $next }
            if (-not $next) { $next = "$($info.column)" }
            $m.awaiting = 'release-queue'; $m.release = $d.candidate.version; $m.queued_at = ConvertTo-Iso $now
            Add-Comment $n "release candidate **$($d.candidate.version)** carries ``$($sha.Substring(0,7))`` - waiting in **$next** for the production deployment."
            Save-State $n $st
            return @{ outcome = 'advanced'; awaiting = 'release-queue'; release = $d.candidate.version; queued_at = $m.queued_at }
        }
        $deadline = ConvertFrom-Iso $m.rc_deadline
        if ($m.awaiting -eq 'release-candidate' -and $deadline -and $now -gt $deadline) {
            $m.awaiting = 'late-rc'; $m.late_deadline = ConvertTo-Iso ($now.AddHours($t.lateReleaseCandidateHours))
            Set-Park $s 'fv:release-candidate-timeout' ($t.lateReleaseCandidateHours * 60)
            Add-Comment $n "master went green but no release candidate carrying it was published within $($t.releaseCandidateTimeoutMinutes) min - parked for a human. The worker keeps looking for $($t.lateReleaseCandidateHours) h."
            Save-State $n $st
            return @{ outcome = 'parked'; reason = 'release-candidate-timeout'; still_looking = $true }
        }
        if ($m.awaiting -eq 'late-rc' -and (ConvertFrom-Iso $m.late_deadline) -lt $now -and -not ((Test-Has $m 'late_reported') -and $m.late_reported)) {
            # issue 114: the wait is not erased (the item would be offered to a worker again): it keeps looking, and says so once
            $m.late_reported = ConvertTo-Iso $now; Set-Park $s 'fv:release-candidate-timeout' ($t.parkHours * 60)
            Add-Comment $n "still no release candidate carrying ``$($sha.Substring(0,7))`` after $($t.lateReleaseCandidateHours) h - parked for a human. The gateway keeps looking."
            Save-State $n $st
            return @{ outcome = 'parked'; reason = 'release-candidate-timeout'; still_looking = $true }
        }
        return @{ outcome = 'waiting'; awaiting = $m.awaiting }
    }
    if ($m.awaiting -eq 'release-queue') {
        $d = Get-Delivery $sha
        if ($d.prod_success) {
            & $finish "Delivered to **Prod** - moved to **$(Get-LastColumn)**. Release $($m.release)."
            return @{ outcome = 'done'; path = 'prod' }
        }
        $later = Get-ProdContaining $sha
        if ($later) {
            & $finish "Delivered to **Prod** in release $later, which contains this change - moved to **$(Get-LastColumn)**."
            return @{ outcome = 'done'; path = 'prod-later-release'; release = $later }
        }
        # since when it waits (the Release Queue age of the digest): an item queued before queued_at was recorded counts from master green, or the merge
        $queued = if (Test-Has $m 'queued_at') { $m.queued_at } elseif (Test-Has $m 'green_at') { $m.green_at } else { $m.merged_at }
        return @{ outcome = 'waiting'; awaiting = 'release-queue'; deployments = $d.deployments; release = $m.release; queued_at = $queued }
    }
    return @{ outcome = 'unknown-state'; awaiting = $m.awaiting }
}

function Verb_settle($a) {
    $n = Get-ItemNumber $a
    $r = Invoke-Settle $n; $r.ok = $true; $r.id = $n
    return $r
}
