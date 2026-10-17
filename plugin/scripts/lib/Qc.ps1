# PR QC environment, gateway side (rule scripts). Design: docs/design/pr-qc-environment.md.
# The QC record per pull request lives in the work item's state comment (key 'qc'), changed only at transitions and only by these verbs.
# Lease, heartbeat, URL, client address, probe result and log tail live in gateway memory (gateway/Qc.cs), never here and never in a comment.
# Every string a worker supplies passes ConvertTo-QcText before it is persisted: Get-State finds the JSON with a regex on the code fence, so a backtick would corrupt it.

$script:QcLiveStates = @('requested', 'reset', 'assigned', 'building', 'running', 'ready', 'stale')
$script:QcFailCodes = @('build-failed', 'start-failed', 'health-timeout', 'no-reachable-url', 'unreachable-url', 'no-dotnet', 'port-busy', 'no-memory', 'profile-incomplete', 'trust-refused', 'app-down', 'no-worker')
$script:QcTeardownReasons = @('merged', 'closed', 'head-changed', 'idle', 'lifetime', 'person', 'left-validation', 'label-changed', 'worker-stopped', 'drafted')
$script:QcMoves = @{
    'assigned' = @('requested', 'reset', 'assigned'); 'building' = @('assigned'); 'running' = @('building'); 'ready' = @('building', 'running', 'ready')
    'failed' = @('requested', 'reset', 'assigned', 'building', 'running', 'ready', 'stale'); 'stale' = @('assigned', 'building', 'running', 'ready')
    'torn-down' = @('requested', 'reset', 'assigned', 'building', 'running', 'ready', 'stale', 'failed')
}

function Test-QcLoopbackHost([string]$HostName) {
    $h = $HostName.Trim().Trim('[', ']').ToLowerInvariant()
    return ($h -in 'localhost', '0.0.0.0', '::1', '::') -or $h.EndsWith('.localhost') -or ($h -match '^127\.')
}

function Get-QcPublicUrl { "$env:FACTORY_PUBLIC_URL".Trim().TrimEnd('/') }

# The lifetime cap in minutes: timing.qcLifetimeMinutes, else timing.qcLifetimeHours * 60, else 8 hours.
function Get-QcLifetimeMinutes {
    $t = (Get-Cfg).timing
    if (Test-Has $t 'qcLifetimeMinutes') { return [double]$t.qcLifetimeMinutes }
    if (Test-Has $t 'qcLifetimeHours') { return [double]$t.qcLifetimeHours * 60 }
    return 480.0
}

function Get-QcCfg {
    $c = Get-Cfg
    $q = @{ trustProxy = $false; knownProxies = @(); rateLimitPerIp = 10; rateLimitPerPr = 20; probeTimeoutSeconds = 5; minFreeMb = 3500; maxEnvironments = 3; waitingDelaySeconds = 300; trustedAuthors = @(); allowLoopbackForTests = $false }
    if (Test-Has $c 'qc') { foreach ($k in @($c.qc.Keys)) { $q[$k] = $c.qc[$k] } }
    $t = $c.timing
    if ($q.allowLoopbackForTests) {
        $pu = Get-QcPublicUrl; $h = ''; $u = $null
        if ($pu -and [Uri]::TryCreate($pu, [UriKind]::Absolute, [ref]$u)) { $h = $u.Host }
        if (-not (Test-QcLoopbackHost $h)) { Reject 30 'config-invalid' 'qc.allowLoopbackForTests is for tests only and loads only when FACTORY_PUBLIC_URL is a loopback address' }
    }
    if ((Test-Has $t 'qcTokenHours') -and (Test-Has $t 'qcBuildCapMinutes') -and [double]$t.qcTokenHours -le ([double]$t.qcBuildCapMinutes / 60 + (Get-QcLifetimeMinutes) / 60)) {
        Reject 30 'config-invalid' 'timing.qcTokenHours must be above the build cap plus timing.qcLifetimeMinutes, so a live environment never outlives its token'
    }
    return $q
}

# The merge gate (design 3.6): for an item without the Auto Merge label under mergePolicy peer-approved, merge needs a QC run for the current head
# (qc.requireRun) and a GitHub approval of the current head by a person in humanApprovers (qc.requireApproval). Both default to true under
# peer-approved and false otherwise; a null in the config means "default". Read from the raw config so a merge never trips the QC config guards.
function Get-QcGate {
    $c = Get-Cfg; $peer = ("$($c.mergePolicy)" -eq 'peer-approved')
    $q = if (Test-Has $c 'qc') { $c.qc } else { @{} }
    $run = if (Test-Has $q 'requireRun') { [bool]$q.requireRun } else { $peer }
    $appr = if (Test-Has $q 'requireApproval') { [bool]$q.requireApproval } else { $peer }
    return @{ requireRun = $run; requireApproval = $appr }
}
# True when a non-auto-merge item can be merged through the gate at all: owner mode (QC exists), peer-approved, and at least one requirement on.
function Test-QcGateActive {
    if (-not (Test-QcEnabled)) { return $false }
    if ("$((Get-Cfg).mergePolicy)" -ne 'peer-approved') { return $false }
    $g = Get-QcGate
    return ($g.requireRun -or $g.requireApproval)
}

function Test-QcEnabled { ($env:FACTORY_OWNER_MODE -eq '1') -and ("$env:FACTORY_TOKEN_SECRET".Length -ge 16) }

# ---- text hygiene -----------------------------------------------------------------------------------------------------
# Backticks are replaced, control characters dropped, secrets redacted, length capped. Applied to everything a worker sends that is persisted.
function ConvertTo-QcText([string]$Text, [int]$Max = 300) {
    if (-not $Text) { return '' }
    $t = $Text.Replace('`', "'")
    $t = [regex]::Replace($t, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    $t = Protect-JournalText $t
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}
# For journal comments: no @mention can fire.
function ConvertTo-QcJournalText([string]$Text, [int]$Max = 300) { (ConvertTo-QcText $Text $Max).Replace('@', "@$([char]0x200B)") }

# ---- records ----------------------------------------------------------------------------------------------------------
function Get-QcRec($s, [int]$Pr) { if ((Test-Has $s 'qc') -and $s.qc.Contains("$Pr")) { return $s.qc["$Pr"] }; return $null }
function Test-QcLive($rec) { $null -ne $rec -and "$($rec.state)" -in $script:QcLiveStates }

function Add-QcHistory($rec, [string]$State) {
    $h = New-Object System.Collections.ArrayList
    if (Test-Has $rec 'history') { foreach ($x in @($rec.history)) { if ($x) { [void]$h.Add($x) } } }
    [void]$h.Add(@{ state = $State; at = ConvertTo-Iso (Get-UtcNow) })
    if ($h.Count -gt 20) { $h.RemoveRange(0, $h.Count - 20) }
    $rec.history = @($h)
}

function Set-QcState($rec, [string]$To) {
    $rec.state = $To; Add-QcHistory $rec $To
    $rec.rev = 1 + $(if (Test-Has $rec 'rev') { [int]$rec.rev } else { 0 })
}

function Test-QcMove([string]$From, [string]$To) { $script:QcMoves.ContainsKey($To) -and ($script:QcMoves[$To] -contains $From) }

# The local index of items with a live record, so a sweep reaches an item that left Functional Testing.
function Get-QcIndexFile { Join-Path (Get-StateDir) 'qc-items.json' }
function Get-QcIndex { $f = Get-QcIndexFile; if (Test-Path $f) { return @(Get-Content -Raw $f | ConvertFrom-Json -AsHashtable | ForEach-Object { [int]$_ }) }; return @() }
function Update-QcIndex([int]$Item, [bool]$Live) {
    $cur = @(Get-QcIndex | Where-Object { $_ -ne $Item })
    if ($Live) { $cur += $Item }
    ConvertTo-Json -InputObject @($cur) -Compress | Set-Content (Get-QcIndexFile)
}

function Save-QcRecord([int]$n, $st, $rec) {
    $s = $st.state
    if (-not (Test-Has $s 'qc')) { $s.qc = @{} }
    $s.qc["$($rec.pr)"] = $rec
    Save-State $n $st
    $anyLive = $false; foreach ($k in $s.qc.Keys) { if (Test-QcLive $s.qc[$k]) { $anyLive = $true } }
    Update-QcIndex $n $anyLive
}

function Get-QcPr([int]$PrNum) {
    try { return Get-Pr $PrNum }
    catch [FactoryReject] { if ($_.Exception.Exit -eq 12) { Reject 12 'no-such-pr' "pull request #$PrNum does not exist" }; throw }
}

function Get-QcRecByAssignment($s, [string]$Assignment) {
    if (Test-Has $s 'qc') { foreach ($k in $s.qc.Keys) { $x = $s.qc[$k]; if ((Test-Has $x 'assignment') -and "$($x.assignment)" -eq $Assignment) { return $x } } }
    return $null
}

# The token's assignment must be the record's. An assignment this record used to have is stale (11); anything else is not yours (40).
function Assert-QcAssignment($rec, [string]$Assignment) {
    if ($null -eq $rec) { Reject 12 'no-environment' 'no QC environment is recorded for this pull request' }
    if ((Test-Has $rec 'assignment') -and "$($rec.assignment)" -eq $Assignment) { return }
    if ((Test-Has $rec 'old_assignments') -and (@($rec.old_assignments) -contains $Assignment)) { Reject 11 'stale-assignment' 'this assignment was replaced by a reset or a newer attempt; stop and remove what it built' }
    Reject 40 'claim-held' 'this QC environment is not assigned to you'
}

# ---- eligibility and trust ------------------------------------------------------------------------------------------------
function Get-QcEligibility($c, [int]$n, $labels, $column, $s, $pr, $files) {
    $why = New-Object System.Collections.ArrayList
    if ("$($pr.state)" -ne 'open') { [void]$why.Add('pr-not-open') }
    if ($true -eq (Get-Prop $pr 'draft' $false)) { [void]$why.Add('draft') }
    $full = "$(Get-Prop (Get-Prop (Get-Prop $pr 'head' $null) 'repo' $null) 'full_name' '')"
    if ($full -ine "$($c.owner)/$($c.repo)") { [void]$why.Add('fork') }
    if ("$($pr.head.ref)" -notmatch "^$([regex]::Escape($c.name))/$n-") { [void]$why.Add('branch-prefix') }
    if ("$column" -ine "$($c.columns.validation)") { [void]$why.Add('not-in-validation') }
    # A PASS without the Auto Merge label is recorded as processed and parked ('pass-without-auto-merge') for a person to merge: that is exactly the item QC serves.
    if (-not (Test-Has $s 'verdict') -or -not $s.verdict.passed -or [int]$s.verdict.pr -ne [int]$pr.number -or (Test-Has $s 'merge')) { [void]$why.Add('no-pass-verdict') }
    if (Test-NameIn $c.autoMergeLabel @($labels)) { [void]$why.Add('auto-merge') }
    if ($why.Count -eq 0 -and $null -ne $files -and (Test-DocsOnlyFiles $files)) { [void]$why.Add('docs-only') }
    return @{ ok = ($why.Count -eq 0); reasons = @($why) }
}

# Reasons a run needs the operator's confirmation. The anonymous link cannot supply one.
function Get-QcTrust([int]$n, $info, $s, $pr) {
    $c = Get-Cfg; $q = Get-QcCfg; $reasons = @()
    $author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"
    $trusted = @($q.trustedAuthors) + @($c.humanApprovers) + @(Get-ServerLogin)
    if (-not (Test-NameIn $author $trusted)) { $reasons += "author-not-trusted:$author" }
    $facts = Get-InspectFacts $n $info $s $pr
    foreach ($m in @($facts.mandatory)) { if ($m.code -in 'protected-path', 'package-change', 'database-migration', 'secret-like', 'ai-directed-text') { $reasons += "$($m.code)" } }
    return @($reasons)
}

# ---- link token -------------------------------------------------------------------------------------------------------
function ConvertTo-QcB64([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function New-QcToken([int]$Pr, [string]$Sha, [int]$Item) {
    $secret = "$env:FACTORY_TOKEN_SECRET"
    if ($secret.Length -lt 16) { Reject 30 'no-token-secret' 'FACTORY_TOKEN_SECRET is not set on the gateway' }
    $exp = [DateTimeOffset]::UtcNow.AddDays([double](Get-Cfg).timing.qcLinkDays).ToUnixTimeSeconds()
    $payload = (@{ pr = $Pr; sha = $Sha; u = 'qc-open'; x = $exp; n = [guid]::NewGuid().ToString('N'); i = $Item } | ConvertTo-Json -Compress)
    $p = ConvertTo-QcB64 ([Text.Encoding]::UTF8.GetBytes($payload))
    $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secret))
    $mac = ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes('qc:' + $p))) -replace '-', '').ToLowerInvariant()
    return @{ token = "q1.$p.$mac"; expires = $exp }
}

function Get-QcBaseUrl {
    $u = Get-QcPublicUrl
    if (-not $u) { Reject 30 'public-url-not-reachable' 'FACTORY_PUBLIC_URL is not set on the gateway' }
    $uri = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'http', 'https') { Reject 30 'public-url-not-reachable' 'FACTORY_PUBLIC_URL is not an http(s) address' }
    if ((Test-QcLoopbackHost $uri.Host) -and -not (Get-QcCfg).allowLoopbackForTests) { Reject 30 'public-url-not-reachable' "FACTORY_PUBLIC_URL points at $($uri.Host), which nobody else can reach; set it to the address people use" }
    return $u
}

function Get-QcOfferText([int]$Pr, [string]$Sha, [string]$Link, [long]$Exp) {
    $days = [double](Get-Cfg).timing.qcLinkDays
    return @"
QC environment available for PR #$Pr at head $($Sha.Substring(0,7)): [Start the QC environment]($Link)
Nothing runs until someone presses Start. The environment runs on a factory worker's own computer and is reachable only from networks that can reach that computer (the worker is chosen at Start).
The link works for $days days and only for this commit.
<!-- qc link pr=$Pr sha=$Sha exp=$Exp -->
"@
}

function Find-QcOffer($Comments, [int]$Pr, [string]$Login) {
    foreach ($cm in @($Comments)) {
        if ($null -eq $cm) { continue }
        if ($cm.user.login -eq $Login -and "$($cm.body)".Contains("<!-- qc link pr=$Pr ")) { return $cm }
    }
    return $null
}

# Posts or edits the offer on the pull request and on the work item. Returns 'posted', 'edited' or 'unchanged'.
function Update-QcOffer([int]$n, $st, $pr, [switch]$Force) {
    $base = Get-QcBaseUrl; $login = Get-ServerLogin
    $prNum = [int]$pr.number; $sha = "$($pr.head.sha)"
    $outcome = 'unchanged'
    $targets = @(@{ number = $prNum; found = (Find-QcOffer (Get-Comments $prNum) $prNum $login) }, @{ number = $n; found = (Find-QcOffer $st.comments $prNum $login) })
    $minted = $null
    foreach ($t in $targets) {
        $needs = $true
        if ($t.found -and -not $Force) {
            $m = [regex]::Match("$($t.found.body)", 'sha=([0-9a-f]{40}) exp=(\d+)')
            if ($m.Success -and $m.Groups[1].Value -eq $sha -and ([long]$m.Groups[2].Value - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -gt 86400) { $needs = $false }
        }
        if (-not $needs) { continue }
        if (-not $minted) { $minted = New-QcToken $prNum $sha $n }
        $text = Get-QcOfferText $prNum $sha "$base/qc/${prNum}?t=$($minted.token)" $minted.expires
        if ($t.found) { Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/issues/comments/$($t.found.id)" -Body @{ body = $text } | Out-Null; if ($outcome -ne 'posted') { $outcome = 'edited' } }
        else { Invoke-Gh -Method POST -Path "$(Get-RepoPath)/issues/$($t.number)/comments" -Body @{ body = $text } | Out-Null; $outcome = 'posted' }
    }
    if ($outcome -ne 'unchanged') { [void](Add-Journal $n $st 'qc-offered' @{ pr = $prNum; sha7 = $sha.Substring(0, 7) } "$prNum|$sha") }
    return $outcome
}

# After Start the offer comments name the worker (edited once).
function Update-QcAssignedComments([int]$n, $st, $rec) {
    try {
        $login = Get-ServerLogin; $prNum = [int]$rec.pr; $sha = "$($rec.sha)"
        foreach ($t in @(@{ number = $prNum; list = (Get-Comments $prNum) }, @{ number = $n; list = $st.comments })) {
            $f = Find-QcOffer $t.list $prNum $login
            if ($f -and "$($f.body)" -notmatch 'was requested and runs on') {
                # keep the link line so a person can still click it
                $link = [regex]::Match("$($f.body)", '\]\(([^)]+)\)').Groups[1].Value
                $body = "QC environment for PR #$prNum at head $($sha.Substring(0, 7)) runs on **$($rec.worker)**'s computer (reachable only from networks that can reach it): [QC page]($link)`nThis environment was requested and runs on that worker.`n<!-- qc link pr=$prNum sha=$sha exp=$(([regex]::Match("$($f.body)", 'exp=(\d+)')).Groups[1].Value) -->"
                Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/issues/comments/$($f.id)" -Body @{ body = $body } | Out-Null
            }
        }
    } catch { [Console]::Error.WriteLine("qc: could not edit the offer comments: $($_.Exception.Message)") }
}

function Remove-QcOfferText([int]$n, $st, [int]$PrNum, [string]$Why) {
    $login = Get-ServerLogin; $found = Find-QcOffer $st.comments $PrNum $login
    if (-not $found) { return }
    if ("$($found.body)" -match 'is no longer offered') { return }
    $body = "QC environment for PR #$PrNum is no longer offered ($Why).`n<!-- qc link pr=$PrNum sha=withdrawn exp=0 -->"
    Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/issues/comments/$($found.id)" -Body @{ body = $body } | Out-Null
    $pc = Find-QcOffer (Get-Comments $PrNum) $PrNum $login
    if ($pc) { Invoke-Gh -Method PATCH -Path "$(Get-RepoPath)/issues/comments/$($pc.id)" -Body @{ body = $body } | Out-Null }
}

# ---- sweep ------------------------------------------------------------------------------------------------------------
# When the record went stale (the last history entry of that state).
function Get-QcStaleSince($rec) {
    $at = $null
    if (Test-Has $rec 'history') { foreach ($h in @($rec.history)) { if ($h -is [System.Collections.IDictionary] -and "$($h.state)" -eq 'stale') { $at = ConvertFrom-Iso $h.at } } }
    return $at
}

# The sweep offers and tears down. It never creates a record, never assigns or offers a job and never rebuilds on a new head (design 3.5).
# Teardowns it asks for: merged / closed / left-validation / label-changed (as before), and from the persisted record: head-changed after
# timing.qcGraceMinutes in stale, lifetime after timing.qcLifetimeMinutes in ready. Idle and a lost lease need gateway memory and are decided there.
function Invoke-QcSync($List, [bool]$Dry) {
    $c = Get-Cfg; $res = @{ actions = @(); errors = @(); records = @(); teardowns = @(); approvals = @() }
    $null = Get-QcCfg
    $open = @(Invoke-Gh -Path "$(Get-RepoPath)/pulls?state=open&per_page=100")
    $index = @(Get-QcIndex)
    $now = Get-UtcNow
    $graceMin = [double]$c.timing.qcGraceMinutes; $lifeMin = Get-QcLifetimeMinutes
    $gateApproval = (Test-QcGateActive) -and (Get-QcGate).requireApproval
    foreach ($it in $List) {
        if (-not $it.open -or -not (Test-NameIn $c.label $it.labels) -or (Test-NameIn $c.rivalLabel $it.labels)) { continue }
        $n = [int]$it.number
        $inVal = ("$($it.column)" -ieq "$($c.columns.validation)")
        if (-not $inVal -and $index -notcontains $n) { continue }
        try {
            $st = Get-State $n; $s = $st.state
            $verdictPr = if ((Test-Has $s 'verdict') -and (Test-Has $s.verdict 'pr')) { [int]$s.verdict.pr } else { 0 }
            $live = @(); if (Test-Has $s 'qc') { foreach ($k in $s.qc.Keys) { if (Test-QcLive $s.qc[$k]) { $live += $s.qc[$k] } } }
            $pr = $open | Where-Object { [int]$_.number -eq $verdictPr } | Select-Object -First 1
            if (-not $inVal) {
                foreach ($rec in $live) { $res.teardowns += @{ item = $n; pr = [int]$rec.pr; reason = 'left-validation' } ; $res.records += $rec }
                continue
            }
            if ($null -eq $pr) {
                $why = if (Test-Has $s 'merge') { 'merged' } else { 'closed' }
                foreach ($rec in $live) { $res.teardowns += @{ item = $n; pr = [int]$rec.pr; reason = $why }; $res.records += $rec }
                continue
            }
            $head = "$($pr.head.sha)"
            if ($live.Count -gt 0 -and -not $Dry) {
                # a head that moved marks the live record stale. The write runs under the item lock on a fresh read: a verb that finished meanwhile
                # (qc-stopped, a reset) is not overwritten with what this sweep read earlier.
                $toStale = @($live | Where-Object { "$($_.sha)" -ne $head -and "$($_.state)" -ne 'stale' -and (Test-QcMove "$($_.state)" 'stale') })
                if ($toStale.Count -gt 0) {
                    Use-ItemLock $n {
                        $st2 = Get-State $n
                        foreach ($r0 in $toStale) {
                            $cur = Get-QcRec $st2.state ([int]$r0.pr)
                            if ($null -ne $cur -and "$($cur.sha)" -ne $head -and "$($cur.state)" -ne 'stale' -and (Test-QcMove "$($cur.state)" 'stale')) {
                                Set-QcState $cur 'stale'; Save-QcRecord $n $st2 $cur; $res.actions += @{ item = $n; action = 'qc-stale'; pr = [int]$r0.pr }
                            }
                        }
                    }
                    $st = Get-State $n; $s = $st.state
                    $live = @(); if (Test-Has $s 'qc') { foreach ($k in $s.qc.Keys) { if (Test-QcLive $s.qc[$k]) { $live += $s.qc[$k] } } }
                }
            }
            foreach ($rec in $live) {
                $res.records += $rec
                if ($Dry) { continue }
                if ("$($rec.state)" -eq 'stale') {
                    $since = Get-QcStaleSince $rec
                    if ($since -and ($now - $since).TotalMinutes -ge $graceMin) { $res.teardowns += @{ item = $n; pr = [int]$rec.pr; reason = 'head-changed' } }
                } elseif ("$($rec.state)" -eq 'ready' -and (Test-Has $rec 'ready_at')) {
                    $readyAt = ConvertFrom-Iso $rec.ready_at
                    if ($readyAt -and ($now - $readyAt).TotalMinutes -ge $lifeMin) { $res.teardowns += @{ item = $n; pr = [int]$rec.pr; reason = 'lifetime' } }
                }
            }
            # a person's approval of the current head wakes the owner (qc.approved) so it retries merge; the persisted copy follows GitHub
            if ($gateApproval -and -not $Dry -and (Test-Has $s 'verdict') -and -not $s.verdict.processed -and -not (Test-NameIn $c.autoMergeLabel @($it.labels))) {
                $rec0 = Get-QcRec $s ([int]$pr.number)
                $inspected = (Test-Has $s 'approval') -and "$($s.approval.sha)" -eq $head
                if ($null -ne $rec0 -or $inspected) {
                    $by = Find-HumanApproval $pr
                    if ($null -ne $rec0 -and ((Test-QcLive $rec0) -or (Test-Has $rec0 'approved'))) {
                        $differs = if ($by) { -not (Test-Has $rec0 'approved') -or "$($rec0.approved.sha)" -ne $head -or "$($rec0.approved.by)" -ne "$by" } else { Test-Has $rec0 'approved' }
                        if ($differs) { Use-ItemLock $n { $st3 = Get-State $n; [void](Update-QcApproved $n $st3 (Get-QcRec $st3.state ([int]$pr.number)) $head $by) } }
                    }
                    $ran = ($null -ne $rec0) -and (Test-Has $rec0 'ran_sha') -and "$($rec0.ran_sha)" -eq $head
                    if ($by) { $res.approvals += @{ item = $n; pr = [int]$pr.number; sha = $head; by = "$by"; ran = [bool]$ran } }
                }
            }
            $el = Get-QcEligibility $c $n $it.labels $it.column $s $pr $null
            if ($el.ok) { $el = Get-QcEligibility $c $n $it.labels $it.column $s $pr (@(Get-PrFiles ([int]$pr.number))) }
            if ($el.ok) {
                if (-not $Dry) {
                    # this sweep holds no item lock and read the state a while ago: only the journal line of the offer is written, under the lock
                    # on a fresh read (Save-JournalKeys), never the state as it was read here
                    $jk0 = Get-JournalKeys $s
                    $o = Update-QcOffer $n $st $pr
                    if ($o -ne 'unchanged') { $jk1 = @(Get-JournalKeys $s | Where-Object { $jk0 -notcontains $_ }); if ($jk1.Count -gt 0) { Save-JournalKeys $n $jk1 }; $res.actions += @{ item = $n; action = 'qc-offer'; pr = [int]$pr.number; outcome = $o } }
                }
            } else {
                if ($Dry) { continue }
                $note = @($el.reasons | Where-Object { $_ -notin 'auto-merge', 'docs-only', 'no-pass-verdict', 'not-in-validation' })
                if ($note.Count -gt 0) {
                    $posted = Add-Journal $n $st 'skipped' @{ reason = "QC is not offered for PR #$($pr.number): $($note -join ', ')" } "qc|$($pr.number)|$($note -join ',')"
                    if ($posted) { Save-JournalKeys $n @("skipped|qc|$($pr.number)|$($note -join ',')") }
                }
                $hadOffer = [bool](Find-QcOffer $st.comments ([int]$pr.number) (Get-ServerLogin))
                if ($hadOffer) { Remove-QcOfferText $n $st ([int]$pr.number) ($el.reasons -join ', '); $res.actions += @{ item = $n; action = 'qc-withdrawn'; pr = [int]$pr.number } }
                # an Auto Merge label added later ends a running environment
                if ($el.reasons -contains 'auto-merge') { foreach ($rec in $live) { $res.teardowns += @{ item = $n; pr = [int]$rec.pr; reason = 'label-changed' } } }
            }
        } catch [FactoryReject] {
            if ($_.Exception.Code -in 'github-not-found', 'item-not-found') { $res.actions += @{ item = $n; action = 'qc-skip'; reason = 'vanished-during-sweep' } }
            else { $res.errors += @{ item = $n; code = $_.Exception.Code; reason = "qc: $($_.Exception.Message)" } }
        }
        catch { $res.errors += @{ item = $n; code = 'error'; reason = "qc: $($_.Exception.Message)" } }
    }
    return $res
}

function Verb_qc_sync($a) {
    if (-not (Test-QcEnabled)) { Reject 30 'qc-disabled' 'QC environments need the gateway in owner mode with FACTORY_TOKEN_SECRET' }
    $r = Invoke-QcSync (Get-BoardList) ((Test-Has $a 'dry') -and $a.dry)
    return @{ ok = $true; actions = @($r.actions); errors = @($r.errors); records = @($r.records); teardowns = @($r.teardowns); approvals = @($r.approvals) }
}

# ---- verbs: links and pages ---------------------------------------------------------------------------------------------
function Verb_qc_link($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $c = Get-Cfg
    $null = Get-QcCfg
    if ("$env:FACTORY_TOKEN_SECRET".Length -lt 16) { Reject 30 'no-token-secret' 'FACTORY_TOKEN_SECRET is not set on the gateway' }
    $null = Get-QcBaseUrl
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    $pr = Get-QcPr $prNum
    $el = Get-QcEligibility $c $n $info.labels $info.column $s $pr (@(Get-PrFiles $prNum))
    if (-not $el.ok) { Reject 10 'not-eligible' "PR #$prNum is not eligible for a QC environment: $($el.reasons -join ', ')" @{ reasons = @($el.reasons) } }
    $o = Update-QcOffer $n $st $pr
    if ($o -ne 'unchanged') { Save-State $n $st }
    return @{ ok = $true; id = $n; pr = $prNum; outcome = $o }
}

function Get-QcPublicRec($rec) { if ($null -eq $rec) { return $null }; return $rec }

function Verb_qc_view($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $c = Get-Cfg
    $pr = Get-QcPr $prNum; $head = "$($pr.head.sha)"
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    $view = @{ pr = $prNum; item = $n; title = "$($pr.title)"; author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"; head_sha = $head; pr_state = $(if ($true -eq (Get-Prop $pr 'merged' $false)) { 'merged' } else { "$($pr.state)" }) }
    if ((Test-Has $a 'sha') -and "$($a.sha)" -ne $head) {
        $view.current_sha = $head; $view.current_token = (New-QcToken $prNum $head $n).token
        Reject 11 'stale-head' 'this link is for an older commit of the pull request' $view
    }
    $rec = Get-QcRec $s $prNum
    $el = Get-QcEligibility $c $n $info.labels $info.column $s $pr (@(Get-PrFiles $prNum))
    $view.eligible = $el.ok; $view.reasons = @($el.reasons)
    $view.needs_confirmation = @()
    if ($el.ok -and -not (Test-QcLive $rec)) { $view.needs_confirmation = @(Get-QcTrust $n $info $s $pr) }
    if ($null -ne $rec) { $view.record = $rec }
    $view.ok = $true
    return $view
}

# ---- verbs: Start, Reset, Teardown --------------------------------------------------------------------------------------------
function New-QcRecord([int]$n, $pr, [int]$Attempt, [string]$State) {
    $sha = "$($pr.head.sha)"
    $rec = @{ state = $State; sha = $sha; item = $n; pr = [int]$pr.number; author = (ConvertTo-QcText "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')" 64); requested_at = ConvertTo-Iso (Get-UtcNow)
        attempt = $Attempt; env_id = "qc-$($pr.number)-$($sha.Substring(0, 7))-$Attempt"; assignment = ''; worker = ''; history = @(); rev = 0; old_assignments = @() }
    Set-QcState $rec $State
    return $rec
}

function Move-QcAssignmentAside($rec) {
    if ((Test-Has $rec 'assignment') -and "$($rec.assignment)") {
        $old = @(@($rec.old_assignments) + "$($rec.assignment)") | Select-Object -Last 5
        $rec.old_assignments = @($old)
    }
    $rec.assignment = ''; $rec.worker = ''
    foreach ($k in 'accepted_at', 'ready_at', 'expires_at', 'port', 'probe', 'fail', 'teardown', 'approved') { if (Test-Has $rec $k) { $rec.Remove($k) } }
}

function Verb_qc_request($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $c = Get-Cfg
    $isOp = (Test-Has $a 'operator') -and [bool]$a.operator
    $confirm = $isOp -and (Test-Has $a 'confirm') -and [bool]$a.confirm
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    $pr = Get-QcPr $prNum; $head = "$($pr.head.sha)"
    if ((Test-Has $a 'sha') -and "$($a.sha)" -ne $head) { Reject 11 'stale-head' 'this link is for an older commit; nothing was queued' @{ current_sha = $head } }
    $el = Get-QcEligibility $c $n $info.labels $info.column $s $pr (@(Get-PrFiles $prNum))
    if (-not $el.ok) { Reject 10 'not-eligible' "PR #$prNum is not eligible for a QC environment: $($el.reasons -join ', ')" @{ reasons = @($el.reasons) } }
    $existing = Get-QcRec $s $prNum
    if ((Test-QcLive $existing) -and "$($existing.sha)" -eq $head) {
        return @{ ok = $true; id = $n; pr = $prNum; outcome = 'existing'; record = $existing }
    }
    $needs = @(Get-QcTrust $n $info $s $pr)
    if ($needs.Count -gt 0 -and -not $confirm) { Reject 10 'trust-confirm-needed' "this run needs the operator's confirmation: $($needs -join ', ')" @{ reasons = $needs } }
    $previous = $null
    if (Test-QcLive $existing) { $previous = $existing }
    $attempt = if ($null -ne $existing -and "$($existing.sha)" -eq $head) { [int]$existing.attempt + 1 } else { 1 }
    $rec = New-QcRecord $n $pr $attempt 'requested'
    $rec.link_nonce = ConvertTo-QcText "$(if (Test-Has $a 'link_nonce') { $a.link_nonce } else { '' })" 40
    if ($needs.Count -gt 0) { $rec.trust_confirmed = $true }
    if ($null -ne $existing -and (Test-Has $existing 'ran_sha')) { $rec.ran_sha = "$($existing.ran_sha)" }
    [void](Add-Journal $n $st 'qc-requested' @{ pr = $prNum; sha7 = $head.Substring(0, 7); attempt = $attempt } "$prNum|$head|$attempt")
    Save-QcRecord $n $st $rec
    $out = @{ ok = $true; id = $n; pr = $prNum; outcome = 'started'; record = $rec }
    if ($null -ne $previous) { $out.previous = $previous }
    return $out
}

function Verb_qc_reset($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $c = Get-Cfg
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    $rec = Get-QcRec $s $prNum
    if ($null -eq $rec -or "$($rec.state)" -eq 'torn-down') { Reject 12 'no-environment' "no QC environment exists for PR #$prNum; press Start" }
    $pr = Get-QcPr $prNum; $head = "$($pr.head.sha)"
    if ((Test-Has $a 'sha') -and "$($a.sha)" -ne $head) { Reject 11 'stale-head' 'the reset was asked for an older commit' @{ current_sha = $head } }
    $el = Get-QcEligibility $c $n $info.labels $info.column $s $pr (@(Get-PrFiles $prNum))
    if (-not $el.ok) { Reject 10 'not-eligible' "PR #$prNum is not eligible for a QC environment: $($el.reasons -join ', ')" @{ reasons = @($el.reasons) } }
    $previous = @{ worker = "$($rec.worker)"; assignment = "$($rec.assignment)"; env_id = "$($rec.env_id)"; sha = "$($rec.sha)"; accepted = (Test-Has $rec 'accepted_at') }
    $attempt = if ("$($rec.sha)" -eq $head) { [int]$rec.attempt + 1 } else { 1 }
    $new = New-QcRecord $n $pr $attempt 'reset'
    $new.old_assignments = @($rec.old_assignments)
    if ($previous.assignment) { $new.old_assignments = @(@($new.old_assignments) + $previous.assignment | Select-Object -Last 5) }
    if (Test-Has $rec 'trust_confirmed') { $new.trust_confirmed = $rec.trust_confirmed }
    if (Test-Has $rec 'ran_sha') { $new.ran_sha = "$($rec.ran_sha)" }
    [void](Add-Journal $n $st 'qc-reset' @{ pr = $prNum; attempt = $attempt } "$prNum|$head|$attempt")
    Save-QcRecord $n $st $new
    return @{ ok = $true; id = $n; pr = $prNum; outcome = 'reset'; record = $new; previous = $previous }
}

function Verb_qc_teardown($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr')
    $reason = if (Test-Has $a 'reason') { "$($a.reason)" } else { 'person' }
    if ($reason -notin $script:QcTeardownReasons) { $reason = 'person' }
    # an item that vanished has nothing left to tear down; the gateway still drops whatever it holds in memory
    $st = try { Get-State $n } catch [FactoryReject] { if ($_.Exception.Code -eq 'github-not-found') { $null } else { throw } }
    $s = if ($st) { $st.state } else { @{} }; $rec = Get-QcRec $s $prNum
    if ($null -eq $rec -or "$($rec.state)" -eq 'torn-down') { return @{ ok = $true; id = $n; pr = $prNum; outcome = 'already' } }
    $needsStop = (Test-Has $rec 'accepted_at')
    $info = @{ worker = "$($rec.worker)"; assignment = "$($rec.assignment)"; env_id = "$($rec.env_id)"; sha = "$($rec.sha)" }
    if (-not $needsStop) {
        Set-QcState $rec 'torn-down'; $rec.teardown = @{ reason = $reason; at = ConvertTo-Iso (Get-UtcNow) }
        [void](Add-Journal $n $st 'qc-torn-down' @{ pr = $prNum; reason = $reason } "$prNum|$($rec.sha)|$($rec.attempt)")
        Save-QcRecord $n $st $rec
        return @{ ok = $true; id = $n; pr = $prNum; outcome = 'torn-down'; needs_stop = $false; record = $rec; env = $info }
    }
    # asked before and still waiting for the worker's qc-stopped: the first reason stands and nothing is written again
    if (-not (Test-Has $rec 'teardown')) {
        $rec.teardown = @{ reason = $reason; at = ConvertTo-Iso (Get-UtcNow) }
        $rec.rev = 1 + [int]$rec.rev
        Save-QcRecord $n $st $rec
    }
    return @{ ok = $true; id = $n; pr = $prNum; outcome = 'stopping'; needs_stop = $true; record = $rec; env = $info }
}

# Internal (admin): the gateway moves a record when it places a job, finishes a teardown or notices a failure.
function Verb_qc_transition($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $to = "$(Need $a 'to')"
    $st = Get-State $n; $s = $st.state; $rec = Get-QcRec $s $prNum
    if ($null -eq $rec) { Reject 12 'no-environment' "no QC record for PR #$prNum" }
    if ((Test-Has $a 'sha') -and "$($a.sha)" -ne "$($rec.sha)") { Reject 11 'stale-head' 'the record is for another commit' }
    if ((Test-Has $a 'assignment_was') -and "$($a.assignment_was)" -ne "$($rec.assignment)") { Reject 11 'stale-assignment' 'the record has a newer assignment' }
    if ($to -eq 'assigned' -and (Test-Has $a 'relaunch') -and [bool]$a.relaunch) {
        # The worker holding the environment was lost (its lease ran out): back to assigned for another worker, up to timing.qcMaxRelaunches times.
        if ("$($rec.state)" -notin 'assigned', 'building', 'running', 'ready') { Reject 10 'bad-transition' "cannot relaunch from $($rec.state)" }
        $max = if (Test-Has $a 'max_relaunches') { [int]$a.max_relaunches } else { [int](Get-Cfg).timing.qcMaxRelaunches }
        $done = if (Test-Has $rec 'relaunches') { [int]$rec.relaunches } else { 0 }
        if ($done -ge $max) {
            $rec.fail = @{ code = 'no-worker'; reason = ConvertTo-QcText "the worker was lost $done times; the environment was not started again" 300 }
            Set-QcState $rec 'failed'
            [void](Add-Journal $n $st 'qc-failed' @{ pr = $prNum; code = 'no-worker'; reason = (ConvertTo-QcJournalText $rec.fail.reason 300) } "$prNum|$($rec.sha)|$($rec.attempt)")
            Save-QcRecord $n $st $rec
            return @{ ok = $true; id = $n; pr = $prNum; outcome = 'failed'; record = $rec }
        }
        if ((Test-Has $rec 'assignment') -and "$($rec.assignment)") { $rec.old_assignments = @(@($rec.old_assignments) + "$($rec.assignment)" | Select-Object -Last 5) }
        $rec.assignment = ''; $rec.worker = ''
        foreach ($k in 'accepted_at', 'ready_at', 'expires_at', 'port', 'probe', 'fail') { if (Test-Has $rec $k) { $rec.Remove($k) } }
        $rec.relaunches = $done + 1; $rec.mode = 'relaunch'
        Set-QcState $rec 'assigned'
        Save-QcRecord $n $st $rec
        return @{ ok = $true; id = $n; pr = $prNum; outcome = 'relaunch'; record = $rec }
    }
    if ($to -eq 'assigned') {
        if ("$($rec.state)" -notin 'requested', 'reset', 'assigned') { Reject 10 'bad-transition' "cannot assign from $($rec.state)" }
        $newId = ConvertTo-QcText "$(Need $a 'assignment')" 40
        if ((Test-Has $rec 'assignment') -and "$($rec.assignment)" -and "$($rec.assignment)" -ne $newId) { $rec.old_assignments = @(@($rec.old_assignments) + "$($rec.assignment)" | Select-Object -Last 5) }
        $rec.assignment = $newId; $rec.worker = ConvertTo-QcText "$(Need $a 'worker')" 40
        if (Test-Has $a 'mode') { $rec.mode = ConvertTo-QcText "$($a.mode)" 20 }
        if ("$($rec.state)" -ne 'assigned') { Set-QcState $rec 'assigned' } else { $rec.rev = 1 + [int]$rec.rev }
        Save-QcRecord $n $st $rec
        Update-QcAssignedComments $n $st $rec
        return @{ ok = $true; id = $n; pr = $prNum; record = $rec }
    }
    if (-not (Test-QcMove "$($rec.state)" $to)) { Reject 10 'bad-transition' "a QC environment cannot go from $($rec.state) to $to" }
    if ($to -eq 'failed') {
        $code = if ((Test-Has $a 'code') -and "$($a.code)" -in $script:QcFailCodes) { "$($a.code)" } else { 'start-failed' }
        $rec.fail = @{ code = $code; reason = ConvertTo-QcText "$(if (Test-Has $a 'reason') { $a.reason } else { '' })" 300 }
        Set-QcState $rec 'failed'
        [void](Add-Journal $n $st 'qc-failed' @{ pr = $prNum; code = $code; reason = (ConvertTo-QcJournalText $rec.fail.reason 300) } "$prNum|$($rec.sha)|$($rec.attempt)")
    } elseif ($to -eq 'torn-down') {
        $reason = if ((Test-Has $a 'reason') -and "$($a.reason)" -in $script:QcTeardownReasons) { "$($a.reason)" } elseif (Test-Has $rec 'teardown') { "$($rec.teardown.reason)" } else { 'person' }
        $rec.teardown = @{ reason = $reason; at = ConvertTo-Iso (Get-UtcNow) }
        Set-QcState $rec 'torn-down'
        [void](Add-Journal $n $st 'qc-torn-down' @{ pr = $prNum; reason = $reason } "$prNum|$($rec.sha)|$($rec.attempt)")
    } else { Set-QcState $rec $to }
    Save-QcRecord $n $st $rec
    return @{ ok = $true; id = $n; pr = $prNum; record = $rec }
}

function Verb_qc_list($a) {
    $c = Get-Cfg; $records = @(); $available = @()
    $open = @(Invoke-Gh -Path "$(Get-RepoPath)/pulls?state=open&per_page=100")
    foreach ($it in (Get-BoardList)) {
        if (-not $it.open -or -not (Test-NameIn $c.label $it.labels) -or "$($it.column)" -ine "$($c.columns.validation)") { continue }
        $st = Get-State $it.number; $s = $st.state
        if (Test-Has $s 'qc') {
            foreach ($k in $s.qc.Keys) {
                $r0 = $s.qc[$k]; $p0 = $open | Where-Object { [int]$_.number -eq [int]$r0.pr } | Select-Object -First 1
                # the dashboard shows the title and flags a record whose head is no longer the PR's head (copy: nothing here is saved)
                $r0.title = if ($p0) { "$($p0.title)" } else { '' }; $r0.head_sha = if ($p0) { "$($p0.head.sha)" } else { '' }; $r0.pr_open = [bool]$p0
                $records += $r0
            }
        }
        if (-not (Test-Has $s 'verdict') -or -not $s.verdict.passed -or (Test-Has $s 'merge')) { continue }
        $pr = $open | Where-Object { [int]$_.number -eq [int]$s.verdict.pr } | Select-Object -First 1
        if ($null -eq $pr) { continue }
        $el = Get-QcEligibility $c ([int]$it.number) $it.labels $it.column $s $pr (@(Get-PrFiles ([int]$pr.number)))
        $rec = Get-QcRec $s ([int]$pr.number)
        if ($el.ok -and -not (Test-QcLive $rec)) { $available += @{ item = [int]$it.number; pr = [int]$pr.number; sha = "$($pr.head.sha)"; title = "$($pr.title)"; author = "$(Get-Prop (Get-Prop $pr 'user' $null) 'login' '')"; created_at = "$(Get-Prop $pr 'created_at' '')" } }
    }
    $all = (Test-Has $a 'include') -and "$($a.include)" -eq 'all'
    if (-not $all) { $records = @($records | Where-Object { Test-QcLive $_ }) }
    return @{ ok = $true; available = @($available); records = @($records) }
}

# ---- verbs: the worker's side -------------------------------------------------------------------------------------------------
function Invoke-QcAccept([int]$n, $a, [string]$Assignment, [string]$Holder) {
    $st = Get-State $n; $s = $st.state
    $rec = Get-QcRecByAssignment $s $Assignment
    if ($null -eq $rec -or "$($rec.state)" -notin 'assigned', 'building', 'running', 'ready') { Reject 11 'stale-assignment' 'this QC assignment is no longer current' }
    if (-not (Test-Has $rec 'accepted_at')) {
        $rec.accepted_at = ConvertTo-Iso (Get-UtcNow); $rec.worker = ConvertTo-QcText $Holder 40
        $rec.rev = 1 + [int]$rec.rev
        [void](Add-Journal $n $st 'qc-assigned' @{ worker = $rec.worker; pr = [int]$rec.pr; attempt = [int]$rec.attempt } "$Assignment")
        Save-QcRecord $n $st $rec
    }
    return @{ ok = $true; id = $n; accepted = $true; kind = 'qc-env'; role = 'qc'; record = $rec; pr = [int]$rec.pr; sha = "$($rec.sha)"; env_id = "$($rec.env_id)"; mode = "$(if (Test-Has $rec 'mode') { $rec.mode } else { 'first' })"; assignment = $Assignment; state = "$($rec.state)" }
}

function Verb_qc_job($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $c = Get-Cfg
    $assignment = "$(Need $a 'assignment')"
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state; $rec = Get-QcRec $s $prNum
    Assert-QcAssignment $rec $assignment
    if ("$($rec.state)" -notin 'assigned', 'building', 'running', 'ready') { Reject 10 'wrong-state' "the environment is $($rec.state)" }
    $pr = Get-QcPr $prNum; $head = "$($pr.head.sha)"
    $full = "$(Get-Prop (Get-Prop (Get-Prop $pr 'head' $null) 'repo' $null) 'full_name' '')"
    if ($full -ine "$($c.owner)/$($c.repo)") { Reject 10 'fork-pr' 'pull requests from forks are never run' }
    if ($head -ne "$($rec.sha)") { Reject 11 'stale-head' "the pull request moved to $($head.Substring(0, 7)); press Reset" @{ current_sha = $head } }
    $needs = @(Get-QcTrust $n $info $s $pr)
    if ($needs.Count -gt 0 -and -not (Test-Has $rec 'trust_confirmed')) { Reject 10 'qc-trust-refused' "this run needs the operator's confirmation: $($needs -join ', ')" @{ reasons = $needs } }
    return @{ ok = $true; id = $n; pr = $prNum; sha = $head; branch = "$($pr.head.ref)"; env_id = "$($rec.env_id)"; attempt = [int]$rec.attempt
        trust = @{ ok = $true; reasons = @($needs) }; limits = @{ buildCapMinutes = [double]$c.timing.qcBuildCapMinutes; lifetimeMinutes = (Get-QcLifetimeMinutes); lifetimeHours = ((Get-QcLifetimeMinutes) / 60) }; title = @{ text = "$($pr.title)"; untrusted = $true } }
}

function Verb_qc_progress($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $to = "$(Need $a 'state')"
    if ($to -notin 'building', 'running') { Reject 2 'usage' 'state must be building or running' }
    $st = Get-State $n; $s = $st.state; $rec = Get-QcRec $s $prNum
    Assert-QcAssignment $rec "$(Need $a 'assignment')"
    if ("$($rec.state)" -ne $to) {
        if (-not (Test-QcMove "$($rec.state)" $to)) { Reject 10 'bad-transition' "a QC environment cannot go from $($rec.state) to $to" }
        Set-QcState $rec $to; Save-QcRecord $n $st $rec
    }
    $log = if (Test-Has $a 'log_tail') { ConvertTo-QcText "$($a.log_tail)" 1500 } else { '' }
    return @{ ok = $true; id = $n; pr = $prNum; state = "$($rec.state)"; record = $rec; log_tail = $log }
}

# qc-report: the gateway has already checked the URL and probed it; this records the persisted part (never the URL).
function Verb_qc_report($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $sha = "$(Need $a 'sha')"
    $st = Get-State $n; $s = $st.state; $rec = Get-QcRec $s $prNum
    Assert-QcAssignment $rec "$(Need $a 'assignment')"
    if ("$($rec.sha)" -ne $sha) { Reject 11 'stale-head' 'the report is for another commit than the record' @{ current_sha = "$($rec.sha)" } }
    if ("$($a.env_id)" -ne "$($rec.env_id)") { Reject 11 'stale-assignment' 'the report is for another environment than the record' }
    $probe = if ((Test-Has $a 'probe') -and "$($a.probe)" -in 'verified', 'unverified') { "$($a.probe)" } else { 'unverified' }
    $firstTime = ("$($rec.state)" -ne 'ready')
    if ($firstTime) {
        if (-not (Test-QcMove "$($rec.state)" 'ready')) { Reject 10 'bad-transition' "a QC environment cannot go from $($rec.state) to ready" }
        $cfg = Get-Cfg
        Set-QcState $rec 'ready'
        $rec.ready_at = ConvertTo-Iso (Get-UtcNow); $rec.expires_at = ConvertTo-Iso ((Get-UtcNow).AddMinutes((Get-QcLifetimeMinutes)))
        if (Test-Has $a 'port') { $p = 0; if ([int]::TryParse("$($a.port)", [ref]$p)) { $rec.port = $p } }
        $rec.probe = $probe
        # The record of a run for the merge gate: the head this environment reached ready for. Written here and nowhere else; a new record for the same PR carries it over.
        $rec.ran_sha = $sha
        [void](Add-Journal $n $st 'qc-ready' @{ pr = $prNum; worker = $rec.worker; attempt = [int]$rec.attempt; url = $(if (Test-Has $a 'url') { "$($a.url)" } else { '' }) } "$prNum|$($rec.sha)|$($rec.attempt)")
        Save-QcRecord $n $st $rec
    } elseif ("$($rec.probe)" -ne $probe) { $rec.probe = $probe; $rec.rev = 1 + [int]$rec.rev; Save-QcRecord $n $st $rec }
    return @{ ok = $true; id = $n; pr = $prNum; outcome = 'ready'; probe = $probe; record = $rec }
}

function Verb_qc_fail($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr'); $code = "$(Need $a 'code')"
    if ($code -notin $script:QcFailCodes) { Reject 2 'usage' "unknown failure code '$code'" }
    $st = Get-State $n; $s = $st.state; $rec = Get-QcRec $s $prNum
    Assert-QcAssignment $rec "$(Need $a 'assignment')"
    if (-not (Test-QcMove "$($rec.state)" 'failed')) { Reject 10 'bad-transition' "a QC environment cannot go from $($rec.state) to failed" }
    $reason = ConvertTo-QcText "$(if (Test-Has $a 'reason') { $a.reason } else { '' })" 300
    $rec.fail = @{ code = $code; reason = $reason }
    Set-QcState $rec 'failed'
    [void](Add-Journal $n $st 'qc-failed' @{ pr = $prNum; code = $code; reason = (ConvertTo-QcJournalText $reason 300) } "$prNum|$($rec.sha)|$($rec.attempt)")
    Save-QcRecord $n $st $rec
    $log = if (Test-Has $a 'log_tail') { ConvertTo-QcText "$($a.log_tail)" 1500 } else { '' }
    return @{ ok = $true; id = $n; pr = $prNum; state = 'failed'; record = $rec; log_tail = $log }
}

function Verb_qc_stopped($a) {
    $n = Get-ItemNumber $a; $envId = "$(Need $a 'env_id')"; $assignment = "$(Need $a 'assignment')"
    $st = Get-State $n; $s = $st.state
    $rec = $null
    if (Test-Has $s 'qc') { foreach ($k in $s.qc.Keys) { $x = $s.qc[$k]; if ("$($x.env_id)" -eq $envId) { $rec = $x } else { if ((Test-Has $x 'old_assignments') -and (@($x.old_assignments) -contains $assignment)) { return @{ ok = $true; id = $n; outcome = 'old-environment' } } } } }
    if ($null -eq $rec) { Reject 12 'no-environment' "no QC environment '$envId' is recorded for this item" }
    Assert-QcAssignment $rec $assignment
    if ("$($rec.state)" -eq 'torn-down') { return @{ ok = $true; id = $n; outcome = 'already'; pr = [int]$rec.pr; record = $rec } }
    $reason = if (Test-Has $rec 'teardown') { "$($rec.teardown.reason)" } else { 'worker-stopped' }
    $rec.teardown = @{ reason = $reason; at = ConvertTo-Iso (Get-UtcNow) }
    Set-QcState $rec 'torn-down'
    [void](Add-Journal $n $st 'qc-torn-down' @{ pr = [int]$rec.pr; reason = $reason } "$($rec.pr)|$($rec.sha)|$($rec.attempt)")
    Save-QcRecord $n $st $rec
    return @{ ok = $true; id = $n; outcome = 'torn-down'; pr = [int]$rec.pr; record = $rec }
}

# ---- human approval (merge gate trigger) -------------------------------------------------------------------------------------
# Internal (admin): the gateway asks after a pull_request_review webhook. Reads GitHub for the truth (a person in humanApprovers whose latest
# review of the PR is APPROVED at the current head), keeps the persisted copy in the record in step (set, or cleared by a dismissal), and
# answers what the gateway needs to wake the owner: qc.approved is routed when approved is true.
function Verb_qc_approval($a) {
    $n = Get-ItemNumber $a; $prNum = [int](Need $a 'pr')
    $pr = Get-QcPr $prNum; $head = "$($pr.head.sha)"
    $by = Find-HumanApproval $pr
    $st = Get-State $n; $rec = Get-QcRec $st.state $prNum
    $changed = Update-QcApproved $n $st $rec $head $by
    $ran = ($null -ne $rec) -and (Test-Has $rec 'ran_sha') -and "$($rec.ran_sha)" -eq $head
    return @{ ok = $true; id = $n; pr = $prNum; sha = $head; approved = [bool]$by; by = "$by"; ran = [bool]$ran; changed = [bool]$changed }
}

# Sets or clears record.approved; saves only on a change. Returns whether it changed.
function Update-QcApproved([int]$n, $st, $rec, [string]$Head, $By) {
    if ($null -eq $rec) { return $false }
    $had = Test-Has $rec 'approved'
    if ($By) {
        if ($had -and "$($rec.approved.sha)" -eq $Head -and "$($rec.approved.by)" -eq "$By") { return $false }
        $rec.approved = @{ by = ConvertTo-QcText "$By" 64; sha = $Head; at = ConvertTo-Iso (Get-UtcNow) }
    } elseif ($had) { $rec.Remove('approved') }
    else { return $false }
    $rec.rev = 1 + [int]$rec.rev
    Save-QcRecord $n $st $rec
    return $true
}
