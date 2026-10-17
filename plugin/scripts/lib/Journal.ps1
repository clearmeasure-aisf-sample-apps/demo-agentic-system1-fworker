# The plant manager's journal on the work item. One helper writes every dispatch-side comment: a visible line, a hidden marker, a dedup ledger
# in the item's state comment (so redelivered webhooks and repeated sweeps never post twice), redaction, a length cap, and a per-item limit.
# Best-effort: a failed comment never blocks a dispatch. Design: docs/design/plant-manager.md section 8.
#
# Folding (issue 93): an item that waits for a worker repeats matched, waiting and reassigned again and again (23 items filled their 30 comments
# with them and then said nothing about what came later). A repeat of one of these kinds edits the comment its kind last posted instead of
# posting a new one, as long as no other kind of line came between that comment and now except these and offered: the comment then says how many
# times and when, with the latest lines. Any other line (assigned, released, lease-expired, unparked, a QC line...) ends the fold, so the next
# matched after it is a new comment in its place in the journal. Only a new comment counts against the cap. The state keeps, per kind, how many
# lines were journaled (journal.kinds.<event>: count, first, last) and the open folds (journal.fold.<event>: comment id, count, the latest lines).

$script:JournalCap = 30
$script:JournalFoldKinds = @('matched', 'waiting', 'reassigned')
# lines that neither end a fold nor are folded themselves
$script:JournalFoldNeutral = @('offered')
$script:JournalFoldShow = 5
# a folded line is kept in the state for the comment's history: at most this long (the state comment has a size limit of its own)
$script:JournalFoldLineMax = 300
# Used only when config/instance.json has no secrets catalogue (worker-messaging.md 5.4); the catalogue is the source of truth.
$script:FallbackSecretPatterns = @('-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)', 'gh[pousr]_[A-Za-z0-9]{20,}', 'xox[baprs]-[A-Za-z0-9-]{10,}', 'AKIA[0-9A-Z]{16}',
    '(?i)(bearer|token|secret|password|api[_-]?key)(\s*[:=]\s*|\s+)[A-Za-z0-9._~+/=-]{12,}', '\b(w1|w2|m1|i1|q1|o1|k1|r1|n1)\.[A-Za-z0-9_.-]{20,}')

function Protect-JournalText([string]$Text) {
    if (-not $Text) { return '' }
    $t = $Text
    $secrets = try { (Get-Cfg).secrets } catch { $null }
    $list = if ($secrets) { @($secrets.patterns) + @($secrets.redactOnly) } else { @() }
    $list = @($list | Where-Object { $_ })
    if (-not $list) { $list = $script:FallbackSecretPatterns }
    foreach ($p in $list) { $t = [regex]::Replace($t, $p, '[redacted]') }
    return $t
}

function Get-JournalText([string]$Event, [hashtable]$F) {
    $col = if ($F.ContainsKey('column')) { "**$($F.column)**" } else { '' }
    $n = $F.item
    switch ($Event) {
        'matched' { return "matched $(if ($F.ContainsKey('trigger')) { $F.trigger } else { 'a trigger' }) to work item #$n in $col ($($F.reason)). Needs $(if ($F.ContainsKey('role') -and $F.role) { "a $($F.role) bot" } else { 'an owner session' })." }
        'offered' { return "offered to **$($F.worker)** ($($F.type)); waiting up to $($F.ackSeconds) s for it to accept." }
        'assigned' {
            if ($F.ContainsKey('role') -and $F.role) { return "**$($F.worker)** accepted the $($F.role) job for PR #$($F.pr)$(if ($F.ContainsKey('url') -and $F.url) { " ([session]($($F.url)))" })." }
            $m = if ($F.ContainsKey('model') -and $F.model) { " Model: $($F.model) ($($F.effort)), tier $($F.tier)." } else { '' }
            $link = if ($F.ContainsKey('url') -and $F.url) { " [session]($($F.url))" } else { '' }
            $by = if ($F.ContainsKey('by') -and $F.by -eq 'client') { ' (accepted by its client; the session starts on it next)' } else { '' }
            return "**$($F.worker)**$link accepted$($by): it owns this item from $col until it is merged (mode $($F.mode), attempt $($F.attempt)).$m Lease until $($F.lease)."
        }
        'routed' { return "told the owner (**$($F.worker)**): $($F.what)." }
        'reassigned' { return "$($F.reason); offering to the next worker." }
        'tier' { return "model tier raised to **$($F.name)** ($($F.reasons))." }
        'waiting' { return "waiting: $($F.reason)." }
        'pin-fallback' { return "the pinned worker **$($F.pin)** could not take the item for $($F.minutes) min ($($F.code)): the pin is set aside and it is offered to **$($F.worker)**. A new worker label pins it again." }
        'skipped' { return "not assigned: $($F.reason)." }
        'qc-offered' { return "a QC environment is offered for PR #$($F.pr) at head $($F.sha7); nothing runs until a person presses Start." }
        'qc-requested' { return "a person asked for a QC environment for PR #$($F.pr) at head $($F.sha7) (attempt $($F.attempt))." }
        'qc-assigned' { return "**$($F.worker)** accepted the QC environment job for PR #$($F.pr) (attempt $($F.attempt))." }
        'qc-ready' { return "QC environment for PR #$($F.pr) is ready on **$($F.worker)** (attempt $($F.attempt))$(if ($F.ContainsKey('url') -and $F.url) { ": $($F.url)" } else { '' }). Reachable only from networks that can reach that computer." }
        'qc-failed' { $fence = '```'; return "QC environment for PR #$($F.pr) failed (**$($F.code)**).`n$($fence)text`n$($F.reason)`n$fence" }
        'qc-reset' { return "QC environment for PR #$($F.pr) was reset by a person (attempt $($F.attempt))." }
        'qc-torn-down' { return "QC environment for PR #$($F.pr) torn down ($($F.reason))." }
        'qc-waiting' { return "QC environment for PR #$($F.pr) is waiting: $($F.reason)." }
        'question-escalated' { return "a question from **$($F.worker)** has waited $($F.minutes) min for the supervisor (supervisor: $(if ("$($F.supervisor)" -eq 'connected') { 'connected' } else { 'absent' })); a person is asked to look at the dashboard." }
        'merge-waiting' { return "PR #$($F.pr) has a PASS verdict and is not merged yet: $($F.reason) (``$($F.code)``). The gateway merges it by itself when that clears; no session has to call anything." }
        'base-updated' {
            if ($F.ContainsKey('conflict') -and $F.conflict) { return "the pull request has a merge conflict with master (``$($F.sha7)``); told the owner (**$($F.worker)**) to merge master into the branch and resolve it: $($F.behind) commit(s) behind$(if ($F.ContainsKey('overlap') -and $F.overlap) { ", files changed on both sides: $($F.overlap)" })." }
            return "master moved to ``$($F.sha7)``$(if ($F.ContainsKey('prs') -and $F.prs) { " (merged: $($F.prs))" }); told the owner (**$($F.worker)**) to merge master into the branch now: $($F.behind) commit(s) behind$(if ($F.ContainsKey('overlap') -and $F.overlap) { ", files changed on both sides: $($F.overlap)" })."
        }
        'branch-updated' { return "the gateway merged master into the branch of PR #$($F.pr) (GitHub's update branch: no conflict, the owner had not updated it within $($F.seconds) s)." }
        'gap-renewed' { return "the lease of **$($F.worker)** ran out at $($F.lapsed) while no gateway was running (down since $($F.since)); renewed for $($F.minutes) min instead of offering the item again." }
        'lease-expired' { return "the gateway ended the lease of **$($F.worker)** ($($F.reason)); the item is offered again in resume mode." }
        'flagged' { return "flagged ``$($F.code)`` in $($col): $($F.reason)." }
        'settle-rearmed' { return "the settle step of this merged item is re-armed by $($F.by) (awaiting ``$($F.awaiting)``): $($F.reason). The gateway carries it on; it is not offered to a worker." }
        'board-added' { return "the item has the factory label but had no column on the board: the sweep put it in $($F.column), where it is offered like any new item." }
        'unparked' {
            $rs = if ($F.ContainsKey('reset') -and $F.reset) { ' Its fix-forward rounds and demotions count from 0 again.' } else { '' }
            if ($F.ContainsKey('merged') -and $F.merged) { return "park ``$($F.code)`` removed by $($F.by): $($F.reason). The item is merged: the gateway settles it, nothing is offered." }
            if ($F.ContainsKey('closed') -and $F.closed) { return "park ``$($F.code)`` removed by $($F.by): $($F.reason). The item is closed: nothing is offered." }
            if ($F.code -eq 'master-broken' -and "$($F.by)" -ne 'expiry') { return "park ``master-broken`` released early by $($F.by): $($F.reason).$rs The item waits for master green again, then for its release candidate." }
            if ("$($F.by)" -eq 'expiry') { return "park ``$($F.code)`` expired ($($F.reason)).$rs The next sweep takes it up again in $col." }
            return "park ``$($F.code)`` released early by $($F.by): $($F.reason).$rs The next sweep takes it up again in $col."
        }
        'released' { return "ownership released by **$($F.worker)** ($($F.reason)); the next trigger assigns it again." }
        'pulled' { return "pulled from **$($F.from)** into ${col}: a worker slot was free and nothing waited there ($($F.wip) of at most $($F.wipLimit) items in the AI columns)." }
        # the plant manager's flow verbs (Verbs.Manager.ps1, docs/design/plant-manager.md 10e): who acted, what, under which policy code, and why
        # the backlog keeper's verbs (Verbs.Keeper.ps1, docs/design/backlog-keeper.md): who, what, the policy code and why
        'keeper-action' { return "$(if ("$($F.by)" -eq 'operator') { 'the operator' } else { "the backlog keeper (**$($F.by)**)" }) $($F.detail), under policy ``$($F.policy)``$(if ($F.ContainsKey('reason') -and $F.reason) { ": $($F.reason)" })." }
        'manager-action' { return "$(if ("$($F.by)" -eq 'operator') { 'the operator' } else { "the plant manager (**$($F.by)**)" }) $($F.detail), under policy ``$($F.policy)``$(if ($F.ContainsKey('reason') -and $F.reason) { ": $($F.reason)" })." }
        default { return "$Event" }
    }
}

# Posts one journal comment, or folds a repeat into the comment of its kind. $St is the caller's state holder: the ledger is updated in it, and
# saved here only with -Save.
function Add-Journal([int]$Item, $St, [string]$Event, [hashtable]$Fields = @{}, [string]$Key = '', [switch]$Save) {
    try {
        $own = $false
        if ($null -eq $St) { $St = Get-State $Item; $own = $true }
        $s = $St.state
        if (-not (Test-Has $s 'journal')) { $s.journal = @{ keys = @(); count = 0 } }
        $j = $s.journal
        $k = "$Event|$Key"
        if (@($j.keys) -contains $k) { return $false }
        $Fields.item = $Item
        $now = Get-UtcNow; $nowIso = ConvertTo-Iso $now
        $line = Get-JournalText $Event $Fields
        $line = Protect-JournalText $line
        if ($line.Length -gt 1500) { $line = $line.Substring(0, 1500) + ' [truncated]' }
        if (-not (Test-Has $j 'fold')) { $j.fold = @{} }
        # a line of another kind ends every open fold: what comes after it is new in the journal
        Close-JournalFolds $j $Event
        $folded = $false
        if ($Event -in $script:JournalFoldKinds -and (Test-Has $j.fold $Event) -and (Test-Has $j.fold[$Event] 'id')) {
            $f = $j.fold[$Event]
            $f.count = [int]$f.count + 1; $f.last = $nowIso
            $f.lines = @(@($f.lines) + @("$(Get-JournalStamp $now) $(Limit-JournalLine $line)") | Select-Object -Last $script:JournalFoldShow)
            $body = Format-JournalFold $Event $f "$($f.key)"
            # a comment that is gone (deleted by a person) or cannot be edited any more is replaced by a new one; a rate limit fails the line as before
            $r = try { Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/issues/comments/$($f.id)" -Body @{ body = $body } -Allow 404, 410 } catch [FactoryReject] { if ($_.Exception.Exit -eq 20) { throw }; @{ status = 0 } }
            if ($r -is [hashtable] -and $r.ContainsKey('status')) { $j.fold.Remove($Event) }
            else { $folded = $true }
        }
        if (-not $folded) {
            # qc-ready, qc-failed and question-escalated may take a few slots beyond the cap: they are the lines a person looks for
            # (and manager-action: every action of the plant manager is journaled, docs/design/plant-manager.md 10e; it is limited to 3 a day per item)
            $extra = $Event -in 'qc-ready', 'qc-failed', 'question-escalated', 'manager-action', 'keeper-action'
            if ([int]$j.count -ge $script:JournalCap + $(if ($extra) { 4 } else { 1 })) { return $false }
            $full = [int]$j.count -eq $script:JournalCap -and -not $extra
            $text = if ($full) { "journal full ($script:JournalCap entries); later events are not posted here, see the gateway log." } else { $line }
            $body = "🏭 Plant manager: $text`n`n<!-- plant event=$Event key=$Key -->"
            $r = Invoke-Gh -Method POST -Path "$(Get-RepoPath)/issues/$Item/comments" -Body @{ body = $body }
            $j.count = [int]$j.count + 1
            $cid = if ($r -and $r.PSObject.Properties['id']) { $r.id } else { $null }
            if ($Event -in $script:JournalFoldKinds -and -not $full -and $cid) { $j.fold[$Event] = @{ id = $cid; key = $Key; count = 1; first = $nowIso; last = $nowIso; lines = @("$(Get-JournalStamp $now) $(Limit-JournalLine $line)") } }
        }
        $j.keys = @(@($j.keys) + $k | Select-Object -Last 200)
        Add-JournalKind $j $Event $nowIso
        if ($Save -or $own) { Save-State $Item $St }
        return $true
    } catch { [Console]::Error.WriteLine("journal $Event for #$Item failed: $($_.Exception.Message)"); return $false }
}

# the bookkeeping shared by Add-Journal and Save-JournalKeys: another kind of line ends the open folds; every line counts for its kind
function Close-JournalFolds($J, [string]$Event) { if ($Event -notin $script:JournalFoldKinds -and $Event -notin $script:JournalFoldNeutral) { $J.fold = @{} } }
function Add-JournalKind($J, [string]$Event, [string]$At) {
    if (-not (Test-Has $J 'kinds')) { $J.kinds = @{} }
    if (Test-Has $J.kinds $Event) { $J.kinds[$Event].count = [int]$J.kinds[$Event].count + 1; $J.kinds[$Event].last = $At }
    else { $J.kinds[$Event] = @{ count = 1; first = $At; last = $At } }
}
# one line (no line breaks, no code fences: the latest lines are kept in the state comment, inside its json fence), at most JournalFoldLineMax long
function Limit-JournalLine([string]$Line) { $one = (($Line -replace '\s+', ' ') -replace '`{3,}', "'''").Trim(); if ($one.Length -gt $script:JournalFoldLineMax) { $one.Substring(0, $script:JournalFoldLineMax) + ' [...]' } else { $one } }
function Get-JournalStamp([DateTime]$At) { $At.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + 'Z' }

# The body of a folded comment: the latest line first (what is true now), then how often and since when, then the latest lines with their times.
# The hidden marker is the one of the first line (its event and key), so a reader of the markers sees one line of the kind, posted when it first
# happened.
function Format-JournalFold([string]$Event, $Fold, [string]$Key) {
    $lines = @($Fold.lines)
    $latest = if ($lines.Count) { "$($lines[-1])" -replace '^\S+ \S+ ', '' } else { '' }
    $first = ConvertFrom-Iso $Fold.first; $last = ConvertFrom-Iso $Fold.last
    $shown = if ([int]$Fold.count -gt $lines.Count) { "the latest $($lines.Count)" } else { 'each' }
    $hist = ($lines | ForEach-Object { "> $_" }) -join "`n"
    $b = "🏭 Plant manager: $latest`n`n$Event $($Fold.count) times, from $(Get-JournalStamp $first) to $(Get-JournalStamp $last) ($shown below; this comment is edited instead of posting a new one each time).`n`n$hist`n`n<!-- plant event=$Event key=$Key fold=$($Fold.count) -->"
    if ($b.Length -gt 6000) { $b = $b.Substring(0, 5900) + "`n[truncated]`n`n<!-- plant event=$Event key=$Key fold=$($Fold.count) -->" }
    return $b
}

# For a caller that holds no item lock (the sweep): the ledger entries Add-Journal put into the caller's holder are written under the item lock into
# a state read there, never as a save of the holder itself. The holder was read before whatever a verb recorded meanwhile (an approval, a claim):
# saving it would undo that (seen on slow runners: an inspector's approval lost to the sweep that was posting the QC offer).
function Save-JournalKeys([int]$Item, [string[]]$Keys) {
    Use-ItemLock $Item {
        $f = Get-State $Item; $fs = $f.state; $added = 0
        if (-not (Test-Has $fs 'journal')) { $fs.journal = @{ keys = @(); count = 0 } }
        $at = ConvertTo-Iso (Get-UtcNow)
        foreach ($k in $Keys) {
            if (@($fs.journal.keys) -contains $k) { continue }
            $fs.journal.keys = @(@($fs.journal.keys) + $k | Select-Object -Last 200); $fs.journal.count = [int]$fs.journal.count + 1; $added++
            # the line's kind ends the open folds and is counted, as Add-Journal does for a holder it saves itself (the lines of this path are
            # QC and skipped lines, never folded)
            $ev = ($k -split '\|', 2)[0]; if (-not (Test-Has $fs.journal 'fold')) { $fs.journal.fold = @{} }
            Close-JournalFolds $fs.journal $ev; Add-JournalKind $fs.journal $ev $at
        }
        if ($added -gt 0) { Save-State $Item $f }
    }
}
function Get-JournalKeys($State) { if (Test-Has $State 'journal') { return @($State.journal.keys) }; return @() }

# Admin verb: the gateway journals the decisions it makes itself (matched, offered, reassigned, waiting, skipped).
function Verb_journal($a) {
    $n = Get-ItemNumber $a; $ev = "$(Need $a 'event')"
    if ($ev -notin 'matched', 'offered', 'assigned', 'routed', 'reassigned', 'tier', 'waiting', 'skipped', 'released', 'qc-offered', 'qc-requested', 'qc-assigned', 'qc-ready', 'qc-failed', 'qc-reset', 'qc-torn-down', 'qc-waiting', 'question-escalated', 'base-updated', 'branch-updated', 'keeper-action', 'manager-action', 'pin-fallback') { Reject 2 'usage' "unknown journal event '$ev'" }
    $f = @{}; if (Test-Has $a 'fields') { foreach ($k in $a.fields.Keys) { $f[$k] = $a.fields[$k] } }
    # a 'waiting' note is rate-limited: at most one per timing.journalWaitingMinutes (30) per item
    if ($ev -eq 'waiting') {
        $tw = (Get-Cfg).timing; $every = if (Test-Has $tw 'journalWaitingMinutes') { [double]$tw.journalWaitingMinutes } else { 30 }
        $st = Get-State $n; $last = if ((Test-Has $st.state 'journal') -and (Test-Has $st.state.journal 'waiting_at')) { ConvertFrom-Iso $st.state.journal.waiting_at } else { $null }
        if ($last -and ((Get-UtcNow) - $last).TotalMinutes -lt $every) { return @{ ok = $true; id = $n; posted = $false; reason = 'rate-limited' } }
        $key = [string](Get-UtcNow).Ticks
        $posted = Add-Journal $n $st 'waiting' $f $key
        if ($posted) { $st.state.journal.waiting_at = ConvertTo-Iso (Get-UtcNow); Save-State $n $st }
        return @{ ok = $true; id = $n; posted = $posted }
    }
    $key = if (Test-Has $a 'key') { "$($a.key)" } else { [string](Get-UtcNow).Ticks }
    $posted = Add-Journal $n $null $ev $f $key
    return @{ ok = $true; id = $n; posted = $posted }
}
