#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic state-transition validator for the AI_ORCHESTRA Supervisor.

.DESCRIPTION
    Validates a requested state transition against the whitelist defined in
    policies\ORCHESTRATOR_POLICY.md section 2. A transition not present in the
    table is forbidden.

    This validator makes no decision about what should happen next. It answers
    exactly one question: is this transition permitted?

    Read-only. No AI calls, no network, no Git, no filesystem writes.

.PARAMETER CurrentState
    The run's current state. Must be one of the 13 values in the `state` enum of
    schemas\STATUS.schema.json.

.PARAMETER RequestedState
    The state the caller wants to move to.

.PARAMETER AsJson
    Emit the result as a single-line JSON object instead of a PSCustomObject.

.OUTPUTS
    PSCustomObject (or JSON with -AsJson):
      validator, result, current_state, requested_state, code, reason

.NOTES
    Exit codes (shared by all AI_ORCHESTRA validators):
      0  PASS         transition allowed
      1  WARNING      not used by this validator
      2  FAIL         transition forbidden
      3  INPUT_ERROR  unknown state name or missing argument

.EXAMPLE
    .\Test-AgentState.ps1 -CurrentState REVIEWING -RequestedState APPROVED
    # exit 0

.EXAMPLE
    .\Test-AgentState.ps1 -CurrentState CREATED -RequestedState PUBLISHED
    # exit 2
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string] $CurrentState,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string] $RequestedState,

    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

# The 13 states of schemas\STATUS.schema.json -> properties.state.enum
$script:ValidStates = @(
    'CREATED'
    'PLANNING'
    'WORKER_RUNNING'
    'WORKER_DONE'
    'VALIDATING'
    'REVIEWING'
    'CORRECTION_REQUIRED'
    'APPROVED'
    'PUBLISHING'
    'PUBLISHED'
    'HUMAN_REQUIRED'
    'FAILED'
    'CANCELLED'
)

# Whitelist from policies\ORCHESTRATOR_POLICY.md section 2.1.
# Anything absent from this table is forbidden.
$script:AllowedTransitions = [ordered]@{
    'CREATED'             = @('PLANNING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'PLANNING'            = @('WORKER_RUNNING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'WORKER_RUNNING'      = @('WORKER_DONE', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'WORKER_DONE'         = @('VALIDATING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'VALIDATING'          = @('REVIEWING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'REVIEWING'           = @('APPROVED', 'CORRECTION_REQUIRED', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'CORRECTION_REQUIRED' = @('WORKER_RUNNING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    'APPROVED'            = @('PUBLISHING', 'HUMAN_REQUIRED', 'FAILED', 'CANCELLED')
    # PUBLISHING cannot be cancelled: a Git operation may be partially applied.
    'PUBLISHING'          = @('PUBLISHED', 'HUMAN_REQUIRED', 'FAILED')
    # Terminal states have no outgoing transitions.
    'PUBLISHED'           = @()
    'FAILED'              = @()
    'CANCELLED'           = @()
    # Halt state. Exits only via a recorded human action (ESCALATION_POLICY.md section 3).
    'HUMAN_REQUIRED'      = @('PLANNING', 'APPROVED', 'FAILED', 'CANCELLED')
}

$script:TerminalStates = @('PUBLISHED', 'FAILED', 'CANCELLED')

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

function Test-AgentStateTransition {
    <#
    .SYNOPSIS
        Returns a structured verdict for one state transition.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $CurrentState,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $RequestedState
    )

    $from = $CurrentState.Trim()
    $to   = $RequestedState.Trim()

    $result = [ordered]@{
        validator       = 'Test-AgentState'
        result          = $null
        current_state   = $from
        requested_state = $to
        code            = $null
        reason          = $null
    }

    # --- input validation -------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($from) -or $script:ValidStates -cnotcontains $from) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'unknown_current_state'
        $result.reason = "Current state '$from' is not one of the 13 states defined in STATUS.schema.json."
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($to) -or $script:ValidStates -cnotcontains $to) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'unknown_requested_state'
        $result.reason = "Requested state '$to' is not one of the 13 states defined in STATUS.schema.json."
        return [pscustomobject]$result
    }

    # --- specific rejection reasons (ordered most-specific first) ---------
    if ($from -ceq $to) {
        $result.result = 'FAIL'
        $result.code   = 'self_transition'
        $result.reason = "A self-transition is not a state change. Counters and updated_at are written in place."
        return [pscustomobject]$result
    }
    if ($script:TerminalStates -ccontains $from) {
        $result.result = 'FAIL'
        $result.code   = 'terminal_state'
        $result.reason = "'$from' is terminal and has no outgoing transitions. Further work requires a new task_id."
        return [pscustomobject]$result
    }
    if ($to -ceq 'CREATED') {
        $result.result = 'FAIL'
        $result.code   = 'reentry_to_created'
        $result.reason = "CREATED is an entry state only. A run is never re-created."
        return [pscustomobject]$result
    }

    # --- whitelist --------------------------------------------------------
    if ($script:AllowedTransitions[$from] -ccontains $to) {
        $result.result = 'PASS'
        $result.code   = 'transition_allowed'
        $result.reason = "$from -> $to is permitted by ORCHESTRATOR_POLICY.md section 2.1."
        return [pscustomobject]$result
    }

    $result.result = 'FAIL'
    $result.code   = 'forbidden_transition'
    $result.reason = "$from -> $to is not in the allowed-transition whitelist (ORCHESTRATOR_POLICY.md section 2.1)."
    return [pscustomobject]$result
}

function Get-AgentStateExitCode {
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

# ---------------------------------------------------------------------------
# Entry point (skipped when dot-sourced by the test harness)
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    $verdict = Test-AgentStateTransition -CurrentState $CurrentState -RequestedState $RequestedState
    if ($AsJson) { $verdict | ConvertTo-Json -Compress -Depth 5 } else { $verdict }
    exit (Get-AgentStateExitCode -Verdict $verdict)
}
