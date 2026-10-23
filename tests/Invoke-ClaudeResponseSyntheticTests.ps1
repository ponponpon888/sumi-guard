[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$policyManifest = Join-Path $root 'src\SumiGuard.EnforcementDecision\SumiGuard.EnforcementDecision.psd1'
$responseManifest = Join-Path $root 'src\SumiGuard.ClaudeResponse\SumiGuard.ClaudeResponse.psd1'
Import-Module -Name $policyManifest -Force -ErrorAction Stop
Import-Module -Name $responseManifest -Force -ErrorAction Stop

$fullReceipt = [pscustomobject]@{
    status = 'EVENT_AND_BODY_SAVED'
    success = $true
    event_storage_status = 'SAVED'
    body_storage_status = 'SAVED'
}
$bodyFailed = [pscustomobject]@{
    status = 'EVENT_SAVED_BODY_COLLECTION_FAILED'
    success = $false
    event_storage_status = 'SAVED'
    body_storage_status = 'FAILED'
    command_text = 'SECRET_CANARY_DO_NOT_OUTPUT'
}
$noRecord = [pscustomobject]@{
    status = 'EXECUTION_STORE_VALIDATION_FAILED'
    success = $false
    event_storage_status = 'FAILED'
    body_storage_status = 'FAILED'
}
$metadataOnly = [pscustomobject]@{
    status = 'EVENT_SAVED_METADATA_ONLY'
    success = $true
    event_storage_status = 'SAVED'
    body_storage_status = 'OMITTED_BY_POLICY'
}

$denyByStore = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true -AdapterResult $noRecord
$denyByBody = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true -AdapterResult $bodyFailed
$denyMetadata = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true -AdapterResult $metadataOnly
$denyNoEvidence = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true
$allowGood = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true -AdapterResult $fullReceipt
$allowMonitor = Get-SumiGuardRecordingDecision -AdapterResult $noRecord
$allowUnlisted = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -AdapterResult $noRecord
$allowBadInput = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING -RouteAllowlisted $true -HookInputStatus INVALID

$sourceCanary = 'SECRET_CANARY_DO_NOT_OUTPUT'
$decisionWithExtra = $denyByStore | Select-Object *
$decisionWithExtra | Add-Member -MemberType NoteProperty -Name command_text -Value $sourceCanary
$wrongMode = $denyByStore | Select-Object *
$wrongMode.requested_mode = 'MONITOR'
$wrongReason = $denyByStore | Select-Object *
$wrongReason.reason_code = 'SECRET_CANARY_DO_NOT_OUTPUT'
$wrongSchema = $denyByStore | Select-Object *
$wrongSchema.schema_version = 2
$noPermission = $denyByStore | Select-Object *
$noPermission.hook_response_generated = $true
$missingField = [pscustomobject]@{
    schema_version = 1
    requested_mode = 'ENFORCE_RECORDING'
    effective_mode = 'ENFORCE_RECORDING'
    decision = 'DENY'
    reason_code = 'STORE_VALIDATION_FAILED'
}

$cases = @(
    [pscustomobject]@{ name = 'denies_store_failure'; value = $denyByStore; shouldDeny = $true },
    [pscustomobject]@{ name = 'denies_body_failure'; value = $denyByBody; shouldDeny = $true },
    [pscustomobject]@{ name = 'denies_metadata_only'; value = $denyMetadata; shouldDeny = $true },
    [pscustomobject]@{ name = 'denies_missing_record'; value = $denyNoEvidence; shouldDeny = $true },
    [pscustomobject]@{ name = 'never_echoes_extra_source_fields'; value = $decisionWithExtra; shouldDeny = $true },
    [pscustomobject]@{ name = 'recording_confirmed_no_hook_decision'; value = $allowGood; shouldDeny = $false },
    [pscustomobject]@{ name = 'monitor_no_hook_decision'; value = $allowMonitor; shouldDeny = $false },
    [pscustomobject]@{ name = 'unlisted_route_no_hook_decision'; value = $allowUnlisted; shouldDeny = $false },
    [pscustomobject]@{ name = 'invalid_input_no_hook_decision'; value = $allowBadInput; shouldDeny = $false },
    [pscustomobject]@{ name = 'null_decision_no_hook_decision'; value = $null; shouldDeny = $false },
    [pscustomobject]@{ name = 'string_input_no_hook_decision'; value = 'DENY'; shouldDeny = $false },
    [pscustomobject]@{ name = 'wrong_requested_mode_rejected'; value = $wrongMode; shouldDeny = $false },
    [pscustomobject]@{ name = 'unknown_reason_rejected'; value = $wrongReason; shouldDeny = $false },
    [pscustomobject]@{ name = 'wrong_schema_rejected'; value = $wrongSchema; shouldDeny = $false },
    [pscustomobject]@{ name = 'already_generated_rejected'; value = $noPermission; shouldDeny = $false },
    [pscustomobject]@{ name = 'missing_required_field_rejected'; value = $missingField; shouldDeny = $false }
)

$results = New-Object System.Collections.Generic.List[object]
$golden = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SUMI Guard: required recording not confirmed."}}'
foreach ($case in $cases) {
    $ok = $false
    try {
        $wire = ConvertTo-SumiGuardClaudePreToolUseResponse -RecordingDecision $case.value
        if ($case.shouldDeny) {
            $parsed = $wire | ConvertFrom-Json
            $inner = $parsed.hookSpecificOutput
            $ok = ($wire -is [string] -and $wire -ceq $golden -and
                @($parsed.PSObject.Properties.Name).Count -eq 1 -and
                @($inner.PSObject.Properties.Name).Count -eq 3 -and
                $inner.hookEventName -ceq 'PreToolUse' -and
                $inner.permissionDecision -ceq 'deny' -and
                $inner.permissionDecisionReason -ceq 'SUMI Guard: required recording not confirmed.' -and
                (-not $wire.Contains($sourceCanary)))
        }
        else {
            $ok = ($null -eq $wire)
        }
    }
    catch {
        $ok = $false
    }
    $results.Add([pscustomobject][ordered]@{
        name = $case.name
        passed = [bool]$ok
    })
}

$exports = @(Get-Command -Module SumiGuard.ClaudeResponse -CommandType Function | Select-Object -ExpandProperty Name)
$onlyExport = ($exports.Count -eq 1 -and $exports[0] -ceq 'ConvertTo-SumiGuardClaudePreToolUseResponse')
$results.Add([pscustomobject][ordered]@{
    name = 'only_pure_formatter_exported'
    passed = [bool]$onlyExport
})

$passed = @($results | Where-Object { $_.passed }).Count
$allPassed = ($passed -eq $results.Count)
$summary = [pscustomobject][ordered]@{
    suite = 'claude-response-synthetic'
    success = [bool]$allPassed
    test_count = $results.Count
    pass_count = $passed
    tests = $results.ToArray()
    actual_host_invoked = $false
    hook_registered = $false
    store_accessed = $false
    deny_effectiveness_verified = $false
}
$summary | ConvertTo-Json -Depth 7
if ($allPassed) { exit 0 }
exit 1
