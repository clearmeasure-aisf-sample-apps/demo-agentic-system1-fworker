# Server side of the gateway's leader lease (gateway/Leader.cs, issue 94). Only one gateway may act on the board, but in single-revision mode the
# platform starts a new revision before it stops the old one. The lease says which process acts: the ref refs/factory/<instance>/gateway-leader
# points at a commit whose message is the lease record (JSON: epoch, holder, version, until when it is held, whether it was released). Every
# change is a compare-and-swap: the new commit's parent is the commit the writer read, and the ref is moved without force, so GitHub refuses the
# update (422, not a fast forward) when another process moved it in between; the writer then reads again. The tree of every commit is master's
# tree, so nothing new is stored but the message. The epoch only grows: a process that starts takes epoch+1 (the newest process acts), a holder
# renews its own epoch. Admin verb, called by the gateway only (gateway/Leader.cs), never through the verb route.
#
# leader-lease { action, holder, epoch, ttl_seconds, version, revision, replica, tree, sha, etag }
#   acquire  take the lease with the next epoch, whatever the current record says; answers the predecessor's record
#   renew    the holder's epoch is still the current one: until = now + ttl; else leader false and the current record
#   check    is the holder's epoch still the current one? one conditional read (an unchanged ref answers 304, which GitHub does not count)
#   release  the holder's epoch ends now (a graceful stop): released true, until now, plant_epoch (whose snapshot holds the plant)
function Get-LeaderRefPath { "factory/$((Get-Cfg).name)/gateway-leader" }

function Read-LeaderLease([string]$Etag = '') {
    $repo = Get-RepoPath; $path = Get-LeaderRefPath
    $hdr = @{}; if ($Etag) { $hdr['If-None-Match'] = $Etag }
    $r = Invoke-GhRaw -Path "$repo/git/ref/$path" -Headers $hdr
    if ($r.status -eq 304) { return @{ unchanged = $true; etag = $Etag } }
    if ($r.status -eq 404) { return @{ missing = $true } }
    if ($r.status -lt 200 -or $r.status -ge 300) { [void](Invoke-Gh -Path "$repo/git/ref/$path") }   # the usual refusal (rate limit, forbidden, error)
    $sha = "$($r.body.object.sha)"
    if ($sha -notmatch '^[0-9a-f]{7,64}$') { Reject 20 'github-error' 'the leader ref names no commit' @{ retryAfterSeconds = 15 } }
    $c = Invoke-Gh -Path "$repo/git/commits/$sha"
    $rec = $null; try { $rec = "$($c.message)" | ConvertFrom-Json -AsHashtable -DateKind String } catch { }
    if ($rec -isnot [System.Collections.IDictionary] -or -not $rec.Contains('kind') -or "$($rec['kind'])" -ne 'gateway-leader' -or -not $rec.Contains('epoch') -or -not $rec.Contains('holder')) { $rec = $null }
    return @{ sha = $sha; tree = "$($c.tree.sha)"; record = $rec; etag = "$(Get-LeaderHeader $r.headers 'etag')" }
}
function Get-LeaderHeader($Headers, [string]$Name) { if ($Headers) { foreach ($k in @($Headers.Keys)) { if ("$k" -ieq $Name) { return "$(@($Headers[$k])[0])" } } }; return '' }

# Writes a record as a new commit on top of $Parent ('' for a ref that does not exist yet). @{ ok; sha } or @{ ok = $false; conflict = $true }.
function Write-LeaderLease($Record, [string]$Parent, [string]$Tree) {
    $repo = Get-RepoPath; $path = Get-LeaderRefPath
    if (-not $Tree) { $head = (Invoke-Gh -Path "$repo/git/ref/heads/$((Get-Cfg).defaultBranch)").object.sha; $Tree = "$((Invoke-Gh -Path "$repo/git/commits/$head").tree.sha)" }
    $msg = $Record | ConvertTo-Json -Depth 6 -Compress
    $commit = (Invoke-Gh -Method POST -Path "$repo/git/commits" -Body @{ message = $msg; tree = $Tree; parents = @(if ($Parent) { $Parent }) }).sha
    if ($Parent) {
        # no force: GitHub moves the ref only when the new commit descends from the one it points at now (the compare-and-swap)
        $u = Invoke-Gh -Method PATCH -Path "$repo/git/refs/$path" -Body @{ sha = $commit; force = $false } -Allow 409, 422
        if ($u -is [hashtable] -and $u.ContainsKey('status')) { return @{ ok = $false; conflict = $true; detail = "$($u.body.message)"; tree = $Tree } }
    } else {
        $n = Invoke-Gh -Method POST -Path "$repo/git/refs" -Body @{ ref = "refs/$path"; sha = $commit } -Allow 422
        if ($n -is [hashtable] -and $n.ContainsKey('status')) { return @{ ok = $false; conflict = $true; detail = "$($n.body.message)"; tree = $Tree } }
    }
    return @{ ok = $true; sha = $commit; tree = $Tree }
}

function Get-LeaderSummary($Rec) {
    if (-not $Rec) { return $null }
    $o = @{}; foreach ($k in 'epoch', 'holder', 'version', 'revision', 'replica', 'acquired_at', 'renewed_at', 'until', 'released', 'released_at', 'plant_epoch') { if ($Rec.Contains($k)) { $o[$k] = $Rec[$k] } }
    return $o
}

function Verb_leader_lease($a) {
    $action = "$(Need $a 'action')"; $holder = "$(Need $a 'holder')"
    $info = @{}; foreach ($k in 'version', 'revision', 'replica') { $info[$k] = if (Test-Has $a $k) { "$($a[$k])" } else { '' } }
    if ($holder -notmatch '^[A-Za-z0-9._:-]{1,100}$') { Reject 2 'usage' 'holder: letters, digits, . _ : - (100 at most)' }
    $ttl = if (Test-Has $a 'ttl_seconds') { [Math]::Clamp([double]$a.ttl_seconds, 10, 86400) } else { 360 }
    $tree = if (Test-Has $a 'tree') { "$($a.tree)" } else { '' }
    $now = Get-UtcNow; $nowIso = ConvertTo-Iso $now
    $mine = if (Test-Has $a 'epoch') { [long]$a.epoch } else { 0 }
    switch ($action) {
        'acquire' {
            for ($try = 1; $try -le 5; $try++) {
                $cur = Read-LeaderLease
                $prev = if ($cur.ContainsKey('record')) { $cur.record } else { $null }
                $epoch = $(if ($prev) { [long]$prev.epoch } else { 0 }) + 1
                $rec = [ordered]@{ v = 1; kind = 'gateway-leader'; epoch = $epoch; holder = $holder; version = $info.version; revision = $info.revision; replica = $info.replica
                    acquired_at = $nowIso; renewed_at = $nowIso; until = ConvertTo-Iso ($now.AddSeconds($ttl)); released = $false; predecessor = (Get-LeaderSummary $prev) }
                $w = Write-LeaderLease $rec $(if ($cur.ContainsKey('sha')) { $cur.sha } else { '' }) $(if ($tree) { $tree } elseif ($cur.ContainsKey('tree')) { $cur.tree } else { '' })
                if ($w.ok) { return @{ ok = $true; leader = $true; epoch = $epoch; sha = $w.sha; tree = $w.tree; until = $rec.until; predecessor = (Get-LeaderSummary $prev); attempts = $try } }
                Start-Sleep -Milliseconds (200 * $try)
            }
            Reject 20 'lease-contended' 'the leader lease changed on every attempt' @{ retryAfterSeconds = 5 }
        }
        { $_ -in 'renew', 'release' } {
            for ($try = 1; $try -le 3; $try++) {
                $cur = Read-LeaderLease
                $rec = if ($cur.ContainsKey('record')) { $cur.record } else { $null }
                if ($cur.ContainsKey('missing')) {
                    # someone removed the ref: the holder writes its own record again (a process that took a later epoch would have written the ref)
                    if ($action -eq 'release') { return @{ ok = $true; leader = $false; current = $null; missing = $true } }
                    $rec = [ordered]@{ v = 1; kind = 'gateway-leader'; epoch = $mine; holder = $holder; version = $info.version; revision = $info.revision; replica = $info.replica; acquired_at = $nowIso; renewed_at = $nowIso; released = $false }
                    $parent = ''
                } elseif (-not $rec -or [long]$rec.epoch -ne $mine -or "$($rec.holder)" -ne $holder -or ($rec.Contains('released') -and $rec.released -eq $true)) {
                    return @{ ok = $true; leader = $false; current = (Get-LeaderSummary $rec); sha = $cur.sha; etag = $cur.etag }
                } else { $parent = $cur.sha }
                if ($action -eq 'renew') { $rec.renewed_at = $nowIso; $rec.until = ConvertTo-Iso ($now.AddSeconds($ttl)) }
                else { $rec.released = $true; $rec.released_at = $nowIso; $rec.until = $nowIso; if (Test-Has $a 'plant_epoch') { $rec.plant_epoch = [long]$a.plant_epoch } }
                $w = Write-LeaderLease $rec $parent $(if ($tree) { $tree } elseif ($cur.ContainsKey('tree')) { $cur.tree } else { '' })
                if ($w.ok) { return @{ ok = $true; leader = ($action -eq 'renew'); epoch = $mine; sha = $w.sha; tree = $w.tree; until = $rec.until; released = ($action -eq 'release') } }
                Start-Sleep -Milliseconds (200 * $try)
            }
            Reject 20 'lease-contended' 'the leader lease changed on every attempt' @{ retryAfterSeconds = 5 }
        }
        'check' {
            $etag = if (Test-Has $a 'etag') { "$($a.etag)" } else { '' }
            $cur = Read-LeaderLease $etag
            if ($cur.ContainsKey('unchanged')) { return @{ ok = $true; leader = $true; unchanged = $true; etag = $etag } }
            if ($cur.ContainsKey('missing')) { return @{ ok = $true; leader = $false; missing = $true; current = $null } }
            if ((Test-Has $a 'sha') -and "$($a.sha)" -eq $cur.sha) { return @{ ok = $true; leader = $true; unchanged = $true; etag = $cur.etag; sha = $cur.sha } }
            $rec = $cur.record
            $is = $rec -and [long]$rec.epoch -eq $mine -and "$($rec.holder)" -eq $holder -and -not ($rec.Contains('released') -and $rec.released -eq $true)
            return @{ ok = $true; leader = [bool]$is; current = (Get-LeaderSummary $rec); sha = $cur.sha; etag = $cur.etag }
        }
        default { Reject 2 'usage' 'action is acquire, renew, check or release' }
    }
}
