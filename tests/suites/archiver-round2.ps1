# =============================================================================
# archiver-round2 -- GNU tar (Git for Windows) against the real backup set.
#   1. Does GNU tar select exactly the same files as Windows tar, given the
#      same include paths and exclude.txt? (witrn left out of this comparison,
#      because Windows tar crashes on a filename in it.)
#   2. Full archive with GNU tar, witrn included: time, exit code, re-read,
#      and the previously-crashing font extracted intact.
#   3. Can Windows tar read the full GNU tar archive? (recorded only)
#
# Local only: reads your files, writes only under the run's work directory
# (one ~3.3 GB archive), deleted at the end. Takes roughly 15-30 minutes.
# Uses the include.txt / exclude.txt left by the last backup run.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite archiver-round2
# =============================================================================
@{
    Name           = 'archiver-round2'
    Description    = 'GNU tar vs Windows tar on the real backup set (local only)'
    RequiresAdmin  = $false
    RequiresRemote = $false

    Setup = {
        param($c)
        $c.GitUsrBin = 'C:\Program Files\Git\usr\bin'
        $c.GnuTar    = Join-Path $c.GitUsrBin 'tar.exe'
        $c.WinTar    = Join-Path $env:SystemRoot 'System32\tar.exe'
        $c.Manifest  = Join-Path $c.RepoDir '.backup-manifest'
        $c.Include   = Join-Path $c.Manifest 'include.txt'
        $c.Exclude   = Join-Path $c.Manifest 'exclude.txt'
        foreach ($p in $c.GnuTar, $c.WinTar, $c.Include, $c.Exclude) {
            if (-not (Test-Path $p)) { throw "Not found: $p" }
        }

        # This pwsh process only.
        $env:Path   = "$($c.GitUsrBin);$env:Path"
        $env:LANG   = 'C.UTF-8'
        $env:LC_ALL = 'C.UTF-8'
        [Console]::OutputEncoding = [Text.Encoding]::UTF8

        $c.Includes        = @(Get-Content $c.Include | Where-Object { $_.Trim() -ne '' })
        $c.IncludesNoWitrn = @($c.Includes | Where-Object { $_ -ne 'witrn' })
        $c.HomeFs    = $env:USERPROFILE -replace '\\', '/'
        $c.ExcludeFs = $c.Exclude       -replace '\\', '/'
        $c.Arc       = Join-Path $c.WorkDir 'full.tar.gz'
        $c.ArcFs     = $c.Arc -replace '\\', '/'
        $c.Out       = Join-Path $c.WorkDir 'out'
        $c.OutFs     = $c.Out -replace '\\', '/'

        $str = { param([int[]]$cp) -join ($cp | ForEach-Object { [char]$_ }) }
        $c.FontMember = 'witrn/pcsoft/Fonts/' + (& $str 0x601D, 0x6E90, 0x9ED1, 0x4F53) + '.ttf'
        $c.FontSource = Join-Path $env:USERPROFILE ($c.FontMember -replace '/', '\')

        # Normalise a verbose/list line to "path" without a trailing slash.
        $c.Norm = { param([string]$s) ($s -replace '^a ', '').TrimEnd('/') }
    }

    Tests = @(
        @{
            Id = 'B00'; Name = 'At least 8 GB free on C:'; Critical = $true
            Run = { param($c) "$([math]::Floor((Get-PSDrive C).Free / 1GB))" }
            Check = { param($Lines, $Exit, $c) if ([int]$Lines[0] -lt 8) { "only $($Lines[0]) GB free" } }
        }
        @{
            Id = 'B01'; Name = 'Windows tar: file list of the backup set without witrn'
            ExpectExit = @(0, 1)
            Run = {
                param($c)
                $raw = & $c.WinTar -cvf NUL -C $env:USERPROFILE --exclude-from $c.Exclude @($c.IncludesNoWitrn) 2>&1
                $rc  = $LASTEXITCODE
                $msgs = @($raw | Where-Object { "$_" -notmatch '^a ' } | ForEach-Object { "$_" })
                $c.WinList = @($raw | Where-Object { "$_" -match '^a ' } | ForEach-Object { & $c.Norm "$_" })
                "entries: $($c.WinList.Count)"
                $msgs | Select-Object -First 40
                $global:LASTEXITCODE = $rc
            }
        }
        @{
            Id = 'B02'; Name = 'GNU tar: file list of the same set'
            ExpectExit = @(0, 1)
            Run = {
                param($c)
                $raw = & $c.GnuTar --force-local -cvf /dev/null -C $c.HomeFs "--exclude-from=$($c.ExcludeFs)" @($c.IncludesNoWitrn) 2>&1
                $rc  = $LASTEXITCODE
                $msgs = @($raw | Where-Object { "$_" -match '^tar: ' } | ForEach-Object { "$_" })
                $c.GnuList = @($raw | Where-Object { "$_" -notmatch '^tar: ' } | ForEach-Object { & $c.Norm "$_" })
                "entries: $($c.GnuList.Count)"
                $msgs | Select-Object -First 40
                $global:LASTEXITCODE = $rc
            }
        }
        @{
            Id = 'B03'; Name = 'Both tars select exactly the same entries'
            Run = {
                param($c)
                if ($null -eq $c.WinList -or $null -eq $c.GnuList) { 'a list is missing'; return }
                $d = @(Compare-Object @($c.WinList) @($c.GnuList))
                "differences: $($d.Count)  (<= only Windows tar, => only GNU tar)"
                $d | Select-Object -First 150 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
            }
            Check = { param($Lines, $Exit, $c) if ($Lines[0] -ne 'differences: 0  (<= only Windows tar, => only GNU tar)') { $Lines[0] } }
        }
        @{
            Id = 'B04'; Name = 'GNU tar: full archive including witrn (timed)'; Critical = $true
            ExpectExit = @(0, 1)
            Run = {
                param($c)
                # Capture everything first: piping a native command into
                # Select-Object -First can stop it early and truncate the archive.
                $raw = & $c.GnuTar --force-local -czf $c.ArcFs -C $c.HomeFs "--exclude-from=$($c.ExcludeFs)" @($c.Includes) 2>&1
                $rc  = $LASTEXITCODE
                $raw | Select-Object -First 40
                if (Test-Path $c.Arc) { "archive bytes: $((Get-Item $c.Arc).Length)" } else { 'archive not created' }
                $global:LASTEXITCODE = $rc
            }
        }
        @{
            Id = 'B05'; Name = 'GNU tar re-reads the full archive; font entry present'
            ExpectExit = 0
            Run = {
                param($c)
                $raw = & $c.GnuTar --force-local -tzf $c.ArcFs 2>&1
                $rc  = $LASTEXITCODE
                $c.FullList = @($raw | Where-Object { "$_" -notmatch '^tar: ' } | ForEach-Object { "$_" })
                "entries: $($c.FullList.Count)"
                "font entry present: $($c.FullList -contains $c.FontMember)"
                $raw | Where-Object { "$_" -match '^tar: ' } | Select-Object -First 20
                $global:LASTEXITCODE = $rc
            }
            Check = { param($Lines, $Exit, $c) if (-not ($Lines -contains 'font entry present: True')) { 'font entry not in archive' } }
        }
        @{
            Id = 'B06'; Name = 'GNU tar extracts the font; SHA-256 matches the original'
            ExpectExit = 0
            Run = {
                param($c)
                New-Item -ItemType Directory -Path $c.Out -Force | Out-Null
                & $c.GnuTar --force-local -xzf $c.ArcFs -C $c.OutFs $c.FontMember 2>&1
                $rc  = $LASTEXITCODE
                $got = Join-Path $c.Out ($c.FontMember -replace '/', '\')
                if (Test-Path -LiteralPath $got) {
                    "hash match: $((Get-FileHash -LiteralPath $got).Hash -eq (Get-FileHash -LiteralPath $c.FontSource).Hash)"
                } else { 'extracted file not found' }
                $global:LASTEXITCODE = $rc
            }
            Check = { param($Lines, $Exit, $c) if (-not ($Lines -contains 'hash match: True')) { 'font missing or hash differs' } }
        }
        @{
            Id = 'B07'; Name = 'Windows tar reads the full GNU tar archive'; Info = $true
            Run = {
                param($c)
                $raw = & $c.WinTar -tzf $c.Arc 2>&1
                $rc  = $LASTEXITCODE
                "entries: $(@($raw | Where-Object { "$_" -notmatch '^tar' }).Count)"
                $raw | Where-Object { "$_" -match '^tar' } | Select-Object -First 20
                $global:LASTEXITCODE = $rc
            }
        }
    )
}
