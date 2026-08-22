#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\Invoke-Worker.ps1.
.NOTES
    Invoked by tests\Run-AllTests.ps1. Returns the failure count.
    Builds throwaway Git repositories and compiles a fake worker binary under system temp.
    No real AI tokens are consumed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here         = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot     = Split-Path -Parent $here
$invokeScript = Join-Path $repoRoot 'scripts/Invoke-Worker.ps1'
$newWTScript  = Join-Path $repoRoot 'scripts/New-AgentWorktree.ps1'
$newRunScript = Join-Path $repoRoot 'scripts/New-AgentRun.ps1'

. (Join-Path $here 'TestHelpers.ps1')
. $newRunScript

Set-TestSuite 'Test-InvokeWorker'

$fixtures = [System.Collections.Generic.List[string]]::new()

# --- Compile Fake Worker binary for testing ---------------------------------
$fakeWorkerSource = @"
using System;
using System.IO;

public class FakeWorker {
    public static int Main(string[] args) {
        string exitCodeStr = Environment.GetEnvironmentVariable("FAKE_WORKER_EXIT_CODE");
        int exitCode = 0;
        if (!string.IsNullOrEmpty(exitCodeStr)) {
            int.TryParse(exitCodeStr, out exitCode);
        }

        string sleepStr = Environment.GetEnvironmentVariable("FAKE_WORKER_SLEEP_MS");
        if (!string.IsNullOrEmpty(sleepStr)) {
            int ms;
            if (int.TryParse(sleepStr, out ms)) {
                System.Threading.Thread.Sleep(ms);
            }
        }

        string writeCwdPath = Environment.GetEnvironmentVariable("FAKE_WORKER_WRITE_CWD");
        if (!string.IsNullOrEmpty(writeCwdPath)) {
            File.WriteAllText(writeCwdPath, Directory.GetCurrentDirectory());
        }

        string writeArgsPath = Environment.GetEnvironmentVariable("FAKE_WORKER_WRITE_ARGS");
        if (!string.IsNullOrEmpty(writeArgsPath)) {
            using (StreamWriter sw = new StreamWriter(writeArgsPath)) {
                sw.WriteLine(args.Length);
                foreach (string arg in args) {
                    sw.WriteLine(arg.Replace("\r", "").Replace("\n", "\\n"));
                }
            }
        }

        string reportDest = Environment.GetEnvironmentVariable("FAKE_WORKER_REPORT_DEST");
        string reportContent = Environment.GetEnvironmentVariable("FAKE_WORKER_REPORT_CONTENT");
        if (!string.IsNullOrEmpty(reportDest) && !string.IsNullOrEmpty(reportContent)) {
            File.WriteAllText(reportDest, reportContent);
        }

        string stdoutEnv = Environment.GetEnvironmentVariable("FAKE_WORKER_STDOUT");
        if (!string.IsNullOrEmpty(stdoutEnv)) {
            Console.WriteLine(stdoutEnv);
        } else {
            Console.WriteLine("FAKE WORKER STDOUT");
        }
        Console.Error.WriteLine("FAKE WORKER STDERR");

        return exitCode;
    }
}
"@

# Compile inline using csc.exe (built-in Windows .NET Framework compiler)
$fakeWorkerTempDir = New-TempDirectory
$script:fixtures.Add($fakeWorkerTempDir) | Out-Null
$fakeWorkerExe = Join-Path $fakeWorkerTempDir "fake-worker.exe"
$fakeWorkerSourcePath = Join-Path $fakeWorkerTempDir "FakeWorker.cs"
Set-Content -LiteralPath $fakeWorkerSourcePath -Value $fakeWorkerSource -Encoding UTF8

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}

if (-not (Test-Path $csc)) {
    throw "C# compiler csc.exe not found at $csc."
}

$compileOut = & $csc /target:exe /out:$fakeWorkerExe /nologo $fakeWorkerSourcePath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed: $($compileOut -join ' ')"
}

# --- Fixture Helper ---------------------------------------------------------
function New-InvokeWorkerFixture {
    $tmpDir = New-TempDirectory
    $script:fixtures.Add($tmpDir) | Out-Null

    $repo = New-TestGitRepository -InitialFiles @('README.md')
    $script:fixtures.Add($repo) | Out-Null
    
    $worktreeRoot = Join-Path $tmpDir "worktree_root"
    $null = New-Item -ItemType Directory -Path $worktreeRoot -Force

    $runsRoot = Join-Path $tmpDir "runs"
    $null = New-Item -ItemType Directory -Path $runsRoot -Force

    # Write PROJECT_STATE.json in repo/config/
    $null = New-Item -ItemType Directory -Path (Join-Path $repo "config") -Force
    $projectState = @{
        project_name          = "TEST_ORCHESTRA"
        repository            = "owner/test"
        default_branch        = "main"
        protected_branches    = @("main", "stable")
        source_root           = $repo
        runtime_worktree_root = $worktreeRoot
        runtime_runs_root     = $runsRoot
    }
    $null = New-TestJsonFile -Directory (Join-Path $repo "config") -FileName "PROJECT_STATE.json" -Data $projectState

    & git -C $repo add config/PROJECT_STATE.json 2>&1 | Out-Null
    & git -C $repo commit -m "add project state" --quiet 2>&1 | Out-Null

    # Create the isolated Git worktree using New-AgentWorktree.ps1
    $taskData = @{
        task_id             = "task-101"
        project             = "TEST_ORCHESTRA"
        repository          = "owner/test"
        branch              = "agent/task-101"
        workspace           = (Join-Path $worktreeRoot "task-101")
        objective           = "Implement feature X"
        allowed_paths       = @("src/")
        forbidden_paths     = @()
        acceptance_criteria = @("Code passes tests")
    }
    $taskFile = New-TestJsonFile -Directory $tmpDir -FileName "TASK.json" -Data $taskData

    $wtRaw = & $newWTScript -TaskPath $taskFile -SourceRepositoryPath $repo -AsJson
    $wt = $wtRaw | ConvertFrom-Json

    # Initialize the run directory using scripts\New-AgentRun.ps1's function
    $projectStateFile = Join-Path $repo "config/PROJECT_STATE.json"
    $runRes = New-AgentRunDirectory -TaskFile $taskFile -RunId "run-101" -ProjectStateFile $projectStateFile
    if ($runRes.result -ne 'CREATED') {
        throw "Failed to initialize run directory in fixture: $($runRes.reason)"
    }

    return @{
        TmpDir       = $tmpDir
        Repo         = $repo
        WorktreeRoot = $worktreeRoot
        RunsRoot     = $runsRoot
        Workspace    = $wt.workspace
        TaskData     = $taskData
        RunDir       = $runRes.run_directory
        ProjectState = $projectStateFile
    }
}

try {
    # =======================================================================
    # SUCCESS CASES (1 - 8)
    # =======================================================================
    # Reset env variables
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""

    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData

    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    # 1. fake claude worker runs inside assigned workspace
    # 7. deterministic JSON result returned
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'success - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result
    Assert-Equal -Name 'success - worker is claude' -Expected 'claude' -Actual $res.worker
    Assert-Equal -Name 'success - task_id matches' -Expected 'task-101' -Actual $res.task_id
    Assert-Equal -Name 'success - workspace matches' -Expected $f.Workspace -Actual $res.workspace
    Assert-Equal -Name 'success - run_directory matches' -Expected $runDir -Actual $res.run_directory
    
    # 8. duration recorded
    Assert-True -Name 'success - duration_seconds is recorded' -Condition ($res.duration_seconds -ge 0)
    Assert-Equal -Name 'success - exit_code is 0' -Expected 0 -Actual $res.exit_code

    # 3. TASK.json copied to run directory
    $copiedTask = Join-Path $runDir "TASK.json"
    Assert-True -Name 'success - TASK.json is copied to run directory' -Condition (Test-Path -LiteralPath $copiedTask)

    # 4. stdout captured
    $stdoutFile = Join-Path $runDir "logs/worker.stdout.log"
    Assert-True -Name 'success - stdout log exists' -Condition (Test-Path -LiteralPath $stdoutFile)
    $stdoutContent = Get-Content -LiteralPath $stdoutFile -Raw
    Assert-True -Name 'success - stdout captured content' -Condition ($stdoutContent -match "FAKE WORKER STDOUT")

    # 5. stderr captured
    $stderrFile = Join-Path $runDir "logs/worker.stderr.log"
    Assert-True -Name 'success - stderr log exists' -Condition (Test-Path -LiteralPath $stderrFile)
    $stderrContent = Get-Content -LiteralPath $stderrFile -Raw
    Assert-True -Name 'success - stderr captured content' -Condition ($stderrContent -match "FAKE WORKER STDERR")

    # 6. valid WORKER_REPORT.json accepted
    Assert-Equal -Name 'success - report status is completed' -Expected 'completed' -Actual $res.worker_report.status
    Assert-Equal -Name 'success - report summary matches' -Expected 'Done' -Actual $res.worker_report.summary

    # =======================================================================
    # BLOCKED CASES (9)
    # =======================================================================
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"blocked","files_changed":[],"summary":"I am blocked by missing API"}'

    # 9. valid worker report with status=blocked returns BLOCKED semantics
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'blocked - result is BLOCKED' -Expected 'BLOCKED' -Actual $res.result
    Assert-True -Name 'blocked - exit code is 1' -Condition ($LASTEXITCODE -eq 1)

    # =======================================================================
    # FAILURES (10 - 20)
    # =======================================================================
    
    # 10. unsupported worker rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "invalid-worker" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject unsupported worker' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject unsupported worker - exit code is 3' -Condition ($LASTEXITCODE -eq 3)

    # 11. missing executable rejected/unavailable
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath "C:\nonexistent\exe\path.exe"
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject missing executable' -Expected 'WORKER_UNAVAILABLE' -Actual $res.result
    Assert-True -Name 'reject missing executable - exit code is 5' -Condition ($LASTEXITCODE -eq 5)

    # 12. workspace mismatch rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.WorktreeRoot -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject workspace mismatch' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject workspace mismatch - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 13. workspace outside runtime root rejected
    $f = New-InvokeWorkerFixture
    $taskDataOutside = $f.TaskData.Clone()
    $taskDataOutside.workspace = (Join-Path $f.TmpDir "outside-workspace")
    $null = New-Item -ItemType Directory -Path $taskDataOutside.workspace -Force
    
    # Setup git in outside workspace
    & git -C $taskDataOutside.workspace init --quiet -b agent/task-101
    & git -C $taskDataOutside.workspace config user.email 'test@ai-orchestra.local'
    & git -C $taskDataOutside.workspace config user.name 'Test'
    Set-Content -LiteralPath (Join-Path $taskDataOutside.workspace "README.md") -Value "test"
    & git -C $taskDataOutside.workspace add -A
    & git -C $taskDataOutside.workspace commit -m "baseline" --quiet
    
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskDataOutside
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $taskDataOutside.workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject workspace outside root' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject workspace outside root - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 14. run directory outside runtime root rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = Join-Path $f.TmpDir "outside-run"

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject run directory outside root' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject run directory outside root - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 15. protected branch rejected
    $f = New-InvokeWorkerFixture
    $taskDataProtected = $f.TaskData.Clone()
    $taskDataProtected.branch = "stable"
    $taskDataProtected.workspace = $f.Workspace
    & git -C $f.Repo branch stable --quiet
    & git -C $f.Workspace checkout stable --quiet
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskDataProtected
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject protected branch' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject protected branch - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 16. current branch mismatch rejected
    $f = New-InvokeWorkerFixture
    $taskDataMismatch = $f.TaskData.Clone()
    $taskDataMismatch.branch = "agent/task-different"
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $taskDataMismatch
    $runDir = $f.RunDir

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject current branch mismatch' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject current branch mismatch - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 17. existing WORKER_REPORT.json not overwritten
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    Set-Content -LiteralPath $reportFile -Value "{}" -Encoding UTF8

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject existing report overwrite' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'reject existing report overwrite - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 18. malformed worker report rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status": "completed", '

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject malformed report' -Expected 'INVALID_OUTPUT' -Actual $res.result
    Assert-True -Name 'reject malformed report - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 19. missing worker report rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject missing report' -Expected 'INVALID_OUTPUT' -Actual $res.result
    Assert-True -Name 'reject missing report - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 20. non-zero worker exit handled deterministically
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_EXIT_CODE = "42"
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"failed","files_changed":[],"summary":"failed to run tests"}'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject non-zero worker exit - result' -Expected 'FAILED' -Actual $res.result
    Assert-Equal -Name 'reject non-zero worker exit - exit_code' -Expected 42 -Actual $res.exit_code
    Assert-True -Name 'reject non-zero worker exit - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # =======================================================================
    # TIMEOUT (21 - 22)
    # =======================================================================
    
    # 21. worker exceeding timeout is terminated/reported TIMEOUT
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "10000"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -TimeoutSeconds 1 -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'timeout result' -Expected 'TIMEOUT' -Actual $res.result
    Assert-True -Name 'timeout exit code is 4' -Condition ($LASTEXITCODE -eq 4)

    # 22. timeout cannot exceed policy maximum
    # We test that the process completes normally when a large timeout is passed (it is clamped and doesn't crash)
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":[],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -TimeoutSeconds 9999 -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    if ($res.result -ne 'COMPLETED') {
        Write-Host "Test 22 failed. Reason: $($res.reason)"
    }
    Assert-Equal -Name 'clamped timeout works' -Expected 'COMPLETED' -Actual $res.result

    # =======================================================================
    # SECURITY (23 - 25)
    # =======================================================================
    
    # 23. invocation current directory equals assigned worktree
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $cwdFile = Join-Path $runDir "cwd.txt"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = $cwdFile
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":[],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    if ($res.result -ne 'COMPLETED') {
        Write-Host "Test 23 failed. Reason: $($res.reason)"
    }
    Assert-Equal -Name 'cwd run - result' -Expected 'COMPLETED' -Actual $res.result
    $writtenCwd = (Get-Content -LiteralPath $cwdFile -Raw).Trim()
    Assert-Equal -Name 'cwd matches assigned workspace' -Expected $f.Workspace -Actual $writtenCwd

    # 24. primary source working tree remains unchanged
    $gitBranch = (& git -C $f.Repo branch --show-current 2>&1).Trim()
    Assert-Equal -Name 'primary repo active branch is main' -Expected 'main' -Actual $gitBranch

    # 28. missing run directory rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $nonExistentRunDir = Join-Path $f.RunsRoot "run-does-not-exist"
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $nonExistentRunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'missing run directory rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'missing run directory exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 29. missing TASK.json rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    Remove-Item -LiteralPath (Join-Path $f.RunDir "TASK.json") -Force
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'missing TASK.json rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'missing TASK.json exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 30. missing STATUS.json rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    Remove-Item -LiteralPath (Join-Path $f.RunDir "STATUS.json") -Force
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'missing STATUS.json rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'missing STATUS.json exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 31. missing USAGE.json rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    Remove-Item -LiteralPath (Join-Path $f.RunDir "USAGE.json") -Force
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'missing USAGE.json rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'missing USAGE.json exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 32. missing logs directory rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    Remove-Item -LiteralPath (Join-Path $f.RunDir "logs") -Recurse -Force
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'missing logs directory rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'missing logs directory exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 33. run TASK/task_id mismatch rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $mismatchedTask = $f.TaskData.Clone()
    $mismatchedTask.task_id = "task-mismatched"
    $mismatchedTask | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $f.RunDir "TASK.json") -Encoding UTF8
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'run TASK/task_id mismatch rejected' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'run TASK/task_id mismatch exits 3' -Condition ($LASTEXITCODE -eq 3)

    # 34. Invoke-Worker does not alter STATUS.json
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $statusPath = Join-Path $f.RunDir "STATUS.json"
    $hashBefore = (Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash
    
    $reportFile = Join-Path $f.RunDir "WORKER_REPORT.json"
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $hashAfter = (Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash
    Assert-Equal -Name 'STATUS.json not altered' -Expected $hashBefore -Actual $hashAfter

    # 35. Invoke-Worker updates USAGE.json for Claude
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $usagePath = Join-Path $f.RunDir "USAGE.json"
    
    $reportFile = Join-Path $f.RunDir "WORKER_REPORT.json"
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    
    $updatedUsage = Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json
    Assert-Equal -Name 'Claude worker_calls incremented' -Expected 1 -Actual $updatedUsage.worker_calls

    # 36. Invoke-Worker does not alter TASK.json
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runTaskPath = Join-Path $f.RunDir "TASK.json"
    $hashBefore = (Get-FileHash -LiteralPath $runTaskPath -Algorithm SHA256).Hash
    
    $reportFile = Join-Path $f.RunDir "WORKER_REPORT.json"
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $hashAfter = (Get-FileHash -LiteralPath $runTaskPath -Algorithm SHA256).Hash
    Assert-Equal -Name 'TASK.json not altered' -Expected $hashBefore -Actual $hashAfter

    # 37. Gemini worker adapter parses args correctly (uses --print, --output-format json, and prompt)
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $argsFile = Join-Path $runDir "args.txt"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_ARGS = $argsFile
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-123","status":"SUCCESS","num_turns":1,"usage":{"input_tokens":1000,"output_tokens":200,"thinking_tokens":50,"cache_read_tokens":500,"total_tokens":1200}}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'gemini success - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result
    Assert-Equal -Name 'gemini success - worker is gemini' -Expected 'gemini' -Actual $res.worker
    Assert-Equal -Name 'gemini success - total_tokens matches' -Expected 1200 -Actual $res.total_tokens
    Assert-Equal -Name 'gemini success - input_tokens matches' -Expected 1000 -Actual $res.input_tokens
    Assert-Equal -Name 'gemini success - output_tokens matches' -Expected 200 -Actual $res.output_tokens
    Assert-Equal -Name 'gemini success - cache_read_tokens matches' -Expected 500 -Actual $res.cache_read_tokens
    Assert-Equal -Name 'gemini success - thinking_tokens matches' -Expected 50 -Actual $res.thinking_tokens
    Assert-Equal -Name 'gemini success - conversation_id matches' -Expected 'conv-123' -Actual $res.conversation_id

    Assert-True -Name 'gemini args file exists' -Condition (Test-Path -LiteralPath $argsFile)
    $passedArgs = Get-Content -LiteralPath $argsFile
    
    Assert-Equal -Name 'gemini args count is 3' -Expected 3 -Actual ([int]$passedArgs[0])
    Assert-Equal -Name 'gemini has --output-format' -Expected '--output-format' -Actual ($passedArgs[1])
    Assert-Equal -Name 'gemini output-format value is json' -Expected 'json' -Actual ($passedArgs[2])
    
    $argsList = $passedArgs[1..3]
    $printArgs = @($argsList | Where-Object { $_.StartsWith("--print=") })
    Assert-Equal -Name 'exactly one arg starts with --print=' -Expected 1 -Actual $printArgs.Count
    Assert-True -Name 'print arg contains the prompt' -Condition ($printArgs[0] -match "You are a worker agent executing a bounded task under the AI_ORCHESTRA system")

    # Verify prompt is not passed as a separate positional argument
    $nonPrintArgs = $argsList | Where-Object { -not $_.StartsWith("--print=") }
    foreach ($arg in $nonPrintArgs) {
        Assert-True -Name 'non-print arg does not contain prompt' -Condition ($arg -notmatch "You are a worker agent executing a bounded task under the AI_ORCHESTRA system")
    }

    # Verify dangerously-skip-permissions is absent
    $hasSkipPerms = $argsList | Where-Object { $_ -eq "--dangerously-skip-permissions" }
    Assert-True -Name 'dangerously-skip-permissions is absent' -Condition ($null -eq $hasSkipPerms)

    # Verify prompt instructs worker to write a normal file rather than an artifact
    Assert-True -Name 'prompt instructs worker to write normal file' -Condition (($passedArgs[3]) -match "WORKER_REPORT.json is a normal filesystem file")

    # 38. Gemini stdout status ERROR + exit_code 0 + completed WORKER_REPORT -> FAILED with agy.error reason
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-456","status":"ERROR","error":"declaring permissions failed","num_turns":1,"usage":{"total_tokens":200}}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'gemini CLI error is FAILED (not COMPLETED)' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'gemini CLI error contains error reason' -Condition ($res.reason -match "declaring permissions failed")

    # 39. Gemini malformed stdout JSON -> INVALID_OUTPUT
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_STDOUT = '{"conversation_id": "malformed'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'gemini malformed stdout is INVALID_OUTPUT' -Expected 'INVALID_OUTPUT' -Actual $res.result

    # 40. Usage accounting: worker_calls increments, runtime_seconds adds, total_tokens accumulates, reviewer_calls/correction_rounds preserved
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $usageFile = Join-Path $runDir "USAGE.json"

    # Set existing USAGE.json values to non-zero to test accumulation
    $existingUsage = @{
        task_id = "task-101"
        worker_calls = 0
        reviewer_calls = 2
        correction_rounds = 1
        runtime_seconds = 100
        total_tokens = 5000
    }
    $existingUsage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "1000"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-abc","status":"SUCCESS","num_turns":1,"usage":{"total_tokens":1500}}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    
    # Read updated USAGE.json
    $updatedUsage = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'usage worker_calls increments exactly once' -Expected 1 -Actual $updatedUsage.worker_calls
    Assert-Equal -Name 'usage reviewer_calls preserved' -Expected 2 -Actual $updatedUsage.reviewer_calls
    Assert-Equal -Name 'usage correction_rounds preserved' -Expected 1 -Actual $updatedUsage.correction_rounds
    Assert-True -Name 'usage runtime_seconds accumulated' -Condition ($updatedUsage.runtime_seconds -gt 100)
    Assert-Equal -Name 'usage total_tokens accumulated rather than reset' -Expected 6500 -Actual $updatedUsage.total_tokens

    # 41. Missing token usage does not invent tokens (total_tokens remains unchanged)
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $usageFile = Join-Path $runDir "USAGE.json"

    $existingUsage = @{
        task_id = "task-101"
        worker_calls = 0
        reviewer_calls = 0
        correction_rounds = 0
        runtime_seconds = 0
        total_tokens = 5000
    }
    $existingUsage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    # stdout lacks usage token info:
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-xyz","status":"SUCCESS","num_turns":1}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    
    $updatedUsage = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'missing token usage does not invent tokens' -Expected 5000 -Actual $updatedUsage.total_tokens

    # 42. Budget STOP/escalation semantics triggered at 172798 total tokens
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $usageFile = Join-Path $runDir "USAGE.json"
    
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-huge","status":"SUCCESS","num_turns":1,"usage":{"total_tokens":172798}}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'huge tokens triggers budget STOP' -Expected 'STOP' -Actual $res.result
    Assert-Equal -Name 'budget STOP returns budget_exhausted escalation_reason' -Expected 'budget_exhausted' -Actual $res.escalation_reason
    Assert-True -Name 'huge tokens exits 2' -Condition ($LASTEXITCODE -eq 2)

}
finally {
    # Reset env variables
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_ARGS = ""
    $env:FAKE_WORKER_STDOUT = ""
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""

    foreach ($fixture in $fixtures) {
        Remove-TempDirectory -Path $fixture
    }
}

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
