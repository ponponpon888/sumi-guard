[CmdletBinding()]
param(
    [switch]$RunFixedCommand
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SumiGuardManagedDemoAssessmentInitialized = $false
$script:SumiGuardManagedDemoAssessmentManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'

function Get-SumiGuardManagedPowerShellDemoConfiguration {
    $fixedCommand = "Write-Output 'SUMI_GUARD_MANAGED_POWERSHELL_DEMO_OK'"
    $expectedOutput = 'SUMI_GUARD_MANAGED_POWERSHELL_DEMO_OK'
    $executablePath = Join-Path `
        ([Environment]::SystemDirectory) `
        'WindowsPowerShell\v1.0\powershell.exe'
    $argumentLine = '-Version 5.1 -NoLogo -NoProfile -NonInteractive -Command "' +
        $fixedCommand + '"'

    return [pscustomobject][ordered]@{
        executable_path = $executablePath
        required_major_version = 5
        required_minor_version = 1
        assessment_command_text = $fixedCommand
        launch_command_text = $fixedCommand
        expected_stdout_text = $expectedOutput + "`r`n"
        argument_line = $argumentLine
        timeout_milliseconds = 5000
    }
}

function New-SumiGuardManagedPowerShellStartInfo {
    $configuration = Get-SumiGuardManagedPowerShellDemoConfiguration
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $configuration.executable_path
    $startInfo.Arguments = $configuration.argument_line
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return $startInfo
}

function Initialize-SumiGuardManagedDemoAssessment {
    if ($script:SumiGuardManagedDemoAssessmentInitialized) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:SumiGuardManagedDemoAssessmentManifest -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new()
    }
    $null = Import-Module `
        -Name $script:SumiGuardManagedDemoAssessmentManifest `
        -Force `
        -ErrorAction Stop
    $script:SumiGuardManagedDemoAssessmentInitialized = $true
}

function Get-SumiGuardManagedPowerShellVerification {
    $configuration = Get-SumiGuardManagedPowerShellDemoConfiguration
    $verified = $false
    $reasonCode = 'MANAGED_WINDOWS_POWERSHELL_UNVERIFIED'
    $interpreterVersion = $null
    $fileVersion = $null
    $executableIsStandardPath = $false
    $runnerProcessIsStandardPath = $false
    $launchConfigurationVerified = $false
    $currentProcess = $null
    try {
        $expectedPath = [IO.Path]::GetFullPath($configuration.executable_path)
        $expectedDirectory = [IO.Path]::GetDirectoryName($expectedPath)
        $file = Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
        $executableIsStandardPath = (
            -not [string]::IsNullOrWhiteSpace($expectedPath) -and
            $file.FullName.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase) -and
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
        $fileVersion = [string]$file.VersionInfo.FileVersion

        $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
        $currentPath = [IO.Path]::GetFullPath($currentProcess.MainModule.FileName)
        $runnerProcessIsStandardPath = $currentPath.Equals(
            $expectedPath,
            [StringComparison]::OrdinalIgnoreCase)

        $psHomePath = [IO.Path]::GetFullPath($PSHOME)
        $psHomeMatches = $psHomePath.Equals(
            $expectedDirectory,
            [StringComparison]::OrdinalIgnoreCase)
        $editionMatches = ([string]$PSVersionTable.PSEdition -ceq 'Desktop')
        $versionMatches = (
            $PSVersionTable.PSVersion.Major -eq $configuration.required_major_version -and
            $PSVersionTable.PSVersion.Minor -eq $configuration.required_minor_version)
        $interpreterVersion = $PSVersionTable.PSVersion.ToString()

        $startInfo = New-SumiGuardManagedPowerShellStartInfo
        $launchConfigurationVerified = (
            ([IO.Path]::GetFullPath($startInfo.FileName)).Equals(
                $expectedPath,
                [StringComparison]::OrdinalIgnoreCase) -and
            $startInfo.Arguments -ceq $configuration.argument_line -and
            -not $startInfo.UseShellExecute -and
            $startInfo.RedirectStandardOutput -and
            $startInfo.RedirectStandardError -and
            $startInfo.CreateNoWindow)

        $verified = (
            $executableIsStandardPath -and
            $runnerProcessIsStandardPath -and
            $psHomeMatches -and
            $editionMatches -and
            $versionMatches -and
            -not [string]::IsNullOrWhiteSpace($fileVersion) -and
            $launchConfigurationVerified)
        if ($verified) {
            $reasonCode = 'MANAGED_WINDOWS_POWERSHELL_VERIFIED'
        }
    }
    catch {
        $verified = $false
        $reasonCode = 'MANAGED_WINDOWS_POWERSHELL_UNVERIFIED'
    }
    finally {
        if ($null -ne $currentProcess) {
            $currentProcess.Dispose()
        }
    }

    return [pscustomobject][ordered]@{
        verified = $verified
        reason_code = $reasonCode
        interpreter_version = $interpreterVersion
        executable_file_version = $fileVersion
        executable_is_standard_path = $executableIsStandardPath
        runner_process_is_standard_path = $runnerProcessIsStandardPath
        launch_configuration_verified = $launchConfigurationVerified
        evidence_source = 'MANAGED_RUNNER_PROCESS_AND_LAUNCH_CONFIGURATION'
    }
}

function New-SumiGuardManagedExecutionDecision {
    param(
        [Parameter(Mandatory = $true)][bool]$InterpreterVerified,
        [Parameter(Mandatory = $true)][bool]$CommandMatches,
        [Parameter(Mandatory = $true)][string]$AssessmentStatus,
        [AllowNull()]$AssessmentReasonCode,
        [Parameter(Mandatory = $true)][int]$FindingCount,
        [Parameter(Mandatory = $true)][bool]$RunRequested
    )

    $assessmentExpected = (
        $AssessmentStatus -ceq 'NO_DETECTION' -and
        [string]::IsNullOrEmpty([string]$AssessmentReasonCode) -and
        $FindingCount -eq 0)
    $shouldStart = (
        $RunRequested -and
        $InterpreterVerified -and
        $CommandMatches -and
        $assessmentExpected)
    $reasonCode = if (-not $RunRequested) {
        'RUN_NOT_REQUESTED'
    }
    elseif (-not $InterpreterVerified) {
        'INTERPRETER_NOT_VERIFIED'
    }
    elseif (-not $CommandMatches) {
        'COMMAND_MISMATCH'
    }
    elseif (-not $assessmentExpected) {
        'ASSESSMENT_NOT_EXPECTED'
    }
    else {
        'READY_TO_START_FIXED_COMMAND'
    }

    return [pscustomobject][ordered]@{
        assessment_expected = $assessmentExpected
        should_start = $shouldStart
        reason_code = $reasonCode
    }
}

function Invoke-SumiGuardManagedFixedCommand {
    $configuration = Get-SumiGuardManagedPowerShellDemoConfiguration
    $verification = Get-SumiGuardManagedPowerShellVerification
    if (-not $verification.verified) {
        return [pscustomobject][ordered]@{
            execution_started = $false
            execution_start_count = 0
            execution_status = 'LAUNCH_CONFIGURATION_INVALID'
            stdout_matches_expected = $null
            exit_code = $null
            stderr_nonempty = $null
            timed_out = $false
        }
    }

    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutText = $null
    $stderrText = $null
    $started = $false
    $result = $null
    try {
        $startInfo = New-SumiGuardManagedPowerShellStartInfo
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $started = $true

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($configuration.timeout_milliseconds)
        if (-not $exited) {
            $process.Kill()
            $process.WaitForExit()
        }
        else {
            $process.WaitForExit()
        }

        $stdoutText = $stdoutTask.Result
        $stderrText = $stderrTask.Result
        $result = [pscustomobject][ordered]@{
            execution_started = $true
            execution_start_count = 1
            execution_status = if ($exited -and $process.ExitCode -eq 0) {
                'SUCCEEDED'
            }
            elseif (-not $exited) {
                'TIMED_OUT'
            }
            else {
                'FAILED'
            }
            stdout_matches_expected = ($stdoutText -ceq $configuration.expected_stdout_text)
            exit_code = $process.ExitCode
            stderr_nonempty = (-not [string]::IsNullOrEmpty($stderrText))
            timed_out = (-not $exited)
        }
    }
    catch {
        $result = [pscustomobject][ordered]@{
            execution_started = $started
            execution_start_count = if ($started) { 1 } else { 0 }
            execution_status = 'START_OR_CAPTURE_FAILED'
            stdout_matches_expected = $null
            exit_code = $null
            stderr_nonempty = $null
            timed_out = $false
        }
    }
    finally {
        if ($null -ne $process) {
            try {
                if ($started -and -not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit()
                }
            }
            catch {
            }
            $process.Dispose()
        }
        $stdoutText = $null
        $stderrText = $null
        $stdoutTask = $null
        $stderrTask = $null
    }
    return $result
}

function New-SumiGuardManagedDemoFailureReport {
    param([Parameter(Mandatory = $true)][bool]$RunRequested)

    return [pscustomobject][ordered]@{
        schema_version = 1
        demo_status = 'DEMO_INTERNAL_ERROR'
        interpreter_verified = $false
        interpreter_reason_code = 'MANAGED_WINDOWS_POWERSHELL_UNVERIFIED'
        interpreter_version = $null
        executable_file_version = $null
        executable_is_standard_path = $false
        runner_process_is_standard_path = $false
        launch_configuration_verified = $false
        assessment_status = 'EVALUATION_FAILED'
        assessment_reason_code = 'RUNNER_INTERNAL_ERROR'
        assessment_finding_count = 0
        assessment_expected = $false
        assessment_command_matches_launch_command = $false
        execution_requested = $RunRequested
        execution_started = $false
        execution_start_count = 0
        execution_status = 'BLOCKED_BY_PRECONDITION'
        stdout_matches_expected = $null
        exit_code = $null
        stderr_nonempty = $null
        timed_out = $false
        raw_stdout_included = $false
        raw_stderr_included = $false
        command_text_included = $false
        exception_message_included = $false
        success = $false
    }
}

function Invoke-SumiGuardManagedPowerShellAssessmentDemo {
    param([Parameter(Mandatory = $true)][bool]$RunRequested)

    try {
        Initialize-SumiGuardManagedDemoAssessment
        $configuration = Get-SumiGuardManagedPowerShellDemoConfiguration
        $verification = Get-SumiGuardManagedPowerShellVerification
        $commandMatches = (
            $configuration.assessment_command_text -ceq
            $configuration.launch_command_text)
        $interpreterKind = if ($verification.verified) {
            'WINDOWS_POWERSHELL'
        }
        else {
            'UNKNOWN'
        }
        $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText $configuration.assessment_command_text `
            -ExecutionId '00000000000000000000000000000001' `
            -InterpreterKind $interpreterKind `
            -InterpreterVerified ([bool]$verification.verified)
        $findingCount = @($assessment.findings).Count
        $decision = New-SumiGuardManagedExecutionDecision `
            -InterpreterVerified ([bool]$verification.verified) `
            -CommandMatches $commandMatches `
            -AssessmentStatus ([string]$assessment.assessment_status) `
            -AssessmentReasonCode $assessment.assessment_reason_code `
            -FindingCount $findingCount `
            -RunRequested $RunRequested

        $execution = if ($decision.should_start) {
            Invoke-SumiGuardManagedFixedCommand
        }
        else {
            [pscustomobject][ordered]@{
                execution_started = $false
                execution_start_count = 0
                execution_status = if ($RunRequested) {
                    'BLOCKED_BY_PRECONDITION'
                }
                else {
                    'NOT_REQUESTED'
                }
                stdout_matches_expected = $null
                exit_code = $null
                stderr_nonempty = $null
                timed_out = $false
            }
        }

        $success = if ($RunRequested) {
            ($decision.should_start -and
                $execution.execution_status -ceq 'SUCCEEDED' -and
                $execution.stdout_matches_expected -eq $true -and
                $execution.exit_code -eq 0 -and
                $execution.stderr_nonempty -eq $false -and
                $execution.timed_out -eq $false)
        }
        else {
            ($verification.verified -and
                $decision.assessment_expected -and
                $commandMatches -and
                -not $execution.execution_started)
        }
        $demoStatus = if ($RunRequested -and $success) {
            'COMPLETED'
        }
        elseif (-not $RunRequested -and $success) {
            'READY_NOT_RUN'
        }
        elseif ($RunRequested -and -not $decision.should_start) {
            'PRECONDITION_BLOCKED'
        }
        else {
            'EXECUTION_FAILED'
        }

        return [pscustomobject][ordered]@{
            schema_version = 1
            demo_status = $demoStatus
            interpreter_verified = [bool]$verification.verified
            interpreter_reason_code = [string]$verification.reason_code
            interpreter_version = $verification.interpreter_version
            executable_file_version = $verification.executable_file_version
            executable_is_standard_path = [bool]$verification.executable_is_standard_path
            runner_process_is_standard_path = [bool]$verification.runner_process_is_standard_path
            launch_configuration_verified = [bool]$verification.launch_configuration_verified
            assessment_status = [string]$assessment.assessment_status
            assessment_reason_code = $assessment.assessment_reason_code
            assessment_finding_count = $findingCount
            assessment_expected = [bool]$decision.assessment_expected
            assessment_command_matches_launch_command = $commandMatches
            execution_requested = $RunRequested
            execution_started = [bool]$execution.execution_started
            execution_start_count = [int]$execution.execution_start_count
            execution_status = [string]$execution.execution_status
            stdout_matches_expected = $execution.stdout_matches_expected
            exit_code = $execution.exit_code
            stderr_nonempty = $execution.stderr_nonempty
            timed_out = [bool]$execution.timed_out
            raw_stdout_included = $false
            raw_stderr_included = $false
            command_text_included = $false
            exception_message_included = $false
            success = $success
        }
    }
    catch {
        return New-SumiGuardManagedDemoFailureReport -RunRequested $RunRequested
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    $report = Invoke-SumiGuardManagedPowerShellAssessmentDemo `
        -RunRequested ([bool]$RunFixedCommand)
    $report | ConvertTo-Json -Depth 6 -Compress
    if ($report.success) {
        exit 0
    }
    exit 1
}
