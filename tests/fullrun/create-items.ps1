#!/usr/bin/env pwsh
# Creates the ten text-replacement work items on the real board, in Todo, where the factory ignores them. Idempotent (matches on the title).
# -HandOver moves them into Technical Design, which is what starts the run.
param([switch] $HandOver, [string] $Only = '', [string] $ItemsFile = 'items.json')
$ErrorActionPreference = 'Stop'
$repo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'; $project = 'PVT_kwDOD_ESUc4BliGL'; $field = 'PVTSSF_lADOD_ESUc4BliGLzhkOn7g'
$todo = 'f75ad846'; $td = 'e6ec2abc'
$items = Get-Content -Raw (Join-Path $PSScriptRoot $ItemsFile) | ConvertFrom-Json
$have = @(gh api "repos/$repo/labels?per_page=100" --jq '.[].name'); if ($have -notcontains 'factory test') {
    gh api -X POST "repos/$repo/labels" -f name='factory test' -f color='fbca04' -f description='Automated test item: the factory uses the cheapest model (testing profile)' | Out-Null; 'created label: factory test' }
$existing = @{}; foreach ($i in (gh api "repos/$repo/issues?state=all&labels=factory%20test&per_page=100" --jq '.[]|{n:.number,t:.title,node:.node_id}' | ForEach-Object { $_ | ConvertFrom-Json })) { $existing[$i.t] = $i }
$out = @()
foreach ($it in $items) {
    if ($Only -and (@($Only -split ',' | ForEach-Object { [int]$_.Trim() }) -notcontains [int]$it.n)) { continue }
    $title = if ($it.PSObject.Properties['title']) { $it.title } else { 'Text change {0:00}: {1}' -f $it.n, ((Split-Path -Leaf $it.file) -replace '\.razor$', '') }
    $testLine = if ($it.test) { " and update the unit test that asserts the old text (``$($it.test)``) to expect the new text" } else { '' }
    $body = @"
Replace text in one file.

- File: ``$($it.file)``
- Replace: ``$($it.from)``
- With: ``$($it.to)``

Change only that text$testLine. Do not reformat or change anything else.

Acceptance: ``$($it.file)`` contains ``$($it.to)`` and no longer contains ``$($it.from)``; $(if ($it.test) { 'the unit test is updated and passes; ' })no other file changes.
"@
    if ($existing.ContainsKey($title)) { $n = $existing[$title].n; $node = $existing[$title].node }
    else {
        $j = gh api "repos/$repo/issues" -f title="$title" -f body="$body" -f 'labels[]=factory worker' -f 'labels[]=Auto Merge' -f 'labels[]=factory test' --jq '{n:.number,node:.node_id}' | ConvertFrom-Json
        $n = $j.n; $node = $j.node
    }
    $card = gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' -f p=$project -f c="$node" --jq .data.addProjectV2ItemById.item.id
    # Only move a card that has not been handed over yet: a restart must never pull a running item back.
    $cur = gh api graphql -f query='query($id:ID!){node(id:$id){... on ProjectV2Item{fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}' -f id="$card" --jq '.data.node.fieldValueByName.name'
    $column = if ($cur) { $cur } else { 'none' }
    if ($column -in 'none', 'Todo') {
        $opt = if ($HandOver) { $td } else { $todo }
        gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' -f p=$project -f i="$card" -f f=$field -f o=$opt | Out-Null
        $column = if ($HandOver) { 'Technical Design' } else { 'Todo' }
    }
    $out += [pscustomobject]@{ item = $it.n; issue = $n; title = $title; column = $column }
}
$out | Format-Table -AutoSize | Out-String -Width 200
$out | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'created.json')
