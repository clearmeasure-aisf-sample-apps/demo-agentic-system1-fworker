# Peer verbs of the worker client (worker-messaging.md 6.1, 6.4): peers, send, inbox, ack, ask, presence, message-status, and the supervisor's
# answer, direct, questions, plant-digest and patrol-ack. Dispatched from factory.ps1 like
# wait-event; they are not server verbs and never go through /verbs. The envelope, the strip set, the seen set and the open-question store are
# in Client.Own.ps1, which is loaded first.
#
# Every verb builds its own request body and never adds `holder`: the generic client adds it to every verb body, and a `holder` (or `from`, `sender`,
# `fromKind`, `role`) in a messaging body is refused forged-sender (4.2) rather than ignored. The sender is the credential, nothing else: the worker
# credential (Get-WorkerCredential), which may also be the item token of a headless session.
# Message text is untrusted data. It is read from an argument or a file, passes the credential catalogue before it leaves this machine, and is
# never put into a command, a path or a log line here; what comes back is printed only as the envelope of 5.2.

function New-ClientId([string]$Prefix = 'c') { $Prefix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12) }

# A flag's text. ConvertFrom-Flags turns the words true and false into booleans; a message that says "true" is still text.
function Get-FlagText($a, [string]$Key) {
    if (-not $a.ContainsKey($Key)) { return $null }
    $v = $a[$Key]
    if ($v -is [bool]) { return $v.ToString().ToLowerInvariant() }
    return "$v"
}

function Exit-Usage([string]$Reason) { Write-Out @{ ok = $false; code = 'usage'; reason = $Reason } 2 }

# The sender's credential for these calls: the configured worker credential (or its item token), never anything named in a body.
function Get-MessageCredential($Cfg) {
    $holder = if ($env:FACTORY_HOLDER) { $env:FACTORY_HOLDER } else { '' }
    return (Get-WorkerCredential $Cfg $holder)
}

# ---- the credential catalogue (5.4): the client runs the same patterns first, so a refused text never leaves this machine ----------------------
# secrets.patterns of config/instance.json when this machine has it (a working copy does; a downloaded plugin does not), else the shipped list.
$script:FallbackRefusePatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)', 'gh[pousr]_[A-Za-z0-9]{20,}', 'xox[baprs]-[A-Za-z0-9-]{10,}', 'AKIA[0-9A-Z]{16}',
    '\b(w1|w2|m1|i1|q1|o1|k1|r1|n1)\.[A-Za-z0-9_.-]{20,}', '(?i)authorization:\s*bearer\s+[A-Za-z0-9._~+/=-]{20,}',
    '(?i)\b(bearer|token|secret|password|api[_-]?key)\b\s*[:=]\s*(["''][^"'']{8,}["'']|[A-Za-z0-9+/_-]{20,}={0,2})')
$script:SecretRegexes = $null
function Get-SecretRegexes {
    if ($script:SecretRegexes) { return $script:SecretRegexes }
    $list = @()
    try {
        . (Join-Path $PSScriptRoot 'Core.ps1')
        $c = Get-Cfg
        if ($c.ContainsKey('secrets') -and $c.secrets.ContainsKey('patterns')) { $list = @($c.secrets.patterns | Where-Object { $_ }) }
    } catch { }
    if ($list.Count -eq 0) { $list = $script:FallbackRefusePatterns }
    $script:SecretRegexes = @($list | ForEach-Object { [regex]::new("$_", [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds(250)) })
    return $script:SecretRegexes
}

# The patterns run on the text and on its displayed form (the strip set applied), as the gateway does: a token split by a zero-width character
# would reach the model whole. A pattern that times out counts as a match.
function Test-LooksSecret([string]$Text) {
    if (-not $Text) { return $false }
    $forms = @($Text); $d = (Format-MessageText $Text).text; if ($d -ne $Text) { $forms += $d }
    foreach ($f in $forms) {
        foreach ($rx in (Get-SecretRegexes)) {
            try { if ($rx.IsMatch($f)) { return $true } } catch [Text.RegularExpressions.RegexMatchTimeoutException] { return $true }
        }
    }
    return $false
}

function Assert-NoSecret([string]$What, [string]$Text) {
    if (Test-LooksSecret $Text) { Write-Out @{ ok = $false; code = 'secret-in-message'; reason = "the $What looks like a credential or token; messages never carry secrets (worker-messaging.md 5.4). Nothing was sent." } 10 }
}

# Prints the gateway's answer as it is (it carries no message text) and exits with its exit code.
function Write-GatewayResult($R) {
    if (-not $R.transport) { Write-Out @{ ok = $false; code = 'gateway-unreachable'; reason = $R.error; retryAfterSeconds = 15 } 20 }
    $code = Get-GatewayExit $R
    if ($null -eq $R.body) {
        [Console]::Out.WriteLine((@{ ok = $false; code = 'gateway-error'; reason = "HTTP $($R.status)"; exit = $code } | ConvertTo-Json -Compress)); exit $code
    }
    [Console]::Out.WriteLine($R.raw.Trim()); exit $code
}

# A call that is safe to repeat with the same body (a send carries a clientId): a transport failure or a 5xx is tried again, twice at most.
function Invoke-GatewayJsonRetry($Cfg, [string]$Method, [string]$Path, $Body, [string]$Cred, [int]$TimeoutSec = 30) {
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-GatewayJson $Cfg $Method $Path $Body $Cred $TimeoutSec
        if ($r.transport -and $r.status -lt 500) { return $r }
        if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
    }
    return $r
}

# ---- send --to NAME|operator | --all | --thread item-N --text "..." | --text-file F [--subject S] [--item N] [--in-reply-to ID] ------------
function Invoke-MsgSend($a, $cfg) {
    $text = Get-FlagText $a 'text'
    if ([string]::IsNullOrWhiteSpace($text)) { Exit-Usage '--text or --text-file is required' }
    $targets = @(@('to', 'all', 'thread') | Where-Object { $a.ContainsKey($_) })
    if ($targets.Count -ne 1) { Exit-Usage 'exactly one of --to NAME (or operator), --all and --thread item-N is required' }
    $body = [ordered]@{ type = 'note' }
    switch ($targets[0]) {
        'to' { $to = Get-FlagText $a 'to'; if ($to -notmatch '^[A-Za-z0-9_-]{1,40}$') { Exit-Usage '--to is a session name (letters, digits, - and _), or operator' }; $body['to'] = $to }
        'all' { $body['to'] = '*' }
        'thread' { $th = Get-FlagText $a 'thread'; if ($th -notmatch '^item-\d{1,9}$') { Exit-Usage '--thread is item-<number>' }; $body['thread'] = $th }
    }
    if ($a.ContainsKey('subject')) { $body['subject'] = Get-FlagText $a 'subject'; Assert-NoSecret 'subject' $body['subject'] }
    if ($a.ContainsKey('item')) { $n = 0; if (-not [int]::TryParse((Get-FlagText $a 'item'), [ref]$n) -or $n -lt 1) { Exit-Usage '--item is a work item number' }; $body['item'] = $n }
    if ($a.ContainsKey('in_reply_to')) { $re = Get-FlagText $a 'in_reply_to'; if ($re -notmatch '^m-[0-9a-f]{8}-\d{4,}$') { Exit-Usage '--in-reply-to is a message id' }; $body['inReplyTo'] = $re }
    Assert-NoSecret 'text' $text
    $body['text'] = $text
    $body['clientId'] = New-ClientId
    $cred = Get-MessageCredential $cfg
    Write-GatewayResult (Invoke-GatewayJsonRetry $cfg 'POST' '/api/v1/messages' $body $cred)
}

# ---- peers [--all] [--text]: the directory (3.2) --------------------------------------------------------------------------------------------
# Prints the gateway's directory JSON with the supervisor block; --all adds the sessions that are offline (listed for 60 minutes); --text prints
# one line per session instead. A summary is text a peer wrote: it passes the strip set before it is printed, and stays marked untrusted.
function Invoke-MsgPeers($a, $cfg) {
    $q = if ($a.ContainsKey('all') -and $a.all -eq $true) { '?all=1' } else { '' }
    $r = Invoke-GatewayJson $cfg 'GET' "/api/v1/peers$q" $null (Get-MessageCredential $cfg) 30
    if (-not $r.transport -or $r.status -ne 200 -or -not $r.body) { Write-GatewayResult $r }
    $b = $r.body
    foreach ($p in @($b.peers)) { if ($p -is [hashtable] -and $p['summary'] -is [hashtable]) { $p.summary.text = (Format-MessageText "$($p.summary.text)" 140).text } }
    if ($a.ContainsKey('text') -and $a.text -eq $true) {
        $sup = if ($b['supervisor'] -is [hashtable]) { "supervisor: $(if ($b.supervisor.present) { 'present' } else { 'absent' })" } else { 'supervisor: off' }
        [Console]::Out.WriteLine($sup)
        foreach ($p in @($b.peers)) {
            if ($p -isnot [hashtable]) { continue }
            $can = if (-not $p.ContainsKey('canMessage')) { '' } elseif ($p.canMessage) { 'can message' } else { "cannot message ($($p.reason))" }
            $items = (@($p.owned | ForEach-Object { "#$($_.item)" }) -join ' ')
            [Console]::Out.WriteLine(("{0}  {1}  roles={2}  owned={3}  {4}" -f $p.name, $p.presence, (@($p.roles) -join ','), $items, $can).TrimEnd())
        }
        exit 0
    }
    [Console]::Out.WriteLine(($b | ConvertTo-Json -Compress -Depth 8)); exit 0
}

# ---- inbox [--after SEQ] [--wait S] [--id M] [--include delivered] [--ack] ------------------------------------------------------------------
# Prints one json object: the envelopes (5.2) of the messages not printed before, in `messages`. A poll never acknowledges at the gateway, so this
# verb does it by itself once it printed (delivered); --ack also marks what it printed handled. The cursor and the epoch are kept in the worker
# directory; a changed epoch voids the cursor and asks the open questions once more. With --wait it long-polls, and retries on exit 20.
function Invoke-MsgInbox($a, $cfg) {
    $cred = Get-MessageCredential $cfg; $name = Get-CredentialName $cred
    $include = $false
    if ($a.ContainsKey('include')) { if ((Get-FlagText $a 'include') -ne 'delivered') { Exit-Usage '--include is delivered' }; $include = $true }
    $id = if ($a.ContainsKey('id')) { Get-FlagText $a 'id' } else { '' }
    if ($id -and $id -notmatch '^m-[0-9a-f]{8}-\d{4,}$') { Exit-Usage '--id is a message id' }
    $wait = 0.0
    if ($a.ContainsKey('wait')) { if (-not [double]::TryParse((Get-FlagText $a 'wait'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$wait) -or $wait -lt 0) { Exit-Usage '--wait is a number of seconds' } }
    $wait = [Math]::Min($wait, 3600)
    $after = 0L
    if ($a.ContainsKey('after')) { if (-not [long]::TryParse((Get-FlagText $a 'after'), [ref]$after) -or $after -lt 0) { Exit-Usage '--after is a sequence number' } }
    $cur = if ($name) { Get-InboxCursor $name } else { $null }
    $useCursor = (-not $a.ContainsKey('after')) -and (-not $include) -and (-not $id)
    if ($useCursor -and $cur) { $after = $cur.after }
    $deadline = (Get-Date).AddSeconds($wait)
    $reasked = @()
    while ($true) {
        $left = ($deadline - (Get-Date)).TotalSeconds
        $t = if ($wait -gt 0 -and $left -gt 0.5) { [int][Math]::Max(1, [Math]::Min(55, [Math]::Floor($left))) } else { 0 }
        $q = "limit=50"
        if ($id) { $q += "&id=$id" } else { $q += "&after=$after"; if ($t -gt 0) { $q += "&timeout=$t" }; if ($include) { $q += '&include=delivered' } }
        if ($cur -and $cur.epoch -and -not $id -and $useCursor) { $q += "&epoch=$([uri]::EscapeDataString("$($cur.epoch)"))" }
        $r = Invoke-GatewayJson $cfg 'GET' "/api/v1/inbox?$q" $null $cred ($t + 20)
        if (-not $r.transport -or $r.status -ge 500 -or $r.status -eq 429) {
            # exit 20: the gateway is away or restarting; with --wait this tries again after the time it asked for, else 15 s
            if ($wait -le 0 -or $left -le 1) { Write-GatewayResult $r }
            $ra = if ($r.body -and $r.body.retryAfterSeconds) { [int]$r.body.retryAfterSeconds } else { 15 }
            Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Min($ra, [Math]::Floor($left)))); continue
        }
        if ($r.status -ne 200 -or -not $r.body) { Write-GatewayResult $r }
        $j = $r.body; $epoch = "$($j.epoch)"
        if ($j.epochChanged -eq $true -and $name) {
            # the gateway is a new process: the cursor is void and the open questions it lost are asked once more (3.6)
            $after = 0; $cur = $null
            $reasked += @(Invoke-QuestionReask $cfg $cred $name $epoch -Quiet)
        }
        $shown = @(); $held = 0
        # (the answer stays under the size a command's output arrives whole at: what does not fit waits for the next call, more says how many)
        if ([int]$j.count -gt 0) { $shown = @(ConvertTo-PresentedMessages @($j.messages) $cfg $cred $name $epoch -IncludeSeen:($include -or [bool]$id) -Full:([bool]$id) -MaxChars $script:AnswerMaxChars); $held = $script:PresentedHeld }
        if ($shown.Count -gt 0) {
            if ($a.ContainsKey('ack') -and $a.ack -eq $true) { [void](Send-MessageAck $cfg $cred @($shown | ForEach-Object { "$($_.id)" }) 'handled') }
            $lastShown = if ($held -gt 0) { [long]$script:PresentedLastSeq } else { [long]$j.last }
            if ($name -and $useCursor) { Save-InboxCursor $name $epoch $lastShown }
            $out = [ordered]@{ ok = $true; epoch = $epoch; count = $shown.Count; last = $lastShown }
            if ($held -gt 0) { $out['more'] = $held; $out['note'] = 'more messages wait than one answer holds: run inbox again (with --after the last of this answer when you passed --after or --include)' }
            $out['messages'] = $shown
            if ($reasked.Count -gt 0) { $out['reasked'] = @($reasked | ForEach-Object { [ordered]@{ was = $_.was; id = $_.id } }) }
            $out['exit'] = 0
            [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8)); exit 0
        }
        if ($name -and $useCursor -and $epoch) { Save-InboxCursor $name $epoch ([long]$(if ($j.epochChanged -eq $true) { 0 } else { $after })) }
        if ($wait -le 0 -or $left -le 0.5) {
            $out = [ordered]@{ ok = $true; epoch = $epoch; count = 0; last = $after; messages = @() }
            if ($reasked.Count -gt 0) { $out['reasked'] = @($reasked | ForEach-Object { [ordered]@{ was = $_.was; id = $_.id } }) }
            $code = if ($wait -gt 0) { 21 } else { 0 }
            $out['exit'] = $code
            [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8)); exit $code
        }
        # the gateway had messages this client already printed (and has now acknowledged): wait for the next ones
        if ([int]$j.count -gt 0) { Start-Sleep -Seconds 1 }
    }
}

# ---- ack --ids a,b | --up-to SEQ ----------------------------------------------------------------------------------------------------------
function Invoke-MsgAck($a, $cfg) {
    $body = [ordered]@{}
    if ($a.ContainsKey('ids')) {
        $ids = @((Get-FlagText $a 'ids') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($ids.Count -eq 0 -or $ids.Count -gt 100 -or @($ids | Where-Object { $_ -notmatch '^m-[0-9a-f]{8}-\d{4,}$' }).Count -gt 0) { Exit-Usage '--ids is 1 to 100 message ids, separated by commas' }
        $body['ids'] = $ids; $body['state'] = 'handled'
    }
    elseif ($a.ContainsKey('up_to')) {
        $n = 0L; if (-not [long]::TryParse((Get-FlagText $a 'up_to'), [ref]$n) -or $n -lt 0) { Exit-Usage '--up-to is a sequence number' }
        $body['upTo'] = $n
    }
    else { Exit-Usage 'ack needs --ids a,b or --up-to SEQ' }
    Write-GatewayResult (Invoke-GatewayJson $cfg 'POST' '/api/v1/messages/ack' $body (Get-MessageCredential $cfg) 30)
}

# ---- presence [--summary "..."]: a heartbeat in itself ------------------------------------------------------------------------------------
function Invoke-MsgPresence($a, $cfg) {
    $body = [ordered]@{}
    if ($a.ContainsKey('summary')) { $s = Get-FlagText $a 'summary'; Assert-NoSecret 'summary' $s; $body['summary'] = $s }
    Write-GatewayResult (Invoke-GatewayJson $cfg 'POST' '/api/v1/presence' $body (Get-MessageCredential $cfg) 30)
}

# One state check of a message this session sent, long-polling up to $Seconds for a question's answer, and following a re-ask across a gateway
# restart: when the id belongs to an earlier epoch the open questions are asked once more and the poll continues on the new id.
function Get-MessageStateLoop($Cfg, [string]$Cred, [string]$Name, [string]$Id, [double]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds); $reasked = @(); $r = $null
    while ($true) {
        $left = ($deadline - (Get-Date)).TotalSeconds
        # the whole of what is left is asked for (the gateway takes a fraction): a whole number of seconds rounded down ended the wait up to 1 s early
        $slice = if ($left -gt 0.05) { [Math]::Round([Math]::Min(55.0, $left), 2) } else { 0.0 }
        $r = Invoke-GatewayJson $Cfg 'GET' ("/api/v1/messages/$Id" + $(if ($slice -gt 0) { "?wait=$($slice.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture))" } else { '' })) $null $Cred ([int][Math]::Ceiling($slice) + 20)
        if (-not $r.transport -or $r.status -ge 500 -or $r.status -eq 429) {
            if ($left -le 1) { break }
            $ra = if ($r.body -and $r.body.retryAfterSeconds) { [int]$r.body.retryAfterSeconds } else { 15 }
            Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Min($ra, [Math]::Floor($left)))); continue
        }
        if ($r.status -eq 404 -and $r.body -and $r.body.epochChanged -eq $true) {
            $reasked += @(Invoke-QuestionReask $Cfg $Cred $Name "$($r.body.epoch)" -Quiet)
            $q = if ($Name) { Find-Question $Name $Id } else { $null }
            if ($q -and "$($q.id)" -ne $Id) { $Id = "$($q.id)"; continue }
            break
        }
        if ($r.status -eq 200 -and $r.body -and "$($r.body.type)" -eq 'question' -and "$($r.body.state)" -eq 'open' -and $left -gt 0.05) { continue }
        break
    }
    return @{ r = $r; id = $Id; reasked = $reasked }
}

# The answer to a question as the model gets it: the envelope of 5.2 (never the gateway's JSON), recorded in the seen set and acknowledged delivered.
# An explicit request for the answer shows it even if the stream printed it a moment earlier.
function ConvertTo-AnswerEnvelope($Cfg, [string]$Cred, [string]$Name, $Answer, [string]$Epoch) {
    $shown = @(ConvertTo-PresentedMessages @($Answer) $Cfg $Cred $Name $Epoch -IncludeSeen)
    if ($shown.Count -gt 0) { return $shown[0] }
    return $null
}

# ---- message-status --id M [--wait S] -----------------------------------------------------------------------------------------------------
function Invoke-MsgStatus($a, $cfg) {
    $id = Get-FlagText $a 'id'
    if (-not $id -or $id -notmatch '^m-[0-9a-f]{8}-\d{4,}$') { Exit-Usage '--id is a message id' }
    $wait = 0.0
    if ($a.ContainsKey('wait')) { if (-not [double]::TryParse((Get-FlagText $a 'wait'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$wait) -or $wait -lt 0) { Exit-Usage '--wait is a number of seconds' } }
    $cred = Get-MessageCredential $cfg; $name = Get-CredentialName $cred
    $res = Get-MessageStateLoop $cfg $cred $name $id ([Math]::Min($wait, 120))
    $r = $res.r
    if (-not $r.transport -or $null -eq $r.body) { Write-GatewayResult $r }
    if ($r.status -eq 404 -and $res.reasked.Count -gt 0) {
        # an earlier epoch's question that could not be followed (refused, or the gateway went away again): say what was done
        $out = [ordered]@{ ok = $true; id = $id; state = 'open'; epochChanged = $true; reasked = @($res.reasked | ForEach-Object { [ordered]@{ was = $_.was; id = $_.id } }); exit = 21 }
        [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 6)); exit 21
    }
    if ($r.status -ne 200) { Write-GatewayResult $r }
    $b = $r.body
    if ($b.ContainsKey('answer') -and $b.answer -is [hashtable]) {
        $env2 = ConvertTo-AnswerEnvelope $cfg $cred $name $b.answer "$($b.epoch)"
        $b.answer = $env2
        if ($name) { try { Close-Question $name $res.id } catch { } }
    }
    if ("$($b.state)" -in 'expired', 'moot' -and $name) { try { Close-Question $name $res.id } catch { } }
    if ($res.id -ne $id) { $b.was = $id; $b.reasked = @($res.reasked | ForEach-Object { [ordered]@{ was = $_.was; id = $_.id } }) }
    $code = if ($b.ContainsKey('exit')) { [int]$b.exit } else { 0 }
    [Console]::Out.WriteLine(($b | ConvertTo-Json -Compress -Depth 8)); exit $code
}

# ---- ask --text "..." | --text-file F [--item N] [--context "..."] [--wait S] ---------------------------------------------------------------
# A question to the supervisor (6.4). The gateway records it and answers at once (202, exit 21): pending, or no-supervisor (it waits for one).
# The question goes into the worker directory (questions-<name>.json) so it can be asked again after a gateway restart (3.6). With --wait S the call
# long-polls for the answer and exits 0 with the supervisor.answer envelope; it does not wait when no supervisor is present.
function Invoke-MsgAsk($a, $cfg) {
    $text = Get-FlagText $a 'text'
    if ([string]::IsNullOrWhiteSpace($text)) { Exit-Usage '--text or --text-file is required' }
    $wait = 0.0
    if ($a.ContainsKey('wait')) { if (-not [double]::TryParse((Get-FlagText $a 'wait'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$wait) -or $wait -lt 0) { Exit-Usage '--wait is a number of seconds' } }
    $wait = [Math]::Min($wait, 120)
    $body = [ordered]@{ type = 'question'; text = $text }
    $item = $null
    if ($a.ContainsKey('item')) { $n = 0; if (-not [int]::TryParse((Get-FlagText $a 'item'), [ref]$n) -or $n -lt 1) { Exit-Usage '--item is a work item number' }; $item = $n; $body['item'] = $n }
    $context = $null
    if ($a.ContainsKey('context')) { $context = Get-FlagText $a 'context'; Assert-NoSecret 'context' $context; $body['context'] = $context }
    Assert-NoSecret 'text' $text
    $cred = Get-MessageCredential $cfg; $name = Get-CredentialName $cred
    $clientId = New-ClientId; $body['clientId'] = $clientId
    $r = Invoke-GatewayJsonRetry $cfg 'POST' '/api/v1/messages' $body $cred
    if (-not $r.transport -or $r.status -ne 202 -or -not $r.body -or -not $r.body.id) { Write-GatewayResult $r }
    $qid = "$($r.body.id)"
    # a question the gateway recognised as one asked before and still open (issue 105: same item, same text, within an hour) is that question: stored once
    if ($name -and -not ($r.body.duplicate -eq $true -and (Find-Question $name $qid))) {
        $rec = @{ id = $qid; ids = @(); text = $text; item = $item; context = $context; clientId = $clientId; epoch = "$($r.body.epoch)"; reasked = ''; askedAt = [DateTime]::UtcNow.ToString('o') }
        try { Add-Question $name $rec } catch { [Console]::Error.WriteLine("the question could not be stored for a re-ask: $($_.Exception.Message)") }
    }
    if ($wait -le 0 -or "$($r.body.code)" -ne 'pending') { Write-GatewayResult $r }
    $res = Get-MessageStateLoop $cfg $cred $name $qid $wait
    $s = $res.r
    if ($s.transport -and $s.status -eq 200 -and $s.body -and "$($s.body.state)" -eq 'answered' -and $s.body.answer -is [hashtable]) {
        $env2 = ConvertTo-AnswerEnvelope $cfg $cred $name $s.body.answer "$($s.body.epoch)"
        if ($name) { try { Close-Question $name $res.id } catch { } }
        $out = [ordered]@{ ok = $true; id = $res.id; type = 'question'; state = 'answered'; answer = $env2 }
        if ($res.id -ne $qid) { $out['was'] = $qid }
        $out['exit'] = 0
        [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8)); exit 0
    }
    if ($s.transport -and $s.status -eq 200 -and $s.body -and "$($s.body.state)" -in 'expired', 'moot') {
        # expired, or moot (this session lost the item before the supervisor saw the question): nobody will answer it, and it is not asked again
        if ($name) { try { Close-Question $name $res.id } catch { } }
        [Console]::Out.WriteLine((([ordered]@{ ok = $true; id = $res.id; type = 'question'; state = "$($s.body.state)"; exit = 0 }) | ConvertTo-Json -Compress)); exit 0
    }
    # no answer within --wait (or the gateway could not be reached for the rest of it): still pending, the id is printed
    $out = [ordered]@{ ok = $true; id = $res.id; type = 'question'; state = 'open'; code = 'pending'; supervisor = "$($r.body.supervisor)" }
    if ($res.id -ne $qid) { $out['was'] = $qid }
    $out['exit'] = 21
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress)); exit 21
}

# ---- the supervisor's verbs (6.4): answer, direct, questions, plant-digest, patrol-ack ------------------------------------------------------
# They use the supervisor credential (FACTORY_SUPERVISOR_TOKEN, else the keyring entry kind supervisor-token of this session's name). The gateway
# decides who the supervisor is: any other credential is answered not-supervisor or forbidden (exit 30).
function Get-SupervisorCredential($Cfg) {
    $holder = if ($env:FACTORY_HOLDER) { $env:FACTORY_HOLDER } else { '' }
    return (Get-WorkerCredential $Cfg $holder -Supervisor)
}

# ---- answer --id M --text "..." | --text-file F [--note "..."]   or   answer --batch-file F -------------------------------------------------
# One answer, or up to 5 in one call (one step of the budget): the batch file is a JSON array of { inReplyTo, text, note }. The gateway answers a
# batch with one row per entry in `answers` (ok, or its code); the call exits 0 when at least one stood. An answer is not repeated by this client:
# after a failed call the same command is safe to run again, and a question that was answered the first time says already-answered.
function Invoke-MsgAnswer($a, $cfg) {
    $body = [ordered]@{ type = 'answer' }
    if ($a.ContainsKey('batch')) {
        if ($a.ContainsKey('id') -or $a.ContainsKey('text') -or $a.ContainsKey('note')) { Exit-Usage 'answer takes either --batch-file F or --id M with --text-file F and --note' }
        $list = try { Get-FlagText $a 'batch' | ConvertFrom-Json -AsHashtable -NoEnumerate } catch { $null }
        if ($list -isnot [array] -or $list.Count -lt 1 -or $list.Count -gt 5 -or @($list | Where-Object { $_ -isnot [hashtable] }).Count -gt 0) { Exit-Usage '--batch-file is a JSON array of 1 to 5 objects { "inReplyTo": "<question id>", "text": "<answer>", "note": "<one line>" }' }
        $rows = @()
        foreach ($e in $list) {
            $extra = @($e.Keys | Where-Object { $_ -cnotin 'inReplyTo', 'text', 'note' })
            if ($extra.Count -gt 0) { Exit-Usage "an entry of the batch file carries inReplyTo, text and note only (found '$($extra[0])')" }
            if ("$($e['inReplyTo'])" -notmatch '^m-[0-9a-f]{8}-\d{4,}$') { Exit-Usage 'inReplyTo is the id of a question' }
            if ($e['text'] -isnot [string] -or [string]::IsNullOrWhiteSpace($e['text'])) { Exit-Usage "the answer to $($e['inReplyTo']) has no text" }
            Assert-NoSecret 'text' $e['text']
            $row = [ordered]@{ inReplyTo = "$($e['inReplyTo'])"; text = $e['text'] }
            if ($e.ContainsKey('note') -and $null -ne $e['note']) { if ($e['note'] -isnot [string]) { Exit-Usage 'note is one line of text' }; Assert-NoSecret 'note' $e['note']; $row['note'] = $e['note'] }
            $rows += $row
        }
        $body['answers'] = @($rows)
    }
    else {
        $id = Get-FlagText $a 'id'
        if (-not $id -or $id -notmatch '^m-[0-9a-f]{8}-\d{4,}$') { Exit-Usage '--id is the id of a question (or use --batch-file F)' }
        $text = Get-FlagText $a 'text'
        if ([string]::IsNullOrWhiteSpace($text)) { Exit-Usage '--text or --text-file is required' }
        Assert-NoSecret 'text' $text
        $body['inReplyTo'] = $id; $body['text'] = $text
        if ($a.ContainsKey('note')) { $note = Get-FlagText $a 'note'; Assert-NoSecret 'note' $note; $body['note'] = $note }
    }
    Write-GatewayResult (Invoke-GatewayJson $cfg 'POST' '/api/v1/messages' $body (Get-SupervisorCredential $cfg) 60)
}

# ---- direct --to NAME | --all [--kind directive|announcement] --text "..." | --text-file F [--item N] ---------------------------------------
function Invoke-MsgDirect($a, $cfg) {
    $text = Get-FlagText $a 'text'
    if ([string]::IsNullOrWhiteSpace($text)) { Exit-Usage '--text or --text-file is required' }
    $kind = if ($a.ContainsKey('kind')) { Get-FlagText $a 'kind' } else { 'directive' }
    if ($kind -cnotin 'directive', 'announcement') { Exit-Usage '--kind is directive or announcement' }
    $targets = @(@('to', 'all') | Where-Object { $a.ContainsKey($_) })
    if ($targets.Count -ne 1) { Exit-Usage 'exactly one of --to NAME and --all is required' }
    $body = [ordered]@{ type = $kind }
    if ($targets[0] -eq 'all') { $body['to'] = '*' }
    else { $to = Get-FlagText $a 'to'; if ($to -notmatch '^[A-Za-z0-9_-]{1,40}$') { Exit-Usage '--to is a session name (letters, digits, - and _)' }; $body['to'] = $to }
    if ($a.ContainsKey('item')) { $n = 0; if (-not [int]::TryParse((Get-FlagText $a 'item'), [ref]$n) -or $n -lt 1) { Exit-Usage '--item is a work item number' }; $body['item'] = $n }
    Assert-NoSecret 'text' $text
    $body['text'] = $text
    $body['clientId'] = New-ClientId
    Write-GatewayResult (Invoke-GatewayJsonRetry $cfg 'POST' '/api/v1/messages' $body (Get-SupervisorCredential $cfg))
}

# ---- questions [--state open|all]: the supervisor's own queue, once after a restart or compaction -------------------------------------------
# The questions are workers' text: each is printed as in a supervisor.questions line (strip set, text last, marked untrusted), never as the gateway's JSON.
function Invoke-MsgQuestions($a, $cfg) {
    $state = if ($a.ContainsKey('state')) { Get-FlagText $a 'state' } else { 'open' }
    if ($state -cnotin 'open', 'all') { Exit-Usage '--state is open or all' }
    $r = Invoke-GatewayJson $cfg 'GET' "/api/v1/questions?state=$state" $null (Get-SupervisorCredential $cfg) 30
    if (-not $r.transport -or $r.status -ne 200 -or -not $r.body) { Write-GatewayResult $r }
    $b = $r.body
    $qs = @(@($b.questions) | Where-Object { $_ -is [hashtable] } | ForEach-Object { ConvertTo-QuestionEntry $_ -Full })
    $out = [ordered]@{ ok = $true; provider = 'client'; event = 'supervisor.question-list'; state = $state; trust = 'untrusted-worker-question'; count = $qs.Count }
    if ($b['counts'] -is [hashtable]) { $c = [ordered]@{}; foreach ($k in 'open', 'late', 'escalated', 'moot', 'answered', 'expired') { if ($b.counts[$k] -is [ValueType]) { $c[$k] = [int64]$b.counts[$k] } }; $out['counts'] = $c }
    $out['warning'] = $script:QuestionsWarning
    $out['questions'] = $qs
    $out['exit'] = 0
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8)); exit 0
}

# ---- plant-digest: the digest of this moment, once after a restart or compaction (the routine receives supervisor.patrol and never polls this) ---
function Invoke-MsgDigest($a, $cfg) {
    $r = Invoke-GatewayJson $cfg 'GET' '/api/v1/digest' $null (Get-SupervisorCredential $cfg) 30
    if (-not $r.transport -or $r.status -ne 200 -or $r.body['digest'] -isnot [hashtable]) { Write-GatewayResult $r }
    $e = ConvertTo-PatrolEnvelope $r.body.digest
    $out = [ordered]@{ ok = $true }; foreach ($k in $e.Keys) { $out[$k] = $e[$k] }
    $out['event'] = 'plant.digest'; $out['exit'] = 0
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 8)); exit 0
}

# ---- patrol-ack --seq N [--note "..."]: acknowledges patrol N (its entries are muted at their buckets) and records the one-line decision note ----
function Invoke-MsgPatrolAck($a, $cfg) {
    $n = 0L
    if (-not $a.ContainsKey('seq') -or -not [long]::TryParse((Get-FlagText $a 'seq'), [ref]$n) -or $n -lt 1) { Exit-Usage '--seq is the seq of a supervisor.patrol line' }
    $body = [ordered]@{ seq = $n }
    if ($a.ContainsKey('note')) { $note = (Get-FlagText $a 'note').Trim(); Assert-NoSecret 'note' $note; $body['note'] = $note }
    Write-GatewayResult (Invoke-GatewayJson $cfg 'POST' '/api/v1/supervisor/patrol-ack' $body (Get-SupervisorCredential $cfg) 30)
}

function Invoke-MessageVerb([string]$Verb, $a, $cfg) {
    switch ($Verb) {
        'answer' { Invoke-MsgAnswer $a $cfg }
        'direct' { Invoke-MsgDirect $a $cfg }
        'questions' { Invoke-MsgQuestions $a $cfg }
        'plant-digest' { Invoke-MsgDigest $a $cfg }
        'patrol-ack' { Invoke-MsgPatrolAck $a $cfg }
        'send' { Invoke-MsgSend $a $cfg }
        'peers' { Invoke-MsgPeers $a $cfg }
        'inbox' { Invoke-MsgInbox $a $cfg }
        'ack' { Invoke-MsgAck $a $cfg }
        'ask' { Invoke-MsgAsk $a $cfg }
        'presence' { Invoke-MsgPresence $a $cfg }
        'message-status' { Invoke-MsgStatus $a $cfg }
    }
}
