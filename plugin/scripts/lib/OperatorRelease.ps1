# Server side of the operator session's release record (gateway/Operator.cs). A self-merged release restarts the gateway, and the gateway keeps
# nothing on its own disk, so the releases of a day live in GitHub as refs beside the claim and revocation refs:
# refs/factory/<instance>/operator-release/<yyyyMMdd>/<pull request>/<version>. Admin verbs, called by the gateway only
# (POST /api/v1/operator/record-release and its read at start).
function Get-OperatorReleaseRefPath { "factory/$((Get-Cfg).name)/operator-release" }

# operator-releases: the releases recorded for one UTC day, one per pull request.
function Verb_operator_releases($a) {
    $day = "$(Need $a 'day')"
    if ($day -notmatch '^\d{8}$') { Reject 2 'usage' 'day is yyyyMMdd' }
    $out = @(); $seen = @{}; $prefix = "refs/$(Get-OperatorReleaseRefPath)/$day/"
    for ($page = 1; $page -le 10; $page++) {
        $rows = @(Invoke-Gh -Path "$(Get-RepoPath)/git/matching-refs/$(Get-OperatorReleaseRefPath)/$day/?per_page=100&page=$page")
        foreach ($r in $rows) {
            if ("$($r.ref)".StartsWith($prefix, [StringComparison]::Ordinal) -and "$($r.ref)".Substring($prefix.Length) -match '^(\d{1,9})/(\d{1,6}(\.\d{1,9}){1,3})$') {
                $pr = [int]$Matches[1]
                if (-not $seen.ContainsKey($pr)) { $seen[$pr] = $true; $out += @{ pr = $pr; version = $Matches[2] } }
            }
        }
        if ($rows.Count -lt 100) { break }
    }
    return @{ ok = $true; day = $day; releases = @($out) }
}

# operator-release: records one self-merged release (idempotent).
function Verb_operator_release($a) {
    $day = "$(Need $a 'day')"; $pr = [int](Need $a 'pr'); $version = "$(Need $a 'version')"
    if ($day -notmatch '^\d{8}$' -or $pr -lt 1 -or $version -notmatch '^\d{1,6}(\.\d{1,9}){1,3}$') { Reject 2 'usage' 'day is yyyyMMdd, pr a pull request number and version digits and dots' }
    $c = Get-Cfg
    $head = (Invoke-Gh -Path "$(Get-RepoPath)/git/ref/heads/$($c.defaultBranch)").object.sha
    $r = Invoke-Gh -Method POST -Path "$(Get-RepoPath)/git/refs" -Body @{ ref = "refs/$(Get-OperatorReleaseRefPath)/$day/$pr/$version"; sha = $head } -Allow 422
    if ($r -is [hashtable] -and $r.ContainsKey('status') -and $r.status -eq 422 -and "$($r.body.message)" -notmatch '(?i)already exists') { Reject 20 'github-error' 'GitHub refused the release ref' @{ detail = "$($r.body.message)"; retryAfterSeconds = 30 } }
    return @{ ok = $true; day = $day; pr = $pr; version = $version }
}
