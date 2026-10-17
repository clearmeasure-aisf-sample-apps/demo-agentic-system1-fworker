# The sweep throttle and the GitHub budget (issue 92): at most one full sweep per sweepMinSeconds, triggers of an item get an incremental pass, the
# budget is built from GitHub's rate-limit headers, below its reserve only the essential verbs run, and a 403 is a rate limit only when GitHub says
# so. Runs in the owner suite; each scenario starts a gateway of its own (a long sweep interval, so only the scenario's triggers sweep) and gives
# the suite's gateway back in finally.

function Bg-Status { Get-Plant }
function Bg-Verb([string]$Verb, [hashtable]$Body) {
    $r = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/api/v1/verbs/$Verb" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -Body ($Body | ConvertTo-Json -Compress -Depth 5) -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 120
    @{ status = [int]$r.StatusCode; body = $(try { $r.Content | ConvertFrom-Json -AsHashtable } catch { @{ raw = "$($r.Content)" } }) }
}
function Bg-Labeled([int]$n) { Qc-Hook 'issues' @{ action = 'labeled'; label = @{ name = 'factory worker' }; issue = @{ number = $n; labels = @(@{ name = 'factory worker' }) }; repository = @{ full_name = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' } } }
function Bg-MasterBuild { Qc-Hook 'workflow_run' @{ action = 'completed'; workflow_run = @{ head_branch = 'master'; head_sha = ('a' * 40); conclusion = 'success'; name = 'Build' }; repository = @{ full_name = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' } } }
function Bg-WithGateway([hashtable]$Env, [scriptblock]$Body) {
    $old = @{}; foreach ($k in $Env.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { Restart-Gateway; [void](Wait-Until -Seconds 40 { (Bg-Status).sweep.full -ge 1 }); & $Body }
    finally {
        Fake 'rate' @{ resource = 'core'; remaining = 1000000; resetSeconds = 3600 } | Out-Null; Fake 'rate' @{ resource = 'graphql'; remaining = 1000000; resetSeconds = 3600 } | Out-Null
        foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
        Restart-Gateway
    }
}

$BudgetScenarios = [ordered]@{}

$BudgetScenarios['sweep throttle: one full sweep per sweepMinSeconds; a trigger of an item between them gets an incremental pass of that item only [full]'] = {
    Bg-WithGateway @{ FACTORY_SWEEP_SECONDS = '600'; FACTORY_SWEEP_MIN_SECONDS = '20' } {
        $s0 = (Bg-Status).sweep
        Check 'the status shows the sweep: one full sweep at start, the minimum interval' ($s0.full -eq 1 -and $s0.minSeconds -eq 20 -and $s0.incremental -eq 0) ($s0 | ConvertTo-Json -Compress)
        # a trigger of no item asks for a full sweep: it runs, but not before the minimum interval after the last one
        $lastFull = [DateTime]::Parse("$($s0.lastFull)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        [void](Bg-MasterBuild)
        Start-Sleep -Seconds 6
        $early = (Bg-Status).sweep
        if (([DateTime]::UtcNow - $lastFull).TotalSeconds -lt 14) { Check 'a trigger of no item right after a full sweep: no full sweep yet' ($early.full -eq 1 -and $early.fullRequested -eq $true) ($early | ConvertTo-Json -Compress) }
        Check 'a full sweep follows once the minimum interval has passed' (Wait-Until -Seconds 45 { (Bg-Status).sweep.full -ge 2 }) ((Bg-Status).sweep | ConvertTo-Json -Compress)
        $full2 = [DateTime]::Parse("$((Bg-Status).sweep.lastFull)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        Check 'not much sooner than sweepMinSeconds after the one before' (($full2 - $lastFull).TotalSeconds -ge 15) "$lastFull -> $full2"
        # an item put on the board after that sweep, nobody to take it: only a pass that reads it matches it
        $n = New-Item-Fake 'Throttle item' 'x' $OwnerLabels
        Check 'a webhook of the item is accepted' ((Bg-Labeled $n) -eq 202)
        Check 'it gets an incremental pass at once, not a full sweep' (Wait-Until -Seconds 20 { $s = (Bg-Status).sweep; $s.incremental -ge 1 -and $s.full -eq 2 }) ((Bg-Status).sweep | ConvertTo-Json -Compress)
        Check 'and that pass matched the item' (Wait-Until -Seconds 20 { @((Bg-Status).plant.assignments | Where-Object { $_.item -eq $n }).Count -eq 1 }) ((Bg-Status).plant.assignments | ConvertTo-Json -Compress)
        $before = (Bg-Status).sweep
        $hooks = @(foreach ($i in 1..4) { Start-ThreadJob -ArgumentList $n, $script:HookPort -ScriptBlock { param($n, $port)
            $raw = (@{ action = 'labeled'; label = @{ name = 'factory worker' }; issue = @{ number = $n; labels = @(@{ name = 'factory worker' }) }; repository = @{ full_name = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders' } } | ConvertTo-Json -Depth 8 -Compress)
            $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes('x' * 40)); $sig = 'sha256=' + ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))) -replace '-', '').ToLowerInvariant()
            [int](Invoke-WebRequest "http://127.0.0.1:$port/webhooks/github" -Method POST -Body $raw -ContentType 'application/json' -Headers @{ 'X-GitHub-Event' = 'issues'; 'X-GitHub-Delivery' = [guid]::NewGuid().ToString(); 'X-Hub-Signature-256' = $sig } -SkipHttpErrorCheck).StatusCode } })
        [void]($hooks | Wait-Job -Timeout 60); $hooks | Remove-Job -Force
        [void](Wait-Until -Seconds 20 { (Bg-Status).sweep.queued -eq 0 -and (Bg-Status).sweep.incremental -gt $before.incremental })
        $after = (Bg-Status).sweep
        Check 'four triggers of the same item at once: fewer passes than triggers, still no full sweep' ($after.full -eq 2 -and ($after.incremental - $before.incremental) -lt 4 -and ($after.incremental - $before.incremental) -ge 1 -and ($after.requests - $before.requests) -ge 4) "$($before | ConvertTo-Json -Compress) -> $($after | ConvertTo-Json -Compress)"
        Check 'no sweep errors' (@(Get-ChildItem -Path $script:Work -File -Filter 'gateway*.out' | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_ -match '"sweep":"(failed|error)"' }).Count -eq 0)
    }
}

$BudgetScenarios['github budget: built from the rate-limit headers; below the reserve only essential verbs run, the sweep skips its extra reads; a 403 is a rate limit only when GitHub says so [full]'] = {
    Bg-WithGateway @{ FACTORY_SWEEP_SECONDS = '600'; FACTORY_SWEEP_MIN_SECONDS = '600' } {
        $n = New-Item-Fake 'Budget item' 'x' @()
        $r = Bg-Verb 'get-item' @{ item = $n }
        Check 'a verb answers as before: the rate limit it saw is not in its answer' ($r.status -eq 200 -and -not $r.body.ContainsKey('_github')) ($r.body.Keys -join ',')
        $g = (Bg-Status).github
        Check 'the budget has the core numbers GitHub sent, and is not low' ($g.low -eq $false -and $g.reserve -eq 300 -and $g.resources.core.remaining -gt 1000 -and $g.resources.core.limit -eq 1000000) ($g | ConvertTo-Json -Compress -Depth 4)
        # GitHub says 200 requests are left in this window: under the reserve of 300
        Fake 'rate' @{ resource = 'core'; remaining = 200; resetSeconds = 3650 } | Out-Null   # (a later window than the one at start: GitHub's windows only move forward)
        $r = Bg-Verb 'get-item' @{ item = $n }
        Check 'the call that saw it still ran' ($r.status -eq 200) "$($r.status)"
        $g = (Bg-Status).github
        Check 'now the budget is low, with the reset time' ($g.low -eq $true -and $g.lowResource -eq 'core' -and $g.resources.core.remaining -lt 300 -and $g.resetAt) ($g | ConvertTo-Json -Compress -Depth 4)
        $r = Bg-Verb 'get-item' @{ item = $n }
        Check 'an ordinary verb is answered 503, exit 20 github-budget, with retryAfterSeconds and resetAt' ($r.status -eq 503 -and $r.body.code -eq 'github-budget' -and $r.body.exit -eq 20 -and $r.body.retryAfterSeconds -gt 60 -and $r.body.resetAt) ($r.body | ConvertTo-Json -Compress)
        $r = Bg-Verb 'my-items' @{ holder = 'nobody' }
        Check 'an essential verb still runs' ($r.status -eq 200 -and $r.body.ok -eq $true) ($r.body | ConvertTo-Json -Compress)
        $before = (Bg-Status).sweep.lowBudgetSweeps
        $w = New-Item-Fake 'Budget sweep item' 'x' $OwnerLabels
        [void](Bg-Labeled $w)
        Check 'the sweep still runs on a low budget, without its extra reads' (Wait-Until -Seconds 20 { (Bg-Status).sweep.lowBudgetSweeps -gt $before }) ((Bg-Status).sweep | ConvertTo-Json -Compress)
        Check 'the refusals are counted' ((Bg-Status).github.verbRefusals -ge 1)
        # a new window: the budget is full again once a call reports it
        Fake 'rate' @{ resource = 'core'; remaining = 1000000; resetSeconds = 3700 } | Out-Null
        [void](Bg-Verb 'my-items' @{ holder = 'nobody' })
        $r = Bg-Verb 'get-item' @{ item = $n }
        Check 'a new window ends the low budget' ((Bg-Status).github.low -eq $false -and $r.status -eq 200) ((Bg-Status).github | ConvertTo-Json -Compress -Depth 4)
        # how a refusal of GitHub is read (the rule script alone, so the gateway's own calls see none of it)
        Fake 'fault' @{ match = "^GET \S*/issues/$n/comments"; status = 403; count = 1; body = '{"message":"Resource not accessible by integration"}' } | Out-Null
        $f = Qc-Server 'get-item' @{ item = $n }
        Check 'a 403 of permission: exit 30 github-forbidden with what GitHub said' ($f.exit -eq 30 -and $f.code -eq 'github-forbidden' -and "$($f.reason)" -match 'not accessible by integration') ($f | ConvertTo-Json -Compress)
        Fake 'fault' @{ match = "^GET \S*/issues/$n/comments"; status = 403; count = 1; body = '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}' } | Out-Null
        $f = Qc-Server 'get-item' @{ item = $n }
        Check 'a 403 of a secondary rate limit: exit 20 github-rate-limited' ($f.exit -eq 20 -and $f.code -eq 'github-rate-limited' -and $f.retryAfterSeconds -gt 0) ($f | ConvertTo-Json -Compress)
        Fake 'rate' @{ resource = 'core'; remaining = 0; resetSeconds = 120 } | Out-Null
        $f = Qc-Server 'get-item' @{ item = $n }
        Fake 'rate' @{ resource = 'core'; remaining = 1000000; resetSeconds = 3800 } | Out-Null
        Check 'nothing left (x-ratelimit-remaining 0): exit 20 github-rate-limited, retry after the reset, with resetAt' ($f.exit -eq 20 -and $f.code -eq 'github-rate-limited' -and $f.retryAfterSeconds -gt 60 -and $f.retryAfterSeconds -le 120 -and $f.resetAt) ($f | ConvertTo-Json -Compress)
        Fake 'rate' @{ resource = 'graphql'; remaining = 0; resetSeconds = 120 } | Out-Null
        $f = Qc-Server 'get-item' @{ item = $n }
        Fake 'rate' @{ resource = 'graphql'; remaining = 1000000; resetSeconds = 3800 } | Out-Null
        Check 'GraphQL out of points (200 with RATE_LIMITED): exit 20 github-rate-limited' ($f.exit -eq 20 -and $f.code -eq 'github-rate-limited') ($f | ConvertTo-Json -Compress)
        Check 'the rule script reports what GitHub said in _github, for the gateway' ($f.ContainsKey('_github') -and $f._github.ContainsKey('graphql')) ($f | ConvertTo-Json -Compress -Depth 4)
    }
}

foreach ($k in $BudgetScenarios.Keys) { $OwnerScenarios[$k] = $BudgetScenarios[$k] }
