# Master moved: the standing back-merge trigger (docs/design/plant-manager.md 6a). Two admin verbs the gateway calls; no model is involved.
#   base-watch          the head of the default branch, and for each owned item its pull request, how far its branch is behind, and the files the
#                       new master commits changed that the item's pull request changes too (overlap: a likely conflict)
#   base-update-branch  GitHub's "update branch" for one item's pull request, only when it is open, still at the head the trigger saw, has no
#                       conflict with master and is behind; anything else is left to the owner session

# baseUpdate.mode (issue 103, gateway/BaseUpdate.cs): conflict-or-merge (default), conflict or every-move; FACTORY_BASE_UPDATE_MODE overrides it.
function Get-BaseUpdateMode {
    $m = if ($env:FACTORY_BASE_UPDATE_MODE) { "$env:FACTORY_BASE_UPDATE_MODE" } else { $c = Get-Cfg; if ((Test-Has $c 'baseUpdate') -and (Test-Has $c.baseUpdate 'mode')) { "$($c.baseUpdate.mode)" } else { '' } }
    if ($m -in 'every-move', 'conflict', 'conflict-or-merge') { return $m }
    return 'conflict-or-merge'
}

function Get-BaseHead { $c = Get-Cfg; "$((Invoke-Gh -Path "$(Get-RepoPath)/branches/$($c.defaultBranch)").commit.sha)" }

# behind_by of the default branch against a branch (per_page=1: the count is all that is read, not the commit list)
function Get-BehindBy([string]$Branch) {
    $c = Get-Cfg
    $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$($c.defaultBranch)...$($Branch)?per_page=1" -Allow 404, 422
    if ($cmp -is [hashtable]) { return -1 }
    return [int]$cmp.behind_by
}

# Why the gateway must not move this item's branch (and need not trigger a back-merge): a verdict on record, a merge being settled, the item in
# its validation column, or a QC record for the head. Moving the head would make the verdict's sha (the merge-after-PASS path) or the QC run stale.
function Get-BackmergeHold([int]$Item, $State, [int]$Pr, [string]$Head) {
    $c = Get-Cfg; $s = $State
    if (Test-Has $s 'verdict') { return 'verdict-recorded' }
    if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'awaiting') -and $s.merge.awaiting) { return 'merge-awaiting' }
    $col = try { "$((Get-ItemInfo $Item).column)" } catch { '' }
    if ($col -ieq $c.columns.validation) { return 'in-validation' }
    if ($Pr -gt 0 -and $Head -and (Test-Has $s 'qc') -and $s.qc.Contains("$Pr") -and (($s.qc["$Pr"] | ConvertTo-Json -Depth 8 -Compress) -match [regex]::Escape($Head))) { return 'qc-for-head' }
    return ''
}

function Verb_base_watch($a) {
    $c = Get-Cfg
    $known = if (Test-Has $a 'known') { "$($a.known)" } else { '' }
    $merged = @(if (Test-Has $a 'mergedPrs') { @($a.mergedPrs) | ForEach-Object { [int]$_ } })
    $head = Get-BaseHead
    $changed = $known -ne '' -and $head -ne $known
    # the files master changed since the last head the gateway saw (bounded: 300 files)
    $baseFiles = @()
    if ($changed) {
        $cmp = Invoke-Gh -Path "$(Get-RepoPath)/compare/$known...$head" -Allow 404, 422
        if ($cmp -isnot [hashtable] -and $cmp.PSObject.Properties['files']) { $baseFiles = @($cmp.files | Select-Object -First 300 | ForEach-Object { "$($_.filename)" }) }
    }
    $rows = @()
    # the conflict modes (issue 103): whether each open pull request conflicts with master. GitHub answers mergeable null until it has computed
    # it (a later look gets it); a pull request whose head and master's are the ones of a definite earlier answer is not read again
    $conflicts = (Test-Has $a 'conflicts') -and $a.conflicts
    $knownC = if (Test-Has $a 'conflictKnown') { $a.conflictKnown } else { @{} }
    $items = @(if (Test-Has $a 'items') { @($a.items) | ForEach-Object { [int]$_ } | Select-Object -First 50 })
    if ($items.Count -gt 0) {
        $open = @(Invoke-Gh -Path "$(Get-RepoPath)/pulls?state=open&per_page=100")
        foreach ($n in $items) {
            $row = @{ item = $n; pr = 0; branch = ''; head = ''; behind = 0; overlap = @(); skip = '' }
            try {
                $s = (Get-State $n).state
                # a PASS verdict waiting for its merge, or a merge being settled: the gateway owns the next step, not a back-merge
                if ((Test-Has $s 'verdict') -and $s.verdict.passed -and -not $s.verdict.processed) { $row.skip = 'pass-unmerged' }
                elseif ((Test-Has $s 'merge') -and (Test-Has $s.merge 'awaiting') -and $s.merge.awaiting) { $row.skip = 'merged' }
                $pr = @($open | Where-Object { $_.head.ref -match "^$([regex]::Escape($c.name))/$n-" }) | Select-Object -First 1
                if ($pr) { $row.pr = [int]$pr.number; $row.branch = "$($pr.head.ref)"; $row.head = "$($pr.head.sha)"; if ($row.pr -in $merged -and -not $row.skip) { $row.skip = 'merged' } }
                elseif ((Test-Has $s 'pr') -and (Test-Has $s.pr 'number') -and $s.pr.number) { if (-not $row.skip) { $row.skip = 'pr-closed' } }
                elseif ((Test-Has $s 'pr') -and (Test-Has $s.pr 'branch') -and $s.pr.branch) { $row.branch = "$($s.pr.branch)" }
                elseif (-not $row.skip) { $row.skip = 'no-branch' }
                if (-not $row.skip) { $row.skip = Get-BackmergeHold $n $s $row.pr $row.head }
                if (-not $row.skip -and $conflicts -and $row.pr -gt 0) {
                    $kc = if ($knownC -is [System.Collections.IDictionary] -and $knownC.Contains("$n")) { $knownC["$n"] } else { $null }
                    if ($kc -and "$($kc.prHead)" -eq $row.head -and "$($kc.head)" -eq $head -and $kc.conflict -is [bool]) { $row.conflict = $kc.conflict }
                    else {
                        # GitHub answers null until it has computed it (the first read starts that): one more read 3 s later, then the next look
                        $p1 = Get-Pr $row.pr
                        if ($null -eq $p1.mergeable) { Start-Sleep -Seconds 3; $p1 = Get-Pr $row.pr }
                        $row.conflict = if ($p1.mergeable -eq $false -or "$($p1.mergeable_state)" -eq 'dirty') { $true } elseif ($p1.mergeable -eq $true) { $false } else { $null }
                    }
                }
                if (-not $row.skip) {
                    $row.behind = Get-BehindBy $row.branch
                    if ($changed -and $row.pr -gt 0 -and $baseFiles.Count -gt 0) {
                        $mine = @(Get-PrFiles $row.pr | ForEach-Object { "$($_.filename)" })
                        $row.overlap = @($baseFiles | Where-Object { $mine -contains $_ } | Select-Object -First 20)
                    }
                }
            } catch [FactoryReject] { $row.skip = 'error'; $row.code = $_.Exception.Code }
            $rows += $row
        }
    }
    return @{ head = $head; known = $known; changed = $changed; baseFiles = $baseFiles.Count; rows = $rows }
}

function Verb_base_update_branch($a) {
    $n = [int](Need $a 'item'); $num = [int](Need $a 'pr'); $expected = "$(Need $a 'expected')"
    $pr = Get-Pr $num
    if ("$($pr.state)" -ne 'open') { return @{ item = $n; pr = $num; outcome = 'not-open' } }
    if ("$($pr.head.sha)" -ne $expected) { return @{ item = $n; pr = $num; outcome = 'head-moved' } }
    # read fresh: a verdict, a merge or a QC run may have started since the trigger
    $hold = Get-BackmergeHold $n (Get-State $n).state $num $expected
    if ($hold) { return @{ item = $n; pr = $num; outcome = 'skip'; reason = $hold } }
    # GitHub computes mergeability after a push to either side: null until then
    for ($i = 0; $i -lt 5 -and $null -eq $pr.mergeable; $i++) { Start-Sleep -Seconds 2; $pr = Get-Pr $num }
    if ($pr.mergeable -eq $false -or "$($pr.mergeable_state)" -eq 'dirty') { return @{ item = $n; pr = $num; outcome = 'conflict' } }
    if ($null -eq $pr.mergeable) { return @{ item = $n; pr = $num; outcome = 'unknown' } }
    $behind = Get-BehindBy "$($pr.head.ref)"
    if ($behind -eq 0) { return @{ item = $n; pr = $num; outcome = 'current' } }
    $u = Invoke-Gh -Method PUT -Path "$(Get-RepoPath)/pulls/$num/update-branch" -Body @{ expected_head_sha = $expected } -Allow 409, 422
    if ($u -is [hashtable] -and $u.ContainsKey('status')) { return @{ item = $n; pr = $num; outcome = 'refused'; status = $u.status } }
    return @{ item = $n; pr = $num; outcome = 'updated'; behind = $behind }
}
