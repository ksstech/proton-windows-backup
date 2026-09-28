# =============================================================================
# restore-remote -- after a real backup: did the scheduled run succeed, and
# does win_restore.ps1 work against what is on Proton Drive?
#
# Proton Drive: read-only (list, download). Needs -AllowRemote.
# R00 waits (up to 60 min) for a running backup task to finish, so this suite
# can be started right after Start-ScheduledTask.
# Downloads the newest and oldest archives (up to ~3.5 GB total) to %TEMP%; extracts to
# %TEMP%\restore-staging. All removed in Cleanup. Nothing on the live system is
# changed: restore path / restore full are NOT run here (they overwrite files).
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite restore-remote -AllowRemote
# =============================================================================
@{
    Name           = 'restore-remote'
    Description    = 'Scheduled-run result, then win_restore.ps1 against Proton Drive (read-only)'
    # Administrator: R00 reads the state of a task registered with RunLevel Highest.
    RequiresAdmin  = $true
    RequiresRemote = $true

    Setup = {
        param($c)
        $c.Restore  = Join-Path $c.RepoDir 'win_restore.ps1'
        $c.LastOk   = Join-Path $c.RepoDir '.last_success'
        $c.Task     = 'Proton Drive - Win11 PZ13 Backup'
        $c.Proton   = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Proton.ProtonDrive.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\proton-drive.exe'
        $c.Staging  = Join-Path $env:TEMP 'restore-staging'
        [Console]::OutputEncoding = [Text.Encoding]::UTF8

        $str = { param([int[]]$cp) -join ($cp | ForEach-Object { [char]$_ }) }
        $c.FontRel    = 'witrn\pcsoft\Fonts\' + (& $str 0x601D, 0x6E90, 0x9ED1, 0x4F53) + '.ttf'
        $c.FontSource = Join-Path $env:USERPROFILE $c.FontRel
    }

    Tests = @(
        @{
            Id = 'R00'; Name = 'Scheduled backup finished with result 0, .last_success updated today'; Critical = $true
            Run = {
                param($c)
                $deadline = (Get-Date).AddMinutes(60)
                while ((Get-ScheduledTask -TaskName $c.Task).State -eq 'Running' -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 20
                }
                $i = Get-ScheduledTaskInfo -TaskName $c.Task
                "state: $((Get-ScheduledTask -TaskName $c.Task).State)"
                "last run: $($i.LastRunTime.ToString('s'))"
                "result: $($i.LastTaskResult)"
                $ls = if (Test-Path $c.LastOk) { Get-Content $c.LastOk } else { 'missing' }
                ".last_success: $ls"
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'result: 0') { $r += 'task result is not 0' }
                $today = (Get-Date).ToString('yyyy-MM-dd')
                if (-not ($Lines -like "last run: $today*")) { $r += 'task did not run today' }
                $ls = ($Lines | Where-Object { $_ -like '.last_success:*' }) -replace '^\.last_success: ', ''
                try {
                    $t = [datetime]::Parse($ls, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
                    if (((Get-Date).ToUniversalTime() - $t).TotalHours -gt 12) { $r += ".last_success older than 12 h ($ls)" }
                } catch { $r += ".last_success unreadable ($ls)" }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'R01'; Name = 'list'
            ExpectExit = 0; ExpectMatch = 'backup\(s\) stored'
            Run = {
                param($c)
                # Work out newest and oldest archive names for the next tests,
                # and make sure no stale local copy is reused instead of a download.
                $items = & $c.Proton filesystem list /my-files/PZ13 --json 2>$null | ConvertFrom-Json
                $names = @($items | Where-Object { $_.name.value -like 'win11-pz13-*.tar.gz' } | ForEach-Object { $_.name.value } | Sort-Object)
                $c.Newest = $names[-1]
                $c.Oldest = $names[0]
                foreach ($n in $c.Newest, $c.Oldest) {
                    $p = Join-Path $env:TEMP $n
                    if (Test-Path $p) { Remove-Item $p -Force }
                }
                & pwsh -NoProfile -File $c.Restore list 2>&1
            }
        }
        @{
            Id = 'R02'; Name = 'check latest: downloads and reads the newest archive intact'
            Note = 'Downloads the newest archive first -- no output for a minute or more.'
            ExpectExit = 0; ExpectMatch = 'Archive is intact'
            Run = { param($c) & pwsh -NoProfile -File $c.Restore check latest 2>&1 }
            Check = { param($Lines, $Exit, $c) if (-not ($Lines -match [regex]::Escape($c.Newest))) { "header does not name $($c.Newest)" } }
        }
        @{
            Id = 'R03'; Name = 'check <oldest date>: the named archive is the one checked (not the newest)'
            Note = 'Downloads the oldest archive (about 3 GB) -- no output for several minutes. Do not stop it.'
            Run = {
                param($c)
                $date = $c.Oldest -replace '^win11-pz13-', '' -replace '\.tar\.gz$', ''
                "requested: $date"
                & pwsh -NoProfile -File $c.Restore check $date 2>&1
            }
            Check = {
                param($Lines, $Exit, $c)
                if (-not ($Lines -match "Integrity Check -- $([regex]::Escape($c.Oldest))")) { "did not check $($c.Oldest)" }
            }
        }
        @{
            Id = 'R04'; Name = 'browse latest Documents/Python: Documents is in the newest archive'
            ExpectExit = 0; ExpectMatch = 'Documents/Python/'
            Run = { param($c) & pwsh -NoProfile -File $c.Restore browse latest 'Documents/Python' 2>&1 }
        }
        @{
            Id = 'R05'; Name = 'browse latest espressif/sdks: excluded, 0 entries'
            ExpectExit = 0; ExpectMatch = '\b0 matching entries'
            Run = { param($c) & pwsh -NoProfile -File $c.Restore browse latest 'espressif/sdks' 2>&1 }
        }
        @{
            Id = 'R06'; Name = 'restore staging latest pcsoft/Fonts: CJK-named font restored with identical SHA-256'
            ExpectExit = 0
            Run = {
                param($c)
                & pwsh -NoProfile -File $c.Restore restore staging latest 'pcsoft/Fonts' 2>&1
                $staged = Join-Path $c.Staging $c.FontRel
                if (Test-Path -LiteralPath $staged) {
                    "hash match: $((Get-FileHash -LiteralPath $staged).Hash -eq (Get-FileHash -LiteralPath $c.FontSource).Hash)"
                } else { 'staged font not found' }
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'hash match: True') { $r += 'CJK font missing from staging or hash differs' }
                $bad = @($Lines | Where-Object { $_ -match 'Not found in archive|tar exit|\[ERR\]|/usr/bin/tar: ' })
                if ($bad.Count) { $r += "tar reported errors: $($bad[0])" }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'R07'; Name = 'restore packages latest -DryRun: finds winget and pip lists in the archive'
            ExpectExit = 0
            Run = { param($c) & pwsh -NoProfile -File $c.Restore restore packages latest -DryRun 2>&1 }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if (-not ($Lines -match 'winget export found \(.*\.backup-manifest/winget-export\.json\)')) { $r += 'winget-export.json not found' }
                if (-not ($Lines -match 'pip-packages\.txt found'))                                       { $r += 'pip-packages.txt not found' }
                if ($r) { $r -join '; ' }
            }
        }
    )

    Cleanup = {
        param($c)
        foreach ($n in $c.Newest, $c.Oldest) {
            if ($n) { $p = Join-Path $env:TEMP $n; if (Test-Path $p) { Remove-Item $p -Force } }
        }
        if (Test-Path $c.Staging) { Remove-Item $c.Staging -Recurse -Force }
    }
}
