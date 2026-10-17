# Tier 1: the author identity as a GitHub App (cloud gateways). The App's ids and key come from the environment, a short-lived installation
# token is minted once and cached, and the 'unset' vault placeholder counts as no token.
$AuthorScenarios = [ordered]@{

'author app: the gateway acts as the App, mints once, caches the token and never needs GH_TOKEN' = {
    $before = (Get-FakeState).appMints
    $n = New-Item-Fake 'App author' 'x' $L
    $r = F 'w1' @('comment', '--item', $n, '--body', 'hello from the App'); CheckExit 'comment as the App' $r 0
    $c = @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'hello from the App' })
    Check 'the comment was posted' ($c.Count -ge 1)
    $r = F 'w1' @('comment', '--item', $n, '--body', 'second call'); CheckExit 'second call' $r 0
    $after = (Get-FakeState).appMints
    Check 'one token was minted for several verbs (cache)' (($after - $before) -ge 1 -and ($after - $before) -le 2) "minted $($after - $before)"
    $al = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/alive" -SkipHttpErrorCheck; Check '/alive answers without a token (the kit health probe)' ($al.StatusCode -eq 200)
    $cache = Join-Path $env:FACTORY_STATE_DIR 'app-token-author.json'
    Check 'the token cache exists' (Test-Path $cache)
    if ($IsLinux) { Check 'the token cache is mode 0600' ((& stat -c %a $cache) -eq '600') }
    Check 'no private key in the cache or the gateway log' (-not ((Get-Content -Raw $cache) -match 'PRIVATE KEY') -and -not ((Get-Content -Raw (Join-Path $script:Work 'gateway.out')) -match 'PRIVATE KEY'))
}


'author app: state written by an earlier identity is adopted, then continued in the App''s own comment [full]' = {
    $n = New-Item-Fake 'Migrated item' 'x' $L
    $body = "<!-- factory-state:factory-worker v1 -->`nstate of #$n for ``factory-worker`` (machine-read; edits by others are ignored)`n`n``````json`n" + (@{ schema = 1; item = $n; migrated_marker = 'from-old-identity'; demotions = 1 } | ConvertTo-Json) + "`n``````n"
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/$((Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json).owner)/$((Get-Content -Raw $env:FACTORY_CONFIG | ConvertFrom-Json).repo)/issues/$n/comments" -Method POST -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ body = $body } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    $g = F 'w1' @('get-item', '--item', $n); CheckExit 'get-item' $g 0
    Check 'the earlier identity''s state is read' ((Pv $g.state 'demotions') -eq 1) ($g.state | ConvertTo-Json -Compress -Depth 3)
    $r = F 'w1' @('claim-item', '--item', $n, '--column', 'Technical Design'); CheckExit 'claim (a save)' $r 0
    $g2 = F 'w1' @('get-item', '--item', $n)
    Check 'the adopted facts survive the first save by the App' ((Pv $g2.state 'demotions') -eq 1 -and (Pv $g2.state 'claim') -ne $null) ($g2.state | ConvertTo-Json -Compress -Depth 3)
    $own = @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'factory-state:' })
    Check 'the App wrote a state comment of its own next to the old one' ($own.Count -eq 2) "state comments: $($own.Count)"
}

'plugin: a downloaded copy follows the gateway and a working copy is never touched [full]' = {
    $base = "http://127.0.0.1:$($script:ApiPort)"
    $b = Invoke-RestMethod "$base/_build"
    Check 'the gateway publishes a plugin hash' ($b.pluginHash -match '^[0-9a-f]{64}$') "$($b.pluginHash)"
    $anon = try { Invoke-WebRequest "$base/api/v1/plugin" -SkipHttpErrorCheck; } catch { $null }
    Check 'the plugin download needs a credential' ($anon.StatusCode -eq 401) "status $($anon.StatusCode)"
    $dir = Join-Path $script:Work 'managed-plugin'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-WebRequest "$base/api/v1/plugin" -Headers @{ Authorization = 'Bearer test-token' } -OutFile "$dir.tgz" | Out-Null
    & tar -xzf "$dir.tgz" -C $dir
    Check 'the archive carries the marker and the version stamp' ((Test-Path "$dir/.plugin-managed") -and (Test-Path "$dir/.plugin-version") -and (Test-Path "$dir/scripts/factory.ps1"))
    Check 'the stamp equals the hash the gateway announces' (((Get-Content -Raw "$dir/.plugin-version" | ConvertFrom-Json).hash) -eq $b.pluginHash)
    $w = F 'w1' @('plugin-sync'); CheckExit 'a working copy is never touched' $w 10 'not-managed'
    $cur = (& pwsh -NoProfile -File "$dir/scripts/factory.ps1" plugin-sync 2>&1) -join "`n" | ConvertFrom-Json
    Check 'a current copy is left alone' ($cur.ok -and -not $cur.updated) ($cur | ConvertTo-Json -Compress)
    $skill = Get-ChildItem "$dir/skills" -Recurse -Filter SKILL.md | Select-Object -First 1
    $orig = Get-Content -Raw $skill.FullName; Set-Content $skill.FullName 'tampered'; Set-Content "$dir/.plugin-version" '{"hash":"stale"}'
    $upd = (& pwsh -NoProfile -File "$dir/scripts/factory.ps1" plugin-sync 2>&1) -join "`n" | ConvertFrom-Json
    Check 'a stale copy is replaced' ($upd.ok -and $upd.updated -and $upd.to -eq $b.pluginHash) ($upd | ConvertTo-Json -Compress)
    Check 'the replaced skill is the gateway version again' ((Get-Content -Raw (Join-Path $dir (Resolve-Path $skill.FullName -Relative -RelativeBasePath $dir)) -ErrorAction SilentlyContinue) -eq $orig -or (Get-Content -Raw $skill.FullName) -eq $orig)
    # the temp directory on another filesystem than the copy (a tmpfs /tmp is common): the move is then a copy and a removal, and the hidden
    # .claude-plugin directory must not stop the sync before the stamp is written. Only where such a filesystem exists (Linux: /dev/shm).
    $shm = '/dev/shm'
    if ((Test-Path $shm) -and ((& stat -c '%d' $shm) -ne (& stat -c '%d' $dir))) {
        $tmpOther = Join-Path $shm "fw-author-$([guid]::NewGuid().ToString('N').Substring(0,8))"; New-Item -ItemType Directory -Force -Path $tmpOther | Out-Null
        try {
            Set-Content "$dir/.plugin-version" '{"hash":"stale"}'
            $x = (& env "TMPDIR=$tmpOther" pwsh -NoProfile -File "$dir/scripts/factory.ps1" plugin-sync 2>&1) -join "`n"
            $xj = try { $x | ConvertFrom-Json } catch { $null }
            Check 'a stale copy is replaced when the temp directory is on another filesystem' ($xj -and $xj.ok -and $xj.updated -and $xj.to -eq $b.pluginHash) $x
            Check 'and the stamp and the hidden .claude-plugin directory are in place' ((((Get-Content -Raw "$dir/.plugin-version" | ConvertFrom-Json).hash) -eq $b.pluginHash) -and (Test-Path "$dir/.claude-plugin")) (Get-Content -Raw "$dir/.plugin-version")
            $again = (& env "TMPDIR=$tmpOther" pwsh -NoProfile -File "$dir/scripts/factory.ps1" plugin-sync 2>&1) -join "`n" | ConvertFrom-Json
            Check 'and the next sync finds it current' ($again.ok -and -not $again.updated) ($again | ConvertTo-Json -Compress)
        } finally { Remove-Item -LiteralPath $tmpOther -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

'plugin: the package names no maintainer path and no preinstalled tool' = {
    $root = Join-Path $script:Root 'plugin'
    $files = Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in '.md', '.ps1', '.json' }
    $bad = @()
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1)
        # a line that forbids the thing ("never write $HOME", "gh is not installed") is the rule, not a use of it
        $t = (Get-Content -LiteralPath $f.FullName | Where-Object { $_ -cnotmatch '(?i)\bnever\b|not installed|not used|refuse' }) -join "`n"
        if ($t -cmatch '/home/[a-z]|/Users/[A-Za-z]|C:\\Users|Projects/factory|jeffrey') { $bad += "${rel}: a maintainer or machine path" }
        if ($rel -like 'skills*' -or $rel -like 'agents*') {
            if ($t -cmatch '\$FACTORY_PLUGIN_SCRIPTS|\$HOME|~/\.') { $bad += "${rel}: a shell variable or home path in a command" }
            if ($t -cmatch '(?m)`gh |\bgh (pr|run|api|issue)\b|`jq |`python') { $bad += "${rel}: a tool that is not installed on a clean machine" }
        }
        if ($rel -like 'scripts*') {
            if ($t -cmatch '\.\./\.\./\.\./') { $bad += "${rel}: reaches outside the plugin directory" }
        }
    }
    Check 'no file in the plugin assumes the maintainer machine, a preinstalled tool or a path outside the package' ($bad.Count -eq 0) ($bad -join '; ')
    # the docs-only fast path: its three skills stay plain ASCII, and each names the script answer it depends on
    $fp = [ordered]@{ 'factory-technical-design' = @('finding-without-criterion', 'max_rounds', 'FINDING: criterion "'); 'factory-development' = @('build_owed: false', 'build_owed: true', '## A command refused in a subagent''s shell'); 'factory-functional-testing' = @('verification: "diff"', 'verification: "app"') }
    $miss = @()
    foreach ($k in $fp.Keys) {
        $txt = Get-Content -Raw -LiteralPath (Join-Path $root "skills/$k/SKILL.md")
        if ($txt -cmatch '[^\x00-\x7F]') { $miss += "${k}: a character outside ASCII" }
        foreach ($w in $fp[$k]) { if ($txt.IndexOf($w, [StringComparison]::Ordinal) -lt 0) { $miss += "${k}: does not name '$w'" } }
    }
    Check 'the fast-path skills are ASCII and name the answers of the script (build_owed, verification, finding-without-criterion)' ($miss.Count -eq 0) ($miss -join '; ')
}

'plugin: a downloaded plugin runs on a machine with nothing else [full]' = {
    $base = "http://127.0.0.1:$($script:ApiPort)"
    $dir = Join-Path $script:Work 'clean-plugin'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-WebRequest "$base/api/v1/plugin" -Headers @{ Authorization = 'Bearer test-token' } -OutFile "$dir.tgz" | Out-Null
    & tar -xzf "$dir.tgz" -C $dir
    $home2 = Join-Path $script:Work 'clean-home'; New-Item -ItemType Directory -Force -Path $home2 | Out-Null
    $envArgs = @('-i', "PATH=$env:PATH", "HOME=$home2", "FACTORY_URL=$base", 'FACTORY_TOKEN=test-token')
    $m = (& env @envArgs pwsh -NoProfile -File "$dir/scripts/factory.ps1" model-for --role subagent --tier 1 2>&1) -join "`n"
    $mj = try { $m | ConvertFrom-Json } catch { $null }
    Check 'model-for finds its ladder inside the plugin' ($mj -and $mj.model) $m
    $o = (& env @envArgs pwsh -NoProfile -File "$dir/scripts/factory.ps1" plugin-sync 2>&1) -join "`n"
    $oj = try { $o | ConvertFrom-Json } catch { $null }
    Check 'plugin-sync answers from the downloaded copy' ($oj -and $oj.ok) $o
    $t = (& env @envArgs pwsh -NoProfile -Command ". '$dir/scripts/lib/Paths.ps1'; Get-FwDataDir") -join "`n"
    Check 'the data directory is created under the machine home and nowhere else' ($t.StartsWith($home2)) $t
    $t2 = (& env -i "PATH=$env:PATH" "HOME=/nonexistent-home" "TMPDIR=$home2" pwsh -NoProfile -Command ". '$dir/scripts/lib/Paths.ps1'; Get-FwDataDir") -join "`n"
    Check 'a missing home falls back to a temp directory instead of failing' ($t2 -and (Test-Path -LiteralPath $t2)) $t2
}
}
