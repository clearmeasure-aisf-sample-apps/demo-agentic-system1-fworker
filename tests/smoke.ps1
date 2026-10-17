# No network, no secrets: parses every script and exercises the pure rule functions.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $ok) { if ($ok) { "  ok   $name" } else { "  FAIL $name"; $script:fail++ } }
"parse"
Get-ChildItem (Join-Path $root 'plugin/scripts') -Recurse -Filter *.ps1 | ForEach-Object {
    $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    Check $_.Name ($errs.Count -eq 0); $errs | ForEach-Object { "       $($_.Message) line $($_.Extent.StartLineNumber)" }
}
$env:FACTORY_CONFIG = Join-Path $root 'config/instance.json'
foreach ($f in 'Core', 'Board', 'Prs', 'Checks', 'Verbs.Item', 'Apps', 'Verbs.Pr', 'Verbs.Inspect', 'Verbs.Merge', 'Verbs.Delivery', 'Verbs.Sweep', 'Models', 'Journal', 'Owner') { . (Join-Path $root "plugin/scripts/lib/$f.ps1") }
"rules"
Check 'docs-only: docs and md only' (Test-DocsOnlyFiles @(@{filename='docs/a.md'}, @{filename='README.md'}))
Check 'docs-only: src file is code' (-not (Test-DocsOnlyFiles @(@{filename='docs/a.md'}, @{filename='src/X.cs'})))
Check 'docs-only: workflow is code' (-not (Test-DocsOnlyFiles @(@{filename='.github/workflows/build.yml'})))
foreach ($f in 'docs/x.ps1', 'docs/ci.yml', 'src/UI/README.md', '.github/pull_request_template.md', 'CLAUDE.md', 'AGENTS.md', 'sub/CLAUDE.md', '.claude/skills/x/SKILL.md', '.cursor/rules/x.md', '.cursor/commands/y.md', 'plugin/skills/x/SKILL.md', 'LICENSE.exe', 'LICENSES/x.cs') { Check "docs-only: $f is not documentation" (-not (Test-DocsOnlyFiles @(@{filename=$f}))) }
foreach ($f in 'docs/a/b.md', 'docs/diagram.svg', 'README.md', 'arch/Workflow.md', 'LICENSE', 'LICENSE.txt') { Check "docs-only: $f is documentation" (Test-DocsOnlyFiles @(@{filename=$f})) }
Check 'docs-only: empty list is not docs-only' (-not (Test-DocsOnlyFiles @()))
$fpInfo = @{ body = "Criteria:`n- The guide names the route.`n`n## Technical Design`nFiles: docs/guide.md`n<!-- aisf:docs-only -->`n- add the sentence." }
Check 'fast path: a criterion that contains double quotes is matched whole' ((Get-GroundedFindings @{ body = "- The page says `"Ready`" in bold.`n## Technical Design`n- x" } 'Technical Design' @('FINDING: criterion "The page says "Ready" in bold." - not covered')).accepted.Count -eq 1)
$mk = "x`n<!-- aisf:docs-only -->"
$legacy = '2026-10-01T00:00:00Z'
Check 'docs-only flag: the body counts only for an item created before timing.docsOnlyLegacyBefore' ((Get-LegacyCutoff) -eq [DateTime]::new(2026, 10, 16, 0, 0, 0, [DateTimeKind]::Utc) -and -not (Test-ItemDocsOnly @{} @{ column = 'Development'; body = $mk; createdAt = '2026-10-16T00:00:00Z' }) -and -not (Test-ItemDocsOnly @{} @{ column = 'Development'; body = $mk; createdAt = [DateTime]::UtcNow.AddYears(1) }) -and -not (Test-ItemDocsOnly @{} @{ column = 'Development'; body = $mk }) -and (Test-ItemDocsOnly @{} @{ column = 'Development'; body = $mk; createdAt = '2026-10-15T23:59:59Z' }))
Check 'fast path: the quote of a finding ends at the first separator when that grounds it, so a remark with quotes and a dash is not read into it' ((Get-GroundedFindings $fpInfo 'Technical Design' @('FINDING: criterion "The guide names the route." - the design says "the route" - which one?')).accepted[0].quote -eq 'The guide names the route.' -and (Get-GroundedFindings @{ body = "- The label reads `"A`" - not `"B`" in bold.`n## Technical Design`n- x" } 'Technical Design' @('FINDING: criterion "The label reads "A" - not "B" in bold." - missing')).accepted.Count -eq 1)
Check 'docs-only flag: the field decides once it exists; only a field-less state past the design column reads the body' ((Test-ItemDocsOnly @{} @{ column = 'Development'; body = $mk; createdAt = $legacy }) -and -not (Test-ItemDocsOnly @{ design = @{ docs_only = $false } } @{ column = 'Development'; body = $mk }) -and -not (Test-ItemDocsOnly @{} @{ column = 'Technical Design'; body = $mk }) -and (Test-ItemDocsOnly @{ design = @{ docs_only = $true } } @{ column = 'Development'; body = 'x' }))
$gf = Get-GroundedFindings $fpInfo 'Technical Design' @('FINDING: criterion "The guide names the route." - not covered', '- FINDING: file "docs/guide.md" - outside the scope', 'FINDING: criterion "add the sentence." - vague', 'FINDING: better wording', 'a remark')
Check 'fast path: only findings that quote the item count' ($gf.accepted.Count -eq 2 -and $gf.dropped -eq 2)
Check 'fast path: the design review of a marked item, and only that' ((Test-DocsOnlyDesignReview @{ design = @{ docs_only = $true } } 'Technical Design') -and -not (Test-DocsOnlyDesignReview @{ design = @{ docs_only = $true } } 'Development') -and -not (Test-DocsOnlyDesignReview @{ design = @{ docs_only = $false } } 'Technical Design') -and -not (Test-DocsOnlyDesignReview @{} 'Technical Design'))
$pr = [pscustomobject]@{ head = [pscustomobject]@{ ref = 'factory-worker/12-development' }; title = 'x (#12)' }
Check 'belongs: branch /12-' (Test-PrBelongs $pr 12)
$pr2 = [pscustomobject]@{ head = [pscustomobject]@{ ref = 'other/branch' }; title = 'fix #123' }
Check 'belongs: #12 does not match #123' (-not (Test-PrBelongs $pr2 12))
Check 'belongs: #123 matches' (Test-PrBelongs $pr2 123)
Check 'column order' ((Get-ColumnIndex 'Development') -eq 1 -and (Get-ColumnIndex 'Nope') -eq -1)
Check 'name in list is case-insensitive' (Test-NameIn 'FACTORY WORKER' @('factory worker'))
try { Reject 10 'x' 'y' } catch { Check 'reject carries exit and code' ($_.Exception.Exit -eq 10 -and $_.Exception.Code -eq 'x') }
$d = '{"a":"2026-10-10T21:09:32.250Z"}' | ConvertFrom-Json -AsHashtable -DateKind String
Check 'state dates stay strings through the JSON round trip (milliseconds kept)' ((ConvertTo-Iso (ConvertFrom-Iso $d.a)) -eq '2026-10-10T21:09:32.250Z')
$d2 = '{"a":"2026-10-10T21:09:32.250Z"}' | ConvertFrom-Json -AsHashtable
Check 'a DateTime from the default parser keeps its milliseconds' ((ConvertTo-Iso (ConvertFrom-Iso $d2.a)) -eq '2026-10-10T21:09:32.250Z')
Check 'iso roundtrip' ((ConvertTo-Iso (ConvertFrom-Iso '2026-10-10T12:00:00.250Z')) -eq '2026-10-10T12:00:00.250Z' -and (ConvertFrom-Iso '2026-10-10T12:00:00Z') -lt (ConvertFrom-Iso '2026-10-10T12:00:00.001Z'))
"model ladder"
Check 'tier thresholds: below, at, past' (((Get-TierFor 1 @(2,3)) -eq 0) -and ((Get-TierFor 2 @(2,3)) -eq 1) -and ((Get-TierFor 3 @(2,3)) -eq 2) -and ((Get-TierFor 99 @(2,3)) -eq 2))
$mc = Get-Content -Raw (Join-Path $root 'plugin/scripts/models.default.json') | ConvertFrom-Json -AsHashtable
$m0 = Resolve-ModelFor 'orchestrator' 0 $mc; $m1 = Resolve-ModelFor 'subagent' 1 $mc; $m2 = Resolve-ModelFor 'subagent' 2 $mc; $m9 = Resolve-ModelFor 'subagent' 9 $mc
Check 'default ladder starts on haiku 5.5 at xhigh' ($m0.model -eq 'claude-haiku-5-5' -and $m0.effort -eq 'xhigh')
Check 'tier 1 is sonnet 5.5 at medium' ($m1.model -eq 'claude-sonnet-5-5' -and $m1.effort -eq 'medium')
Check 'tier 2 is opus 5.5 at medium' ($m2.model -eq 'claude-opus-5-5' -and $m2.effort -eq 'medium')
Check 'a tier past the ladder is capped at the top rung' ($m9.model -eq 'claude-opus-5-5')
$cap = $mc | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable; $cap.subagent.maxTier = 1
Check 'a machine can cap the ladder' ((Resolve-ModelFor 'subagent' 2 $cap).model -eq 'claude-sonnet-5-5')
$st0 = $mc | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable; $st0.orchestrator.startTier = 1
Check 'a machine can raise the starting rung' ((Resolve-ModelFor 'orchestrator' 0 $st0).model -eq 'claude-sonnet-5-5')
$fx = $mc | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable; $fx.mode = 'fixed'
Check 'fixed mode ignores the tier' ((Resolve-ModelFor 'subagent' 2 $fx).model -eq 'claude-sonnet-5-5' -and (Resolve-ModelFor 'subagent' 2 $fx).mode -eq 'fixed')
$tp = Resolve-ModelFor 'subagent' 2 $mc 'testing'
Check 'testing profile is haiku 5.5 at low effort' ($tp.model -eq 'claude-haiku-5-5' -and $tp.effort -eq 'low' -and $tp.mode -eq 'profile')
Check 'testing profile never climbs, whatever the tier' ((Resolve-ModelFor 'orchestrator' 2 $mc 'testing').model -eq 'claude-haiku-5-5' -and -not $tp.escalates)
Check 'an unknown profile falls back to the ladder' ((Resolve-ModelFor 'subagent' 1 $mc 'nope').model -eq 'claude-sonnet-5-5')
Check 'the testing profile wins over fixed mode too' ((Resolve-ModelFor 'subagent' 0 $fx 'testing').effort -eq 'low')
# local progress of owned items (lib/Progress.ps1): which places belong to an item, and which files of the work directory never count
. (Join-Path $root 'plugin/scripts/lib/Progress.ps1')
Check 'progress: a branch or file names the item as a whole token' ((Test-NamesItem 'factory-worker/308-development' 308) -and (Test-NamesItem 'brief-308.md' 308) -and (Test-NamesItem '308' 308))
Check 'progress: a longer number or a hash does not name the item' (-not (Test-NamesItem 'factory-worker/1308-development' 308) -and -not (Test-NamesItem 'worktree-agent-a3081f' 308) -and -not (Test-NamesItem '3080.txt' 308))
Check 'progress: the files the client, the launcher and the stream write are never work' ($script:PgWorkSkip.IsMatch('events.log') -and $script:PgWorkSkip.IsMatch('launcher.log') -and $script:PgWorkSkip.IsMatch('session-ended') -and -not $script:PgWorkSkip.IsMatch('brief-308.md'))
$pgDir = Join-Path ([IO.Path]::GetTempPath()) "fw-smoke-progress-$PID"; New-Item -ItemType Directory -Force -Path (Join-Path $pgDir 'progress') | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $pgDir 'progress/308.txt') -Value 'x'
    $pgState = New-ProgressState $pgDir @(); $pgState.owned[308] = [DateTime]::UtcNow.AddMinutes(-1); $pgState.repos = @()
    $pgRep = @(Get-ProgressReport $pgState)
    Check 'progress: a progress file is reported once as the item''s (source marker), then not again until it changes' ($pgRep.Count -eq 1 -and $pgRep[0].item -eq 308 -and $pgRep[0].source -eq 'marker' -and $(foreach ($e in $pgRep) { $pgState.sent[[int]$e.item] = [DateTime]::Parse($e.seen).ToUniversalTime() }; @(Get-ProgressReport $pgState).Count -eq 0))
    Check 'progress: recent work answers a check' ($null -ne (Get-RecentProgress $pgState 308) -and $null -eq (Get-RecentProgress $pgState 309))
    # a file dated in the future (a skewed mount, a restored archive) is no sign of work
    $pgFut = New-ProgressState $pgDir @(); $pgFut.owned[310] = [DateTime]::UtcNow.AddMinutes(-1); $pgFut.repos = @()
    $fut = Join-Path $pgDir 'progress/310.txt'; Set-Content -LiteralPath $fut -Value 'x'; (Get-Item -LiteralPath $fut).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(3)
    Check 'progress: a file dated in the future is not work' ($null -eq (Get-ItemProgress $pgFut 310 $false ([Diagnostics.Stopwatch]::StartNew())))
} finally { Remove-Item -Recurse -Force -LiteralPath $pgDir -ErrorAction SilentlyContinue }
"config"
# docs/design/cloud-worker-runtimes.md section 5: every runtime is off in the source defaults; one is switched on and sized only in
# config/deploy.overrides.json (a code-owner path). A default that starts executions would spend money from any build of this repository.
$rtCfg = (Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable).runtimes
Check 'runtimes: the source defaults exist' ($rtCfg -is [System.Collections.IDictionary] -and $rtCfg.caeJob -is [System.Collections.IDictionary])
Check 'runtimes: no routing rule in the source defaults' (@($rtCfg.routing).Count -eq 0)
Check 'runtimes: no environment block in the source defaults' ($rtCfg.environments -is [System.Collections.IDictionary] -and $rtCfg.environments.Count -eq 0)
foreach ($rk in @($rtCfg.Keys | Where-Object { $_ -ne 'environments' -and $rtCfg[$_] -is [System.Collections.IDictionary] })) {
    $rv = $rtCfg[$rk]
    Check "runtimes.${rk}: off in the source defaults (enabled false, maxConcurrent 0, maxExecutionsPerDay 0, no job named)" ($rv.enabled -eq $false -and $rv.maxConcurrent -eq 0 -and $rv.maxExecutionsPerDay -eq 0 -and "$($rv.jobResourceId)" -eq '')
}
# The deployed settings: the overrides merge over the defaults as the Dockerfile merges them, and only tdd has a runtime switched on
# (runtimes.environments.<FACTORY_ENVIRONMENT> is the block of that environment; one without an entry has every runtime off).
$cfgDir = Join-Path $PSScriptRoot '..' 'config'; $merged = Join-Path ([IO.Path]::GetTempPath()) "fw-merged-$PID.json"
try {
    $null = & pwsh -NoProfile -File (Join-Path $cfgDir 'apply-overrides.ps1') -Base (Join-Path $cfgDir 'instance.json') -Overrides (Join-Path $cfgDir 'deploy.overrides.json') -Out $merged 2>&1
    Check 'config: the deploy overrides merge over the defaults' ($LASTEXITCODE -eq 0)
    $envs = if (Test-Path $merged) { (Get-Content -Raw $merged | ConvertFrom-Json -AsHashtable).runtimes.environments } else { @{} }
    $t = $envs.tdd
    # apply-overrides adds an environment's block as written, so its names are checked here: each key exists in the base runtimes block
    # (a misspelt setting would otherwise ship as its default), and environment names are lower case (FACTORY_ENVIRONMENT is matched lower-cased).
    $baseRt = (Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable).runtimes
    $badKeys = @(foreach ($en in @($envs.Keys)) { foreach ($k in @($envs[$en].Keys)) { if ($k -eq 'environments' -or -not $baseRt.Contains($k)) { "$en.$k" } elseif ($envs[$en][$k] -is [System.Collections.IDictionary]) { foreach ($k2 in @($envs[$en][$k].Keys)) { if (-not $baseRt[$k].Contains($k2)) { "$en.$k.$k2" } } } } })
    Check 'config: every environment names only settings of the base runtimes block' ($badKeys.Count -eq 0); if ($badKeys) { "       unknown: $($badKeys -join ', ')" }
    Check 'config: environment names are lower case' (@($envs.Keys | Where-Object { $_ -cne $_.ToLowerInvariant() }).Count -eq 0)
    Check 'config: tdd routes every phase to cae-job, connected workers first' ($t.preferConnected -eq $true -and @($t.routing | Where-Object { $_.phase -eq '*' -and $_.runtime -eq 'cae-job' }).Count -eq 1)
    Check 'config: tdd runs at most 2 executions at a time and 30 a day' ($t.caeJob.enabled -eq $true -and $t.caeJob.maxConcurrent -eq 2 -and $t.caeJob.maxExecutionsPerDay -eq 30)
    Check 'config: no runtime is switched on outside tdd' (@($envs.Keys | Where-Object { $_ -ne 'tdd' -and $envs[$_].caeJob.enabled -eq $true }).Count -eq 0)
    $curDep = (Get-Content -Raw $merged | ConvertFrom-Json -AsHashtable).api.cursor
    Check 'config: the deployed api mode is on in tdd only, one agent at a time, 60 minutes, 6 launches a day, model auto with optimizeFor cost' ($curDep.enabled -eq $true -and @($curDep.environments.Keys).Count -eq 1 -and $curDep.environments.ContainsKey('tdd') -and $curDep.maxConcurrent -eq 1 -and $curDep.maxMinutes -eq 60 -and $curDep.maxExecutionsPerDay -eq 6 -and $curDep.model -eq 'auto' -and $curDep.optimizeFor -eq 'cost')
    Check 'config: the api mode (Cursor Cloud Agents) is off in the source defaults, one agent at a time, 60 minutes' (((Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable).api.cursor | ForEach-Object { $_.enabled -eq $false -and $_.maxConcurrent -eq 1 -and $_.maxMinutes -eq 60 -and -not $_.ContainsKey('apiKey') }))
    Check 'config: the legacy credential kinds stay accepted in the source defaults (auth.legacyKinds)' ((Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json -AsHashtable).auth.legacyKinds -eq $true)
} finally { Remove-Item -LiteralPath $merged -ErrorAction SilentlyContinue }

# ---- prompts (docs/design/agents-roles-launch.md 5.6): the rules gateway/Mcp/Prompts.cs applies, plus the body's tool names ------------------
'prompts'
$promptDir = Join-Path $PSScriptRoot '..' 'prompts'
$rtText = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'gateway' 'Mcp' 'RoleTools.cs')
$roleSets = @{}
foreach ($m in [regex]::Matches($rtText, '\["([a-z]+)"\]\s*=\s*\[([^\]]*)\]')) { $roleSets[$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, '"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value }) }
$allTools = @($roleSets.Values | ForEach-Object { $_ }) | Sort-Object -Unique
Check 'prompts: the role tool sets are read from RoleTools.cs' ($roleSets.ContainsKey('worker') -and $roleSets['worker'] -contains 'get_prompt')
$pfiles = @(Get-ChildItem -Path $promptDir -Recurse -Filter '*.md' | Where-Object { $_.Name -ne 'README.md' })
$seen = @{}
foreach ($pf in $pfiles) {
    $rel = [IO.Path]::GetRelativePath($promptDir, $pf.FullName).Replace('\', '/')
    $txt = (Get-Content -Raw $pf.FullName).Replace("`r`n", "`n")
    $ok = $txt -match '(?s)^---\n(.*?)\n---\n(.*)$'
    Check "prompts: $rel has front matter" $ok
    if (-not $ok) { continue }
    $head = $Matches[1]; $body = $Matches[2]
    $fm = @{}; foreach ($l in $head -split "`n") { if ($l -match '^([a-z]+):\s*(.*)$') { $fm[$Matches[1]] = $Matches[2].Trim() } }
    Check "prompts: $rel has role, phase, version, tools and includes" (@('role', 'phase', 'version', 'tools', 'includes' | Where-Object { -not $fm.ContainsKey($_) }).Count -eq 0)
    Check "prompts: $rel version is a positive number" ("$($fm.version)" -match '^[1-9][0-9]*$')
    $tools = @(if ($fm.tools -match '^\[(.*)\]$') { $Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $incs = @(if ($fm.includes -match '^\[(.*)\]$') { $Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $set = $(if ($fm.role -eq 'bootstrap') { 'worker' } else { $fm.role })
    Check "prompts: $rel names a known role" ($fm.role -in 'common', 'bootstrap' -or $roleSets.ContainsKey($fm.role))
    $outside = @($tools | Where-Object { -not ($roleSets.ContainsKey($set) -and $roleSets[$set] -contains $_) })
    Check "prompts: $rel tools are all in the $set role's set" ($outside.Count -eq 0); if ($outside) { "       outside: $($outside -join ', ')" }
    $named = @([regex]::Matches($body, '`([a-z_]+)`') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $allTools -contains $_ } | Sort-Object -Unique)
    $undeclared = @($named | Where-Object { $tools -notcontains $_ })
    Check "prompts: $rel declares every tool its body names" ($undeclared.Count -eq 0); if ($undeclared) { "       undeclared: $($undeclared -join ', ')" }
    Check "prompts: $rel includes exist" (@($incs | Where-Object { -not (Test-Path (Join-Path $promptDir $_)) }).Count -eq 0)
    Check "prompts: $rel names no factory.ps1 and holds no shell variable" (-not $body.Contains('factory.ps1') -and $body -notmatch '\$[A-Za-z_][A-Za-z0-9_]*')
    $key = "$($fm.role)/$($fm.phase)"; Check "prompts: $rel is the only prompt of $key" (-not $seen.ContainsKey($key)); $seen[$key] = $rel
}
foreach ($need in 'worker/technical-design', 'worker/development', 'worker/functional-testing', 'bootstrap/api') { Check "prompts: there is a prompt for $need" ($seen.ContainsKey($need)) }
if ($fail) { "FAILED: $fail"; exit 1 } else { 'all passed' }
