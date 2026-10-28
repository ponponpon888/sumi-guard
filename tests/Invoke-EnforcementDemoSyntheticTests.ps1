[CmdletBinding()]
param()

# Synthetic test for demo/Start-SumiGuardEnforcementDemo.ps1.
#
# Runs the demo once in a separate Windows PowerShell 5.1 process with
# -AdapterMode SYNTHETIC, so the hook's test seam stands in for the
# DPAPI-protected body store and no host is involved. The hook itself, its
# standard input path, the operator setting, the kill switch and the notice
# file are the real ones. What this cannot show (the real encrypted store,
# a host honouring the deny) is left to the operator run and gates 2 and 4.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$demoPath = Join-Path -Path $projectRoot -ChildPath 'demo\Start-SumiGuardEnforcementDemo.ps1'
$powerShell51 = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRootPrefix = 'sumi-guard-enforcement-demo-tests-'
$testRoot = [System.IO.Path]::GetFullPath(
    (Join-Path -Path $tempRoot -ChildPath ($testRootPrefix + [Guid]::NewGuid().ToString('N'))))
$results = New-Object -TypeName System.Collections.Generic.List[object]
$failure = $null
$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$testStartedUtc = [DateTime]::UtcNow

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Invoke-DemoCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        $output = @(& $Body)
        $evidence = $null
        if ($output.Count -eq 1) {
            $evidence = $output[0]
        }
        Assert-Test ($evidence -is [hashtable]) 'The case produced output other than its evidence.'
        $results.Add([pscustomobject][ordered]@{
            name = $Name
            passed = $true
            evidence = [pscustomobject]$evidence
            failure_type = $null
            failure_message = $null
        })
    }
    catch {
        $exception = $_.Exception
        $message = $null
        if ($exception -is [System.InvalidOperationException]) {
            $message = $exception.Message
        }
        $results.Add([pscustomobject][ordered]@{
            name = $Name
            passed = $false
            evidence = $null
            failure_type = $exception.GetType().FullName
            failure_message = $message
        })
    }
}

function Get-SceneCase {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int]$Scene
    )

    $match = @(@($Result.cases) | Where-Object { [int]$_.scene -eq $Scene })
    Assert-Test ($match.Count -eq 1) ('Scene ' + $Scene + ' is missing from the result.')
    return $match[0]
}

try {
    [void](New-Item -ItemType Directory -Path $testRoot)
    $resultPath = Join-Path -Path $testRoot -ChildPath 'demo-result.json'
    $castPath = Join-Path -Path $testRoot -ChildPath 'demo.cast'

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $demoOutput = & $powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $demoPath `
            -AdapterMode SYNTHETIC -PauseSeconds 0 -ResultPath $resultPath -CastPath $castPath 2>&1
        $demoExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $demoText = (@($demoOutput) | ForEach-Object { [string]$_ }) -join "`n"

    $demoResult = $null
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $demoResult = [System.IO.File]::ReadAllText($resultPath, $utf8) | ConvertFrom-Json
    }
    $castText = ''
    if (Test-Path -LiteralPath $castPath -PathType Leaf) {
        $castText = [System.IO.File]::ReadAllText($castPath, $utf8)
    }

    Invoke-DemoCase -Name 'demo_exits_zero' -Body {
        Assert-Test ($demoExitCode -eq 0) ('The demo exited with ' + $demoExitCode + '.')
        @{ exit_code = $demoExitCode }
    }

    Invoke-DemoCase -Name 'every_scene_matches' -Body {
        Assert-Test ($null -ne $demoResult) 'The demo wrote no result file.'
        $failedScenes = @(@($demoResult.cases) | Where-Object { -not $_.passed } |
            ForEach-Object { [string]$_.scene + ':' + (@($_.failed_checks) -join '/') })
        Assert-Test ([bool]$demoResult.success) ('The demo reported failure. setup=' + [string]$demoResult.setup_failure +
            ' stage=' + [string]$demoResult.failure_stage + ' type=' + [string]$demoResult.failure_exception_type +
            ' scenes=' + ($failedScenes -join ','))
        Assert-Test ([int]$demoResult.scene_count -eq 6) 'The demo did not run six scenes.'
        Assert-Test ([int]$demoResult.passed_count -eq 6) 'Not every scene matched.'
        Assert-Test ([string]$demoResult.adapter_mode -ceq 'SYNTHETIC') 'The demo did not run in synthetic mode.'
        @{ passed_count = [int]$demoResult.passed_count }
    }

    Invoke-DemoCase -Name 'deny_json_only_in_scenes_3_and_6' -Body {
        Assert-Test ($null -ne $demoResult) 'The demo wrote no result file.'
        foreach ($scene in 1..6) {
            $case = Get-SceneCase -Result $demoResult -Scene $scene
            $expected = 'EMPTY'
            if ($scene -eq 3 -or $scene -eq 6) { $expected = 'DENY_JSON' }
            Assert-Test ([string]$case.observed.stdout_kind -ceq $expected) ('Scene ' + $scene + ' answered ' + [string]$case.observed.stdout_kind + '.')
        }
        @{ checked_scenes = 6 }
    }

    Invoke-DemoCase -Name 'kill_switch_and_unlisted_route_step_aside' -Body {
        Assert-Test ($null -ne $demoResult) 'The demo wrote no result file.'
        $unlisted = Get-SceneCase -Result $demoResult -Scene 4
        $off = Get-SceneCase -Result $demoResult -Scene 5
        $back = Get-SceneCase -Result $demoResult -Scene 6
        Assert-Test (-not [bool]$unlisted.observed.route_allowlisted) 'Scene 4 treated the PowerShell route as listed.'
        Assert-Test ([string]$unlisted.observed.hook_status -ceq 'NOT_ENFORCED') 'Scene 4 enforced an unlisted route.'
        Assert-Test ([string]$off.observed.setting_status -ceq 'KILL_SWITCH_ACTIVE') 'Scene 5 did not see the kill switch.'
        Assert-Test ([int]$off.observed.notice_delta -eq 0) 'Scene 5 wrote a notice while switched off.'
        Assert-Test ([string]$back.observed.decision -ceq 'DENY') 'Removing the kill switch did not restore the deny.'
        @{ unlisted = 'NOT_ENFORCED'; kill_switch = 'KILL_SWITCH_ACTIVE'; restored = 'DENY' }
    }

    Invoke-DemoCase -Name 'temporary_folder_removed' -Body {
        Assert-Test ($null -ne $demoResult) 'The demo wrote no result file.'
        Assert-Test ([bool]$demoResult.temp_removed) 'The demo reported its folder as not removed.'
        $left = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'sumi-guard-enforcement-demo-*' |
            Where-Object { $_.Name -cmatch '^sumi-guard-enforcement-demo-[0-9a-f]{32}$' -and $_.LastWriteTimeUtc -gt $testStartedUtc })
        Assert-Test ($left.Count -eq 0) 'A demo folder from this run is still under %TEMP%.'
        @{ removed = $true }
    }

    Invoke-DemoCase -Name 'cast_is_well_formed' -Body {
        Assert-Test ($castText.Length -gt 0) 'The demo wrote no cast file.'
        # Bytes, not text: a culture-aware StartsWith treats the BOM as an
        # ignorable character and matches any string.
        [byte[]]$head = [System.IO.File]::ReadAllBytes($castPath)
        Assert-Test (-not ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) 'The cast file starts with a BOM.'
        $lines = @($castText -split "`n" | Where-Object { $_ -ne '' })
        Assert-Test ($lines.Count -ge 20) 'The cast file has too few lines.'
        $header = $lines[0] | ConvertFrom-Json
        Assert-Test ([int]$header.version -eq 2) 'The cast header is not asciicast v2.'
        $lastTime = -1.0
        for ($index = 1; $index -lt $lines.Count; $index++) {
            # Assigned before wrapping: Windows PowerShell 5.1 emits a parsed
            # JSON array as one pipeline item, so @(... | ConvertFrom-Json)
            # would hold the array as a single element.
            $parsed = ConvertFrom-Json -InputObject $lines[$index]
            $frame = @($parsed)
            Assert-Test ($frame.Count -eq 3) ('Cast line ' + $index + ' is not a three-item array.')
            Assert-Test ([string]$frame[1] -ceq 'o') ('Cast line ' + $index + ' is not an output event.')
            $time = [double]$frame[0]
            Assert-Test ($time -ge $lastTime) ('Cast line ' + $index + ' goes back in time.')
            $lastTime = $time
        }
        Assert-Test ($castText.Contains('6/6')) 'The cast does not carry the six-of-six summary.'
        @{ frames = $lines.Count - 1 }
    }

    Invoke-DemoCase -Name 'no_path_or_identity_in_output' -Body {
        $forbidden = New-Object -TypeName System.Collections.Generic.List[string]
        $forbidden.Add($tempRoot.TrimEnd('\'))
        if (-not [string]::IsNullOrEmpty($env:TEMP)) { $forbidden.Add($env:TEMP.TrimEnd('\')) }
        if (-not [string]::IsNullOrEmpty($env:USERNAME) -and $env:USERNAME.Length -ge 3) { $forbidden.Add($env:USERNAME) }
        foreach ($text in @($castText, $demoText)) {
            foreach ($value in $forbidden) {
                Assert-Test ($text.IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'The demo output carried a path or the user name.'
            }
            Assert-Test (-not ($text -cmatch 'sumi-guard-enforcement-demo-[0-9a-f]{32}')) 'The demo output carried its folder name.'
        }
        @{ checked_values = $forbidden.Count }
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = 'Setup failed before or between cases.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRoot)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Path $resolvedForDelete -Leaf) -like ($testRootPrefix + '*')) {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
        else {
            $failure = [pscustomobject][ordered]@{
                type = 'CleanupSafetyFailure'
                message = 'Refused to remove a test path outside the resolved temporary root.'
            }
        }
    }
}

$failedCases = @($results | Where-Object { -not $_.passed } | ForEach-Object { $_.name })
if ($null -eq $failure -and $failedCases.Count -gt 0) {
    $failure = [pscustomobject][ordered]@{
        type = 'CaseFailure'
        message = 'One or more enforcement demo cases failed.'
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    passed_count = @($results | Where-Object { $_.passed }).Count
    failed_cases = $failedCases
    tests = $results.ToArray()
    failure = $failure
    host_invoked = $false
    dpapi_used = $false
}
$summary | ConvertTo-Json -Depth 6

if ($null -ne $failure) {
    exit 1
}
