# Backup System Runbook

Exact commands for every operational scenario.

---

## Phase 1 -- First-Time Setup (RPi5)

### 1.1 Create directory and deploy scripts

```bash
mkdir -p ~/proton-headless-backup
# Copy audit_backup.sh, rpi_backup.sh, rpi_restore.sh into it
chmod +x ~/proton-headless-backup/audit_backup.sh \
          ~/proton-headless-backup/rpi_backup.sh \
          ~/proton-headless-backup/rpi_restore.sh
```

### 1.2 Download proton-drive CLI

```bash
curl -Lo ~/proton-headless-backup/proton-drive \
  https://proton.me/download/drive/cli/0.4.3/linux-arm64/proton-drive
chmod +x ~/proton-headless-backup/proton-drive
~/proton-headless-backup/proton-drive --version
```

### 1.3 Authenticate

```bash
~/proton-headless-backup/proton-drive auth login
~/proton-headless-backup/proton-drive filesystem list /
```

### 1.4 Create remote folder

```bash
~/proton-headless-backup/proton-drive filesystem create-folder /my-files RPi5-VH
```

### 1.5 Run manual test

```bash
~/proton-headless-backup/rpi_backup.sh
tail -50 ~/proton-headless-backup/rpi_backup.log
```

### 1.6 Install cron job

```bash
(crontab -l 2>/dev/null; echo "0 23 * * 0 /home/vh/proton-headless-backup/rpi_backup.sh") | crontab -
crontab -l
```

---

## Phase 2 -- Verify RPi Backup Running

```bash
# Check log for last run
tail -20 ~/proton-headless-backup/rpi_backup.log

# List remote backups
~/proton-headless-backup/proton-drive filesystem list /my-files/RPi5-VH

# Verify archive integrity
~/proton-headless-backup/rpi_restore.sh check latest
```

---

## Phase 3 -- RPi Routine Maintenance

```bash
# Add a new path to back up
echo "/home/vh/new-project" >> ~/proton-headless-backup/.backup-manifest/include-custom.txt

# Add an exclusion pattern
echo "*.iso" >> ~/proton-headless-backup/.backup-manifest/exclude-custom.txt

# Force manual backup
~/proton-headless-backup/rpi_backup.sh

# Preview what will be included (without running backup)
bash ~/proton-headless-backup/audit_backup.sh
cat ~/proton-headless-backup/.backup-manifest/include.txt

# What changed since last backup?
~/proton-headless-backup/rpi_restore.sh live latest
```

---

## Phase 4 -- RPi Restore

### 4.1 Assess

```bash
~/proton-headless-backup/rpi_restore.sh list
~/proton-headless-backup/rpi_restore.sh check latest
~/proton-headless-backup/rpi_restore.sh live  latest
```

### 4.2 Preview (safe -- nothing overwritten)

```bash
~/proton-headless-backup/rpi_restore.sh restore staging latest
ls /tmp/restore-staging/
```

### 4.3 Restore specific path

```bash
~/proton-headless-backup/rpi_restore.sh restore path latest /home/vh/.ssh
~/proton-headless-backup/rpi_restore.sh restore path latest /home/vh/ea_ps2342
```

### 4.4 Full restore (destructive)

```bash
~/proton-headless-backup/rpi_restore.sh restore full latest
# Type YES to confirm
```

### 4.5 Post-restore

```bash
# Reinstall apt packages
sudo apt-get install $(cat ~/proton-headless-backup/.backup-manifest/packages.txt | tr '\n' ' ')

# Reinstall pip packages
pip3 install -r ~/proton-headless-backup/.backup-manifest/pip-packages.txt

# Re-authenticate Proton Drive
~/proton-headless-backup/proton-drive auth login

# Reinstall cron job
(crontab -l 2>/dev/null; echo "0 23 * * 0 /home/vh/proton-headless-backup/rpi_backup.sh") | crontab -
```

---

## Phase 5 -- First-Time Setup (Windows PZ13)

### 5.1 Install PowerShell 7

PowerShell 7 is required. Windows ships with 5.1 but the scheduled task targets
pwsh.exe (PS7). Install once, it coexists safely with 5.1.

```powershell
winget install Microsoft.PowerShell
```

Open a new terminal and verify:

```powershell
pwsh --version   # should show 7.x.x
```

### 5.2 Create directory and set execution policy

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\proton-windows-backup" -Force
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 5.3 Download proton-drive.exe

Download from:
https://proton.me/download/drive/cli/0.4.3/windows-arm64/proton-drive.exe
Save to: C:\Users\<username>\proton-windows-backup\proton-drive.exe

```powershell
# Or from PowerShell:
Invoke-WebRequest `
  -Uri "https://proton.me/download/drive/cli/0.4.3/windows-arm64/proton-drive.exe" `
  -OutFile "$env:USERPROFILE\proton-windows-backup\proton-drive.exe"
```

### 5.4 Copy scripts

Copy win_audit.ps1, win_backup.ps1, win_restore.ps1 into ~\proton-windows-backup\

### 5.5 Authenticate

```powershell
cd ~\proton-windows-backup
.\proton-drive.exe auth login
.\proton-drive.exe filesystem list /
```

### 5.6 Create remote folder

```powershell
.\proton-drive.exe filesystem create-folder /my-files PZ13
```

### 5.7 Run manual test

```powershell
.\win_backup.ps1
```

### 5.8 Install scheduled task (requires Administrator once)

Open a PS7 Administrator terminal (required -- registration fails silently otherwise):

```powershell
# Option A: from any existing PowerShell window
Start-Process pwsh -Verb RunAs

# Option B: Start menu -> search "pwsh" -> right-click -> Run as Administrator
```

Then in the Administrator window:

```powershell
cd ~\proton-windows-backup
.\win_backup.ps1 -InstallTask
```

This creates the task with LogonType = Interactive -- required for Credential
Manager access. Do NOT change it to "Run whether user is logged on or not".

### 5.9 Verify task

```powershell
Get-ScheduledTask -TaskName 'Proton Drive - Win11 PZ13 Backup' | Select *
```

---

## Phase 6 -- Windows Routine Maintenance

```powershell
# Add a path to back up
Add-Content "$env:USERPROFILE\proton-windows-backup\.backup-manifest\include-custom.txt" "C:\MyProject"

# Add an exclusion pattern
Add-Content "$env:USERPROFILE\proton-windows-backup\.backup-manifest\exclude-custom.txt" "*.iso"

# Force manual backup
cd ~\proton-windows-backup
.\win_backup.ps1

# What changed since last backup?
.\win_restore.ps1 live latest

# View log
Get-Content ~\proton-windows-backup\win_backup.log | Select-Object -Last 100
```

---

## Phase 7 -- Windows Restore

### 7.1 Assess

```powershell
cd ~\proton-windows-backup
.\win_restore.ps1 list
.\win_restore.ps1 check latest
.\win_restore.ps1 live  latest
```

### 7.2 Preview (safe)

```powershell
.\win_restore.ps1 restore staging latest
Get-ChildItem $env:TEMP\restore-staging
```

### 7.3 Restore specific path

```powershell
.\win_restore.ps1 restore path latest .ssh
.\win_restore.ps1 restore path latest Documents\Projects
```

### 7.4 Full restore (destructive)

```powershell
.\win_restore.ps1 restore full latest
# Type YES to confirm
```

### 7.5 Post-restore

```powershell
# Reinstall applications
winget import -i ~\proton-windows-backup\.backup-manifest\winget-export.json --accept-source-agreements

# Reinstall pip packages
pip install -r ~\proton-windows-backup\.backup-manifest\pip-packages.txt

# Re-authenticate Proton Drive
~\proton-windows-backup\proton-drive.exe auth login

# Reinstall scheduled task (as Administrator)
~\proton-windows-backup\win_backup.ps1 -InstallTask
```

---

## Troubleshooting

### gnome-keyring WARNING (Linux)

```
WARNING ** : g_main_context_push_thread_default: already registered
```

Benign -- backup still completes. Root cause is inside proton-drive's libsecret
call. No action needed unless SolarWinds/PaperTrail is alerting on it, in which
case add an rsyslog discard rule.

### proton-drive cannot authenticate (Linux, cron)

```bash
# Verify D-Bus is running
ls /run/user/$(id -u)/bus

# If missing, manually export (already in rpi_backup.sh but useful for debugging)
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
export GNOME_KEYRING_CONTROL="/run/user/$(id -u)/keyring"
~/proton-headless-backup/proton-drive filesystem list /
```

### -InstallTask fails with "Access is denied"

`Register-ScheduledTask` requires Administrator. The script will report `[ERR]`
and exit. Open a PS7 Administrator terminal and retry:

```powershell
Start-Process pwsh -Verb RunAs
# In the new window:
cd ~\proton-windows-backup
.\win_backup.ps1 -InstallTask
```

### Windows backup task never ran

Check Task Scheduler history. Most likely cause: LogonType is Batch (Session 0).

```powershell
# Fix by reinstalling
cd ~\proton-windows-backup
.\win_backup.ps1 -RemoveTask
.\win_backup.ps1 -InstallTask   # run as Administrator (see above)
```

### PowerShell execution policy error

```
cannot be loaded because running scripts is disabled on this system
```

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### pwsh not found / PS7 not installed

```
The term 'pwsh' is not recognized
```

```powershell
winget install Microsoft.PowerShell
# Open new terminal, retry
```

### Upload fails mid-transfer (both platforms)

Archive stays in /tmp (Linux) or %TEMP% (Windows). Simply re-run the backup --
the -f replace flag overwrites the partial upload without prompting.

---

## Quick Reference

| Task | Linux | Windows |
|------|-------|---------|
| Run backup now | `~/proton-headless-backup/rpi_backup.sh` | `.\win_backup.ps1` |
| View log | `tail -100 ~/proton-headless-backup/rpi_backup.log` | `Get-Content ~\proton-windows-backup\win_backup.log -Tail 100` |
| List remote | `rpi_restore.sh list` | `.\win_restore.ps1 list` |
| Check archive | `rpi_restore.sh check latest` | `.\win_restore.ps1 check latest` |
| Full restore | `rpi_restore.sh restore full latest` | `.\win_restore.ps1 restore full latest` |
| Re-auth | `proton-drive auth login` | `.\proton-drive.exe auth login` |
| Cron/Task | `0 23 * * 0 .../rpi_backup.sh` | `win_backup.ps1 -InstallTask` |
