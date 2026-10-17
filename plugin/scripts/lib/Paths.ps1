# Where a worker keeps its own files (item tokens, worker pid files, the QC profile, cached App tokens). Nothing is assumed to exist:
# FACTORY_DATA_DIR wins; otherwise a folder under the user's home directory; when the machine has no usable home (a container with HOME unset or
# read-only) a folder under the temp directory. The folder is created on first use. Each specific directory can still be set on its own
# (FACTORY_TOKEN_DIR, FACTORY_WORKER_DIR, FACTORY_STATE_DIR, FACTORY_WORKER_STATE_DIR, FACTORY_QC_BASE_DIR).

function Get-FwHome {
    foreach ($h in @($env:HOME, $env:USERPROFILE, [Environment]::GetFolderPath('UserProfile'))) {
        if ($h -and (Test-Path -LiteralPath $h -PathType Container)) { return $h }
    }
    return $null
}

function Get-FwDataDir {
    if ($env:FACTORY_DATA_DIR) { New-Item -ItemType Directory -Force -Path $env:FACTORY_DATA_DIR | Out-Null; return $env:FACTORY_DATA_DIR }
    $h = Get-FwHome
    if ($h) {
        $d = Join-Path $h '.local/share/factory-worker'
        try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; return $d } catch { }
    }
    $d = Join-Path ([IO.Path]::GetTempPath()) 'factory-worker'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# A sub directory of the data directory (created), e.g. Get-FwSubDir 'tokens'.
function Get-FwSubDir([string]$Name, [string]$Override) {
    $d = if ($Override) { $Override } else { Join-Path (Get-FwDataDir) $Name }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# The work directory of a session (<BASE>/work of the connect prompt, beside its data directory <BASE>/data): build logs and saved answers go
# there, never into a repository checkout. FACTORY_WORK_DIR wins; else the sibling "work" of FACTORY_DATA_DIR; else "work" in the data directory.
function Get-FwWorkDir {
    $d = if ($env:FACTORY_WORK_DIR) { $env:FACTORY_WORK_DIR }
         elseif ($env:FACTORY_DATA_DIR) { Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($env:FACTORY_DATA_DIR).TrimEnd('/', '\'))) 'work' }
         else { Join-Path (Get-FwDataDir) 'work' }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Optional operator configuration (client.json, models.json, App ids). Never created, may not exist: $null when the machine has no home.
function Get-FwConfigPath([string]$Relative) {
    $h = Get-FwHome
    if (-not $h) { return $null }
    return Join-Path $h (Join-Path '.config/factory-worker' $Relative)
}

# The user name for a default holder, on any platform.
function Get-FwUserName {
    foreach ($u in @($env:USER, $env:USERNAME, $env:LOGNAME)) { if ($u) { return $u } }
    try { return [Environment]::UserName } catch { return 'worker' }
}
