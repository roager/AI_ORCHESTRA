#Requires -Version 7.0
<#
.SYNOPSIS
    Deterministic budget validator for the AI_ORCHESTRA Supervisor.

.DESCRIPTION
    Compares observed consumption (USAGE.json) against the limits in
    policies\BUDGET_POLICY.json and returns CONTINUE, WARNING or STOP.

    STOP means a hard limit has been reached. At orchestration level STOP
    implies HUMAN_REQUIRED with reason 'budget_exhausted'
    (ESCALATION_POLICY.md section 2.1). This script never changes state; it
    only reports.

    Threshold semantics follow ORCHESTRATOR_POLICY.md section 5: a gate is
    passable while value < limit, and is reached at value >= limit.

    Read-only. No AI calls, no network, no Git, no filesystem writes.

.PARAMETER UsagePath
    Path to a USAGE.json conforming to schemas\USAGE.schema.json.
    Recognised fields (all optional here, default 0):
      total_tokens        | tokens_total
      worker_calls
      reviewer_calls
      correction_rounds   | correction_round      (STATUS.json spelling)
      runtime_seconds     | runtime_minutes | elapsed_minutes

    runtime_seconds is the field defined by USAGE.schema.json and is converted
    to minutes before comparison with max_runtime_minutes.

    Unrecognised fields are ignored. A missing counter is treated as 0 and
    reported as 'assumed_zero' so the gap is visible rather than silent. This
    script does not perform JSON Schema validation; that is the schema
    validator's job.

.PARAMETER PolicyPath
    Path to BUDGET_POLICY.json. Required keys:
      max_total_tokens, warning_tokens, max_worker_calls,
      max_reviewer_calls, max_correction_rounds, max_runtime_minutes

.PARAMETER AsJson
    Emit the result as JSON instead of a PSCustomObject.

.OUTPUTS
    PSCustomObject (or JSON with -AsJson):
      validator, result, code, reason, escalation_reason, checks[]
    Each check: limit, source_field, observed, threshold, status, assumed_zero

.NOTES
    Exit codes (shared by all AI_ORCHESTRA validators):
      0  CONTINUE     no limit reached
      1  WARNING      warning_tokens crossed; run may continue
      2  STOP         a hard limit reached -> HUMAN_REQUIRED
      3  INPUT_ERROR  unreadable/invalid input

.EXAMPLE
    .\Test-AgentBudget.ps1 -UsagePath .\USAGE.json -PolicyPath ..\policies\BUDGET_POLICY.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string] $UsagePath,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string] $PolicyPath,

    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RequiredPolicyKeys = @(
    'max_total_tokens'
    'warning_tokens'
    'max_worker_calls'
    'max_reviewer_calls'
    'max_correction_rounds'
    'max_runtime_minutes'
)

# Maps a policy limit to the USAGE.json field names that may carry it.
# First matching field wins; order is significant. 'Scale' converts the field's
# unit into the limit's unit (schemas\USAGE.schema.json records runtime in
# seconds, while BUDGET_POLICY.json expresses the limit in minutes).
$script:UsageFieldMap = [ordered]@{
    'max_total_tokens'      = @(
        @{ Name = 'total_tokens';      Scale = 1.0 }
        @{ Name = 'tokens_total';      Scale = 1.0 }
    )
    'max_worker_calls'      = @(
        @{ Name = 'worker_calls';      Scale = 1.0 }
    )
    'max_reviewer_calls'    = @(
        @{ Name = 'reviewer_calls';    Scale = 1.0 }
    )
    'max_correction_rounds' = @(
        @{ Name = 'correction_rounds'; Scale = 1.0 }   # USAGE.schema.json
        @{ Name = 'correction_round';  Scale = 1.0 }   # STATUS.schema.json spelling
    )
    'max_runtime_minutes'   = @(
        @{ Name = 'runtime_seconds';   Scale = (1.0 / 60.0) }   # USAGE.schema.json
        @{ Name = 'runtime_minutes';   Scale = 1.0 }
        @{ Name = 'elapsed_minutes';   Scale = 1.0 }
    )
}

function Read-JsonFile {
    [CmdletBinding()]
    param([string] $Path, [string] $Label)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label path was not supplied." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: '$Path'." }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "$Label is empty: '$Path'." }

    try { return $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Label is not valid JSON: '$Path'. $($_.Exception.Message)" }
}

function Get-UsageField {
    <#
    .SYNOPSIS
        Resolves the first present usage field for a limit.
    .OUTPUTS
        Hashtable @{ Name; Value; Scale } for the first field present on the
        object, else $null when none of the candidates are present.
    #>
    [CmdletBinding()]
    param([psobject] $Object, [object[]] $Candidates)

    foreach ($c in $Candidates) {
        if ($Object.PSObject.Properties.Name -contains $c.Name) {
            $v = $Object.PSObject.Properties[$c.Name].Value
            if ($null -ne $v) { return @{ Name = $c.Name; Value = $v; Scale = $c.Scale } }
        }
    }
    return $null
}

function ConvertTo-NonNegativeNumber {
    <# Strict numeric coercion. Returns $null when the value is not a usable number. #>
    [CmdletBinding()]
    param([object] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }

    $parsed = 0.0
    if (-not [double]::TryParse(
            [string]$Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $null
    }
    if ($parsed -lt 0) { return $null }
    return $parsed
}

function Test-AgentBudgetUsage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $UsagePath,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $PolicyPath
    )

    $result = [ordered]@{
        validator         = 'Test-AgentBudget'
        result            = $null
        code              = $null
        reason            = $null
        escalation_reason = $null
        checks            = @()
    }

    # --- load -------------------------------------------------------------
    try {
        $usage  = Read-JsonFile -Path $UsagePath  -Label 'USAGE.json'
        $policy = Read-JsonFile -Path $PolicyPath -Label 'BUDGET_POLICY.json'
    }
    catch {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'unreadable_input'
        $result.reason = $_.Exception.Message
        return [pscustomobject]$result
    }

    # --- policy completeness ---------------------------------------------
    $missing = @($script:RequiredPolicyKeys | Where-Object { $policy.PSObject.Properties.Name -notcontains $_ })
    if ($missing.Count -gt 0) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'incomplete_policy'
        $result.reason = "BUDGET_POLICY.json is missing required key(s): $($missing -join ', ')."
        return [pscustomobject]$result
    }

    $limits = @{}
    foreach ($k in $script:RequiredPolicyKeys) {
        $n = ConvertTo-NonNegativeNumber -Value $policy.PSObject.Properties[$k].Value
        if ($null -eq $n) {
            $result.result = 'INPUT_ERROR'
            $result.code   = 'invalid_policy_value'
            $result.reason = "BUDGET_POLICY.json key '$k' is not a non-negative number."
            return [pscustomobject]$result
        }
        $limits[$k] = $n
    }

    if ($limits['warning_tokens'] -gt $limits['max_total_tokens']) {
        $result.result = 'INPUT_ERROR'
        $result.code   = 'incoherent_policy'
        $result.reason = "warning_tokens ($($limits['warning_tokens'])) exceeds max_total_tokens ($($limits['max_total_tokens']))."
        return [pscustomobject]$result
    }

    # --- evaluate hard limits --------------------------------------------
    $checks  = [System.Collections.Generic.List[object]]::new()
    $stopped = [System.Collections.Generic.List[string]]::new()

    foreach ($limitKey in $script:UsageFieldMap.Keys) {
        $candidates = $script:UsageFieldMap[$limitKey]
        $hit        = Get-UsageField -Object $usage -Candidates $candidates
        $assumed    = ($null -eq $hit)
        $sourceName = if ($assumed) { $candidates[0].Name } else { $hit.Name }

        if ($assumed) {
            $observed = 0.0
        }
        else {
            $raw = ConvertTo-NonNegativeNumber -Value $hit.Value
            $observed = if ($null -eq $raw) { $null } else { $raw * $hit.Scale }
        }

        if ($null -eq $observed) {
            $result.result = 'INPUT_ERROR'
            $result.code   = 'invalid_usage_value'
            $result.reason = "USAGE.json field '$sourceName' is not a non-negative number."
            return [pscustomobject]$result
        }

        $threshold = $limits[$limitKey]
        $status    = if ($observed -ge $threshold) { 'STOP' } else { 'OK' }
        if ($status -eq 'STOP') { $stopped.Add($limitKey) | Out-Null }

        $checks.Add([pscustomobject][ordered]@{
            limit        = $limitKey
            source_field = $sourceName
            observed     = $observed
            threshold    = $threshold
            status       = $status
            assumed_zero = $assumed
        }) | Out-Null
    }

    # --- evaluate the soft token warning ---------------------------------
    $tokenCheck  = $checks | Where-Object { $_.limit -eq 'max_total_tokens' } | Select-Object -First 1
    $warnCrossed = ($tokenCheck.observed -ge $limits['warning_tokens'])

    $checks.Add([pscustomobject][ordered]@{
        limit        = 'warning_tokens'
        source_field = $tokenCheck.source_field
        observed     = $tokenCheck.observed
        threshold    = $limits['warning_tokens']
        status       = $(if ($warnCrossed) { 'WARNING' } else { 'OK' })
        assumed_zero = $tokenCheck.assumed_zero
    }) | Out-Null

    $result.checks = $checks.ToArray()

    # --- verdict ----------------------------------------------------------
    if ($stopped.Count -gt 0) {
        $result.result            = 'STOP'
        $result.code              = 'hard_limit_reached'
        $result.reason            = "Hard limit reached: $($stopped -join ', ')."
        $result.escalation_reason = 'budget_exhausted'
        return [pscustomobject]$result
    }
    if ($warnCrossed) {
        $result.result = 'WARNING'
        $result.code   = 'warning_threshold_crossed'
        $result.reason = "Observed tokens ($($tokenCheck.observed)) reached warning_tokens ($($limits['warning_tokens'])). Recorded; run may continue."
        return [pscustomobject]$result
    }

    $result.result = 'CONTINUE'
    $result.code   = 'within_budget'
    $result.reason = 'All limits are below threshold.'
    return [pscustomobject]$result
}

function Get-AgentBudgetExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)] [pscustomobject] $Verdict)

    switch ($Verdict.result) {
        'CONTINUE'    { return 0 }
        'WARNING'     { return 1 }
        'STOP'        { return 2 }
        'INPUT_ERROR' { return 3 }
        default       { return 3 }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $verdict = Test-AgentBudgetUsage -UsagePath $UsagePath -PolicyPath $PolicyPath
    if ($AsJson) { $verdict | ConvertTo-Json -Compress -Depth 6 } else { $verdict }
    exit (Get-AgentBudgetExitCode -Verdict $verdict)
}
