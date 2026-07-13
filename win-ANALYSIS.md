# Windows ARM64 vs Linux RPi -- proton-drive CLI Platform Analysis

## Why the Windows Backup Has Never Run

**Root cause: Windows Credential Manager session isolation.**

When Windows Task Scheduler is configured with "Run whether user is logged on or
not" (the natural choice for an automated backup), it creates a batch logon session
that does NOT share the interactive user's Windows Credential Manager vault.
proton-drive.exe stores its auth token as a user credential in Credential Manager.
In the batch session, that vault entry is either inaccessible or simply not there --
so the CLI either silently errors or waits for browser-based auth that never
completes. The backup process exits without uploading anything.

This is structurally identical to the gnome-keyring problem on the RPi, where cron
also runs without the D-Bus session bus the keyring daemon listens on. The RPi fix
was to export DBUS_SESSION_BUS_ADDRESS before calling proton-drive. The Windows fix
is different: ensure Task Scheduler runs the task in the interactive user's session,
not a batch session.

**Correct Task Scheduler setting:**

```
General tab -> Security options
  [x] Run only when user is logged on
  [ ] Run whether user is logged on or not   <- this is what breaks it
```

Since the backup runs Sunday at 23:00 when the workstation is on and the user is
logged in (even if the screen is locked -- the session still exists), "run only when
user is logged on" is sufficient.

---

## PowerShell Version Requirement

**PowerShell 7 is required.** The scripts use `#Requires -Version 5.1` for broad
compatibility, but PowerShell 7 must be installed for the scheduled task to function
correctly and for all features to work as designed.

### Why not Windows PowerShell 5.1?

Windows ships with PowerShell 5.1 (`powershell.exe`) which cannot be removed. It is
adequate for running the scripts manually. However:

- Task Scheduler by default invokes `powershell.exe` (5.1), not `pwsh.exe` (7).
  The `-InstallTask` switch in `win_backup.ps1` explicitly targets `pwsh.exe`.
  If PS7 is not installed, the scheduled task will fail to start.
- PS7 is in active development; 5.1 is maintenance-only (security patches only).
- PS7 is cross-platform -- the same scripts could run on Linux or macOS if needed.

### PowerShell 5.1 vs 7 -- Key Differences

| Aspect | 5.1 (Windows PowerShell) | 7.x (PowerShell) |
|--------|--------------------------|------------------|
| Runtime | .NET Framework 4.x | .NET 8+ |
| Binary | `powershell.exe` | `pwsh.exe` |
| Ships with Windows | Yes (built-in) | No (separate install) |
| Active development | No (maintenance only) | Yes |
| Cross-platform | No (Windows only) | Yes (Win/Linux/macOS) |
| Language features | Base set | Ternary `? :`, `??=`, `&&`/`||` pipeline chains |
| Parallel pipelines | No | `ForEach-Object -Parallel` |
| JSON depth control | Limited | `ConvertFrom-Json -Depth` |
| Coexistence | Yes | Yes -- both can be installed simultaneously |

### Language features available in PS7 only

```powershell
# Ternary operator
$result = $condition ? 'yes' : 'no'

# Null-coalescing assignment
$value ??= 'default'

# Pipeline chain operators (like && and || in bash)
Get-Item file.txt && Write-Host "found"

# Parallel pipeline
1..10 | ForEach-Object -Parallel { Start-Sleep 1; $_ } -ThrottleLimit 5
```

None of these are used in the current backup scripts (for 5.1 compatibility), but
they are available if scripts are extended in future.

### Compatibility notes

PS7 does NOT fully replace 5.1. Some Windows-specific modules require 5.1:
- Old WMI via `Get-WmiObject` (use `Get-CimInstance` in PS7 instead)
- Some legacy Exchange / Active Directory modules
- COM interop in certain enterprise tools

For this backup system none of those apply, so PS7 is a drop-in upgrade.

### Install PowerShell 7

```powershell
winget install Microsoft.PowerShell
```

Verify after install (open a new terminal):

```powershell
pwsh --version   # should show 7.x.x
```

PS7 and PS5.1 coexist. Windows continues to default to 5.1 for right-click "Run
with PowerShell" and for `.ps1` file association. The backup scheduled task
explicitly calls `pwsh.exe` to ensure PS7 is used.

---

## Platform Comparison

| Aspect | RPi (Linux ARM64) | Windows 11 ARM64 (PZ13) |
|--------|-------------------|--------------------------|
| CLI binary | `proton-drive` (ELF) | `proton-drive.exe` (PE) |
| CLI version | 0.4.3 | 0.4.3 (windows/arm64 build) |
| Credential store | gnome-keyring / libsecret | Windows Credential Manager (DPAPI) |
| Session problem | cron has no D-Bus session bus | Batch logon has no Credential Manager access |
| Session fix | Export DBUS_SESSION_BUS_ADDRESS | Task Scheduler: "Run only when user is logged on" |
| Scheduler | cron | Windows Task Scheduler |
| Shell | bash | PowerShell 7 (pwsh.exe) |
| Archive tool | GNU tar (installed) | BSD tar.exe (built into Windows 10/11) |
| Archive format | .tar.gz with -P (absolute paths) | .tar.gz without -P (relative to home dir) |
| Root file access | sudo tar (passwordless) | Run task as Administrator, or target user-owned paths only |
| Temp directory | /tmp/ | $env:TEMP\ |
| Home directory | /home/vh/ | C:\Users\username\ |
| Log file | ~/proton-headless-backup/rpi_backup.log | ~\proton-windows-backup\win_backup.log |
| Include manifest | ~/proton-headless-backup/.backup-manifest/ | ~\proton-windows-backup\.backup-manifest\ |
| Remote folder | /my-files/RPi5-VH/ | /my-files/PZ13/ |
| Archive label | rpi5-vh-YYYY-MM-DD.tar.gz | win11-pz13-YYYY-MM-DD.tar.gz |
| Pre-flight keyring check | dbus-send --session ping | None needed (Credential Manager always running) |
| Environment export needed | DBUS_SESSION_BUS_ADDRESS, GNOME_KEYRING_CONTROL | None |
| --json flag available | Yes (v0.4.3) | Yes (same binary, same flags) |

---

## Key Differences in Backup Content

| Category | RPi equivalent | Windows |
|----------|----------------|---------|
| User home | /home/vh/ | C:\Users\username\ (selective) |
| Code / projects | /home/vh/ea_ps2342/ | Documents\, Projects\, Code\ etc. |
| Application config | Custom systemd units, /etc/ files | AppData\Roaming (selective) |
| Credentials / keys | ~/.local/share/keyrings/, NM connections | ~\.ssh\, ~\.gnupg\ (if used) |
| Admin config | /etc/webmin/ (sudo copy) | Registry (not file-copyable) |
| Installed packages | apt-mark showmanual -> packages.txt | winget export -> winget-export.json |
| Scheduled tasks | /etc/systemd/system/*.service | schtasks /query export |

---

## Archive Format: BSD tar on Windows

Windows 10/11 include BSD tar.exe at C:\Windows\System32\tar.exe. It supports:
- -czf to create .tar.gz
- --exclude and --exclude-from for exclusion files
- -C to set the working directory (relative paths in archive)
- positional path arguments for the include list (do NOT use -T with -C; see below)

The key difference from the RPi: the RPi uses -P (preserve absolute paths starting
with /) because restoring to exact Linux paths is the goal. On Windows, we use
-C "$env:USERPROFILE" so paths inside the archive are relative to the home directory
(e.g. Documents/foo.txt instead of C:\Users\username\Documents\foo.txt).
Restore uses tar -xzf archive.tar.gz -C "$env:USERPROFILE".

### BSD tar quirk: -T combined with -C

BSD tar on Windows generates a spurious empty-path visit between archive entries
when -T (include file list) is used together with -C. This produces:

    tar.exe: : Couldn't visit directory: No such file or directory

even when all listed paths are valid. The fix is to read include.txt into a
PowerShell array and pass the paths directly as positional arguments:

    $includePaths = Get-Content include.txt | Where-Object { $_.Trim() -ne '' }
    tar -czf archive.tar.gz -C $env:USERPROFILE --exclude-from exclude.txt @($includePaths)

This is the approach used in win_backup.ps1 and in the selective-extract commands
in win_restore.ps1.

---

## The --json Flag (Available on Both Platforms)

The Proton CLI --json flag outputs structured data for reliable parsing. The Windows
scripts use --json | ConvertFrom-Json throughout:

```powershell
$items = & $PROTON filesystem list $REMOTE_BASE --json | ConvertFrom-Json
$items | Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } | Sort-Object { $_.name.value }
```

**Important:** the `name` field is a nested object `{"ok":true,"value":"filename.tar.gz"}`,
not a plain string. Always access it as `$_.name.value`. Sorting must also use
`Sort-Object { $_.name.value }` (a scriptblock), not `Sort-Object name`, because
sorting on the nested object directly does not sort alphabetically.

This is cleaner and more robust than parsing human-readable output.

Note for RPi scripts: the same --json flag works on Linux. Future iterations of
rpi_backup.sh could use: proton-drive filesystem list --json | jq -r '.[] | .name.value'

---

## What Is NOT Backed Up (By Design)

| Item | Reason |
|------|--------|
| Windows Registry | Cannot be file-copied while OS is running |
| AppData\Local\ | Mostly caches, temp files, per-machine state |
| AppData\Local\Temp | Transient |
| node_modules\ | Regenerable with npm install |
| .venv\, venv\ | Regenerable with pip install -r requirements.txt |
| bin\Debug\, obj\ | Build output, regenerable |
| OneDrive synced folders | Already in cloud |
| C:\Windows\ | OS files -- reinstall from ISO |
| Program Files | Applications reinstallable via winget |

---

## Setup Steps (One-Time)

1. Install PowerShell 7 (if not already installed):
   ```powershell
   winget install Microsoft.PowerShell
   # Open a new terminal, then verify:
   pwsh --version
   ```

2. Create the proton-windows-backup directory:
   ```powershell
   New-Item -ItemType Directory -Path "$env:USERPROFILE\proton-windows-backup" -Force
   ```

3. Download proton-drive.exe (windows/arm64) from
   https://proton.me/download/drive/cli/0.4.3/windows-arm64/proton-drive.exe
   -> save to C:\Users\username\proton-windows-backup\proton-drive.exe

4. Authenticate (interactive, once only):
   ```powershell
   cd ~\proton-windows-backup
   .\proton-drive.exe auth login
   # Follow browser prompt
   .\proton-drive.exe filesystem list /   # verify
   ```

5. Create remote folder (once only):
   ```powershell
   .\proton-drive.exe filesystem create-folder /my-files PZ13
   ```

6. Copy scripts to ~\proton-windows-backup\:
   ```
   ~\proton-windows-backup\win_audit.ps1
   ~\proton-windows-backup\win_backup.ps1
   ~\proton-windows-backup\win_restore.ps1
   ```

7. Set PowerShell execution policy (once only):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

8. Run a manual test backup:
   ```powershell
   cd ~\proton-windows-backup
   .\win_backup.ps1
   ```

9. Install the scheduled task (run as Administrator once):
   ```powershell
   .\win_backup.ps1 -InstallTask
   ```
   This creates a Task Scheduler entry that runs Sunday at 23:00
   with "Run only when user is logged on" -- the critical setting.

---

## Files in This Package

| File | Purpose | RPi equivalent |
|------|---------|----------------|
| win-ANALYSIS.md | This document | (none) |
| win_audit.ps1 | Discovers what to back up, writes manifest | audit_backup.sh |
| win_backup.ps1 | Audit -> archive -> upload -> retention | rpi_backup.sh |
| win_restore.ps1 | list / check / browse / restore | rpi_restore.sh |
