<#
    SUMI Guard MONITOR hook for a Codex PreToolUse event.

    Stage 5 of docs/23-suspicious-execution-warning-design.md. It assesses the
    command text in memory before the body reaches the local store, saves the
    execution intent through the existing adapter without changing it, and then
    saves the assessment alone. It never denies, blocks, quarantines, deletes,
    repairs, changes settings or sends anything outward.

    Standard output carries exactly one JSON object with one property,
    systemMessage, which is the hook response. Nothing else is written to
    standard output, and the exit code is always 0: a MONITOR hook must not turn
    its own failure into a denied execution. The detailed result goes to
    -ResultPath when one is given.
#>
[CmdletBinding()]
param(
    # Hook input JSON. Standard input is read when this is not supplied, which
    # is how a hook host passes the event.
    [AllowEmptyString()][AllowNull()][string]$RawHookInputJson,

    [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
    [Parameter(Mandatory = $true)][string]$LocalStorePath,
    [Parameter(Mandatory = $true)][string]$AssessmentStorePath,

    # Separate from the primary store, per the collection-failure notice path in
    # docs/19. Only fixed codes are written here, never command text.
    [string]$NoticePath,

    # Asserts that the hook registration restricts this event to a Windows
    # PowerShell host. Nothing in the hook JSON can establish that, so without
    # this switch the interpreter stays unverified and the assessment comes back
    # UNASSESSABLE / UNSUPPORTED_LANGUAGE instead of being guessed from the text.
    [switch]$TrustedWindowsPowerShellRoute,

    # The assessment store accepts SYNTHETIC_TEST and MANAGED_EXECUTION only. It
    # has no value for "assessed by a Codex PreToolUse hook", so an operational
    # record is currently indistinguishable from a managed-runner record. Adding
    # one is a store change and is left to an explicit decision.
    [ValidateSet('MANAGED_EXECUTION')][string]$EvaluationOrigin = 'MANAGED_EXECUTION',

    # Writes the detailed result as JSON. The hook response on standard output
    # stays a single systemMessage either way.
    [string]$ResultPath,

    # Test seam. ADAPTER is the operational path. The other values stand in for
    # SumiGuard.ExecutionAdapter without calling it, because its body protection
    # is DPAPI CurrentUser and cannot be exercised on a shared runner. A string
    # rather than a script block, so a test can set it across a process
    # boundary, which is how the hook is actually invoked.
    [ValidateSet('ADAPTER', 'TEST_SUCCESS', 'TEST_FAILURE', 'TEST_THROW')]
    [string]$TestIntentSaveOutcome = 'ADAPTER',

    [switch]$TestForceEvaluationFailure,
    [switch]$TestForceAssessmentSaveFailure
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Root = Split-Path -Parent $PSScriptRoot
$script:AssessmentManifest = Join-Path $script:Root 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
$script:AssessmentStoreManifest = Join-Path $script:Root 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'
$script:ExecutionAdapterManifest = Join-Path $script:Root 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'

if ([string]::IsNullOrWhiteSpace($NoticePath)) {
    $NoticePath = Join-Path $AssessmentStorePath 'monitor-hook-notices.ndjson'
}

function Get-SumiGuardPreToolExecutionId {
    param([Parameter(Mandatory = $true)]$HookInput)

    [byte[]]$bytes = $script:Utf8Strict.GetBytes(
        ([string]$HookInput.session_id) + '|' +
        ([string]$HookInput.turn_id) + '|' +
        ([string]$HookInput.tool_use_id))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 32)
    }
    finally {
        $sha.Dispose()
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Test-SumiGuardPreToolInput {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [Array]) { return $false }
    foreach ($name in @('hook_event_name', 'tool_name', 'session_id', 'turn_id', 'tool_use_id', 'tool_input')) {
        if ($Value.PSObject.Properties.Name -cnotcontains $name) { return $false }
    }
    if ([string]$Value.hook_event_name -cne 'PreToolUse' -or
        [string]$Value.tool_name -cne 'Bash' -or
        $null -eq $Value.tool_input) {
        return $false
    }
    foreach ($name in @('session_id', 'turn_id', 'tool_use_id')) {
        if ([string]::IsNullOrWhiteSpace([string]$Value.$name)) { return $false }
    }
    return ($Value.tool_input.PSObject.Properties.Name -ccontains 'command' -and
        $Value.tool_input.command -is [string])
}

# Only fixed codes reach the notice path. No command text, no argument values,
# no paths from the input, no exception messages.
function Write-SumiGuardMonitorNotice {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [AllowNull()]$ExecutionId
    )

    try {
        $directory = Split-Path -Parent $NoticePath
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }

        $notice = [pscustomobject][ordered]@{
            schema_version = 1
            event_type = 'MonitorHookFailureNotice'
            execution_id = $ExecutionId
            occurred_at_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            failed_stage = $Stage
            reason_code = $ReasonCode
            content_included = $false
            exception_message_included = $false
        }
        Add-Content -LiteralPath $NoticePath -Value ($notice | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
        return 'NOTICE_WRITTEN'
    }
    catch {
        # The notice path is the last resort. When it fails too, nothing about
        # this failure is persisted, and the result says so rather than implying
        # the record exists.
        return 'NOTICE_NOT_PERSISTED'
    }
}

$result = [ordered]@{
    hook_schema_version = 1
    hook_status = 'NOT_STARTED'
    execution_id = $null
    interpreter_verified = $false
    interpreter_reason_code = 'TARGET_INTERPRETER_UNVERIFIED'
    assessment_status = 'NOT_OBTAINED'
    assessment_obtained = $false
    assessment_storage_status = 'NOT_ATTEMPTED'
    intent_storage_status = 'NOT_ATTEMPTED'
    notice_status = 'NOT_ATTEMPTED'
    monitor_action = 'WARN_ONLY'
    automatic_deny = $false
    response_generation_status = 'NOT_GENERATED'
    evaluation_origin = $EvaluationOrigin
    intent_save_path = $TestIntentSaveOutcome
    body_store_reached = $false
    content_included = $false
    exception_message_included = $false
}
$assessment = $null

try {
    # An unbound [string] parameter can arrive as $null or as an empty string
    # depending on how the host invoked the script, and both mean "nothing was
    # passed", so standard input is the source in either case.
    if ([string]::IsNullOrEmpty($RawHookInputJson)) {
        $RawHookInputJson = [Console]::In.ReadToEnd()
    }

    $hookInput = $null
    try { $hookInput = $RawHookInputJson | ConvertFrom-Json -ErrorAction Stop } catch { $hookInput = $null }

    if (-not (Test-SumiGuardPreToolInput $hookInput)) {
        # Out of the collected range. Nothing is stored and nothing is denied:
        # a hook that cannot read its own event says nothing about the command.
        $result.hook_status = 'INVALID_HOOK_INPUT'
        $result.interpreter_reason_code = 'HOOK_INPUT_INVALID'
    }
    else {
        $result.hook_status = 'IN_PROGRESS'
        $executionId = Get-SumiGuardPreToolExecutionId $hookInput
        $result.execution_id = $executionId
        $commandText = [string]$hookInput.tool_input.command

        $verified = [bool]$TrustedWindowsPowerShellRoute
        $result.interpreter_verified = $verified
        $interpreterKind = 'UNKNOWN'
        if ($verified) {
            $interpreterKind = 'WINDOWS_POWERSHELL'
            $result.interpreter_reason_code = 'HOOK_REGISTRATION_RESTRICTS_HOST'
        }

        Import-Module $script:AssessmentManifest -Force -ErrorAction Stop
        Import-Module $script:AssessmentStoreManifest -Force -ErrorAction Stop

        # Step 2 of the design: the assessment is decided in memory before the
        # body is handed to the store in step 3.
        $assessmentModule = (Get-Module -Name 'SumiGuard.CommandAssessment' -All | Select-Object -First 1)
        if ($TestForceEvaluationFailure) {
            $assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure', $true)
        }
        try {
            $assessment = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
                -CommandText $commandText `
                -ExecutionId $executionId `
                -InterpreterKind $interpreterKind `
                -InterpreterVerified $verified
        }
        catch {
            # The evaluator reports its own internal failure as
            # EVALUATION_FAILED. Reaching this branch means no record was
            # returned at all, so none is fabricated here.
            $assessment = $null
        }
        finally {
            if ($TestForceEvaluationFailure) {
                $assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure', $false)
            }
        }

        if ($null -ne $assessment) {
            $result.assessment_obtained = $true
            $result.assessment_status = [string]$assessment.assessment_status
        }
        else {
            $result.notice_status = Write-SumiGuardMonitorNotice -Stage 'assessment' -ReasonCode 'ASSESSMENT_NOT_OBTAINED' -ExecutionId $executionId
        }

        # Step 3: the existing adapter is called unchanged. A failure here does
        # not stop step 4; the two are not one transaction and the design allows
        # one side to survive alone.
        $intent = $null
        switch ($TestIntentSaveOutcome) {
            'ADAPTER' {
                Import-Module $script:ExecutionAdapterManifest -Force -ErrorAction Stop
                $intent = SumiGuard.ExecutionAdapter\Save-SumiGuardExecutionIntent `
                    -ExecutionStorePath $ExecutionStorePath `
                    -LocalStorePath $LocalStorePath `
                    -Body $commandText `
                    -ExecutionId $executionId
            }
            'TEST_SUCCESS' {
                $intent = [pscustomobject][ordered]@{ success = $true; status = 'TEST_DOUBLE_SAVED' }
            }
            'TEST_FAILURE' {
                $intent = [pscustomobject][ordered]@{ success = $false; status = 'TEST_DOUBLE_IO_ERROR' }
            }
            'TEST_THROW' {
                try {
                    throw [System.InvalidOperationException]::new('synthetic')
                }
                catch {
                    $intent = $null
                }
            }
        }

        if ($null -ne $intent -and $intent.success) {
            # The adapter's own status is kept rather than flattened to SAVED.
            # The real path reports EVENT_AND_BODY_SAVED; a test seam reports its
            # own code. Flattening both to SAVED would let a run that never
            # touched the protected body store read as though it had.
            $status = 'SAVED'
            if (-not [string]::IsNullOrWhiteSpace([string]$intent.status)) {
                $status = [string]$intent.status
            }
            $result.intent_storage_status = $status
            $result.body_store_reached = ($TestIntentSaveOutcome -ceq 'ADAPTER')
        }
        else {
            $status = 'INTENT_STORE_FAILED'
            if ($null -ne $intent -and -not [string]::IsNullOrWhiteSpace([string]$intent.status)) {
                $status = [string]$intent.status
            }
            $result.intent_storage_status = $status
            $result.notice_status = Write-SumiGuardMonitorNotice -Stage 'intent-store' -ReasonCode 'INTENT_STORE_FAILED' -ExecutionId $executionId
        }

        # Step 4: the assessment alone. The command text is not passed here.
        if ($null -eq $assessment) {
            $result.assessment_storage_status = 'NOT_ATTEMPTED'
        }
        else {
            $storeModule = (Get-Module -Name 'SumiGuard.AssessmentStore' -All | Select-Object -First 1)
            if ($TestForceAssessmentSaveFailure) {
                $storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure', $true)
            }
            $save = $null
            try {
                $save = SumiGuard.AssessmentStore\Save-SumiGuardAssessment `
                    -StorePath $AssessmentStorePath `
                    -Assessment $assessment `
                    -EvaluationOrigin $EvaluationOrigin `
                    -RelatedExecutionId $executionId
            }
            catch {
                $save = $null
            }
            finally {
                if ($TestForceAssessmentSaveFailure) {
                    $storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure', $false)
                }
            }

            if ($null -ne $save -and $save.success) {
                $result.assessment_storage_status = 'SAVED'
            }
            else {
                $status = 'ASSESSMENT_STORE_FAILED'
                if ($null -ne $save -and -not [string]::IsNullOrWhiteSpace([string]$save.status)) {
                    $status = [string]$save.status
                }
                $result.assessment_storage_status = $status
                $result.notice_status = Write-SumiGuardMonitorNotice -Stage 'assessment-store' -ReasonCode 'ASSESSMENT_STORE_FAILED' -ExecutionId $executionId
            }
        }

        $result.hook_status = 'COMPLETED'
    }
}
catch {
    # Any unexpected failure still ends as a monitor-only continue.
    $result.hook_status = 'HOOK_INTERNAL_ERROR'
    $result.notice_status = Write-SumiGuardMonitorNotice -Stage 'hook' -ReasonCode 'HOOK_INTERNAL_ERROR' -ExecutionId $result.execution_id
}

# Step 5: continue either way. The message carries states and fixed codes only,
# never the command text or a matched fragment.
$message = 'SUMI Guard MONITOR: evaluation=' + [string]$result.assessment_status +
    '; assessment_storage=' + [string]$result.assessment_storage_status +
    '; intent_storage=' + [string]$result.intent_storage_status +
    '; response=monitor-only.'
$response = [pscustomobject][ordered]@{ systemMessage = $message }
$result.response_generation_status = 'GENERATED'

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    try {
        $detailed = [pscustomobject]$result
        $detailed | Add-Member -NotePropertyName assessment -NotePropertyValue $assessment -Force
        Set-Content -LiteralPath $ResultPath -Value ($detailed | ConvertTo-Json -Depth 8) -Encoding UTF8
    }
    catch {
        # The result file is for inspection. Losing it must not change the hook
        # response or the exit code.
        $null = $null
    }
}

$response | ConvertTo-Json -Compress -Depth 3
exit 0
