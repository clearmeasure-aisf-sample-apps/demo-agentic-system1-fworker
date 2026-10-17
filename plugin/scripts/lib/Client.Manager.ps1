# The plant manager's flow verbs, client side (docs/design/plant-manager.md 10e): what the supervisor session may change to keep the flow moving.
# Dispatched from factory.ps1 like the messaging verbs; Client.Own.ps1 (Invoke-GatewayJson, Get-WorkerCredential) and Client.Messages.ps1
# (Assert-NoSecret) are loaded first. Every call goes
# out with the supervisor credential (FACTORY_SUPERVISOR_TOKEN, else the keyring entry kind supervisor-token of this session's name); the gateway
# decides who may act, and refuses everything else.
#
#   act <unpark|release-owner|pin|unpin|requeue|prioritize|rerun-failed> --item N --policy CODE [--reason "..."] [--worker W] [--level top|high|normal]
#   act <drain|resume|restart-session> --name W --policy CODE [--reason "..."]
#   act-log                      the plant manager's actions of the last 24 hours, the mode and the limits
#   metrics [--since 24h|7d]     cycle times from the items' journals (GET /api/v1/metrics, cached), for the daily summary

$script:ActItemActions = @('unpark', 'release-owner', 'pin', 'unpin', 'requeue', 'prioritize', 'rerun-failed')
$script:ActNameActions = @('drain', 'resume', 'restart-session')

function Exit-ActUsage([string]$Reason) { Write-Out @{ ok = $false; code = 'usage'; reason = $Reason } 2 }

function Get-ManagerCallCredential($Cfg) {
    $holder = if ($env:FACTORY_HOLDER) { $env:FACTORY_HOLDER } else { '' }
    return (Get-WorkerCredential $Cfg $holder -Supervisor)
}

# Prints the gateway's answer as it is and exits with its exit code (no text of a work item is in it: names, numbers and codes only).
function Write-ActResult($R) {
    if (-not $R.transport) { Write-Out @{ ok = $false; code = 'gateway-unreachable'; reason = $R.error; retryAfterSeconds = 15 } 20 }
    $code = Get-GatewayExit $R
    if ($null -eq $R.body) { [Console]::Out.WriteLine((@{ ok = $false; code = 'gateway-error'; reason = "HTTP $($R.status)"; exit = $code } | ConvertTo-Json -Compress)); exit $code }
    [Console]::Out.WriteLine($R.raw.Trim()); exit $code
}

function Invoke-ManagerAct([string]$Action, $a, $cfg) {
    if ($Action -notin ($script:ActItemActions + $script:ActNameActions)) { Exit-ActUsage "act <action>: one of $(($script:ActItemActions + $script:ActNameActions) -join ', ')" }
    $policy = if ($a.ContainsKey('policy')) { "$($a.policy)" } else { '' }
    if ($policy -notmatch '^[a-z][a-z0-9-]{1,39}$') { Exit-ActUsage '--policy CODE is required: the policy code that this action follows (the skill lists them)' }
    $body = [ordered]@{ action = $Action; policy = $policy }
    if ($Action -in $script:ActItemActions) {
        $n = 0; if (-not $a.ContainsKey('item') -or -not [int]::TryParse("$($a.item)", [ref]$n) -or $n -lt 1) { Exit-ActUsage '--item N is required' }
        $body['item'] = $n
        if ($Action -eq 'pin') { $w = if ($a.ContainsKey('worker')) { "$($a.worker)" } else { '' }; if ($w -notmatch '^[A-Za-z0-9_-]{1,40}$') { Exit-ActUsage 'pin needs --worker NAME' }; $body['worker'] = $w }
        if ($Action -eq 'prioritize') { $l = if ($a.ContainsKey('level')) { "$($a.level)" } else { 'top' }; if ($l -notin 'top', 'high', 'normal') { Exit-ActUsage '--level is top, high or normal' }; $body['level'] = $l }
    } else {
        $w = if ($a.ContainsKey('name')) { "$($a.name)" } else { '' }
        if ($w -notmatch '^[A-Za-z0-9_-]{1,40}$') { Exit-ActUsage "$Action needs --name NAME (a worker session's name)" }
        $body['worker'] = $w
    }
    if ($a.ContainsKey('reason')) {
        $r = "$($a.reason)".Trim()
        if ($r.Length -gt 300) { Exit-ActUsage '--reason is at most 300 characters' }
        Assert-NoSecret 'reason' $r
        $body['reason'] = $r
    }
    Write-ActResult (Invoke-GatewayJson $cfg 'POST' '/api/v1/verbs/manager-action' $body (Get-ManagerCallCredential $cfg) 170)
}

function Invoke-ManagerVerb([string]$Verb, [string[]]$Tokens, $cfg) {
    switch ($Verb) {
        'act' {
            $t = @($Tokens); $action = if ($t.Count -gt 0) { "$($t[0])" } else { '' }
            Invoke-ManagerAct $action (ConvertFrom-Flags ([string[]]@($t | Select-Object -Skip 1))) $cfg
        }
        'act-log' { Write-ActResult (Invoke-GatewayJson $cfg 'GET' '/api/v1/manager/actions' $null (Get-ManagerCallCredential $cfg) 30) }
        'metrics' {
            $a = ConvertFrom-Flags ([string[]]@($Tokens)); $q = @()
            if ($a.ContainsKey('since')) { $s = "$($a.since)"; if ($s -notin '24h', '7d') { Exit-ActUsage '--since is 24h or 7d' }; $q += "since=$s" }
            Write-ActResult (Invoke-GatewayJson $cfg 'GET' ("/api/v1/metrics" + $(if ($q.Count) { '?' + ($q -join '&') } else { '' })) $null (Get-ManagerCallCredential $cfg) 200)
        }
    }
}
