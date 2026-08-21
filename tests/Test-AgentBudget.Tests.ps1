#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for scripts\Test-AgentBudget.ps1.
.NOTES
    Invoked by tests\Run-AllTests.ps1. Returns the failure count.
    Uses the real policies\BUDGET_POLICY.json where present, plus synthetic
    fixtures in a temp directory. Never writes inside the repository.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $here
$scriptPath = Join-Path $repoRoot 'scripts/Test-AgentBudget.ps1'

. (Join-Path $here 'TestHelpers.ps1')
. $scriptPath

Set-TestSuite 'Test-AgentBudget'

$tmp = New-TempDirectory
try {
    # MVP provisional limits, mirroring policies\BUDGET_POLICY.json.
    $policy = New-TestJsonFile -Directory $tmp -FileName 'BUDGET_POLICY.json' -Data @{
        policy_version        = '0.2'
        max_total_tokens      = 40000
        warning_tokens        = 30000
        max_worker_calls      = 2
        max_reviewer_calls    = 3
        max_correction_rounds = 1
        max_runtime_seconds   = 2700
    }

    function Invoke-BudgetCase {
        param([hashtable] $Usage, [string] $Name = 'USAGE.json', [string] $PolicyOverride)
        $u = New-TestJsonFile -Directory $tmp -FileName $Name -Data $Usage
        $p = if ($PSBoundParameters.ContainsKey('PolicyOverride')) { $PolicyOverride } else { $policy }
        $v = Test-AgentBudgetUsage -UsagePath $u -PolicyPath $p
        return [pscustomobject]@{ Verdict = $v; ExitCode = (Get-AgentBudgetExitCode -Verdict $v) }
    }

    # -----------------------------------------------------------------------
    # POSITIVE: below warning
    # -----------------------------------------------------------------------
    $r = Invoke-BudgetCase -Usage @{
        total_tokens = 12000; worker_calls = 1; reviewer_calls = 1
        correction_rounds = 0; runtime_seconds = 480
    } -Name 'usage-low.json'
    Assert-Equal -Name 'budget below warning is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result
    Assert-Equal -Name 'budget below warning exits 0'      -Expected 0          -Actual $r.ExitCode

    # Zero usage at the start of a run.
    $r = Invoke-BudgetCase -Usage @{
        total_tokens = 0; worker_calls = 0; reviewer_calls = 0
        correction_rounds = 0; runtime_seconds = 0
    } -Name 'usage-zero.json'
    Assert-Equal -Name 'zero usage is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result

    # One token below the warning threshold.
    $r = Invoke-BudgetCase -Usage @{ total_tokens = 29999 } -Name 'usage-29999.json'
    Assert-Equal -Name 'tokens one below warning is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # WARNING boundary
    # -----------------------------------------------------------------------
    $r = Invoke-BudgetCase -Usage @{
        total_tokens = 30000; worker_calls = 1; reviewer_calls = 1
        correction_rounds = 0; runtime_seconds = 600
    } -Name 'usage-warn-exact.json'
    Assert-Equal -Name 'tokens exactly at warning_tokens is WARNING' -Expected 'WARNING' -Actual $r.Verdict.result
    Assert-Equal -Name 'warning exits 1' -Expected 1 -Actual $r.ExitCode
    Assert-Equal -Name 'warning is not an escalation' -Expected '' -Actual ([string]$r.Verdict.escalation_reason)

    $r = Invoke-BudgetCase -Usage @{ total_tokens = 35500; worker_calls = 1 } -Name 'usage-warn.json'
    Assert-Equal -Name 'tokens between warning and max is WARNING' -Expected 'WARNING' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # STOP: each hard limit independently
    # -----------------------------------------------------------------------
    $stopCases = @(
        @{ Name = 'max_total_tokens';      Usage = @{ total_tokens = 40000 } },
        @{ Name = 'max_total_tokens over'; Usage = @{ total_tokens = 41000 } },
        @{ Name = 'max_worker_calls';      Usage = @{ worker_calls = 2 } },
        @{ Name = 'max_reviewer_calls';    Usage = @{ reviewer_calls = 3 } },
        @{ Name = 'max_correction_rounds'; Usage = @{ correction_rounds = 1 } },
        @{ Name = 'max_runtime_seconds';   Usage = @{ runtime_seconds = 2700 } }
    )
    $i = 0
    foreach ($c in $stopCases) {
        $i++
        $r = Invoke-BudgetCase -Usage $c.Usage -Name "usage-stop-$i.json"
        Assert-Equal -Name "budget exceeded ($($c.Name)) is STOP" -Expected 'STOP' -Actual $r.Verdict.result
        Assert-Equal -Name "budget exceeded ($($c.Name)) exits 2"  -Expected 2      -Actual $r.ExitCode
        Assert-Equal -Name "budget exceeded ($($c.Name)) escalates budget_exhausted" `
            -Expected 'budget_exhausted' -Actual $r.Verdict.escalation_reason
    }

    # One below each hard limit must NOT stop.
    $r = Invoke-BudgetCase -Usage @{
        total_tokens = 100; worker_calls = 1; reviewer_calls = 2
        correction_rounds = 0; runtime_seconds = 2699
    } -Name 'usage-just-under.json'
    Assert-Equal -Name 'one unit below every hard limit is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result

    # STOP dominates WARNING.
    $r = Invoke-BudgetCase -Usage @{ total_tokens = 32000; worker_calls = 2 } -Name 'usage-stop-wins.json'
    Assert-Equal -Name 'STOP takes precedence over WARNING' -Expected 'STOP' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # Field aliases and missing counters
    # -----------------------------------------------------------------------
    $r = Invoke-BudgetCase -Usage @{ tokens_total = 40000 } -Name 'usage-alias2.json'
    Assert-Equal -Name 'tokens_total alias is honoured' -Expected 'STOP' -Actual $r.Verdict.result

    # -----------------------------------------------------------------------
    # runtime_seconds: the unit defined by schemas\USAGE.schema.json
    # -----------------------------------------------------------------------
    $r = Invoke-BudgetCase -Usage @{ runtime_seconds = 2699 } -Name 'usage-secs-under.json'
    Assert-Equal -Name 'runtime_seconds 2699 is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result

    $r = Invoke-BudgetCase -Usage @{ runtime_seconds = 2700 } -Name 'usage-secs-exact.json'
    Assert-Equal -Name 'runtime_seconds 2700 is STOP' -Expected 'STOP' -Actual $r.Verdict.result

    $r = Invoke-BudgetCase -Usage @{ runtime_seconds = 600 } -Name 'usage-secs-low.json'
    $runtimeCheck = @($r.Verdict.checks | Where-Object { $_.limit -eq 'max_runtime_seconds' })[0]
    Assert-Equal -Name 'runtime_seconds is read directly' -Expected 600 -Actual $runtimeCheck.observed
    Assert-Equal -Name 'source_field names the field actually read' -Expected 'runtime_seconds' -Actual $runtimeCheck.source_field

    # A document with the exact required shape of USAGE.schema.json.
    $r = Invoke-BudgetCase -Usage @{
        task_id = 'ao-test-001'; worker_calls = 1; reviewer_calls = 1
        correction_rounds = 0; runtime_seconds = 300; total_tokens = 5000
    } -Name 'usage-schema-shaped.json'
    Assert-Equal -Name 'USAGE.schema.json-shaped document is CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result
    $assumedAny = @($r.Verdict.checks | Where-Object { $_.assumed_zero })
    Assert-Equal -Name 'schema-shaped document leaves no counter assumed' -Expected 0 -Actual $assumedAny.Count

    # The real schema forbids runtime_minutes, so a run recording only seconds
    # must still be gated. Regression guard for the unit mismatch.
    $r = Invoke-BudgetCase -Usage @{
        task_id = 'x'; worker_calls = 0; reviewer_calls = 0
        correction_rounds = 0; runtime_seconds = 5400; total_tokens = 10
    } -Name 'usage-secs-over.json'
    Assert-Equal -Name 'runtime limit is enforced from runtime_seconds alone' -Expected 'STOP' -Actual $r.Verdict.result

    $r = Invoke-BudgetCase -Usage @{ total_tokens = 100 } -Name 'usage-partial.json'
    Assert-Equal -Name 'missing counters default to zero -> CONTINUE' -Expected 'CONTINUE' -Actual $r.Verdict.result
    $assumed = @($r.Verdict.checks | Where-Object { $_.assumed_zero -and $_.limit -eq 'max_worker_calls' })
    Assert-True -Name 'missing counter is flagged assumed_zero, not silently absent' -Condition ($assumed.Count -eq 1)

    # -----------------------------------------------------------------------
    # Reporting shape
    # -----------------------------------------------------------------------
    $r = Invoke-BudgetCase -Usage @{ total_tokens = 100 } -Name 'usage-shape.json'
    Assert-Equal -Name 'every limit plus warning_tokens is reported' -Expected 6 -Actual @($r.Verdict.checks).Count
    Assert-Equal -Name 'validator name is stamped' -Expected 'Test-AgentBudget' -Actual $r.Verdict.validator

    # -----------------------------------------------------------------------
    # NEGATIVE: input errors
    # -----------------------------------------------------------------------
    $v = Test-AgentBudgetUsage -UsagePath (Join-Path $tmp 'does-not-exist.json') -PolicyPath $policy
    Assert-Equal -Name 'missing USAGE.json is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result
    Assert-Equal -Name 'missing USAGE.json exits 3' -Expected 3 -Actual (Get-AgentBudgetExitCode -Verdict $v)

    $bad = Join-Path $tmp 'malformed.json'
    Set-Content -LiteralPath $bad -Value '{ "total_tokens": ' -Encoding UTF8
    $v = Test-AgentBudgetUsage -UsagePath $bad -PolicyPath $policy
    Assert-Equal -Name 'malformed USAGE.json is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    $incomplete = New-TestJsonFile -Directory $tmp -FileName 'policy-incomplete.json' -Data @{ max_total_tokens = 100 }
    $u = New-TestJsonFile -Directory $tmp -FileName 'usage-any.json' -Data @{ total_tokens = 1 }
    $v = Test-AgentBudgetUsage -UsagePath $u -PolicyPath $incomplete
    Assert-Equal -Name 'incomplete policy is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result
    Assert-Equal -Name 'incomplete policy names the missing keys' -Expected 'incomplete_policy' -Actual $v.code

    $incoherent = New-TestJsonFile -Directory $tmp -FileName 'policy-incoherent.json' -Data @{
        max_total_tokens = 1000; warning_tokens = 5000; max_worker_calls = 2
        max_reviewer_calls = 3; max_correction_rounds = 1; max_runtime_seconds = 2700
    }
    $v = Test-AgentBudgetUsage -UsagePath $u -PolicyPath $incoherent
    Assert-Equal -Name 'warning_tokens above max_total_tokens is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    $negative = New-TestJsonFile -Directory $tmp -FileName 'usage-negative.json' -Data @{ total_tokens = -5 }
    $v = Test-AgentBudgetUsage -UsagePath $negative -PolicyPath $policy
    Assert-Equal -Name 'negative counter is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    $nonNumeric = New-TestJsonFile -Directory $tmp -FileName 'usage-nonnumeric.json' -Data @{ total_tokens = 'many' }
    $v = Test-AgentBudgetUsage -UsagePath $nonNumeric -PolicyPath $policy
    Assert-Equal -Name 'non-numeric counter is INPUT_ERROR' -Expected 'INPUT_ERROR' -Actual $v.result

    # -----------------------------------------------------------------------
    # Cross-check against the real repository policy file
    # -----------------------------------------------------------------------
    $realPolicy = Join-Path $repoRoot 'policies/BUDGET_POLICY.json'
    if (Test-Path -LiteralPath $realPolicy) {
        $u2 = New-TestJsonFile -Directory $tmp -FileName 'usage-real.json' -Data @{
            total_tokens = 100; worker_calls = 0; reviewer_calls = 0
            correction_rounds = 0; runtime_seconds = 60
        }
        $v = Test-AgentBudgetUsage -UsagePath $u2 -PolicyPath $realPolicy
        Assert-Equal -Name 'real BUDGET_POLICY.json is accepted by the validator' -Expected 'CONTINUE' -Actual $v.result

        $u3 = New-TestJsonFile -Directory $tmp -FileName 'usage-real-stop.json' -Data @{ total_tokens = 40000 }
        $v = Test-AgentBudgetUsage -UsagePath $u3 -PolicyPath $realPolicy
        Assert-Equal -Name 'real policy: 40000 tokens is STOP' -Expected 'STOP' -Actual $v.result
    }
    else {
        Assert-True -Name 'policies/BUDGET_POLICY.json present' -Condition $false -Detail "not found at $realPolicy"
    }
}
finally {
    Remove-TempDirectory -Path $tmp
}

return @(Get-TestResults | Where-Object { -not $_.Passed }).Count
