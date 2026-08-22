#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic worker invocation layer for the AI_ORCHESTRA Supervisor.
.DESCRIPTION
    Launches a supported worker CLI inside a created isolated Git worktree,
    enforcing runtime timeout and budget policy bounds, and capturing execution logs.
.PARAMETER Worker
    Name of the worker (claude or gemini). Case-insensitive.
.PARAMETER TaskFile
    Path to TASK.json task definition.
.PARAMETER Workspace
    Path to the isolated Git worktree.
.PARAMETER RunDirectory
    Path to the execution run directory.
.PARAMETER TimeoutSeconds
    Optional timeout in seconds. Clamped to BUDGET_POLICY.max_runtime_seconds.
.PARAMETER AsJson
    Emit result as JSON instead of a PSCustomObject.
.PARAMETER OverrideExecutablePath
    Optional executable path override for dependency injection in tests.
.NOTES
    Exit codes:
      0 = Completed invocation with valid worker report (status is completed)
      1 = Worker reported BLOCKED (status is blocked in report)
      2 = Worker execution/validation failure (status is failed, invalid report, or precondition failed)
      3 = Input/configuration error (malformed files, missing required inputs)
      4 = Timeout
      5 = Worker unavailable
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string] $Worker,

    [Parameter(Position = 1, Mandatory = $true)]
    [string] $TaskFile,

    [Parameter(Position = 2, Mandatory = $true)]
    [string] $Workspace,

    [Parameter(Position = 3, Mandatory = $true)]
    [string] $RunDirectory,

    [Parameter(Position = 4, Mandatory = $false)]
    [int] $TimeoutSeconds = 0,

    [switch] $AsJson,

    [Parameter(Mandatory = $false)]
    [string] $OverrideExecutablePath = ""
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

# --- 1. Validate Worker Name ------------------------------------------------
$workerClean = $Worker.Trim().ToLower()
if ($workerClean -ne 'claude' -and $workerClean -ne 'gemini') {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Worker '$Worker' is unsupported. Supported workers: claude, gemini."
    }
    exit 3
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectStatePath = ""
if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    $projectStatePath = Join-Path $Workspace "config/PROJECT_STATE.json"
}
if ([string]::IsNullOrWhiteSpace($projectStatePath) -or -not (Test-Path -LiteralPath $projectStatePath)) {
    $projectStatePath = Join-Path $scriptDir "../config/PROJECT_STATE.json"
}
$budgetPolicyPath = Join-Path $scriptDir "../policies/BUDGET_POLICY.json"

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

$maxRuntimeSeconds = 2700
if (Test-Path -LiteralPath $budgetPolicyPath) {
    try {
        $bp = Get-Content -LiteralPath $budgetPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $bp.max_runtime_seconds) {
            $maxRuntimeSeconds = $bp.max_runtime_seconds
        }
    }
    catch {}
}

# --- 3. Validate Inputs and Preconditions ----------------------------------
$taskPathCanonical = Get-NormalizedFullPath -Path $TaskFile
if (-not (Test-Path -LiteralPath $taskPathCanonical -PathType Leaf)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "TASK.json not found at '$TaskFile'."
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

# Validate required task fields
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

# Workspace canonicalization and verification
$workspaceCanonical = Get-NormalizedFullPath -Path $Workspace
if ([string]::IsNullOrWhiteSpace($workspaceCanonical) -or -not (Test-Path -LiteralPath $workspaceCanonical -PathType Container)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace directory '$Workspace' does not exist."
    }
    exit 3
}

# Check that Workspace matches task's workspace path
$taskWorkspaceCanonical = Get-NormalizedFullPath -Path $task.workspace
if ($workspaceCanonical -ne $taskWorkspaceCanonical) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace path '$workspaceCanonical' does not match TASK.json workspace '$taskWorkspaceCanonical'."
    }
    exit 2
}

# Verify Workspace is a valid Git repository/worktree
$null = & git -C $workspaceCanonical rev-parse --is-inside-work-tree 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace '$workspaceCanonical' is not a valid Git repository/worktree."
    }
    exit 3
}

# Verify Workspace is under PROJECT_STATE.runtime_worktree_root
$wtRootCanonical = Get-NormalizedFullPath -Path $projectState.runtime_worktree_root
$wtRootCanonicalWithSeparator = $wtRootCanonical.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $workspaceCanonical.StartsWith($wtRootCanonicalWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace '$workspaceCanonical' escapes runtime_worktree_root '$wtRootCanonical'."
    }
    exit 2
}

# RunDirectory verification
$runDirCanonical = Get-NormalizedFullPath -Path $RunDirectory
if ([string]::IsNullOrWhiteSpace($runDirCanonical)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "RunDirectory path is invalid."
    }
    exit 3
}

# Verify RunDirectory is under PROJECT_STATE.runtime_runs_root
$runsRootCanonical = Get-NormalizedFullPath -Path $projectState.runtime_runs_root
$runsRootCanonicalWithSeparator = $runsRootCanonical.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not $runDirCanonical.StartsWith($runsRootCanonicalWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Run directory '$runDirCanonical' escapes runtime_runs_root '$runsRootCanonical'."
    }
    exit 2
}

# Verify branch safety
$requestedBranch = $task.branch.Trim()
if ($requestedBranch.Equals("main", [System.StringComparison]::OrdinalIgnoreCase) -or
    $requestedBranch.Equals("master", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Task branch '$requestedBranch' is protected (main/master)."
    }
    exit 2
}

$protectedBranches = @()
if ($null -ne $projectState.protected_branches) {
    $protectedBranches = @($projectState.protected_branches)
}
foreach ($pb in $protectedBranches) {
    if ($requestedBranch.Equals($pb.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-OutputObject -Data @{
            result = "FAILED"
            reason = "Task branch '$requestedBranch' is configured as protected."
        }
        exit 2
    }
}

# Verify workspace branch matches task branch
$wsCurrentBranch = (& git -C $workspaceCanonical rev-parse --abbrev-ref HEAD 2>&1).Trim()
if ($LASTEXITCODE -ne 0 -or $wsCurrentBranch -ne $requestedBranch) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Workspace current branch '$wsCurrentBranch' does not match TASK.json branch '$requestedBranch'."
    }
    exit 2
}

# --- 4. Validate Run Directory and Artifacts Existence ----------------------
if (-not (Test-Path -LiteralPath $runDirCanonical -PathType Container)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Run directory '$RunDirectory' does not exist."
    }
    exit 3
}

$logDir = Join-Path $runDirCanonical "logs"
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Logs directory does not exist in run directory."
    }
    exit 3
}

$copiedTaskPath = Join-Path $runDirCanonical "TASK.json"
if (-not (Test-Path -LiteralPath $copiedTaskPath -PathType Leaf)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "TASK.json does not exist in run directory."
    }
    exit 3
}

# Verify the run TASK.json matches the supplied task/task_id
try {
    $runTaskRaw = Get-Content -LiteralPath $copiedTaskPath -Raw -Encoding UTF8
    $runTask = $runTaskRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to parse TASK.json in run directory: $($_.Exception.Message)"
    }
    exit 3
}

if ($runTask.task_id -ne $task.task_id) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Run TASK.json task_id '$($runTask.task_id)' does not match supplied task_id '$($task.task_id)'."
    }
    exit 3
}

$statusPath = Join-Path $runDirCanonical "STATUS.json"
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "STATUS.json does not exist in run directory."
    }
    exit 3
}

$usagePath = Join-Path $runDirCanonical "USAGE.json"
if (-not (Test-Path -LiteralPath $usagePath -PathType Leaf)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "USAGE.json does not exist in run directory."
    }
    exit 3
}

$reportFile = Join-Path $runDirCanonical "WORKER_REPORT.json"
if (Test-Path -LiteralPath $reportFile) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "WORKER_REPORT.json already exists in run directory. Refusing to overwrite."
    }
    exit 2
}

$stdoutLog = Join-Path $logDir "worker.stdout.log"
$stderrLog = Join-Path $logDir "worker.stderr.log"

if ((Test-Path -LiteralPath $stdoutLog) -or (Test-Path -LiteralPath $stderrLog)) {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Worker log files already exist in run directory. Refusing to overwrite."
    }
    exit 2
}

# --- 5. Resolve Worker Executable & Discovery -------------------------------
$executable = ""

if ($workerClean -eq 'claude') {
    if (-not [string]::IsNullOrWhiteSpace($OverrideExecutablePath)) {
        $executable = $OverrideExecutablePath
    } else {
        $executable = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
    }
    if ([string]::IsNullOrWhiteSpace($executable) -or -not (Test-Path -LiteralPath $executable)) {
        Write-OutputObject -Data @{
            result = "WORKER_UNAVAILABLE"
            worker = "claude"
            reason = "Claude CLI executable not found or not accessible."
        }
        exit 5
    }
} elseif ($workerClean -eq 'gemini') {
    if (-not [string]::IsNullOrWhiteSpace($OverrideExecutablePath)) {
        $executable = $OverrideExecutablePath
    } else {
        $executable = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($executable)) {
            $executable = Get-Command gemini -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
        }
    }
    if ([string]::IsNullOrWhiteSpace($executable) -or -not (Test-Path -LiteralPath $executable)) {
        Write-OutputObject -Data @{
            result = "WORKER_UNAVAILABLE"
            worker = "gemini"
            reason = "Gemini/Antigravity CLI executable not found or not accessible."
        }
        exit 5
    }
}

# --- 6. Handle Timeout Clamping ---------------------------------------------
$timeout = $maxRuntimeSeconds
if ($TimeoutSeconds -gt 0) {
    if ($TimeoutSeconds -gt $maxRuntimeSeconds) {
        $timeout = $maxRuntimeSeconds # clamped
    } else {
        $timeout = $TimeoutSeconds
    }
}
$timeoutMs = $timeout * 1000

# --- 7. Construct Bounded Worker Prompt ------------------------------------
$Prompt = @"
You are a worker agent executing a bounded task under the AI_ORCHESTRA system.

Your instructions:
1. Read the assigned TASK.json in your workspace or run directory.
2. Read only the relevant worker/security policy files (e.g., policies/WORKER_POLICY.md, policies/SECURITY_POLICY.md).
3. Work ONLY inside the assigned workspace. Do not access files outside it.
4. Modify only task-authorized paths specified under allowed_paths in TASK.json.
5. NEVER push, merge, force push, modify credentials, or elevate privileges.
6. Execute relevant tests when appropriate.
7. Produce your final structured report in JSON format at: $runDirCanonical\WORKER_REPORT.json
   The report must strictly conform to schemas\WORKER_REPORT.schema.json, including:
   - "status": "completed" | "blocked" | "failed"
   - "files_changed": array of repository-relative paths modified
   - "summary": concise description of changes
8. If blocked or uncertain, stop and report status = "blocked" rather than expanding scope.
9. Do not create unrelated artifacts outside the workspace or run directory.
"@

# --- 8. Execute Worker Process ----------------------------------------------
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $executable
$psi.ArgumentList.Add($Prompt)
$psi.WorkingDirectory = $workspaceCanonical
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi

$startTime = [DateTime]::UtcNow
try {
    $proc.Start() | Out-Null
}
catch {
    Write-OutputObject -Data @{
        result = "FAILED"
        reason = "Failed to start worker process: $($_.Exception.Message)"
    }
    exit 2
}

# Background asynchronous reading to prevent stdout/stderr buffer deadlocks
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()

$exited = $proc.WaitForExit($timeoutMs)
$endTime = [DateTime]::UtcNow
$duration = [Math]::Round(($endTime - $startTime).TotalSeconds, 2)

$stdoutText = ""
$stderrText = ""
$exitCode = -1

if (-not $exited) {
    # Timeout termination
    try {
        $proc.Kill($true) # Kill process tree
    }
    catch {
        $proc.Kill()
    }
    
    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    
    # Save partial output logs
    Set-Content -LiteralPath $stdoutLog -Value $stdoutText -Encoding UTF8
    Set-Content -LiteralPath $stderrLog -Value $stderrText -Encoding UTF8
    
    Write-OutputObject -Data @{
        result           = "TIMEOUT"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = -1
    }
    exit 4
}

# Clean termination: retrieve stdout, stderr, exit code
$stdoutText = $stdoutTask.Result
$stderrText = $stderrTask.Result
$exitCode = $proc.ExitCode

# Save output logs
Set-Content -LiteralPath $stdoutLog -Value $stdoutText -Encoding UTF8
Set-Content -LiteralPath $stderrLog -Value $stderrText -Encoding UTF8

# --- 9. Validate WORKER_REPORT.json -----------------------------------------
if (-not (Test-Path -LiteralPath $reportFile)) {
    Write-OutputObject -Data @{
        result           = "INVALID_OUTPUT"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        reason           = "WORKER_REPORT.json is missing."
    }
    exit 2
}

$reportData = $null
try {
    $reportRaw = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8
    $reportData = $reportRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-OutputObject -Data @{
        result           = "INVALID_OUTPUT"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        reason           = "WORKER_REPORT.json is not valid JSON."
    }
    exit 2
}

# Structural Schema validation
$isValid = $true
$validationError = ""

if ($null -eq $reportData) {
    $isValid = $false
    $validationError = "Report data is null."
} elseif ($null -eq $reportData.status -or ($reportData.status -ne 'completed' -and $reportData.status -ne 'blocked' -and $reportData.status -ne 'failed')) {
    $isValid = $false
    $validationError = "Required property 'status' must be one of 'completed', 'blocked', 'failed'."
} elseif ($null -eq $reportData.files_changed) {
    $isValid = $false
    $validationError = "Required property 'files_changed' is missing."
} elseif ($null -eq $reportData.summary -or [string]::IsNullOrWhiteSpace($reportData.summary)) {
    $isValid = $false
    $validationError = "Required property 'summary' is missing or empty."
}

if ($isValid) {
    $fc = @($reportData.files_changed)
    foreach ($f in $fc) {
        if ($null -eq $f -or $f -isnot [string] -or [string]::IsNullOrWhiteSpace($f)) {
            $isValid = $false
            $validationError = "'files_changed' must be an array of non-empty strings."
            break
        }
    }
}

if (-not $isValid) {
    Write-OutputObject -Data @{
        result           = "INVALID_OUTPUT"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        reason           = "WORKER_REPORT.json structural validation failed: $validationError"
    }
    exit 2
}

# --- 10. Process Deterministic Verdict & Exit Codes ------------------------
if ($exitCode -ne 0 -and $reportData.status -eq 'completed') {
    # If the process exited non-zero but claimed completed, treat it as FAILED
    Write-OutputObject -Data @{
        result           = "FAILED"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        worker_report    = $reportData
        reason           = "Worker process exited with non-zero code $exitCode."
    }
    exit 2
}

if ($reportData.status -eq 'completed') {
    Write-OutputObject -Data @{
        result           = "COMPLETED"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        worker_report    = $reportData
    }
    exit 0
}
elseif ($reportData.status -eq 'blocked') {
    Write-OutputObject -Data @{
        result           = "BLOCKED"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        worker_report    = $reportData
    }
    exit 1
}
else {
    # Status is failed
    Write-OutputObject -Data @{
        result           = "FAILED"
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
        worker_report    = $reportData
    }
    exit 2
}
