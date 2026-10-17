#!/usr/bin/env pwsh
# Report on a finished (or stopped) full run: where each item is, its pull request, approvals, merge, release and deployments. Read-only.
param([Parameter(Mandatory)] [string] $Work, [Parameter(Mandatory)] [string] $Numbers)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot); $repo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'
$env:FACTORY_CONFIG = Join-Path $root 'config/instance.json'; $env:GH_TOKEN = (& gh auth token); $env:OCTOPUS_API_KEY = (& secret-tool lookup service demo-operator kind octopus-read-key)
$rows = @()
foreach ($n in ($Numbers -split ',' | ForEach-Object { [int]$_ })) {
    $g = '{"item":' + $n + '}' | & pwsh -NoProfile -File (Join-Path $root 'plugin/scripts/factory.ps1') --server get-item | ConvertFrom-Json
    $s = $g.state; $pr = if ($s.PSObject.Properties['pr']) { $s.pr.number } else { $null }
    $rev = if ($pr) { (gh api "repos/$repo/pulls/$pr/reviews" --jq '[.[]|select(.state=="APPROVED")|.user.login]|unique|join(",")') } else { '' }
    $sha = if ($s.PSObject.Properties['merge']) { $s.merge.sha } else { $null }
    $rel = ''; $dep = ''
    if ($sha) { $d = '{"commit":"' + $sha + '"}' | & pwsh -NoProfile -File (Join-Path $root 'plugin/scripts/factory.ps1') --server get-delivery | ConvertFrom-Json
                if ($d.candidate) { $rel = $d.candidate.version; $dep = ($d.deployments.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.state)" }) -join ' ' } }
    $park = if ($s.PSObject.Properties['park']) { $s.park.reason } else { '' }
    $rows += [pscustomobject]@{ item = $n; column = $g.status; pr = $pr; approvedBy = $rev; merged = $(if ($sha) { $sha.Substring(0, 7) } else { '' }); release = $rel; deployments = $dep; parked = $park }
}
$rows | Format-Table -AutoSize | Out-String -Width 220
$rows | ConvertTo-Json | Set-Content (Join-Path $Work 'report.json')
