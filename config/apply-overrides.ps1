#!/usr/bin/env pwsh
# Writes the configuration of the container image: config/instance.json (the source defaults the tests run on) with
# config/deploy.overrides.json merged over it. The Dockerfile runs this while the image is built; nothing else changes the configuration
# between the repository and a deployed gateway.
# usage: pwsh config/apply-overrides.ps1 -Base config/instance.json -Overrides config/deploy.overrides.json -Out <file>
#   Objects are merged key by key; a value or an array replaces the one in the base. A key the base does not have is refused (exit 1): an
#   override may only change a setting that exists, so a misspelt name fails the image build and never ships as a silent no-op. The one
#   exceptions are runtimes.environments and api.cursor.environments: their keys are environment names (tdd, uat, prod), each a whole
#   block, added as written.
param([Parameter(Mandatory)] [string] $Base, [Parameter(Mandatory)] [string] $Overrides, [Parameter(Mandatory)] [string] $Out)
$ErrorActionPreference = 'Stop'
function Read-Json([string]$Path) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path) | ConvertFrom-Json -AsHashtable -DateKind String }
function Merge-Into($Target, $Source, [string]$Where) {
    foreach ($k in @($Source.Keys)) {
        if ($Where -in 'runtimes.environments.', 'api.cursor.environments.') { $Target[$k] = $Source[$k]; continue }
        if (-not $Target.Contains($k)) { throw "deploy override '$Where$k' names no setting of the base configuration" }
        if ($Source[$k] -is [Collections.IDictionary]) {
            if ($Target[$k] -isnot [Collections.IDictionary]) { throw "deploy override '$Where$k' is an object, the base setting is not" }
            Merge-Into $Target[$k] $Source[$k] "$Where$k."
        } else { $Target[$k] = $Source[$k] }
    }
}
$cfg = Read-Json $Base
Merge-Into $cfg (Read-Json $Overrides) ''
[IO.File]::WriteAllText($Out, (($cfg | ConvertTo-Json -Depth 64) + "`n"))
Write-Host "wrote $Out (base $Base, overrides $Overrides)"
