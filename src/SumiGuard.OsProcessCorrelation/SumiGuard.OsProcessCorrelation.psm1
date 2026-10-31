Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Pure Phase 4A engine: no process enumeration, WMI/ETW subscription, child
# process, hook, or collection side effect. Evidence is input data only; any
# caller-supplied `trusted` flag is deliberately ignored.
$script:StrictUtcPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
$script:SourcePattern = '^[A-Z][A-Z0-9_]{1,31}$'

function Get-SumiGuardCorrelationValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Test-SumiGuardStrictUtc {
    param([AllowNull()]$Value)
    if ($Value -isnot [string] -or $Value -cnotmatch $script:StrictUtcPattern) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value, 'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)
}
function Test-SumiGuardPositivePid {
    param([AllowNull()]$Value)
    if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
    return ($Value -gt 0 -and $Value -le [int]::MaxValue)
}
function Test-SumiGuardExecutablePath {
    param([AllowNull()]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    try { return [IO.Path]::IsPathRooted($Value) -and -not $Value.EndsWith('\\') -and -not $Value.EndsWith('/') } catch { return $false }
}
function Test-SumiGuardIdentityShape {
    param([AllowNull()]$Object)
    return (Test-SumiGuardPositivePid (Get-SumiGuardCorrelationValue $Object 'observed_pid')) -and (Test-SumiGuardStrictUtc (Get-SumiGuardCorrelationValue $Object 'observed_start_time_utc')) -and (Test-SumiGuardExecutablePath (Get-SumiGuardCorrelationValue $Object 'observed_executable_path'))
}
function Test-SumiGuardObservationShape {
    param([AllowNull()]$Observation)
    if (-not (Test-SumiGuardIdentityShape $Observation)) { return $false }
    $source = Get-SumiGuardCorrelationValue $Observation 'observation_source'
    $sequence = Get-SumiGuardCorrelationValue -Object $Observation -Name 'observation_sequence'
    return ($source -is [string] -and $source -cmatch $script:SourcePattern -and (Test-SumiGuardStrictUtc (Get-SumiGuardCorrelationValue -Object $Observation -Name 'collected_at_utc')) -and (Get-SumiGuardCorrelationValue -Object $Observation -Name 'start_time_precision') -ceq 'TICKS_100NS' -and (Get-SumiGuardCorrelationValue -Object $Observation -Name 'collection_status') -ceq 'COLLECTED' -and $sequence -is [int] -and $sequence -in @(1,2))
}
function Test-SumiGuardSameIdentity {
    param([Parameter(Mandatory = $true)]$Left, [Parameter(Mandatory = $true)]$Right)
    return ((Get-SumiGuardCorrelationValue $Left 'observed_pid') -eq (Get-SumiGuardCorrelationValue $Right 'observed_pid')) -and ((Get-SumiGuardCorrelationValue $Left 'observed_start_time_utc') -ceq (Get-SumiGuardCorrelationValue $Right 'observed_start_time_utc')) -and [string]::Equals([string](Get-SumiGuardCorrelationValue $Left 'observed_executable_path'), [string](Get-SumiGuardCorrelationValue $Right 'observed_executable_path'), [StringComparison]::OrdinalIgnoreCase)
}
function ConvertTo-SumiGuardCorrelationResult {
    param([Parameter(Mandatory = $true)][ValidateSet('DIRECT_MATCH', 'INFERRED_MATCH', 'UNMATCHED')][string]$Status, [Parameter(Mandatory = $true)][string]$ReasonCode, [object[]]$Observations = @(), [ValidateRange(0,2)][int]$AcceptedObservationCount = 0)
    return [pscustomobject][ordered]@{ correlation_status = $Status; correlation_reason_code = $ReasonCode; observation_collection_states = @($Observations | ForEach-Object { Get-SumiGuardCorrelationValue -Object $_ -Name 'collection_status' }); accepted_observation_count = $AcceptedObservationCount; direct_match_operationally_enabled = $false }
}
function ConvertTo-SumiGuardUtcTimestamp {
    param([Parameter(Mandatory = $true)][string]$Value)
    # StrictUtc validation runs before this parser. A literal Z denotes UTC.
    return [DateTime]::ParseExact($Value, 'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
}
function Resolve-SumiGuardOsProcessCorrelation {
    # Module-private test seam. It is intentionally not exported: callers of
    # the public API cannot opt into DIRECT_MATCH before provenance-bound
    # collection is implemented.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$ProcessEvidence, [AllowNull()][object[]]$OsObservations = @(), [switch]$AllowSyntheticDirectMatch)
    try {
        if (-not (Test-SumiGuardIdentityShape -Object $ProcessEvidence)) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'EVIDENCE_IDENTITY_INVALID' -Observations $OsObservations }
        # A caller-controlled Phase 3 status is not attestation. An explicitly
        # unconfirmed status must block even a synthetic inferred match.
        if ((Get-SumiGuardCorrelationValue -Object $ProcessEvidence -Name 'process_confirmation_status') -cne 'PROCESS_CONFIRMED') { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'PHASE3_NOT_CONFIRMED' -Observations $OsObservations }
        $observations = @($OsObservations)
        if ($observations.Count -eq 0 -or $observations.Count -ne 2) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_CARDINALITY_INVALID' -Observations $observations }
        foreach ($observation in $observations) { if (-not (Test-SumiGuardObservationShape $observation)) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_INVALID_OR_UNAVAILABLE' -Observations $observations } }
        # Phase 4A accepts two ordered readings of one named source (e.g. WMI).
        # Matching source labels alone do not prove independent collection.
        $source1 = [string](Get-SumiGuardCorrelationValue -Object $observations[0] -Name 'observation_source')
        $source2 = [string](Get-SumiGuardCorrelationValue -Object $observations[1] -Name 'observation_source')
        if ($source1 -cne $source2) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_SOURCE_MISMATCH' -Observations $observations }
        if ((Get-SumiGuardCorrelationValue -Object $observations[0] -Name 'observation_sequence') -ne 1 -or (Get-SumiGuardCorrelationValue -Object $observations[1] -Name 'observation_sequence') -ne 2) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_ORDER_INVALID' -Observations $observations }
        $startTime = ConvertTo-SumiGuardUtcTimestamp -Value (Get-SumiGuardCorrelationValue -Object $ProcessEvidence -Name 'observed_start_time_utc')
        $firstTime = ConvertTo-SumiGuardUtcTimestamp -Value (Get-SumiGuardCorrelationValue -Object $observations[0] -Name 'collected_at_utc')
        $secondTime = ConvertTo-SumiGuardUtcTimestamp -Value (Get-SumiGuardCorrelationValue -Object $observations[1] -Name 'collected_at_utc')
        if ($firstTime -lt $startTime) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_BEFORE_PROCESS_START' -Observations $observations }
        if ($secondTime -le $firstTime) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_TIME_ORDER_INVALID' -Observations $observations }
        # Bounded relative windows are shape checks, not proof of wall-clock
        # freshness or of the origin of caller-supplied timestamps.
        if (($firstTime - $startTime).TotalSeconds -gt 5 -or ($secondTime - $firstTime).TotalSeconds -gt 2) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'OBSERVATION_WINDOW_EXCEEDED' -Observations $observations }
        if (-not (Test-SumiGuardSameIdentity -Left $observations[0] -Right $observations[1])) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'DUAL_OBSERVATION_DISAGREEMENT' -Observations $observations }
        if (-not (Test-SumiGuardSameIdentity -Left $ProcessEvidence -Right $observations[0])) { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'IDENTITY_MISMATCH_OR_PID_REUSE' -Observations $observations }
        if (-not $AllowSyntheticDirectMatch) { return ConvertTo-SumiGuardCorrelationResult -Status 'INFERRED_MATCH' -ReasonCode 'DIRECT_MATCH_PROVENANCE_NOT_ENABLED' -Observations $observations -AcceptedObservationCount 2 }
        return ConvertTo-SumiGuardCorrelationResult -Status 'DIRECT_MATCH' -ReasonCode 'SYNTHETIC_DUAL_OBSERVATION_MATCH' -Observations $observations -AcceptedObservationCount 2
    } catch { return ConvertTo-SumiGuardCorrelationResult -Status 'UNMATCHED' -ReasonCode 'CORRELATION_INPUT_EXCEPTION' -Observations $OsObservations }
}
function Invoke-SumiGuardOsProcessCorrelation {
    <#
    Pure production-facing correlation API. Exact, dual observations can only
    produce INFERRED_MATCH until a provenance-bound collection path exists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$ProcessEvidence, [AllowNull()][object[]]$OsObservations = @())
    return Resolve-SumiGuardOsProcessCorrelation -ProcessEvidence $ProcessEvidence -OsObservations $OsObservations
}
Export-ModuleMember -Function @('Invoke-SumiGuardOsProcessCorrelation')
