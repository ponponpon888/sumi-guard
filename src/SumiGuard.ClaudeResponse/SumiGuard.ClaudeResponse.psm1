Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Pure formatter for a *candidate* Claude Code PreToolUse JSON response.
# There is no hook registration, command execution, output to stdout, or
# store access here. Missing/malformed decisions yield no host response.
function ConvertTo-SumiGuardClaudePreToolUseResponse {
    [CmdletBinding()]
    param(
        [AllowNull()]$RecordingDecision
    )

    if ($null -eq $RecordingDecision -or
        $RecordingDecision -isnot [pscustomobject]) {
        return
    }

    $names = @($RecordingDecision.PSObject.Properties.Name)
    $required = @(
        'schema_version',
        'requested_mode',
        'effective_mode',
        'decision',
        'reason_code',
        'decision_only',
        'hook_response_generated',
        'command_executed'
    )
    foreach ($name in $required) {
        if ($names -cnotcontains $name) { return }
    }

    # The formatter never manufactures an allow/ask decision. An ordinary
    # allow outcome leaves Claude Code's normal permission flow unchanged.
    if ($RecordingDecision.schema_version -isnot [int] -or
        $RecordingDecision.schema_version -ne 1 -or
        $RecordingDecision.requested_mode -isnot [string] -or
        $RecordingDecision.requested_mode -cne 'ENFORCE_RECORDING' -or
        $RecordingDecision.effective_mode -isnot [string] -or
        $RecordingDecision.effective_mode -cne 'ENFORCE_RECORDING' -or
        $RecordingDecision.decision -isnot [string] -or
        $RecordingDecision.decision -cne 'DENY' -or
        $RecordingDecision.reason_code -isnot [string] -or
        $RecordingDecision.decision_only -isnot [bool] -or
        -not $RecordingDecision.decision_only -or
        $RecordingDecision.hook_response_generated -isnot [bool] -or
        $RecordingDecision.hook_response_generated -or
        $RecordingDecision.command_executed -isnot [bool] -or
        $RecordingDecision.command_executed) {
        return
    }

    # Accept only reasons produced by the policy's strict recording failures.
    # Do not echo the reason's source object, body, path, exception or status.
    $denyReasons = @(
        'RECORDING_NOT_VERIFIED',
        'STORE_VALIDATION_FAILED',
        'BODY_HASH_FAILED',
        'BODY_STORE_FAILED',
        'BODY_NOT_CAPTURED',
        'EVENT_SAVE_FAILED'
    )
    if ($RecordingDecision.reason_code -cnotin $denyReasons) {
        return
    }

    $response = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = 'SUMI Guard: required recording not confirmed.'
        }
    }
    return (ConvertTo-Json -InputObject $response -Depth 4 -Compress)
}

Export-ModuleMember -Function ConvertTo-SumiGuardClaudePreToolUseResponse
