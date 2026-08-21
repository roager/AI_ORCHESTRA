#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic scope validator for the AI_ORCHESTRA Supervisor.

.DESCRIPTION
    Compares the files actually changed in a worktree against the
    allowed_paths / forbidden_paths of a TASK.json.

    Enforces OUT_OF_SCOPE_CHANGES_CANNOT_BE_SILENTLY_PUBLISHED. Deterministic
    evidence (Git) is authoritative; a worker's own files_changed list is not
    consulted.

    Read-only: only `git diff`, `git status` and `git ls-files` are executed.
    No repository file is created, modified or deleted.

.PARAMETER TaskPath
    Path to a TASK.json conforming to schemas\TASK.schema.json.

.PARAMETER RepositoryPath
    Path to the repository or worktree to inspect.

.PARAMETER DiffOnly
    Restrict detection to `git diff --name-only` (unstaged tracked changes).
    Default behaviour additionally includes staged changes and untracked files,
    which is strictly stronger — a newly added out-of-scope file cannot escape
    detection. See ASSUMPTIONS in the task report.

.PARAMETER AsJson
    Emit the result as JSON instead of a PSCustomObject.

.OUTPUTS
    PSCustomObject (or JSON with -AsJson):
      validator, result, code, reason, changed_files[], violations[]
    Each violation: file, kind (FORBIDDEN_PATH | OUT_OF_SCOPE), matched_path

.NOTES
    Exit codes (shared by all AI_ORCHESTRA validators):
      0  PASS         every changed file is in scope (including zero changes)
      1  WARNING      not used by this validator
      2  FAIL         at least one forbidden or out-of-scope change
      3  INPUT_ERROR  bad task file, bad path, or Git failure

    Matching rule: a changed file F matches a scope entry P when F equals P or
    F begins with P + '/'. Comparison is case-insensitive (Windows-first) on
    forward-slash-normalised, repository-relative paths.

.EXAMPLE
    .\Test-AgentScope.ps1 -TaskPath .\TASK.json -RepositoryPath C:\tmp\ai-orchestra-worktrees\demo
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string] $TaskPath,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string] $RepositoryPath,

    [switch] $DiffOnly,
    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedPath {
    <#
    .SYNOPSIS
        Normalises a Git or Windows path for comparison.
    .DESCRIPTION
        - unwraps Git's C-style quoting for paths with special characters
        - converts backslashes to forward slashes
        - collapses duplicate separators
        - strips a leading './' and any leading or trailing '/'
        Returns an empty string for null/whitespace input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] [AllowEmptyString()] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $p = $Path.Trim()

    # Git quotes paths containing non-ASCII or special characters: "src/\303\251.txt"
    if ($p.Length -ge 2 -and $p.StartsWith('"') -and $p.EndsWith('"')) {
        $p = $p.Substring(1, $p.Length - 2)
        $p = $p -replace '\\"', '"'
    }

    $p = $p -replace '\\', '/'
    while ($p -match '//') { $p = $p -replace '//', '/' }
    if ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p.Trim('/')
}

function Test-PathInScope {
    <# True when $File equals $ScopeEntry or sits beneath it. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $File, [string] $ScopeEntry)

    if ([string]::IsNullOrWhiteSpace($ScopeEntry)) { return $false }
    if ([string]::IsNullOrWhiteSpace($File))       { return $false }

    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if ($File.Equals($ScopeEntry, $cmp)) { return $true }
    return $File.StartsWith($ScopeEntry + '/', $cmp)
}

function Get-MatchingScopeEntry {
    <# Returns the first scope entry matching $File, else $null. #>
    [CmdletBinding()]
    param([string] $File, [string[]] $ScopeEntries)

    foreach ($entry in $ScopeEntries) {
        if (Test-PathInScope -File $File -ScopeEntry $entry) { return $entry }
    }
    return $null
}

function Invoke-GitRead {
    <# Runs a read-only git command and returns its stdout lines. Throws on failure. #>
    [CmdletBinding()]
    param([string] $RepositoryPath, [string[]] $GitArgs)

    $out = & git -C $RepositoryPath @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    return @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
}

function Get-ChangedFile {
    <# Union of changed paths in the worktree, as normalised repo-relative paths. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string] $RepositoryPath, [switch] $DiffOnly)

    $lines = [System.Collections.Generic.List[string]]::new()

    # Unstaged tracked modifications - the baseline required by the task spec.
    Invoke-GitRead -RepositoryPath $RepositoryPath -GitArgs @('diff', '--name-only') |
        ForEach-Object { $lines.Add($_) | Out-Null }

    if (-not $DiffOnly) {
        # Staged changes.
        Invoke-GitRead -RepositoryPath $RepositoryPath -GitArgs @('diff', '--cached', '--name-only') |
            ForEach-Object { $lines.Add($_) | Out-Null }
        # Untracked, honouring .gitignore.
        Invoke-GitRead -RepositoryPath $RepositoryPath -GitArgs @('ls-files', '--others', '--exclude-standard') |
            ForEach-Object { $lines.Add($_) | Out-Null }
    }

    $normalized = $lines |
        ForEach-Object { ConvertTo-NormalizedPath -Path $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    return @($normalized | Sort-Object -Unique)
}

function Test-AgentScopeCompliance {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $TaskPath,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $RepositoryPath,
        [switch] $DiffOnly
    )

    $result = [ordered]@{
        validator     = 'Test-AgentScope'
        result        = $null
        code          = $null
        reason        = $null
        changed_files = @()
        violations    = @()
    }

    # --- load task --------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($TaskPath) -or -not (Test-Path -LiteralPath $TaskPath -PathType Leaf)) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'task_not_found'
        $result.reason = "Task file not found: '$TaskPath'."
        return [pscustomobject]$result
    }
    try {
        $task = Get-Content -LiteralPath $TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'task_not_valid_json'
        $result.reason = "Task file is not valid JSON: '$TaskPath'. $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    foreach ($key in @('allowed_paths', 'forbidden_paths')) {
        if ($task.PSObject.Properties.Name -notcontains $key) {
            $result.result = 'INPUT_ERROR'
            $result.code   = 'task_missing_scope'
            $result.reason = "Task file has no '$key'. TASK.schema.json requires it."
            return [pscustomobject]$result
        }
    }

    $allowed = @(@($task.allowed_paths)   | ForEach-Object { ConvertTo-NormalizedPath -Path $_ } | Where-Object { $_ })
    $forbidden = @(@($task.forbidden_paths) | ForEach-Object { ConvertTo-NormalizedPath -Path $_ } | Where-Object { $_ })

    # --- repository -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($RepositoryPath) -or -not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'repository_not_found'
        $result.reason = "Repository path not found: '$RepositoryPath'."
        return [pscustomobject]$result
    }

    try {
        $inside = Invoke-GitRead -RepositoryPath $RepositoryPath -GitArgs @('rev-parse', '--is-inside-work-tree')
        if (($inside -join '').Trim() -ne 'true') { throw 'Path is not inside a Git work tree.' }
        $changed = @(Get-ChangedFile -RepositoryPath $RepositoryPath -DiffOnly:$DiffOnly)
    }
    catch {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'git_unavailable'
        $result.reason = $_.Exception.Message
        return [pscustomobject]$result
    }

    $result.changed_files = $changed

    # --- no changes is valid ---------------------------------------------
    if ($changed.Count -eq 0) {
        $result.result = 'PASS'
        $result.code   = 'no_changes'
        $result.reason = 'No changed files. Nothing can be out of scope.'
        return [pscustomobject]$result
    }

    # --- evaluate ---------------------------------------------------------
    $violations = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $changed) {
        # forbidden_paths always win, evaluated before allowed_paths
        $hitForbidden = Get-MatchingScopeEntry -File $file -ScopeEntries $forbidden
        if ($null -ne $hitForbidden) {
            $violations.Add([pscustomobject][ordered]@{
                file         = $file
                kind         = 'FORBIDDEN_PATH'
                matched_path = $hitForbidden
            }) | Out-Null
            continue
        }

        $hitAllowed = Get-MatchingScopeEntry -File $file -ScopeEntries $allowed
        if ($null -eq $hitAllowed) {
            $violations.Add([pscustomobject][ordered]@{
                file         = $file
                kind         = 'OUT_OF_SCOPE'
                matched_path = $null
            }) | Out-Null
        }
    }

    $result.violations = $violations.ToArray()

    if ($violations.Count -gt 0) {
        $nForbidden = @($violations | Where-Object { $_.kind -eq 'FORBIDDEN_PATH' }).Count
        $nOut       = @($violations | Where-Object { $_.kind -eq 'OUT_OF_SCOPE' }).Count
        $result.result = 'FAIL'
        $result.code   = $(if ($nForbidden -gt 0) { 'forbidden_path_modified' } else { 'out_of_scope_change' })
        $result.reason = "Scope violation: $nForbidden forbidden-path change(s), $nOut out-of-scope change(s), of $($changed.Count) changed file(s)."
        return [pscustomobject]$result
    }

    $result.result = 'PASS'
    $result.code   = 'in_scope'
    $result.reason = "All $($changed.Count) changed file(s) are within allowed_paths and clear of forbidden_paths."
    return [pscustomobject]$result
}

function Get-AgentScopeExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)] [pscustomobject] $Verdict)

    switch ($Verdict.result) {
        'PASS'        { return 0 }
        'WARNING'     { return 1 }
        'FAIL'        { return 2 }
        'INPUT_ERROR' { return 3 }
        default       { return 3 }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $verdict = Test-AgentScopeCompliance -TaskPath $TaskPath -RepositoryPath $RepositoryPath -DiffOnly:$DiffOnly
    if ($AsJson) { $verdict | ConvertTo-Json -Compress -Depth 6 } else { $verdict }
    exit (Get-AgentScopeExitCode -Verdict $verdict)
}
