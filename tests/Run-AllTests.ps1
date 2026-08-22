#Requires -Version 7.0
<#
.SYNOPSIS
    Runs every AI_ORCHESTRA validator test suite: budget, scope, state, worktree, run, and worker.

.DESCRIPTION
    Dependency-free runner. Each *.Tests.ps1 file is executed in its own scope
    so the suites cannot contaminate one another.

    No AI calls, no network, no GitHub. Test fixtures are created under the
    system temp directory and removed afterwards; the repository is never
    written to.

.PARAMETER Filter
    Optional wildcard to select suites, e.g. -Filter '*Scope*'.

.NOTES
    Exit codes:
      0  all suites passed
      1  at least one assertion failed
      2  a suite could not be executed

.EXAMPLE
    pwsh -File tests\Run-AllTests.ps1
#>
[CmdletBinding()]
param([string] $Filter = '*')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ''
Write-Host 'AI_ORCHESTRA validator, worktree, and worker tests' -ForegroundColor White
Write-Host ("PowerShell {0} on {1}" -f $PSVersionTable.PSVersion, [System.Environment]::OSVersion.Platform)

$suites = @(Get-ChildItem -LiteralPath $here -Filter '*.Tests.ps1' -File |
            Where-Object { $_.Name -like $Filter } |
            Sort-Object Name)

if ($suites.Count -eq 0) {
    Write-Host "No test suites matched filter '$Filter'." -ForegroundColor Yellow
    exit 2
}

$totalFailures = 0
$broken        = 0

foreach ($suite in $suites) {
    try {
        $failures = & $suite.FullName
        $count    = @($failures)[-1]
        if ($null -eq $count) { $count = 0 }
        $totalFailures += [int]$count
    }
    catch {
        $broken++
        Write-Host ''
        Write-Host "  ERROR  $($suite.Name) could not be executed" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('=' * 60)
if ($broken -gt 0) {
    Write-Host "RESULT: $broken suite(s) failed to execute, $totalFailures assertion failure(s)." -ForegroundColor Red
    Write-Host ('=' * 60)
    exit 2
}
if ($totalFailures -gt 0) {
    Write-Host "RESULT: FAILED - $totalFailures assertion failure(s) across $($suites.Count) suite(s)." -ForegroundColor Red
    Write-Host ('=' * 60)
    exit 1
}
Write-Host "RESULT: PASSED - all $($suites.Count) suite(s) green." -ForegroundColor Green
Write-Host ('=' * 60)
exit 0
