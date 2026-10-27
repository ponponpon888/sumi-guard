<#
    SUMI Guard ENFORCE_RECORDING hook for a Claude Code PreToolUse event.
    Gate 4, part 2 (docs/37). Separate from, and never a replacement for,
    hooks/Invoke-SumiGuardMonitorHook.ps1.

    It enforces only when the operator's control directory says so for this
    exact route (SumiGuard.EnforcementControl). Otherwise, including when the
    ENFORCEMENT_OFF kill switch exists, it records nothing and writes nothing
    to standard output, so Claude Code's normal permission flow is unchanged.

    When it enforces, it saves the execution intent with the encrypted body
    and denies the tool call unless the recording is confirmed:

      setting -> adapter -> decision -> Claude response -> notice

    Standard output carries either nothing or exactly the fixed deny JSON from
    SumiGuard.ClaudeResponse. The exit code is always 0. Any internal failure
    of this hook writes nothing to standard output, which Claude Code treats as
    no decision: the documented fail-open limit of docs/26. That fact is
    written to the notice file when possible.
#>
[CmdletBinding()]
param(
    # Hook input JSON. Standard input is read when this is not supplied, which
    # is how Claude Code passes the event.
    [AllowEmptyString()][AllowNull()][string]$RawHookInputJson,

    [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
    [Parameter(Mandatory = $true)][string]$LocalStorePath,

    # Operator-owned directory holding enforcement.json, ENFORCEMENT_OFF and
    # the notice file. Never derived from the event.
    [Parameter(Mandatory = $true)][string]$ControlDirectory,

    # Writes the detailed result as JSON for inspection.
    [string]$ResultPath,

    # Test seam. ADAPTER is the operational path. The others stand in for the
    # execution adapter, whose body protection is DPAPI CurrentUser and cannot
    # be exercised on a shared runner.
    [ValidateSet('ADAPTER', 'TEST_RECORDED', 'TEST_LOCK_TIMEOUT', 'TEST_CAPACITY',
        'TEST_STORE_INVALID', 'TEST_METADATA_ONLY', 'TEST_THROW')]
    [string]$TestIntentSaveOutcome = 'ADAPTER',

    # Test seam: fail inside the hook after the setting is read.
    [switch]$TestForceInternalError
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Root = Split-Path -Parent $PSScriptRoot
$script:RoutePrefix = 'claude-code:PreToolUse:'
$script:FallbackRoute = 'claude-code:PreToolUse:UNKNOWN_TOOL'
$script:ToolNamePattern = '^[A-Za-z0-9_]{1,64}$'

function Read-SumiGuardEnforcementInputText {
    # Bytes first, then strict UTF-8, as in the MONITOR hook: the console code
    # page must not decide how the host's event is read.
    $stream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    try {
        [byte[]]$chunk = New-Object byte[] 8192
        while ($true) {
            $read = $stream.Read($chunk, 0, $chunk.Length)
            if ($read -le 0) { break }
            $buffer.Write($chunk, 0, $read)
        }
        [byte[]]$bytes = $buffer.ToArray()
        $offset = 0
        if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $offset = 3
        }
        try {
            return [pscustomobject]@{
                status = 'DECODED'
                text = $script:Utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
            }
        }
        catch {
            return [pscustomobject]@{ status = 'NOT_UTF8'; text = '' }
        }
    }
    finally {
        $buffer.Dispose()
    }
}

# Its own identity space: a MONITOR hook registered for the same event derives
# a different execution id, so two hooks sharing a store cannot collide.
function Get-SumiGuardEnforcementExecutionId {
    param([Parameter(Mandatory = $true)]$HookInput)

    $session = [string]$HookInput.session_id
    $toolUse = [string]$HookInput.tool_use_id
    $material = 'CLAUDE_PRETOOLUSE_ENFORCEMENT_HOOK' +
        '|' + $session.Length + ':' + $session +
        '|' + $toolUse.Length + ':' + $toolUse
    [byte[]]$bytes = $script:Utf8Strict.GetBytes($material)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 32)
    }
    finally {
        $sha.Dispose()
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

# Returns the tool name when the event names one we can route, else $null.
function Get-SumiGuardEnforcementToolName {
    param([AllowNull()]$HookInput)

    if ($null -eq $HookInput -or $HookInput -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $names = @($HookInput.PSObject.Properties.Name)
    if ($names -cnotcontains 'tool_name' -or $HookInput.tool_name -isnot [string]) { return $null }
    if ($HookInput.tool_name -cnotmatch $script:ToolNamePattern) { return $null }
    return [string]$HookInput.tool_name
}

# A valid event for enforcement: PreToolUse, identity fields present, and a
# command string to record. Anything else is INVALID and is not enforced.
function Test-SumiGuardEnforcementInput {
    param([AllowNull()]$HookInput)

    if ($null -eq $HookInput -or $HookInput -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $names = @($HookInput.PSObject.Properties.Name)
    foreach ($name in @('hook_event_name', 'session_id', 'tool_use_id', 'tool_input')) {
        if ($names -cnotcontains $name) { return $false }
    }
    if ($HookInput.hook_event_name -cne 'PreToolUse') { return $false }
    foreach ($name in @('session_id', 'tool_use_id')) {
        if ($HookInput.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($HookInput.$name)) { return $false }
    }
    $toolInput = $HookInput.tool_input
    if ($null -eq $toolInput -or $toolInput -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    return (@($toolInput.PSObject.Properties.Name) -ccontains 'command' -and $toolInput.command -is [string])
}

function Get-SumiGuardTestAdapterResult {
    param([Parameter(Mandatory = $true)][string]$Outcome)

    switch ($Outcome) {
        'TEST_RECORDED' {
            return [pscustomobject][ordered]@{ success = $true; status = 'EVENT_AND_BODY_SAVED'
                event_storage_status = 'SAVED'; body_storage_status = 'SAVED'; body_failure_reason_code = $null }
        }
        'TEST_LOCK_TIMEOUT' {
            return [pscustomobject][ordered]@{ success = $false; status = 'EVENT_SAVED_BODY_COLLECTION_FAILED'
                event_storage_status = 'SAVED'; body_storage_status = 'FAILED'; body_failure_reason_code = 'STORE_LOCK_TIMEOUT' }
        }
        'TEST_CAPACITY' {
            return [pscustomobject][ordered]@{ success = $false; status = 'EVENT_SAVED_BODY_COLLECTION_FAILED'
                event_storage_status = 'SAVED'; body_storage_status = 'FAILED'; body_failure_reason_code = 'TOTAL_LIMIT_EXCEEDED' }
        }
        'TEST_STORE_INVALID' {
            return [pscustomobject][ordered]@{ success = $false; status = 'EXECUTION_STORE_VALIDATION_FAILED' }
        }
        'TEST_METADATA_ONLY' {
            return [pscustomobject][ordered]@{ success = $true; status = 'EVENT_SAVED_METADATA_ONLY'
                event_storage_status = 'SAVED'; body_storage_status = 'OMITTED_BY_POLICY'; body_failure_reason_code = $null }
        }
        'TEST_THROW' {
            throw [System.InvalidOperationException]::new('synthetic adapter failure')
        }
    }
    return $null
}

$result = [ordered]@{
    hook_schema_version = 1
    hook_status = 'NOT_STARTED'
    hook_input_decode_status = 'NOT_ATTEMPTED'
    route_id = $null
    setting_status = 'NOT_READ'
    requested_mode = 'MONITOR'
    route_allowlisted = $false
    hook_input_status = 'NOT_CHECKED'
    execution_id = $null
    intent_status = 'NOT_ATTEMPTED'
    body_failure_reason_code = $null
    decision = 'ALLOW'
    reason_code = 'MONITOR_ONLY'
    host_response = 'NONE'
    notice_status = 'NOT_REQUIRED'
    notice_failure_code = $null
    intent_save_path = $TestIntentSaveOutcome
    content_included = $false
    exception_message_included = $false
}
$responseJson = $null

try {
    Import-Module (Join-Path $script:Root 'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psd1') -Force -ErrorAction Stop

    if ([string]::IsNullOrEmpty($RawHookInputJson)) {
        $decoded = Read-SumiGuardEnforcementInputText
        $result.hook_input_decode_status = [string]$decoded.status
        $RawHookInputJson = [string]$decoded.text
    }
    else {
        $result.hook_input_decode_status = 'DIRECT_ARGUMENT'
    }

    $hookInput = $null
    if ($result.hook_input_decode_status -cne 'NOT_UTF8') {
        try { $hookInput = $RawHookInputJson | ConvertFrom-Json -ErrorAction Stop } catch { $hookInput = $null }
    }

    $toolName = Get-SumiGuardEnforcementToolName -HookInput $hookInput
    if ($null -eq $toolName) {
        # No route can be named, so no setting applies: nothing is enforced.
        $result.hook_status = 'NO_ROUTE'
        $result.route_id = $script:FallbackRoute
        $result.hook_input_status = 'INVALID'
    }
    else {
        $route = $script:RoutePrefix + $toolName
        $result.route_id = $route
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $ControlDirectory -RouteId $route
        $result.setting_status = [string]$setting.setting_status
        $result.requested_mode = [string]$setting.requested_mode
        $result.route_allowlisted = [bool]$setting.route_allowlisted

        if ($TestForceInternalError) {
            throw [System.InvalidOperationException]::new('synthetic hook failure')
        }

        if ($setting.requested_mode -cne 'ENFORCE_RECORDING' -or -not $setting.route_allowlisted) {
            # MONITOR, kill switch, absent or broken setting, unlisted route:
            # this hook steps aside completely.
            $result.hook_status = 'NOT_ENFORCED'
        }
        else {
            Import-Module (Join-Path $script:Root 'src\SumiGuard.EnforcementDecision\SumiGuard.EnforcementDecision.psd1') -Force -ErrorAction Stop
            Import-Module (Join-Path $script:Root 'src\SumiGuard.ClaudeResponse\SumiGuard.ClaudeResponse.psd1') -Force -ErrorAction Stop

            $inputValid = Test-SumiGuardEnforcementInput -HookInput $hookInput
            $result.hook_input_status = if ($inputValid) { 'VALID' } else { 'INVALID' }

            $adapterResult = $null
            if ($inputValid) {
                $executionId = Get-SumiGuardEnforcementExecutionId -HookInput $hookInput
                $result.execution_id = $executionId
                try {
                    if ($TestIntentSaveOutcome -ceq 'ADAPTER') {
                        Import-Module (Join-Path $script:Root 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force -ErrorAction Stop
                        $adapterResult = SumiGuard.ExecutionAdapter\Save-SumiGuardExecutionIntent `
                            -ExecutionStorePath $ExecutionStorePath `
                            -LocalStorePath $LocalStorePath `
                            -Body ([string]$hookInput.tool_input.command) `
                            -ExecutionId $executionId `
                            -BodyLockTimeoutMilliseconds ([int]$setting.lock_timeout_milliseconds)
                    }
                    else {
                        $adapterResult = Get-SumiGuardTestAdapterResult -Outcome $TestIntentSaveOutcome
                    }
                }
                catch {
                    # A recording attempt that threw is an unconfirmed
                    # recording, not a hook failure: the decision denies it.
                    $adapterResult = $null
                }
                if ($null -ne $adapterResult) {
                    $result.intent_status = [string]$adapterResult.status
                    if (@($adapterResult.PSObject.Properties.Name) -ccontains 'body_failure_reason_code') {
                        $result.body_failure_reason_code = $adapterResult.body_failure_reason_code
                    }
                }
                else {
                    $result.intent_status = 'NOT_CONFIRMED'
                }
            }

            $hookInputStatus = if ($inputValid) { 'VALID' } else { 'INVALID' }
            $decision = Get-SumiGuardRecordingDecision `
                -RequestedMode 'ENFORCE_RECORDING' `
                -RouteAllowlisted $true `
                -HookInputStatus $hookInputStatus `
                -AdapterResult $adapterResult
            $result.decision = [string]$decision.decision
            $result.reason_code = [string]$decision.reason_code

            $responseJson = ConvertTo-SumiGuardClaudePreToolUseResponse -RecordingDecision $decision
            if ($responseJson -is [string]) {
                $result.host_response = 'DENY'
            }
            elseif ($result.decision -ceq 'DENY') {
                # The formatter refused a DENY. Nothing is sent, and the
                # notice records that the deny did not reach the host.
                $result.reason_code = 'DENY_NOT_FORMATTED'
            }

            # A confirmed recording needs no notice. A deny, and an event this
            # hook could not read while it was supposed to enforce, do.
            if ($result.decision -ceq 'DENY' -or -not $inputValid) {
                $executionForNotice = ''
                if ($null -ne $result.execution_id) { $executionForNotice = [string]$result.execution_id }
                $notice = Write-SumiGuardEnforcementNotice -ControlDirectory $ControlDirectory `
                    -RouteId $route -Decision $result.decision -ReasonCode $result.reason_code `
                    -ExecutionId $executionForNotice
                $result.notice_status = [string]$notice.notice_status
                $result.notice_failure_code = $notice.failure_code
            }
            $result.hook_status = 'ENFORCED'
        }
    }
}
catch {
    # Fail open, as docs/26 states: no output means no host decision. Record
    # the fact if the notice path still works.
    $responseJson = $null
    $result.hook_status = 'HOOK_INTERNAL_ERROR'
    $result.host_response = 'NONE'
    $result.decision = 'ALLOW'
    $result.reason_code = 'HOOK_INTERNAL_ERROR'
    try {
        $routeForNotice = $script:FallbackRoute
        if ($null -ne $result.route_id) { $routeForNotice = [string]$result.route_id }
        $notice = Write-SumiGuardEnforcementNotice -ControlDirectory $ControlDirectory `
            -RouteId $routeForNotice -Decision 'ALLOW' -ReasonCode 'HOOK_INTERNAL_ERROR'
        $result.notice_status = [string]$notice.notice_status
        $result.notice_failure_code = $notice.failure_code
    }
    catch {
        $result.notice_status = 'NOTICE_NOT_PERSISTED'
        $result.notice_failure_code = 'NOTICE_MODULE_UNAVAILABLE'
    }
}

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    try {
        Set-Content -LiteralPath $ResultPath -Value ([pscustomobject]$result | ConvertTo-Json -Depth 4) -Encoding UTF8
    }
    catch {
        # Inspection only. Losing it must not change the response or exit code.
        $null = $null
    }
}

if ($responseJson -is [string]) {
    $responseJson
}
exit 0
