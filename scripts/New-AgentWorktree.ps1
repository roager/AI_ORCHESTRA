#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic Git worktree creation for the AI_ORCHESTRA Supervisor.
.DESCRIPTION
    Creates an isolated Git worktree for a task defined by TASK.json.
.PARAMETER TaskPath
    Path to TASK.json.
.PARAMETER SourceRepositoryPath
    Optional path to the source repository. If omitted, uses source_root from PROJECT_STATE.json.
.PARAMETER AsJson
    Emit result as JSON instead of a PSCustomObject.
.NOTES
    Exit codes:
      0 = success
      2 = validation failed / rejected
      3 = input/configuration error
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string] $TaskPath,

    [Parameter(Position = 1, Mandatory = $false)]
    [string] $SourceRepositoryPath,

    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedFullPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $p = [System.IO.Path]::GetFullPath($Path)
        if ($p.Length -gt 3) {
            $p = $p.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }
        return $p
    }
    catch {
        return ''
    }
}

function Write-OutputObject {
    param([hashtable] $Data)
    $obj = [pscustomobject]$Data
    if ($AsJson) {
        $obj | ConvertTo-Json -Compress -Depth 6
    }
    else {
        $obj
    }
}

# --- 1. Find and Load PROJECT_STATE.json ------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectStatePath = ""

if (-not [string]::IsNullOrWhiteSpace($SourceRepositoryPath)) {
    $projectStatePath = Join-Path $SourceRepositoryPath "config/PROJECT_STATE.json"
}

if ([string]::IsNullOrWhiteSpace($projectStatePath) -or -not (Test-Path -LiteralPath $projectStatePath)) {
    $projectStatePath = Join-Path $scriptDir "../config/PROJECT_STATE.json"
}

if (-not (Test-Path -LiteralPath $projectStatePath)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "PROJECT_STATE.json not found."
    }
    exit 3
}

try {
    $projectStateRaw = Get-Content -LiteralPath $projectStatePath -Raw -Encoding UTF8
    $projectState = $projectStateRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to parse PROJECT_STATE.json: $($_.Exception.Message)"
    }
    exit 3
}

# --- 2. Determine and Validate Source Repository Path ----------------------
$srcRepo = $SourceRepositoryPath
if ([string]::IsNullOrWhiteSpace($srcRepo)) {
    $srcRepo = $projectState.source_root
}

$srcRepoCanonical = Get-NormalizedFullPath -Path $srcRepo
if ([string]::IsNullOrWhiteSpace($srcRepoCanonical) -or -not (Test-Path -LiteralPath $srcRepoCanonical -PathType Container)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Source repository path '$srcRepo' not found or not a directory."
    }
    exit 3
}

# Validate it is a Git repository
$null = & git -C $srcRepoCanonical rev-parse --is-inside-work-tree 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Source path '$srcRepoCanonical' is not a valid Git repository."
    }
    exit 3
}

# --- 3. Load and Validate TASK.json -----------------------------------------
$taskPathCanonical = Get-NormalizedFullPath -Path $TaskPath
if (-not (Test-Path -LiteralPath $taskPathCanonical -PathType Leaf)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "TASK.json not found at '$TaskPath'."
    }
    exit 3
}

try {
    $taskRaw = Get-Content -LiteralPath $taskPathCanonical -Raw -Encoding UTF8
    $task = $taskRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to parse TASK.json: $($_.Exception.Message)"
    }
    exit 3
}

# Validate fields are present and non-empty
if ($null -eq $task -or
    [string]::IsNullOrWhiteSpace($task.task_id) -or
    [string]::IsNullOrWhiteSpace($task.branch) -or
    [string]::IsNullOrWhiteSpace($task.workspace)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "TASK.json is missing required fields (task_id, branch, workspace)."
    }
    exit 3
}

# --- 4. Validate Branch Constraints -----------------------------------------
$requestedBranch = $task.branch.Trim()

# Reject main/master explicitly
if ($requestedBranch.Equals("main", [System.StringComparison]::OrdinalIgnoreCase) -or
    $requestedBranch.Equals("master", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Branch '$requestedBranch' is protected (main/master)."
    }
    exit 2
}

# Reject branches configured as protected in PROJECT_STATE.json
$protectedBranches = @()
if ($null -ne $projectState.protected_branches) {
    $protectedBranches = @($projectState.protected_branches)
}

foreach ($pb in $protectedBranches) {
    if ($requestedBranch.Equals($pb.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-OutputObject -Data @{
            result = "FAILED"
            reason = "Branch '$requestedBranch' is configured as protected."
        }
        exit 2
    }
}

# --- 5. Validate Workspace Path & Escape Guard -----------------------------
$workspaceCanonical = Get-NormalizedFullPath -Path $task.workspace
$rootCanonical = Get-NormalizedFullPath -Path $projectState.runtime_worktree_root

if ([string]::IsNullOrWhiteSpace($rootCanonical)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "runtime_worktree_root is not configured or invalid."
    }
    exit 3
}

$rootCanonicalWithSeparator = $rootCanonical.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $workspaceCanonical.StartsWith($rootCanonicalWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace path '$workspaceCanonical' is not located under runtime_worktree_root '$rootCanonical'."
    }
    exit 2
}

# Ensure workspace is not the primary working tree
if ($workspaceCanonical -eq $srcRepoCanonical) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace path matches the primary working tree."
    }
    exit 2
}

# Ensure destination does not contain unrelated files
if (Test-Path -LiteralPath $workspaceCanonical) {
    $files = @(Get-ChildItem -LiteralPath $workspaceCanonical -Force -ErrorAction SilentlyContinue)
    if ($files.Count -gt 0) {
        Write-OutputObject -Data @{
            result = "FAILED"
            reason = "Workspace path '$workspaceCanonical' already exists and is not empty."
        }
        exit 2
    }
}

# --- 6. Get Base Commit and Create Worktree ---------------------------------
$baseCommit = (& git -C $srcRepoCanonical rev-parse HEAD 2>&1).Trim()
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to determine base commit: $baseCommit"
    }
    exit 3
}

$gitOut = & git -C $srcRepoCanonical worktree add $workspaceCanonical -b $requestedBranch 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "git worktree add failed (exit $LASTEXITCODE): $($gitOut -join ' ')"
    }
    exit 2
}

Write-OutputObject -Data @{
    result      = "CREATED"
    task_id     = $task.task_id
    workspace   = $workspaceCanonical
    branch      = $requestedBranch
    base_commit = $baseCommit
}
exit 0
