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

# --- Fake Claude PowerShell-script launcher ---------------------------------
# Mirrors the npm-installed Claude CLI on Windows, which resolves to claude.ps1.
# System.Diagnostics.ProcessStartInfo cannot execute this file directly.
$fakeClaudePs1Source = @'
$argsPath = $env:FAKE_WORKER_WRITE_ARGS
if (-not [string]::IsNullOrEmpty($argsPath)) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string]$args.Count)
    foreach ($a in $args) {
        $lines.Add((([string]$a).Replace("`r", "").Replace("`n", "\n")))
    }
    Set-Content -LiteralPath $argsPath -Value $lines -Encoding UTF8
}

$cwdPath = $env:FAKE_WORKER_WRITE_CWD
if (-not [string]::IsNullOrEmpty($cwdPath)) {
    Set-Content -LiteralPath $cwdPath -Value ((Get-Location).Path) -Encoding UTF8
}

$hostPath = $env:FAKE_WORKER_WRITE_HOST
if (-not [string]::IsNullOrEmpty($hostPath)) {
    Set-Content -LiteralPath $hostPath -Value ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Encoding UTF8
}

$dest = $env:FAKE_WORKER_REPORT_DEST
$reportContent = $env:FAKE_WORKER_REPORT_CONTENT
if ((-not [string]::IsNullOrEmpty($dest)) -and (-not [string]::IsNullOrEmpty($reportContent))) {
    Set-Content -LiteralPath $dest -Value $reportContent -Encoding UTF8 -NoNewline
}

$stdoutEnv = $env:FAKE_WORKER_STDOUT
if (-not [string]::IsNullOrEmpty($stdoutEnv)) {
    Write-Output $stdoutEnv
} else {
    Write-Output "FAKE PS1 WORKER STDOUT"
}
[Console]::Error.WriteLine("FAKE PS1 WORKER STDERR")
exit 0
'@

$fakeClaudePs1 = Join-Path $fakeWorkerTempDir "claude.ps1"
Set-Content -LiteralPath $fakeClaudePs1 -Value $fakeClaudePs1Source -Encoding UTF8

# A resolvable-but-not-executable file, used to force a pre-launch start failure.
$notAnExecutable = Join-Path $fakeWorkerTempDir "not-an-executable.txt"
Set-Content -LiteralPath $notAnExecutable -Value "this is not a program" -Encoding UTF8

function Get-LaunchPlan {
    param([string] $RunDirectory)
    $planPath = Join-Path $RunDirectory "logs/worker.launch.json"
    if (-not (Test-Path -LiteralPath $planPath)) { return $null }
    return (Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json)
}

$forbiddenWorkerFlags = @(
    '--dangerously-skip-permissions',
    '--allow-dangerously-skip-permissions',
    '--continue',
    '--resume',
    '--remote-control'
)

# Permission modes amounting to an unrestricted bypass. AO-CLAUDE-002 forbids
# these; only auto-deny / prompt-free-but-bounded modes are acceptable.
$forbiddenPermissionModes = @('bypassPermissions')

# --- Claude structured stdout helpers (AO-CLAUDE-002) -----------------------
# Envelope shape verified against the installed Claude CLI (2.1.241):
#   { type, subtype, is_error, num_turns, session_id, result, total_cost_usd,
#     usage: { input_tokens, output_tokens, cache_creation_input_tokens,
#              cache_read_input_tokens, output_tokens_details: { thinking_tokens } },
#     permission_denials: [...], structured_output?: {...} }
function New-ClaudeEnvelope {
    param(
        [object]    $Report = $null,
        [string]    $ResultText = 'Task complete.',
        [bool]      $IsError = $false,
        [string]    $Subtype = 'success',
        [hashtable] $Usage = $null,
        [object[]]  $PermissionDenials = @()
    )
    $envelope = [ordered]@{
        type               = 'result'
        subtype            = $Subtype
        is_error           = $IsError
        num_turns          = 3
        session_id         = 'sess-claude-001'
        result             = $ResultText
        total_cost_usd     = 0.0123
        permission_denials = @($PermissionDenials)
    }
    if ($null -ne $Usage)  { $envelope['usage'] = $Usage }
    if ($null -ne $Report) { $envelope['structured_output'] = $Report }
    return ([pscustomobject]$envelope | ConvertTo-Json -Depth 10 -Compress)
}

$claudeCompletedReport = [ordered]@{
    status        = 'completed'
    files_changed = @('src/main.py')
    summary       = 'Done'
}

# Claude workers no longer write WORKER_REPORT.json themselves: the report comes
# back through structured stdout and the Supervisor persists it. This helper
# expresses that in one line per test, and asserts the worker is given no
# run-directory write target at all.
function Set-ClaudeWorkerOutput {
    param(
        [object]    $Report = $null,
        [string]    $ResultText = 'Task complete.',
        [bool]      $IsError = $false,
        [string]    $Subtype = 'success',
        [hashtable] $Usage = $null,
        [object[]]  $PermissionDenials = @(),
        [string]    $RawStdout = ''
    )
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""
    if (-not [string]::IsNullOrEmpty($RawStdout)) {
        $env:FAKE_WORKER_STDOUT = $RawStdout
        return
    }
    $env:FAKE_WORKER_STDOUT = New-ClaudeEnvelope -Report $Report -ResultText $ResultText `
        -IsError $IsError -Subtype $Subtype -Usage $Usage -PermissionDenials $PermissionDenials
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
    
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

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
    Assert-True -Name 'success - stdout captured content' -Condition ($stdoutContent -match '"type":"result"')

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
    
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'blocked'; files_changed = @(); summary = 'I am blocked by missing API' })

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
    
    # Claude returns a structurally invalid report through stdout.
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'not-a-valid-status'; files_changed = @(); summary = 'x' })

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'reject malformed report' -Expected 'INVALID_OUTPUT' -Actual $res.result
    Assert-True -Name 'reject malformed report - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    # 19. missing worker report rejected
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    
    # Valid envelope, but no structured report at all.
    Set-ClaudeWorkerOutput -Report $null -ResultText 'I could not complete this.'

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
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'failed'; files_changed = @(); summary = 'failed to run tests' })

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
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'completed'; files_changed = @(); summary = 'Done' })

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
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'completed'; files_changed = @(); summary = 'Done' })

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
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $hashAfter = (Get-FileHash -LiteralPath $statusPath -Algorithm SHA256).Hash
    Assert-Equal -Name 'STATUS.json not altered' -Expected $hashBefore -Actual $hashAfter

    # 35. Invoke-Worker updates USAGE.json for Claude
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $usagePath = Join-Path $f.RunDir "USAGE.json"
    
    $reportFile = Join-Path $f.RunDir "WORKER_REPORT.json"
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport
    
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $f.RunDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    
    $updatedUsage = Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json
    Assert-Equal -Name 'Claude worker_calls incremented' -Expected 1 -Actual $updatedUsage.worker_calls

    # 36. Invoke-Worker does not alter TASK.json
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runTaskPath = Join-Path $f.RunDir "TASK.json"
    $hashBefore = (Get-FileHash -LiteralPath $runTaskPath -Algorithm SHA256).Hash
    
    $reportFile = Join-Path $f.RunDir "WORKER_REPORT.json"
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport
    
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

    # =======================================================================
    # CLAUDE LAUNCHER FORMS (43 - 46)   [AO-004C1]
    # =======================================================================

    # 43. FORM A: Claude resolved as a PowerShell script (.ps1)
    #     -> launched through pwsh -NoProfile -File <claude.ps1> --print --output-format json <prompt>
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $argsFile = Join-Path $runDir "args.txt"
    $cwdFile = Join-Path $runDir "cwd.txt"
    $hostFile = Join-Path $runDir "host.txt"

    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_ARGS = $argsFile
    $env:FAKE_WORKER_WRITE_CWD = $cwdFile
    $env:FAKE_WORKER_WRITE_HOST = $hostFile
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeClaudePs1
    $res = $resRaw | ConvertFrom-Json

    if ($res.result -ne 'COMPLETED') {
        Write-Host "Test 43 failed. Reason: $($res.reason)"
    }
    Assert-Equal -Name 'claude ps1 - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result
    Assert-Equal -Name 'claude ps1 - exit_code is 0' -Expected 0 -Actual $res.exit_code

    $plan = Get-LaunchPlan -RunDirectory $runDir
    Assert-True -Name 'claude ps1 - launch plan recorded' -Condition ($null -ne $plan)
    Assert-True -Name 'claude ps1 - detected as PowerShell script' -Condition ([bool]$plan.is_powershell_script)
    Assert-Equal -Name 'claude ps1 - resolved command is claude.ps1' -Expected $fakeClaudePs1 -Actual $plan.resolved_command

    # ProcessStartInfo.FileName must be the pwsh host, never the .ps1 itself
    $planFileLeaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$plan.file_name)
    Assert-Equal -Name 'claude ps1 - ProcessStartInfo launches pwsh' -Expected 'pwsh' -Actual $planFileLeaf
    Assert-True -Name 'claude ps1 - FileName is not the .ps1' -Condition (([string]$plan.file_name) -ne $fakeClaudePs1)

    $planArgs = @($plan.arguments)
    Assert-Equal -Name 'claude ps1 - argument count is 15' -Expected 15 -Actual $planArgs.Count
    Assert-Equal -Name 'claude ps1 - arg 0 is -NoProfile' -Expected '-NoProfile' -Actual $planArgs[0]
    Assert-Equal -Name 'claude ps1 - arg 1 is -File' -Expected '-File' -Actual $planArgs[1]
    Assert-Equal -Name 'claude ps1 - arg 2 is the claude.ps1 path' -Expected $fakeClaudePs1 -Actual $planArgs[2]
    Assert-Equal -Name 'claude ps1 - arg 3 is --print' -Expected '--print' -Actual $planArgs[3]
    Assert-Equal -Name 'claude ps1 - arg 4 is --output-format' -Expected '--output-format' -Actual $planArgs[4]
    Assert-Equal -Name 'claude ps1 - arg 5 is json' -Expected 'json' -Actual $planArgs[5]
    Assert-True -Name 'claude ps1 - last arg is the bounded prompt' -Condition ($planArgs[-1] -match "You are a worker agent executing a bounded task under the AI_ORCHESTRA system")

    # Non-interactive contract: --print present, no dangerous or session-resuming flags
    Assert-True -Name 'claude ps1 - prompt is not interactive (--print present)' -Condition ($planArgs -contains '--print')
    foreach ($flag in $forbiddenWorkerFlags) {
        Assert-True -Name "claude ps1 - forbidden flag '$flag' absent" -Condition (-not ($planArgs -contains $flag))
    }

    # The pwsh host really did run the script, and only the CLI args reached it
    Assert-True -Name 'claude ps1 - script received args' -Condition (Test-Path -LiteralPath $argsFile)
    $passedArgs = Get-Content -LiteralPath $argsFile
    Assert-Equal -Name 'claude ps1 - script arg count is 12' -Expected 12 -Actual ([int]$passedArgs[0])
    Assert-Equal -Name 'claude ps1 - script arg 1 is --print' -Expected '--print' -Actual $passedArgs[1]
    Assert-Equal -Name 'claude ps1 - script arg 2 is --output-format' -Expected '--output-format' -Actual $passedArgs[2]
    Assert-Equal -Name 'claude ps1 - script arg 3 is json' -Expected 'json' -Actual $passedArgs[3]
    Assert-True -Name 'claude ps1 - script last arg is the prompt' -Condition ($passedArgs[-1] -match "You are a worker agent executing a bounded task under the AI_ORCHESTRA system")

    $actualHost = (Get-Content -LiteralPath $hostFile -Raw).Trim()
    Assert-Equal -Name 'claude ps1 - hosting process is pwsh' -Expected 'pwsh' -Actual ([System.IO.Path]::GetFileNameWithoutExtension($actualHost))

    # Assigned worktree preserved as WorkingDirectory
    $writtenCwd = (Get-Content -LiteralPath $cwdFile -Raw).Trim()
    Assert-Equal -Name 'claude ps1 - cwd remains assigned workspace' -Expected $f.Workspace -Actual $writtenCwd
    Assert-Equal -Name 'claude ps1 - launch plan working directory is workspace' -Expected $f.Workspace -Actual $plan.working_directory

    # stdout/stderr capture preserved
    $stdoutContent = Get-Content -LiteralPath (Join-Path $runDir "logs/worker.stdout.log") -Raw
    Assert-True -Name 'claude ps1 - stdout captured' -Condition ($stdoutContent -match '"type":"result"')
    $stderrContent = Get-Content -LiteralPath (Join-Path $runDir "logs/worker.stderr.log") -Raw
    Assert-True -Name 'claude ps1 - stderr captured' -Condition ($stderrContent -match "FAKE PS1 WORKER STDERR")

    # Budget/USAGE accounting preserved
    $updatedUsage = Get-Content -LiteralPath (Join-Path $runDir "USAGE.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name 'claude ps1 - worker_calls incremented' -Expected 1 -Actual $updatedUsage.worker_calls

    # 44. FORM B: Claude resolved as a real executable -> direct execution still works
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $argsFile = Join-Path $runDir "args.txt"
    $cwdFile = Join-Path $runDir "cwd.txt"

    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_ARGS = $argsFile
    $env:FAKE_WORKER_WRITE_CWD = $cwdFile
    $env:FAKE_WORKER_WRITE_HOST = ""
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    if ($res.result -ne 'COMPLETED') {
        Write-Host "Test 44 failed. Reason: $($res.reason)"
    }
    Assert-Equal -Name 'claude exe - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result

    $plan = Get-LaunchPlan -RunDirectory $runDir
    Assert-True -Name 'claude exe - launch plan recorded' -Condition ($null -ne $plan)
    Assert-True -Name 'claude exe - not detected as PowerShell script' -Condition (-not [bool]$plan.is_powershell_script)
    Assert-Equal -Name 'claude exe - ProcessStartInfo launches the executable directly' -Expected $fakeWorkerExe -Actual $plan.file_name

    $planArgs = @($plan.arguments)
    Assert-Equal -Name 'claude exe - argument count is 12' -Expected 12 -Actual $planArgs.Count
    Assert-Equal -Name 'claude exe - arg 0 is --print' -Expected '--print' -Actual $planArgs[0]
    Assert-Equal -Name 'claude exe - arg 1 is --output-format' -Expected '--output-format' -Actual $planArgs[1]
    Assert-Equal -Name 'claude exe - arg 2 is json' -Expected 'json' -Actual $planArgs[2]
    Assert-True -Name 'claude exe - last arg is the bounded prompt' -Condition ($planArgs[-1] -match "You are a worker agent executing a bounded task under the AI_ORCHESTRA system")

    Assert-True -Name 'claude exe - prompt is not interactive (--print present)' -Condition ($planArgs -contains '--print')
    foreach ($flag in $forbiddenWorkerFlags) {
        Assert-True -Name "claude exe - forbidden flag '$flag' absent" -Condition (-not ($planArgs -contains $flag))
    }

    Assert-True -Name 'claude exe - executable received args' -Condition (Test-Path -LiteralPath $argsFile)
    $passedArgs = Get-Content -LiteralPath $argsFile
    Assert-Equal -Name 'claude exe - executable arg count is 12' -Expected 12 -Actual ([int]$passedArgs[0])
    Assert-Equal -Name 'claude exe - executable arg 1 is --print' -Expected '--print' -Actual $passedArgs[1]

    $writtenCwd = (Get-Content -LiteralPath $cwdFile -Raw).Trim()
    Assert-Equal -Name 'claude exe - cwd remains assigned workspace' -Expected $f.Workspace -Actual $writtenCwd

    # 45. No token usage recorded when the process fails before launch
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $usageFile = Join-Path $runDir "USAGE.json"

    $existingUsage = @{
        task_id           = "task-101"
        worker_calls      = 0
        reviewer_calls    = 0
        correction_rounds = 0
        runtime_seconds   = 0
        total_tokens      = 5000
    }
    $existingUsage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8

    $env:FAKE_WORKER_WRITE_ARGS = ""
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_HOST = ""
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $notAnExecutable
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'pre-launch failure - result is FAILED' -Expected 'FAILED' -Actual $res.result
    Assert-True -Name 'pre-launch failure - exit code is 2' -Condition ($LASTEXITCODE -eq 2)

    $unchangedUsage = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'pre-launch failure - worker_calls not incremented' -Expected 0 -Actual $unchangedUsage.worker_calls
    Assert-Equal -Name 'pre-launch failure - total_tokens unchanged' -Expected 5000 -Actual $unchangedUsage.total_tokens
    Assert-Equal -Name 'pre-launch failure - runtime_seconds unchanged' -Expected 0 -Actual $unchangedUsage.runtime_seconds

    # 46. Gemini launch contract is unchanged by the Claude launcher fix
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"

    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_ARGS = ""
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_HOST = ""
    $env:FAKE_WORKER_STDOUT = '{"conversation_id":"conv-999","status":"SUCCESS","num_turns":1,"usage":{"total_tokens":100}}'
    $env:FAKE_WORKER_REPORT_DEST = $reportFile
    $env:FAKE_WORKER_REPORT_CONTENT = '{"status":"completed","files_changed":["src/main.py"],"summary":"Done"}'

    $resRaw = & $invokeScript -Worker "gemini" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'gemini regression - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result

    $plan = Get-LaunchPlan -RunDirectory $runDir
    $planArgs = @($plan.arguments)
    Assert-Equal -Name 'gemini regression - launches executable directly' -Expected $fakeWorkerExe -Actual $plan.file_name
    Assert-Equal -Name 'gemini regression - argument count is 3' -Expected 3 -Actual $planArgs.Count
    Assert-Equal -Name 'gemini regression - arg 0 is --output-format' -Expected '--output-format' -Actual $planArgs[0]
    Assert-Equal -Name 'gemini regression - arg 1 is json' -Expected 'json' -Actual $planArgs[1]
    Assert-True -Name 'gemini regression - arg 2 is --print=<prompt>' -Condition ($planArgs[2].StartsWith('--print='))
    foreach ($flag in $forbiddenWorkerFlags) {
        Assert-True -Name "gemini regression - forbidden flag '$flag' absent" -Condition (-not ($planArgs -contains $flag))
    }

    # =======================================================================
    # CLAUDE BOUNDED FILESYSTEM ACCESS (47 - 54)   [AO-CLAUDE-002]
    # =======================================================================

    # 47. Non-interactive bounded execution: the whole task contract travels in the
    #     prompt, the report travels back through structured stdout, and the
    #     Supervisor persists WORKER_REPORT.json. The worker writes nothing outside
    #     its worktree.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"
    $argsFile = Join-Path $runDir "args.txt"

    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_ARGS = $argsFile
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_HOST = ""
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    if ($res.result -ne 'COMPLETED') { Write-Host "Test 47 failed. Reason: $($res.reason)" }
    Assert-Equal -Name 'bounded claude - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result
    Assert-Equal -Name 'bounded claude - report came from structured stdout' -Expected 'structured_output' -Actual $res.report_source
    Assert-True  -Name 'bounded claude - Supervisor persisted WORKER_REPORT.json' -Condition (Test-Path -LiteralPath $reportFile)

    $persisted = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'bounded claude - persisted status matches' -Expected 'completed' -Actual $persisted.status
    Assert-Equal -Name 'bounded claude - persisted summary matches' -Expected 'Done' -Actual $persisted.summary
    Assert-Equal -Name 'bounded claude - persisted files_changed matches' -Expected 'src/main.py' -Actual (@($persisted.files_changed)[0])
    Assert-Equal -Name 'bounded claude - worker report returned to caller' -Expected 'completed' -Actual $res.worker_report.status

    # The task contract must be inside the prompt, so the worker never needs the run directory.
    $passedArgs = Get-Content -LiteralPath $argsFile
    $claudePromptArg = $passedArgs[-1]
    Assert-True -Name 'bounded claude - prompt carries task_id'   -Condition ($claudePromptArg -match 'task-101')
    Assert-True -Name 'bounded claude - prompt carries objective' -Condition ($claudePromptArg -match 'Implement feature X')
    Assert-True -Name 'bounded claude - prompt carries allowed_paths' -Condition ($claudePromptArg -match 'allowed_paths')
    Assert-True -Name 'bounded claude - prompt carries the workspace path' -Condition ($claudePromptArg -match [regex]::Escape($f.Workspace))
    Assert-True -Name 'bounded claude - prompt no longer tells the worker to read TASK.json' `
        -Condition ($claudePromptArg -notmatch 'Read the assigned TASK\.json')
    Assert-True -Name 'bounded claude - prompt no longer points at the run directory report path' `
        -Condition ($claudePromptArg -notmatch [regex]::Escape((Join-Path $runDir 'WORKER_REPORT.json')))
    Assert-True -Name 'bounded claude - prompt forbids writing WORKER_REPORT.json to disk' `
        -Condition ($claudePromptArg -match 'Do NOT write a WORKER_REPORT\.json file anywhere')

    # 48. Least-privilege permission contract on the launch plan.
    $plan = Get-LaunchPlan -RunDirectory $runDir
    $planArgs = @($plan.arguments)

    Assert-Equal -Name 'least privilege - permission mode is dontAsk' -Expected 'dontAsk' -Actual $plan.permission_mode
    Assert-True  -Name 'least privilege - --permission-mode is passed' -Condition ($planArgs -contains '--permission-mode')
    Assert-True  -Name 'least privilege - dontAsk value is passed' -Condition ($planArgs -contains 'dontAsk')
    Assert-Equal -Name 'least privilege - report transport is structured stdout' -Expected 'structured_stdout' -Actual $plan.report_transport

    # No additional directory may be authorized: the worktree boundary IS the sandbox.
    Assert-Equal -Name 'least privilege - no additional directories authorized' -Expected 0 -Actual (@($plan.additional_directories).Count)
    Assert-True  -Name 'least privilege - --add-dir is never passed' -Condition (-not ($planArgs -contains '--add-dir'))
    foreach ($root in @('C:\', 'C:\\', '/', '~', '.', '..')) {
        Assert-True -Name "least privilege - filesystem root '$root' is not authorized" -Condition (-not ($planArgs -contains $root))
    }
    $runDirArgs = @($planArgs | Where-Object { $_ -eq $runDir })
    Assert-Equal -Name 'least privilege - run directory is not passed to the worker' -Expected 0 -Actual $runDirArgs.Count

    # Tool allowlist: file tools only, no shell.
    Assert-True -Name 'least privilege - --allowedTools is passed' -Condition ($planArgs -contains '--allowedTools')
    Assert-True -Name 'least privilege - --disallowedTools is passed' -Condition ($planArgs -contains '--disallowedTools')
    $allowedTools = @(([string]$plan.allowed_tools) -split ',' | ForEach-Object { $_.Trim() })
    $deniedTools  = @(([string]$plan.disallowed_tools) -split ',' | ForEach-Object { $_.Trim() })
    foreach ($t in @('Read', 'Edit', 'Write', 'Glob', 'Grep')) {
        Assert-True -Name "least privilege - '$t' is allowed" -Condition ($allowedTools -contains $t)
    }
    Assert-True -Name 'least privilege - Bash is NOT in the allowlist' -Condition (-not ($allowedTools -contains 'Bash'))
    foreach ($t in @('Bash', 'WebFetch', 'WebSearch')) {
        Assert-True -Name "least privilege - '$t' is explicitly denied" -Condition ($deniedTools -contains $t)
    }

    # 49. Security regression: no permission bypass of any form.
    foreach ($flag in $forbiddenWorkerFlags) {
        Assert-True -Name "bounded claude - forbidden flag '$flag' absent" -Condition (-not ($planArgs -contains $flag))
    }
    foreach ($mode in $forbiddenPermissionModes) {
        Assert-True -Name "bounded claude - permission mode '$mode' absent" -Condition (-not ($planArgs -contains $mode))
        Assert-True -Name "bounded claude - plan permission_mode is not '$mode'" -Condition (([string]$plan.permission_mode) -ne $mode)
    }
    $joinedArgs = ($planArgs -join ' ')
    Assert-True -Name 'bounded claude - no skip-permissions substring anywhere in the argument vector' `
        -Condition ($joinedArgs -notmatch 'skip-permissions')
    Assert-True -Name 'bounded claude - no bypassPermissions substring anywhere in the argument vector' `
        -Condition ($joinedArgs -notmatch 'bypassPermissions')

    # 50. Non-interactive: --print present, no interactive-session flag.
    Assert-True -Name 'bounded claude - --print present (non-interactive)' -Condition ($planArgs -contains '--print')
    foreach ($flag in @('--remote-control', '--continue', '--resume', '--ide', '--tmux')) {
        Assert-True -Name "bounded claude - interactive flag '$flag' absent" -Condition (-not ($planArgs -contains $flag))
    }

    # 51. Structured-output contract handed to the CLI matches WORKER_REPORT.
    Assert-True -Name 'bounded claude - --json-schema is passed' -Condition ($planArgs -contains '--json-schema')
    $schemaIndex = [array]::IndexOf($planArgs, '--json-schema')
    $schemaObj = $planArgs[$schemaIndex + 1] | ConvertFrom-Json
    Assert-Equal -Name 'bounded claude - schema type is object' -Expected 'object' -Actual $schemaObj.type
    Assert-CollectionEqual -Name 'bounded claude - schema requires the WORKER_REPORT fields' `
        -Expected @('status', 'files_changed', 'summary') -Actual @($schemaObj.required)
    Assert-CollectionEqual -Name 'bounded claude - schema status enum matches WORKER_REPORT.schema.json' `
        -Expected @('completed', 'blocked', 'failed') -Actual @($schemaObj.properties.status.enum)

    # 52. Claude token accounting.
    #     total_tokens = input + cache_creation_input + cache_read_input + output.
    #     thinking_tokens is a breakdown of output_tokens and must NOT be added again.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $usageFile = Join-Path $runDir "USAGE.json"

    @{ task_id = "task-101"; worker_calls = 0; reviewer_calls = 2; correction_rounds = 1
       runtime_seconds = 100; total_tokens = 5000 } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8

    $env:FAKE_WORKER_WRITE_ARGS = ""
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport -Usage @{
        input_tokens                = 1000
        output_tokens               = 200
        cache_creation_input_tokens = 300
        cache_read_input_tokens     = 500
        output_tokens_details       = @{ thinking_tokens = 150 }
    }

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'claude usage - input_tokens reported' -Expected 1000 -Actual $res.input_tokens
    Assert-Equal -Name 'claude usage - output_tokens reported' -Expected 200 -Actual $res.output_tokens
    Assert-Equal -Name 'claude usage - cache_creation_input_tokens reported' -Expected 300 -Actual $res.cache_creation_input_tokens
    Assert-Equal -Name 'claude usage - cache_read_input_tokens reported' -Expected 500 -Actual $res.cache_read_input_tokens
    Assert-Equal -Name 'claude usage - thinking_tokens reported' -Expected 150 -Actual $res.thinking_tokens
    Assert-Equal -Name 'claude usage - total_tokens sums the four disjoint counters' -Expected 2000 -Actual $res.total_tokens
    Assert-Equal -Name 'claude usage - session_id surfaced' -Expected 'sess-claude-001' -Actual $res.session_id
    Assert-Equal -Name 'claude usage - total_cost_usd surfaced' -Expected 0.0123 -Actual $res.total_cost_usd
    Assert-Equal -Name 'claude usage - num_turns surfaced' -Expected 3 -Actual $res.num_turns

    $updatedUsage = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'claude usage - USAGE.json total_tokens accumulates' -Expected 7000 -Actual $updatedUsage.total_tokens
    Assert-Equal -Name 'claude usage - worker_calls increments once' -Expected 1 -Actual $updatedUsage.worker_calls
    Assert-Equal -Name 'claude usage - reviewer_calls preserved' -Expected 2 -Actual $updatedUsage.reviewer_calls
    Assert-Equal -Name 'claude usage - correction_rounds preserved' -Expected 1 -Actual $updatedUsage.correction_rounds
    # USAGE.schema.json sets additionalProperties=false, so no per-type keys may leak in.
    $usageKeys = @($updatedUsage.PSObject.Properties.Name)
    foreach ($k in @('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens', 'thinking_tokens')) {
        Assert-True -Name "claude usage - USAGE.json gains no '$k' key" -Condition (-not ($usageKeys -contains $k))
    }

    # 53. Missing Claude usage does not invent tokens.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $usageFile = Join-Path $runDir "USAGE.json"
    @{ task_id = "task-101"; worker_calls = 0; reviewer_calls = 0; correction_rounds = 0
       runtime_seconds = 0; total_tokens = 5000 } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8

    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

    $null = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $unchanged = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'claude usage - absent usage block invents no tokens' -Expected 5000 -Actual $unchanged.total_tokens

    # 54. Permission denials are surfaced instead of a generic "report missing".
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir

    Set-ClaudeWorkerOutput -Report $null -ResultText 'The permission to read TASK.json was denied.' -PermissionDenials @(
        [ordered]@{ tool_name = 'Read'; tool_input = @{ file_path = 'C:\tmp\ai-orchestra-runs\x\TASK.json' } },
        [ordered]@{ tool_name = 'Bash'; tool_input = @{ command = 'type TASK.json' } }
    )

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'denials - result is INVALID_OUTPUT' -Expected 'INVALID_OUTPUT' -Actual $res.result
    Assert-Equal -Name 'denials - denial count surfaced' -Expected 2 -Actual $res.permission_denial_count
    Assert-True  -Name 'denials - reason names the denial count' -Condition ($res.reason -match '2 permission denial')
    Assert-True  -Name 'denials - reason names the denied tools' -Condition (($res.reason -match 'Read') -and ($res.reason -match 'Bash'))

    # Malformed Claude stdout is rejected the same way Gemini's is.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -RawStdout '{"type":"result","malformed'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'claude malformed stdout is INVALID_OUTPUT' -Expected 'INVALID_OUTPUT' -Actual $res.result

    # A CLI-level error is FAILED, not COMPLETED.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport -IsError $true -Subtype 'error_during_execution' -ResultText 'model overloaded'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'claude CLI error is FAILED (not COMPLETED)' -Expected 'FAILED' -Actual $res.result
    Assert-True  -Name 'claude CLI error names the subtype' -Condition ($res.reason -match 'error_during_execution')

    # structured_output is the SOLE authoritative task result. A clean CLI exit
    # carrying a plausible report in the `result` text field must NOT be accepted.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -Report $null -Subtype 'success' -IsError $false `
        -ResultText '{"status":"completed","files_changed":["src/a.py"],"summary":"via result"}'

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'clean CLI exit without structured_output is INVALID_OUTPUT' -Expected 'INVALID_OUTPUT' -Actual $res.result
    Assert-True  -Name 'reason says a clean exit is not proof of task success' -Condition ($res.reason -match 'not proof')
    Assert-True  -Name 'no WORKER_REPORT.json is persisted without structured_output' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $runDir 'WORKER_REPORT.json')))

    # =======================================================================
    # CLAUDE HEADLESS CONTRACT (55 - 62)   [AO-CLAUDE-003]
    # =======================================================================

    # 55. structured_output status drives the verdict, never the CLI envelope.
    #     Each case ships a "clean" envelope (is_error false, subtype success) so
    #     the verdict can only be coming from structured_output.
    foreach ($case in @(
        @{ Status = 'completed'; Verdict = 'COMPLETED'; Code = 0 },
        @{ Status = 'blocked';   Verdict = 'BLOCKED';   Code = 1 },
        @{ Status = 'failed';    Verdict = 'FAILED';    Code = 2 }
    )) {
        $f = New-InvokeWorkerFixture
        $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
        $runDir = $f.RunDir

        $env:FAKE_WORKER_EXIT_CODE = "0"
        $env:FAKE_WORKER_SLEEP_MS = "0"
        $env:FAKE_WORKER_WRITE_ARGS = ""
        Set-ClaudeWorkerOutput -Subtype 'success' -IsError $false -Report ([ordered]@{
            status        = $case.Status
            files_changed = @('src/main.py')
            summary       = "worker reported $($case.Status)"
        })

        $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
        $caseExit = $LASTEXITCODE
        $res = $resRaw | ConvertFrom-Json

        Assert-Equal -Name "structured_output '$($case.Status)' -> $($case.Verdict)" -Expected $case.Verdict -Actual $res.result
        Assert-Equal -Name "structured_output '$($case.Status)' -> exit code $($case.Code)" -Expected $case.Code -Actual $caseExit
    }

    # 56. Malformed structured_output is INVALID_OUTPUT and persists nothing.
    foreach ($bad in @('"just a string"', '[1,2,3]', '12345')) {
        $f = New-InvokeWorkerFixture
        $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
        $runDir = $f.RunDir
        Set-ClaudeWorkerOutput -RawStdout ('{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s","result":"ok","permission_denials":[],"structured_output":' + $bad + '}')

        $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
        $res = $resRaw | ConvertFrom-Json
        Assert-Equal -Name "malformed structured_output ($bad) -> INVALID_OUTPUT" -Expected 'INVALID_OUTPUT' -Actual $res.result
        Assert-True  -Name "malformed structured_output ($bad) persists no report" `
            -Condition (-not (Test-Path -LiteralPath (Join-Path $runDir 'WORKER_REPORT.json')))
    }

    # A structurally invalid report (bad status enum) is also INVALID_OUTPUT.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -Report ([ordered]@{ status = 'done'; files_changed = @(); summary = 'x' })
    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'invalid status enum -> INVALID_OUTPUT' -Expected 'INVALID_OUTPUT' -Actual $res.result

    # 57. Supervisor owns WORKER_REPORT.json: written exactly once, containing only
    #     the validated report - never the Claude envelope.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $reportFile = Join-Path $runDir "WORKER_REPORT.json"

    $ownedReport = [ordered]@{
        status        = 'completed'
        files_changed = @('src/main.py', 'src/util.py')
        summary       = 'Supervisor-owned persistence'
        risks         = @('none')
    }
    Set-ClaudeWorkerOutput -Report $ownedReport

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    Assert-Equal -Name 'ownership - result is COMPLETED' -Expected 'COMPLETED' -Actual $res.result

    $reportFiles = @(Get-ChildItem -LiteralPath $runDir -Filter 'WORKER_REPORT*.json' -File)
    Assert-Equal -Name 'ownership - exactly one WORKER_REPORT file exists' -Expected 1 -Actual $reportFiles.Count

    $persistedRaw = Get-Content -LiteralPath $reportFile -Raw
    $persisted = $persistedRaw | ConvertFrom-Json
    Assert-CollectionEqual -Name 'ownership - persisted keys are exactly the report keys' `
        -Expected @('status', 'files_changed', 'summary', 'risks') -Actual @($persisted.PSObject.Properties.Name)
    Assert-Equal -Name 'ownership - persisted summary matches structured_output' -Expected 'Supervisor-owned persistence' -Actual $persisted.summary
    Assert-Equal -Name 'ownership - persisted files_changed count matches' -Expected 2 -Actual (@($persisted.files_changed).Count)

    # No envelope field may leak into the persisted report.
    foreach ($envelopeKey in @('type', 'subtype', 'is_error', 'session_id', 'usage', 'permission_denials', 'total_cost_usd', 'structured_output', 'num_turns')) {
        Assert-True -Name "ownership - envelope key '$envelopeKey' absent from persisted report" `
            -Condition ($persistedRaw -notmatch ('"' + [regex]::Escape($envelopeKey) + '"'))
    }

    # 58. A second invocation against the same run directory is refused outright,
    #     so the Supervisor can never write the report twice.
    $resRaw2 = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $secondExit = $LASTEXITCODE
    $res2 = $resRaw2 | ConvertFrom-Json
    Assert-Equal -Name 'ownership - re-run with existing report is refused' -Expected 'FAILED' -Actual $res2.result
    Assert-True  -Name 'ownership - refusal names the existing report' -Condition ($res2.reason -match 'WORKER_REPORT.json already exists')
    Assert-Equal -Name 'ownership - refusal exits 2' -Expected 2 -Actual $secondExit
    Assert-Equal -Name 'ownership - existing report is left byte-identical' -Expected $persistedRaw -Actual (Get-Content -LiteralPath $reportFile -Raw)

    # 59. The prompt is self-sufficient: no run-directory, policy or schema reads.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $argsFile = Join-Path $runDir "args.txt"
    $env:FAKE_WORKER_WRITE_ARGS = $argsFile
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport

    $null = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $promptText = (Get-Content -LiteralPath $argsFile)[-1]

    Assert-True -Name 'input contract - prompt includes task_id' -Condition ($promptText -match 'task-101')
    Assert-True -Name 'input contract - prompt includes objective' -Condition ($promptText -match 'Implement feature X')
    Assert-True -Name 'input contract - prompt includes allowed_paths content' -Condition ($promptText -match 'src/')
    Assert-True -Name 'input contract - prompt includes forbidden_paths section' -Condition ($promptText -match 'forbidden_paths')
    Assert-True -Name 'input contract - prompt includes acceptance_criteria content' -Condition ($promptText -match 'Code passes tests')
    Assert-True -Name 'input contract - prompt includes assigned workspace' -Condition ($promptText -match [regex]::Escape($f.Workspace))

    # It must not point the worker at anything outside its worktree.
    Assert-True -Name 'input contract - prompt never names the run directory' -Condition ($promptText -notmatch [regex]::Escape($runDir))
    Assert-True -Name 'input contract - prompt requires no schema file read' -Condition ($promptText -notmatch 'WORKER_REPORT\.schema\.json')
    Assert-True -Name 'input contract - prompt requires no policy file read' -Condition ($promptText -notmatch 'WORKER_POLICY|SECURITY_POLICY|policies[\\/]')
    Assert-True -Name 'input contract - prompt requires no TASK.json read' -Condition ($promptText -notmatch 'Read the assigned TASK\.json')
    Assert-True -Name 'input contract - prompt inlines the report contract instead' -Condition ($promptText -match '"files_changed" \(required\)')

    # 60. Usage: runtime_seconds accumulates and the adapter rule holds.
    #     ADAPTER RULE (provisional, AO-CLAUDE-003):
    #       total_tokens = input + cache_creation_input + cache_read_input + output
    #     thinking_tokens is a breakdown of output_tokens and is NEVER added again.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    $usageFile = Join-Path $runDir "USAGE.json"
    @{ task_id = "task-101"; worker_calls = 3; reviewer_calls = 4; correction_rounds = 2
       runtime_seconds = 40; total_tokens = 1000 } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $usageFile -Encoding UTF8

    $env:FAKE_WORKER_WRITE_ARGS = ""
    $env:FAKE_WORKER_SLEEP_MS = "1100"
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport -Usage @{
        input_tokens                = 11
        cache_creation_input_tokens = 22
        cache_read_input_tokens     = 33
        output_tokens               = 44
        output_tokens_details       = @{ thinking_tokens = 40 }
    }

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $res = $resRaw | ConvertFrom-Json
    $env:FAKE_WORKER_SLEEP_MS = "0"

    # 11 + 22 + 33 + 44 = 110. Adding thinking_tokens would give 150 - it must not.
    Assert-Equal -Name 'adapter rule - total_tokens is the four-counter sum' -Expected 110 -Actual $res.total_tokens
    Assert-True  -Name 'adapter rule - thinking_tokens not double-counted' -Condition ($res.total_tokens -ne 150)
    Assert-Equal -Name 'adapter rule - thinking_tokens still reported' -Expected 40 -Actual $res.thinking_tokens

    $u = Get-Content -LiteralPath $usageFile -Raw | ConvertFrom-Json
    Assert-Equal -Name 'usage - worker_calls increments exactly once' -Expected 4 -Actual $u.worker_calls
    Assert-Equal -Name 'usage - total_tokens accumulates onto the prior value' -Expected 1110 -Actual $u.total_tokens
    Assert-True  -Name 'usage - runtime_seconds accumulates' -Condition ($u.runtime_seconds -gt 40)
    Assert-Equal -Name 'usage - reviewer_calls preserved' -Expected 4 -Actual $u.reviewer_calls
    Assert-Equal -Name 'usage - correction_rounds preserved' -Expected 2 -Actual $u.correction_rounds
    Assert-CollectionEqual -Name 'usage - USAGE.json keys stay exactly the declared contract' `
        -Expected @('task_id', 'worker_calls', 'reviewer_calls', 'correction_rounds', 'runtime_seconds', 'total_tokens') `
        -Actual @($u.PSObject.Properties.Name)

    # 61. Budget STOP still fires for Claude, and artifacts survive it.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport -Usage @{
        input_tokens                = 100000
        cache_creation_input_tokens = 0
        cache_read_input_tokens     = 72798
        output_tokens               = 0
    }

    $resRaw = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $stopExit = $LASTEXITCODE
    $res = $resRaw | ConvertFrom-Json

    Assert-Equal -Name 'budget - claude over-budget run yields STOP' -Expected 'STOP' -Actual $res.result
    Assert-Equal -Name 'budget - escalation_reason is budget_exhausted' -Expected 'budget_exhausted' -Actual $res.escalation_reason
    Assert-Equal -Name 'budget - STOP exits 2' -Expected 2 -Actual $stopExit
    Assert-True  -Name 'budget - runtime artifacts are preserved through STOP' `
        -Condition ((Test-Path -LiteralPath (Join-Path $runDir 'USAGE.json')) -and (Test-Path -LiteralPath (Join-Path $runDir 'logs/worker.stdout.log')))
    $stopUsage = Get-Content -LiteralPath (Join-Path $runDir 'USAGE.json') -Raw | ConvertFrom-Json
    Assert-Equal -Name 'budget - USAGE.json still updated exactly once before STOP' -Expected 1 -Actual $stopUsage.worker_calls

    # 62. The --bare cost experiment is deliberately NOT enabled yet, but the
    #     argument builder has a single extension point for it.
    $f = New-InvokeWorkerFixture
    $taskFile = New-TestJsonFile -Directory $f.TmpDir -FileName "TASK.json" -Data $f.TaskData
    $runDir = $f.RunDir
    Set-ClaudeWorkerOutput -Report $claudeCompletedReport
    $null = & $invokeScript -Worker "claude" -TaskFile $taskFile -Workspace $f.Workspace -RunDirectory $runDir -AsJson -OverrideExecutablePath $fakeWorkerExe
    $plan = Get-LaunchPlan -RunDirectory $runDir
    $planArgs = @($plan.arguments)
    Assert-True -Name 'cost experiment - --bare is not enabled in this task' -Condition (-not ($planArgs -contains '--bare'))
    Assert-True -Name 'cost experiment - bounded prompt is still the final argument' `
        -Condition ($planArgs[-1] -match 'You are a worker agent executing a bounded task under the AI_ORCHESTRA system')

}
finally {
    # Reset env variables
    $env:FAKE_WORKER_EXIT_CODE = "0"
    $env:FAKE_WORKER_SLEEP_MS = "0"
    $env:FAKE_WORKER_WRITE_CWD = ""
    $env:FAKE_WORKER_WRITE_ARGS = ""
    $env:FAKE_WORKER_WRITE_HOST = ""
    $env:FAKE_WORKER_STDOUT = ""
    $env:FAKE_WORKER_REPORT_DEST = ""
    $env:FAKE_WORKER_REPORT_CONTENT = ""

    foreach ($fixture in $fixtures) {
        Remove-TempDirectory -Path $fixture
    }
}

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
