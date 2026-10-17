# The plant manager's flow verbs (docs/design/plant-manager.md 10e): what the supervisor session may change on an item to keep the flow moving,
# and nothing that decides about the work itself. One rule verb, manager-action, with one action per call, reached only through
# POST /api/v1/verbs/manager-action: with the supervisor's credential (Auth.cs keeps item, action, policy, reason, worker and level of the body and
# stamps `by` from the credential) or the operator token. The gateway checks the mode (manager.mode "advise" turns every action off) and the hourly
# limit before this runs; it runs under the item lock.
# Enforced here, on the item:
#   - a label hold:owner (ownerHoldLabel) refuses every action: the owner's hold wins;
#   - at most manager.actions.perItemPerDay actions on one item in 24 hours, counted in the item state (a gateway restart does not reset it);
#   - a policy code from manager.actions.policies on every call, and one journal line per action that names it;
#   - never a merge, an approval, a verdict, clear-hold, a column move or a claim for a session: no action here does any of them, and unpark refuses
#     the parks that only those would end (the inspector's hold, a PASS verdict waiting for a person's merge, the gateway's own wait for checks).

$script:ManagerItemActions = @('unpark', 'release-owner', 'pin', 'unpin', 'requeue', 'prioritize', 'rerun-failed')
# The policy codes when the config has none (config/instance.json manager.actions.policies is the source of truth; the supervisor's skill says
# which action each one stands for).
$script:DefaultManagerPolicies = @('park-resolved', 'stalled-owner', 'pinned-worker-absent', 'stuck-offer', 'outside-blocker', 'flaky-check', 'repeated-question', 'backlog-order', 'load-balance', 'operator-request')

function Get-ManagerActionCfg {
    $c = Get-Cfg
    $m = if ((Test-Has $c 'manager') -and (Test-Has $c.manager 'actions')) { $c.manager.actions } else { @{} }
    return @{
        perItemPerDay = $(if (Test-Has $m 'perItemPerDay') { [int]$m.perItemPerDay } else { 3 })
        policies = $(if ((Test-Has $m 'policies') -and @($m.policies).Count -gt 0) { @($m.policies | ForEach-Object { "$_" }) } else { $script:DefaultManagerPolicies })
        holdLabel = $(if (Test-Has $c 'ownerHoldLabel') { "$($c.ownerHoldLabel)" } else { 'hold:owner' })
    }
}

# The label of the item as it is spelled on the item (labels compare case-insensitively), or $null.
function Get-LabelAsSpelled($Info, [string]$Name) { @($Info.labels | Where-Object { "$_" -ieq $Name } | Select-Object -First 1) | Select-Object -First 1 }

function Verb_manager_action($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg; $mc = Get-ManagerActionCfg
    $action = "$(Need $a 'action')"
    if ($action -notin $script:ManagerItemActions) { Reject 2 'usage' "action is one of $($script:ManagerItemActions -join ', ')" }
    $policy = "$(Need $a 'policy')"
    if ($policy -notin $mc.policies) { Reject 2 'unknown-policy' "the policy code is one of manager.actions.policies: $($mc.policies -join ', ')" }
    # one line, no HTML comment markers, no mention: the reason goes into a journal comment whose hidden marker is machine-read
    $reason = if (Test-Has $a 'reason') { ("$($a.reason)" -replace '://', ' ' -replace '[<>@`\[\]!]', '' -replace '\s+', ' ').Trim() } else { '' }
    if ($reason.Length -gt 300) { Reject 2 'usage' 'the reason is at most 300 characters' }
    $by = if ((Test-Has $a 'by') -and "$($a.by)" -match '^[A-Za-z0-9_-]{1,40}$') { "$($a.by)" } else { 'operator' }

    $info = Get-ItemInfo $n
    if (Test-Label $info $mc.holdLabel) { Reject 10 'owner-hold' "item #$n carries the label '$($mc.holdLabel)': the owner holds it, and the plant manager changes nothing on it" }
    $st = Get-State $n; $s = $st.state
    $now = Get-UtcNow
    $recent = @(@(if (Test-Has $s 'manager_actions') { $s.manager_actions }) | Where-Object { $_ -is [System.Collections.IDictionary] -and (Test-Has $_ 'at') -and ($now - (ConvertFrom-Iso $_.at)).TotalHours -lt 24 })
    if ($recent.Count -ge $mc.perItemPerDay) {
        $retry = 86400
        if ($recent.Count -gt 0) { $first = @($recent | ForEach-Object { ConvertFrom-Iso $_.at } | Sort-Object)[0]; $retry = [int][Math]::Max(60, [Math]::Ceiling(($first.AddHours(24) - $now).TotalSeconds)) }
        Reject 10 'item-action-limit' "the plant manager acted on item #$n $($recent.Count) times in 24 hours (limit $($mc.perItemPerDay)): leave it to the operator" @{ retryAfterSeconds = $retry; actions_today = $recent.Count; limit = $mc.perItemPerDay }
    }
    $out = @{ ok = $true; id = $n; item = $n; action = $action; policy = $policy; column = $info.column }
    $detail = ''
    switch ($action) {
        'unpark' {
            if (-not (Test-Has $s 'park')) { Reject 10 'not-parked' "item #$n is not parked" }
            $park = $s.park; $code = "$($park.reason)"
            if ($code -eq 'development:awaiting-checks') { Reject 10 'gateway-wait' 'the item waits for its pull request checks, not for a person; the sweep ends that wait by itself' }
            if ($code -eq 'inspector-escalated') { Reject 10 'needs-approval' 'the inspector''s hold clears only on a human approval of the head commit (clear-hold); the plant manager never clears it' }
            if ((Test-Has $s 'verdict') -and $s.verdict.passed) { Reject 10 'needs-merge' 'a PASS verdict is on record: the item waits for a merge, and the plant manager never merges' }
            $s.Remove('park')
            $offered = $info.open -and -not (Test-ClaimLive $s) -and (Test-NameIn "$($info.column)" $c.columns.ai)
            if ($offered) { $s.handoff = @{ column = $info.column; at = ConvertTo-Iso $now } }
            $out.park = $park; $out.reoffer = [bool]$offered; $out.closed = (-not $info.open)
            $detail = "released the park ``$code``$(if ($offered) { "; the next sweep offers it again in **$($info.column)**" })"
        }
        'release-owner' {
            if (-not (Test-OwnedClaim $s) -or -not (Test-ClaimLive $s)) { Reject 10 'no-owner' "item #$n has no owner session with a live lease: the sweep offers it by itself" }
            $holder = "$($s.claim.holder)"
            # as expire-claim does (Owner.ps1): the claim stays and its lease ends now, marked taken_back, so the old owner cannot renew it and the next
            # sweep offers the item in resume mode (a relaunch, counted against maxRelaunches)
            $s.claim.lease_until = ConvertTo-Iso ($now.AddSeconds(-1)); $s.claim.taken_back = 'released-by-plant-manager'
            $out.holder = $holder
            $detail = "ended the lease of **$holder**; the item is offered again in resume mode"
        }
        'pin' {
            Assert-Open $info
            $w = if (Test-Has $a 'worker') { "$($a.worker)" } else { '' }
            if ($w -notmatch '^[A-Za-z0-9_-]{1,40}$' -or $w -in 'operator', 'gateway', 'all', 'supervisor', 'plant-manager') { Reject 2 'usage' 'worker is the name of a worker session' }
            $old = @($info.labels | Where-Object { "$_" -like 'worker:*' })
            if ($old.Count -eq 1 -and "$($old[0])" -ieq "worker:$w") { Reject 10 'already-pinned' "item #$n is pinned to $w already" }
            foreach ($l in $old) { if ("$l" -ine "worker:$w") { Remove-ItemLabel $n "$l" } }
            if (-not (@($old) | Where-Object { "$_" -ieq "worker:$w" })) { Add-ItemLabels $n @("worker:$w") }
            $out.worker = $w; $out.was = @($old | ForEach-Object { "$_".Substring(7) } | Where-Object { $_ -ine $w })
            $detail = "pinned it to **$w**$(if ($out.was.Count -gt 0) { " (was $($out.was -join ', '))" })"
        }
        'unpin' {
            $old = @($info.labels | Where-Object { "$_" -like 'worker:*' })
            if ($old.Count -eq 0) { Reject 10 'not-pinned' "item #$n is not pinned to a worker" }
            foreach ($l in $old) { Remove-ItemLabel $n "$l" }
            $out.was = @($old | ForEach-Object { "$_".Substring(7) })
            $detail = "removed the pin to $($out.was -join ', ')"
        }
        'requeue' {
            Assert-Open $info
            if (-not (Test-NameIn "$($info.column)" $c.columns.ai)) { Reject 10 'not-ai-column' "item #$n is in '$($info.column)', which no session works" }
            if (Test-ClaimLive $s) { Reject 10 'owned' "item #$n has a live claim of $($s.claim.holder): release the owner first (release-owner), or let it work" }
            if (Get-Park $s) { Reject 10 'parked' "item #$n is parked ($($s.park.reason)): unpark it, which offers it again" }
            if ((Test-Has $s 'verdict') -and $s.verdict.passed -and -not $s.verdict.processed) { Reject 10 'gateway-merge' 'a PASS verdict waits for the gateway''s merge: there is nothing to offer' }
            if ((Test-Has $s 'merge') -and (Test-Has $s.merge 'awaiting') -and $s.merge.awaiting) { Reject 10 'settling' 'the item is merged and its release is being settled: there is nothing to offer' }
            $s.handoff = @{ column = $info.column; at = ConvertTo-Iso $now }
            $out.reoffer = $true
            $detail = "put it back to be offered in **$($info.column)** at once"
        }
        'prioritize' {
            Assert-Open $info
            $level = if (Test-Has $a 'level') { "$($a.level)" } else { 'top' }
            if ($level -notin 'top', 'high', 'normal') { Reject 2 'usage' 'level is top, high or normal' }
            $pl = Get-PriorityLabels; $cur = Get-ItemPriority $info.labels
            if ($cur -eq $level -or ($level -eq 'normal' -and $cur -eq '')) { Reject 10 'already' "item #$n has priority $level already" }
            foreach ($k in 'top', 'high') { $sp = Get-LabelAsSpelled $info $pl[$k]; if ($sp -and $k -ne $level) { Remove-ItemLabel $n "$sp" } }
            if ($level -ne 'normal' -and -not (Get-LabelAsSpelled $info $pl[$level])) { Add-ItemLabels $n @($pl[$level]) }
            $out.level = $level; $out.was = $(if ($cur) { $cur } else { 'normal' })
            $detail = "set its priority to **$level** (was $($out.was))"
        }
        'rerun-failed' {
            Assert-Open $info
            $prn = if ((Test-Has $s 'pr') -and (Test-Has $s.pr 'number')) { [int]$s.pr.number } else { 0 }
            $pr = if ($prn -gt 0) { try { Get-Pr $prn } catch [FactoryReject] { $null } } else { $null }
            if (-not $pr -or "$($pr.state)" -ne 'open') { $pr = Find-ItemPr $n }
            if (-not $pr) { Reject 10 'no-pr' "item #$n has no open pull request" }
            $head = "$($pr.head.sha)"
            $done = if ((Test-Has $s 'manager_reruns') -and $s.manager_reruns -is [System.Collections.IDictionary]) { $s.manager_reruns } else { @{} }
            if ($done.Contains($head)) { Reject 10 'already-rerun' "the failed jobs of head $($head.Substring(0, 7)) were re-run once already: a second failure is not a flake; report it instead" }
            $runs = @((Invoke-Gh -Path "$(Get-RepoPath)/actions/runs?head_sha=$head&per_page=50").workflow_runs | Where-Object { $_ })
            $failedRuns = @($runs | Where-Object { "$($_.status)" -eq 'completed' -and (-not (Test-Has $_ 'event') -or "$($_.event)" -eq 'pull_request') -and "$($_.conclusion)" -in 'failure', 'timed_out' })
            if ($failedRuns.Count -eq 0) {
                if (@($runs | Where-Object { "$($_.status)" -ne 'completed' }).Count -gt 0) { Reject 10 'run-in-progress' 'a workflow run of the head is still running: GitHub re-runs only a completed run; ask again when it has finished' @{ retryAfterSeconds = 120 } }
                Reject 10 'nothing-failed' "no failed workflow run on head $($head.Substring(0, 7))"
            }
            $started = @(); $refused = @()
            foreach ($r in $failedRuns) {
                $res = Invoke-GhRaw -Method POST -Path "$(Get-RepoPath)/actions/runs/$($r.id)/rerun-failed-jobs"
                if ([int]$res.status -in 200, 201) { $started += @{ id = [long]$r.id } } else { $refused += "$($r.id): $([int]$res.status)" }
            }
            if ($started.Count -eq 0) { Reject 20 'rerun-refused' "GitHub refused the re-run ($($refused -join ', '))" @{ retryAfterSeconds = 60 } }
            # once per head: a later failure of the same head is a real one; the last 10 heads are kept
            $done[$head] = @{ at = ConvertTo-Iso $now; runs = @($started | ForEach-Object { $_.id }) }
            $keep = @($done.Keys | Sort-Object { ConvertFrom-Iso $done[$_].at } | Select-Object -Last 10)
            $s.manager_reruns = @{}; foreach ($k in $keep) { $s.manager_reruns[$k] = $done[$k] }
            $out.pr = [int]$pr.number; $out.sha = $head; $out.runs = @($started | ForEach-Object { $_.id }); $out.refused = $refused
            $detail = "re-ran the failed jobs of PR #$($pr.number) at ``$($head.Substring(0, 7))`` (workflow run $(@($started | ForEach-Object { $_.id }) -join ', ')), once for this head"
        }
    }
    $s.manager_actions = @(@($recent) + @(@{ at = ConvertTo-Iso $now; action = $action; policy = $policy; by = $by }) | Select-Object -Last ([Math]::Max(10, $mc.perItemPerDay)))
    $out.journaled = [bool](Add-Journal $n $st 'manager-action' @{ action = $action; policy = $policy; by = $by; reason = $reason; detail = $detail } "$action|$([string]$now.Ticks)")
    Save-State $n $st
    $out.actions_today = $recent.Count + 1; $out.limit = $mc.perItemPerDay
    return $out
}
