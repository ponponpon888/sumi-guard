[CmdletBinding()]
param([switch]$RunSmoke)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is an opt-in, single-child Windows PowerShell 5.1 smoke test.
# Do not dot-source: the script reports an OS exit code for CI.
if ($MyInvocation.InvocationName -ceq '.') {
    throw 'Dot-sourcing this smoke test is not supported.'
}
if (-not $RunSmoke) {
    [pscustomobject]@{
        check = 'managed-process-evidence-real-smoke'
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

# Only the product's fixed, encoded, harmless correlation-echo command is
# launched. No arbitrary command, hook, persistent monitor, or store is enabled.
$correlationId = [Guid]::NewGuid().ToString('N')
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$report = $null
$exceptionType = $null
try {
    $report = Invoke-SumiGuardManagedProcessEvidenceConnection `
        -CorrelationId $correlationId `
        -RunProcess `
        -UseRealProcessAdapter
}
catch {
    # Return only the type, never exception text or child output.
    $exceptionType = $_.Exception.GetType().FullName
}
finally {
    $stopwatch.Stop()
}

$checks = [ordered]@{
    report_present = ($null -ne $report)
}
if ($null -ne $report) {
    $checks['plan_verified'] = ($report.plan_body_verified -eq $true -and $report.plan_arguments_verified -eq $true)
    $checks['launch_plan_verified'] = ($report.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN')
    $checks['process_confirmed'] = ($report.process_confirmation_status -ceq 'PROCESS_CONFIRMED')
    $checks['observer_once'] = ($report.observer_invocation_count -eq 1 -and $report.execution_start_count -eq 1)
    $checks['single_process_start'] = ($report.process_start_attempt_count -eq 1 -and $report.process_start_success_count -eq 1)
    $checks['identity_observed'] = ($report.pid_obtained -eq $true -and $report.start_time_obtained -eq $true -and $report.executable_path_obtained -eq $true)
    $checks['correlation_matches'] = ($report.correlation_id_matches -eq $true)
    $checks['exit_confirmed'] = ($report.process_exit_confirmed -eq $true -and $report.termination_status -ceq 'EXITED_NORMALLY')
    $checks['child_exit_zero'] = ($null -ne $report.child_exit_code -and $report.child_exit_code -eq 0)
    $checks['child_succeeded'] = ($report.child_execution_succeeded -eq $true -and $report.child_execution_status -ceq 'SUCCEEDED')
    $checks['stdout_matches'] = ($report.stdout_matches_expected -eq $true -and $report.stdout_capture_completed -eq $true)
    $checks['stderr_capture_complete'] = ($report.stderr_capture_completed -eq $true)
    $checks['no_timeout_or_kill'] = ($report.timed_out -eq $false -and $report.kill_attempted -eq $false)
    $checks['adapter_completed'] = ($report.adapter_stage -ceq 'COMPLETED' -and $null -eq $report.adapter_exception_type)
    $checks['no_storage'] = ($report.storage_status -ceq 'NOT_ATTEMPTED')
}

$failedChecks = @($checks.Keys | Where-Object { -not [bool]$checks[$_] })
$success = ($failedChecks.Count -eq 0 -and $null -eq $exceptionType)
[pscustomobject][ordered]@{
    check = 'managed-process-evidence-real-smoke'
    success = $success
    host = 'Windows PowerShell 5.1'
    scope = 'SINGLE_FIXED_HARMLESS_CHILD_ON_CI_RUNNER'
    elapsed_milliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds)
    failed_checks = $failedChecks
    exception_type = $exceptionType
    storage_status = 'NOT_ATTEMPTED'
    operator_machine_verified = $false
    dpapi_verified = $false
    abnormal_and_timeout_paths_verified = $false
} | ConvertTo-Json -Compress -Depth 6

if (-not $success) { exit 1 }
