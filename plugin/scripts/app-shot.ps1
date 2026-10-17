#!/usr/bin/env pwsh
# app-shot.ps1 shots --repo <worktree> --dotnet <dotnet> [--paths "/,/login"] [--login <user>] [--out <dir>] [--port 5174] [--video]
#   Builds the UI server of <worktree>, seeds a SQLite database with the repository's own demo data loader, starts the application on it,
#   takes one screenshot per path (logging in first when --login is given), optionally records a video, stops the application.
#   Needs only: the .NET SDK (ensure-tools.ps1 dotnet), network access to nuget.org and the Playwright CDN. Nothing else is assumed.
#   Prints one JSON line {ok, app:{health}, shots:[{path,file,status,title,text}], video}. Exit 0 ok, 2 usage, 20 failed (reason in the JSON).
#   --probe-file <json>: a JSON array of {method, path, body, contentType} calls made against the running application (for an API route,
#   a POST for example); each answer ({method,path,status,body}) is in `probes`. Quote nothing on the command line: put the calls in the file.
# app-shot.ps1 prepare --repo <worktree> --dotnet <dotnet>   only builds, seeds and installs the browser (the slow, one-time part)
$Rest = [string[]]$args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Paths.ps1')
function Out([hashtable]$o, [int]$code) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 8)); exit $code }
$verb = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
$f = @{}
for ($i = 1; $i -lt $Rest.Count; $i++) { if ($Rest[$i] -like '--*') { $k = $Rest[$i].Substring(2); if ($i + 1 -lt $Rest.Count -and $Rest[$i + 1] -notlike '--*') { $f[$k] = $Rest[$i + 1]; $i++ } else { $f[$k] = 'true' } } }
if ($verb -notin 'shots', 'prepare' -or -not $f.ContainsKey('repo') -or -not $f.ContainsKey('dotnet')) { Out @{ ok = $false; code = 'usage'; reason = 'usage: app-shot.ps1 shots|prepare --repo <worktree> --dotnet <dotnet> [--paths "/,/x"] [--login user] [--out dir] [--port N] [--video]' } 2 }
$repo = (Resolve-Path -LiteralPath $f.repo).Path; $dotnet = $f.dotnet
$port = if ($f.ContainsKey('port')) { $f.port } else { '5174' }
$work = Join-Path (Get-FwDataDir) 'app-shot'; New-Item -ItemType Directory -Force -Path $work | Out-Null
$db = Join-Path $work 'app.db'
$outDir = if ($f.ContainsKey('out')) { $f.out } else { Join-Path $work 'out' }; New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Run([string]$Exe, [string[]]$A, [string]$Cwd, [int]$TimeoutSeconds = 900) {
    $log = Join-Path $work "$([IO.Path]::GetFileName($Exe))-$([guid]::NewGuid().ToString('N').Substring(0,6)).log"
    $p = Start-Process -FilePath $Exe -ArgumentList $A -WorkingDirectory $Cwd -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill($true) } catch { }; return @{ code = -1; tail = 'timed out' } }
    $t = @(Get-Content -LiteralPath $log -Tail 8; Get-Content -LiteralPath "$log.err" -Tail 8 -ErrorAction SilentlyContinue) -join "`n"
    return @{ code = $p.ExitCode; tail = $t }
}
$env:DOTNET_NOLOGO = '1'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = '1'
$bflags = @('-c', 'Release', '--nologo', '-v', 'q', '-nodeReuse:false', '-p:UseSharedCompilation=false')

# 1. the application and its demo data (the repository's own loader test creates the schema and seeds employees and work orders)
$r = Run $dotnet (@('build', 'src/UI/Server') + $bflags) $repo
if ($r.code -ne 0) { Out @{ ok = $false; code = 'build-failed'; reason = 'the UI server did not build'; tail = $r.tail } 20 }
if (-not (Test-Path -LiteralPath $db)) {
    $env:ConnectionStrings__SqlConnectionString = "Data Source=$db"
    $r = Run $dotnet (@('test', 'src/IntegrationTests', '--filter', 'FullyQualifiedName~ZDataLoader') + $bflags) $repo
    if ($r.code -ne 0 -or -not (Test-Path -LiteralPath $db)) { Out @{ ok = $false; code = 'seed-failed'; reason = 'the demo data loader did not create the database'; tail = $r.tail } 20 }
}
# 2. the screenshot tool, built from the plugin's source into the data directory (the plugin directory itself is never written to)
$src = Join-Path $work 'shot-src'; $bin = Join-Path $work 'shot-bin'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'Shot.dll'))) {
    Copy-Item -Recurse -Force -LiteralPath (Join-Path $PSScriptRoot '../tools/shot') -Destination $src
    $r = Run $dotnet @('build', $src, '-c', 'Release', '--nologo', '-v', 'q', '-o', $bin, '-nodeReuse:false') $work
    if ($r.code -ne 0) { Out @{ ok = $false; code = 'shot-build-failed'; reason = 'the screenshot tool did not build (needs nuget.org)'; tail = $r.tail } 20 }
    $r = Run $dotnet @((Join-Path $bin 'Shot.dll'), 'install') $work 1200
    if ($r.code -ne 0) { Remove-Item -Recurse -Force -LiteralPath $bin -ErrorAction SilentlyContinue; Out @{ ok = $false; code = 'browser-install-failed'; reason = 'Chromium did not install (needs the Playwright CDN and the usual Linux libraries)'; tail = $r.tail } 20 }
}
if ($verb -eq 'prepare') { Out @{ ok = $true; prepared = $true; db = $db } 0 }

# 3. start, shoot, stop
$env:ASPNETCORE_ENVIRONMENT = 'Development'; $env:ConnectionStrings__SqlConnectionString = "Data Source=$db"; $env:ApiKeyAuthentication__Enabled = 'false'
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=00000000-0000-0000-0000-000000000000'
$me = (Get-Process -Id $PID).Path
$app = (@(& $me -NoProfile -File (Join-Path $PSScriptRoot 'app-run.ps1') start --dotnet $dotnet --project (Join-Path $repo 'src/UI/Server') --port $port --log (Join-Path $work 'app.log')) | Select-Object -Last 1) | ConvertFrom-Json
try {
    $health = 0; $end = (Get-Date).AddSeconds(120)
    do { Start-Sleep -Seconds 2; try { $health = [int](Invoke-WebRequest -Uri "$($app.url)/_healthcheck" -SkipHttpErrorCheck -TimeoutSec 5).StatusCode } catch { $health = 0 } } while ($health -ne 200 -and (Get-Date) -lt $end)
    if ($health -ne 200) { Out @{ ok = $false; code = 'unhealthy'; reason = 'the application did not become healthy'; health = $health; tail = (@(Get-Content -LiteralPath $app.log -Tail 10 -ErrorAction SilentlyContinue) -join "`n") } 20 }
    $sa = @((Join-Path $bin 'Shot.dll'), '--base', $app.url, '--out', $outDir)
    if ($f.ContainsKey('paths')) { $sa += @('--paths', $f.paths) }
    if ($f.ContainsKey('login')) { $sa += @('--login', $f.login) }
    if ($f.ContainsKey('video')) { $sa += '--video' }
    $res = & $dotnet @sa
    $j = $res | Select-Object -Last 1 | ConvertFrom-Json
    $probes = @()
    if ($f.ContainsKey('probe-file')) {
        foreach ($c in @(Get-Content -Raw -LiteralPath $f['probe-file'] | ConvertFrom-Json)) {
            $m = if ($c.PSObject.Properties['method']) { "$($c.method)" } else { 'GET' }
            $ct = if ($c.PSObject.Properties['contentType']) { "$($c.contentType)" } else { 'application/json' }
            $ia = @{ Uri = "$($app.url)$($c.path)"; Method = $m; SkipHttpErrorCheck = $true; TimeoutSec = 30 }
            if ($c.PSObject.Properties['body']) { $ia.Body = "$($c.body)"; $ia.ContentType = $ct }
            try { $r2 = Invoke-WebRequest @ia; $t = "$($r2.Content)"; $probes += @{ method = $m; path = "$($c.path)"; status = [int]$r2.StatusCode; body = $t.Substring(0, [Math]::Min(800, $t.Length)) } }
            catch { $probes += @{ method = $m; path = "$($c.path)"; status = 0; body = "$($_.Exception.Message)" } }
        }
    }
    $j | Add-Member -NotePropertyName probes -NotePropertyValue $probes -Force
    $j | Add-Member -NotePropertyName app -NotePropertyValue @{ health = $health; url = $app.url } -Force
    [Console]::Out.WriteLine(($j | ConvertTo-Json -Compress -Depth 8)); exit $(if ($j.ok) { 0 } else { 20 })
} finally { if ($app -and $app.pid) { & $me -NoProfile -File (Join-Path $PSScriptRoot 'app-run.ps1') stop --pid $app.pid | Out-Null } }
