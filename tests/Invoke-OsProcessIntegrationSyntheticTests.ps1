[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\SumiGuard.OsProcessIntegration\SumiGuard.OsProcessIntegration.psd1') -Force
$results = New-Object 'System.Collections.Generic.List[object]'

function Get-TestEvidence {
    param([string]$Status = 'PROCESS_CONFIRMED', [int]$PidValue = 4242)
    return [pscustomobject]@{
        process_confirmation_status = $Status
        observed_pid = $PidValue
        observed_start_time_utc = '2026-10-31T01:02:03.1234567Z'
        observed_executable_path = 'C:\Synthetic\powershell.exe'
    }
}
function Get-TestObservation {
    param([int]$Sequence = 1, [int]$PidValue = 4242, [string]$Precision = 'CIM_DATETIME_UNVERIFIED',
          [string]$Source = 'CIM', [string]$Status = 'COLLECTED',
          [string]$Path = 'C:\Synthetic\powershell.exe')
    return [pscustomobject]@{
        observation_source = $Source
        observation_sequence = $Sequence
        observed_pid = $PidValue
        observed_start_time_utc = '2026-10-31T01:02:03.1234567Z'
        observed_executable_path = $Path
        collected_at_utc = ('2026-10-31T01:02:04.{0}Z' -f $(if ($Sequence -eq 1) { '1234567' } else { '2234567' }))
        start_time_precision = $Precision
        collection_status = $Status
    }
}
function Get-TestObserver {
    param([string]$Status = 'OBSERVED_LOW_PRECISION')
    $observations = @((Get-TestObservation -Sequence 1),(Get-TestObservation -Sequence 2))
    return [pscustomobject]@{
        collection_status = $Status
        collection_succeeded = $true
        read_performed = $true
        correlation_ready = $false
        direct_match_operationally_enabled = $false
        observation_count = 2
        observations = $observations
    }
}
function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    $pass = $false
    $detail = ''
    try { $pass = [bool](& $Body) } catch { $detail = $_.Exception.GetType().Name }
    $results.Add([pscustomobject]@{ name = $Name; pass = $pass; detail = $detail })
}

Invoke-TestCase 'LOW_PRECISION_ALWAYS_UNMATCHED' {
    $r = Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult (Get-TestObserver)
    $r.correlation_status -ceq 'UNMATCHED' -and $r.correlation_reason_code -ceq 'CIM_START_TIME_PRECISION_UNVERIFIED'
}
Invoke-TestCase 'PHASE4A_DIAGNOSTIC_REJECTION' {
    $r = Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult (Get-TestObserver)
    $r.phase4a_evaluated -and $r.phase4a_reason_code -ceq 'OBSERVATION_INVALID_OR_UNAVAILABLE'
}
Invoke-TestCase 'NEVER_DIRECT_OR_INFERRED' {
    $r = Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult (Get-TestObserver)
    -not $r.correlation_ready -and -not $r.direct_match_operationally_enabled -and $r.accepted_observation_count -eq 0
}
Invoke-TestCase 'UNCONFIRMED_PHASE3_BLOCKED' {
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence -Status 'PROCESS_UNVERIFIED') -CimObserverResult (Get-TestObserver)).correlation_reason_code -ceq 'PHASE3_NOT_CONFIRMED'
}
Invoke-TestCase 'NULL_EVIDENCE_BLOCKED' {
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence $null -CimObserverResult (Get-TestObserver)).correlation_status -ceq 'UNMATCHED'
}
Invoke-TestCase 'FORGED_TRUSTED_FLAG_IGNORED' {
    $e = Get-TestEvidence
    $e | Add-Member NoteProperty trusted $true
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence $e -CimObserverResult (Get-TestObserver)).correlation_status -ceq 'UNMATCHED'
}
Invoke-TestCase 'NO_OPT_IN_BLOCKED' {
    $o = Get-TestObserver -Status 'OPT_IN_REQUIRED'
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'CIM_COLLECTION_NOT_SUCCESSFUL'
}
Invoke-TestCase 'ACCESS_DENIED_BLOCKED' {
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult (Get-TestObserver -Status 'ACCESS_DENIED')).correlation_status -ceq 'UNMATCHED'
}
Invoke-TestCase 'NULL_OBSERVER_BLOCKED' {
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $null).correlation_status -ceq 'UNMATCHED'
}
Invoke-TestCase 'NO_READ_FLAG_BLOCKED' {
    $o = Get-TestObserver; $o.read_performed = $false
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'CIM_CONTRACT_INVALID'
}
Invoke-TestCase 'FORGED_READY_FLAG_BLOCKED' {
    $o = Get-TestObserver; $o.correlation_ready = $true
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'CIM_CONTRACT_INVALID'
}
Invoke-TestCase 'FORGED_DIRECT_FLAG_BLOCKED' {
    $o = Get-TestObserver; $o.direct_match_operationally_enabled = $true
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'CIM_CONTRACT_INVALID'
}
Invoke-TestCase 'CARDINALITY_MISMATCH_BLOCKED' {
    $o = Get-TestObserver; $o.observation_count = 1
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'OBSERVATION_CARDINALITY_INVALID'
}
Invoke-TestCase 'MISSING_OBSERVATION_BLOCKED' {
    $o = Get-TestObserver; $o.observations = @($o.observations[0])
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'OBSERVATION_CARDINALITY_INVALID'
}
Invoke-TestCase 'CIM_SOURCE_MISMATCH_BLOCKED' {
    $o = Get-TestObserver; $o.observations[1].observation_source = 'ETW'
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'OBSERVATION_CONTRACT_INVALID'
}
Invoke-TestCase 'PRECISION_SPOOF_BLOCKED' {
    $o = Get-TestObserver; $o.observations[0].start_time_precision = 'TICKS_100NS'
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'PRECISION_ESCALATION_REJECTED'
}
Invoke-TestCase 'SEQUENCE_REORDER_BLOCKED' {
    $o = Get-TestObserver; $o.observations[1].observation_sequence = 1
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'OBSERVATION_CONTRACT_INVALID'
}
Invoke-TestCase 'INVALID_COLLECTION_STATE_BLOCKED' {
    $o = Get-TestObserver; $o.observations[0].collection_status = 'ACCESS_DENIED'
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'OBSERVATION_CONTRACT_INVALID'
}
Invoke-TestCase 'PID_REUSE_SUSPECTED_BLOCKED' {
    $o = Get-TestObserver; $o.observations[1].observed_pid = 4243
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'IDENTITY_DISAGREEMENT'
}
Invoke-TestCase 'PATH_DISAGREEMENT_BLOCKED' {
    $o = Get-TestObserver; $o.observations[1].observed_executable_path = 'C:\Synthetic\other.exe'
    (Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult $o).correlation_reason_code -ceq 'IDENTITY_DISAGREEMENT'
}
Invoke-TestCase 'NO_BACKGROUND_FLAGS' {
    $r = Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-TestEvidence) -CimObserverResult (Get-TestObserver)
    -not $r.os_collection_performed -and -not $r.process_started -and -not $r.wmi_subscription_started -and -not $r.etw_subscription_started
}
Invoke-TestCase 'EXPORTED_API_ONLY' {
    $exported = @((Get-Module SumiGuard.OsProcessIntegration).ExportedFunctions.Keys)
    $exported.Count -eq 1 -and $exported[0] -ceq 'Invoke-SumiGuardOsProcessIntegration'
}

$failed = @($results | Where-Object { -not $_.pass }).Count
[pscustomobject][ordered]@{
    success = ($failed -eq 0 -and $results.Count -eq 22)
    test_count = $results.Count
    passed_count = $results.Count - $failed
    failed_count = $failed
    real_os_read_performed = $false
    process_started = $false
    wmi_subscription_started = $false
    etw_subscription_started = $false
    results = $results.ToArray()
} | ConvertTo-Json -Compress -Depth 5
if ($failed -gt 0 -or $results.Count -ne 22) { exit 1 }
