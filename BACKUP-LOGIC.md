# Backup System Design and Logic

Design rationale for the RPi5-VH and PZ13 backup system.

---

## Design Goals

1. **Fully automated** -- runs weekly without user interaction
2. **Encrypted at rest** -- all data encrypted end-to-end in Proton Drive
3. **Recoverable without special tools** -- restore with standard tar; no proprietary backup format
4. **Self-contained** -- each platform's scripts, binary, logs, and manifests live in a single directory
5. **Cross-platform parity** -- Linux (RPi5) and Windows (PZ13) use the same upload mechanism, the same CLI tool, and the same remote folder structure

---

## Two-Script Architecture

Each platform uses two scripts that are always called in sequence:

```
[audit script]  -->  [backup script]
```

**Audit script** (`audit_backup.sh` / `win_audit.ps1`):
- Runs fresh every time, never caches
- Discovers what exists (home dir contents, custom additions, installed packages)
- Writes include.txt and exclude.txt to `.backup-manifest/`
- Exports package lists (apt/pip on Linux, winget/pip on Windows)
- Copies privileged config (Linux only: /etc/webmin via sudo)
- Reports what it found but makes no archive

**Backup script** (`rpi_backup.sh` / `win_backup.ps1`):
- Calls the audit script as its first step
- Reads include.txt and exclude.txt from `.backup-manifest/`
- Creates the archive
- Uploads to Proton Drive
- Manages retention (delete backups beyond KEEP_COUNT)
- Logs all output

The split exists so the audit can also be run independently for inspection without triggering an upload. It also keeps the backup script focused on the mechanics of upload and retention.

---

## Manifest Directory

Both platforms maintain a `.backup-manifest/` subdirectory within the backup directory:

```
Linux:   ~/proton-headless-backup/.backup-manifest/
Windows: ~\proton-windows-backup\.backup-manifest\
```

Auto-generated files (overwritten on every audit run):

| File | Contents |
|------|----------|
| include.txt | Paths fed directly to tar |
| include-etc.txt | Selected /etc/ paths (Linux only) |
| exclude.txt | Patterns passed to tar --exclude-from |
| packages.txt | apt-mark showmanual output (Linux) |
| pip-packages.txt | pip freeze output (both platforms) |
| winget-export.json | winget export output (Windows) |
| webmin-config/ | Sudo-copied /etc/webmin/ tree (Linux) |

User-managed files (never overwritten by audit):

| File | Purpose |
|------|---------|
| include-custom.txt | Extra paths to include; one per line; # comments OK |
| exclude-custom.txt | Extra exclusion patterns; one per line |

The manifest directory is included in the backup archive so it can be used during
restore. After a full restore, package lists are immediately available to reinstall
applications.

---

## Archive Format

### Linux (GNU tar with -P)

```bash
tar -czPf "$BACKUP_TMP" \
    --exclude-from "$EXCLUDE_FILE" \
    --files-from "$INCLUDE_FILE"
```

- `-P` preserves absolute paths (archive contains `/home/vh/...`, `/etc/...`)
- Restore: `sudo tar -xzPf archive.tar.gz`
- Files land at their exact original paths without needing to specify `-C`

### Windows (BSD tar with -C $HOME)

```powershell
$includePaths = Get-Content $includeFile | Where-Object { $_.Trim() -ne '' }
$tarArgs = @(
    '-czf', $BACKUP_TMP,
    '-C', $env:USERPROFILE,
    '--exclude-from', $excludeFile
) + @($includePaths)
tar @tarArgs
```

- `-C $USERPROFILE` means all paths in the archive are relative to home dir
  (e.g., `Documents/file.txt` instead of `C:\Users\andre\Documents\file.txt`)
- Include paths are passed directly as positional arguments, not via `-T`.
  BSD tar on Windows has a quirk where `-T` combined with `-C` generates an
  empty-path visit between archive entries, producing spurious
  `Couldn't visit directory: No such file or directory` errors.
- Restore: `tar -xzf archive.tar.gz -C $env:USERPROFILE`
- Avoids drive-letter issues; works even if the user profile path changes

BSD tar.exe ships with Windows 10 build 17063 and later (`C:\Windows\System32\tar.exe`).
No installation needed.

---

## Upload Mechanism

Both platforms use the proton-drive CLI v0.4.3 with the same upload command pattern:

```
proton-drive filesystem upload -f replace <local-archive> <remote-folder>
```

- `-f replace`: automatically overwrites if an identically-named file already exists
  in the remote folder. Prevents the interactive conflict prompt that would block
  scheduled/unattended runs.
- Same-day re-runs (e.g., if the Sunday job is re-triggered manually) work cleanly.

---

## Retention

Both platforms keep `KEEP_COUNT = 5` most recent backups.

After each upload:

1. List the remote folder using `--json` for clean output
2. Filter for files matching the archive name pattern
3. Sort by name (ISO date names sort chronologically)
4. If count > KEEP_COUNT, **trash** the oldest (count - KEEP_COUNT) archives, then run a
   single `filesystem empty-trash`

**`filesystem delete` does not work on active files** — it only permanently removes items
already in the trash ("You can permanently delete items only from trash. Trash your files
first."). The working retention mechanism on both platforms is therefore `filesystem trash
<path>` per archive, followed by one `filesystem empty-trash` after the loop. (`empty-trash`
empties the whole account trash — fine for a dedicated backup account.)

The `--json` flag on `filesystem list` returns a JSON array; this is parsed directly
(with `jq` on Linux, `ConvertFrom-Json` on Windows) rather than parsing human-readable
table output. This avoids fragile column-parsing that breaks on long filenames or
different terminal widths.

**Note:** In proton-drive CLI v0.4.3, the `name` field in the JSON output is a nested
object, not a plain string: `{"ok": true, "value": "filename.tar.gz"}`. Always access
the filename as `.name.value`. The size field is `totalStorageSize` (bytes) and
modification time is `modificationTime`.

---

## Heartbeat (dead-man's-switch)

After a successful run, both scripts write a UTC ISO-8601 timestamp to `.last_success` in
the backup directory, and optionally ping a `HEARTBEAT_URL` (taken from the environment or
a `HEARTBEAT_URL=...` line in a `.env` file in the directory). A missed or failed run
otherwise fails silently — the local timestamp (and the optional external ping) make a
silently missed week detectable in days instead of weeks.

---

## Credential Store and Session Isolation

The most common failure mode for automated backup tools: the credential store is
not accessible in the session where the backup runs.

### Linux: gnome-keyring and D-Bus

`proton-drive` on Linux stores the auth token via libsecret, which talks to
gnome-keyring over a D-Bus session bus. When `cron` runs a job, it launches a
minimal environment with no D-Bus session bus. The keyring is unreachable and
authentication fails silently.

**Fix in `rpi_backup.sh`:**

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
export GNOME_KEYRING_CONTROL="/run/user/$(id -u)/keyring"
```

These point libsecret at the socket files created when the user's graphical session
started (systemd user session). As long as the user is logged in when cron fires,
the socket exists and authentication works.

The WARNING messages that appear in the log:
```
WARNING ** : g_main_context_push_thread_default: already registered
```
are benign. They originate inside proton-drive's libsecret call (attempting to
replace an already-registered GLib main context). The backup completes successfully.

### Windows: Windows Credential Manager and Task Scheduler sessions

`proton-drive.exe` on Windows stores the auth token in Windows Credential Manager
(DPAPI-encrypted, per-user). Task Scheduler offers two logon types:

- **Batch logon** ("Run whether user is logged on or not"): creates an isolated
  Session 0 process. This session has its own Credential Manager vault, which is
  empty. Authentication fails because the stored token is in the interactive session's
  vault, not the batch session's vault.

- **Interactive logon** ("Run only when user is logged on"): runs in the user's
  interactive session. The Credential Manager vault is accessible. Authentication
  succeeds.

**Fix:** `win_backup.ps1 -InstallTask` uses `LogonType = Interactive` when creating
the scheduled task principal. The task only fires when the user is logged in, which
is always true on Sunday at 23:00 (the workstation is on, session exists even if
screen is locked).

---

## PowerShell Version

The Windows scripts use `#Requires -Version 5.1` for broad compatibility, but
**PowerShell 7 (`pwsh.exe`) must be installed** for the scheduled task to function.

### Why PS7 is required

The `-InstallTask` switch registers the task with `Execute = 'pwsh.exe'`. If PS7
is not installed, the scheduled task fails to start (the executable is not found).

### Why PS7 is preferred

| Aspect | PS 5.1 (Windows PowerShell) | PS 7 (PowerShell) |
|--------|----------------------------|-------------------|
| Runtime | .NET Framework 4.x | .NET 8+ |
| Binary | `powershell.exe` | `pwsh.exe` |
| Ships with Windows | Yes | No (separate install) |
| Development status | Maintenance-only | Active |
| Cross-platform | No | Yes (Win/Linux/macOS) |
| Ternary `? :` | No | Yes |
| Null-coalescing `??=` | No | Yes |
| Pipeline chains `&&` `\|\|` | No | Yes |
| `ForEach-Object -Parallel` | No | Yes |

Current scripts avoid PS7-only syntax for maximum compatibility, but `pwsh.exe` is
the explicit execution target for the scheduled task.

### Install PS7

```powershell
winget install Microsoft.PowerShell
```

Verify (in a new terminal):

```powershell
pwsh --version
```

PS7 coexists safely with PS5.1. Windows defaults to 5.1 for file associations and
right-click "Run with PowerShell". The scheduled task explicitly calls `pwsh.exe`.

### Encoding gotcha (PS5.1 and PS7)

PowerShell reads `.ps1` files using Windows-1252 encoding by default unless the file
has a UTF-8 BOM. Characters like Unicode checkmarks (U+2713 CHECK MARK = UTF-8 bytes
E2 9C 93) become garbled: byte 0x93 in Windows-1252 is `"` (left double quotation
mark), which PowerShell interprets as a string terminator, causing parse errors.

**All Windows scripts in this package use pure ASCII.** No Unicode, no box-drawing
characters, no emoji. Status indicators use `[OK]`, `[WARN]`, `[ERR]`. Table borders
use `+--...--+` and `|`. This avoids the encoding issue entirely.

---

## Restore Logic

Both restore scripts (`rpi_restore.sh`, `win_restore.ps1`) support the same
sub-commands:

| Command | Action |
|---------|--------|
| `list` | List available remote backups with sizes |
| `check <name>` | Test archive integrity (tar -tzf) without extracting |
| `live <name>` | Browse archive contents interactively |
| `restore staging <name>` | Extract to /tmp or %TEMP% for inspection (safe) |
| `restore path <name> <path>` | Extract a specific path from the archive |
| `restore full <name>` | Full restore to home directory (requires confirmation) |
| `help` | Show usage |

`latest` can be used as the archive name to automatically select the most recent
backup. The script fetches the remote listing, sorts by name, and picks the last entry.

### Archive-internal path format

Linux archives contain absolute paths (e.g., `/home/vh/.ssh/`). Restore of a
specific path uses:
```bash
tar -xzPf archive.tar.gz --wildcards --no-anchored "home/vh/.ssh*"
```

Windows archives contain home-relative paths (e.g., `.ssh\`). Restore of a specific
path uses:
```powershell
tar -xzf archive.tar.gz -C $env:USERPROFILE ".ssh"
```

---

## Schedule

Both platforms run the backup weekly on Sunday at 23:00.

| Platform | Mechanism | Configuration |
|----------|-----------|---------------|
| Linux (RPi5) | cron | `0 23 * * 0 /home/vh/proton-headless-backup/rpi_backup.sh` |
| Windows (PZ13) | Task Scheduler | `win_backup.ps1 -InstallTask` |

Sunday at 23:00 was chosen because:
- The workstation is typically on and the user is logged in (interactive session available)
- Low-activity period minimises impact on system resources
- Weekly frequency is appropriate for the data being backed up (configuration, code, documents)

---

## Remote Folder Structure

```
Proton Drive /my-files/
  RPi5-VH/                          <- Linux backups
    rpi5-vh-2026-06-01.tar.gz
    rpi5-vh-2026-06-08.tar.gz
    rpi5-vh-2026-06-15.tar.gz
    rpi5-vh-2026-06-22.tar.gz
    rpi5-vh-2026-06-29.tar.gz       <- 5 max; oldest removed on next run

  PZ13/                             <- Windows backups
    win11-pz13-2026-07-06.tar.gz
    ...
```

Archives are named with ISO dates so they sort chronologically both in the Proton
Drive web UI and when parsed by the scripts. Prefix includes the machine identifier
so multiple machines can coexist under `/my-files/` without collision.

---

## What Is and Is Not Backed Up

### Linux (RPi5)

**Included:**
- `/home/vh/` (entire user home, minus exclusions below)
- `/home/vh/proton-headless-backup/.backup-manifest/` (self-referential; restores cleanly)
- Selected `/etc/` paths: cron entries, sudoers, network interfaces, hostname, hosts,
  fstab, locale, timezone, ssh daemon config, apt sources
- `/etc/webmin/` via sudo copy into manifest dir

**Excluded (auto):**
- `.cache/`, `Cache/`, `CacheStorage/`
- `node_modules/`
- `.venv/`, `venv/`
- `__pycache__/`
- `/tmp/`
- `.git/objects/` (object store regenerable from remotes)

### Windows (PZ13)

**Included (selective from user home):**
- `.ssh/`, `.gnupg/`
- `Documents/`, `Desktop/`, `Downloads/`
- `AppData\Roaming\` (selective -- user config, not caches)
- `proton-windows-backup\.backup-manifest\` (self-referential)
- Custom paths from `include-custom.txt`

**Excluded (auto):**
- `AppData\Local\Temp\` and other AppData\Local caches
- `node_modules\`
- `.venv\`, `venv\`, `__pycache__\`
- `bin\Debug\`, `bin\Release\`, `obj\`, `build\`, `dist\`
- OneDrive synced folders (already in cloud)
- `Documents\My Videos`, `Documents\My Music`, `Documents\My Pictures`,
  `Documents\My Documents` -- Windows shell junction ReparsePoints that are
  circular symlinks; tar reports permission denied without these exclusions
- `Documents\$Temp` -- hidden scratch directory Windows creates in some
  configurations; causes `Couldn't visit directory` if not excluded

**Not attempted:**
- Windows Registry (cannot file-copy while OS is running)
- `C:\Windows\`, `Program Files` (reinstall from ISO / winget)
- AppData\Local in full (mostly machine-specific caches)

---

## Proton Drive CLI Flags Reference

| Flag | Purpose |
|------|---------|
| `filesystem list <path>` | List directory contents |
| `filesystem list <path> --json` | List as JSON array (name, size, etc.) |
| `filesystem upload <local> <remote>` | Upload file |
| `filesystem upload -f replace <local> <remote>` | Upload; overwrite if exists |
| `filesystem delete <path>` | Delete remote file or folder |
| `filesystem create-folder <parent> <name>` | Create remote folder |
| `auth login` | Interactive browser-based login |
| `auth status` | Check current auth status |
