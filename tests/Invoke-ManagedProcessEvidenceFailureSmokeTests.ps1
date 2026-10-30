[CmdletBinding()]
param([switch]$RunSmoke)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This opt-in check starts exactly two fixed, harmless children: one exits 7
# after echoing its correlation marker and one sleeps until the adapter kills
# it. It never accepts a caller-provided command, enables a hook, or writes a
# store. The adapter owns cleanup of each Process instance.
if ($MyInvocation.InvocationName -ceq '.') {
    throw 'Dot-sourcing this smoke test is not supported.'
}
if (-not $RunSmoke) {
    [pscustomobject]@{
        check = 'managed-process-evidence-failure-smoke'
        success = $false
        reason = 'EXPLICIT_OPT_IN_REQUIRED'
        process_started = $false
    } | ConvertTo-Json -Compress
    exit 2
}
if ($env:OS -cne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'This smoke test requires Windows PowerShell 5.1.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'demo\Invoke-SumiGuardManagedProcessEvidenceDemo.ps1')

function Invoke-SumiGuardFailureScenario {
    param([Parameter(Mandatory = $true)][ValidateSet('NONZERO_EXIT', 'TIMEOUT')][string]$Scenario)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $report = $null
    $exceptionType = $null
    try {
        $report = Invoke-SumiGuardManagedProcessEvidenceConnection `
            -CorrelationId ([Guid]::NewGuid().ToString('N')) `
            -Scenario $Scenario `
            -RunProcess `
            -UseRealProcessAdapter
    }
    catch {
        # The report intentionally carries only an exception type.
        $exceptionType = $_.Exception.GetType().FullName
    }
    finally {
        $stopwatch.Stop()
    }

    $checks = [ordered]@{ report_present = ($null -ne $report) }
    if ($null -ne $report) {
        $checks['plan_verified'] = ($report.plan_body_verified -eq $true -and $report.plan_arguments_verified -eq $true)
        $checks['launch_plan_verified'] = ($report.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN')
        $checks['observer_once'] = ($report.observer_invocation_count -eq 1 -and $report.execution_start_count -eq 1)
        $checks['single_process_start'] = ($report.process_start_attempt_count -eq 1 -and $report.process_start_success_count -eq 1)
        $checks['identity_observed'] = ($report.pid_obtained -eq $true -and $report.start_time_obtained -eq $true -and $report.executable_path_obtained -eq $true)
        $checks['adapter_completed'] = ($report.adapter_stage -ceq 'COMPLETED' -and $null -eq $report.adapter_exception_type)
        $checks['no_storage'] = ($report.storage_status -ceq 'NOT_ATTEMPTED')
        if ($Scenario -ceq 'NONZERO_EXIT') {
            $checks['process_confirmed'] = ($report.process_confirmation_status -ceq 'PROCESS_CONFIRMED')
            $checks['normal_exit_confirmed'] = ($report.process_exit_confirmed -eq $true -and $report.termination_status -ceq 'EXITED_NORMALLY')
            $checks['fixed_nonzero_exit'] = ($report.child_exit_code -eq 7 -and $report.child_execution_status -ceq 'NONZERO_EXIT' -and $report.child_execution_succeeded -eq $false)
            $checks['marker_captured'] = ($report.correlation_id_matches -eq $true -and $report.stdout_matches_expected -eq $true -and $report.stdout_capture_completed -eq $true -and $report.stderr_capture_completed -eq $true)
            $checks['no_timeout_or_kill'] = ($report.timed_out -eq $false -and $report.kill_attempted -eq $false)
        }
        else {
            # The fixed timeout child emits no marker before it is killed, so
            # reconciliation must not promote it to PROCESS_CONFIRMED.
            $checks['not_falsely_confirmed'] = ($report.process_confirmation_status -cne 'PROCESS_CONFIRMED')
            $checks['timeout_reported'] = ($report.timed_out -eq $true -and $report.child_execution_status -ceq 'TIMED_OUT' -and $report.child_execution_succeeded -eq $false)
            $checks['kill_and_exit_confirmed'] = ($report.kill_attempted -eq $true -and $report.kill_succeeded -eq $true -and $report.process_exit_confirmed -eq $true -and $report.termination_status -ceq 'KILL_CONFIRMED')
            $checks['output_drained'] = ($report.stdout_capture_completed -eq $true -and $report.stderr_capture_completed -eq $true)
        }
    }

    $failedChecks = @($checks.Keys | Where-Object { -not [bool]$checks[$_] })
    return [pscustomobject][ordered]@{
        scenario = $Scenario
        success = ($failedChecks.Count -eq 0 -and $null -eq $exceptionType)
        elapsed_milliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
        failed_checks = $failedChecks
        exception_type = $exceptionType
    }
}

$results = @(
    Invoke-SumiGuardFailureScenario -Scenario 'NONZERO_EXIT'
    Invoke-SumiGuardFailureScenario -Scenario 'TIMEOUT'
)
$failedScenarios = @($results | Where-Object { -not $_.success } | ForEach-Object { $_.scenario })
[pscustomobject][ordered]@{
    check = 'managed-process-evidence-failure-smoke'
    success = ($failedScenarios.Count -eq 0)
    host = 'Windows PowerShell 5.1'
    scope = 'TWO_FIXED_HARMLESS_CHILDREN_ON_CI_RUNNER'
    failed_scenarios = $failedScenarios
    results = $results
    storage_status = 'NOT_ATTEMPTED'
    operator_machine_verified = $false
    dpapi_verified = $false
    arbitrary_command_execution_supported = $false
} | ConvertTo-Json -Compress -Depth 6

if ($failedScenarios.Count -ne 0) { exit 1 }
