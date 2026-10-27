Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Pure policy decision only. This module does not register hooks, emit host
# permission responses, execute commands, or read/write any store.
function Get-SumiGuardRecordingDecision {
    [CmdletBinding()]
    param(
        [ValidateSet('MONITOR', 'ENFORCE_RECORDING')]
        [string]$RequestedMode = 'MONITOR',

        # The caller must obtain this from trusted hook/runner configuration,
        # never from the hook's untrusted JSON payload.
        [bool]$RouteAllowlisted = $false,

        [ValidateSet('VALID', 'INVALID')]
        [string]$HookInputStatus = 'VALID',

        # A trusted caller passes the actual ExecutionAdapter result.
        # A supplied object is NOT proof that the operation was recorded.
        [AllowNull()]$AdapterResult
    )

    $effectiveMode = 'MONITOR'
    $decision = 'ALLOW'
    $reason = 'MONITOR_ONLY'

    if ($RequestedMode -ceq 'ENFORCE_RECORDING') {
        if (-not $RouteAllowlisted) {
            $reason = 'ROUTE_NOT_ALLOWLISTED'
        }
        else {
            $effectiveMode = 'ENFORCE_RECORDING'
            if ($HookInputStatus -ceq 'INVALID') {
                # Matches docs/26: malformed/unidentified input is not denied.
                # This is an explicitly documented fail-open limitation.
                $reason = 'INVALID_HOOK_INPUT_NOT_ENFORCED'
            }
            else {
                # For an in-scope, valid event, unconfirmed persistence is denied.
                # The policy never interprets DETECTED / NO_DETECTION as safety.
                $decision = 'DENY'
                $reason = 'RECORDING_NOT_VERIFIED'

                if ($null -ne $AdapterResult) {
                    $names = @($AdapterResult.PSObject.Properties.Name)
                    $status = ''
                    $success = $false
                    $eventState = ''
                    $bodyState = ''
                    $bodyFailureReason = ''

                    if ($names -ccontains 'status' -and $AdapterResult.status -is [string]) {
                        $status = $AdapterResult.status
                    }
                    if ($names -ccontains 'success' -and $AdapterResult.success -is [bool]) {
                        $success = $AdapterResult.success
                    }
                    if ($names -ccontains 'event_storage_status' -and $AdapterResult.event_storage_status -is [string]) {
                        $eventState = $AdapterResult.event_storage_status
                    }
                    if ($names -ccontains 'body_storage_status' -and $AdapterResult.body_storage_status -is [string]) {
                        $bodyState = $AdapterResult.body_storage_status
                    }
                    if ($names -ccontains 'body_failure_reason_code' -and $AdapterResult.body_failure_reason_code -is [string]) {
                        $bodyFailureReason = $AdapterResult.body_failure_reason_code
                    }

                    switch -CaseSensitive ($status) {
                        'EVENT_AND_BODY_SAVED' {
                            # A status string alone is insufficient evidence.
                            if ($success -and $eventState -ceq 'SAVED' -and $bodyState -ceq 'SAVED') {
                                $decision = 'ALLOW'
                                $reason = 'RECORDING_CONFIRMED'
                            }
                            break
                        }
                        'EXECUTION_STORE_VALIDATION_FAILED' {
                            $reason = 'STORE_VALIDATION_FAILED'
                            break
                        }
                        'BODY_HASH_FAILED' {
                            $reason = 'BODY_HASH_FAILED'
                            break
                        }
                        'EVENT_SAVED_BODY_COLLECTION_FAILED' {
                            # Narrow the reason only from LocalStore's fixed codes,
                            # so the operator notice can say what to do. Anything
                            # else stays the generic body-store failure.
                            switch -CaseSensitive ($bodyFailureReason) {
                                'STORE_LOCK_TIMEOUT' { $reason = 'LOCK_TIMEOUT'; break }
                                'ITEM_LIMIT_EXCEEDED' { $reason = 'STORE_CAPACITY_REACHED'; break }
                                'TOTAL_LIMIT_EXCEEDED' { $reason = 'STORE_CAPACITY_REACHED'; break }
                                default { $reason = 'BODY_STORE_FAILED' }
                            }
                            break
                        }
                        'EVENT_SAVED_METADATA_ONLY' {
                            # Metadata-only recording is not a full-body receipt.
                            $reason = 'BODY_NOT_CAPTURED'
                            break
                        }
                        'EVENT_SAVE_FAILED_BODY_ORPHANED' {
                            $reason = 'EVENT_SAVE_FAILED'
                            break
                        }
                        'EVENT_SAVE_FAILED_METADATA_ONLY' {
                            $reason = 'EVENT_SAVE_FAILED'
                            break
                        }
                        'EVENT_AND_BODY_SAVE_FAILED' {
                            $reason = 'EVENT_SAVE_FAILED'
                            break
                        }
                    }
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        schema_version = 1
        requested_mode = $RequestedMode
        effective_mode = $effectiveMode
        decision = $decision
        reason_code = $reason
        decision_only = $true
        hook_response_generated = $false
        command_executed = $false
    }
}

Export-ModuleMember -Function Get-SumiGuardRecordingDecision
