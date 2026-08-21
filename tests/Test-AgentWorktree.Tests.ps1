#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\New-AgentWorktree.ps1 and scripts\Remove-AgentWorktree.ps1.
.NOTES
    Invoked by tests\Run-AllTests.ps1. Returns the failure count.
    Builds throwaway Git repositories under the system temp directory.
    The AI_ORCHESTRA repository is never written to.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $here
$newScript  = Join-Path $repoRoot 'scripts/New-AgentWorktree.ps1'
$removeScript = Join-Path $repoRoot 'scripts/Remove-AgentWorktree.ps1'

. (Join-Path $here 'TestHelpers.ps1')

Set-TestSuite 'Test-AgentWorktree'

$fixtures = [System.Collections.Generic.List[string]]::new()

function New-WorktreeFixture {
    # Creates a root temp folder
    $tmpDir = New-TempDirectory
    $script:fixtures.Add($tmpDir) | Out-Null

    # Create source repo
    $repo = New-TestGitRepository -InitialFiles @('README.md')
    $script:fixtures.Add($repo) | Out-Null
    
    # Create runtime worktree root directory
    $worktreeRoot = Join-Path $tmpDir "worktree_root"
    $null = New-Item -ItemType Directory -Path $worktreeRoot -Force

    # Write a fake PROJECT_STATE.json in $repo/config/PROJECT_STATE.json
    $null = New-Item -ItemType Directory -Path (Join-Path $repo "config") -Force
    $projectState = @{
        project_name          = "TEST_ORCHESTRA"
        repository            = "owner/test"
        default_branch        = "main"
        protected_branches    = @("main", "stable")
        source_root           = $repo
        runtime_worktree_root = $worktreeRoot
        runtime_runs_root     = (Join-Path $tmpDir "runs")
        current_phase         = "Phase 1"
    }
    $null = New-TestJsonFile -Directory (Join-Path $repo "config") -FileName "PROJECT_STATE.json" -Data $projectState

    return @{
        TmpDir       = $tmpDir
        Repo         = $repo
        WorktreeRoot = $worktreeRoot
    }
}

try {
    # =======================================================================
    # SUCCESS CASES (1 - 7)
    # =======================================================================
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-101"
        project             = "TEST_ORCHESTRA"
        repository          = "owner/test"
        branch              = "agent/task-101"
        workspace           = (Join-Path $f.WorktreeRoot "task-101")
        objective           = "Implement feature X"
        allowed_paths       = @("src/")
        forbidden_paths     = @()
        acceptance_criteria = @("Code passes tests")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    
    # 1. Create worktree for valid task
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    
    Assert-Equal -Name 'create worktree - result is CREATED' -Expected 'CREATED' -Actual $res.result
    Assert-Equal -Name 'create worktree - task_id matches' -Expected 'task-101' -Actual $res.task_id
    Assert-Equal -Name 'create worktree - workspace path matches' -Expected (Join-Path $f.WorktreeRoot "task-101") -Actual $res.workspace
    Assert-Equal -Name 'create worktree - branch matches' -Expected 'agent/task-101' -Actual $res.branch
    # 2. Correct branch is created
    $branches = & git -C $f.Repo branch --list 2>&1
    Assert-True -Name 'correct branch is created in source repo' -Condition (@($branches -match 'agent/task-101').Count -gt 0)
    
    # 3. Worktree is registered
    $wtList = & git -C $f.Repo worktree list --porcelain 2>&1
    Assert-True -Name 'worktree is registered in Git' -Condition (@($wtList -match 'task-101').Count -gt 0)
    
    # 4. Base commit matches expected HEAD
    $headCommit = (& git -C $f.Repo rev-parse HEAD 2>&1).Trim()
    Assert-Equal -Name 'base_commit matches expected HEAD commit' -Expected $headCommit -Actual $res.base_commit
    
    # 5. Primary working tree remains unchanged
    $srcHeadBranch = (& git -C $f.Repo branch --show-current 2>&1).Trim()
    Assert-Equal -Name 'primary working tree active branch is unchanged (main)' -Expected 'main' -Actual $srcHeadBranch
    
    # 6. Remove clean worktree successfully
    $rem = & $removeScript -WorkspacePath (Join-Path $f.WorktreeRoot "task-101") -SourceRepositoryPath $f.Repo -AsJson
    $remRes = $rem | ConvertFrom-Json
    
    Assert-Equal -Name 'remove clean worktree - result is REMOVED' -Expected 'REMOVED' -Actual $remRes.result
    Assert-Equal -Name 'remove clean worktree - branch matches' -Expected 'agent/task-101' -Actual $remRes.branch
    
    $wtList2 = & git -C $f.Repo worktree list --porcelain 2>&1
    Assert-True -Name 'worktree is no longer registered' -Condition (@($wtList2 -match 'task-101').Count -eq 0)
    
    # 7. Task branch remains after removal
    $branches2 = & git -C $f.Repo branch --list 2>&1
    Assert-True -Name 'task branch remains locally after worktree removal' -Condition (@($branches2 -match 'agent/task-101').Count -gt 0)

    # =======================================================================
    # REJECTION CASES (8 - 19)
    # =======================================================================
    
    # 8. Reject protected branch
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-pb"
        branch              = "stable"
        workspace           = (Join-Path $f.WorktreeRoot "task-pb")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject protected branch (stable) - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject protected branch (stable) - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 9. Reject main
    $taskData.branch = "main"
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject protected branch (main) - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject protected branch (main) - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 10. Reject master
    $taskData.branch = "master"
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject protected branch (master) - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject protected branch (master) - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 11. Reject workspace outside runtime_worktree_root
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-outside"
        branch              = "agent/task-outside"
        workspace           = (Join-Path $f.TmpDir "outside-folder/task-outside")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject workspace outside root - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject workspace outside root - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 12. Reject existing non-empty workspace
    $f = New-WorktreeFixture
    $wsDir = Join-Path $f.WorktreeRoot "task-nonempty"
    $null = New-Item -ItemType Directory -Path $wsDir -Force
    Set-Content -LiteralPath (Join-Path $wsDir "unrelated.txt") -Value "unrelated" -Encoding UTF8
    
    $taskData = @{
        task_id             = "task-nonempty"
        branch              = "agent/task-nonempty"
        workspace           = $wsDir
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject non-empty workspace - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject non-empty workspace - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 13. Reject malformed TASK.json
    $f = New-WorktreeFixture
    $badTaskFile = Join-Path $f.TmpDir "TASK-bad.json"
    Set-Content -LiteralPath $badTaskFile -Value '{ "task_id": ' -Encoding UTF8
    
    $v = & $newScript -TaskPath $badTaskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject malformed TASK.json - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject malformed TASK.json - exit code is 3' -Condition ($LASTEXITCODE -eq 3)

    # 14. Reject missing source repository
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-missing-repo"
        branch              = "agent/task-missing-repo"
        workspace           = (Join-Path $f.WorktreeRoot "task-missing-repo")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath (Join-Path $f.TmpDir "nonexistent-repo") -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject missing source repository - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject missing source repository - exit code is 3' -Condition ($LASTEXITCODE -eq 3)

    # 15. Reject non-Git source directory
    $f = New-WorktreeFixture
    $nonGitDir = Join-Path $f.TmpDir "non-git-dir"
    $null = New-Item -ItemType Directory -Path $nonGitDir -Force
    $taskData = @{
        task_id             = "task-nongit"
        branch              = "agent/task-nongit"
        workspace           = (Join-Path $f.WorktreeRoot "task-nongit")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $nonGitDir -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject non-Git source directory - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject non-Git source directory - exit code is 3' -Condition ($LASTEXITCODE -eq 3)

    # 16. Reject removal of unregistered directory
    $f = New-WorktreeFixture
    $unregDir = Join-Path $f.WorktreeRoot "unregistered-dir"
    $null = New-Item -ItemType Directory -Path $unregDir -Force
    
    $v = & $removeScript -WorkspacePath $unregDir -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject remove unregistered directory - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject remove unregistered directory - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 17. Reject removal outside runtime_worktree_root
    $f = New-WorktreeFixture
    $v = & $removeScript -WorkspacePath (Join-Path $f.TmpDir "outside-remove") -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject remove outside root - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject remove outside root - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 18. Reject removal of dirty worktree
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-dirty"
        branch              = "agent/task-dirty"
        workspace           = (Join-Path $f.WorktreeRoot "task-dirty")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $null = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    
    # Dirty the worktree by adding a file
    $wsDir = Join-Path $f.WorktreeRoot "task-dirty"
    Set-Content -LiteralPath (Join-Path $wsDir "newfile.txt") -Value "dirty" -Encoding UTF8
    
    $v = & $removeScript -WorkspacePath $wsDir -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject removal of dirty worktree - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject removal of dirty worktree - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 19. Reject attempt to remove primary working tree
    $f = New-WorktreeFixture
    $parent = Split-Path -Parent $f.Repo
    $projectStateCustom = @{
        project_name          = "TEST_ORCHESTRA"
        repository            = "owner/test"
        default_branch        = "main"
        protected_branches    = @("main")
        source_root           = $f.Repo
        runtime_worktree_root = $parent
        runtime_runs_root     = (Join-Path $f.TmpDir "runs")
        current_phase         = "Phase 1"
    }
    $null = New-TestJsonFile -Directory (Join-Path $f.Repo "config") -FileName "PROJECT_STATE.json" -Data $projectStateCustom
    
    $v = & $removeScript -WorkspacePath $f.Repo -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject remove primary working tree - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject remove primary working tree - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # =======================================================================
    # PATH TESTS (20 - 21)
    # =======================================================================
    
    # 20. Windows path normalization
    $f = New-WorktreeFixture
    $taskData = @{
        task_id             = "task-norm"
        branch              = "agent/task-norm"
        workspace           = ($f.WorktreeRoot.Replace("/", "\") + "\task-norm\")
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'path normalization success - result is CREATED' -Expected 'CREATED' -Actual $res.result
    Assert-Equal -Name 'path normalization success - workspace path is canonicalized' -Expected (Join-Path $f.WorktreeRoot "task-norm") -Actual $res.workspace

    # 21. Sibling-prefix escape must fail
    $f = New-WorktreeFixture
    $evilWorkspace = $f.WorktreeRoot + "-evil/task-evil"
    $taskData = @{
        task_id             = "task-evil"
        branch              = "agent/task-evil"
        workspace           = $evilWorkspace
    }
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskData
    $v = & $newScript -TaskPath $taskFile -SourceRepositoryPath $f.Repo -AsJson
    $res = $v | ConvertFrom-Json
    Assert-Equal -Name 'reject sibling prefix escape - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject sibling prefix escape - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

}
finally {
    foreach ($fixture in $fixtures) {
        Remove-TempDirectory -Path $fixture
    }
}

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
