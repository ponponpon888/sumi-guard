[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPidFile,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [Parameter(Mandatory = $true)][string]$StopPath,
    [int]$PollMilliseconds = 20,
    [int]$MaximumSeconds = 360
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class SumiProcessInfo
{
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation,
        int processInformationLength,
        out int returnLength);

    public static int GetParentProcessId(Process process)
    {
        PROCESS_BASIC_INFORMATION information = new PROCESS_BASIC_INFORMATION();
        int returnLength;
        int status = NtQueryInformationProcess(
            process.Handle,
            0,
            ref information,
            Marshal.SizeOf(information),
            out returnLength);
        if (status != 0)
        {
            return 0;
        }
        return information.InheritedFromUniqueProcessId.ToInt32();
    }
}
'@

function Get-RootProcessIds {
    if (-not (Test-Path -LiteralPath $RootPidFile -PathType Leaf)) {
        return @()
    }

    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($line in [System.IO.File]::ReadAllLines($RootPidFile)) {
        $value = 0
        if ([int]::TryParse($line, [ref]$value)) {
            $ids.Add($value)
        }
    }
    return $ids.ToArray()
}

function Get-ParentProcessId {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    try {
        return [SumiProcessInfo]::GetParentProcessId($Process)
    }
    catch {
        return 0
    }
}

function Get-MatchingRootProcessId {
    param(
        [Parameter(Mandatory = $true)][int]$ParentProcessId,
        [Parameter(Mandatory = $true)][int[]]$RootProcessIds
    )

    $currentId = $ParentProcessId
    $seen = @{}
    for ($depth = 0; $depth -lt 12 -and $currentId -gt 0; $depth++) {
        if ($RootProcessIds -contains $currentId) {
            return $currentId
        }
        if ($seen.ContainsKey($currentId)) {
            return 0
        }
        $seen[$currentId] = $true

        try {
            $parent = [System.Diagnostics.Process]::GetProcessById($currentId)
            $currentId = Get-ParentProcessId -Process $parent
            $parent.Dispose()
        }
        catch {
            return 0
        }
    }
    return 0
}

function Write-Observation {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Compress -Depth 8
    [System.IO.File]::AppendAllText(
        $OutputPath,
        $json + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false)))
}

$knownProcessIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($name in @('pwsh', 'powershell', 'cmd')) {
    foreach ($process in [System.Diagnostics.Process]::GetProcessesByName($name)) {
        [void]$knownProcessIds.Add($process.Id)
        $process.Dispose()
    }
}

[System.IO.File]::WriteAllText(
    $ReadyPath,
    [DateTimeOffset]::UtcNow.ToString('o'),
    (New-Object System.Text.UTF8Encoding($false)))

$deadline = [DateTime]::UtcNow.AddSeconds($MaximumSeconds)
$pollClock = [System.Diagnostics.Stopwatch]::StartNew()
$previousPollTicks = $null
$pollIntervalCount = 0L
$pollIntervalSumMilliseconds = 0.0
$pollIntervalMinimumMilliseconds = [double]::PositiveInfinity
$pollIntervalMaximumMilliseconds = 0.0
while (-not (Test-Path -LiteralPath $StopPath) -and [DateTime]::UtcNow -lt $deadline) {
    $currentPollTicks = $pollClock.ElapsedTicks
    if ($null -ne $previousPollTicks) {
        $pollIntervalMilliseconds =
            (($currentPollTicks - $previousPollTicks) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency
        $pollIntervalCount++
        $pollIntervalSumMilliseconds += $pollIntervalMilliseconds
        if ($pollIntervalMilliseconds -lt $pollIntervalMinimumMilliseconds) {
            $pollIntervalMinimumMilliseconds = $pollIntervalMilliseconds
        }
        if ($pollIntervalMilliseconds -gt $pollIntervalMaximumMilliseconds) {
            $pollIntervalMaximumMilliseconds = $pollIntervalMilliseconds
        }
    }
    $previousPollTicks = $currentPollTicks

    $rootProcessIds = @(Get-RootProcessIds)
    if ($rootProcessIds.Count -eq 0) {
        Start-Sleep -Milliseconds $PollMilliseconds
        continue
    }

    foreach ($name in @('pwsh', 'powershell', 'cmd')) {
        foreach ($process in [System.Diagnostics.Process]::GetProcessesByName($name)) {
            try {
                if ($knownProcessIds.Contains($process.Id)) {
                    continue
                }
                [void]$knownProcessIds.Add($process.Id)

                $parentProcessId = Get-ParentProcessId -Process $process
                $matchedRootId = Get-MatchingRootProcessId `
                    -ParentProcessId $parentProcessId `
                    -RootProcessIds $rootProcessIds
                if ($matchedRootId -eq 0) {
                    continue
                }

                $executablePath = $null
                try {
                    $executablePath = [string]$process.MainModule.FileName
                }
                catch {
                }

                $startTime = $null
                try {
                    $startTime = $process.StartTime.ToUniversalTime().ToString('o')
                }
                catch {
                    $startTime = [DateTime]::UtcNow.ToString('o')
                }

                Write-Observation -Value ([ordered]@{
                    event_type = 'ProcessObserved'
                    observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
                    process_start_time_utc = $startTime
                    source = 'NativeProcessPolling'
                    process_name = $process.ProcessName + '.exe'
                    executable_path = $executablePath
                    process_id = $process.Id
                    parent_process_id = $parentProcessId
                    matched_root_process_id = $matchedRootId
                    command_line_collected = $false
                })
            }
            finally {
                $process.Dispose()
            }
        }
    }

    Start-Sleep -Milliseconds $PollMilliseconds
}

Write-Observation -Value ([ordered]@{
    event_type = 'ObserverTimingSummary'
    observed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    source = 'NativeProcessPolling'
    configured_poll_milliseconds = $PollMilliseconds
    measured_interval_count = $pollIntervalCount
    measured_interval_average_milliseconds = if ($pollIntervalCount -gt 0) {
        $pollIntervalSumMilliseconds / $pollIntervalCount
    } else { $null }
    measured_interval_minimum_milliseconds = if ($pollIntervalCount -gt 0) {
        $pollIntervalMinimumMilliseconds
    } else { $null }
    measured_interval_maximum_milliseconds = if ($pollIntervalCount -gt 0) {
        $pollIntervalMaximumMilliseconds
    } else { $null }
})
