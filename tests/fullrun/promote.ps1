#!/usr/bin/env pwsh
# uat and prod are the operator's manual promotions (each starts with an Octopus sign-off). This prints the exact kit command per release and runs it
# only with -Run. The factory's own Octopus key is read-only and never deploys.
# usage: pwsh tests/fullrun/promote.ps1 -Release 2.4.120 -To uat [-Run]
param([Parameter(Mandatory)] [string] $Release, [Parameter(Mandatory)] [ValidateSet('uat', 'prod')] [string] $To, [switch] $Run)
# The kit's checkout and the account that runs it come from the environment: FACTORY_KIT_DIR and FACTORY_KIT_USER.
$kit = $env:FACTORY_KIT_DIR; $kitUser = $env:FACTORY_KIT_USER
if (-not $kit -or -not $kitUser) { throw 'set FACTORY_KIT_DIR (the demo environment kit checkout) and FACTORY_KIT_USER (the account that runs it)' }
if ($kit -notmatch '^[A-Za-z0-9._/-]+$' -or $kitUser -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'FACTORY_KIT_DIR or FACTORY_KIT_USER has characters that are not allowed' }
$cmd = "cd $kit && pwsh .claude/skills/demo-environment/scripts/invoke-demo-promotion.ps1 -Config $kit/fleet/systems/cmdemo1.json -Project deployable -Environment $To -Release $Release -Wait -Approve -Reason 'factory-worker full test run: text replacement item, reviewed and approved'"
$full = "sudo -n -u $kitUser -H bash -lc '$cmd'"
if ($Run) { & bash -c $full } else { $full }
