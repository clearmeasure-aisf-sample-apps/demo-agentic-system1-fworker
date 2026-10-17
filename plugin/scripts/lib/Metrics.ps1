# Cycle-time metrics (enhancement 13): computed from what lasts on GitHub, never from the gateway's memory, so a restart loses nothing.
# Per item it reads the journal comments of the plant (<!-- plant event=E key=K -->, their created_at) and the item's state comment
# (dispatched_at per column, merge.merged_at, merge.done_at). Admin verb only: GET /api/v1/metrics runs it and caches the answer.
#
# Times of one item, all ISO, missing when the event did not happen (or happened before the journal existed):
#   matched   first "matched" journal line: the gateway matched a trigger to the item (the hand-over)
#   offered   first "offered" line
#   accepted  first owner "assigned" line (key owner|...): a session took the item
#   merged    merge.merged_at;  done  merge.done_at (master green, release, Done)
# Durations in seconds: matchToAccept, acceptToMerge, matchToMerge, mergeToDone, matchToDone, and columns.<name>: from that column's dispatch to the
# next column's dispatch (the last one to the merge). dispatched_at keeps only the latest dispatch per column, so a column visited twice (a
# demotion to Development) counts from its last visit.

function Get-MetricsSince([string]$Since, [DateTime]$Now) {
    if (-not $Since) { return $Now.AddDays(-7) }
    $m = [regex]::Match($Since, '^\s*(\d{1,4})\s*([mhd])\s*$')
    if ($m.Success) {
        $v = [int]$m.Groups[1].Value
        $d = switch ($m.Groups[2].Value) { 'm' { $Now.AddMinutes(-$v) } 'h' { $Now.AddHours(-$v) } 'd' { $Now.AddDays(-$v) } }
    } else {
        try { $d = ConvertFrom-Iso $Since } catch { Reject 2 'bad-since' "since is an ISO date or a duration like 30m, 24h, 7d; got '$Since'" }
    }
    if ($d -lt $Now.AddDays(-90)) { $d = $Now.AddDays(-90) }
    return $d
}

function Get-MetricsStats([double[]]$Values) {
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return @{ count = 0 } }
    $pick = { param($p) $v[[Math]::Min($v.Count - 1, [int][Math]::Ceiling($p * $v.Count) - 1)] }
    $median = if ($v.Count % 2 -eq 1) { $v[($v.Count - 1) / 2] } else { ($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2 }
    return @{ count = $v.Count; median = [Math]::Round($median); p90 = [Math]::Round((& $pick 0.9)); min = [Math]::Round($v[0]); max = [Math]::Round($v[-1]) }
}

function Get-ItemCycle([int]$Item, $St, [string]$Login) {
    $first = @{}
    foreach ($cm in @($St.comments)) {
        if ($cm.user.login -ne $Login) { continue }
        $mm = [regex]::Match("$($cm.body)", '<!-- plant event=([a-z-]+) key=(.*?) -->')
        if (-not $mm.Success) { continue }
        $ev = $mm.Groups[1].Value; $key = $mm.Groups[2].Value
        if ($ev -eq 'assigned') { if ($key.StartsWith('owner|')) { $ev = 'accepted' } else { continue } }
        if ($ev -notin 'matched', 'offered', 'accepted') { continue }
        $at = ConvertFrom-Iso $cm.created_at
        if ($at -and (-not $first.ContainsKey($ev) -or $at -lt $first[$ev])) { $first[$ev] = $at }
    }
    $s = $St.state
    if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'merged_at')) { $first.merged = ConvertFrom-Iso $s.merge.merged_at }
    if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'done_at')) { $first.done = ConvertFrom-Iso $s.merge.done_at }
    if ($first.Count -eq 0) { return $null }
    $o = @{ item = $Item; times = @{}; durations = @{}; columns = @{} }
    foreach ($k in $first.Keys) { $o.times[$k] = ConvertTo-Iso $first[$k] }
    $span = { param($a, $b) if ($first.ContainsKey($a) -and $first.ContainsKey($b) -and $first[$b] -ge $first[$a]) { [Math]::Round(($first[$b] - $first[$a]).TotalSeconds) } else { $null } }
    foreach ($p in @(@('matchToAccept', 'matched', 'accepted'), @('acceptToMerge', 'accepted', 'merged'), @('matchToMerge', 'matched', 'merged'), @('mergeToDone', 'merged', 'done'), @('matchToDone', 'matched', 'done'))) {
        $d = & $span $p[1] $p[2]; if ($null -ne $d) { $o.durations[$p[0]] = $d }
    }
    if (Test-Has $s 'dispatched_at') {
        $ds = @($s.dispatched_at.Keys | ForEach-Object { @{ column = "$_"; at = (ConvertFrom-Iso $s.dispatched_at[$_]) } } | Where-Object { $_.at } | Sort-Object { $_.at })
        for ($i = 0; $i -lt $ds.Count; $i++) {
            $end = if ($i + 1 -lt $ds.Count) { $ds[$i + 1].at } elseif ($first.ContainsKey('merged') -and $first.merged -gt $ds[$i].at) { $first.merged } else { $null }
            if ($end) { $o.columns[$ds[$i].column] = [Math]::Round(($end - $ds[$i].at).TotalSeconds) }
        }
    }
    if (Test-Has $s 'merge') { if (Test-Has $s.merge 'pr') { $o.pr = [int]$s.merge.pr } }
    $o.last = ConvertTo-Iso (@($first.Values | Sort-Object)[-1])
    return $o
}

# Admin verb: metrics [--since 7d|ISO] [--max 100]. Reads the board's items with the factory label, newest first, at most max of them.
function Verb_metrics($a) {
    $c = Get-Cfg; $now = Get-UtcNow
    $since = Get-MetricsSince $(if (Test-Has $a 'since') { "$($a.since)" } else { '' }) $now
    $max = if (Test-Has $a 'max') { [Math]::Clamp([int]$a.max, 1, 300) } else { 100 }
    $login = Get-ServerLogin
    $cands = @(Get-BoardList | Where-Object { Test-NameIn $c.label $_.labels } | Sort-Object { $_.number } -Descending | Select-Object -First $max)
    $items = @(); $failed = @()
    foreach ($it in $cands) {
        try { $r = Get-ItemCycle $it.number (Get-State $it.number) $login } catch { $failed += $it.number; continue }
        if ($r -and (ConvertFrom-Iso $r.last) -ge $since) { $r.column = "$($it.column)"; $r.open = [bool]$it.open; $items += $r }
    }
    $agg = @{}
    foreach ($k in 'matchToAccept', 'acceptToMerge', 'matchToMerge', 'mergeToDone', 'matchToDone') { $agg[$k] = Get-MetricsStats @($items | Where-Object { $_.durations.ContainsKey($k) } | ForEach-Object { [double]$_.durations[$k] }) }
    $cols = @{}
    foreach ($col in @($items | ForEach-Object { $_.columns.Keys } | Sort-Object -Unique)) { $cols[$col] = Get-MetricsStats @($items | Where-Object { $_.columns.ContainsKey($col) } | ForEach-Object { [double]$_.columns[$col] }) }
    return @{ ok = $true; since = (ConvertTo-Iso $since); computedAt = (ConvertTo-Iso $now); scanned = $cands.Count; unreadable = @($failed)
        items = @($items | Sort-Object { $_.item } -Descending); aggregate = $agg; columns = $cols; unit = 'seconds' }
}
