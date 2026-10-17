#!/usr/bin/env pwsh
# Creates one work item on the real board from a title and a body file, with the labels given (default: factory worker, Auto Merge).
# -HandOver puts it in Technical Design, which is what starts the run; without it the card stays in Todo, where the factory ignores it.
# usage: pwsh create-item.ps1 -Title "..." -BodyFile body.md [-Label 'factory worker','Auto Merge'] [-HandOver]
param([Parameter(Mandatory)][string] $Title, [Parameter(Mandatory)][string] $BodyFile, [string[]] $Label = @('factory worker', 'Auto Merge'), [switch] $HandOver)
$ErrorActionPreference = 'Stop'
$Label = @($Label | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # -File passes an array as one comma-joined string
$repo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'; $project = 'PVT_kwDOD_ESUc4BliGL'; $field = 'PVTSSF_lADOD_ESUc4BliGLzhkOn7g'
$todo = 'f75ad846'; $td = 'e6ec2abc'
$args2 = @('api', "repos/$repo/issues", '-f', "title=$Title", '-f', "body=$(Get-Content -Raw -LiteralPath $BodyFile)")
foreach ($l in $Label) { $args2 += @('-f', "labels[]=$l") }
$j = & gh @args2 --jq '{n:.number,node:.node_id}' | ConvertFrom-Json
$card = gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' -f p=$project -f c="$($j.node)" --jq .data.addProjectV2ItemById.item.id
$opt = if ($HandOver) { $td } else { $todo }
gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' -f p=$project -f i="$card" -f f=$field -f o=$opt | Out-Null
[pscustomobject]@{ issue = $j.n; column = $(if ($HandOver) { 'Technical Design' } else { 'Todo' }); labels = ($Label -join ', ') } | ConvertTo-Json -Compress
