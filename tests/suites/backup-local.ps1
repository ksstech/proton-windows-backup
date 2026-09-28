# =============================================================================
# backup-local -- the real backup code path, minus Proton Drive:
#   win_backup.ps1 -ArchiveOnly = audit + GNU tar archive + verify, then stop.
# Then checks the generated manifest and the archive contents.
#
# No Proton Drive access, no upload, no retention, no .last_success.
# Side effects: regenerates .backup-manifest\ (as every backup run does) and
# appends to win_backup.log. The archive (%TEMP%\win11-pz13-<date>.tar.gz,
# ~3 GB) is deleted in Cleanup. Takes roughly 5-10 minutes.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite backup-local
# =============================================================================
@{
    Name           = 'backup-local'
    Description    = 'win_backup.ps1 -ArchiveOnly, then manifest and archive checks (no Proton Drive)'
    RequiresAdmin  = $false
    RequiresRemote = $false

    Setup = {
        param($c)
        $c.Backup    = Join-Path $c.RepoDir 'win_backup.ps1'
        $c.Include   = Join-Path $c.RepoDir '.backup-manifest\include.txt'
        $c.Exclude   = Join-Path $c.RepoDir '.backup-manifest\exclude.txt'
        $c.GnuTar    = 'C:\Program Files\Git\usr\bin\tar.exe'
        if (-not (Test-Path $c.GnuTar)) { throw "Not found: $($c.GnuTar)" }
        $env:Path   = "C:\Program Files\Git\usr\bin;$env:Path"
        $env:LANG   = 'C.UTF-8'
        $env:LC_ALL = 'C.UTF-8'
        [Console]::OutputEncoding = [Text.Encoding]::UTF8

        $c.Archive   = Join-Path $env:TEMP ('win11-pz13-{0}.tar.gz' -f (Get-Date -Format 'yyyy-MM-dd'))
        $c.ArchiveFs = $c.Archive -replace '\\', '/'
        if (Test-Path $c.Archive) { Remove-Item $c.Archive -Force }

        $str = { param([int[]]$cp) -join ($cp | ForEach-Object { [char]$_ }) }
        $c.FontMember = 'witrn/pcsoft/Fonts/' + (& $str 0x601D, 0x6E90, 0x9ED1, 0x4F53) + '.ttf'
    }

    Tests = @(
        @{
            Id = 'L01'; Name = 'win_backup.ps1 -ArchiveOnly: audit, archive, verify'; Critical = $true
            ExpectExit = 0; ExpectMatch = 'Archive verified: \d+ entries'
            Run = { param($c) & pwsh -NoProfile -File $c.Backup -ArchiveOnly 2>&1 }
        }
        @{
            Id = 'L02'; Name = 'exclude.txt written literally (Documents/$Temp, $RECYCLE.BIN) and has espressif/sdks'
            Run = { param($c) Get-Content $c.Exclude }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'Documents/$Temp') { $r += 'missing literal Documents/$Temp' }
                if ($Lines -contains 'Documents/')         { $r += 'bare Documents/ present (excludes all of Documents)' }
                if ($Lines -notcontains '$RECYCLE.BIN')    { $r += 'missing literal $RECYCLE.BIN' }
                if ($Lines -notcontains 'espressif/sdks')  { $r += 'missing espressif/sdks (from exclude-custom.txt)' }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'L03'; Name = 'include.txt: Documents present, no path inside another'
            Run = { param($c) Get-Content $c.Include }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'Documents') { $r += 'Documents not in include.txt' }
                foreach ($p in $Lines) {
                    $parent = $Lines | Where-Object { $_ -ne $p -and $p.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                    if ($parent) { $r += "$p is inside $parent" }
                }
                if ($r) { $r -join '; ' }
            }
        }
        @{
            Id = 'L04'; Name = 'Archive: Documents in, espressif/sdks out, CJK font in, no duplicate entries'
            ExpectExit = 0
            Run = {
                param($c)
                $raw  = & $c.GnuTar --force-local -tzf $c.ArchiveFs 2>&1
                $rc   = $LASTEXITCODE
                $list = @($raw | Where-Object { "$_" -notmatch '^tar: ' } | ForEach-Object { "$_" })
                "entries: $($list.Count)"
                "duplicates: $($list.Count - @($list | Sort-Object -Unique).Count)"
                "Documents entries: $(@($list | Where-Object { $_ -like 'Documents/*' }).Count)"
                "espressif/sdks entries: $(@($list | Where-Object { $_ -like 'espressif/sdks*' }).Count)"
                "font present: $($list -contains $c.FontMember)"
                "powershell profile present: $(@($list | Where-Object { $_ -like 'Documents/PowerShell/*profile*' }).Count -gt 0)"
                $raw | Where-Object { "$_" -match '^tar: ' } | Select-Object -First 20 | ForEach-Object { "$_" }
                $global:LASTEXITCODE = $rc
            }
            Check = {
                param($Lines, $Exit, $c)
                $r = @()
                if ($Lines -notcontains 'duplicates: 0')                { $r += 'duplicate entries' }
                if ($Lines -contains 'Documents entries: 0')           { $r += 'no Documents entries' }
                if ($Lines -notcontains 'espressif/sdks entries: 0')   { $r += 'espressif/sdks entries present' }
                if ($Lines -notcontains 'font present: True')          { $r += 'CJK font missing' }
                if ($Lines -notcontains 'powershell profile present: True') { $r += 'PowerShell profile missing' }
                if ($r) { $r -join '; ' }
            }
        }
    )

    Cleanup = {
        param($c)
        if ($c.Archive -and (Test-Path $c.Archive)) { Remove-Item $c.Archive -Force }
    }
}
