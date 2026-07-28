# =============================================================================
# win_backup.ps1
# Weekly full backup of Windows 11 (PZ13) user data to Proton Drive.
#
# SCHEDULE -- installed automatically with -InstallTask switch:
#   Sunday at 23:00, runs only when user is logged on
#   (critical: "run when user is logged on" allows Credential Manager access)
#
# WHAT IT DOES
#   1. Runs win_audit.ps1 to update the include/exclude manifest
#   2. Creates a tar.gz archive of everything in include.txt
#      minus everything in exclude.txt
#   3. Uploads to Proton Drive: /my-files/PZ13/
#   4. Keeps the 5 most recent backups; deletes older ones from Proton Drive
#   5. Logs everything to ~\proton-windows-backup\win_backup.log
#
# RESTORE
#   Use win_restore.ps1  (run .\win_restore.ps1 help  for full reference)
#
# USAGE
#   .\win_backup.ps1                # run backup now
#   .\win_backup.ps1 -InstallTask   # install scheduled task (requires admin once)
#   .\win_backup.ps1 -RemoveTask    # remove scheduled task
# =============================================================================

#Requires -Version 5.1

param(
    [switch]$InstallTask,
    [switch]$RemoveTask
)

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
$BACKUP_DATE   = Get-Date -Format 'yyyy-MM-dd'
$BACKUP_LABEL  = "win11-pz13-$BACKUP_DATE.tar.gz"
$BACKUP_TMP    = Join-Path $env:TEMP $BACKUP_LABEL
$REMOTE_BASE   = '/my-files/PZ13'
$MANIFEST_DIR  = Join-Path $PSScriptRoot '.backup-manifest'
$PROTON        = Join-Path $PSScriptRoot 'proton-drive.exe'
$AUDIT         = Join-Path $PSScriptRoot 'win_audit.ps1'
$KEEP_COUNT    = 5
$env:WIN_BACKUP_LOGFILE = Join-Path $PSScriptRoot 'win_backup.log'
$LOGFILE       = $env:WIN_BACKUP_LOGFILE

# -----------------------------------------------------------------------------
# TASK SCHEDULER MANAGEMENT
# -----------------------------------------------------------------------------
$TASK_NAME = 'Proton Drive - Win11 PZ13 Backup'

if ($RemoveTask) {
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task '$TASK_NAME' removed."
    exit 0
}

if ($InstallTask) {
    # Requires Administrator to register a scheduled task.
    # CRITICAL: LogonType = Interactive means the task only runs when the user
    # is logged on -- this is required for Windows Credential Manager access.

    # Resolve full path to pwsh.exe -- Task Scheduler runs with a minimal PATH
    # that often does not include the PS7 install directory, so 'pwsh.exe' alone
    # produces ERROR_FILE_NOT_FOUND (0x80070002) at runtime.
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        # Fallback to default PS7 install location
        $pwshExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }
    if (-not (Test-Path $pwshExe)) {
        Write-Host "  [ERR] pwsh.exe not found at: $pwshExe" -ForegroundColor Red
        Write-Host "  Install PowerShell 7 first:  winget install Microsoft.PowerShell"
        exit 1
    }

    $action  = New-ScheduledTaskAction -Execute $pwshExe `
                   -Argument "-NonInteractive -WindowStyle Hidden -File `"$PSCommandPath`""

    # Trigger: Sunday 23:00, with a WakeToRun-friendly random delay window disabled.
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '23:00'

    # POWER MANAGEMENT -- CRITICAL FOR LAPTOPS
    # Root cause of missed runs on a laptop that is always on AC power but
    # sleeps (screen off / idle): at 23:00 the CPU is asleep, so an
    # Interactive task with WakeToRun=False cannot fire. It misses the slot,
    # then a catch-up run starts when the machine briefly wakes -- and is
    # terminated when it sleeps again (LastTaskResult 0x40010004 =
    # DBG_TERMINATE_PROCESS).
    #
    #   -WakeToRun                  : wake the machine at 23:00 to run the task
    #   -DontStopIfGoingOnBatteries : a run that STARTED on AC finishes even if
    #                                 the charger is briefly pulled mid-backup
    #   DisallowStartIfOnBatteries  : left True -- do NOT start a fresh run on
    #                                 battery (Task Scheduler has no percentage
    #                                 threshold; this is the closest to "only
    #                                 on power"). Harmless here since the
    #                                 machine is always on AC.
    #
    # NOTE: WakeToRun requires the AC power plan to allow wake timers AND to
    # not hard-sleep the CPU. See RUNBOOK phase 5 for the powercfg commands.
    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                    -StartWhenAvailable `
                    -RunOnlyIfNetworkAvailable `
                    -DontStopIfGoingOnBatteries `
                    -WakeToRun
    $principal = New-ScheduledTaskPrincipal `
                    -UserId "$env:USERDOMAIN\$env:USERNAME" `
                    -LogonType Interactive `
                    -RunLevel Highest

    try {
        Register-ScheduledTask `
            -TaskName  $TASK_NAME `
            -Action    $action `
            -Trigger   $trigger `
            -Settings  $settings `
            -Principal $principal `
            -Description 'Weekly backup of user data to Proton Drive. Runs only when user is logged on (required for Credential Manager access).' `
            -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ""
        Write-Host "  [ERR] Failed to register scheduled task: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Requires Administrator. Right-click your terminal and choose"
        Write-Host "  'Run as Administrator', then run:"
        Write-Host "    cd ~\proton-windows-backup"
        Write-Host "    .\win_backup.ps1 -InstallTask"
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "Scheduled task installed: '$TASK_NAME'"
    Write-Host "  Schedule : Every Sunday at 23:00"
    Write-Host "  Logon    : Interactive (logged-on user only) -- required for Proton auth"
    Write-Host "  Script   : $PSCommandPath"
    Write-Host ""
    Write-Host "Verify with: Get-ScheduledTask -TaskName '$TASK_NAME' | Select *"
    exit 0
}

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
function Log  { param([string]$m) $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; "$ts $m" | Tee-Object -FilePath $LOGFILE -Append | Out-Host }
function Ok   { param([string]$m) "  [OK]   $m" | Tee-Object -FilePath $LOGFILE -Append | Out-Host }
function Warn { param([string]$m) "  [WARN] $m" | Tee-Object -FilePath $LOGFILE -Append | Out-Host }
function Fail { param([string]$m) "  [ERR]  $m" | Tee-Object -FilePath $LOGFILE -Append | Out-Host; exit 1 }

# -----------------------------------------------------------------------------
# LOG ROTATION -- keep 500 lines max
# -----------------------------------------------------------------------------
if (Test-Path $LOGFILE) {
    $lines = Get-Content $LOGFILE
    if ($lines.Count -gt 500) {
        $lines | Select-Object -Last 400 | Set-Content $LOGFILE -Encoding utf8
    }
}

Log "========================================================"
Log "Win11 PZ13 Backup - $BACKUP_DATE"
Log "========================================================"

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
if (-not (Test-Path $PROTON))  { Fail "proton-drive.exe not found at $PROTON" }
if (-not (Test-Path $AUDIT))   { Fail "win_audit.ps1 not found at $AUDIT" }

# Verify tar.exe is available (built into Windows 10/11)
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Fail "tar.exe not found. Required: Windows 10 build 17063 or later."
}

# Quick connectivity check -- also validates Credential Manager access
Log "Pre-flight: verifying Proton Drive connection..."
try {
    $null = & $PROTON filesystem list $REMOTE_BASE --json 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Folder might not exist yet -- try to create it
        Log "Remote folder not found -- attempting to create $REMOTE_BASE ..."
        & $PROTON filesystem create-folder /my-files PZ13 2>&1 | ForEach-Object { Log $_ }
    }
} catch {
    Fail "Cannot reach Proton Drive. Check authentication: .\proton-drive.exe auth login"
}
Ok "Proton Drive connection verified"

# -----------------------------------------------------------------------------
# STEP 1 -- RUN AUDIT (update include/exclude manifest)
# -----------------------------------------------------------------------------
Log "--- Step 1: Audit ---"
try {
    & $AUDIT -ManifestDir $MANIFEST_DIR -LogFile $LOGFILE
    if ($LASTEXITCODE -ne 0) { Fail "Audit script failed (exit $LASTEXITCODE)" }
} catch {
    Fail "Audit script threw exception: $_"
}

$includeFile = Join-Path $MANIFEST_DIR 'include.txt'
$excludeFile = Join-Path $MANIFEST_DIR 'exclude.txt'
if (-not (Test-Path $includeFile)) { Fail "include.txt missing after audit" }
$includeCount = (Get-Content $includeFile | Measure-Object -Line).Lines
if ($includeCount -eq 0)           { Fail "include.txt is empty after audit" }
Ok "Audit complete - $includeCount include paths"

# -----------------------------------------------------------------------------
# STEP 2 -- CREATE ARCHIVE
# -----------------------------------------------------------------------------
Log "--- Step 2: Create archive ---"
Log "Output: $BACKUP_TMP"

if (Test-Path $BACKUP_TMP) { Remove-Item $BACKUP_TMP -Force }

# BSD tar on Windows:
#   -czf                  create gzip-compressed archive
#   -C $homeDir           paths in archive are RELATIVE to home dir
#   --exclude-from        exclusion patterns (relative to -C directory)
#   paths passed directly as arguments (NOT via -T) -- avoids BSD tar quirk
#   where -T causes "Couldn't visit directory" for empty path between entries.
#
# Archive paths will look like: Documents/file.txt  (relative to home)
# Restore is:  tar -xzf archive.tar.gz -C $env:USERPROFILE

$homeDir = $env:USERPROFILE

# Read include paths from file; pass directly as positional arguments to tar
$includePaths = Get-Content $includeFile | Where-Object { $_.Trim() -ne '' }

$tarArgs = @(
    '-czf', $BACKUP_TMP,
    '-C', $homeDir,
    '--exclude-from', $excludeFile
) + @($includePaths)

Log "Running tar..."
$tarOutput = & tar @tarArgs 2>&1
$tarOutput | ForEach-Object { Log "  tar: $_" }

# tar exits non-zero for warnings -- log but don't abort unless archive wasn't created
if (-not (Test-Path $BACKUP_TMP)) {
    Fail "Archive was not created -- check log for tar errors"
}

$archiveSize = (Get-Item $BACKUP_TMP).Length
$archiveSizeHR = if ($archiveSize -ge 1GB) { "{0:N1} GB" -f ($archiveSize/1GB) }
                 elseif ($archiveSize -ge 1MB) { "{0:N1} MB" -f ($archiveSize/1MB) }
                 else { "{0:N0} KB" -f ($archiveSize/1KB) }

Log "Archive created: $BACKUP_LABEL ($archiveSizeHR)"
Ok "Archive: $archiveSizeHR"

# -----------------------------------------------------------------------------
# STEP 3 -- UPLOAD TO PROTON DRIVE
# -----------------------------------------------------------------------------
Log "--- Step 3: Upload ---"
Log "Uploading to $REMOTE_BASE ..."

# -f replace: automatically overwrites if a same-name file exists at destination.
# Prevents the interactive conflict prompt that blocks scheduled-task runs.
$uploadOutput = & $PROTON filesystem upload -f replace $BACKUP_TMP $REMOTE_BASE 2>&1
$uploadOutput | ForEach-Object { Log "  upload: $_" }

if ($LASTEXITCODE -ne 0) {
    Fail "Upload failed (exit $LASTEXITCODE) -- archive kept at $BACKUP_TMP for manual retry"
}
Ok "Upload complete: $REMOTE_BASE/$BACKUP_LABEL"

# -----------------------------------------------------------------------------
# STEP 4 -- RETENTION (keep KEEP_COUNT, delete older)
# -----------------------------------------------------------------------------
Log "--- Step 4: Retention (keep $KEEP_COUNT) ---"

# Use --json for clean parsing
$remoteJson = & $PROTON filesystem list $REMOTE_BASE --json 2>$null
$remoteItems = $remoteJson | ConvertFrom-Json -ErrorAction SilentlyContinue

if (-not $remoteItems) {
    Warn "Could not parse remote listing -- skipping retention check"
} else {
    # name is a nested object: {ok: true, value: "filename.tar.gz"}
    $backups = $remoteItems |
        Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } |
        Sort-Object { $_.name.value }   # ISO date names sort chronologically oldest-first

    $total = @($backups).Count
    Log "Remote backups found: $total"

    if ($total -gt $KEEP_COUNT) {
        $deleteCount = $total - $KEEP_COUNT
        Log "Removing $deleteCount old backup(s)..."
        $backups | Select-Object -First $deleteCount | ForEach-Object {
            $fname       = $_.name.value
            $remotePath  = "$REMOTE_BASE/$fname"
            Log "  Deleting: $remotePath"
            $delOut = & $PROTON filesystem delete $remotePath 2>&1
            $delOut | ForEach-Object { Log "    $_" }
            if ($LASTEXITCODE -eq 0) {
                Ok "Deleted: $fname"
            } else {
                Warn "Could not delete $remotePath -- may need manual cleanup"
            }
        }
    } else {
        Ok "Retention OK - $total of $KEEP_COUNT slots used"
    }
}

# -----------------------------------------------------------------------------
# STEP 5 -- CLEANUP AND REPORT
# -----------------------------------------------------------------------------
Log "--- Step 5: Cleanup ---"
if (Test-Path $BACKUP_TMP) {
    Remove-Item $BACKUP_TMP -Force
    Ok "Local temp file removed"
}

Log "Current remote backups:"
$finalJson = & $PROTON filesystem list $REMOTE_BASE --json 2>$null
try {
    ($finalJson | ConvertFrom-Json) |
        Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } |
        Sort-Object { $_.name.value } |
        ForEach-Object { Log "  $($_.name.value)  ($([math]::Round($_.totalStorageSize/1MB,1)) MB)" }
} catch { }

Log "========================================================"
Log "Backup COMPLETE - $BACKUP_LABEL ($archiveSizeHR)"
Log "========================================================"

Write-Host ""
Write-Host "  Backup complete: $BACKUP_LABEL ($archiveSizeHR)"
Write-Host "  Log: $LOGFILE"
Write-Host ""
