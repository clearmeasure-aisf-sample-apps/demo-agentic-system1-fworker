# Keeps a DOWNLOADED copy of the plugin equal to the gateway's: the gateway stamps /_build with a content hash of the plugin it serves, and a
# downloaded copy carries .plugin-version (the hash) and .plugin-managed (the marker). A working copy has no marker and is never touched.

function Sync-Plugin($Cfg) {
    $root = [IO.Path]::GetFullPath((Join-Path $here '..'))
    if (-not (Test-Path -LiteralPath (Join-Path $root '.plugin-managed'))) { return @{ ok = $false; code = 'not-managed'; reason = 'this plugin directory was not downloaded from a gateway (no .plugin-managed marker); it is never overwritten' } }
    $vf = Join-Path $root '.plugin-version'
    $local = try { (Get-Content -Raw -LiteralPath $vf | ConvertFrom-Json).hash } catch { '' }
    try { $b = Invoke-RestMethod -Uri "$($Cfg.url)/_build" -TimeoutSec 20 } catch { return @{ ok = $false; code = 'gateway-unreachable'; reason = $_.Exception.Message } }
    if (-not $b.PSObject.Properties['pluginHash'] -or -not $b.pluginHash) { return @{ ok = $false; code = 'gateway-old'; reason = 'the gateway does not publish a plugin hash' } }
    if ($b.pluginHash -eq $local) { return @{ ok = $true; updated = $false; hash = $local } }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "fw-plugin-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $tgz = Join-Path $tmp 'plugin.tgz'
        Invoke-WebRequest -Uri "$($Cfg.url)/api/v1/plugin" -Headers @{ Authorization = "Bearer $(Get-ConfigToken $Cfg)" } -OutFile $tgz -TimeoutSec 60 | Out-Null
        $new = Join-Path $tmp 'new'; New-Item -ItemType Directory -Force -Path $new | Out-Null
        & tar -xzf $tgz -C $new
        if ($LASTEXITCODE -ne 0) { return @{ ok = $false; code = 'extract-failed'; reason = 'tar could not extract the plugin archive' } }
        $got = try { (Get-Content -Raw -LiteralPath (Join-Path $new '.plugin-version') | ConvertFrom-Json).hash } catch { '' }
        if (-not (Test-Path -LiteralPath (Join-Path $new 'scripts/factory.ps1')) -or $got -ne $b.pluginHash) { return @{ ok = $false; code = 'archive-mismatch'; reason = 'the downloaded archive is not the version the gateway announced; nothing was replaced' } }
        foreach ($d in 'scripts', 'skills', 'agents', 'hooks', '.claude-plugin') {
            $dst = Join-Path $root $d; if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            # -Force: the temp directory is often on another filesystem (a tmpfs /tmp). There a move is a copy and a removal, and without -Force
            # the removal of a hidden directory (.claude-plugin) throws after the copy, before the version stamp is written.
            $src = Join-Path $new $d; if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force }
        }
        Copy-Item -LiteralPath (Join-Path $new '.plugin-version') -Destination $vf -Force
        return @{ ok = $true; updated = $true; from = $local; to = $got; restart_needed = $true }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# factory.ps1 plugin-sync: exit 0 (current or updated), 10 not-managed, 20 gateway unreachable or old, 21 never.
function Invoke-PluginSync($Cfg) {
    $r = Sync-Plugin $Cfg
    $code = if ($r.ok) { 0 } elseif ($r.code -eq 'not-managed') { 10 } else { 20 }
    Write-Out $r $code
}
