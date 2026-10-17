# Pull requests and CI: lookup, ownership, check classification, docs-only test.

function Find-ItemPr([int]$Item) {
    $name = (Get-Cfg).name
    $open = @(Invoke-Gh -Path "$(Get-RepoPath)/pulls?state=open&per_page=100")
    $mine = @($open | Where-Object { $_.head.ref -match "^$([regex]::Escape($name))/$Item-" })
    if ($mine.Count -eq 0) { $mine = @($open | Where-Object { $_.head.ref -match "/$Item-" }) }
    if ($mine.Count -eq 0) { return $null }
    return $mine[0]
}

function Get-Pr([int]$Number) { Invoke-Gh -Path "$(Get-RepoPath)/pulls/$Number" }

# Word-boundary match: '#12' does not match '#123'.
function Test-PrBelongs($Pr, [int]$Item) {
    if ($Pr.head.ref -match "/$Item-") { return $true }
    return ($Pr.title -match "(^|[^0-9])#$Item([^0-9]|$)")
}

function Get-PrFiles([int]$Number) {
    $all = @(); $page = 1
    do { $chunk = @(Invoke-Gh -Path "$(Get-RepoPath)/pulls/$Number/files?per_page=100&page=$page"); $all += $chunk; $page++ } while ($chunk.Count -eq 100)
    return $all
}

function Test-DocsOnlyFiles($Files) {
    $pats = (Get-Cfg).docsOnlyPaths
    if (@($Files).Count -eq 0) { return $false }
    foreach ($f in $Files) {
        $ok = $false
        foreach ($p in $pats) { if ($f.filename -match $p) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    return $true
}

# Strict classification. Divergence from the live factory, on purpose: a head with zero check runs is 'pending', never green, and every configured
# gate must be present and successful. One rule for every reader (issue 102): only the gates (ciGates, the checks the ruleset requires) decide. A
# failed check that is not a gate is listed (failed_checks, nongate_failed) and never makes the head red by itself: failure when a gate failed,
# pending while a gate is absent or running, success when every gate succeeded. Without configured gates any failed check is a failure, as before.
# -Ignore: check names left out of the verdict (status, failed, pending); they stay readable in `runs`. Master's verdict ignores the checks of the
# workflows that a finished Build starts (masterIgnoredChecks: Release, Architecture): GitHub attaches those to master's head at the time they
# start, not to the commit that was built, so they say nothing about that commit and a skipped or failed one must not decide its fate.
function Get-ChecksFor([string]$Sha, [string[]]$Ignore = @()) {
    $runs = @((Invoke-Gh -Path "$(Get-RepoPath)/commits/$Sha/check-runs?per_page=100").check_runs)
    $latest = @{}
    foreach ($r in $runs) {
        $k = $r.name
        if (-not $latest.ContainsKey($k) -or ([DateTime]$r.started_at) -gt ([DateTime]$latest[$k].started_at)) { $latest[$k] = $r }
    }
    $failed = @(); $pending = @(); $ok = @(); $cancelled = @()
    $judged = @($latest.Keys | Where-Object { -not (Test-NameIn "$_" $Ignore) })
    foreach ($k in $judged) {
        $r = $latest[$k]
        if ($r.status -ne 'completed') { $pending += $k; continue }
        switch ($r.conclusion) {
            { $_ -in 'failure', 'timed_out', 'action_required', 'startup_failure' } { $failed += $k }
            'cancelled' { $pending += $k; $cancelled += $k }
            default { $ok += $k }
        }
    }
    $gateList = @((Get-Cfg).ciGates | Where-Object { $_ })
    $gates = [ordered]@{}
    foreach ($g in $gateList) {
        if (Test-NameIn $g $Ignore) { continue }   # an ignored check is no gate either
        if (-not $latest.ContainsKey($g)) { $gates[$g] = 'absent' }
        elseif ($failed -contains $g) { $gates[$g] = 'failure' }
        elseif ($pending -contains $g) { $gates[$g] = 'pending' }
        else { $gates[$g] = 'success' }
    }
    $status = 'success'
    if ($gateList.Count -eq 0) {
        if ($failed.Count -gt 0) { $status = 'failure' } elseif ($judged.Count -eq 0 -or $pending.Count -gt 0) { $status = 'pending' }
    }
    elseif ($gates.Values -contains 'failure') { $status = 'failure' }
    elseif ($judged.Count -eq 0 -or ($gates.Values -contains 'absent') -or ($gates.Values -contains 'pending')) { $status = 'pending' }
    $nongate = @($failed | Where-Object { $gateList -notcontains $_ } | Sort-Object)
    $nongateCancelled = @($cancelled | Where-Object { $gateList -notcontains $_ } | Sort-Object)
    return @{ status = $status; total = $judged.Count; failed = $failed.Count; failed_checks = $failed; pending_checks = $pending; gates = $gates; runs = $latest; nongate_failed = $nongate; nongate_cancelled = $nongateCancelled }
}

# ---- the CI rule for a red head (issue 102) ------------------------------------------------------------------------------------------------
# A head whose gates failed is judged only once every workflow run of it has completed. Then, once per head, the failed jobs are re-run when the
# failures that caused it are checks other than the gates (an aggregating gate like "Build result" fails because a job it needs failed), match
# masterFlakyChecks, or fail on the base branch too; the runs and attempts re-run are recorded in pr.rerun[sha] and the head is judged again on
# the newer, completed attempt of each. A head still red after that whose causes all fail on the base branch as well (their newest finished
# conclusion there failed) is a master defect: it costs no fix-forward round and no demotion, and is reported once; once the base branch passes
# those checks again the ruling says so (fixed), once per head, and the caller brings the branch up to date. Anything else is red, as before.

# The checks that caused the red: the failed (or cancelled) checks that are not gates, and the failed gates that are not aggregating ones (ciAggregateGates,
# default "Build result": it fails because a job it needs failed); when there are none of those, the failed gates themselves.
function Get-RedCauses($Chk) {
    $c = Get-Cfg; $agg = if (Test-Has $c 'ciAggregateGates') { @($c.ciAggregateGates) } else { @('Build result') }
    $gateList = @($c.ciGates | Where-Object { $_ })
    $own = @(@($Chk.nongate_failed) + @($Chk.nongate_cancelled) + @($Chk.failed_checks | Where-Object { $gateList -contains $_ -and $agg -notcontains $_ }) | Where-Object { $_ } | Sort-Object -Unique)
    if ($own.Count -gt 0) { return $own }
    return @($Chk.failed_checks | Sort-Object)
}

# Which of these checks match masterFlakyChecks (patterns).
function Get-FlakyMatches($Names) {
    $c = Get-Cfg; $pats = if (Test-Has $c 'masterFlakyChecks') { @($c.masterFlakyChecks) } else { @() }
    return @(@($Names) | Where-Object { $f = "$_"; @($pats | Where-Object { $f -match $_ }).Count -gt 0 })
}

# Which of these checks fail on the base branch now: the newest finished conclusion of the check on the last 5 commits of the default branch
# failed (Get-BaseHistory, Get-CheckBaseline of Checks.ps1). @{ available; preexisting = names; green = names whose newest is success }.
function Get-BaseFailures($Names) {
    $c = Get-Cfg
    $h = try { Get-BaseHistory "$($c.defaultBranch)" } catch { @{ available = $false } }
    if (-not $h.available) { return @{ available = $false; preexisting = @(); green = @() } }
    $pre = @(); $green = @()
    foreach ($nm in @($Names)) {
        $b = Get-CheckBaseline "$nm" $h
        if ($b.available -and "$($b.conclusion)" -in 'failure', 'timed_out', 'action_required', 'startup_failure') { $pre += "$nm" }
        elseif ($b.available -and "$($b.conclusion)" -in 'success', 'neutral', 'skipped') { $green += "$nm" }
    }
    return @{ available = $true; preexisting = $pre; green = $green }
}

# The ruling for a red head ($Chk.status 'failure'). Records a re-run in $State.pr.rerun[sha] (the caller saves the state). Returns
# @{ ruling; causes; reason; runs; fixed; cached }:
#   running        a workflow run of the head is still in progress: judge later
#   rerun          the failed jobs were re-run just now (once per head)
#   rerun-wait     the re-run has not finished yet
#   deferred       the base branch's checks could not be read: judge later (a rate-limit blip costs no round)
#   master-defect  still red, and every cause fails on the base branch too; fixed: the base branch passes the reported defect's checks again and
#                  this head was not brought up to date for it yet; cached: the same head was judged a master defect less than
#                  timing.masterDefectCheckMinutes (5) ago and nothing was read
#   red            still red for a reason of its own
# Every ruling has every key (the rule scripts run under strict mode, where a missing key cannot be read).
function New-Ruling([string]$Ruling, $Causes, [string]$Reason, $Runs = @(), [bool]$Fixed = $false, [bool]$Cached = $false) {
    return @{ ruling = $Ruling; causes = @($Causes); reason = $Reason; runs = @($Runs); fixed = $Fixed; cached = $Cached }
}

function Get-RedHeadRuling($State, [string]$Sha, $Chk) {
    $causes = @(Get-RedCauses $Chk)
    $md = if (Test-Has $State 'master_defect') { $State.master_defect } else { $null }
    if ($md -and "$($md.sha)" -eq $Sha -and (Test-Has $md 'checked_at')) {
        $t = (Get-Cfg).timing; $every = if (Test-Has $t 'masterDefectCheckMinutes') { [double]$t.masterDefectCheckMinutes } else { 5 }
        $ca = ConvertFrom-Iso $md.checked_at
        if ($ca -and ((Get-UtcNow) - $ca).TotalMinutes -lt $every) { return New-Ruling 'master-defect' @($md.checks) 'looked at less than a check interval ago' -Cached $true }
    }
    # the branch was just brought up to date for the fixed defect: GitHub makes the new head a moment later (update branch answers 202 at once)
    if ($md -and (Test-Has $md 'updated_for') -and "$($md.updated_for)" -eq $Sha -and (Test-Has $md 'updated_at')) {
        $ua = ConvertFrom-Iso $md.updated_at
        if ($ua -and ((Get-UtcNow) - $ua).TotalMinutes -lt 3) { return New-Ruling 'deferred' $causes 'the branch was just brought up to date; its new head comes next' }
    }
    $runs = @((Invoke-Gh -Path "$(Get-RepoPath)/actions/runs?head_sha=$Sha&per_page=50").workflow_runs | Where-Object { $_ })
    if (@($runs | Where-Object { "$($_.status)" -ne 'completed' }).Count -gt 0) { return New-Ruling 'running' $causes 'a workflow run of the head is still in progress' }
    if (-not (Test-Has $State 'pr')) { $State.pr = @{} }
    if (-not (Test-Has $State.pr 'rerun')) { $State.pr.rerun = @{} }
    $rec = if ($State.pr.rerun.Contains($Sha)) { $State.pr.rerun[$Sha] } else { $null }
    $base = Get-BaseFailures $causes
    if ($null -eq $rec) {
        $flaky = @(Get-FlakyMatches $causes)
        $why = @()
        if (@($Chk.nongate_failed).Count + @($Chk.nongate_cancelled).Count -gt 0) { $why += "checks other than the gates failed ($(@(@($Chk.nongate_failed) + @($Chk.nongate_cancelled)) -join ', '))" }
        if ($flaky.Count -gt 0) { $why += "known flaky: $($flaky -join ', ')" }
        if (@($base.preexisting).Count -gt 0) { $why += "failing on $((Get-Cfg).defaultBranch) too: $(@($base.preexisting) -join ', ')" }
        if ($why.Count -gt 0) {
            # (the record of the last 5 heads is kept: an older one can no longer be the head of this pull request)
            foreach ($old in @($State.pr.rerun.Keys | Sort-Object { "$($State.pr.rerun[$_].at)" } | Select-Object -SkipLast 4)) { $State.pr.rerun.Remove($old) }
            $rec = @{ at = ConvertTo-Iso (Get-UtcNow); runs = @(); causes = $causes; reason = ($why -join '; '); refused = @() }
            $State.pr.rerun[$Sha] = $rec
            foreach ($r in @($runs | Where-Object { "$($_.conclusion)" -in 'failure', 'timed_out', 'startup_failure', 'cancelled' })) {
                $res = try { Invoke-GhRaw -Method POST -Path "$(Get-RepoPath)/actions/runs/$($r.id)/rerun-failed-jobs" } catch { @{ status = 0 } }
                if ([int]$res.status -in 200, 201) { $rec.runs = @(@($rec.runs) + @{ id = [long]$r.id; attempt = $(if ($r.run_attempt) { [int]$r.run_attempt } else { 1 }) }) } else { $rec.refused = @(@($rec.refused) + "$($r.id): $([int]$res.status)") }
            }
            if (@($rec.runs).Count -gt 0) { return New-Ruling 'rerun' $causes ($why -join '; ') @($rec.runs) }
        }
    }
    elseif (@($rec.runs).Count -gt 0) {
        # the first attempt's results stand until each re-run has a newer attempt that completed
        $inFlight = @(@($rec.runs) | Where-Object { $rr = $_; $cur = @($runs | Where-Object { [long]$_.id -eq [long]$rr.id }) | Select-Object -First 1
                (-not $cur) -or ([int]$cur.run_attempt -le [int]$rr.attempt) -or ("$($cur.status)" -ne 'completed') })
        if ($inFlight.Count -gt 0) { return New-Ruling 'rerun-wait' $causes 'the re-run of the failed jobs has not finished' }
    }
    if (-not $base.available) { return New-Ruling 'deferred' $causes "the checks of $((Get-Cfg).defaultBranch) could not be read" }
    if ($causes.Count -gt 0 -and @($base.preexisting).Count -eq $causes.Count) {
        return New-Ruling 'master-defect' $causes "$($causes -join ', ') also fail$(if ($causes.Count -eq 1) { 's' }) on $((Get-Cfg).defaultBranch)"
    }
    # the defect reported before (the same checks) is fixed on the base branch: the branch is brought up to date once for it, and every head after
    # that is judged as any head (a head still red on those checks while the base branch passes them is a red of its own)
    if ($md -and "$(@($md.checks) -join '|')" -eq "$(@($causes | Sort-Object) -join '|')" -and @($base.green).Count -eq $causes.Count -and -not (Test-Has $md 'updated_for')) {
        return New-Ruling 'master-defect' $causes "$($causes -join ', ') pass on $((Get-Cfg).defaultBranch) again" -Fixed $true
    }
    return New-Ruling 'red' $causes "$(if ($rec -and @($rec.runs).Count -gt 0) { 'still red after one re-run of the failed jobs' } else { 'red' }): $($causes -join ', ')"
}

# A master defect is reported once per set of checks (state master_defect): a comment on the item, and the caller's sweep action names it new.
# Returns $true when this call reported it (the caller saves the state).
function Register-MasterDefect([int]$n, $State, [int]$Pr, [string]$Sha, $Causes) {
    $key = (@($Causes) | Sort-Object) -join '|'
    $known = (Test-Has $State 'master_defect') -and "$($State.master_defect.checks -join '|')" -eq $key
    if ($known) { $State.master_defect.sha = $Sha; return $false }
    $State.master_defect = @{ checks = @(@($Causes) | Sort-Object); sha = $Sha; pr = $Pr; reported_at = ConvertTo-Iso (Get-UtcNow) }
    $c = Get-Cfg
    Add-Comment $n "PR #$Pr is red only on checks that fail on **$($c.defaultBranch)** as well ($(@($Causes) -join ', ')): a defect of $($c.defaultBranch), not of this change. It costs this item no fix-forward round and no demotion; the gateway waits, merges $($c.defaultBranch) into the branch once $($c.defaultBranch) passes those checks again, and judges the new head."
    return $true
}

# The checks a master commit is judged without (see Get-ChecksFor -Ignore).
function Get-MasterIgnoredChecks { $c = Get-Cfg; if (Test-Has $c 'masterIgnoredChecks') { @($c.masterIgnoredChecks | ForEach-Object { "$_" }) } else { @('release', 'packages', 'architecture') } }

function Get-PublicChecks($c) {
    @{ status = $c.status; total = $c.total; failed = $c.failed; failed_checks = $c.failed_checks; pending_checks = $c.pending_checks; gates = $c.gates; nongate_failed = @($c.nongate_failed) }
}

# Docs-only is what the design step recorded in the item state (append-body in the design column); marker text in the body alone proves nothing,
# because anyone who can edit the issue can type it.
# The design step always writes the field, true or false (append-body, and complete of the design column when no design append set it), and once it
# exists the body text is ignored. Only a state with NO field on an item that is already past its design column AND was created before
# timing.docsOnlyLegacyBefore (the items an older version designed) falls back to the marker in the body; pass $Info to allow that fallback.
# A newer item without the field is not docs-only, whatever its body says.
function Get-LegacyCutoff { $t = (Get-Cfg).timing; if (Test-Has $t 'docsOnlyLegacyBefore') { return ConvertFrom-Iso $t.docsOnlyLegacyBefore }; return $null }
function Test-ItemDocsOnly($State, $Info = $null) {
    if ((Test-Has $State 'design') -and (Test-Has $State.design 'docs_only')) { return [bool]$State.design.docs_only }
    $c = Get-Cfg
    if ($null -eq $Info -or (Test-Has $c.requiredBodySection "$($Info.column)")) { return $false }
    $cut = Get-LegacyCutoff; $made = if (Test-Has $Info 'createdAt') { try { ConvertFrom-Iso $Info.createdAt } catch { $null } } else { $null }
    if ($null -eq $cut -or $null -eq $made -or $made -ge $cut) { return $false }
    return "$($Info.body)".Contains($c.docsOnlyMarker)
}

# Docs-only fast path (plant-manager.md section 10a). The private build is NOT owed for a pull request only when BOTH facts hold: the item body carries
# the docs-only marker (written by its technical design) and every changed file matches docsOnlyPaths. Anything else owes the build: an item without
# the marker, a marked item whose pull request touches a file that is not documentation, or a pull request whose files could not be read.
# verification says how Functional Testing checks the change: 'diff' (read the diff against the criteria, no build, no application) under the same
# two facts and no video label; otherwise 'app'.
function Get-BuildOwed($Info, [int]$PrNumber, $State) {
    $c = Get-Cfg; $marker = Test-ItemDocsOnly $State $Info
    $files = $null; try { $files = @(Get-PrFiles $PrNumber) } catch { }
    if ($null -eq $files) { return @{ build_owed = $true; docs_only_files = $false; verification = 'app'; build_reason = 'the files of the pull request could not be read; the private build is owed' } }
    $docs = Test-DocsOnlyFiles $files
    $other = @($files | Where-Object { -not (Test-DocsOnlyFiles @($_)) } | ForEach-Object { "$($_.filename)" } | Select-Object -First 5)
    if ($marker -and $docs) {
        $video = Test-Label $Info $c.videoLabel
        return @{ build_owed = $false; docs_only_files = $true; verification = $(if ($video) { 'app' } else { 'diff' })
            build_reason = "every changed file is documentation and the technical design recorded the item as docs-only: no private build and no SDK are owed; the checks of the pull request are the gate" }
    }
    if ($marker) { return @{ build_owed = $true; docs_only_files = $false; verification = 'app'; not_documentation = $other
        build_reason = "the technical design recorded the item as docs-only but the pull request changes files that are not documentation ($($other -join ', ')): the private build is owed before complete" } }
    return @{ build_owed = $true; docs_only_files = $docs; verification = 'app'; build_reason = "the technical design did not record the item as docs-only: the private build is owed" }
}
