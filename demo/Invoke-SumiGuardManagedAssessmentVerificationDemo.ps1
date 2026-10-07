[CmdletBinding()]
param([switch]$RunFixedCommand)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ManagedAssessmentConnectionRoot = Split-Path -Parent $PSScriptRoot
$script:ManagedAssessmentConnectionInitialized = $false
$script:ManagedAssessmentConnectionRequestedFixedCommand = [bool]$RunFixedCommand
. (Join-Path $script:ManagedAssessmentConnectionRoot 'demo\Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1')

function Initialize-SumiGuardManagedAssessmentVerificationConnection {
    if ($script:ManagedAssessmentConnectionInitialized) { return }
    Import-Module (Join-Path $script:ManagedAssessmentConnectionRoot 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $script:ManagedAssessmentConnectionRoot 'src\SumiGuard.ManagedAssessmentVerification\SumiGuard.ManagedAssessmentVerification.psd1') -Force -ErrorAction Stop
    $script:ManagedAssessmentConnectionInitialized = $true
}

function Get-SumiGuardConnectionValue {
    param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) { return $null }
    return $Value.PSObject.Properties[$Name].Value
}

function New-SumiGuardManagedAssessmentHostEvidence {
    param([Parameter(Mandatory = $true)]$Configuration, [Parameter(Mandatory = $true)]$Verification)
    $hostVerified = ([bool](Get-SumiGuardConnectionValue $Verification 'verified') -and
        [bool](Get-SumiGuardConnectionValue $Verification 'executable_is_standard_path') -and
        [bool](Get-SumiGuardConnectionValue $Verification 'runner_process_is_standard_path') -and
        [bool](Get-SumiGuardConnectionValue $Verification 'launch_configuration_verified') -and
        [string](Get-SumiGuardConnectionValue $Verification 'evidence_source') -ceq 'MANAGED_RUNNER_PROCESS_AND_LAUNCH_CONFIGURATION')
    $fixedPath = [string](Get-SumiGuardConnectionValue $Configuration 'executable_path')
    $observedPath = Get-SumiGuardConnectionValue $Verification 'observed_executable_path'
    if ($null -eq $observedPath) { $observedPath = $fixedPath }
    $expectedVersion = Get-SumiGuardConnectionValue $Configuration 'expected_interpreter_version'
    if ($null -eq $expectedVersion) { $expectedVersion = Get-SumiGuardConnectionValue $Verification 'interpreter_version' }
    return [pscustomobject]@{
        fixed_executable_path = $fixedPath
        observed_executable_path = [string]$observedPath
        expected_interpreter_version = [string]$expectedVersion
        observed_interpreter_version = [string](Get-SumiGuardConnectionValue $Verification 'interpreter_version')
        expected_file_version = [string](Get-SumiGuardConnectionValue $Verification 'executable_file_version')
        observed_file_version = [string](Get-SumiGuardConnectionValue $Verification 'executable_file_version')
        launch_configuration_verified = $hostVerified
    }
}

function Invoke-SumiGuardManagedAssessmentVerificationConnection {
    [CmdletBinding()]
    param(
        [AllowNull()]$ConfigurationOverride = $null,
        [AllowNull()]$VerificationOverride = $null,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$AssessmentExecutionId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$PlannedExecutionId,
        [AllowNull()]$PostExecutionEvidence = $null,
        [bool]$RequestDryStart = $false,
        [AllowNull()][scriptblock]$TestDoubleStart = $null,
        [bool]$RunFixedCommand = $false,
        [AllowNull()][scriptblock]$TestDoubleFixedExecution = $null,
        [AllowNull()][scriptblock]$AssessmentInvoker = $null
    )
    $startCount = 0
    try {
        Initialize-SumiGuardManagedAssessmentVerificationConnection
        $configuration = if ($null -ne $ConfigurationOverride) { $ConfigurationOverride } else { Get-SumiGuardManagedPowerShellDemoConfiguration }
        $verification = if ($null -ne $VerificationOverride) { $VerificationOverride } else { Get-SumiGuardManagedPowerShellVerification }
        $assessmentText = [string](Get-SumiGuardConnectionValue $configuration 'assessment_command_text')
        $launchText = [string](Get-SumiGuardConnectionValue $configuration 'launch_command_text')
        $hostEvidence = New-SumiGuardManagedAssessmentHostEvidence -Configuration $configuration -Verification $verification
        $reconciliation = Test-SumiGuardManagedAssessmentEvidence -AssessmentCommandText $assessmentText -LaunchCommandText $launchText -AssessmentExecutionId $AssessmentExecutionId -PlannedExecutionId $PlannedExecutionId -HostEvidence $hostEvidence -PostExecutionEvidence $PostExecutionEvidence

        $assessment = $null
        try {
            if ($null -ne $AssessmentInvoker) { $assessment = & $AssessmentInvoker $assessmentText $AssessmentExecutionId ([bool]$reconciliation.interpreter_verified) }
            else {
                $kind = if ([bool]$reconciliation.interpreter_verified) { 'WINDOWS_POWERSHELL' } else { 'UNKNOWN' }
                $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText $assessmentText -ExecutionId $AssessmentExecutionId -InterpreterKind $kind -InterpreterVerified ([bool]$reconciliation.interpreter_verified)
            }
        } catch { $assessment = $null }
        $assessmentStatus = if ($null -eq $assessment) { 'EVALUATION_FAILED' } else { [string]$assessment.assessment_status }
        $assessmentReason = if ($null -eq $assessment) { 'RULE_ENGINE_ERROR' } else { $assessment.assessment_reason_code }

        $startStatus = 'NOT_REQUESTED'
        $executionResult = $null
        if ($RequestDryStart -and [bool]$reconciliation.interpreter_verified -and $assessmentStatus -ne 'EVALUATION_FAILED') {
            if ($null -ne $TestDoubleStart) {
                $startCount = 1
                $startStatus = 'TEST_DOUBLE_STARTED'
                $returnedPost = & $TestDoubleStart
                if ($null -ne $returnedPost) {
                    $reconciliation = Test-SumiGuardManagedAssessmentEvidence -AssessmentCommandText $assessmentText -LaunchCommandText $launchText -AssessmentExecutionId $AssessmentExecutionId -PlannedExecutionId $PlannedExecutionId -HostEvidence $hostEvidence -PostExecutionEvidence $returnedPost
                }
            } else { $startStatus = 'DRY_START_NOT_IMPLEMENTED' }
        }
        elseif ($RequestDryStart) { $startStatus = 'START_BLOCKED_BY_RECONCILIATION' }

        if ($RunFixedCommand) {
            if (-not [bool]$reconciliation.interpreter_verified -or $assessmentStatus -eq 'EVALUATION_FAILED') {
                $startStatus = 'START_BLOCKED_BY_RECONCILIATION'
            }
            elseif ($null -ne $TestDoubleFixedExecution) {
                $executionResult = & $TestDoubleFixedExecution
                $startStatus = 'TEST_DOUBLE_FIXED_EXECUTION'
            }
            else {
                $executionResult = Invoke-SumiGuardManagedFixedCommand
                $startStatus = 'FIXED_COMMAND_EXECUTION_ATTEMPTED'
            }
        }

        $executionStarted = if ($null -eq $executionResult) { $false } else { [bool]$executionResult.execution_started }
        $executionStartCount = if ($null -eq $executionResult) { $startCount } else { [int]$executionResult.execution_start_count }
        $executionStatus = if ($null -eq $executionResult) { [string]$reconciliation.execution_status } else { [string]$executionResult.execution_status }
        $stdoutMatches = if ($null -eq $executionResult) { $null } else { $executionResult.stdout_matches_expected }
        $exitCode = if ($null -eq $executionResult) { $null } else { $executionResult.exit_code }
        $stderrNonempty = if ($null -eq $executionResult) { $null } else { $executionResult.stderr_nonempty }
        $timedOut = if ($null -eq $executionResult) { $false } else { [bool]$executionResult.timed_out }

        return [pscustomobject][ordered]@{
            assessment_status = $assessmentStatus
            assessment_reason_code = $assessmentReason
            reconciliation_status = [string]$reconciliation.launch_plan_status
            reconciliation_reason_code = [string]$reconciliation.launch_plan_reason_code
            process_confirmation_status = [string]$reconciliation.process_confirmation_status
            process_confirmation_reason_code = [string]$reconciliation.process_confirmation_reason_code
            execution_status = $executionStatus
            execution_started = $executionStarted
            execution_start_count = $executionStartCount
            execution_start_status = $startStatus
            stdout_matches_expected = $stdoutMatches
            exit_code = $exitCode
            stderr_nonempty = $stderrNonempty
            timed_out = $timedOut
            storage_status = 'NOT_ATTEMPTED'
            evaluation_origin = 'DRY_RUN'
            content_included = $false
        }
    }
    catch {
        return [pscustomobject][ordered]@{ assessment_status='NOT_OBTAINED';assessment_reason_code='RUNNER_INTERNAL_ERROR';reconciliation_status='UNVERIFIED_LAUNCH_PLAN';reconciliation_reason_code='RUNNER_INTERNAL_ERROR';process_confirmation_status='NOT_ATTEMPTED';process_confirmation_reason_code='PROCESS_NOT_STARTED';execution_status='NOT_STARTED';execution_start_count=$startCount;execution_start_status='NOT_REQUESTED';storage_status='NOT_ATTEMPTED';evaluation_origin='DRY_RUN';content_included=$false }
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    $executionId = [Guid]::NewGuid().ToString('N')
    $report = Invoke-SumiGuardManagedAssessmentVerificationConnection -AssessmentExecutionId $executionId -PlannedExecutionId $executionId -RunFixedCommand ([bool]$script:ManagedAssessmentConnectionRequestedFixedCommand)
    $report | ConvertTo-Json -Compress
    if ($report.reconciliation_status -cne 'VERIFIED_LAUNCH_PLAN' -or $report.assessment_status -cin @('EVALUATION_FAILED', 'NOT_OBTAINED')) { exit 1 }
}
