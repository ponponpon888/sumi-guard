Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:AssessmentManifest = Join-Path $script:Root 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
$script:StoreManifest = Join-Path $script:Root 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'

function Get-SumiGuardPreToolExecutionId {
    param([Parameter(Mandatory = $true)]$HookInput)
    [byte[]]$bytes = $script:Utf8Strict.GetBytes(([string]$HookInput.session_id) + '|' + ([string]$HookInput.turn_id) + '|' + ([string]$HookInput.tool_use_id))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $sha.Dispose(); if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function New-SumiGuardHookStoreResult {
    param([string]$AdapterStatus,[AllowNull()]$ExecutionId,[AllowNull()]$Assessment,[string]$AssessmentStatus,[string]$SaveStatus,[string]$ResponseStatus,[bool]$InterpreterVerified,[string]$InterpreterReason)
    $message = 'SUMI Guard MONITOR: evaluation=' + $AssessmentStatus + '; storage=' + $SaveStatus + '; response=monitor-only.'
    return [pscustomobject][ordered]@{
        adapter_schema_version = 1
        adapter_status = $AdapterStatus
        execution_id = $ExecutionId
        assessment = $Assessment
        assessment_status = $AssessmentStatus
        assessment_obtained = ($null -ne $Assessment)
        assessment_storage_status = $SaveStatus
        response_generation_status = $ResponseStatus
        interpreter_verified = $InterpreterVerified
        interpreter_reason_code = $InterpreterReason
        structured_response = [pscustomobject][ordered]@{ systemMessage = $message }
        control_output_emitted = $false
        content_included = $false
        exception_message_included = $false
    }
}

function Test-SumiGuardPreToolInput {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or $Value -is [Array]) { return $false }
    foreach ($name in @('hook_event_name','tool_name','session_id','turn_id','tool_use_id','tool_input')) {
        if ($Value.PSObject.Properties.Name -cnotcontains $name) { return $false }
    }
    if ([string]$Value.hook_event_name -cne 'PreToolUse' -or [string]$Value.tool_name -cne 'Bash' -or $null -eq $Value.tool_input) { return $false }
    foreach ($name in @('session_id','turn_id','tool_use_id')) { if ([string]::IsNullOrWhiteSpace([string]$Value.$name)) { return $false } }
    return ($Value.tool_input.PSObject.Properties.Name -ccontains 'command' -and $Value.tool_input.command -is [string])
}

function Invoke-SumiGuardSyntheticPreToolUseAssessmentStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawHookInputJson,
        [Parameter(Mandatory = $true)][string]$AssessmentStorePath,
        [switch]$SyntheticTrustedWindowsPowerShell,
        [switch]$TestForceEvaluationFailure,
        [switch]$TestForceSaveFailure,
        [Parameter(Mandatory = $true)][ref]$Result
    )
    $Result.Value = $null
    $executionId = $null
    try {
        Import-Module $script:AssessmentManifest -Force -ErrorAction Stop
        Import-Module $script:StoreManifest -Force -ErrorAction Stop
        try { $input = $RawHookInputJson | ConvertFrom-Json -ErrorAction Stop } catch { $input = $null }
        if (-not (Test-SumiGuardPreToolInput $input)) {
            $Result.Value = New-SumiGuardHookStoreResult -AdapterStatus 'INVALID_HOOK_INPUT' -ExecutionId $null -Assessment $null -AssessmentStatus 'NOT_OBTAINED' -SaveStatus 'NOT_ATTEMPTED' -ResponseStatus 'GENERATED' -InterpreterVerified $false -InterpreterReason 'HOOK_INPUT_INVALID'
            return
        }
        $executionId = Get-SumiGuardPreToolExecutionId $input
        # Only this test-only parameter supplies trusted provenance. JSON fields, tool_name, and hook host do not.
        $verified = [bool]$SyntheticTrustedWindowsPowerShell
        $kind = if ($verified) { 'WINDOWS_POWERSHELL' } else { 'UNKNOWN' }
        $reason = if ($verified) { 'SYNTHETIC_TRUSTED_EXECUTION_EVIDENCE' } else { 'TARGET_INTERPRETER_UNVERIFIED' }
        $assessmentModule = (Get-Module -Name 'SumiGuard.CommandAssessment' -All | Select-Object -First 1)
        $storeModule = (Get-Module -Name 'SumiGuard.AssessmentStore' -All | Select-Object -First 1)
        if ($TestForceEvaluationFailure) { $assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure', $true) }
        try {
            $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText ([string]$input.tool_input.command) -ExecutionId $executionId -InterpreterKind $kind -InterpreterVerified $verified
        }
        finally { if ($TestForceEvaluationFailure) { $assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure', $false) } }
        # PreToolUse does not prove execution. Store it only as a synthetic assessment with no related execution ID.
        if ($TestForceSaveFailure) { $storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure', $true) }
        try {
            $save = SumiGuard.AssessmentStore\Save-SumiGuardAssessment -StorePath $AssessmentStorePath -Assessment $assessment -EvaluationOrigin 'SYNTHETIC_TEST' -RelatedExecutionId $null
        }
        finally { if ($TestForceSaveFailure) { $storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure', $false) } }
        $saveStatus = if ($save.success) { 'SAVED' } else { [string]$save.status }
        $Result.Value = New-SumiGuardHookStoreResult -AdapterStatus 'COMPLETED' -ExecutionId $executionId -Assessment $assessment -AssessmentStatus ([string]$assessment.assessment_status) -SaveStatus $saveStatus -ResponseStatus 'GENERATED' -InterpreterVerified $verified -InterpreterReason $reason
    }
    catch {
        $Result.Value = New-SumiGuardHookStoreResult -AdapterStatus 'ADAPTER_INTERNAL_ERROR' -ExecutionId $executionId -Assessment $null -AssessmentStatus 'NOT_OBTAINED' -SaveStatus 'NOT_ATTEMPTED' -ResponseStatus 'GENERATED' -InterpreterVerified $false -InterpreterReason 'ADAPTER_INTERNAL_ERROR'
    }
}

Export-ModuleMember -Function @('Invoke-SumiGuardSyntheticPreToolUseAssessmentStore')
