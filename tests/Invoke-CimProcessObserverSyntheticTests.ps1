[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\SumiGuard.CimProcessObserver\SumiGuard.CimProcessObserver.psd1') -Force
Import-Module (Join-Path $root 'src\SumiGuard.OsProcessCorrelation\SumiGuard.OsProcessCorrelation.psd1') -Force
$module = Get-Module SumiGuard.CimProcessObserver
$fixedStart = [DateTime]::SpecifyKind([datetime]'2026-10-31T01:02:03', [DateTimeKind]::Utc)
$results = New-Object 'System.Collections.Generic.List[object]'
$planned = @(
    'NO_OPT_IN_NO_READ', 'PUBLIC_API_HAS_NO_ARBITRARY_PID',
    'TWO_SYNTHETIC_READS', 'SAME_CIM_SOURCE_AND_SEQUENCE',
    'PRECISION_IS_NOT_UPGRADED', 'CORRELATION_NOT_READY',
    'PHASE4A_REJECTS_UNVERIFIED_CIM_PRECISION',
    'PROCESS_NOT_FOUND', 'PROCESS_EXITS_BETWEEN_READS',
    'ACCESS_DENIED', 'CIM_EXCEPTION', 'MULTIPLE_CANDIDATES',
    'PID_MISMATCH', 'INVALID_OBSERVED_PID',
    'CREATION_DATE_MISSING', 'CREATION_DATE_UNSUPPORTED',
    'CREATION_DATE_TIMEZONE_UNKNOWN', 'FUTURE_START_REJECTED',
    'EXECUTABLE_PATH_MISSING', 'EXECUTABLE_PATH_INVALID',
    'DUAL_OBSERVATION_PID_REUSE', 'DUAL_OBSERVATION_PATH_CHANGE',
    'PRIVATE_CAPTURE_NOT_EXPORTED', 'NO_BACKGROUND_ACTIVATION'
)

function Get-SumiGuardTestRow {
    param(
        [object]$RowPid = [uint32]4242,
        [AllowNull()]$CreationDate = $fixedStart,
        [AllowNull()]$ExecutablePath = 'C:\Synthetic\powershell.exe'
    )
    return [pscustomobject]@{
        ProcessId = $RowPid
        CreationDate = $CreationDate
        ExecutablePath = $ExecutablePath
    }
}
function Get-SumiGuardTestReader {
    param([AllowNull()]$First, [AllowNull()]$Second)
    $one = $First
    $two = $Second
    return {
        param($TargetPid, $Sequence)
        if ($TargetPid -ne 4242) { throw 'Unexpected synthetic PID' }
        if ($Sequence -eq 1) { $one } else { $two }
    }.GetNewClosure()
}
function Invoke-SumiGuardTestCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Reader)
    return & $module {
        param($MockReader)
        Invoke-SumiGuardCimCapture -ExpectedPid 4242 -ReadInstance $MockReader
    } $Reader
}
function Invoke-SumiGuardTestCase {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
    $passed = $false
    $detail = ''
    try { $passed = [bool](& $Body) }
    catch { $detail = $_.Exception.GetType().FullName }
    $results.Add([pscustomobject]@{ name = $Name; pass = $passed; detail = $detail })
}

Invoke-SumiGuardTestCase 'NO_OPT_IN_NO_READ' {
    $r = Invoke-SumiGuardSelfProcessCimObserver
    $r.collection_status -ceq 'OPT_IN_REQUIRED' -and -not $r.read_performed -and $r.observation_count -eq 0
}
Invoke-SumiGuardTestCase 'PUBLIC_API_HAS_NO_ARBITRARY_PID' {
    $cmd = Get-Command Invoke-SumiGuardSelfProcessCimObserver
    $cmd.Parameters.Keys -notcontains 'ProcessId' -and $cmd.Parameters.Keys -contains 'RunSelfRead'
}
Invoke-SumiGuardTestCase 'TWO_SYNTHETIC_READS' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) (Get-SumiGuardTestRow))
    $r.collection_status -ceq 'OBSERVED_LOW_PRECISION' -and $r.collection_succeeded -and $r.observation_count -eq 2
}
Invoke-SumiGuardTestCase 'SAME_CIM_SOURCE_AND_SEQUENCE' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) (Get-SumiGuardTestRow))
    $r.observation_count -eq 2 -and $r.observations[0].observation_source -ceq 'CIM' -and
        $r.observations[1].observation_source -ceq 'CIM' -and
        $r.observations[0].observation_sequence -eq 1 -and $r.observations[1].observation_sequence -eq 2
}
Invoke-SumiGuardTestCase 'PRECISION_IS_NOT_UPGRADED' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) (Get-SumiGuardTestRow))
    $r.observation_count -eq 2 -and
        @($r.observations | Where-Object { $_.start_time_precision -cne 'CIM_DATETIME_UNVERIFIED' }).Count -eq 0
}
Invoke-SumiGuardTestCase 'CORRELATION_NOT_READY' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) (Get-SumiGuardTestRow))
    -not $r.correlation_ready -and -not $r.direct_match_operationally_enabled -and
        $r.correlation_block_reason -ceq 'CIM_START_TIME_PRECISION_UNVERIFIED'
}
Invoke-SumiGuardTestCase 'PHASE4A_REJECTS_UNVERIFIED_CIM_PRECISION' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) (Get-SumiGuardTestRow))
    $e = [pscustomobject]@{
        observed_pid = 4242
        observed_start_time_utc = $r.observations[0].observed_start_time_utc
        observed_executable_path = 'C:\Synthetic\powershell.exe'
        process_confirmation_status = 'PROCESS_CONFIRMED'
    }
    $correlation = Invoke-SumiGuardOsProcessCorrelation -ProcessEvidence $e -OsObservations $r.observations
    $correlation.correlation_status -ceq 'UNMATCHED' -and
        $correlation.correlation_reason_code -ceq 'OBSERVATION_INVALID_OR_UNAVAILABLE'
}
Invoke-SumiGuardTestCase 'PROCESS_NOT_FOUND' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First @() -Second (Get-SumiGuardTestRow))).collection_status -ceq 'PROCESS_NOT_FOUND'
}
Invoke-SumiGuardTestCase 'PROCESS_EXITS_BETWEEN_READS' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow) -Second @())
    $r.collection_status -ceq 'PROCESS_EXITED_BEFORE_SECOND_READ' -and $r.observation_count -eq 1
}
Invoke-SumiGuardTestCase 'ACCESS_DENIED' {
    $reader = { throw [UnauthorizedAccessException]::new('synthetic') }
    (Invoke-SumiGuardTestCapture $reader).collection_status -ceq 'ACCESS_DENIED'
}
Invoke-SumiGuardTestCase 'CIM_EXCEPTION' {
    $reader = { throw [InvalidOperationException]::new('synthetic') }
    (Invoke-SumiGuardTestCapture $reader).collection_status -ceq 'CIM_READ_FAILED'
}
Invoke-SumiGuardTestCase 'MULTIPLE_CANDIDATES' {
    $r = Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First @((Get-SumiGuardTestRow),(Get-SumiGuardTestRow)) -Second @())
    $r.collection_status -ceq 'MULTIPLE_CANDIDATES' -and $r.observation_count -eq 0
}
Invoke-SumiGuardTestCase 'PID_MISMATCH' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -RowPid 4243) -Second @())).collection_status -ceq 'PID_MISMATCH'
}
Invoke-SumiGuardTestCase 'INVALID_OBSERVED_PID' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -RowPid 0) -Second @())).collection_status -ceq 'INVALID_OBSERVED_PID'
}
Invoke-SumiGuardTestCase 'CREATION_DATE_MISSING' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -CreationDate $null) -Second @())).collection_status -ceq 'CREATION_DATE_MISSING'
}
Invoke-SumiGuardTestCase 'CREATION_DATE_UNSUPPORTED' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -CreationDate 'DMTF string') -Second @())).collection_status -ceq 'CREATION_DATE_UNSUPPORTED'
}
Invoke-SumiGuardTestCase 'CREATION_DATE_TIMEZONE_UNKNOWN' {
    $date = [DateTime]::SpecifyKind($fixedStart, [DateTimeKind]::Unspecified)
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -CreationDate $date) -Second @())).collection_status -ceq 'CREATION_DATE_TIMEZONE_UNKNOWN'
}
Invoke-SumiGuardTestCase 'FUTURE_START_REJECTED' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -CreationDate ([DateTime]::UtcNow.AddMinutes(1))) -Second @())).collection_status -ceq 'INVALID_TIME_ORDER'
}
Invoke-SumiGuardTestCase 'EXECUTABLE_PATH_MISSING' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -ExecutablePath $null) -Second @())).collection_status -ceq 'EXECUTABLE_PATH_MISSING'
}
Invoke-SumiGuardTestCase 'EXECUTABLE_PATH_INVALID' {
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader -First (Get-SumiGuardTestRow -ExecutablePath 'relative.exe') -Second @())).collection_status -ceq 'EXECUTABLE_PATH_INVALID'
}
Invoke-SumiGuardTestCase 'DUAL_OBSERVATION_PID_REUSE' {
    $other = Get-SumiGuardTestRow -CreationDate ($fixedStart.AddSeconds(1))
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) $other)).collection_status -ceq 'DUAL_OBSERVATION_MISMATCH'
}
Invoke-SumiGuardTestCase 'DUAL_OBSERVATION_PATH_CHANGE' {
    $other = Get-SumiGuardTestRow -ExecutablePath 'C:\Synthetic\other.exe'
    (Invoke-SumiGuardTestCapture (Get-SumiGuardTestReader (Get-SumiGuardTestRow) $other)).collection_status -ceq 'DUAL_OBSERVATION_MISMATCH'
}
Invoke-SumiGuardTestCase 'PRIVATE_CAPTURE_NOT_EXPORTED' {
    $exports = @(Get-Module SumiGuard.CimProcessObserver | ForEach-Object { $_.ExportedFunctions.Keys })
    $exports.Count -eq 1 -and $exports[0] -ceq 'Invoke-SumiGuardSelfProcessCimObserver'
}
Invoke-SumiGuardTestCase 'NO_BACKGROUND_ACTIVATION' {
    $r = Invoke-SumiGuardSelfProcessCimObserver
    -not $r.process_started -and -not $r.wmi_subscription_started -and -not $r.etw_subscription_started
}

$executed = @($results | ForEach-Object { $_.name })
$duplicates = @($executed | Group-Object | Where-Object { $_.Count -ne 1 } | ForEach-Object { $_.Name })
$unexecuted = @($planned | Where-Object { $_ -notin $executed })
$unexpected = @($executed | Where-Object { $_ -notin $planned })
$failed = @($results | Where-Object { -not $_.pass }).Count
$success = $failed -eq 0 -and $duplicates.Count -eq 0 -and $unexecuted.Count -eq 0 -and $unexpected.Count -eq 0
[pscustomobject][ordered]@{
    success = $success
    test_count = $results.Count
    passed_count = $results.Count - $failed
    failed_count = $failed
    unexecuted_cases = $unexecuted
    duplicate_cases = $duplicates
    unexpected_cases = $unexpected
    real_cim_read_performed = $false
    process_started = $false
    wmi_subscription_started = $false
    etw_subscription_started = $false
    results = $results.ToArray()
} | ConvertTo-Json -Compress -Depth 5
if (-not $success) { exit 1 }
