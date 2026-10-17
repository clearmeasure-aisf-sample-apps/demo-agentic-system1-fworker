# The journal folds its repeats (plugin/scripts/lib/Journal.ps1, issue 93): a repeated matched, waiting or reassigned line edits the comment of its
# kind, a line of another kind (offered aside) ends the folds, only new comments count against the cap of 30, and the state keeps per-kind counts.
# Runs in the owner suite; the rule script journal is called directly (as the gateway calls it), on an item that is not factory work, so no sweep
# touches it.

function Jf-Journal([int]$n, [string]$Ev, [string]$Key, [hashtable]$Fields = @{}) { Pm-Server 'journal' @{ item = $n; event = $Ev; key = $Key; fields = $Fields } }
# (written to the pipeline one by one: callers wrap them in @())
function Jf-Comments([int]$n) { (Get-FakeIssue $n).comments | Where-Object { "$($_.body)" -match '<!-- plant event=' } }
function Jf-Events([int]$n) { Jf-Comments $n | ForEach-Object { [regex]::Match("$($_.body)", 'plant event=([a-z-]+)').Groups[1].Value } }
# the item's state comment with journal.count set to a value (as an item that has journaled that much already)
function Jf-SetCount([int]$n, [int]$Count) {
    $st = Pm-State $n; $st.journal.count = $Count; $json = $st | ConvertTo-Json -Depth 12
    $cm = @((Get-FakeIssue $n).comments | Where-Object { "$($_.body)".StartsWith('<!-- factory-state:') })[0]
    $nb = "$($cm.body)" -replace '(?s)```json.*```', "``````json`n$json`n``````"
    Invoke-RestMethod "http://127.0.0.1:$($script:FakePort)/repos/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/comments/$($cm.id)" -Method PATCH -Headers @{ Authorization = "Bearer $env:GH_TOKEN" } -Body (@{ body = $nb } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
}

$JournalFoldScenarios = [ordered]@{}

$JournalFoldScenarios['journal fold: repeated matched, waiting and reassigned lines edit one comment per kind; another line ends the fold; folds do not count against the cap'] = {
    $old = $env:FACTORY_TIMING_journalWaitingMinutes; $env:FACTORY_TIMING_journalWaitingMinutes = '0'   # every waiting line is written (the default writes one per 30 min)
    try {
        $n = New-Item-Fake 'Journal fold' 'x' @()
        $m = @{ column = 'Technical Design'; reason = 'board-move'; trigger = 'the sweep' }
        foreach ($i in 1..3) { $r = Jf-Journal $n 'matched' "m$i" $m; CheckExit "matched $i" $r 0 }
        $mc = @(Jf-Comments $n | Where-Object { "$($_.body)" -match 'plant event=matched' })
        Check 'three matched lines: one comment' ($mc.Count -eq 1) (@(Jf-Events $n) -join ',')
        Check 'it says how often, keeps the first line''s marker and shows the latest lines' ($mc.Count -eq 1 -and "$($mc[0].body)" -match 'matched 3 times' -and "$($mc[0].body)" -match '<!-- plant event=matched key=m1 fold=3 -->' -and @([regex]::Matches("$($mc[0].body)", '(?m)^> ')).Count -eq 3) "$($mc[0].body)"
        $rp = Jf-Journal $n 'matched' 'm3' $m
        Check 'a redelivered line (same key) changes nothing' ($rp.posted -eq $false -and "$((@(Jf-Comments $n | Where-Object { "$($_.body)" -match 'plant event=matched' }))[0].body)" -match 'matched 3 times') ($rp | ConvertTo-Json -Compress)
        foreach ($i in 1..2) { $r = Jf-Journal $n 'waiting' '' @{ reason = "no session can take it ($i)" }; CheckExit "waiting $i" $r 0 }
        foreach ($i in 1..2) { $r = Jf-Journal $n 'reassigned' "r$i" @{ reason = "w$i did not accept in time" }; CheckExit "reassigned $i" $r 0 }
        $r = Jf-Journal $n 'offered' 'o1' @{ worker = 'w9'; type = 'persistent-local'; ackSeconds = 120 }; CheckExit 'offered' $r 0
        $r = Jf-Journal $n 'matched' 'm4' $m; CheckExit 'matched after an offer' $r 0
        Check 'an offer does not end the folds: the order is matched, waiting, reassigned, offered' ((@(Jf-Events $n) -join ',') -eq 'matched,waiting,reassigned,offered') (@(Jf-Events $n) -join ',')
        $w = @(Jf-Comments $n | Where-Object { "$($_.body)" -match 'plant event=waiting' })[0]; $ra = @(Jf-Comments $n | Where-Object { "$($_.body)" -match 'plant event=reassigned' })[0]
        Check 'waiting and reassigned folded as well, the latest line first' ("$($w.body)" -match 'waiting 2 times' -and "$($w.body)" -match 'Plant manager: waiting: no session can take it \(2\)\.\s' -and "$($ra.body)" -match 'reassigned 2 times') "$($w.body) | $($ra.body)"
        $st = Pm-State $n
        Check 'the state counts every kind and only the new comments' ($st.journal.kinds.matched.count -eq 4 -and $st.journal.kinds.waiting.count -eq 2 -and $st.journal.kinds.reassigned.count -eq 2 -and $st.journal.kinds.offered.count -eq 1 -and $st.journal.count -eq 4) ($st.journal | ConvertTo-Json -Compress -Depth 5)
        # another kind of line ends the folds: the next matched is a new comment after it
        $r = Jf-Journal $n 'assigned' 'a1' @{ worker = 'w9'; column = 'Technical Design'; mode = 'first'; attempt = 1; lease = 'soon' }; CheckExit 'assigned' $r 0
        $r = Jf-Journal $n 'matched' 'm5' $m; CheckExit 'matched after assigned' $r 0
        Check 'after an assigned line the next matched is a new comment in its place' ((@(Jf-Events $n) -join ',') -eq 'matched,waiting,reassigned,offered,assigned,matched') (@(Jf-Events $n) -join ',')
        Check 'the open fold is the new comment, the old one is closed' ((Pm-State $n).journal.fold.Keys -contains 'matched' -and @((Pm-State $n).journal.fold.Keys).Count -eq 1 -and "$((Pm-State $n).journal.fold.matched.key)" -eq 'm5') ((Pm-State $n).journal.fold | ConvertTo-Json -Compress -Depth 5)
        # the cap: an item one comment short of it
        Jf-SetCount $n 29
        foreach ($i in 6..8) { $r = Jf-Journal $n 'matched' "m$i" $m; CheckExit "matched $i at the cap" $r 0 }
        Check 'folded lines do not count against the cap' ((Pm-State $n).journal.count -eq 29 -and @(Jf-Comments $n).Count -eq 6 -and "$(@(Jf-Comments $n)[-1].body)" -match 'matched 4 times') "count $((Pm-State $n).journal.count), comments $(@(Jf-Comments $n).Count)"
        $r = Jf-Journal $n 'released' 'x1' @{ worker = 'w9'; reason = 'test' }; CheckExit 'released (the 30th comment)' $r 0
        $r = Jf-Journal $n 'released' 'x2' @{ worker = 'w9'; reason = 'test' }
        $last = "$(@(Jf-Comments $n)[-1].body)"
        Check 'the 31st comment is the journal full note, as before' ($r.posted -eq $true -and $last -match 'journal full' -and (Pm-State $n).journal.count -eq 31) $last
        $r = Jf-Journal $n 'released' 'x3' @{ worker = 'w9'; reason = 'test' }
        Check 'and nothing after it' ($r.posted -eq $false -and @(Jf-Comments $n).Count -eq 8) "$(@(Jf-Comments $n).Count)"
    } finally { if ($old) { $env:FACTORY_TIMING_journalWaitingMinutes = $old } else { Remove-Item Env:FACTORY_TIMING_journalWaitingMinutes -ErrorAction SilentlyContinue } }
}

foreach ($k in $JournalFoldScenarios.Keys) { $OwnerScenarios[$k] = $JournalFoldScenarios[$k] }
