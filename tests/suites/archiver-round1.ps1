# =============================================================================
# archiver-round1 -- can GNU tar (Git for Windows) archive, list and extract
# filenames that Windows' own tar.exe 3.8.8 crashes on (Chinese, Japanese,
# Korean), and can Windows' tar read what GNU tar writes?
#
# Local only. Writes only under the run's work directory. Non-ASCII names are
# built from Unicode code points so this file stays pure ASCII.
# Run: pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite archiver-round1
# =============================================================================
@{
    Name           = 'archiver-round1'
    Description    = 'GNU tar vs Windows tar on non-ANSI filenames (local only)'
    RequiresAdmin  = $false
    RequiresRemote = $false

    Setup = {
        param($c)
        $c.GitUsrBin = 'C:\Program Files\Git\usr\bin'
        $c.GnuTar    = Join-Path $c.GitUsrBin 'tar.exe'
        $c.Gzip      = Join-Path $c.GitUsrBin 'gzip.exe'
        $c.MsysDll   = Join-Path $c.GitUsrBin 'msys-2.0.dll'
        $c.WinTar    = Join-Path $env:SystemRoot 'System32\tar.exe'
        foreach ($p in $c.GnuTar, $c.Gzip, $c.WinTar) {
            if (-not (Test-Path $p)) { throw "Not found: $p" }
        }

        # This pwsh process only: GNU tar finds gzip via PATH; UTF-8 output.
        $env:Path   = "$($c.GitUsrBin);$env:Path"
        $env:LANG   = 'C.UTF-8'
        $env:LC_ALL = 'C.UTF-8'
        [Console]::OutputEncoding = [Text.Encoding]::UTF8

        $str = { param([int[]]$cp) -join ($cp | ForEach-Object { [char]$_ }) }
        $c.Zi       = & $str 0x5B57                       # Chinese: character
        $c.Japanese = & $str 0x65E5, 0x672C, 0x8A9E       # Japanese: Japanese language
        $c.Korean   = & $str 0xD55C, 0xAD6D, 0xC5B4       # Korean: Korean language
        $c.Cafe     = & $str 0x63, 0x61, 0x66, 0xE9        # cafe with e-acute (ANSI-safe control)
        $c.SubDir   = & $str 0x5B50, 0x76EE, 0x5F55       # Chinese: subdirectory
        $c.Font     = & $str 0x601D, 0x6E90, 0x9ED1, 0x4F53   # the font name that crashed tar

        $c.Src    = Join-Path $c.WorkDir 'uni-test'
        $c.Out    = Join-Path $c.WorkDir 'uni-out'
        $c.Arc    = Join-Path $c.WorkDir 'uni-test.tar.gz'
        $c.WorkFs = $c.WorkDir -replace '\\', '/'
        $c.ArcFs  = $c.Arc     -replace '\\', '/'
        $c.OutFs  = $c.Out     -replace '\\', '/'

        $c.ExpectedEntries = @(
            'uni-test/'
            "uni-test/$($c.Zi).txt"
            "uni-test/$($c.Japanese).txt"
            "uni-test/$($c.Korean).txt"
            "uni-test/$($c.Cafe).txt"
            "uni-test/$($c.SubDir)/"
            "uni-test/$($c.SubDir)/$($c.Font).txt"
        )

        # PE header machine type of a binary: tells native ARM64 from emulated x64.
        $c.PeMachine = {
            param([string]$Path)
            $fs = [IO.File]::OpenRead($Path)
            try { $buf = New-Object byte[] 4096; [void]$fs.Read($buf, 0, 4096) } finally { $fs.Close() }
            $pe = [BitConverter]::ToInt32($buf, 0x3C)
            $m  = [BitConverter]::ToUInt16($buf, $pe + 4)
            switch ($m) { 0xAA64 { 'ARM64 (native)' } 0x8664 { 'x64 (emulated on ARM64)' } 0x014C { 'x86' } default { '0x{0:X4}' -f $m } }
        }
    }

    Tests = @(
        @{
            Id = 'A01'; Name = 'GNU tar present'; Critical = $true
            ExpectExit = 0; ExpectMatch = 'GNU tar'
            Run = { param($c) & $c.GnuTar --version }
        }
        @{
            Id = 'A02'; Name = 'gzip present'; Critical = $true
            ExpectExit = 0; ExpectMatch = 'gzip'
            Run = { param($c) & $c.Gzip --version }
        }
        @{
            Id = 'A03'; Name = 'Build architecture of GNU tar, gzip, msys runtime'; Info = $true
            Run = {
                param($c)
                foreach ($f in $c.GnuTar, $c.Gzip, $c.MsysDll) {
                    if (Test-Path $f) { '{0}: {1}' -f (Split-Path $f -Leaf), (& $c.PeMachine $f) }
                    else { '{0}: not found' -f (Split-Path $f -Leaf) }
                }
            }
        }
        @{
            Id = 'A04'; Name = 'Create test tree (5 files, CJK/Korean/Latin names, CJK subfolder)'; Critical = $true
            ExpectMatch = '^5$'
            Run = {
                param($c)
                New-Item -ItemType Directory -Path (Join-Path $c.Src $c.SubDir) -Force | Out-Null
                'a' | Set-Content (Join-Path $c.Src "$($c.Zi).txt")
                'b' | Set-Content (Join-Path $c.Src "$($c.Japanese).txt")
                'c' | Set-Content (Join-Path $c.Src "$($c.Korean).txt")
                'd' | Set-Content (Join-Path $c.Src "$($c.Cafe).txt")
                'e' | Set-Content (Join-Path (Join-Path $c.Src $c.SubDir) "$($c.Font).txt")
                "$((Get-ChildItem $c.Src -Recurse -File).Count)"
            }
        }
        @{
            Id = 'A05'; Name = 'GNU tar creates the archive'; Critical = $true
            ExpectExit = 0; ExpectNoOutput = $true
            Run = { param($c) & $c.GnuTar --force-local -czf $c.ArcFs -C $c.WorkFs 'uni-test' 2>&1 }
        }
        @{
            Id = 'A06'; Name = 'GNU tar lists all 7 entries with the correct names'
            ExpectExit = 0
            Run = { param($c) & $c.GnuTar --force-local -tzf $c.ArcFs 2>&1 }
            Check = {
                param($Lines, $Exit, $c)
                $d = Compare-Object @($c.ExpectedEntries) @($Lines)
                if ($d) { 'entries differ: ' + (($d | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' | ') }
            }
        }
        @{
            Id = 'A07'; Name = 'GNU tar extracts the archive'
            ExpectExit = 0; ExpectNoOutput = $true
            Run = {
                param($c)
                New-Item -ItemType Directory -Path $c.Out -Force | Out-Null
                & $c.GnuTar --force-local -xzf $c.ArcFs -C $c.OutFs 2>&1
            }
        }
        @{
            Id = 'A08'; Name = 'Extracted names identical to the originals'
            ExpectNoOutput = $true
            Run = {
                param($c)
                Compare-Object (Get-ChildItem $c.Src -Recurse -Name) (Get-ChildItem (Join-Path $c.Out 'uni-test') -Recurse -Name)
            }
        }
        @{
            Id = 'A09'; Name = 'Extracted contents identical (SHA-256)'
            ExpectNoOutput = $true
            Run = {
                param($c)
                $o = Join-Path $c.Out 'uni-test'
                $a = Get-ChildItem $c.Src -Recurse -File | ForEach-Object { $_.FullName.Substring($c.Src.Length) + ' ' + (Get-FileHash $_.FullName).Hash }
                $b = Get-ChildItem $o     -Recurse -File | ForEach-Object { $_.FullName.Substring($o.Length)     + ' ' + (Get-FileHash $_.FullName).Hash }
                Compare-Object @($a) @($b)
            }
        }
        @{
            Id = 'A10'; Name = 'Windows tar lists the GNU tar archive (does restore also need GNU tar?)'; Info = $true
            Run = { param($c) & $c.WinTar -tzf $c.Arc 2>&1 }
        }
        @{
            Id = 'A11'; Name = 'Windows tar archives the same tree (known defect: expect crash -1073741819)'; Info = $true
            ExpectExit = -1073741819
            Run = { param($c) & $c.WinTar -czf (Join-Path $c.WorkDir 'wintar.tar.gz') -C $c.WorkDir 'uni-test' 2>&1 }
        }
    )
}
