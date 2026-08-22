#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\New-AgentRun.ps1.

.DESCRIPTION
    Runnable directly:  pwsh -File tests\Test-AgentRun.Tests.ps1
    Also returns the failure count so a shared runner can aggregate it.

    Every fixture lives under a disposable temp directory, including a
    synthetic PROJECT_STATE.json whose runtime_runs_root points into that temp
    tree. The real C:\tmp\ai-orchestra-runs is never touched, and the
    AI_ORCHESTRA repository is never written to.

.NOTES
    Exit codes: 0 all passed, 1 assertion failures.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $here
$scriptPath = Join-Path $repoRoot 'scripts/New-AgentRun.ps1'

. (Join-Path $here 'TestHelpers.ps1')
. $scriptPath

Set-TestSuite 'New-AgentRun'

$fixtures = [System.Collections.Generic.List[string]]::new()

function New-RunFixture {
    <#
    .SYNOPSIS
        Disposable sandbox: runs root, a PROJECT_STATE.json pointing at it, and
        a valid TASK.json.
    .OUTPUTS
        Hashtable @{ Sandbox; RunsRoot; ProjectState; Task }
    #>
    param([hashtable] $TaskOverrides = @{})

    $sandbox = New-TempDirectory
    $script:fixtures.Add($sandbox) | Out-Null

    $runsRoot = Join-Path $sandbox 'ai-orchestra-runs'
    New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null

    $projectState = New-TestJsonFile -Directory $sandbox -FileName 'PROJECT_STATE.json' -Data @{
        project_name          = 'AI_ORCHESTRA'
        repository            = 'roager/AI_ORCHESTRA'
        default_branch        = 'main'
        protected_branches    = @('main')
        source_root           = $sandbox
        runtime_worktree_root = (Join-Path $sandbox 'ai-orchestra-worktrees')
        runtime_runs_root     = $runsRoot
        current_phase         = 'Phase 1'
    }

    $task = [ordered]@{
        task_id             = 'ao-run-001'
        project             = 'AI_ORCHESTRA_TEST'
        repository          = 'owner/test'
        branch              = 'agent/ao-run-001'
        workspace           = (Join-Path $sandbox 'wt')
        objective           = 'Run initialization fixture'
        allowed_paths       = @('src/api')
        forbidden_paths     = @('.github')
        acceptance_criteria = @('fixture only')
    }
    foreach ($k in $TaskOverrides.Keys) { $task[$k] = $TaskOverrides[$k] }

    $taskPath = Join-Path $sandbox 'TASK.json'
    $task | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskPath -Encoding UTF8

    return @{ Sandbox = $sandbox; RunsRoot = $runsRoot; ProjectState = $projectState; Task = $taskPath }
}

function Invoke-RunCase {
    param([hashtable] $Fixture, [string] $RunId, [string] $RunDirectory, [string] $TaskFile)

    $t = if ($PSBoundParameters.ContainsKey('TaskFile')) { $TaskFile } else { $Fixture.Task }
    $d = if ($PSBoundParameters.ContainsKey('RunDirectory')) { $RunDirectory } else { '' }

    $res = New-AgentRunDirectory -TaskFile $t -RunId $RunId -RunDirectory $d -ProjectStateFile $Fixture.ProjectState
    return [pscustomobject]@{ Result = $res; ExitCode = (Get-AgentRunExitCode -Result $res) }
}

function Get-DirectorySnapshot {
    <# Sorted relative paths under $Root, for before/after damage comparison. #>
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force |
             ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar) } |
             Sort-Object)
}

try {
    # =======================================================================
    # SUCCESS
    # =======================================================================

    # --- 1. valid run initialization --------------------------------------
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'run-001'
    Assert-Equal -Name '1. valid initialization returns CREATED' -Expected 'CREATED' -Actual $r.Result.result
    Assert-Equal -Name '1. valid initialization exits 0'         -Expected 0         -Actual $r.ExitCode
    $runDir = Join-Path $f.RunsRoot 'run-001'
    Assert-True  -Name '1. run directory exists' -Condition (Test-Path -LiteralPath $runDir -PathType Container)
    Assert-Equal -Name '1. run_directory is reported' -Expected $runDir -Actual $r.Result.run_directory
    Assert-Equal -Name '1. run_id is reported'        -Expected 'run-001' -Actual $r.Result.run_id

    # --- 2. TASK.json copied correctly ------------------------------------
    $srcHash  = (Get-FileHash -LiteralPath $f.Task -Algorithm SHA256).Hash
    $destTask = Join-Path $runDir 'TASK.json'
    Assert-True  -Name '2. TASK.json exists in run directory' -Condition (Test-Path -LiteralPath $destTask -PathType Leaf)
    Assert-Equal -Name '2. TASK.json copy is byte-identical to source' `
        -Expected $srcHash -Actual (Get-FileHash -LiteralPath $destTask -Algorithm SHA256).Hash
    $copied = Get-Content -LiteralPath $destTask -Raw | ConvertFrom-Json
    Assert-Equal -Name '2. copied task_id matches' -Expected 'ao-run-001' -Actual $copied.task_id

    # --- 3. original TASK.json unchanged ----------------------------------
    Assert-Equal -Name '3. source TASK.json unchanged after run creation' `
        -Expected $srcHash -Actual (Get-FileHash -LiteralPath $f.Task -Algorithm SHA256).Hash

    # --- 4/5/6. STATUS.json ------------------------------------------------
    $statusPath = Join-Path $runDir 'STATUS.json'
    Assert-True -Name '4. STATUS.json created' -Condition (Test-Path -LiteralPath $statusPath -PathType Leaf)
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    Assert-Equal -Name '5. STATUS initial state is CREATED' -Expected 'CREATED' -Actual $status.state
    Assert-Equal -Name '5. initial_state echoed in output'  -Expected 'CREATED' -Actual $r.Result.initial_state
    Assert-Equal -Name '6. STATUS correction_rounds is 0' -Expected 0 -Actual $status.correction_rounds
    Assert-Equal -Name '6. STATUS worker_calls is 0'     -Expected 0 -Actual $status.worker_calls
    Assert-Equal -Name '6. STATUS reviewer_calls is 0'   -Expected 0 -Actual $status.reviewer_calls
    Assert-Equal -Name '6. STATUS task_id matches task'  -Expected 'ao-run-001' -Actual $status.task_id
    # Assert on the raw file text: ConvertFrom-Json coerces ISO 8601 strings to
    # DateTime, so the parsed object cannot prove the on-disk format.
    $statusRaw = Get-Content -LiteralPath $statusPath -Raw
    Assert-True -Name '6. STATUS updated_at is ISO 8601 UTC on disk' `
        -Condition ($statusRaw -match '"updated_at":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') -Detail $statusRaw
    Assert-True -Name '6. STATUS started_at is ISO 8601 UTC on disk' `
        -Condition ($statusRaw -match '"started_at":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') -Detail $statusRaw

    # STATUS must satisfy schemas\STATUS.schema.json (additionalProperties:false).
    $statusSchema = Join-Path $repoRoot 'schemas/STATUS.schema.json'
    if (Test-Path -LiteralPath $statusSchema) {
        $allowed = @((Get-Content -LiteralPath $statusSchema -Raw | ConvertFrom-Json).properties.PSObject.Properties.Name)
        $extra   = @($status.PSObject.Properties.Name | Where-Object { $allowed -notcontains $_ })
        Assert-Equal -Name '6. STATUS has no properties outside STATUS.schema.json' -Expected 0 -Actual $extra.Count
        $required = @((Get-Content -LiteralPath $statusSchema -Raw | ConvertFrom-Json).required)
        $absent   = @($required | Where-Object { $status.PSObject.Properties.Name -notcontains $_ })
        Assert-Equal -Name '6. STATUS contains every required property' -Expected 0 -Actual $absent.Count
    }

    # --- 7/8. USAGE.json ---------------------------------------------------
    $usagePath = Join-Path $runDir 'USAGE.json'
    Assert-True -Name '7. USAGE.json created' -Condition (Test-Path -LiteralPath $usagePath -PathType Leaf)
    $usage = Get-Content -LiteralPath $usagePath -Raw | ConvertFrom-Json
    Assert-Equal -Name '8. USAGE worker_calls is 0'      -Expected 0 -Actual $usage.worker_calls
    Assert-Equal -Name '8. USAGE reviewer_calls is 0'    -Expected 0 -Actual $usage.reviewer_calls
    Assert-Equal -Name '8. USAGE correction_rounds is 0' -Expected 0 -Actual $usage.correction_rounds
    Assert-Equal -Name '8. USAGE runtime_seconds is 0'   -Expected 0 -Actual $usage.runtime_seconds
    Assert-Equal -Name '8. USAGE total_tokens is 0'      -Expected 0 -Actual $usage.total_tokens
    Assert-Equal -Name '8. USAGE task_id matches task'   -Expected 'ao-run-001' -Actual $usage.task_id

    $usageSchema = Join-Path $repoRoot 'schemas/USAGE.schema.json'
    if (Test-Path -LiteralPath $usageSchema) {
        $uAllowed = @((Get-Content -LiteralPath $usageSchema -Raw | ConvertFrom-Json).properties.PSObject.Properties.Name)
        $uExtra   = @($usage.PSObject.Properties.Name | Where-Object { $uAllowed -notcontains $_ })
        Assert-Equal -Name '8. USAGE has no properties outside USAGE.schema.json' -Expected 0 -Actual $uExtra.Count
        $uRequired = @((Get-Content -LiteralPath $usageSchema -Raw | ConvertFrom-Json).required)
        $uAbsent   = @($uRequired | Where-Object { $usage.PSObject.Properties.Name -notcontains $_ })
        Assert-Equal -Name '8. USAGE contains every required property' -Expected 0 -Actual $uAbsent.Count
    }
    Assert-True -Name '8. USAGE does not use the retired runtime_minutes name' `
        -Condition ($usage.PSObject.Properties.Name -notcontains 'runtime_minutes')

    # --- 9. logs directory -------------------------------------------------
    $logsPath = Join-Path $runDir 'logs'
    Assert-True  -Name '9. logs directory created' -Condition (Test-Path -LiteralPath $logsPath -PathType Container)
    Assert-Equal -Name '9. logs directory is empty' -Expected 0 -Actual @(Get-ChildItem -LiteralPath $logsPath -Force).Count

    # Lifecycle artifacts owned by later stages must NOT be present.
    foreach ($later in @('WORKER_REPORT.json', 'REVIEW.json', 'RESULT.json', 'HUMAN_DECISION.json')) {
        Assert-True -Name "9. $later is not created by this stage" `
            -Condition (-not (Test-Path -LiteralPath (Join-Path $runDir $later)))
    }
    Assert-CollectionEqual -Name '9. run directory contains exactly the expected entries' `
        -Expected @('TASK.json', 'STATUS.json', 'USAGE.json', 'logs') `
        -Actual   @(Get-ChildItem -LiteralPath $runDir -Force | ForEach-Object { $_.Name })

    # --- 10. deterministic JSON output -------------------------------------
    $f = New-RunFixture
    $jsonOut = & $scriptPath -TaskFile $f.Task -RunId 'run-json' -ProjectStateFile $f.ProjectState -AsJson
    $exitJson = $LASTEXITCODE
    Assert-Equal -Name '10. -AsJson invocation exits 0' -Expected 0 -Actual $exitJson
    $parsed = $null
    try { $parsed = ($jsonOut | Out-String) | ConvertFrom-Json } catch { }
    Assert-True  -Name '10. -AsJson emits parseable JSON' -Condition ($null -ne $parsed)
    if ($null -ne $parsed) {
        foreach ($k in @('result', 'run_id', 'run_directory', 'task_id', 'initial_state')) {
            Assert-True -Name "10. JSON output contains '$k'" -Condition ($parsed.PSObject.Properties.Name -contains $k)
        }
        Assert-Equal -Name '10. JSON result is CREATED'        -Expected 'CREATED'    -Actual $parsed.result
        Assert-Equal -Name '10. JSON run_id is correct'        -Expected 'run-json'   -Actual $parsed.run_id
        Assert-Equal -Name '10. JSON task_id is correct'       -Expected 'ao-run-001' -Actual $parsed.task_id
        Assert-Equal -Name '10. JSON initial_state is CREATED' -Expected 'CREATED'    -Actual $parsed.initial_state
    }
    Assert-Equal -Name '10. JSON output is a single line' -Expected 1 `
        -Actual @(($jsonOut | Out-String).Trim() -split "`n").Count

    # =======================================================================
    # REJECTIONS
    # =======================================================================

    # --- 11. malformed TASK.json -------------------------------------------
    $f = New-RunFixture
    $badTask = Join-Path $f.Sandbox 'malformed.json'
    Set-Content -LiteralPath $badTask -Value '{ "task_id": ' -Encoding UTF8
    $r = Invoke-RunCase -Fixture $f -RunId 'run-bad' -TaskFile $badTask
    Assert-Equal -Name '11. malformed TASK.json is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $r.Result.result
    Assert-Equal -Name '11. malformed TASK.json exits 3'        -Expected 3             -Actual $r.ExitCode
    Assert-True  -Name '11. malformed TASK.json creates no run directory' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $f.RunsRoot 'run-bad')))

    # A task missing required fields is also rejected.
    $f = New-RunFixture
    $thin = New-TestJsonFile -Directory $f.Sandbox -FileName 'thin.json' -Data @{ task_id = 'x' }
    $r = Invoke-RunCase -Fixture $f -RunId 'run-thin' -TaskFile $thin
    Assert-Equal -Name '11b. TASK.json missing required fields is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $r.Result.result
    Assert-Equal -Name '11b. rejection code names the cause' -Expected 'task_missing_required_fields' -Actual $r.Result.code

    # --- 12. missing TASK.json ----------------------------------------------
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'run-missing' -TaskFile (Join-Path $f.Sandbox 'nope.json')
    Assert-Equal -Name '12. missing TASK.json is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $r.Result.result
    Assert-Equal -Name '12. missing TASK.json exits 3'        -Expected 3             -Actual $r.ExitCode
    Assert-Equal -Name '12. missing TASK.json code'           -Expected 'task_not_found' -Actual $r.Result.code

    # --- 13-17. unsafe RunId values -----------------------------------------
    $unsafeIds = @(
        @{ Label = '13. empty RunId';                 Id = '' },
        @{ Label = '13b. whitespace RunId';           Id = '   ' },
        @{ Label = '14. RunId containing ".."';       Id = '..' },
        @{ Label = '14b. RunId "../escape"';          Id = '../escape' },
        @{ Label = '14c. RunId "run..evil"';          Id = 'run..evil' },
        @{ Label = '14d. RunId "."';                  Id = '.' },
        @{ Label = '15. RunId containing slash';      Id = 'a/b' },
        @{ Label = '15b. RunId "../../etc/passwd"';   Id = '../../etc/passwd' },
        @{ Label = '16. RunId containing backslash';  Id = 'a\b' },
        @{ Label = '16b. RunId "..\..\windows"';      Id = '..\..\windows' },
        @{ Label = '17. absolute-path RunId (drive)'; Id = 'C:\tmp\evil' },
        @{ Label = '17b. absolute-path RunId (unix)'; Id = '/etc/passwd' },
        @{ Label = '17c. UNC-style RunId';            Id = '\\server\share' },
        @{ Label = '17d. RunId with drive marker';    Id = 'C:evil' },
        @{ Label = '17e. RunId starting with ~';      Id = '~evil' },
        @{ Label = '17f. RunId with trailing space';  Id = 'run1 ' },
        @{ Label = '17g. RunId with trailing dot';    Id = 'run1.' }
    )
    foreach ($u in $unsafeIds) {
        $f = New-RunFixture
        $before = Get-DirectorySnapshot -Root $f.RunsRoot
        $r = Invoke-RunCase -Fixture $f -RunId $u.Id
        Assert-Equal -Name "$($u.Label) is REJECTED" -Expected 'REJECTED' -Actual $r.Result.result
        Assert-Equal -Name "$($u.Label) exits 2"     -Expected 2          -Actual $r.ExitCode
        Assert-Equal -Name "$($u.Label) code is unsafe_run_id" -Expected 'unsafe_run_id' -Actual $r.Result.code
        Assert-CollectionEqual -Name "$($u.Label) leaves the runs root untouched" `
            -Expected $before -Actual (Get-DirectorySnapshot -Root $f.RunsRoot)
    }

    # --- 18. RunDirectory outside runtime root -------------------------------
    $f = New-RunFixture
    $outside = Join-Path $f.Sandbox 'not-the-runs-root'
    $r = Invoke-RunCase -Fixture $f -RunId 'run-out' -RunDirectory $outside
    Assert-Equal -Name '18. RunDirectory outside runtime root is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result
    Assert-Equal -Name '18. exits 2' -Expected 2 -Actual $r.ExitCode
    Assert-Equal -Name '18. code is outside_runtime_root' -Expected 'outside_runtime_root' -Actual $r.Result.code
    Assert-True  -Name '18. nothing was created at the outside path' -Condition (-not (Test-Path -LiteralPath $outside))

    # Traversal back out of the root is rejected too.
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'run-trav' -RunDirectory (Join-Path $f.RunsRoot '..\escaped')
    Assert-Equal -Name '18b. RunDirectory traversing out of the root is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result
    Assert-Equal -Name '18b. code is outside_runtime_root' -Expected 'outside_runtime_root' -Actual $r.Result.code

    # The runs root itself is not a valid run directory.
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'run-root' -RunDirectory $f.RunsRoot
    Assert-Equal -Name '18c. the runs root itself is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result

    # --- 19. sibling-prefix escape --------------------------------------------
    # <sandbox>\ai-orchestra-runs-evil must NOT be authorized by
    # <sandbox>\ai-orchestra-runs.
    $f = New-RunFixture
    $sibling = (Join-Path $f.Sandbox 'ai-orchestra-runs-evil')
    $r = Invoke-RunCase -Fixture $f -RunId 'run1' -RunDirectory (Join-Path $sibling 'run1')
    Assert-Equal -Name '19. sibling-prefix directory is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result
    Assert-Equal -Name '19. exits 2' -Expected 2 -Actual $r.ExitCode
    Assert-Equal -Name '19. code is outside_runtime_root' -Expected 'outside_runtime_root' -Actual $r.Result.code
    Assert-True  -Name '19. sibling directory was not created' -Condition (-not (Test-Path -LiteralPath $sibling))

    # The containment predicate itself, exercised directly.
    Assert-True -Name '19b. root does not authorize a sibling-prefix path' `
        -Condition (-not (Test-PathUnderRoot -Candidate '/tmp/ai-orchestra-runs-evil/run1' -Root '/tmp/ai-orchestra-runs'))
    Assert-True -Name '19c. root does authorize a real child' `
        -Condition (Test-PathUnderRoot -Candidate '/tmp/ai-orchestra-runs/run1' -Root '/tmp/ai-orchestra-runs')
    Assert-True -Name '19d. root is not under itself' `
        -Condition (-not (Test-PathUnderRoot -Candidate '/tmp/ai-orchestra-runs' -Root '/tmp/ai-orchestra-runs'))

    # --- 20. existing non-empty run directory ----------------------------------
    $f = New-RunFixture
    $existing = Join-Path $f.RunsRoot 'run-existing'
    New-Item -ItemType Directory -Path $existing -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $existing 'pre-existing.txt') -Value 'do not touch' -Encoding UTF8
    $preHash = (Get-FileHash -LiteralPath (Join-Path $existing 'pre-existing.txt') -Algorithm SHA256).Hash
    $r = Invoke-RunCase -Fixture $f -RunId 'run-existing'
    Assert-Equal -Name '20. existing non-empty run directory is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result
    Assert-Equal -Name '20. exits 2' -Expected 2 -Actual $r.ExitCode
    Assert-Equal -Name '20. code is run_directory_not_empty' -Expected 'run_directory_not_empty' -Actual $r.Result.code
    Assert-Equal -Name '20. pre-existing file survives untouched' `
        -Expected $preHash -Actual (Get-FileHash -LiteralPath (Join-Path $existing 'pre-existing.txt') -Algorithm SHA256).Hash
    Assert-True  -Name '20. no STATUS.json written into the existing directory' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $existing 'STATUS.json')))

    # An empty pre-existing directory is acceptable and is populated.
    $f = New-RunFixture
    $emptyDir = Join-Path $f.RunsRoot 'run-empty'
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $r = Invoke-RunCase -Fixture $f -RunId 'run-empty'
    Assert-Equal -Name '20b. empty pre-existing directory is accepted' -Expected 'CREATED' -Actual $r.Result.result

    # --- 21. existing runtime artifact not overwritten ---------------------------
    foreach ($artifact in @('TASK.json', 'STATUS.json', 'USAGE.json')) {
        $f = New-RunFixture
        $dir = Join-Path $f.RunsRoot 'run-artifact'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $artifactPath = Join-Path $dir $artifact
        Set-Content -LiteralPath $artifactPath -Value '{"sentinel":true}' -Encoding UTF8
        $sentinelHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash

        $r = Invoke-RunCase -Fixture $f -RunId 'run-artifact'
        Assert-Equal -Name "21. existing $artifact blocks initialization" -Expected 'REJECTED' -Actual $r.Result.result
        Assert-Equal -Name "21. existing $artifact exits 2" -Expected 2 -Actual $r.ExitCode
        Assert-Equal -Name "21. existing $artifact is not replaced" `
            -Expected $sentinelHash -Actual (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    }

    # =======================================================================
    # SECURITY / INTEGRITY
    # =======================================================================

    # --- 22. no files created outside the validated run directory ---------------
    $f = New-RunFixture
    $sandboxBefore = Get-DirectorySnapshot -Root $f.Sandbox
    $r = Invoke-RunCase -Fixture $f -RunId 'run-contained'
    Assert-Equal -Name '22. contained run succeeds' -Expected 'CREATED' -Actual $r.Result.result

    $sandboxAfter = Get-DirectorySnapshot -Root $f.Sandbox
    $newEntries   = @($sandboxAfter | Where-Object { $sandboxBefore -notcontains $_ })
    $runDirLeaf   = Join-Path 'ai-orchestra-runs' 'run-contained'
    $escapees     = @($newEntries | Where-Object { -not $_.StartsWith($runDirLeaf, [System.StringComparison]::OrdinalIgnoreCase) })
    Assert-Equal -Name '22. every new filesystem entry is inside the run directory' -Expected 0 -Actual $escapees.Count
    # run directory itself + TASK.json + STATUS.json + USAGE.json + logs
    Assert-Equal -Name '22. exactly the five expected entries were created' -Expected 5 -Actual $newEntries.Count

    # Every path the script reports as created is inside the runs root.
    $outsideCreated = @($r.Result.created | Where-Object { -not (Test-PathUnderRoot -Candidate $_ -Root $f.RunsRoot) })
    Assert-Equal -Name '22b. no reported created path lies outside runtime_runs_root' -Expected 0 -Actual $outsideCreated.Count

    # --- 23. failed initialization does not damage pre-existing files -----------
    # A pre-existing STATUS.json blocks the run; the sibling file and the
    # directory listing must be exactly as before.
    $f = New-RunFixture
    $dir = Join-Path $f.RunsRoot 'run-damage'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'STATUS.json')  -Value '{"state":"REVIEWING"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir 'important.txt') -Value 'precious' -Encoding UTF8
    $beforeSnap = Get-DirectorySnapshot -Root $dir
    $beforeHash = (Get-FileHash -LiteralPath (Join-Path $dir 'important.txt') -Algorithm SHA256).Hash

    $r = Invoke-RunCase -Fixture $f -RunId 'run-damage'
    Assert-Equal -Name '23. blocked run is REJECTED' -Expected 'REJECTED' -Actual $r.Result.result
    Assert-CollectionEqual -Name '23. pre-existing directory listing is unchanged' `
        -Expected $beforeSnap -Actual (Get-DirectorySnapshot -Root $dir)
    Assert-Equal -Name '23. pre-existing sibling file is unchanged' `
        -Expected $beforeHash -Actual (Get-FileHash -LiteralPath (Join-Path $dir 'important.txt') -Algorithm SHA256).Hash
    Assert-Equal -Name '23. pre-existing STATUS.json still holds its original content' `
        -Expected 'REVIEWING' -Actual ((Get-Content -LiteralPath (Join-Path $dir 'STATUS.json') -Raw | ConvertFrom-Json).state)

    # Rollback removes only what an invocation created, never a pre-existing dir.
    $f = New-RunFixture
    $keep = Join-Path $f.RunsRoot 'keep-me'
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $keep 'keep.txt') -Value 'keep' -Encoding UTF8
    Remove-CreatedArtifact -CreatedPaths @($keep) -RunsRoot $f.RunsRoot
    Assert-True -Name '23b. rollback never deletes a non-empty pre-existing directory' `
        -Condition (Test-Path -LiteralPath (Join-Path $keep 'keep.txt'))

    # Rollback refuses to act on a path outside the runs root.
    $f = New-RunFixture
    $outsideFile = Join-Path $f.Sandbox 'outside.txt'
    Set-Content -LiteralPath $outsideFile -Value 'outside' -Encoding UTF8
    Remove-CreatedArtifact -CreatedPaths @($outsideFile) -RunsRoot $f.RunsRoot
    Assert-True -Name '23c. rollback refuses to delete outside runtime_runs_root' `
        -Condition (Test-Path -LiteralPath $outsideFile)

    # --- 24. source TASK.json remains byte-identical -----------------------------
    $f = New-RunFixture
    $hashBefore = (Get-FileHash -LiteralPath $f.Task -Algorithm SHA256).Hash
    $writeBefore = (Get-Item -LiteralPath $f.Task).LastWriteTimeUtc
    $null = Invoke-RunCase -Fixture $f -RunId 'run-src-a'
    $null = Invoke-RunCase -Fixture $f -RunId 'run-src-b'
    $null = Invoke-RunCase -Fixture $f -RunId '../evil'
    Assert-Equal -Name '24. source TASK.json is byte-identical after 3 invocations' `
        -Expected $hashBefore -Actual (Get-FileHash -LiteralPath $f.Task -Algorithm SHA256).Hash
    Assert-Equal -Name '24. source TASK.json mtime unchanged' `
        -Expected $writeBefore -Actual (Get-Item -LiteralPath $f.Task).LastWriteTimeUtc

    # PROJECT_STATE.json is read-only input too.
    $psHash = (Get-FileHash -LiteralPath $f.ProjectState -Algorithm SHA256).Hash
    $null = Invoke-RunCase -Fixture $f -RunId 'run-src-c'
    Assert-Equal -Name '24b. PROJECT_STATE.json is never modified' `
        -Expected $psHash -Actual (Get-FileHash -LiteralPath $f.ProjectState -Algorithm SHA256).Hash

    # --- 25. no network / Git / AI operation -------------------------------------
    # Static assertion over the script source: none of the forbidden operations
    # appear. Cheaper and more reliable than trying to observe their absence.
    $src = Get-Content -LiteralPath $scriptPath -Raw
    $codeOnly = ($src -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $forbiddenTokens = @(
        'Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net.WebClient', 'HttpClient',
        'Start-BitsTransfer', 'curl ', 'wget ',
        'git ', 'git.exe', 'gh ', 'gh.exe',
        'Invoke-Worker', 'Invoke-Codex', 'claude ', 'codex ',
        'Get-ChildItem env:', '$env:GITHUB', 'Get-Credential'
    )
    foreach ($tok in $forbiddenTokens) {
        Assert-True -Name "25. script contains no '$($tok.Trim())' operation" `
            -Condition (-not $codeOnly.Contains($tok)) -Detail "found '$tok' in script body"
    }
    Assert-True -Name '25. script issues no recursive delete' `
        -Condition (-not ($codeOnly -match '-Recurse')) -Detail 'found -Recurse in script body'

    # A successful run leaves no Git repository behind and creates no worktree.
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'run-nogit'
    $gitDirs = @(Get-ChildItem -LiteralPath $f.Sandbox -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -eq '.git' })
    Assert-Equal -Name '25b. no .git directory is created anywhere in the sandbox' -Expected 0 -Actual $gitDirs.Count
    Assert-True  -Name '25c. no worktree root is created' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $f.Sandbox 'ai-orchestra-worktrees')))

    # --- configuration errors -----------------------------------------------------
    $f = New-RunFixture
    $res = New-AgentRunDirectory -TaskFile $f.Task -RunId 'run-cfg' -RunDirectory '' `
                                 -ProjectStateFile (Join-Path $f.Sandbox 'no-such-state.json')
    Assert-Equal -Name '26. missing PROJECT_STATE.json is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $res.result
    Assert-Equal -Name '26. exits 3' -Expected 3 -Actual (Get-AgentRunExitCode -Result $res)

    $badState = New-TestJsonFile -Directory $f.Sandbox -FileName 'state-no-root.json' -Data @{ project_name = 'X' }
    $res = New-AgentRunDirectory -TaskFile $f.Task -RunId 'run-cfg2' -RunDirectory '' -ProjectStateFile $badState
    Assert-Equal -Name '26b. PROJECT_STATE without runtime_runs_root is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $res.result
    Assert-Equal -Name '26b. code names the cause' -Expected 'runtime_runs_root_missing' -Actual $res.code

    # --- run id / directory derivation --------------------------------------------
    $f = New-RunFixture
    $r = Invoke-RunCase -Fixture $f -RunId 'derived-id'
    Assert-Equal -Name '27. RunDirectory defaults to <runtime_runs_root>\<RunId>' `
        -Expected (Join-Path $f.RunsRoot 'derived-id') -Actual $r.Result.run_directory

    # Two distinct run ids coexist without interfering.
    $r2 = Invoke-RunCase -Fixture $f -RunId 'derived-id-2'
    Assert-Equal -Name '27b. a second run in the same root succeeds' -Expected 'CREATED' -Actual $r2.Result.result
    Assert-True  -Name '27c. the first run directory is intact' `
        -Condition (Test-Path -LiteralPath (Join-Path (Join-Path $f.RunsRoot 'derived-id') 'STATUS.json'))

    # Re-running the same id is refused (the directory is now non-empty).
    $r3 = Invoke-RunCase -Fixture $f -RunId 'derived-id'
    Assert-Equal -Name '27d. re-initializing an existing run is REJECTED' -Expected 'REJECTED' -Actual $r3.Result.result
}
finally {
    foreach ($d in $fixtures) { Remove-TempDirectory -Path $d }
}

$failures = @(Get-TestResults | Where-Object { -not $_.Passed }).Count
$null = Get-TestSummary

# Emit the failure count so an aggregating runner can consume it, then exit with
# a shell-friendly status for direct `pwsh -File` invocation.
$failures
exit ([int]($failures -gt 0))
