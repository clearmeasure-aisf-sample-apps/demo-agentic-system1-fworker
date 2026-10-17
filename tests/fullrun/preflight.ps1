#!/usr/bin/env pwsh
# Read-only checks before the fully connected run: every system the run touches is real, so every one is checked first. Changes nothing.
# usage: pwsh tests/fullrun/preflight.ps1 [-CheckModel]    (-CheckModel makes one tiny call to the testing-profile model)
param([switch] $CheckModel, [switch] $AllowRunning, [string] $Pick = '1,2,3,4,5,6,7,8,9,10')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'
$sandbox = $(if ($env:FACTORY_SANDBOX_REPO) { $env:FACTORY_SANDBOX_REPO } else { Join-Path $HOME 'Projects/factory-worker-sandbox/cmdemo1-workorders' })   # a clone of cmdemo1-workorders the run may change; FACTORY_SANDBOX_REPO names another place
$script:bad = 0
function Row([string]$Name, [bool]$Ok, [string]$Detail = '') { if (-not $Ok) { $script:bad++ }; '{0,-4} {1,-58} {2}' -f $(if ($Ok) { 'ok' } else { 'FAIL' }), $Name, $Detail }
$env:FACTORY_CONFIG = Join-Path $root 'config/instance.json'
foreach ($f in 'Core', 'Apps') { . (Join-Path $root "plugin/scripts/lib/$f.ps1") }
$all = Get-Content -Raw (Join-Path $PSScriptRoot 'items.json') | ConvertFrom-Json; $pickN = @($Pick -split ',' | ForEach-Object { [int]$_.Trim() }); $items = @($all | Where-Object { $pickN -contains [int]$_.n })

# --- GitHub
try { $me = gh api user --jq .login; Row 'GitHub token (operator)' $true $me } catch { Row 'GitHub token (operator)' $false 'gh is not signed in' }
$flag = [int](Invoke-WebRequest 'https://github.com/cm-ai-ops-bot' -SkipHttpErrorCheck -TimeoutSec 20).StatusCode; Row 'operator account is visible (not flagged)' ($flag -eq 200) "http $flag"
$perm = gh api repos/$repo --jq '.permissions.push'; Row 'push access to cmdemo1-workorders' ($perm -eq 'true')
$labels = @(gh api "repos/$repo/labels?per_page=100" --jq '.[].name'); foreach ($l in 'factory worker', 'Auto Merge') { Row "label '$l' exists" ($labels -contains $l) }
Row "label 'factory test' (created by create-items.ps1 if missing)" $true $(if ($labels -contains 'factory test') { 'exists' } else { 'will be created' })
$rs = gh api repos/$repo/rulesets/24408815 --jq '[.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|join(",")'; Row 'master requires Build result and secret-scan' ($rs -match 'Build result' -and $rs -match 'secret-scan') $rs
$last = gh api "repos/$repo/actions/workflows/build.yml/runs?branch=master&per_page=1" --jq '.workflow_runs[0]|"\(.conclusion) \(.run_number)"'; Row 'last master Build' ($last -like 'success*') $last
$open = @(gh pr list -R $repo --state open --json headRefName --jq '.[].headRefName' | Where-Object { $_ -like 'factory-worker/*' }); if (-not $AllowRunning) { Row 'no open factory-worker pull requests' ($open.Count -eq 0) ($open -join ',') }
# --- the apps and their one-repository installs
foreach ($k in 'reviewer', 'testperson') {
    try { $t = Get-AppToken $k; $r = Invoke-RestMethod 'https://api.github.com/installation/repositories' -Headers @{ Authorization = "Bearer $t"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'preflight' }
          Row "App '$k' mints a token, reaches only the repo" ($r.total_count -eq 1 -and $r.repositories[0].name -eq 'cmdemo1-workorders') "$(Get-AppLogin $k)" } catch { Row "App '$k'" $false $_.Exception.Message }
}
# --- Octopus (read-only key)
$ok = & secret-tool lookup service demo-operator kind octopus-read-key; $env:OCTOPUS_API_KEY = $ok
try {
    $h = @{ 'X-Octopus-ApiKey' = $ok }; $o = 'https://clearmeasure.octopus.app/api/Spaces-355'
    $p = Invoke-RestMethod "$o/projects/cmdemo1-ui" -Headers $h; Row 'Octopus project cmdemo1-ui' ($p.Name -eq 'cmdemo1-ui') $p.Id
    $lc = Invoke-RestMethod "$o/lifecycles/$($p.LifecycleId)" -Headers $h
    Row 'lifecycle: tdd deploys automatically' (@($lc.Phases[0].AutomaticDeploymentTargets).Count -gt 0) ($lc.Phases | ForEach-Object { "$($_.Name):$(if (@($_.AutomaticDeploymentTargets).Count) {'auto'} else {'manual'})" }) -join ' '
    $rels = (Invoke-RestMethod "$o/projects/$($p.Id)/releases?take=1" -Headers $h).Items; Row 'latest release' ($rels.Count -eq 1) "$($rels[0].Version)"
} catch { Row 'Octopus' $false $_.Exception.Message }; Remove-Item Env:OCTOPUS_API_KEY
# --- the ten replacements exist exactly once at master, and the new text does not
& git -C $sandbox fetch -q origin 2>&1 | Out-Null
foreach ($i in $items) {
    $txt = (& git -C $sandbox show "origin/master:$($i.file)" 2>$null) -join "`n"
    $n1 = ([regex]::Matches($txt, [regex]::Escape($i.from))).Count; $n2 = ([regex]::Matches($txt, [regex]::Escape($i.to))).Count
    $tn = 1; if ($i.test) { $tt = (& git -C $sandbox show "origin/master:$($i.test)" 2>$null) -join "`n"; $tn = ([regex]::Matches($tt, [regex]::Escape($i.from))).Count }
    Row ("item {0,2}: '{1}' occurs once in {2}" -f $i.n, $i.from, (Split-Path -Leaf $i.file)) ($n1 -eq 1 -and $n2 -eq 0 -and $tn -eq 1) "src=$n1 new=$n2 test=$(if ($i.test) {$tn} else {'-'})"
}
$files = @($all | ForEach-Object { $_.file }); Row 'ten different files (no merge conflicts between items)' (($files | Select-Object -Unique).Count -eq 10)
# --- this machine
Row 'claude CLI' ([bool](Get-Command claude -ErrorAction SilentlyContinue)) ((& claude --version) -join '')
Row 'dotnet SDK for the unit tests' ([bool](Get-Command dotnet -ErrorAction SilentlyContinue)) ((& dotnet --version) -join '')
if (-not $AllowRunning) { $busy = @(5100, 5101, 5300, 5301 | Where-Object { (& ss -ltn 2>$null | Select-String ":$_ ") }); Row 'gateway ports are free' ($busy.Count -eq 0) ($busy -join ',') }
$gwOk = Test-Path (Join-Path $root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'); Row 'gateway is built' $gwOk
$mc = Get-Content -Raw (Join-Path $root 'plugin/scripts/models.default.json') | ConvertFrom-Json -AsHashtable; Row 'testing profile' ($mc.profiles.testing.model -eq 'claude-haiku-5-5' -and $mc.profiles.testing.effort -eq 'low') "$($mc.profiles.testing.model) / $($mc.profiles.testing.effort)"
if ($CheckModel) { $out = ('' | & claude -p 'Reply with only the word ok.' --model $mc.profiles.testing.model --effort low --max-turns 1 2>&1 | Where-Object { $_ -notmatch 'catalog|unrecognized_model' }) -join ' '; Row 'testing model answers' ($out -match 'ok') $out.Trim() }
''
if ($script:bad) { "$($script:bad) check(s) failed"; exit 1 } else { 'preflight passed' }
