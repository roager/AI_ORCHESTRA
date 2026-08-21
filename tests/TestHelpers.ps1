#Requires -Version 7.0
<#
.SYNOPSIS
    Minimal assertion harness for AI_ORCHESTRA validator tests.

.DESCRIPTION
    Deliberately dependency-free: no Pester, no external modules, per the
    MVP constraint. Dot-source this file, call Assert-* helpers, then call
    Get-TestSummary.
#>

Set-StrictMode -Version Latest

$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:CurrentSuite = '(unnamed)'

function Set-TestSuite {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $script:CurrentSuite = $Name
    Write-Host ''
    Write-Host "== $Name ==" -ForegroundColor Cyan
}

function Add-TestResult {
    param([string] $Name, [bool] $Passed, [string] $Detail)

    $script:TestResults.Add([pscustomobject]@{
        Suite  = $script:CurrentSuite
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    }) | Out-Null

    if ($Passed) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor Red }
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [AllowNull()] $Expected,
        [AllowNull()] $Actual
    )
    $ok = ([string]$Expected -eq [string]$Actual)
    Add-TestResult -Name $Name -Passed $ok -Detail "expected '$Expected', got '$Actual'"
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [bool] $Condition,
        [string] $Detail = 'condition was false'
    )
    Add-TestResult -Name $Name -Passed $Condition -Detail $Detail
}

function Assert-CollectionEqual {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [string[]] $Expected = @(),
        [string[]] $Actual = @()
    )
    $e = (@($Expected) | Sort-Object) -join '|'
    $a = (@($Actual)   | Sort-Object) -join '|'
    Add-TestResult -Name $Name -Passed ($e -eq $a) -Detail "expected [$e], got [$a]"
}

function Get-TestResults { return $script:TestResults }

function Get-TestSummary {
    <# Prints a summary and returns the failure count. #>
    $all    = @($script:TestResults)
    $failed = @($all | Where-Object { -not $_.Passed })

    Write-Host ''
    Write-Host ('-' * 60)
    Write-Host ("Total: {0}   Passed: {1}   Failed: {2}" -f $all.Count, ($all.Count - $failed.Count), $failed.Count)
    if ($failed.Count -gt 0) {
        Write-Host 'Failures:' -ForegroundColor Red
        foreach ($f in $failed) { Write-Host ("  [{0}] {1} -- {2}" -f $f.Suite, $f.Name, $f.Detail) -ForegroundColor Red }
    }
    Write-Host ('-' * 60)
    return $failed.Count
}

function New-TempDirectory {
    <# Creates a unique temp directory outside the source repository. #>
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("ao-test-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-TestGitRepository {
    <#
    .SYNOPSIS
        Creates a throwaway Git repository with one commit, for scope tests.
    .OUTPUTS
        The repository path.
    #>
    param([string[]] $InitialFiles = @('src/api/existing.py'))

    $repo = New-TempDirectory

    & git -C $repo init --quiet -b main 2>&1 | Out-Null
    & git -C $repo config user.email 'test@ai-orchestra.local' 2>&1 | Out-Null
    & git -C $repo config user.name  'AI_ORCHESTRA Test'        2>&1 | Out-Null
    & git -C $repo config commit.gpgsign false                  2>&1 | Out-Null

    foreach ($f in $InitialFiles) {
        $full = Join-Path $repo $f
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        Set-Content -LiteralPath $full -Value 'baseline' -Encoding UTF8
    }
    & git -C $repo add -A                          2>&1 | Out-Null
    & git -C $repo commit -m 'baseline' --quiet    2>&1 | Out-Null

    return $repo
}

function Set-RepositoryFile {
    <# Writes content to a repo-relative path, creating directories as needed. #>
    param([string] $Repository, [string] $RelativePath, [string] $Content = 'changed')

    $full = Join-Path $Repository $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    Set-Content -LiteralPath $full -Value $Content -Encoding UTF8
}

function New-TestTaskFile {
    <# Writes a minimal TASK.json valid against schemas\TASK.schema.json. #>
    param(
        [string]   $Directory,
        [string[]] $AllowedPaths   = @('src/api', 'tests/api'),
        [string[]] $ForbiddenPaths = @('.github', 'infra'),
        [string]   $FileName       = 'TASK.json'
    )

    $task = [ordered]@{
        task_id             = 'ao-test-001'
        project             = 'AI_ORCHESTRA_TEST'
        repository          = 'owner/test'
        branch              = 'agent/ao-test-001'
        workspace           = $Directory
        objective           = 'Scope validator fixture'
        allowed_paths       = @($AllowedPaths)
        forbidden_paths     = @($ForbiddenPaths)
        acceptance_criteria = @('fixture only')
    }

    $path = Join-Path $Directory $FileName
    $task | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function New-TestJsonFile {
    param([string] $Directory, [string] $FileName, [hashtable] $Data)

    $path = Join-Path $Directory $FileName
    [pscustomobject]$Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Remove-TempDirectory {
    param([string] $Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
