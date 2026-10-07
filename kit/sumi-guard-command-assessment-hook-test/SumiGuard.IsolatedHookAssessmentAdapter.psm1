Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:AssessmentManifest = Join-Path `
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
    'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
if (-not (Test-Path -LiteralPath $script:AssessmentManifest -PathType Leaf)) {
    throw 'CommandAssessment module was not found.'
}
$null = Import-Module -Name $script:AssessmentManifest -Force -ErrorAction Stop

function Get-SumiGuardHookExecutionId {
    param([Parameter(Mandatory = $true)]$HookInput)

    $identity = ([string]$HookInput.session_id) + '|' +
        ([string]$HookInput.turn_id) + '|' +
        ([string]$HookInput.tool_use_id)
    [byte[]]$bytes = $script:Utf8Strict.GetBytes($identity)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$digest = $sha256.ComputeHash($bytes)
        try {
            return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant().Substring(0, 32)
        }
        finally {
            if ($digest.Length -gt 0) { [Array]::Clear($digest, 0, $digest.Length) }
        }
    }
    finally {
        $sha256.Dispose()
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function New-SumiGuardHookAssessmentEnvelope {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$AdapterStatus,
        [AllowNull()]$ExecutionId,
        [Parameter(Mandatory = $true)][bool]$InterpreterVerified,
        [Parameter(Mandatory = $true)][string]$InterpreterEvidenceSource,
        [Parameter(Mandatory = $true)][string]$InterpreterReasonCode,
        [AllowNull()]$Assessment
    )

    return [pscustomobject][ordered]@{
        adapter_schema_version = 1
        success = $Success
        adapter_status = $AdapterStatus
        execution_id = $ExecutionId
        interpreter_verified = $InterpreterVerified
        interpreter_evidence_source = $InterpreterEvidenceSource
        interpreter_reason_code = $InterpreterReasonCode
        assessment = $Assessment
        control_output_emitted = $false
        content_included = $false
        exception_message_included = $false
    }
}

function Get-SumiGuardInterpreterVerification {
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [AllowEmptyString()][string]$TrustedPowerShellExecutablePath
    )

    $unverifiedSource = 'UNVERIFIED'
    if ([string]::IsNullOrWhiteSpace($TrustedPowerShellExecutablePath)) {
        return [pscustomobject][ordered]@{
            verified = $false
            source = $unverifiedSource
            reason_code = 'TRUSTED_EXECUTABLE_UNAVAILABLE'
        }
    }

    $expectedPath = Join-Path `
        ([Environment]::SystemDirectory) `
        'WindowsPowerShell\v1.0\powershell.exe'
    try {
        $trustedPath = [IO.Path]::GetFullPath($TrustedPowerShellExecutablePath)
        $canonicalPath = [IO.Path]::GetFullPath($expectedPath)
        if (-not $trustedPath.Equals($canonicalPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $trustedPath -PathType Leaf)) {
            return [pscustomobject][ordered]@{
                verified = $false
                source = $unverifiedSource
                reason_code = 'TRUSTED_EXECUTABLE_NOT_CANONICAL'
            }
        }
        $item = Get-Item -LiteralPath $trustedPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject][ordered]@{
                verified = $false
                source = $unverifiedSource
                reason_code = 'TRUSTED_EXECUTABLE_NOT_CANONICAL'
            }
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            verified = $false
            source = $unverifiedSource
            reason_code = 'TRUSTED_EXECUTABLE_NOT_CANONICAL'
        }
    }

    if ($null -eq $HookInput.tool_input -or
        $HookInput.tool_input.PSObject.Properties.Name -cnotcontains 'shell') {
        return [pscustomobject][ordered]@{
            verified = $false
            source = $unverifiedSource
            reason_code = 'HOOK_SHELL_FIELD_MISSING'
        }
    }
    $shellValue = [string]$HookInput.tool_input.shell
    $shellMatches = ($shellValue -ieq 'powershell' -or $shellValue -ieq 'powershell.exe')
    if (-not $shellMatches -and -not [string]::IsNullOrWhiteSpace($shellValue)) {
        try {
            $shellMatches = [IO.Path]::GetFullPath($shellValue).Equals(
                [IO.Path]::GetFullPath($expectedPath),
                [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $shellMatches = $false
        }
    }
    if (-not $shellMatches) {
        return [pscustomobject][ordered]@{
            verified = $false
            source = $unverifiedSource
            reason_code = 'HOOK_SHELL_VALUE_UNSUPPORTED'
        }
    }
    return [pscustomobject][ordered]@{
        verified = $true
        source = 'TOOL_INPUT_SHELL_PLUS_LAUNCH_CONFIGURATION'
        reason_code = 'VERIFIED_WINDOWS_POWERSHELL'
    }
}

function Invoke-SumiGuardSyntheticPreToolUseAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RawHookInputJson,
        [AllowEmptyString()][string]$TrustedPowerShellExecutablePath = '',
        [Parameter(Mandatory = $true)][ref]$Result
    )

    $Result.Value = $null
    $executionId = $null
    try {
        try {
            $hookInput = $RawHookInputJson | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $Result.Value = (
                New-SumiGuardHookAssessmentEnvelope `
                    -Success $false `
                    -AdapterStatus 'INVALID_HOOK_INPUT' `
                    -ExecutionId $null `
                    -InterpreterVerified $false `
                    -InterpreterEvidenceSource 'UNVERIFIED' `
                    -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                    -Assessment $null)
            return
        }
        if ($null -eq $hookInput -or $hookInput -is [Array]) {
            $Result.Value = (
                New-SumiGuardHookAssessmentEnvelope `
                    -Success $false `
                    -AdapterStatus 'INVALID_HOOK_INPUT' `
                    -ExecutionId $null `
                    -InterpreterVerified $false `
                    -InterpreterEvidenceSource 'UNVERIFIED' `
                    -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                    -Assessment $null)
            return
        }

        $requiredProperties = @(
            'hook_event_name', 'tool_name', 'session_id',
            'turn_id', 'tool_use_id', 'tool_input')
        foreach ($propertyName in $requiredProperties) {
            if ($hookInput.PSObject.Properties.Name -cnotcontains $propertyName) {
                $Result.Value = (
                    New-SumiGuardHookAssessmentEnvelope `
                        -Success $false `
                        -AdapterStatus 'INVALID_HOOK_INPUT' `
                        -ExecutionId $null `
                        -InterpreterVerified $false `
                        -InterpreterEvidenceSource 'UNVERIFIED' `
                        -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                        -Assessment $null)
                return
            }
        }
        foreach ($propertyName in @('session_id', 'turn_id', 'tool_use_id')) {
            if ([string]::IsNullOrWhiteSpace([string]$hookInput.$propertyName)) {
                $Result.Value = (
                    New-SumiGuardHookAssessmentEnvelope `
                        -Success $false `
                        -AdapterStatus 'INVALID_HOOK_INPUT' `
                        -ExecutionId $null `
                        -InterpreterVerified $false `
                        -InterpreterEvidenceSource 'UNVERIFIED' `
                        -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                        -Assessment $null)
                return
            }
        }
        if ([string]$hookInput.hook_event_name -cne 'PreToolUse') {
            $Result.Value = (
                New-SumiGuardHookAssessmentEnvelope `
                    -Success $true `
                    -AdapterStatus 'HOOK_EVENT_NOT_APPLICABLE' `
                    -ExecutionId $null `
                    -InterpreterVerified $false `
                    -InterpreterEvidenceSource 'UNVERIFIED' `
                    -InterpreterReasonCode 'HOOK_EVENT_NOT_APPLICABLE' `
                    -Assessment $null)
            return
        }
        if ([string]$hookInput.tool_name -cne 'Bash') {
            $Result.Value = (
                New-SumiGuardHookAssessmentEnvelope `
                    -Success $true `
                    -AdapterStatus 'TOOL_NOT_APPLICABLE' `
                    -ExecutionId $null `
                    -InterpreterVerified $false `
                    -InterpreterEvidenceSource 'UNVERIFIED' `
                    -InterpreterReasonCode 'TOOL_NOT_APPLICABLE' `
                    -Assessment $null)
            return
        }
        if ($null -eq $hookInput.tool_input) {
            $Result.Value = (
                New-SumiGuardHookAssessmentEnvelope `
                    -Success $false `
                    -AdapterStatus 'INVALID_HOOK_INPUT' `
                    -ExecutionId $null `
                    -InterpreterVerified $false `
                    -InterpreterEvidenceSource 'UNVERIFIED' `
                    -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                    -Assessment $null)
            return
        }

        $executionId = Get-SumiGuardHookExecutionId -HookInput $hookInput
        $command = ''
        if ($hookInput.tool_input.PSObject.Properties.Name -ccontains 'command' -and
            $null -ne $hookInput.tool_input.command) {
            if ($hookInput.tool_input.command -isnot [string]) {
                $Result.Value = (
                    New-SumiGuardHookAssessmentEnvelope `
                        -Success $false `
                        -AdapterStatus 'INVALID_HOOK_INPUT' `
                        -ExecutionId $executionId `
                        -InterpreterVerified $false `
                        -InterpreterEvidenceSource 'UNVERIFIED' `
                        -InterpreterReasonCode 'HOOK_INPUT_INVALID' `
                        -Assessment $null)
                return
            }
            $command = [string]$hookInput.tool_input.command
        }

        $verification = Get-SumiGuardInterpreterVerification `
            -HookInput $hookInput `
            -TrustedPowerShellExecutablePath $TrustedPowerShellExecutablePath
        $interpreterKind = if ($verification.verified) {
            'WINDOWS_POWERSHELL'
        }
        else {
            'UNKNOWN'
        }
        $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText $command `
            -ExecutionId $executionId `
            -InterpreterKind $interpreterKind `
            -InterpreterVerified ([bool]$verification.verified)
        $Result.Value = (
            New-SumiGuardHookAssessmentEnvelope `
                -Success $true `
                -AdapterStatus 'ASSESSMENT_COMPLETED' `
                -ExecutionId $executionId `
                -InterpreterVerified ([bool]$verification.verified) `
                -InterpreterEvidenceSource ([string]$verification.source) `
                -InterpreterReasonCode ([string]$verification.reason_code) `
                -Assessment $assessment)
    }
    catch {
        $Result.Value = (
            New-SumiGuardHookAssessmentEnvelope `
                -Success $false `
                -AdapterStatus 'ADAPTER_INTERNAL_ERROR' `
                -ExecutionId $executionId `
                -InterpreterVerified $false `
                -InterpreterEvidenceSource 'UNVERIFIED' `
                -InterpreterReasonCode 'ADAPTER_INTERNAL_ERROR' `
                -Assessment $null)
    }
}

Export-ModuleMember -Function @('Invoke-SumiGuardSyntheticPreToolUseAssessment')
