Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ManagedDemoCurrentAssertion = 'INITIALIZATION'
$script:ManagedDemoTestResults = New-Object System.Collections.Generic.List[object]
$script:ManagedDemoRunnerPath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'demo\Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1'

function Assert-SumiGuardManagedDemoTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )

    $script:ManagedDemoCurrentAssertion = $Code
    if (-not $Condition) {
        throw [System.InvalidOperationException]::new()
    }
}

function Invoke-SumiGuardManagedDemoTestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:ManagedDemoCurrentAssertion = 'CASE_START'
    try {
        & $Body
        $script:ManagedDemoTestResults.Add([pscustomobject][ordered]@{
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
        $script:ManagedDemoTestResults.Add([pscustomobject][ordered]@{
            name = $Name
            result = 'FAIL'
            failure_stage = $script:ManagedDemoCurrentAssertion
            exception_type = $exceptionType
        })
    }
}

$topLevelFailureStage = $null
$topLevelExceptionType = $null
try {
    $script:ManagedDemoCurrentAssertion = 'LOAD_RUNNER_FUNCTIONS'
    . $script:ManagedDemoRunnerPath

    $script:ManagedDemoCurrentAssertion = 'PARSE_RUNNER'
    $tokens = $null
    $parseErrors = $null
    $runnerAst = [Management.Automation.Language.Parser]::ParseFile(
        $script:ManagedDemoRunnerPath,
        [ref]$tokens,
        [ref]$parseErrors)
    Assert-SumiGuardManagedDemoTest `
        (@($parseErrors).Count -eq 0) `
        'RUNNER_PARSE_ERRORS'

    Invoke-SumiGuardManagedDemoTestCase -Name 'RUNNER_ACCEPTS_ONLY_RUN_SWITCH' -Body {
        $parameterNames = @(
            $runnerAst.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-SumiGuardManagedDemoTest `
            ($parameterNames.Count -eq 1) `
            'RUNNER_PARAMETER_COUNT'
        Assert-SumiGuardManagedDemoTest `
            ($parameterNames[0] -ceq 'RunFixedCommand') `
            'RUNNER_PARAMETER_NAME'

        $fixedExecutionFunctions = @($runnerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Invoke-SumiGuardManagedFixedCommand'
        }, $true))
        Assert-SumiGuardManagedDemoTest `
            ($fixedExecutionFunctions.Count -eq 1) `
            'FIXED_EXECUTION_FUNCTION_COUNT'
        Assert-SumiGuardManagedDemoTest `
            ($null -eq $fixedExecutionFunctions[0].Parameters) `
            'FIXED_EXECUTION_FUNCTION_PARAMETERS'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'MANAGED_HOST_AND_LAUNCH_ARE_VERIFIED' -Body {
        $verification = Get-SumiGuardManagedPowerShellVerification
        Assert-SumiGuardManagedDemoTest `
            ($verification.verified -eq $true) `
            'MANAGED_HOST_VERIFIED'
        Assert-SumiGuardManagedDemoTest `
            ($verification.reason_code -ceq 'MANAGED_WINDOWS_POWERSHELL_VERIFIED') `
            'MANAGED_HOST_REASON'
        Assert-SumiGuardManagedDemoTest `
            ($verification.interpreter_version.StartsWith('5.1.')) `
            'MANAGED_HOST_VERSION'
        Assert-SumiGuardManagedDemoTest `
            (-not [string]::IsNullOrWhiteSpace($verification.executable_file_version)) `
            'MANAGED_EXECUTABLE_FILE_VERSION'
        Assert-SumiGuardManagedDemoTest `
            ($verification.executable_is_standard_path -eq $true) `
            'MANAGED_EXECUTABLE_PATH'
        Assert-SumiGuardManagedDemoTest `
            ($verification.runner_process_is_standard_path -eq $true) `
            'MANAGED_RUNNER_PROCESS_PATH'
        Assert-SumiGuardManagedDemoTest `
            ($verification.launch_configuration_verified -eq $true) `
            'MANAGED_LAUNCH_CONFIGURATION'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'FIXED_COMMAND_IS_ASSESSED_WITHOUT_EXECUTION' -Body {
        $report = Invoke-SumiGuardManagedPowerShellAssessmentDemo -RunRequested $false
        Assert-SumiGuardManagedDemoTest ($report.success -eq $true) 'DRY_REPORT_SUCCESS'
        Assert-SumiGuardManagedDemoTest `
            ($report.demo_status -ceq 'READY_NOT_RUN') `
            'DRY_DEMO_STATUS'
        Assert-SumiGuardManagedDemoTest `
            ($report.assessment_status -ceq 'NO_DETECTION') `
            'DRY_ASSESSMENT_STATUS'
        Assert-SumiGuardManagedDemoTest `
            ($report.assessment_expected -eq $true) `
            'DRY_ASSESSMENT_EXPECTED'
        Assert-SumiGuardManagedDemoTest `
            ($report.assessment_command_matches_launch_command -eq $true) `
            'DRY_COMMAND_MATCH'
        Assert-SumiGuardManagedDemoTest `
            ($report.execution_started -eq $false) `
            'DRY_EXECUTION_NOT_STARTED'
        Assert-SumiGuardManagedDemoTest `
            ($report.execution_start_count -eq 0) `
            'DRY_EXECUTION_COUNT'
        Assert-SumiGuardManagedDemoTest `
            ($report.execution_status -ceq 'NOT_REQUESTED') `
            'DRY_EXECUTION_STATUS'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'EXPECTED_STATE_GATE_IS_EXACT' -Body {
        $ready = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $true `
            -CommandMatches $true `
            -AssessmentStatus 'NO_DETECTION' `
            -AssessmentReasonCode $null `
            -FindingCount 0 `
            -RunRequested $true
        Assert-SumiGuardManagedDemoTest ($ready.should_start -eq $true) 'READY_GATE'

        $detected = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $true `
            -CommandMatches $true `
            -AssessmentStatus 'DETECTED' `
            -AssessmentReasonCode $null `
            -FindingCount 1 `
            -RunRequested $true
        Assert-SumiGuardManagedDemoTest `
            ($detected.should_start -eq $false) `
            'DETECTED_GATE'

        $notRequested = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $true `
            -CommandMatches $true `
            -AssessmentStatus 'NO_DETECTION' `
            -AssessmentReasonCode $null `
            -FindingCount 0 `
            -RunRequested $false
        Assert-SumiGuardManagedDemoTest `
            ($notRequested.should_start -eq $false) `
            'EXPLICIT_SWITCH_GATE'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'SUSPICIOUS_SYNTHETIC_INPUT_IS_ASSESSMENT_ONLY' -Body {
        Initialize-SumiGuardManagedDemoAssessment
        $suspiciousText = 'Set-MpPreference -DisableRealtimeMonitoring $true'
        $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText $suspiciousText `
            -ExecutionId '00000000000000000000000000000002' `
            -InterpreterKind 'WINDOWS_POWERSHELL' `
            -InterpreterVerified $true
        Assert-SumiGuardManagedDemoTest `
            ($assessment.assessment_status -ceq 'DETECTED') `
            'SUSPICIOUS_ASSESSMENT_STATUS'
        Assert-SumiGuardManagedDemoTest `
            ($assessment.findings[0].rule_id -ceq 'SG-CMD-002') `
            'SUSPICIOUS_RULE_ID'
        $decision = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $true `
            -CommandMatches $false `
            -AssessmentStatus ([string]$assessment.assessment_status) `
            -AssessmentReasonCode $assessment.assessment_reason_code `
            -FindingCount @($assessment.findings).Count `
            -RunRequested $true
        Assert-SumiGuardManagedDemoTest `
            ($decision.should_start -eq $false) `
            'SUSPICIOUS_NOT_EXECUTABLE'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'UNASSESSABLE_INPUT_CANNOT_START' -Body {
        Initialize-SumiGuardManagedDemoAssessment
        $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText 'Get-ChildItem' `
            -ExecutionId '00000000000000000000000000000003' `
            -InterpreterKind 'UNKNOWN' `
            -InterpreterVerified $false
        Assert-SumiGuardManagedDemoTest `
            ($assessment.assessment_status -ceq 'UNASSESSABLE') `
            'UNASSESSABLE_STATUS'
        $decision = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $false `
            -CommandMatches $true `
            -AssessmentStatus ([string]$assessment.assessment_status) `
            -AssessmentReasonCode $assessment.assessment_reason_code `
            -FindingCount @($assessment.findings).Count `
            -RunRequested $true
        Assert-SumiGuardManagedDemoTest `
            ($decision.should_start -eq $false) `
            'UNASSESSABLE_NOT_EXECUTABLE'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'EVALUATION_FAILURE_CANNOT_START' -Body {
        Initialize-SumiGuardManagedDemoAssessment
        $assessmentModules = @(Get-Module -Name 'SumiGuard.CommandAssessment' -All)
        Assert-SumiGuardManagedDemoTest `
            ($assessmentModules.Count -gt 0) `
            'ASSESSMENT_MODULE_VISIBLE'
        $assessmentModule = $assessmentModules[0]
        try {
            $assessmentModule.SessionState.PSVariable.Set(
                'SumiGuardTestForceEvaluationFailure',
                $true)
            $report = Invoke-SumiGuardManagedPowerShellAssessmentDemo -RunRequested $true
            Assert-SumiGuardManagedDemoTest `
                ($report.assessment_status -ceq 'EVALUATION_FAILED') `
                'FAILURE_ASSESSMENT_STATUS'
            Assert-SumiGuardManagedDemoTest `
                ($report.execution_started -eq $false) `
                'FAILURE_EXECUTION_NOT_STARTED'
            Assert-SumiGuardManagedDemoTest `
                ($report.execution_start_count -eq 0) `
                'FAILURE_EXECUTION_COUNT'
            Assert-SumiGuardManagedDemoTest `
                ($report.execution_status -ceq 'BLOCKED_BY_PRECONDITION') `
                'FAILURE_EXECUTION_STATUS'
        }
        finally {
            $assessmentModule.SessionState.PSVariable.Set(
                'SumiGuardTestForceEvaluationFailure',
                $false)
        }
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'COMMAND_MISMATCH_CANNOT_START' -Body {
        $decision = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified $true `
            -CommandMatches $false `
            -AssessmentStatus 'NO_DETECTION' `
            -AssessmentReasonCode $null `
            -FindingCount 0 `
            -RunRequested $true
        Assert-SumiGuardManagedDemoTest `
            ($decision.should_start -eq $false) `
            'MISMATCH_NOT_EXECUTABLE'
        Assert-SumiGuardManagedDemoTest `
            ($decision.reason_code -ceq 'COMMAND_MISMATCH') `
            'MISMATCH_REASON'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'PARALLEL_CAPTURE_AND_TIMEOUT_CLEANUP_EXIST' -Body {
        $memberCalls = @($runnerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
        }, $true))
        $readCalls = @($memberCalls | Where-Object {
            $_.Member.Value -ceq 'ReadToEndAsync'
        })
        $waitCalls = @($memberCalls | Where-Object {
            $_.Member.Value -ceq 'WaitForExit'
        } | Sort-Object { $_.Extent.StartOffset })
        $killCalls = @($memberCalls | Where-Object {
            $_.Member.Value -ceq 'Kill'
        })
        Assert-SumiGuardManagedDemoTest `
            ($readCalls.Count -eq 2) `
            'PARALLEL_READ_CALL_COUNT'
        Assert-SumiGuardManagedDemoTest `
            ($waitCalls.Count -ge 1) `
            'WAIT_CALL_EXISTS'
        $lastReadOffset = @(
            $readCalls |
                ForEach-Object { $_.Extent.StartOffset } |
                Measure-Object -Maximum)[0].Maximum
        Assert-SumiGuardManagedDemoTest `
            ($lastReadOffset -lt $waitCalls[0].Extent.StartOffset) `
            'READS_START_BEFORE_WAIT'
        Assert-SumiGuardManagedDemoTest `
            ($killCalls.Count -ge 2) `
            'TIMEOUT_AND_FINALLY_KILL_CALLS'
    }

    Invoke-SumiGuardManagedDemoTestCase -Name 'REPORT_OMITS_COMMAND_AND_RAW_STREAMS' -Body {
        $report = Invoke-SumiGuardManagedPowerShellAssessmentDemo -RunRequested $false
        $serialized = $report | ConvertTo-Json -Depth 8 -Compress
        Assert-SumiGuardManagedDemoTest `
            (-not $serialized.Contains('Write-Output')) `
            'COMMAND_NOT_RETURNED'
        Assert-SumiGuardManagedDemoTest `
            (-not $serialized.Contains('SUMI_GUARD_MANAGED_POWERSHELL_DEMO_OK')) `
            'FIXED_OUTPUT_NOT_RETURNED'
        Assert-SumiGuardManagedDemoTest `
            ($report.raw_stdout_included -eq $false) `
            'RAW_STDOUT_NOT_INCLUDED'
        Assert-SumiGuardManagedDemoTest `
            ($report.raw_stderr_included -eq $false) `
            'RAW_STDERR_NOT_INCLUDED'
        Assert-SumiGuardManagedDemoTest `
            ($report.command_text_included -eq $false) `
            'COMMAND_TEXT_NOT_INCLUDED'
        Assert-SumiGuardManagedDemoTest `
            ($report.exception_message_included -eq $false) `
            'EXCEPTION_MESSAGE_NOT_INCLUDED'
        Assert-SumiGuardManagedDemoTest `
            ($report.PSObject.Properties.Name -ccontains 'assessment_status') `
            'ASSESSMENT_STATUS_PRESENT'
        Assert-SumiGuardManagedDemoTest `
            ($report.PSObject.Properties.Name -ccontains 'execution_status') `
            'EXECUTION_STATUS_PRESENT'
    }
}
catch {
    $topLevelFailureStage = $script:ManagedDemoCurrentAssertion
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
    $failedCount = @(
        $script:ManagedDemoTestResults |
            Where-Object { $_.result -cne 'PASS' }).Count
    $success = ($null -eq $topLevelFailureStage -and $failedCount -eq 0)
    [pscustomobject][ordered]@{
        success = $success
        powershell_version = $PSVersionTable.PSVersion.ToString()
        test_count = $script:ManagedDemoTestResults.Count
        passed_count = $script:ManagedDemoTestResults.Count - $failedCount
        failed_count = $failedCount
        tests = $script:ManagedDemoTestResults.ToArray()
        top_level_failure_stage = $topLevelFailureStage
        top_level_exception_type = $topLevelExceptionType
        managed_child_start_count = 0
        suspicious_inputs_executed = $false
        raw_streams_emitted = $false
        records_saved = $false
        network_access_performed = $false
    } | ConvertTo-Json -Depth 8 -Compress
    if ($success) {
        exit 0
    }
    exit 1
}
