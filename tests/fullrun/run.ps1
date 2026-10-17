#!/usr/bin/env pwsh
# The fully connected run. Nothing is stubbed: real GitHub (cmdemo1-workorders), real GitHub Apps, real CI, real Octopus (read-only key), real Claude
# sessions on the testing profile (claude-haiku-5-5 at low effort) doing every role. Ten text-replacement items are handed over at once, workers run
# three at a time, merges go through the merge queue one release at a time, and each item ends in Release Queue once its tdd deployment succeeds.
# uat and prod are the operator's manual promotions: see promote.ps1. usage: pwsh tests/fullrun/run.ps1 -Go   (without -Go it only runs the preflight)
param([switch] $Go, [string] $Pick = '1,2,3,4,5,6,7,8,9,10', [int] $Workers = 3, [double] $TimeoutHours = 6)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$work = Join-Path ([IO.Path]::GetTempPath()) "factory-worker-fullrun-$stamp"; New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "work directory: $work"
$running = $false; $sf = Join-Path $HOME '.local/share/factory-worker/fullrun-services.json'; if (Test-Path $sf) { try { $null = Get-Process -Id ((Get-Content -Raw $sf | ConvertFrom-Json).gatewayPid) -ErrorAction Stop; $running = $true } catch { } }
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'preflight.ps1') -CheckModel -Pick $Pick $(if ($running) { '-AllowRunning' }); if ($LASTEXITCODE -ne 0) { throw 'preflight failed; nothing was started' }
if (-not $Go) { Write-Host 'preflight only (add -Go to start the run)'; return }

# --- gateway and workers: reused if a previous phase left them running (they must keep sweeping until the last item is Done)
$svcFile = Join-Path $HOME '.local/share/factory-worker/fullrun-services.json'
$svc = if (Test-Path $svcFile) { Get-Content -Raw $svcFile | ConvertFrom-Json } else { $null }
$alive = $false; if ($svc) { try { $null = Get-Process -Id $svc.gatewayPid -ErrorAction Stop; $env:FACTORY_URL = 'http://127.0.0.1:5300'; $env:FACTORY_TOKEN = $svc.token; $alive = ((Invoke-RestMethod 'http://127.0.0.1:5300/health' -TimeoutSec 3) -eq 'ok') } catch { } }
if ($alive) { Write-Host "reusing the running gateway (pid $($svc.gatewayPid)) and workers (pid $($svc.subscribePid)); work directory $($svc.work)"; $work = $svc.work }
else {
    $cfg = Get-Content -Raw (Join-Path $root 'config/instance.json') | ConvertFrom-Json -AsHashtable
    $cfg.mergePolicy = 'peer-approved'; $cfg.humanApprovers = @('factory-worker-testperson[bot]'); $cfg.mergeQueueDepth = 1
    $cfg.timing.sweepSeenCount = 1; $cfg.timing.docsOnlyReleaseGraceSeconds = 120
    $cfgPath = Join-Path $work 'instance.fullrun.json'; $cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath
    $env:GH_TOKEN = (& gh auth token); $env:OCTOPUS_API_KEY = (& secret-tool lookup service demo-operator kind octopus-read-key)
    $env:FACTORY_CONFIG = $cfgPath; $env:FACTORY_STATE_DIR = Join-Path $work 'state'; $env:FACTORY_PLUGIN_SCRIPTS = Join-Path $root 'plugin/scripts'
    $env:FACTORY_DEV_TOKEN = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)); $env:FACTORY_WEBHOOK_SECRET = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    $env:FACTORY_API_PORT = '5300'; $env:FACTORY_WEBHOOK_PORT = '5301'; $env:FACTORY_SWEEP_SECONDS = '15'
    $gw = Start-Process dotnet -ArgumentList (Join-Path $root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll') -PassThru -RedirectStandardOutput (Join-Path $work 'gateway.out') -RedirectStandardError (Join-Path $work 'gateway.err')
    Remove-Item Env:GH_TOKEN, Env:OCTOPUS_API_KEY      # the workers' side never holds them
    $env:FACTORY_URL = 'http://127.0.0.1:5300'; $env:FACTORY_TOKEN = $env:FACTORY_DEV_TOKEN
    $until = (Get-Date).AddSeconds(40); while ((Get-Date) -lt $until) { try { if ((Invoke-RestMethod 'http://127.0.0.1:5300/health' -TimeoutSec 2) -eq 'ok') { break } } catch { Start-Sleep -Milliseconds 500 } }
    # real Claude workers: one headless session per work offer, up to $Workers at a time
    if (-not $env:FACTORY_SANDBOX_REPO) { $env:FACTORY_SANDBOX_REPO = Join-Path $HOME 'Projects/factory-worker-sandbox/cmdemo1-workorders' }; $env:FACTORY_MAX_WORKERS = "$Workers"; $env:FACTORY_WORKER_DIR = Join-Path $work 'workers'
    $sub = Start-Process pwsh -ArgumentList '-NoProfile', '-File', (Join-Path $root 'plugin/scripts/factory.ps1'), 'subscribe', '--spawn' -PassThru -RedirectStandardOutput (Join-Path $work 'subscribe.out') -RedirectStandardError (Join-Path $work 'subscribe.err')
    @{ work = $work; gatewayPid = $gw.Id; subscribePid = $sub.Id; token = $env:FACTORY_TOKEN } | ConvertTo-Json | Set-Content $svcFile
    $svc = Get-Content -Raw $svcFile | ConvertFrom-Json
}

# --- hand over
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'create-items.ps1') -HandOver -Only $Pick
$items = Get-Content -Raw (Join-Path $PSScriptRoot 'created.json') | ConvertFrom-Json
$numbers = @($items | ForEach-Object { [int]$_.issue })
$t0 = Get-Date; $seen = @{}; $timeline = @()
function Get-Board { (gh api graphql -f query='query{organization(login:"clearmeasure-aisf-sample-apps"){projectV2(number:679){items(first:100){nodes{fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}} content{... on Issue{number state}}}}}}}' --jq '.data.organization.projectV2.items.nodes[]|select(.content.number!=null)|"\(.content.number)|\(.fieldValueByName.name)|\(.content.state)"') }
try {
    while (((Get-Date) - $t0).TotalHours -lt $TimeoutHours) {
        $now = Get-Board | ForEach-Object { $p = $_ -split '\|'; @{ n = [int]$p[0]; col = $p[1]; state = $p[2] } } | Where-Object { $numbers -contains $_.n }
        foreach ($r in $now) { if ($seen["$($r.n)"] -ne $r.col) { $seen["$($r.n)"] = $r.col; $timeline += [pscustomobject]@{ at = [int]((Get-Date) - $t0).TotalSeconds; item = $r.n; column = $r.col }; Write-Host ('{0,5}s  #{1}  -> {2}' -f [int]((Get-Date) - $t0).TotalSeconds, $r.n, $r.col) } }
        $finished = @($now | Where-Object { $_.col -in 'Release Queue', 'Done' }).Count
        if ($finished -eq $numbers.Count) { Write-Host 'all ten items reached Release Queue or Done'; break }
        Start-Sleep -Seconds 30
    }
} finally {
    $timeline | Export-Csv (Join-Path $work 'timeline.csv') -NoTypeInformation
    Write-Host "gateway and workers are still running (gateway pid $($svc.gatewayPid), workers pid $($svc.subscribePid)); stop them with tests/fullrun/stop.ps1; logs in $work"
}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'report.ps1') -Work $work -Numbers ($numbers -join ',')
