#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministically initializes an AI_ORCHESTRA run directory and its initial
    runtime artifacts.

.DESCRIPTION
    Creates, for exactly one orchestration run:

        <runtime_runs_root>\<run-id>\
        |-- TASK.json     copy of the supplied task definition
        |-- STATUS.json   initial orchestration state
        |-- USAGE.json    zeroed consumption counters
        \-- logs\         empty

    This script invokes no agent, creates no Git worktree, and performs no
    network, Git, or GitHub operation. It only validates inputs and writes
    files inside a run directory it has proven to be under runtime_runs_root.

    WORKER_REPORT.json, REVIEW.json, RESULT.json and HUMAN_DECISION.json belong
    to later lifecycle stages and are deliberately not created here.

.PARAMETER TaskFile
    Path to a TASK.json conforming to schemas\TASK.schema.json. Read-only; the
    original file is never modified.

.PARAMETER RunId
    Identifier for this run. Must be usable as a single directory segment:
    non-empty, no directory separators, no drive or root, no '.'/'..'
    semantics, no characters invalid in a filename.

.PARAMETER RunDirectory
    Optional explicit run directory. When omitted it is derived as
    <runtime_runs_root>\<RunId>. Either way the resolved path must lie strictly
    beneath runtime_runs_root.

.PARAMETER ProjectStateFile
    Optional path to PROJECT_STATE.json. Defaults to config\PROJECT_STATE.json
    beside this script's repository root. Exposed so tests can supply a
    disposable configuration instead of touching the real runtime root.

.PARAMETER AsJson
    Emit the result as a single-line JSON object instead of a PSCustomObject.

.OUTPUTS
    PSCustomObject (or JSON with -AsJson). On success:
      result, run_id, run_directory, task_id, initial_state, created[]
    On rejection or error:
      result, code, reason (plus run_id / run_directory when known)

.NOTES
    Exit codes:
      0  CREATED       run initialized successfully
      2  REJECTED      deterministic refusal (unsafe RunId, containment
                       violation, existing run directory or artifact)
      3  INPUT_ERROR   unreadable or invalid input/configuration (missing or
                       malformed TASK.json, missing required task fields,
                       unusable PROJECT_STATE.json)

    Security: no network, no AI, no Git, no GitHub, no credential access, no
    environment dumping. Files are created only inside the validated run
    directory. Nothing is copied into the generated artifacts except the task
    definition supplied by the caller.

.EXAMPLE
    .\New-AgentRun.ps1 -TaskFile .\TASK.json -RunId podiumhub-epic26-d4-003

.EXAMPLE
    .\New-AgentRun.ps1 -TaskFile .\TASK.json -RunId demo-001 -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string] $TaskFile,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string] $RunId,

    [AllowEmptyString()]
    [string] $RunDirectory,

    [AllowEmptyString()]
    [string] $ProjectStateFile,

    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

# Initial orchestration state, per schemas\STATUS.schema.json and
# policies\ORCHESTRATOR_POLICY.md section 2.1 (CREATED is the entry state).
$script:InitialState = 'CREATED'

# schemas\TASK.schema.json -> required
$script:RequiredTaskFields = @(
    'task_id'
    'project'
    'repository'
    'branch'
    'workspace'
    'objective'
    'allowed_paths'
    'forbidden_paths'
    'acceptance_criteria'
)

# Artifacts this script owns. Anything already present blocks initialization.
$script:RunArtifacts = @('TASK.json', 'STATUS.json', 'USAGE.json')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-RunResult {
    param([string] $Result, [string] $Code, [string] $Reason)
    return [ordered]@{
        script        = 'New-AgentRun'
        result        = $Result
        code          = $Code
        reason        = $Reason
        run_id        = $null
        run_directory = $null
        task_id       = $null
        initial_state = $null
        created       = @()
    }
}

function Get-UtcTimestamp {
    <# ISO 8601 UTC, second precision, matching the date-time format used by
       STATUS.schema.json. #>
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-SafeRunId {
    <#
    .SYNOPSIS
        True when $RunId is safe as exactly one directory segment.
    .OUTPUTS
        Hashtable @{ Safe = [bool]; Reason = [string] }
    #>
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $RunId)

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        return @{ Safe = $false; Reason = 'RunId is empty or whitespace.' }
    }
    # Leading/trailing whitespace would silently change the directory name.
    if ($RunId -ne $RunId.Trim()) {
        return @{ Safe = $false; Reason = "RunId '$RunId' has leading or trailing whitespace." }
    }
    if ($RunId -eq '.' -or $RunId -eq '..') {
        return @{ Safe = $false; Reason = "RunId '$RunId' has directory-navigation semantics." }
    }
    # Any '..' is traversal, wherever it appears.
    if ($RunId.Contains('..')) {
        return @{ Safe = $false; Reason = "RunId '$RunId' contains '..' (path traversal)." }
    }
    # Separators and drive markers, checked explicitly so behaviour is identical
    # on Windows and on any host running the tests.
    foreach ($bad in @('/', '\', ':')) {
        if ($RunId.Contains($bad)) {
            return @{ Safe = $false; Reason = "RunId '$RunId' contains a path separator or drive marker ('$bad')." }
        }
    }
    if ($RunId.StartsWith('~')) {
        return @{ Safe = $false; Reason = "RunId '$RunId' starts with '~' (home-directory expansion)." }
    }
    if ([System.IO.Path]::IsPathRooted($RunId)) {
        return @{ Safe = $false; Reason = "RunId '$RunId' is an absolute path." }
    }
    # A trailing dot is stripped by Windows, changing the effective name.
    if ($RunId.EndsWith('.')) {
        return @{ Safe = $false; Reason = "RunId '$RunId' ends with '.'." }
    }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        if ($RunId.Contains([string]$c)) {
            return @{ Safe = $false; Reason = "RunId '$RunId' contains a character invalid in a filename." }
        }
    }
    # Control characters are invalid on Windows but not flagged on Linux.
    foreach ($ch in $RunId.ToCharArray()) {
        if ([char]::IsControl($ch)) {
            return @{ Safe = $false; Reason = "RunId '$RunId' contains a control character." }
        }
    }
    # Final guard: the value must be exactly its own leaf name.
    if ([System.IO.Path]::GetFileName($RunId) -ne $RunId) {
        return @{ Safe = $false; Reason = "RunId '$RunId' is not a single path segment." }
    }
    return @{ Safe = $true; Reason = $null }
}

function Get-NormalizedFullPath {
    <# Absolute, separator-normalised path with no trailing separator.
       Works on a path that does not yet exist. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathUnderRoot {
    <#
    .SYNOPSIS
        True when $Candidate is strictly beneath $Root.
    .DESCRIPTION
        Compares on a separator boundary, so a sibling directory that merely
        shares a name prefix is rejected:
            root      C:\tmp\ai-orchestra-runs
            candidate C:\tmp\ai-orchestra-runs-evil\run1   -> false
        The root itself is not "under" the root.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Candidate, [string] $Root)

    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }

    $sep  = [System.IO.Path]::DirectorySeparatorChar
    $c    = Get-NormalizedFullPath -Path $Candidate
    $r    = Get-NormalizedFullPath -Path $Root
    $cmp  = [System.StringComparison]::OrdinalIgnoreCase

    if ($c.Equals($r, $cmp)) { return $false }
    return $c.StartsWith($r + $sep, $cmp)
}

function Test-DirectoryNonEmpty {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    return ($entries.Count -gt 0)
}

function Write-JsonArtifact {
    <# Writes an object as UTF-8 JSON, refusing to overwrite. #>
    [CmdletBinding()]
    param([string] $Path, [object] $Data)

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite an existing artifact: '$Path'."
    }
    $json = $Data | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -NoNewline:$false
}

function Remove-CreatedArtifact {
    <#
    .SYNOPSIS
        Rolls back only what this invocation created.
    .DESCRIPTION
        Deletes the recorded paths in reverse order, each one individually and
        only when it lies under $RunsRoot. Directories are removed only when
        empty. A pre-existing run directory is never touched, and no recursive
        delete is issued against an unverified path.
    #>
    [CmdletBinding()]
    param([string[]] $CreatedPaths, [string] $RunsRoot)

    for ($i = $CreatedPaths.Count - 1; $i -ge 0; $i--) {
        $p = $CreatedPaths[$i]
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-PathUnderRoot -Candidate $p -Root $RunsRoot)) { continue }   # never operate outside the root
        try {
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $p -PathType Container) {
                # Empty directories only; no recursive delete is ever issued.
                if (-not (Test-DirectoryNonEmpty -Path $p)) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Verbose "Rollback could not remove '$p': $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function New-AgentRunDirectory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()] [string] $TaskFile,
        [AllowEmptyString()] [string] $RunId,
        [AllowEmptyString()] [string] $RunDirectory,
        [AllowEmptyString()] [string] $ProjectStateFile
    )

    $r = New-RunResult -Result $null -Code $null -Reason $null

    # --- 1. project state / runtime root ---------------------------------
    if ([string]::IsNullOrWhiteSpace($ProjectStateFile)) {
        $scriptDir = Split-Path -Parent $PSCommandPath
        $ProjectStateFile = Join-Path (Split-Path -Parent $scriptDir) 'config/PROJECT_STATE.json'
    }
    if (-not (Test-Path -LiteralPath $ProjectStateFile -PathType Leaf)) {
        $r.result = 'INPUT_ERROR'; $r.code = 'project_state_not_found'
        $r.reason = "PROJECT_STATE.json not found: '$ProjectStateFile'."
        return [pscustomobject]$r
    }
    try {
        $projectState = Get-Content -LiteralPath $ProjectStateFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $r.result = 'INPUT_ERROR'; $r.code = 'project_state_not_valid_json'
        $r.reason = "PROJECT_STATE.json is not valid JSON: '$ProjectStateFile'. $($_.Exception.Message)"
        return [pscustomobject]$r
    }
    if ($projectState.PSObject.Properties.Name -notcontains 'runtime_runs_root' -or
        [string]::IsNullOrWhiteSpace($projectState.runtime_runs_root)) {
        $r.result = 'INPUT_ERROR'; $r.code = 'runtime_runs_root_missing'
        $r.reason = "PROJECT_STATE.json has no usable 'runtime_runs_root'."
        return [pscustomobject]$r
    }
    $runsRoot = Get-NormalizedFullPath -Path $projectState.runtime_runs_root

    # --- 2. task file ------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($TaskFile) -or -not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) {
        $r.result = 'INPUT_ERROR'; $r.code = 'task_not_found'
        $r.reason = "Task file not found: '$TaskFile'."
        return [pscustomobject]$r
    }
    try {
        $taskRaw  = Get-Content -LiteralPath $TaskFile -Raw -Encoding UTF8
        $task     = $taskRaw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $r.result = 'INPUT_ERROR'; $r.code = 'task_not_valid_json'
        $r.reason = "Task file is not valid JSON: '$TaskFile'. $($_.Exception.Message)"
        return [pscustomobject]$r
    }
    $missing = @($script:RequiredTaskFields | Where-Object { $task.PSObject.Properties.Name -notcontains $_ })
    if ($missing.Count -gt 0) {
        $r.result = 'INPUT_ERROR'; $r.code = 'task_missing_required_fields'
        $r.reason = "Task file is missing required field(s): $($missing -join ', ')."
        return [pscustomobject]$r
    }
    if ([string]::IsNullOrWhiteSpace([string]$task.task_id)) {
        $r.result = 'INPUT_ERROR'; $r.code = 'task_id_empty'
        $r.reason = 'Task file has an empty task_id.'
        return [pscustomobject]$r
    }
    $r.task_id = [string]$task.task_id

    # --- 3. run id ---------------------------------------------------------
    $idCheck = Test-SafeRunId -RunId $RunId
    if (-not $idCheck.Safe) {
        $r.result = 'REJECTED'; $r.code = 'unsafe_run_id'; $r.reason = $idCheck.Reason
        return [pscustomobject]$r
    }
    $r.run_id = $RunId

    # --- 4. run directory + containment -----------------------------------
    $targetDir = if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
        Join-Path $runsRoot $RunId
    }
    else {
        $RunDirectory
    }
    try { $targetDir = Get-NormalizedFullPath -Path $targetDir }
    catch {
        $r.result = 'REJECTED'; $r.code = 'run_directory_unresolvable'
        $r.reason = "Run directory could not be resolved: '$targetDir'. $($_.Exception.Message)"
        return [pscustomobject]$r
    }
    $r.run_directory = $targetDir

    # Boundary-aware containment; rejects sibling-prefix escapes.
    if (-not (Test-PathUnderRoot -Candidate $targetDir -Root $runsRoot)) {
        $r.result = 'REJECTED'; $r.code = 'outside_runtime_root'
        $r.reason = "Run directory '$targetDir' is not strictly under runtime_runs_root '$runsRoot'."
        return [pscustomobject]$r
    }

    # --- 5. existing run directory / artifacts ----------------------------
    $dirPreexisted = Test-Path -LiteralPath $targetDir -PathType Container

    if (Test-Path -LiteralPath $targetDir -PathType Leaf) {
        $r.result = 'REJECTED'; $r.code = 'run_path_is_file'
        $r.reason = "Run path '$targetDir' already exists as a file."
        return [pscustomobject]$r
    }
    if ($dirPreexisted -and (Test-DirectoryNonEmpty -Path $targetDir)) {
        $r.result = 'REJECTED'; $r.code = 'run_directory_not_empty'
        $r.reason = "Run directory '$targetDir' already exists and is not empty."
        return [pscustomobject]$r
    }
    foreach ($a in $script:RunArtifacts) {
        if (Test-Path -LiteralPath (Join-Path $targetDir $a)) {
            $r.result = 'REJECTED'; $r.code = 'artifact_exists'
            $r.reason = "Refusing to replace an existing runtime artifact: '$a'."
            return [pscustomobject]$r
        }
    }

    # --- 6. create ---------------------------------------------------------
    $created = [System.Collections.Generic.List[string]]::new()
    $now     = Get-UtcTimestamp

    try {
        if (-not $dirPreexisted) {
            New-Item -ItemType Directory -Path $targetDir -Force:$false -ErrorAction Stop | Out-Null
            $created.Add($targetDir) | Out-Null
        }

        # TASK.json - byte-preserving copy of the caller's definition.
        $taskDest = Join-Path $targetDir 'TASK.json'
        Copy-Item -LiteralPath $TaskFile -Destination $taskDest -ErrorAction Stop
        $created.Add($taskDest) | Out-Null

        # STATUS.json - schemas\STATUS.schema.json
        $statusDest = Join-Path $targetDir 'STATUS.json'
        Write-JsonArtifact -Path $statusDest -Data ([ordered]@{
            task_id         = [string]$task.task_id
            state           = $script:InitialState
            correction_rounds = 0
            worker_calls    = 0
            reviewer_calls  = 0
            updated_at      = $now
            started_at      = $now
            total_tokens    = 0
        })
        $created.Add($statusDest) | Out-Null

        # USAGE.json - schemas\USAGE.schema.json, all counters zero.
        $usageDest = Join-Path $targetDir 'USAGE.json'
        Write-JsonArtifact -Path $usageDest -Data ([ordered]@{
            task_id           = [string]$task.task_id
            worker_calls      = 0
            reviewer_calls    = 0
            correction_rounds = 0
            runtime_seconds   = 0
            total_tokens      = 0
        })
        $created.Add($usageDest) | Out-Null

        # logs\ - empty
        $logsDest = Join-Path $targetDir 'logs'
        New-Item -ItemType Directory -Path $logsDest -Force:$false -ErrorAction Stop | Out-Null
        $created.Add($logsDest) | Out-Null
    }
    catch {
        Remove-CreatedArtifact -CreatedPaths $created.ToArray() -RunsRoot $runsRoot
        $r.result = 'INPUT_ERROR'; $r.code = 'initialization_failed'
        $r.reason = "Initialization failed and was rolled back: $($_.Exception.Message)"
        return [pscustomobject]$r
    }

    $r.result        = 'CREATED'
    $r.code          = 'run_initialized'
    $r.reason        = "Run directory initialized at '$targetDir'."
    $r.initial_state = $script:InitialState
    $r.created       = $created.ToArray()
    return [pscustomobject]$r
}

function Get-AgentRunExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)] [pscustomobject] $Result)

    switch ($Result.result) {
        'CREATED'     { return 0 }
        'REJECTED'    { return 2 }
        'INPUT_ERROR' { return 3 }
        default       { return 3 }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $outcome = New-AgentRunDirectory -TaskFile $TaskFile -RunId $RunId `
                                     -RunDirectory $RunDirectory -ProjectStateFile $ProjectStateFile
    if ($AsJson) { $outcome | ConvertTo-Json -Compress -Depth 6 } else { $outcome }
    exit (Get-AgentRunExitCode -Result $outcome)
}
