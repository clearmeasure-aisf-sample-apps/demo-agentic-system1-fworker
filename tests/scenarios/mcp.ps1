# Tier 1 scenarios of the gateway's MCP server (docs/design/agents-roles-launch.md 6, gateway/Mcp/): Streamable HTTP at /mcp, the bearer
# credential, tools/list by role and tools/call through the /api/v1 endpoint in-process. Suite 'mcp' (owner mode). Uses the helpers of owner.ps1.

$script:McpId = 0
# One JSON-RPC request to /mcp. The answer is JSON or one SSE event ("data: {...}"): both are read. Returns @{ status; json; text }.
function Mcp([string]$Method, $Params = @{}, [string]$Token = 'test-token') {
    $script:McpId++
    $body = @{ jsonrpc = '2.0'; id = $script:McpId; method = $Method; params = $Params } | ConvertTo-Json -Depth 12 -Compress
    $h = @{ Accept = 'application/json, text/event-stream' }; if ($Token) { $h.Authorization = "Bearer $Token" }
    $r = Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/mcp" -Method POST -Headers $h -Body $body -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 120
    $text = "$($r.Content)"
    $data = @([regex]::Matches($text, '(?m)^data: ?(.*)$') | ForEach-Object { $_.Groups[1].Value })
    $raw = $(if ($data.Count) { $data[-1] } else { $text })
    $json = $null; try { $json = $raw | ConvertFrom-Json -AsHashtable -Depth 30 } catch { }
    return @{ status = [int]$r.StatusCode; json = $json; text = $text }
}
# tools/call: @{ status; isError; body (the tool's JSON text, parsed) }
function Mcp-Call([string]$Name, [hashtable]$Arguments = @{}, [string]$Token = 'test-token') {
    $r = Mcp 'tools/call' @{ name = $Name; arguments = $Arguments } $Token
    $res = $(if ($r.json) { $r.json['result'] } else { $null })
    $b = $null; if ($res -and $res['content']) { try { $b = $res['content'][0]['text'] | ConvertFrom-Json -AsHashtable -Depth 30 } catch { } }
    return @{ status = $r.status; isError = [bool]($res -and $res['isError']); body = $b; rpc = $r.json }
}
function Mcp-ToolNames([string]$Token = 'test-token') { $r = Mcp 'tools/list' @{} $Token; , @($r.json.result.tools | ForEach-Object { $_.name } | Sort-Object) }
function Api-As([string]$Method, [string]$Path, $Body = $null, [string]$Token = 'test-token') {
    $p = @{ Uri = "http://127.0.0.1:$($script:ApiPort)$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $Token" }; SkipHttpErrorCheck = $true; StatusCodeVariable = 'sc' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 8 -Compress); $p.ContentType = 'application/json' }
    $r = Invoke-RestMethod @p
    return @{ status = [int]$sc; body = $r }
}

$McpScenarios = [ordered]@{

'mcp: the owner (admin token) lists the owner read tools; a missing, forged or roleless credential is refused before the server' = {
    $names = Mcp-ToolNames
    Check 'tools/list for the admin token shows exactly the owner tools' (($names -join ',') -eq 'factory_status,item_detail,metrics,workers_and_runs') ($names -join ',')
    $none = Mcp 'tools/list' @{} ''
    Check 'no credential: 401 unauthorized' ($none.status -eq 401 -and $none.text -match '"unauthorized"') "$($none.status) $($none.text)"
    $forged = Mcp 'tools/list' @{} 'w1.alice.0000'
    Check 'a forged credential: 401' ($forged.status -eq 401)
    $w1 = Mcp 'tools/list' @{} (New-WorkerToken 'mcpw1')
    Check 'a worker credential (a seat) has no tools at /mcp yet: 403' ($w1.status -eq 403 -and $w1.text -match '"forbidden"') "$($w1.status) $($w1.text)"
}

'mcp: owner read tools answer what the /api/v1 endpoints answer; refusals keep the endpoint''s code' = {
    $s = Mcp-Call 'factory_status'
    $api = Api-As GET '/api/v1/status'
    Check 'factory_status answers the status JSON' (-not $s.isError -and $s.body.ownerMode -eq $true -and $s.body.ContainsKey('plant')) ($s | ConvertTo-Json -Compress -Depth 4)
    Check 'the same process: the start time is the endpoint''s' ([datetime]$s.body.started -eq [datetime]$api.body.started)
    $w = Mcp-Call 'workers_and_runs'
    Check 'workers_and_runs answers the workers and the runtimes' (-not $w.isError -and $w.body.ContainsKey('workers') -and $w.body.ContainsKey('runtimes')) ($w | ConvertTo-Json -Compress -Depth 4)
    $n = New-Item-Fake 'MCP item detail' 'The body of the item.' $OwnerLabels
    $d = Mcp-Call 'item_detail' @{ item = $n }
    $v = Api-As POST '/api/v1/verbs/get-item' @{ item = $n }
    Check 'item_detail answers the get-item verb''s JSON' (-not $d.isError -and $d.body.ok -eq $true -and $d.body.title -eq 'MCP item detail' -and $d.body.title -eq $v.body.title -and $d.body.status -eq $v.body.status -and $d.body.status -eq 'Technical Design') ($d | ConvertTo-Json -Compress -Depth 4)
    $gone = Mcp-Call 'item_detail' @{ item = 999999 }
    $gv = Api-As POST '/api/v1/verbs/get-item' @{ item = 999999 }
    Check 'a refusal of the verb comes back as an error with the verb''s code and exit' ($gone.isError -and $gone.body.code -eq $gv.body.code -and $gone.body.exit -eq $gv.body.exit) "$($gone | ConvertTo-Json -Compress -Depth 4) / $($gv | ConvertTo-Json -Compress -Depth 4)"
    $u = Mcp-Call 'item_detail' @{}
    Check 'a missing argument is a usage error' ($u.isError -and $u.body.code -eq 'usage' -and $u.body.exit -eq 2) ($u | ConvertTo-Json -Compress -Depth 4)
    $x = Mcp-Call 'no_such_tool'
    Check 'an unknown tool is refused' ($x.isError -and $x.body.code -eq 'unknown-tool')
    $m = Mcp-Call 'metrics' @{ since = '1y' }
    Check 'metrics checks its window' ($m.isError -and $m.body.code -eq 'usage')
    Check 'every call is logged with its tool, role and caller, never a credential' (Wait-Until -Seconds 5 { @(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch '"mcp":"item_detail","role":"owner","caller":"admin:"').Count -gt 0 })
}
}

# ---- the role token r1 (Auth.cs, agents-roles-launch.md 4) ----------------------------------------------------------------------------------
function Role-Token([hashtable]$Claims) { (Api-As POST '/api/v1/_test/role-token' $Claims).body.token }

$McpScenarios['mcp: an r1 round trip: minted, verified for its role, expired, revoked by generation, another environment and another kind''s MAC refused'] = {
    $t = Role-Token @{ name = 'r1own'; role = 'owner'; mode = 'manual' }
    Check 'an r1 is minted' ("$t" -like 'r1.*.*')
    Check 'an owner r1 lists the owner tools at /mcp' (((Mcp-ToolNames $t) -join ',') -eq 'factory_status,item_detail,metrics,workers_and_runs')
    $st = Mcp-Call 'factory_status' @{} $t
    Check 'and its tools answer' (-not $st.isError -and $st.body.ownerMode -eq $true) ($st | ConvertTo-Json -Compress -Depth 3)
    Check 'an r1 cannot wait on an item''s triggers at /api' ((Api-As GET '/api/v1/wait?item=1&timeout=1' $null $t).status -eq 403)
    $v = Api-As POST '/api/v1/verbs/get-item' @{ item = 1 } $t
    Check 'an r1 calls no verb directly' ($v.status -eq 403) ($v | ConvertTo-Json -Compress)
    $p = $t.Split('.'); $forged = "r1.$($p[1]).$('0' * 64)"
    Check 'a forged MAC is refused' ((Mcp 'tools/list' @{} $forged).status -eq 401)
    $asItem = "i1.$($p[1]).$($p[2])"
    Check 'the same payload and MAC as an i1 is refused (domain separation)' ((Api-As POST '/api/v1/verbs/get-item' @{ item = 1 } $asItem).status -eq 401)
    $short = Role-Token @{ name = 'r1short'; role = 'owner'; mode = 'manual'; tokenSeconds = 2 }
    Check 'a short r1 answers before its expiry' ((Mcp 'tools/list' @{} $short).status -eq 200)
    Start-Sleep -Seconds 4
    Check 'and is refused after it' ((Mcp 'tools/list' @{} $short).status -eq 401)
    $prod = Role-Token @{ name = 'r1prod'; role = 'owner'; mode = 'manual'; env = 'prod' }
    Check 'an r1 of another environment is refused' ((Mcp 'tools/list' @{} $prod).status -eq 401)
    $rv = Role-Token @{ name = 'r1rev'; role = 'owner'; mode = 'manual' }
    Check 'before the revocation it answers' ((Mcp 'tools/list' @{} $rv).status -eq 200)
    [void](Api-As POST '/api/v1/workers/r1rev/revoke' @{})
    Check 'a revocation of its name refuses it' (Wait-Until -Seconds 20 { (Mcp 'tools/list' @{} $rv).status -eq 401 })
    $seat = Role-Token @{ name = 'r1seat'; role = 'seat'; mode = 'manual' }
    Check 'a seat r1 has no tools at /mcp in this step' ((Mcp 'tools/list' @{} $seat).status -eq 403)
}

$McpScenarios['mcp: the legacy kinds map to role principals: the admin token is the owner, a worker credential a seat; /status shows mode and role'] = {
    Start-OwnerClient 'r1legacy'
    try {
        $row = @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'r1legacy' })
        Check 'a local worker shows mode manual and role seat' ($row.Count -eq 1 -and $row[0].mode -eq 'manual' -and $row[0].role -eq 'seat') ($row | ConvertTo-Json -Compress)
        Check 'its w1 still works at /api (auth.legacyKinds true)' ((Api-As POST '/api/v1/verbs/my-items' @{} (New-WorkerToken 'r1legacy')).status -eq 200)
    } finally { Stop-OwnerClient 'r1legacy' }
}

# ---- the worker role's tools (agents-roles-launch.md 6.2, 6.3, 7) ------------------------------------------------------------------------
$McpWorkerTools = 'ask,get_prompt,item_accept,item_append_body,item_claim,item_comment,item_complete,item_get,item_record_review,item_release,item_validation_verdict,next_event,pr_checks,pr_open,pr_update,pr_wait_checks,send_note,session_end'
function Mcp-Events([string]$Token, [string]$After = '', [double]$Wait = 0) { (Mcp-Call 'next_event' @{ after = $After; wait_seconds = $Wait } $Token).body }

$McpScenarios['mcp: a worker r1 registers at its first call, gets its offer by next_event without the item token, accepts and works its item through the verbs'] = {
    $name = 'mcpwork1'
    $n = New-Item-Fake 'MCP worker item' 'Write docs/mcp.md.' ($OwnerLabels + "worker:$name")
    $t = Role-Token @{ name = $name; role = 'worker'; mode = 'api'; agent = 'cursor-cloud-agent'; item = $n; phase = 'technical-design' }
    try {
        Check 'tools/list for a technical-design r1 is that phase''s set' (((Mcp-ToolNames $t) -join ',') -eq 'ask,get_prompt,item_accept,item_append_body,item_claim,item_complete,item_get,item_record_review,item_release,next_event,send_note,session_end') ((Mcp-ToolNames $t) -join ',')
        $po = Mcp-Call 'pr_open' @{ item = $n; head = 'x'; title = 'x'; body = 'x' } $t
        Check 'a tool of another phase is refused wrong-phase' ($po.isError -and $po.body.code -eq 'wrong-phase') ($po | ConvertTo-Json -Compress)
        $e = Mcp-Events $t
        Check 'the first call registers the session' (@($e.events | Where-Object { $_.event -eq 'worker.registered' }).Count -eq 1) ($e | ConvertTo-Json -Compress -Depth 5)
        [void](Wait-Until -Seconds 10 { $script:row = @((Get-Plant).plant.workers | Where-Object { $_.name -eq $name }); $script:row.Count -eq 1 })
        Check 'the plant lists it as connected, mode api' ($script:row.Count -eq 1 -and $script:row[0].connected -and $script:row[0].mode -eq 'api') ($script:row | ConvertTo-Json -Compress)
        $cur = "$($e.cursor)"; $got = $null
        Check 'the offer arrives as item.assigned' (Wait-Until -Seconds 40 { $x = Mcp-Events $t $cur 5; $script:got = @($x.events | Where-Object { $_.event -eq 'item.assigned' -and $_.item -eq $n }); $script:got.Count -gt 0 })
        Check 'without the item token' (-not $script:got[0].ContainsKey('token') -and -not (($script:got | ConvertTo-Json -Compress -Depth 5) -match 'i1\.')) ($script:got | ConvertTo-Json -Compress -Depth 5)
        $a = Mcp-Call 'item_accept' @{ item = $n } $t
        Check 'item_accept accepts the assignment' (-not $a.isError -and $a.body.ok -eq $true) ($a | ConvertTo-Json -Compress -Depth 5)
        Check 'the plant names it owner' (Wait-Until -Seconds 10 { $o = (Get-Plant).plant.owners; $o.PSObject.Properties["$n"] -and $o."$n" -eq $name })
        $g = Mcp-Call 'item_get' @{ item = $n } $t
        $v = Api-As POST '/api/v1/verbs/get-item' @{ item = $n }
        Check 'item_get answers what get-item answers' (-not $g.isError -and $g.body.title -eq $v.body.title -and $g.body.status -eq $v.body.status) ($g | ConvertTo-Json -Compress -Depth 3)
        $m = New-Item-Fake 'Someone else''s item' 'x' $OwnerLabels
        $o = Mcp-Call 'item_get' @{ item = $m } $t
        Check 'another item is refused' ($o.isError -and $o.body.code -eq 'forbidden')
        $c = Mcp-Call 'item_complete' @{ item = $n } $t
        $cv = Api-As POST '/api/v1/verbs/complete' @{ item = $n; holder = $name }
        Check 'a gate refusal is the verb''s own code' ($c.isError -and $c.body.code -eq $cv.body.code -and $c.body.exit -eq $cv.body.exit) "$($c.body | ConvertTo-Json -Compress) / $($cv.body | ConvertTo-Json -Compress)"
        $vd = Mcp-Call 'item_validation_verdict' @{ item = $n; passed = $true; summary = 'x'; pr = 1; head_sha = ('0' * 40) } $t
        Check 'the verdict is not a tool of a technical-design session' ($vd.isError -and $vd.body.code -eq 'wrong-phase')
        $sec = Mcp-Call 'send_note' @{ to = 'operator'; text = ('my key is ghp_' + ('A' * 30)) } $t
        Check 'a note that looks like a credential is refused' ($sec.isError -and $sec.body.code -eq 'secret-in-message') ($sec | ConvertTo-Json -Compress)
        $r1note = Mcp-Call 'send_note' @{ to = 'operator'; text = ('token ' + $t) } $t
        Check 'an r1 in a note is refused as well' ($r1note.isError -and $r1note.body.code -eq 'secret-in-message')
        $ok = Mcp-Call 'send_note' @{ to = 'operator'; text = 'starting on the design' } $t
        Check 'a plain note is sent' (-not $ok.isError -and $ok.body.ok -eq $true) ($ok | ConvertTo-Json -Compress)
        $own = Mcp-Call 'factory_status' @{} $t
        Check 'an owner tool is refused to the worker role' ($own.isError -and $own.body.code -eq 'forbidden')
        $end = Mcp-Call 'session_end' @{ reason = 'scenario done' } $t
        Check 'session_end ends the session' (-not $end.isError)
        Check 'the plant no longer sees it connected' (Wait-Until -Seconds 10 { -not (@((Get-Plant).plant.workers | Where-Object { $_.name -eq $name -and $_.connected }).Count) })
        Check 'next_event says the session ended' ((Mcp-Events $t).ended -eq $true)
        $after = Mcp-Call 'item_get' @{ item = $n } $t
        Check 'after session_end its item tools are refused' ($after.isError -and $after.body.code -eq 'no-offer') ($after | ConvertTo-Json -Compress)
        Check 'no item token reached the gateway log' (@(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -Pattern '\bi1\.[A-Za-z0-9_-]{20,}').Count -eq 0)
        Check 'no token reaches the log' (@(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch $t).Count -eq 0)
    } finally { [void](Mcp-Call 'session_end' @{} $t) }
}

$McpScenarios['mcp: a legacy item token is accepted at /mcp as the worker role; a seat r1 and a w1 have no tools'] = {
    $name = 'mcpleg1'
    Start-OwnerClient $name
    try {
        $n = New-Item-Fake 'MCP legacy item' 'x' ($OwnerLabels + "worker:$name")
        Check 'offered to the stream client' (Wait-Until -Seconds 40 { (Get-Assigned $name $n).Count -gt 0 })
        [void](Wait-Until -Seconds 10 { Test-Path (Join-Path $script:Workers[$name].dir "$n.owner") })
        $tok = Get-Content -Raw (Join-Path $script:Workers[$name].dir "$n.owner") -ErrorAction SilentlyContinue
        $tok = "$tok".Trim()
        Check 'the client holds its item token' ($tok -like 'i1.*')
        Check 'the i1 lists the worker tools' (((Mcp-ToolNames $tok) -join ',') -eq $McpWorkerTools)
        $g = Mcp-Call 'item_get' @{ item = $n } $tok
        Check 'and reads its item through them' (-not $g.isError -and $g.body.title -eq 'MCP legacy item')
        $ne = Mcp-Call 'next_event' @{} $tok
        Check 'an i1 has no session: next_event is refused' ($ne.isError -and $ne.body.code -eq 'no-session')
        Check 'a w1 has no tools at /mcp' ((Mcp 'tools/list' @{} (New-WorkerToken $name)).status -eq 403)
    } finally { Stop-OwnerClient $name }
}

# ---- prompts served live (prompts/, gateway/Mcp/Prompts.cs, agents-roles-launch.md 5) ------------------------------------------------------
$McpScenarios['mcp: get_prompt serves the prompt of the session''s role and phase, with the common rules and its agent''s section; /_build reports promptsHash'] = {
    $t = Role-Token @{ name = 'mcpprompt1'; role = 'worker'; mode = 'api'; agent = 'cursor-cloud-agent'; item = 1; phase = 'development' }
    try {
        $p = Mcp-Call 'get_prompt' @{} $t
        Check 'get_prompt answers the development prompt with its version' (-not $p.isError -and $p.body.prompt -eq 'worker/development' -and $p.body.version -ge 1) ($p | ConvertTo-Json -Compress -Depth 3)
        Check 'the common rules come first' ("$($p.body.text)" -match '(?s)^Rules: .*# Development')
        Check 'it is short' ("$($p.body.text)".Length -lt 3000) "$("$($p.body.text)".Length) characters"
        Check 'no front matter in the text' ("$($p.body.text)" -notmatch '(?m)^tools: \[')
        $td = Mcp-Call 'get_prompt' @{ phase = 'technical-design' } $t
        Check 'another phase by argument' (-not $td.isError -and $td.body.prompt -eq 'worker/technical-design')
        $no = Mcp-Call 'get_prompt' @{ phase = 'nothing' } $t
        Check 'an unknown phase is refused' ($no.isError -and $no.body.code -eq 'no-prompt')
        $b = Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/_build"
        Check '/_build reports the prompts hash, the one get_prompt reports' ("$($b.promptsHash)" -match '^[0-9a-f]{16}$' -and $b.promptsHash -eq $p.body.promptsHash)
        Check 'the gateway is ready: every shipped prompt parses' ((Invoke-WebRequest "http://127.0.0.1:$($script:ApiPort)/ready" -SkipHttpErrorCheck).StatusCode -eq 200)
    } finally { [void](Mcp-Call 'session_end' @{} $t) }
}
