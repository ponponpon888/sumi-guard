[CmdletBinding()]
param(
    [switch]$RunFixedCommand,
    [string]$StorePath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SumiGuardIntegrationRoot = Split-Path -Parent $PSScriptRoot
$script:SumiGuardRequestedRunFixedCommand = [bool]$RunFixedCommand
$script:SumiGuardRequestedStorePath = $StorePath
$script:SumiGuardExistingRunner = Join-Path $script:SumiGuardIntegrationRoot 'demo\Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1'
$script:SumiGuardAssessmentManifest = Join-Path $script:SumiGuardIntegrationRoot 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
$script:SumiGuardStoreManifest = Join-Path $script:SumiGuardIntegrationRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'
$script:SumiGuardShowCli = Join-Path $script:SumiGuardIntegrationRoot 'tools\Show-SumiGuardAssessments.ps1'
$script:SumiGuardIntegrationInitialized = $false

function Initialize-SumiGuardManagedAssessmentStoreIntegration {
    if ($script:SumiGuardIntegrationInitialized) { return }
    foreach ($path in @($script:SumiGuardExistingRunner, $script:SumiGuardAssessmentManifest, $script:SumiGuardStoreManifest, $script:SumiGuardShowCli)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw [IO.FileNotFoundException]::new() }
    }
    $null = Import-Module -Name $script:SumiGuardAssessmentManifest -Force -ErrorAction Stop
    $null = Import-Module -Name $script:SumiGuardStoreManifest -Force -ErrorAction Stop
    $script:SumiGuardIntegrationInitialized = $true
}

function New-SumiGuardIntegrationStorePath {
    return Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-managed-assessment-store-' + [Guid]::NewGuid().ToString('N'))
}

function New-SumiGuardIntegrationFailureReport {
    param(
        [bool]$RunRequested,
        [string]$FailureStage,
        [string]$IntegrationStatus,
        [AllowNull()]$Assessment,
        [bool]$AssessmentSaved = $false,
        [string]$AssessmentSaveStatus = 'NOT_ATTEMPTED'
    )
    $assessmentObtained = ($null -ne $Assessment)
    return [pscustomobject][ordered]@{
        demo_status = 'INTEGRATION_FAILED'; integration_status = $IntegrationStatus; integration_failure_stage = $FailureStage
        assessment_obtained = $assessmentObtained; assessment_status = if($assessmentObtained){[string]$Assessment.assessment_status}else{$null}; assessment_reason_code = if($assessmentObtained){$Assessment.assessment_reason_code}else{$null}
        assessment_saved = $AssessmentSaved; assessment_save_status = $AssessmentSaveStatus; assessment_displayed = $false
        evaluation_origin = 'SYNTHETIC_TEST'; execution_status = if ($RunRequested) { 'BLOCKED_BY_PRECONDITION' } else { 'NOT_EXECUTED' }
        execution_started = $false; execution_start_count = 0; stdout_matches_expected = $null; exit_code = $null; stderr_nonempty = $null; timed_out = $false
        command_text_included = $false; raw_streams_included = $false; exception_message_included = $false; success = $false
    }
}

function Invoke-SumiGuardManagedAssessmentStoreDemo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$RunRequested,
        [string]$AssessmentStorePath = '',
        [AllowNull()][scriptblock]$ManagedExecutionInvoker = $null,
        [AllowNull()][scriptblock]$DisplayInvoker = $null,
        [AllowNull()][scriptblock]$ReadbackInvoker = $null
    )

    $createdStorePath = $false
    $stage = 'INITIALIZATION'
    $assessment = $null
    $assessmentSaved = $false
    $assessmentSaveStatus = 'NOT_ATTEMPTED'
    try {
        Initialize-SumiGuardManagedAssessmentStoreIntegration
        $stage = 'STORE_INITIALIZATION'
        if ([string]::IsNullOrWhiteSpace($AssessmentStorePath)) {
            $AssessmentStorePath = New-SumiGuardIntegrationStorePath
            $createdStorePath = $true
        }
        $storeCreate = SumiGuard.AssessmentStore\New-SumiGuardAssessmentStore -StorePath $AssessmentStorePath
        if (-not $storeCreate.success) {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'STORE_INITIALIZATION_FAILED' -Assessment $null
        }

        $stage = 'ASSESSMENT'
        $configuration = Get-SumiGuardManagedPowerShellDemoConfiguration
        $verification = Get-SumiGuardManagedPowerShellVerification
        $executionId = [Guid]::NewGuid().ToString('N')
        $interpreterKind = if ($verification.verified) { 'WINDOWS_POWERSHELL' } else { 'UNKNOWN' }
        $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText $configuration.assessment_command_text `
            -ExecutionId $executionId `
            -InterpreterKind $interpreterKind `
            -InterpreterVerified ([bool]$verification.verified)

        $decision = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified ([bool]$verification.verified) `
            -CommandMatches ($configuration.assessment_command_text -ceq $configuration.launch_command_text) `
            -AssessmentStatus ([string]$assessment.assessment_status) `
            -AssessmentReasonCode $assessment.assessment_reason_code `
            -FindingCount @($assessment.findings).Count `
            -RunRequested $RunRequested
        $stage = 'EXECUTION'
        $execution = if ($decision.should_start) {
            if ($null -ne $ManagedExecutionInvoker) { & $ManagedExecutionInvoker } else { Invoke-SumiGuardManagedFixedCommand }
        } else {
            [pscustomobject][ordered]@{ execution_started = $false; execution_start_count = 0; execution_status = if ($RunRequested) { 'BLOCKED_BY_PRECONDITION' } else { 'NOT_EXECUTED' }; stdout_matches_expected = $null; exit_code = $null; stderr_nonempty = $null; timed_out = $false }
        }

        $origin = if ($execution.execution_started) { 'MANAGED_EXECUTION' } else { 'SYNTHETIC_TEST' }
        $relatedId = if ($execution.execution_started) { $executionId } else { $null }
        $stage = 'SAVE'
        $save = SumiGuard.AssessmentStore\Save-SumiGuardAssessment `
            -StorePath $AssessmentStorePath -Assessment $assessment -EvaluationOrigin $origin -RelatedExecutionId $relatedId
        $assessmentSaved = [bool]$save.success
        $assessmentSaveStatus = [string]$save.status
        if (-not $save.success) {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'ASSESSMENT_SAVE_FAILED' -Assessment $assessment -AssessmentSaved $false -AssessmentSaveStatus $assessmentSaveStatus
        }
        $stage = 'DISPLAY'
        $displayed = $false
        $displayExitCode = 1
        try {
            if ($null -ne $DisplayInvoker) {
                $displayLines = @(& $DisplayInvoker)
                $displayExitCode = 0
            }
            else {
                $displayLines = @(Invoke-SumiGuardAssessmentDisplay -AssessmentStorePath $AssessmentStorePath -RequestedAssessmentId $save.assessment_id -ExitCode ([ref]$displayExitCode))
            }
        }
        catch {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'ASSESSMENT_DISPLAY_FAILED' -Assessment $assessment -AssessmentSaved $true -AssessmentSaveStatus $assessmentSaveStatus
        }
        $displayed = ($displayExitCode -eq 0 -and $displayLines.Count -gt 0)
        $displayLabelsConfirmed = ($displayLines -join "`n").Contains('評価結果詳細')
        if (-not $displayed) {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'ASSESSMENT_DISPLAY_FAILED' -Assessment $assessment -AssessmentSaved $true -AssessmentSaveStatus $assessmentSaveStatus
        }
        $stage = 'READBACK'
        $readback = if ($null -ne $ReadbackInvoker) { & $ReadbackInvoker } else { SumiGuard.AssessmentStore\Get-SumiGuardAssessmentRecord -StorePath $AssessmentStorePath -AssessmentId $save.assessment_id }
        $readbackSuccess = [bool]$readback.success
        $readbackContainsAssessment = ($readbackSuccess -and $readback.record_count -eq 1)
        if (-not $readbackContainsAssessment) {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'ASSESSMENT_READBACK_FAILED' -Assessment $assessment -AssessmentSaved $true -AssessmentSaveStatus $assessmentSaveStatus
        }
        $stored = $readback.records[0]
        $storedOriginMatches = ([string]$stored.evaluation_origin -ceq [string]$origin)
        $storedExecutionIdMatches = if ($origin -ceq 'MANAGED_EXECUTION') { [string]$stored.execution_id -ceq $executionId } else { $null }
        if (-not $storedOriginMatches -or ($origin -ceq 'MANAGED_EXECUTION' -and -not $storedExecutionIdMatches)) {
            return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'ASSESSMENT_IDENTITY_MISMATCH' -Assessment $assessment -AssessmentSaved $true -AssessmentSaveStatus $assessmentSaveStatus
        }
        $success = ($save.success -and $displayed -and $displayLabelsConfirmed -and $readbackContainsAssessment -and $storedOriginMatches -and (($origin -cne 'MANAGED_EXECUTION') -or $storedExecutionIdMatches) -and ((-not $RunRequested) -or ($execution.execution_status -ceq 'SUCCEEDED' -and $execution.stdout_matches_expected -eq $true -and $execution.exit_code -eq 0 -and $execution.stderr_nonempty -eq $false -and -not $execution.timed_out)))
        return [pscustomobject][ordered]@{
            demo_status = if ($success -and $RunRequested) { 'COMPLETED' } elseif ($success) { 'SYNTHETIC_SAVED_NOT_EXECUTED' } else { 'EXECUTION_PRECONDITION_NOT_MET' }
            integration_status = if($success){'COMPLETED'}else{'EXECUTION_PRECONDITION_NOT_MET'}; integration_failure_stage = $null
            assessment_obtained = $true; assessment_status = [string]$assessment.assessment_status; assessment_reason_code = $assessment.assessment_reason_code
            assessment_saved = [bool]$save.success; assessment_save_status = [string]$save.status; assessment_displayed = $displayed
            display_labels_confirmed = $displayLabelsConfirmed; readback_success = $readbackSuccess; readback_contains_assessment = $readbackContainsAssessment
            stored_origin_matches_execution = $storedOriginMatches; stored_execution_id_matches_execution = $storedExecutionIdMatches
            evaluation_origin = $origin; execution_status = [string]$execution.execution_status; execution_started = [bool]$execution.execution_started; execution_start_count = [int]$execution.execution_start_count
            stdout_matches_expected = $execution.stdout_matches_expected; exit_code = $execution.exit_code; stderr_nonempty = $execution.stderr_nonempty; timed_out = [bool]$execution.timed_out
            command_text_included = $false; raw_streams_included = $false; exception_message_included = $false; success = $success
        }
    }
    catch { return New-SumiGuardIntegrationFailureReport -RunRequested $RunRequested -FailureStage $stage -IntegrationStatus 'INTEGRATION_EXCEPTION' -Assessment $assessment -AssessmentSaved $assessmentSaved -AssessmentSaveStatus $assessmentSaveStatus }
    finally {
        if ($createdStorePath -and -not [string]::IsNullOrWhiteSpace($AssessmentStorePath) -and (Test-Path -LiteralPath $AssessmentStorePath)) {
            Remove-Item -LiteralPath $AssessmentStorePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# The existing runner and display CLI are loaded at script scope so their
# public helper functions remain available to this isolated integration demo.
# The display CLI receives only a disposable directory while being dot-sourced.
. $script:SumiGuardExistingRunner
. $script:SumiGuardShowCli -StorePath ([IO.Path]::GetTempPath())

if ($MyInvocation.InvocationName -cne '.') {
    $report = Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $script:SumiGuardRequestedRunFixedCommand -AssessmentStorePath $script:SumiGuardRequestedStorePath
    $report | ConvertTo-Json -Compress
    if ($report.success) { exit 0 }
    exit 1
}
