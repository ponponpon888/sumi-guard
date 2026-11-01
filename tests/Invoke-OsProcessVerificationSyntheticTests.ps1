[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\SumiGuard.OsProcessIntegration\SumiGuard.OsProcessIntegration.psd1') -Force
$results = New-Object 'System.Collections.Generic.List[object]'

function Get-VerificationEvidence {
    return [pscustomobject]@{
        process_confirmation_status = 'PROCESS_CONFIRMED'
        observed_pid = 4242
        observed_start_time_utc = '2026-10-31T01:02:03.1234567Z'
        observed_executable_path = 'C:\Synthetic\powershell.exe'
    }
}
function Get-VerificationObserver {
    $rows = @(
        [pscustomobject]@{ observation_source='CIM'; observation_sequence=1; observed_pid=4242; observed_start_time_utc='2026-10-31T01:02:03.1234567Z'; observed_executable_path='C:\Synthetic\powershell.exe'; collected_at_utc='2026-10-31T01:02:04.1234567Z'; start_time_precision='CIM_DATETIME_UNVERIFIED'; collection_status='COLLECTED' }
        [pscustomobject]@{ observation_source='CIM'; observation_sequence=2; observed_pid=4242; observed_start_time_utc='2026-10-31T01:02:03.1234567Z'; observed_executable_path='C:\Synthetic\powershell.exe'; collected_at_utc='2026-10-31T01:02:04.2234567Z'; start_time_precision='CIM_DATETIME_UNVERIFIED'; collection_status='COLLECTED' }
    )
    return [pscustomobject]@{
        collection_status='OBSERVED_LOW_PRECISION'
        collection_succeeded=$true
        read_performed=$true
        correlation_ready=$false
        direct_match_operationally_enabled=$false
        observation_count=2
        observations=$rows
    }
}
function Invoke-VerificationCase {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
    $passed = $false
    $detail = ''
    try { $passed = [bool](& $Body) }
    catch { $detail = $_.Exception.GetType().FullName }
    [void]$results.Add([pscustomobject]@{ name=$Name; pass=$passed; detail=$detail })
}
function Test-VerificationReason {
    param([Parameter(Mandatory = $true)][string]$Reason, [AllowNull()]$Evidence, [AllowNull()]$Observer)
    $result = Invoke-SumiGuardOsProcessIntegration -ProcessEvidence $Evidence -CimObserverResult $Observer
    return $result.correlation_reason_code -ceq $Reason -and
        $result.correlation_status -ceq 'UNMATCHED' -and
        $result.integration_status -ceq 'BLOCKED' -and
        $result.accepted_observation_count -eq 0 -and
        -not $result.direct_match_operationally_enabled -and -not $result.correlation_ready
}

Invoke-VerificationCase 'BASELINE_LOW_PRECISION' { Test-VerificationReason -Reason 'CIM_START_TIME_PRECISION_UNVERIFIED' -Evidence (Get-VerificationEvidence) -Observer (Get-VerificationObserver) }
Invoke-VerificationCase 'EVIDENCE_OFFSET_FORMAT_REJECTED' { $e=Get-VerificationEvidence;$e.observed_start_time_utc='2026-10-31T01:02:03.1234567+00:00';Test-VerificationReason -Reason 'TIMESTAMP_FORMAT_INVALID' -Evidence $e -Observer (Get-VerificationObserver) }
Invoke-VerificationCase 'INVALID_CALENDAR_REJECTED' { $o=Get-VerificationObserver;$o.observations[0].observed_start_time_utc='2026-13-31T01:02:03.1234567Z';Test-VerificationReason -Reason 'TIMESTAMP_FORMAT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'MISSING_COLLECTION_TIME_REJECTED' { $o=Get-VerificationObserver;$o.observations[0].collected_at_utc=$null;Test-VerificationReason -Reason 'TIMESTAMP_FORMAT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'NONSTRING_COLLECTION_TIME_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].collected_at_utc=12;Test-VerificationReason -Reason 'TIMESTAMP_FORMAT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'NONCANONICAL_UTC_REJECTED' { $o=Get-VerificationObserver;$o.observations[0].collected_at_utc='2026-10-31T01:02:04Z';Test-VerificationReason -Reason 'TIMESTAMP_FORMAT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'BEFORE_START_REJECTED' { $o=Get-VerificationObserver;$o.observations[0].collected_at_utc='2026-10-31T01:02:02.1234567Z';Test-VerificationReason -Reason 'OBSERVATION_BEFORE_PROCESS_START' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'REVERSED_OBSERVATION_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].collected_at_utc='2026-10-31T01:02:04.0234567Z';Test-VerificationReason -Reason 'OBSERVATION_TIME_ORDER_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'EQUAL_OBSERVATION_TIME_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].collected_at_utc=$o.observations[0].collected_at_utc;Test-VerificationReason -Reason 'OBSERVATION_TIME_ORDER_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'LATE_FIRST_OBSERVATION_REJECTED' { $o=Get-VerificationObserver;$o.observations[0].collected_at_utc='2026-10-31T01:02:10.1234567Z';$o.observations[1].collected_at_utc='2026-10-31T01:02:10.2234567Z';Test-VerificationReason -Reason 'OBSERVATION_WINDOW_EXCEEDED' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'LARGE_INTEROBSERVATION_GAP_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].collected_at_utc='2026-10-31T01:02:07.2234567Z';Test-VerificationReason -Reason 'OBSERVATION_WINDOW_EXCEEDED' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'START_TIME_DISAGREEMENT_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].observed_start_time_utc='2026-10-31T01:02:03.2234567Z';Test-VerificationReason -Reason 'IDENTITY_DISAGREEMENT' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'PID_REUSE_SIMULATED_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].observed_pid=4343;Test-VerificationReason -Reason 'IDENTITY_DISAGREEMENT' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'PATH_TAMPER_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].observed_executable_path='C:\Synthetic\other.exe';Test-VerificationReason -Reason 'IDENTITY_DISAGREEMENT' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'PHASE3_STATUS_PRIORITY' { $e=Get-VerificationEvidence;$e.process_confirmation_status='PROCESS_UNVERIFIED';$o=Get-VerificationObserver;$o.observations[0].collected_at_utc='bad';Test-VerificationReason -Reason 'PHASE3_NOT_CONFIRMED' -Evidence $e -Observer $o }
Invoke-VerificationCase 'PRECISION_SPOOF_PRIORITY' { $o=Get-VerificationObserver;$o.observations[0].start_time_precision='TICKS_100NS';$o.observations[0].collected_at_utc='bad';Test-VerificationReason -Reason 'PRECISION_ESCALATION_REJECTED' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'READY_FLAG_SPOOF_REJECTED' { $o=Get-VerificationObserver;$o.correlation_ready=$true;Test-VerificationReason -Reason 'CIM_CONTRACT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'DIRECT_FLAG_SPOOF_REJECTED' { $o=Get-VerificationObserver;$o.direct_match_operationally_enabled=$true;Test-VerificationReason -Reason 'CIM_CONTRACT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'SOURCE_TAMPER_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].observation_source='ETW';Test-VerificationReason -Reason 'OBSERVATION_CONTRACT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'SEQUENCE_TAMPER_REJECTED' { $o=Get-VerificationObserver;$o.observations[1].observation_sequence=1;Test-VerificationReason -Reason 'OBSERVATION_CONTRACT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'NO_READ_REJECTED' { $o=Get-VerificationObserver;$o.read_performed=$false;Test-VerificationReason -Reason 'CIM_CONTRACT_INVALID' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'FAILED_COLLECTION_REJECTED' { $o=Get-VerificationObserver;$o.collection_status='ACCESS_DENIED';Test-VerificationReason -Reason 'CIM_COLLECTION_NOT_SUCCESSFUL' -Evidence (Get-VerificationEvidence) -Observer $o }
Invoke-VerificationCase 'INPUTS_NOT_MUTATED' { $o=Get-VerificationObserver;$e=Get-VerificationEvidence;$beforeE=ConvertTo-Json -InputObject $e -Compress -Depth 5;$beforeO=ConvertTo-Json -InputObject $o -Compress -Depth 5;[void](Invoke-SumiGuardOsProcessIntegration -ProcessEvidence $e -CimObserverResult $o);(ConvertTo-Json -InputObject $e -Compress -Depth 5) -ceq $beforeE -and (ConvertTo-Json -InputObject $o -Compress -Depth 5) -ceq $beforeO }
Invoke-VerificationCase 'NO_OS_ACTIVATION' { $r=Invoke-SumiGuardOsProcessIntegration -ProcessEvidence (Get-VerificationEvidence) -CimObserverResult (Get-VerificationObserver);-not $r.os_collection_performed -and -not $r.process_started -and -not $r.wmi_subscription_started -and -not $r.etw_subscription_started }

$failed = @($results | Where-Object { -not $_.pass }).Count
$success = ($failed -eq 0 -and $results.Count -eq 24)
[pscustomobject][ordered]@{
    success=$success
    test_count=$results.Count
    passed_count=$results.Count - $failed
    failed_count=$failed
    real_os_read_performed=$false
    process_started=$false
    wmi_subscription_started=$false
    etw_subscription_started=$false
    results=$results.ToArray()
} | ConvertTo-Json -Compress -Depth 5
if (-not $success) { exit 1 }
