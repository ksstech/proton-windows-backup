# =============================================================================
# archiver-round3 -- explain every difference between the file lists that
# Windows tar and GNU tar produce for the same backup set (round 2 found
# 35,157). Also lists every junction/symlink in the backup set, since
# Windows tar follows them and GNU tar stores them as links.
#
# Local only, read-only apart from its results. witrn is left out of the
# comparison (Windows tar crashes on a filename in it).
# Extra output: tests\results\archiver-round3-<run>-diff.txt (full diff)
#               tests\results\archiver-round3-<run>-links.txt (all links)
# Takes about 5-8 minutes.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite archiver-round3
# =============================================================================
@{
    Name           = 'archiver-round3'
    Description    = 'Explain Windows tar vs GNU tar file-list differences (local only)'
    RequiresAdmin  = $false
    RequiresRemote = $false

    Setup = {
        param($c)
        $c.GitUsrBin = 'C:\Program Files\Git\usr\bin'
        $c.GnuTar    = Join-Path $c.GitUsrBin 'tar.exe'
        $c.WinTar    = Join-Path $env:SystemRoot 'System32\tar.exe'
        $c.Include   = Join-Path $c.RepoDir '.backup-manifest\include.txt'
        $c.Exclude   = Join-Path $c.RepoDir '.backup-manifest\exclude.txt'
        foreach ($p in $c.GnuTar, $c.WinTar, $c.Include, $c.Exclude) {
            if (-not (Test-Path $p)) { throw "Not found: $p" }
        }
        $env:Path   = "$($c.GitUsrBin);$env:Path"
        $env:LANG   = 'C.UTF-8'
        $env:LC_ALL = 'C.UTF-8'
        [Console]::OutputEncoding = [Text.Encoding]::UTF8

        $c.Includes        = @(Get-Content $c.Include | Where-Object { $_.Trim() -ne '' })
        $c.IncludesNoWitrn = @($c.Includes | Where-Object { $_ -ne 'witrn' })
        $c.HomeFs    = $env:USERPROFILE -replace '\\', '/'
        $c.ExcludeFs = $c.Exclude       -replace '\\', '/'
        $c.Norm      = { param([string]$s) ($s -replace '^a ', '').TrimEnd('/') }
        # Group key: first N path components.
        $c.Key       = { param([string]$p, [int]$n) (($p -split '/') | Select-Object -First $n) -join '/' }
    }

    Tests = @(
        @{
            Id = 'C01'; Name = 'Junctions and symlinks inside the backup set'; Info = $true
            Run = {
                param($c)
                $links = foreach ($inc in $c.Includes) {
                    $root = Join-Path $env:USERPROFILE ($inc -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $root)) { continue }
                    $items = @(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)
                    $items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                        ForEach-Object { '{0} | {1} | {2}' -f $_.FullName.Substring($env:USERPROFILE.Length + 1), $_.LinkType, (@($_.Target) -join ';') }
                }
                $links = @($links | Sort-Object -Unique)
                $links | Set-Content -Path "$($c.ResultsBase)-links.txt" -Encoding utf8
                "links: $($links.Count)  (full list in $($c.ResultsBase)-links.txt)"
                $links | Select-Object -First 60
            }
        }
        @{
            Id = 'C02'; Name = 'Windows tar: file list without witrn'
            ExpectExit = @(0, 1)
            Run = {
                param($c)
                $raw = & $c.WinTar -cvf NUL -C $env:USERPROFILE --exclude-from $c.Exclude @($c.IncludesNoWitrn) 2>&1
                $rc  = $LASTEXITCODE
                $c.WinList = @($raw | Where-Object { "$_" -match '^a ' } | ForEach-Object { & $c.Norm "$_" })
                "entries: $($c.WinList.Count)"
                $raw | Where-Object { "$_" -notmatch '^a ' } | Select-Object -First 20 | ForEach-Object { "$_" }
                $global:LASTEXITCODE = $rc
            }
        }
        @{
            Id = 'C03'; Name = 'GNU tar: file list without witrn'
            ExpectExit = @(0, 1)
            Run = {
                param($c)
                $raw = & $c.GnuTar --force-local -cvf /dev/null -C $c.HomeFs "--exclude-from=$($c.ExcludeFs)" @($c.IncludesNoWitrn) 2>&1
                $rc  = $LASTEXITCODE
                $c.GnuList = @($raw | Where-Object { "$_" -notmatch '^tar: ' } | ForEach-Object { & $c.Norm "$_" })
                "entries: $($c.GnuList.Count)  (unique: $(@($c.GnuList | Sort-Object -Unique).Count))"
                $raw | Where-Object { "$_" -match '^tar: ' } | Select-Object -First 20 | ForEach-Object { "$_" }
                $global:LASTEXITCODE = $rc
            }
        }
        @{
            Id = 'C04'; Name = 'Differences grouped by folder (full diff saved to file)'; Info = $true
            Run = {
                param($c)
                if ($null -eq $c.WinList -or $null -eq $c.GnuList) { 'a list is missing'; return }
                $win = [Collections.Generic.HashSet[string]]::new([string[]]$c.WinList, [StringComparer]::OrdinalIgnoreCase)
                $gnu = [Collections.Generic.HashSet[string]]::new([string[]]$c.GnuList, [StringComparer]::OrdinalIgnoreCase)
                $onlyWin = @($win | Where-Object { -not $gnu.Contains($_) } | Sort-Object)
                $onlyGnu = @($gnu | Where-Object { -not $win.Contains($_) } | Sort-Object)
                $file = "$($c.ResultsBase)-diff.txt"
                @("# only in Windows tar list ($($onlyWin.Count))") + $onlyWin +
                @('', "# only in GNU tar list ($($onlyGnu.Count))") + $onlyGnu |
                    Set-Content -Path $file -Encoding utf8
                "only Windows tar: $($onlyWin.Count)   only GNU tar: $($onlyGnu.Count)   (full list: $file)"
                'Grouped (count, side, first 3 path components), largest first:'
                $groups = @($onlyWin | ForEach-Object { '<= ' + (& $c.Key $_ 3) }) + @($onlyGnu | ForEach-Object { '=> ' + (& $c.Key $_ 3) })
                $groups | Group-Object | Sort-Object Count -Descending | Select-Object -First 80 |
                    ForEach-Object { '{0,7} {1}' -f $_.Count, $_.Name }
            }
        }
    )
}
