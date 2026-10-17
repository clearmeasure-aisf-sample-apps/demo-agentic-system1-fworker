# Owner leases kept by the plant (gateway/Lease.cs, docs/design/plant-manager.md 6b): the client's own acceptance, renewal by verb and by
# heartbeat, the item.check of an owner that went quiet, and the take-back. The scenarios join the manager suite (messaging on, test seams) and run
# on a second gateway each (Msg-OnGateway) that reads the suite's fake GitHub but does not sweep on its own: offers come from the plan seam, and
# its short schedule.* times are its own. The items of the renewal scenario are pinned to a session that never connects, so the suite's own gateway
# offers them to nobody; the take-back scenario's item is not pinned, so that it can be offered again.

function Ls-State([int]$n) {
    $sc = @((Get-FakeIssue $n).comments | Where-Object { $_.body -like '<!-- factory-state:*' })
    if ($sc.Count -eq 0) { return @{} }
    $mm = [regex]::Match($sc[0].body, '(?s)```json\s*(.*?)\s*```'); return ($mm.Groups[1].Value | ConvertFrom-Json -AsHashtable -DateKind String)
}
function Ls-Lease([int]$n) { $s = Ls-State $n; if ($s.ContainsKey('claim')) { return "$($s.claim.lease_until)" }; return '' }
function Ls-Taken($s) { if ($s.ContainsKey('claim') -and $s.claim.ContainsKey('taken_back')) { return "$($s.claim['taken_back'])" }; return '' }
function Ls-Status { Msg-Admin '/api/v1/status' }
function Ls-Owner([int]$n) { $o = (Ls-Status).plant.owners; if ($o -and $o.ContainsKey("$n")) { return "$($o["$n"])" }; return '' }
function Ls-Journal([int]$n, [string]$Event) { , @((Get-FakeIssue $n).comments | Where-Object { $_.body -match "<!-- plant event=$Event " }) }
function Ls-Config([string]$File) { Msg-Config $File { param($c) $c.messaging.allowedWorkers = @('alice', 'bob', 'carol') } }
# the second gateway: the fake GitHub, this suite's config with the three names, and the schedule times of the scenario
function Ls-Env([string]$File, [hashtable]$Times) { Msg-Merge @{ FACTORY_CONFIG = (Ls-Config $File); GITHUB_API_URL = "http://127.0.0.1:$($script:FakePort)" } $Times }
# its start-up sweep is over (it reads the whole fake board once): after it, nothing sweeps unless a verb asks for it
function Ls-Swept { [void](Wait-Until -Seconds 60 -Message 'the start-up sweep' { $null -ne (Ls-Status).lastSweep }) }

$LeaseScenarios = [ordered]@{}

$LeaseScenarios['lease: the client accepts an owner offer itself (acceptedBy client); the session never starts, so after the lease the item is taken back and offered again in resume mode'] = {
    # not pinned: after the take-back the item must be offered to another session (the suite's clients do not accept by themselves)
    $n = New-Item-Fake 'Client accept, no start' 'x' @('factory worker')
    Msg-OnGateway (Ls-Env 'instance.lease-a.json' @{ FACTORY_TIMING_clientStartMinutes = '0.15'; FACTORY_TIMING_staleItemMinutes = '600' }) {
        param($g)
        Ls-Swept
        $c = Msg-Client 'alice' 'lease-a' '' @{ FACTORY_AUTO_ACCEPT = '1' } @('--capacity', '1')
        try {
            Check 'the client registers' (Msg-WaitEvent $c 'worker.registered' 30)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Check 'the client prints the offer, then accepts it by itself: item.accepted, acceptedBy client' (Msg-WaitEvent $c 'item.accepted' 60) (Get-Content -Raw $c.out)
            $acc = Msg-First @(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.accepted' })
            Check 'the line names the item, the client and the lease' ($acc['item'] -eq $n -and $acc.acceptedBy -eq 'client' -and "$($acc.lease_until)" -ne '' -and "$($acc.next)" -match 'owner-session') ($acc | ConvertTo-Json -Compress)
            Check 'the plant owns the item for alice and records acceptedBy client' ((Ls-Owner $n) -eq 'alice' -and @((Ls-Status).lease.clientAccepted | Where-Object { $_.item -eq $n -and $_.acceptedBy -eq 'client' -and $_.worker -eq 'alice' }).Count -eq 1) ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
            Check 'the journal says the client accepted it' (Wait-Until -Seconds 30 { @((Ls-Journal $n 'assigned') | Where-Object { $_.body -match 'accepted by its client' }).Count -eq 1 })
        } finally { Mgr-Stop $c }
        # the session never calls a verb for the item: a worker without auto-accept is there to be offered it again
        $bob = Msg-Open 'name=bob&capacity=20&messaging=1' (Msg-Token 'bob'); Msg-Registered $bob
        try {
            Check 'after clientStartMinutes the lease is ended: taken_back in the state, lease-expired in the journal' (Wait-Until -Seconds 40 { $s = Ls-State $n; $s.ContainsKey('claim') -and "$(Ls-Taken $s)" -eq 'client-accepted-not-started' -and (Ls-Journal $n 'lease-expired').Count -eq 1 }) ((Ls-State $n) | ConvertTo-Json -Compress -Depth 6)
            # (the state is saved inside expire-claim; the plant lets go when that rule script has returned, a moment later)
            Check 'the plant forgot the owner and counted the take-back' (Wait-Until -Seconds 15 { (Ls-Owner $n) -eq '' -and (Ls-Status).lease.takenBack -ge 1 }) ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
            Msg-Read $bob 40 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' -and $_.data['item'] -eq $n }).Count -ge 1 }
            $re = Msg-First @(Msg-Of $bob 'item.assigned' | Where-Object { $_.data['item'] -eq $n })
            Check 'the next sweep offers it again, in resume mode' ($re -and $re.data.mode -eq 'resume') ($re | ConvertTo-Json -Compress -Depth 5)
            $r = Msg-Json (Msg-Verb 'claim-item' (Msg-ItemToken $n 'owner' 'alice') @{ item = $n; renew = $true })
            Check 'the old owner cannot renew the claim it lost' ($r.exit -eq 40 -and $r.code -eq 'claim-not-held') ($r | ConvertTo-Json -Compress)
        } finally { Msg-Close $bob }
    }
}

$LeaseScenarios['lease: a verb and a heartbeat that names the item renew its lease; a quiet owner gets item.check, and an item whose check nobody answers is taken back'] = {
    $n1 = New-Item-Fake 'Lease by verb, check answered' 'x' @('factory worker', 'worker:ghost-lease')
    $n2 = New-Item-Fake 'Lease by heartbeat, check unanswered' 'x' @('factory worker', 'worker:ghost-lease')
    # (two offers accepted one after the other: the suite's 8 s to confirm an offer is too short for the second accept on a loaded runner)
    Msg-OnGateway (Ls-Env 'instance.lease-b.json' @{ FACTORY_TIMING_leaseRenewMinutes = '0'; FACTORY_TIMING_staleItemMinutes = '0.25'; FACTORY_TIMING_staleConfirmMinutes = '0.4'; FACTORY_ASSIGN_ACK_SECONDS = '60' }) {
        param($g)
        Ls-Swept
        $carol = Msg-Open 'name=carol&capacity=5&messaging=1' (Msg-Token 'carol'); Msg-Registered $carol
        try {
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n1; kind = 'own-item'; column = 'Technical Design' }, @{ item = $n2; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Msg-Read $carol 20 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' }).Count -ge 2 }
            $tok = @{}
            $evs = Msg-Of $carol 'item.assigned'; foreach ($ev in $evs) { $d = $ev.data; $ik = "$($d['item'])"; $tok[$ik] = "$($d['token'])" }
            foreach ($i in $n1, $n2) { $r = Msg-Json (Msg-Verb 'accept' $tok["$i"] @{ item = $i }); Check "carol accepts #$i" ($r.exit -eq 0) ($r | ConvertTo-Json -Compress) }
            $l1 = Ls-Lease $n1; $l2 = Ls-Lease $n2
            Start-Sleep -Seconds 1.2
            [void](Msg-Verb 'get-item' $tok["$n1"] @{ item = $n1 })
            Check 'a verb for the item renews its lease (the gateway calls claim-item --renew)' (Wait-Until -Seconds 30 { (Ls-Lease $n1) -gt $l1 }) "$l1 -> $(Ls-Lease $n1)"
            Check 'the other item was not renewed by it' ((Ls-Lease $n2) -eq $l2)
            $p = Msg-Post '/api/v1/presence' @{ summary = "working on #$n2 (design)" } (Msg-Token 'carol')
            Check 'a heartbeat whose summary names the item renews its lease' ($p.status -eq 200 -and (Wait-Until -Seconds 30 { (Ls-Lease $n2) -gt $l2 })) "$l2 -> $(Ls-Lease $n2)"
            # (Lease.Renew counts a renewal after its claim-item call has saved the new lease: the state can show it a moment before the counter)
            Check 'the renewals are counted' (Wait-Until -Seconds 30 { (Ls-Status).lease.renewals -ge 2 }) ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
            # quiet from here: heartbeats go on with the same summary, no verb. Both items get one item.check.
            $checks = { $x = Msg-Of $carol 'item.check'; $x }
            $end = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $end -and @((& $checks) | Where-Object { $_.data['item'] -in $n1, $n2 } | ForEach-Object { $_.data['item'] } | Select-Object -Unique).Count -lt 2) { [void](Msg-Post '/api/v1/presence' @{} (Msg-Token 'carol')); Msg-Read $carol 3 }
            $ck = @((& $checks) | Where-Object { $_.data['item'] -in $n1, $n2 })
            Check 'after staleItemMinutes without a verb and with the summary unchanged, each item gets item.check' (@($ck | ForEach-Object { $_.data['item'] } | Select-Object -Unique).Count -eq 2 -and "$($ck[0].data.reason)" -match 'claim-item') ($ck | ConvertTo-Json -Compress -Depth 5)
            # the owner answers for n1 with a verb; n2 stays silent
            [void](Msg-Verb 'claim-item' $tok["$n1"] @{ item = $n1; renew = $true })
            Check 'one item.check per quiet spell' (@((& $checks) | Where-Object { $_.data['item'] -eq $n1 }).Count -eq 1)
            Msg-Read $carol 40 { param($e) @($e | Where-Object { $_.data.event -eq 'item.taken_back' }).Count -ge 1 }
            $tb = Msg-Of $carol 'item.taken_back'
            Check 'the unanswered item is taken back; the answered one is not' ($tb.Count -eq 1 -and $tb[0].data['item'] -eq $n2) ($tb | ConvertTo-Json -Compress -Depth 5)
            Check 'its lease is ended in the state and the journal says why' (Wait-Until -Seconds 30 { "$(Ls-Taken (Ls-State $n2))" -eq 'no-answer-to-item-check' -and (Ls-Journal $n2 'lease-expired').Count -eq 1 }) ((Ls-State $n2) | ConvertTo-Json -Compress -Depth 6)
            Check 'the plant still names carol for the answered item only' ((Ls-Owner $n1) -eq 'carol' -and (Ls-Owner $n2) -eq '') ((Ls-Status).plant.owners | ConvertTo-Json -Compress)
        } finally { Msg-Close $carol }
    }
}

# busy owners are not quiet (Lease.cs rule 3, Progress.ps1): local progress sent with the heartbeat counts like a verb and answers an item.check
$LeaseScenarios['lease: local progress sent with the heartbeat keeps a busy owner without verbs; once it stops the item gets item.check, and newer progress answers it'] = {
    $n = New-Item-Fake 'Busy owner, progress by heartbeat' 'x' @('factory worker', 'worker:ghost-lease')
    $other = New-Item-Fake 'Not owned by carol' 'x' @('factory worker', 'worker:ghost-lease')
    Msg-OnGateway (Ls-Env 'instance.lease-p.json' @{ FACTORY_TIMING_leaseRenewMinutes = '0'; FACTORY_TIMING_staleItemMinutes = '0.25'; FACTORY_TIMING_staleConfirmMinutes = '0.4' }) {
        param($g)
        Ls-Swept
        $carol = Msg-Open 'name=carol&capacity=5&messaging=1' (Msg-Token 'carol'); Msg-Registered $carol
        try {
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Msg-Read $carol 20 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' -and $_.data['item'] -eq $n }).Count -ge 1 }
            $tok = "$((Msg-First @(Msg-Of $carol 'item.assigned' | Where-Object { $_.data['item'] -eq $n })).data['token'])"
            $r = Msg-Json (Msg-Verb 'accept' $tok @{ item = $n }); Check 'carol accepts the item' ($r.exit -eq 0) ($r | ConvertTo-Json -Compress)
            $bad = Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = 0; source = 'guess' }) } (Msg-Token 'carol')
            $bad2 = Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = -5; source = 'files' }) } (Msg-Token 'carol')
            Check 'a progress entry with an unknown source or a negative age is refused (400 usage)' ($bad.status -eq 400 -and $bad.code -eq 'usage' -and $bad2.status -eq 400) "$($bad | ConvertTo-Json -Compress) $($bad2 | ConvertTo-Json -Compress)"
            $checksOf = { $x = Msg-Of $carol 'item.check'; @($x | Where-Object { $_.data['item'] -eq $n }) }
            $l0 = Ls-Lease $n
            # 30 s of work on the machine and no verb: every 3 s a heartbeat with progress (staleItemMinutes is 15 s)
            $end = (Get-Date).AddSeconds(30); $last = $null
            while ((Get-Date) -lt $end) { $last = Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = 1; source = 'files' }, @{ item = $other; ageSeconds = 1; source = 'files' }) } (Msg-Token 'carol'); Msg-Read $carol 3 }
            Check 'the heartbeat answers which items the progress counted for: the owned one only' ($last.status -eq 200 -and @($last.progress) -contains $n -and @($last.progress) -notcontains $other) ($last | ConvertTo-Json -Compress)
            Check 'no item.check while progress keeps coming, though no verb was called for twice staleItemMinutes' (@(& $checksOf).Count -eq 0)
            Check 'progress renews the lease like a summary that names the item' (Wait-Until -Seconds 20 { (Ls-Lease $n) -gt $l0 }) "$l0 -> $(Ls-Lease $n)"
            $ls = (Ls-Status).lease
            Check '/status lease lists the progress of the item (worker, source) and counts the reports' ($ls.progressReports -ge 5 -and @($ls.progress | Where-Object { $_.item -eq $n -and $_.worker -eq 'carol' -and $_.source -eq 'files' }).Count -eq 1 -and @($ls.progress | Where-Object { $_.item -eq $other }).Count -eq 0) ($ls | ConvertTo-Json -Compress -Depth 5)
            # the work stops: heartbeats go on without progress, and after staleItemMinutes the item gets its check
            $end = (Get-Date).AddSeconds(40)
            while ((Get-Date) -lt $end -and @(& $checksOf).Count -eq 0) { [void](Msg-Post '/api/v1/presence' @{} (Msg-Token 'carol')); Msg-Read $carol 3 }
            $ck = @(& $checksOf)
            Check 'without progress the quiet owner gets item.check; progress still counts (within progressMaxMinutes)' ($ck.Count -eq 1 -and $ck[0].data['progressCounts'] -eq $true) ($ck | ConvertTo-Json -Compress -Depth 5)
            # the subagent writes again: progress newer than the start of the quiet spell answers the check, so the item is not taken back
            $p = Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = 0; source = 'marker' }) } (Msg-Token 'carol')
            Check 'the progress is counted' ($p.status -eq 200 -and @($p.progress) -contains $n) ($p | ConvertTo-Json -Compress)
            Check 'progress answers the open check (counted, no check open)' (Wait-Until -Seconds 10 { $x = (Ls-Status).lease; $x.checksAnsweredByProgress -ge 1 -and @($x.checksOpen | Where-Object { $_.item -eq $n }).Count -eq 0 }) ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
            # the subagent goes on writing: the item stays carol's past staleConfirmMinutes
            $end = (Get-Date).AddSeconds(30); while ((Get-Date) -lt $end) { [void](Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = 0; source = 'marker' }) } (Msg-Token 'carol')); Msg-Read $carol 3 }
            $tb = Msg-Of $carol 'item.taken_back'
            Check 'the item is not taken back after staleConfirmMinutes: carol still owns it' ($tb.Count -eq 0 -and (Ls-Owner $n) -eq 'carol' -and "$(Ls-Taken (Ls-State $n))" -eq '') ((Ls-Status).plant.owners | ConvertTo-Json -Compress)
        } finally { Msg-Close $carol }
    }
}

# The client side: the stream client watches the work directory and the item's worktree, sends what it saw with the heartbeat, and answers an
# item.check itself when it saw work recently. A checkout of its own (a git repository with a worktree for the item) stands for the session's clone.
function Ls-Repo([int]$n) {
    $repo = Join-Path $script:Work "progress-repo-$n"; New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -q -b master 2>$null; & git -C $repo -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init 2>$null
    $wt = Join-Path $script:Work "progress-wt-$n"; & git -C $repo worktree add -q -b "factory-worker/$n-development" $wt 2>$null
    return @{ repo = $repo; wt = $wt }
}
$LeaseScenarios['lease: the stream client sends the work it sees on its machine (a progress file, a changed worktree) with the heartbeat; an item.check is answered by the client itself [full]'] = {
    $n = New-Item-Fake 'Busy owner, client progress' 'x' @('factory worker', 'worker:ghost-lease')
    $place = Ls-Repo $n
    $work = Join-Path $script:Work "progress-work-$n"; New-Item -ItemType Directory -Force -Path (Join-Path $work 'progress') | Out-Null
    Msg-OnGateway (Ls-Env 'instance.lease-q.json' @{ FACTORY_TIMING_leaseRenewMinutes = '0'; FACTORY_TIMING_staleItemMinutes = '0.25'; FACTORY_TIMING_staleConfirmMinutes = '0.4' }) {
        param($g)
        Ls-Swept
        $c = Msg-Client 'alice' 'progress' '' @{ FACTORY_HEARTBEAT_SECONDS = '2'; FACTORY_WORK_DIR = $work; FACTORY_REPO_DIR = $place.repo; FACTORY_PROGRESS_RECENT_MINUTES = '2' } @('--capacity', '1')
        try {
            Check 'the client registers' (Msg-WaitEvent $c 'worker.registered' 30)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            $tf = Join-Path $script:Work "tokens-alice/$n.owner"
            Check 'the offer arrives and the client saves the item token' (Wait-Until -Seconds 30 { Test-Path -LiteralPath $tf })
            $r = Msg-Json (Msg-Verb 'accept' (Get-Content -Raw -LiteralPath $tf).Trim() @{ item = $n }); Check 'the session accepts the item' ($r.exit -eq 0) ($r | ConvertTo-Json -Compress)
            # a subagent at work: the progress file every 3 s for 30 s, no verb
            $pf = Join-Path $work "progress/$n.txt"; $end = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $end) { Set-Content -LiteralPath $pf -Value ([DateTime]::UtcNow.ToString('o')); Start-Sleep -Seconds 3 }
            $ls = (Ls-Status).lease
            Check 'the heartbeat carried the progress file as progress of the item (source marker or work: it lies in the work directory)' (@($ls.progress | Where-Object { $_.item -eq $n -and $_.worker -eq 'alice' -and $_.source -in 'marker', 'work' }).Count -eq 1) ($ls | ConvertTo-Json -Compress -Depth 5)
            Check 'no item.check reached the client while the subagent wrote' (@(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.check' }).Count -eq 0) (Get-Content -Raw $c.out)
            # a change in the item's worktree (an edit or a build output) counts as well
            Start-Sleep -Seconds 3
            Set-Content -LiteralPath (Join-Path $place.wt 'built.txt') -Value 'x'
            Check 'a file written in the item''s worktree is reported as progress (source files or commit)' (Wait-Until -Seconds 20 { @((Ls-Status).lease.progress | Where-Object { $_.item -eq $n -and $_.source -in 'files', 'commit' }).Count -eq 1 }) ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
        } finally { Mgr-Stop $c }
        # the same session without progress in its heartbeat (FACTORY_PROGRESS_HEARTBEAT=0: as with messaging off): the check arrives, and the client
        # answers it itself because it saw work within FACTORY_PROGRESS_RECENT_MINUTES
        $c2 = Msg-Client 'alice' 'progress-2' '' @{ FACTORY_HEARTBEAT_SECONDS = '2'; FACTORY_WORK_DIR = $work; FACTORY_REPO_DIR = $place.repo; FACTORY_PROGRESS_RECENT_MINUTES = '2'; FACTORY_PROGRESS_HEARTBEAT = '0' } @('--capacity', '1')
        try {
            Check 'the second client registers and is told about the owned item again (resent)' (Wait-Until -Seconds 30 { @(Msg-ClientEvents $c2 | Where-Object { $_.event -eq 'item.assigned' -and $_['item'] -eq $n }).Count -ge 1 }) (Get-Content -Raw $c2.out)
            $end = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $end -and @(Msg-ClientEvents $c2 | Where-Object { $_.event -eq 'item.check-answered' }).Count -eq 0) { Set-Content -LiteralPath $pf -Value ([DateTime]::UtcNow.ToString('o')); Start-Sleep -Seconds 3 }
            $ck = Msg-First @(Msg-ClientEvents $c2 | Where-Object { $_.event -eq 'item.check' -and $_['item'] -eq $n })
            Check 'the item.check line says the client answers it (answeredBy client, the progress it saw)' ($ck -and $ck.answeredBy -eq 'client' -and $ck.progress.source -in 'marker', 'work', 'files', 'commit') ($ck | ConvertTo-Json -Compress -Depth 5)
            $an = Msg-First @(Msg-ClientEvents $c2 | Where-Object { $_.event -eq 'item.check-answered' -and $_['item'] -eq $n })
            Check 'the client renewed the claim itself: item.check-answered ok' ($an -and $an.ok -eq $true -and $an.by -eq 'client') (Get-Content -Raw $c2.out)
            Start-Sleep -Seconds 26
            Check 'the item is not taken back: alice still owns it' (@(Msg-ClientEvents $c2 | Where-Object { $_.event -eq 'item.taken_back' }).Count -eq 0 -and (Ls-Owner $n) -eq 'alice') ((Ls-Status).plant.owners | ConvertTo-Json -Compress)
        } finally { Mgr-Stop $c2 }
    }
}

# The cap (schedule.progressMaxMinutes): a machine that stays busy while the session itself does nothing holds the item only so long. After it the
# check goes out although progress keeps coming (progressCounts false), progress does not answer it, and the item is taken back.
$LeaseScenarios['lease: progress counts only within progressMaxMinutes of the session''s own last verb; after it the check stands and the item is taken back [full]'] = {
    $n = New-Item-Fake 'Busy machine, idle session' 'x' @('factory worker', 'worker:ghost-lease')
    Msg-OnGateway (Ls-Env 'instance.lease-cap.json' @{ FACTORY_TIMING_leaseRenewMinutes = '0'; FACTORY_TIMING_staleItemMinutes = '0.25'; FACTORY_TIMING_staleConfirmMinutes = '0.3'; FACTORY_TIMING_progressMaxMinutes = '0.4' }) {
        param($g)
        Ls-Swept
        $carol = Msg-Open 'name=carol&capacity=5&messaging=1' (Msg-Token 'carol'); Msg-Registered $carol
        try {
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Msg-Read $carol 20 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' -and $_.data['item'] -eq $n }).Count -ge 1 }
            $tok = "$((Msg-First @(Msg-Of $carol 'item.assigned' | Where-Object { $_.data['item'] -eq $n })).data['token'])"
            $r = Msg-Json (Msg-Verb 'accept' $tok @{ item = $n }); Check 'carol accepts the item' ($r.exit -eq 0) ($r | ConvertTo-Json -Compress)
            # progress every 3 s, no verb, no summary: within 24 s of the accept it counts; after that the check goes out and is not answered by it
            $checksOf = { $x = Msg-Of $carol 'item.check'; @($x | Where-Object { $_.data['item'] -eq $n }) }
            $taken = { $x = Msg-Of $carol 'item.taken_back'; @($x | Where-Object { $_.data['item'] -eq $n }) }
            $end = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $end -and @(& $taken).Count -eq 0) { [void](Msg-Post '/api/v1/presence' @{ progress = @(@{ item = $n; ageSeconds = 0; source = 'process' }) } (Msg-Token 'carol')); Msg-Read $carol 3 }
            $ck = @(& $checksOf)
            Check 'past the cap the check goes out although progress keeps coming, marked progressCounts false' ($ck.Count -ge 1 -and $ck[0].data['progressCounts'] -eq $false) ($ck | ConvertTo-Json -Compress -Depth 5)
            Check 'progress does not answer it: the item is taken back' (@(& $taken).Count -eq 1 -and (Ls-Owner $n) -eq '') ((Ls-Status).lease | ConvertTo-Json -Compress -Depth 5)
            $c2 = Msg-Json (Msg-Verb 'claim-item' $tok @{ item = $n; renew = $true; renewed_by = 'client' })
            Check 'and the client''s own renew cannot bring it back' ($c2.exit -eq 40) ($c2 | ConvertTo-Json -Compress)
        } finally { Msg-Close $carol }
    }
}

# Issue 100: a blocked session kept winning items. Its client accepted every offer by itself (accepted_by client), which counted as answering, and
# the take-back that followed counted as nothing. Now the client's accept is no answer, every take-back is a miss, and two misses in a row with a
# take-back among them block the session until it calls a verb of its own: the plant event session-blocked, the digest entry, no offer meanwhile.
$LeaseScenarios['lease: items taken back from a session count as misses and the client''s accept is no answer; after two in a row the session is blocked until it calls a verb of its own'] = {
    $n = New-Item-Fake 'Blocked session' 'x' @('factory worker')
    Msg-OnGateway (Ls-Env 'instance.lease-c.json' @{ FACTORY_TIMING_clientStartMinutes = '0.1'; FACTORY_TIMING_staleItemMinutes = '600'; FACTORY_TIMING_offerCoolDownMinutes = '600' }) {
        param($g)
        Ls-Swept
        $c = Msg-Client 'alice' 'lease-c' '' @{ FACTORY_AUTO_ACCEPT = '1' } @('--capacity', '1')
        $alice = { Msg-First @((Ls-Status).plant.workers | Where-Object { $_.name -eq 'alice' }) }
        try {
            Check 'the client registers' (Msg-WaitEvent $c 'worker.registered' 30)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            # the client accepts by itself, the session never starts: taken back; the sweep that follows offers the item to alice again (no other session)
            # the second offer comes from the plan here, not from a sweep: a sweep's timing decided whether the item came back within the wait (issue 154)
            Check 'the item is accepted by the client and taken back' (Wait-Until -Seconds 60 { (Ls-Journal $n 'lease-expired').Count -ge 1 }) "lease-expired $((Ls-Journal $n 'lease-expired').Count)"
            [void](Wait-Until -Seconds 20 { -not (Msg-First @((Ls-Status).plant.assignments | Where-Object { $_.item -eq $n -and $_.kind -eq 'own-item' -and "$($_.worker)" -eq 'alice' })) })
            if ((Ls-Journal $n 'lease-expired').Count -lt 2) { [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() }) }
            Check 'and accepted and taken back a second time' (Wait-Until -Seconds 60 { (Ls-Journal $n 'lease-expired').Count -ge 2 }) "lease-expired $((Ls-Journal $n 'lease-expired').Count)"
            Check 'the client accepted it each time (acceptedBy client)' (@(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.accepted' -and $_['item'] -eq $n -and $_.acceptedBy -eq 'client' }).Count -ge 2)
            Check 'two take-backs in a row block the session: the client''s accept between them did not count as answering' (Wait-Until -Seconds 20 { $w = & $alice; $w -and $w.blocked -eq $true -and "$($w.blockedSince)" -ne '' }) ((& $alice) | ConvertTo-Json -Compress)
            Check 'the journal says why' (Wait-Until -Seconds 20 { @((Ls-Journal $n 'reassigned') | Where-Object { $_.body -like '*is offered nothing until it calls a verb of its own*' }).Count -eq 1 })
            Check 'the status counts it' ((Ls-Status).plant.sessionsBlocked -ge 1)
            $dg = (Msg-Admin '/api/v1/digest').digest
            $e = Msg-First @($dg.attention | Where-Object { $_.kind -eq 'session-blocked' -and $_.worker -eq 'alice' })
            Check 'the digest reports session-blocked with the item, in the schema' ($e -and $e.item -eq $n -and @(Mgr-DigestProblems $dg).Count -eq 0) (($dg | ConvertTo-Json -Compress -Depth 6) + ' ' + (@(Mgr-DigestProblems $dg) -join ','))
            $acc = @(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.accepted' -and $_['item'] -eq $n }).Count
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Start-Sleep -Seconds 4
            $wt = Msg-First @((Ls-Status).plant.assignments | Where-Object { $_.item -eq $n -and $_.kind -eq 'own-item' })
            Check 'a blocked session is offered nothing: the item waits' ($wt -and "$($wt.worker)" -eq '' -and @(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.accepted' -and $_['item'] -eq $n }).Count -eq $acc) ($wt | ConvertTo-Json -Compress)
            # a verb of the session's own (my-items with its worker credential) ends the block
            $r = Msg-Json (Msg-Verb 'my-items' (Msg-Token 'alice') @{})
            Check 'alice calls a verb of its own' ($r.exit -eq 0) ($r | ConvertTo-Json -Compress)
            Check 'that ends the block' (Wait-Until -Seconds 10 { (& $alice).blocked -eq $false }) ((& $alice) | ConvertTo-Json -Compress)
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Check 'and the item is offered to alice again' (Wait-Until -Seconds 30 { @(Msg-ClientEvents $c | Where-Object { $_.event -eq 'item.accepted' -and $_['item'] -eq $n }).Count -gt $acc })
        } finally { Mgr-Stop $c }
    }
}

$LeaseScenarios['lease: an owner whose complete answered continue and that calls nothing more for the item within continueMinutes is taken back at once (issue 76); one that goes on keeps it'] = {
    $n1 = New-Item-Fake 'Continue, then silent' 'x' @('factory worker', 'worker:ghost-lease')
    $n2 = New-Item-Fake 'Continue, then goes on' 'x' @('factory worker', 'worker:ghost-lease')
    Msg-OnGateway (Ls-Env 'instance.lease-c.json' @{ FACTORY_TIMING_continueMinutes = '0.25'; FACTORY_TIMING_staleItemMinutes = '600' }) {
        param($g)
        Ls-Swept
        $carol = Msg-Open 'name=carol&capacity=5&messaging=1' (Msg-Token 'carol'); Msg-Registered $carol
        try {
            [void](Msg-Post '/api/v1/_test/plan' @{ offers = @(@{ item = $n1; kind = 'own-item'; column = 'Technical Design' }, @{ item = $n2; kind = 'own-item'; column = 'Technical Design' }); pins = @{}; owned = @{}; keep = @() })
            Msg-Read $carol 20 { param($e) @($e | Where-Object { $_.data.event -eq 'item.assigned' }).Count -ge 2 }
            $tok = @{}
            foreach ($ev in (Msg-Of $carol 'item.assigned')) { $d = $ev.data; $tok["$($d['item'])"] = "$($d['token'])" }
            # both accepted first: an offer not accepted within the ack window is withdrawn
            foreach ($i in $n1, $n2) { $r = Msg-Json (Msg-Verb 'accept' $tok["$i"] @{ item = $i }); Check "carol accepts #$i" ($r.exit -eq 0) ($r | ConvertTo-Json -Compress) }
            foreach ($i in $n1, $n2) {
                $r = Msg-Json (Msg-Verb 'append-body' $tok["$i"] @{ item = $i; column = 'Technical Design'; content = "## Technical Design`n`n<!-- aisf:docs-only -->`n- change as described.`n" }); Check "the design of #$i is appended" ($r.exit -eq 0) ($r | ConvertTo-Json -Compress)
                $rv = Msg-Json (Msg-Verb 'record-review' $tok["$i"] @{ item = $i; column = 'Technical Design'; role = 'reviewer'; text = "ok`nREVIEW: COMPLETE" }); Check "the review of #$i is recorded" ($rv.exit -eq 0) ($rv | ConvertTo-Json -Compress)
                $c = Msg-Json (Msg-Verb 'complete' $tok["$i"] @{ item = $i; column = 'Technical Design'; review_ref = $rv.review_ref; comment = 'REVIEW: COMPLETE - design done' })
                Check "#$i completes Technical Design with continue" ($c.exit -eq 0 -and $c.continue -eq $true -and $c.next_column -eq 'Development') ($c | ConvertTo-Json -Compress -Depth 4)
            }
            # n2's session goes on into the next column (any call counts); n1's session ended at the column
            [void](Msg-Verb 'get-item' $tok["$n2"] @{ item = $n2 })
            Msg-Read $carol 40 { param($e) @($e | Where-Object { $_.data.event -eq 'item.taken_back' }).Count -ge 1 }
            $tb = Msg-Of $carol 'item.taken_back'
            Check 'the silent item is taken back after continueMinutes; the one that went on is not' ($tb.Count -eq 1 -and $tb[0].data['item'] -eq $n1 -and "$($tb[0].data.reason)" -eq 'no-call-after-complete') ($tb | ConvertTo-Json -Compress -Depth 5)
            Check 'its lease is ended in the state and the journal says why' (Wait-Until -Seconds 30 { "$(Ls-Taken (Ls-State $n1))" -eq 'no-call-after-complete' -and @((Ls-Journal $n1 'reassigned') | Where-Object { $_.body -match 'called nothing for the item' }).Count -eq 1 }) ((Ls-State $n1) | ConvertTo-Json -Compress -Depth 6)
            Check 'the plant still names carol for the item that went on only' ((Ls-Owner $n2) -eq 'carol' -and (Ls-Owner $n1) -eq '') ((Ls-Status).plant.owners | ConvertTo-Json -Compress)
        } finally { Msg-Close $carol }
    }
}
