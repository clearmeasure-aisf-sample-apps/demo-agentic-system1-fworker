#!/usr/bin/env pwsh
#Requires -Version 7.4
<#
.SYNOPSIS
    A one-page web app that creates the factory-worker test GitHub Apps with a button each.

.DESCRIPTION
    GitHub has no API to create or install an App: an owner of the organization presses "Create GitHub App" and "Install" in a signed-in
    browser (the "manifest flow"). This page makes that two clicks per App and does the rest:
      - serves one page on THIS machine's Tailscale address only, answering only the allowed Tailscale login (anyone else: 403), and every
        path starts with a token made for this run (without it: 404);
      - "Create" posts the App's manifest to GitHub; GitHub sends the browser back with a one-time code; the page exchanges the code for the
        App id and private key, and stores the key in the keyring (secret-tool) without ever showing, logging or passing it as an argument;
      - "Check install" asks GitHub, as the App, which installation it has and records the installation id.
    Non-secret facts (id, slug, client id, installation id) go to ~/.config/factory-worker/apps/<kind>.json.

    Kinds (least permission each):
      reviewer     the factory inspector's identity: reviews pull requests            (pull requests write, contents read, checks read)
      author       the cloud gateways' own identity: contents, pull requests, issues write; the organization's projects write
      testperson   a simulated human, test configuration only: approves, clears holds  (pull requests write, issues write)

.EXAMPLE
    pwsh tools/github-app-setup/serve.ps1                 # prints the address to open
#>
param(
    [string] $Organization = 'clearmeasure-aisf-sample-apps',
    [string] $Repository = 'demo-agentic-system1-workorders',
    [string] $AllowedLogin,
    [int] $Port = 5390,
    [double] $WaitHours = 2
)
$ErrorActionPreference = 'Stop'

$kinds = [ordered]@{
    reviewer   = @{ name = 'factory-worker-reviewer';   title = 'Reviewer (factory inspector)'; permissions = @{ pull_requests = 'write'; contents = 'read'; checks = 'read'; metadata = 'read' } }
    author     = @{ name = 'factory-worker-author';     title = 'Author (cloud gateways: opens and merges pull requests, moves the board)'; permissions = @{ contents = 'write'; pull_requests = 'write'; issues = 'write'; checks = 'read'; actions = 'read'; statuses = 'read'; metadata = 'read'; organization_projects = 'write' } }
    testperson = @{ name = 'factory-worker-testperson'; title = 'Test person (simulated human)'; permissions = @{ pull_requests = 'write'; issues = 'write'; metadata = 'read' } }
}
$stateDir = Join-Path $HOME '.config/factory-worker/apps'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# ---- tailnet ------------------------------------------------------------------------------------------------------
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) { throw 'tailscale is not on PATH: the page is served on this machine''s Tailscale address only.' }
$ts = tailscale status --json | ConvertFrom-Json
$myIp = @($ts.Self.TailscaleIPs | Where-Object { $_ -notmatch ':' })[0]
$myName = ("$($ts.Self.DNSName)").TrimEnd('.')
if (-not $myIp) { throw 'Tailscale is not running or has no IPv4 address.' }
if (-not $AllowedLogin) { $AllowedLogin = $ts.User."$($ts.Self.UserID)".LoginName }
function Test-Client([string] $remote) {
    try { $w = tailscale whois --json $remote | ConvertFrom-Json; return ($w.UserProfile.LoginName -ieq $AllowedLogin) } catch { return $false }
}

$gh = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'factory-worker-app-setup' }
$orgId = (Invoke-RestMethod -Uri "https://api.github.com/orgs/$Organization" -Headers $gh).id
$repoId = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Organization/$Repository" -Headers $gh).id
$token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$base = "http://${myName}:$Port/$token"
$states = @{}   # state -> kind, for the callback

# ---- helpers ------------------------------------------------------------------------------------------------------
function Save-Key([string] $kind, [string] $pem) {
    $psi = [Diagnostics.ProcessStartInfo]::new('secret-tool')
    foreach ($a in 'store', "--label=factory-worker $kind GitHub App private key", 'service', 'factory-worker', 'kind', 'github-app-private-key', 'app', $kind) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Write($pem); $p.StandardInput.Close(); $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "secret-tool could not store the key (exit $($p.ExitCode))." }
}
function Get-Key([string] $kind) {
    $r = & secret-tool lookup service factory-worker kind github-app-private-key app $kind 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $r) { return $null }; return ($r -join "`n")
}
function Get-Info([string] $kind) { $f = Join-Path $stateDir "$kind.json"; if (Test-Path $f) { Get-Content -Raw $f | ConvertFrom-Json -AsHashtable } else { $null } }
function Set-Info([string] $kind, [hashtable] $info) { $info | ConvertTo-Json | Set-Content (Join-Path $stateDir "$kind.json") }
function New-Jwt([string] $pem, [string] $appId) {
    $b64 = { param($bytes) [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $head = & $b64 ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $pay = & $b64 ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = $appId } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create(); $rsa.ImportFromPem($pem)
    $sig = & $b64 ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$head.$pay"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    return "$head.$pay.$sig"
}
function Get-InstallUrl($info) { "https://github.com/apps/$($info.slug)/installations/new/permissions?target_id=$orgId&repository_ids[]=$repoId" }
function Get-SettingsUrl($info) { "https://github.com/organizations/$Organization/settings/installations/$($info.installation_id)" }
function Invoke-Check([string] $k) {
    # Asks GitHub, as the App, about its installation. Returns @{ ok; html }.
    $info = Get-Info $k; $pem = Get-Key $k
    if (-not $info -or -not $pem) { return @{ ok = $false; html = (Html '<p>No such App or no key.</p>') } }
    $jwt = New-Jwt $pem $info.id
    $inst = Invoke-RestMethod -Uri 'https://api.github.com/app/installations' -Headers ($gh + @{ Authorization = "Bearer $jwt" })
    $mine = @($inst | Where-Object { $_.account.login -eq $Organization })
    if ($mine.Count -eq 0) { return @{ ok = $false; html = (Html "<h2>Not installed yet</h2><p class=no>The App is not installed on <code>$Organization</code>.</p><p><a class=b href='$base/install/$k'>Install it (only $Repository preselected)</a> <a class='b s' href='$base/check/$k'>Check again</a></p>") } }
    $tok = Invoke-RestMethod -Method POST -Uri "https://api.github.com/app/installations/$($mine[0].id)/access_tokens" -Headers ($gh + @{ Authorization = "Bearer $jwt" })
    $repos = Invoke-RestMethod -Uri 'https://api.github.com/installation/repositories?per_page=100' -Headers ($gh + @{ Authorization = "Bearer $($tok.token)" })
    $names = @($repos.repositories | ForEach-Object { $_.name })
    $info.installation_id = $mine[0].id; $info.repository_selection = $mine[0].repository_selection; $info.repository_count = $repos.total_count
    $info.repositories = $names | Select-Object -First 5; $info.permissions = $tok.permissions
    Set-Info $k $info
    $good = ($mine[0].repository_selection -eq 'selected' -and $repos.total_count -eq 1 -and $names[0] -eq $Repository)
    Write-Host "checked $($info.slug): installation $($mine[0].id), selection $($mine[0].repository_selection), $($repos.total_count) repositories"
    if ($good) { return @{ ok = $true; html = (Html "<h2>$($kinds[$k].title)</h2><p class=ok>Installed on only <code>$Repository</code> (installation $($mine[0].id)). Done.</p><p><a class=b href='$base/'>Back</a></p>") } }
    $why = if ($mine[0].repository_selection -eq 'all') { "it is installed on <b>all repositories</b> of the organization ($($repos.total_count))" } else { "it can reach $($repos.total_count) repositories" }
    return @{ ok = $false; html = (Html "<h2>$($kinds[$k].title)</h2><p class=no>This App should reach only <code>$Repository</code>, but $why.</p><ol><li>Click the button: GitHub opens this installation's settings.</li><li>Under <b>Repository access</b> choose <b>Only select repositories</b>, pick <code>$Repository</code>, and <b>Save</b>.</li><li>Come back and press <b>Check again</b>.</li></ol><p><a class=b href='$base/go/$k' target=_blank>Restrict to $Repository (opens GitHub)</a> <a class='b s' href='$base/check/$k'>Check again</a></p>") }
}
function Html([string] $inner) {
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>factory-worker GitHub Apps</title>" +
    "<style>body{font:16px system-ui;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5}.card{border:1px solid #8884;border-radius:8px;padding:1rem;margin:1rem 0}" +
    "button,a.b{font:inherit;padding:.5rem 1rem;border-radius:6px;border:1px solid #888;background:#2da44e;color:#fff;text-decoration:none;cursor:pointer;display:inline-block}a.b.s{background:#666}.ok{color:#1a7f37}.no{color:#b35900}code{background:#8882;padding:0 .3rem;border-radius:4px}</style>$inner"
}
function Get-Home {
    $h = "<h1>factory-worker GitHub Apps</h1><p>Organization <code>$Organization</code>, repository <code>$Repository</code>. You need to be an owner of the organization and signed in to GitHub.</p>"
    foreach ($k in $kinds.Keys) {
        $info = Get-Info $k
        $perm = ($kinds[$k].permissions.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '
        $h += "<div class=card><h2>$($kinds[$k].title)</h2><p>Permissions: <code>$perm</code>. No webhook, no events.</p>"
        if (-not $info) { $h += "<p class=no>Not created.</p><a class=b href='$base/start/$k'>Create the App</a>" }
        elseif (-not $info.installation_id) { $h += "<p class=no>Created (app $($info.id)); not installed yet.</p><a class=b href='$base/install/$k'>Install on $Repository only</a> <a class='b s' href='$base/check/$k'>Check</a>" }
        elseif ($info.repository_selection -eq 'selected' -and $info.repository_count -eq 1) { $h += "<p class=ok>Installed on only $Repository (installation $($info.installation_id)).</p><a class='b s' href='$base/check/$k'>Check again</a>" }
        else { $h += "<p class=no>Installed, but on more than $Repository (selection: $($info.repository_selection)). Narrow it.</p><a class=b href='$base/check/$k'>Show what to do</a>" }
        $h += "</div>"
    }
    return Html $h
}

# ---- server -------------------------------------------------------------------------------------------------------
$listener = [Net.HttpListener]::new(); $listener.Prefixes.Add("http://${myIp}:$Port/"); $listener.Prefixes.Add("http://${myName}:$Port/"); $listener.Start()
Write-Host "Open this on a device of $AllowedLogin (on the tailnet):"
Write-Host "  $base/"
Write-Host "Waiting up to $WaitHours h. Press Ctrl+C to stop."
$deadline = (Get-Date).AddHours($WaitHours)
function Send($ctx, [int] $code, [string] $html, [string] $redirect) {
    $ctx.Response.StatusCode = $code
    if ($redirect) { $ctx.Response.Headers['Location'] = $redirect }
    if ($html) { $bytes = [Text.Encoding]::UTF8.GetBytes($html); $ctx.Response.ContentType = 'text/html; charset=utf-8'; $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $ctx.Response.Close()
}
while ((Get-Date) -lt $deadline) {
    $task = $listener.GetContextAsync()
    while (-not $task.Wait(1000)) { if ((Get-Date) -gt $deadline) { break } }
    if (-not $task.IsCompleted) { break }
    $ctx = $task.Result
    try {
        $remote = $ctx.Request.RemoteEndPoint.Address.ToString()
        if (-not (Test-Client $remote)) { Write-Host "refused $remote"; Send $ctx 403 $null $null; continue }
        $path = $ctx.Request.Url.AbsolutePath
        if (-not $path.StartsWith("/$token/") -and $path -ne "/$token") { Send $ctx 404 $null $null; continue }
        $rest = $path.Substring($token.Length + 1).Trim('/')
        switch -Regex ($rest) {
            '^$' { Send $ctx 200 (Get-Home) $null }
            '^start/(\w+)$' {
                $k = $Matches[1]; if (-not $kinds.Contains($k)) { Send $ctx 404 $null $null; break }
                $state = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(12)).ToLowerInvariant(); $states[$state] = $k
                $manifest = [ordered]@{
                    name = $kinds[$k].name; url = "https://github.com/$Organization/$Repository"; public = $false
                    redirect_url = "$base/callback"; setup_url = "$base/after-install/$k"; setup_on_update = $true; hook_attributes = @{ url = 'https://example.invalid/unused'; active = $false }
                    default_events = @(); default_permissions = $kinds[$k].permissions
                } | ConvertTo-Json -Depth 5 -Compress
                $form = "<form id=f method=post action='https://github.com/organizations/$Organization/settings/apps/new?state=$state'><input type=hidden name=manifest value='$([Net.WebUtility]::HtmlEncode($manifest))'><noscript><button>Continue to GitHub</button></noscript></form><p>Sending you to GitHub...</p><script>document.getElementById('f').submit()</script>"
                Send $ctx 200 (Html $form) $null
            }
            '^callback$' {
                $q = [Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query); $k = $states[$q['state']]
                if (-not $k -or -not $q['code']) { Send $ctx 400 (Html '<p>Unknown or missing state. Start again from the home page.</p>') $null; break }
                $states.Remove($q['state'])
                $conv = Invoke-RestMethod -Method POST -Uri "https://api.github.com/app-manifests/$($q['code'])/conversions" -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'factory-worker-app-setup' }
                if ($conv.name -ne $kinds[$k].name -or $conv.owner.login -ne $Organization) { Send $ctx 400 (Html "<p>GitHub returned a different App (<code>$($conv.name)</code>, owner <code>$($conv.owner.login)</code>) than the one asked for. Nothing was stored.</p>") $null; break }
                Save-Key $k $conv.pem
                Set-Info $k @{ kind = $k; id = $conv.id; slug = $conv.slug; client_id = $conv.client_id; organization = $Organization; created = [DateTime]::UtcNow.ToString('o') }
                Write-Host "created $($conv.slug) (app $($conv.id)); key stored in the keyring"
                Send $ctx 302 $null "$base/install/$k"
            }
            '^install/(\w+)$' {
                $info = Get-Info $Matches[1]; if (-not $info) { Send $ctx 404 $null $null; break }
                Send $ctx 302 $null (Get-InstallUrl $info)
            }
            '^go/(\w+)$' {
                $info = Get-Info $Matches[1]; if (-not $info) { Send $ctx 404 $null $null; break }
                Send $ctx 302 $null $(if ($info.installation_id) { Get-SettingsUrl $info } else { Get-InstallUrl $info })
            }
            '^after-install/(\w+)$' { $r = Invoke-Check $Matches[1]; Send $ctx 200 $r.html $null }
            '^check/(\w+)$' { $r = Invoke-Check $Matches[1]; Send $ctx 200 $r.html $null }
            default { Send $ctx 404 $null $null }
        }
    } catch {
        Write-Host "error: $($_.Exception.Message)"
        try { Send $ctx 500 (Html '<p>Something failed; see the terminal.</p>') $null } catch { }
    }
}
$listener.Stop()
Write-Host 'stopped'
