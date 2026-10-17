# Local progress of the items a stream session owns (gateway/Lease.cs, rule 3). An owner that waits on a long subagent (a private build, an app run,
# a functional test) calls no verb for many minutes, and the gateway would read that as a session gone quiet and take the item back. The stream
# client looks at this machine instead and reports, with its heartbeat, the latest work it saw per owned item:
#   marker   a progress file a subagent wrote: <work>/progress/<N>.txt (any content; only its time is read)
#   work     any other file written in the work directory (briefs, results, logs)
#   commit   a commit, checkout or staging in one of the item's git worktrees (the worktree's index and HEAD log)
#   files    a file or directory changed in one of the item's worktrees (builds write obj/ and bin/, editors write sources)
#   process  a build or test process (dotnet, a test host, a browser of a UI test, a build script) that used CPU since the last look, in one of the
#            item's worktrees (Linux only: /proc; elsewhere the other four)
# A place belongs to item N when its path or branch names N as a whole token (factory-worker/308-development, brief-308.md); while the session owns
# one item (the rule: one item per session) every worktree of its checkouts and every file of its work directory belong to that item. Nothing
# here calls the gateway or changes a file; git is the only program it runs, and every look is bounded in entries and time.

$script:PgLib = $PSCommandPath
$script:PgSkipDirs = [Collections.Generic.HashSet[string]]::new([string[]]@('.git', 'node_modules'), [StringComparer]::OrdinalIgnoreCase)
# files of the work directory that the client, the launcher or the stream write by themselves: never progress
$script:PgWorkSkip = [regex]::new('^(events\.log.*|launcher.*|session-ended.*|session-restart.*|STOP|.*\.pid)$', 'IgnoreCase')
# build and test programs by process name (Linux comm, at most 15 characters), and scripts or tools recognised by their command line
$script:PgBuildNames = [regex]::new('^(dotnet|testhost.*|msbuild.*|vstest.*|vbcscompiler|csc|chrome.*|chromium.*|headless_shell|firefox|msedge|npm|npx|yarn|pnpm|java|gradle.*|mvn|cargo|rustc|go|make|cmake|gcc|cc1.*|clang.*)$', 'IgnoreCase')
$script:PgBuildCmd = [regex]::new('(build\.ps1|app-shot\.ps1|app-run\.ps1|ensure-tools\.ps1|playwright|jest|vitest|mocha|pytest)', 'IgnoreCase')

# Does this path or branch name N as a whole token (no letter or digit next to it)? '308' in 'factory-worker/308-development' or 'brief-308.md', never
# in 'agent-a3081f' or '1308'.
function Test-NamesItem([string]$Text, [int]$Item) {
    if (-not $Text -or $Item -le 0) { return $false }
    return [regex]::IsMatch($Text, "(^|[^0-9A-Za-z])$Item([^0-9A-Za-z]|$)")
}

# The state shared by the stream loop and the heartbeat thread (synchronized: both run in the client's one process).
#   owned     item -> when this client learned it owns it (item.assigned own-item, item.accepted; removed on item.taken_back, item.complete, session.end)
#   progress  item -> @{ at; source } the latest work seen;  sent  item -> the time last reported to the gateway
function New-ProgressState([string]$WorkDir = '', [string[]]$Repos = @(), [double]$RecentMinutes = 0) {
    $recent = if ($RecentMinutes -gt 0) { $RecentMinutes } elseif ($env:FACTORY_PROGRESS_RECENT_MINUTES -match '^\d+(\.\d+)?$') { [double]$env:FACTORY_PROGRESS_RECENT_MINUTES } else { 10 }
    $places = Get-ProgressPlaces $WorkDir $Repos
    return [hashtable]::Synchronized(@{
            owned = [hashtable]::Synchronized(@{}); progress = [hashtable]::Synchronized(@{}); sent = [hashtable]::Synchronized(@{})
            cpu = [hashtable]::Synchronized(@{}); work = $places.work; repos = $places.repos; worktrees = $null; worktreesAt = [DateTime]::MinValue
            recentMinutes = $recent; off = ($env:FACTORY_PROGRESS -eq '0'); report = ($env:FACTORY_PROGRESS_HEARTBEAT -ne '0'); lib = $script:PgLib
        })
}

# Where this session works: the work directory (--work-dir, FACTORY_WORK_DIR, the folder of the launcher's end marker, or <BASE>/work beside
# FACTORY_DATA_DIR) and the git checkouts (--repo, FACTORY_REPO_DIR, FACTORY_SANDBOX_REPO, <BASE>/repo; the current directory when none of them is one).
function Get-ProgressPlaces([string]$WorkDir = '', [string[]]$Repos = @()) {
    $work = ''
    $base = if ($env:FACTORY_DATA_DIR) { Split-Path -Parent $env:FACTORY_DATA_DIR } else { '' }
    foreach ($w in @($WorkDir, $env:FACTORY_WORK_DIR, $(if ($env:FACTORY_SESSION_END_FILE) { Split-Path -Parent $env:FACTORY_SESSION_END_FILE }), $(if ($base) { Join-Path $base 'work' }))) {
        if ($w -and (Test-Path -LiteralPath $w -PathType Container)) { $work = (Resolve-Path -LiteralPath $w).ProviderPath; break }
    }
    $found = [Collections.Generic.List[string]]::new()
    foreach ($r in @($Repos) + @($env:FACTORY_REPO_DIR, $env:FACTORY_SANDBOX_REPO, $(if ($base) { Join-Path $base 'repo' }))) {
        if (-not $r -or -not (Test-Path -LiteralPath (Join-Path $r '.git'))) { continue }
        $full = (Resolve-Path -LiteralPath $r).ProviderPath
        if (-not $found.Contains($full)) { $found.Add($full) }
    }
    # the checkout around the current directory only when nothing named one (the session usually starts its stream in its checkout)
    if ($found.Count -eq 0) {
        $top = try { "$(& git rev-parse --show-toplevel 2>$null)".Trim() } catch { '' }
        if ($top -and (Test-Path -LiteralPath $top -PathType Container)) { $found.Add((Resolve-Path -LiteralPath $top).ProviderPath) }
    }
    return @{ work = $work; repos = @($found) }
}

# The worktrees of the checkouts (git worktree list), read again at most every 2 minutes: @{ path; branch; gitdir }.
function Get-ProgressWorktrees($State) {
    if ($null -ne $State.worktrees -and ([DateTime]::UtcNow - $State.worktreesAt).TotalSeconds -lt 120) { return $State.worktrees }
    $list = [Collections.Generic.List[object]]::new(); $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($repo in @($State.repos)) {
        $lines = try { @(& git -C $repo worktree list --porcelain 2>$null) } catch { @() }
        $cur = $null
        foreach ($l in @($lines) + @('')) {
            if ($l -like 'worktree *') { $cur = @{ path = $l.Substring(9); branch = ''; gitdir = '' } }
            elseif ($cur -and $l -like 'branch *') { $cur.branch = $l.Substring(7) -replace '^refs/heads/', '' }
            elseif ($cur -and -not $l) {
                if ((Test-Path -LiteralPath $cur.path -PathType Container) -and $seen.Add($cur.path)) {
                    $dotgit = Join-Path $cur.path '.git'
                    if (Test-Path -LiteralPath $dotgit -PathType Container) { $cur.gitdir = $dotgit }
                    elseif (Test-Path -LiteralPath $dotgit -PathType Leaf) {
                        $g = try { ((Get-Content -Raw -LiteralPath $dotgit) -replace '^gitdir:\s*', '').Trim() } catch { '' }
                        if ($g -and -not [IO.Path]::IsPathRooted($g)) { $g = Join-Path $cur.path $g }
                        if ($g -and (Test-Path -LiteralPath $g -PathType Container)) { $cur.gitdir = $g }
                    }
                    $list.Add($cur)
                }
                $cur = $null
            }
        }
    }
    $State.worktrees = @($list); $State.worktreesAt = [DateTime]::UtcNow
    return $State.worktrees
}

# The newest write time under a directory (files and directories), skipping .git and node_modules and never following a link. Stops early at the
# first entry newer than $After (enough to know there is news), after $MaxEntries entries or $Budget (a Stopwatch shared by one look) at $MaxMs.
# $Skip, when given, filters names out. Returns [DateTime] (UTC), or MinValue when nothing was read.
function Get-NewestWrite([string]$Dir, [DateTime]$After, [int]$MaxEntries, [Diagnostics.Stopwatch]$Budget, [int]$MaxMs, [regex]$Skip = $null) {
    # a time in the future (a skewed mount, a restored archive) is no sign of work: it would keep an item busy for ever
    $newest = [DateTime]::MinValue; $n = 0; $limit = [DateTime]::UtcNow.AddMinutes(2)
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    try { $stack.Push([IO.DirectoryInfo]::new($Dir)) } catch { return $newest }
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $entries = try { $d.EnumerateFileSystemInfos() } catch { continue }
        try {
            foreach ($e in $entries) {
                if ($Skip -and $Skip.IsMatch($e.Name)) { continue }
                $isDir = ($e.Attributes -band [IO.FileAttributes]::Directory) -ne 0
                if ($isDir -and $script:PgSkipDirs.Contains($e.Name)) { continue }
                $t = $e.LastWriteTimeUtc
                if ($t -le $limit) {
                    if ($t -gt $newest) { $newest = $t }
                    if ($newest -gt $After) { return $newest }
                }
                if ($isDir -and ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push([IO.DirectoryInfo]$e) }
                if (++$n -ge $MaxEntries -or $Budget.ElapsedMilliseconds -ge $MaxMs) { return $newest }
            }
        } catch { }
    }
    return $newest
}

# A build or test process at work (Linux, /proc): one whose name is a build or test program, or whose command line names a build script or a test
# runner, whose current directory or command line lies in one of $Dirs, and that used CPU since the last look for this item (a process seen for the
# first time counts when it started within the last minute). The CPU baselines are kept per item. Returns $true or $false; on other systems $false.
function Test-BuildProcess($State, [int]$Item, [string[]]$Dirs) {
    if (-not $IsLinux -or $Dirs.Count -eq 0 -or -not (Test-Path -LiteralPath '/proc/self')) { return $false }
    $tick = 100.0; $found = $false; $alive = [Collections.Generic.HashSet[string]]::new()
    foreach ($p in [IO.Directory]::EnumerateDirectories('/proc')) {
        $id = [IO.Path]::GetFileName($p)
        if ($id -notmatch '^\d+$' -or $id -eq "$PID") { continue }
        try {
            $comm = [IO.File]::ReadAllText("$p/comm").Trim()
            $cmd = ''
            if (-not $script:PgBuildNames.IsMatch($comm)) {
                if ($comm -notmatch '^(node|pwsh|powershell|bash|sh)$') { continue }
                $cmd = [IO.File]::ReadAllText("$p/cmdline").Replace([char]0, ' ')
                if (-not $script:PgBuildCmd.IsMatch($cmd)) { continue }
            }
            $cwd = "$([IO.DirectoryInfo]::new("$p/cwd").LinkTarget)"
            if (-not $cmd) { $cmd = [IO.File]::ReadAllText("$p/cmdline").Replace([char]0, ' ') }
            $inside = $false
            foreach ($d in $Dirs) { $dd = $d.TrimEnd('/'); if (($cwd -and ($cwd + '/').StartsWith($dd + '/', [StringComparison]::Ordinal)) -or [regex]::IsMatch($cmd, [regex]::Escape($dd) + '(/|\s|$)')) { $inside = $true; break } }
            if (-not $inside) { continue }
            # utime and stime: fields 14 and 15 of stat, counted after the ')' that ends the name (a name may hold spaces)
            $stat = [IO.File]::ReadAllText("$p/stat"); $f = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ')
            $cpu = ([double]$f[11] + [double]$f[12]) / $tick
            $key = "$Item/$id/$($f[19])"   # the item, the pid with its start time (a reused pid is a new process)
            [void]$alive.Add($key)
            if ($State.cpu.ContainsKey($key)) { if ($cpu - [double]$State.cpu[$key] -ge 0.2) { $found = $true } }
            elseif ($cpu -ge 0.2) {
                $up = try { [double]([IO.File]::ReadAllText('/proc/uptime').Split(' ')[0]) - [double]$f[19] / $tick } catch { 1e9 }
                if ($up -le 60) { $found = $true }
            }
            $State.cpu[$key] = $cpu
        } catch { continue }
    }
    # (a copy: the stream thread may look too, on an item.check)
    foreach ($k in @($State.cpu.Clone().Keys)) { if ("$k".StartsWith("$Item/", [StringComparison]::Ordinal) -and -not $alive.Contains($k)) { $State.cpu.Remove($k) } }
    return $found
}

# The later of two observations: $Best (@{ at; source } or $null) or the time $At seen by $Source.
function Select-NewerProgress($Best, [DateTime]$At, [string]$Source) {
    if ($At -le [DateTime]::MinValue) { return $Best }
    if ($null -eq $Best -or $At -gt [DateTime]$Best.at) { return @{ at = $At; source = $Source } }
    return $Best
}

# The latest work seen for one item: @{ at; source } or $null. $Single: the session owns this item only, so every worktree of its checkouts and its
# whole work directory are the item's. A look searches for news since the latest of the last progress seen, the moment this client learned it owns
# the item and 15 minutes ago, and stops at the first it finds per place. $Budget (shared by one whole look) ends the walks after 4 s. Times in the
# future are no news.
function Get-ItemProgress($State, [int]$Item, [bool]$Single, [Diagnostics.Stopwatch]$Budget) {
    $now = [DateTime]::UtcNow; $limit = $now.AddMinutes(2)
    $prev = $State.progress[$Item]
    $after = $now.AddMinutes(-15); if ($prev -and [DateTime]$prev.at -gt $after) { $after = [DateTime]$prev.at }
    $since = $State.owned[$Item]; if ($since -is [DateTime] -and $since -gt $after) { $after = $since }
    $best = $null
    $dirs = [Collections.Generic.List[string]]::new()
    if ($State.work) {
        # marker: <work>/progress/<N>.txt (or <N>, <N>.anything)
        $pdir = Join-Path $State.work 'progress'
        if (Test-Path -LiteralPath $pdir -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $pdir -File -ErrorAction SilentlyContinue)) { if ($f.Name -match "^$Item(\..*)?$" -and $f.LastWriteTimeUtc -gt $after -and $f.LastWriteTimeUtc -le $limit) { $best = Select-NewerProgress $best $f.LastWriteTimeUtc 'marker' } }
        }
        if ($Single) {
            $w = Get-NewestWrite $State.work $after 3000 $Budget 4000 $script:PgWorkSkip
            if ($w -gt $after) { $best = Select-NewerProgress $best $w 'work' }
            [void]$dirs.Add($State.work)
        }
    }
    # the item's worktrees: git activity first (index, HEAD log), then a walk of their files, the most recently touched first
    $ranked = @(foreach ($wt in @(Get-ProgressWorktrees $State)) {
            if (-not ($Single -or (Test-NamesItem $wt.branch $Item) -or (Test-NamesItem (Split-Path -Leaf $wt.path) $Item))) { continue }
            [void]$dirs.Add($wt.path)
            $g = [DateTime]::MinValue
            if ($wt.gitdir) { foreach ($gf in 'index', 'logs/HEAD', 'HEAD') { $gp = Join-Path $wt.gitdir $gf; if (Test-Path -LiteralPath $gp) { $gt = (Get-Item -LiteralPath $gp).LastWriteTimeUtc; if ($gt -gt $g -and $gt -le $limit) { $g = $gt } } } }
            if ($g -gt $after) { $best = Select-NewerProgress $best $g 'commit' }
            [pscustomobject]@{ path = $wt.path; git = $g }
        })
    foreach ($r in @($ranked | Sort-Object git -Descending)) {
        if ($Budget.ElapsedMilliseconds -ge 4000) { break }
        $ft = Get-NewestWrite $r.path $after 20000 $Budget 4000
        if ($ft -gt $after) { $best = Select-NewerProgress $best $ft 'files' }
    }
    if (Test-BuildProcess $State $Item @($dirs)) { $best = Select-NewerProgress $best $now 'process' }
    if ($best -and (-not $prev -or [DateTime]$best.at -gt [DateTime]$prev.at)) { $State.progress[$Item] = $best }
    return $State.progress[$Item]
}

# One look for the heartbeat: every owned item, and the entries newer than what was last reported (for the presence body's "progress": how many
# seconds ago, by this machine's clock, so the gateway's clock decides what is recent).
function Get-ProgressReport($State) {
    if ($State.off) { return @() }
    $items = @($State.owned.Clone().Keys | ForEach-Object { [int]$_ } | Sort-Object)
    if ($items.Count -eq 0) { return @() }
    $budget = [Diagnostics.Stopwatch]::StartNew(); $out = @()
    foreach ($i in $items) {
        $p = try { Get-ItemProgress $State $i ($items.Count -eq 1) $budget } catch { $null }
        if (-not $p) { continue }
        $sent = $State.sent[$i]
        if ($sent -and [DateTime]$p.at -le [DateTime]$sent) { continue }
        if (([DateTime]::UtcNow - [DateTime]$p.at).TotalMinutes -gt 15) { continue }   # old work says nothing about now
        $out += [ordered]@{ item = $i; ageSeconds = [int][Math]::Max(0, ([DateTime]::UtcNow - [DateTime]$p.at).TotalSeconds); source = "$($p.source)"; seen = ([DateTime]$p.at).ToString('o') }
    }
    return $out
}

# Recent work on one item (for the client's own answer to item.check): the last look when it is under a minute old, else a fresh one.
function Get-RecentProgress($State, [int]$Item) {
    if ($State.off) { return $null }
    $p = $State.progress[$Item]
    if (-not $p -or ([DateTime]::UtcNow - [DateTime]$p.at).TotalMinutes -ge $State.recentMinutes) {
        $single = $State.owned.Count -eq 0 -or ($State.owned.Count -eq 1 -and $State.owned.ContainsKey($Item))
        $p = try { Get-ItemProgress $State $Item $single ([Diagnostics.Stopwatch]::StartNew()) } catch { $null }
    }
    if ($p -and ([DateTime]::UtcNow - [DateTime]$p.at).TotalMinutes -lt $State.recentMinutes) { return $p }
    return $null
}
