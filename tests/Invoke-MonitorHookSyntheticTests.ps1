<#
    Synthetic tests for hooks/Invoke-SumiGuardMonitorHook.ps1.

    Every input is fixed string data passed to the hook as hook-event JSON. No
    input is executed: the hook is started as a child Windows PowerShell 5.1
    process with -File, and the command strings inside the events never reach a
    shell, the call operator, Invoke-Expression or Start-Process. The body store
    is not touched; -TestIntentSaveOutcome stands in for the adapter because its
    protection is DPAPI CurrentUser.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hookPath = Join-Path $projectRoot 'hooks\Invoke-SumiGuardMonitorHook.ps1'
$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$canary = 'SYNTHETIC_SECRET_CANARY_7f3a'
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$childStartCount = 0
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-monitor-hook-' + [Guid]::NewGuid().ToString('N'))

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        # Fixed status and reason codes only, so a failure says what it saw
        # without copying command text into the test output.
        [AllowNull()][hashtable]$Observed
    )

    $row = [ordered]@{ name = $Name; pass = $Pass }
    if ($null -ne $Observed) {
        $row['observed'] = [pscustomobject]$Observed
    }
    $results.Add([pscustomobject]$row)
}

function Get-ObservedDiagnostic {
    param([Parameter(Mandatory = $true)]$Run)

    $detail = $Run.detail
    if ($null -eq $detail) {
        return @{ detail_present = $false }
    }

    $ruleIds = @()
    $reasonCode = $null
    if ($null -ne $detail.assessment) {
        $ruleIds = @(@($detail.assessment.findings) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.rule_id })
        $reasonCode = [string]$detail.assessment.assessment_reason_code
    }

    return @{
        detail_present = $true
        hook_status = [string]$detail.hook_status
        assessment_status = [string]$detail.assessment_status
        assessment_reason_code = $reasonCode
        rule_ids = $ruleIds
        findings_count = $ruleIds.Count
        assessment_storage_status = [string]$detail.assessment_storage_status
        intent_storage_status = [string]$detail.intent_storage_status
        notice_status = [string]$detail.notice_status
        interpreter_verified = [bool]$detail.interpreter_verified
        interpreter_reason_code = [string]$detail.interpreter_reason_code
        exit_code = $Run.exit_code
    }
}

function Get-HookEventJson {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [string]$ToolUseId = 'tool-use-1',
        [string]$HookEventName = 'PreToolUse',
        [string]$ToolName = 'Bash'
    )

    return ([ordered]@{
        hook_event_name = $HookEventName
        tool_name = $ToolName
        session_id = 'synthetic-session'
        turn_id = 'synthetic-turn'
        tool_use_id = $ToolUseId
        tool_input = [ordered]@{ command = $Command }
    } | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EventJson,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [switch]$TrustedRoute,
        [string]$IntentOutcome = 'TEST_SUCCESS',
        [switch]$ForceEvaluationFailure,
        [switch]$ForceAssessmentSaveFailure
    )

    $caseRoot = Join-Path $workRoot $CaseName
    $assessmentStorePath = Join-Path $caseRoot 'assessment-store'
    $noticePath = Join-Path $caseRoot 'notices\monitor-hook-notices.ndjson'
    $resultPath = Join-Path $caseRoot 'result.json'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force

    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    $created = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    if (-not $created.success) {
        throw [System.InvalidOperationException]::new('assessment store setup failed')
    }

    # The event goes in over standard input, which is how a hook host delivers
    # it. It is not passed as -RawHookInputJson here: Windows PowerShell 5.1
    # does not reliably preserve a JSON argument across a native command
    # boundary, and a mangled argument reaches the hook as an unreadable event
    # rather than as an error.
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $hookPath,
        '-ExecutionStorePath', (Join-Path $caseRoot 'execution-store'),
        '-LocalStorePath', (Join-Path $caseRoot 'body-store'),
        '-AssessmentStorePath', $assessmentStorePath,
        '-NoticePath', $noticePath,
        '-ResultPath', $resultPath,
        '-TestIntentSaveOutcome', $IntentOutcome)
    if ($TrustedRoute) { $arguments += '-TrustedWindowsPowerShellRoute' }
    if ($ForceEvaluationFailure) { $arguments += '-TestForceEvaluationFailure' }
    if ($ForceAssessmentSaveFailure) { $arguments += '-TestForceAssessmentSaveFailure' }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = $EventJson | & $powerShell51 @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $script:childStartCount++

    $stdoutText = ($stdout | Out-String)
    $detail = $null
    if (Test-Path -LiteralPath $resultPath) {
        $detail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $storeText = ''
    $storeFile = Join-Path $assessmentStorePath 'assessments.ndjson'
    if (Test-Path -LiteralPath $storeFile) {
        $storeText = Get-Content -LiteralPath $storeFile -Raw -Encoding UTF8
    }

    $noticeText = ''
    if (Test-Path -LiteralPath $noticePath) {
        $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
    }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        stdout_text = $stdoutText
        detail = $detail
        store_text = $storeText
        notice_text = $noticeText
        assessment_store_path = $assessmentStorePath
    }
}

function Test-MonitorOnlyResponse {
    param([Parameter(Mandatory = $true)]$Run)

    if ($Run.exit_code -ne 0) { return $false }

    $response = $null
    try { $response = $Run.stdout_text | ConvertFrom-Json } catch { return $false }
    if ($null -eq $response) { return $false }

    $names = @($response.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -cne 'systemMessage') { return $false }

    $lowered = $Run.stdout_text.ToLowerInvariant()
    foreach ($word in @('"deny"', 'permissiondecision', 'block')) {
        if ($lowered.Contains($word)) { return $false }
    }

    if ($null -eq $Run.detail) { return $false }
    return ((-not [bool]$Run.detail.automatic_deny) -and ([string]$Run.detail.monitor_action -ceq 'WARN_ONLY'))
}

try {
    $null = New-Item -ItemType Directory -Path $workRoot -Force

    # The hook is the thing under test, so its own source is checked for the
    # ways a command string could reach execution.
    $hookSource = Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8
    $forbidden = @('Invoke-Expression', 'Start-Process', 'iex ', '& $commandText', '. $commandText')
    $sourceClean = $true
    foreach ($pattern in $forbidden) {
        if ($hookSource.Contains($pattern)) { $sourceClean = $false }
    }
    Add-Result 'HOOK_SOURCE_NEVER_EXECUTES_COMMAND_TEXT' $sourceClean

    # Detection on a trusted route.
    $detected = Invoke-Hook -CaseName 'detected' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command 'Set-MpPreference -DisableRealtimeMonitoring $true')
    $detectedDiagnostic = Get-ObservedDiagnostic -Run $detected
    Add-Result 'TRUSTED_ROUTE_DETECTED' (
        [string]$detected.detail.assessment_status -ceq 'DETECTED' -and
        [string]$detected.detail.assessment_storage_status -ceq 'SAVED' -and
        [string]$detected.detail.intent_storage_status -ceq 'TEST_DOUBLE_SAVED' -and
        [bool]$detected.detail.interpreter_verified -and
        $detectedDiagnostic.findings_count -eq 1 -and
        @($detectedDiagnostic.rule_ids) -ccontains 'SG-CMD-002') -Observed $detectedDiagnostic
    Add-Result 'DETECTED_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $detected) -Observed $detectedDiagnostic
    Add-Result 'DETECTED_RECORD_LINKED_TO_EXECUTION_ID' (
        $detected.store_text.Contains([string]$detected.detail.execution_id) -and
        [string]$detected.detail.evaluation_origin -ceq 'MANAGED_EXECUTION') -Observed $detectedDiagnostic

    # The same detection with a canary appended as a comment. A comment is not a
    # call, so the state stays the same, and the canary must not reach any output.
    $canaryRun = Invoke-Hook -CaseName 'canary' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command "Set-MpPreference -DisableRealtimeMonitoring `$true # $canary")
    $canaryDiagnostic = Get-ObservedDiagnostic -Run $canaryRun
    Add-Result 'TRAILING_COMMENT_DOES_NOT_CHANGE_STATE' (
        [string]$canaryRun.detail.assessment_status -ceq [string]$detected.detail.assessment_status -and
        $canaryDiagnostic.findings_count -eq $detectedDiagnostic.findings_count) -Observed $canaryDiagnostic
    Add-Result 'NO_CONTENT_LEAK' (
        (-not $canaryRun.stdout_text.Contains($canary)) -and
        (-not $canaryRun.store_text.Contains($canary)) -and
        (-not $canaryRun.notice_text.Contains($canary)) -and
        (-not ($canaryRun.detail | ConvertTo-Json -Depth 10 -Compress).Contains($canary))) -Observed $canaryDiagnostic

    # No trusted route: the interpreter is not guessed from the text.
    $unverified = Invoke-Hook -CaseName 'unverified' `
        -EventJson (Get-HookEventJson -Command 'Set-MpPreference -DisableRealtimeMonitoring $true')
    Add-Result 'UNVERIFIED_ROUTE_IS_UNASSESSABLE' (
        [string]$unverified.detail.assessment_status -ceq 'UNASSESSABLE' -and
        [string]$unverified.detail.assessment.assessment_reason_code -ceq 'UNSUPPORTED_LANGUAGE' -and
        [string]$unverified.detail.assessment_storage_status -ceq 'SAVED' -and
        (-not [bool]$unverified.detail.interpreter_verified)) -Observed (Get-ObservedDiagnostic -Run $unverified)
    Add-Result 'UNVERIFIED_ROUTE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $unverified)

    # A query is not a registration, so the same vocabulary does not detect.
    $query = Invoke-Hook -CaseName 'query' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command "Get-ScheduledTask -TaskName 'Synthetic'")
    Add-Result 'QUERY_IS_NO_DETECTION' (
        [string]$query.detail.assessment_status -ceq 'NO_DETECTION' -and
        [string]$query.detail.assessment_storage_status -ceq 'SAVED') -Observed (Get-ObservedDiagnostic -Run $query)

    # Malformed event: nothing is stored and nothing is denied.
    $invalid = Invoke-Hook -CaseName 'invalid' -TrustedRoute -EventJson '{invalid'
    Add-Result 'INVALID_INPUT_STORES_NOTHING' (
        [string]$invalid.detail.hook_status -ceq 'INVALID_HOOK_INPUT' -and
        [string]$invalid.detail.assessment_storage_status -ceq 'NOT_ATTEMPTED' -and
        [string]$invalid.detail.intent_storage_status -ceq 'NOT_ATTEMPTED' -and
        [string]$invalid.detail.interpreter_reason_code -ceq 'HOOK_INPUT_INVALID' -and
        $invalid.store_text.Length -eq 0) -Observed (Get-ObservedDiagnostic -Run $invalid)
    Add-Result 'INVALID_INPUT_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $invalid)

    # Only PreToolUse is an entry point for assessment.
    $post = Invoke-Hook -CaseName 'post' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command 'Get-Date' -HookEventName 'PostToolUse')
    Add-Result 'POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT' (
        [string]$post.detail.hook_status -ceq 'INVALID_HOOK_INPUT' -and
        $post.store_text.Length -eq 0)

    # The design requires the intent save to happen even when evaluation fails,
    # and a record to exist for EVALUATION_FAILED.
    $evaluationFailed = Invoke-Hook -CaseName 'evaluation-failed' -TrustedRoute -ForceEvaluationFailure `
        -EventJson (Get-HookEventJson -Command 'Get-Date')
    Add-Result 'EVALUATION_FAILURE_STILL_SAVES_INTENT_AND_RECORD' (
        [string]$evaluationFailed.detail.assessment_status -ceq 'EVALUATION_FAILED' -and
        [string]$evaluationFailed.detail.assessment_storage_status -ceq 'SAVED' -and
        [string]$evaluationFailed.detail.intent_storage_status -ceq 'TEST_DOUBLE_SAVED') -Observed (Get-ObservedDiagnostic -Run $evaluationFailed)
    Add-Result 'EVALUATION_FAILURE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $evaluationFailed)

    # The two stores are not one transaction: a failed intent save still leaves
    # the assessment, and the failure is noticed rather than implied away.
    $intentFailed = Invoke-Hook -CaseName 'intent-failed' -TrustedRoute -IntentOutcome 'TEST_FAILURE' `
        -EventJson (Get-HookEventJson -Command 'Get-Date')
    Add-Result 'INTENT_FAILURE_STILL_SAVES_ASSESSMENT' (
        [string]$intentFailed.detail.intent_storage_status -ceq 'TEST_DOUBLE_IO_ERROR' -and
        [string]$intentFailed.detail.assessment_storage_status -ceq 'SAVED' -and
        (-not [bool]$intentFailed.detail.body_store_reached) -and
        [string]$intentFailed.detail.notice_status -ceq 'NOTICE_WRITTEN' -and
        $intentFailed.notice_text.Contains('INTENT_STORE_FAILED')) -Observed (Get-ObservedDiagnostic -Run $intentFailed)

    $intentThrew = Invoke-Hook -CaseName 'intent-threw' -TrustedRoute -IntentOutcome 'TEST_THROW' `
        -EventJson (Get-HookEventJson -Command 'Get-Date')
    Add-Result 'INTENT_EXCEPTION_IS_NOT_A_SILENT_SUCCESS' (
        [string]$intentThrew.detail.intent_storage_status -ceq 'INTENT_STORE_FAILED' -and
        [string]$intentThrew.detail.assessment_storage_status -ceq 'SAVED' -and
        $intentThrew.notice_text.Contains('INTENT_STORE_FAILED') -and
        (-not $intentThrew.notice_text.Contains('Exception'))) -Observed (Get-ObservedDiagnostic -Run $intentThrew)

    # A failed assessment save is reported and noticed, not rounded to saved.
    $saveFailed = Invoke-Hook -CaseName 'assessment-save-failed' -TrustedRoute -ForceAssessmentSaveFailure `
        -EventJson (Get-HookEventJson -Command "Set-MpPreference -DisableRealtimeMonitoring `$true")
    Add-Result 'ASSESSMENT_SAVE_FAILURE_IS_DISTINCT' (
        [string]$saveFailed.detail.assessment_status -ceq 'DETECTED' -and
        [string]$saveFailed.detail.assessment_storage_status -cne 'SAVED' -and
        [string]$saveFailed.detail.notice_status -ceq 'NOTICE_WRITTEN' -and
        $saveFailed.notice_text.Contains('ASSESSMENT_STORE_FAILED')) -Observed (Get-ObservedDiagnostic -Run $saveFailed)
    Add-Result 'ASSESSMENT_SAVE_FAILURE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $saveFailed)

    # The execution id is derived from the event identity only.
    $first = Invoke-Hook -CaseName 'id-first' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command 'Get-Date' -ToolUseId 'tool-use-same')
    $second = Invoke-Hook -CaseName 'id-second' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command 'Get-ChildItem' -ToolUseId 'tool-use-same')
    $third = Invoke-Hook -CaseName 'id-third' -TrustedRoute `
        -EventJson (Get-HookEventJson -Command 'Get-Date' -ToolUseId 'tool-use-other')
    Add-Result 'EXECUTION_ID_IS_DETERMINISTIC_AND_IDENTITY_ONLY' (
        [string]$first.detail.execution_id -ceq [string]$second.detail.execution_id -and
        [string]$first.detail.execution_id -cne [string]$third.detail.execution_id -and
        [string]$first.detail.execution_id -cmatch '^[0-9a-f]{32}$')

    # An empty command is a state, not a detection.
    $empty = Invoke-Hook -CaseName 'empty' -TrustedRoute -EventJson (Get-HookEventJson -Command '')
    Add-Result 'EMPTY_COMMAND_IS_UNASSESSABLE' (
        [string]$empty.detail.assessment_status -ceq 'UNASSESSABLE' -and
        [string]$empty.detail.assessment.assessment_reason_code -ceq 'CONTENT_UNAVAILABLE' -and
        [string]$empty.detail.assessment_storage_status -ceq 'SAVED') -Observed (Get-ObservedDiagnostic -Run $empty)
}
catch {
    $failure = [pscustomobject][ordered]@{
        stage = 'TOP_LEVEL'
        exception_type = $_.Exception.GetType().FullName
        target = [string]$_.CategoryInfo.TargetName
    }
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $failed = @($results | Where-Object { -not $_.pass })
    # failure_stage and failure_exception_type are flattened to the top level,
    # the same shape the other tests in this repository use, so a runner can put
    # them in its failure line. A test that stops on an exception otherwise
    # reports an empty failed-case list and says nothing about why.
    $summary = [pscustomobject][ordered]@{
        success = ($failed.Count -eq 0 -and $null -eq $failure)
        powershell_version = $PSVersionTable.PSVersion.ToString()
        failure_stage = $(if ($null -eq $failure) { $null } else { [string]$failure.stage })
        failure_exception_type = $(if ($null -eq $failure) { $null } else { [string]$failure.exception_type })
        last_completed_case = $(if ($results.Count -eq 0) { $null } else { [string]$results[$results.Count - 1].name })
        test_count = $results.Count
        passed_count = $results.Count - $failed.Count
        failed_count = $failed.Count
        failed_cases = @($failed | ForEach-Object { $_.name })
        failure = $failure
        results = $results.ToArray()
        hook_child_processes_started = $childStartCount
        command_inputs_executed = $false
        body_store_written = $false
        network_access_performed = $false
        structured_output_only = $true
    }
    $summary | ConvertTo-Json -Depth 8

    if ($summary.success) { exit 0 } else { exit 1 }
}
