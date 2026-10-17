# Tier 1 scenarios of the api launch mode, v1 Cursor Cloud Agents (docs/design/agents-roles-launch.md 10, gateway/Runtimes/CursorCloudRuntime.cs),
# against the fake Cursor API of tests/FakeGitHub. The scenario plays the Cursor agent: it takes the r1 from the launch body's MCP server entry
# and calls the gateway's /mcp with it. Suite 'cursor' (owner mode). Uses the helpers of owner.ps1 and mcp.ps1.

$CurLabels = @('factory worker', 'Auto Merge', 'runtime:cursor-cloud')
function Cur-State { Fake 'cursor' }
function Cur-Agents([int]$Item) { , @((Cur-State).agents | Where-Object { $_.body.PSObject.Properties['prompt'] -and "$($_.body.prompt.text)" -match "work item: #$Item," }) }
function Cur-R1($Agent) { "$($Agent.body.mcpServers[0].headers.Authorization)".Substring(7) }
function Cur-Status { (Get-Plant).runtimes.'cursor-cloud' }
function Cur-Cleanup([int[]]$Items) {
    foreach ($n in $Items) { if ($n) { [void](Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/$n" -Method PATCH -Headers @{ Authorization = 'Bearer fake-operator' } -Body (@{ state = 'closed' } | ConvertTo-Json) -ContentType 'application/json') } }
    foreach ($a in @((Cur-State).agents | Where-Object { -not $_.deleted -and $_.status -eq 'ACTIVE' })) { [void](Fake 'cursor-agent' @{ id = $a.id; status = 'ARCHIVED' }) }
    [void](Wait-Until -Seconds 20 { (Cur-Status).running -eq 0 })
    [void](Invoke-RestMethod "http://127.0.0.1:$($script:ApiPort)/api/v1/runtimes/cursor-cloud/reset" -Method POST -Headers @{ Authorization = 'Bearer test-token' })
}

$CursorScenarios = [ordered]@{

'cursor: an item labelled runtime:cursor-cloud launches one agent with the bootstrap prompt, the repository at master and the gateway''s /mcp with an r1; the agent works the item by MCP and session_end deletes it' = {
    $n = 0
    try {
        $n = New-Item-Fake 'Cursor docs item' 'Add a line to docs/cursor.md.' $CurLabels
        Check 'an agent is launched for the item' (Wait-Until -Seconds 30 { (Cur-Agents $n).Count -gt 0 })
        $a = (Cur-Agents $n)[0]; $b = $a.body
        Check 'the prompt is prompts/bootstrap/api.md with the item and phase' ("$($b.prompt.text)" -match 'You are a factory worker for ONE phase' -and "$($b.prompt.text)" -match "#$n, phase technical-design") "$($b.prompt.text)"
        Check 'the repository at master, autoCreatePR false' ($b.repos[0].url -eq 'https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders' -and $b.repos[0].startingRef -eq 'master' -and $b.autoCreatePR -eq $false) ($b | ConvertTo-Json -Compress -Depth 6)
        Check 'one MCP server fworker at the gateway''s public /mcp, with an r1 bearer' (@($b.mcpServers).Count -eq 1 -and $b.mcpServers[0].name -eq 'fworker' -and $b.mcpServers[0].url -eq 'http://gw.test/mcp' -and (Cur-R1 $a) -like 'r1.*')
        Check 'the model is Auto with the cost preference: the Cursor Router auto-smart, optimize_for cost (from /v1/models)' ($b.model.id -eq 'auto-smart' -and @($b.model.params).Count -eq 1 -and $b.model.params[0].id -eq 'optimize_for' -and $b.model.params[0].value -eq 'cost') ($b.model | ConvertTo-Json -Compress -Depth 4)
        Check 'the model Cursor reports for the agent is logged' (Wait-Until -Seconds 10 { @(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch '"runtime":"cursor-agent-model"').Count -gt 0 })
        Check 'the agent''s name carries the environment' ($b.name -like 'fworker-tdd-cur-*')
        Check 'no other credential in the launch body' (-not $b.PSObject.Properties['envVars'] -and -not (($b | ConvertTo-Json -Compress -Depth 8) -match 'fake-cursor|i1\.|w1\.|w2\.'))
        Check 'neither the key nor the r1 is in the gateway log' (@(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch 'fake-cursor').Count -eq 0 -and @(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch (Cur-R1 $a)).Count -eq 0)
        $st = Cur-Status
        Check 'status: the agent runs under the cursor-cloud runtime' ($st.running -eq 1 -and @($st.executions | Where-Object { $_.item -eq $n -and $_.execution -eq $a.id }).Count -eq 1) ($st | ConvertTo-Json -Compress -Depth 5)
        $r1 = Cur-R1 $a
        Check 'the r1 is a worker of the api mode: the worker tools' ((Mcp-ToolNames $r1) -contains 'get_prompt')
        $p = Mcp-Call 'get_prompt' @{} $r1
        Check 'get_prompt gives the technical-design prompt' (-not $p.isError -and $p.body.prompt -eq 'worker/technical-design')
        $cur = ''; $got = $false
        Check 'the offer arrives by next_event' (Wait-Until -Seconds 30 { $e = Mcp-Events $r1 $cur 5; @($e.events | Where-Object { $_.event -eq 'item.assigned' -and $_.item -eq $n }).Count -gt 0 })
        $ac = Mcp-Call 'item_accept' @{ item = $n } $r1
        Check 'the agent accepts its item' (-not $ac.isError) ($ac | ConvertTo-Json -Compress -Depth 4)
        Check 'the plant names the agent''s worker owner' (Wait-Until -Seconds 10 { $o = (Get-Plant).plant.owners; $o.PSObject.Properties["$n"] -and "$($o."$n")" -like "cur-$n-*" })
        $row = @((Get-Plant).plant.workers | Where-Object { $_.name -like "cur-$n-*" })
        Check 'its worker shows mode api' ($row.Count -eq 1 -and $row[0].mode -eq 'api' -and $row[0].execution -eq $a.id) ($row | ConvertTo-Json -Compress)
        [void](Mcp-Call 'session_end' @{ reason = 'scenario done' } $r1)
        Check 'session_end cancels the run and deletes the agent' (Wait-Until -Seconds 15 { $x = @((Cur-State).agents | Where-Object { $_.id -eq $a.id }); $x.Count -eq 1 -and $x[0].cancelled -and $x[0].deleted })
        Check 'status shows the model asked for and the model Cursor reports' (Wait-Until -Seconds 10 { $d = @((Cur-Status).last | Where-Object { $_.execution -eq $a.id }); $d.Count -eq 1 -and $d[0].detail.model.id -eq 'auto-smart' -and $d[0].detail.reportedModel.id -eq 'auto-smart' -and $d[0].detail.usage.totalTokens -eq 2340 }) ((Cur-Status).last | ConvertTo-Json -Compress -Depth 6)
        Check 'its token usage is logged' (Wait-Until -Seconds 10 { @(Get-ChildItem $script:Work -Filter 'gateway*.out' | Select-String -SimpleMatch "`"runtime`":`"cursor-usage`"").Count -gt 0 })
        Check 'and the runtime no longer counts it' (Wait-Until -Seconds 15 { (Cur-Status).running -eq 0 })
    } finally { Cur-Cleanup @($n) }
}

'cursor: v1 takes docs-only items only: a code item labelled for it in Development is not launched' = {
    $n = 0
    try {
        $before = @((Cur-State).agents).Count
        $n = New-Item-Fake 'Cursor code item' 'Change src/Foo.cs.' $CurLabels 'Development'
        $script:mid = $null; $s0 = "$((Get-Plant).lastSweep)"
        Check 'two sweeps read the item' (Wait-Until -Seconds 40 { $s1 = "$((Get-Plant).lastSweep)"; if ($s1 -ne $s0 -and -not $script:mid) { $script:mid = $s1 }; $script:mid -and $s1 -ne $script:mid })
        $script:mid = $null
        Check 'no agent is launched for it' ((Cur-Agents $n).Count -eq 0 -and @((Cur-State).agents).Count -eq $before)
    } finally { Cur-Cleanup @($n) }
}

'cursor: an agent that ends by itself is deleted and its item taken back; a restarted gateway deletes the agents a former process left' = {
    $n = 0
    try {
        $n = New-Item-Fake 'Cursor idle' 'x' $CurLabels
        Check 'an agent is launched' (Wait-Until -Seconds 30 { (Cur-Agents $n).Count -gt 0 })
        $a = (Cur-Agents $n)[0]
        [void](Fake 'cursor-agent' @{ id = $a.id; status = 'IDLE'; run = 'FINISHED' })
        Check 'its end is seen and the agent deleted' (Wait-Until -Seconds 20 { @((Cur-State).agents | Where-Object { $_.id -eq $a.id -and $_.deleted }).Count -eq 1 })
        $o = (Fake 'cursor-add' @{ name = 'fworker-tdd-cur-999-abcdef'; ageMinutes = 30 }).id
        $young = (Fake 'cursor-add' @{ name = 'fworker-tdd-cur-997-abcdef' }).id
        $other = (Fake 'cursor-add' @{ name = 'fworker-prod-cur-998-abcdef'; ageMinutes = 30 }).id
        Restart-Gateway
        Check 'after a restart the left-over fworker agent of this environment is deleted' (Wait-Until -Seconds 30 { @((Cur-State).agents | Where-Object { $_.id -eq $o -and $_.deleted }).Count -eq 1 })
        Check 'a young one (a former process may still run it during a rollover) is left alone' (@((Cur-State).agents | Where-Object { $_.id -eq $young -and -not $_.deleted }).Count -eq 1)
        Check 'another environment''s agent is left alone' (@((Cur-State).agents | Where-Object { $_.id -eq $other -and -not $_.deleted }).Count -eq 1)
    } finally { Cur-Cleanup @($n) }
}

'cursor: a failed launch frees the slot and the item gets a new agent; an agent past api.cursor.maxMinutes is cancelled and deleted' = {
    $n = 0
    try {
        [void](Fake 'cursor-launch-failures' @{ count = 1 })
        $n = New-Item-Fake 'Cursor relaunch' 'x' $CurLabels
        Check 'after the failed launch a new agent is launched' (Wait-Until -Seconds 40 { (Cur-Agents $n).Count -ge 1 })
        Check 'status: the failure was counted against the item' (@((Cur-Status).failures | Where-Object { $_.item -eq $n -and $_.count -ge 1 }).Count -eq 1) (Cur-Status | ConvertTo-Json -Compress -Depth 5)
        $a = (Cur-Agents $n)[-1]
        Check 'the deadline (0.25 min in this suite) cancels and deletes it' (Wait-Until -Seconds 60 { $x = @((Cur-State).agents | Where-Object { $_.id -eq $a.id }); $x.Count -eq 1 -and $x[0].deleted })
        Check 'its r1 no longer works: the name is revoked when its agent ends' (Wait-Until -Seconds 30 { (Mcp 'tools/list' @{} (Cur-R1 $a)).status -eq 401 })
    } finally { Cur-Cleanup @($n) }
}
}
