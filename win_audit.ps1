# =============================================================================
# win_audit.ps1
# Discovers what to back up on Windows 11 and writes a manifest for win_backup.ps1.
#
# RUNS AUTOMATICALLY at the start of every backup (called by win_backup.ps1).
# Can also be run manually at any time to review or update the manifest.
#
# OUTPUT  (all in ~\proton-backup\.backup-manifest\)
#   include.txt           -- file/folder paths fed to tar (auto-generated)
#   exclude.txt           -- patterns fed to tar --exclude-from (auto-generated)
#   include-custom.txt    -- user-managed additions  (never overwritten)
#   exclude-custom.txt    -- user-managed exclusions (never overwritten)
#   winget-export.json    -- winget package list for reinstallation
#   pip-packages.txt      -- pip freeze output (if Python is installed)
#   npm-global.txt        -- npm global packages (if Node.js is installed)
#   schtasks-export.csv   -- own scheduled tasks snapshot
#
# HOW AUTOMATIC DISCOVERY WORKS
#   1. Core user directories      -- Documents, Desktop, .ssh, dotfiles
#   2. Code/project directories   -- Projects, Code, repos, dev, src, git (if found)
#   3. AppData\Roaming            -- application settings (key known locations)
#   4. Package manager lists      -- winget, pip, npm (for reinstall, not binaries)
#
# WHEN YOU ADD NEW PATHS
#   Edit ~\proton-backup\.backup-manifest\include-custom.txt
#   (one path per line, never overwritten)
# =============================================================================

#Requires -Version 5.1

param(
    [string]$ManifestDir = (Join-Path $PSScriptRoot '.backup-manifest'),
    [string]$LogFile     = (Join-Path $PSScriptRoot 'win_backup.log')
)

# Allow callers to override the log path
if ($env:WIN_BACKUP_LOGFILE) { $LogFile = $env:WIN_BACKUP_LOGFILE }

# --- Helpers -----------------------------------------------------------------
function Log  { param([string]$m) $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; "$ts [audit] $m" | Tee-Object -FilePath $LogFile -Append | Out-Host }
function Info { param([string]$m) Write-Host "  . $m" }
function Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

Log "win_audit.ps1 starting"
New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null

$includeFile   = Join-Path $ManifestDir 'include.txt'
$excludeFile   = Join-Path $ManifestDir 'exclude.txt'
$customInclude = Join-Path $ManifestDir 'include-custom.txt'
$customExclude = Join-Path $ManifestDir 'exclude-custom.txt'

# Collect include paths here
$includes = [System.Collections.Generic.List[string]]::new()

function Add-Include {
    param([string]$Path, [string]$Reason = '')
    if (Test-Path $Path) {
        $includes.Add($Path)
        Info "include: $Path$(if ($Reason) {" ($Reason)"})"
    }
}

# =============================================================================
# STEP 1 -- PACKAGE MANAGER SNAPSHOTS
# =============================================================================
Log "Snapshotting installed packages..."

# winget export
$wingetExport = Join-Path $ManifestDir 'winget-export.json'
try {
    winget export -o $wingetExport --accept-source-agreements *>$null
    Ok "winget export: $wingetExport"
} catch {
    Warn "winget export failed (winget not available or no packages)"
}

# pip freeze (if Python available)
$pipPackages = Join-Path $ManifestDir 'pip-packages.txt'
if (Get-Command pip -ErrorAction SilentlyContinue) {
    pip freeze 2>$null | Out-File -FilePath $pipPackages -Encoding utf8
    Ok "pip freeze: $(((Get-Content $pipPackages -ErrorAction SilentlyContinue) | Measure-Object -Line).Lines) packages"
} elseif (Get-Command pip3 -ErrorAction SilentlyContinue) {
    pip3 freeze 2>$null | Out-File -FilePath $pipPackages -Encoding utf8
    Ok "pip3 freeze: $(((Get-Content $pipPackages -ErrorAction SilentlyContinue) | Measure-Object -Line).Lines) packages"
}

# npm global packages (if Node available)
$npmGlobal = Join-Path $ManifestDir 'npm-global.txt'
if (Get-Command npm -ErrorAction SilentlyContinue) {
    npm list -g --depth=0 2>$null | Out-File -FilePath $npmGlobal -Encoding utf8
    Ok "npm global: $npmGlobal"
}

# Scheduled tasks snapshot (own user tasks only)
$schtasksExport = Join-Path $ManifestDir 'schtasks-export.csv'
try {
    schtasks /query /fo CSV /v 2>$null | Out-File -FilePath $schtasksExport -Encoding utf8
    Ok "Scheduled tasks: $schtasksExport"
} catch { }

# =============================================================================
# STEP 2 -- BUILD INCLUDE LIST
# =============================================================================
Log "Building include list..."

$homeDir = $env:USERPROFILE

# -- Always include -----------------------------------------------------------
Add-Include (Join-Path $homeDir 'Documents')       'user documents'
Add-Include (Join-Path $homeDir 'Desktop')         'desktop files'
Add-Include (Join-Path $homeDir '.ssh')            'SSH keys'
Add-Include (Join-Path $homeDir '.gitconfig')      'git config'
Add-Include (Join-Path $homeDir '.gitignore_global') 'global gitignore'
Add-Include (Join-Path $homeDir '.npmrc')          'npm config'
Add-Include (Join-Path $homeDir '.gnupg')          'GPG keys'
Add-Include $ManifestDir                        'backup manifest itself'

# -- Code / project directories -----------------------------------------------
foreach ($dir in @('Projects','Code','code','repos','dev','src','git','Development','workspace')) {
    Add-Include (Join-Path $homeDir $dir) "code directory"
}

# -- AppData\Roaming -- known application config locations --------------------
$roaming = $env:APPDATA   # = %USERPROFILE%\AppData\Roaming

# Windows Terminal settings
Add-Include (Join-Path $roaming 'Microsoft\Windows Terminal') 'Windows Terminal'

# VSCode settings
Add-Include (Join-Path $roaming 'Code\User')    'VSCode user settings'
Add-Include (Join-Path $homeDir '.vscode')         'VSCode extensions list'

# PowerShell profile
$psProfile = Split-Path $PROFILE -Parent
Add-Include $psProfile 'PowerShell profile'

# Git credential helper config
Add-Include (Join-Path $roaming 'GitHub')       'GitHub Desktop / GCM'

# npm global config
Add-Include (Join-Path $roaming 'npm')          'npm global config'

# Python pip config
Add-Include (Join-Path $roaming 'pip')          'pip config'

# -- User-managed additions ---------------------------------------------------
if (Test-Path $customInclude) {
    Get-Content $customInclude | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } | ForEach-Object {
        Add-Include $_.Trim() 'from include-custom.txt'
    }
}

# Deduplicate and convert to paths relative to USERPROFILE.
# BSD tar is called with -C $homeDir so all include paths must be relative to that.
# "C:\Users\andre\Documents" -> "Documents"
# Paths outside USERPROFILE are kept as-is (rare; tar will warn about drive letters).
$relIncludes = $includes | Sort-Object -Unique | Where-Object { $_ -ne '' } | ForEach-Object {
    if ($_.StartsWith($homeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        $_.Substring($homeDir.Length).TrimStart('\').TrimStart('/')
    } else {
        $_
    }
} | Where-Object { $_ -ne '' }

# Normalize to forward slashes (BSD tar uses / internally on Windows)
# and write without a trailing newline -- Set-Content adds one, which BSD tar
# interprets as a blank 7th entry and warns "Couldn't visit directory: No such file".
$normalizedIncludes = $relIncludes | ForEach-Object { $_ -replace '\\', '/' }
($normalizedIncludes -join "`n") | Set-Content $includeFile -Encoding utf8 -NoNewline
Log "include.txt: $($normalizedIncludes.Count) paths (relative to $homeDir)"

# =============================================================================
# STEP 3 -- BUILD EXCLUDE LIST
# =============================================================================
Log "Building exclude list..."

# BSD tar (Windows) uses --exclude patterns; these are glob patterns relative
# to the archive root (i.e., relative to the -C directory used during creation).
@"
# Auto-generated by win_audit.ps1 -- DO NOT EDIT directly.
# Add personal exclusions to %USERPROFILE%\proton-backup\.backup-manifest\exclude-custom.txt instead.

# -- Node.js -- regenerate with: npm install --
node_modules

# -- Python virtual environments -- regenerate with: pip install -r requirements.txt --
.venv
venv
env
.env
__pycache__
*.pyc
*.pyo
*.egg-info

# -- Build output --
bin/Debug
bin/Release
obj
build
dist
out
.next
.nuxt

# -- IDE / editor caches --
.vs
.idea
*.suo
*.user
.ionide

# -- Windows temp / cache --
AppData/Local/Temp
AppData/Local/Microsoft/Windows/INetCache
AppData/Local/Microsoft/Windows/Explorer
AppData/Local/CrashDumps
AppData/Local/D3DSCache
AppData/Local/NVIDIA

# -- Log files --
*.log
*.log.[0-9]*

# -- Large media / archives (edit include-custom.txt to add back specific ones) --
*.iso
*.vmdk
*.vhd
*.vhdx

# -- OneDrive (already in cloud) --
OneDrive

# -- Windows shell junction folders in Documents (circular / cross-device symlinks) --
# tar reports paths with forward slashes, so patterns must use forward slashes.
Documents/My Videos
Documents/My Music
Documents/My Pictures
Documents/My Documents

# -- Hidden temp / scratch directories in Documents --
Documents/$Temp

# -- Recycle Bin --
`$RECYCLE.BIN
"@ | Set-Content $excludeFile -Encoding utf8

# Merge user-managed exclusions
if (Test-Path $customExclude) {
    $userExcludes = Get-Content $customExclude | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
    if ($userExcludes) {
        "`n# -- From exclude-custom.txt --" | Add-Content $excludeFile -Encoding utf8
        $userExcludes | Add-Content $excludeFile -Encoding utf8
        Log "exclude-custom.txt merged ($($userExcludes.Count) entries)"
    }
}
# BSD tar on Windows treats blank lines in --exclude-from as empty patterns.
# Read into variable first (can't pipe Get-Content to Set-Content on the same file).
$excludeClean = Get-Content $excludeFile | Where-Object { $_.Trim() -ne '' }
($excludeClean -join "`n") | Set-Content $excludeFile -Encoding utf8 -NoNewline
Log "exclude.txt written"

# =============================================================================
# STEP 4 -- INITIALISE CUSTOM FILES IF MISSING
# =============================================================================
if (-not (Test-Path $customInclude)) {
    @"
# %USERPROFILE%\proton-backup\.backup-manifest\include-custom.txt
# Paths not auto-discovered by win_audit.ps1.
# One absolute path per line. Lines starting with # are ignored.
# This file is NEVER overwritten by the audit.
#
# Examples:
#   C:\MyApp\data
#   D:\Projects\ClientWork
"@ | Set-Content $customInclude -Encoding utf8
    Ok "Created $customInclude"
}

if (-not (Test-Path $customExclude)) {
    @"
# %USERPROFILE%\proton-backup\.backup-manifest\exclude-custom.txt
# Patterns to exclude (tar glob syntax, one per line, relative to home dir).
# This file is NEVER overwritten by the audit.
#
# Examples (use forward slashes -- BSD tar uses / internally on Windows):
#   Documents/LargeDataset
#   *.psd
#   Projects/OldArchive
"@ | Set-Content $customExclude -Encoding utf8
    Ok "Created $customExclude"
}

# =============================================================================
# REPORT
# =============================================================================
$lineCount = (Get-Content $includeFile | Measure-Object -Line).Lines
# Shorten manifest dir for display: replace USERPROFILE prefix with ~
$displayDir = $ManifestDir -replace [regex]::Escape($homeDir), '~'
Write-Host ""
Write-Host "+----------------------------------------------------------+"
Write-Host "|  Backup Manifest Updated                                 |"
Write-Host "+----------------------------------------------------------+"
Write-Host ("| {0,-20} {1,-37} |" -f "  Include paths:", $lineCount)
Write-Host ("| {0,-20} {1,-37} |" -f "  Manifest dir:", $displayDir)
Write-Host "+----------------------------------------------------------+"
Write-Host "|  Add paths audit misses:                                 |"
Write-Host "|    edit ~\proton-backup\.backup-manifest\include-custom.txt |"
Write-Host "|  Add exclusion patterns:                                 |"
Write-Host "|    edit ~\proton-backup\.backup-manifest\exclude-custom.txt |"
Write-Host "+----------------------------------------------------------+"
Write-Host ""

Log "win_audit.ps1 complete"
