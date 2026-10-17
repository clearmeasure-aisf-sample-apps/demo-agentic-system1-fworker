#!/usr/bin/env pwsh
# Test actor: submits a review on a pull request as one of the factory-worker Apps (the 'testperson' App stands in for a human reviewer).
# Mints the App's installation token from the keyring exactly as the gateway does; prints no secret.
param([Parameter(Mandatory)][ValidateSet('reviewer', 'testperson')] [string] $Kind, [Parameter(Mandatory)] [int] $Pr,
      [ValidateSet('APPROVE', 'REQUEST_CHANGES', 'COMMENT')] [string] $Event = 'APPROVE', [string] $Body = 'Reviewed by the test person.')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $env:FACTORY_CONFIG) { $env:FACTORY_CONFIG = Join-Path $root 'config/instance.json' }
foreach ($f in 'Core', 'Apps') { . (Join-Path $root "plugin/scripts/lib/$f.ps1") }
$c = Get-Cfg
$tok = Get-AppToken $Kind
$h = @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'factory-worker-test-actor' }
$base = "https://api.github.com/repos/$($c.owner)/$($c.repo)"
$sha = (Invoke-RestMethod -Uri "$base/pulls/$Pr" -Headers $h).head.sha
$r = Invoke-RestMethod -Method POST -Uri "$base/pulls/$Pr/reviews" -Headers $h -ContentType 'application/json' -Body (@{ event = $Event; commit_id = $sha; body = $Body } | ConvertTo-Json)
@{ ok = $true; kind = $Kind; pr = $Pr; event = $Event; commit = $sha; review = $r.id; state = $r.state } | ConvertTo-Json -Compress
