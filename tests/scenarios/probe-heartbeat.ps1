# A probe of the client's heartbeat for the messaging scenarios (messaging.ps1). It runs in its own process, so its thread jobs, its throttle limit
# and its environment (FACTORY_HEARTBEAT_SECONDS) are its own. It answers the heartbeat on a loopback port and prints one JSON line.
#   -Mode watchers   five long-lived thread jobs hold the default slots (as spawn watchers do); the heartbeat must still run and beat, a running
#                    job is kept, a stopped one is replaced, and a queued one is neither counted as running nor duplicated
#   -Mode floor      FACTORY_HEARTBEAT_SECONDS=0 must beat about once a second, not in a busy loop
param([string]$Mode = 'watchers', [int]$Port = 0)
$ErrorActionPreference = 'Stop'
$lib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'plugin/scripts/lib/Client.Own.ps1'
. $lib
$url = "http://127.0.0.1:$Port"
$listener = [Net.HttpListener]::new(); $listener.Prefixes.Add("$url/"); $listener.Start()
$script:pending = $null
# Answers the beats that arrive within $Seconds and returns how many there were.
function Count-Beats([double]$Seconds) {
    $n = 0; $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if (-not $script:pending) { $script:pending = $listener.GetContextAsync() }
        if ($script:pending.Wait(200)) { $c = $script:pending.Result; $script:pending = $null; $c.Response.StatusCode = 200; $c.Response.Close(); $n++ }
    }
    return $n
}
if ($Mode -eq 'watchers') {
    $watch = 1..5 | ForEach-Object { Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 60 } }
    $hb = Start-Heartbeat $url 'cred'
    $beats = Count-Beats 4
    $state = "$($hb.State)"
    $same = Confirm-Heartbeat $hb $url 'cred'
    $kept = ($same.Id -eq $hb.Id)
    Stop-Job $hb | Out-Null
    $new = Confirm-Heartbeat $hb $url 'cred'
    Start-Sleep -Milliseconds 500
    $replaced = ($new.Id -ne $hb.Id -and "$($new.State)" -eq 'Running')
    # a limit of one slot, with jobs already running, queues the next job: it is not started yet and must not be started a second time
    $null = Start-ThreadJob -ThrottleLimit 1 -ScriptBlock { 'queued first' }
    $queued = Start-ThreadJob -ScriptBlock { Start-Sleep -Seconds 30 }
    $before = @(Get-Job).Count
    $q2 = Confirm-Heartbeat $queued $url 'cred'
    $after = @(Get-Job).Count
    [ordered]@{ beats = $beats; state = $state; kept = $kept; replaced = $replaced; queuedState = "$($queued.State)"; queuedKept = ($q2.Id -eq $queued.Id); noNewJob = ($after -eq $before) } | ConvertTo-Json -Compress
}
else {
    $hb = Start-Heartbeat $url 'cred'
    [ordered]@{ beats = (Count-Beats 4.5) } | ConvertTo-Json -Compress
}
# leave at once: a heartbeat in the middle of a request would otherwise keep a stop of its job waiting for the request's timeout
[Console]::Out.Flush()
[Environment]::Exit(0)
