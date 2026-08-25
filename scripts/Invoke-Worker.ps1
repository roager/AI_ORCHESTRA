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
   Note that WORKER_REPORT.json is a normal filesystem file. You must write it directly to the exact run-directory path using standard file-system writes. Do NOT create it as an Antigravity artifact, and do NOT use artifact-only tooling for this report. The run directory is explicitly authorized for this report.
   The report must strictly conform to schemas\WORKER_REPORT.schema.json, including:
   - "status": "completed" | "blocked" | "failed"
   - "files_changed": array of repository-relative paths modified
   - "summary": concise description of changes
8. If blocked or uncertain, stop and report status = "blocked" rather than expanding scope.
9. Do not create unrelated artifacts outside the workspace or run directory.
"@

# --- 7b. Claude Bounded Contract (AO-CLAUDE-002) ----------------------------
# Claude workers are confined to the assigned worktree: no additional directories
# are authorized, so they can neither read TASK.json from the run directory nor
# write WORKER_REPORT.json there. The Supervisor therefore mediates both ends:
#   inbound  - the task contract is embedded in the bounded prompt below;
#   outbound - the report is returned through structured stdout and persisted
#              to the run directory by this script.
# This matches WORKER_POLICY section 2 ("Read Assigned Worktree", "Return
# Structured Reports") without granting any filesystem access outside the worktree.

function ConvertTo-PromptList {
    param([object] $Value, [string] $Empty = '(none specified)')
    $items = @()
    if ($null -ne $Value) {
        $items = @(@($Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    if (@($items).Count -eq 0) { return $Empty }
    return ((@($items) | ForEach-Object { "     - $_" }) -join "`n").TrimStart()
}

function Get-TaskField {
    param([object] $Task, [string] $Name)
    if ($null -eq $Task) { return $null }
    if ($Task.PSObject.Properties.Name -contains $Name) { return $Task.$Name }
    return $null
}

$taskObjective  = [string](Get-TaskField -Task $task -Name 'objective')
$taskAllowed    = ConvertTo-PromptList -Value (Get-TaskField -Task $task -Name 'allowed_paths')       -Empty '(none - do not modify any file)'
$taskForbidden  = ConvertTo-PromptList -Value (Get-TaskField -Task $task -Name 'forbidden_paths')     -Empty '(none listed)'
$taskAcceptance = ConvertTo-PromptList -Value (Get-TaskField -Task $task -Name 'acceptance_criteria') -Empty '(none listed)'

$ClaudePrompt = @"
You are a worker agent executing a bounded task under the AI_ORCHESTRA system.

Your entire task contract is reproduced below. It is authoritative. You do NOT
need to read TASK.json, and you have no access to any directory other than your
current working directory.

TASK CONTRACT
   task_id:   $($task.task_id)
   branch:    $requestedBranch
   workspace: $workspaceCanonical
   objective: $taskObjective
   allowed_paths:
     $taskAllowed
   forbidden_paths:
     $taskForbidden
   acceptance_criteria:
     $taskAcceptance

Your instructions:
1. Your current working directory IS the assigned workspace. Work only there.
2. Modify only paths listed under allowed_paths. Never touch forbidden_paths.
3. NEVER push, merge, force push, modify credentials or secrets, or elevate privileges.
4. Do not attempt to read or write any location outside the working directory.
   Such attempts are denied by policy and only waste the run.
5. Do NOT write a WORKER_REPORT.json file anywhere. Reporting is handled below.
6. If blocked or uncertain, stop and report status = "blocked" rather than expanding scope.

Reporting:
   Your FINAL answer must be the structured worker report itself. The full contract
   is reproduced here; you do NOT need to read any schema or policy file:
   - "status" (required): exactly one of "completed", "blocked", "failed"
   - "files_changed" (required): array of repository-relative paths you modified
   - "summary" (required): concise, non-empty description of what you did
   - "risks" (optional): array of strings
   - "questions" (optional): array of strings
   The Supervisor captures this from your output and persists it. Do not write it to disk.
"@

# JSON Schema handed to the Claude CLI via --json-schema. Mirrors the required
# subset of schemas\WORKER_REPORT.schema.json that this script validates below.
$ClaudeReportSchema = [pscustomobject][ordered]@{
    type                 = 'object'
    additionalProperties = $false
    required             = @('status', 'files_changed', 'summary')
    properties           = [ordered]@{
        status        = [ordered]@{ type = 'string'; enum = @('completed', 'blocked', 'failed') }
        files_changed = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string'; minLength = 1 } }
        summary       = [ordered]@{ type = 'string'; minLength = 1 }
        risks         = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string'; minLength = 1 } }
        questions     = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'string'; minLength = 1 } }
    }
} | ConvertTo-Json -Depth 10 -Compress

# Least-privilege tool contract for Claude.
#   - The Claude CLI confines file tools to the working directory unless additional
#     directories are granted. We grant NONE, so the worktree boundary is structural
#     and does not depend on getting permission-rule syntax right.
#   - Bash is denied outright: a shell would defeat that boundary. Deny rules take
#     precedence over allow rules, so this cannot be widened by a stray allow rule.
#   - 'dontAsk' auto-DENIES anything not pre-approved. It is the documented
#     unattended/CI mode and is the opposite of a permission bypass.
$ClaudePermissionMode  = 'dontAsk'
$ClaudeAllowedTools    = 'Read,Edit,Write,Glob,Grep'
$ClaudeDisallowedTools = 'Bash,WebFetch,WebSearch'

# Extension point for controlled experiments (e.g. '--bare' as a cost optimization).
# Deliberately empty: AO-CLAUDE-003 is a correctness task and must not mix in tuning.
# Adding a flag here is the only change required to trial one.
$ClaudeOptionalFlags = @()

# --- 8. Build Deterministic Launch Plan -------------------------------------
# System.Diagnostics.ProcessStartInfo cannot execute a PowerShell script (.ps1)
# directly as FileName. On Windows the npm-installed Claude CLI commonly resolves
# to '<npm prefix>\claude.ps1', so a resolved .ps1 must be launched through pwsh.
# A resolved real executable continues to be launched directly.

function Resolve-PwshHostPath {
    $candidate = ""
    try {
        $candidate = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Source -ErrorAction SilentlyContinue
    }
    catch {
        $candidate = ""
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        try {
            $candidate = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        }
        catch {
            $candidate = ""
        }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) { return "" }
    return $candidate
}

$executableExtension = ""
try {
    $executableExtension = [System.IO.Path]::GetExtension($executable)
}
catch {
    $executableExtension = ""
}
$isPowerShellScript = (-not [string]::IsNullOrWhiteSpace($executableExtension)) -and
    $executableExtension.Equals(".ps1", [System.StringComparison]::OrdinalIgnoreCase)

$launchFileName = $executable
$launchArguments = [System.Collections.Generic.List[string]]::new()

if ($isPowerShellScript) {
    $pwshHostPath = Resolve-PwshHostPath
    if ([string]::IsNullOrWhiteSpace($pwshHostPath)) {
        Write-OutputObject -Data @{
            result = "WORKER_UNAVAILABLE"
            worker = $workerClean
            reason = "Resolved worker command '$executable' is a PowerShell script but the pwsh host could not be located."
        }
        exit 5
    }
    $launchFileName = $pwshHostPath
    $null = $launchArguments.Add("-NoProfile")
    $null = $launchArguments.Add("-File")
    $null = $launchArguments.Add($executable)
}

if ($workerClean -eq 'gemini') {
    # Gemini's contract is unchanged.
    $null = $launchArguments.Add("--output-format")
    $null = $launchArguments.Add("json")
    $null = $launchArguments.Add("--print=$Prompt")
} else {
    # Claude's documented non-interactive contract, plus the least-privilege
    # permission contract. No --add-dir: the worktree boundary is the sandbox.
    $null = $launchArguments.Add("--print")
    $null = $launchArguments.Add("--output-format")
    $null = $launchArguments.Add("json")
    $null = $launchArguments.Add("--json-schema")
    $null = $launchArguments.Add($ClaudeReportSchema)
    $null = $launchArguments.Add("--permission-mode")
    $null = $launchArguments.Add($ClaudePermissionMode)
    $null = $launchArguments.Add("--allowedTools")
    $null = $launchArguments.Add($ClaudeAllowedTools)
    $null = $launchArguments.Add("--disallowedTools")
    $null = $launchArguments.Add($ClaudeDisallowedTools)
    foreach ($optionalFlag in @($ClaudeOptionalFlags)) {
        $null = $launchArguments.Add($optionalFlag)
    }
    # AO-CLAUDE-004: '--' terminates option parsing.
    # --allowedTools / --disallowedTools are VARIADIC (<tools...>) in the Claude CLI,
    # so a bare trailing positional prompt is absorbed into the preceding option's
    # value list. The CLI then sees no prompt and exits with:
    #   "Input must be provided either through stdin or as a prompt argument when using --print"
    # The '--' separator makes everything after it positional, which fixes the binding
    # and permanently immunises it against any option added above (including
    # $ClaudeOptionalFlags). Verified against Claude CLI 2.1.241, and verified to
    # survive the 'pwsh -NoProfile -File claude.ps1' wrapper without being stripped.
    $null = $launchArguments.Add("--")
    # The bounded prompt is always the final argument, passed as ONE intact argv entry.
    $null = $launchArguments.Add($ClaudePrompt)
}

# Record the resolved launch plan for auditability before any process is started.
$launchPlanPath = Join-Path $logDir "worker.launch.json"
try {
    $planData = [ordered]@{
        worker               = $workerClean
        resolved_command     = $executable
        is_powershell_script = $isPowerShellScript
        file_name            = $launchFileName
        arguments            = @($launchArguments)
        working_directory    = $workspaceCanonical
        # Explicitly empty: no filesystem location outside the worktree is authorized.
        additional_directories = @()
    }
    if ($workerClean -eq 'claude') {
        $planData["permission_mode"]   = $ClaudePermissionMode
        $planData["allowed_tools"]     = $ClaudeAllowedTools
        $planData["disallowed_tools"]  = $ClaudeDisallowedTools
        $planData["report_transport"]  = 'structured_stdout'
    }
    [pscustomobject]$planData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $launchPlanPath -Encoding UTF8
}
catch {
    # Auditing artifact only; never block the invocation on it.
}

# --- 9. Execute Worker Process ----------------------------------------------
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $launchFileName
foreach ($launchArg in $launchArguments) {
    $null = $psi.ArgumentList.Add($launchArg)
}
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
    $exitCode = -1
    
    # Save partial output logs
    Set-Content -LiteralPath $stdoutLog -Value $stdoutText -Encoding UTF8
    Set-Content -LiteralPath $stderrLog -Value $stderrText -Encoding UTF8
}
else {
    # Clean termination: retrieve stdout, stderr, exit code
    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    $exitCode = $proc.ExitCode
    
    # Save output logs
    Set-Content -LiteralPath $stdoutLog -Value $stdoutText -Encoding UTF8
    Set-Content -LiteralPath $stderrLog -Value $stderrText -Encoding UTF8
}

# --- Parse Gemini Structured Stdout ---
$geminiStdoutData = $null
$geminiStdoutParseError = $null
$conversationId = $null
$numTurns = $null
$inputTokens = $null
$cacheReadTokens = $null
$outputTokens = $null
$thinkingTokens = $null
$totalTokens = 0
$hasTokens = $false
$geminiCliStatus = $null
$geminiCliErrorMsg = $null

if ($workerClean -eq 'gemini' -and -not [string]::IsNullOrWhiteSpace($stdoutText)) {
    try {
        $geminiStdoutData = $stdoutText | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $geminiStdoutData) {
            if ($geminiStdoutData.PSObject.Properties.Name -contains 'conversation_id') {
                $conversationId = $geminiStdoutData.conversation_id
            }
            if ($geminiStdoutData.PSObject.Properties.Name -contains 'num_turns') {
                $numTurns = $geminiStdoutData.num_turns
            }
            if ($geminiStdoutData.PSObject.Properties.Name -contains 'status') {
                $geminiCliStatus = $geminiStdoutData.status
            }
            if ($geminiStdoutData.PSObject.Properties.Name -contains 'error') {
                $geminiCliErrorMsg = $geminiStdoutData.error
            }
            if ($geminiStdoutData.PSObject.Properties.Name -contains 'usage' -and $null -ne $geminiStdoutData.usage) {
                $u = $geminiStdoutData.usage
                if ($u.PSObject.Properties.Name -contains 'input_tokens') {
                    $inputTokens = $u.input_tokens
                }
                if ($u.PSObject.Properties.Name -contains 'cache_read_tokens') {
                    $cacheReadTokens = $u.cache_read_tokens
                }
                if ($u.PSObject.Properties.Name -contains 'output_tokens') {
                    $outputTokens = $u.output_tokens
                }
                if ($u.PSObject.Properties.Name -contains 'thinking_tokens') {
                    $thinkingTokens = $u.thinking_tokens
                }
                if ($u.PSObject.Properties.Name -contains 'total_tokens') {
                    $totalTokens = [int]$u.total_tokens
                    $hasTokens = $true
                }
            }
        }
    }
    catch {
        $geminiStdoutParseError = $_.Exception.Message
    }
}

# --- Parse Claude Structured Stdout (AO-CLAUDE-002) ---
# Envelope shape verified against the installed Claude CLI (2.1.241):
#   { type, subtype, is_error, num_turns, result, session_id, total_cost_usd,
#     usage: { input_tokens, output_tokens, cache_creation_input_tokens,
#              cache_read_input_tokens, output_tokens_details: { thinking_tokens } },
#     modelUsage: {...}, permission_denials: [...], structured_output?: {...} }
$claudeStdoutData        = $null
$claudeStdoutParseError  = $null
$claudeIsError           = $false
$claudeSubtype           = $null
$claudePermissionDenials = @()
$claudeReport            = $null
$claudeReportSource      = $null
$claudeReportMalformed   = $false
$claudeSessionId         = $null
$claudeDurationApiMs     = $null
$claudeTotalCostUsd      = $null
$claudeModelUsage        = $null
$claudeInputTokens       = $null
$claudeOutputTokens      = $null
$claudeCacheCreateTokens = $null
$claudeCacheReadTokens   = $null
$claudeThinkingTokens    = $null

if ($workerClean -eq 'claude' -and -not [string]::IsNullOrWhiteSpace($stdoutText)) {
    try {
        $claudeStdoutData = $stdoutText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $claudeStdoutParseError = $_.Exception.Message
        $claudeStdoutData = $null
    }
}

if ($null -ne $claudeStdoutData) {
    $names = $claudeStdoutData.PSObject.Properties.Name

    if ($names -contains 'session_id')     { $claudeSessionId     = $claudeStdoutData.session_id }
    if ($names -contains 'num_turns')      { $numTurns             = $claudeStdoutData.num_turns }
    if ($names -contains 'subtype')        { $claudeSubtype        = $claudeStdoutData.subtype }
    if ($names -contains 'duration_api_ms'){ $claudeDurationApiMs  = $claudeStdoutData.duration_api_ms }
    if ($names -contains 'total_cost_usd') { $claudeTotalCostUsd   = $claudeStdoutData.total_cost_usd }
    if ($names -contains 'modelUsage')     { $claudeModelUsage     = $claudeStdoutData.modelUsage }
    if ($names -contains 'is_error' -and $null -ne $claudeStdoutData.is_error) {
        $claudeIsError = [bool]$claudeStdoutData.is_error
    }
    if ($names -contains 'permission_denials' -and $null -ne $claudeStdoutData.permission_denials) {
        $claudePermissionDenials = @($claudeStdoutData.permission_denials)
    }

    # --- Token accounting ---
    # AI_ORCHESTRA total_tokens is defined by USAGE.schema.json as "Total observed
    # token consumption". Claude reports four disjoint counters, all of which are
    # tokens the model actually processed, so all four are summed:
    #     input + cache_creation_input + cache_read_input + output
    # output_tokens_details.thinking_tokens is a BREAKDOWN of output_tokens, not an
    # additional counter, so it is reported but never added (that would double-count).
    if ($names -contains 'usage' -and $null -ne $claudeStdoutData.usage) {
        $cu = $claudeStdoutData.usage
        $cuNames = $cu.PSObject.Properties.Name
        $claudeTotal = 0
        $sawAny = $false

        if ($cuNames -contains 'input_tokens' -and $null -ne $cu.input_tokens) {
            $claudeInputTokens = [int]$cu.input_tokens
            $claudeTotal += $claudeInputTokens; $sawAny = $true
        }
        if ($cuNames -contains 'cache_creation_input_tokens' -and $null -ne $cu.cache_creation_input_tokens) {
            $claudeCacheCreateTokens = [int]$cu.cache_creation_input_tokens
            $claudeTotal += $claudeCacheCreateTokens; $sawAny = $true
        }
        if ($cuNames -contains 'cache_read_input_tokens' -and $null -ne $cu.cache_read_input_tokens) {
            $claudeCacheReadTokens = [int]$cu.cache_read_input_tokens
            $claudeTotal += $claudeCacheReadTokens; $sawAny = $true
        }
        if ($cuNames -contains 'output_tokens' -and $null -ne $cu.output_tokens) {
            $claudeOutputTokens = [int]$cu.output_tokens
            $claudeTotal += $claudeOutputTokens; $sawAny = $true
        }
        if ($cuNames -contains 'output_tokens_details' -and $null -ne $cu.output_tokens_details) {
            $otd = $cu.output_tokens_details
            if ($otd.PSObject.Properties.Name -contains 'thinking_tokens' -and $null -ne $otd.thinking_tokens) {
                $claudeThinkingTokens = [int]$otd.thinking_tokens
            }
        }

        if ($sawAny) {
            $totalTokens = $claudeTotal
            $hasTokens = $true
        }
    }

    # --- Report transport: structured stdout ---
    # structured_output is the ONLY authoritative task result. A top-level
    # exit_code 0 / subtype 'success' / terminal_reason 'completed' says the CLI
    # session ended cleanly; it says nothing about whether the assigned task
    # succeeded, and is never treated as proof of one.
    if ($names -contains 'structured_output' -and $null -ne $claudeStdoutData.structured_output) {
        $candidate = $claudeStdoutData.structured_output
        if ($candidate -is [string]) {
            # Some builds hand back the structured answer as a JSON string.
            try { $candidate = ([string]$candidate).Trim() | ConvertFrom-Json -ErrorAction Stop }
            catch { $candidate = $null }
        }
        if ($null -ne $candidate -and $candidate -is [pscustomobject]) {
            $claudeReport = $candidate
            $claudeReportSource = 'structured_output'
        }
        else {
            # Present but not an object: malformed. Falls through to INVALID_OUTPUT.
            $claudeReportMalformed = $true
        }
    }
}

# Persist the returned report to the run directory. The worker never writes here;
# the Supervisor owns this file, which keeps every downstream check unchanged.
if ($workerClean -eq 'claude' -and $null -ne $claudeReport -and -not (Test-Path -LiteralPath $reportFile)) {
    try {
        $claudeReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportFile -Encoding UTF8
    }
    catch {
        $claudeReportSource = $null
    }
}

# --- Usage Accounting ---
$usagePath = Join-Path $runDirCanonical "USAGE.json"
if (Test-Path -LiteralPath $usagePath -PathType Leaf) {
    try {
        $usageRaw = Get-Content -LiteralPath $usagePath -Raw -Encoding UTF8
        $usageData = $usageRaw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $usageData) {
            $usageData.worker_calls = [int]$usageData.worker_calls + 1
            $usageData.runtime_seconds = [int]$usageData.runtime_seconds + [Math]::Round($duration)
            if ($hasTokens) {
                $usageData.total_tokens = [int]$usageData.total_tokens + $totalTokens
            }
            $usageData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usagePath -Encoding UTF8
        }
    }
    catch {
        # proceed silently if USAGE.json is unparseable
    }
}

# --- Budget Check ---
$budgetVerdict = $null
$budgetExceeded = $false
$budgetReason = ""
$budgetEscalationReason = ""

if (Test-Path -LiteralPath $usagePath -PathType Leaf) {
    try {
        $budgetScript = Join-Path $scriptDir "Test-AgentBudget.ps1"
        $budgetOutputText = pwsh -NoProfile -NonInteractive -File $budgetScript -UsagePath $usagePath -PolicyPath $budgetPolicyPath -AsJson
        $budgetExitCode = $LASTEXITCODE
        if ($budgetExitCode -eq 2) {
            $budgetExceeded = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($budgetOutputText)) {
            $budgetVerdict = $budgetOutputText | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $budgetVerdict) {
                if ($budgetVerdict.PSObject.Properties.Name -contains 'reason') {
                    $budgetReason = $budgetVerdict.reason
                }
                if ($budgetVerdict.PSObject.Properties.Name -contains 'escalation_reason') {
                    $budgetEscalationReason = $budgetVerdict.escalation_reason
                }
            }
        }
    }
    catch {
        # proceed silently if budget check fails
    }
}

# --- Structured Exit Helper ---
function Write-ResultAndExit {
    param(
        [Parameter(Mandatory=$true)] [string] $Verdict,
        [Parameter(Mandatory=$false)] [int] $CustomExitCode = 2,
        [Parameter(Mandatory=$false)] [object] $Report = $null,
        [Parameter(Mandatory=$false)] [string] $CustomReason = $null,
        [Parameter(Mandatory=$false)] [string] $EscalationReason = $null
    )
    
    $resultData = [ordered]@{
        result           = $Verdict
        worker           = $Worker
        task_id          = $task.task_id
        workspace        = $workspaceCanonical
        run_directory    = $runDirCanonical
        duration_seconds = $duration
        exit_code        = $exitCode
    }
    
    if ($null -ne $Report) {
        $resultData["worker_report"] = $Report
    }
    
    if (-not [string]::IsNullOrWhiteSpace($CustomReason)) {
        $resultData["reason"] = $CustomReason
    }
    
    if (-not [string]::IsNullOrWhiteSpace($EscalationReason)) {
        $resultData["escalation_reason"] = $EscalationReason
    }
    
    if ($workerClean -eq 'gemini') {
        if ($null -ne $conversationId)   { $resultData["conversation_id"]   = $conversationId }
        if ($null -ne $numTurns)         { $resultData["num_turns"]         = $numTurns }
        if ($null -ne $inputTokens)      { $resultData["input_tokens"]      = $inputTokens }
        if ($null -ne $cacheReadTokens)  { $resultData["cache_read_tokens"]  = $cacheReadTokens }
        if ($null -ne $outputTokens)     { $resultData["output_tokens"]     = $outputTokens }
        if ($null -ne $thinkingTokens)   { $resultData["thinking_tokens"]   = $thinkingTokens }
        if ($null -ne $totalTokens)      { $resultData["total_tokens"]      = $totalTokens }
    }

    if ($workerClean -eq 'claude') {
        if ($null -ne $claudeSessionId)         { $resultData["session_id"]                 = $claudeSessionId }
        if ($null -ne $numTurns)                { $resultData["num_turns"]                  = $numTurns }
        if ($null -ne $claudeDurationApiMs)     { $resultData["duration_api_ms"]            = $claudeDurationApiMs }
        if ($null -ne $claudeTotalCostUsd)      { $resultData["total_cost_usd"]             = $claudeTotalCostUsd }
        if ($null -ne $claudeModelUsage)        { $resultData["model_usage"]                = $claudeModelUsage }
        if ($null -ne $claudeInputTokens)       { $resultData["input_tokens"]               = $claudeInputTokens }
        if ($null -ne $claudeCacheCreateTokens) { $resultData["cache_creation_input_tokens"] = $claudeCacheCreateTokens }
        if ($null -ne $claudeCacheReadTokens)   { $resultData["cache_read_input_tokens"]    = $claudeCacheReadTokens }
        if ($null -ne $claudeOutputTokens)      { $resultData["output_tokens"]              = $claudeOutputTokens }
        if ($null -ne $claudeThinkingTokens)    { $resultData["thinking_tokens"]            = $claudeThinkingTokens }
        if ($hasTokens)                         { $resultData["total_tokens"]               = $totalTokens }
        if ($null -ne $claudeReportSource)      { $resultData["report_source"]              = $claudeReportSource }
        $resultData["permission_denial_count"] = @($claudePermissionDenials).Count
    }

    $obj = [pscustomobject]$resultData
    if ($AsJson) {
        $obj | ConvertTo-Json -Compress -Depth 6
    }
    else {
        $obj
    }
    exit $CustomExitCode
}

# --- Process Verdict ---

# 1. Budget hard-stop check
if ($budgetExceeded) {
    Write-ResultAndExit -Verdict "STOP" -CustomExitCode 2 -CustomReason "Hard limit reached: $budgetReason" -EscalationReason $budgetEscalationReason
}

# 2. Timeout check
if (-not $exited) {
    Write-ResultAndExit -Verdict "TIMEOUT" -CustomExitCode 4
}

# 3. Gemini stdout valid JSON check
if ($workerClean -eq 'gemini' -and $null -eq $geminiStdoutData) {
    Write-ResultAndExit -Verdict "INVALID_OUTPUT" -CustomExitCode 2 -CustomReason "Gemini stdout is not valid JSON. Parse error: $geminiStdoutParseError"
}

# 4. Gemini CLI error check
if ($workerClean -eq 'gemini' -and $geminiCliStatus -eq 'ERROR') {
    Write-ResultAndExit -Verdict "FAILED" -CustomExitCode 2 -CustomReason "Gemini CLI reported error: $geminiCliErrorMsg"
}

# 4b. Claude stdout valid JSON check
if ($workerClean -eq 'claude' -and $null -eq $claudeStdoutData) {
    Write-ResultAndExit -Verdict "INVALID_OUTPUT" -CustomExitCode 2 -CustomReason "Claude stdout is not valid JSON. Parse error: $claudeStdoutParseError"
}

# 4c. Claude CLI error check
if ($workerClean -eq 'claude' -and $claudeIsError) {
    $claudeErrText = ""
    if ($null -ne $claudeStdoutData -and $claudeStdoutData.PSObject.Properties.Name -contains 'result') {
        $claudeErrText = [string]$claudeStdoutData.result
    }
    Write-ResultAndExit -Verdict "FAILED" -CustomExitCode 2 -CustomReason "Claude CLI reported an error (subtype '$claudeSubtype'): $claudeErrText"
}

# 5. WORKER_REPORT.json existence check
if (-not (Test-Path -LiteralPath $reportFile)) {
    $missingReason = "WORKER_REPORT.json is missing."
    if ($workerClean -eq 'claude') {
        if ($claudeReportMalformed) {
            $missingReason = "Claude structured_output is malformed: it is not a JSON object matching the WORKER_REPORT contract."
        }
        else {
            $missingReason = "Claude returned no structured_output. A clean CLI exit is not proof the assigned task succeeded."
        }
        $denialCount = @($claudePermissionDenials).Count
        if ($denialCount -gt 0) {
            # Surface the bounded-access failure precisely instead of a generic miss.
            $denialTools = @($claudePermissionDenials | ForEach-Object {
                if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'tool_name') { [string]$_.tool_name } else { 'unknown' }
            } | Select-Object -Unique) -join ', '
            $missingReason += " The worker hit $denialCount permission denial(s) (tools: $denialTools); it may have attempted access outside the assigned worktree."
        }
    }
    Write-ResultAndExit -Verdict "INVALID_OUTPUT" -CustomExitCode 2 -CustomReason $missingReason
}

# 6. Parse WORKER_REPORT.json
$reportData = $null
try {
    $reportRaw = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8
    $reportData = $reportRaw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-ResultAndExit -Verdict "INVALID_OUTPUT" -CustomExitCode 2 -CustomReason "WORKER_REPORT.json is not valid JSON."
}

# 7. Structural Schema validation
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
    Write-ResultAndExit -Verdict "INVALID_OUTPUT" -CustomExitCode 2 -CustomReason "WORKER_REPORT.json structural validation failed: $validationError"
}

# 8. Clean process non-zero exit code with status completed check
if ($exitCode -ne 0 -and $reportData.status -eq 'completed') {
    Write-ResultAndExit -Verdict "FAILED" -CustomExitCode 2 -Report $reportData -CustomReason "Worker process exited with non-zero code $exitCode."
}

# 9. Return worker report status outcome
if ($reportData.status -eq 'completed') {
    Write-ResultAndExit -Verdict "COMPLETED" -CustomExitCode 0 -Report $reportData
}
elseif ($reportData.status -eq 'blocked') {
    Write-ResultAndExit -Verdict "BLOCKED" -CustomExitCode 1 -Report $reportData
}
else {
    Write-ResultAndExit -Verdict "FAILED" -CustomExitCode 2 -Report $reportData
}

