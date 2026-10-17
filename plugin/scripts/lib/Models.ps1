# Model choice. Two halves, deliberately apart:
#   server (gateway): WHEN to escalate. Verb_model_tier turns an item's history (relaunches, review findings, demotions, fix-forward rounds, gate
#     refusals) into a tier number, never lower than before in the same column. A script rule, so a looping model cannot argue its way out of it.
#   client (this machine): WHICH model sits on each rung (~/.config/factory-worker/models.json), and what to run when the mode is fixed.
# The default ladder is cost-first: economy -> standard -> premium.

function Get-TierFor($Value, $Thresholds) { $t = 0; for ($i = 0; $i -lt @($Thresholds).Count; $i++) { if ([double]$Value -ge [double]@($Thresholds)[$i]) { $t = $i + 1 } }; return $t }

function Get-RefusalFile { Join-Path (Get-StateDir) 'refusals.json' }
function Read-Refusals { $f = Get-RefusalFile; if (Test-Path $f) { try { return Get-Content -Raw $f | ConvertFrom-Json -AsHashtable -DateKind String } catch { } }; return @{} }
function Add-Refusal([int]$Item) { $r = Read-Refusals; $r["$Item"] = $(if ($r.ContainsKey("$Item")) { [int]$r["$Item"] + 1 } else { 1 }); $r | ConvertTo-Json | Set-Content (Get-RefusalFile) }
function Reset-Refusals([int]$Item) { $r = Read-Refusals; if ($r.ContainsKey("$Item")) { $r.Remove("$Item"); $r | ConvertTo-Json | Set-Content (Get-RefusalFile) } }

function Verb_model_tier($a) {
    $n = Get-ItemNumber $a; $c = Get-Cfg; $e = $c.escalation
    $info = Get-ItemInfo $n; $st = Get-State $n; $s = $st.state
    $col = if ((Test-Has $a 'column') -and $a.column) { "$($a.column)" } else { "$($info.column)" }
    $sig = [ordered]@{}
    $launches = if ((Test-Has $s 'claim') -and (Test-Has $s.claim 'launches')) { [int]$s.claim.launches } else { 0 }
    $sig.launches = @{ value = $launches; tier = (Get-TierFor $launches $e.launches) }
    $rounds = 0; if ((Test-Has $s 'reviews') -and (Test-Has $s.reviews $col) -and $s.reviews[$col].last -eq 'FINDINGS') { $rounds = [int]$s.reviews[$col].round }
    $sig.findingsRounds = @{ value = $rounds; tier = (Get-TierFor $rounds $e.findingsRounds) }
    $dem = if (Test-Has $s 'demotions') { [int]$s.demotions } else { 0 }
    $sig.demotions = @{ value = $dem; tier = (Get-TierFor $dem $e.demotions) }
    $ff = if (Test-Has $s 'fix_forward_rounds') { [int]$s.fix_forward_rounds } else { 0 }
    $sig.fixForwardRounds = @{ value = $ff; tier = (Get-TierFor $ff $e.fixForwardRounds) }
    $ref = Read-Refusals; $rf = if ($ref.ContainsKey("$n")) { [int]$ref["$n"] } else { 0 }
    $sig.refusals = @{ value = $rf; tier = (Get-TierFor $rf $e.refusals) }
    $floor = 0; if ($e.minTierByColumn -and (Test-Has $e.minTierByColumn $col)) { $floor = [int]$e.minTierByColumn[$col] }
    $tier = $floor; foreach ($k in $sig.Keys) { if ($sig[$k].tier -gt $tier) { $tier = $sig[$k].tier } }
    $prev = if ((Test-Has $s 'model_tier') -and $s.model_tier.column -ieq $col) { [int]$s.model_tier.tier } else { 0 }
    if ($prev -gt $tier) { $tier = $prev }
    if (-not (Test-Has $s 'model_tier') -or $s.model_tier.column -ine $col -or [int]$s.model_tier.tier -ne $tier) {
        $s.model_tier = @{ column = $col; tier = $tier; at = ConvertTo-Iso (Get-UtcNow); signals = @($sig.Keys | Where-Object { $sig[$_].tier -gt 0 }) }
        Save-State $n $st
    }
    $why = @($sig.Keys | Where-Object { $sig[$_].tier -ge 1 -and $sig[$_].tier -eq $tier } | ForEach-Object { "$_=$($sig[$_].value)" })
    $profile = if ($c.testLabel -and (Test-Label $info $c.testLabel)) { 'testing' } else { $null }
    return @{ ok = $true; id = $n; column = $col; tier = $tier; reasons = $why; signals = $sig; profile = $profile }
}

# ---- client half ------------------------------------------------------------------------------------------------------
function Get-ModelsConfig {
    $path = $env:FACTORY_MODELS_CONFIG
    if (-not $path) { $user = Get-FwConfigPath 'models.json'; if ($user -and (Test-Path $user)) { $path = $user } }
    if (-not $path) { $path = Join-Path $PSScriptRoot '../models.default.json' }
    return Get-Content -Raw $path | ConvertFrom-Json -AsHashtable
}

# The short name an Agent tool accepts when it does not take full model ids (haiku, sonnet, opus, fable); '' when the id is not recognised.
function Get-ModelAlias([string]$Model) {
    foreach ($a in 'haiku', 'sonnet', 'opus', 'fable') { if ($Model -match "(?i)^claude-$a(-|$)") { return $a } }
    return ''
}

# Resolve the model and effort for a role. -Tier overrides the gateway lookup (tests, explicit pins).
function Resolve-ModelFor([string]$Role, $Tier, $Cfg, [string]$Profile = '') {
    if ($Profile -and $Cfg.ContainsKey('profiles') -and $Cfg.profiles.ContainsKey($Profile)) {
        $p = $Cfg.profiles[$Profile]; return @{ role = $Role; mode = 'profile'; profile = $Profile; tier = $null; name = $Profile; model = $p.model; effort = $p.effort; escalates = [bool]$p.escalate }
    }
    if ($Cfg.mode -eq 'fixed') {
        $f = $Cfg.fixed[$Role]; return @{ role = $Role; mode = 'fixed'; tier = $null; name = 'fixed'; model = $f.model; effort = $f.effort }
    }
    $r = $Cfg[$Role]; $ladder = @($Cfg.ladder)
    $t = [Math]::Max([int]$r.startTier, [int]$Tier); $t = [Math]::Min($t, [Math]::Min([int]$r.maxTier, $ladder.Count - 1))
    $rung = $ladder[$t]
    return @{ role = $Role; mode = 'auto'; tier = $t; name = $rung.name; model = $rung.model; effort = $rung.effort }
}
