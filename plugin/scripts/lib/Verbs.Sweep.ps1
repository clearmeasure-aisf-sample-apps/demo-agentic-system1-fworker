# The sweep (reconciliation + run watchdog), event intake and the secrets check. No model is involved in any of it.

function Get-SeenFile { Join-Path (Get-StateDir) 'seen.json' }

# Issue 117: called under the item lock on a fresh read (Invoke-AwaitingChecksLocked). The card moves on only from the column the wait began in
# (Development): a card that is elsewhere was moved by a person, or by an earlier pass that a stale read did not see (290 went from Development
# to Functional Testing and on to the Release Queue in two passes 5 s apart, its pull request unmerged), so the wait ends without a move.
function Complete-AwaitingChecks([int]$n, $info, $st) {
    $c = Get-Cfg; $s = $st.state; $aw = $s.awaiting_checks
    $expect = if ((Test-Has $aw 'column') -and $aw.column) { "$($aw.column)" } else { "$($c.columns.development)" }
    if ("$($info.column)" -ine $expect) {
        $s.Remove('awaiting_checks'); if ((Test-Has $s 'park') -and "$($s.park.reason)" -eq 'development:awaiting-checks') { $s.Remove('park') }
        Save-State $n $st
        Add-Comment $n "the wait for the checks of PR #$($aw.pr) ended without moving the card: it is in **$($info.column)**, not in **$expect** where the wait began."
        return @{ outcome = 'column-moved'; column = "$($info.column)"; expected = $expect }
    }
    $pr = Get-Pr ([int]$aw.pr); $sha = "$($pr.head.sha)"
    $chk = Get-ChecksFor $sha
    if ($chk.status -eq 'success') {
        $s.Remove('fix_forward_rounds'); $s.Remove('master_defect'); if ((Test-Has $s 'pr') -and (Test-Has $s.pr 'rejection')) { $s.pr.Remove('rejection') }
        $comment = "PR #$($pr.number) checks are green; development complete. $($aw.comment)"
        $r = Finish-ColumnExit $n $info $st $comment @{ prNumber = $pr.number }
        return @{ outcome = 'completed'; moved_to = $r.moved_to }
    }
    if ($chk.status -eq 'failure') {
        # one CI rule (issue 102, Prs.ps1): re-run once, a master defect costs no round, only a red of the change's own is a fix-forward round
        $rule = Get-RedHeadRuling $s $sha $chk
        if ($rule.ruling -eq 'rerun') {
            # the wait for the checks starts again with the re-run: an acceptance re-run takes as long as the first run
            $aw.since = ConvertTo-Iso (Get-UtcNow); Set-Park $s 'development:awaiting-checks' $c.timing.awaitingChecksParkMinutes; Save-State $n $st
            Add-Comment $n "PR #$($pr.number) checks failed at ``$($sha.Substring(0,7))`` ($($rule.causes -join ', ')) - $($rule.reason); re-running the failed jobs once (workflow run $(($rule.runs | ForEach-Object { $_.id }) -join ', ')), then judging the new attempt. No fix-forward round is counted for it."
            return @{ outcome = 'rerun'; failed = $rule.causes; runs = $rule.runs }
        }
        # running, rerun-wait, deferred: judged later; the hung-CI timeout below still counts (from the re-run, when there was one)
        # a master defect seen less than masterDefectCheckMinutes ago (cached: nothing was read): wait
        if ($rule.ruling -eq 'master-defect' -and $rule.cached) { return @{ outcome = 'waiting'; reason = 'master-defect'; checks = @($rule.causes) } }
        if ($rule.ruling -eq 'master-defect') {
            $new = Register-MasterDefect $n $s ([int]$pr.number) $sha $rule.causes
            $md = $s.master_defect; $md.checked_at = ConvertTo-Iso (Get-UtcNow)
            # the hung-CI timeout does not apply while the base branch is broken; a defect that outlasts timing.parkHours is a person's to look at
            $since = ConvertFrom-Iso $md.reported_at
            if ($since -and ((Get-UtcNow) - $since).TotalHours -gt [double]$c.timing.parkHours) {
                $s.Remove('awaiting_checks'); Set-Park $s 'master-defect' ($c.timing.parkHours * 60); Save-State $n $st
                Add-Comment $n "PR #$($pr.number) has waited more than $($c.timing.parkHours) h for **$($c.defaultBranch)** to pass $($rule.causes -join ', ') again - parked for a human. No fix-forward round and no demotion were counted."
                return @{ outcome = 'parked'; reason = 'master-defect' }
            }
            $aw.since = ConvertTo-Iso (Get-UtcNow); Set-Park $s 'development:awaiting-checks' $c.timing.awaitingChecksParkMinutes
            # the base branch passes those checks again (the ruling says fixed): its fix is merged into the branch (GitHub's update branch), once
            # per head, and the new head is judged as any head
            $updated = ''
            if ($rule.fixed) {
                $md.updated_for = $sha; $md.updated_at = ConvertTo-Iso (Get-UtcNow)
                $u = try { Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$($pr.number)/update-branch" -Body @{ expected_head_sha = $sha } -Allow 409, 422 } catch { @{ status = 0; body = @{ message = "$($_.Exception.Message)" } } }
                $updated = if (-not ($u -is [hashtable] -and $u.ContainsKey('status'))) { 'updated' } elseif ("$($u.body.message)" -match 'conflict') { 'conflict' } else { 'refused' }
                if ($updated -eq 'updated') { Add-Comment $n "**$($c.defaultBranch)** passes $($rule.causes -join ', ') again: the gateway merged $($c.defaultBranch) into the branch of PR #$($pr.number); the checks of the new head decide." }
                elseif ($updated -eq 'refused') { $md.Remove('updated_for'); $md.Remove('updated_at') }   # (a refusal that is no conflict: tried again at the next look)
                elseif ($updated -eq 'conflict') {
                    # GitHub cannot merge it (a conflict): the owner merges master into the branch; this hand-off is not a fix-forward round
                    $s.Remove('awaiting_checks'); $s.Remove('park')
                    if (-not (Test-Has $s 'pr')) { $s.pr = @{} }
                    $s.pr.number = $pr.number; $s.pr.branch = $pr.head.ref; $s.pr.url = $pr.html_url
                    $s.pr.rejection = "$($c.defaultBranch) passes $($rule.causes -join ', ') again, and GitHub could not merge it into the branch of PR #$($pr.number) (conflict): merge $($c.defaultBranch) into the branch, resolve, push"
                    $s.handoff = @{ column = $c.columns.development; at = ConvertTo-Iso (Get-UtcNow) }
                    Save-State $n $st
                    Add-Comment $n "**$($c.defaultBranch)** passes $($rule.causes -join ', ') again, but GitHub could not merge it into the branch of PR #$($pr.number). Re-dispatching Development to merge $($c.defaultBranch) into the branch (not counted as a fix-forward round)."
                    return @{ outcome = 'fix-forward'; round = $(if (Test-Has $s 'fix_forward_rounds') { [int]$s.fix_forward_rounds } else { 0 }); reason = 'master-fixed-conflict'; offer = $true }
                }
            }
            Save-State $n $st
            return @{ outcome = 'master-defect'; checks = @($rule.causes); new = $new; branch = $updated }
        }
        if ($rule.ruling -eq 'red') {
            $rounds = $(if (Test-Has $s 'fix_forward_rounds') { [int]$s.fix_forward_rounds } else { 0 }) + 1
            $s.fix_forward_rounds = $rounds; $s.Remove('awaiting_checks'); $s.Remove('park'); $s.Remove('master_defect')
            if ($rounds -gt [int]$c.timing.fixForwardMaxRounds) {
                Set-Park $s 'fix-forward-exhausted' ($c.timing.parkHours * 60); $s.park.pr = [int]$pr.number; $s.park.head = "$($pr.head.sha)"; Save-State $n $st
                Add-Comment $n "PR #$($pr.number) has failed CI after $($rounds - 1) fix-forward Development rounds - parked for a human."
                return @{ outcome = 'parked'; reason = 'fix-forward-exhausted' }
            }
            if (-not (Test-Has $s 'pr')) { $s.pr = @{} }
            $s.pr.number = $pr.number; $s.pr.branch = $pr.head.ref; $s.pr.url = $pr.html_url
            $s.pr.rejection = "PR #$($pr.number) checks failed after the completion: $($rule.causes -join ', ')"
            $s.pr.failed_checks = $chk.failed_checks
            [void](Add-ChecksRed $s "$($pr.head.sha)")
            $s.handoff = @{ column = $c.columns.development; at = ConvertTo-Iso (Get-UtcNow) }
            Save-State $n $st
            Add-Comment $n "REJECTED a Development completion - PR #$($pr.number) checks are 'failure' ($($chk.failed_checks -join ', ')$(if ($rule.reason -match '^still red') { '; still red after one re-run of the failed jobs' })). Re-dispatching Development to fix forward (round $rounds)."
            return @{ outcome = 'fix-forward'; round = $rounds; offer = $true }
        }
    }
    $since = ConvertFrom-Iso $aw.since
    if ($since -and ((Get-UtcNow) - $since).TotalMinutes -gt $c.timing.devChecksTimeoutMinutes) {
        $s.Remove('awaiting_checks'); Set-Park $s 'stuck' ($c.timing.parkHours * 60); Save-State $n $st
        Add-Comment $n "PR #$($pr.number) checks were still not finished after $($c.timing.devChecksTimeoutMinutes) min - parked for a human (a hung CI run, not a code problem)."
        return @{ outcome = 'parked'; reason = 'stuck' }
    }
    return @{ outcome = 'waiting'; checks = (Get-PublicChecks $chk) }
}

# Issue 117: the sweep's two long steps that save an item's state, settle and the end of a wait for checks, run under the item lock on a fresh read
# (the sweep read the state earlier, without the lock, and a verb or an earlier pass may have changed it since). A lock still busy after 3 s skips
# the item for this sweep (outcome busy); the next sweep takes it up. Use-ItemLock is a lock of this machine: one gateway sweeps the board.
function Invoke-SettleLocked([int]$n) {
    try { return (Use-ItemLock $n { Invoke-Settle $n } 3) }
    catch [FactoryReject] { if ($_.Exception.Code -eq 'item-busy') { return @{ outcome = 'busy' } }; throw }
}
function Invoke-AwaitingChecksLocked([int]$n) {
    try {
        return (Use-ItemLock $n {
            $f = Get-State $n
            if (-not (Test-Has $f.state 'awaiting_checks')) { @{ outcome = 'settled-meanwhile' } }
            else { Complete-AwaitingChecks $n (Get-ItemInfo $n) $f }
        } 3)
    } catch [FactoryReject] { if ($_.Exception.Code -eq 'item-busy') { return @{ outcome = 'busy' } }; throw }
}

# A pull request of the item was merged outside the merge verb (a person pressed the button): the item is settled from wherever it was. Under the
# item lock on a fresh read (the sweep holds no lock, and the merge verb may have recorded the same merge a moment ago): the merge is recorded once,
# the verdict is closed, and whatever held the item (claim, park, handoff, a wait for checks, an inspector lease) ends. Returns whether it recorded.
function Invoke-MergePickup([int]$n, $pr) {
    return Use-ItemLock $n {
        $f = Get-State $n; $fs = $f.state
        if ((Test-Has $fs 'merge') -and (Test-Has $fs.merge 'sha') -and $fs.merge.sha) { $false }
        else {
            $fs.merge = @{ sha = $pr.merge_commit_sha; awaiting = 'master-green'; merged_at = ConvertTo-Iso (Get-UtcNow); pr = [int]$pr.number; by = 'person' }
            if (Test-Has $fs 'verdict') { $fs.verdict.processed = $true; $fs.verdict.Remove('wait') }
            foreach ($k in 'claim', 'park', 'handoff', 'awaiting_checks', 'bot') { $fs.Remove($k) }
            Save-State $n $f; Remove-ClaimRef $n; $true
        }
    }
}

# ---- orphan claim refs (issue 47) --------------------------------------------------------------------------------------
# A claim is a ref (refs/factory/<instance>/claims/<item>) and the claim in the item's state; the ref is written first. A claim cut off between the
# two (a restart) leaves a ref with no claim, and refs of closed items were never removed. Each sweep (the first one runs at start-up) lists the
# refs and, under the item lock on a fresh read of the state, removes a ref that has no live claim: at once when the item is closed or gone, and
# when it is open once the ref has been seen without a claim for longer than a lease. When it was first seen so is kept in the state directory: a
# restart starts the wait again, which only delays the removal (an accept takes such a ref over anyway, Verb_claim_item).
function Get-ClaimOrphanFile { Join-Path (Get-StateDir) 'claim-orphans.json' }

function Get-ClaimRefItems {
    $prefix = "refs/$(Get-RefPath)/"; $seen = [System.Collections.Generic.HashSet[int]]::new(); $out = @()
    # matching-refs may ignore the page parameter (as Get-RevokedRefs): end on an empty page or on one that brings nothing new
    for ($page = 1; $page -le 50; $page++) {
        $rows = @(Invoke-Gh -Path "$(Get-RepoPath)/git/matching-refs/$(Get-RefPath)/`?per_page=100&page=$page")
        if ($rows.Count -eq 0) { break }
        $new = 0
        foreach ($r in $rows) {
            $ref = "$($r.ref)"
            if ($ref.StartsWith($prefix, [StringComparison]::Ordinal) -and $ref.Substring($prefix.Length) -match '^\d{1,9}$' -and $seen.Add([int]$Matches[0])) { $out += [int]$Matches[0]; $new++ }
        }
        if ($new -eq 0) { break }
    }
    return , @($out)
}

function Invoke-ClaimRefReap($List) {
    $t = (Get-Cfg).timing; $f = Get-ClaimOrphanFile
    $first = if (Test-Path $f) { try { Get-Content -Raw $f | ConvertFrom-Json -AsHashtable -DateKind String } catch { @{} } } else { @{} }
    if ($null -eq $first) { $first = @{} }
    $board = @{}; foreach ($it in $List) { $board["$($it.number)"] = $it }
    $acts = @(); $keep = @{}; $now = Get-UtcNow
    foreach ($n in (Get-ClaimRefItems)) {
        try {
            $open = if ($board.ContainsKey("$n")) { [bool]$board["$n"].open } else { try { [bool](Get-ItemInfo $n).open } catch [FactoryReject] { if ($_.Exception.Code -in 'github-not-found', 'item-not-found') { $false } else { throw } } }
            $since = if ($first.ContainsKey("$n")) { ConvertFrom-Iso $first["$n"] } else { $null }
            if (-not $since) { $since = $now }
            $aged = ($now - $since).TotalMinutes -ge [double]$t.leaseMinutes
            $res = Use-ItemLock $n {
                $st = try { Get-State $n } catch [FactoryReject] { if ($_.Exception.Code -in 'github-not-found', 'item-not-found') { $null } else { throw } }
                if ($st -and (Test-ClaimLive $st.state)) { return 'live' }
                if (-not $open -or $aged) { Remove-ClaimRef $n; return 'removed' }
                return 'orphan'
            }
            if ($res -eq 'removed') { $acts += @{ item = $n; action = 'claim-ref-removed'; reason = $(if (-not $open) { 'item-closed' } else { 'orphan' }) } }
            elseif ($res -eq 'orphan') { $keep["$n"] = ConvertTo-Iso $since; $acts += @{ item = $n; action = 'orphan-claim'; since = $keep["$n"] } }
        } catch [FactoryReject] { $acts += @{ item = $n; action = 'skip'; reason = "claim-ref-reap: $($_.Exception.Code)" } }
    }
    $keep | ConvertTo-Json -Depth 3 | Set-Content $f
    return , @($acts)
}

# Issue 114: re-arms the settle step of an item with a merge record that has no wait and is not done (Restore-Settle), under the item lock on a
# fresh read, and journals it. Returns the wait it set, or ''.
function Invoke-RearmSettle([int]$n, [string]$Why) {
    Use-ItemLock $n {
        $f = Get-State $n; $w = Restore-Settle $f.state
        if (-not $w) { return '' }
        [void](Add-Journal $n $f 'settle-rearmed' @{ awaiting = $w; by = 'the sweep'; reason = $Why } "rearm|$($f.state.merge.sha)|$($f.state.merge.rearmed_at)")
        Save-State $n $f
        return $w
    } 3
}

# Issue 82: removes the park of a closed item under the item lock, on a fresh read, and journals it. Returns the park's code, or $null when there
# was none any more or the item is open again (reopened meanwhile: its park is a person's to release).
function Clear-ClosedPark([int]$n) {
    Use-ItemLock $n {
        $info = Get-ItemInfo $n; if ($info.open) { return $null }
        $f = Get-State $n; $fs = $f.state
        if (-not (Test-Has $fs 'park')) { return $null }
        if ((Test-Has $fs 'merge') -and (Test-Has $fs.merge 'awaiting') -and $fs.merge.awaiting) { return $null }
        $park = $fs.park; $code = "$($park.reason)"; $fs.Remove('park')
        [void](Add-Journal $n $f 'unparked' @{ column = "$($info.column)"; code = $code; by = 'the sweep'; reason = 'the item is closed'; closed = $true } "closed|$($park.at)")
        Save-State $n $f
        return $code
    }
}

# Issue 94: an owner's claim whose lease ran out while no gateway was up (between the predecessor's last renewal, or its release, and this gateway's
# first sweep) is renewed instead of being offered again as a relaunch: nothing could renew it then. Under the item lock on a fresh read, only a
# claim that was not taken back and whose lease ended inside the gap. Returns the holder, or $null.
function Invoke-GapRenew([int]$n, $Gap) {
    Use-ItemLock $n {
        $f = Get-State $n; $fs = $f.state
        if (-not ((Test-OwnedClaim $fs) -and -not (Test-ClaimLive $fs))) { return $null }
        if ((Test-Has $fs.claim 'taken_back') -and $fs.claim.taken_back) { return $null }
        $lu = ConvertFrom-Iso $fs.claim.lease_until
        if (-not $lu -or $lu -lt $Gap.since -or $lu -gt $Gap.until) { return $null }
        $t = (Get-Cfg).timing; $now = Get-UtcNow
        $fs.claim.lease_until = ConvertTo-Iso ($now.AddMinutes($t.leaseMinutes)); $fs.claim.gap_renewed = ConvertTo-Iso $now
        [void](Add-Journal $n $f 'gap-renewed' @{ worker = "$($fs.claim.holder)"; lapsed = (ConvertTo-Iso $lu); since = (ConvertTo-Iso $Gap.since); minutes = $t.leaseMinutes } "gap|$(ConvertTo-Iso $lu)")
        Save-State $n $f
        "$($fs.claim.holder)"
    }
}

# Issue 102: a park that ended by expiry gives the item a fresh start. Its fix-forward rounds and demotions are counted from 0 again (they parked it,
# or they would park it again at the first red), and the expired park leaves the state; a journal line says so. Not the gateway's own wait for
# checks (development:awaiting-checks): that one is not a person's park. Under the item lock on a fresh read. Returns the park code, or $null.
function Reset-ExpiredPark([int]$n) {
    Use-ItemLock $n {
        $f = Get-State $n; $fs = $f.state
        if (-not (Test-Has $fs 'park') -or (Get-Park $fs) -or "$($fs.park.reason)" -eq 'development:awaiting-checks') { return $null }
        if (-not ((Test-Has $fs 'fix_forward_rounds') -or (Test-Has $fs 'demotions') -or (Test-Has $fs 'master_defect'))) { return $null }
        $park = $fs.park; $code = "$($park.reason)"
        $fs.Remove('park'); $fs.Remove('fix_forward_rounds'); $fs.Remove('demotions'); $fs.Remove('master_defect')
        $info = Get-ItemInfo $n
        [void](Add-Journal $n $f 'unparked' @{ column = "$($info.column)"; code = $code; by = 'expiry'; reason = "the park ended at $($park.until)"; reset = $true } "expired|$($park.at)")
        Save-State $n $f
        return $code
    }
}

# Auto-unpark: a park whose cause has cleared is lifted by the sweep, so nobody has to watch for it (the overnight runs of 2026-10-14 needed a person
# for each). Returns why the cause cleared, or $null. $Ctx caches master's state for one sweep and carries free_workers from the gateway.
#   master-broken             master's head is green now AND every check that failed at the park (park.failed) passed on it (a skipped job, as
#                             on a docs-only head, does not count); a park written before park.failed existed is left to a person
#   verdict-failed,           the item's open pull request is green on a head newer than the one the park judged (park.head; a park written
#   fix-forward-exhausted     before park.head existed is left to a person)
#   session-relaunch-budget   (and a watchdog-relaunch-budget whose last claim was taken back by the gateway): a session that could take it is free
# No item is lifted more than timing.autoUnparkMax times (default 3) per park code: after that the park is a person's again, so an item that
# breaks every session it gets is not retried for ever.
function Test-AutoUnpark([int]$n, $s, $Park, $Ctx) {
    $code = "$($Park.reason)"
    $t = (Get-Cfg).timing; $max = if (Test-Has $t 'autoUnparkMax') { [int]$t.autoUnparkMax } else { 3 }
    $cnt = if ((Test-Has $s 'auto_unparks') -and (Test-Has $s.auto_unparks $code)) { [int]$s.auto_unparks[$code] } else { 0 }
    if ($cnt -ge $max) { return $null }   # (0 switches the lifts off)
    switch ($code) {
        'master-broken' {
            if (-not (Test-Has $Park 'failed') -or @($Park.failed).Count -eq 0) { return $null }
            if (-not $Ctx.ContainsKey('master')) {
                $Ctx.master = $null
                try { $head = Get-BaseHead; $chk = Get-ChecksFor $head; $Ctx.master = @{ sha = $head; green = ($chk.status -eq 'success'); runs = $chk.runs } } catch { }
            }
            $mc = $Ctx.master
            if (-not $mc -or -not $mc.green) { return $null }
            foreach ($f in @($Park.failed)) { $r = $mc.runs["$f"]; if (-not $r -or "$($r.conclusion)" -ne 'success') { return $null } }
            return "master is green again at $($mc.sha.Substring(0, 7)), with $(@($Park.failed) -join ', ') passing"
        }
        { $_ -in 'verdict-failed', 'fix-forward-exhausted' } {
            if (-not (Test-Has $Park 'head') -or -not "$($Park.head)") { return $null }
            $prn = if (Test-Has $Park 'pr') { [int]$Park.pr } elseif ((Test-Has $s 'pr') -and (Test-Has $s.pr 'number')) { [int]$s.pr.number } else { 0 }
            if ($prn -le 0) { return $null }
            $pr = try { Get-Pr $prn } catch { $null }
            if (-not $pr -or "$($pr.state)" -ne 'open' -or "$($pr.head.sha)" -eq "$($Park.head)") { return $null }
            if ((Get-ChecksFor "$($pr.head.sha)").status -eq 'success') { return "PR #$prn is green on a newer head $("$($pr.head.sha)".Substring(0, 7))" }
        }
        { $_ -eq 'session-relaunch-budget' -or ($_ -eq 'watchdog-relaunch-budget' -and (Test-Has $Park 'last_take_back')) } {
            # one lift per free session in a sweep: six parked items and one free session lift one
            if ([int]$Ctx.free_workers -gt 0) { return "the relaunches were lost to session trouble ($(if (Test-Has $Park 'last_take_back') { $Park.last_take_back } else { 'take-backs' })) and a worker session can take it now" }
        }
    }
    return $null
}
# Lifts the park under the item lock on a fresh read (only the same park: one a person or a verb changed meanwhile is left), counts the lift,
# journals it, and hands an open item without a live claim to its column so the sweep offers it at once. A merged item parked master-broken goes
# back to waiting for master green, judged on master's green head when its own merge commit is still not green (issue 70). Returns
# @{ code; handoff; owned } or $null.
function Invoke-AutoUnpark([int]$n, $Park, [string]$Why, $Ctx) {
    Use-ItemLock $n {
        $c = Get-Cfg
        $info = Get-ItemInfo $n; $f = Get-State $n; $fs = $f.state
        if (-not (Test-Has $fs 'park') -or "$($fs.park.at)" -ne "$($Park.at)" -or "$($fs.park.reason)" -ne "$($Park.reason)") { return $null }
        $code = "$($fs.park.reason)"; $fs.Remove('park')
        if (-not (Test-Has $fs 'auto_unparks')) { $fs.auto_unparks = @{} }
        $fs.auto_unparks[$code] = $(if (Test-Has $fs.auto_unparks $code) { [int]$fs.auto_unparks[$code] } else { 0 }) + 1
        $handoff = $false
        if ($code -eq 'master-broken' -and (Test-Has $fs 'merge')) {
            $m = $fs.merge; $m.awaiting = 'master-green'
            if ($Ctx.master -and "$($m.sha)" -and (Get-ChecksFor "$($m.sha)").status -ne 'success') { $m.judge_sha = $Ctx.master.sha } elseif (Test-Has $m 'judge_sha') { $m.Remove('judge_sha') }
        } elseif ($info.open -and -not (Test-ClaimLive $fs) -and (Test-NameIn "$($info.column)" $c.columns.ai)) {
            $fs.handoff = @{ column = $info.column; at = ConvertTo-Iso (Get-UtcNow) }; $handoff = $true
        }
        $why2 = "$Why (automatic lift $($fs.auto_unparks[$code]) of at most $(if (Test-Has $c.timing 'autoUnparkMax') { $c.timing.autoUnparkMax } else { 3 }))"
        [void](Add-Journal $n $f 'unparked' @{ column = "$($info.column)"; code = $code; by = 'the sweep'; reason = $why2 } "auto|$($Park.at)")
        Save-State $n $f
        return @{ code = $code; handoff = $handoff; owned = (Test-OwnedClaim $fs) -and (Test-ClaimLive $fs) }
    } 3
}

# Board guard: an open issue with the factory label that has no card on the board, or a card with no column, is invisible to the sweep (on
# 2026-10-14 nine new items sat unseen until a person added them). Each sweep lists the open labelled issues (REST, paged, pull requests and the
# rival label skipped) and, for each one the board snapshot shows without a column, reads the issue again (a person may have placed it meanwhile):
# a card in a column is left alone, a card without a column is given the intake column, and an issue without a card is added there (the intake
# column is the first column the factory works, Technical Design). One journal line each. At most $Max per sweep, so a first run over many issues
# stays within the sweep's time; the rest follow at the next sweeps. A rate limit ends the pass. Returns the actions.
function Invoke-BoardGuard($List, [int]$Max = 20) {
    $c = Get-Cfg; $acts = [System.Collections.Generic.List[object]]::new(); $placed = @{}
    foreach ($x in $List) { if ("$($x.column)") { $placed[[int]$x.number] = $true } }
    $intake = "$(@($c.columns.ai)[0])"
    $page = 1; $done = 0; $fails = 0
    do {
        $chunk = @(Invoke-Gh -Path "$(Get-RepoPath)/issues?state=open&labels=$([uri]::EscapeDataString("$($c.label)"))&per_page=100&page=$page")
        foreach ($i in $chunk) {
            $n = [int]$i.number
            if ($null -ne $i.PSObject.Properties['pull_request'] -or $n -le 0 -or $placed.ContainsKey($n)) { continue }
            if (@($i.labels | ForEach-Object { "$($_.name)" }) -contains "$($c.rivalLabel)") { continue }
            if ($done -ge $Max -or $fails -ge 3) { return , $acts.ToArray() }   # attempts count, failed ones too; three failures in a row end the pass
            $done++
            try {
                $info = Get-ItemInfo $n
                if (-not $info.open -or "$($info.column)") { $placed[$n] = $true; $done--; continue }   # (a read that found it placed is no attempt)
                $card = if ($info.cardId) { $info.cardId } else { Add-ToBoard "$($info.nodeId)" }
                Move-Card @{ number = $n; cardId = $card } $intake
                $placed[$n] = $true; $fails = 0
                $acts.Add(@{ item = $n; action = 'board-added'; column = $intake; repaired = [bool]$info.cardId })
                try { Use-ItemLock $n { [void](Add-Journal $n $null 'board-added' @{ column = $intake } "$n") } 3 }
                catch { $acts.Add(@{ item = $n; action = 'board-added-unjournalled'; reason = "$($_.Exception.Message)" }) }
            } catch [FactoryReject] {
                if ($_.Exception.Code -eq 'github-rate-limited') { $acts.Add(@{ item = $n; action = 'board-add-failed'; reason = 'rate limited: the pass ends' }); return , $acts.ToArray() }
                $acts.Add(@{ item = $n; action = 'board-add-failed'; reason = "$($_.Exception.Message)" }); $fails++
            } catch { $acts.Add(@{ item = $n; action = 'board-add-failed'; reason = "$($_.Exception.Message)" }); $fails++ }
        }
        $page++
    } while ($chunk.Count -eq 100 -and $page -le 20)
    return , $acts.ToArray()
}

# Issue 65: the items an item waits for, from "Depends on #N" in its body (any case, a colon allowed, several numbers on the same line: "Depends
# on #291 and #292"; a list on the following lines is not read). Its own number is never a dependency.
function Get-ItemDependencies([int]$Item, [string]$Body) {
    $deps = @()
    foreach ($m in [regex]::Matches("$Body", '(?im)\bdepends[ \t]+on[ \t]*:?[ \t]*([^\r\n]*)')) {
        foreach ($d in [regex]::Matches($m.Groups[1].Value, '#(\d{1,7})\b')) { $v = [int]$d.Groups[1].Value; if ($v -ne $Item -and $deps -notcontains $v) { $deps += $v } }
    }
    return , $deps
}
# A dependency is met once it is merged or closed: closed, or (still open) in a hold column (the Release Queue: merged, waiting for production) or
# Done. An item that is not on the board is read once per sweep through the REST API; one that cannot be read counts as not met.
function Test-DependencyMet([int]$Dep, $ByNumber, $Cache) {
    $c = Get-Cfg
    if ($Cache.ContainsKey($Dep)) { return $Cache[$Dep] }
    $met = $false
    if ($ByNumber.ContainsKey($Dep)) {
        $d = $ByNumber[$Dep]; $col = "$($d.column)"
        $met = (-not $d.open) -or (Test-NameIn $col $c.columns.hold) -or ($col -and $col -ieq "$($c.columns.done)")
    } else {
        try { $iss = Invoke-Gh -Path "$(Get-RepoPath)/issues/$Dep"; $met = "$($iss.state)" -eq 'closed' } catch { $met = $false }
    }
    $Cache[$Dep] = $met; return $met
}

# items (issue 92): an incremental pass over those items only (the gateway queues the item of a webhook or a verb between full sweeps): the same rules,
# each item read by itself instead of the whole board, and no claim-ref reaping and no QC sync (both are about the whole board). low: the gateway's
# GitHub budget is below its reserve; the full sweep skips the claim-ref reaping and the QC sync, which can wait for the reset.
function Verb_sync_board($a) {
    $c = Get-Cfg; $t = $c.timing
    $dry = (Test-Has $a 'dry') -and $a.dry
    # gap { since, until }: the gateway was down in between (Leader.cs); see Invoke-GapRenew
    $gap = $null
    if ((Test-Has $a 'gap') -and (Test-Has $a.gap 'since') -and (Test-Has $a.gap 'until')) { $gap = @{ since = (ConvertFrom-Iso $a.gap.since); until = (ConvertFrom-Iso $a.gap.until) } }
    $only = $null
    if (Test-Has $a 'items') { $only = @($a.items | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 } | Select-Object -Unique -First 50) }
    $low = (Test-Has $a 'low') -and $a.low
    $skipped = @()
    $seenFile = Get-SeenFile
    $seen = if (Test-Path $seenFile) { Get-Content -Raw $seenFile | ConvertFrom-Json -AsHashtable } else { @{} }
    $offers = @(); $actions = @(); $errors = @(); $owners = @{}; $pins = @{}; $triggers = @(); $flags = @(); $rtLabels = @{}; $profiles = @{}
    # priorities: the priority label of each item that has one (top, high), for the order of the plan (Plant.Plan)
    $priorities = @{}
    # holds: the items labelled hold:owner (ownerHoldLabel); the plant manager's name actions leave the sessions that own one alone (Manager.cs)
    $holds = @(); $holdLabel = if (Test-Has $c 'ownerHoldLabel') { "$($c.ownerHoldLabel)" } else { 'hold:owner' }
    # owned: every live owned claim with what the digest needs of it (worker-messaging.md 3.9); settling: items whose merge is being settled (their
    # owner was released at item.merged)
    $owned = @{}; $settling = @(); $unconfirmed = @()
    # pass_unmerged: every item with a PASS verdict that the gateway is to merge and has not merged yet, with why (a reason code) and since when
    $passUnmerged = @()
    # release_queue: the items that wait in the Release Queue for the production deployment, with their release and since when (enhancement 9)
    $releaseQueue = @()
    # unparked: items whose park the sweep removed because they are closed (issue 82); the plant forgets their parks
    $unparked = @()
    # parks: every parked item the sweep read (issue 99)
    $parks = @()
    # design_waiting: open factory items in the backlog keeper's column (keeper.newItemColumn, Technical Design); fewer than keeper.minTechnicalDesign
    # send the keeper backlog-low (gateway/Keeper.cs)
    $designWaiting = 0; $designCol = if ((Test-Has $c 'keeper') -and (Test-Has $c.keeper 'newItemColumn')) { "$($c.keeper.newItemColumn)" } else { 'Technical Design' }
    $list = if ($null -ne $only) {
        # one read per item (the board list is one read per 100 cards): an item without a card on the board is not factory work here
        @(foreach ($n0 in $only) { try { $i0 = Get-ItemInfo $n0; if ($i0.cardId) { $i0 } } catch [FactoryReject] { if ($_.Exception.Code -notin 'github-not-found', 'item-not-found') { $errors += @{ item = $n0; code = $_.Exception.Code; reason = $_.Exception.Message } } } })
    } else { Get-BoardList }
    $last = Get-LastColumn
    $unparkCtx = @{ free_workers = $(if (Test-Has $a 'free_workers') { [int]$a.free_workers } else { 0 }) }
    foreach ($it in $list) {
        # a closed item is still followed when its merged pull request closed it and the flow after the merge is not finished
        if (-not (Test-NameIn $c.label $it.labels)) { continue }
        # (issue 82: a closed item in any column the factory works is read too, so a park it was left with is removed below)
        if (-not $it.open -and -not ((Test-NameIn "$($it.column)" $c.columns.ai) -or (Test-NameIn "$($it.column)" $c.columns.hold))) { continue }
        $n = $it.number; $col = "$($it.column)"
        if ($it.open -and $col -ieq $designCol) { $designWaiting++ }
        if (Test-NameIn $c.rivalLabel $it.labels) { $actions += @{ item = $n; action = 'skip'; reason = 'ambiguous-owner' }; continue }
        if (-not $col -or $col -ieq $last) { continue }
        try {
            $isAi = Test-NameIn $col $c.columns.ai; $isHold = Test-NameIn $col $c.columns.hold
            if (-not $isAi -and -not $isHold) { $seen.Remove("$n"); continue }
            $st = Get-State $n; $s = $st.state
            if ($it.open -and -not $dry -and (Test-Has $s 'park') -and -not (Get-Park $s) -and ((Test-Has $s 'fix_forward_rounds') -or (Test-Has $s 'demotions') -or (Test-Has $s 'master_defect'))) {
                $xp = Reset-ExpiredPark $n
                if ($xp) { $actions += @{ item = $n; action = 'park-expired'; code = $xp; reset = $true }; $unparked += $n; $st = Get-State $n; $s = $st.state }
            }
            $pin = @($it.labels | Where-Object { $_ -like 'worker:*' } | Select-Object -First 1)
            if ($pin.Count -gt 0) { $pins["$n"] = ([string]$pin[0]).Substring(7) }
            $prio = Get-ItemPriority $it.labels; if ($prio) { $priorities["$n"] = $prio }
            if (Test-NameIn $holdLabel $it.labels) { $holds += $n }
            $merged = (Test-Has $s 'merge') -and (Test-Has $s.merge 'sha') -and $s.merge.sha
            $settled = $merged -and (Test-Has $s.merge 'done_at') -and $s.merge.done_at
            # cloud-worker-runtimes.md 4.4: a runtime:<kind> label forces the item's runtime; the test label selects the cheapest model profile
            $rtl = @($it.labels | Where-Object { $_ -match '^runtime:[a-z0-9-]{1,20}$' } | Select-Object -First 1)
            if ($rtl.Count -gt 0) { $rtLabels["$n"] = ([string]$rtl[0]).Substring(8) }
            # agents-roles-launch.md 10: the api mode (Cursor Cloud Agents) takes docs-only items only in v1: Technical Design (which decides docs-only)
            # and the later columns of an item whose design carries the marker; any other item labelled for it goes the ordinary way
            if ($rtLabels["$n"] -eq 'cursor-cloud' -and $col -ine $designCol -and -not (Test-ItemDocsOnly $s $it)) { $rtLabels.Remove("$n"); $actions += @{ item = $n; action = 'runtime-label-ignored'; runtime = 'cursor-cloud'; reason = 'not-docs-only' } }
            if ($c.testLabel -and (Test-NameIn $c.testLabel $it.labels)) { $profiles["$n"] = 'testing' }
            if (-not $it.open -and -not ((Test-Has $s 'merge') -and (Test-Has $s.merge 'awaiting') -and $s.merge.awaiting)) {
                # issue 114: a closed item with a merge record that is not done was stranded by an older gateway (262, 280): its settle is re-armed
                if ($merged -and -not $settled -and -not $dry) {
                    $w = try { Invoke-RearmSettle $n 'closed with a merge record and no settle step' } catch [FactoryReject] { if ($_.Exception.Code -ne 'item-busy') { throw }; '' }
                    if ($w) { $actions += @{ item = $n; action = 'settle-rearmed'; awaiting = $w }; $settling += $n; continue }
                }
                # issue 82: a closed item whose flow has ended keeps no park (280 stayed parked master-broken after it was closed)
                if ((Test-Has $s 'park') -and -not $dry) { $r = Clear-ClosedPark $n; if ($r) { $actions += @{ item = $n; action = 'park-cleared'; reason = 'item-closed'; code = $r }; $unparked += $n } }
                continue
            }
            # a closed item outside Functional Testing and the hold columns is followed no further, as before (only its park was of interest)
            if (-not $it.open -and -not (("$($it.column)" -ieq $c.columns.validation) -or (Test-NameIn "$($it.column)" $c.columns.hold))) { continue }
            if ($gap -and -not $dry -and (Test-OwnedClaim $s) -and -not (Test-ClaimLive $s)) {
                $lu0 = ConvertFrom-Iso $s.claim.lease_until
                if ($lu0 -and $lu0 -ge $gap.since -and $lu0 -le $gap.until) {
                    $gh = Invoke-GapRenew $n $gap
                    if ($gh) { $st = Get-State $n; $s = $st.state; $actions += @{ item = $n; action = 'claim-renewed-after-gap'; holder = $gh; lapsed = (ConvertTo-Iso $lu0) } }
                }
            }
            if ((Test-OwnedClaim $s) -and (Test-ClaimLive $s)) {
                $owners["$n"] = "$($s.claim.holder)"
                $owned["$n"] = @{ holder = "$($s.claim.holder)"; column = $col; lease_until = $s.claim.lease_until; heartbeat = $(if (Test-Has $s.claim 'heartbeat') { $s.claim.heartbeat } else { $null }); parked = [bool](Get-Park $s) }
            }
            if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'awaiting') -and $s.merge.awaiting) {
                # (an item that waits for a person, master red or no release candidate for a day, keeps no owner: issue 114)
                if ("$($s.merge.awaiting)" -notin 'master-broken', 'master-timeout' -and -not ((Test-Has $s.merge 'late_reported') -and $s.merge.late_reported)) { $settling += $n }
                # a master-broken park is lifted only by auto-unpark's rule (the checks that failed passed on master; judged on that head): it puts
                # the wait back to master-green, and the next sweep settles it
                $mbPark = Get-Park $s
                if ("$($s.merge.awaiting)" -eq 'master-broken' -and $mbPark -and "$($mbPark.reason)" -eq 'master-broken') {
                    if (-not $dry) {
                        $why = Test-AutoUnpark $n $s $mbPark $unparkCtx
                        if ($why) { $u = Invoke-AutoUnpark $n $mbPark $why $unparkCtx; if ($u) { $actions += @{ item = $n; action = 'auto-unparked'; code = $u.code; reason = $why }; $unparked += $n } }
                    }
                    continue
                }
                if (-not $dry) { $r = Invoke-SettleLocked $n; $actions += @{ item = $n; action = 'settle'; result = $r } }
                # (a busy lock skips this sweep: an item that waits in the Release Queue is still listed, from the state the sweep read)
                if (-not $dry -and $r.outcome -eq 'busy' -and "$($s.merge.awaiting)" -eq 'release-queue') { $r = @{ outcome = 'waiting'; awaiting = 'release-queue'; release = "$($s.merge.release)"; queued_at = $(if (Test-Has $s.merge 'queued_at') { $s.merge.queued_at } else { $null }) } }
                if (-not $dry -and $r.outcome -in 'advanced', 'waiting' -and (Test-Has $r 'awaiting') -and $r.awaiting -eq 'release-queue') {
                    $releaseQueue += @{ item = $n; release = $(if (Test-Has $r 'release') { "$($r.release)" } else { '' }); since = $(if (Test-Has $r 'queued_at') { $r.queued_at } else { $null }) }
                }
                if (-not $dry -and ($r.outcome -eq 'done' -or ($r.outcome -eq 'advanced' -and (Test-Has $r 'awaiting') -and $r.awaiting -eq 'release-queue'))) { $triggers += @{ item = $n; event = 'item.complete'; path = $(if (Test-Has $r 'path') { "$($r.path)" } else { '' }) } }
                elseif (-not $dry -and $r.outcome -eq 'parked') { $triggers += @{ item = $n; event = 'item.parked'; reason = $r.reason } }
                if (-not $dry -and (Test-Has $r 'recovered') -and $r.recovered) { $unparked += $n }   # its master-broken or timeout park is gone
                continue
            }
            # issue 114: an item with a merge record is never offered to a worker (272 and 276 were validated again after their merge): one without a
            # settle step and not done gets it back (an older gateway erased it), a done one is left alone
            if ($merged) {
                if (-not $settled -and -not $dry) {
                    $w = try { Invoke-RearmSettle $n 'merged with no settle step' } catch [FactoryReject] { if ($_.Exception.Code -ne 'item-busy') { throw }; '' }
                    if ($w) { $actions += @{ item = $n; action = 'settle-rearmed'; awaiting = $w }; $settling += $n }
                }
                continue
            }
            if ($isHold) {
                # issue 117: only settle moves a card into the Release Queue, and only a merged one: an open item there without a merge record got
                # there some other way (290). It is flagged once (a journal line, and the sweep's flags for the operator stream); nothing moves it.
                if ($it.open -and -not $merged) {
                    $flags += @{ item = $n; code = 'release-queue-without-merge'; column = $col }
                    if (-not $dry) { try { [void](Use-ItemLock $n { $f = Get-State $n; if (-not ((Test-Has $f.state 'merge') -and (Test-Has $f.state.merge 'sha') -and $f.state.merge.sha)) { if (Add-Journal $n $f 'flagged' @{ column = $col; code = 'release-queue-without-merge'; reason = 'the card is in the Release Queue but the item has no merge record (its pull request is not merged by the factory); a person moves it back' } "rq-no-merge") { Save-State $n $f } } } 3) } catch [FactoryReject] { if ($_.Exception.Code -ne 'item-busy') { throw } } }
                }
                continue
            }
            if (Test-NameIn $c.demoLabel $it.labels) { continue }
            # A person merged the item's pull request: pick the merge up, whatever state the item was in (a PASS waiting for the gateway's merge, a
            # PASS parked for a person because the item has no Auto Merge label, an item still in Development, a parked or unowned item). The pull
            # request is the one of the PASS verdict, else the one open-pr recorded; not one whose merge a FAIL verdict already judged (residual gaps).
            $unprocessedPass = $col -ieq $c.columns.validation -and (Test-Has $s 'verdict') -and $s.verdict.passed -and -not $s.verdict.processed
            $ownPr = 0
            if ((Test-Has $s 'verdict') -and $s.verdict.passed -and [int]$s.verdict.pr -gt 0) { $ownPr = [int]$s.verdict.pr }
            elseif ((Test-Has $s 'pr') -and (Test-Has $s.pr 'number') -and -not (Test-Has $s.pr 'residual')) { $ownPr = [int]$s.pr.number }
            $pr = $null
            if ($ownPr -gt 0 -and ($unprocessedPass -or -not (Test-Has $s 'merge'))) { $pr = try { Get-Pr $ownPr } catch { $null } }
            if ($pr -and $pr.merged -and ($unprocessedPass -or (Test-PrBelongs $pr $n))) {
                if ($dry) { continue }
                if (-not (Invoke-MergePickup $n $pr)) { continue }
                # the flow after a merge starts from the validation column (settle moves the card on from there)
                if ((Get-ColumnIndex $col) -ge 0 -and (Get-ColumnIndex $col) -lt (Get-ColumnIndex $c.columns.validation)) { Move-Card (Get-ItemInfo $n) $c.columns.validation }
                Add-Comment $n "PR #$($pr.number) was merged as ``$($pr.merge_commit_sha.Substring(0,7))``$(if (-not $unprocessedPass) { ' by a person' }); watching master CI, then the release candidate."
                $actions += @{ item = $n; action = 'merge-detected'; sha = $pr.merge_commit_sha }
                $settling += $n; $triggers += @{ item = $n; event = 'item.merged' }
                continue
            }
            # a hold label (holdLabels, issue 109): a person holds the item. Nothing is offered or merged for it (its open offer is dropped because the
            # plan no longer asks for it); a merge the person makes is still picked up above and settled.
            $hold = Get-HoldLabel $it.labels
            if ($hold) { $actions += @{ item = $n; action = 'skip'; reason = 'held-by-label'; label = $hold }; continue }
            if ($unprocessedPass) {
                # the pull request of a PASS verdict was closed without merging: the verdict is void, so the item goes back to Development
                if ($pr -and -not $pr.merged -and "$($pr.state)" -eq 'closed') {
                    if (-not $dry) { $info = Get-ItemInfo $n; $dr = Invoke-Demote $n $info $st "PR #$($pr.number) was closed without merging; the PASS verdict no longer applies." 'pr-closed'; $actions += @{ item = $n; action = 'demote'; reason = 'pr-closed' } }
                    continue
                }
                $held = Get-Park $s
                if ($held) {
                    $parks += @{ item = $n; column = $col; code = "$($held.reason)"; since = $held.at; until = $held.until }   # issue 99
                    if ($held.reason -eq 'inspector-escalated' -and $pr -and -not $dry) {
                        $info = Get-ItemInfo $n
                        if (Invoke-ClearHoldIfApproved $n $info $st $pr) {
                            $actions += @{ item = $n; action = 'hold-cleared' }
                            $triggers += @{ item = $n; event = 'hold.cleared' }
                            if (-not (Test-ClaimLive $s)) { $offers += @{ item = $n; column = $col; reason = 'ready-to-merge'; kind = 'own-item'; mode = 'resume' } }
                        }
                    }
                    elseif ((Test-OwnedClaim $s) -and ((Get-UtcNow) - (ConvertFrom-Iso $held.at)).TotalMinutes -gt [double]$c.idleReleaseMinutes -and -not $dry) {
                        # an owner waiting out a hold for too long gives the item up; the next trigger assigns it again
                        $holderName = "$($s.claim.holder)"
                        # (under the item lock on a fresh read, as above; given up only if the same owner still waits on the same hold)
                        $did = Use-ItemLock $n {
                            $f = Get-State $n; $fs = $f.state; $fh = Get-Park $fs
                            if ((Test-OwnedClaim $fs) -and "$($fs.claim.holder)" -eq $holderName -and $fh -and "$($fh.at)" -eq "$($held.at)") {
                                $fs.Remove('claim'); [void](Add-Journal $n $f 'released' @{ worker = $holderName; reason = "idle for more than $($c.idleReleaseMinutes) min on a hold" } "idle|$($held.at)"); Save-State $n $f; Remove-ClaimRef $n; $true
                            } else { $false }
                        }
                        if (-not $did) { continue }
                        $actions += @{ item = $n; action = 'owner-released-idle'; worker = $holderName }
                        $owned.Remove("$n")
                    }
                    continue
                }
                # Merge policy auto with the gateway merging (Verbs.Merge.ps1): the item is the gateway's from the verdict to the merge. It is never
                # offered to a worker in this state (a session could not claim it: verdict-already-recorded), whether its owner is still there or not.
                # The merge runs under the item lock on a fresh read, so a second sweep or the session's own merge call finds the verdict processed.
                if ($c.mergePolicy -eq 'auto' -and (Test-GatewayMerge)) {
                    if (-not $pr -or $dry) { continue }
                    $vat = ConvertFrom-Iso $s.verdict.at; $age = if ($vat) { ((Get-UtcNow) - $vat).TotalSeconds } else { 1e9 }
                    $grace = if (Test-Has $t 'passMergeGraceSeconds') { [double]$t.passMergeGraceSeconds } else { 60 }
                    # the grace leaves the verdict call (and the session's merge call right after it) alone; once the gateway has tried, none is needed
                    if ($age -lt $grace -and -not (Test-Has $s.verdict 'wait')) { $passUnmerged += @{ item = $n; code = 'grace'; since = $s.verdict.at; pr = [int]$s.verdict.pr }; $unconfirmed += $n; continue }
                    $gm = try {
                        Use-ItemLock $n {
                            $f = Get-State $n; $fs = $f.state
                            if (-not ((Test-Has $fs 'verdict') -and $fs.verdict.passed -and -not $fs.verdict.processed)) { @{ outcome = 'skipped'; reason = 'settled-meanwhile' } }
                            elseif (-not (Test-Label (Get-ItemInfo $n) $c.autoMergeLabel)) {
                                # the label was taken off after the verdict: what the verdict does for an item without it
                                $fs.verdict.processed = $true; Set-Park $fs 'pass-without-auto-merge' ($t.parkHours * 60); $fs.Remove('claim'); Save-State $n $f; Remove-ClaimRef $n
                                Add-Comment $n "validation PASSED - awaiting human merge (the '$($c.autoMergeLabel)' label is no longer on the item; the gateway will not merge)."
                                @{ outcome = 'parked'; reason = 'pass-without-auto-merge' }
                            }
                            else { Verb_merge @{ item = $n } -Gateway }
                        } 3
                    } catch [FactoryReject] {
                        # item-busy: a verb of the item is running (the session's own merge call): the next sweep looks again. Anything else the merge
                        # verb refuses (the card was moved, the item closed) is not a merge the gateway may make.
                        if ($_.Exception.Code -in 'github-not-found', 'item-not-found') { throw }
                        @{ outcome = $(if ($_.Exception.Code -eq 'item-busy') { 'waiting' } else { 'skipped' }); reason = $_.Exception.Code }
                    }
                    $actions += @{ item = $n; action = 'pass-merge'; outcome = "$($gm.outcome)"; reason = $(if (Test-Has $gm 'reason') { "$($gm.reason)" } else { '' }); roundTrip = $(if ((Test-Has $gm 'detail') -and (Test-Has $gm.detail 'round_trip')) { [int]$gm.detail.round_trip } else { 0 }); masterDefectNew = ((Test-Has $gm 'masterDefectNew') -and $gm.masterDefectNew) }
                    $ownedLive = (Test-OwnedClaim $s) -and (Test-ClaimLive $s)
                    switch ("$($gm.outcome)") {
                        { $_ -in 'merged', 'already-merged' } { $settling += $n; $triggers += @{ item = $n; event = 'item.merged' } }
                        'demoted' {
                            # back in Development: its owner is told as for checks that failed (fix forward); without an owner it is offered
                            $rt = if ((Test-Has $gm 'detail') -and (Test-Has $gm.detail 'round_trip')) { [int]$gm.detail.round_trip } else { 1 }
                            if ($ownedLive) { $triggers += @{ item = $n; event = 'checks.failed'; column = $c.columns.development; reason = 'merge-demoted'; roundTrip = $rt } }
                            else { $offers += @{ item = $n; column = $c.columns.development; reason = 'handoff' } }
                        }
                        'parked' { $triggers += @{ item = $n; event = 'item.parked'; reason = "$($gm.reason)" } }
                        'waiting' { $passUnmerged += @{ item = $n; code = "$($gm.reason)"; since = $s.verdict.at; pr = [int]$s.verdict.pr }; if ("$($gm.reason)" -in 'item-busy', 'mergeability-unknown', 'branch-updated') { $unconfirmed += $n } }
                    }
                    continue
                }
                if ($pr) {
                    $has = (Test-Has $s 'approval') -and $s.approval.sha -eq $pr.head.sha
                    if ($c.mergePolicy -eq 'auto') { if (-not (Test-ClaimLive $s)) { $offers += @{ item = $n; column = $col; reason = 'ready-to-merge'; kind = 'own-item'; mode = 'resume' } } }
                    elseif (Test-OwnerMode) {
                        if (-not $has) { if (-not (Test-BotLive $s)) { $offers += @{ item = $n; column = $col; reason = 'needs-approval'; kind = 'bot-job'; role = 'inspector'; pr = [int]$s.verdict.pr } } }
                        elseif (-not (Test-ClaimLive $s)) { $offers += @{ item = $n; column = $col; reason = 'ready-to-merge'; kind = 'own-item'; mode = 'resume' } }
                    }
                    elseif (-not (Test-ClaimLive $s)) { $offers += @{ item = $n; column = $col; reason = $(if ($has) { 'ready-to-merge' } else { 'needs-approval' }) } }
                }
                continue
            }
            $park = Get-Park $s
            if ($park) {
                # issue 99: every park, for the status's list of unowned items and why they wait
                $parks += @{ item = $n; column = $col; code = "$($park.reason)"; since = $park.at; until = $park.until }
                if ($park.reason -eq 'development:awaiting-checks' -and (Test-Has $s 'awaiting_checks') -and -not $dry) {
                    $r = Invoke-AwaitingChecksLocked $n
                    $actions += @{ item = $n; action = 'awaiting-checks'; result = $r }
                    if ($r.outcome -in 'completed', 'fix-forward') { $seen.Remove("$n") }
                    if (Test-OwnedClaim $s) {
                        if ($r.outcome -eq 'completed') { $triggers += @{ item = $n; event = 'column.advanced'; to = $r.moved_to } }
                        elseif ($r.outcome -eq 'fix-forward') { $triggers += @{ item = $n; event = 'checks.failed'; column = $c.columns.development } }
                        elseif ($r.outcome -eq 'parked') { $triggers += @{ item = $n; event = 'item.parked'; reason = $r.reason } }
                    } else {
                        if ($r.outcome -eq 'completed') { $offers += @{ item = $n; column = $r.moved_to; reason = 'handoff' } }
                        if ($r.outcome -eq 'fix-forward') { $offers += @{ item = $n; column = $c.columns.development; reason = 'fix-forward' } }
                    }
                }
                elseif (-not $dry) {
                    $why = Test-AutoUnpark $n $s $park $unparkCtx
                    if ($why) {
                        $u = Invoke-AutoUnpark $n $park $why $unparkCtx
                        if ($u) {
                            $actions += @{ item = $n; action = 'auto-unparked'; code = $u.code; reason = $why }; $unparked += $n
                            if ($u.code -in 'session-relaunch-budget', 'watchdog-relaunch-budget') { $unparkCtx.free_workers = [int]$unparkCtx.free_workers - 1 }
                            if ($u.handoff) { $offers += @{ item = $n; column = $col; reason = 'handoff' } }
                            # an owner that still holds the claim (owner mode keeps it across a fix-forward wait) is told, so it carries on
                            if ($u.owned) { $triggers += @{ item = $n; event = 'item.unparked'; code = $u.code; reason = $why } }
                        }
                    }
                }
                continue
            }
            if (Test-ClaimLive $s) { continue }
            if (Test-Has $s 'claim') { $offers += @{ item = $n; column = $col; reason = 'relaunch'; kind = 'own-item'; mode = $(if (Test-OwnedClaim $s) { 'resume' } else { 'relaunch' }) }; continue }
            if ((Test-Has $s 'handoff') -and $s.handoff.column -ieq $col) { $offers += @{ item = $n; column = $col; reason = 'handoff' }; continue }
            $prev = if ($seen.ContainsKey("$n")) { $seen["$n"] } else { @{ column = ''; count = 0 } }
            $count = if ($prev.column -ieq $col) { [int]$prev.count + 1 } else { 1 }
            $seen["$n"] = @{ column = $col; count = $count }
            if ($count -ge [int]$t.sweepSeenCount) { $offers += @{ item = $n; column = $col; reason = 'board-move' } }
            else { $unconfirmed += $n }   # seen, not yet offered: the gateway looks again soon instead of a whole interval later
        } catch [FactoryReject] {
            # an item (or its card) that vanished while the sweep was reading it is not an error: the next sweep sees the board as it is
            if ($_.Exception.Code -in 'github-not-found', 'item-not-found') { $actions += @{ item = $n; action = 'skip'; reason = 'vanished-during-sweep' } }
            else { $errors += @{ item = $n; code = $_.Exception.Code; reason = $_.Exception.Message } }
        }
        catch { $errors += @{ item = $n; code = 'error'; reason = "$($_.Exception.Message)" } }
    }
    # issue 65: an item is offered to nobody while an item it depends on is neither merged nor closed. The seen count goes on meanwhile, so the
    # sweep after its last dependency was merged offers it at once. held: the items that wait, with the code and the numbers they wait for.
    $held = @(); $byNumber = @{}; foreach ($x in $list) { $byNumber[[int]$x.number] = $x }; $depCache = @{}
    $kept = @()
    foreach ($o in $offers) {
        # a failure here offers the item (fail open, as before this rule) and is reported; it never stops the sweep
        try {
            $kind = if ($o.ContainsKey('kind')) { "$($o.kind)" } else { 'own-item' }
            $it = $byNumber[[int]$o.item]
            $deps = if ($kind -eq 'own-item' -and $it) { Get-ItemDependencies ([int]$o.item) "$($it.body)" } else { @() }
            $open = @($deps | Where-Object { -not (Test-DependencyMet $_ $byNumber $depCache) })
        } catch { $errors += @{ item = [int]$o.item; code = 'depends-on-check'; reason = "$($_.Exception.Message)" }; $open = @() }
        if ($open.Count -gt 0) { $held += @{ item = [int]$o.item; column = "$($o.column)"; code = 'depends-on'; on = $open } }
        else { $kept += $o }
    }
    $offers = $kept
    if (-not $dry) { $seen | ConvertTo-Json -Depth 5 | Set-Content $seenFile }
    # claim refs with no live claim behind them (issue 47): removed at once for a closed item, after a lease for an open one
    if ($null -ne $only) { }
    elseif ($low) { $skipped += 'claim-ref-reap' }
    elseif (-not $dry) {
        try { $actions += @(Invoke-ClaimRefReap $list) }
        catch [FactoryReject] { $errors += @{ item = 0; code = $_.Exception.Code; reason = "claim-ref-reap: $($_.Exception.Message)" } }
        catch { $errors += @{ item = 0; code = 'error'; reason = "claim-ref-reap: $($_.Exception.Message)" } }
    }
    # work intake (issue 104): with a worker slot free and nothing waiting in Technical Design, the next item comes onto the board from Todo (a full sweep only: it needs the whole board)
    if (-not $dry -and $null -eq $only) {
        try { $in = Invoke-Intake $a $list $offers $unconfirmed $pins $seen $seenFile; if ($in) { $actions += $in.action; $offers += $in.offer } }
        catch [FactoryReject] { $errors += @{ item = 0; code = $_.Exception.Code; reason = "intake: $($_.Exception.Message)" } }
        catch { $errors += @{ item = 0; code = 'error'; reason = "intake: $($_.Exception.Message)" } }
    }
    # the board guard: open labelled issues without a card are put on the board in the intake column (they are offered from the next sweeps); it
    # needs the whole board, so a full sweep only, and not on a low budget (it lists every labelled issue)
    if ($null -ne $only) { }
    elseif ($low) { $skipped += 'board-guard' }
    elseif (-not $dry) {
        try { $actions += Invoke-BoardGuard $list }
        catch [FactoryReject] { $errors += @{ item = 0; code = $_.Exception.Code; reason = "board-guard: $($_.Exception.Message)" } }
        catch { $errors += @{ item = 0; code = 'error'; reason = "board-guard: $($_.Exception.Message)" } }
    }
    # PR QC environments: offers and teardowns only, never a start (design pr-qc-environment.md 3.5)
    $qcRecords = @(); $qcTeardowns = @(); $qcApprovals = @()
    if ((Test-QcEnabled) -and $low -and $null -eq $only) { $skipped += 'qc-sync' }
    if ((Test-QcEnabled) -and -not $low -and $null -eq $only) {
        try { $qs = Invoke-QcSync $list $dry; $actions += @($qs.actions); $errors += @($qs.errors); $qcRecords = @($qs.records); $qcTeardowns = @($qs.teardowns); $qcApprovals = @($qs.approvals) }
        catch [FactoryReject] { $errors += @{ item = 0; code = $_.Exception.Code; reason = "qc-sync: $($_.Exception.Message)" } }
        catch { $errors += @{ item = 0; code = 'error'; reason = "qc-sync: $($_.Exception.Message)" } }
    }
    return @{ ok = $true; offers = $offers; design_waiting = $(if ($null -ne $only) { $null } else { $designWaiting }); held = $held; parks = $parks; actions = $actions; errors = $errors; owners = $owners; owned = $owned; settling = $settling; release_queue = $(if ($dry -or $null -ne $only) { $null } else { $releaseQueue }); pins = $pins; runtimes = $rtLabels; profiles = $profiles; priorities = $priorities; holds = $holds; triggers = $triggers; unconfirmed = $unconfirmed; pass_unmerged = $passUnmerged; unparked = $unparked; flags = $flags; qc = $qcRecords; qc_teardowns = $qcTeardowns; qc_approvals = $qcApprovals; incremental = ($null -ne $only); items = $(if ($null -ne $only) { @($only) } else { $null }); skipped = $skipped; at = ConvertTo-Iso (Get-UtcNow) }
}

# ---- work intake (issue 104) -----------------------------------------------------------------------------------------
# When a worker slot is free (the gateway passes intake.freeSlots: owner sessions that could take a new work item now) and nothing waits in Technical
# Design (no unpinned own-item offer there, no item there seen and not yet offered), the highest-priority open issue labelled for the factory in
# intake.fromColumn (Todo) is moved to Technical Design and offered at once. Priority is the order of the board column (its top first; a person
# orders it by dragging). Left in Todo: a closed issue, one without the label or with the rival label, the demo label, a hold label (hold:* or
# intake.holdLabels), a worker:* pin (a person placed it for one worker), and one whose Depends-on items are not merged or closed. At most one
# item per sweep, and none while the AI columns hold intake.wipLimit items or more. Switch: intake.enabled (FACTORY_INTAKE 0 or 1 overrides it;
# FACTORY_INTAKE_WIP overrides the limit). Returns $null or @{ action; offer }.
function Get-IntakeSettings {
    $c = Get-Cfg; $i = if (Test-Has $c 'intake') { $c.intake } else { @{} }
    $on = (Test-Has $i 'enabled') -and [bool]$i.enabled
    if ($env:FACTORY_INTAKE -in '0', '1') { $on = $env:FACTORY_INTAKE -eq '1' }
    $wip = if ($env:FACTORY_INTAKE_WIP -match '^\d+$') { [int]$env:FACTORY_INTAKE_WIP } elseif (Test-Has $i 'wipLimit') { [int]$i.wipLimit } else { 6 }
    return @{ enabled = $on; from = $(if (Test-Has $i 'fromColumn') { "$($i.fromColumn)" } else { 'Todo' }); wip = $wip
        hold = @(if (Test-Has $i 'holdLabels') { @($i.holdLabels) }) }
}

function Invoke-Intake($a, $List, $Offers, $Unconfirmed, $Pins, $Seen, [string]$SeenFile) {
    $set = Get-IntakeSettings
    if (-not $set.enabled -or -not (Test-Has $a 'intake') -or -not (Test-Has $a.intake 'freeSlots') -or [int]$a.intake.freeSlots -le 0) { return $null }
    $c = Get-Cfg; $td = "$(@($c.columns.ai)[0])"
    $byNumber = @{}; foreach ($x in $List) { $byNumber[[int]$x.number] = $x }
    # something already waits in Technical Design for a session: no intake (an item pinned to one worker waits for that worker, not for a slot)
    $waiting = @(@($Offers | Where-Object { "$($_.column)" -ieq $td -and (-not $_.ContainsKey('kind') -or "$($_.kind)" -eq 'own-item') -and -not $Pins.ContainsKey("$($_.item)") }) +
        @($Unconfirmed | Where-Object { $byNumber.ContainsKey([int]$_) -and "$($byNumber[[int]$_].column)" -ieq $td -and -not $Pins.ContainsKey("$_") }))
    if ($waiting.Count -gt 0) { return $null }
    $wip = @($List | Where-Object { $_.open -and (Test-NameIn $c.label $_.labels) -and (Test-NameIn "$($_.column)" $c.columns.ai) }).Count
    if ($wip -ge $set.wip) { return $null }
    $depCache = @{}
    foreach ($it in $List) {
        if (-not $it.open -or "$($it.column)" -ine $set.from -or -not (Test-NameIn $c.label $it.labels)) { continue }
        if ((Test-NameIn $c.rivalLabel $it.labels) -or (Test-NameIn $c.demoLabel $it.labels)) { continue }
        if (@($it.labels | Where-Object { "$_" -like 'hold:*' -or "$_" -like 'worker:*' -or (Test-NameIn "$_" $set.hold) }).Count -gt 0) { continue }
        if (-not $it.cardId) { continue }
        # Depends-on (issue 65): read with the sweep's own functions when this gateway has them
        if (Get-Command Get-ItemDependencies -ErrorAction SilentlyContinue) {
            $body = if ($it.ContainsKey('body')) { "$($it.body)" } else { "$((Get-ItemInfo ([int]$it.number)).body)" }
            $deps = Get-ItemDependencies ([int]$it.number) $body
            if (@($deps | Where-Object { -not (Test-DependencyMet $_ $byNumber $depCache) }).Count -gt 0) { continue }
        }
        $n = [int]$it.number
        Move-Card @{ number = $n; cardId = $it.cardId } $td
        # offered at once by this sweep, and by the next ones as a card that was seen in its column
        $Seen["$n"] = @{ column = $td; count = [int]$c.timing.sweepSeenCount }; $Seen | ConvertTo-Json -Depth 5 | Set-Content $SeenFile
        $jf = @{ column = $td; from = $set.from; slots = [int]$a.intake.freeSlots; wip = $wip; wipLimit = $set.wip }; $jk = "intake|$((Get-UtcNow).Ticks)"
        try { [void](Use-ItemLock $n { $f = Get-State $n; if (Add-Journal $n $f 'pulled' $jf $jk) { Save-State $n $f } } 5) } catch [FactoryReject] { if ($_.Exception.Code -ne 'item-busy') { throw } }
        return @{ action = @{ item = $n; action = 'intake-pulled'; column = $td; from = $set.from; wip = $wip }; offer = @{ item = $n; column = $td; reason = 'intake' } }
    }
    return $null
}

# ---- event intake ---------------------------------------------------------------------------------------------------
function New-Event([string]$Event, $Item, $Column, [string]$Ref, [hashtable]$Extra = @{}) {
    $e = @{ provider = 'github'; event = $Event; item = $Item; column = $Column; ref = $Ref; at = ConvertTo-Iso (Get-UtcNow) }
    foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
    return $e
}

function Verb_ingest_event($a) {
    $c = Get-Cfg
    $event = "$(Need $a 'event')"; $delivery = if (Test-Has $a 'delivery') { "$($a.delivery)" } else { '' }
    $p = $a.payload
    $out = @()
    $repoOk = $true
    if ((Test-Has $p 'repository')) { $repoOk = ($p.repository.full_name -ieq "$($c.owner)/$($c.repo)") }
    if (-not $repoOk) { return @{ ok = $true; events = @(); dropped = 'other-repository' } }
    switch ($event) {
        'issues' {
            $act = "$($p.action)"; $num = [int]$p.issue.number
            $labels = @($p.issue.labels | ForEach-Object { $_.name })
            $mine = (Test-NameIn $c.label $labels)
            if ($act -eq 'labeled' -and $p.label.name -ieq $c.label) {
                $col = try { (Get-ItemInfo $num).column } catch { $null }
                $out += New-Event 'item.labeled' $num $col $delivery
            } elseif ($act -in 'closed', 'reopened' -and $mine) { $out += New-Event "item.$act" $num $null $delivery }
        }
        'workflow_run' {
            $run = $p.workflow_run; $act = "$($p.action)"; $branch = "$($run.head_branch)"
            $kind = if ($act -eq 'completed') { 'completed' } elseif ($act -eq 'in_progress') { 'started' } else { $null }
            if ($kind) {
                if ($branch -match "^$([regex]::Escape($c.name))/(\d+)-") {
                    $out += New-Event "build.branch_$kind" ([int]$Matches[1]) $null $delivery @{ sha = $run.head_sha; conclusion = $run.conclusion; workflow = $run.name }
                } elseif ($branch -eq $c.defaultBranch) {
                    $out += New-Event "build.master_$kind" $null $null $delivery @{ sha = $run.head_sha; conclusion = $run.conclusion; workflow = $run.name }
                }
            }
        }
        'projects_v2_item' {
            if ("$($p.action)" -eq 'edited' -and (Test-Has $p 'changes') -and $p.changes.field_value.field_name -eq 'Status') {
                $q = 'query($id:ID!){ node(id:$id){ ... on Issue{ number labels(first:30){ nodes{ name } } } } }'
                $d = Invoke-GhGraphQL $q @{ id = $p.projects_v2_item.content_node_id }
                if ($d.node -and (Test-NameIn $c.label @($d.node.labels.nodes | ForEach-Object { $_.name }))) {
                    $out += New-Event 'item.column_changed' ([int]$d.node.number) "$($p.changes.field_value.to.name)" $delivery
                }
            }
        }
        'pull_request' {
            $act = "$($p.action)"; $pull = $p.pull_request
            $branch = "$($pull.head.ref)"
            # any pull request merged into the default branch moves master: the gateway tells the owners of open branches (base.updated)
            if ($act -eq 'closed' -and (Test-Has $pull 'merged') -and $pull.merged -and (Test-Has $pull 'base') -and "$($pull.base.ref)" -eq $c.defaultBranch) { $out += New-Event 'base.merged' $null $null $delivery @{ pr = [int]$pull.number; sha = "$($pull.merge_commit_sha)" } }
            if ($branch -match "^$([regex]::Escape($c.name))/(\d+)-") {
                $num = [int]$Matches[1]; $full = if ((Test-Has $pull 'head') -and (Test-Has $pull.head 'repo')) { "$($pull.head.repo.full_name)" } else { '' }
                if ($full -ine "$($c.owner)/$($c.repo)") { return @{ ok = $true; events = @(); dropped = 'pr.fork' } }
                $x = @{ pr = [int]$pull.number; sha = "$($pull.head.sha)"; login = $(if (Test-Has $p 'sender') { "$($p.sender.login)" } else { '' }) }
                if ($act -in 'opened', 'reopened', 'ready_for_review') { $out += New-Event 'pr.opened' $num $null $delivery $x }
                elseif ($act -eq 'synchronize') { $out += New-Event 'pr.head_changed' $num $null $delivery $x }
                elseif ($act -eq 'closed') { $out += New-Event $(if ((Test-Has $pull 'merged') -and $pull.merged) { 'pr.merged' } else { 'pr.closed' }) $num $null $delivery $x }
                elseif ($act -eq 'converted_to_draft') { $out += New-Event 'pr.drafted' $num $null $delivery $x }
            }
        }
        'pull_request_review' {
            $act = "$($p.action)"; $pull = $p.pull_request; $branch = "$($pull.head.ref)"
            if ($act -in 'submitted', 'dismissed' -and $branch -match "^$([regex]::Escape($c.name))/(\d+)-") {
                $num = [int]$Matches[1]
                $out += New-Event 'pr.reviewed' $num $null $delivery @{ pr = [int]$pull.number; sha = "$($pull.head.sha)"; login = "$($p.review.user.login)"; state = "$($p.review.state)".ToUpperInvariant(); commit_id = "$($p.review.commit_id)"; action = $act }
            }
        }
        default { }
    }
    return @{ ok = $true; events = $out }
}

# ---- secrets (read-only probes; names and pass/fail only, never a value) -------------------------------------------
function Verb_check_secrets($a) {
    $c = Get-Cfg; $checks = @()
    $add = { param($name, $ok, $detail) $script:checks += @{ name = $name; ok = [bool]$ok; detail = $detail } }
    $script:checks = @()
    try { $login = Get-ServerLogin; & $add 'github-token' $true "authenticated as $login" } catch { & $add 'github-token' $false 'token missing or rejected' }
    try {
        $r = Invoke-Gh -Path (Get-RepoPath); $perm = $r.permissions
        & $add 'repo-access' ($perm.push) "push=$($perm.push) admin=$($perm.admin)"
    } catch { & $add 'repo-access' $false 'repository not readable' }
    try { $m = Get-ProjectMeta; & $add 'project-read' ($m.options.Count -gt 0) "Status options: $($m.options.Count)" } catch { & $add 'project-read' $false 'project not readable' }
    try { $missing = @($c.columns.ai + $c.columns.hold + $c.columns.done | Where-Object { -not (Get-ProjectMeta).options.Contains($_) }); & $add 'board-columns' ($missing.Count -eq 0) $(if ($missing.Count) { "missing: $($missing -join ', ')" } else { 'all expected columns present' }) } catch { & $add 'board-columns' $false 'unreadable' }
    try {
        $labels = @(Invoke-Gh -Path "$(Get-RepoPath)/labels?per_page=100" | ForEach-Object { $_.name })
        & $add 'worker-label' (Test-NameIn $c.label $labels) "label '$($c.label)' $(if (Test-NameIn $c.label $labels) {'exists'} else {'is missing'})"
    } catch { & $add 'worker-label' $false 'labels unreadable' }
    $ws = $env:FACTORY_WEBHOOK_SECRET
    & $add 'webhook-secret' ($ws -and $ws.Length -ge 32) $(if ($ws) { "set, $($ws.Length) chars" } else { 'not set' })
    if ($env:OCTOPUS_API_KEY) {
        try {
            $me = Invoke-Octo 'api/users/me'; & $add 'octopus-key' ($null -ne $me) 'authenticated'
            $proj = Invoke-Octo "api/$($c.octopus.space)/projects/$($c.octopus.project)"; & $add 'octopus-project' ($null -ne $proj) "project $($c.octopus.project)"
        } catch { & $add 'octopus-key' $false 'rejected or unreachable' }
    } else { & $add 'octopus-key' $false 'not set' }
    $bad = @($script:checks | Where-Object { -not $_.ok })
    if ($bad.Count -gt 0) { Reject 30 'secrets-check-failed' "$($bad.Count) check(s) failed" @{ checks = $script:checks } }
    return @{ ok = $true; checks = $script:checks }
}
