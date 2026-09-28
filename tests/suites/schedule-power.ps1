# =============================================================================
# schedule-power -- the scheduled task definition, the "due / power" decision,
# the keep-awake power request, and a scheduled run that is not due.
#
# No Proton Drive access. Administrator: powercfg /requests and reading the
# task need it.
# Side effects: S09 runs win_backup.ps1 -ArchiveOnly (regenerates
# .backup-manifest\, appends to win_backup.log; the archive is deleted in
# Cleanup). S10 starts the scheduled task once; with a backup already done
# since Sunday 23:00 it must exit at once without doing anything.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite schedule-power
# =============================================================================
@{
    Name           = 'schedule-power'
    Description    = 'Task definition, due/power decision, keep-awake request, not-due scheduled run'
    RequiresAdmin  = $true
    RequiresRemote = $false

    Setup = {
        param($c)
        $c.Backup  = Join-Path $c.RepoDir 'win_backup.ps1'
        $c.LastOk  = Join-Path $c.RepoDir '.last_success'
        $c.Log     = Join-Path $c.RepoDir 'win_backup.log'
        $c.Task    = 'Proton Drive - Win11 PZ13 Backup'
        $c.Archive = Join-Path $env:TEMP ('win11-pz13-{0}.tar.gz' -f (Get-Date -Format 'yyyy-MM-dd'))
        $c.Reason  = 'Proton Drive backup (win_backup.ps1)'

        # Same rule as win_backup.ps1: most recent Sunday 23:00 not in the future
        $now = Get-Date
        $d = $now.Date.AddDays(-[int]$now.DayOfWeek).AddHours(23)
        if ($d -gt $now) { $d = $d.AddDays(-7) }
        $iso = { param([datetime]$t) $t.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $c.DueSince  = $d
        $c.BeforeDue = & $iso $d.AddMinutes(-1)
        $c.AfterDue  = & $iso $d.AddMinutes(1)
        $c.Old       = & $iso $now.AddDays(-8)
        $c.Recent    = & $iso $now

        # Sections of `powercfg /requests` (SYSTEM, EXECUTION, ...) that list our request
        $c.Sections = {
            $sec = ''; $found = @()
            foreach ($l in (& powercfg /requests 2>&1)) {
                $s = "$l".Trim()
                if ($s -match '^([A-Z]+):$') { $sec = $Matches[1]; continue }
                if ($s -like "*$($c.Reason)*") { $found += $sec }
            }
            @($found | Sort-Object -Unique)
        }
        if (-not (Get-ScheduledTask -TaskName $c.Task -ErrorAction SilentlyContinue)) { throw "Task not found: $($c.Task)" }
    }

    Tests = @(
        @{
            Id = 'S01'; Name = 'Task: -Scheduled, hourly + logon + unlock triggers, battery/wake/limit settings'
            Run = {
                param($c)
                $t = Get-ScheduledTask -TaskName $c.Task
                "action: $($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
                foreach ($tr in $t.Triggers) {
                    $n = $tr.CimClass.CimClassName
                    $extra = switch ($n) {
                        'MSFT_TaskTimeTrigger'               { "interval=$($tr.Repetition.Interval) duration=$($tr.Repetition.Duration)" }
                        'MSFT_TaskSessionStateChangeTrigger' { "state=$($tr.StateChange)" }
                        default                              { '' }
                    }
                    "trigger: $n $extra enabled=$($tr.Enabled)"
                }
                $s = $t.Settings
                "WakeToRun=$($s.WakeToRun)"
                "DisallowStartIfOnBatteries=$($s.DisallowStartIfOnBatteries)"
                "StopIfGoingOnBatteries=$($s.StopIfGoingOnBatteries)"
                "StartWhenAvailable=$($s.StartWhenAvailable)"
                "RunOnlyIfNetworkAvailable=$($s.RunOnlyIfNetworkAvailable)"
                "ExecutionTimeLimit=$($s.ExecutionTimeLimit)"
                "MultipleInstances=$($s.MultipleInstances)"
                "LogonType=$($t.Principal.LogonType)"
                "RunLevel=$($t.Principal.RunLevel)"
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if (-not ($Lines -match '^action: .*win_backup\.ps1" -Scheduled$'))                  { $r += 'action lacks -Scheduled' }
                if (-not ($Lines -match '^trigger: MSFT_TaskTimeTrigger interval=PT1H .*enabled=True')) { $r += 'no hourly trigger' }
                if (-not ($Lines -match '^trigger: MSFT_TaskLogonTrigger .*enabled=True'))            { $r += 'no logon trigger' }
                if (-not ($Lines -match '^trigger: MSFT_TaskSessionStateChangeTrigger state=8 enabled=True')) { $r += 'no unlock trigger' }
                if (@($Lines -match '^trigger: ').Count -ne 3)                                        { $r += 'expected exactly 3 triggers' }
                foreach ($want in 'WakeToRun=False', 'DisallowStartIfOnBatteries=False', 'StopIfGoingOnBatteries=False',
                                  'StartWhenAvailable=True', 'RunOnlyIfNetworkAvailable=True', 'ExecutionTimeLimit=PT12H',
                                  'MultipleInstances=IgnoreNew', 'LogonType=Interactive', 'RunLevel=Highest') {
                    if ($Lines -notcontains $want) { $r += "not $want" }
                }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'S02'; Name = 'Decision: backup done after Sunday 23:00 -> SKIP not due'
            ExpectExit = 0; ExpectMatch = '^Decision: SKIP not due'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess $c.AfterDue -SimulatePower AC 2>&1 }
        }
        @{
            Id = 'S03'; Name = 'Decision: last backup just before Sunday 23:00, on AC -> RUN'
            ExpectExit = 0; ExpectMatch = '^Decision: RUN'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess $c.BeforeDue -SimulatePower AC 2>&1 }
        }
        @{
            Id = 'S04'; Name = 'Decision: due, battery 30% -> SKIP battery'
            ExpectExit = 0; ExpectMatch = '^Decision: SKIP battery below 50%'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess $c.Old -SimulatePower 30 2>&1 }
        }
        @{
            Id = 'S05'; Name = 'Decision: due, battery 50% -> RUN'
            ExpectExit = 0; ExpectMatch = '^Decision: RUN'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess $c.Old -SimulatePower 50 2>&1 }
        }
        @{
            Id = 'S06'; Name = 'Decision: due, battery 80% -> RUN'
            ExpectExit = 0; ExpectMatch = '^Decision: RUN'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess $c.Old -SimulatePower 80 2>&1 }
        }
        @{
            Id = 'S07'; Name = 'Decision: never backed up, on AC -> RUN'
            ExpectExit = 0; ExpectMatch = '^Decision: RUN: last success never'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly -SimulateLastSuccess ' ' -SimulatePower AC 2>&1 }
        }
        @{
            Id = 'S08'; Name = 'Decision with the real .last_success and real power state (record only)'
            Info = $true
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -DecisionOnly 2>&1 }
        }
        @{
            Id = 'S09'; Name = 'Keep-awake: request listed by powercfg while a run is active, gone after'
            Note = 'Runs win_backup.ps1 -ArchiveOnly (about 1 minute) and watches powercfg /requests.'
            Run = {
                param($c)
                "before: $((& $c.Sections) -join ',')"
                $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "`"$($c.Backup)`"", '-ArchiveOnly') -WindowStyle Hidden -PassThru
                $seen = @(); $deadline = (Get-Date).AddSeconds(120)
                while (-not $p.HasExited -and (Get-Date) -lt $deadline -and -not $seen) {
                    Start-Sleep -Seconds 2
                    $seen = @(& $c.Sections)
                }
                "during: $($seen -join ',')"
                if (-not $p.WaitForExit(1800000)) { 'backup did not finish within 30 minutes'; $p.Kill() }
                "backup exit: $($p.ExitCode)"
                Start-Sleep -Seconds 2
                "after: $((& $c.Sections) -join ',')"
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'before: ')          { $r += 'request already present before the run' }
                if (-not ($Lines -match '^during: .*SYSTEM')) { $r += 'SYSTEM request not seen during the run' }
                if ($Lines -notcontains 'backup exit: 0')    { $r += 'backup -ArchiveOnly did not exit 0' }
                if ($Lines -notcontains 'after: ')           { $r += 'request still present after the run' }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'S10'; Name = 'Scheduled task, not due: exits at once, result 0, no log lines, .last_success unchanged'
            Run = {
                param($c)
                $lsBefore = (Get-Content $c.LastOk -Raw).Trim()
                "last_success: $lsBefore"
                $start = Get-Date
                Start-ScheduledTask -TaskName $c.Task
                Start-Sleep -Seconds 3
                $deadline = $start.AddMinutes(3)
                while ((Get-ScheduledTask -TaskName $c.Task).State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
                $i = Get-ScheduledTaskInfo -TaskName $c.Task
                "state: $((Get-ScheduledTask -TaskName $c.Task).State)"
                "result: $($i.LastTaskResult)"
                "ran after start: $($i.LastRunTime -ge $start.AddSeconds(-2))"
                "seconds: $([int]((Get-Date) - $start).TotalSeconds)"
                "last_success unchanged: $((Get-Content $c.LastOk -Raw).Trim() -eq $lsBefore)"
                $stamp = $start.ToString('yyyy-MM-dd HH:mm:ss')
                "new log lines: $(@(Get-Content $c.Log | Where-Object { $_ -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d' -and $_.Substring(0, 19) -ge $stamp }).Count)"
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'result: 0')                    { $r += 'task result not 0' }
                if ($Lines -notcontains 'ran after start: True')        { $r += 'task did not run' }
                if ($Lines -notcontains 'last_success unchanged: True') { $r += '.last_success changed' }
                if ($Lines -notcontains 'new log lines: 0')             { $r += 'a not-due run wrote to the log' }
                if ($r) { $r -join '; ' }
            }
        }
    )

    Cleanup = {
        param($c)
        if ($c.Archive -and (Test-Path $c.Archive)) { Remove-Item $c.Archive -Force }
    }
}
