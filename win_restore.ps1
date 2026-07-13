# =============================================================================
# win_restore.ps1 -- Restore utility for Win11 PZ13 Proton Drive backups
#
# QUICK START
#   .\win_restore.ps1 list                        # see what's available
#   .\win_restore.ps1 check  latest               # verify archive is intact
#   .\win_restore.ps1 browse latest               # inspect contents
#   .\win_restore.ps1 live   latest               # what changed since backup?
#   .\win_restore.ps1 restore staging latest      # safe preview to %TEMP%\restore-staging\
#   .\win_restore.ps1 restore full    latest      # commit full restore
#
# BACKUP NAME SHORTCUTS
#   latest                    Most recently stored backup
#   2026-06-29                Backup by date (YYYY-MM-DD)
#   win11-pz13-2026-06-29.tar.gz   Full filename
#
# Run  help           for full command reference.
# Run  help <command> for detailed help on one command.
# =============================================================================

#Requires -Version 5.1

param(
    [Parameter(Position=0)] [string]$Command  = '',
    [Parameter(Position=1)] [string]$Arg1     = '',
    [Parameter(Position=2)] [string]$Arg2     = '',
    [Parameter(Position=3)] [string]$Arg3     = ''
)

# -- Configuration ------------------------------------------------------------
$REMOTE_BASE  = '/my-files/PZ13'
$PROTON       = Join-Path $PSScriptRoot 'proton-drive.exe'
$STAGING_DIR  = Join-Path $env:TEMP 'restore-staging'
$DOWNLOAD_DIR = $env:TEMP
$RESTORE_LOG  = Join-Path $PSScriptRoot 'win_restore.log'
$HOME_DIR     = $env:USERPROFILE

# -- Output helpers -----------------------------------------------------------
function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "  [ERR]  $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "  [..] $m" -ForegroundColor Cyan }
function Write-Hdr  { param([string]$m) Write-Host ""; Write-Host " $m " -ForegroundColor White -BackgroundColor DarkBlue; Write-Host ("-" * 62) -ForegroundColor Blue }
function Write-Sep  { Write-Host ("-" * 62) -ForegroundColor Blue }

function Log {
    param([string]$m)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts $m" | Add-Content -Path $RESTORE_LOG -Encoding utf8
}

function Fail { param([string]$m) Write-Err $m; exit 1 }

# -- Proton Drive helpers -----------------------------------------------------
function Resolve-BackupName {
    param([string]$Input)
    if ($Input -like 'win11-pz13-*.tar.gz') { return $Input }
    if ($Input -match '^\d{4}-\d{2}-\d{2}$') { return "win11-pz13-$Input.tar.gz" }
    if ($Input -eq 'latest') {
        $json  = & $PROTON filesystem list $REMOTE_BASE --json 2>$null
        $items = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $items) { Fail "No backups found or cannot parse listing" }
        $name  = ($items | Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } |
                  Sort-Object { $_.name.value } | Select-Object -Last 1).name.value
        if (-not $name) { Fail "No backups found in $REMOTE_BASE" }
        return $name
    }
    # Partial match
    $json  = & $PROTON filesystem list $REMOTE_BASE --json 2>$null
    $items = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
    $name  = ($items | Where-Object { $_.name.value -like "*$Input*" } |
              Sort-Object { $_.name.value } | Select-Object -Last 1).name.value
    if (-not $name) { Fail "Cannot resolve backup name: '$Input'" }
    return $name
}

function Ensure-Local {
    param([string]$Name)
    $path = Join-Path $DOWNLOAD_DIR $Name
    if (Test-Path $path) {
        Write-Info "Using cached: $path"
        return $path
    }
    Write-Info "Downloading $Name from Proton Drive..."
    & $PROTON filesystem download "$REMOTE_BASE/$Name" "$DOWNLOAD_DIR/" 2>&1 |
        ForEach-Object { Log "  download: $_" }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $path)) {
        Fail "Download failed -- see $RESTORE_LOG"
    }
    $sz = "{0:N1} MB" -f ((Get-Item $path).Length / 1MB)
    Write-Ok "Downloaded: $path ($sz)"
    return $path
}

# =============================================================================
# COMMAND: list
# =============================================================================
function Invoke-List {
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }
    Write-Hdr "Remote Backups -- $REMOTE_BASE"

    $json  = & $PROTON filesystem list $REMOTE_BASE --json 2>$null
    $items = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
    $backups = $items | Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } | Sort-Object { $_.name.value }

    if (-not $backups) { Write-Warn "No backups found in $REMOTE_BASE"; return }

    Write-Host ("  {0,-42}  {1,8}  {2}" -f "Filename","Size","Date") -ForegroundColor White
    Write-Sep
    $backups | ForEach-Object {
        $sizeMB   = "{0:N1} MB" -f ($_.totalStorageSize / 1MB)
        $dateStr  = if ($_.modificationTime) { ([datetime]$_.modificationTime).ToString('yyyy-MM-dd HH:mm') } else { '?' }
        Write-Host ("  {0,-42}  {1,8}  {2}" -f $_.name.value, $sizeMB, $dateStr)
    }
    Write-Sep
    Write-Host "  $(@($backups).Count) backup(s) stored - retention limit: 5"
    Write-Host ""
    Write-Info "Use the date (e.g. 2026-06-29) or 'latest' as <backup> in other commands."
    Write-Host ""
}

# =============================================================================
# COMMAND: check
# =============================================================================
function Invoke-Check {
    param([string]$BackupArg)
    if (-not $BackupArg) { Show-HelpCheck; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Archive Integrity Check -- $name"
    $f = Ensure-Local $name
    Log "check: $name"
    Write-Info "Reading every block (may take a minute)..."

    $output   = tar -tzf $f 2>&1
    $fileCount = ($output | Where-Object { $_ -notmatch '^tar:' } | Measure-Object -Line).Lines

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Archive is intact -- $fileCount entries"
        Log "check OK: $name ($fileCount entries)"
    } else {
        Write-Err "Archive is CORRUPT or truncated -- do not restore from this file"
        Log "check FAILED: $name"
        exit 1
    }
    Write-Host ""
}

# =============================================================================
# COMMAND: diff
# =============================================================================
function Invoke-Diff {
    param([string]$B1, [string]$B2)
    if (-not $B1 -or -not $B2) { Show-HelpDiff; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $n1 = Resolve-BackupName $B1
    $n2 = Resolve-BackupName $B2
    Write-Hdr "Backup Diff:  $n1  ->  $n2"
    Write-Warn "Downloads both archives if not cached. Continue? [y/N]: "
    $confirm = Read-Host
    if ($confirm -notmatch '^[Yy]$') { Write-Host "Aborted."; exit 0 }

    $f1 = Ensure-Local $n1
    $f2 = Ensure-Local $n2

    Write-Info "Building file lists..."
    $list1 = (tar -tzf $f1 2>$null) | Where-Object { $_ -notmatch '^tar:' } | Sort-Object
    $list2 = (tar -tzf $f2 2>$null) | Where-Object { $_ -notmatch '^tar:' } | Sort-Object

    $set1    = [System.Collections.Generic.HashSet[string]]$list1
    $set2    = [System.Collections.Generic.HashSet[string]]$list2
    $removed = $list1 | Where-Object { -not $set2.Contains($_) }
    $added   = $list2 | Where-Object { -not $set1.Contains($_) }

    Write-Host ""
    Write-Host "  Summary" -ForegroundColor White
    Write-Host ("  {0,-38} {1,6} files" -f "${n1} (older):", $list1.Count)
    Write-Host ("  {0,-38} {1,6} files" -f "${n2} (newer):", $list2.Count)
    Write-Host ("  {0,-38} {1,6}"       -f "Removed in newer:", $removed.Count)
    Write-Host ("  {0,-38} {1,6}"       -f "Added in newer:",   $added.Count)
    Write-Host ""

    if ($removed.Count -gt 0) {
        Write-Host "  -- Removed --" -ForegroundColor Red
        $removed | Select-Object -First 100 | ForEach-Object { Write-Host "    $_" }
        if ($removed.Count -gt 100) { Write-Host "    ... and $($removed.Count-100) more" }
        Write-Host ""
    }
    if ($added.Count -gt 0) {
        Write-Host "  -- Added --" -ForegroundColor Green
        $added | Select-Object -First 100 | ForEach-Object { Write-Host "    $_" }
        if ($added.Count -gt 100) { Write-Host "    ... and $($added.Count-100) more" }
        Write-Host ""
    }
    if ($removed.Count -eq 0 -and $added.Count -eq 0) {
        Write-Ok "File lists are identical between the two backups."
    }
    Log "diff: $n1 vs $n2 removed=$($removed.Count) added=$($added.Count)"
    Write-Host ""
}

# =============================================================================
# COMMAND: live
# Compare archive against live filesystem
# =============================================================================
function Invoke-Live {
    param([string]$BackupArg)
    if (-not $BackupArg) { Show-HelpLive; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Archive vs Live System -- $name"
    Write-Info "Each file in the archive is checked against its current path."
    Write-Info "Only differences (changed, missing, permission changes) are shown."
    Write-Host ""

    $f = Ensure-Local $name
    Log "live compare: $name"

    # BSD tar --diff compares archive against filesystem.
    # -C $HOME_DIR because archive paths are relative to home.
    $output = tar --diff -zf $f -C $HOME_DIR 2>&1
    $filtered = $output | Where-Object { $_ -notmatch '^tar: (Error exit|socket)' }

    if (-not $filtered) {
        Write-Ok "Live system matches the backup -- no differences found."
    } else {
        $filtered | Select-Object -First 300 | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Warn "$($filtered.Count) line(s) of differences -- these files changed since $name was taken."
    }
    Write-Host ""
    Write-Info "To restore specific files: .\win_restore.ps1 restore path $BackupArg <relative-path>"
    Write-Info "To restore everything:     .\win_restore.ps1 restore full $BackupArg"
    Write-Host ""
    Log "live compare done: $name"
}

# =============================================================================
# COMMAND: browse
# =============================================================================
function Invoke-Browse {
    param([string]$BackupArg, [string]$Filter = '')
    if (-not $BackupArg) { Show-HelpBrowse; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    $hdr  = if ($Filter) { "Archive Contents -- $name  [filter: $Filter]" } else { "Archive Contents -- $name" }
    Write-Hdr $hdr

    $f = Ensure-Local $name
    $entries = tar -tzf $f 2>$null | Where-Object { $_ -notmatch '^tar:' }
    if ($Filter) { $entries = $entries | Where-Object { $_ -like "*$Filter*" } }
    $entries = $entries | Sort-Object

    $entries | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "  $($entries.Count) $(if ($Filter) {"matching"} else {"total"}) entries"
    Write-Host ""
    Write-Info "Tip: Use a filter string to narrow results:"
    Write-Info "  .\win_restore.ps1 browse $BackupArg Documents"
    Write-Info "  .\win_restore.ps1 browse $BackupArg .ssh"
    Write-Host ""
}

# =============================================================================
# COMMAND: get
# =============================================================================
function Invoke-Get {
    param([string]$BackupArg)
    if (-not $BackupArg) { Show-HelpGet; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Download Archive -- $name"

    $path = Join-Path $DOWNLOAD_DIR $name
    if (Test-Path $path) {
        $sz = "{0:N1} MB" -f ((Get-Item $path).Length/1MB)
        Write-Warn "Already downloaded: $path ($sz)"
        Write-Host "  Delete to force re-download:  Remove-Item '$path'"
        Write-Host ""
        return
    }
    Log "get: $name"
    & $PROTON filesystem download "$REMOTE_BASE/$name" "$DOWNLOAD_DIR/" 2>&1 |
        ForEach-Object { Log "  $_"; Write-Host "  $_" }
    if (-not (Test-Path $path)) { Fail "Download completed but file not found at $path" }
    $sz = "{0:N1} MB" -f ((Get-Item $path).Length/1MB)
    Write-Ok "Saved to: $path ($sz)"
    Write-Host ""
    Write-Info "Next: .\win_restore.ps1 check $BackupArg"
    Write-Host ""
}

# =============================================================================
# COMMAND: restore full
# =============================================================================
function Invoke-RestoreFull {
    param([string]$BackupArg)
    if (-not $BackupArg) { Show-HelpRestore; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Full Restore -- $name"
    Write-Host ""
    Write-Host "  WARNING: Destructive operation." -ForegroundColor Red
    Write-Host "  Every file in the archive will be written to its original path"
    Write-Host "  under $HOME_DIR, overwriting the current version."
    Write-Host ""
    Write-Host "  Backup: $name"
    Write-Host ""
    $confirm = Read-Host "  Type  YES  (uppercase) to confirm"
    if ($confirm -ne 'YES') { Write-Host "Aborted."; exit 0 }

    $f = Ensure-Local $name
    Log "restore full: $name"
    Write-Info "Extracting archive to $HOME_DIR ..."
    Write-Host ""

    # Archive paths are relative to home dir (created with -C $HOME_DIR)
    tar -xzf $f -C $HOME_DIR 2>&1 | Where-Object { $_ -notmatch '^tar: (socket|Error)' } |
        ForEach-Object { Write-Host "  $_"; Log "  tar: $_" }

    Write-Host ""
    Write-Ok "Archive extracted."
    Log "restore full complete: $name"

    Write-Host ""
    Write-Host "  Post-restore steps:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Reinstall applications:"
    Write-Host "       winget import -i ~\proton-backup\.backup-manifest\winget-export.json --accept-source-agreements"
    Write-Host ""
    Write-Host "  2. Reinstall Python packages (if applicable):"
    Write-Host "       pip install -r ~\proton-backup\.backup-manifest\pip-packages.txt"
    Write-Host ""
    Write-Host "  3. Re-authenticate Proton Drive:"
    Write-Host "       ~\proton-backup\proton-drive.exe auth login"
    Write-Host ""
    Write-Host "  4. Reinstall the backup scheduled task:"
    Write-Host "       ~\proton-backup\win_backup.ps1 -InstallTask"
    Write-Host ""
}

# =============================================================================
# COMMAND: restore path
# =============================================================================
function Invoke-RestorePath {
    param([string]$BackupArg, [string]$TargetPath)
    if (-not $BackupArg -or -not $TargetPath) { Show-HelpRestore; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Selective Restore -- $name  ->  $TargetPath"

    $f = Ensure-Local $name

    # Check path exists in archive.
    # Use $archivePaths (not $matches) -- $matches is a PS7 automatic variable
    # that gets silently overwritten by any subsequent -match/-notmatch operation.
    $archivePaths = tar -tzf $f 2>$null | Where-Object { $_ -like "*$TargetPath*" }
    if (-not $archivePaths) {
        Write-Host ""
        Write-Err "Path not found in archive: $TargetPath"
        Write-Host ""
        Write-Host "  Use 'browse' to check exact paths:"
        Write-Host "    .\win_restore.ps1 browse $BackupArg"
        exit 1
    }

    $pathCount = @($archivePaths).Count
    $livePath = Join-Path $HOME_DIR $TargetPath
    if (Test-Path $livePath) {
        Write-Warn "'$livePath' already exists -- $pathCount file(s) will be overwritten."
        $confirm = Read-Host "  Confirm? [y/N]"
        if ($confirm -notmatch '^[Yy]$') { Write-Host "Aborted."; exit 0 }
    } else {
        Write-Info "Target does not exist on live system -- restoring $pathCount file(s)."
    }

    Log "restore path: '$TargetPath' from $name ($pathCount files)"
    Write-Info "Extracting $pathCount file(s)..."

    # Pass paths directly as positional arguments.
    # BSD tar on Windows has a quirk where -T combined with -C causes
    # "Couldn't visit directory" errors for an empty path between archive entries.
    tar -xzf $f -C $HOME_DIR @($archivePaths) 2>&1 |
        Where-Object { $_ -notmatch '^tar: (socket|Error)' } |
        ForEach-Object { Write-Host "  $_"; Log "  tar: $_" }

    Write-Host ""
    Write-Ok "$pathCount file(s) restored to $HOME_DIR\$TargetPath"
    Log "restore path done: '$TargetPath' from $name"
    Write-Host ""
}

# =============================================================================
# COMMAND: restore staging
# =============================================================================
function Invoke-RestoreStaging {
    param([string]$BackupArg, [string]$Filter = '')
    if (-not $BackupArg) { Show-HelpRestore; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    $hdr  = if ($Filter) { "Staging Extract -- $name  [filter: $Filter]  ->  $STAGING_DIR" } else { "Staging Extract -- $name  ->  $STAGING_DIR" }
    Write-Hdr $hdr

    Write-Info "Safe extract: files go to $STAGING_DIR, not original paths."
    Write-Info "Nothing on the live system is modified."
    Write-Host ""

    if (Test-Path $STAGING_DIR) { Remove-Item $STAGING_DIR -Recurse -Force }
    New-Item -ItemType Directory -Path $STAGING_DIR -Force | Out-Null

    $f = Ensure-Local $name
    Log "restore staging: $name filter='$Filter' -> $STAGING_DIR"

    if ($Filter) {
        $archivePaths = tar -tzf $f 2>$null | Where-Object { $_ -like "*$Filter*" -and $_ -notmatch '^tar:' }
        if (-not $archivePaths) {
            Write-Err "Path not found in archive: $Filter"
            Write-Host "  Use 'browse' to check paths: .\win_restore.ps1 browse $BackupArg"
            exit 1
        }
        $pathCount = @($archivePaths).Count
        Write-Info "Extracting $pathCount file(s) matching '$Filter'..."
        # Pass paths directly as positional arguments (avoids -T + -C quirk in BSD tar on Windows)
        tar -xzf $f -C $STAGING_DIR @($archivePaths) 2>&1 |
            Where-Object { $_ -notmatch '^tar: (socket|Error)' } |
            ForEach-Object { Log "  tar: $_" }
    } else {
        Write-Info "Extracting full archive..."
        tar -xzf $f -C $STAGING_DIR 2>&1 |
            Where-Object { $_ -notmatch '^tar: (socket|Error)' } |
            ForEach-Object { Log "  tar: $_" }
    }

    Write-Host ""
    Write-Ok "Extracted to: $STAGING_DIR"
    Write-Host ""
    Write-Host "  Top-level directories:"
    Get-ChildItem $STAGING_DIR -Directory | ForEach-Object { Write-Host "    $($_.Name)" }
    Write-Host ""
    Write-Info "Next steps:"
    Write-Info "  Inspect:  Get-ChildItem '$STAGING_DIR'"
    Write-Info "  Compare:  Compare-Object (Get-Content 'live\file') (Get-Content '$STAGING_DIR\staged\file')"
    Write-Info "  Restore:  Copy-Item '$STAGING_DIR\...' 'C:\Users\...' -Recurse"
    Write-Info "  Or commit: .\win_restore.ps1 restore path $BackupArg $Filter"
    Write-Host ""
    Log "restore staging done: $name -> $STAGING_DIR"
}

# =============================================================================
# COMMAND: restore packages
# =============================================================================
function Invoke-RestorePackages {
    param([string]$BackupArg)
    if (-not $BackupArg) { Show-HelpRestore; exit 1 }
    if (-not (Test-Path $PROTON)) { Fail "proton-drive.exe not found at $PROTON" }

    $name = Resolve-BackupName $BackupArg
    Write-Hdr "Package Reinstall -- $name"

    $f = Ensure-Local $name

    # Extract winget-export.json to staging
    $tmpDir = Join-Path $env:TEMP "restore-pkgs-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        tar -xzf $f -C $tmpDir 'proton-backup/.backup-manifest/winget-export.json' 2>$null
        $wingetFile = Join-Path $tmpDir 'proton-backup\.backup-manifest\winget-export.json'
        if (Test-Path $wingetFile) {
            Write-Info "winget export found -- contents:"
            Get-Content $wingetFile | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
            Write-Host ""
            $confirm = Read-Host "  Reinstall all packages? [y/N]"
            if ($confirm -match '^[Yy]$') {
                winget import -i $wingetFile --accept-source-agreements --accept-package-agreements
            }
        } else {
            Write-Warn "winget-export.json not found in archive"
        }

        # Also handle pip-packages.txt
        tar -xzf $f -C $tmpDir 'proton-backup/.backup-manifest/pip-packages.txt' 2>$null
        $pipFile = Join-Path $tmpDir 'proton-backup\.backup-manifest\pip-packages.txt'
        if (Test-Path $pipFile) {
            $pkgCount = (Get-Content $pipFile | Measure-Object -Line).Lines
            Write-Host ""
            Write-Info "pip-packages.txt found ($pkgCount packages)"
            $confirm2 = Read-Host "  Reinstall pip packages? [y/N]"
            if ($confirm2 -match '^[Yy]$') {
                pip install -r $pipFile
            }
        }
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Log "restore packages done: $name"
}

# =============================================================================
# HELP SYSTEM
# =============================================================================
function Show-HelpOverview {
    Write-Host @"

win_restore.ps1 -- Restore utility for Win11 PZ13 Proton Drive backups

USAGE
  .\win_restore.ps1 <command> [arguments]
  .\win_restore.ps1 help <command>

BACKUP NAME SHORTCUTS
  Wherever <backup> appears, use any of these:
    latest                          Most recently stored backup
    2026-06-29                      Backup by date (YYYY-MM-DD)
    win11-pz13-2026-06-29.tar.gz    Full filename

COMMANDS
----------------------------------------------------------------
  list
    List all backups on Proton Drive with sizes and dates.

  check  <backup>
    Verify the archive can be read end-to-end. Run before any restore.

  diff  <backup1>  <backup2>
    Compare file lists between two backups.

  live  <backup>
    Compare archive against the live filesystem (what changed?).

  browse  <backup>  [filter-string]
    List all files in archive, optionally filtered.

  get  <backup>
    Download archive to %TEMP% without extracting (for caching).

  restore full  <backup>
    Extract all files to original paths under $HOME_DIR (YES prompt).

  restore path  <backup>  <relative-path>
    Restore a specific file or subdirectory to its original location.

  restore staging  <backup>  [filter]
    Safe extract to %TEMP%\restore-staging\ -- nothing overwritten.

  restore packages  <backup>
    Reinstall winget packages and pip packages from backup.

  help  [command]
    This overview, or detailed help for a specific command.
----------------------------------------------------------------

RECOMMENDED WORKFLOW

  Step 1 -- Assess
    .\win_restore.ps1 list
    .\win_restore.ps1 check   latest
    .\win_restore.ps1 live    latest

  Step 2 -- Preview (optional but recommended)
    .\win_restore.ps1 browse  latest
    .\win_restore.ps1 restore staging latest

  Step 3 -- Restore
    .\win_restore.ps1 restore full     latest
    .\win_restore.ps1 restore packages latest

ARCHIVE CACHING
  Archives are downloaded to %TEMP%\win11-pz13-YYYY-MM-DD.tar.gz
  on first use and reused by subsequent commands.
  Use 'get' to pre-download before running multiple commands.

LOG FILE
  All operations are appended to: $RESTORE_LOG
"@
}

function Show-HelpCheck  { Write-Host "`ncheck <backup>`n  Verify archive integrity. Downloads if not cached.`n  Exit 0 = intact, Exit 1 = corrupt.`n" }
function Show-HelpDiff   { Write-Host "`ndiff <backup1> <backup2>`n  Compare file lists between two archives.`n" }
function Show-HelpLive   { Write-Host "`nlive <backup>`n  Compare archive against live filesystem (tar --diff).`n  Shows what changed since the backup was taken.`n" }
function Show-HelpBrowse { Write-Host "`nbrowse <backup> [filter]`n  List archive contents, optionally filtered by string match.`n" }
function Show-HelpGet    { Write-Host "`nget <backup>`n  Download archive to %TEMP% without extracting.`n" }
function Show-HelpRestore {
    Write-Host @"

restore sub-commands:

  restore full    <backup>              Full restore to $HOME_DIR (YES prompt)
  restore path    <backup> <rel-path>   Restore one file or folder
  restore staging <backup> [filter]     Safe extract to %TEMP%\restore-staging\
  restore packages <backup>             Reinstall winget + pip packages
"@
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================
"" | Add-Content -Path $RESTORE_LOG -Encoding utf8 2>$null
Log "=== win_restore.ps1 $Command $Arg1 $Arg2 $Arg3 ==="

switch ($Command.ToLower()) {
    'list'    { Invoke-List }
    'check'   { Invoke-Check   $Arg1 }
    'diff'    { Invoke-Diff    $Arg1 $Arg2 }
    'live'    { Invoke-Live    $Arg1 }
    'browse'  { Invoke-Browse  $Arg1 $Arg2 }
    'get'     { Invoke-Get     $Arg1 }
    'restore' {
        switch ($Arg1.ToLower()) {
            'full'     { Invoke-RestoreFull     $Arg2 }
            'path'     { Invoke-RestorePath     $Arg2 $Arg3 }
            'staging'  { Invoke-RestoreStaging  $Arg2 $Arg3 }
            'packages' { Invoke-RestorePackages $Arg2 }
            default {
                Write-Err "restore requires a sub-command: full | path | staging | packages"
                Write-Host ""
                Show-HelpRestore
                exit 1
            }
        }
    }
    { $_ -in 'help','-h','--help','' } {
        switch ($Arg1.ToLower()) {
            'check'   { Show-HelpCheck }
            'diff'    { Show-HelpDiff }
            'live'    { Show-HelpLive }
            'browse'  { Show-HelpBrowse }
            'get'     { Show-HelpGet }
            'restore' { Show-HelpRestore }
            default   { Show-HelpOverview }
        }
    }
    default {
        Write-Err "Unknown command: '$Command'"
        Write-Host ""
        Show-HelpOverview
        exit 1
    }
}
