# =============================================================================
# win_backup.ps1
# Weekly full backup of Windows 11 (PZ13) user data to Proton Drive.
#
# LOCATION
#   Runs from the git repo that holds it (the scheduled task points here).
#   win_backup.log, .last_success and .backup-manifest\ are written next to
#   this script and are gitignored, except the two *-custom.txt files.
#   The Proton Drive CLI is winget-managed (user scope) -- see $PROTON below.
#   Archives are made with GNU tar from Git for Windows -- see $TAR below.
#
# SCHEDULE -- installed with -InstallTask (Administrator):
#   A backup is due once a week, from Sunday 23:00. The task starts
#   win_backup.ps1 -Scheduled every hour, at logon and at unlock; the script
#   exits at once unless a backup is due and power allows (AC, or battery at
#   or above $MIN_BATTERY_PCT). A missed week is caught up the next time the
#   machine is awake. LogonType Interactive (Credential Manager access).
#   While running, the script holds a Windows power request so the machine
#   does not go to sleep. Windows cannot run the backup while PZ13 is in
#   Modern Standby (desktop apps are paused), and a power request does not
#   survive lid close / power button / Start > Sleep. See BACKUP-LOGIC.md.
#
# WHAT IT DOES
#   0. winget upgrade of the Proton Drive CLI (non-fatal)
#   1. Runs win_audit.ps1 to regenerate the include/exclude manifest
#   2. Creates a tar.gz of everything in include.txt minus exclude.txt, then
#      re-reads the whole archive. A tar failure or an unreadable archive stops
#      the run here: nothing is uploaded and retention does not run.
#   3. Uploads to Proton Drive: /my-files/PZ13/
#   4. Keeps the 5 most recent archives; trashes older ones, then empties trash
#   5. Logs to win_backup.log in this directory
#   6. Writes .last_success (UTC) and optionally pings HEARTBEAT_URL
#
# RESTORE
#   .\win_restore.ps1 help
#
# USAGE (PowerShell 7)
#   .\win_backup.ps1                # run backup now
#   .\win_backup.ps1 -InstallTask   # install scheduled task (Administrator)
#   .\win_backup.ps1 -RemoveTask    # remove scheduled task
#   .\win_backup.ps1 -ArchiveOnly   # test: audit + archive + verify only. No
#                                   # Proton Drive access, no upload, no
#                                   # retention, no .last_success. The archive
#                                   # is left in %TEMP% for inspection.
#   .\win_backup.ps1 -Scheduled     # what the task runs: back up only if due
#                                   # and power allows
#   .\win_backup.ps1 -DecisionOnly  # test: print what -Scheduled would decide,
#                                   # change nothing. -SimulatePower AC|<pct>
#                                   # and -SimulateLastSuccess <UTC ISO time>
#                                   # replace the real values.
# =============================================================================

#Requires -Version 7.0

param(
    [switch]$InstallTask,
    [switch]$RemoveTask,
    [switch]$ArchiveOnly,
    [switch]$Scheduled,
    [switch]$DecisionOnly,
    [string]$SimulatePower = '',
    [string]$SimulateLastSuccess = ''
)

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
$BACKUP_DATE   = Get-Date -Format 'yyyy-MM-dd'
$BACKUP_LABEL  = "win11-pz13-$BACKUP_DATE.tar.gz"
$BACKUP_TMP    = Join-Path $env:TEMP $BACKUP_LABEL
$REMOTE_BASE   = '/my-files/PZ13'
$MANIFEST_DIR  = Join-Path $PSScriptRoot '.backup-manifest'
# Proton Drive CLI -- installed and upgraded by winget (user scope). The
# absolute package path is used so the scheduled task depends on neither PATH
# nor winget's Links shim. winget upgrades a portable package in place, so
# this path does not change between versions.
$WINGET_ID     = 'Proton.ProtonDrive.CLI'
$PROTON        = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe'
$AUDIT         = Join-Path $PSScriptRoot 'win_audit.ps1'
# GNU tar (Git for Windows). Windows' own tar.exe (bsdtar 3.8.8) crashes with
# an access violation on filenames outside the ANSI code page (e.g. Chinese),
# leaving a truncated archive, and follows junctions. GNU tar handles Unicode
# names and stores junctions as links. Tested 2026-09-28 (tests\suites\archiver-*).
$GIT_USR_BIN   = 'C:\Program Files\Git\usr\bin'
$TAR           = Join-Path $GIT_USR_BIN 'tar.exe'
$GZIP          = Join-Path $GIT_USR_BIN 'gzip.exe'
$KEEP_COUNT    = 5
# Scheduled runs: a backup is due from Sunday 23:00 each week; on battery it
# starts only at or above this charge (AC always allowed).
$MIN_BATTERY_PCT = 50
$LAST_SUCCESS  = Join-Path $PSScriptRoot '.last_success'
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
                   -Argument "-NonInteractive -WindowStyle Hidden -File `"$PSCommandPath`" -Scheduled"

    # TRIGGERS -- frequent chances to run; the script decides whether a backup
    # is due (weekly, from Sunday 23:00) and whether power allows it.
    #   hourly : any hour the machine is awake
    #   logon, unlock : the moment the user is back after sleep or a reboot
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
                  -RepetitionInterval (New-TimeSpan -Hours 1) `
                  -RepetitionDuration (New-TimeSpan -Days 3650)
    $logon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $unlockClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
    $unlock = New-CimInstance -CimClass $unlockClass -ClientOnly
    $unlock.StateChange = 8          # TASK_SESSION_UNLOCK
    $unlock.UserId      = "$env:USERDOMAIN\$env:USERNAME"
    $unlock.Enabled     = $true
    $trigger = @($hourly, $logon, $unlock)

    # POWER SETTINGS (PZ13 is a Modern Standby / S0 laptop)
    #   AllowStartIfOnBatteries     : the script applies the battery threshold
    #   DontStopIfGoingOnBatteries  : a run that has started finishes
    #   StartWhenAvailable          : a trigger missed while asleep runs on wake
    #   no WakeToRun                : a Modern Standby wake does not let a
    #                                 desktop app run; it only started runs
    #                                 that were then paused (2026-09-20, -28)
    #   ExecutionTimeLimit 12 h     : a run takes minutes; a run paused by
    #                                 standby resumes on wake and must not be
    #                                 killed after 2 h (orphaned tar, 2026-08)
    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
                    -StartWhenAvailable `
                    -RunOnlyIfNetworkAvailable `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -MultipleInstances IgnoreNew
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
            -Description 'Weekly backup of user data to Proton Drive. Checks hourly, at logon and at unlock; backs up only when due (from Sunday 23:00) and on AC or battery >= 50%. Runs only when the user is logged on (Credential Manager access).' `
            -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ""
        Write-Host "  [ERR] Failed to register scheduled task: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Requires Administrator. Right-click your terminal and choose"
        Write-Host "  'Run as Administrator', then run:"
        Write-Host "    cd `"$PSScriptRoot`""
        Write-Host "    .\win_backup.ps1 -InstallTask"
        Write-Host ""
        exit 1
    }

    Write-Host ""
    Write-Host "Scheduled task installed: '$TASK_NAME'"
    Write-Host "  Checks   : hourly, at logon, at unlock (backs up when due: weekly from Sunday 23:00)"
    Write-Host "  Power    : AC, or battery >= $MIN_BATTERY_PCT%"
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
# POWER STATE, POWER REQUEST (kernel32)
# -----------------------------------------------------------------------------
# PowerCreateRequest/PowerSetRequest: while a SystemRequired request is held
# the machine does not idle into sleep -- on AC with no time limit, on battery
# for at most 5 minutes after the sleep timeout (Microsoft Learn,
# PowerSetRequest remarks). Requests end on lid close, power button or
# Start > Sleep. ExecutionRequired additionally asks Windows not to suspend
# the process. Both end when this process exits.
if (-not ('PwbPower.Native' -as [type])) {
    Add-Type -Namespace PwbPower -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct REASON_CONTEXT { public uint Version; public uint Flags; [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString; }
[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS { public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent; public byte SystemStatusFlag; public int BatteryLifeTime; public int BatteryFullLifeTime; }
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr PowerCreateRequest(ref REASON_CONTEXT context);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool PowerSetRequest(IntPtr handle, int requestType);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
'@
}

function Get-PowerState {
    # Returns @{ OnAC = bool; Percent = int (-1 unknown); Text = string }
    if ($DecisionOnly -and $SimulatePower) {
        if ($SimulatePower -eq 'AC') { return @{ OnAC = $true; Percent = -1; Text = 'AC (simulated)' } }
        $p = [int]$SimulatePower
        return @{ OnAC = $false; Percent = $p; Text = "battery $p% (simulated)" }
    }
    $s = New-Object PwbPower.Native+SYSTEM_POWER_STATUS
    if (-not [PwbPower.Native]::GetSystemPowerStatus([ref]$s)) { return @{ OnAC = $true; Percent = -1; Text = 'unknown (treated as AC)' } }
    $pct = if ($s.BatteryLifePercent -eq 255) { -1 } else { [int]$s.BatteryLifePercent }
    if ($s.ACLineStatus -eq 0) { return @{ OnAC = $false; Percent = $pct; Text = "battery $pct%" } }
    return @{ OnAC = $true; Percent = $pct; Text = $(if ($pct -ge 0) { "AC, battery $pct%" } else { 'AC' }) }
}

function Get-DueSince {
    # Most recent Sunday 23:00 (local) that is not in the future.
    $now = Get-Date
    $d = $now.Date.AddDays(-[int]$now.DayOfWeek).AddHours(23)
    if ($d -gt $now) { $d = $d.AddDays(-7) }
    return $d
}

function Get-LastSuccess {
    $raw = if ($DecisionOnly -and $SimulateLastSuccess) { $SimulateLastSuccess }
           elseif (Test-Path $LAST_SUCCESS) { (Get-Content $LAST_SUCCESS -Raw).Trim() }
           else { '' }
    if (-not $raw) { return $null }
    try {
        return [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
    } catch { return $null }
}

# -----------------------------------------------------------------------------
# SCHEDULED RUN: IS A BACKUP DUE, AND DOES POWER ALLOW IT?
# -----------------------------------------------------------------------------
if ($Scheduled -or $DecisionOnly) {
    $dueSince = Get-DueSince
    $lastOk   = Get-LastSuccess
    $power    = Get-PowerState
    $lastText = if ($lastOk) { $lastOk.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
    $state    = "last success $lastText, due since $($dueSince.ToString('yyyy-MM-dd HH:mm')), power $($power.Text)"

    $decision = if ($lastOk -and $lastOk -ge $dueSince) { "SKIP not due: $state" }
                elseif (-not $power.OnAC -and $power.Percent -ge 0 -and $power.Percent -lt $MIN_BATTERY_PCT) {
                    "SKIP battery below $MIN_BATTERY_PCT%: $state" }
                else { "RUN: $state" }

    if ($DecisionOnly) { Write-Host "Decision: $decision"; exit 0 }
    if ($decision -like 'SKIP not due*') { exit 0 }     # the normal hourly case: no log line
    if ($decision -like 'SKIP*') {
        Log "Scheduled check: $decision"
        exit 0
    }
}

# -----------------------------------------------------------------------------
# ONE RUN AT A TIME
# -----------------------------------------------------------------------------
# A manual run and the task must not build the same archive at once. The mutex
# is released when this process exits, including when it is killed.
$runMutex = [System.Threading.Mutex]::new($false, 'Local\ProtonDrive-PZ13-Backup')
$haveMutex = $false
try { $haveMutex = $runMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) {
    if (-not $Scheduled) { Write-Host 'Another backup run is in progress -- exiting.' }
    exit 0
}

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
if ($Scheduled) { Log "Scheduled run: $decision" } else { Log "Manual run, power $((Get-PowerState).Text)" }

# Keep the machine awake until this process exits (see POWER REQUEST above).
$reason = New-Object PwbPower.Native+REASON_CONTEXT
$reason.Version = 0                  # POWER_REQUEST_CONTEXT_VERSION
$reason.Flags   = 1                  # POWER_REQUEST_CONTEXT_SIMPLE_STRING
$reason.SimpleReasonString = 'Proton Drive backup (win_backup.ps1)'
$powerRequest = [PwbPower.Native]::PowerCreateRequest([ref]$reason)
if ($powerRequest -eq [IntPtr]::Zero -or $powerRequest -eq [IntPtr]::new(-1)) {
    Warn "Could not create a power request -- the machine may sleep during the run"
} else {
    $sys  = [PwbPower.Native]::PowerSetRequest($powerRequest, 1)   # PowerRequestSystemRequired
    $exec = [PwbPower.Native]::PowerSetRequest($powerRequest, 3)   # PowerRequestExecutionRequired
    if ($sys) { Ok "Keep-awake power request set (system required: $sys, execution required: $exec)" }
    else      { Warn "Power request not accepted -- the machine may sleep during the run" }
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
if (-not (Test-Path $PROTON))  { Fail "Proton Drive CLI not found at $PROTON -- install: winget install --id $WINGET_ID --exact --scope user" }
if (-not (Test-Path $AUDIT))   { Fail "win_audit.ps1 not found at $AUDIT" }
if (-not (Test-Path $TAR) -or -not (Test-Path $GZIP)) {
    Fail "GNU tar/gzip not found in $GIT_USR_BIN -- install Git for Windows: winget install --id Git.Git --exact"
}

# For this process only: GNU tar starts gzip via PATH; UTF-8 names and output.
$env:Path   = "$GIT_USR_BIN;$env:Path"
$env:LANG   = 'C.UTF-8'
$env:LC_ALL = 'C.UTF-8'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if ($ArchiveOnly) {
    Log "ArchiveOnly test run: no Proton Drive access, no upload, no retention"
} else {
# Steps 0 and the connection check need Proton Drive; -ArchiveOnly skips them.

# -----------------------------------------------------------------------------
# STEP 0 -- UPDATE THE PROTON DRIVE CLI (winget)
# -----------------------------------------------------------------------------
# The CLI is winget-managed; winget upgrades it in place. Non-fatal: if winget
# is missing, fails, or has no newer version, the installed binary is used.
# A broken new release is stopped by the pre-flight check below, before any
# archive is built. There is no automatic rollback. To go back to an older
# release (only while Proton still publishes it in the winget catalog):
#   winget show --id Proton.ProtonDrive.CLI --versions
#   winget install --id Proton.ProtonDrive.CLI --exact --scope user --version <old> --force
Log "--- Step 0: Proton Drive CLI update (winget) ---"

function Get-CliVersion {
    foreach ($line in (& $PROTON --version 2>$null)) {
        if ($line -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    }
    return $null
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Warn "winget not available -- skipping CLI update"
} else {
    $beforeVer  = Get-CliVersion
    $upgradeOut = winget upgrade --id $WINGET_ID --exact --scope user --silent --disable-interactivity `
                      --accept-source-agreements --accept-package-agreements 2>&1
    # Log winget's text lines; drop progress-bar and spinner lines.
    $upgradeOut | Where-Object { "$_" -match '[A-Za-z]' -and "$_" -notmatch '[KMG]B\s*/\s*\d' } |
        ForEach-Object { Log "  winget: $_" }
    $afterVer = Get-CliVersion

    if (-not $afterVer) {
        Warn "Could not read the CLI version after winget upgrade -- pre-flight check decides"
    } elseif ($afterVer -eq $beforeVer) {
        Ok "Proton Drive CLI is current ($afterVer)"
    } else {
        Ok "Proton Drive CLI upgraded: $beforeVer -> $afterVer"

        # Tell the RPi's xware-update tracking table, so its weekly report stops
        # flagging PZ13 as outstanding. Soft-fails -- an unreachable RPi must not
        # block this backup.
        $sshKey = Join-Path $env:USERPROFILE '.ssh\workstation-to-rpi'
        if (Test-Path $sshKey) {
            & ssh -o BatchMode=yes -o ConnectTimeout=5 -i $sshKey vh@192.168.1.6 `
                "~/xware-update-checks/xware-ack proton-drive-cli/windows-arm64 $afterVer" 2>&1 |
                ForEach-Object { Log "  xware-ack: $_" }
            if ($LASTEXITCODE -eq 0) {
                Ok "RPi tracking updated: proton-drive-cli/windows-arm64 = $afterVer"
            } else {
                Warn "Could not reach the RPi -- run there by hand: ~/xware-update-checks/xware-ack proton-drive-cli/windows-arm64 $afterVer"
            }
        } else {
            Warn "SSH key not found at $sshKey -- run on the RPi by hand: ~/xware-update-checks/xware-ack proton-drive-cli/windows-arm64 $afterVer"
        }
    }
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT -- CONNECTION AND AUTH
# -----------------------------------------------------------------------------
# Any failure other than a missing remote folder must stop the run here, not
# after building a multi-GB archive that cannot be uploaded. The CLI's error
# wording varies ("You need to login first", "Invalid access token", ...), so
# the check does not depend on it alone: known auth phrases fail immediately;
# any other failure gets one create-folder attempt, then must list cleanly.
Log "Pre-flight: verifying Proton Drive connection..."
$authPattern = 'need to login|not authenticated|unauthori|access token'
$listOut = & $PROTON filesystem list $REMOTE_BASE 2>&1
$listRc  = $LASTEXITCODE
if ($listOut -match $authPattern) {
    $listOut | ForEach-Object { Log "  list: $_" }
    Fail "Proton Drive auth failed -- re-authenticate: & '$PROTON' auth login"
}
if ($listRc -ne 0) {
    $listOut | ForEach-Object { Log "  list: $_" }
    Log "Listing $REMOTE_BASE failed -- attempting to create it, then re-checking"
    & $PROTON filesystem create-folder /my-files PZ13 2>&1 | ForEach-Object { Log "  create-folder: $_" }
    $listOut = & $PROTON filesystem list $REMOTE_BASE 2>&1
    if ($LASTEXITCODE -ne 0 -or ($listOut -match $authPattern)) {
        $listOut | ForEach-Object { Log "  list: $_" }
        Fail "Cannot list $REMOTE_BASE -- see the lines above. If they mention login or a token: & '$PROTON' auth login"
    }
}
Ok "Proton Drive connection verified"
}   # end: if (-not $ArchiveOnly)

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

# A tar left running by an earlier run that was killed (this run holds the
# single-run mutex, so any such tar is orphaned) would hold the archive open.
$staleTar = @(Get-CimInstance Win32_Process -Filter "Name = 'tar.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $TAR -and $_.CommandLine -like '*win11-pz13-*' })
foreach ($p in $staleTar) {
    Warn "Stopping tar left by an earlier run (PID $($p.ProcessId), started $($p.CreationDate))"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($staleTar) { Start-Sleep -Seconds 2 }

if (Test-Path $BACKUP_TMP) { Remove-Item $BACKUP_TMP -Force }

# GNU tar (MSYS runtime) arguments:
#   --force-local       an archive path like C:/... is a local file, not host:file
#   -czf <archive>      create, gzip (gzip.exe found via the PATH set above)
#   -C <profile>        member paths are relative to the profile (Documents/...)
#   --exclude-from      patterns from exclude.txt
#   include paths are passed as arguments. Paths use forward slashes.
# Restore: GNU tar -xzf <archive> -C <profile>   (win_restore.ps1 does this)
$homeFs    = $env:USERPROFILE -replace '\\', '/'
$archiveFs = $BACKUP_TMP      -replace '\\', '/'
$excludeFs = $excludeFile     -replace '\\', '/'
$includePaths = @(Get-Content $includeFile | Where-Object { $_.Trim() -ne '' })

function Remove-LocalArchive {
    if (Test-Path $BACKUP_TMP) { Remove-Item $BACKUP_TMP -Force -ErrorAction SilentlyContinue }
}

Log "Running GNU tar..."
$tarOutput = & $TAR --force-local -czf $archiveFs -C $homeFs "--exclude-from=$excludeFs" @includePaths 2>&1
$tarRc = $LASTEXITCODE
$tarOutput | ForEach-Object { Log "  tar: $_" }
Log "tar exit code: $tarRc"

# GNU tar: 0 = OK; 1 = some file changed while being read (archive still
# valid, warned); 2 = fatal. Anything else (e.g. a crash) is also fatal.
if ($tarRc -ne 0 -and $tarRc -ne 1) {
    Remove-LocalArchive
    Fail "tar failed (exit $tarRc) -- nothing uploaded, retention not run"
}
if ($tarRc -eq 1) { Warn "tar exit 1: a file changed while being read (see tar lines above) -- verifying archive" }
if (-not (Test-Path $BACKUP_TMP)) {
    Fail "Archive was not created -- nothing uploaded, retention not run"
}

$archiveSize = (Get-Item $BACKUP_TMP).Length
$archiveSizeHR = if ($archiveSize -ge 1GB) { "{0:N1} GB" -f ($archiveSize/1GB) }
                 elseif ($archiveSize -ge 1MB) { "{0:N1} MB" -f ($archiveSize/1MB) }
                 else { "{0:N0} KB" -f ($archiveSize/1KB) }
Log "Archive created: $BACKUP_LABEL ($archiveSizeHR, $archiveSize bytes)"

# -----------------------------------------------------------------------------
# STEP 2b -- VERIFY THE ARCHIVE BEFORE UPLOAD
# -----------------------------------------------------------------------------
# Re-read every block. A truncated or damaged archive must never be uploaded:
# the upload would count as a backup and retention would push out an older,
# good one. (Five weeks of truncated archives were uploaded and reported
# COMPLETE before this check existed -- see BACKUP-LOGIC.md.)
Log "--- Step 2b: Verify archive ---"
$verifyOut = & $TAR --force-local -tzf $archiveFs 2>&1
$verifyRc  = $LASTEXITCODE
$entryCount = @($verifyOut | Where-Object { "$_" -notmatch '^tar: ' }).Count
$verifyOut | Where-Object { "$_" -match '^tar: ' } | ForEach-Object { Log "  verify: $_" }
if ($verifyRc -ne 0) {
    Remove-LocalArchive
    Fail "Archive failed verification (tar -tzf exit $verifyRc) -- nothing uploaded, retention not run"
}
Ok "Archive verified: $entryCount entries, $archiveSize bytes ($archiveSizeHR)"

if ($ArchiveOnly) {
    Log "ArchiveOnly: stopping before upload. Archive kept for inspection: $BACKUP_TMP"
    exit 0
}

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
# STEP 4 -- RETENTION (keep KEEP_COUNT, trash older, then empty trash)
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
        # NOTE: `filesystem delete` only permanently removes items ALREADY in
        # trash ("You can permanently delete items only from trash. Trash your
        # files first.") -- so it silently fails on active backups. The working
        # mechanism is `trash <path>` per file, then a single `empty-trash`.
        # NOTE: empty-trash empties the WHOLE account trash, not just these
        # files -- fine for a dedicated backup account.
        $backups | Select-Object -First $deleteCount | ForEach-Object {
            $fname       = $_.name.value
            $remotePath  = "$REMOTE_BASE/$fname"
            Log "  Trashing: $remotePath"
            $delOut = & $PROTON filesystem trash $remotePath 2>&1
            $delOut | ForEach-Object { Log "    $_" }
            if ($LASTEXITCODE -eq 0) {
                Ok "Trashed: $fname"
            } else {
                Warn "Could not trash $remotePath -- may need manual cleanup"
            }
        }
        $emptyOut = & $PROTON filesystem empty-trash 2>&1
        $emptyOut | ForEach-Object { Log "    $_" }
        if ($LASTEXITCODE -eq 0) {
            Ok "Trash emptied"
        } else {
            Warn "Could not empty trash -- check Proton Drive quota manually"
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

# -----------------------------------------------------------------------------
# STEP 6 -- HEARTBEAT (dead-man's-switch)
# -----------------------------------------------------------------------------
# A missed or failed run otherwise fails silently -- nothing checks that this
# script ran at all. Write a local UTC timestamp every successful run, and
# optionally ping an external monitor if HEARTBEAT_URL is set (in the
# environment, or as a HEARTBEAT_URL=... line in a .env file in this
# directory). Mirrors rpi_backup.sh's heartbeat exactly (same .last_success
# filename, same UTC ISO-8601 format) so both platforms are monitored alike.
$heartbeatStamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-Content -Path (Join-Path $PSScriptRoot '.last_success') -Value $heartbeatStamp -Encoding ascii -NoNewline
$heartbeatUrl = $env:HEARTBEAT_URL
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
    $line = Get-Content $envFile | Where-Object { $_ -match '^\s*HEARTBEAT_URL\s*=' } | Select-Object -First 1
    if ($line) { $heartbeatUrl = ($line -split '=', 2)[1].Trim().Trim('"').Trim("'") }
}
if ($heartbeatUrl) {
    try {
        Invoke-WebRequest -Uri $heartbeatUrl -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
        Ok "Heartbeat sent"
    } catch {
        Warn "Heartbeat URL unreachable -- check network/monitor config"
    }
}

Write-Host ""
Write-Host "  Backup complete: $BACKUP_LABEL ($archiveSizeHR)"
Write-Host "  Log: $LOGFILE"
Write-Host ""
