# The GitHub identities other than the gateway's own token: the reviewer App (the factory inspector's approvals) and the test-person App.
# Server side only. A private key is read from the keyring by secret-tool, used to sign a short-lived JWT, and never printed or logged.
# In Tier 1 tests (FACTORY_FAKE_APPS=1) no key exists: the token is the literal 'fake-<kind>', which the fake GitHub maps to the App's bot login.

function Get-AppInfo([string]$Kind) {
    $f = Get-FwConfigPath "apps/$Kind.json"
    if ($env:FACTORY_FAKE_APPS) { return @{ kind = $Kind; id = 0; slug = "factory-worker-$Kind"; installation_id = 0 } }
    # A container has no home directory config: the App's ids come from FACTORY_APP_<KIND>_ID / _INSTALLATION / _SLUG (settings, not secrets).
    $envKind = $Kind.ToUpperInvariant()
    $envId = [Environment]::GetEnvironmentVariable("FACTORY_APP_${envKind}_ID")
    if ($envId) { return @{ kind = $Kind; id = $envId; installation_id = [Environment]::GetEnvironmentVariable("FACTORY_APP_${envKind}_INSTALLATION"); slug = [Environment]::GetEnvironmentVariable("FACTORY_APP_${envKind}_SLUG") } }
    if (-not $f -or -not (Test-Path $f)) { Reject 30 'app-not-configured' "the '$Kind' GitHub App is not set up on this gateway" }
    return Get-Content -Raw $f | ConvertFrom-Json -AsHashtable
}

function Get-AppLogin([string]$Kind) { "$((Get-AppInfo $Kind).slug)[bot]" }

function New-AppJwt([string]$Pem, $AppId) {
    $b64 = { param($bytes) [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $head = & $b64 ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $pay = & $b64 ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create(); $rsa.ImportFromPem($Pem)
    $sig = & $b64 ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$head.$pay"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    return "$head.$pay.$sig"
}

# A 1-hour installation token for the App, minted per request. The key stays inside this function.
function Get-AppToken([string]$Kind) {
    if ($env:FACTORY_FAKE_APPS) { return "fake-$Kind" }
    $info = Get-AppInfo $Kind
    if (-not $info.installation_id) { Reject 30 'app-not-installed' "the '$Kind' GitHub App has no installation recorded" }
    # A short-lived installation token is cached on disk (mode 0600) until five minutes before it expires: every verb is a new process.
    $cacheDir = Get-FwSubDir 'state' $env:FACTORY_STATE_DIR
    $cache = Join-Path $cacheDir "app-token-$Kind.json"
    if (Test-Path -LiteralPath $cache) {
        try { $c = Get-Content -Raw -LiteralPath $cache | ConvertFrom-Json -AsHashtable -DateKind String; if ($c.token -and [DateTimeOffset]::Parse($c.expires) -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $c.token } } catch { }
    }
    $envKey = [Environment]::GetEnvironmentVariable("FACTORY_APP_$($Kind.ToUpperInvariant())_KEY")
    $pem = if ($envKey) { $envKey } else { (& secret-tool lookup service factory-worker kind github-app-private-key app $Kind 2>$null) -join "`n" }
    if ($pem -and $pem.Trim() -eq 'unset') { $pem = $null }   # the vault placeholder written before a key exists
    if (-not $pem) { Reject 30 'secret-missing' "no private key for the '$Kind' GitHub App (FACTORY_APP_$($Kind.ToUpperInvariant())_KEY or the keyring)" }
    $base = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
    $r = Invoke-RestMethod -Method POST -Uri "$base/app/installations/$($info.installation_id)/access_tokens" -SkipHttpErrorCheck -StatusCodeVariable sc `
        -Headers @{ Authorization = "Bearer $(New-AppJwt $pem $info.id)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'factory-worker-gateway' }
    $pem = $null
    if ($sc -ne 201) { Reject 20 'app-token-failed' "GitHub answered $sc when minting the '$Kind' App token" @{ retryAfterSeconds = 30 } }
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Set-Content -LiteralPath $cache -Value (@{ token = $r.token; expires = "$($r.expires_at)" } | ConvertTo-Json -Compress)
        if ($IsLinux -or $IsMacOS) { chmod 600 $cache }
    } catch { }
    return $r.token
}

# Run a block with GitHub calls made as an App. Nothing leaks past the block.
function Use-GhAs([string]$Kind, [scriptblock]$Body) {
    $script:AsToken = Get-AppToken $Kind
    try { & $Body } finally { $script:AsToken = $null }
}

# git-credential (docs/design/cloud-worker-runtimes.md 2.6): a GitHub installation token of the author App for the item of a runtime worker, scoped by
# GitHub itself to the work-orders repository with contents write and nothing else, valid one hour. The gateway admits the verb only for an item
# token of role owner minted for a runtime worker (Auth.GitCredentialVerbs); the git credential helper of the runner image calls it again when the
# token nears its expiry. The App key never leaves this process; the token is minted per call and never cached on disk (the cache of Get-AppToken
# holds the App's own, unscoped token). In Tier 1 (FACTORY_FAKE_APPS) no key exists: the request goes to the fake with a JWT-shaped placeholder.
function Verb_git_credential($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg
    $info = Get-AppInfo 'author'
    $base = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
    if ($env:FACTORY_FAKE_APPS) { $jwt = 'eyJhbGciOiJSUzI1NiJ9.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"iss":"0"}')).TrimEnd('=') + '.fake'; $inst = 0 }
    else {
        if (-not $info.installation_id) { Reject 30 'app-not-installed' "the 'author' GitHub App has no installation recorded" }
        $pem = [Environment]::GetEnvironmentVariable('FACTORY_APP_AUTHOR_KEY')
        if (-not $pem) { $pem = (& secret-tool lookup service factory-worker kind github-app-private-key app author 2>$null) -join "`n" }
        if ($pem -and $pem.Trim() -eq 'unset') { $pem = $null }
        if (-not $pem) { Reject 30 'secret-missing' 'no private key for the author GitHub App' }
        $jwt = New-AppJwt $pem $info.id; $pem = $null; $inst = $info.installation_id
    }
    $req = @{ repositories = @("$($c.repo)"); permissions = @{ contents = 'write' } } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method POST -Uri "$base/app/installations/$inst/access_tokens" -Body $req -ContentType 'application/json' -SkipHttpErrorCheck -StatusCodeVariable sc `
        -Headers @{ Authorization = "Bearer $jwt"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'factory-worker-gateway' }
    $jwt = $null
    if ($sc -ne 201) { Reject 20 'app-token-failed' "GitHub answered $sc when minting the item's git credential" @{ retryAfterSeconds = 30 } }
    # GitHub answers the scope it granted (every App token also carries metadata: read): a token wider than asked for is revoked, not handed out
    $prop = { param($o, $k) if ($o -and $o.PSObject.Properties[$k]) { $o.$k } else { $null } }
    $perms = & $prop $r 'permissions'
    $repos = @(& $prop $r 'repositories' | Where-Object { $_ } | ForEach-Object { @{ name = "$(& $prop $_ 'name')"; full = "$(& $prop $_ 'full_name')" } })
    $grant = @{}; if ($perms) { foreach ($pp in $perms.PSObject.Properties) { $grant[$pp.Name] = "$($pp.Value)" } }
    $okPerms = $grant['contents'] -eq 'write' -and @($grant.Keys | Where-Object { -not (($_ -eq 'contents') -or ($_ -eq 'metadata' -and $grant[$_] -eq 'read')) }).Count -eq 0
    $okRepo = $repos.Count -eq 1 -and $repos[0].name -eq "$($c.repo)" -and ($repos[0].full -eq '' -or $repos[0].full -eq "$($c.owner)/$($c.repo)")
    if (-not ($okPerms -and $okRepo)) {
        try { [void](Invoke-RestMethod -Method DELETE -Uri "$base/installation/token" -SkipHttpErrorCheck -Headers @{ Authorization = "Bearer $($r.token)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'factory-worker-gateway' }) } catch { }
        Reject 20 'git-credential-scope' 'GitHub granted a different scope than asked for (one repository, contents write); the token was revoked and nothing is handed out'
    }
    return @{ ok = $true; item = $n; token = "$($r.token)"; expires_at = "$($r.expires_at)"; repository = "$($c.owner)/$($c.repo)"; permissions = @{ contents = 'write' }; username = 'x-access-token' }
}
