#!/usr/bin/env pwsh
# ensure-tools.ps1 dotnet --repo <checkout>
# Installs a tool on demand into the worker's data directory instead of assuming it is on the machine. Prints one JSON line.
#   dotnet   the .NET SDK the repository asks for (global.json "sdk.version"; the newest stable when there is none). When `dotnet` on the
#            PATH already satisfies it nothing is downloaded. The installer is Microsoft's dotnet-install script from https://dot.net/v1/.
# Exit 0 ok, 2 usage, 20 download failed, 30 unsupported.
$Rest = [string[]]$args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/Paths.ps1')

function Out([hashtable]$o, [int]$code) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress)); exit $code }

$tool = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
$repo = '.'
for ($i = 1; $i -lt $Rest.Count; $i++) { if ($Rest[$i] -eq '--repo' -and $i + 1 -lt $Rest.Count) { $repo = $Rest[$i + 1]; $i++ } }
if ($tool -ne 'dotnet') { Out @{ ok = $false; code = 'usage'; reason = 'usage: ensure-tools.ps1 dotnet --repo <checkout>' } 2 }

$want = $null
$gj = Join-Path $repo 'global.json'
if (Test-Path -LiteralPath $gj) { try { $want = (Get-Content -Raw -LiteralPath $gj | ConvertFrom-Json).sdk.version } catch { $want = $null } }

# 1. a dotnet on the PATH that the repository's global.json accepts: asking `dotnet --version` from inside the repository applies the
#    pin and its roll-forward policy exactly as the build will, so a newer feature band that the pin allows is used and nothing is downloaded.
function Test-Dotnet([string]$Exe) {
    try {
        Push-Location -LiteralPath $repo
        try { $out = @(& $Exe --version 2>$null); $code = $LASTEXITCODE } finally { Pop-Location }
        if ($code -eq 0 -and $out.Count -gt 0) { return "$($out[0])".Trim() }
    } catch { }
    return $null
}
$have = Get-Command dotnet -ErrorAction SilentlyContinue
if ($have) { $v = Test-Dotnet $have.Source; if ($v) { Out @{ ok = $true; dotnet = $have.Source; version = $v; installed = $false } 0 } }

# 2. a previous install of ours
$dir = Join-Path (Get-FwDataDir) 'dotnet'
$exe = Join-Path $dir $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
if (Test-Path -LiteralPath $exe) { $v = Test-Dotnet $exe; if ($v) { Out @{ ok = $true; dotnet = $exe; version = $v; installed = $false } 0 } }

# 3. install with Microsoft's script
$tmp = Join-Path ([IO.Path]::GetTempPath()) "dotnet-install-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    if ($IsWindows) {
        $s = Join-Path $tmp 'dotnet-install.ps1'
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $s -TimeoutSec 60
        $ia = @('-InstallDir', $dir); if ($want) { $ia += @('-Version', $want) } else { $ia += @('-Channel', 'LTS') }
        & (Get-Process -Id $PID).Path -NoProfile -File $s @ia | Out-Null
    } else {
        $s = Join-Path $tmp 'dotnet-install.sh'
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.sh' -OutFile $s -TimeoutSec 60
        $ia = @('--install-dir', $dir); if ($want) { $ia += @('--version', $want) } else { $ia += @('--channel', 'LTS') }
        & bash $s @ia | Out-Null
    }
} catch { Out @{ ok = $false; code = 'download-failed'; reason = "$($_.Exception.Message)" } 20 }
finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
if (-not (Test-Path -LiteralPath $exe)) { Out @{ ok = $false; code = 'install-failed'; reason = 'the installer finished but no dotnet was installed' } 20 }
$v = Test-Dotnet $exe
Out @{ ok = $true; dotnet = $exe; version = $(if ($v) { $v } else { '' }); installed = $true } 0
