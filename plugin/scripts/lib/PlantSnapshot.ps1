# Server side of the plant snapshot (gateway/PlantSnapshot.cs, enhancement 5). The plant (offers, assignments, owners, leases) lives in the gateway's
# memory and the gateway keeps nothing on its own disk, so on SIGTERM it writes the plant to GitHub and reads it back at the next start. The snapshot
# is the message of one commit without a parent (the tree is master's, so nothing new is stored but the message), held by the single ref
# refs/factory/<instance>/plant-snapshot. Commits, trees and refs are what GitHub really stores for any repository; a ref that pointed at a blob
# would rest on a behaviour the API does not document. Admin verbs, called by the gateway only (its stop and its start), never through the verb route.
function Get-PlantSnapshotRefPath { "factory/$((Get-Cfg).name)/plant-snapshot" }

# plant-snapshot-save: { snapshot: <object>, tree, guard_epoch } -> the ref points at a new commit whose message is the snapshot's JSON.
# tree: the tree of an earlier save (the gateway keeps it: two reads fewer per save). guard_epoch (issue 94): a superseded gateway's final snapshot
# is not written over the snapshot of a later epoch (exit 11 snapshot-newer).
function Verb_plant_snapshot_save($a) {
    if (-not (Test-Has $a 'snapshot') -or $a.snapshot -isnot [System.Collections.IDictionary]) { Reject 2 'usage' 'snapshot is an object' }
    $json = $a.snapshot | ConvertTo-Json -Depth 12 -Compress
    if ($json.Length -gt 900000) { Reject 2 'too-large' "the snapshot is $($json.Length) characters; at most 900000" }
    $c = Get-Cfg; $repo = Get-RepoPath
    if (Test-Has $a 'guard_epoch') {
        $cur = Verb_plant_snapshot_load @{}
        if ($cur.found -and $cur.snapshot -is [System.Collections.IDictionary] -and $cur.snapshot.Contains('epoch') -and [long]$cur.snapshot.epoch -gt [long]$a.guard_epoch) {
            Reject 11 'snapshot-newer' "the snapshot ref holds epoch $($cur.snapshot.epoch), later than $($a.guard_epoch)"
        }
    }
    $tree = if ((Test-Has $a 'tree') -and "$($a.tree)" -match '^[0-9a-f]{7,64}$') { "$($a.tree)" } else {
        $head = (Invoke-Gh -Path "$repo/git/ref/heads/$($c.defaultBranch)").object.sha
        (Invoke-Gh -Path "$repo/git/commits/$head").tree.sha
    }
    $commit = (Invoke-Gh -Method POST -Path "$repo/git/commits" -Body @{ message = $json; tree = $tree; parents = @() }).sha
    $path = Get-PlantSnapshotRefPath
    $r = Invoke-Gh -Method PATCH -Path "$repo/git/refs/$path" -Body @{ sha = $commit; force = $true } -Allow 404, 422
    if ($r -is [hashtable] -and $r.ContainsKey('status')) {
        # no ref yet (GitHub answers 422 "Reference does not exist" to an update of a missing ref): create it
        $n = Invoke-Gh -Method POST -Path "$repo/git/refs" -Body @{ ref = "refs/$path"; sha = $commit } -Allow 422
        if ($n -is [hashtable] -and $n.ContainsKey('status')) { Reject 20 'github-error' 'GitHub refused the plant snapshot ref' @{ detail = "$($n.body.message)"; retryAfterSeconds = 30 } }
    }
    return @{ ok = $true; ref = "refs/$path"; commit = $commit; length = $json.Length; tree = $tree }
}

# plant-snapshot-load: the snapshot the ref holds, or found false when there is none. A message that is not JSON is found true with snapshot null.
function Verb_plant_snapshot_load($a) {
    $repo = Get-RepoPath; $path = Get-PlantSnapshotRefPath
    $r = Invoke-Gh -Path "$repo/git/ref/$path" -Allow 404
    if ($r -is [hashtable] -and $r.ContainsKey('status')) { return @{ ok = $true; found = $false } }
    $sha = "$($r.object.sha)"
    if ($sha -notmatch '^[0-9a-f]{7,64}$') { return @{ ok = $true; found = $false } }
    $msg = "$((Invoke-Gh -Path "$repo/git/commits/$sha").message)"
    $snap = $null; try { $snap = $msg | ConvertFrom-Json -AsHashtable -DateKind String } catch { }
    return @{ ok = $true; found = $true; commit = $sha; snapshot = $snap }
}

# plant-snapshot-await: { epoch, wait_seconds, until } (issue 94). A starting gateway that superseded a live one waits for that one's final snapshot
# (epoch = the predecessor's, final true) for at most wait_seconds, reading the ref conditionally every 3 s (an unchanged ref answers 304). It
# stops early once until (the predecessor's lease) has passed by 10 s: that process is gone and writes nothing more. Answers the final snapshot,
# else the latest one of that epoch (final false), else found false.
function Verb_plant_snapshot_await($a) {
    $epoch = [long](Need $a 'epoch')
    $wait = if (Test-Has $a 'wait_seconds') { [Math]::Clamp([double]$a.wait_seconds, 0, 600) } else { 90 }
    $until = if (Test-Has $a 'until') { ConvertFrom-Iso $a.until } else { $null }
    $repo = Get-RepoPath; $path = Get-PlantSnapshotRefPath
    $start = Get-UtcNow; $deadline = $start.AddSeconds($wait); $etag = ''; $lastSha = ''; $latest = $null; $reads = 0
    while ($true) {
        $hdr = @{}; if ($etag) { $hdr['If-None-Match'] = $etag }
        $r = Invoke-GhRaw -Path "$repo/git/ref/$path" -Headers $hdr; $reads++
        if ($r.status -ge 200 -and $r.status -lt 300) {
            $etag = Get-LeaderHeader $r.headers 'etag'
            $sha = "$($r.body.object.sha)"
            if ($sha -match '^[0-9a-f]{7,64}$' -and $sha -ne $lastSha) {
                $lastSha = $sha
                $snap = $null; try { $snap = "$((Invoke-Gh -Path "$repo/git/commits/$sha").message)" | ConvertFrom-Json -AsHashtable -DateKind String } catch { }
                if ($snap -is [System.Collections.IDictionary] -and $snap.Contains('epoch') -and [long]$snap.epoch -eq $epoch) {
                    $latest = $snap
                    if ($snap.Contains('final') -and $snap.final -eq $true) { return @{ ok = $true; found = $true; final = $true; snapshot = $snap; waitedSeconds = [int]((Get-UtcNow) - $start).TotalSeconds; reads = $reads } }
                }
            }
        }
        $now = Get-UtcNow
        if ($now -ge $deadline -or ($until -and $now -gt $until.AddSeconds(10))) { break }
        Start-Sleep -Seconds 3
    }
    return @{ ok = $true; found = ($null -ne $latest); final = $false; snapshot = $latest; waitedSeconds = [int]((Get-UtcNow) - $start).TotalSeconds; reads = $reads }
}

# plant-snapshot-clear: removes the ref once the start has read it (a snapshot is restored once). No ref is no error.
function Verb_plant_snapshot_clear($a) {
    $r = Invoke-Gh -Method DELETE -Path "$(Get-RepoPath)/git/refs/$(Get-PlantSnapshotRefPath)" -Allow 404, 422
    return @{ ok = $true; removed = -not ($r -is [hashtable] -and $r.ContainsKey('status')) }
}
