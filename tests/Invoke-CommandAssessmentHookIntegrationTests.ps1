Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CurrentAssertion = 'INITIALIZATION'
$script:TestResults = New-Object System.Collections.Generic.List[object]
$script:CanonicalPowerShellPath = Join-Path `
    ([Environment]::SystemDirectory) `
    'WindowsPowerShell\v1.0\powershell.exe'
$script:AdapterManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'kit\sumi-guard-command-assessment-hook-test\SumiGuard.IsolatedHookAssessmentAdapter.psd1'

function Assert-SumiGuardTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )

    $script:CurrentAssertion = $Code
    if (-not $Condition) {
        throw [System.InvalidOperationException]::new()
    }
}

function New-SumiGuardSyntheticHookJson {
    param(
        [AllowNull()][object]$Command,
        [switch]$OmitCommand,
        [AllowNull()][string]$Shell,
        [switch]$OmitShell,
        [string]$SessionId = 'synthetic-session',
        [string]$TurnId = 'synthetic-turn',
        [string]$ToolUseId = 'synthetic-tool-use'
    )

    $toolInput = [ordered]@{}
    if (-not $OmitCommand) {
        $toolInput.command = $Command
    }
    if (-not $OmitShell) {
        $toolInput.shell = $Shell
    }
    return ([ordered]@{
        hook_event_name = 'PreToolUse'
        tool_name = 'Bash'
        session_id = $SessionId
        turn_id = $TurnId
        tool_use_id = $ToolUseId
        tool_input = $toolInput
    } | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-SumiGuardAdapterForTest {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [AllowEmptyString()][string]$TrustedPath = ''
    )

    $value = $null
    $pipelineOutput = @(
        Invoke-SumiGuardSyntheticPreToolUseAssessment `
            -RawHookInputJson $Json `
            -TrustedPowerShellExecutablePath $TrustedPath `
            -Result ([ref]$value))
    Assert-SumiGuardTest `
        -Condition ($pipelineOutput.Count -eq 0) `
        -Code 'CONTROL_STDOUT_MUST_BE_EMPTY'
    Assert-SumiGuardTest `
        -Condition ($null -ne $value) `
        -Code 'RESULT_REFERENCE_MUST_BE_SET'
    Assert-SumiGuardTest `
        -Condition (-not [bool]$value.control_output_emitted) `
        -Code 'CONTROL_OUTPUT_FLAG_MUST_BE_FALSE'
    return $value
}

function Get-SumiGuardExpectedExecutionId {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$ToolUseId
    )

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    [byte[]]$bytes = $encoding.GetBytes($SessionId + '|' + $TurnId + '|' + $ToolUseId)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$digest = $sha256.ComputeHash($bytes)
        try {
            return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant().Substring(0, 32)
        }
        finally {
            if ($digest.Length -gt 0) {
                [Array]::Clear($digest, 0, $digest.Length)
            }
        }
    }
    finally {
        $sha256.Dispose()
        if ($bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Invoke-SumiGuardIntegrationCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:CurrentAssertion = 'CASE_START'
    try {
        & $Body
        $script:TestResults.Add([pscustomobject][ordered]@{
            name = $Name
            result = 'PASS'
            failure_stage = $null
            exception_type = $null
        })
    }
    catch {
        $exceptionType = $null
        try {
            if ($null -ne $_.Exception) {
                $exceptionType = $_.Exception.GetType().FullName
            }
        }
        catch {
            $exceptionType = $null
        }
        $script:TestResults.Add([pscustomobject][ordered]@{
            name = $Name
            result = 'FAIL'
            failure_stage = $script:CurrentAssertion
            exception_type = $exceptionType
        })
    }
}

$topLevelFailureStage = $null
$topLevelExceptionType = $null
try {
    $script:CurrentAssertion = 'IMPORT_ADAPTER'
    $null = Import-Module -Name $script:AdapterManifest -Force -ErrorAction Stop

    Invoke-SumiGuardIntegrationCase -Name 'CURRENT_BASH_SHAPE_IS_UNVERIFIED' -Body {
        $json = New-SumiGuardSyntheticHookJson `
            -Command 'Set-MpPreference -DisableRealtimeMonitoring $true' `
            -OmitShell
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        Assert-SumiGuardTest ($result.success -eq $true) 'CURRENT_SUCCESS'
        Assert-SumiGuardTest ($result.interpreter_verified -eq $false) 'BASH_NOT_INTERPRETER_PROOF'
        Assert-SumiGuardTest `
            ($result.interpreter_reason_code -ceq 'HOOK_SHELL_FIELD_MISSING') `
            'CURRENT_REASON'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_status -ceq 'UNASSESSABLE') `
            'CURRENT_STATUS'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_reason_code -ceq 'UNSUPPORTED_LANGUAGE') `
            'CURRENT_ASSESSMENT_REASON'
        Assert-SumiGuardTest `
            (@($result.assessment.findings).Count -eq 0) `
            'CURRENT_FINDINGS_EMPTY'
    }

    Invoke-SumiGuardIntegrationCase -Name 'TRUSTED_EVIDENCE_DETECTS_KNOWN_RULE' -Body {
        $json = New-SumiGuardSyntheticHookJson `
            -Command 'Set-MpPreference -DisableRealtimeMonitoring $true' `
            -Shell 'powershell'
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        Assert-SumiGuardTest ($result.interpreter_verified -eq $true) 'DETECTION_VERIFIED'
        Assert-SumiGuardTest `
            ($result.interpreter_evidence_source -ceq 'TOOL_INPUT_SHELL_PLUS_LAUNCH_CONFIGURATION') `
            'DETECTION_EVIDENCE_SOURCE'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_status -ceq 'DETECTED') `
            'DETECTION_STATUS'
        Assert-SumiGuardTest `
            (@($result.assessment.findings).Count -eq 1) `
            'DETECTION_FINDING_COUNT'
        Assert-SumiGuardTest `
            ($result.assessment.findings[0].rule_id -ceq 'SG-CMD-002') `
            'DETECTION_RULE_ID'
    }

    Invoke-SumiGuardIntegrationCase -Name 'TRUSTED_EVIDENCE_NORMAL_INPUT' -Body {
        $json = New-SumiGuardSyntheticHookJson `
            -Command 'Get-ChildItem -LiteralPath . -File' `
            -Shell 'powershell.exe'
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        Assert-SumiGuardTest ($result.interpreter_verified -eq $true) 'NORMAL_VERIFIED'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_status -ceq 'NO_DETECTION') `
            'NORMAL_STATUS'
        Assert-SumiGuardTest `
            (@($result.assessment.findings).Count -eq 0) `
            'NORMAL_FINDINGS_EMPTY'
    }

    Invoke-SumiGuardIntegrationCase -Name 'UNVERIFIED_INTERPRETER_IS_UNASSESSABLE' -Body {
        $json = New-SumiGuardSyntheticHookJson `
            -Command 'Get-ChildItem' `
            -Shell 'cmd.exe'
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        Assert-SumiGuardTest ($result.interpreter_verified -eq $false) 'OTHER_SHELL_UNVERIFIED'
        Assert-SumiGuardTest `
            ($result.interpreter_reason_code -ceq 'HOOK_SHELL_VALUE_UNSUPPORTED') `
            'OTHER_SHELL_REASON'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_status -ceq 'UNASSESSABLE') `
            'OTHER_SHELL_STATUS'
    }

    Invoke-SumiGuardIntegrationCase -Name 'MISSING_COMMAND_IS_CONTENT_UNAVAILABLE' -Body {
        $json = New-SumiGuardSyntheticHookJson `
            -Command $null `
            -OmitCommand `
            -Shell 'powershell'
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        Assert-SumiGuardTest ($result.interpreter_verified -eq $true) 'MISSING_COMMAND_VERIFIED'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_status -ceq 'UNASSESSABLE') `
            'MISSING_COMMAND_STATUS'
        Assert-SumiGuardTest `
            ($result.assessment.assessment_reason_code -ceq 'CONTENT_UNAVAILABLE') `
            'MISSING_COMMAND_REASON'
    }

    Invoke-SumiGuardIntegrationCase -Name 'INVALID_JSON_IS_REJECTED' -Body {
        $result = Invoke-SumiGuardAdapterForTest -Json '{invalid'
        Assert-SumiGuardTest ($result.success -eq $false) 'INVALID_JSON_SUCCESS_FALSE'
        Assert-SumiGuardTest `
            ($result.adapter_status -ceq 'INVALID_HOOK_INPUT') `
            'INVALID_JSON_STATUS'
        Assert-SumiGuardTest ($null -eq $result.assessment) 'INVALID_JSON_NO_ASSESSMENT'
        Assert-SumiGuardTest ($null -eq $result.execution_id) 'INVALID_JSON_NO_EXECUTION_ID'
    }

    Invoke-SumiGuardIntegrationCase -Name 'EVALUATION_FAILURE_IS_DISTINCT' -Body {
        $assessmentModules = @(Get-Module -Name 'SumiGuard.CommandAssessment' -All)
        Assert-SumiGuardTest ($assessmentModules.Count -gt 0) 'ASSESSMENT_MODULE_VISIBLE'
        $assessmentModule = $assessmentModules[0]
        try {
            $assessmentModule.SessionState.PSVariable.Set(
                'SumiGuardTestForceEvaluationFailure',
                $true)
            $json = New-SumiGuardSyntheticHookJson `
                -Command 'Get-ChildItem' `
                -Shell 'powershell'
            $result = Invoke-SumiGuardAdapterForTest `
                -Json $json `
                -TrustedPath $script:CanonicalPowerShellPath
            Assert-SumiGuardTest `
                ($result.assessment.assessment_status -ceq 'EVALUATION_FAILED') `
                'EVALUATION_FAILURE_STATUS'
            Assert-SumiGuardTest `
                ($result.assessment.assessment_reason_code -ceq 'RULE_ENGINE_ERROR') `
                'EVALUATION_FAILURE_REASON'
        }
        finally {
            $assessmentModule.SessionState.PSVariable.Set(
                'SumiGuardTestForceEvaluationFailure',
                $false)
        }
    }

    Invoke-SumiGuardIntegrationCase -Name 'RESULT_OMITS_SENSITIVE_INPUT' -Body {
        $secretMarker = 'SYNTHETIC_SECRET_6f45e2'
        $urlMarker = 'https://example.invalid/download?token=SYNTHETIC_TOKEN_41'
        $pathMarker = 'C:\SyntheticPrivate\payload.ps1'
        $command = "Invoke-WebRequest -Uri '$urlMarker' -OutFile '$pathMarker'; Get-ChildItem # $secretMarker"
        $json = New-SumiGuardSyntheticHookJson `
            -Command $command `
            -Shell 'powershell'
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        $serializedResult = $result | ConvertTo-Json -Depth 12 -Compress
        Assert-SumiGuardTest `
            (-not $serializedResult.Contains($secretMarker)) `
            'SECRET_NOT_RETURNED'
        Assert-SumiGuardTest `
            (-not $serializedResult.Contains($urlMarker)) `
            'URL_NOT_RETURNED'
        Assert-SumiGuardTest `
            (-not $serializedResult.Contains($pathMarker)) `
            'PATH_NOT_RETURNED'
        Assert-SumiGuardTest `
            (-not [bool]$result.content_included) `
            'CONTENT_INCLUDED_FALSE'
        Assert-SumiGuardTest `
            (-not [bool]$result.exception_message_included) `
            'EXCEPTION_MESSAGE_INCLUDED_FALSE'
    }

    Invoke-SumiGuardIntegrationCase -Name 'EXECUTION_ID_MATCHES_EXISTING_HOOK_RULE' -Body {
        $sessionId = 'integration-session-A'
        $turnId = 'integration-turn-B'
        $toolUseId = 'integration-tool-C'
        $json = New-SumiGuardSyntheticHookJson `
            -Command 'Get-Date' `
            -Shell 'powershell' `
            -SessionId $sessionId `
            -TurnId $turnId `
            -ToolUseId $toolUseId
        $result = Invoke-SumiGuardAdapterForTest `
            -Json $json `
            -TrustedPath $script:CanonicalPowerShellPath
        $expected = Get-SumiGuardExpectedExecutionId `
            -SessionId $sessionId `
            -TurnId $turnId `
            -ToolUseId $toolUseId
        Assert-SumiGuardTest `
            ($result.execution_id -ceq $expected) `
            'EXECUTION_ID_VALUE'
        Assert-SumiGuardTest `
            ($result.assessment.execution_id -ceq $expected) `
            'ASSESSMENT_EXECUTION_ID_VALUE'
        Assert-SumiGuardTest `
            ($result.PSObject.Properties.Name -cnotcontains 'execution_status') `
            'EXECUTION_STATUS_MUST_REMAIN_SEPARATE'
    }
}
catch {
    $topLevelFailureStage = $script:CurrentAssertion
    try {
        if ($null -ne $_.Exception) {
            $topLevelExceptionType = $_.Exception.GetType().FullName
        }
    }
    catch {
        $topLevelExceptionType = $null
    }
}
finally {
    $failedCount = @($script:TestResults | Where-Object { $_.result -cne 'PASS' }).Count
    $success = ($null -eq $topLevelFailureStage -and $failedCount -eq 0)
    [pscustomobject][ordered]@{
        success = $success
        powershell_version = $PSVersionTable.PSVersion.ToString()
        test_count = $script:TestResults.Count
        passed_count = $script:TestResults.Count - $failedCount
        failed_count = $failedCount
        tests = $script:TestResults.ToArray()
        top_level_failure_stage = $topLevelFailureStage
        top_level_exception_type = $topLevelExceptionType
        hook_control_stdout_emitted = $false
        command_inputs_executed = $false
        network_access_performed = $false
        external_processes_started_by_test_data = $false
        dynamic_code_evaluation_performed = $false
        records_saved = $false
        notifications_sent = $false
    } | ConvertTo-Json -Depth 8 -Compress
    if ($success) {
        exit 0
    }
    exit 1
}
