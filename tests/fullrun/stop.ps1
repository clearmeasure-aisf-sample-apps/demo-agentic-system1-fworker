#!/usr/bin/env pwsh
# Stops the gateway and the worker launcher left running by run.ps1.
$f = Join-Path $HOME '.local/share/factory-worker/fullrun-services.json'
if (-not (Test-Path $f)) { 'nothing recorded'; return }
$s = Get-Content -Raw $f | ConvertFrom-Json
foreach ($id in $s.gatewayPid, $s.subscribePid) { try { Stop-Process -Id $id -Force -ErrorAction Stop; "stopped $id" } catch { "$id was not running" } }
Remove-Item $f
