Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Phase 4C: pure diagnostic connection of caller-supplied Phase 3 evidence,
# Phase 4B observer results, and the Phase 4A PUBLIC correlation API.
# This module NEVER collects OS data, changes Phase 3 confirmation, or promotes
# any CIM result into INFERRED_MATCH or DIRECT_MATCH. Caller input is not an
# attestation; the result is not proof of provenance or of process identity.

function Get-SumiGuardIntegrationValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Get-SumiGuardIntegrationResult {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Phase4AReason = 'NOT_EVALUATED',
        [bool]$Phase4AEvaluated = $false
    )
    return [pscustomobject][ordered]@{
        integration_status = 'BLOCKED'
        correlation_status = 'UNMATCHED'
        correlation_reason_code = $Reason
        phase4a_reason_code = $Phase4AReason
        phase4a_evaluated = $Phase4AEvaluated
        accepted_observation_count = 0
        correlation_ready = $false
        direct_match_operationally_enabled = $false
        os_collection_performed = $false
        process_started = $false
        wmi_subscription_started = $false
        etw_subscription_started = $false
    }
}

# Phase 4D diagnostic checks: date shape and RELATIVE time windows only.
# Strings and clock values supplied by callers are not provenance evidence.
function Get-SumiGuardIntegrationTimeReason {
    param([AllowNull()]$Evidence, [Parameter(Mandatory = $true)][object[]]$Observations)
    $values = @(
        (Get-SumiGuardIntegrationValue $Evidence 'observed_start_time_utc')
        (Get-SumiGuardIntegrationValue $Observations[0] 'observed_start_time_utc')
        (Get-SumiGuardIntegrationValue $Observations[1] 'observed_start_time_utc')
        (Get-SumiGuardIntegrationValue $Observations[0] 'collected_at_utc')
        (Get-SumiGuardIntegrationValue $Observations[1] 'collected_at_utc')
    )
    $pattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
    $parsed = New-Object 'System.Collections.Generic.List[datetime]'
    foreach ($value in $values) {
        if ($value -isnot [string] -or $value -cnotmatch $pattern) {
            return 'TIMESTAMP_FORMAT_INVALID'
        }
        $stamp = [datetime]::MinValue
        $valid = [datetime]::TryParseExact(
            $value, "yyyy-MM-ddTHH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$stamp)
        if (-not $valid) { return 'TIMESTAMP_FORMAT_INVALID' }
        [void]$parsed.Add($stamp)
    }
    if ($parsed[3] -lt $parsed[0]) { return 'OBSERVATION_BEFORE_PROCESS_START' }
    if ($parsed[4] -le $parsed[3]) { return 'OBSERVATION_TIME_ORDER_INVALID' }
    if (($parsed[3] - $parsed[0]).TotalSeconds -gt 5 -or
        ($parsed[4] - $parsed[3]).TotalSeconds -gt 2) {
        return 'OBSERVATION_WINDOW_EXCEEDED'
    }
    return ''
}

function Test-SumiGuardIntegrationIdentity {
    param([AllowNull()]$Evidence, [AllowNull()]$First, [AllowNull()]$Second)
    $a = Get-SumiGuardIntegrationValue $Evidence 'observed_pid'
    $b = Get-SumiGuardIntegrationValue $First 'observed_pid'
    $c = Get-SumiGuardIntegrationValue $Second 'observed_pid'
    if ($a -isnot [int] -or $b -isnot [int] -or $c -isnot [int]) { return $false }
    if ($a -le 0 -or $a -ne $b -or $b -ne $c) { return $false }

    $starts = @(
        (Get-SumiGuardIntegrationValue $Evidence 'observed_start_time_utc'),
        (Get-SumiGuardIntegrationValue $First 'observed_start_time_utc'),
        (Get-SumiGuardIntegrationValue $Second 'observed_start_time_utc')
    )
    if (@($starts | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { return $false }
    if ($starts[0] -cne $starts[1] -or $starts[1] -cne $starts[2]) { return $false }

    $paths = @(
        (Get-SumiGuardIntegrationValue $Evidence 'observed_executable_path'),
        (Get-SumiGuardIntegrationValue $First 'observed_executable_path'),
        (Get-SumiGuardIntegrationValue $Second 'observed_executable_path')
    )
    if (@($paths | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { return $false }
    if (-not [IO.Path]::IsPathRooted($paths[0]) -or $paths[0].EndsWith('\') -or $paths[0].EndsWith('/')) { return $false }
    return [string]::Equals($paths[0], $paths[1], [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($paths[1], $paths[2], [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-SumiGuardOsProcessIntegration {
    <#
    Only accepts already collected data. Does not call Phase 4B's OS reader.
    Phase 4A is used to produce a diagnostic reason, never an approval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$ProcessEvidence,
        [Parameter(Mandatory = $true)][AllowNull()]$CimObserverResult
    )
    try {
        if ((Get-SumiGuardIntegrationValue $ProcessEvidence 'process_confirmation_status') -cne 'PROCESS_CONFIRMED') {
            return Get-SumiGuardIntegrationResult -Reason 'PHASE3_NOT_CONFIRMED'
        }
        if ((Get-SumiGuardIntegrationValue $CimObserverResult 'collection_status') -cne 'OBSERVED_LOW_PRECISION') {
            return Get-SumiGuardIntegrationResult -Reason 'CIM_COLLECTION_NOT_SUCCESSFUL'
        }
        $read = Get-SumiGuardIntegrationValue $CimObserverResult 'read_performed'
        $ok = Get-SumiGuardIntegrationValue $CimObserverResult 'collection_succeeded'
        $ready = Get-SumiGuardIntegrationValue $CimObserverResult 'correlation_ready'
        $direct = Get-SumiGuardIntegrationValue $CimObserverResult 'direct_match_operationally_enabled'
        if ($read -isnot [bool] -or $read -ne $true -or $ok -isnot [bool] -or $ok -ne $true -or
            $ready -isnot [bool] -or $ready -ne $false -or $direct -isnot [bool] -or $direct -ne $false) {
            return Get-SumiGuardIntegrationResult -Reason 'CIM_CONTRACT_INVALID'
        }
        $count = Get-SumiGuardIntegrationValue $CimObserverResult 'observation_count'
        $raw = Get-SumiGuardIntegrationValue $CimObserverResult 'observations'
        if ($null -eq $raw -or $count -isnot [int] -or $count -ne 2) {
            return Get-SumiGuardIntegrationResult -Reason 'OBSERVATION_CARDINALITY_INVALID'
        }
        $observations = @($raw)
        if ($observations.Count -ne 2) {
            return Get-SumiGuardIntegrationResult -Reason 'OBSERVATION_CARDINALITY_INVALID'
        }
        for ($index = 0; $index -lt 2; $index++) {
            $item = $observations[$index]
            if ((Get-SumiGuardIntegrationValue $item 'observation_source') -cne 'CIM' -or
                (Get-SumiGuardIntegrationValue $item 'collection_status') -cne 'COLLECTED' -or
                (Get-SumiGuardIntegrationValue $item 'observation_sequence') -ne ($index + 1)) {
                return Get-SumiGuardIntegrationResult -Reason 'OBSERVATION_CONTRACT_INVALID'
            }
            if ((Get-SumiGuardIntegrationValue $item 'start_time_precision') -cne 'CIM_DATETIME_UNVERIFIED') {
                return Get-SumiGuardIntegrationResult -Reason 'PRECISION_ESCALATION_REJECTED'
            }
        }
        $timeReason = Get-SumiGuardIntegrationTimeReason -Evidence $ProcessEvidence -Observations $observations
        if (-not [string]::IsNullOrEmpty($timeReason)) {
            return Get-SumiGuardIntegrationResult -Reason $timeReason
        }
        if (-not (Test-SumiGuardIntegrationIdentity -Evidence $ProcessEvidence -First $observations[0] -Second $observations[1])) {
            return Get-SumiGuardIntegrationResult -Reason 'IDENTITY_DISAGREEMENT'
        }

        # Public Phase 4A is diagnostic only. If its behavior ever changes to
        # accept unverified CIM precision, this bridge STILL returns UNMATCHED.
        $manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'SumiGuard.OsProcessCorrelation\SumiGuard.OsProcessCorrelation.psd1'
        Import-Module -Name $manifest -ErrorAction Stop
        $diagnostic = Invoke-SumiGuardOsProcessCorrelation -ProcessEvidence $ProcessEvidence -OsObservations $observations
        if ($null -eq $diagnostic -or (Get-SumiGuardIntegrationValue $diagnostic 'correlation_status') -cne 'UNMATCHED') {
            return Get-SumiGuardIntegrationResult -Reason 'PHASE4A_UNEXPECTED_PROMOTION' -Phase4AEvaluated $true
        }
        return Get-SumiGuardIntegrationResult -Reason 'CIM_START_TIME_PRECISION_UNVERIFIED' -Phase4AReason ([string](Get-SumiGuardIntegrationValue $diagnostic 'correlation_reason_code')) -Phase4AEvaluated $true
    } catch {
        return Get-SumiGuardIntegrationResult -Reason 'INTEGRATION_INPUT_OR_DEPENDENCY_ERROR'
    }
}

Export-ModuleMember -Function @('Invoke-SumiGuardOsProcessIntegration')
