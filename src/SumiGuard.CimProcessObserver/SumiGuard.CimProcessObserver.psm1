Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Phase 4B: local, read-only CIM snapshots. No hook, subscription, service,
# child process, or remote CIM session is created by this module.
# Win32_Process.CreationDate does NOT prove TICKS_100NS source precision.
# Consequently, these observations cannot satisfy Phase 4A's precision gate.

function Get-SumiGuardCimPropertyValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-SumiGuardCimObserverResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [object[]]$Observations = @(),
        [bool]$ReadPerformed = $false,
        [string]$ExceptionType = ''
    )
    return [pscustomobject][ordered]@{
        collection_status = $Status
        observations = @($Observations)
        observation_count = @($Observations).Count
        read_performed = $ReadPerformed
        collection_succeeded = ($Status -ceq 'OBSERVED_LOW_PRECISION')
        correlation_ready = $false
        correlation_block_reason = 'CIM_START_TIME_PRECISION_UNVERIFIED'
        direct_match_operationally_enabled = $false
        process_started = $false
        wmi_subscription_started = $false
        etw_subscription_started = $false
        exception_type = $ExceptionType
    }
}

function ConvertTo-SumiGuardCimObservation {
    param(
        [Parameter(Mandatory = $true)][int]$ExpectedPid,
        [Parameter(Mandatory = $true)][ValidateRange(1,2)][int]$Sequence,
        [AllowNull()]$Snapshot,
        [Parameter(Mandatory = $true)][datetime]$CollectedAtUtc
    )
    try {
        if ($null -eq $Snapshot) {
            return [pscustomobject]@{ status = 'PROCESS_NOT_FOUND'; observation = $null }
        }
        $pidValue = Get-SumiGuardCimPropertyValue $Snapshot 'ProcessId'
        if (($pidValue -isnot [int] -and $pidValue -isnot [uint32] -and $pidValue -isnot [long]) -or
            $pidValue -le 0 -or $pidValue -gt [int]::MaxValue) {
            return [pscustomobject]@{ status = 'INVALID_OBSERVED_PID'; observation = $null }
        }
        if ([int]$pidValue -ne $ExpectedPid) {
            return [pscustomobject]@{ status = 'PID_MISMATCH'; observation = $null }
        }
        $start = Get-SumiGuardCimPropertyValue $Snapshot 'CreationDate'
        if ($null -eq $start) {
            return [pscustomobject]@{ status = 'CREATION_DATE_MISSING'; observation = $null }
        }
        if ($start -isnot [datetime] -or $start -eq [datetime]::MinValue) {
            return [pscustomobject]@{ status = 'CREATION_DATE_UNSUPPORTED'; observation = $null }
        }
        if ($start.Kind -eq [DateTimeKind]::Unspecified) {
            return [pscustomobject]@{ status = 'CREATION_DATE_TIMEZONE_UNKNOWN'; observation = $null }
        }
        $startUtc = $start.ToUniversalTime()
        if ($CollectedAtUtc.Kind -ne [DateTimeKind]::Utc -or $startUtc -gt $CollectedAtUtc) {
            return [pscustomobject]@{ status = 'INVALID_TIME_ORDER'; observation = $null }
        }
        $path = Get-SumiGuardCimPropertyValue $Snapshot 'ExecutablePath'
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{ status = 'EXECUTABLE_PATH_MISSING'; observation = $null }
        }
        if (-not [IO.Path]::IsPathRooted($path) -or $path.EndsWith('\') -or $path.EndsWith('/')) {
            return [pscustomobject]@{ status = 'EXECUTABLE_PATH_INVALID'; observation = $null }
        }
        $utcFormat = 'yyyy-MM-ddTHH:mm:ss.fffffffZ'
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $observation = [pscustomobject][ordered]@{
            observation_source = 'CIM'
            observation_sequence = $Sequence
            observed_pid = [int]$pidValue
            observed_start_time_utc = $startUtc.ToString($utcFormat, $culture)
            observed_executable_path = $path
            collected_at_utc = $CollectedAtUtc.ToString($utcFormat, $culture)
            # Seven-digit serialization is not evidence of 100-ns precision.
            start_time_precision = 'CIM_DATETIME_UNVERIFIED'
            collection_status = 'COLLECTED'
        }
        return [pscustomobject]@{ status = 'OBSERVED_LOW_PRECISION'; observation = $observation }
    } catch {
        return [pscustomobject]@{ status = 'NORMALIZATION_EXCEPTION'; observation = $null }
    }
}

function Invoke-SumiGuardCimCapture {
    # Private synthetic reader seam; no live arbitrary-PID public entry point.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1,2147483647)][int]$ExpectedPid,
        [Parameter(Mandatory = $true)][scriptblock]$ReadInstance
    )
    $observations = New-Object System.Collections.Generic.List[object]
    for ($sequence = 1; $sequence -le 2; $sequence++) {
        $candidates = @()
        try {
            $candidates = @(& $ReadInstance $ExpectedPid $sequence)
        } catch {
            $status = 'CIM_READ_FAILED'
            if ($_.Exception -is [UnauthorizedAccessException] -or
                $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::PermissionDenied) {
                $status = 'ACCESS_DENIED'
            }
            return ConvertTo-SumiGuardCimObserverResult -Status $status -Observations $observations.ToArray() -ReadPerformed $true -ExceptionType $_.Exception.GetType().FullName
        }
        $readCompletedUtc = [DateTime]::UtcNow
        if ($candidates.Count -eq 0) {
            $status = if ($sequence -eq 1) { 'PROCESS_NOT_FOUND' } else { 'PROCESS_EXITED_BEFORE_SECOND_READ' }
            return ConvertTo-SumiGuardCimObserverResult -Status $status -Observations $observations.ToArray() -ReadPerformed $true
        }
        if ($candidates.Count -ne 1) {
            return ConvertTo-SumiGuardCimObserverResult -Status 'MULTIPLE_CANDIDATES' -Observations $observations.ToArray() -ReadPerformed $true
        }
        $converted = ConvertTo-SumiGuardCimObservation -ExpectedPid $ExpectedPid -Sequence $sequence -Snapshot $candidates[0] -CollectedAtUtc $readCompletedUtc
        if ($converted.status -cne 'OBSERVED_LOW_PRECISION') {
            return ConvertTo-SumiGuardCimObserverResult -Status $converted.status -Observations $observations.ToArray() -ReadPerformed $true
        }
        $observations.Add($converted.observation)
    }
    $one = $observations[0]
    $two = $observations[1]
    if ($one.observed_pid -ne $two.observed_pid -or
        $one.observed_start_time_utc -cne $two.observed_start_time_utc -or
        -not [string]::Equals($one.observed_executable_path, $two.observed_executable_path, [StringComparison]::OrdinalIgnoreCase)) {
        return ConvertTo-SumiGuardCimObserverResult -Status 'DUAL_OBSERVATION_MISMATCH' -Observations $observations.ToArray() -ReadPerformed $true
    }
    $firstTime = [DateTime]::ParseExact($one.collected_at_utc, 'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    $secondTime = [DateTime]::ParseExact($two.collected_at_utc, 'yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    if ($secondTime -le $firstTime) {
        return ConvertTo-SumiGuardCimObserverResult -Status 'OBSERVATION_TIME_ORDER_INVALID' -Observations $observations.ToArray() -ReadPerformed $true
    }
    if (($secondTime - $firstTime).TotalSeconds -gt 2) {
        return ConvertTo-SumiGuardCimObserverResult -Status 'OBSERVATION_WINDOW_EXCEEDED' -Observations $observations.ToArray() -ReadPerformed $true
    }
    return ConvertTo-SumiGuardCimObserverResult -Status 'OBSERVED_LOW_PRECISION' -Observations $observations.ToArray() -ReadPerformed $true
}

function Invoke-SumiGuardSelfProcessCimObserver {
    <#
    Only this PowerShell host's PID can be read. Explicit -RunSelfRead is required.
    No caller-specified PID, remote host, or session is accepted. No background
    subscription, persistent monitor, or Phase 4A correlation is started.
    #>
    [CmdletBinding()]
    param([switch]$RunSelfRead)
    if (-not $RunSelfRead) {
        return ConvertTo-SumiGuardCimObserverResult -Status 'OPT_IN_REQUIRED'
    }
    $reader = {
        param([int]$TargetPid, [int]$Sequence)
        if ($Sequence -lt 1 -or $Sequence -gt 2) { throw 'Invalid observer sequence' }
        # Fixed numeric filter. No untrusted WQL or remote computer argument.
        Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $TargetPid) -ErrorAction Stop
    }
    return Invoke-SumiGuardCimCapture -ExpectedPid $PID -ReadInstance $reader
}

Export-ModuleMember -Function @('Invoke-SumiGuardSelfProcessCimObserver')
