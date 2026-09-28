# =============================================================================
# Run-Tests.ps1 -- run one test suite, write the results to tests\results\
#
# USAGE (PowerShell 7; a normal window unless the suite says otherwise)
#   pwsh -NoProfile -File <repo>\tests\Run-Tests.ps1 -Suite <name> [-AllowRemote] [-AllowUpload] [-KeepWorkDir]
#
# A suite is tests\suites\<name>.ps1. It returns a hashtable:
#   Name, Description   text
#   RequiresAdmin       $true: refuse to run unless elevated
#   RequiresRemote      $true: refuse to run unless -AllowRemote is given.
#                       Remote access in a suite must be read-only (list/download).
#   RequiresUpload      $true: the suite runs a real backup (upload + retention);
#                       refuse to run unless -AllowUpload is given.
#   Setup   = { param($Ctx) ... }   optional; a failure skips every test
#   Tests   = @( @{
#       Id, Name
#       Run            = { param($Ctx) ... }   the commands under test
#       ExpectExit     int or int[]; omitted = exit code not checked
#       ExpectNoOutput $true: the test must produce no output lines
#       ExpectMatch    regex; at least one output line must match
#       Check          = { param($Lines, $ExitCode, $Ctx) ... }
#                        returns nothing when OK, or a failure reason string
#       Info           $true: record the result only, never PASS/FAIL
#       Critical       $true: if this test FAILs, skip the remaining tests
#     } ... )
#   Cleanup = { param($Ctx) ... }   optional; always runs
#
# SAFETY
#   Tests write only under $Ctx.WorkDir (%TEMP%\pwb-tests\<suite>-<run-id>),
#   deleted at the end unless -KeepWorkDir. Anything a suite changes in the
#   environment (PATH, console encoding) exists only inside this pwsh process.
#
# OUTPUT
#   tests\results\<suite>-<run-id>.json   every test: command text, exit code,
#                                         output, duration, result, reason
#   tests\results\<suite>-<run-id>.txt    one line per test, then the totals
#   This script's exit code = the number of FAILed tests.
# =============================================================================

#Requires -Version 7.0

param(
    [Parameter(Mandatory = $true)][string]$Suite,
    [switch]$AllowRemote,
    [switch]$AllowUpload,
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Continue'
$MaxLines = 200

$TestsDir   = $PSScriptRoot
$RepoDir    = Split-Path $TestsDir -Parent
$SuiteFile  = Join-Path $TestsDir "suites\$Suite.ps1"
$ResultsDir = Join-Path $TestsDir 'results'
$RunId      = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkDir    = Join-Path $env:TEMP "pwb-tests\$Suite-$RunId"
$JsonFile   = Join-Path $ResultsDir "$Suite-$RunId.json"
$TextFile   = Join-Path $ResultsDir "$Suite-$RunId.txt"

# Refusals before the run starts also leave a file, so the reason can be read
# without the console: tests\results\<suite>-<run-id>-refused.txt
function Stop-Run {
    param([string]$Message)
    Write-Host "  [ERR] $Message" -ForegroundColor Red
    try {
        New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
        "REFUSED $(Get-Date -Format s)  suite $Suite  run $RunId`n$Message" |
            Set-Content -Path (Join-Path $ResultsDir "$Suite-$RunId-refused.txt") -Encoding utf8
    } catch { }
    exit 1
}

if (-not (Test-Path $SuiteFile)) {
    $available = Get-ChildItem (Join-Path $TestsDir 'suites') -Filter *.ps1 -ErrorAction SilentlyContinue |
                 ForEach-Object BaseName
    Stop-Run "Suite not found: $SuiteFile. Available: $($available -join ', ')"
}

try {
    $def = & $SuiteFile
} catch {
    Stop-Run "Could not load suite ${Suite}: $_"
}
if (-not ($def -is [hashtable]) -or -not $def.Tests) {
    Stop-Run "Suite $Suite did not return a hashtable with Tests"
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($def.RequiresAdmin -and -not $isAdmin) { Stop-Run "Suite $Suite needs an Administrator PS7 window" }
if ($def.RequiresRemote -and -not $AllowRemote) { Stop-Run "Suite $Suite reads Proton Drive; add -AllowRemote" }
if ($def.RequiresUpload -and -not $AllowUpload) { Stop-Run "Suite $Suite runs a real backup (upload, retention); add -AllowUpload" }

New-Item -ItemType Directory -Path $WorkDir    -Force | Out-Null
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

$Ctx = @{
    WorkDir     = $WorkDir
    RepoDir     = $RepoDir
    RunId       = $RunId
    AllowRemote = [bool]$AllowRemote
    # For suites that save extra evidence next to the results
    # (e.g. a full diff): write to "$($Ctx.ResultsBase)-<what>.txt".
    ResultsBase = Join-Path $ResultsDir "$Suite-$RunId"
}

# -- Helpers -------------------------------------------------------------------

# Turn anything a test emits (strings, error records, objects) into text lines.
function ConvertTo-Lines {
    param($Items)
    $text = foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        if ($i -is [string]) { $i }
        elseif ($i -is [System.Management.Automation.ErrorRecord]) { "ERR: $($i.ToString())" }
        else { ($i | Out-String -Width 250).TrimEnd() }
    }
    @($text | ForEach-Object { $_ -split "`r?`n" } | Where-Object { $_ -match '\S' })
}

# Run a block with the context; capture output, the native exit code, any exception.
function Invoke-Block {
    param([scriptblock]$Block)
    $global:LASTEXITCODE = 0
    $err = $null
    $raw = @()
    try { $raw = & $Block $Ctx 2>&1 } catch { $err = $_ }
    @{ Lines = @(ConvertTo-Lines $raw); Exit = $global:LASTEXITCODE; Error = $err }
}

function Format-Result {
    param($Rec)
    $exitTxt = if ($null -ne $Rec.ExitCode) { "exit $($Rec.ExitCode), " } else { '' }
    $line = "[{0}] {1,-6} {2} ({3}{4} ms)" -f $Rec.Result, $Rec.Id, $Rec.Name, $exitTxt, $Rec.DurationMs
    if ($Rec.Reason) { $line += "`n         $($Rec.Reason)" }
    $line
}

function Show-Result {
    param($Rec)
    $color = switch ($Rec.Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'INFO' { 'Cyan' } default { 'Yellow' } }
    Write-Host ("  " + (Format-Result $Rec)) -ForegroundColor $color
}

# -- Run -------------------------------------------------------------------------

$results      = [System.Collections.Generic.List[object]]::new()
$setupLines   = @()
$cleanupLines = @()
$aborted      = $null
$started      = Get-Date

Write-Host ""
Write-Host "  Suite: $Suite -- $($def.Description)"
Write-Host "  Run:   $RunId   Elevated: $isAdmin   Work dir: $WorkDir"
Write-Host ""

$completed = $false
$current   = $null
try {
    if ($def.Setup) {
        $s = Invoke-Block $def.Setup
        $setupLines = $s.Lines
        if ($s.Error) { $aborted = "Setup failed: $($s.Error)" }
    }
    $skipRest = [bool]$aborted

    foreach ($t in $def.Tests) {
        $current = $t
        $rec = [ordered]@{
            Id              = $t.Id
            Name            = $t.Name
            Command         = $t.Run.ToString().Trim()
            ExitCode        = $null
            DurationMs      = 0
            Result          = ''
            Reason          = ''
            OutputLineCount = 0
            Output          = @()
        }

        if ($skipRest) {
            $rec.Result = 'SKIP'
            $rec.Reason = if ($aborted) { $aborted } else { 'skipped after a critical failure' }
            $results.Add([pscustomobject]$rec)
            Show-Result $rec
            continue
        }

        Write-Host ("  ...    {0,-6} {1}" -f $t.Id, $t.Name) -ForegroundColor DarkGray
        if ($t.Note) { Write-Host "         $($t.Note)" -ForegroundColor DarkGray }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r  = Invoke-Block $t.Run
        $sw.Stop()

        $lines = @($r.Lines)
        $rec.ExitCode        = $r.Exit
        $rec.DurationMs      = $sw.ElapsedMilliseconds
        $rec.OutputLineCount = $lines.Count
        $rec.Output = if ($lines.Count -gt $MaxLines) {
                          @($lines[0..($MaxLines - 1)]) + "... ($($lines.Count - $MaxLines) more lines)"
                      } else { $lines }

        $reasons = @()
        if ($r.Error) { $reasons += "exception: $($r.Error)" }
        if ($t.ContainsKey('ExpectExit') -and ($r.Exit -notin @($t.ExpectExit))) {
            $reasons += "exit $($r.Exit), expected $(@($t.ExpectExit) -join ' or ')"
        }
        if ($t.ExpectNoOutput -and $lines.Count -gt 0) {
            $reasons += "expected no output, got $($lines.Count) line(s)"
        }
        if ($t.ExpectMatch -and -not (@($lines) -match $t.ExpectMatch)) {
            $reasons += "no output line matches '$($t.ExpectMatch)'"
        }
        if ($t.Check) {
            try { $c = & $t.Check $lines $r.Exit $Ctx } catch { $c = "check error: $_" }
            if ($c) { $reasons += "$c" }
        }

        if ($t.Info) {
            $rec.Result = 'INFO'
            $rec.Reason = $reasons -join '; '
        } elseif ($reasons.Count -gt 0) {
            $rec.Result = 'FAIL'
            $rec.Reason = $reasons -join '; '
            if ($t.Critical) { $skipRest = $true }
        } else {
            $rec.Result = 'PASS'
        }
        $results.Add([pscustomobject]$rec)
        Show-Result $rec
    }
    $completed = $true
} finally {
    # Ctrl+C or an unexpected error leaves the loop early: say so in the results.
    if (-not $completed -and -not $aborted) {
        $aborted = if ($current) { "Run stopped during $($current.Id) ($($current.Name)) -- interrupted (Ctrl+C) or failed; later tests did not run" }
                   else { 'Run stopped before the first test' }
    }
    if ($def.Cleanup) {
        $cl = Invoke-Block $def.Cleanup
        $cleanupLines = $cl.Lines
    }
    if (-not $KeepWorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $summary = [ordered]@{
        Pass = @($results | Where-Object Result -eq 'PASS').Count
        Fail = @($results | Where-Object Result -eq 'FAIL').Count
        Info = @($results | Where-Object Result -eq 'INFO').Count
        Skip = @($results | Where-Object Result -eq 'SKIP').Count
    }
    $doc = [ordered]@{
        Suite         = $Suite
        Description   = $def.Description
        RunId         = $RunId
        Started       = $started.ToString('s')
        Finished      = (Get-Date).ToString('s')
        Computer      = $env:COMPUTERNAME
        User          = $env:USERNAME
        Elevated      = $isAdmin
        PSVersion     = $PSVersionTable.PSVersion.ToString()
        AllowRemote   = [bool]$AllowRemote
        WorkDir       = $WorkDir
        WorkDirKept   = [bool]$KeepWorkDir
        Aborted       = $aborted
        Summary       = $summary
        SetupOutput   = $setupLines
        Tests         = $results
        CleanupOutput = $cleanupLines
    }
    $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonFile -Encoding utf8

    $text = @("Suite $Suite  run $RunId  ($($started.ToString('s')))", "")
    $text += $results | ForEach-Object { Format-Result $_ }
    $text += ""
    $text += "PASS $($summary.Pass)  FAIL $($summary.Fail)  INFO $($summary.Info)  SKIP $($summary.Skip)"
    if ($aborted) { $text += "ABORTED: $aborted" }
    $text | Set-Content -Path $TextFile -Encoding utf8

    Write-Host ""
    Write-Host "  PASS $($summary.Pass)  FAIL $($summary.Fail)  INFO $($summary.Info)  SKIP $($summary.Skip)"
    if ($aborted) { Write-Host "  ABORTED: $aborted" -ForegroundColor Red }
    Write-Host "  Results: $JsonFile"
    Write-Host ""
}

exit $summary.Fail
