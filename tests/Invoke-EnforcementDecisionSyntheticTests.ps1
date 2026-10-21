[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $root 'src\SumiGuard.EnforcementDecision\SumiGuard.EnforcementDecision.psd1'
Import-Module -Name $manifest -Force -ErrorAction Stop

function New-TestAdapterResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [bool]$Success = $false,
        [string]$EventState = 'FAILED',
        [string]$BodyState = 'FAILED'
    )

    return [pscustomobject]@{
        status = $Status
        success = $Success
        event_storage_status = $EventState
        body_storage_status = $BodyState
        command_text = 'SECRET_TEST_ONLY_NEVER_OUTPUT'
        assessment_status = 'DETECTED'
    }
}

$complete = New-TestAdapterResult -Status 'EVENT_AND_BODY_SAVED' -Success $true -EventState 'SAVED' -BodyState 'SAVED'
$metadataOnly = New-TestAdapterResult -Status 'EVENT_SAVED_METADATA_ONLY' -Success $true -EventState 'SAVED' -BodyState 'OMITTED_BY_POLICY'
$partial = New-TestAdapterResult -Status 'EVENT_SAVED_BODY_COLLECTION_FAILED' -EventState 'SAVED'
$failed = New-TestAdapterResult -Status 'EXECUTION_STORE_VALIDATION_FAILED'
$hashFailed = New-TestAdapterResult -Status 'BODY_HASH_FAILED'
$eventFailed = New-TestAdapterResult -Status 'EVENT_SAVE_FAILED_BODY_ORPHANED' -BodyState 'SAVED_ORPHANED'

$cases = @(
    [pscustomobject]@{ name = 'default_monitor'; mode = 'MONITOR'; route = $false; input = 'VALID'; adapter = $null; action = 'ALLOW'; reason = 'MONITOR_ONLY'; effective = 'MONITOR' },
    [pscustomobject]@{ name = 'monitor_never_denies_failed_store'; mode = 'MONITOR'; route = $true; input = 'VALID'; adapter = $failed; action = 'ALLOW'; reason = 'MONITOR_ONLY'; effective = 'MONITOR' },
    [pscustomobject]@{ name = 'unlisted_route_stays_monitor'; mode = 'ENFORCE_RECORDING'; route = $false; input = 'VALID'; adapter = $failed; action = 'ALLOW'; reason = 'ROUTE_NOT_ALLOWLISTED'; effective = 'MONITOR' },
    [pscustomobject]@{ name = 'invalid_input_is_documented_fail_open'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'INVALID'; adapter = $null; action = 'ALLOW'; reason = 'INVALID_HOOK_INPUT_NOT_ENFORCED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'full_recording_allows_even_with_detection'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $complete; action = 'ALLOW'; reason = 'RECORDING_CONFIRMED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'metadata_only_not_a_full_receipt'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $metadataOnly; action = 'DENY'; reason = 'BODY_NOT_CAPTURED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'body_store_failure_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $partial; action = 'DENY'; reason = 'BODY_STORE_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'execution_store_validation_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $failed; action = 'DENY'; reason = 'STORE_VALIDATION_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'body_hash_failure_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $hashFailed; action = 'DENY'; reason = 'BODY_HASH_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'event_save_failure_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $eventFailed; action = 'DENY'; reason = 'EVENT_SAVE_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'metadata_event_save_failure_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'EVENT_SAVE_FAILED_METADATA_ONLY'); action = 'DENY'; reason = 'EVENT_SAVE_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'event_and_body_save_failure_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'EVENT_AND_BODY_SAVE_FAILED'); action = 'DENY'; reason = 'EVENT_SAVE_FAILED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'missing_adapter_result_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = $null; action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'success_flag_mismatch_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'EVENT_AND_BODY_SAVED' -EventState 'SAVED' -BodyState 'SAVED'); action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'event_state_mismatch_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'EVENT_AND_BODY_SAVED' -Success $true -EventState 'FAILED' -BodyState 'SAVED'); action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'body_state_mismatch_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'EVENT_AND_BODY_SAVED' -Success $true -EventState 'SAVED' -BodyState 'FAILED'); action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'unknown_status_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'UNKNOWN_STATUS' -Success $true -EventState 'SAVED' -BodyState 'SAVED'); action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' },
    [pscustomobject]@{ name = 'invalid_execution_id_denied'; mode = 'ENFORCE_RECORDING'; route = $true; input = 'VALID'; adapter = (New-TestAdapterResult -Status 'INVALID_EXECUTION_ID'); action = 'DENY'; reason = 'RECORDING_NOT_VERIFIED'; effective = 'ENFORCE_RECORDING' }
)

$results = New-Object System.Collections.Generic.List[object]
foreach ($case in $cases) {
    $passed = $false
    $observedReason = 'TEST_EXCEPTION'
    try {
        $decision = Get-SumiGuardRecordingDecision -RequestedMode $case.mode -RouteAllowlisted $case.route -HookInputStatus $case.input -AdapterResult $case.adapter
        $observedReason = [string]$decision.reason_code
        $expectedShape = @('schema_version', 'requested_mode', 'effective_mode', 'decision', 'reason_code', 'decision_only', 'hook_response_generated', 'command_executed')
        $actualShape = @($decision.PSObject.Properties.Name)
        $shapeOk = ($actualShape.Count -eq $expectedShape.Count)
        for ($i = 0; $i -lt $expectedShape.Count; $i++) {
            if (-not $shapeOk -or $actualShape[$i] -cne $expectedShape[$i]) {
                $shapeOk = $false
                break
            }
        }
        $wire = $decision | ConvertTo-Json -Compress -Depth 5
        $passed = $shapeOk -and
            ([int]$decision.schema_version -eq 1) -and
            ([string]$decision.decision -ceq $case.action) -and
            ([string]$decision.reason_code -ceq $case.reason) -and
            ([string]$decision.effective_mode -ceq $case.effective) -and
            ([bool]$decision.decision_only) -and
            (-not [bool]$decision.hook_response_generated) -and
            (-not [bool]$decision.command_executed) -and
            (-not $wire.Contains('SECRET_TEST_ONLY_NEVER_OUTPUT'))
    }
    catch {
        $passed = $false
        $observedReason = 'TEST_EXCEPTION'
    }
    $results.Add([pscustomobject][ordered]@{
        name = $case.name
        passed = [bool]$passed
        observed_reason_code = $observedReason
    })
    if ($passed) {
        Write-Host ('PASS ' + $case.name)
    }
    else {
        Write-Host ('FAIL ' + $case.name)
    }
}

$exported = @(Get-Command -Module SumiGuard.EnforcementDecision -CommandType Function | Select-Object -ExpandProperty Name)
$exportsOk = ($exported.Count -eq 1 -and $exported[0] -ceq 'Get-SumiGuardRecordingDecision')
$results.Add([pscustomobject][ordered]@{
    name = 'only_one_readonly_policy_function_exported'
    passed = [bool]$exportsOk
    observed_reason_code = if ($exportsOk) { 'EXPECTED_EXPORTS' } else { 'UNEXPECTED_EXPORTS' }
})
if ($exportsOk) { Write-Host 'PASS only_one_readonly_policy_function_exported' }
else { Write-Host 'FAIL only_one_readonly_policy_function_exported' }

$allPassed = (@($results | Where-Object { -not $_.passed }).Count -eq 0)
$summary = [pscustomobject][ordered]@{
    suite = 'enforcement-decision-synthetic'
    success = [bool]$allPassed
    test_count = $results.Count
    pass_count = @($results | Where-Object { $_.passed }).Count
    tests = $results.ToArray()
    host_hook_invoked = $false
    store_used = $false
    actual_deny_verified = $false
}
$summary | ConvertTo-Json -Depth 7
if ($allPassed) { exit 0 }
exit 1
