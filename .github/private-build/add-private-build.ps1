#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Takes the private build's word into the build's facts: the object "build" (command, ranBy, run) that says which
    one command built this artifact and that the integration build ran it.

.DESCRIPTION
    The kit's Release of an application runs this after it has stamped the build's facts (the kit owns this file in
    the repository, like the Release itself). The platform reads the object from the deployed application: "Private
    build" is met when every production application's facts name the command and say the integration build ran it
    (the kit's decisions 0028 and 0046).

    Where the word comes from. The private build is one command of the repository that a developer runs before a
    commit and that the integration build runs too. When that command runs in the integration build it writes
    private-build.json, { "command": "<the command as a developer types it>" }, and the Build workflow keeps the
    file as the artifact "private-build". The Release downloads that artifact of the Build run it releases and
    hands the file to this script (-Word). Nothing of the Release decides what the command is.

    What this script checks before it writes, and what it says when it does not (a SKIP line, exit code 0, the facts
    as they were, so the application reads as behind and nothing fails):
      - the Build run kept no word: the build has no private build that says so;
      - the word is no JSON object with a "command" of 1 to 200 printable characters on one line;
      - the Build workflow of this commit (-Workflow, .github/workflows/build.yml) does not run that command: the
        integration build would then have a definition of the build of its own. A run: may split the command over
        lines (continuations, a folded block): it is compared as the shell gets it.
    What it writes: "build": { "command", "ranBy": "integration", "run": <-Run, the address of the Build run> }.
    "ranBy" is "integration" because the word is an artifact of the integration build's run; the run's address is
    the Release's own knowledge, not the word's.

    The facts are a file (-FactsPath) or the entry build-facts.json at the root of a zip (-Package, an App Service
    package). A facts file that is absent or no JSON object is left alone, with a SKIP line.

    -NotesPath, instead of facts, for a release that ships the Build's image unchanged (a container in a repository
    of its own, an application with its own runtime): the facts in the image cannot change after the build, so the
    word goes into the Octopus release's notes, and the platform reads it there for an application whose facts name no
    private build (decision 0049). The same checks; then the file holds one line, "Private build, run by the
    integration build: <command>", which the release appends to its notes. Where a check fails the file is not
    written.

.EXAMPLE
    pwsh -NoProfile -File .github/private-build/add-private-build.ps1 -FactsPath built/build-facts.json -Word word/private-build.json -Run https://github.com/example-org/app/actions/runs/1

.EXAMPLE
    pwsh -NoProfile -File .github/private-build/add-private-build.ps1 -NotesPath word/notes.txt -Word word/private-build.json -Run https://github.com/example-org/app/actions/runs/1
#>
[CmdletBinding()]
param(
    [string] $FactsPath = '',
    [string] $Package = '',
    # Instead of facts: the file that gets the release notes' line (a release that ships the Build's image unchanged).
    [string] $NotesPath = '',
    # The file the Build run kept as artifact "private-build"; absent when it kept none.
    [string] $Word = '',
    [Parameter(Mandatory)] [string] $Run,
    [string] $Workflow = '.github/workflows/build.yml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Read-PrivateBuildCommand {
    # The command the word names, or why it names none.
    param([AllowNull()] [string] $Text)
    $word = try { "$Text" | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
    if ($word -isnot [Collections.IDictionary]) { return @{ Command = ''; Why = 'private-build.json is no JSON object' } }
    $command = if ($word['command'] -is [string]) { ([string] $word['command']).Trim() } else { '' }
    if ($command.Length -lt 1 -or $command.Length -gt 200 -or $command -cnotmatch '^[\x20-\x7E]+$') {
        return @{ Command = ''; Why = 'private-build.json names no "command" of 1 to 200 printable characters on one line' }
    }
    return @{ Command = $command; Why = '' }
}

function Test-WorkflowRunsCommand {
    # True when a "run:" of the Build workflow runs the command: the integration build runs what a developer runs.
    # A run's value is read as the shell gets it, in logical lines: a plain value and its continuation lines, a
    # literal block (|) line by line, a folded block (>) as one line; in every case a line that ends with a
    # continuation (\ for bash, ` for pwsh) is joined with the next. Spaces are compared as one; a shell comment
    # (#) and a YAML comment run nothing.
    param([AllowNull()] [string] $WorkflowText, [Parameter(Mandatory)] [string] $Command)
    $plain = { param([string] $Line) ($Line -replace '\s+', ' ').Trim() }
    $wanted = & $plain $Command
    $lines = @("$WorkflowText" -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $key = [regex]::Match($lines[$i], '^(\s*)(?:-\s+)?run:(?:\s+(.*))?$')
        if (-not $key.Success) { continue }
        $indent = $key.Groups[1].Length
        $value = $key.Groups[2].Value.Trim()
        # The lines of the value: those after the key that are indented further, and the blank ones between them.
        $body = [Collections.Generic.List[string]]::new()
        while ($i + 1 -lt $lines.Count -and ($lines[$i + 1] -match '^\s*$' -or ($lines[$i + 1] -replace '^(\s*).*$', '$1').Length -gt $indent)) {
            $i++
            $body.Add($lines[$i])
        }
        $physical = if ($value -match '^>[+-]?$') {
            @((@($body | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '))
        }
        elseif ($value -match '^\|[+-]?$') { @($body) }
        else {
            # A plain or quoted value: YAML folds its continuation lines into one.
            $folded = (@($value) + @($body | ForEach-Object { $_.Trim() } | Where-Object { $_ })) -join ' '
            @($folded -replace '^\s*([''"])(.*)\1\s*$', '$2')
        }
        $logical = [Collections.Generic.List[string]]::new()
        $pending = ''
        foreach ($line in $physical) {
            $part = "$line".Trim()
            # A shell comment ends at its line, a continuation character in it included.
            if (-not $pending -and $part.StartsWith('#')) { continue }
            if ($part -match '^(.*?)\s*[\\`]$') { $pending = "$pending $($Matches[1])"; continue }
            $logical.Add("$pending $part")
            $pending = ''
        }
        if ($pending) { $logical.Add($pending) }
        foreach ($line in $logical) {
            $text = & $plain $line
            if ($text -and -not $text.StartsWith('#') -and $text.Contains($wanted)) { return $true }
        }
    }
    return $false
}

function Add-BuildObject {
    # The facts with the object, as text; $null when the text is no JSON object.
    param([AllowNull()] [string] $FactsText, [Parameter(Mandatory)] [string] $Command, [Parameter(Mandatory)] [string] $Run)
    $facts = try { "$FactsText" | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
    if ($facts -isnot [Collections.IDictionary]) { return $null }
    $facts['build'] = [ordered] @{ command = $Command; ranBy = 'integration'; run = $Run }
    return ($facts | ConvertTo-Json -Depth 20) + "`n"
}

if (@($FactsPath, $Package, $NotesPath | Where-Object { $_ }).Count -ne 1) { throw 'Name one: -FactsPath <file>, -Package <zip with build-facts.json at its root>, or -NotesPath <file for the release notes'' line>.' }
if (-not $Word -or -not (Test-Path -LiteralPath $Word -PathType Leaf)) {
    Write-Host 'SKIP private build: the Build run kept no artifact "private-build", so the facts name no command (the application reads as behind on "Private build")'
    exit 0
}
$named = Read-PrivateBuildCommand -Text (Get-Content -LiteralPath $Word -Raw)
if (-not $named.Command) { Write-Host "SKIP private build: $($named.Why)"; exit 0 }
$workflowText = if (Test-Path -LiteralPath $Workflow -PathType Leaf) { Get-Content -LiteralPath $Workflow -Raw } else { '' }
if (-not (Test-WorkflowRunsCommand -WorkflowText $workflowText -Command $named.Command)) {
    Write-Host "SKIP private build: $Workflow does not run `"$($named.Command)`", the command the word names: the integration build must run the private build's command"
    exit 0
}

if ($NotesPath) {
    New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($NotesPath))) -Force | Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($NotesPath), "Private build, run by the integration build: $($named.Command)")
    Write-Host "PASS private build: the release notes say `"$($named.Command)`" built this artifact, run by the integration build ($Run)"
    exit 0
}
if ($Package) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open((Resolve-Path -LiteralPath $Package).Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('build-facts.json')
        if (-not $entry) { Write-Host "SKIP private build: $Package has no build-facts.json at its root"; exit 0 }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $before = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $after = Add-BuildObject -FactsText $before -Command $named.Command -Run $Run
        if ($null -eq $after) { Write-Host "SKIP private build: build-facts.json of $Package is no JSON object"; exit 0 }
        $entry.Delete()
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('build-facts.json').Open())
        try { $writer.Write($after) } finally { $writer.Dispose() }
    }
    finally { $zip.Dispose() }
}
else {
    if (-not (Test-Path -LiteralPath $FactsPath -PathType Leaf)) { Write-Host "SKIP private build: $FactsPath is not there (the repository writes no build facts)"; exit 0 }
    $after = Add-BuildObject -FactsText (Get-Content -LiteralPath $FactsPath -Raw) -Command $named.Command -Run $Run
    if ($null -eq $after) { Write-Host "SKIP private build: $FactsPath is no JSON object"; exit 0 }
    [IO.File]::WriteAllText((Resolve-Path -LiteralPath $FactsPath).Path, $after)
}
Write-Host "PASS private build: the facts say `"$($named.Command)`" built this artifact, run by the integration build ($Run)"
exit 0
