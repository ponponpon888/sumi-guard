[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Utf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PropertyNames {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value.PSObject.Properties.Name | Sort-Object)
}

function Write-JsonLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Compress -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-CollectionFailureNotice {
    param(
        [Parameter(Mandatory = $true)][string]$HookEventName,
        [Parameter(Mandatory = $true)][string]$TestCase,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$FailureType
    )

    $noticePath = [Environment]::GetEnvironmentVariable('SUMI_GUARD_ALTERNATE_NOTICE_PATH')
    if ([string]::IsNullOrWhiteSpace($noticePath)) {
        return $false
    }

    $notice = [ordered]@{
        schema_version = 1
        event_type = 'CollectionFailureNotice'
        observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        status = 'COLLECTION_FAILED'
        hook_event_name = $HookEventName
        test_case = $TestCase
        execution_id = $ExecutionId
        failure_type = $FailureType
        command_body_included = $false
        automatic_deny = $false
    }

    try {
        Write-JsonLine -Path $noticePath -Value $notice
        return $true
    }
    catch {
        return $false
    }
}

function Write-MonitorWarning {
    param([Parameter(Mandatory = $true)][bool]$AlternateNoticeSaved)

    $status = 'alternate notice saved'
    if (-not $AlternateNoticeSaved) {
        $status = 'alternate notice also failed'
    }

    $output = [ordered]@{
        systemMessage = "SUMI Guard prototype MONITOR: COLLECTION_FAILED; $status; execution was not denied."
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress))
}

function Write-UnexpectedCommandDeny {
    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = 'SUMI Guard isolated prototype permits only its declared harmless fixed command.'
        }
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 5))
}

$rawHookInput = [Console]::In.ReadToEnd()
$hookInput = $rawHookInput | ConvertFrom-Json
$hookEventName = [string]$hookInput.hook_event_name
$testCase = [Environment]::GetEnvironmentVariable('SUMI_GUARD_TEST_CASE')
$expectedCommand = [Environment]::GetEnvironmentVariable('SUMI_GUARD_EXPECTED_COMMAND')
$primaryPath = [Environment]::GetEnvironmentVariable('SUMI_GUARD_PRIMARY_EVENT_PATH')

if ([string]::IsNullOrWhiteSpace($testCase)) {
    $testCase = 'UNSPECIFIED'
}

$command = ''
if ($null -ne $hookInput.tool_input -and $null -ne $hookInput.tool_input.command) {
    $command = [string]$hookInput.tool_input.command
}

if ($hookEventName -ceq 'PreToolUse' -and [string]$hookInput.tool_name -ceq 'write_stdin') {
    $transportEvent = [ordered]@{
        schema_version = 1
        event_type = 'FollowUpStdinHookObserved'
        observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        status = 'RECORDS_FOUND'
        test_case = $testCase
        tool_name = [string]$hookInput.tool_name
        input_body_saved = $false
        automatic_deny = $false
    }

    try {
        Write-JsonLine -Path $primaryPath -Value $transportEvent
    }
    catch {
        $alternateSaved = Write-CollectionFailureNotice `
            -HookEventName $hookEventName `
            -TestCase $testCase `
            -ExecutionId 'sumi-write-stdin-transport' `
            -FailureType $_.Exception.GetType().FullName
        Write-MonitorWarning -AlternateNoticeSaved $alternateSaved
    }
    exit 0
}

$commandMatches = -not [string]::IsNullOrWhiteSpace($expectedCommand) -and
    $command.Trim() -ceq $expectedCommand

if (-not $commandMatches) {
    if ($hookEventName -ceq 'PreToolUse') {
        Write-UnexpectedCommandDeny
    }
    exit 0
}

$commandHash = Get-Utf8Sha256 -Text $command
$identityMaterial = ([string]$hookInput.session_id) + '|' +
    ([string]$hookInput.turn_id) + '|' + ([string]$hookInput.tool_use_id)
$executionId = 'sumi-' + (Get-Utf8Sha256 -Text $identityMaterial).Substring(0, 24)
$schemaSummary = [ordered]@{
    top_level_properties = @(Get-PropertyNames -Value $hookInput)
    tool_input_properties = @(Get-PropertyNames -Value $hookInput.tool_input)
    command_runtime_type = $command.GetType().FullName
}

if ($hookEventName -ceq 'PreToolUse') {
    $event = [ordered]@{
        schema_version = 1
        event_type = 'ExecutionIntentRecorded'
        observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        status = 'RECORDS_FOUND'
        test_case = $testCase
        execution_id = $executionId
        session_id = [string]$hookInput.session_id
        turn_id = [string]$hookInput.turn_id
        tool_use_id = [string]$hookInput.tool_use_id
        tool_name = [string]$hookInput.tool_name
        command_body = $command
        command_body_classification = 'HARMLESS_FIXED_TEST_VALUE'
        raw_input_sha256 = $commandHash
        hash_algorithm = 'SHA-256'
        hash_scope = 'UTF-8 without BOM bytes of the JSON-decoded tool_input.command string; no normalization'
        utf8_byte_length = (New-Object System.Text.UTF8Encoding($false)).GetByteCount($command)
        input_schema = $schemaSummary
        hook_process_id = $PID
        automatic_deny = $false
    }
}
elseif ($hookEventName -ceq 'PostToolUse') {
    $responseJson = $hookInput.tool_response | ConvertTo-Json -Compress -Depth 20
    $event = [ordered]@{
        schema_version = 1
        event_type = 'ExecutionOutcomeObserved'
        observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        status = 'RECORDS_FOUND'
        test_case = $testCase
        execution_id = $executionId
        session_id = [string]$hookInput.session_id
        turn_id = [string]$hookInput.turn_id
        tool_use_id = [string]$hookInput.tool_use_id
        tool_name = [string]$hookInput.tool_name
        raw_input_sha256 = $commandHash
        fixed_output_observed = $responseJson.Contains('SUMI_GUARD_PROTOTYPE_OK')
        tool_response_sha256 = Get-Utf8Sha256 -Text $responseJson
        tool_response_body_saved = $false
        hook_process_id = $PID
    }
}
else {
    exit 0
}

try {
    if ([string]::IsNullOrWhiteSpace($primaryPath)) {
        throw [System.InvalidOperationException]::new('Primary event path was not supplied.')
    }
    Write-JsonLine -Path $primaryPath -Value $event
}
catch {
    $failureType = $_.Exception.GetType().FullName
    $alternateSaved = Write-CollectionFailureNotice `
        -HookEventName $hookEventName `
        -TestCase $testCase `
        -ExecutionId $executionId `
        -FailureType $failureType
    Write-MonitorWarning -AlternateNoticeSaved $alternateSaved
    exit 0
}

exit 0
