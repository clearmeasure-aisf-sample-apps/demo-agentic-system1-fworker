# Start guards shared by run.ps1 and run-all.ps1: one test run at a time on a machine, and not on a machine that is short of memory or disk.
# Two runs at once starve each other (4 cores, a suite is ~0.5 GB): the result is timeouts and crashed pwsh processes that read like product defects.
# A run started by another run (run-all's suites, run.ps1's groups) carries FACTORY_TEST_RUN_HELD and is never checked itself.

# Exit code of a refused start (2 is usage, 3 is a port in use).
$script:GuardExit = 4

# Other run.ps1 or run-all.ps1 processes on this machine: not this process, not its ancestors, not a listing call. Linux and macOS; elsewhere none.
function Get-OtherTestRuns {
    $found = @()
    if (-not ($IsLinux -or $IsMacOS)) { return $found }
    $rows = @()
    if ($IsLinux) {
        foreach ($d in [IO.Directory]::EnumerateDirectories('/proc')) {
            $n = [IO.Path]::GetFileName($d); if ($n -notmatch '^\d+$') { continue }
            try { $raw = [IO.File]::ReadAllText("$d/cmdline"); $st = [IO.File]::ReadAllText("$d/stat"); $pp = [int](($st.Substring($st.LastIndexOf(')') + 2) -split ' ')[1]) } catch { continue }
            $rows += , @{ id = [int]$n; parent = $pp; cmd = ($raw -replace "`0", ' ').Trim(); exe = ($raw -split "`0")[0] }
        }
    } else {
        foreach ($l in @(& ps -axo 'pid=,ppid=,args=' 2>$null)) { if ("$l" -match '^\s*(\d+)\s+(\d+)\s+(.*)$') { $rows += , @{ id = [int]$Matches[1]; parent = [int]$Matches[2]; cmd = $Matches[3]; exe = ($Matches[3] -split '\s+')[0] } } }
    }
    $by = @{}; foreach ($r in $rows) { $by[$r.id] = $r }
    $mine = @{ $PID = $true }; $p = $PID
    for ($i = 0; $i -lt 64 -and $by.ContainsKey($p) -and $by[$p].parent -gt 1; $i++) { $p = $by[$p].parent; $mine[$p] = $true }
    foreach ($r in $rows) {
        if ($mine.ContainsKey($r.id)) { continue }
        # the program itself is pwsh (as `pgrep -x pwsh` sees it): a shell whose command line merely quotes the runner's path is no run
        if ([IO.Path]::GetFileName("$($r.exe)") -notmatch '^pwsh(\.exe)?$' -or $r.cmd -notmatch 'tests[/\\]scenarios[/\\]run(-all)?\.ps1' -or $r.cmd -match '-List(Suites|Scenarios)\b') { continue }
        $found += , $r
    }
    return $found
}

function Get-AvailableMemoryMb { try { [int]((Select-String -Path /proc/meminfo -Pattern '^MemAvailable:\s+(\d+)').Matches[0].Groups[1].Value) / 1024 } catch { 99999 } }
# Free space of the filesystem that holds the temp directory (every work directory of a run is under it).
function Get-TempFreeDiskMb { try { [long]([IO.DriveInfo]::new([IO.Path]::GetTempPath()).AvailableFreeSpace / 1MB) } catch { 9999999 } }

# Refuses to start (exit 4) when another run is active or the temp filesystem is below the floor; -Force starts anyway. Returns $true when
# memory is short, so the caller lowers its parallelism. Does nothing in a run that another run started.
function Assert-TestRunMayStart([string]$What, [bool]$Force, [int]$MinFreeDiskMb, [int]$MinAvailableMb) {
    if ($env:FACTORY_TEST_RUN_HELD) { return $false }
    $others = @(Get-OtherTestRuns)
    if ($others.Count -gt 0) {
        $list = ($others | Select-Object -First 4 | ForEach-Object { "pid $($_.id): $($_.cmd.Substring(0, [Math]::Min(140, $_.cmd.Length)))" }) -join "`n  "
        if (-not $Force) { Write-Host "${What}: refused, another test run is active on this machine (two runs at once starve each other and fail for no product reason). Wait for it to end, or pass -Force.`n  $list"; exit $script:GuardExit }
        Write-Host "${What}: -Force, starting although another test run is active:`n  $list"
    }
    $disk = Get-TempFreeDiskMb
    if ($disk -lt $MinFreeDiskMb) {
        if (-not $Force) { Write-Host "${What}: refused, $disk MB free on the filesystem of $([IO.Path]::GetTempPath()), below the floor of $MinFreeDiskMb MB (-MinFreeDiskMb). Free space or set TMPDIR to a larger disk, or pass -Force."; exit $script:GuardExit }
        Write-Host "${What}: -Force, starting with $disk MB free on the temp filesystem (floor $MinFreeDiskMb MB)"
    }
    $mem = Get-AvailableMemoryMb
    if ($mem -lt $MinAvailableMb) { Write-Host "${What}: $([int]$mem) MB of memory available, below $MinAvailableMb MB (-MinAvailableMb): running with less parallelism"; return $true }
    return $false
}
