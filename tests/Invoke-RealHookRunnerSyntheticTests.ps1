[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Stage = 'INITIALIZATION'
$rows = New-Object System.Collections.ArrayList
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-quote-test-' + [Guid]::NewGuid().ToString('N'))
$receiverPath = Join-Path $tempRoot 'receive.ps1'
$runnerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'kit\sumi-guard-real-hook-assessment-check\Invoke-SumiGuardRealHookAssessmentCheck.ps1'
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process = $null
$exitCode = $null
$failureType = $null
$failureHResult = $null

function Add-Result([string]$Name, [bool]$Pass) {
    [void]$rows.Add([pscustomobject]@{ name = $Name; pass = $Pass })
}

function Invoke-ReceiverCase([string]$Name, [string]$Value) {
    $receiverProcess = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShellPath
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $receiverPath, $Value)
        $startInfo.Arguments = (($arguments | ForEach-Object { Quote ([string]$_) }) -join ' ')
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $receiverProcess = New-Object Diagnostics.Process
        $receiverProcess.StartInfo = $startInfo
        if (-not $receiverProcess.Start()) { throw [InvalidOperationException]::new() }

        $stdoutTask = $receiverProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $receiverProcess.StandardError.ReadToEndAsync()
        $receiverProcess.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $childExitCode = $receiverProcess.ExitCode
        $receiverProcess.Dispose()
        $receiverProcess = $null

        $parsed = $null
        $jsonValid = $true
        try { $parsed = ConvertFrom-Json -InputObject $stdout -ErrorAction Stop } catch { $jsonValid = $false }
        $received = @($parsed)
        [pscustomobject]@{
            Name = $Name
            ExitCode = $childExitCode
            JsonValid = $jsonValid
            CountMatches = ($jsonValid -and $received.Count -eq 1)
            ValueMatches = ($jsonValid -and $received.Count -eq 1 -and $received[0] -ceq $Value)
        }
    } finally {
        if ($null -ne $receiverProcess) {
            if (-not $receiverProcess.HasExited) { $receiverProcess.Kill() }
            $receiverProcess.Dispose()
        }
        $stdout = ''
        $stderr = ''
    }
}

try {
    $script:Stage = 'DOT_SOURCE'
    . $runnerPath
    $script:Stage = 'CREATE_RECEIVER'
    New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop | Out-Null
    $receiver = @'
$items = New-Object System.Collections.ArrayList
foreach ($item in $args) {
    [void]$items.Add([string]$item)
}
ConvertTo-Json -InputObject $items -Compress
'@
    [IO.File]::WriteAllText($receiverPath, $receiver, (New-Object Text.UTF8Encoding($true, $true)))
    $receiverTokens = $null
    $receiverParseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $receiverPath,
        [ref]$receiverTokens,
        [ref]$receiverParseErrors
    )
    $receiverParseErrorCount = if ($null -eq $receiverParseErrors) { 0 } else { $receiverParseErrors.Count }
    Add-Result 'RECEIVER_PARSE_ZERO' ($receiverParseErrorCount -eq 0)
    if ($receiverParseErrorCount -ne 0) { throw [InvalidOperationException]::new() }
    $cases = @(
        [pscustomobject]@{ Name = 'EMPTY_ARGUMENT'; Value = '' }
        [pscustomobject]@{ Name = 'SPACE_ARGUMENT'; Value = 'with space' }
        [pscustomobject]@{ Name = 'JAPANESE_ARGUMENT'; Value = '日本語' }
        [pscustomobject]@{ Name = 'QUOTE_ARGUMENT'; Value = 'quote " value' }
        [pscustomobject]@{ Name = 'TRAILING_BACKSLASH_ARGUMENT'; Value = 'C:\tail\' }
        [pscustomobject]@{ Name = 'HOOK_TOML_ARGUMENT'; Value = "[{matcher='^Bash$',hooks=[{type='command',command='x y',command_windows='x y',timeout=20}]}]" }
    )
    foreach ($case in $cases) {
        $script:Stage = 'START_RECEIVER'
        $caseResult = Invoke-ReceiverCase -Name $case.Name -Value $case.Value
        $exitCode = $caseResult.ExitCode
        $script:Stage = 'COMPARE'
        Add-Result ($case.Name + '_EXIT_ZERO') ($caseResult.ExitCode -eq 0)
        Add-Result ($case.Name + '_JSON_VALID') $caseResult.JsonValid
        Add-Result ($case.Name + '_COUNT') $caseResult.CountMatches
        Add-Result $case.Name $caseResult.ValueMatches
    }

    $script:Stage = 'SUMMARY_SYNTHETIC'
    $expectedCommand = 'Write-Output SUMI_GUARD_REAL_HOOK_OK'
    $expectedOutput = 'SUMI_GUARD_REAL_HOOK_OK'
    $newline = [Environment]::NewLine
    $normalEvent = ([ordered]@{ item = [ordered]@{ type = 'assistant_message' } } | ConvertTo-Json -Compress)
    $startEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'same-id' } } | ConvertTo-Json -Compress)
    $completedEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'same-id'; command = $expectedCommand; aggregated_output = $expectedOutput } } | ConvertTo-Json -Compress)
    $sameIdSummary = Summary (($normalEvent, $startEvent, $completedEvent) -join $newline)
    Add-Result 'SUMMARY_NORMAL_NONCOMMAND_EVENT_ALLOWED' $sameIdSummary.valid
    Add-Result 'SUMMARY_SAME_ID_START_COMPLETE_ONE' ($sameIdSummary.valid -and $sameIdSummary.count -eq 1 -and $sameIdSummary.command -and $sameIdSummary.output)

    $otherCompletedEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'other-id'; command = $expectedCommand; aggregated_output = $expectedOutput } } | ConvertTo-Json -Compress)
    $separateIdSummary = Summary (($completedEvent, $otherCompletedEvent) -join $newline)
    Add-Result 'SUMMARY_SEPARATE_IDS_COUNT_SEPARATELY' ($separateIdSummary.valid -and $separateIdSummary.count -eq 2)

    $malformedSummary = Summary (($completedEvent, '{not-json') -join $newline)
    Add-Result 'SUMMARY_MALFORMED_JSON_NOT_SUCCESS' (-not $malformedSummary.valid)

    $missingPropertyEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution' } } | ConvertTo-Json -Compress)
    $missingPropertySummary = Summary $missingPropertyEvent
    Add-Result 'SUMMARY_MISSING_PROPERTY_NOT_SUCCESS' (-not $missingPropertySummary.valid)

    $partialCommandEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'partial-id'; command = ($expectedCommand + ' extra'); aggregated_output = $expectedOutput } } | ConvertTo-Json -Compress)
    $partialCommandSummary = Summary $partialCommandEvent
    Add-Result 'SUMMARY_PARTIAL_COMMAND_NOT_SUCCESS' (-not $partialCommandSummary.command -and -not $partialCommandSummary.output)

    $commandOnlyMatchEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'command-id'; command = $expectedCommand; aggregated_output = 'different-output' } } | ConvertTo-Json -Compress)
    $outputOnlyMatchEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'output-id'; command = 'different-command'; aggregated_output = $expectedOutput } } | ConvertTo-Json -Compress)
    $splitRecordSummary = Summary (($commandOnlyMatchEvent, $outputOnlyMatchEvent) -join $newline)
    Add-Result 'SUMMARY_SPLIT_RECORD_MATCH_NOT_SUCCESS' (-not $splitRecordSummary.command -and -not $splitRecordSummary.output)

    $outputMismatchEvent = ([ordered]@{ item = [ordered]@{ type = 'command_execution'; id = 'output-mismatch'; command = $expectedCommand; aggregated_output = 'different-output' } } | ConvertTo-Json -Compress)
    $outputMismatchSummary = Summary $outputMismatchEvent
    Add-Result 'SUMMARY_OUTPUT_MISMATCH_NOT_SUCCESS' (-not $outputMismatchSummary.command -and -not $outputMismatchSummary.output)

    $eventData = [pscustomobject]@{ assessment_status = 'UNASSESSABLE'; response_generated = $true }
    Add-Result 'OVERALL_VALID_INPUT_SUCCESS' (Test-SumiGuardRealHookAssessmentResult -CodexStarted 1 -CodexExitCode 0 -TimedOut $false -SummaryResult $sameIdSummary -EventData $eventData).success
    Add-Result 'OVERALL_NONZERO_EXIT_NOT_SUCCESS' (-not (Test-SumiGuardRealHookAssessmentResult -CodexStarted 1 -CodexExitCode 3 -TimedOut $false -SummaryResult $sameIdSummary -EventData $eventData).success)
    Add-Result 'OVERALL_TIMEOUT_NOT_SUCCESS' (-not (Test-SumiGuardRealHookAssessmentResult -CodexStarted 1 -CodexExitCode 0 -TimedOut $true -SummaryResult $sameIdSummary -EventData $eventData).success)
    Add-Result 'OVERALL_EVENT_MISSING_NOT_SUCCESS' (-not (Test-SumiGuardRealHookAssessmentResult -CodexStarted 1 -CodexExitCode 0 -TimedOut $false -SummaryResult $sameIdSummary -EventData $null).success)

    $script:Stage = 'HOOK_MARKER_STATIC'
    $hookPath = Join-Path (Split-Path -Parent $runnerPath) 'sumi-guard-real-hook-assessment.ps1'
    $hookSource = [IO.File]::ReadAllText($hookPath, (New-Object Text.UTF8Encoding($false, $true)))
    $processStartedIndex = $hookSource.IndexOf("`$stages.Add('HOOK_PROCESS_STARTED')")
    $stageListIndex = $hookSource.IndexOf('New-Object System.Collections.Generic.List[string]')
    $jsonParsedIndex = $hookSource.IndexOf("`$stages.Add('HOOK_JSON_PARSED')")
    $inputParseIndex = $hookSource.IndexOf('ConvertFrom-Json -ErrorAction Stop')
    $evaluationIndex = $hookSource.IndexOf("`$stages.Add('HOOK_EVALUATION_COMPLETED')")
    $assessmentIndex = $hookSource.IndexOf('Invoke-SumiGuardCommandAssessment')
    $responseIndex = $hookSource.IndexOf("`$stages.Add('HOOK_RESPONSE_EMITTED')")
    $responseWriteIndex = $hookSource.IndexOf('[Console]::Out.WriteLine')
    $responseFlushIndex = $hookSource.IndexOf('[Console]::Out.Flush()')
    $eventWriteIndex = $hookSource.IndexOf('[IO.File]::WriteAllText($eventPath')
    Add-Result 'HOOK_PROCESS_MARKER_AFTER_STAGE_LIST_CREATED' ($processStartedIndex -gt $stageListIndex)
    Add-Result 'HOOK_JSON_MARKER_AFTER_PARSE' ($jsonParsedIndex -gt $inputParseIndex)
    Add-Result 'HOOK_EVALUATION_MARKER_AFTER_EVALUATION' ($evaluationIndex -gt $assessmentIndex)
    Add-Result 'HOOK_RESPONSE_MARKER_AFTER_RESPONSE_OUTPUT' ($responseIndex -gt $responseWriteIndex -and $responseIndex -gt $responseFlushIndex)
    Add-Result 'HOOK_EVENT_AFTER_RESPONSE_MARKER' ($eventWriteIndex -gt $responseIndex)
} catch {
    $failureType = $_.Exception.GetType().FullName
    $failureHResult = $_.Exception.HResult
    Add-Result ('FAIL_' + $script:Stage) $false
} finally {
    $stdout = ''
    $stderr = ''
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
$failed = @($rows | Where-Object { -not $_.pass }).Count
[pscustomobject]@{
    success = ($failed -eq 0)
    test_count = $rows.Count
    passed_count = $rows.Count - $failed
    failed_count = $failed
    receiver_exit_code = $exitCode
    failure_stage = $script:Stage
    failure_exception_type = $failureType
    failure_hresult = $failureHResult
    child_codex_started = 0
    temporary_residual_count = 0
    results = @($rows)
} | ConvertTo-Json -Compress -Depth 4
if ($failed -gt 0) { exit 1 }
