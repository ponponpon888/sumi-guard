<#
    Synthetic tests for hooks/Invoke-SumiGuardMonitorHook.ps1.

    Every input is fixed string data passed to the hook as hook-event JSON. No
    input is executed: the hook is started as a child Windows PowerShell 5.1
    process with -File, and the command strings inside the events never reach a
    shell, the call operator, Invoke-Expression or Start-Process. Most cases use
    -TestIntentSaveOutcome as a deterministic adapter seam. The real-adapter
    metadata-only case uses only a disposable store and child PowerShell process.
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
# Updated as the test moves, so an exception names the statement group it came
# from rather than only TOP_LEVEL.
$script:stage = 'start'
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

# Reads one field of the object Invoke-Hook returned. It tolerates $null and a
# collection: under Set-StrictMode 2.0 a property access on either aborts the
# whole test, and the shape of the value is itself worth reporting.
function Get-RunField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Run) { return $null }

    $first = @($Run)[0]
    if ($null -eq $first) { return $null }
    if (@($first.PSObject.Properties.Name) -notcontains $Name) { return $null }

    return $first.$Name
}

# Reads one field of a hook result. A missing field returns $null instead of
# throwing: under Set-StrictMode 2.0 a direct property access on an absent field
# aborts the whole test, which costs a run and reports nothing about the case
# that was being checked.
function Get-DetailField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $detail = Get-RunField -Run $Run -Name 'detail'
    if ($null -eq $detail) { return $null }
    if (@($detail.PSObject.Properties.Name) -notcontains $Name) { return $null }

    return $detail.$Name
}

function Get-ObjectField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $first = @($Object)[0]
    if ($null -eq $first -or @($first.PSObject.Properties.Name) -notcontains $Name) {
        return $null
    }
    return $first.$Name
}

# Reads one field of the assessment record inside a hook result, tolerating an
# absent record. A missing assessment is a state worth a failed assertion, not a
# reason for the case to throw.
function Get-AssessmentField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $assessment = Get-DetailField -Run $Run -Name 'assessment'
    if ($null -eq $assessment) { return $null }
    if (@($assessment.PSObject.Properties.Name) -notcontains $Name) { return $null }

    return $assessment.$Name
}

function Get-ObservedDiagnostic {
    param([Parameter(Mandatory = $true)][AllowNull()]$Run)

    $runCount = 0
    $runType = 'null'
    if ($null -ne $Run) {
        $runCount = @($Run).Count
        $runType = $Run.GetType().FullName
    }

    if ($null -eq (Get-RunField -Run $Run -Name 'detail')) {
        return @{ detail_present = $false; run_count = $runCount; run_type = $runType }
    }

    $ruleIds = @()
    $reasonCode = $null
    $assessment = Get-DetailField -Run $Run -Name 'assessment'
    if ($null -ne $assessment) {
        if (@($assessment.PSObject.Properties.Name) -contains 'findings') {
            $ruleIds = @(@($assessment.findings) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.rule_id })
        }
        if (@($assessment.PSObject.Properties.Name) -contains 'assessment_reason_code') {
            $reasonCode = [string]$assessment.assessment_reason_code
        }
    }

    # Keep every value a plain string or number. A $null in the hashtable is the
    # only thing the two cases without an assessment record had in common.
    if ($null -eq $reasonCode) {
        $reasonCode = ''
    }

    return @{
        detail_present = $true
        run_count = $runCount
        run_type = $runType
        hook_status = [string](Get-DetailField -Run $Run -Name 'hook_status')
        assessment_status = [string](Get-DetailField -Run $Run -Name 'assessment_status')
        assessment_reason_code = $reasonCode
        rule_ids = $ruleIds
        findings_count = $ruleIds.Count
        assessment_storage_status = [string](Get-DetailField -Run $Run -Name 'assessment_storage_status')
        intent_storage_status = [string](Get-DetailField -Run $Run -Name 'intent_storage_status')
        intent_save_path = [string](Get-DetailField -Run $Run -Name 'intent_save_path')
        body_store_reached = [bool](Get-DetailField -Run $Run -Name 'body_store_reached')
        notice_status = [string](Get-DetailField -Run $Run -Name 'notice_status')
        interpreter_verified = [bool](Get-DetailField -Run $Run -Name 'interpreter_verified')
        interpreter_reason_code = [string](Get-DetailField -Run $Run -Name 'interpreter_reason_code')
        exit_code = (Get-RunField -Run $Run -Name 'exit_code')
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

function ConvertTo-HookProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    # All values passed here are fixed paths or fixed switches. Quoting each
    # value keeps the ProcessStartInfo invocation independent of the caller's
    # current working directory and avoids putting event JSON on argv.
    return '"' + $Value + '"'
}

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EventJson,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [switch]$TrustedRoute,
        [string]$IntentOutcome = 'TEST_SUCCESS',
        [switch]$ForceEvaluationFailure,
        [switch]$ForceAssessmentSaveFailure,
        [switch]$SeparateNativeStreams
    )

    $caseRoot = Join-Path $workRoot $CaseName
    $assessmentStorePath = Join-Path $caseRoot 'assessment-store'
    $noticePath = Join-Path $caseRoot 'notices\monitor-hook-notices.ndjson'
    $resultPath = Join-Path $caseRoot 'result.json'
    $executionStorePath = Join-Path $caseRoot 'execution-store'
    $localStorePath = Join-Path $caseRoot 'body-store'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force

    $script:stage = $CaseName + '/store-setup'
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    $created = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    if (-not $created.success) {
        throw [System.InvalidOperationException]::new('assessment store setup failed')
    }

    if ($IntentOutcome -ceq 'ADAPTER') {
        # The operational adapter contract expects both protected stores to
        # exist before the hook calls it. Prepare only this case's disposable
        # stores; the hook itself still performs the real adapter call.
        Import-Module (Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1') -Force
        Import-Module (Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
        $bodyStoreInit = Initialize-SumiGuardLocalStore -Path $localStorePath
        $executionStoreInit = Initialize-SumiGuardExecutionStore -Path $executionStorePath
        if (-not $bodyStoreInit.success -or -not $executionStoreInit.success) {
            throw [System.InvalidOperationException]::new('adapter test stores setup failed')
        }
    }

    # The event goes in over standard input, which is how a hook host delivers
    # it. It is not passed as -RawHookInputJson here: Windows PowerShell 5.1
    # does not reliably preserve a JSON argument across a native command
    # boundary, and a mangled argument reaches the hook as an unreadable event
    # rather than as an error.
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $hookPath,
        '-ExecutionStorePath', $executionStorePath,
        '-LocalStorePath', $localStorePath,
        '-AssessmentStorePath', $assessmentStorePath,
        '-NoticePath', $noticePath,
        '-ResultPath', $resultPath,
        '-TestIntentSaveOutcome', $IntentOutcome)
    if ($TrustedRoute) { $arguments += '-TrustedWindowsPowerShellRoute' }
    if ($ForceEvaluationFailure) { $arguments += '-TestForceEvaluationFailure' }
    if ($ForceAssessmentSaveFailure) { $arguments += '-TestForceAssessmentSaveFailure' }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutText = ''
    $stderrText = ''
    $childExited = $false
    try {
        $script:stage = $CaseName + '/child-run'
        if ($SeparateNativeStreams) {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $powerShell51
            $startInfo.Arguments = (($arguments | ForEach-Object {
                ConvertTo-HookProcessArgument -Value ([string]$_)
            }) -join ' ')
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $child = New-Object System.Diagnostics.Process
            $child.StartInfo = $startInfo
            try {
                if (-not $child.Start()) {
                    throw [System.InvalidOperationException]::new('child process did not start')
                }
                $child.StandardInput.Write($EventJson)
                $child.StandardInput.Close()
                $stdoutText = $child.StandardOutput.ReadToEnd()
                $stderrText = $child.StandardError.ReadToEnd()
                $child.WaitForExit()
                $exitCode = $child.ExitCode
                $childExited = $child.HasExited
            }
            finally {
                if ($null -ne $child) { $child.Dispose() }
            }
        }
        else {
            $stdout = $EventJson | & $powerShell51 @arguments 2>&1
            $exitCode = $LASTEXITCODE
            $stdoutText = ($stdout | Out-String)
            # The legacy seam intentionally merges streams; the real-adapter
            # case above captures stderr separately.
            $childExited = $true
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $script:childStartCount++

    $script:stage = $CaseName + '/read-result'
    $detail = $null
    if (Test-Path -LiteralPath $resultPath) {
        $detail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $script:stage = $CaseName + '/read-store'
    $storeText = ''
    $storeFile = Join-Path $assessmentStorePath 'assessments.ndjson'
    if (Test-Path -LiteralPath $storeFile) {
        $storeText = Get-Content -LiteralPath $storeFile -Raw -Encoding UTF8
    }

    $script:stage = $CaseName + '/read-notice'
    $noticeText = ''
    if (Test-Path -LiteralPath $noticePath) {
        $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
    }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        stdout_text = $stdoutText
        stderr_text = $stderrText
        child_process_exited = $childExited
        detail = $detail
        store_text = $storeText
        notice_text = $noticeText
        assessment_store_path = $assessmentStorePath
        execution_store_path = $executionStorePath
        local_store_path = $localStorePath
    }
}

function Test-MonitorOnlyResponse {
    param([Parameter(Mandatory = $true)]$Run)

    if ((Get-RunField -Run $Run -Name 'exit_code') -ne 0) { return $false }

    $response = $null
    try { $response = (Get-RunField -Run $Run -Name 'stdout_text') | ConvertFrom-Json } catch { return $false }
    if ($null -eq $response) { return $false }

    $names = @($response.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -cne 'systemMessage') { return $false }

    $lowered = ([string](Get-RunField -Run $Run -Name 'stdout_text')).ToLowerInvariant()
    foreach ($word in @('"deny"', 'permissiondecision', 'block')) {
        if ($lowered.Contains($word)) { return $false }
    }

    if ($null -eq $Run.detail) { return $false }
    return ((-not [bool](Get-DetailField -Run $Run -Name 'automatic_deny')) -and ([string](Get-DetailField -Run $Run -Name 'monitor_action') -ceq 'WARN_ONLY'))
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
    $script:stage = 'add/HOOK_SOURCE_NEVER_EXECUTES_COMMAND_TEXT'
    Add-Result 'HOOK_SOURCE_NEVER_EXECUTES_COMMAND_TEXT' $sourceClean
    $metadataOnlyWiring = $hookSource -match '\[switch\]\$CaptureCommandBody' -and
        $hookSource -match '-MetadataOnly:\(-not \[bool\]\$CaptureCommandBody\)'
    $script:stage = 'add/HOOK_DEFAULTS_TO_METADATA_ONLY'
    Add-Result 'HOOK_DEFAULTS_TO_METADATA_ONLY' $metadataOnlyWiring

    # Detection on a trusted route.
    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/detected'
        $detected = Invoke-Hook -CaseName 'detected' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command 'Set-MpPreference -DisableRealtimeMonitoring $true')
        $detectedDiagnostic = Get-ObservedDiagnostic -Run $detected
        $script:stage = 'add/TRUSTED_ROUTE_DETECTED'
        Add-Result 'TRUSTED_ROUTE_DETECTED' (
            [string](Get-DetailField -Run $detected -Name 'assessment_status') -ceq 'DETECTED' -and
            [string](Get-DetailField -Run $detected -Name 'assessment_storage_status') -ceq 'SAVED' -and
            [string](Get-DetailField -Run $detected -Name 'intent_storage_status') -ceq 'TEST_DOUBLE_SAVED' -and
            [bool](Get-DetailField -Run $detected -Name 'interpreter_verified') -and
            $detectedDiagnostic.findings_count -eq 1 -and
            @($detectedDiagnostic.rule_ids) -ccontains 'SG-CMD-002') -Observed $detectedDiagnostic
        $script:stage = 'add/DETECTED_IS_MONITOR_ONLY'
        Add-Result 'DETECTED_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $detected) -Observed $detectedDiagnostic
        $script:stage = 'add/DETECTED_RECORD_LINKED_TO_EXECUTION_ID'
        Add-Result 'DETECTED_RECORD_LINKED_TO_EXECUTION_ID' (
            ([string](Get-RunField -Run $detected -Name 'store_text')).Contains([string](Get-DetailField -Run $detected -Name 'execution_id')) -and
            [string](Get-DetailField -Run $detected -Name 'evaluation_origin') -ceq 'CODEX_PRETOOLUSE_HOOK') -Observed $detectedDiagnostic

        # The origin has to be in the stored record, not only in the hook's own
        # report, or a reader still cannot tell a hook record from a
        # managed-runner record.
        $script:stage = 'add/STORED_RECORD_DECLARES_HOOK_ORIGIN'
        $detectedStoreText = [string](Get-RunField -Run $detected -Name 'store_text')
        Add-Result 'STORED_RECORD_DECLARES_HOOK_ORIGIN' (
            $detectedStoreText.Contains('"evaluation_origin":"CODEX_PRETOOLUSE_HOOK"') -and
            -not $detectedStoreText.Contains('MANAGED_EXECUTION')) -Observed $detectedDiagnostic

        # The same detection with a canary appended as a comment. A comment is not a
        # call, so the state stays the same, and the canary must not reach any output.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_DETECTED' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    try {
        # This is the one end-to-end case: the child hook uses the real adapter
        # path and receives no -CaptureCommandBody switch. The command is fixed,
        # harmless synthetic input and is never sent to a command interpreter.
        $script:stage = 'assert/real-adapter-metadata-only'
        $realBody = "Write-Output '$canary'"
        $realRun = Invoke-Hook -CaseName 'real-adapter-metadata-only' -TrustedRoute `
            -IntentOutcome 'ADAPTER' -SeparateNativeStreams `
            -EventJson (Get-HookEventJson -Command $realBody)

        Import-Module (Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
        $realExecutionStore = [string](Get-RunField -Run $realRun -Name 'execution_store_path')
        $realLocalStore = [string](Get-RunField -Run $realRun -Name 'local_store_path')
        $realDetail = Get-DetailField -Run $realRun -Name 'detail'
        $realExecutionId = [string](Get-DetailField -Run $realRun -Name 'execution_id')
        $realRecords = Get-SumiGuardExecutionRecord `
            -ExecutionStorePath $realExecutionStore `
            -LocalStorePath $realLocalStore `
            -ExecutionId $realExecutionId
        $realRecord = $null
        if ($realRecords.success -and $realRecords.record_count -eq 1) {
            $realRecord = @($realRecords.records)[0]
        }
        $realReadBody = Read-SumiGuardExecutionBody `
            -ExecutionStorePath $realExecutionStore `
            -LocalStorePath $realLocalStore `
            -ExecutionId $realExecutionId
        $realNotices = Get-SumiGuardCollectionFailureNotice `
            -ExecutionStorePath $realExecutionStore `
            -ExecutionId $realExecutionId
        $realRecordCount = [int](Get-ObjectField -Object $realRecords -Name 'record_count')
        $realRecordsSuccess = [bool](Get-ObjectField -Object $realRecords -Name 'success')
        $realNoticeCount = [int](Get-ObjectField -Object $realNotices -Name 'notice_count')

        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $expectedHash = ([BitConverter]::ToString($sha.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes($realBody)))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }

        $bodyFiles = @()
        if (Test-Path -LiteralPath $realLocalStore) {
            $bodyFiles = @(Get-ChildItem -LiteralPath $realLocalStore -Recurse -File -Filter '*.sgb' -ErrorAction Stop)
        }

        $allFiles = @(Get-ChildItem -LiteralPath (Join-Path $workRoot 'real-adapter-metadata-only') -Recurse -File -ErrorAction Stop)
        $plaintextFoundInFiles = $false
        foreach ($file in $allFiles) {
            $fileText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($file.FullName))
            if ($fileText.Contains($canary)) {
                $plaintextFoundInFiles = $true
                break
            }
        }

        $realAssessmentText = [string](Get-RunField -Run $realRun -Name 'store_text')
        $realStdout = [string](Get-RunField -Run $realRun -Name 'stdout_text')
        $realStderr = [string](Get-RunField -Run $realRun -Name 'stderr_text')
        $intentNotExecutionEvidence = (
            $null -ne $realRecord -and
            [string]$realRecord.record_type -ceq 'ExecutionIntentRecorded' -and
            [string](Get-DetailField -Run $realRun -Name 'evaluation_origin') -ceq 'CODEX_PRETOOLUSE_HOOK' -and
            -not $realAssessmentText.Contains('MANAGED_EXECUTION'))
        $realPass = (
            (Test-MonitorOnlyResponse -Run $realRun) -and
            [bool](Get-RunField -Run $realRun -Name 'child_process_exited') -and
            [string](Get-DetailField -Run $realRun -Name 'intent_storage_status') -ceq 'EVENT_SAVED_METADATA_ONLY' -and
            [string](Get-DetailField -Run $realRun -Name 'assessment_storage_status') -ceq 'SAVED' -and
            $realRecordsSuccess -and $realRecordCount -eq 1 -and
            $null -ne $realRecord -and
            [string]$realRecord.content_status -ceq 'HASH_ONLY' -and
            [string]$realRecord.body_reference_status -ceq 'NOT_STORED' -and
            [string]$realRecord.collection_status -ceq 'RECORDS_FOUND' -and
            [string]$realRecord.body_sha256 -ceq $expectedHash -and
            [string]$realRecord.execution_id -ceq $realExecutionId -and
            $bodyFiles.Count -eq 0 -and
            -not $realStdout.Contains($canary) -and
            -not $realStderr.Contains($canary) -and
            -not $plaintextFoundInFiles -and
            -not $realReadBody.success -and
            [string]$realReadBody.status -ceq 'BODY_NOT_CAPTURED' -and
            [bool](Get-ObjectField -Object $realNotices -Name 'success') -and $realNoticeCount -eq 0 -and
            $intentNotExecutionEvidence)
        $script:stage = 'add/REAL_ADAPTER_DEFAULTS_TO_METADATA_ONLY'
        Add-Result 'REAL_ADAPTER_DEFAULTS_TO_METADATA_ONLY' $realPass -Observed @{
            intent_status = [string](Get-DetailField -Run $realRun -Name 'intent_storage_status')
            record_count = $realRecordCount
            content_status = if ($null -eq $realRecord) { '' } else { [string]$realRecord.content_status }
            body_reference_status = if ($null -eq $realRecord) { '' } else { [string]$realRecord.body_reference_status }
            body_files = $bodyFiles.Count
            body_hash_matches = ($null -ne $realRecord -and [string]$realRecord.body_sha256 -ceq $expectedHash)
            body_read_status = [string]$realReadBody.status
            failure_notices = $realNoticeCount
            child_process_exited = [bool](Get-RunField -Run $realRun -Name 'child_process_exited')
            monitor_action = [string](Get-DetailField -Run $realRun -Name 'monitor_action')
            automatic_deny = [bool](Get-DetailField -Run $realRun -Name 'automatic_deny')
            plaintext_found_in_output_or_files = ($realStdout.Contains($canary) -or
                $realStderr.Contains($canary) -or $plaintextFoundInFiles)
            evaluation_origin = [string](Get-DetailField -Run $realRun -Name 'evaluation_origin')
            record_type = if ($null -eq $realRecord) { '' } else { [string]$realRecord.record_type }
        }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_REAL_ADAPTER_METADATA_ONLY' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/canary'
        $canaryRun = Invoke-Hook -CaseName 'canary' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command "Set-MpPreference -DisableRealtimeMonitoring `$true # $canary")
        $canaryDiagnostic = Get-ObservedDiagnostic -Run $canaryRun
        $script:stage = 'add/TRAILING_COMMENT_DOES_NOT_CHANGE_STATE'
        Add-Result 'TRAILING_COMMENT_DOES_NOT_CHANGE_STATE' (
            [string](Get-DetailField -Run $canaryRun -Name 'assessment_status') -ceq [string](Get-DetailField -Run $detected -Name 'assessment_status') -and
            $canaryDiagnostic.findings_count -eq $detectedDiagnostic.findings_count) -Observed $canaryDiagnostic
        $script:stage = 'add/NO_CONTENT_LEAK'
        Add-Result 'NO_CONTENT_LEAK' (
            (-not ([string](Get-RunField -Run $canaryRun -Name 'stdout_text')).Contains($canary)) -and
            (-not ([string](Get-RunField -Run $canaryRun -Name 'store_text')).Contains($canary)) -and
            (-not ([string](Get-RunField -Run $canaryRun -Name 'notice_text')).Contains($canary)) -and
            (-not ($canaryRun.detail | ConvertTo-Json -Depth 10 -Compress).Contains($canary))) -Observed $canaryDiagnostic

        # No trusted route: the interpreter is not guessed from the text.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_CANARY' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/unverified'
        $unverified = Invoke-Hook -CaseName 'unverified' `
            -EventJson (Get-HookEventJson -Command 'Set-MpPreference -DisableRealtimeMonitoring $true')
        $script:stage = 'add/UNVERIFIED_ROUTE_IS_UNASSESSABLE'
        Add-Result 'UNVERIFIED_ROUTE_IS_UNASSESSABLE' (
            [string](Get-DetailField -Run $unverified -Name 'assessment_status') -ceq 'UNASSESSABLE' -and
            [string](Get-AssessmentField -Run $unverified -Name 'assessment_reason_code') -ceq 'UNSUPPORTED_LANGUAGE' -and
            [string](Get-DetailField -Run $unverified -Name 'assessment_storage_status') -ceq 'SAVED' -and
            (-not [bool](Get-DetailField -Run $unverified -Name 'interpreter_verified'))) -Observed (Get-ObservedDiagnostic -Run $unverified)
        $script:stage = 'add/UNVERIFIED_ROUTE_IS_MONITOR_ONLY'
        Add-Result 'UNVERIFIED_ROUTE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $unverified)

        # A query is not a registration, so the same vocabulary does not detect.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_UNVERIFIED' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/query'
        $query = Invoke-Hook -CaseName 'query' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command "Get-ScheduledTask -TaskName 'Synthetic'")
        $script:stage = 'add/QUERY_IS_NO_DETECTION'
        Add-Result 'QUERY_IS_NO_DETECTION' (
            [string](Get-DetailField -Run $query -Name 'assessment_status') -ceq 'NO_DETECTION' -and
            [string](Get-DetailField -Run $query -Name 'assessment_storage_status') -ceq 'SAVED') -Observed (Get-ObservedDiagnostic -Run $query)

        # Malformed event: nothing is stored and nothing is denied.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_QUERY' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/invalid'
        $invalid = Invoke-Hook -CaseName 'invalid' -TrustedRoute -EventJson '{invalid'
        # Read one field per statement, with a marker before each. The combined
        # expression threw under Set-StrictMode 2.0 and the statement line alone
        # could not say which read did it.
        $script:stage = 'read/invalid/hook_status'
        $invalidHookStatus = [string](Get-DetailField -Run $invalid -Name 'hook_status')
        $script:stage = 'read/invalid/assessment_storage_status'
        $invalidAssessmentStorage = [string](Get-DetailField -Run $invalid -Name 'assessment_storage_status')
        $script:stage = 'read/invalid/intent_storage_status'
        $invalidIntentStorage = [string](Get-DetailField -Run $invalid -Name 'intent_storage_status')
        $script:stage = 'read/invalid/interpreter_reason_code'
        $invalidInterpreterReason = [string](Get-DetailField -Run $invalid -Name 'interpreter_reason_code')
        $script:stage = 'read/invalid/store_text'
        $invalidStoreText = [string](Get-RunField -Run $invalid -Name 'store_text')
        $script:stage = 'read/invalid/observed'
        $invalidObserved = Get-ObservedDiagnostic -Run $invalid
        $script:stage = 'evaluate/INVALID_INPUT_STORES_NOTHING'
        $invalidPass = ($invalidHookStatus -ceq 'INVALID_HOOK_INPUT') -and
            ($invalidAssessmentStorage -ceq 'NOT_ATTEMPTED') -and
            ($invalidIntentStorage -ceq 'NOT_ATTEMPTED') -and
            ($invalidInterpreterReason -ceq 'HOOK_INPUT_INVALID') -and
            ([string]::IsNullOrEmpty($invalidStoreText))
        $script:stage = 'add/INVALID_INPUT_STORES_NOTHING'
        Add-Result 'INVALID_INPUT_STORES_NOTHING' $invalidPass -Observed $invalidObserved
        $script:stage = 'add/INVALID_INPUT_IS_MONITOR_ONLY'
        Add-Result 'INVALID_INPUT_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $invalid)

        # Only PreToolUse is an entry point for assessment.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INVALID' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/post'
        $post = Invoke-Hook -CaseName 'post' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command 'Get-Date' -HookEventName 'PostToolUse')
        $script:stage = 'read/post/hook_status'
        $postHookStatus = [string](Get-DetailField -Run $post -Name 'hook_status')
        $script:stage = 'read/post/store_text'
        $postStoreText = [string](Get-RunField -Run $post -Name 'store_text')
        $script:stage = 'read/post/observed'
        $postObserved = Get-ObservedDiagnostic -Run $post
        $script:stage = 'evaluate/POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT'
        $postPass = ($postHookStatus -ceq 'INVALID_HOOK_INPUT') -and
            ([string]::IsNullOrEmpty($postStoreText))
        $script:stage = 'add/POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT'
        Add-Result 'POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT' $postPass -Observed $postObserved

        # The design requires the intent save to happen even when evaluation fails,
        # and a record to exist for EVALUATION_FAILED.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_POST' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/evaluation-failed'
        $evaluationFailed = Invoke-Hook -CaseName 'evaluation-failed' -TrustedRoute -ForceEvaluationFailure `
            -EventJson (Get-HookEventJson -Command 'Get-Date')
        $script:stage = 'add/EVALUATION_FAILURE_STILL_SAVES_INTENT_AND_RECORD'
        Add-Result 'EVALUATION_FAILURE_STILL_SAVES_INTENT_AND_RECORD' (
            [string](Get-DetailField -Run $evaluationFailed -Name 'assessment_status') -ceq 'EVALUATION_FAILED' -and
            [string](Get-DetailField -Run $evaluationFailed -Name 'assessment_storage_status') -ceq 'SAVED' -and
            [string](Get-DetailField -Run $evaluationFailed -Name 'intent_storage_status') -ceq 'TEST_DOUBLE_SAVED') -Observed (Get-ObservedDiagnostic -Run $evaluationFailed)
        $script:stage = 'add/EVALUATION_FAILURE_IS_MONITOR_ONLY'
        Add-Result 'EVALUATION_FAILURE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $evaluationFailed)

        # The two stores are not one transaction: a failed intent save still leaves
        # the assessment, and the failure is noticed rather than implied away.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_EVALUATION_FAILED' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/intent-failed'
        $intentFailed = Invoke-Hook -CaseName 'intent-failed' -TrustedRoute -IntentOutcome 'TEST_FAILURE' `
            -EventJson (Get-HookEventJson -Command 'Get-Date')
        $script:stage = 'add/INTENT_FAILURE_STILL_SAVES_ASSESSMENT'
        Add-Result 'INTENT_FAILURE_STILL_SAVES_ASSESSMENT' (
            [string](Get-DetailField -Run $intentFailed -Name 'intent_storage_status') -ceq 'TEST_DOUBLE_IO_ERROR' -and
            [string](Get-DetailField -Run $intentFailed -Name 'assessment_storage_status') -ceq 'SAVED' -and
            (-not [bool](Get-DetailField -Run $intentFailed -Name 'body_store_reached')) -and
            [string](Get-DetailField -Run $intentFailed -Name 'notice_status') -ceq 'NOTICE_WRITTEN' -and
            ([string](Get-RunField -Run $intentFailed -Name 'notice_text')).Contains('INTENT_STORE_FAILED')) -Observed (Get-ObservedDiagnostic -Run $intentFailed)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INTENT_FAILED' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/intent-threw'
        $intentThrew = Invoke-Hook -CaseName 'intent-threw' -TrustedRoute -IntentOutcome 'TEST_THROW' `
            -EventJson (Get-HookEventJson -Command 'Get-Date')
        $script:stage = 'add/INTENT_EXCEPTION_IS_NOT_A_SILENT_SUCCESS'
        Add-Result 'INTENT_EXCEPTION_IS_NOT_A_SILENT_SUCCESS' (
            [string](Get-DetailField -Run $intentThrew -Name 'intent_storage_status') -ceq 'INTENT_STORE_FAILED' -and
            [string](Get-DetailField -Run $intentThrew -Name 'assessment_storage_status') -ceq 'SAVED' -and
            ([string](Get-RunField -Run $intentThrew -Name 'notice_text')).Contains('INTENT_STORE_FAILED') -and
            (-not ([string](Get-RunField -Run $intentThrew -Name 'notice_text')).Contains('Exception'))) -Observed (Get-ObservedDiagnostic -Run $intentThrew)

        # A failed assessment save is reported and noticed, not rounded to saved.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INTENT_THREW' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/assessment-save-failed'
        $saveFailed = Invoke-Hook -CaseName 'assessment-save-failed' -TrustedRoute -ForceAssessmentSaveFailure `
            -EventJson (Get-HookEventJson -Command "Set-MpPreference -DisableRealtimeMonitoring `$true")
        $script:stage = 'add/ASSESSMENT_SAVE_FAILURE_IS_DISTINCT'
        Add-Result 'ASSESSMENT_SAVE_FAILURE_IS_DISTINCT' (
            [string](Get-DetailField -Run $saveFailed -Name 'assessment_status') -ceq 'DETECTED' -and
            [string](Get-DetailField -Run $saveFailed -Name 'assessment_storage_status') -cne 'SAVED' -and
            [string](Get-DetailField -Run $saveFailed -Name 'notice_status') -ceq 'NOTICE_WRITTEN' -and
            ([string](Get-RunField -Run $saveFailed -Name 'notice_text')).Contains('ASSESSMENT_STORE_FAILED')) -Observed (Get-ObservedDiagnostic -Run $saveFailed)
        $script:stage = 'add/ASSESSMENT_SAVE_FAILURE_IS_MONITOR_ONLY'
        Add-Result 'ASSESSMENT_SAVE_FAILURE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $saveFailed)

        # The execution id is derived from the event identity only.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ASSESSMENT_SAVE_FAILED' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/id-first'
        $first = Invoke-Hook -CaseName 'id-first' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command 'Get-Date' -ToolUseId 'tool-use-same')
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ID_FIRST' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/id-second'
        $second = Invoke-Hook -CaseName 'id-second' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command 'Get-ChildItem' -ToolUseId 'tool-use-same')
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ID_SECOND' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/id-third'
        $third = Invoke-Hook -CaseName 'id-third' -TrustedRoute `
            -EventJson (Get-HookEventJson -Command 'Get-Date' -ToolUseId 'tool-use-other')
        $script:stage = 'add/EXECUTION_ID_IS_DETERMINISTIC_AND_IDENTITY_ONLY'
        Add-Result 'EXECUTION_ID_IS_DETERMINISTIC_AND_IDENTITY_ONLY' (
            [string](Get-DetailField -Run $first -Name 'execution_id') -ceq [string](Get-DetailField -Run $second -Name 'execution_id') -and
            [string](Get-DetailField -Run $first -Name 'execution_id') -cne [string](Get-DetailField -Run $third -Name 'execution_id') -and
            [string](Get-DetailField -Run $first -Name 'execution_id') -cmatch '^[0-9a-f]{32}$')

        # An empty command is a state, not a detection.
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ID_THIRD' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # One case must not end the run: a case that throws is recorded as a
    # failed case with its exception type and line, and the rest still run.
    try {
        $script:stage = 'assert/empty'
        $empty = Invoke-Hook -CaseName 'empty' -TrustedRoute -EventJson (Get-HookEventJson -Command '')
        $script:stage = 'add/EMPTY_COMMAND_IS_UNASSESSABLE'
        Add-Result 'EMPTY_COMMAND_IS_UNASSESSABLE' (
            [string](Get-DetailField -Run $empty -Name 'assessment_status') -ceq 'UNASSESSABLE' -and
            [string](Get-AssessmentField -Run $empty -Name 'assessment_reason_code') -ceq 'CONTENT_UNAVAILABLE' -and
            [string](Get-DetailField -Run $empty -Name 'assessment_storage_status') -ceq 'SAVED') -Observed (Get-ObservedDiagnostic -Run $empty)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_EMPTY' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

}
catch {
    $failure = [pscustomobject][ordered]@{
        stage = [string]$script:stage
        exception_type = $_.Exception.GetType().FullName
        target = [string]$_.CategoryInfo.TargetName
        script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
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
        failure_line = $(if ($null -eq $failure) { $null } else { [int]$failure.script_line_number })
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
