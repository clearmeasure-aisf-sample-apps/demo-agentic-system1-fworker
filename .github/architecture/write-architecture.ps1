#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes the logical architecture of one release of an application: the process its artifact starts, the
    assemblies of its own solution that process loads, the references between them and the NuGet packages each
    references, as JSON and as a C4 diagram in PlantUML.

.DESCRIPTION
    Workflow "Architecture" of an application's repository (.github/workflows/architecture.yml, a file the kit owns
    there, like this one) runs it after every green Build of the default branch, renders the diagram and commits the
    three files to branch "architecture" as <deployable>/<version>.json, .puml and .svg. The health dashboard of the
    system zooms from the application's box into the diagram of the version that runs (the kit's decision 0041).

    What it reads. -Folder is what the artifact runs from: the files of a container image's working directory, or
    the published files of an App Service package. -Command is how the artifact starts: a container image's
    entrypoint and command, as one line. The entry assembly is the .dll that line names, or the one a
    <name>.runtimeconfig.json marks as an application when the line names none (an executable host, or no -Command
    for App Service). Its <name>.deps.json, which every .NET build writes, lists every library the application loads:
    those of type "project" are the solution's own assemblies, those of type "package" come from NuGet.

    What it writes. The entry assembly and every assembly of the solution it reaches, each with the assemblies of the
    solution it references and the packages it references directly (name and version). An artifact with no entry
    assembly (not .NET) is written with its process alone.

    The names are the application's and are text: an assembly or package name is written with letters, digits and
    . _ - only (any other character as "_"), a version also with +, each cut at its length. 60 assemblies are
    written, and 15 packages of an assembly are drawn; what is left out is counted.

.EXAMPLE
    pwsh -NoProfile -File .github/architecture/write-architecture.ps1 -Folder ./app -Command 'dotnet Ui.Server.dll' -Deployable ui -Version 1.0.42 -OutputFolder ./out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Folder,
    [Parameter(Mandatory)] [string] $Deployable,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $OutputFolder,
    # How the artifact starts ("dotnet Ui.Server.dll"); empty for an App Service package.
    [string] $Command = '',
    # What kind of artifact it is, said on the diagram: "container image" or "App Service package".
    [string] $Kind = 'container image'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function ConvertTo-PlainName {
    # A name as the files write it: letters, digits and . _ - only (-Version: also +), any other character as "_".
    param([AllowNull()] [string] $Text, [int] $Longest = 120, [switch] $Version, [switch] $Line)
    $pattern = if ($Line) { '[^A-Za-z0-9 ._/-]' } elseif ($Version) { '[^A-Za-z0-9._+-]' } else { '[^A-Za-z0-9._-]' }
    $plain = ("$Text" -replace $pattern, '_').Trim()
    if ($plain.Length -gt $Longest) { $plain.Substring(0, $Longest) } else { $plain }
}

function Find-EntryAssembly {
    # The name (without .dll) of the assembly the artifact starts, or '' when it has none. First the .dll the command
    # names; then an executable host the command names that has a .dll of its name; without a command, the one application of the
    # folder: a <name>.runtimeconfig.json with a <name>.deps.json and a <name>.dll beside it.
    param([Parameter(Mandatory)] [string] $Folder, [string] $Command = '')
    $tokens = @("$Command" -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.Trim('"', "'") })
    foreach ($token in $tokens) {
        $leaf = [IO.Path]::GetFileName($token)
        if ($leaf -match '\.dll$' -and (Test-Path -LiteralPath (Join-Path $Folder $leaf) -PathType Leaf)) { return [IO.Path]::GetFileNameWithoutExtension($leaf) }
    }
    foreach ($token in $tokens) {
        # The host has the assembly's name ("Ui.Server", or "Ui.Server.exe"): a dot in it is no file ending.
        $leaf = [IO.Path]::GetFileName($token) -replace '\.exe$', ''
        if ($leaf -and (Test-Path -LiteralPath (Join-Path $Folder "$leaf.dll") -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $Folder "$leaf.deps.json") -PathType Leaf)) { return $leaf }
    }
    # A command that names neither is another runtime's (node, python): it starts no assembly, whatever lies beside it.
    if ($tokens.Count -gt 0) { return '' }
    $applications = @(Get-ChildItem -LiteralPath $Folder -Filter '*.runtimeconfig.json' -File | ForEach-Object { $_.Name -replace '\.runtimeconfig\.json$', '' } |
            Where-Object { (Test-Path -LiteralPath (Join-Path $Folder "$_.deps.json") -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $Folder "$_.dll") -PathType Leaf) } | Sort-Object)
    if ($applications.Count -eq 1) { return $applications[0] }
    return ''
}

function Get-Architecture {
    # The architecture of one release, from the entry assembly's deps.json (parsed, as a hashtable; $null without
    # one). It asks nothing: the same input gives the same result, but for the time.
    param(
        [Parameter(Mandatory)] [string] $Deployable,
        [Parameter(Mandatory)] [string] $Version,
        [string] $Command = '',
        [string] $Kind = 'container image',
        [string] $Entry = '',
        [AllowNull()] $Dependency = $null,
        [datetime] $Generated = [datetime]::UtcNow,
        [int] $MostAssemblies = 60
    )
    $assemblies = [ordered] @{}
    $truncated = $false
    if ($Entry -and $Dependency -is [Collections.IDictionary] -and $Dependency['targets'] -is [Collections.IDictionary] -and $Dependency['libraries'] -is [Collections.IDictionary]) {
        # One target is the application's (the others are a runtime's own, in a self-contained build).
        $target = @($Dependency['targets'].Values | Where-Object { $_ -is [Collections.IDictionary] } | Sort-Object { -$_.Count } | Select-Object -First 1)
        $entries = if ($target.Count -eq 1) { $target[0] } else { @{} }
        $kindOf = @{}
        $keyOf = @{}
        foreach ($key in $Dependency['libraries'].Keys) {
            $name = ("$key" -split '/', 2)[0]
            $library = $Dependency['libraries'][$key]
            $kindOf[$name] = if ($library -is [Collections.IDictionary]) { [string] $library['type'] } else { '' }
            $keyOf[$name] = [string] $key
        }
        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($Entry)
        while ($queue.Count -gt 0) {
            $name = $queue.Dequeue()
            if ($assemblies.Contains($name)) { continue }
            if ($assemblies.Count -ge $MostAssemblies) { $truncated = $true; break }
            $listed = if ($keyOf.ContainsKey($name) -and $entries[$keyOf[$name]] -is [Collections.IDictionary] -and $entries[$keyOf[$name]]['dependencies'] -is [Collections.IDictionary]) { $entries[$keyOf[$name]]['dependencies'] } else { @{} }
            $references = @($listed.Keys | Where-Object { $kindOf["$_"] -eq 'project' } | ForEach-Object { "$_" } | Sort-Object)
            $packages = @($listed.Keys | Where-Object { $kindOf["$_"] -eq 'package' } | Sort-Object | ForEach-Object { [ordered] @{ name = ConvertTo-PlainName "$_"; version = ConvertTo-PlainName ([string] $listed[$_]) 40 -Version } })
            $assemblies[$name] = [ordered] @{ name = ConvertTo-PlainName $name; entry = ($name -eq $Entry); references = @($references | ForEach-Object { ConvertTo-PlainName $_ }); packages = $packages }
            foreach ($reference in $references) { $queue.Enqueue($reference) }
        }
    }
    $kept = @($assemblies.Values | ForEach-Object { $_.name })
    foreach ($assembly in $assemblies.Values) { $assembly.references = @($assembly.references | Where-Object { $kept -contains $_ }) }
    return [ordered] @{
        deployable = ConvertTo-PlainName $Deployable 64
        version    = ConvertTo-PlainName $Version 40 -Version
        generated  = $Generated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        kind       = ConvertTo-PlainName $Kind 40 -Line
        process    = ConvertTo-PlainName $Command 200 -Line
        entry      = if ($assemblies.Count -gt 0) { ConvertTo-PlainName $Entry } else { '' }
        assemblies = @($assemblies.Values)
        truncated  = $truncated
    }
}

function ConvertTo-ArchitectureDiagram {
    # The C4 diagram of an architecture (Get-Architecture), as PlantUML: the process, a box per assembly with the
    # packages it references, an arrow per reference. Every line of a box is one word (its spaces are no-break
    # spaces), so PlantUML writes one <text> per line. An alias is "a_<name>" with every character outside
    # A-Z a-z 0-9 as "_".
    param([Parameter(Mandatory)] [Collections.IDictionary] $Architecture, [int] $MostPackages = 15)
    $space = [string] [char] 0xA0
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('@startuml')
    # PlantUML's own layout engine: a runner need not have Graphviz, and without it PlantUML draws an error.
    $lines.Add('!pragma layout smetana')
    $lines.Add('!include <C4/C4_Component>')
    $lines.Add('HIDE_STEREOTYPE()')
    $lines.Add('skinparam wrapWidth 900')
    $lines.Add('skinparam maxMessageSize 300')
    $lines.Add('skinparam nodesep 40')
    $lines.Add('skinparam ranksep 60')
    $lines.Add('UpdateElementStyle("component", $bgColor="#eceff1", $fontColor="#1c2b33", $borderColor="#455a64")')
    $lines.Add('UpdateElementStyle("system", $bgColor="#37474f", $fontColor="#ffffff", $borderColor="#263238")')
    $process = if ($Architecture.process) { [string] $Architecture.process } elseif ($Architecture.entry) { "$($Architecture.entry).dll" } else { 'process not known' }
    $lines.Add("System(process, `"$($process -replace ' ', $space)`", `"The process the $($Architecture.kind) starts`")")
    $alias = @{}
    foreach ($assembly in @($Architecture.assemblies)) { $alias[[string] $assembly.name] = 'a_' + ([string] $assembly.name -replace '[^A-Za-z0-9]', '_') }
    if (@($Architecture.assemblies).Count -gt 0) {
        $lines.Add("Boundary(app, `"$($Architecture.deployable) $($Architecture.version)`", `"Assemblies of the application`") {")
        foreach ($assembly in @($Architecture.assemblies)) {
            $packages = @($assembly.packages)
            $text = [Collections.Generic.List[string]]::new()
            foreach ($package in @($packages | Select-Object -First $MostPackages)) { $text.Add("$($package.name) $($package.version)") }
            if ($packages.Count -gt $MostPackages) { $text.Add("and $($packages.Count - $MostPackages) more package$(if ($packages.Count - $MostPackages -ne 1) { 's' })") }
            if ($packages.Count -eq 0) { $text.Add('no NuGet package of its own') }
            $descr = @($text | ForEach-Object { $_ -replace ' ', $space }) -join '\n'
            $lines.Add("  Component($($alias[[string] $assembly.name]), `"$($assembly.name)`", `$descr=`"$descr`")")
        }
        $lines.Add('}')
        $lines.Add("Rel(process, $($alias[[string] $Architecture.entry]), `"starts`")")
        foreach ($assembly in @($Architecture.assemblies)) {
            foreach ($reference in @($assembly.references)) { $lines.Add("Rel($($alias[[string] $assembly.name]), $($alias[[string] $reference]), `"references`")") }
        }
    }
    $lines.Add('@enduml')
    return ($lines -join "`n") + "`n"
}

$entry = Find-EntryAssembly -Folder $Folder -Command $Command
$dependency = $null
if ($entry) {
    try { $dependency = Get-Content -LiteralPath (Join-Path $Folder "$entry.deps.json") -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-Host "SKIP $entry.deps.json is not read ($($_.Exception.Message)): the architecture has the process alone" }
}
else { Write-Host "SKIP no entry assembly in $Folder$(if ($Command) { " for '$Command'" }): the architecture has the process alone" }
$architecture = Get-Architecture -Deployable $Deployable -Version $Version -Command $Command -Kind $Kind -Entry $entry -Dependency $dependency
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$base = Join-Path $OutputFolder $architecture.version
[IO.File]::WriteAllText("$base.json", (($architecture | ConvertTo-Json -Depth 8) + "`n"))
[IO.File]::WriteAllText("$base.puml", (ConvertTo-ArchitectureDiagram -Architecture $architecture))
Write-Host "PASS $base.json and .puml: $(@($architecture.assemblies).Count) assembly(ies) of $($architecture.deployable) $($architecture.version)$(if ($architecture.entry) { ", entry $($architecture.entry)" })"
exit 0
