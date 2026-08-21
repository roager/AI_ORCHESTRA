#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\Test-AgentState.ps1.
.NOTES
    Invoked by tests\Run-AllTests.ps1. Returns the failure count.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path (Split-Path -Parent $here) 'scripts/Test-AgentState.ps1'

. (Join-Path $here 'TestHelpers.ps1')
. $scriptPath   # dot-source: defines the functions without running the entry point

Set-TestSuite 'Test-AgentState'

function Invoke-StateCase {
    param([string] $From, [string] $To)
    $v = Test-AgentStateTransition -CurrentState $From -RequestedState $To
    return [pscustomobject]@{
        Verdict  = $v
        ExitCode = (Get-AgentStateExitCode -Verdict $v)
    }
}

# ---------------------------------------------------------------------------
# POSITIVE: the full normal lifecycle
# ---------------------------------------------------------------------------
$normalFlow = @(
    @('CREATED', 'PLANNING'),
    @('PLANNING', 'WORKER_RUNNING'),
    @('WORKER_RUNNING', 'WORKER_DONE'),
    @('WORKER_DONE', 'VALIDATING'),
    @('VALIDATING', 'REVIEWING'),
    @('REVIEWING', 'APPROVED'),
    @('APPROVED', 'PUBLISHING'),
    @('PUBLISHING', 'PUBLISHED')
)
foreach ($t in $normalFlow) {
    $r = Invoke-StateCase -From $t[0] -To $t[1]
    Assert-Equal -Name "valid transition $($t[0]) -> $($t[1]) is PASS" -Expected 'PASS' -Actual $r.Verdict.result
    Assert-Equal -Name "valid transition $($t[0]) -> $($t[1]) exits 0"  -Expected 0      -Actual $r.ExitCode
}

# ---------------------------------------------------------------------------
# POSITIVE: correction flow
# ---------------------------------------------------------------------------
foreach ($t in @(@('REVIEWING', 'CORRECTION_REQUIRED'), @('CORRECTION_REQUIRED', 'WORKER_RUNNING'))) {
    $r = Invoke-StateCase -From $t[0] -To $t[1]
    Assert-Equal -Name "correction flow $($t[0]) -> $($t[1]) is PASS" -Expected 'PASS' -Actual $r.Verdict.result
}

# ---------------------------------------------------------------------------
# POSITIVE: escalation reachable from every non-terminal state
# ---------------------------------------------------------------------------
$nonTerminal = @('CREATED','PLANNING','WORKER_RUNNING','WORKER_DONE','VALIDATING',
                 'REVIEWING','CORRECTION_REQUIRED','APPROVED','PUBLISHING')
foreach ($s in $nonTerminal) {
    $r = Invoke-StateCase -From $s -To 'HUMAN_REQUIRED'
    Assert-Equal -Name "$s -> HUMAN_REQUIRED allowed" -Expected 'PASS' -Actual $r.Verdict.result
    $r2 = Invoke-StateCase -From $s -To 'FAILED'
    Assert-Equal -Name "$s -> FAILED allowed" -Expected 'PASS' -Actual $r2.Verdict.result
}

# ---------------------------------------------------------------------------
# POSITIVE: human resumption
# ---------------------------------------------------------------------------
foreach ($to in @('PLANNING', 'APPROVED', 'FAILED', 'CANCELLED')) {
    $r = Invoke-StateCase -From 'HUMAN_REQUIRED' -To $to
    Assert-Equal -Name "HUMAN_REQUIRED -> $to allowed (human action)" -Expected 'PASS' -Actual $r.Verdict.result
}

# ---------------------------------------------------------------------------
# NEGATIVE: the transitions the architecture exists to prevent
# ---------------------------------------------------------------------------
$forbidden = @(
    @('CREATED', 'PUBLISHED'),
    @('CREATED', 'PUBLISHING'),
    @('WORKER_RUNNING', 'APPROVED'),
    @('WORKER_DONE', 'APPROVED'),
    @('WORKER_DONE', 'PUBLISHING'),
    @('VALIDATING', 'APPROVED'),
    @('VALIDATING', 'PUBLISHING'),
    @('REVIEWING', 'PUBLISHING'),
    @('REVIEWING', 'PUBLISHED'),
    @('CORRECTION_REQUIRED', 'APPROVED'),
    @('CORRECTION_REQUIRED', 'PUBLISHING'),
    @('HUMAN_REQUIRED', 'PUBLISHING'),
    @('HUMAN_REQUIRED', 'PUBLISHED'),
    @('PLANNING', 'REVIEWING'),
    @('CREATED', 'WORKER_RUNNING')
)
foreach ($t in $forbidden) {
    $r = Invoke-StateCase -From $t[0] -To $t[1]
    Assert-Equal -Name "invalid transition $($t[0]) -> $($t[1]) is FAIL" -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name "invalid transition $($t[0]) -> $($t[1]) exits 2"  -Expected 2      -Actual $r.ExitCode
}

# ---------------------------------------------------------------------------
# NEGATIVE: terminal states have no exit
# ---------------------------------------------------------------------------
foreach ($from in @('PUBLISHED', 'FAILED', 'CANCELLED')) {
    $r = Invoke-StateCase -From $from -To 'PUBLISHING'
    Assert-Equal -Name "$from is terminal (-> PUBLISHING rejected)" -Expected 'FAIL' -Actual $r.Verdict.result
    Assert-Equal -Name "$from rejection code is terminal_state" -Expected 'terminal_state' -Actual $r.Verdict.code
    $r2 = Invoke-StateCase -From $from -To 'PLANNING'
    Assert-Equal -Name "$from is terminal (-> PLANNING rejected)" -Expected 'FAIL' -Actual $r2.Verdict.result
}

# ---------------------------------------------------------------------------
# NEGATIVE: PUBLISHING cannot be cancelled
# ---------------------------------------------------------------------------
$r = Invoke-StateCase -From 'PUBLISHING' -To 'CANCELLED'
Assert-Equal -Name 'PUBLISHING -> CANCELLED forbidden (Git may be partially applied)' -Expected 'FAIL' -Actual $r.Verdict.result

# ---------------------------------------------------------------------------
# NEGATIVE: self-transitions and re-entry to CREATED
# ---------------------------------------------------------------------------
$r = Invoke-StateCase -From 'REVIEWING' -To 'REVIEWING'
Assert-Equal -Name 'self-transition rejected' -Expected 'FAIL' -Actual $r.Verdict.result
Assert-Equal -Name 'self-transition code'     -Expected 'self_transition' -Actual $r.Verdict.code

$r = Invoke-StateCase -From 'PLANNING' -To 'CREATED'
Assert-Equal -Name 're-entry to CREATED rejected' -Expected 'FAIL' -Actual $r.Verdict.result
Assert-Equal -Name 're-entry code' -Expected 'reentry_to_created' -Actual $r.Verdict.code

# ---------------------------------------------------------------------------
# NEGATIVE: unknown / malformed state names
# ---------------------------------------------------------------------------
foreach ($bad in @('APPROVE', 'reviewing', 'DONE', '', '   ', 'PUBLISH')) {
    $r = Invoke-StateCase -From $bad -To 'PLANNING'
    Assert-Equal -Name "unknown current state '$bad' is INPUT_ERROR" -Expected 'INPUT_ERROR' -Actual $r.Verdict.result
    Assert-Equal -Name "unknown current state '$bad' exits 3"        -Expected 3             -Actual $r.ExitCode
}
$r = Invoke-StateCase -From 'PLANNING' -To 'NOT_A_STATE'
Assert-Equal -Name 'unknown requested state is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $r.Verdict.result

# ---------------------------------------------------------------------------
# STRUCTURAL: whitelist completeness against STATUS.schema.json
# ---------------------------------------------------------------------------
$schemaPath = Join-Path (Split-Path -Parent $here) 'schemas/STATUS.schema.json'
if (Test-Path -LiteralPath $schemaPath) {
    $schemaStates = (Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json).properties.state.enum
    Assert-CollectionEqual -Name 'validator state list matches STATUS.schema.json enum' `
        -Expected @($schemaStates) -Actual @($script:ValidStates)
}
else {
    Assert-True -Name 'STATUS.schema.json present for cross-check' -Condition $false -Detail "not found at $schemaPath"
}

# Every state must appear as a key in the transition table.
Assert-CollectionEqual -Name 'transition table covers all 13 states' `
    -Expected @($script:ValidStates) -Actual @($script:AllowedTransitions.Keys)

# Exhaustive sweep: 13 x 13 = 169 pairs, each must yield a definite verdict.
$definite = 0
foreach ($a in $script:ValidStates) {
    foreach ($b in $script:ValidStates) {
        $v = Test-AgentStateTransition -CurrentState $a -RequestedState $b
        if ($v.result -in @('PASS', 'FAIL')) { $definite++ }
    }
}
Assert-Equal -Name 'all 169 state pairs produce a definite verdict' -Expected 169 -Actual $definite

# Exactly 40 transitions are allowed (ORCHESTRATOR_POLICY.md section 2.1).
$allowedCount = 0
foreach ($a in $script:ValidStates) {
    foreach ($b in $script:ValidStates) {
        if ((Test-AgentStateTransition -CurrentState $a -RequestedState $b).result -eq 'PASS') { $allowedCount++ }
    }
}
Assert-Equal -Name 'exactly 40 allowed transitions' -Expected 40 -Actual $allowedCount

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
