#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\Test-AgentScope.ps1.
.NOTES
    Invoked by tests\Run-AllTests.ps1. Returns the failure count.
    Builds throwaway Git repositories under the system temp directory.
    The AI_ORCHESTRA repository is never written to.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $here
$scriptPath = Join-Path $repoRoot 'scripts/Test-AgentScope.ps1'

. (Join-Path $here 'TestHelpers.ps1')
. $scriptPath

Set-TestSuite 'Test-AgentScope'

$fixtures = [System.Collections.Generic.List[string]]::new()

function New-ScopeFixture {
    <# Fresh repo + TASK.json. Returns @{ Repo; Task }. #>
    param(
        [string[]] $AllowedPaths   = @('src/api', 'tests/api'),
        [string[]] $ForbiddenPaths = @('.github', 'infra')
    )
    $repo = New-TestGitRepository -InitialFiles @('src/api/existing.py', 'infra/deploy.yaml', '.github/workflows/ci.yml')
    $script:fixtures.Add($repo) | Out-Null
    $taskDir = New-TempDirectory
    $script:fixtures.Add($taskDir) | Out-Null
    $task = New-TestTaskFile -Directory $taskDir -AllowedPaths $AllowedPaths -ForbiddenPaths $ForbiddenPaths
    return @{ Repo = $repo; Task = $task }
}

function Invoke-ScopeCase {
    param([string] $Task, [string] $Repo, [switch] $DiffOnly)
    $v = Test-AgentScopeCompliance -TaskPath $Task -RepositoryPath $Repo -DiffOnly:$DiffOnly
    return [pscustomobject]@{ Verdict = $v; ExitCode = (Get-AgentScopeExitCode -Verdict $v) }
}

try {
    # -----------------------------------------------------------------------
    # POSITIVE: no changed files
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'clean worktree is PASS'  -Expected 'PASS'       -Actual $r.Verdict.result
    Assert-Equal -Name 'clean worktree code'     -Expected 'no_changes' -Actual $r.Verdict.code
    Assert-Equal -Name 'clean worktree exits 0'  -Expected 0            -Actual $r.ExitCode

    # -----------------------------------------------------------------------
    # POSITIVE: allowed file change (modified tracked file)
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'allowed file change is PASS' -Expected 'PASS' -Actual $r.Verdict.result
    Assert-Equal -Name 'allowed file change exits 0' -Expected 0      -Actual $r.ExitCode
    Assert-CollectionEqual -Name 'changed file is reported' -Expected @('src/api/existing.py') -Actual @($r.Verdict.changed_files)

    # POSITIVE: new file inside an allowed path
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'tests/api/test_new.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'new file inside allowed path is PASS' -Expected 'PASS' -Actual $r.Verdict.result

    # POSITIVE: deeply nested file under an allowed prefix
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/v2/handlers/deep.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'nested file under allowed prefix is PASS' -Expected 'PASS' -Actual $r.Verdict.result

    # POSITIVE: several allowed changes at once
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'tests/api/test_a.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'multiple allowed changes is PASS' -Expected 'PASS' -Actual $r.Verdict.result
    Assert-Equal -Name 'both changes counted' -Expected 2 -Actual @($r.Verdict.changed_files).Count

    # POSITIVE: staged allowed change is detected
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/staged.py'
    & git -C $f.Repo add 'src/api/staged.py' 2>&1 | Out-Null
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'staged allowed change is PASS' -Expected 'PASS' -Actual $r.Verdict.result
    Assert-True  -Name 'staged change appears in changed_files' `
        -Condition (@($r.Verdict.changed_files) -contains 'src/api/staged.py')

    # -----------------------------------------------------------------------
    # NEGATIVE: forbidden file change
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'infra/deploy.yaml' -Content 'modified'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'forbidden file change is FAIL' -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name 'forbidden file change exits 2' -Expected 2      -Actual $r.ExitCode
    Assert-Equal -Name 'forbidden violation kind'      -Expected 'FORBIDDEN_PATH' -Actual $r.Verdict.violations[0].kind
    Assert-Equal -Name 'forbidden violation names the matched scope entry' -Expected 'infra' -Actual $r.Verdict.violations[0].matched_path

    # NEGATIVE: nested file under a forbidden prefix
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath '.github/workflows/ci.yml' -Content 'modified'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'nested forbidden path change is FAIL' -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name 'nested forbidden violation kind' -Expected 'FORBIDDEN_PATH' -Actual $r.Verdict.violations[0].kind

    # NEGATIVE: forbidden always wins over allowed (overlapping scope)
    $f = New-ScopeFixture -AllowedPaths @('src') -ForbiddenPaths @('src/secrets')
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/secrets/keys.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'forbidden beats allowed when scopes overlap' -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name 'overlap resolves to FORBIDDEN_PATH, not OUT_OF_SCOPE' `
        -Expected 'FORBIDDEN_PATH' -Actual $r.Verdict.violations[0].kind
    Assert-Equal -Name 'overlap code is forbidden_path_modified' -Expected 'forbidden_path_modified' -Actual $r.Verdict.code

    # -----------------------------------------------------------------------
    # NEGATIVE: out-of-scope file change
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/web/app.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'out-of-scope change is FAIL' -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name 'out-of-scope exits 2'        -Expected 2      -Actual $r.ExitCode
    Assert-Equal -Name 'out-of-scope violation kind' -Expected 'OUT_OF_SCOPE' -Actual $r.Verdict.violations[0].kind
    Assert-Equal -Name 'out-of-scope code'           -Expected 'out_of_scope_change' -Actual $r.Verdict.code

    # A sibling directory sharing a name prefix must not be treated as in scope.
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api_v2/thing.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name "'src/api_v2' is NOT inside 'src/api' (prefix must respect boundaries)" `
        -Expected 'FAIL' -Actual $r.Verdict.result

    # Repository root file is out of scope.
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'README.md'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'root-level file is out of scope' -Expected 'FAIL' -Actual $r.Verdict.result

    # Mixed: one allowed, one out of scope -> still fails, and only the bad one is listed.
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/web/app.py'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'mixed allowed + out-of-scope is FAIL' -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name 'only the offending file is a violation' -Expected 1 -Actual @($r.Verdict.violations).Count
    Assert-Equal -Name 'violation names the offending file' -Expected 'src/web/app.py' -Actual $r.Verdict.violations[0].file

    # Empty allowed_paths authorises nothing.
    $f = New-ScopeFixture -AllowedPaths @() -ForbiddenPaths @('infra')
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'empty allowed_paths authorises nothing' -Expected 'FAIL' -Actual $r.Verdict.result

    # Empty allowed_paths with a clean tree is still PASS (nothing changed).
    $f = New-ScopeFixture -AllowedPaths @() -ForbiddenPaths @()
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'empty scope + clean tree is PASS' -Expected 'PASS' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # Path normalisation
    # -----------------------------------------------------------------------
    Assert-Equal -Name 'backslashes normalised'     -Expected 'src/api/foo.py' -Actual (ConvertTo-NormalizedPath -Path 'src\api\foo.py')
    Assert-Equal -Name 'leading ./ stripped'        -Expected 'src/api'        -Actual (ConvertTo-NormalizedPath -Path './src/api')
    Assert-Equal -Name 'trailing slash stripped'    -Expected 'src/api'        -Actual (ConvertTo-NormalizedPath -Path 'src/api/')
    Assert-Equal -Name 'duplicate separators collapsed' -Expected 'src/api'    -Actual (ConvertTo-NormalizedPath -Path 'src//api')
    Assert-Equal -Name 'git quoting unwrapped'      -Expected 'src/api/x.py'   -Actual (ConvertTo-NormalizedPath -Path '"src/api/x.py"')
    Assert-Equal -Name 'empty path normalises to empty' -Expected ''           -Actual (ConvertTo-NormalizedPath -Path '   ')

    Assert-True -Name 'exact match is in scope'        -Condition (Test-PathInScope -File 'src/api' -ScopeEntry 'src/api')
    Assert-True -Name 'child is in scope'              -Condition (Test-PathInScope -File 'src/api/x.py' -ScopeEntry 'src/api')
    Assert-True -Name 'sibling prefix is NOT in scope' -Condition (-not (Test-PathInScope -File 'src/apix/y.py' -ScopeEntry 'src/api'))
    Assert-True -Name 'parent is NOT in scope'         -Condition (-not (Test-PathInScope -File 'src' -ScopeEntry 'src/api'))
    Assert-True -Name 'comparison is case-insensitive' -Condition (Test-PathInScope -File 'SRC/API/x.py' -ScopeEntry 'src/api')

    # Windows-style separators in TASK.json must still match Git output.
    $f = New-ScopeFixture -AllowedPaths @('src\api') -ForbiddenPaths @('infra')
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    $r = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    Assert-Equal -Name 'backslash scope entry in TASK.json matches git output' -Expected 'PASS' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # -DiffOnly narrows detection to unstaged tracked changes
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/web/untracked.py'
    $rDefault = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    $rDiff    = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo -DiffOnly
    Assert-Equal -Name 'default mode catches an untracked out-of-scope file' -Expected 'FAIL' -Actual $rDefault.Verdict.result
    Assert-Equal -Name '-DiffOnly does not see untracked files'              -Expected 'PASS' -Actual $rDiff.Verdict.result

    # -----------------------------------------------------------------------
    # Read-only guarantee
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    Set-RepositoryFile -Repository $f.Repo -RelativePath 'src/api/existing.py' -Content 'modified'
    $before = (& git -C $f.Repo status --porcelain) -join "`n"
    $null   = Invoke-ScopeCase -Task $f.Task -Repo $f.Repo
    $after  = (& git -C $f.Repo status --porcelain) -join "`n"
    Assert-Equal -Name 'validator does not modify repository state' -Expected $before -Actual $after

    # -----------------------------------------------------------------------
    # NEGATIVE: input errors
    # -----------------------------------------------------------------------
    $f = New-ScopeFixture
    $v = Test-AgentScopeCompliance -TaskPath (Join-Path $f.Repo 'nope.json') -RepositoryPath $f.Repo
    Assert-Equal -Name 'missing task file is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result
    Assert-Equal -Name 'missing task file exits 3' -Expected 3 -Actual (Get-AgentScopeExitCode -Verdict $v)

    $badTask = Join-Path $f.Repo 'bad.json'
    Set-Content -LiteralPath $badTask -Value '{ not json' -Encoding UTF8
    $v = Test-AgentScopeCompliance -TaskPath $badTask -RepositoryPath $f.Repo
    Assert-Equal -Name 'malformed task file is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    $noScope = New-TestJsonFile -Directory $f.Repo -FileName 'noscope.json' -Data @{ task_id = 'x'; objective = 'y' }
    $v = Test-AgentScopeCompliance -TaskPath $noScope -RepositoryPath $f.Repo
    Assert-Equal -Name 'task without allowed_paths is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result
    Assert-Equal -Name 'missing-scope code' -Expected 'task_missing_scope' -Actual $v.code

    $v = Test-AgentScopeCompliance -TaskPath $f.Task -RepositoryPath (Join-Path ([System.IO.Path]::GetTempPath()) 'ao-no-such-dir-xyz')
    Assert-Equal -Name 'missing repository path is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    $notARepo = New-TempDirectory
    $fixtures.Add($notARepo) | Out-Null
    $v = Test-AgentScopeCompliance -TaskPath $f.Task -RepositoryPath $notARepo
    Assert-Equal -Name 'non-Git directory is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result
    Assert-Equal -Name 'non-Git directory code' -Expected 'git_unavailable' -Actual $v.code
}
finally {
    foreach ($d in $fixtures) { Remove-TempDirectory -Path $d }
}

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
