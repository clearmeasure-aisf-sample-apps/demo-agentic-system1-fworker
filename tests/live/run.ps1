#!/usr/bin/env pwsh
# Tier 2: the real gateway, the real GitHub (cmdemo1-workorders, a sandbox), the real reviewer and test-person Apps, real CI, real merges of
# docs-only files. A scripted worker stands in for Claude; the simulated human is the test-person App. No human takes part.
# usage: pwsh tests/live/run.ps1 [-Only <regex>]
param([string] $Only = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tests/scenarios/lib.ps1')
$RepoSlug = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'
$sandbox = $(if ($env:FACTORY_SANDBOX_REPO) { $env:FACTORY_SANDBOX_REPO } else { Join-Path $HOME 'Projects/factory-worker-sandbox/cmdemo1-workorders' })   # a clone of cmdemo1-workorders the run may change; FACTORY_SANDBOX_REPO names another place
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$script:Work = Join-Path ([IO.Path]::GetTempPath()) "factory-worker-live-$stamp"; New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
$pngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

function Start-LiveEnv {
    $cfg = Get-Content -Raw (Join-Path $root 'config/instance.json') | ConvertFrom-Json -AsHashtable
    $cfg.mergePolicy = 'peer-approved'; $cfg.humanApprovers = @('factory-worker-testperson[bot]')
    $cfg.timing.sweepSeenCount = 1; $cfg.timing.docsOnlyReleaseGraceSeconds = 60; $cfg.timing.mergeabilityWaitSeconds = 30
    $cfgPath = Join-Path $script:Work 'instance.live.json'; $cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath
    $gw = Join-Path $root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'
    if (-not (Test-Path $gw)) { throw "build the gateway first: $gw" }
    foreach ($v in 'GITHUB_API_URL', 'FACTORY_FAKE_APPS') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    $env:GH_TOKEN = (& gh auth token); $env:OCTOPUS_API_KEY = (& secret-tool lookup service demo-operator kind octopus-read-key)
    $env:FACTORY_CONFIG = $cfgPath; $env:FACTORY_STATE_DIR = Join-Path $script:Work 'state'
    $env:FACTORY_PLUGIN_SCRIPTS = Join-Path $root 'plugin/scripts'; $env:FACTORY_DEV_TOKEN = 'live-test-token'; $env:FACTORY_WEBHOOK_SECRET = ('y' * 40)
    $env:FACTORY_API_PORT = '5300'; $env:FACTORY_WEBHOOK_PORT = '5301'; $env:FACTORY_SWEEP_SECONDS = '6'
    $script:Procs += Start-Process dotnet -ArgumentList $gw -PassThru -RedirectStandardOutput (Join-Path $script:Work 'gateway.out') -RedirectStandardError (Join-Path $script:Work 'gateway.err')
    Remove-Item Env:GH_TOKEN, Env:OCTOPUS_API_KEY   # the client side never holds them
    $env:FACTORY_URL = 'http://127.0.0.1:5300'; $env:FACTORY_TOKEN = 'live-test-token'
    $up = Wait-Until -Seconds 40 { try { (Invoke-RestMethod 'http://127.0.0.1:5300/health' -TimeoutSec 2) -eq 'ok' } catch { $false } }
    if (-not $up) { throw 'the live-test gateway did not start (is another gateway on port 5300?)' }
}

function New-LiveItem([string]$Title, [string]$Body, [string[]]$Labels) {
    $a = @('api', "repos/$RepoSlug/issues", '-f', "title=$Title", '-f', "body=$Body"); foreach ($l in $Labels) { $a += @('-f', "labels[]=$l") }
    $j = (& gh @a --jq '{n:.number,node:.node_id}') | ConvertFrom-Json
    $card = & gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' -f p=PVT_kwDOD_ESUc4BliGL -f c="$($j.node)" --jq .data.addProjectV2ItemById.item.id
    & gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' -f p=PVT_kwDOD_ESUc4BliGL -f i="$card" -f f=PVTSSF_lADOD_ESUc4BliGLzhkOn7g -f o=e6ec2abc | Out-Null
    return [int]$j.n
}

function Push-LiveBranch([int]$n, $Files) {
    & git -C $sandbox fetch -q origin 2>&1 | Out-Null
    $wt = Join-Path (Split-Path -Parent $sandbox) "live-wt-$n"
    & git -C $sandbox worktree add -q -b "factory-worker/$n-development" $wt origin/master 2>&1 | Out-Null
    foreach ($f in $Files) {
        $p = Join-Path $wt $f.path; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        if ($f.ContainsKey('bytes')) { [IO.File]::WriteAllBytes($p, $f.bytes) } else { Set-Content -Path $p -Value $f.text }
    }
    & git -C $wt add -A 2>&1 | Out-Null; & git -C $wt commit -q -m "Add live trial files for work item #$n" 2>&1 | Out-Null
    & git -C $wt -c credential.helper='!gh auth git-credential' push -q -u origin "factory-worker/$n-development" 2>&1 | Out-Null
}

function Live-Status([int]$n) { (F 'w1' @('get-item', '--item', $n)) }
function Live-Development([int]$n, $Files) {
    $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Development'); CheckExit "DEV $n claim" $r 0
    Push-LiveBranch $n $Files
    $r = F 'w1' @('open-pr', '--item', $n, '--head', "factory-worker/$n-development", '--title', "Live trial for item $n", '--body-file', (TmpFile "lpr$n.md" 'Live trial change.')); CheckExit "DEV $n open-pr" $r 0
    $pr = $r.pullRequest.number
    $ok = $false; foreach ($i in 1..12) { $w = F 'w1' @('wait-for-checks', '--item', $n); if ($w.exit -eq 0) { $ok = $true; break }; if ($w.exit -eq 10) { break } }
    Check "DEV $n real CI is green" $ok "(last: exit $($w.exit) $(Pv $w 'status'))"
    return [int]$pr
}
function Live-ToVerdict([int]$n, $Files, [bool]$DocsOnly = $true) {
    Do-TechnicalDesign $n 'w1' $DocsOnly
    $pr = Live-Development $n $Files
    $r = Do-DevComplete $n; CheckExit "DEV $n complete" $r 0
    $v = Do-Verdict $n $pr; CheckExit "FT $n verdict PASS" $v 0
    return @{ pr = $pr; verdict = $v }
}
function Live-Reviews([int]$pr) { (& gh api "repos/$RepoSlug/pulls/$pr/reviews" --jq '[.[]|{u:.user.login,s:.state,c:.commit_id}]') | ConvertFrom-Json }
function Live-Head([int]$pr) { (& gh api "repos/$RepoSlug/pulls/$pr" --jq .head.sha) }
function Wait-Done([int]$n, [int]$Minutes = 9) { Wait-Until -Seconds ($Minutes * 60) { $g = Live-Status $n; ($g.status -eq 'Done') -and (-not $g.open) } }

$Live = [ordered]@{

'live: inspector approves, a different identity, real merge, finishes to Done' = {
    $n = New-LiveItem "Live trial $stamp A: approve path" "Add docs/factory-worker-trials/live-$stamp-a.md. Documentation only." @('factory worker', 'Auto Merge', 'factory test')
    Write-Host "    item #$n"
    $t = Live-ToVerdict $n @(@{ path = "docs/factory-worker-trials/live-$stamp-a.md"; text = "# Live trial $stamp A`n`nWritten by the scripted worker.`n" })
    Check 'verdict points at the approval step' ((Pv $t.verdict 'next') -eq 'approve')
    $r = F 'w1' @('merge', '--item', $n, '--pr', $t.pr); CheckExit 'merge before approval is refused' $r 10 'approval-missing'
    $f = F 'w1' @('inspect-facts', '--item', $n); Check 'no mandatory escalation' ((Pv $f 'must_escalate') -eq $false) "$($f.mandatory | ConvertTo-Json -Compress -Depth 4)"
    $r = F 'w1' @('approve-pr', '--item', $n, '--pr', $t.pr, '--text-file', (TmpFile 'la.md' (Insp-Text 'APPROVE' 'One new docs file, matches the item.'))); CheckExit 'inspector approves' $r 0
    $rev = Live-Reviews $t.pr; $head = Live-Head $t.pr
    Check 'GitHub shows an approval by the reviewer App on the current head' (@($rev | Where-Object { $_.u -eq 'factory-worker-reviewer[bot]' -and $_.s -eq 'APPROVED' -and $_.c -eq $head }).Count -eq 1) ($rev | ConvertTo-Json -Compress)
    $m = F 'w1' @('merge', '--item', $n, '--pr', $t.pr); CheckExit 'merge' $m 0; Check 'merged' ((Pv $m 'outcome') -eq 'merged') "$(Pv $m 'outcome') $(Pv $m 'reason')"
    Check 'finished to Done and closed (master CI, then docs-only release handling)' (Wait-Done $n) "status $((Live-Status $n).status)"
}

'live: a binary file forces escalation; the test person releases the hold' = {
    $n = New-LiveItem "Live trial $stamp B: escalation path" "Add docs/factory-worker-trials/live-$stamp-b.png. Documentation only." @('factory worker', 'Auto Merge', 'factory test')
    Write-Host "    item #$n"
    $t = Live-ToVerdict $n @(@{ path = "docs/factory-worker-trials/live-$stamp-b.png"; bytes = $pngBytes })
    $f = F 'w1' @('inspect-facts', '--item', $n); Check 'binary-file is mandatory' (@($f.mandatory | Where-Object { $_.code -eq 'binary-file' }).Count -eq 1) "$($f.mandatory | ConvertTo-Json -Compress -Depth 4)"
    $r = F 'w1' @('approve-pr', '--item', $n, '--pr', $t.pr, '--text-file', (TmpFile 'lb1.md' (Insp-Text 'APPROVE'))); CheckExit 'approve is refused' $r 10 'escalation-required'
    $r = F 'w1' @('approve-pr', '--item', $n, '--pr', $t.pr, '--text-file', (TmpFile 'lb2.md' (Insp-Text 'ESCALATE' 'A binary file cannot be inspected.'))); CheckExit 'escalate' $r 0
    Check 'GitHub issue carries Needs Human Review' ((Live-Status $n).labels -contains 'Needs Human Review')
    $r = F 'w1' @('merge', '--item', $n, '--pr', $t.pr); CheckExit 'merge while held' $r 10 'held'
    $a = & pwsh -NoProfile -File (Join-Path $root 'tests/live/as-app.ps1') -Kind testperson -Pr $t.pr -Event APPROVE -Body 'Approved by the simulated person.' | ConvertFrom-Json
    Check 'the test-person App approved the current head' ($a.state -eq 'APPROVED' -and $a.commit -eq (Live-Head $t.pr)) ($a | ConvertTo-Json -Compress)
    $cleared = Wait-Until -Seconds 60 { -not ((Live-Status $n).labels -contains 'Needs Human Review') }
    Check 'the sweep released the hold' $cleared
    $m = F 'w1' @('merge', '--item', $n, '--pr', $t.pr); CheckExit 'merge after the hold' $m 0; Check 'merged' ((Pv $m 'outcome') -eq 'merged') "$(Pv $m 'outcome') $(Pv $m 'reason')"
    Check 'finished to Done and closed' (Wait-Done $n) "status $((Live-Status $n).status)"
}

'live: request changes sends the item back to Development' = {
    $n = New-LiveItem "Live trial $stamp C: request changes" "Add docs/factory-worker-trials/live-$stamp-c.md. Documentation only." @('factory worker', 'Auto Merge', 'factory test')
    Write-Host "    item #$n"
    $t = Live-ToVerdict $n @(@{ path = "docs/factory-worker-trials/live-$stamp-c.md"; text = "# Live trial $stamp C`n`nmissing full stop`n" })
    $r = F 'w1' @('approve-pr', '--item', $n, '--pr', $t.pr, '--text-file', (TmpFile 'lc.md' (Insp-Text 'REQUEST CHANGES' '- the sentence needs a full stop.'))); CheckExit 'request changes' $r 0
    Check 'demoted' ((Pv $r 'outcome') -eq 'demoted')
    $g = Live-Status $n; Check 'back in Development with the finding attached' ($g.status -eq 'Development' -and $g.existing_pr.rejection -like '*full stop*') "$($g.status)"
    & gh pr close $t.pr -R $RepoSlug --delete-branch 2>&1 | Out-Null
    & gh api -X PATCH "repos/$RepoSlug/issues/$n" -f state=closed 2>&1 | Out-Null
}

}

Start-LiveEnv
try {
    foreach ($name in $Live.Keys) {
        if ($Only -and $name -notmatch $Only) { continue }
        $script:Current = $name; Write-Host "  $name"
        try { & $Live[$name] } catch { Check 'no unexpected exception' $false $_.Exception.Message }
    }
    Start-Sleep -Seconds 8
    Assert-NoServerErrors 'live'
} finally { Stop-TestEnv }
Write-Host ""
Write-Host "$($script:Checks) checks, $($script:Failures.Count) failed"
$script:Failures | ForEach-Object { Write-Host "  FAILED: $_" }
exit ([int]($script:Failures.Count -gt 0))
