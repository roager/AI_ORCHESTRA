#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic Git worktree removal for the AI_ORCHESTRA Supervisor.
.DESCRIPTION
    Safely removes an isolated Git worktree after a task is complete.
.PARAMETER WorkspacePath
    Path to the task workspace.
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
    [string] $WorkspacePath,

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

# --- 3. Validate Workspace Containment & Escape Guard -----------------------
$workspaceCanonical = Get-NormalizedFullPath -Path $WorkspacePath
$rootCanonical = Get-NormalizedFullPath -Path $projectState.runtime_worktree_root

if ([string]::IsNullOrWhiteSpace($workspaceCanonical)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace path is empty or invalid."
    }
    exit 3
}

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

# Ensure we are not removing the primary working tree
if ($workspaceCanonical -eq $srcRepoCanonical) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Refusing to remove the primary working tree."
    }
    exit 2
}

# --- 4. Verify Registered Git Worktree ---------------------------------------
$worktreesRaw = & git -C $srcRepoCanonical worktree list --porcelain 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to list git worktrees: $($worktreesRaw -join ' ')"
    }
    exit 3
}

$worktrees = @()
foreach ($w in $worktreesRaw) {
    if ($null -ne $w) {
        $worktrees += @($w -split "\r?\n")
    }
}

$isRegistered = $false
$registeredBranch = ""

for ($i = 0; $i -lt $worktrees.Count; $i++) {
    $line = $worktrees[$i].Trim()
    if ($line.StartsWith("worktree ")) {
        $wtPath = $line.Substring(9).Trim()
        $wtCanonical = Get-NormalizedFullPath -Path $wtPath
        if ($wtCanonical -eq $workspaceCanonical) {
            $isRegistered = $true
            # Parse the corresponding branch if present by scanning subsequent lines
            for ($j = $i + 1; $j -lt $worktrees.Count; $j++) {
                $subLine = $worktrees[$j].Trim()
                if ($subLine.StartsWith("worktree ")) {
                    break
                }
                if ($subLine.StartsWith("branch ")) {
                    $registeredBranch = $subLine.Substring(7).Replace("refs/heads/", "").Trim()
                    break
                }
            }
            break
        }
    }
}

if (-not $isRegistered) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace path '$workspaceCanonical' is not registered as a worktree of repository '$srcRepoCanonical'."
    }
    exit 2
}

# --- 5. Verify Cleanliness (No Uncommitted/Untracked Changes) ----------------
# We check this from the workspace path itself, so check if the directory exists first.
if (-not (Test-Path -LiteralPath $workspaceCanonical)) {
    # If the directory is physically gone but registered, we can remove it.
    # Otherwise, if it's there, check git status.
    $isDirty = $false
}
else {
    $gitStatus = @(& git -C $workspaceCanonical status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-OutputObject -Data @{
            result = "FAILED"
            reason = "Failed to check git status on worktree: $($gitStatus -join ' ')"
        }
        exit 3
    }
    # If porcelain output has any content, there are modified, deleted, staged, or untracked files
    $isDirty = ($gitStatus.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($gitStatus[0]))
}

if ($isDirty) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace has uncommitted changes or untracked files."
    }
    exit 2
}

# --- 6. Remove the Worktree --------------------------------------------------
$gitRemove = & git -C $srcRepoCanonical worktree remove $workspaceCanonical 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "git worktree remove failed: $($gitRemove -join ' ')"
    }
    exit 2
}

Write-OutputObject -Data @{
    result    = "REMOVED"
    workspace = $workspaceCanonical
    branch    = $registeredBranch
}
exit 0
