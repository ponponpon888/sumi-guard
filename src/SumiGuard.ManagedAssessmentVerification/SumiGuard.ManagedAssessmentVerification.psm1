Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-SumiGuardTextEqual { param([AllowNull()][string]$Left, [AllowNull()][string]$Right) return ($null -ne $Left -and $null -ne $Right -and $Left -ceq $Right) }
function Test-SumiGuardExecutionId { param([AllowNull()][string]$Value) return ($null -ne $Value -and $Value -cmatch '^[0-9a-f]{32}$') }
function Get-SumiGuardEvidenceValue { param([AllowNull()]$Evidence, [Parameter(Mandatory = $true)][string]$Name) if ($null -eq $Evidence) { return $null }; $property = $Evidence.PSObject.Properties[$Name]; if ($null -eq $property) { return $null }; return $property.Value }
function New-SumiGuardManagedVerificationResult {
    param([Parameter(Mandatory = $true)][string]$PlanStatus,[Parameter(Mandatory = $true)][string]$PlanReasonCode,[Parameter(Mandatory = $true)][string]$ProcessStatus,[Parameter(Mandatory = $true)][string]$ProcessReasonCode)
    $verified = $PlanStatus -ceq 'VERIFIED_LAUNCH_PLAN'
    return [pscustomobject][ordered]@{
        interpreter_kind = if ($verified) { 'WINDOWS_POWERSHELL' } else { 'UNKNOWN' }; interpreter_verified = $verified
        launch_plan_status = $PlanStatus; launch_plan_reason_code = $PlanReasonCode
        process_confirmation_status = $ProcessStatus; process_confirmation_reason_code = $ProcessReasonCode
        assessment_input_status = if ($verified) { 'READY_FOR_ASSESSMENT' } else { 'UNASSESSABLE' }
        execution_status = if ($ProcessStatus -ceq 'PROCESS_CONFIRMED') { 'PROCESS_CONFIRMED' } elseif ($ProcessStatus -ceq 'NOT_ATTEMPTED') { 'NOT_STARTED' } else { 'PROCESS_UNVERIFIED' }
        storage_status = 'NOT_ATTEMPTED'; content_included = $false
    }
}
# $CallerInterpreterVerified is accepted and then deliberately never read. A
# caller's declaration cannot establish the target interpreter (the trust
# boundary in docs/24), so the parameter exists to let a caller pass such a
# declaration and have it make no difference. The test
# SELF_DECLARATION_NOT_TRUSTED in tests/Invoke-ManagedAssessmentVerificationTests.ps1
# passes -CallerInterpreterVerified $true and asserts the result is still
# unverified. Removing the parameter would remove the ability to test that.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'CallerInterpreterVerified is ignored by design: a caller declaration is not evidence of the target interpreter. A test passes it to prove it is ignored.')]
function Test-SumiGuardManagedAssessmentEvidence {
    [CmdletBinding()]param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AssessmentCommandText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LaunchCommandText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AssessmentExecutionId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlannedExecutionId,
        [Parameter(Mandatory = $true)]$HostEvidence,[AllowNull()]$PostExecutionEvidence = $null,[bool]$CallerInterpreterVerified = $false)
    try {
        $planStatus = 'UNVERIFIED_LAUNCH_PLAN'; $planReason = 'EVIDENCE_MISSING'
        if (-not (Test-SumiGuardTextEqual $AssessmentCommandText $LaunchCommandText)) { $planReason = 'COMMAND_MISMATCH' }
        elseif (-not (Test-SumiGuardExecutionId $AssessmentExecutionId) -or -not (Test-SumiGuardExecutionId $PlannedExecutionId) -or -not (Test-SumiGuardTextEqual $AssessmentExecutionId $PlannedExecutionId)) { $planReason = 'EXECUTION_ID_MISMATCH' }
        else {
            $fixedExecutable=[string](Get-SumiGuardEvidenceValue $HostEvidence 'fixed_executable_path');$observedExecutable=[string](Get-SumiGuardEvidenceValue $HostEvidence 'observed_executable_path');$expectedVersion=[string](Get-SumiGuardEvidenceValue $HostEvidence 'expected_interpreter_version');$observedVersion=[string](Get-SumiGuardEvidenceValue $HostEvidence 'observed_interpreter_version');$expectedFileVersion=[string](Get-SumiGuardEvidenceValue $HostEvidence 'expected_file_version');$observedFileVersion=[string](Get-SumiGuardEvidenceValue $HostEvidence 'observed_file_version');$launchVerified=Get-SumiGuardEvidenceValue $HostEvidence 'launch_configuration_verified'
            if ([string]::IsNullOrWhiteSpace($fixedExecutable) -or [string]::IsNullOrWhiteSpace($observedExecutable) -or [string]::IsNullOrWhiteSpace($expectedVersion) -or [string]::IsNullOrWhiteSpace($observedVersion) -or [string]::IsNullOrWhiteSpace($expectedFileVersion) -or [string]::IsNullOrWhiteSpace($observedFileVersion) -or $null -eq $launchVerified) { $planReason='EVIDENCE_MISSING' }
            elseif (-not (Test-SumiGuardTextEqual $fixedExecutable $observedExecutable)) { $planReason='EXECUTABLE_MISMATCH' }
            elseif ($expectedVersion -notmatch '^5\.1\.' -or $observedVersion -notmatch '^5\.1\.') { $planReason='UNSUPPORTED_VERSION' }
            elseif (-not (Test-SumiGuardTextEqual $expectedVersion $observedVersion) -or -not (Test-SumiGuardTextEqual $expectedFileVersion $observedFileVersion)) { $planReason='VERSION_MISMATCH' }
            elseif (-not [bool]$launchVerified) { $planReason='LAUNCH_CONFIGURATION_UNVERIFIED' }
            else { $planStatus='VERIFIED_LAUNCH_PLAN';$planReason='VERIFIED_MANAGED_LAUNCH_PLAN' }
        }
        $processStatus='NOT_ATTEMPTED';$processReason='PROCESS_NOT_STARTED'
        if ($null -ne $PostExecutionEvidence) {
            $started=Get-SumiGuardEvidenceValue $PostExecutionEvidence 'process_started';$observedExecutionId=[string](Get-SumiGuardEvidenceValue $PostExecutionEvidence 'execution_id');$observedExecutable=[string](Get-SumiGuardEvidenceValue $PostExecutionEvidence 'observed_executable_path');$fixedExecutable=[string](Get-SumiGuardEvidenceValue $HostEvidence 'fixed_executable_path')
            if ($null -eq $started -or -not [bool]$started) {$processStatus='PROCESS_UNVERIFIED';$processReason='PROCESS_EVIDENCE_MISSING'}
            elseif (-not (Test-SumiGuardExecutionId $observedExecutionId) -or -not (Test-SumiGuardTextEqual $observedExecutionId $PlannedExecutionId)) {$processStatus='PROCESS_UNVERIFIED';$processReason='PROCESS_EXECUTION_ID_MISMATCH'}
            elseif (-not (Test-SumiGuardTextEqual $fixedExecutable $observedExecutable)) {$processStatus='PROCESS_UNVERIFIED';$processReason='PROCESS_EXECUTABLE_MISMATCH'}
            else {$processStatus='PROCESS_CONFIRMED';$processReason='PROCESS_EVIDENCE_CONFIRMED'}
        }
        return New-SumiGuardManagedVerificationResult $planStatus $planReason $processStatus $processReason
    } catch { return New-SumiGuardManagedVerificationResult 'UNVERIFIED_LAUNCH_PLAN' 'VERIFICATION_FAILED' 'PROCESS_UNVERIFIED' 'VERIFICATION_FAILED' }
}
Export-ModuleMember -Function @('Test-SumiGuardManagedAssessmentEvidence')
