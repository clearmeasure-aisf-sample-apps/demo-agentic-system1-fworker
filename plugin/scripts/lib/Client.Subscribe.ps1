# Client side: subscribe to the gateway's event stream. One normalized event per stdout line, so a Monitor on this command
# turns each line into a notification in the Claude session. With --spawn, each work offer starts a headless worker session.

function Get-WorkerDir { Get-FwSubDir 'workers' $env:FACTORY_WORKER_DIR }

function Start-Worker($ev, $cfg, [int]$Max) {
    $dir = Get-WorkerDir
    $running = @(Get-ChildItem $dir -Filter '*.pid' -ErrorAction SilentlyContinue | Where-Object {
            $file = $_; $p = [int](Get-Content $file.FullName)
            try { $null = Get-Process -Id $p -ErrorAction Stop; $true } catch { Remove-Item $file.FullName -Force; $false } })
    if ($running | Where-Object { $_.Name -eq "item-$($ev.item).pid" }) { return }
    if ($running.Count -ge $Max) { return }
    $holder = "worker-$($ev.item)-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    $log = Join-Path $dir "item-$($ev.item)-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).log"
    $plugin = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $sandbox = $env:FACTORY_SANDBOX_REPO
    if (-not $sandbox) { [Console]::Error.WriteLine('FACTORY_SANDBOX_REPO is not set; cannot spawn a worker'); return }
    $prompt = "A factory event arrived: $($ev | ConvertTo-Json -Compress). Use the factory-dispatch skill and follow it exactly (it says whether to claim the item or to approve or merge it). Your hold identity is already set in your environment as FACTORY_HOLDER: never set it yourself and never put VAR=value in front of a command (run `pwsh $(Join-Path $plugin 'scripts/factory.ps1') ...`; wherever a skill shows `$FACTORY_PLUGIN_SCRIPTS`, use the literal path $(Join-Path $plugin 'scripts') instead: commands that contain a shell variable are refused in this sandbox). Use `git -C <dir>` instead of `cd <dir> && git`. Before starting any subagent run factory.ps1 model-for --role subagent --item $($ev.item) and pass the model it returns."
    $mf = try { (& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../factory.ps1') model-for --role orchestrator --item $ev.item) | ConvertFrom-Json } catch { $null }
    $psi = [Diagnostics.ProcessStartInfo]::new('claude')
    if ($mf -and $mf.model) { foreach ($x in @('--model', $mf.model, '--effort', $mf.effort)) { $psi.ArgumentList.Add($x) } }
    foreach ($x in @('-p', $prompt, '--plugin-dir', $plugin, '--permission-mode', 'acceptEdits', '--allowedTools', 'Bash(pwsh:*) Bash(git:*) Bash(gh:*) Bash(dotnet:*) Bash(ls:*) Bash(cat:*) Bash(grep:*) Bash(sed:*) Bash(mkdir:*) Bash(printf:*) Bash(echo:*) Bash(head:*) Bash(tail:*) Bash(wc:*) Bash(test:*) Bash(cd:*) Bash(curl:*) Bash(nohup:*) Bash(kill:*) Bash(sleep:*) Bash(ss:*) Bash(pkill:*) Bash(rm:*) Bash(npx:*) Bash(playwright:*) Read Edit Write Grep Glob Agent', '--max-turns', '120')) { $psi.ArgumentList.Add($x) }
    $psi.WorkingDirectory = $sandbox
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.Environment['FACTORY_URL'] = $cfg.url; $psi.Environment['FACTORY_TOKEN'] = $cfg.token; $psi.Environment['FACTORY_HOLDER'] = $holder; [void]$psi.Environment.Remove('FACTORY_SUPERVISOR_TOKEN')   # a child never holds the supervisor credential
    $psi.Environment['FACTORY_PLUGIN_SCRIPTS'] = Join-Path $plugin 'scripts'
    $proc = [Diagnostics.Process]::Start($psi)
    Set-Content (Join-Path $dir "item-$($ev.item).pid") $proc.Id
    $null = Start-ThreadJob -ScriptBlock { param($p, $l, $n) $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); Set-Content $l ($o + "`n--- stderr ---`n" + $e); $p.WaitForExit(); $h = $p.StartInfo.Environment['FACTORY_HOLDER']; $ff = $p.StartInfo.Environment['FACTORY_PLUGIN_SCRIPTS']; $env:FACTORY_URL = $p.StartInfo.Environment['FACTORY_URL']; $env:FACTORY_TOKEN = $p.StartInfo.Environment['FACTORY_TOKEN']; $env:FACTORY_HOLDER = $h; & pwsh -NoProfile -File (Join-Path $ff 'factory.ps1') release --item $n --reason worker-exited *> $null } -ArgumentList $proc, $log, $ev.item -ErrorAction SilentlyContinue
    [Console]::Out.WriteLine((@{ provider = 'client'; event = 'worker.spawned'; item = $ev.item; holder = $holder; log = $log } | ConvertTo-Json -Compress))
}

function Invoke-Subscribe($a) {
    $cfg = Get-ClientConfig
    $spawn = $a.ContainsKey('spawn') -and $a.spawn
    $max = if ($env:FACTORY_MAX_WORKERS) { [int]$env:FACTORY_MAX_WORKERS } else { 3 }
    $caps = if ($a.ContainsKey('capabilities')) { $a.capabilities } else { 'git,pwsh' }
    $lastId = ''
    $backoff = 2; $dropN = 0
    [Console]::Out.WriteLine((@{ provider = 'client'; event = 'session.start'; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress)); [Console]::Out.Flush()
    # two credentials in one session (worker-messaging.md 6.4): said once, without either value (the function is in Client.Own.ps1)
    . (Join-Path $PSScriptRoot 'Client.Own.ps1'); Write-TwoCredentialWarning
    while ($true) {
        $http = [Net.Http.HttpClient]::new(); $http.Timeout = [TimeSpan]::FromHours(24)
        try {
            $req = [Net.Http.HttpRequestMessage]::new('GET', "$($cfg.url)/api/v1/events?capabilities=$caps")
            $req.Headers.Add('Authorization', "Bearer $(Get-ConfigToken $cfg)")
            if ($lastId) { $req.Headers.Add('Last-Event-ID', $lastId) }
            $resp = $http.SendAsync($req, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) { throw "gateway answered $([int]$resp.StatusCode)" }
            $reader = [IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            $backoff = 2; $dropN = 0
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line.StartsWith('id:')) { $lastId = $line.Substring(3).Trim() }
                elseif ($line.StartsWith('data:')) {
                    $json = $line.Substring(5).Trim()
                    # one line within the bound of the stream (Client.Own.ps1, Format-StreamLine): a gateway event that does not fit keeps its short fields
                    $ev0 = if ($json.Length -le (Get-StreamLineMax)) { $null } else { try { $json | ConvertFrom-Json -AsHashtable } catch { $null } }
                    if ($json.Length -le (Get-StreamLineMax)) { Write-StreamLine $json }
                    elseif ($ev0 -is [Collections.IDictionary]) { Write-StreamLine (Format-StreamLine $ev0 (Get-StreamReadHint $ev0)) }
                    else { Write-StreamLine (([ordered]@{ provider = 'client'; event = 'event.unreadable'; chars = $json.Length; cut = $true }) | ConvertTo-Json -Compress) }
                    if ($spawn) { try { $ev = $json | ConvertFrom-Json; if ($ev.event -eq 'work.offered') { Start-Worker $ev $cfg $max } } catch { [Console]::Error.WriteLine("spawn failed: $($_.Exception.Message)") } }
                }
            }
        } catch {
            # on stdout, where a Monitor reads: a refused credential or an unreachable gateway must be visible to the session, not only on stderr
            # a drop is reported only after 2 reconnects failed as well (enhancement 11): one lost connection that the next attempt restores is
            # routine (a proxy, a gateway restart) and says nothing to the session. Comment lines (`: ping`) are never events.
            $dropN++
            if ($dropN -ge 3 -and ($dropN -le 5 -or $dropN % 10 -eq 0)) { Write-StreamLine (Format-StreamLine ([ordered]@{ provider = 'client'; event = 'stream.error'; reason = "$($_.Exception.Message)"; attempt = $dropN; retry_in_seconds = $backoff })) }
            if ($dropN -ge 3) { [Console]::Error.WriteLine("subscription dropped: $($_.Exception.Message); retrying in ${backoff}s") }
        }
        finally { $http.Dispose() }
        Start-Sleep -Seconds $backoff; $backoff = [Math]::Min(30, $backoff * 2)
    }
}
