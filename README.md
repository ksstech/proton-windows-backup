# proton-windows-backup

Weekly backup of the Windows 11 ARM64 laptop **PZ13** to Proton Drive (`/my-files/PZ13`,
5 archives kept), using the Proton Drive CLI. The CLI is installed and upgraded by winget
(`Proton.ProtonDrive.CLI`, user scope). Archives are made with GNU tar from Git for Windows
and fully re-read before upload. A scheduled task runs the scripts directly from this repo
every Sunday at 23:00.

| File | Purpose |
|---|---|
| `win_backup.ps1` | Upgrade the CLI, audit, archive, verify, upload, retention, heartbeat. `-ArchiveOnly` stops after verify (no upload). `-InstallTask` / `-RemoveTask` manage the scheduled task |
| `win_audit.ps1` | Work out what to back up; write `.backup-manifest\` (run by `win_backup.ps1`, or on its own to preview) |
| `win_restore.ps1` | `list`, `check`, `diff`, `live`, `browse`, `get`, `restore full / path / staging / packages [-DryRun]` |
| `.backup-manifest\include-custom.txt`, `exclude-custom.txt` | Your extra include paths and exclusions (tracked in git) |
| `tests\Run-Tests.ps1`, `tests\suites\` | Test runner and suites; results in `tests\results\` (not in git) |
| `RUNBOOK.md` | Exact commands: setup, weekly check, routine changes, tests, restore, troubleshooting |
| `BACKUP-LOGIC.md` | How it works, why, incidents, known issues, test status |

Requires PowerShell 7 and Git for Windows. Conventions shared with the other Proton Drive
repos are in `../CLAUDE.md`.
