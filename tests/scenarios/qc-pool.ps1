# Tier 1 scenarios for the rule-script worker pool (runner.pool, gateway/RunnerPool.cs, plugin/scripts/runner-host.ps1). They run in the qc suite,
# whose gateway has the pool on. Scenario names start with "qc: runner pool"; run them alone with -Suite qc -Only 'runner pool'.

function Pool-Entry { Join-Path $script:Root 'plugin/scripts/factory.ps1' }
# One rule-script call as the gateway makes it without a pool: its own pwsh process.
function Pool-Process([string]$Verb, [string]$Body) {
    $errFile = Join-Path $script:Work "pool-err-$([guid]::NewGuid().ToString('N').Substring(0,6)).txt"
    $o = $Body | & pwsh -NoProfile -NonInteractive -File (Pool-Entry) --server $Verb 2>$errFile
    $code = $LASTEXITCODE
    $e = if (Test-Path $errFile) { "$(Get-Content -Raw $errFile)" } else { '' }
    return @{ code = $code; out = (($o | ForEach-Object { "$_" }) -join "`n").Trim(); err = $e.Trim() }
}
# A JSON object as text with its keys in order: two runs of the same script print the same object with the keys in a different order
# (a hashtable's order differs from process to process), so stdout is compared in this form.
function Pool-Canon([string]$Json) {
    function Sort-Node($v) {
        if ($v -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in ($v.Keys | Sort-Object { "$_" })) { $o["$k"] = Sort-Node $v[$k] }; return $o }
        if ($v -is [System.Collections.IList]) { return , @($v | ForEach-Object { Sort-Node $_ }) }
        return $v
    }
    # _github is what GitHub said of the rate limit during the call (issue 92): it differs from call to call and the gateway takes it out of every answer
    try { $h0 = $Json | ConvertFrom-Json -AsHashtable -DateKind String; if ($h0 -is [System.Collections.IDictionary]) { $h0.Remove('_github') }; return ((Sort-Node $h0) | ConvertTo-Json -Depth 20 -Compress) } catch { return "not json: $Json" }
}
function Pool-Size { $c = Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable; if ($c.ContainsKey('runner') -and $c.runner.ContainsKey('pool')) { return [int]$c.runner.pool }; return 0 }
# The pool workers of this suite's gateway: its child processes that run the runner host.
function Pool-Pids { , @(& pgrep -P $script:Procs[1].Id -f 'runner-host[.]ps1' | ForEach-Object { [int]$_ }) }
# A second gateway of this suite (same fake GitHub, same configuration and secrets) on spare ports of the slot, with its own state directory and
# its own environment; it sweeps once, three seconds after its start, and then not again. Its logs are pool-<tag>.out/.err.
function Pool-StartGateway([int]$PortOffset, [hashtable]$Env) {
    $dll = Join-Path $script:Root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'; $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $port = $script:PortBase + $PortOffset
    $all = @{ FACTORY_API_PORT = "$port"; FACTORY_WEBHOOK_PORT = "$($port + 1)"; FACTORY_STATE_DIR = (Join-Path $script:Work "pool-state-$tag"); FACTORY_SWEEP_SECONDS = '3600' }
    foreach ($k in $Env.Keys) { $all[$k] = $Env[$k] }
    $saved = @{}; foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
    try { $p = Start-Process dotnet -ArgumentList $dll -PassThru -RedirectStandardOutput (Join-Path $script:Work "pool-$tag.out") -RedirectStandardError (Join-Path $script:Work "pool-$tag.err") }
    finally { foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $script:Procs += $p
    $g = @{ proc = $p; base = "http://127.0.0.1:$port" }
    # up, and its one sweep done
    [void](Wait-Until -Seconds 40 { try { "$((Invoke-RestMethod "$($g.base)/api/v1/status" -Headers @{ Authorization = 'Bearer test-token' } -TimeoutSec 2).lastSweep)" -ne '' } catch { $false } })
    return $g
}
function Pool-StopGateway($g) { try { Stop-Process -Id $g.proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
function Pool-PidsOf($g) { , @(& pgrep -P $g.proc.Id -f 'runner-host[.]ps1' | ForEach-Object { [int]$_ }) }
# One verb call over HTTP with the operator token, as the client makes it.
function Pool-Verb([string]$Base, [string]$Verb, [string]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri "$Base/api/v1/verbs/$Verb" -Method POST -Body $Body -ContentType 'application/json' -Headers @{ Authorization = 'Bearer test-token' } -SkipHttpErrorCheck -TimeoutSec 120
    return @{ status = [int]$r.StatusCode; body = "$($r.Content)".Trim(); seconds = $sw.Elapsed.TotalSeconds }
}

# Returns just after a sweep has finished: the next one starts at least two seconds later, so a worker killed now is not in the middle of a sweep
# (a sweep that loses its worker is a failed sweep, as with a killed process, and the suite's invariant forbids one in the gateway log).
function Pool-QuietMoment {
    $h = @{ Authorization = 'Bearer test-token' }; $u = "http://127.0.0.1:$($script:ApiPort)/api/v1/status"
    $last = "$((Invoke-RestMethod $u -Headers $h).lastSweep)"; $end = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $end) { Start-Sleep -Milliseconds 100; if ("$((Invoke-RestMethod $u -Headers $h).lastSweep)" -ne $last) { return } }
}

$QcPoolScenarios = [ordered]@{

'qc: runner pool a pooled call returns the exit code, stdout and stderr of a process call' = {
    $n = New-Item-Fake 'Pool trial' 'x' $QcLabels
    $h = Start-RunnerHost (Pool-Entry)
    try {
        $cases = @(
            @{ name = 'success (get-item)'; verb = 'get-item'; body = (@{ item = $n } | ConvertTo-Json -Compress); exit = 0 }
            @{ name = 'refusal (unknown verb)'; verb = 'no-such-verb'; body = '{}'; exit = 2 }
            @{ name = 'refusal (usage: no item)'; verb = 'get-item'; body = '{}'; exit = -1 }
        )
        foreach ($c in $cases) {
            # the two calls are made one after the other, and the plant may write a comment on the item in between: asked again (at most 5 times) until both saw the same item
            foreach ($try in 1..5) {
                $p = Pool-Process $c.verb $c.body
                $r = Invoke-RunnerHost $h @('--server', $c.verb) "$($c.body)`n"   # the pipeline ends the process's stdin with a line end
                if ($null -eq $r -or (Pool-Canon "$($r.out)") -ceq (Pool-Canon $p.out)) { break }
                Start-Sleep -Seconds 1
            }
            Check "$($c.name): the pooled call answered" ($null -ne $r)
            if ($null -eq $r) { continue }
            if ($c.exit -ge 0) { Check "$($c.name): the process call exits $($c.exit)" ($p.code -eq $c.exit) "$($p.code) $($p.out)" } else { Check "$($c.name): the process call is refused" ($p.code -ne 0 -and $p.out -match '"ok":false') "$($p.code) $($p.out)" }
            Check "$($c.name): same exit code" ([int]$r.code -eq $p.code) "pooled $($r.code), process $($p.code)"
            Check "$($c.name): same stdout (one JSON line, compared with its keys in order)" (@("$($r.out)".Trim() -split "`n").Count -eq 1 -and @($p.out -split "`n").Count -eq 1 -and (Pool-Canon "$($r.out)") -ceq (Pool-Canon $p.out)) "pooled [$("$($r.out)".Trim())] process [$($p.out)]"
            Check "$($c.name): same stderr" ("$($r.err)".Trim() -ceq $p.err) "pooled [$("$($r.err)".Trim())] process [$($p.err)]"
        }
        # an internal error writes to stderr: same code and stdout, and the same first stderr line (the script stack below it names the caller, which differs)
        $p = Pool-Process 'get-item' '{'
        $r = Invoke-RunnerHost $h @('--server', 'get-item') "{`n"
        Check 'internal error: exit 20 from both' ($null -ne $r -and $p.code -eq 20 -and [int]$r.code -eq 20) "process $($p.code)"
        Check 'internal error: same stdout' ($null -ne $r -and (Pool-Canon "$($r.out)") -ceq (Pool-Canon $p.out)) "pooled [$(if ($r) { "$($r.out)".Trim() })] process [$($p.out)]"
        $l1 = @($p.err -split "`n")[0].Trim(); $l2 = if ($r) { @("$($r.err)".Trim() -split "`n")[0].Trim() } else { '' }
        Check 'internal error: stderr is not empty and its first line is the same' ($l1 -ne '' -and $l1 -ceq $l2) "pooled [$l2] process [$l1]"
    } finally { Stop-RunnerHost $h }
}

'qc: runner pool no state of a call reaches the next call' = {
    # a script that leaves everything behind it can: environment, a global and a script variable, the location, the process directory, and an exit code
    $probe = TmpFile 'pool-probe.ps1' @'
$raw = [Console]::In.ReadToEnd()
$g = Get-Variable -Scope Global -Name poolLeak -ErrorAction SilentlyContinue
[Console]::Out.WriteLine((@{ probe = "$env:POOL_PROBE"; leak = "$env:POOL_LEAK"; global = [bool]$g; fn = [bool](Get-Command Pool-LeakFn -ErrorAction SilentlyContinue); cwd = "$(Get-Location)"; dir = [Environment]::CurrentDirectory; stdin = $raw; args = @($args) } | ConvertTo-Json -Compress))
$env:POOL_LEAK = 'left behind'; $env:POOL_PROBE = 'overwritten'; $global:poolLeak = 1; $script:poolLeak2 = 2
function global:Pool-LeakFn { }
Set-Location /; [Environment]::CurrentDirectory = '/'
exit ([int]$args[0])
'@
    $h = Start-RunnerHost $probe
    try {
        $e1 = Get-ProcessEnv; $e1.POOL_PROBE = 'one'
        $e2 = Get-ProcessEnv; $e2.POOL_PROBE = 'two'
        $r1 = Invoke-RunnerHost $h @('7') 'in-1' $e1 $script:Work
        $r2 = Invoke-RunnerHost $h @('9') 'in-2' $e2 $script:Work
        $r3 = Invoke-RunnerHost $h @('0') '' $null $null
        Check 'three calls answered' ($null -ne $r1 -and $null -ne $r2 -and $null -ne $r3)
        if ($null -ne $r1 -and $null -ne $r2 -and $null -ne $r3) {
            $o1 = $r1.out | ConvertFrom-Json -AsHashtable; $o2 = $r2.out | ConvertFrom-Json -AsHashtable; $o3 = $r3.out | ConvertFrom-Json -AsHashtable
            Check "exit N becomes the call's code (7, 9, 0)" ([int]$r1.code -eq 7 -and [int]$r2.code -eq 9 -and [int]$r3.code -eq 0) "$($r1.code) $($r2.code) $($r3.code)"
            Check 'each call sees its own environment, stdin and arguments' ($o1.probe -eq 'one' -and $o2.probe -eq 'two' -and $o1.stdin -eq 'in-1' -and $o2.stdin -eq 'in-2' -and "$($o2.args)" -eq '9') "$($r1.out) $($r2.out)"
            Check 'an environment variable set by a call is gone in the next' ($o2.leak -eq '' -and $o3.leak -eq '') "$($r2.out) $($r3.out)"
            Check 'a call without an environment sees the host own one, not the previous call one' ($o3.probe -eq '') "$($r3.out)"
            Check 'globals and functions of a call are gone in the next' (-not $o2.global -and -not $o2.fn -and -not $o3.global -and -not $o3.fn) "$($r2.out)"
            Check 'the location and the process directory are put back' ($o2.cwd -eq $script:Work -and $o2.dir -eq $script:Work -and $o3.cwd -ne '/' -and $o3.dir -ne '/') "$($r2.out) $($r3.out)"
        }
    } finally { Stop-RunnerHost $h }
    # the rule script itself: the configuration it caches in $script:Cfg must not answer for a call with another FACTORY_CONFIG
    $n = New-Item-Fake 'Pool leak trial' 'x' $QcLabels
    $body = (@{ item = $n } | ConvertTo-Json -Compress)
    $h = Start-RunnerHost (Pool-Entry)
    try {
        $bad = Get-ProcessEnv; $bad.FACTORY_CONFIG = (Join-Path $script:Work 'no-such-config.json')
        $a = Invoke-RunnerHost $h @('--server', 'get-item') $body
        $b = Invoke-RunnerHost $h @('--server', 'get-item') $body $bad
        $c = Invoke-RunnerHost $h @('--server', 'get-item') $body
        Check 'get-item succeeds, is refused with another configuration (config-missing, exit 30), succeeds again' ($null -ne $a -and $null -ne $b -and $null -ne $c -and [int]$a.code -eq 0 -and [int]$b.code -eq 30 -and "$($b.out)" -match 'config-missing' -and [int]$c.code -eq 0) "$(if ($a) { $a.code }) $(if ($b) { "$($b.code) $($b.out)" }) $(if ($c) { $c.code })"
        Check 'the first and the third answer name the same item' ($null -ne $a -and $null -ne $c -and ($a.out | ConvertFrom-Json -AsHashtable).id -eq $n -and ($c.out | ConvertFrom-Json -AsHashtable).id -eq $n)
    } finally { Stop-RunnerHost $h }
}

'qc: runner pool a killed worker is replaced and calls keep working' = {
    $size = Pool-Size
    Check 'the qc suite runs its gateway with runner.pool on' ($size -gt 0) "$size"
    if ($size -le 0) { return }
    $n = New-Item-Fake 'Pool kill trial' 'x' $QcLabels
    $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Technical Design'); CheckExit 'a call through the pooled gateway' $r 0
    Check "the gateway has $size pool workers" (Wait-Until -Seconds 60 { (Pool-Pids).Count -eq $size }) "$((Pool-Pids) -join ',')"
    $before = Pool-Pids
    Pool-QuietMoment; Stop-Process -Id $before[0] -Force
    $r = F 'w1' @('get-item', '--item', $n); CheckExit 'a call right after one worker was killed' $r 0
    Check 'the killed worker is replaced by a new process' (Wait-Until -Seconds 60 { $now = Pool-Pids; $now.Count -eq $size -and $now -notcontains $before[0] }) "$((Pool-Pids) -join ',')"
    $mid = Pool-Pids
    Pool-QuietMoment
    foreach ($id in $mid) { try { Stop-Process -Id $id -Force } catch { } }
    $r = F 'w1' @('get-item', '--item', $n); CheckExit 'a call right after every worker was killed' $r 0
    Check 'the pool is full again, with new processes only' (Wait-Until -Seconds 60 { $now = Pool-Pids; $now.Count -eq $size -and @($now | Where-Object { $mid -contains $_ }).Count -eq 0 }) "$((Pool-Pids) -join ',')"
    $r = F 'w1' @('get-item', '--item', $n); CheckExit 'a call on the refilled pool' $r 0
    Check 'the answer names the item' ((Pv $r 'ok') -eq $true -and "$($r | ConvertTo-Json -Depth 6 -Compress)" -match "$n")
}

'qc: runner pool the gateway answers the same with and without the pool' = {
    Check 'this gateway runs with the pool' ((Pool-Size) -gt 0 -and (Wait-Until -Seconds 60 { (Pool-Pids).Count -gt 0 }))
    $n = New-Item-Fake 'Pool gateway trial' 'x' @()   # no factory label: no sweep and no plant writes on it between the two calls
    $g = Pool-StartGateway 12 @{ FACTORY_RUNNER_POOL = '0' }
    try {
        Check 'the second gateway runs one process per call (no pool workers)' ((Pool-PidsOf $g).Count -eq 0)
        $cases = @(
            @{ name = 'success (get-item)'; verb = 'get-item'; body = (@{ item = $n; holder = 'w1' } | ConvertTo-Json -Compress); status = 200 }
            @{ name = 'refusal (usage: no item)'; verb = 'get-item'; body = '{"holder":"w1"}'; status = 400 }
            @{ name = 'refusal (no such item)'; verb = 'get-item'; body = '{"item":999999,"holder":"w1"}'; status = 0 }
        )
        foreach ($c in $cases) {
            $a = Pool-Verb (Get-GatewayBase) $c.verb $c.body; $b = Pool-Verb $g.base $c.verb $c.body
            if ($c.status) { Check "$($c.name): HTTP $($c.status) without the pool" ($b.status -eq $c.status) "$($b.status) $($b.body)" } else { Check "$($c.name): refused without the pool" ($b.status -ge 400 -and $b.body -match '"ok":false') "$($b.status) $($b.body)" }
            Check "$($c.name): same HTTP status" ($a.status -eq $b.status) "pooled $($a.status), process $($b.status)"
            Check "$($c.name): same body (keys in order)" ((Pool-Canon $a.body) -ceq (Pool-Canon $b.body)) "pooled [$($a.body)] process [$($b.body)]"
        }
        Check 'the pool is still whole after these calls' ((Pool-Pids).Count -eq (Pool-Size))
    } finally { Pool-StopGateway $g }
}

'qc: runner pool a call that does not finish in time fails as a process call does, and its worker is replaced' = {
    $n = New-Item-Fake 'Pool timeout trial' 'x' @()
    $body = (@{ item = $n; holder = 'w1' } | ConvertTo-Json -Compress)
    # a gateway of its own: one worker, pooled calls capped at 4 seconds (FACTORY_RUNNER_TEST_TIMEOUT_SECONDS), no sweep after the first
    $g = Pool-StartGateway 14 @{ FACTORY_RUNNER_POOL = '1'; FACTORY_RUNNER_TEST_TIMEOUT_SECONDS = '4' }
    try {
        Check 'the gateway has its one worker' (Wait-Until -Seconds 60 { (Pool-PidsOf $g).Count -eq 1 })
        $ok = Pool-Verb $g.base 'get-item' $body; Check 'a call on the worker: 200' ($ok.status -eq 200) "$($ok.status) $($ok.body)"
        $before = (Pool-PidsOf $g)[0]
        & kill -STOP $before   # the worker hangs: it takes the request and never answers
        $t = Pool-Verb $g.base 'get-item' $body
        $want = '{"ok":false,"verb":"get-item","code":"timeout","reason":"the rule script did not finish in time","retryAfterSeconds":30,"exit":20}'   # what Runner answers when a process does not finish in time
        Check 'the call fails with HTTP 503' ($t.status -eq 503) "$($t.status) $($t.body)"
        Check 'its answer is the timeout answer of a process call, field for field' ((Pool-Canon $t.body) -ceq (Pool-Canon $want)) $t.body
        Check 'it failed at the time limit, not later' ($t.seconds -ge 3 -and $t.seconds -lt 20) "$($t.seconds)"
        Check 'the hung worker was killed' (Wait-Until -Seconds 20 { -not (Get-Process -Id $before -ErrorAction SilentlyContinue) })
        Check 'and replaced by a new one' (Wait-Until -Seconds 60 { $now = Pool-PidsOf $g; $now.Count -eq 1 -and $now[0] -ne $before }) "$((Pool-PidsOf $g) -join ',')"
        $again = Pool-Verb $g.base 'get-item' $body; Check 'the next call works: 200' ($again.status -eq 200) "$($again.status) $($again.body)"
    } finally { Pool-StopGateway $g }
}

}
