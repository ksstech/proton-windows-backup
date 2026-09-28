# Runbook — Windows (PZ13) Proton Drive Backup

Exact commands for setup, the weekly check, routine changes, restore and troubleshooting.
How it works and why: `BACKUP-LOGIC.md`.

**Conventions**

- Every command runs on PZ13.
- **PS7** = PowerShell 7 (`pwsh`). The scripts refuse Windows PowerShell 5.1
  (`#Requires -Version 7.0`). If a window is 5.1, type `pwsh` in it first.
- **Admin PS7** = PS7 started with "Run as administrator", or `pwsh` typed in an elevated
  window (it stays elevated).
- One command per block. The expected result is stated above each block.
- Full paths throughout; nothing depends on the current directory.

| Name | Path |
|---|---|
| Repo (scripts run from here) | `C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup` |
| Proton Drive CLI | `C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe` |
| Scheduled task | `Proton Drive - Win11 PZ13 Backup` |
| Remote folder | `/my-files/PZ13` |

---

## Phase 1 — Setup on a New or Rebuilt Machine

On PZ13 on 2026-09-28, steps 1.3a–1.12 were run with the results shown. Steps 1.1–1.3 date
from the original setup, or were not needed because the repo already existed. The whole
sequence has not been run on a fresh machine.

### 1.1 PowerShell 7 (PS7 or Windows PowerShell)

Expect `Successfully installed`, or a message that it is already installed.

```powershell
winget install --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements
```

In a new window, expect `PowerShell 7.x.x`.

```powershell
pwsh --version
```

### 1.2 Execution policy (PS7)

Expect no output.

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 1.3 Clone the repo (PS7) — not needed on PZ13 today

Expect `Cloning into ...` and no error.

```powershell
git clone https://github.com/ksstech/proton-windows-backup.git "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup"
```

### 1.3a Git for Windows — provides GNU tar and gzip (PS7)

Already installed on PZ13. Expect `Successfully installed`, or a message that it is already
installed.

```powershell
winget install --id Git.Git --exact --accept-source-agreements --accept-package-agreements
```

Expect `tar (GNU tar) 1.35` or later.

```powershell
& "C:\Program Files\Git\usr\bin\tar.exe" --version
```

### 1.4 Install the Proton Drive CLI (PS7)

Expect `Successfully installed`. Also printed:
- `Path environment variable modified` — winget added `%LOCALAPPDATA%\Microsoft\WinGet\Links` to the user PATH;
- `Command line alias added: "proton-drive"`.

The scripts use neither.

```powershell
winget install --id Proton.ProtonDrive.CLI --exact --scope user --accept-source-agreements --accept-package-agreements
```

### 1.5 Check the CLI (PS7)

Expect `Proton Drive CLI cli-drive@<version>`.

```powershell
& "C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe" --version
```

### 1.6 Sign in (PS7)

A browser opens; sign in. Expect `Authentication successful`.

```powershell
& "C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe" auth login
```

### 1.7 Check access to the remote folder (PS7)

Expect the stored archives. On a new account the folder may not exist yet; the first backup
run creates it.

```powershell
& "C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe" filesystem list /my-files/PZ13
```

### 1.8 First backup, manual (PS7)

Takes about 3–5 minutes on PZ13 (2026-09-28: 2 min 19 s, 439 MB). Expect
`Archive verified: <n> entries, <bytes> bytes`, then at the end
`Backup COMPLETE - win11-pz13-<date>.tar.gz`.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.ps1"
```

### 1.9 Install the scheduled task (Admin PS7)

Expect `Scheduled task installed: 'Proton Drive - Win11 PZ13 Backup'`,
`Checks : hourly, at logon, at unlock (backs up when due: weekly from Sunday 23:00)`,
`Power : AC, or battery >= 50%` and
`Script : C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.ps1`.
Re-run this after any change to the task settings in `win_backup.ps1`.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.ps1" -InstallTask
```

### 1.10 Power settings on AC (Admin PS7)

Set on PZ13 on 2026-07-22 and still in place. How these combine with the keep-awake request:
`BACKUP-LOGIC.md` "Schedule and Power". Expect no output from each command.

```powershell
powercfg /change standby-timeout-ac 0
```

```powershell
powercfg /change hibernate-timeout-ac 0
```

```powershell
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
```

```powershell
powercfg /setactive SCHEME_CURRENT
```

### 1.11 Test the scheduled path (Admin PS7)

Starting the task by hand does nothing if a backup has already run since Sunday 23:00; that
is by design. The two suites below test both cases.

Task settings, decisions, keep-awake request, a not-due run. About 2 minutes. Expect
`PASS 9  FAIL 0  INFO 1`.

```powershell
pwsh -NoProfile -File "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\tests\Run-Tests.ps1" -Suite schedule-power
```

A real backup through the task (makes one due first; uploads). About 3–5 minutes. Expect
`PASS 1  FAIL 0`.

```powershell
pwsh -NoProfile -File "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\tests\Run-Tests.ps1" -Suite scheduled-run -AllowUpload
```

### 1.12 Check the log (PS7)

Expect the last lines to include `Backup COMPLETE`.

```powershell
Get-Content "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.log" -Tail 30
```

---

## Phase 2 — Weekly Check (Monday, PS7)

No external monitor is configured; these checks are the only way a missed run is noticed.
The task starts every hour, so its `LastRunTime` says little; the decision line does.

Expect `Decision: SKIP not due: last success <time after Sunday 23:00> ...`. `RUN` means no
backup has run since Sunday 23:00 yet; `SKIP battery` means it is waiting for AC or 50%.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.ps1" -DecisionOnly
```

Expect `LastTaskResult` `0`.

```powershell
Get-ScheduledTaskInfo -TaskName 'Proton Drive - Win11 PZ13 Backup' | Select-Object LastRunTime, LastTaskResult
```

Expect five archives, the newest from this week.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" list
```

If the decision is still `RUN` on AC, a run failed: check the log (1.12) and look up
`LastTaskResult` under Troubleshooting. Any failed run is retried at the next hour, logon or
unlock; 1.8 runs one now.

---

## Phase 3 — Routine Changes

### 3.1 Back up an extra path

Add one absolute path per line to
`C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\.backup-manifest\include-custom.txt`,
then commit it. It is tracked in git.

Preview what the next run will include (PS7). Expect a report ending with the include count
and the manifest paths.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_audit.ps1"
```

### 3.2 Exclude a pattern

Add one pattern per line to `.backup-manifest\exclude-custom.txt` in the repo, then commit
it. Use tar glob syntax, relative to the profile, with forward slashes (`Documents/Big`,
`*.psd`). Currently: `espressif/sdks` (the ESP-IDF clones). Check the result with 3.3.

### 3.3 Test a change without uploading (PS7)

Runs audit, archive and verify only; no Proton Drive access. Takes about 1 minute. Expect
4 PASS and `PASS 4  FAIL 0`. Results: `tests\results\backup-local-<run>.txt`.

```powershell
pwsh -NoProfile -File "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\tests\Run-Tests.ps1" -Suite backup-local
```

### 3.4 Test restore against Proton Drive (Admin PS7)

Read-only on Proton Drive. Downloads the newest and oldest archives to `%TEMP%` (up to about
3.5 GB) and removes them afterwards. Takes about 10 minutes. If a backup task is running it
waits for it first. Expect `PASS 8  FAIL 0`. Results:
`tests\results\restore-remote-<run>.txt`.

```powershell
pwsh -NoProfile -File "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\tests\Run-Tests.ps1" -Suite restore-remote -AllowRemote
```

### 3.5 Change a script

Edit it in the repo, run 3.3, then 1.8 or 1.11, then commit and push. There is no deploy
step: the repo is what runs. Do not leave the repo mid-rebase or on another commit over a
Sunday night.

### 3.6 CLI version and manual upgrade (PS7)

Every backup run upgrades the CLI; this is only needed to do it by hand.

Expect `No available upgrade found.` or `Successfully installed`.

```powershell
winget upgrade --id Proton.ProtonDrive.CLI --exact --scope user --accept-source-agreements --accept-package-agreements
```

### 3.7 Roll the CLI back to an older version (PS7)

Tested 2026-09-28 (0.8.0 → 0.7.0). Works only while Proton still publishes the version. The
next backup run upgrades it again.

Expect a list of versions.

```powershell
winget show --id Proton.ProtonDrive.CLI --versions
```

Replace `0.7.0` with the version you want. Expect `Successfully installed`.

```powershell
winget install --id Proton.ProtonDrive.CLI --exact --scope user --version 0.7.0 --force --accept-source-agreements --accept-package-agreements
```

### 3.8 Re-authenticate (PS7)

Needed when a run stops with `Proton Drive auth failed`, or the CLI prints
`Invalid access token` or `You need to login first`. Expect `Authentication successful`.

```powershell
& "C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe" auth login
```

### 3.9 Remove the scheduled task (Admin PS7)

Expect `Scheduled task 'Proton Drive - Win11 PZ13 Backup' removed.`

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_backup.ps1" -RemoveTask
```

---

## Restore Procedure (PS7)

`<backup>` is `latest`, a date such as `2026-09-28`, or a full filename. The first command
that needs an archive downloads it to `%TEMP%` (439 MB for 2026-09-28; about 2–3 GB for the
older, truncated archives); later commands reuse it. All commands use GNU tar from Git for
Windows.
Delete it when finished (R.8). For each command's test status see `BACKUP-LOGIC.md`
("Test Status").

### R.1 What is stored

Expect a table of archives with size and date.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" list
```

### R.2 Check the archive is readable

Expect `Archive is intact -- <n> entries`.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" check latest
```

### R.3 Preview without changing anything

Expect `Extracted to: C:\Users\andre\AppData\Local\Temp\restore-staging` and its top-level
folders.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" restore staging latest
```

### R.4 Restore one file or folder

Paths are relative to the profile. `browse latest <text>` shows exact paths. You are asked
to confirm if the target exists. Expect `<n> file(s) restored to ...`.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" restore path latest .gitconfig
```

### R.5 Full restore (overwrites)

Type `YES` when asked. Expect `Archive extracted.` and a list of post-restore steps.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" restore full latest
```

### R.6 Reinstall packages

Preview first: expect `winget export found (...)` and `pip-packages.txt found`; nothing is
installed.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" restore packages latest -DryRun
```

Then for real: shows the archived winget list and asks before installing, then the same for
pip. Not yet run with the current script.

```powershell
& "C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_restore.ps1" restore packages latest
```

### R.7 Scheduled task after a rebuild

Run Phase 1 steps 1.4–1.11.

### R.8 Remove restore files from %TEMP%

Change the date to the archive you downloaded. Expect no output.

```powershell
Remove-Item "$env:TEMP\win11-pz13-2026-09-28.tar.gz" -Force
```

Expect no output.

```powershell
Remove-Item "$env:TEMP\restore-staging" -Recurse -Force
```

---

## Troubleshooting

### Task result codes seen on PZ13

| `LastTaskResult` | Hex | Meaning |
|---|---|---|
| 0 | 0x0 | Success |
| 267009 | 0x41301 | Still running |
| 2147942402 | 0x80070002 | File not found. 2026-07-12: the task called `pwsh.exe` without a path. Fixed; `-InstallTask` registers the full path |
| 1073807364 | 0x40010004 | Process terminated. 2026-07-20, during a catch-up run |
| 267014 | 0x41306 | Task terminated. See `../history/scheduled-task-missed-runs.md` |
| 2147943467 | 0x8007042B | Process terminated unexpectedly. 2026-09-28, under the old schedule; see `BACKUP-LOGIC.md` "Modern Standby" |

For any failure: run 1.8 manually so the week is covered, then check the log.

### Log shows "Scheduled check: SKIP battery below 50%"

A backup was due but PZ13 was on battery below 50%. Nothing to fix: the next hourly, logon or
unlock check runs it once on AC or at 50% or more. The threshold is `$MIN_BATTERY_PCT` in
`win_backup.ps1`.

### A backup was due but nothing ran

Run the Phase 2 decision check. PZ13 cannot back up while asleep (Modern Standby); the run
starts at the first awake hour, logon or unlock. If it shows `RUN` on AC while PZ13 has been
awake for over an hour, run 1.11.

### "cannot be run because it contained a #requires statement for ... 7.0"

The window is Windows PowerShell 5.1. Type `pwsh` and run the command again.

### "Register-ScheduledTask : Access is denied"

`-InstallTask` needs Admin PS7.

### Log shows "Proton Drive auth failed", or the CLI prints "Invalid access token"

Run 3.8, then 1.8.

### "GNU tar/gzip not found in C:\Program Files\Git\usr\bin"

Git for Windows is missing or was moved. Run 1.3a, then 1.8.

### "tar failed (exit <n>)" or "Archive failed verification"

Nothing was uploaded; the remote archives are unchanged. The tar messages are in the log
lines above. Run 3.3 to reproduce without uploading; its results file shows the full tar
output.

### "Upload failed"

The archive is kept in `%TEMP%`. Re-run 1.8; it rebuilds and uploads.

### "running scripts is disabled on this system"

Run 1.2.

---

## Quick Reference — Key Paths

| Item | Path |
|---|---|
| Scripts | `C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup\win_*.ps1` |
| Backup log | `...\proton-windows-backup\win_backup.log` |
| Restore log | `...\proton-windows-backup\win_restore.log` |
| Last success (UTC) | `...\proton-windows-backup\.last_success` |
| Manifest (generated) | `...\proton-windows-backup\.backup-manifest\` |
| Your include/exclude lists | `...\proton-windows-backup\.backup-manifest\include-custom.txt`, `exclude-custom.txt` |
| CLI binary | `C:\Users\andre\AppData\Local\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe` |
| CLI alias (not used by the scripts) | `C:\Users\andre\AppData\Local\Microsoft\WinGet\Links\proton-drive.exe` |
| Auth token | Credential Manager, `ch.proton.drive/drive-sdk-cli/auth-session` |
| Archive while being built | `%TEMP%\win11-pz13-YYYY-MM-DD.tar.gz` (deleted after upload) |
| Restore downloads / staging | `%TEMP%\win11-pz13-*.tar.gz`, `%TEMP%\restore-staging` |
| Remote | `/my-files/PZ13` (5 archives kept) |
| Archiver | `C:\Program Files\Git\usr\bin\tar.exe` (GNU tar, from Git for Windows) |
| Test runner / results | `...\proton-windows-backup\tests\Run-Tests.ps1`, `tests\results\` |
| RPi version tracking | `vh@192.168.1.6:~/xware-update-checks`, key `C:\Users\andre\.ssh\workstation-to-rpi` |
