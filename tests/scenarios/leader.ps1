# One acting gateway across releases (gateway/Leader.cs, plugin/scripts/lib/Leader.ps1, issue 94): the leader lease is a compare-and-swap with an
# epoch, a newer process supersedes the holder, the holder hands over (final snapshot, stream.replaced, 503 for everything else), the newer one
# restores that snapshot before its first sweep, a graceful stop releases the lease, and the claims that ran out while no gateway was up are renewed.
# Runs in the owner suite. The suite runs with the lease and the snapshot off (run.ps1); these scenarios switch both on for their own gateways and
# give the suite's gateway back in finally. The fake's forwarder (FAKE_PROXY_PORT, lib.ps1) stands in for the platform's ingress.

$script:LeaderEnv = @{ FACTORY_LEADER_LEASE = '1'; FACTORY_PLANT_SNAPSHOT = '1'; FACTORY_TIMING_leaderCheckSeconds = '1'; FACTORY_TIMING_leaderRenewSeconds = '4'; FACTORY_TIMING_leaderLeaseSeconds = '20'
    FACTORY_TIMING_leaderHandoverSeconds = '30'; FACTORY_TIMING_plantSnapshotDebounceSeconds = '1' }
function Ld-SetEnv([hashtable]$Env) { $old = @{}; foreach ($k in $Env.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }; return $old }
function Ld-Status([string]$Base) { Invoke-RestMethod "$Base/api/v1/status" -Headers @{ Authorization = 'Bearer test-token' } -TimeoutSec 10 }
# a field of the status by its path (a.b.c), or $null while it is not there yet (strict mode refuses a missing property)
function Ld-Get($Obj, [string]$Path) { $o = $Obj; foreach ($p in $Path.Split('.')) { if ($null -eq $o) { return $null }; $pp = $o.PSObject.Properties[$p]; if (-not $pp) { return $null }; $o = $pp.Value }; return $o }
function Ld-Restore([string]$Base) { Ld-Get (Ld-Status $Base) 'plantSnapshot.restore' }
function Ld-Log($P) { if (Test-Path $P) { @(Get-Content $P) } else { @() } }
# A gateway process of this suite on another port (same fake GitHub, configuration and secrets), with a state directory of its own, as a second replica
# or revision has. Its log is gateway-<tag>.out, which the suite's invariant reads as well.
function Ld-StartGateway([int]$PortOffset, [string]$Tag) {
    $dll = Join-Path $script:Root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'; $port = $script:PortBase + $PortOffset
    $old = Ld-SetEnv @{ FACTORY_API_PORT = "$port"; FACTORY_WEBHOOK_PORT = "$($port + 1)"; FACTORY_STATE_DIR = (Join-Path $script:Work "state-$Tag") }
    $out = Join-Path $script:Work "gateway-$Tag.out"
    try { $p = Start-Process dotnet -ArgumentList $dll -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work "gateway-$Tag.err") }
    finally { [void](Ld-SetEnv $old) }
    $script:Procs += $p
    [void](Wait-Until -Seconds 40 { try { [bool](Invoke-RestMethod "http://127.0.0.1:$port/ready" -TimeoutSec 2) } catch { $false } })
    return @{ proc = $p; base = "http://127.0.0.1:$port"; out = $out; port = $port }
}
# The suite's gateway process, started again on its own port without stopping anything first (the one before was stopped by the scenario).
function Ld-StartSuiteGateway {
    $gwDll = Join-Path $script:Root 'gateway/bin/Release/net10.0/FactoryWorker.Gateway.dll'; $tag = [guid]::NewGuid().ToString('N').Substring(0, 4)
    $out = Join-Path $script:Work "gateway-$tag.out"
    $script:Procs[1] = Start-Process dotnet -ArgumentList $gwDll -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:Work "gateway-restarted.err")
    [void](Wait-Until -Seconds 30 { try { [bool](Invoke-RestMethod "$(Get-GatewayBase)/ready" -TimeoutSec 2) } catch { $false } })
    return $out
}
function Ld-SuiteLog { $f = Get-ChildItem -Path $script:Work -File -Filter 'gateway*.out' | Sort-Object LastWriteTime | Where-Object { $_.Name -notmatch 'gateway-ld' }; if ($f) { "$(@($f)[-1].FullName)" } else { '' } }
function Ld-Leader([string]$Holder, [string]$Action, [hashtable]$More = @{}) { $b = @{ action = $Action; holder = $Holder; ttl_seconds = 60; version = 'test' }; foreach ($k in $More.Keys) { $b[$k] = $More[$k] }; Qc-Server 'leader-lease' $b }

$LeaderScenarios = [ordered]@{}

$LeaderScenarios['leader: the lease is a compare-and-swap with a growing epoch; a superseded holder can neither renew nor release; a final snapshot never overwrites a later epoch'] = {
    $a = Ld-Leader 'gw-a' 'acquire'
    Check 'the first process takes epoch 1, with no predecessor' ($a.exit -eq 0 -and $a.epoch -eq 1 -and $null -eq $a.predecessor) ($a | ConvertTo-Json -Compress -Depth 4)
    if ($a.exit -ne 0) { return }
    $b = Ld-Leader 'gw-b' 'acquire'
    Check 'a newer process takes epoch 2 and is told its predecessor' ($b.exit -eq 0 -and $b.epoch -eq 2 -and $b.predecessor.holder -eq 'gw-a' -and $b.predecessor.epoch -eq 1) ($b | ConvertTo-Json -Compress -Depth 4)
    $r = Ld-Leader 'gw-a' 'renew' @{ epoch = 1 }
    Check 'the superseded holder cannot renew: leader false, the current holder named' ($r.exit -eq 0 -and $r.leader -eq $false -and $r.current.holder -eq 'gw-b') ($r | ConvertTo-Json -Compress -Depth 4)
    $c = Ld-Leader 'gw-a' 'check' @{ epoch = 1; sha = $a.sha }
    Check 'nor does its check say it leads' ($c.exit -eq 0 -and $c.leader -eq $false -and $c.current.epoch -eq 2) ($c | ConvertTo-Json -Compress -Depth 4)
    $c2 = Ld-Leader 'gw-b' 'check' @{ epoch = 2 }
    Check 'the holder''s check says it leads, with the ETag of the ref' ($c2.exit -eq 0 -and $c2.leader -eq $true -and "$($c2.etag)" -ne '') ($c2 | ConvertTo-Json -Compress -Depth 4)
    $c3 = Ld-Leader 'gw-b' 'check' @{ epoch = 2; etag = $c2.etag }
    Check 'a check with that ETag is answered unchanged (GitHub answers 304)' ($c3.exit -eq 0 -and $c3.leader -eq $true -and $c3.unchanged -eq $true) ($c3 | ConvertTo-Json -Compress -Depth 4)
    $x = Ld-Leader 'gw-a' 'release' @{ epoch = 1; plant_epoch = 1 }
    Check 'nor release it' ($x.exit -eq 0 -and $x.leader -eq $false -and (Ld-Leader 'gw-b' 'check' @{ epoch = 2 }).leader -eq $true) ($x | ConvertTo-Json -Compress -Depth 4)
    $rn = Ld-Leader 'gw-b' 'renew' @{ epoch = 2 }
    Check 'the holder renews' ($rn.exit -eq 0 -and $rn.leader -eq $true) ($rn | ConvertTo-Json -Compress -Depth 4)
    # GitHub moves a ref without force only to a descendant: an update from a commit read before another process moved the ref is refused
    $repo = "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders"; $h = @{ Authorization = 'Bearer fake-operator' }
    $stale = Invoke-RestMethod "$repo/git/commits" -Method POST -Headers $h -Body (@{ message = '{"kind":"gateway-leader","epoch":3,"holder":"gw-late"}'; tree = $a.tree; parents = @($a.sha) } | ConvertTo-Json) -ContentType 'application/json'
    $u = Invoke-WebRequest "$repo/git/refs/factory/factory-worker/gateway-leader" -Method PATCH -Headers $h -Body (@{ sha = $stale.sha; force = $false } | ConvertTo-Json) -ContentType 'application/json' -SkipHttpErrorCheck
    Check 'a write from a stale read is refused (422 not a fast forward), and the holder still leads' ([int]$u.StatusCode -eq 422 -and "$($u.Content)" -match 'fast forward' -and (Ld-Leader 'gw-b' 'check' @{ epoch = 2 }).leader -eq $true) "$([int]$u.StatusCode) $($u.Content)"
    $rl = Ld-Leader 'gw-b' 'release' @{ epoch = 2; plant_epoch = 2 }
    $c4 = Ld-Leader 'gw-c' 'acquire'
    Check 'a release ends the lease: the next process is told it was released and whose snapshot holds the plant' ($rl.exit -eq 0 -and $rl.released -eq $true -and $c4.epoch -eq 3 -and $c4.predecessor.released -eq $true -and $c4.predecessor.plant_epoch -eq 2) ($c4 | ConvertTo-Json -Compress -Depth 4)
    $s1 = Qc-Server 'plant-snapshot-save' @{ snapshot = @{ v = 1; at = (Get-Date).ToUniversalTime().ToString('o'); epoch = 3; final = $false; assignments = @(); owners = @{} } }
    $s2 = Qc-Server 'plant-snapshot-save' @{ snapshot = @{ v = 1; at = (Get-Date).ToUniversalTime().ToString('o'); epoch = 2; final = $true; assignments = @(); owners = @{} }; guard_epoch = 2 }
    $ld = Qc-Server 'plant-snapshot-load' @{}
    Check 'a final snapshot of epoch 2 does not overwrite the snapshot of epoch 3 (exit 11 snapshot-newer)' ($s1.exit -eq 0 -and $s2.exit -eq 11 -and $s2.code -eq 'snapshot-newer' -and $ld.snapshot.epoch -eq 3) "$($s2 | ConvertTo-Json -Compress) / $($ld.snapshot | ConvertTo-Json -Compress)"
}

$LeaderScenarios['leader: two gateways overlap: the newer takes the lease, the older stops acting, writes its final snapshot and hands its streams over; the newer restores it before its first sweep [full]'] = {
    $old = Ld-SetEnv ($script:LeaderEnv + @{ FACTORY_ASSIGN_ACK_SECONDS = '90' })
    $oldUrl = $env:FACTORY_URL; $b = $null
    try {
        Restart-Gateway
        $gwA = Get-GatewayBase
        Check 'the first gateway takes the lease (epoch 1) and acts' (Wait-Until -Seconds 30 { $l = (Ld-Status $gwA).leader; $l.role -eq 'acting' -and $l.epoch -eq 1 }) ((Ld-Status $gwA).leader | ConvertTo-Json -Compress -Depth 4)
        # the sessions reach the gateways through the forwarder, as through the platform's ingress
        Fake 'proxy' @{ port = $script:ApiPort } | Out-Null
        $env:FACTORY_URL = "http://127.0.0.1:$($script:ProxyPort)"
        Start-OwnerClient 'lena' 'persistent-local' '--capacity 2'
        $ia = New-Item-Fake 'Leader owned' 'x' ($OwnerLabels + 'worker:lena'); $ib = New-Item-Fake 'Leader offered' 'x' ($OwnerLabels + 'worker:lena')
        [void](Wait-Until -Seconds 40 { (Get-Assigned 'lena' $ia).Count -gt 0 -and (Get-Assigned 'lena' $ib).Count -gt 0 })
        $ea = (Get-Assigned 'lena' $ia)[-1]; $eb = (Get-Assigned 'lena' $ib)[-1]
        $r = Fo 'lena' @('accept', '--item', $ia, '--assignment', $ea.assignment); CheckExit 'lena accepts the first item' $r 0
        $acceptedAt = [DateTime]::UtcNow
        Check 'the holder writes a snapshot of the change without being stopped' (Wait-Until -Seconds 20 { $ps = (Ld-Status $gwA).plantSnapshot; (Ld-Get $ps 'saves') -ge 1 -and (Ld-Get $ps 'heldEpoch') -eq 1 -and [DateTime]::Parse("$(Ld-Get $ps 'lastSave')", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) -gt $acceptedAt }) ((Ld-Status $gwA).plantSnapshot | ConvertTo-Json -Compress -Depth 4)
        # a new revision starts while the old one runs; the ingress sends new connections to it
        $b = Ld-StartGateway 12 'ldb'
        Fake 'proxy' @{ port = $b.port } | Out-Null
        Check 'the newer process takes epoch 2' (Wait-Until -Seconds 30 { (Ld-Status $b.base).leader.epoch -eq 2 }) ((Ld-Status $b.base).leader | ConvertTo-Json -Compress -Depth 4)
        Check 'the older one finds itself superseded' (Wait-Until -Seconds 20 { (Ld-Status $gwA).leader.role -eq 'superseded' }) ((Ld-Status $gwA).leader | ConvertTo-Json -Compress -Depth 4)
        $supAt = [DateTime]::UtcNow
        $logA = Ld-SuiteLog
        Check 'it writes its final snapshot and ends its streams' (Wait-Until -Seconds 20 { @(Ld-Log $logA | Where-Object { $_ -match '"gateway":"handed-over"' -and $_ -match '"finalSnapshot":true' }).Count -ge 1 }) ((Ld-Log $logA | Where-Object { $_ -match 'handed-over|plant-snapshot' }) -join "`n")
        Check 'the newer process restores that snapshot: the hand-over, epoch 1, the owner and both assignments' (Wait-Until -Seconds 40 { $rs = Ld-Restore $b.base; $rs -and $rs.how -eq 'handover' -and $rs.snapshotEpoch -eq 1 -and $rs.assignments -ge 2 -and $rs.owners -ge 1 }) ((Ld-Status $b.base).plantSnapshot | ConvertTo-Json -Compress -Depth 4)
        $sb = Ld-Status $b.base
        Check 'the owner and the accepted assignment keep their ids on the new process' (@($sb.plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$ia" -and $_.Value -eq 'lena' }).Count -eq 1 -and @($sb.plant.assignments | Where-Object { $_.item -eq $ia -and $_.id -eq $ea.assignment -and $_.accepted }).Count -eq 1) ($sb.plant | ConvertTo-Json -Compress -Depth 4)
        Check 'the session''s client is told of the hand-over and connects to the new process by itself' (Wait-Until -Seconds 40 { @(Get-WorkerEvents 'lena' | Where-Object { $_.event -eq 'stream.handover' }).Count -ge 1 -and @((Ld-Status $b.base).plant.workers | Where-Object { $_.name -eq 'lena' -and $_.connected }).Count -eq 1 }) (@(Get-WorkerEvents 'lena' | Select-Object -Last 6) | ConvertTo-Json -Compress -Depth 3)
        Check 'its client keeps running (no exit 40)' (-not $script:Workers['lena'].proc.HasExited)
        Check 'the unanswered offer is pushed again by the new process, the same assignment' (Wait-Until -Seconds 30 { (Get-Assigned 'lena' $ib).Count -ge 2 -and (Get-Assigned 'lena' $ib)[-1].assignment -eq $eb.assignment }) ((Get-Assigned 'lena' $ib) | ConvertTo-Json -Compress)
        $r2 = Fo 'lena' @('accept', '--item', $ib, '--assignment', (Get-Assigned 'lena' $ib)[-1].assignment); CheckExit 'and accepted there' $r2 0
        $va = Invoke-WebRequest "$gwA/api/v1/verbs/get-item" -Method POST -Headers @{ Authorization = 'Bearer test-token' } -Body (@{ item = $ia } | ConvertTo-Json) -ContentType 'application/json' -SkipHttpErrorCheck
        $ra = Invoke-WebRequest "$gwA/ready" -SkipHttpErrorCheck
        Check 'the old process answers every call 503 gateway-replaced, and is not ready' ([int]$va.StatusCode -eq 503 -and "$($va.Content)" -match 'gateway-replaced' -and [int]$ra.StatusCode -eq 503) "$([int]$va.StatusCode) $($va.Content) / ready $([int]$ra.StatusCode)"
        Start-Sleep -Seconds 6
        $late = @(Ld-Log $logA | Where-Object { $_ -match '"sweep":\{' } | Where-Object { $m = [regex]::Match($_, '"at":"([^"]+)"'); $m.Success -and [DateTime]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) -gt $supAt.AddSeconds(3) })
        Check 'the old process sweeps no more' ($late.Count -eq 0) ($late -join "`n")
        Check 'the new process sweeps' ($null -ne (Ld-Status $b.base).lastSweep)
    } finally {
        Stop-OwnerClient 'lena'; $env:FACTORY_URL = $oldUrl; Fake 'proxy' @{ port = 0 } | Out-Null
        if ($b) { try { Stop-Process -Id $b.proc.Id -Force } catch { } }
        [void](Ld-SetEnv $old); Restart-Gateway
    }
}

$LeaderScenarios['leader: a graceful stop releases the lease; the next start restores at once and renews a claim that ran out while no gateway was up [full]'] = {
    # a claim lease of 15 s, so it runs out while no gateway is up
    $old = Ld-SetEnv ($script:LeaderEnv + @{ FACTORY_TIMING_leaseMinutes = '0.25' })
    try {
        Restart-Gateway
        [void](Wait-Until -Seconds 30 { (Ld-Status (Get-GatewayBase)).leader.role -eq 'acting' })
        Start-OwnerClient 'gina' 'persistent-local' '--capacity 2'
        $n = New-Item-Fake 'Leader gap' 'x' ($OwnerLabels + 'worker:gina')
        [void](Wait-Until -Seconds 40 { (Get-Assigned 'gina' $n).Count -gt 0 })
        $r = Fo 'gina' @('accept', '--item', $n, '--assignment', (Get-Assigned 'gina' $n)[-1].assignment); CheckExit 'gina accepts the item' $r 0
        $leaseUntil = [DateTime]::Parse("$($r.lease_until)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        # the platform stops the process (SIGTERM) and starts the next one only after the claim's lease has passed
        $logA = Ld-SuiteLog
        $gp = $script:Procs[1]; & kill -s TERM $gp.Id 2>$null
        Check 'the stopped process exits' ($gp.WaitForExit(60000))
        Check 'at its stop it wrote its final snapshot and released the lease' (@(Ld-Log $logA | Where-Object { $_ -match '"gateway":"plant-snapshot"' -and $_ -match '"final":true' -and $_ -match '"exit":0' }).Count -ge 1 -and @(Ld-Log $logA | Where-Object { $_ -match '"released":1' -and $_ -match '"exit":0' }).Count -ge 1) ((Ld-Log $logA | Where-Object { $_ -match 'plant-snapshot|released' }) -join "`n")
        $wait = ($leaseUntil.AddSeconds(3) - [DateTime]::UtcNow).TotalSeconds; if ($wait -gt 0) { Start-Sleep -Seconds ([Math]::Ceiling($wait)) }
        Remove-Item Env:FACTORY_TIMING_leaseMinutes -ErrorAction SilentlyContinue
        $t0 = [DateTime]::UtcNow
        [void](Ld-StartSuiteGateway)
        $gw = Get-GatewayBase
        Check 'the next start restores at once: the predecessor released the lease' (Wait-Until -Seconds 30 { $rs = Ld-Restore $gw; $rs -and $rs.how -eq 'released' -and $rs.owners -ge 1 -and $rs.gapSince }) ((Ld-Status $gw).plantSnapshot | ConvertTo-Json -Compress -Depth 4)
        $rsAt = [DateTime]::Parse("$((Ld-Restore $gw).at)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        Check 'without waiting for a hand-over' (($rsAt - $t0).TotalSeconds -lt 25) "$(($rsAt - $t0).TotalSeconds) s"
        Check 'its first sweep renews the claim that ran out in the gap' (Wait-Until -Seconds 40 { $st = Pm-State $n; $st.ContainsKey('claim') -and $st.claim.ContainsKey('gap_renewed') -and [DateTime]::Parse("$($st.claim.lease_until)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) -gt [DateTime]::UtcNow }) ((Pm-State $n).claim | ConvertTo-Json -Compress)
        $j = Get-Journal $n; $gapLines = @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)" -match 'plant event=gap-renewed' })
        Check 'the journal says so, and the item was not offered again' ($gapLines.Count -eq 1 -and $j -notcontains 'reassigned' -and @($j | Where-Object { $_ -eq 'matched' }).Count -eq 1) ($j -join ',')
        Check 'gina still owns it on the new process' (Wait-Until -Seconds 20 { @((Ld-Status $gw).plant.owners.PSObject.Properties | Where-Object { $_.Name -eq "$n" -and $_.Value -eq 'gina' }).Count -eq 1 }) ((Ld-Status $gw).plant.owners | ConvertTo-Json -Compress)
    } finally {
        Stop-OwnerClient 'gina'
        [void](Ld-SetEnv $old); Restart-Gateway
    }
}

foreach ($k in $LeaderScenarios.Keys) { $OwnerScenarios[$k] = $LeaderScenarios[$k] }
