# The backlog keeper session's client (docs/design/backlog-keeper.md): its event stream and its verbs. Its only credential is
# FACTORY_KEEPER_TOKEN ("k1.<name>.<generation>.<hmac>"), set in the shell by its connect prompt; it is never printed. Client.Own.ps1 is loaded
# first (Confirm-Heartbeat).
#
#   subscribe --own --keeper --name N --model ID --effort E     the stream: keeper.job lines (codes and numbers only), one per line
#   backlog | amend-criteria | split-item | create-item | set-priority | link-dependency   (the verbs; see the skill factory-backlog-keeper)

function Get-KeeperCredential {
    if ($env:FACTORY_KEEPER_TOKEN) { return $env:FACTORY_KEEPER_TOKEN }
    Write-Out @{ ok = $false; code = 'client-not-configured'; reason = 'no keeper credential: the connect prompt sets FACTORY_KEEPER_TOKEN in this shell' } 30
}

function Invoke-KeeperSubscribe($a) {
    $cfg = Get-ClientConfig
    $cred = Get-KeeperCredential; $cfg.token = $cred
    $name = "$($a.name)"
    if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { Write-Out @{ ok = $false; code = 'usage'; reason = '--name is required: letters, digits, - and _ (40 at most)' } 2 }
    foreach ($k in 'model', 'effort') { if ($a.ContainsKey($k) -and "$($a[$k])" -cnotmatch '^[a-z0-9._-]{1,60}$') { Write-Out @{ ok = $false; code = 'usage'; reason = "--$k is the id this session runs on: lower-case letters, digits, . _ and - (60 at most)" } 2 } }
    $lastId = ''; $pendingId = ''; $backoff = 2; $dropN = 0; $heartbeat = $null
    [Console]::Out.WriteLine((@{ provider = 'client'; event = 'session.start'; name = $name; type = 'keeper'; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress)); [Console]::Out.Flush()
    . (Join-Path $here 'lib/Client.Plugin.ps1')
    while ($true) {
        try { $ps = Sync-Plugin $cfg; if ($ps.ok -and $ps.updated) { [Console]::Out.WriteLine((@{ provider = 'client'; event = 'plugin.updated'; from = $ps.from; to = $ps.to; restart_needed = $true } | ConvertTo-Json -Compress)); [Console]::Out.Flush() } } catch { }
        $http = [Net.Http.HttpClient]::new(); $http.Timeout = [TimeSpan]::FromHours(24)
        try {
            $q = "name=$([uri]::EscapeDataString($name))&keeper=1"
            foreach ($k in 'model', 'effort') { if ($a.ContainsKey($k)) { $q += "&$k=$([uri]::EscapeDataString("$($a[$k])"))" } }
            $req = [Net.Http.HttpRequestMessage]::new('GET', "$($cfg.url)/api/v1/events?$q")
            $req.Headers.Add('Authorization', "Bearer $cred")
            if ($lastId) { [void]$req.Headers.TryAddWithoutValidation('Last-Event-ID', $lastId) }
            $resp = $http.SendAsync($req, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                $sc = [int]$resp.StatusCode
                if ($sc -in 400, 401, 403, 409) {
                    $rb = try { $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable } catch { $null }
                    $rx = if ($rb -is [hashtable] -and $rb.ContainsKey('exit')) { [int]$rb.exit } else { 30 }
                    $rc = if ($rb -is [hashtable] -and $rb.code) { "$($rb.code)" } else { 'refused' }
                    $rr = if ($rb -is [hashtable] -and $rb.reason) { "$($rb.reason)" } else { '' }
                    [Console]::Out.WriteLine(([ordered]@{ provider = 'client'; event = 'stream.refused'; status = $sc; code = $rc; reason = "gateway answered ${sc}: $rr"; exit = $rx } | ConvertTo-Json -Compress)); [Console]::Out.Flush()
                    exit $rx
                }
                throw "gateway answered $sc"
            }
            $reader = [IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
            $backoff = 2
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($line.StartsWith('id:')) { $pendingId = $line.Substring(3).Trim() }
                elseif ($line.StartsWith('data:')) {
                    $ev = try { $line.Substring(5).Trim() | ConvertFrom-Json -AsHashtable } catch { $null }
                    $evId = $pendingId; $pendingId = ''
                    if ($null -eq $ev) { if ($evId) { $lastId = $evId }; continue }
                    if ($ev.event -eq 'stream.replaced') { [Console]::Out.WriteLine(($ev | ConvertTo-Json -Compress -Depth 6)); [Console]::Out.Flush(); exit 40 }
                    if ($ev.event -eq 'keeper.registered') { $dropN = 0; try { $heartbeat = Confirm-Heartbeat $heartbeat $cfg.url $cred 20 } catch { [Console]::Error.WriteLine("heartbeat not started: $($_.Exception.Message)") } }
                    [Console]::Out.WriteLine(($ev | ConvertTo-Json -Compress -Depth 6)); [Console]::Out.Flush()
                    if ($evId) { $lastId = $evId }
                }
            }
        } catch {
            $dropN++
            # a drop is reported from the third failure in a row (enhancement 11): one lost connection that the next attempt restores says nothing
            if ($dropN -ge 3 -and ($dropN -le 5 -or $dropN % 10 -eq 0)) { [Console]::Out.WriteLine((@{ provider = 'client'; event = 'stream.error'; reason = "$($_.Exception.Message)"; attempt = $dropN; retry_in_seconds = $backoff } | ConvertTo-Json -Compress)); [Console]::Out.Flush() }
            [Console]::Error.WriteLine("subscription dropped: $($_.Exception.Message); retrying in ${backoff}s")
        }
        finally { $http.Dispose() }
        Start-Sleep -Seconds $backoff; $backoff = [Math]::Min(30, $backoff * 2)
    }
}

# One verb of the keeper: POST /api/v1/verbs/<verb> with the keeper credential and the body of its flags. Prints the gateway's answer and exits with
# its exit code. File flags (--body-file, --children-file) were read by ConvertFrom-Flags into body and children.
function Invoke-KeeperVerb([string]$Verb, $a, $cfg) {
    $body = [ordered]@{}
    foreach ($k in $a.Keys) { if ($k -notin 'holder', 'by', 'from', 'role') { $body[$k] = $a[$k] } }
    if ($Verb -eq 'split-item' -and $body.Contains('children')) {
        $kids = try { "$($body['children'])" | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
        if ($kids -isnot [array]) { Write-Out @{ ok = $false; code = 'usage'; reason = '--children-file is a JSON array of { "title": "...", "body": "..." }' } 2 }
        $body['children'] = $kids
    }
    foreach ($k in 'body', 'replacement', 'reason') {
        if ($body.Contains($k)) { . (Join-Path $PSScriptRoot 'Client.Messages.ps1'); if (Test-LooksSecret "$($body[$k])") { Write-Out @{ ok = $false; code = 'secret-in-message'; reason = "the $k looks like a credential or token; nothing was sent" } 10 } }
    }
    $p = @{ Uri = "$($cfg.url)/api/v1/verbs/$Verb"; Method = 'POST'; Headers = @{ Authorization = "Bearer $(Get-KeeperCredential)" }; SkipHttpErrorCheck = $true; TimeoutSec = 170
        Body = ($body | ConvertTo-Json -Depth 8 -Compress); ContentType = 'application/json; charset=utf-8' }
    try { $resp = Invoke-WebRequest @p } catch { Write-Out @{ ok = $false; code = 'gateway-unreachable'; reason = $_.Exception.Message; retryAfterSeconds = 15 } 20 }
    $text = $resp.Content; if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $j = try { $text | ConvertFrom-Json -AsHashtable } catch { $null }
    $sc = [int]$resp.StatusCode
    if ($j -isnot [hashtable]) { Write-Out @{ ok = $false; code = $(if ($sc -in 401, 403) { 'forbidden' } else { 'gateway-error' }); reason = "HTTP $sc" } $(switch ($sc) { 401 { 30 } 403 { 30 } 404 { 12 } default { 20 } }) }
    $code = if ($j.ContainsKey('exit')) { [int]$j.exit } elseif ($sc -lt 300) { 0 } elseif ($sc -in 401, 403) { 30 } else { 20 }
    [Console]::Out.WriteLine("$text".Trim()); exit $code
}
