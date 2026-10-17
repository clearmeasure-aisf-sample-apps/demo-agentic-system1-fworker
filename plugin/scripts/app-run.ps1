#!/usr/bin/env pwsh
# app-run.ps1 <check|start|probe|stop> [...]   Runs a built .NET web application and looks at it, on Linux, macOS and Windows, with no shell tools.
#   check --dotnet D --project P [--port 5199] [--paths "/,/other"] [--wait 90] [--log F] [--configuration Release]
#         starts `dotnet run --no-build --no-launch-profile -c Release --project P --urls http://localhost:PORT`, waits for /_healthcheck, fetches each path, stops the whole
#         process tree. One call; prints one JSON line: health status and, per path, the status code and the first 4000 characters of text.
#   start --dotnet D --project P [--port 5199] [--log F]    starts it detached; prints {pid, url}
#   probe --url U                                           one GET; prints {status, text}
#   stop  --pid N                                           stops the process tree
# Exit 0 ok, 2 usage, 20 the application did not become healthy.
$Rest = [string[]]$args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Out([hashtable]$o, [int]$code) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 6)); exit $code }
$verb = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
$f = @{}
for ($i = 1; $i -lt $Rest.Count; $i++) { if ($Rest[$i] -like '--*' -and $i + 1 -lt $Rest.Count) { $f[$Rest[$i].Substring(2)] = $Rest[$i + 1]; $i++ } }

function Get-Page([string]$Url) {
    try { $r = Invoke-WebRequest -Uri $Url -SkipHttpErrorCheck -TimeoutSec 10 -MaximumRedirection 3; $t = "$($r.Content)"; return @{ status = [int]$r.StatusCode; text = $t.Substring(0, [Math]::Min(4000, $t.Length)) } }
    catch { return @{ status = 0; text = "$($_.Exception.Message)" } }
}
function Stop-Tree([int]$ProcId) { try { (Get-Process -Id $ProcId -ErrorAction Stop).Kill($true) } catch { } }
function Start-App {
    foreach ($k in 'dotnet', 'project') { if (-not $f.ContainsKey($k)) { Out @{ ok = $false; code = 'usage'; reason = "--$k is required" } 2 } }
    $port = if ($f.ContainsKey('port')) { $f.port } else { '5199' }
    $log = if ($f.ContainsKey('log')) { $f.log } else { Join-Path ([IO.Path]::GetTempPath()) "app-run-$port.log" }
    $p = Start-Process -FilePath $f.dotnet -ArgumentList @('run', '--no-build', '--no-launch-profile', '--configuration', $(if ($f.ContainsKey('configuration')) { $f.configuration } else { 'Release' }), '--project', $f.project, '--urls', "http://localhost:$port") -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
    return @{ pid = $p.Id; url = "http://localhost:$port"; log = $log }
}

switch ($verb) {
    'probe' { if (-not $f.ContainsKey('url')) { Out @{ ok = $false; code = 'usage'; reason = '--url is required' } 2 }; $g = Get-Page $f.url; Out @{ ok = $true; status = $g.status; text = $g.text } 0 }
    'stop' { if (-not $f.ContainsKey('pid')) { Out @{ ok = $false; code = 'usage'; reason = '--pid is required' } 2 }; Stop-Tree ([int]$f.pid); Out @{ ok = $true } 0 }
    'start' { $a = Start-App; Out @{ ok = $true; pid = $a.pid; url = $a.url; log = $a.log } 0 }
    'check' {
        $a = Start-App; $wait = if ($f.ContainsKey('wait')) { [int]$f.wait } else { 90 }
        $health = 0; $end = (Get-Date).AddSeconds($wait)
        try {
            do { Start-Sleep -Seconds 2; $health = (Get-Page "$($a.url)/_healthcheck").status; $alive = Get-Process -Id $a.pid -ErrorAction SilentlyContinue } while ($health -ne 200 -and (Get-Date) -lt $end -and $alive -and -not $alive.HasExited)
            $pages = @()
            if ($health -eq 200) { foreach ($path in @(($(if ($f.ContainsKey('paths')) { $f.paths } else { '/' })) -split ',')) { $g = Get-Page ($a.url + $path.Trim()); $pages += @{ path = $path.Trim(); status = $g.status; text = $g.text } } }
        } finally { Stop-Tree $a.pid }
        $tail = if (Test-Path -LiteralPath $a.log) { @(Get-Content -LiteralPath $a.log -Tail 15) -join "`n" } else { '' }
        if ($health -ne 200) { Out @{ ok = $false; code = 'unhealthy'; health = $health; log_tail = $tail } 20 }
        Out @{ ok = $true; health = $health; pages = $pages } 0
    }
    default { Out @{ ok = $false; code = 'usage'; reason = 'usage: app-run.ps1 check|start|probe|stop ...' } 2 }
}
