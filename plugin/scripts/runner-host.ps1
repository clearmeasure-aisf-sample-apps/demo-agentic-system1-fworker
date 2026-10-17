#!/usr/bin/env pwsh
# runner-host.ps1 <script> <mark>
# A long-lived host that runs <script> once per request, without a new pwsh process per call. The gateway keeps a pool of these when runner.pool > 0
# (gateway/RunnerPool.cs); the scenario tests use one for their client calls (tests/scenarios/lib.ps1).
#
# Protocol, one line each way, UTF-8:
#   request   {"id":"...","args":[...],"stdin":"...","env":{...}|null,"cwd":"..."|null}
#   response  <mark> {"id":"...","code":N,"out":"...","err":"..."}   (first line after start: <mark> {"ready":true}); "id" repeats the request's
# A line on this process's stdout that does not start with <mark>, or a response with another id, is not the answer to a call: the gateway ends the host.
#
# Isolation per call: a new runspace (no variables, functions or $script: state survive), [Console] In/Out/Error replaced by the call's own,
# the environment and the current directory put back afterwards, 'exit N' becomes "code". Nothing of a request is logged or kept.
# What is NOT isolated: static .NET state of the process, and anything a call leaves on disk. A call that hangs is ended by the caller, which kills
# this process. End of input ends the host.
$ErrorActionPreference = 'Stop'
$target = [string]$args[0]; $mark = [string]$args[1]
if (-not $target -or -not $mark -or -not (Test-Path -LiteralPath $target)) { [Console]::Error.WriteLine('usage: runner-host.ps1 <script> <mark>'); exit 2 }
$utf8 = [Text.UTF8Encoding]::new($false)
$reqIn = [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
$respOut = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), $utf8); $respOut.AutoFlush = $true
$realOut = [Console]::Out; $realErr = [Console]::Error; $realIn = [Console]::In
$iss = [initialsessionstate]::CreateDefault2()
# The script runs in a child scope of the new runspace's global scope, as 'pwsh -File' runs it. What it writes to the pipeline or the other streams goes
# to the call's stdout or stderr as text.
$wrapper = @'
param($__script, $__args)
& $__script @__args 2>&1 3>&1 6>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine(($_ | Out-String).TrimEnd()) } else { [Console]::Out.WriteLine(($_ | Out-String).TrimEnd()) }
}
# 'exit N' is the call's code; a script that ends without 'exit' returns 0 even after a native command failed, as 'pwsh -File' does
if ($?) { 0 } else { $global:LASTEXITCODE }
'@

function Invoke-Call($req) {
    $envBefore = [Environment]::GetEnvironmentVariables(); $cwdBefore = [Environment]::CurrentDirectory
    $so = [IO.StringWriter]::new(); $se = [IO.StringWriter]::new(); $code = 0; $rs = $null; $ps = $null
    try {
        if ($req.ContainsKey('env') -and $null -ne $req.env) {
            foreach ($k in @($envBefore.Keys)) { if (-not $req.env.ContainsKey($k)) { [Environment]::SetEnvironmentVariable($k, $null) } }
            foreach ($k in $req.env.Keys) { if ("$($envBefore[$k])" -cne "$($req.env[$k])" -or -not $envBefore.ContainsKey($k)) { [Environment]::SetEnvironmentVariable($k, "$($req.env[$k])") } }
        }
        if ($req.ContainsKey('cwd') -and $req.cwd) { [Environment]::CurrentDirectory = "$($req.cwd)" }
        [Console]::SetIn([IO.StringReader]::new("$($req.stdin)")); [Console]::SetOut($so); [Console]::SetError($se)
        $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($wrapper).AddArgument($target).AddArgument([string[]]@($req.args))
        try {
            $res = $ps.Invoke()
            $last = if ($res.Count) { $res[$res.Count - 1] } else { $null }
            if ($null -ne $last) { $code = [int]"$last" }
        } catch {
            # a terminating error the script did not catch: 'pwsh -File' prints it and exits 1
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            $se.WriteLine($inner.Message); $code = 1
        }
    } finally {
        [Console]::SetIn($realIn); [Console]::SetOut($realOut); [Console]::SetError($realErr)
        if ($ps) { try { $ps.Dispose() } catch { } }; if ($rs) { try { $rs.Dispose() } catch { } }
        try { [Environment]::CurrentDirectory = $cwdBefore } catch { }
        $envAfter = [Environment]::GetEnvironmentVariables()
        foreach ($k in @($envAfter.Keys)) { if (-not $envBefore.ContainsKey($k)) { [Environment]::SetEnvironmentVariable($k, $null) } }
        foreach ($k in @($envBefore.Keys)) { if (-not $envAfter.ContainsKey($k) -or "$($envAfter[$k])" -cne "$($envBefore[$k])") { [Environment]::SetEnvironmentVariable($k, "$($envBefore[$k])") } }
    }
    return @{ code = $code; out = $so.ToString(); err = $se.ToString() }
}

# Warm up: parse the script and its libraries once (parsed files are cached by path and content for the life of the process) and load the modules a
# runspace needs, so the first real call does not pay for them.
try {
    foreach ($f in @($target) + @(Get-ChildItem -Path (Join-Path (Split-Path -Parent $target) 'lib') -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) { $null = (Get-Command -Name $f -CommandType ExternalScript).ScriptBlock }
    $w = [runspacefactory]::CreateRunspace($iss); $w.Open(); $p = [powershell]::Create(); $p.Runspace = $w
    $null = $p.AddScript('$null = @{ a = 1 } | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable; $null = Join-Path "a" "b"; $null = Test-Path "."').Invoke(); $p.Dispose(); $w.Dispose()
} catch { }
$respOut.WriteLine("$mark " + '{"ready":true}')

while ($null -ne ($line = $reqIn.ReadLine())) {
    if (-not $line.Trim()) { continue }
    $r = $null
    $req = $null
    try { $req = $line | ConvertFrom-Json -AsHashtable -DateKind String; $r = Invoke-Call $req }
    catch { $r = @{ code = 1; out = ''; err = "runner host: $($_.Exception.Message)" } }
    $r.id = if ($req -is [System.Collections.IDictionary] -and $req.ContainsKey('id')) { "$($req.id)" } else { '' }
    $respOut.WriteLine("$mark " + ($r | ConvertTo-Json -Compress -Depth 3))
}
exit 0
