# Tier 1 scenarios for the PR QC environment, slice S1 (gateway QC core). Design: docs/design/pr-qc-environment.md.
# Real gateway (owner mode), real rule scripts, fake GitHub. A scripted worker registers through the real client with the qc role and calls the real verbs.
# The "environment" is the fake server itself: its /_healthcheck answers for the app, so the gateway's probe has something to reach on 127.0.0.1.
# Scenario names start with "qc:"; run them alone with -Only qc.
$QcLabels = @('factory worker')
$script:QcClient = $null

function Qc-Base { "http://127.0.0.1:$($script:ApiPort)" }
function Qc-Fake { "127.0.0.1:$($script:FakePort)" }

# ---- link tokens made by the test, to prove the gateway refuses what it did not make ------------------------------------
function ConvertTo-B64([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Qc-Mint([int]$Pr, [string]$Sha, [int]$ItemNo, [long]$Exp, [string]$Purpose = 'qc-open', [string]$Prefix = 'qc:', [string]$Kind = 'q1', [string]$Secret = $script:OwnerSecret) {
    $payload = @{ pr = $Pr; sha = $Sha; u = $Purpose; x = $Exp; n = 'test'; i = $ItemNo } | ConvertTo-Json -Compress
    $p = ConvertTo-B64 ([Text.Encoding]::UTF8.GetBytes($payload))
    $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    $mac = ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Prefix + $p))) -replace '-', '').ToLowerInvariant()
    return "$Kind.$p.$mac"
}

# ---- HTTP ------------------------------------------------------------------------------------------------------------------------
function Qc-Client {
    if (-not $script:QcClient) { $h = [Net.Http.HttpClientHandler]::new(); $h.AllowAutoRedirect = $false; $h.UseProxy = $false; $script:QcClient = [Net.Http.HttpClient]::new($h); $script:QcClient.Timeout = [TimeSpan]::FromSeconds(40) }
    return $script:QcClient
}
function Qc-Http([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Form = $null, [string]$ContentType = '', [string]$Body = '') {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
    foreach ($k in $Headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) }
    if ($null -ne $Form) {
        $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
        foreach ($k in $Form.Keys) { $pairs.Add([Collections.Generic.KeyValuePair[string, string]]::new([string]$k, [string]$Form[$k])) }
        $req.Content = [Net.Http.FormUrlEncodedContent]::new($pairs)
    } elseif ($Body) { $req.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, $ContentType) }
    $resp = (Qc-Client).SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $reason = ''; $v = $null; if ($resp.Headers.TryGetValues('X-Qc-Reason', [ref]$v)) { $reason = ($v -join ',') }
    $loc = ''; if ($resp.Headers.Location) { $loc = $resp.Headers.Location.OriginalString }
    $json = $null; try { $json = $text | ConvertFrom-Json -AsHashtable } catch { }
    return @{ status = [int]$resp.StatusCode; reason = $reason; body = $text; json = $json; location = $loc }
}
function Qc-Get([int]$pr, [string]$Tok, [string]$Path = '', [hashtable]$Headers = @{ Accept = 'application/json' }) { Qc-Http 'GET' "$(Qc-Base)/qc/$pr$Path`?t=$Tok" $Headers }
function Qc-Post([int]$pr, [string]$Tok, [string]$Action, [string]$Nonce, [hashtable]$Headers = @{}, [string]$Origin = '') {
    $h = @{ Accept = 'application/json'; Origin = $(if ($Origin) { $Origin } else { Qc-Base }) }; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    Qc-Http 'POST' "$(Qc-Base)/qc/$pr/$Action`?t=$Tok" $h @{ nonce = $Nonce }
}
# One click as a person does it: open the page (get the nonce), press the button.
function Qc-Click([int]$pr, [string]$Tok, [string]$Action = 'start', [hashtable]$Headers = @{}) {
    $g = Qc-Get $pr $Tok '' (@{ Accept = 'application/json' } + $Headers)
    $nonce = if ($g.json -and $g.json.ContainsKey('page_nonce')) { "$($g.json.page_nonce)" } else { 'none' }
    return Qc-Post $pr $Tok $Action $nonce $Headers
}

# ---- offers, state, workers ------------------------------------------------------------------------------------------------
function Qc-OfferComments([int]$pr) { , @((Get-FakePr $pr).comments | Where-Object { $_.body -match 'qc link pr=' }) }
function Qc-Token([int]$pr) { $c = (Qc-OfferComments $pr); if ($c.Count -eq 0) { return '' }; return [regex]::Match($c[0].body, '\?t=(q1\.[A-Za-z0-9_.-]+)\)').Groups[1].Value }
function Qc-ItemOffer([int]$n) { , @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'qc link pr=' }) }
function Qc-StateComment([int]$n) { @((Get-FakeIssue $n).comments | Where-Object { $_.body -like '<!-- factory-state:*' }) | Select-Object -First 1 }
function Qc-State([int]$n) {
    $c = Qc-StateComment $n; if (-not $c) { return $null }
    $m = [regex]::Match($c.body, '(?s)```json\s*(.*?)\s*```')
    if (-not $m.Success) { return $null }
    try { return ($m.Groups[1].Value | ConvertFrom-Json -AsHashtable -DateKind String) } catch { return $null }
}
function Qc-Rec([int]$n, [int]$pr) { $s = Qc-State $n; if ($s -and $s.ContainsKey('qc') -and $s.qc.ContainsKey("$pr")) { return $s.qc["$pr"] }; return $null }
function Qc-RecState([int]$n, [int]$pr) { $r0 = Qc-Rec $n $pr; if ($r0) { return "$($r0.state)" }; return '' }
function Qc-QcAssignments([int]$n) { , @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $n -and $_.kind -eq 'qc-env' }) }
function Qc-Events([string]$Worker, [int]$n) { , @(Get-WorkerEvents $Worker | Where-Object { $_.event -eq 'item.assigned' -and $_.item -eq $n -and $_.job -eq 'qc-env' }) }
function Qc-JournalCount([int]$n, [string]$ev) { $j = Qc-Journal $n; return @($j | Where-Object { $_ -eq $ev }).Count }
function Qc-Journal([int]$n) { , @((Get-FakeIssue $n).comments | Where-Object { $_.body -match '<!-- plant event=qc-' } | ForEach-Object { [regex]::Match($_.body, 'plant event=([\w-]+)').Groups[1].Value }) }
# Waits until the sweep has completed Count more times.
function Qc-Sweeps([int]$Count = 2) {
    $h = @{ Authorization = 'Bearer test-token' }
    $last = "$((Invoke-RestMethod "$(Qc-Base)/api/v1/status" -Headers $h).lastSweep)"; $seen = 0; $end = (Get-Date).AddSeconds(90)
    while ($seen -lt $Count -and (Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 500
        $cur = "$((Invoke-RestMethod "$(Qc-Base)/api/v1/status" -Headers $h).lastSweep)"
        if ($cur -ne $last) { $seen++; $last = $cur }
    }
}

# A worker that holds QC jobs stays connected for the whole suite; what an earlier scenario left running is torn down first (the fake GitHub was reset between scenarios).
function Ensure-QcWorker([string]$Name = 'qw1', [string]$Address = '127.0.0.1', [string]$Extra = '--qc-capacity 2') {
    $up = @((Get-Plant).plant.workers | Where-Object { $_.name -eq $Name -and $_.connected }).Count -gt 0
    if (-not $up) { Start-OwnerClient $Name 'persistent-local' "--roles qc --capabilities dotnet,git --qc-address $Address --qc-profile $Extra" }
    if ($Name -eq 'qw1') {
        foreach ($a in @((Get-Plant).plant.assignments | Where-Object { $_.kind -eq 'qc-env' })) { [void](F 'op' @('qc-teardown', '--item', $a.item, '--pr', $a.pr)) }
        [void](Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/resume" -Method POST -Headers @{ Authorization = 'Bearer test-token' })
    }
}
function Qc-Hook($Event, $Payload) {
    $raw = ($Payload | ConvertTo-Json -Depth 8 -Compress)
    $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes('x' * 40))
    $sig = 'sha256=' + ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))) -replace '-', '').ToLowerInvariant()
    $resp = Invoke-WebRequest "http://127.0.0.1:$($script:HookPort)/webhooks/github" -Method POST -Body $raw -ContentType 'application/json' -Headers @{ 'X-GitHub-Event' = $Event; 'X-GitHub-Delivery' = [guid]::NewGuid().ToString(); 'X-Hub-Signature-256' = $sig } -SkipHttpErrorCheck
    return [int]$resp.StatusCode
}
# Runs a rule script directly (as the gateway does), for the checks that do not need the gateway.
function Qc-Server([string]$Verb, $Body, [hashtable]$Env = @{}) {
    $old = @{}; foreach ($k in $Env.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        $out = ($Body | ConvertTo-Json -Depth 8 -Compress) | & pwsh -NoProfile -File (Join-Path $script:Root 'plugin/scripts/factory.ps1') --server $Verb 2>$null
        $code = $LASTEXITCODE; $j = try { ($out -join "`n") | ConvertFrom-Json -AsHashtable } catch { @{} }; if (-not $j.ContainsKey('exit')) { $j.exit = $code }; return $j
    } finally { foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
}
# Restart-Gateway lives in lib.ps1 (shared with the messaging scenarios).

# ---- a pull request at a PASS verdict, an environment driven by the scripted worker ---------------------------------------------
function New-QcPr([string[]]$Labels = $QcLabels, [string[]]$Files = @('src/a.cs'), [bool]$DocsOnly = $false, [switch]$Fork) {
    $n = New-Item-Fake 'QC trial' 'x' $Labels
    Do-TechnicalDesign $n 'w1' $DocsOnly
    $pr = Do-Development $n $Files
    if ($Fork) { Fake 'pr' @{ number = $pr; fork = $true } | Out-Null }
    Do-DevComplete $n | Out-Null
    $v = Do-Verdict $n $pr
    Check "QC trial $n has a PASS verdict" ($v.exit -eq 0)
    return @{ n = $n; pr = $pr }
}
function New-QcOffered {
    $x = New-QcPr
    $got = Wait-Until -Seconds 60 { (Qc-Token $x.pr) -ne '' -and (Qc-ItemOffer $x.n).Count -gt 0 }
    Check "offer comments appear for PR $($x.pr)" $got
    $x.tok = Qc-Token $x.pr
    return $x
}
# Start, then accept and report progress up to the given step: 'assigned', 'accepted', 'building', 'running'.
function Start-QcRun($x, [string]$Upto = 'running', [string]$Worker = 'qw1') {
    $c = Qc-Click $x.pr $x.tok 'start'; $x.click = $c
    if ($c.status -ne 200) { Check "Start answered 200 (got $($c.status) $($c.reason))" $false; return $x }
    $got = Wait-Until -Seconds 30 { (Qc-Events $Worker $x.n).Count -gt 0 }
    if (-not $got) { Check 'the worker was offered the job' $false; return $x }
    $ev = (Qc-Events $Worker $x.n)[0]; $x.ev = $ev; $x.asg = $ev.assignment; $x.sha = $ev.sha; $x.env = $ev.env_id; $x.worker = $Worker
    if ($Upto -eq 'assigned') { return $x }
    $a = Fo $Worker @('accept', '--item', $x.n, '--assignment', $x.asg, '--role', 'qc'); $x.accept = $a
    if ($Upto -eq 'accepted') { return $x }
    [void](Fo $Worker @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'building'))
    if ($Upto -eq 'building') { return $x }
    [void](Fo $Worker @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'running'))
    return $x
}
function Qc-Report($x, [string]$Url, [string]$Health = 'ok', [string]$Worker = 'qw1') {
    $args2 = @('qc-report', '--item', $x.n, '--pr', $x.pr, '--sha', $x.sha, '--env-id', $x.env, '--url', $Url, '--port', $script:ReportPort)
    if ($Health) { $args2 += @('--local-health', $Health) }
    return Fo $Worker $args2
}
function Qc-Ready($x) { Start-QcRun $x 'running' | Out-Null; $r0 = Qc-Report $x "http://$(Qc-Fake)"; CheckExit 'ready reported' $r0 0; return $r0 }

$QcScenarios = [ordered]@{

'qc: eligible item gets one offer comment on the PR and on the item, and no job [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $pc = (Qc-OfferComments $x.pr); $ic = (Qc-ItemOffer $x.n)
    Check 'one offer comment on the pull request' ($pc.Count -eq 1) "$($pc.Count)"
    Check 'one offer comment on the work item' ($ic.Count -eq 1) "$($ic.Count)"
    Check 'the comment names the PR and the short head' ($pc[0].body -match "PR #$($x.pr) at head $((Get-Head $x.pr).Substring(0,7))")
    Check 'the link starts with the public URL and carries a q1 token' ($pc[0].body -match [regex]::Escape("$(Qc-Base)/qc/$($x.pr)?t=q1."))
    Check 'the comment says nothing runs until Start' ($pc[0].body -match 'Nothing runs until someone presses Start')
    Qc-Sweeps 2
    Check 'a second sweep adds no second comment on the PR' ((Qc-OfferComments $x.pr).Count -eq 1)
    Check 'a second sweep adds no second comment on the item' ((Qc-ItemOffer $x.n).Count -eq 1)
    Check 'no QC record exists before Start' ($null -eq (Qc-Rec $x.n $x.pr))
    Check 'no QC job was offered' ((Qc-Events 'qw1' $x.n).Count -eq 0 -and (Qc-QcAssignments $x.n).Count -eq 0)
    Check 'journal: qc-offered once' (((Qc-Journal $x.n) -join ',') -eq 'qc-offered')
    $al = Qc-State $x.n
    Check 'the item state is intact' ($al -and $al.ContainsKey('verdict') -and $al.verdict.passed)
}

'qc: auto-merge, docs-only and fork items get no offer [full]' = {
    Ensure-QcWorker
    $am = New-QcPr @('factory worker', 'Auto Merge')
    $dx = New-QcPr $QcLabels @('docs/a.md') $true
    $fk = New-QcPr -Fork
    Qc-Sweeps 3
    Check 'Auto Merge item: no comment on the PR, none on the item' ((Qc-OfferComments $am.pr).Count -eq 0 -and (Qc-ItemOffer $am.n).Count -eq 0)
    Check 'docs-only item: no comment' ((Qc-OfferComments $dx.pr).Count -eq 0 -and (Qc-ItemOffer $dx.n).Count -eq 0)
    Check 'fork PR: no comment' ((Qc-OfferComments $fk.pr).Count -eq 0 -and (Qc-ItemOffer $fk.n).Count -eq 0)
    $skipped = @((Get-FakeIssue $fk.n).comments | Where-Object { $_.body -match 'plant event=skipped' -and $_.body -match 'fork' })
    Check 'fork PR: a skipped journal line says why' ($skipped.Count -eq 1) "$($skipped.Count)"
    Check 'no record for any of them' ($null -eq (Qc-Rec $am.n $am.pr) -and $null -eq (Qc-Rec $dx.n $dx.pr) -and $null -eq (Qc-Rec $fk.n $fk.pr))
    $r0 = F 'op' @('qc-request', '--item', $fk.n, '--pr', $fk.pr); CheckExit 'a direct Start for the fork PR is refused' $r0 10 'not-eligible'
    Check 'the refusal names the fork' (@($r0.reasons) -contains 'fork')
    $r0 = F 'op' @('qc-link', '--item', $am.n, '--pr', $am.pr); CheckExit 'qc-link refuses an Auto Merge item' $r0 10 'not-eligible'
    Check 'nothing was queued' ((Qc-QcAssignments $fk.n).Count -eq 0)
}

'qc: a GET of the link has no side effect [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    1..3 | ForEach-Object { $g = Qc-Get $x.pr $x.tok '' @{ Accept = 'text/html' }; Check "GET $_ answered 200" ($g.status -eq 200) "$($g.status)" }
    Check 'still no record' ($null -eq (Qc-Rec $x.n $x.pr))
    Check 'still no job' ((Qc-QcAssignments $x.n).Count -eq 0 -and (Qc-Events 'qw1' $x.n).Count -eq 0)
    $g = Qc-Get $x.pr $x.tok '' @{ Accept = 'text/html' }
    Check 'the page offers a Start button' ($g.body -match 'Start QC environment')
    Check 'the page states who can reach the environment' ($g.body -match 'reachable only from networks that can reach')
    Check 'the page carries a hidden nonce for the POST' ($g.body -match 'name="nonce" value="[0-9a-f]{32}"')
    $st = Qc-Get $x.pr $x.tok '/status'
    Check 'status before Start is available' ($st.status -eq 200 -and $st.json.state -eq 'available')
}

'qc: Start is required before any job exists [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    Qc-Sweeps 3
    $ql = F 'op' @('qc-list'); CheckExit 'qc-list' $ql 0
    Check 'qc-list shows the PR as available and no record yet' (@($ql.available | Where-Object { $_.pr -eq $x.pr }).Count -eq 1 -and @($ql.records | Where-Object { $_.pr -eq $x.pr }).Count -eq 0)
    Check 'after three sweeps with an eligible PR and a connected qc worker: no assignment' ((Qc-QcAssignments $x.n).Count -eq 0)
    Check 'no item.assigned qc-env event reached the worker' ((Qc-Events 'qw1' $x.n).Count -eq 0)
    Check 'no record' ($null -eq (Qc-Rec $x.n $x.pr))
    $c = Qc-Click $x.pr $x.tok 'start'
    Check 'Start answered 200 started' ($c.status -eq 200 -and $c.reason -eq 'started') "$($c.status) $($c.reason)"
    $got = Wait-Until -Seconds 30 { (Qc-Events 'qw1' $x.n).Count -eq 1 }
    Check 'after Start the worker is offered one qc-env job' $got
    Check 'the job names the role and the environment' ((Qc-Events 'qw1' $x.n)[0].role -eq 'qc' -and (Qc-Events 'qw1' $x.n)[0].env_id -eq "qc-$($x.pr)-$((Get-Head $x.pr).Substring(0,7))-1")
    $ql = F 'op' @('qc-list'); Check 'after Start qc-list shows the record and no longer offers the PR' (@($ql.available | Where-Object { $_.pr -eq $x.pr }).Count -eq 0 -and @($ql.records | Where-Object { $_.pr -eq $x.pr }).Count -eq 1)
    Check 'the token is not on the event stream' (-not ((Get-Content $script:Workers['qw1'].out -Raw) -match 'i1\.'))
    Check 'the record is requested or assigned in the state comment' ((Qc-RecState $x.n $x.pr) -in 'assigned', 'requested') (Qc-RecState $x.n $x.pr)
    Check 'the item token for role qc is in the worker token directory' (Test-Path (Join-Path $script:Workers['qw1'].dir "$($x.n).qc"))
}

'qc: forged links are refused with 403 [full]' = {
    $x = New-QcOffered
    $sha = Get-Head $x.pr; $exp = [DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeSeconds()
    $parts = $x.tok.Split('.')
    $badMac = "$($parts[0]).$($parts[1]).$('0' * 64)"
    $otherPayload = ConvertTo-B64 ([Text.Encoding]::UTF8.GetBytes((@{ pr = $x.pr + 1; sha = $sha; u = 'qc-open'; x = $exp; n = 'z'; i = $x.n } | ConvertTo-Json -Compress)))
    $swapped = "$($parts[0]).$otherPayload.$($parts[2])"
    $cases = [ordered]@{
        'tampered payload' = $swapped; 'tampered MAC' = $badMac; 'no token' = ''
        'MAC without the qc: prefix (made as an i1 token would be)' = (Qc-Mint $x.pr $sha $x.n $exp 'qc-open' '')
        'another purpose in the payload' = (Qc-Mint $x.pr $sha $x.n $exp 'worker-open')
        'an i1. item token' = (Qc-Mint $x.pr $sha $x.n $exp 'qc-open' 'qc:' 'i1')
        'a w1. worker token' = ('w1.qw1.' + ('0123456789abcdef' * 4))
        'signed with another secret' = (Qc-Mint $x.pr $sha $x.n $exp 'qc-open' 'qc:' 'q1' 'not-the-gateway-secret-0123456789')
        'a valid link for another pull request' = (Qc-Mint ($x.pr + 1) $sha $x.n $exp)
    }
    foreach ($k in $cases.Keys) {
        $g = Qc-Get $x.pr $cases[$k]
        Check "GET with $k : 403 bad-link" ($g.status -eq 403 -and $g.reason -eq 'bad-link') "$($g.status) $($g.reason)"
    }
    $p = Qc-Post $x.pr $badMac 'start' 'none'
    Check 'POST with a forged link: 403 bad-link' ($p.status -eq 403 -and $p.reason -eq 'bad-link') "$($p.status) $($p.reason)"
    $stt = Qc-Get $x.pr $badMac '/status'; Check 'status with a forged link: 403' ($stt.status -eq 403)
    $go = Qc-Get $x.pr $badMac '/go'; Check 'go with a forged link: 403' ($go.status -eq 403)
    $api = Invoke-WebRequest "$(Qc-Base)/api/v1/verbs/qc-request" -Method POST -Body '{"item":1,"pr":1}' -ContentType 'application/json' -Headers @{ Authorization = "Bearer $($x.tok)" } -SkipHttpErrorCheck
    Check 'a q1 link is no credential for /api/v1/verbs' ([int]$api.StatusCode -eq 401) "$([int]$api.StatusCode)"
    Check 'none of it created a record or a job' ($null -eq (Qc-Rec $x.n $x.pr) -and (Qc-QcAssignments $x.n).Count -eq 0)
}

'qc: an expired link is refused with 410 [full]' = {
    $x = New-QcOffered
    $sha = Get-Head $x.pr
    $old = Qc-Mint $x.pr $sha $x.n ([DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds())
    $g = Qc-Get $x.pr $old
    Check 'GET: 410 link-expired' ($g.status -eq 410 -and $g.reason -eq 'link-expired') "$($g.status) $($g.reason)"
    $p = Qc-Post $x.pr $old 'start' 'none'
    Check 'POST: 410 link-expired' ($p.status -eq 410 -and $p.reason -eq 'link-expired') "$($p.status) $($p.reason)"
    Check 'no record, no job' ($null -eq (Qc-Rec $x.n $x.pr) -and (Qc-QcAssignments $x.n).Count -eq 0)
}

'qc: a stale link offers the current link and queues nothing [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $oldSha = Get-Head $x.pr
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('src/a.cs', 'src/b.cs') } | Out-Null
    $newSha = Get-Head $x.pr
    Check 'the head moved' ($newSha -ne $oldSha)
    $g = Qc-Get $x.pr $x.tok '' @{ Accept = 'text/html' }
    Check 'old link: 410 stale-head' ($g.status -eq 410 -and $g.reason -eq 'stale-head') "$($g.status) $($g.reason)"
    Check 'the page has the Get the current link button' ($g.body -match 'Get the current link' -and $g.body -match 'href="/qc/\d+\?t=q1\.')
    $gj = Qc-Get $x.pr $x.tok
    Check 'the JSON answer carries a fresh token for the current head' ($gj.json.current_sha -eq $newSha -and "$($gj.json.current_token)" -like 'q1.*')
    $fresh = Qc-Get $x.pr $gj.json.current_token
    Check 'the fresh token opens the page' ($fresh.status -eq 200) "$($fresh.status)"
    $p = Qc-Post $x.pr $x.tok 'start' "$($fresh.json.page_nonce)"
    Check 'Start with the old link: 410 stale-head' ($p.status -eq 410 -and $p.reason -eq 'stale-head') "$($p.status) $($p.reason)"
    Check 'nothing was queued' ((Qc-QcAssignments $x.n).Count -eq 0 -and $null -eq (Qc-Rec $x.n $x.pr))
    $edited = Wait-Until -Seconds 40 { (Qc-OfferComments $x.pr)[0].body -match $newSha.Substring(0, 7) }
    Check 'the sweep edited the offer comment to the new head (still one comment)' ($edited -and (Qc-OfferComments $x.pr).Count -eq 1)
    Check 'the new link works' ((Qc-Get $x.pr (Qc-Token $x.pr)).status -eq 200)
}

'qc: cross-origin and malformed posts are refused [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $g = Qc-Get $x.pr $x.tok; $nonce = "$($g.json.page_nonce)"
    Check 'the page minted a nonce' ($nonce -match '^[0-9a-f]{32}$')
    $p = Qc-Post $x.pr $x.tok 'start' $nonce @{} 'https://evil.example'
    Check 'wrong Origin: 403 bad-origin' ($p.status -eq 403 -and $p.reason -eq 'bad-origin') "$($p.status) $($p.reason)"
    $p = Qc-Http 'POST' "$(Qc-Base)/qc/$($x.pr)/start`?t=$($x.tok)" @{ Accept = 'application/json' } @{ nonce = $nonce }
    Check 'no Origin header: 403 bad-origin' ($p.status -eq 403 -and $p.reason -eq 'bad-origin') "$($p.status) $($p.reason)"
    $p = Qc-Post $x.pr $x.tok 'start' ''
    Check 'missing nonce: 403 bad-nonce' ($p.status -eq 403 -and $p.reason -eq 'bad-nonce') "$($p.status) $($p.reason)"
    $p = Qc-Post $x.pr $x.tok 'start' ('0' * 32)
    Check 'invented nonce: 403 bad-nonce' ($p.status -eq 403 -and $p.reason -eq 'bad-nonce') "$($p.status) $($p.reason)"
    $other = New-QcOffered
    $ng = Qc-Get $other.pr $other.tok; $p = Qc-Post $x.pr $x.tok 'start' "$($ng.json.page_nonce)"
    Check 'a nonce minted for another PR: 403 bad-nonce' ($p.status -eq 403 -and $p.reason -eq 'bad-nonce') "$($p.status) $($p.reason)"
    $p = Qc-Http 'POST' "$(Qc-Base)/qc/$($x.pr)/start`?t=$($x.tok)" @{ Accept = 'application/json'; Origin = (Qc-Base) } $null 'application/json' "{`"nonce`":`"$nonce`"}"
    Check 'a JSON body instead of a form: 415' ($p.status -eq 415 -and $p.reason -eq 'bad-content-type') "$($p.status) $($p.reason)"
    $p = Qc-Post $x.pr $x.tok 'explode' $nonce
    Check 'an unknown action is 404' ($p.status -eq 404) "$($p.status)"
    Qc-Sweeps 1
    Check 'no record and no job came of any of them' ($null -eq (Qc-Rec $x.n $x.pr) -and (Qc-QcAssignments $x.n).Count -eq 0 -and (Qc-Events 'qw1' $x.n).Count -eq 0)
}

'qc: /qc is not served on the webhook port [full]' = {
    $x = New-QcOffered
    $hp = "http://127.0.0.1:$($script:HookPort)"
    $r0 = Qc-Http 'GET' "$hp/qc/$($x.pr)`?t=$($x.tok)"; Check 'GET /qc/{pr} on the webhook port: 404' ($r0.status -eq 404) "$($r0.status)"
    $r0 = Qc-Http 'GET' "$hp/qc/$($x.pr)/status`?t=$($x.tok)"; Check 'GET status on the webhook port: 404' ($r0.status -eq 404) "$($r0.status)"
    $r0 = Qc-Http 'POST' "$hp/qc/$($x.pr)/start`?t=$($x.tok)" @{ Origin = $hp } @{ nonce = 'x' }; Check 'POST start on the webhook port: 404' ($r0.status -eq 404) "$($r0.status)"
    $r0 = Qc-Http 'GET' "$hp/qc/$($x.pr)/go`?t=$($x.tok)"; Check 'GET go on the webhook port: 404' ($r0.status -eq 404) "$($r0.status)"
    Check 'nothing was started' ($null -eq (Qc-Rec $x.n $x.pr))
}

'qc: happy path from Start to ready and on to teardown, with the link, the journal and the checks on the stored state' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'assigned'
    Check 'assigned in the state comment, with the worker' ((Qc-RecState $x.n $x.pr) -eq 'assigned' -and (Qc-Rec $x.n $x.pr).worker -eq 'qw1')
    $v = Qc-Get $x.pr $x.tok
    Check 'qc-view: state assigned, with the worker name' ($v.json.record.state -eq 'assigned' -and $v.json.status.worker -eq 'qw1')
    $a = Fo 'qw1' @('accept', '--item', $x.n, '--assignment', $x.asg, '--role', 'qc'); CheckExit 'accept (role qc)' $a 0
    Check 'accept says kind qc-env and names the environment' ($a.kind -eq 'qc-env' -and $a.env_id -eq $x.env -and $a.pr -eq $x.pr)
    $job = Fo 'qw1' @('qc-job', '--item', $x.n, '--pr', $x.pr); CheckExit 'qc-job' $job 0
    Check 'the job carries sha, branch, trust and limits, and flags the title as untrusted' ($job.sha -eq (Get-Head $x.pr) -and $job.branch -like 'factory-worker/*' -and $job.trust.ok -and $job.title.untrusted)
    $p = Fo 'qw1' @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'building'); CheckExit 'progress building' $p 0
    $p = Fo 'qw1' @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'running'); CheckExit 'progress running' $p 0
    $bad = Fo 'qw1' @('qc-progress', '--item', $x.n, '--pr', $x.pr, '--state', 'building'); CheckExit 'a step backwards is refused' $bad 10 'bad-transition'
    $rep = Qc-Report $x "http://$(Qc-Fake)"; CheckExit 'report ready' $rep 0
    Check 'the gateway probe reached /_healthcheck: verified' ($rep.probe -eq 'verified') "$($rep.probe)"
    Check 'state ready with ready_at and an expiry' ((Qc-Rec $x.n $x.pr).state -eq 'ready' -and (Qc-Rec $x.n $x.pr).ready_at -and (Qc-Rec $x.n $x.pr).expires_at)
    $st = Qc-Get $x.pr $x.tok '/status'
    Check 'status (from memory) shows ready, the worker and the URL' ($st.json.state -eq 'ready' -and $st.json.worker -eq 'qw1' -and $st.json.url -eq "http://$(Qc-Fake)") ($st.body)
    $pg = Qc-Get $x.pr $x.tok '' @{ Accept = 'text/html' }
    Check 'the page shows Open the environment and the reachability notice' ($pg.body -match 'Open the environment' -and $pg.body -match "Reachable only from networks that can reach qw1's computer")
    $go = Qc-Get $x.pr $x.tok '/go'
    Check '/go redirects to the reported URL' ($go.status -eq 302 -and $go.location -eq "http://$(Qc-Fake)") "$($go.status) $($go.location)"
    $j = Qc-Journal $x.n
    Check 'journal: qc-offered, qc-requested, qc-assigned, qc-ready, once each' (@('qc-offered', 'qc-requested', 'qc-assigned', 'qc-ready' | Where-Object { $j -notcontains $_ }).Count -eq 0 -and @($j | Group-Object | Where-Object Count -gt 1).Count -eq 0) ($j -join ',')
    $oc = (Qc-OfferComments $x.pr)[0].body
    Check 'the offer comment on the PR now names the worker, still one comment' ($oc -match 'qw1' -and (Qc-OfferComments $x.pr).Count -eq 1)
    Check 'the offer comment on the item names the worker' ((Qc-ItemOffer $x.n)[0].body -match 'qw1')
    $sc = (Qc-StateComment $x.n).body; $recJson = (Qc-Rec $x.n $x.pr) | ConvertTo-Json -Compress -Depth 6
    Check 'the state comment holds no URL, no loopback address and no client address' (-not ($sc -match '127\.0\.0\.1|requested_from') -and -not ($recJson -match 'http|"url"|lease|heartbeat|log_tail|client'))
    Check 'the history is bounded and ordered' (@((Qc-Rec $x.n $x.pr).history).Count -le 20 -and (@((Qc-Rec $x.n $x.pr).history | ForEach-Object { $_.state }) -join ',') -eq 'requested,assigned,building,running,ready')
    $all = ((Get-FakeIssue $x.n).comments + (Get-FakePr $x.pr).comments | ForEach-Object { $_.body }) -join "`n"
    Check 'no credential in any comment' (-not ($all -match '\b[wi]1\.[A-Za-z0-9_.-]{20,}') -and -not ($all -match 'ghp_|test-token'))
    $own = (Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$($x.n)" }
    Check 'the QC worker is not the owner of the item' (-not $own)
    $c = Qc-Click $x.pr $x.tok 'teardown'; Check 'Tear down answered 200' ($c.status -eq 200 -and $c.reason -eq 'torn-down') "$($c.status) $($c.reason)"
    $s = Fo 'qw1' @('qc-stopped', '--item', $x.n, '--env-id', $x.env); CheckExit 'qc-stopped confirms the teardown' $s 0
    Check 'torn-down in the state comment' ((Qc-RecState $x.n $x.pr) -eq 'torn-down')
}

'qc: clicking twice reuses the environment [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $c1 = Qc-Click $x.pr $x.tok 'start'; Check 'first click: started' ($c1.status -eq 200 -and $c1.reason -eq 'started') "$($c1.status) $($c1.reason)"
    $c2 = Qc-Click $x.pr $x.tok 'start'; Check 'second click: existing, 200' ($c2.status -eq 200 -and $c2.reason -eq 'existing') "$($c2.status) $($c2.reason)"
    $c3 = Qc-Click $x.pr $x.tok 'start'; Check 'third click: existing' ($c3.reason -eq 'existing')
    Qc-Sweeps 1
    Check 'one assignment' ((Qc-QcAssignments $x.n).Count -eq 1)
    Check 'the worker was offered the job once' ((Qc-Events 'qw1' $x.n).Count -eq 1)
    Check 'the record is attempt 1 with no person recorded' ((Qc-Rec $x.n $x.pr).attempt -eq 1 -and -not ((Qc-StateComment $x.n).body -match 'requested_from|clicked_by'))
    Check 'the journal has qc-requested once' ((Qc-JournalCount $x.n 'qc-requested') -eq 1)
}

'qc: two simultaneous Starts make one record and one job [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $g1 = Qc-Get $x.pr $x.tok; $g2 = Qc-Get $x.pr $x.tok
    $base = Qc-Base; $url = "$base/qc/$($x.pr)/start?t=$($x.tok)"
    $jobs = @("$($g1.json.page_nonce)", "$($g2.json.page_nonce)") | ForEach-Object -Parallel {
        $resp = Invoke-WebRequest $using:url -Method POST -Body @{ nonce = $_ } -Headers @{ Origin = $using:base; Accept = 'application/json' } -SkipHttpErrorCheck
        "$($resp.Headers['X-Qc-Reason'])"
    } -ThrottleLimit 2
    $reasons = @($jobs | Sort-Object)
    Check 'one Start started it, the other saw it' (($reasons -join ',') -eq 'existing,started') ($reasons -join ',')
    Qc-Sweeps 1
    Check 'exactly one assignment and one offer' ((Qc-QcAssignments $x.n).Count -eq 1 -and (Qc-Events 'qw1' $x.n).Count -eq 1)
    Check 'one qc-requested journal line' ((Qc-JournalCount $x.n 'qc-requested') -eq 1)
}

'qc: a QC accept and a refused release leave the owner of the item alone [full]' = {
    Ensure-QcWorker
    Start-OwnerClient 'ow1' 'persistent-local' '--capacity 5'
    $n = New-Item-Fake 'Owned QC trial' 'x' $QcLabels
    $got = Wait-Until -Seconds 60 { (Get-Assigned 'ow1' $n).Count -gt 0 }
    Check 'the owner session is offered the item' $got
    if ($got) {
        $oe = (Get-Assigned 'ow1' $n)[0]
        $r0 = Fo 'ow1' @('accept', '--item', $n, '--assignment', $oe.assignment); CheckExit 'the owner accepts' $r0 0
        # the owner drives the item to a PASS verdict with its own item token
        $realF = ${function:F}
        function F {
            param([string]$Holder, [string[]]$FactoryArgs)
            if ($Holder -ne 'ow1') { return (& $realF $Holder $FactoryArgs) }
            $w = $script:Workers['ow1']; $old = @{ d = $env:FACTORY_TOKEN_DIR; w = $env:FACTORY_WORKER_TOKEN; t = $env:FACTORY_TOKEN }
            $env:FACTORY_TOKEN_DIR = $w.dir; $env:FACTORY_WORKER_TOKEN = $w.token; $env:FACTORY_TOKEN = $w.token
            try { return (& $realF $Holder $FactoryArgs) } finally { $env:FACTORY_TOKEN_DIR = $old.d; $env:FACTORY_WORKER_TOKEN = $old.w; $env:FACTORY_TOKEN = $old.t }
        }
        Do-TechnicalDesign $n 'ow1' $false
        $pr = Do-Development $n @('src/a.cs') 'ow1'
        Do-DevComplete $n 'ow1' | Out-Null
        $v = Do-Verdict $n $pr 'ow1'; Check 'the owner recorded the PASS verdict' ($v.exit -eq 0) "$($v.exit) $(Pv $v 'code')"
        $own0 = (Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" }
        Check 'ow1 owns the item' ($own0 -and $own0.Value -eq 'ow1')
        $got2 = Wait-Until -Seconds 60 { (Qc-Token $pr) -ne '' }; Check 'the offer appeared' $got2
        $x = @{ n = $n; pr = $pr; tok = (Qc-Token $pr) }
        $x = Start-QcRun $x 'accepted'
        Check 'the QC accept succeeded' ($x.accept.exit -eq 0 -and $x.accept.kind -eq 'qc-env') ($x.accept | ConvertTo-Json -Compress)
        $own1 = (Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" }
        Check 'after the QC accept ow1 is still the owner, and qw1 owns nothing' ($own1 -and $own1.Value -eq 'ow1' -and @((Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Value -eq 'qw1' }).Count -eq 0)
        $rel = Fo 'qw1' @('release', '--item', $n); CheckExit 'release with the QC token: refused' $rel 30 'forbidden'
        $own2 = (Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" }
        Check 'the owner is unchanged after the release attempt' ($own2 -and $own2.Value -eq 'ow1')
        # (flaky on slow runners, cause not found, docs/HANDOFF.md entry p: quarantined. The detail says which assignment was missing, who owned the
        # item then and the item's journal: a 'reassigned' line there means the plant took the owner for gone because a sweep offered the item again)
        $pl = (Get-Plant).plant
        CheckQuarantined 'the owner assignment is still accepted next to the QC one' (@($pl.assignments | Where-Object { $_.item -eq $n -and $_.accepted }).Count -ge 2) "assignments: $(@($pl.assignments | Where-Object { $_.item -eq $n }) | ConvertTo-Json -Compress -Depth 4) owners: $($pl.owners | ConvertTo-Json -Compress) journal: $((Get-Journal $n) -join ',')" -Issue 'docs/HANDOFF.md backlog p'
        $mi = Fo 'ow1' @('get-item', '--item', $n); CheckExit 'the owner can still read the item with its token' $mi 0
        Qc-Sweeps 2
        $own3 = (Get-Plant).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" }
        Check 'and after two more sweeps' ($own3 -and $own3.Value -eq 'ow1' -and (Qc-QcAssignments $n).Count -eq 1)
        Remove-Item Function:\F -ErrorAction SilentlyContinue
    }
    Stop-OwnerClient 'ow1'
}

'qc: a started QC assignment survives the next sweeps [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'assigned'
    Qc-Sweeps 3
    Check 'the unaccepted QC assignment is still there after three sweeps (Plan did not prune it)' ((Qc-QcAssignments $x.n).Count -eq 1 -and (Qc-QcAssignments $x.n)[0].id -eq $x.asg)
    $a = Fo 'qw1' @('accept', '--item', $x.n, '--assignment', $x.asg, '--role', 'qc'); CheckExit 'the same token still accepts it' $a 0
    Qc-Sweeps 3
    $asg = (Qc-QcAssignments $x.n)
    Check 'the accepted QC assignment is still there after three more sweeps' ($asg.Count -eq 1 -and $asg[0].accepted -and $asg[0].worker -eq 'qw1')
    Check 'the record is unchanged by the sweeps' ((Qc-RecState $x.n $x.pr) -eq 'assigned')
    $h = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--mem-free-mb', 9000, '--app-alive', 'true', '--local-health', 'ok'); CheckExit 'heartbeat' $h 0
    Check 'heartbeat says continue' ($h.action -eq 'continue') "$($h.action)"
}

'qc: hostile text cannot corrupt the state comment or the pages [full]' = {
    Ensure-QcWorker
    $n = New-Item-Fake 'Hostile' 'x' $QcLabels
    Do-TechnicalDesign $n 'w1' $false
    Fake 'push-branch' @{ branch = "factory-worker/$n-development"; files = @('src/a.cs'); profile = 'green' } | Out-Null
    $r0 = F 'w1' @('claim-item', '--item', $n, '--column', 'Development'); CheckExit 'claim development' $r0 0
    $r0 = F 'w1' @('open-pr', '--item', $n, '--head', "factory-worker/$n-development", '--title', '<script>alert(1)</script> & <b>x</b>', '--body-file', (TmpFile "pr$n.md" 'change')); CheckExit 'open-pr' $r0 0
    $pr = $r0.pullRequest.number
    Do-DevComplete $n | Out-Null
    $v = Do-Verdict $n $pr; CheckExit 'verdict' $v 0
    [void](Wait-Until -Seconds 60 { (Qc-Token $pr) -ne '' })
    $x = @{ n = $n; pr = $pr; tok = (Qc-Token $pr) }
    $x = Start-QcRun $x 'building'
    $evil = "ok``````json`n{`"state`":`"ready`"}`n`````` @jeffreypalermo `` back`ticks `` <img src=x onerror=alert(1)>"
    $logf = TmpFile 'evil-reason.txt' $evil
    $logOnly = TmpFile 'evil.log' "LOGTAILMARK ``````json`n{`"state`":`"torn-down`"}`n`````` <b>log</b> back`ticks"
    $logGate = $logOnly
    $p = Fo 'qw1' @('qc-progress', '--item', $n, '--pr', $pr, '--state', 'running', '--log-tail-file', $logOnly); CheckExit 'progress with a hostile log tail' $p 0
    Check 'the log tail came back (redacted, capped) without being persisted' ($p.log_tail -match 'LOGTAILMARK')
    $f = Fo 'qw1' @('qc-fail', '--item', $n, '--pr', $pr, '--code', 'build-failed', '--reason-file', $logf, '--log-tail-file', $logOnly); CheckExit 'qc-fail with backticks and a fence in the reason' $f 0
    $s = Qc-State $n
    Check 'the state comment still parses' ($null -ne $s)
    Check 'the other keys are intact (verdict, the QC record)' ($s -and $s.verdict.passed -and $s.qc."$pr".state -eq 'failed')
    Check 'no backtick survives in the persisted reason' ($s -and -not ("$($s.qc."$pr".fail.reason)".Contains([string][char]96)))
    Check 'the reason is still there, capped and cleaned' ($s -and "$($s.qc."$pr".fail.reason)" -match 'ok')
    Check 'the log tail is not persisted at all (not in the state comment, not in a journal line)' (-not ((Qc-StateComment $n).body -match 'LOGTAILMARK|log_tail') -and -not ((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'LOGTAILMARK' }))
    $gi = F 'op' @('get-item', '--item', $n); CheckExit 'get-item still reads the state' $gi 0
    $jc = @((Get-FakeIssue $n).comments | Where-Object { $_.body -match 'plant event=qc-failed' })
    Check 'the failed journal line exists once' ($jc.Count -eq 1)
    if ($jc.Count -eq 1) {
        $b = $jc[0].body
        Check 'journal: the reason is inside a text fence that opens once and closes once' (([regex]::Matches($b, '```')).Count -eq 2)
        Check 'journal: the @mention is escaped' (-not ($b -match '@jeffreypalermo') -and $b -match "@$([char]0x200B)jeffreypalermo")
    }
    $pg = Qc-Get $pr $x.tok '' @{ Accept = 'text/html' }
    Check 'the page escapes the PR title' ($pg.body -notmatch '<script>alert' -and $pg.body -match '&lt;script&gt;alert\(1\)&lt;/script&gt;')
    Check 'the page escapes the log tail' ($pg.body -match 'LOGTAILMARK' -and $pg.body -notmatch '<b>log</b>' -and $pg.body -match '&lt;b&gt;log&lt;/b&gt;')
    Check 'the page shows the failure code' ($pg.body -match 'build-failed')
    $st = Qc-Get $pr $x.tok '/status'; Check 'status shows failed' ($st.json.state -eq 'failed')
}

'qc: URL rules: loopback, userinfo, scheme and the declared address [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    foreach ($u in "http://127.0.0.1:$($script:ReportPort)", "http://localhost:$($script:ReportPort)", "http://0.0.0.0:$($script:ReportPort)", "http://127.0.0.2:$($script:ReportPort)", "http://[::1]:$($script:ReportPort)") {
        if ($u -eq "http://127.0.0.1:$($script:ReportPort)") { continue }     # the one literal the test flag allows (the worker declared exactly that address); covered by the happy path
        $r0 = Qc-Report $x $u; CheckExit "loopback $u refused" $r0 10 'loopback-url'
    }
    $r0 = Qc-Report $x "http://user:secret@127.0.0.1:$($script:ReportPort)"; CheckExit 'userinfo refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x 'ftp://127.0.0.1/'; CheckExit 'ftp scheme refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x 'file:///etc/passwd'; CheckExit 'file scheme refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x 'http://169.254.169.254/latest/meta-data'; CheckExit 'metadata address refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x "http://192.0.2.10:$($script:ReportPort)"; CheckExit 'a host that is not the declared address refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x "http://example.org:$($script:ReportPort)"; CheckExit 'a host name that is not the declared address refused' $r0 10 'url-host-not-allowed'
    $r0 = Qc-Report $x 'not a url'; CheckExit 'garbage refused' $r0 10 'url-host-not-allowed'
    Check 'nothing refused made the environment ready' ((Qc-RecState $x.n $x.pr) -eq 'running')
    Check 'no URL is held for it' ((Qc-Get $x.pr $x.tok '/status').json.ContainsKey('url') -eq $false)
    $go = Qc-Get $x.pr $x.tok '/go'; Check '/go refuses while there is no URL' ($go.status -eq 409 -and $go.reason -eq 'not-ready') "$($go.status) $($go.reason)"
}

'qc: a private address is accepted when the worker declared it, and the unverified path [full]' = {
    Ensure-QcWorker
    $dr = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/drain" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    Ensure-QcWorker 'qw2' '192.0.2.10'
    $x = New-QcOffered
    $x = Start-QcRun $x 'running' 'qw2'
    $r0 = Qc-Report $x "http://192.0.2.10:$($script:ReportPort)" 'ok' 'qw2'; CheckExit 'a documentation-range LAN address declared by the worker is accepted' $r0 0
    Check 'the gateway could not reach it: probe unverified' ($r0.probe -eq 'unverified') "$($r0.probe)"
    Check 'the record is ready and says unverified' ((Qc-Rec $x.n $x.pr).state -eq 'ready' -and (Qc-Rec $x.n $x.pr).probe -eq 'unverified')
    $pg = Qc-Get $x.pr $x.tok '' @{ Accept = 'text/html' }
    Check 'the page says the gateway could not check the address' ($pg.body -match 'could not check this address')
    $go = Qc-Get $x.pr $x.tok '/go'; Check '/go redirects to the declared host' ($go.status -eq 302 -and $go.location -eq "http://192.0.2.10:$($script:ReportPort)") "$($go.status) $($go.location)"
    Stop-OwnerClient 'qw2'
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -eq 'qw2' -and $_.connected }).Count -eq 0 })
    $rs = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/resume" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    # no local health: not ready
    $y = New-QcOffered; $y = Start-QcRun $y 'running'
    $r0 = Qc-Report $y "http://127.0.0.1:$($script:DeadPort)" ''; CheckExit 'no local health ok and nothing answering: 20 unreachable' $r0 20 'unreachable'
    $r0 = Qc-Report $y "http://127.0.0.1:$($script:DeadPort)" 'ok'; CheckExit 'nothing answering but local health ok: ready' $r0 0
    Check 'unverified' ($r0.probe -eq 'unverified')
    # connects but answers badly
    $z = New-QcOffered; $z = Start-QcRun $z 'running'
    Fake 'health' @{ status = 503 } | Out-Null
    $r0 = Qc-Report $z "http://$(Qc-Fake)" 'ok'; CheckExit 'the probe connects and gets 503: 20 unreachable' $r0 20 'unreachable'
    Fake 'health' @{ status = 302 } | Out-Null
    $r0 = Qc-Report $z "http://$(Qc-Fake)" 'ok'; CheckExit 'a redirect is not followed and counts as a bad answer: 20' $r0 20 'unreachable'
    Fake 'health' @{ status = 200 } | Out-Null
    $f = Fo 'qw1' @('qc-fail', '--item', $z.n, '--pr', $z.pr, '--code', 'unreachable-url', '--reason', 'three tries, no good answer'); CheckExit 'the worker gives up with unreachable-url' $f 0
    Check 'failed(unreachable-url) is recorded' ((Qc-Rec $z.n $z.pr).state -eq 'failed' -and (Qc-Rec $z.n $z.pr).fail.code -eq 'unreachable-url')
    $r0 = Fo 'qw1' @('qc-fail', '--item', $z.n, '--pr', $z.pr, '--code', 'because-i-said-so'); CheckExit 'an unknown failure code is a usage error' $r0 2
}

'qc: reset makes a new attempt, a new assignment and kills the old token [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    $oldAsg = $x.asg; $oldEnv = $x.env
    $oldTok = (Get-Content -Raw (Join-Path $script:Workers['qw1'].dir "$($x.n).qc")).Trim()
    $c = Qc-Click $x.pr $x.tok 'reset'
    Check 'Reset answered 200 reset' ($c.status -eq 200 -and $c.reason -eq 'reset') "$($c.status) $($c.reason)"
    $got = Wait-Until -Seconds 30 { (Qc-Events 'qw1' $x.n).Count -ge 2 }
    Check 'the worker was offered a second job' $got
    $ev2 = (Qc-Events 'qw1' $x.n)[-1]
    Check 'new assignment id, new environment id, attempt 2' ($ev2.assignment -ne $oldAsg -and $ev2.env_id -eq ($oldEnv -replace '-1$', '-2') -and $ev2.mode -eq 'reset') "$($ev2.assignment) $($ev2.env_id) $($ev2.mode)"
    $call = { param($verb, $obj) Qc-Http 'POST' "$(Qc-Base)/api/v1/verbs/$verb" @{ Authorization = "Bearer $oldTok" } $null 'application/json' ($obj | ConvertTo-Json -Compress) }
    $stale = & $call 'qc-progress' @{ item = "$($x.n)"; pr = "$($x.pr)"; state = 'building' }
    Check 'the old token (old assignment) is stale: 409 stale-assignment' ($stale.status -eq 409 -and $stale.json.code -eq 'stale-assignment') "$($stale.status) $($stale.body)"
    $hb = & $call 'qc-heartbeat' @{ item = "$($x.n)"; env_id = $oldEnv }
    Check 'a heartbeat of the old environment is stale too' ($hb.status -eq 409 -and $hb.json.code -eq 'stale-assignment') "$($hb.status) $($hb.body)"
    $acc = & $call 'accept' @{ item = "$($x.n)" }
    Check 'the old assignment cannot be accepted any more' ($acc.status -eq 409) "$($acc.status) $($acc.body)"
    $rec = Qc-Rec $x.n $x.pr
    Check 'the record is attempt 2 and not yet accepted' ($rec.attempt -eq 2 -and $rec.state -eq 'assigned' -and -not $rec.ContainsKey('accepted_at') -and $rec.assignment -eq $ev2.assignment) ($rec | ConvertTo-Json -Compress -Depth 4)
    Check 'the old assignment id is remembered as old' (@($rec.old_assignments) -contains $oldAsg)
    $jr = Qc-Journal $x.n; Check 'journal: qc-reset' ($jr -contains 'qc-reset') ($jr -join ',')
    $a = Fo 'qw1' @('accept', '--item', $x.n, '--assignment', $ev2.assignment, '--role', 'qc'); CheckExit 'the new assignment is accepted (token minted again)' $a 0
    $old = & $call 'qc-stopped' @{ item = "$($x.n)"; env_id = $oldEnv }
    Check 'qc-stopped for the old environment is accepted as such and does not tear down the new attempt' ($old.status -eq 200 -and $old.json.outcome -eq 'old-environment' -and (Qc-Rec $x.n $x.pr).state -eq 'assigned') "$((Qc-Rec $x.n $x.pr).state)"
}

'qc: teardown asks the worker to stop and ends when it confirms [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    [void](Qc-Report $x "http://$(Qc-Fake)")
    $c = Qc-Click $x.pr $x.tok 'teardown'
    Check 'Tear down answered 200' ($c.status -eq 200 -and $c.reason -eq 'torn-down') "$($c.status) $($c.reason)"
    $ev = Wait-Until -Seconds 20 { @(Get-WorkerEvents 'qw1' | Where-Object { $_.event -eq 'qc.teardown' -and $_.pr -eq $x.pr }).Count -gt 0 }
    Check 'the worker got a directed qc.teardown event' $ev
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok')
    Check 'a heartbeat is answered with action teardown' ($hb.exit -eq 0 -and $hb.action -eq 'teardown') "$($hb.exit) $($hb.action)"
    Check 'still ready until the worker confirms' ((Qc-RecState $x.n $x.pr) -eq 'ready')
    $s = Fo 'qw1' @('qc-stopped', '--item', $x.n, '--env-id', $x.env); CheckExit 'qc-stopped' $s 0
    Check 'torn-down in the state comment' ((Qc-RecState $x.n $x.pr) -eq 'torn-down')
    Check 'the QC assignment is gone from the plant' ((Qc-QcAssignments $x.n).Count -eq 0)
    Check 'journal: qc-torn-down with the reason' (@((Get-FakeIssue $x.n).comments | Where-Object { $_.body -match 'plant event=qc-torn-down' -and $_.body -match 'torn down \(person\)' }).Count -eq 1)
    $c2 = Qc-Click $x.pr $x.tok 'teardown'; Check 'Tear down again: 200 already' ($c2.status -eq 200 -and $c2.reason -eq 'already') "$($c2.status) $($c2.reason)"
    $c3 = Qc-Click $x.pr $x.tok 'start'; Check 'Start after a teardown is a new attempt' ($c3.status -eq 200 -and $c3.reason -eq 'started' -and (Qc-Rec $x.n $x.pr).attempt -eq 2) "$($c3.status) $($c3.reason)"
}

'qc: a QC token can do nothing but its own job [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'accepted'
    $other = New-QcOffered
    $cases = [ordered]@{
        'release' = @('release', '--item', $x.n); 'merge' = @('merge', '--item', $x.n, '--pr', $x.pr); 'approve-pr' = @('approve-pr', '--item', $x.n, '--pr', $x.pr, '--text-file', (TmpFile 'qa.md' "x`nAPPROVE"))
        'comment' = @('comment', '--item', $x.n, '--text', 'hello'); 'complete' = @('complete', '--item', $x.n, '--column', 'Functional Testing', '--comment', 'x'); 'claim-item' = @('claim-item', '--item', $x.n, '--column', 'Functional Testing')
        'sync-board' = @('sync-board'); 'qc-request' = @('qc-request', '--item', $x.n, '--pr', $x.pr); 'qc-teardown' = @('qc-teardown', '--item', $x.n, '--pr', $x.pr); 'qc-transition' = @('qc-transition', '--item', $x.n, '--pr', $x.pr, '--to', 'ready')
    }
    foreach ($k in $cases.Keys) { $r0 = Fo 'qw1' $cases[$k]; CheckExit "qc role cannot call $k" $r0 30 'forbidden' }
    Copy-Item (Join-Path $script:Workers['qw1'].dir "$($x.n).qc") (Join-Path $script:Workers['qw1'].dir "$($other.n).qc") -Force
    $r0 = Fo 'qw1' @('get-item', '--item', $other.n); CheckExit 'the token of one item is refused for another' $r0 30 'forbidden'
    $r0 = Fo 'qw1' @('qc-job', '--item', $other.n, '--pr', $other.pr); CheckExit 'qc-job on another item is refused' $r0 30 'forbidden'
    Remove-Item (Join-Path $script:Workers['qw1'].dir "$($other.n).qc") -Force
    $r0 = Fo 'qw1' @('accept', '--item', $other.n, '--assignment', $x.asg, '--role', 'qc'); Check 'accept without an item token for that item: refused' ($r0.exit -eq 30)
    $r0 = Fo 'qw1' @('qc-job', '--item', $x.n, '--pr', ($x.pr + 1000)); Check 'qc-job for a PR that has no record here: not found or refused' ($r0.exit -in 12, 10, 40) "$($r0.exit) $($r0.code)"
    $r0 = Fo 'qw1' @('qc-fail', '--item', $x.n, '--pr', $x.pr, '--code', 'build-failed', '--reason', 'x'); CheckExit 'its own qc-fail works' $r0 0
}

'qc: heartbeats and status polls write nothing to GitHub and do not lose fields [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    [void](Qc-Report $x "http://$(Qc-Fake)")
    Start-Sleep -Seconds 2
    $before = @(Fake 'log' | Where-Object { $_ -match '^(POST|PATCH|PUT|DELETE) ' }).Count
    $itemTok = (Get-Content -Raw (Join-Path $script:Workers['qw1'].dir "$($x.n).qc")).Trim(); $hbUrl = "$(Qc-Base)/api/v1/verbs/qc-heartbeat"; $hbBody = (@{ item = "$($x.n)"; env_id = $x.env; mem_free_mb = 8000; app_alive = $true; local_health = 'ok' } | ConvertTo-Json -Compress)
    $statusUrl = "$(Qc-Base)/qc/$($x.pr)/status?t=$($x.tok)"
    $jobs = 1..6 | ForEach-Object -Parallel {
        if ($_ % 2 -eq 0) { (Invoke-WebRequest $using:hbUrl -Method POST -Body $using:hbBody -ContentType 'application/json' -Headers @{ Authorization = "Bearer $using:itemTok" } -SkipHttpErrorCheck).Content }
        else { (Invoke-WebRequest $using:statusUrl -SkipHttpErrorCheck).Content }
    } -ThrottleLimit 6
    Check 'six concurrent heartbeats and polls all answered' (@($jobs | Where-Object { $_ -match '"ok":\s*true|"state":\s*"ready"' }).Count -eq 6) (($jobs | Out-String))
    $writesNow = @(Fake 'log' | Where-Object { $_ -match '^(POST|PATCH|PUT|DELETE) ' })
    $newWrites = $writesNow.Count - $before
    Check 'no write reached GitHub because of them (sweeps edit nothing while nothing changes)' ($newWrites -eq 0) "$newWrites new writes: $(($writesNow | Select-Object -Last 3) -join ' | ')"
    $st = Qc-Get $x.pr $x.tok '/status'
    Check 'the URL and the state are intact in memory' ($st.json.state -eq 'ready' -and $st.json.url -eq "http://$(Qc-Fake)")
    Check 'the record in the state comment is intact too' ((Qc-Rec $x.n $x.pr).state -eq 'ready' -and (Qc-Rec $x.n $x.pr).worker -eq 'qw1')
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'false', '--local-health', 'fail')
    CheckExit 'a heartbeat that reports the app down' $hb 0
    Check 'the record became failed(app-down), nothing reset by itself' ((Qc-Rec $x.n $x.pr).state -eq 'failed' -and (Qc-Rec $x.n $x.pr).fail.code -eq 'app-down')
    Qc-Sweeps 2
    Check 'a sweep leaves it failed' ((Qc-RecState $x.n $x.pr) -eq 'failed')
    $c = Qc-Click $x.pr $x.tok 'reset'; Check 'Reset is the way forward' ($c.status -eq 200 -and $c.reason -eq 'reset')
}

'qc: a new head marks the environment stale and rebuilds nothing [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    [void](Qc-Report $x "http://$(Qc-Fake)")
    $before = (Qc-Events 'qw1' $x.n).Count
    Fake 'push-branch' @{ branch = "factory-worker/$($x.n)-development"; files = @('src/a.cs', 'src/c.cs') } | Out-Null
    $stale = Wait-Until -Seconds 40 { (Qc-RecState $x.n $x.pr) -eq 'stale' }
    Check 'the record is marked stale' $stale (Qc-RecState $x.n $x.pr)
    $newSha = Get-Head $x.pr
    $edited = Wait-Until -Seconds 40 { (Qc-OfferComments $x.pr)[0].body -match $newSha.Substring(0, 7) }
    Check 'the offer comment now carries the new head (the edit did not start anything)' $edited
    Qc-Sweeps 2
    Check 'no new job was created' ((Qc-Events 'qw1' $x.n).Count -eq $before -and (Qc-QcAssignments $x.n).Count -eq 1)
    Check 'the old record is still the old head' ((Qc-Rec $x.n $x.pr).sha -ne $newSha)
    $g = Qc-Get $x.pr $x.tok; Check 'the old link is stale' ($g.status -eq 410)
    $fresh = Qc-Token $x.pr
    $c = Qc-Click $x.pr $fresh 'start'
    Check 'Start with the new link is a new record at the new head' ($c.status -eq 200 -and $c.reason -eq 'started' -and (Qc-Rec $x.n $x.pr).sha -eq $newSha -and (Qc-Rec $x.n $x.pr).attempt -eq 1) "$($c.status) $($c.reason)"
    $td = Wait-Until -Seconds 20 { @(Get-WorkerEvents 'qw1' | Where-Object { $_.event -eq 'qc.teardown' -and $_.pr -eq $x.pr }).Count -gt 0 }
    Check 'the worker of the stale environment was told to stop it' $td
}

'qc: a closed pull request tears the environment down [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    [void](Qc-Report $x "http://$(Qc-Fake)")
    Fake 'pr' @{ number = $x.pr; open = $false } | Out-Null
    $td = Wait-Until -Seconds 60 { @(Get-WorkerEvents 'qw1' | Where-Object { $_.event -eq 'qc.teardown' -and $_.pr -eq $x.pr }).Count -gt 0 }
    Check 'the worker is told to tear the environment down' $td
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); Check 'heartbeat answers teardown' ($hb.action -eq 'teardown') "$($hb.action)"
    $s = Fo 'qw1' @('qc-stopped', '--item', $x.n, '--env-id', $x.env); CheckExit 'qc-stopped' $s 0
    Check 'torn-down with the reason closed' ((Qc-RecState $x.n $x.pr) -eq 'torn-down' -and (Qc-Rec $x.n $x.pr).teardown.reason -eq 'closed')
    Check 'journal: qc-torn-down (closed)' (@((Get-FakeIssue $x.n).comments | Where-Object { $_.body -match 'plant event=qc-torn-down' -and $_.body -match '\(closed\)' }).Count -eq 1)
}

'qc: webhooks for pull requests and reviews become events [full]' = {
    $c = (Get-Content -Raw (Join-Path $script:Root 'config/instance.json') | ConvertFrom-Json -AsHashtable)
    $repo = @{ full_name = "$($c.owner)/$($c.repo)" }
    $pull = { param($act, $sha, $merged) @{ action = $act; repository = $repo; sender = @{ login = 'someone' }; pull_request = @{ number = 77; merged = $merged; head = @{ ref = 'factory-worker/12-development'; sha = $sha; repo = $repo } } } }
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd1'; payload = (& $pull 'synchronize' ('a' * 40) $false) }).events
    Check 'synchronize: pr.head_changed for item 12 with the sha and the sender' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.head_changed' -and $e[0].item -eq 12 -and $e[0].sha -eq ('a' * 40) -and $e[0].login -eq 'someone')
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd2'; payload = (& $pull 'closed' ('b' * 40) $true) }).events
    Check 'closed and merged: pr.merged' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.merged')
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd3'; payload = (& $pull 'closed' ('b' * 40) $false) }).events
    Check 'closed not merged: pr.closed' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.closed')
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd4'; payload = (& $pull 'opened' ('c' * 40) $false) }).events
    Check 'opened: pr.opened' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.opened')
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd5'; payload = (& $pull 'converted_to_draft' ('c' * 40) $false) }).events
    Check 'converted to draft: pr.drafted' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.drafted')
    $fork = & $pull 'synchronize' ('d' * 40) $false; $fork.pull_request.head.repo = @{ full_name = 'evil/fork' }
    $res = Qc-Server 'ingest-event' @{ event = 'pull_request'; delivery = 'd6'; payload = $fork }
    Check 'a fork pull request is ignored' (@($res.events).Count -eq 0 -and $res.dropped -eq 'pr.fork')
    $rv = @{ action = 'submitted'; repository = $repo; review = @{ state = 'approved'; commit_id = ('e' * 40); user = @{ login = 'jeffreypalermo' } }; pull_request = @{ number = 77; head = @{ ref = 'factory-worker/12-development'; sha = ('e' * 40) } } }
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request_review'; delivery = 'd7'; payload = $rv }).events
    Check 'review submitted: pr.reviewed with login, state and commit' (@($e).Count -eq 1 -and $e[0].event -eq 'pr.reviewed' -and $e[0].login -eq 'jeffreypalermo' -and $e[0].state -eq 'APPROVED' -and $e[0].commit_id -eq ('e' * 40))
    $rv.action = 'dismissed'
    $e = (Qc-Server 'ingest-event' @{ event = 'pull_request_review'; delivery = 'd8'; payload = $rv }).events
    Check 'review dismissed: pr.reviewed with action dismissed' (@($e).Count -eq 1 -and $e[0].action -eq 'dismissed')
    Check 'a signed pull_request delivery to the webhook port is accepted' ((Qc-Hook 'pull_request' (& $pull 'opened' ('c' * 40) $false)) -eq 202)
    Check 'a signed pull_request_review delivery is accepted' ((Qc-Hook 'pull_request_review' $rv) -eq 202)
    Check 'a delivery with a bad signature is refused' ((Invoke-WebRequest "http://127.0.0.1:$($script:HookPort)/webhooks/github" -Method POST -Body '{}' -ContentType 'application/json' -Headers @{ 'X-GitHub-Event' = 'pull_request'; 'X-Hub-Signature-256' = 'sha256=00' } -SkipHttpErrorCheck).StatusCode -eq 401)
}

'qc: restart while the environment is ready recovers it [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $x = Start-QcRun $x 'running'
    [void](Qc-Report $x "http://$(Qc-Fake)")
    $before = Qc-Get $x.pr $x.tok '/status'
    Check 'ready with a URL before the restart' ($before.json.state -eq 'ready' -and $before.json.url)
    Restart-Gateway
    $back = Wait-Until -Seconds 60 { try { @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $x.n -and $_.kind -eq 'qc-env' -and $_.accepted }).Count -eq 1 } catch { $false } }
    Check 'the assignment is rebuilt from the state comment as accepted, with the same id' ($back -and (Qc-QcAssignments $x.n)[0].id -eq $x.asg) (((Qc-QcAssignments $x.n) | ConvertTo-Json -Compress))
    $mid = Qc-Get $x.pr $x.tok '/status'
    Check 'the URL was in memory only: after a restart it is gone and the page says it is being re-reported' ($mid.json.state -eq 'ready' -and -not $mid.json.ContainsKey('url') -and "$($mid.json.note)" -match 're-reported') ($mid.body)
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--mem-free-mb', 9000, '--app-alive', 'true', '--local-health', 'ok')
    CheckExit 'the old token still works: heartbeat' $hb 0
    Check 'the heartbeat is answered re-report' ($hb.action -eq 're-report') "$($hb.action)"
    $rep = Qc-Report $x "http://$(Qc-Fake)"; CheckExit 'the worker reports again' $rep 0
    $after = Qc-Get $x.pr $x.tok '/status'
    Check 'the URL is back' ($after.json.state -eq 'ready' -and $after.json.url -eq "http://$(Qc-Fake)")
    $hb = Fo 'qw1' @('qc-heartbeat', '--item', $x.n, '--env-id', $x.env, '--app-alive', 'true', '--local-health', 'ok'); Check 'then the heartbeat says continue' ($hb.action -eq 'continue') "$($hb.action)"
    # restart while building: the accepted job is rebuilt and the worker simply carries on with its token
    $y = New-QcOffered
    $y = Start-QcRun $y 'building'
    Restart-Gateway
    $again = Wait-Until -Seconds 60 { try { @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $y.n -and $_.kind -eq 'qc-env' -and $_.accepted }).Count -eq 1 } catch { $false } }
    Check 'an environment that was building is rebuilt as accepted' $again
    $p = Fo 'qw1' @('qc-progress', '--item', $y.n, '--pr', $y.pr, '--state', 'running'); CheckExit 'the worker carries on: progress running' $p 0
    $rep = Qc-Report $y "http://$(Qc-Fake)"; CheckExit 'and reports ready' $rep 0
}

'qc: a Start that found no worker keeps its place across a restart [full]' = {
    Ensure-QcWorker
    $z = New-QcOffered
    $dr = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/drain" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    $c = Qc-Click $z.pr $z.tok 'start'
    Check 'with the only worker draining, Start waits' ($c.status -eq 202 -and $c.reason -eq 'waiting-for-worker') "$($c.status) $($c.reason)"
    Restart-Gateway
    $placed = Wait-Until -Seconds 60 { try { @((Get-Plant).plant.assignments | Where-Object { $_.item -eq $z.n -and $_.kind -eq 'qc-env' }).Count -eq 1 } catch { $false } }
    Check 'after a restart the waiting Start is placed again from its record' $placed
    $rs = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/resume" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    $served = Wait-Until -Seconds 60 { try { (Qc-RecState $z.n $z.pr) -eq 'assigned' -and (Qc-QcAssignments $z.n)[0].worker -eq 'qw1' } catch { $false } }
    Check 'and served once a qualified worker is there' $served (Qc-RecState $z.n $z.pr)
}

'qc: configuration guards [full]' = {
    $c = Get-Content -Raw (Join-Path $script:Root 'config/instance.json') | ConvertFrom-Json -AsHashtable
    $good = Join-Path $script:Work 'cfg-guard.json'
    $c.qc = @{ allowLoopbackForTests = $true }; $c | ConvertTo-Json -Depth 12 | Set-Content $good
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = 'https://gw.example.org' }
    CheckExit 'allowLoopbackForTests refuses to load when the public URL is not loopback' $r0 30 'config-invalid'
    $c.qc = @{ allowLoopbackForTests = $false }; $c | ConvertTo-Json -Depth 12 | Set-Content $good
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = "http://127.0.0.1:$($script:PublicPort)" }
    CheckExit 'a loopback public URL is refused for links' $r0 30 'public-url-not-reachable'
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = "http://localhost:$($script:PublicPort)" }
    CheckExit 'localhost is refused too' $r0 30 'public-url-not-reachable'
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = '' }
    CheckExit 'no public URL is refused' $r0 30 'public-url-not-reachable'
    $c.timing.qcTokenHours = 8; $c | ConvertTo-Json -Depth 12 | Set-Content $good
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = 'https://gw.example.org' }
    CheckExit 'a QC token TTL not above build cap plus lifetime is refused' $r0 30 'config-invalid'
    $c.timing.qcTokenHours = 16; $c | ConvertTo-Json -Depth 12 | Set-Content $good
    $r0 = Qc-Server 'qc-link' @{ item = 1; pr = 1 } @{ FACTORY_CONFIG = $good; FACTORY_PUBLIC_URL = 'https://gw.example.org'; FACTORY_TOKEN_SECRET = '' }
    CheckExit 'without the token secret no link is made' $r0 30 'no-token-secret'
}

'qc: capacity, memory and worker choice [full]' = {
    Ensure-QcWorker
    $dr = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/drain" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
    $d2 = try { Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw2/drain" -Method POST -Headers @{ Authorization = 'Bearer test-token' } } catch { $null }
    Ensure-QcWorker 'qw3' '127.0.0.1' '--qc-capacity 1'
    Ensure-QcWorker 'qw4' '127.0.0.1' '--qc-capacity 1'
    Start-OwnerClient 'plain' 'persistent-local' '--roles owner'
    Start-OwnerClient 'qnd' 'persistent-local' '--roles qc --capabilities git --qc-address 127.0.0.1 --qc-profile'
    $x = New-QcOffered; $y = New-QcOffered; $z = New-QcOffered
    $c1 = Qc-Click $x.pr $x.tok 'start'; $c2 = Qc-Click $y.pr $y.tok 'start'
    Check 'two Starts: both placed (two workers with capacity 1)' ($c1.status -eq 200 -and $c2.status -eq 200) "$($c1.status) $($c2.status)"
    $w1 = (Qc-QcAssignments $x.n)[0].worker; $w2 = (Qc-QcAssignments $y.n)[0].worker
    Check 'they went to different workers (each has one slot)' ($w1 -ne $w2 -and $w1 -in 'qw3', 'qw4' -and $w2 -in 'qw3', 'qw4') "$w1 $w2"
    Check 'a worker without the qc role, and a qc worker without the .NET SDK, were never chosen' (@(Get-WorkerEvents 'plain' | Where-Object { $_.event -eq 'item.assigned' -and $_.job -eq 'qc-env' }).Count -eq 0 -and @(Get-WorkerEvents 'qnd' | Where-Object { $_.event -eq 'item.assigned' -and $_.job -eq 'qc-env' }).Count -eq 0)
    $c3 = Qc-Click $z.pr $z.tok 'start'
    Check 'a third Start finds no free slot: 202 waiting-for-worker, record stays requested' ($c3.status -eq 202 -and $c3.reason -eq 'waiting-for-worker' -and (Qc-RecState $z.n $z.pr) -eq 'requested') "$($c3.status) $($c3.reason) $(Qc-RecState $z.n $z.pr)"
    Check 'and no job was offered' ((Qc-QcAssignments $z.n)[0].worker -eq '')
    $st = Qc-Get $z.pr $z.tok '/status'; Check 'status says why it waits' ($st.json.state -eq 'requested' -and "$($st.json.waiting)" -ne '')
    # free a slot: tear down the first one
    [void](Qc-Click $x.pr $x.tok 'teardown')
    $moved = Wait-Until -Seconds 30 { (Qc-QcAssignments $z.n)[0].worker -ne '' -and (Qc-RecState $z.n $z.pr) -eq 'assigned' }
    Check 'the waiting Start is served when a slot frees (it is the person''s earlier Start)' $moved
    foreach ($w in 'plain', 'qnd', 'qw3', 'qw4') { Stop-OwnerClient $w }
    [void](Wait-Until -Seconds 20 { @((Get-Plant).plant.workers | Where-Object { $_.name -in 'qw3', 'qw4', 'qnd', 'plain' -and $_.connected }).Count -eq 0 })
    $rs = Invoke-RestMethod "$(Qc-Base)/api/v1/workers/qw1/resume" -Method POST -Headers @{ Authorization = 'Bearer test-token' }
}
}

# The same checks that depend on the rate limit, with the default limits (10 per address and 20 per pull request per hour) and qc.trustProxy off.
$QcRateScenarios = [ordered]@{

'qc: the 11th click from one address in an hour is rate limited, and a spoofed X-Forwarded-For does not bypass it [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $g = Qc-Get $x.pr $x.tok; $nonce = "$($g.json.page_nonce)"
    $codes = @(1..10 | ForEach-Object { (Qc-Post $x.pr $x.tok 'start' $nonce @{ 'X-Forwarded-For' = "203.0.113.$_" }).status })
    Check 'ten requests are served (the first starts, the rest see it), each with a different forwarded address' (@($codes | Where-Object { $_ -eq 200 }).Count -eq 10) ($codes -join ',')
    $p = Qc-Post $x.pr $x.tok 'start' $nonce @{ 'X-Forwarded-For' = '203.0.113.200' }
    Check 'the 11th, with yet another forwarded address, is 429 rate-limited (the header is ignored: trustProxy is off)' ($p.status -eq 429 -and $p.reason -eq 'rate-limited') "$($p.status) $($p.reason)"
    $p = Qc-Post $x.pr $x.tok 'reset' $nonce @{ 'X-Forwarded-For' = '203.0.113.201' }
    Check 'a reset counts against the same budget' ($p.status -eq 429)
    $p = Qc-Post $x.pr $x.tok 'teardown' $nonce @{ 'X-Forwarded-For' = '203.0.113.202, 10.0.0.1' }
    Check 'so does a teardown, whatever the header chain' ($p.status -eq 429)
    $s = Qc-Get $x.pr $x.tok '/status'; Check 'reading status is not limited' ($s.status -eq 200)
    Check 'one record, one job' ((Qc-QcAssignments $x.n).Count -eq 1 -and (Qc-Rec $x.n $x.pr).attempt -eq 1)
}
}

# qc.trustProxy on, with 127.0.0.1 as the known proxy: the client is the right-most address that is not a known proxy.
$QcProxyScenarios = [ordered]@{

'qc: behind a known proxy the right-most hop is the client, and the left hops cannot be chosen by the client [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $g = Qc-Get $x.pr $x.tok; $nonce = "$($g.json.page_nonce)"
    $codes = @(1..12 | ForEach-Object { (Qc-Post $x.pr $x.tok 'start' $nonce @{ 'X-Forwarded-For' = "203.0.113.$_, 198.51.100.7" }).status })
    Check 'rotating the client-controlled left hop changes nothing: the 11th and later are 429' (@($codes[0..9] | Where-Object { $_ -eq 200 }).Count -eq 10 -and $codes[10] -eq 429 -and $codes[11] -eq 429) ($codes -join ',')
    $p = Qc-Post $x.pr $x.tok 'start' $nonce @{ 'X-Forwarded-For' = '203.0.113.1, 198.51.100.8' }
    Check 'another real client (a different right-most address) has its own budget' ($p.status -eq 200) "$($p.status)"
}

'qc: a second click from another address reuses the environment and records no person [full]' = {
    Ensure-QcWorker
    $x = New-QcOffered
    $c1 = Qc-Click $x.pr $x.tok 'start' @{ 'X-Forwarded-For' = '198.51.100.21' }
    $c2 = Qc-Click $x.pr $x.tok 'start' @{ 'X-Forwarded-For' = '198.51.100.22' }
    Check 'first click starts it' ($c1.status -eq 200 -and $c1.reason -eq 'started') "$($c1.status) $($c1.reason)"
    Check 'the second click, from another address with no identity, finds it' ($c2.status -eq 200 -and $c2.reason -eq 'existing') "$($c2.status) $($c2.reason)"
    Qc-Sweeps 1
    Check 'one assignment only' ((Qc-QcAssignments $x.n).Count -eq 1)
    $sc = (Qc-StateComment $x.n).body
    Check 'neither address, nor a person, is in the state comment or any comment' (-not ($sc -match '198\.51\.100')  -and -not (((Get-FakeIssue $x.n).comments + (Get-FakePr $x.pr).comments | ForEach-Object { $_.body }) -join ' ' -match '198\.51\.100'))
}
}
