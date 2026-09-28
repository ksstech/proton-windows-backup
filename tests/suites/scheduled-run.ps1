# =============================================================================
# scheduled-run -- a real backup started by the scheduled task because one is
# due: the -Scheduled decision says RUN, the keep-awake request is held inside
# the task, and the backup completes.
#
# WRITES TO PROTON DRIVE: a full backup run (upload of today's archive, which
# replaces a same-day archive; retention). Needs -AllowUpload. Administrator.
# To make a backup due, Setup sets .last_success to 8 days ago; the run
# rewrites it. If the run fails, Cleanup puts the original value back.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite scheduled-run -AllowUpload
# =============================================================================
@{
    Name           = 'scheduled-run'
    Description    = 'Scheduled task runs a due backup with the keep-awake request held (uploads)'
    RequiresAdmin  = $true
    RequiresRemote = $false
    RequiresUpload = $true

    Setup = {
        param($c)
        $c.LastOk = Join-Path $c.RepoDir '.last_success'
        $c.Log    = Join-Path $c.RepoDir 'win_backup.log'
        $c.Task   = 'Proton Drive - Win11 PZ13 Backup'
        $c.Reason = 'Proton Drive backup (win_backup.ps1)'
        $c.Sections = {
            $sec = ''; $found = @()
            foreach ($l in (& powercfg /requests 2>&1)) {
                $s = "$l".Trim()
                if ($s -match '^([A-Z]+):$') { $sec = $Matches[1]; continue }
                if ($s -like "*$($c.Reason)*") { $found += $sec }
            }
            @($found | Sort-Object -Unique)
        }
        if ((Get-ScheduledTask -TaskName $c.Task).State -eq 'Running') { throw 'The backup task is already running' }
        $c.Saved = if (Test-Path $c.LastOk) { (Get-Content $c.LastOk -Raw).Trim() } else { '' }
        $c.Fake  = (Get-Date).AddDays(-8).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-Content -Path $c.LastOk -Value $c.Fake -Encoding ascii -NoNewline
    }

    Tests = @(
        @{
            Id = 'T01'; Name = 'Task starts a due backup; keep-awake request held; COMPLETE; .last_success renewed'
            Note = 'A full backup through the task: about 3-5 minutes.'
            Run = {
                param($c)
                $start = Get-Date
                Start-ScheduledTask -TaskName $c.Task
                $seen = @(); $deadline = $start.AddSeconds(180)
                while (-not $seen -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 2
                    $seen = @(& $c.Sections)
                    if ((Get-ScheduledTask -TaskName $c.Task).State -ne 'Running' -and -not $seen) { break }
                }
                "request during run: $($seen -join ',')"
                $deadline = $start.AddMinutes(30)
                while ((Get-ScheduledTask -TaskName $c.Task).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
                $i = Get-ScheduledTaskInfo -TaskName $c.Task
                "state: $((Get-ScheduledTask -TaskName $c.Task).State)"
                "result: $($i.LastTaskResult)"
                "minutes: $([math]::Round(((Get-Date) - $start).TotalMinutes, 1))"
                "request after run: $((& $c.Sections) -join ',')"
                $ls = (Get-Content $c.LastOk -Raw).Trim()
                "last_success: $ls"
                $t = [datetime]::Parse($ls, [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
                "last_success renewed: $($t -ge $start.ToUniversalTime().AddSeconds(-5))"
                $stamp = $start.ToString('yyyy-MM-dd HH:mm:ss')
                Get-Content $c.Log |
                    Where-Object { $_ -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d' -and $_.Substring(0, 19) -ge $stamp } |
                    Where-Object { $_ -match 'Scheduled run|Keep-awake|Archive verified|Upload complete|Backup COMPLETE|\[ERR\]|\[WARN\]' } |
                    ForEach-Object { "log: $_" }
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if (-not ($Lines -match '^request during run: .*SYSTEM')) { $r += 'keep-awake request not seen during the run' }
                if ($Lines -notcontains 'result: 0')                     { $r += 'task result not 0' }
                if ($Lines -notcontains 'last_success renewed: True')    { $r += '.last_success not renewed' }
                if (-not ($Lines -match 'Scheduled run: RUN'))           { $r += 'log lacks "Scheduled run: RUN"' }
                if (-not ($Lines -match 'Backup COMPLETE'))              { $r += 'log lacks Backup COMPLETE' }
                if ($Lines -notcontains 'request after run: ')           { $r += 'request still present after the run' }
                if ($r) { $r -join '; ' }
            }
        }
    )

    Cleanup = {
        param($c)
        # Run failed before writing .last_success: put the original value back.
        if ((Test-Path $c.LastOk) -and (Get-Content $c.LastOk -Raw).Trim() -eq $c.Fake -and $c.Saved) {
            Set-Content -Path $c.LastOk -Value $c.Saved -Encoding ascii -NoNewline
        }
    }
}
