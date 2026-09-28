# Backup System — Design Rationale (Windows, PZ13)

Windows counterpart of `proton-headless-backup`. Conventions shared by all the Proton Drive
repos (retention, `--json` parsing, the credential-store bug class, CLI version tracking) are
in the parent `../CLAUDE.md`. This file covers what is specific to Windows. Test evidence is
summarised in "Test Status" at the end.

---

## Layout

The scripts run directly from this git repo:

`C:\Users\andre\DevSpace\z-repo\proton-drive\proton-windows-backup`

DevSpace is on local disk (not a sync folder). Everything the scripts write at runtime lands
next to them and is gitignored:

| Path (in the repo dir) | In git | Written by |
|---|---|---|
| `win_backup.ps1`, `win_audit.ps1`, `win_restore.ps1` | yes | — |
| `.backup-manifest\include-custom.txt`, `exclude-custom.txt` | yes | you |
| `.backup-manifest\include.txt`, `exclude.txt`, `winget-export.json`, `pip-packages.txt`, `npm-global.txt`, `schtasks-export.csv` | no | `win_audit.ps1`, every run |
| `win_backup.log` (trimmed to 400 lines once it passes 500), `win_restore.log` | no | the scripts |
| `.last_success` | no | `win_backup.ps1`, after each successful run |
| `.env` (optional, holds `HEARTBEAT_URL`) | no | you |
| `tests\Run-Tests.ps1`, `tests\suites\*.ps1` | yes | — |
| `tests\results\` | no | `Run-Tests.ps1` |

Because the scheduled task runs the checked-out files, **whatever git has checked out is what
runs**. Do not leave the repo mid-rebase, on an old commit, or with half-finished edits over a
Sunday night.

Prerequisites: PowerShell 7, Git for Windows (for GNU `tar`), the Proton Drive CLI (winget).

---

## Differences from the RPi (`proton-headless-backup`)

| Aspect | RPi5-VH (Linux ARM64) | PZ13 (Windows 11 ARM64) |
|---|---|---|
| CLI install / upgrade | binary in the script dir; xware-update auto-installs | winget, upgraded by Step 0 of each run |
| Credential store | gnome-keyring via libsecret / D-Bus | Credential Manager |
| Unattended-session fix | export D-Bus variables; `loginctl enable-linger` | task `LogonType Interactive` |
| Scheduler / shell | cron / bash | Task Scheduler / PowerShell 7 |
| Archiver | GNU tar, `-P` (absolute paths) | GNU tar from Git for Windows, paths relative to `%USERPROFILE%` |
| Verify before upload | no | yes (`tar -tzf`) |
| Package snapshot | `apt-mark showmanual` | `winget export`, `pip freeze`, `npm -g`, `schtasks` |
| Remote folder / archive name | `/my-files/RPi5-VH`, `rpi5-vh-YYYY-MM-DD.tar.gz` | `/my-files/PZ13`, `win11-pz13-YYYY-MM-DD.tar.gz` |

Include paths are passed to tar as arguments, not with `-T <file>`: Windows' tar combined
with `-C` produced spurious `Couldn't visit directory` errors, and the arguments approach was
kept when switching to GNU tar.

---

## The Proton Drive CLI — winget-managed

| Item | Value |
|---|---|
| winget id | `Proton.ProtonDrive.CLI` (official Proton AG package, installer type `portable`) |
| Scope | user |
| Binary | `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe` |
| Command alias | `%LOCALAPPDATA%\Microsoft\WinGet\Links\proton-drive.exe` — a symbolic link to the binary; winget put the `Links` folder on the user PATH |

This is a deliberate divergence from the "self-contained directory" convention the other
platforms follow: the binary lives where winget puts it, not next to the scripts.

The scripts call the binary by its absolute package path. They do not use PATH or the
`Links` alias — a scheduled task must not depend on either. It is the same class of problem
as Task Scheduler failing to find `pwsh.exe` (`0x80070002`), fixed there by registering the
full path. winget upgrades a portable package in place, so the package path does not change
between versions.

### Updates

Step 0 of every run:

```
winget upgrade --id Proton.ProtonDrive.CLI --exact --scope user --silent --disable-interactivity --accept-source-agreements --accept-package-agreements
```

- The CLI version is read before and after. Non-fatal: if winget is missing, fails, or has
  nothing newer, the installed version is used.
- On a version change the run calls `xware-ack proton-drive-cli/windows-arm64 <version>` on
  the RPi over SSH (`vh@192.168.1.6`, key `~\.ssh\workstation-to-rpi`), so the RPi's weekly
  xware-update report shows PZ13 as current. If the RPi is unreachable the run logs the exact
  command to run there by hand and carries on.
- A broken new release is stopped by the pre-flight check (below) before an archive is built.
- There is no automatic rollback and no `.bak` copy. Manual rollback (see RUNBOOK) is
  `winget install ... --version <old> --force`, which works only while Proton still
  publishes that version in the winget catalog. The next scheduled run upgrades it again.

### Credential store

The auth token is in Windows Credential Manager, target
`ch.proton.drive/drive-sdk-cli/auth-session`, per user. Normal and Administrator PS7
windows and the elevated scheduled task all authenticate with it. Reinstalling the binary
with winget (0.8.0 → 0.7.0 → 0.8.0) did not need a new login.

The task is registered with `LogonType Interactive`, so it runs in your logged-on session
where the token is. A task set to "Run whether user is logged on or not" (batch logon) gets
a separate credential vault without the token. That is the documented reason for this
setting (see `../CLAUDE.md`); batch logon has not been tested on PZ13.

Re-authenticate with `auth login` (browser sign-in). This was needed on 2026-09-28, when the
stored token started returning `Invalid access token`; the cause was not identified.

---

## The Archiver — GNU tar, not Windows' tar.exe

Archives are made and read with **GNU tar 1.35** and **gzip 1.14** from Git for Windows
(`C:\Program Files\Git\usr\bin`). On PZ13 these are x64 builds running under emulation on
ARM64. Git for Windows is therefore a prerequisite (`winget install --id Git.Git --exact`).

Windows' own `C:\Windows\System32\tar.exe` (bsdtar/libarchive **3.8.8**) was dropped on
2026-09-28 for two reasons, both reproduced on PZ13:

1. **It crashes on filenames the Windows ANSI code page cannot represent** — Chinese,
   Japanese, Korean. The crash is an access violation (`0xC0000005`, exit `-1073741819`, same
   fault offset `0x5ef0` every time), with no error message, leaving a truncated archive.
   Names that fit the code page (e.g. `café.txt`) work. It converts filenames through the C
   runtime's ANSI locale; this is a known limitation of the Windows build (libarchive issue
   #2092) with no setting to change it. The Windows "Use Unicode UTF-8" beta option was not
   tried — a machine-wide change, and the libarchive maintainers doubt it reaches this code.
2. **It follows junctions.** `espressif\sdks\esp-idf` is a junction to `espressif\sdks\v5x`,
   so the ESP-IDF tree was archived twice (35,132 extra entries). GNU tar stores a junction
   as a link.

Windows' tar can *read* GNU tar's archives, but lists non-ASCII names wrongly, so
`win_restore.ps1` uses GNU tar too.

GNU tar is run with:

- `--force-local` — otherwise GNU tar reads `C:/...` in an archive path as `host:file`
- forward-slash paths
- `gzip` found via PATH, `LANG`/`LC_ALL=C.UTF-8` and UTF-8 console output — set inside the
  script's own process only
- include paths passed as arguments, `-C <profile>`, `--exclude-from=<exclude.txt>`

The archiver comparison is kept as test suites (`tests\suites\archiver-round1..3`).

---

## The Two-Script Design

```
win_audit.ps1  -->  win_backup.ps1
```

`win_backup.ps1` runs `win_audit.ps1` first on every run. The audit never caches: it
rediscovers what exists, rewrites `include.txt` / `exclude.txt`, and snapshots package lists.
It makes no archive, so it can be run on its own to inspect what would be backed up.

`win_backup.ps1` order (step names as in the log):

- Scheduled runs only: is a backup due, does power allow it? If not, exit (see "Schedule and
  Power")
- One run at a time (a mutex); a second run exits at once
- Keep-awake power request, held until the process exits
- Pre-flight: CLI, GNU tar and gzip present
- Step 0: `winget upgrade` of the CLI (non-fatal)
- Pre-flight: Proton Drive connection and auth
- Step 1: Audit
- Step 2: Archive with GNU tar
- Step 2b: **Verify — re-read the whole archive** (see below)
- Step 3: Upload
- Step 4: Retention
- Step 5: Clean up the local archive, list what is stored
- Heartbeat (`.last_success`, optional `HEARTBEAT_URL`)

`win_backup.ps1 -ArchiveOnly` runs audit, archive and verify only — no Proton Drive access,
no upload, no retention, no `.last_success` — and leaves the archive in `%TEMP%`. It is how
the backup code path is tested without uploading (`tests\suites\backup-local`).

---

## What `win_audit.ps1` Includes

Each path is included only if it exists.

- **Always:** `Documents`, `Desktop`, `.ssh`, `.gitconfig`, `.gitignore_global`, `.npmrc`,
  `.gnupg`, and the manifest directory itself
- **Code directories directly under the profile:** `Projects`, `Code`, `code`, `repos`,
  `dev`, `src`, `git`, `Development`, `workspace`
- **Application config:** `AppData\Roaming\Microsoft\Windows Terminal`,
  `AppData\Roaming\Code\User`, `.vscode`, the PowerShell profile folder,
  `AppData\Roaming\GitHub`, `AppData\Roaming\npm`, `AppData\Roaming\pip`
- **Every path in `include-custom.txt`.** Currently: `espressif`, `lite-vna`, `witrn`,
  `usb_driver`, `winspectrum`, `.claude.json`, `.claude.json.backup`, `Pictures`, `bin`
  (added 2026-08-25)

Include paths are made relative to `%USERPROFILE%`, with forward slashes. A path that lies
inside another include path is dropped — the PowerShell profile folder is inside
`Documents`, and was archived twice before this. On 2026-09-28 the audit produced 16 paths.

Package lists, for reinstalling rather than restoring binaries: `winget export`,
`pip freeze`, `npm list -g --depth=0`, `schtasks /query /fo CSV /v`.

---

## What Is Excluded

`exclude.txt` is regenerated every run from a fixed list, plus anything in
`exclude-custom.txt`. The fixed list is written from a **single-quoted** PowerShell
here-string, so `$Temp` and `$RECYCLE.BIN` are written literally (see "Incidents").

- Regenerable dependencies and build output: `node_modules`, `.venv`, `venv`, `env`, `.env`,
  `__pycache__`, `*.pyc`, `*.pyo`, `*.egg-info`, `bin/Debug`, `bin/Release`, `obj`,
  `build`, `dist`, `out`, `.next`, `.nuxt`
- IDE caches: `.vs`, `.idea`, `*.suo`, `*.user`, `.ionide`
- Windows temp and caches: `AppData/Local/Temp`, `INetCache`, `Explorer`, `CrashDumps`,
  `D3DSCache`, `NVIDIA`
- `*.log`, `*.log.[0-9]*`, `*.iso`, `*.vmdk`, `*.vhd`, `*.vhdx`, `OneDrive`, `$RECYCLE.BIN`
- `Documents/My Videos`, `My Music`, `My Pictures`, `My Documents` — Windows shell junctions
  (to `Videos`, `Music`, `Pictures`)
- `Documents/$Temp` — a hidden scratch folder
- From `exclude-custom.txt`: **`espressif/sdks`** — the ESP-IDF clones `master` and `v5x`
  and the `esp-idf` junction. Public git repositories; re-clone rather than back up
  (excluded 2026-09-28). The rest of `espressif` (`soak`, `backup-sdkmove-*`) stays in;
  `espressif\build` is already excluded by `build`.

## What Is Not Backed Up

- The registry, `C:\Windows`, `Program Files` (reinstall; `winget-export.json` lists apps)
- `AppData\Local` apart from anything listed above
- OneDrive (already in the cloud)
- The ESP-IDF SDK clones (above)

---

## The Archive and Its Verification

```
tar --force-local -czf C:/Users/andre/AppData/Local/Temp/win11-pz13-YYYY-MM-DD.tar.gz -C C:/Users/andre --exclude-from=<exclude.txt> <include paths>
```

- Paths inside the archive are relative to the profile (`Documents/...`,
  `DevSpace/z-repo/proton-drive/proton-windows-backup/.backup-manifest/...`), so restore is
  `tar -xzf <archive> -C <profile>` (with GNU tar, as `win_restore.ps1` does).
- **tar exit code:** 0 = OK; 1 = a file changed while being read (warned, archive still
  valid); anything else = the run fails.
- **Verify before upload:** the whole archive is re-read with `tar -tzf`, which must exit 0.
  The log records the exact size in bytes and the number of entries.
- **On any failure** the local archive is deleted and the run stops: nothing is uploaded,
  retention does not run, `.last_success` is not written. Existing remote archives stay.
- 2026-09-28, scheduled run: 6,164 entries, 460,272,967 bytes (439 MB); tar 38 s, verify
  5 s, upload 78 s, 2 min 19 s in total.

## Upload and Retention

- `filesystem upload -f replace <archive> /my-files/PZ13`. `-f replace` stops a same-day
  re-run blocking on an interactive "file exists" prompt; the re-run replaces the archive.
- Keep 5. The remote folder is listed with `--json`; the filename is `.name.value` (a nested
  object, not a string) and the sort is on that value. Anything beyond 5 is removed with
  `filesystem trash <path>`, then one `filesystem empty-trash`. `filesystem delete` only
  works on items already in the trash. `empty-trash` empties the whole account's trash.

## Pre-flight

Before the audit, the run lists `/my-files/PZ13`:

- Output containing a known auth phrase (`need to login`, `not authenticated`,
  `unauthori...`, `access token`) stops the run with the `auth login` command to use.
- Any other failure gets one `create-folder /my-files PZ13` attempt, then the folder must
  list cleanly or the run stops.

This keeps an auth failure from being discovered only at upload. Only the success path has
run; the two failure paths are untested (they need an invalid token or a missing remote
folder). Whether the CLI returns a non-zero exit code for `Invalid access token` is unknown;
the text match covers that message either way.

The RPi and syslog scripts still match only the first three phrases and carry on after
other failures — TODO in `../CLAUDE.md`.

## Heartbeat

After a successful run `win_backup.ps1` writes a UTC timestamp to `.last_success` and, if
`HEARTBEAT_URL` is set (environment or a `HEARTBEAT_URL=...` line in `.env`), requests that
URL. No `HEARTBEAT_URL` is configured, so that part has never run, and a missed run is only
noticed by checking `.last_success` (RUNBOOK Phase 2).

---

## Schedule and Power

### What Windows allows (Microsoft Learn, checked 2026-09-28)

- PZ13 is a Modern Standby laptop. Once standby has passed its "desktop activity moderator"
  phase, **Windows does not let desktop apps run for the rest of standby.** The backup runs
  in the user's session (it has to, for Credential Manager), so it cannot run while PZ13 is
  asleep. A wake timer does not change this. This is why the 23:00 wake-and-run design kept
  failing: runs started, were paused, and were later killed (see "Known Issue" below).
- A **power request** (`PowerSetRequest`, `PowerRequestSystemRequired`) stops the machine
  entering standby by idling out: on AC for as long as it is held, on battery for at most
  5 minutes after the sleep timeout. PZ13's sleep timeout is Never on AC and on battery.
- Power requests end on **lid close, power button, or Start > Sleep.** Nothing a program
  does prevents that.

Sources: `PowerSetRequest` remarks; "Prepare software for modern standby" (both
learn.microsoft.com).

### The design

A backup is **due** once a week, from **Sunday 23:00**: when `.last_success` is older than
the most recent Sunday 23:00. The task gives the script many chances to run; the script
decides.

- Task triggers: **every hour**, **at logon**, **at unlock**. Each starts
  `win_backup.ps1 -Scheduled`.
- `-Scheduled` checks, in order:
  1. Not due: exit at once, nothing logged (the normal hourly case).
  2. On battery below 50% (`$MIN_BATTERY_PCT`): one log line
     `Scheduled check: SKIP battery below 50%: ...`, exit. The next trigger tries again.
  3. Otherwise run, and log `Scheduled run: RUN: last success ..., due since ..., power ...`.
- Every run, scheduled or manual, holds a power request (system required + execution
  required, reason `Proton Drive backup (win_backup.ps1)`) until the process exits. So once
  a backup has started while the machine is awake, idle sleep waits for it.
- Result: a backup runs on the first awake hour, logon or unlock after Sunday 23:00 with AC
  or at least 50% battery. A missed week is caught up the same way. A run started on AC
  finishes if unplugged.
- A run is only interrupted by closing the lid or pressing the power button. It is then
  paused, and resumes when the machine wakes (the 12-hour limit leaves room for that). If it
  fails instead, `.last_success` is not written, so the next trigger retries.
- Only one run at a time (a named mutex, `Local\ProtonDrive-PZ13-Backup`). Before building
  an archive, the run stops any GNU `tar` still writing a `win11-pz13-*` archive — left
  behind by an earlier run that was killed (August 2026, and 2026-09-20).
- Manual runs (`win_backup.ps1` without `-Scheduled`) always run, whatever the date or
  battery.
- `win_backup.ps1 -DecisionOnly` prints the decision and changes nothing;
  `-SimulatePower AC|<pct>` and `-SimulateLastSuccess <time>` replace the real values (tests).

### The task

`Proton Drive - Win11 PZ13 Backup`, created by `win_backup.ps1 -InstallTask`
(Administrator). Values read back from the registered task on 2026-09-28
(`schedule-power` S01):

| Setting | Value | Why |
|---|---|---|
| Triggers | Time trigger repeating every hour (`PT1H`, for 3650 days); at logon; at session unlock (state 8) | many chances to run while awake |
| Action | `<full path of pwsh.exe> -NonInteractive -WindowStyle Hidden -File "<repo>\win_backup.ps1" -Scheduled` — the path is resolved with `Get-Command pwsh` when `-InstallTask` runs | PATH is not reliable in a task |
| Logon type | Interactive | Credential Manager access |
| Run level | Highest | |
| Execution time limit | 12 hours (`PT12H`) | a run paused by lid close must not be killed on resume |
| StartWhenAvailable | True | a trigger missed while asleep runs on wake |
| RunOnlyIfNetworkAvailable | True | |
| WakeToRun | False | a Modern Standby wake does not let the backup run; it only started runs that were then paused |
| DisallowStartIfOnBatteries | False | the script applies the 50% threshold |
| StopIfGoingOnBatteries | False | a started run finishes |
| MultipleInstances | IgnoreNew | |

If PowerShell 7 is installed under `C:\Program Files\WindowsApps\`, that path contains the
version. After a PowerShell upgrade, re-run `-InstallTask` if the task stops starting (check
`LastTaskResult`, RUNBOOK Troubleshooting).

PowerShell 7 is required: all scripts start with `#Requires -Version 7.0`, so Windows
PowerShell 5.1 refuses to run them. Runs from 5.1 had written UTF-16 lines into the UTF-8
log. The scripts are pure ASCII — PowerShell reads a `.ps1` without a BOM as Windows-1252,
and non-ASCII characters can break parsing. Non-ASCII test filenames are built from Unicode
code points.

Power (checked 2026-09-28): PZ13 uses Modern Standby (`powercfg /a`: "Standby (S0 Low Power
Idle) Network Connected"; S3 not available). On AC: sleep after Never, hibernate after
Never, wake timers enabled — set 2026-07-22 for this backup. On battery both timeouts are
also Never; that was not set by this project.

---

## Modern Standby — Runs Suspended (redesigned 2026-09-28)

Scheduled runs under the old design (Sunday 23:00, `WakeToRun`, 2-hour limit):

- **2026-09-20:** started 23:38, a catch-up for the 23:00 slot. The log stops at
  `Running tar...`. The orphaned `tar` kept writing the archive until 2026-09-22 00:00; it
  was never uploaded.
- **2026-09-28:** started 02:04:05, a catch-up for the missed Sunday slot. The first log
  line is 03:27:43; the run stopped in Step 0. `LastTaskResult` `0x8007042B` (process
  terminated unexpectedly).

Both fit what Microsoft documents: a desktop process started or running during Modern
Standby is paused, and the task later killed it. Replaced on 2026-09-28 by the design in
"Schedule and Power". Tested with the machine awake on AC (see Test Status). Whether it
catches up as intended after a real night in standby is known only after the next Sunday;
check with RUNBOOK Phase 2. Earlier incidents and the diagnosis method:
`../history/scheduled-task-missed-runs.md`.

---

## Incidents Found and Fixed on 2026-09-28

Full account: `../history/pz13-archive-integrity-2026-09.md`.

1. **Truncated archives, reported COMPLETE.** From 2026-08-25, when `witrn` was added,
   Windows' tar crashed on `witrn\pcsoft\Fonts\思源黑体.ttf` every run. The script did not
   check tar's exit code, uploaded the part-written archive, ran retention and reported
   `Backup COMPLETE`. Checked and truncated: 2026-08-31, 2026-09-16, and the first
   2026-09-28 archive; 09-06 and 09-13 were made the same way (not checked). Fixed by GNU tar
   plus the verify step.
2. **`Documents` excluded from every backup since July.** The exclude list was written from a
   double-quoted here-string, so `Documents/$Temp` became `Documents/` and Windows' tar
   dropped the whole folder (21 entries, including the PowerShell profile and Python
   scripts). Fixed by the single-quoted here-string; tested (`backup-local` L02, L04).
3. **ESP-IDF archived twice** through the `esp-idf` junction; now excluded altogether.
4. **`win_restore.ps1` always used the newest archive,** whatever date was given: its
   parameter was named `$Input`, a PowerShell automatic variable. Renamed; tested
   (`restore-remote` R03).
5. **Restoring a folder reported false errors** (`Not found in archive`, tar exit 2) although
   the files were restored. Fixed with `--no-recursion`; any tar error during extraction now
   fails the command. Tested (`restore-remote` R06).

**State of the remote archives after the fix:** 2026-09-28 is complete and verified.
2026-08-31, 09-06, 09-13 and 09-16 were made by Windows' tar: without `Documents`, and
truncated inside `witrn` (08-31 and 09-16 checked); readable up to that point. Retention replaces one per weekly
run; if the runs succeed, all five are good after 2026-10-25. The 2026-08-25 archive was
trashed by retention on 2026-09-28 before anyone checked it.

---

## Restore

`win_restore.ps1` commands (`.\win_restore.ps1 help` for detail). All use GNU tar.

| Command | Action |
|---|---|
| `list` | Remote archives with size and date |
| `check <backup>` | Read the whole archive (`tar -tzf`); exit 1 if corrupt |
| `diff <b1> <b2>` | Files added/removed between two archives |
| `live <backup>` | Compare the archive with the files on disk (`tar --diff`) |
| `browse <backup> [filter]` | List archive contents |
| `get <backup>` | Download only |
| `restore full <backup>` | Extract everything over `%USERPROFILE%` (type `YES`) |
| `restore path <backup> <rel-path>` | Extract matching paths over `%USERPROFILE%` |
| `restore staging <backup> [filter]` | Extract to `%TEMP%\restore-staging` — changes nothing |
| `restore packages <backup> [-DryRun]` | Reinstall winget and pip packages from the archived lists; `-DryRun` shows what it found without asking or installing |

- `<backup>` is `latest`, a date (`2026-09-28`) or a full filename.
- Archives are downloaded to `%TEMP%` and reused by later commands until deleted.
- Filters and paths may use `\` or `/`; matching is on a substring of the archive path.
- `restore path` and `restore staging` extract with `--no-recursion` and the full list of
  matching entries; any tar error makes the command fail.
- `restore packages` finds the manifest inside the archive by matching
  `*.backup-manifest/<file>`, not a fixed folder name. The folder has changed three times
  (`proton-backup/`, `proton-windows-backup/`, now
  `DevSpace/z-repo/proton-drive/proton-windows-backup/`), and older archives keep the old name.

After a full restore on a rebuilt machine: `restore packages`, then reinstall the scheduled
task (RUNBOOK).

---

## Tests

`tests\Run-Tests.ps1 -Suite <name>` runs one suite and writes every step (command, exit code,
output, duration, PASS/FAIL/INFO/SKIP) to `tests\results\<suite>-<run>.json` and `.txt`.
Suites write only to their own temp folder, which is removed afterwards; environment changes
stay inside the runner's process. Suites that read Proton Drive need `-AllowRemote` and are
read-only; the one suite that runs a real backup (upload, retention) needs `-AllowUpload`.
Suites that need Administrator refuse to run without it. A run that is refused or
interrupted says so in its results file.

| Suite | Checks | Proton Drive |
|---|---|---|
| `archiver-round1` | GNU tar vs Windows tar on Chinese/Japanese/Korean/accented names | no |
| `archiver-round2` | Both tars on the real backup set; full GNU tar archive; font round trip | no |
| `archiver-round3` | Explains every file-list difference; lists junctions | no |
| `backup-local` | `win_backup.ps1 -ArchiveOnly`, manifest checks, archive contents | no |
| `restore-remote` | Scheduled-run result, then `list`, `check` (latest and by date), `browse`, `restore staging`, `restore packages -DryRun` | read-only; Administrator |
| `schedule-power` | Task definition read back; due/battery decisions (simulated); keep-awake request seen in `powercfg /requests` during a run and gone after; a not-due task run does nothing | no; Administrator |
| `scheduled-run` | Makes a backup due (`.last_success` set 8 days back), lets the task run it; request held, COMPLETE, `.last_success` renewed | **uploads** (`-AllowUpload`); Administrator |

Results files are local (gitignored); the figures that matter are recorded in this file and
in `../history/pz13-archive-integrity-2026-09.md`.

---

## Test Status (2026-09-28)

**Tested** means run on PZ13 with the current scripts, with the stated result. Run IDs refer
to `tests\results\` files on PZ13.

| Item | Status | Evidence |
|---|---|---|
| CLI `winget install`, user scope; `auth login` | Tested | manual |
| Backup via the scheduled task: GNU tar, verify, upload, retention | Tested — COMPLETE, 6,164 entries verified | log 18:20:36 and 18:29:57 runs; `restore-remote` R00 |
| Backup code path without upload (`-ArchiveOnly`) | Tested | `backup-local-20260928-180612` L01 |
| Exclude list literal; `espressif/sdks` excluded; no nested includes | Tested | `backup-local` L02, L03 |
| Archive contents: `Documents` present, ESP-IDF absent, CJK font present, no duplicates | Tested | `backup-local` L04; `restore-remote` R04, R05 |
| Step 0: "no upgrade" path | Tested | log 18:20:36 run |
| Step 0: upgrade 0.7.0 → 0.8.0 inside the scheduled task, `xware-ack` | Tested (Step 0 code unchanged since) | log 14:24:53 run |
| Manual rollback `winget install --version 0.7.0 --force` | Tested | manual |
| Retention: trash oldest + `empty-trash` | Tested (08-25 trashed, trash emptied) | log 14:05:59 |
| Same-day re-run replaces the archive (`-f replace`) | Tested | log, several runs on 2026-09-28 |
| `.last_success` written | Tested | `restore-remote` R00 |
| Registered task settings (hourly/logon/unlock, `-Scheduled`, battery, no wake, 12 h) | Tested (read back) | `schedule-power-20260928-214840` S01 |
| Due / battery decision: after Sunday 23:00 skip, just before run, never run, battery 30% skip, 50% and 80% run | Tested (simulated values) | `schedule-power` S02–S07 |
| Keep-awake request: listed under SYSTEM and EXECUTION in `powercfg /requests` during a run, gone after | Tested | `schedule-power` S09; `scheduled-run` T01 (inside the task) |
| Task run when not due: result 0 in 4 s, no log lines, `.last_success` unchanged | Tested | `schedule-power` S10 |
| Task run when due: `Scheduled run: RUN`, COMPLETE in 2.3 min, `.last_success` renewed | Tested (on AC) | `scheduled-run-20260928-215026` T01 |
| Battery skip inside a real task run; run on battery; catch-up after a night in standby; stale-tar cleanup | Not tested | needs battery below 50%, or a real Sunday night; next Sunday shows the catch-up |
| `#Requires -Version 7.0` refuses Windows PowerShell 5.1 | Tested (refused) | manual |
| GNU tar with Unicode names: create, list, extract, SHA-256 | Tested | `archiver-round1`, `archiver-round2` B06, `restore-remote` R06 |
| `restore`: `list`, `check latest`, `check <date>`, `browse`, `restore staging <filter>`, `restore packages -DryRun` | Tested | `restore-remote-20260928-185144`, 8/8 PASS |
| Verify step failure path (bad archive not uploaded) | Not tested | needs a failing tar |
| Pre-flight failure paths (auth failure, missing folder) | Not tested | needs an invalid token or missing folder |
| `restore path`, `restore full`, `restore staging` without a filter, `diff`, `live`, `get`; `restore packages` actually installing | Not tested with the current version | `restore path` / `restore full` overwrite files |
| `HEARTBEAT_URL` ping | Not tested | none configured |
| Log trimming at 500 lines | Not tested | code unchanged since July |
