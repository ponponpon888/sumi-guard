[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [int]$TimeoutSeconds = 150,
    [switch]$KeepTemporaryProject
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$fixedCommand = "Write-Output 'SUMI_GUARD_PROTOTYPE_OK'"
$stdinReaderCommand = '$line = Read-Host; Write-Output $line'
$fixedMarker = 'SUMI_GUARD_PROTOTYPE_OK'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hookSource = Join-Path $scriptRoot 'sumi-guard-hook.ps1'
$observerSource = Join-Path $scriptRoot 'process-observer.ps1'

function Get-Utf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-Ndjson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $items.Add(($line | ConvertFrom-Json))
        }
    }
    return $items.ToArray()
}

function Get-SafeCliErrorSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$CodexExecutable
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $safeLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch '(?i)error|failed|invalid|unexpected|unrecognized|usage:|tip:|login|authentication|network|trust|hook') {
            continue
        }
        $safe = $line.Replace($ProjectPath, '<TEMP_PROJECT>').Replace($CodexExecutable, '<CODEX>')
        $safe = $safe -replace '(?i)(token|secret|api[_-]?key)\s*[:=]\s*\S+', '$1=<redacted>'
        if ($safe.Length -gt 300) {
            $safe = $safe.Substring(0, 300) + '...'
        }
        $safeLines.Add($safe)
        if ($safeLines.Count -ge 8) {
            break
        }
    }

    if ($safeLines.Count -eq 0) {
        return @('NONEMPTY_STDERR_NO_CLASSIFIED_LINE')
    }
    return $safeLines.ToArray()
}

function Get-CliExecutionSummary {
    param([Parameter(Mandatory = $true)][string]$JsonLines)

    $commandEvents = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($JsonLines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        $itemProperty = $event.PSObject.Properties['item']
        if ($null -eq $itemProperty) {
            continue
        }
        $item = $itemProperty.Value
        $typeProperty = $item.PSObject.Properties['type']
        if ($null -eq $typeProperty -or [string]$typeProperty.Value -cne 'command_execution') {
            continue
        }

        $outputProperty = $item.PSObject.Properties['aggregated_output']
        $statusProperty = $item.PSObject.Properties['status']
        $exitCodeProperty = $item.PSObject.Properties['exit_code']
        $output = ''
        if ($null -ne $outputProperty) {
            $output = [string]$outputProperty.Value
        }
        $commandEvents.Add([pscustomobject][ordered]@{
            status = if ($null -ne $statusProperty) { [string]$statusProperty.Value } else { $null }
            exit_code = if ($null -ne $exitCodeProperty) { $exitCodeProperty.Value } else { $null }
            fixed_output_observed = $output.Contains($fixedMarker)
            command_body_saved = $false
            output_body_saved = $false
        })
    }

    return [pscustomobject][ordered]@{
        event_count = $commandEvents.Count
        fixed_output_observed = @($commandEvents | Where-Object { $_.fixed_output_observed }).Count -gt 0
        events = $commandEvents.ToArray()
    }
}

function Start-NativeProcessObserver {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$ObserverScript
    )

    $rootPidFile = Join-Path $ProjectPath 'observer-root-pids.txt'
    $outputPath = Join-Path $ProjectPath 'events\os-processes.ndjson'
    $readyPath = Join-Path $ProjectPath 'observer-ready.txt'
    $stopPath = Join-Path $ProjectPath 'observer-stop.txt'
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ObserverScript,
        '-RootPidFile', $rootPidFile,
        '-OutputPath', $outputPath,
        '-ReadyPath', $readyPath,
        '-StopPath', $stopPath
    )
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value ([string]$_) }) -join ' ')

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = $argumentLine
    $startInfo.WorkingDirectory = $ProjectPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Native process observer did not start.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
        -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw 'Native process observer readiness was not confirmed.'
    }

    return [pscustomobject][ordered]@{
        process = $process
        root_pid_file = $rootPidFile
        output_path = $outputPath
        ready_path = $readyPath
        stop_path = $stopPath
        confirmed_at_utc = [System.IO.File]::ReadAllText($readyPath)
        source_name = 'NativeProcessPolling'
    }
}

function Stop-NativeProcessObserver {
    param([Parameter(Mandatory = $true)]$Observer)

    [System.IO.File]::WriteAllText(
        $Observer.stop_path,
        [DateTimeOffset]::UtcNow.ToString('o'),
        (New-Object System.Text.UTF8Encoding($false)))
    if (-not $Observer.process.WaitForExit(5000)) {
        Stop-Process -Id $Observer.process.Id -Force -ErrorAction SilentlyContinue
        $Observer.process.WaitForExit()
    }
    return @(Read-Ndjson -Path $Observer.output_path)
}

function Get-PrototypeHookProcessIds {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$StartTime,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EndTime,
        [Parameter(Mandatory = $true)][int[]]$CandidateProcessIds
    )

    if ($CandidateProcessIds.Count -eq 0) {
        return @()
    }

    $ids = New-Object System.Collections.Generic.List[int]
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Windows PowerShell'
            Id = 400
            StartTime = $StartTime.LocalDateTime.AddSeconds(-1)
            EndTime = $EndTime.LocalDateTime.AddSeconds(2)
        } -ErrorAction Stop | Where-Object { $CandidateProcessIds -contains [int]$_.ProcessId })

        foreach ($eventRecord in $events) {
            $message = [string]$eventRecord.Message
            if ($message.Contains('sumi-guard-hook.ps1')) {
                $ids.Add([int]$eventRecord.ProcessId)
            }
        }
    }
    catch {
        return @()
    }
    return $ids.ToArray()
}

function Invoke-IsolatedCodexRun {
    param(
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$PrimaryPath,
        [Parameter(Mandatory = $true)][string]$AlternatePath,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$HookCommand,
        [Parameter(Mandatory = $true)][string]$RootPidFile,
        [Parameter(Mandatory = $true)][int]$RunTimeoutSeconds
    )

    $preHooksToml = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=10,statusMessage='Recording SUMI Guard prototype intent'}]},{matcher='^write_stdin$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=10,statusMessage='Checking SUMI Guard stdin boundary'}]}]"
    $postHooksToml = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=10,statusMessage='Recording SUMI Guard prototype result'}]}]"
    $arguments = @(
        '--no-daemon',
        '--dangerously-bypass-hook-trust',
        '-c', ('hooks.PreToolUse=' + $preHooksToml),
        '-c', ('hooks.PostToolUse=' + $postHooksToml),
        '-C', $ProjectPath,
        '-s', 'read-only',
        '-a', 'never',
        'exec',
        '--json',
        '--skip-git-repo-check',
        '--ephemeral',
        '--ignore-rules',
        '--color', 'never',
        $Prompt
    )
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value ([string]$_) }) -join ' ')

    $oldEnvironment = @{}
    foreach ($name in @('SUMI_GUARD_TEST_CASE', 'SUMI_GUARD_EXPECTED_COMMAND', 'SUMI_GUARD_PRIMARY_EVENT_PATH', 'SUMI_GUARD_ALTERNATE_NOTICE_PATH', 'SHELL', 'Path')) {
        $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    [Environment]::SetEnvironmentVariable('SUMI_GUARD_TEST_CASE', $CaseName, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_EXPECTED_COMMAND', $ExpectedCommand, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_PRIMARY_EVENT_PATH', $PrimaryPath, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_ALTERNATE_NOTICE_PATH', $AlternatePath, 'Process')
    [Environment]::SetEnvironmentVariable('SHELL', (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), 'Process')
    $safePath = (Join-Path $env:SystemRoot 'System32') + ';' +
        $env:SystemRoot + ';' +
        (Join-Path $env:SystemRoot 'System32\Wbem') + ';' +
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    [Environment]::SetEnvironmentVariable('Path', $safePath, 'Process')

    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    $timedOut = $false
    $stdoutText = ''
    $stderrText = ''
    $startedAt = [DateTimeOffset]::UtcNow
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $CodexExecutable
        $startInfo.Arguments = $argumentLine
        $startInfo.WorkingDirectory = $ProjectPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Codex process did not start.'
        }
        [System.IO.File]::AppendAllText(
            $RootPidFile,
            ([string]$process.Id) + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false)))
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $deadline = [DateTime]::UtcNow.AddSeconds($RunTimeoutSeconds)
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }

        if (-not $process.HasExited) {
            $timedOut = $true
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        $process.WaitForExit()
        $stdoutText = $stdoutTask.Result
        $stderrText = $stderrTask.Result
    }
    finally {
        foreach ($name in $oldEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
        }
    }
    $endedAt = [DateTimeOffset]::UtcNow

    $exitCode = $null
    if ($null -ne $process -and $process.HasExited) {
        $exitCode = $process.ExitCode
    }
    $executionSummary = Get-CliExecutionSummary -JsonLines $stdoutText

    return [pscustomobject][ordered]@{
        case_name = $CaseName
        root_process_id = $process.Id
        started_at_utc = $startedAt.ToString('o')
        ended_at_utc = $endedAt.ToString('o')
        exit_code = $exitCode
        timed_out = $timedOut
        command_execution_event_count = $executionSummary.event_count
        command_execution_events = @($executionSummary.events)
        fixed_output_visible_in_command_execution = $executionSummary.fixed_output_observed
        cli_error_summary = @(Get-SafeCliErrorSummary -Text $stderrText -ProjectPath $ProjectPath -CodexExecutable $CodexExecutable)
        cli_stdout_saved = $false
        cli_stderr_saved = $false
    }
}

if ([string]::IsNullOrWhiteSpace($CodexPath)) {
    $codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($null -eq $codexCommand) {
        $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    }
    if ($null -eq $codexCommand) {
        throw 'Codex CLI was not found. Supply -CodexPath.'
    }
    $CodexPath = $codexCommand.Source
}

if (-not (Test-Path -LiteralPath $CodexPath -PathType Leaf)) {
    throw "Codex CLI was not found at the supplied path: $CodexPath"
}
if (-not (Test-Path -LiteralPath $hookSource -PathType Leaf)) {
    throw "Prototype hook was not found: $hookSource"
}
if (-not (Test-Path -LiteralPath $observerSource -PathType Leaf)) {
    throw "Prototype process observer was not found: $observerSource"
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$projectPath = Join-Path $tempRoot ('sumi-guard-prototype-' + [Guid]::NewGuid().ToString('N'))
$projectFullPath = [System.IO.Path]::GetFullPath($projectPath)
if (-not $projectFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create a temporary project outside the resolved temporary root.'
}

$observer = $null
$observerConfirmedAt = $null
$observations = @()
$runs = @()
$result = $null

try {
    $codexDirectory = Join-Path $projectPath '.codex'
    $eventDirectory = Join-Path $projectPath 'events'
    $blockedPrimaryDirectory = Join-Path $projectPath 'blocked-primary'
    [void](New-Item -ItemType Directory -Path $codexDirectory -Force)
    [void](New-Item -ItemType Directory -Path $eventDirectory -Force)
    [void](New-Item -ItemType Directory -Path $blockedPrimaryDirectory -Force)

    $hookCopy = Join-Path $codexDirectory 'sumi-guard-hook.ps1'
    Copy-Item -LiteralPath $hookSource -Destination $hookCopy

    $quotedHook = '"' + $hookCopy + '"'
    $hookCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $quotedHook
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        $git = Get-Command git -ErrorAction SilentlyContinue
    }
    if ($null -ne $git) {
        & $git.Source init --quiet $projectPath
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not initialize the disposable Git project.'
        }
    }

    $observer = Start-NativeProcessObserver -ProjectPath $projectPath -ObserverScript $observerSource
    $observerConfirmedAt = $observer.confirmed_at_utc

    $normalPath = Join-Path $eventDirectory 'normal.ndjson'
    $alternatePath = Join-Path $eventDirectory 'alternate.ndjson'
    $normalPrompt = "Call exec_command exactly once with shell set to powershell. Set its cmd field to the exact text between the XML tags, without the tags or any added character. Do not call any other tool. <command>$fixedCommand</command> Return only the command output."
    $runs += Invoke-IsolatedCodexRun `
        -CaseName 'A_INITIAL_COMMAND' `
        -ExpectedCommand $fixedCommand `
        -Prompt $normalPrompt `
        -PrimaryPath $normalPath `
        -AlternatePath $alternatePath `
        -ProjectPath $projectPath `
        -CodexExecutable $CodexPath `
        -HookCommand $hookCommand `
        -RootPidFile $observer.root_pid_file `
        -RunTimeoutSeconds $TimeoutSeconds

    $stdinPath = Join-Path $eventDirectory 'stdin.ndjson'
    $stdinPrompt = "Call exec_command exactly once with shell set to powershell, tty set to true, and yield_time_ms set to 1000. Set its cmd field to the exact text in the first XML element, without tags or added characters: <command>$stdinReaderCommand</command> It must remain waiting at Read-Host. Then call write_stdin exactly once using the nonzero session_id returned by exec_command; never use 0. Send the exact literal data in the second XML element followed by Enter: <data>$fixedCommand</data> Do not execute the sent line. Call no other tool. Return only the echoed line."
    $runs += Invoke-IsolatedCodexRun `
        -CaseName 'B_WRITE_STDIN' `
        -ExpectedCommand $stdinReaderCommand `
        -Prompt $stdinPrompt `
        -PrimaryPath $stdinPath `
        -AlternatePath $alternatePath `
        -ProjectPath $projectPath `
        -CodexExecutable $CodexPath `
        -HookCommand $hookCommand `
        -RootPidFile $observer.root_pid_file `
        -RunTimeoutSeconds $TimeoutSeconds

    $failurePrompt = "Call exec_command exactly once with shell set to powershell. Set its cmd field to the exact text between the XML tags, without the tags or any added character. Do not call any other tool. <command>$fixedCommand</command> Return only the command output."
    $runs += Invoke-IsolatedCodexRun `
        -CaseName 'MONITOR_SAVE_FAILURE' `
        -ExpectedCommand $fixedCommand `
        -Prompt $failurePrompt `
        -PrimaryPath $blockedPrimaryDirectory `
        -AlternatePath $alternatePath `
        -ProjectPath $projectPath `
        -CodexExecutable $CodexPath `
        -HookCommand $hookCommand `
        -RootPidFile $observer.root_pid_file `
        -RunTimeoutSeconds $TimeoutSeconds

    $observations = @(Stop-NativeProcessObserver -Observer $observer)
    $observer = $null

    $normalEvents = @(Read-Ndjson -Path $normalPath)
    $stdinEvents = @(Read-Ndjson -Path $stdinPath)
    $alternateEvents = @(Read-Ndjson -Path $alternatePath)
    $processObservations = @($observations | Where-Object {
        $_.event_type -ceq 'ProcessObserved'
    })
    $observerTimingSummaries = @($observations | Where-Object {
        $_.event_type -ceq 'ObserverTimingSummary'
    })

    $runResults = New-Object System.Collections.Generic.List[object]
    foreach ($run in $runs) {
        $events = @()
        if ($run.case_name -ceq 'A_INITIAL_COMMAND') {
            $events = $normalEvents
        }
        elseif ($run.case_name -ceq 'B_WRITE_STDIN') {
            $events = $stdinEvents
        }

        $start = [DateTimeOffset]::Parse($run.started_at_utc)
        $end = [DateTimeOffset]::Parse($run.ended_at_utc)
        $processes = @($processObservations | Where-Object {
            $observed = [DateTimeOffset]::Parse($_.process_start_time_utc)
            [int]$_.matched_root_process_id -eq [int]$run.root_process_id -and
                $observed -ge $start.AddSeconds(-1) -and
                $observed -le $end.AddSeconds(2)
        })

        $intentEvents = @($events | Where-Object { $_.event_type -ceq 'ExecutionIntentRecorded' })
        $outcomeEvents = @($events | Where-Object { $_.event_type -ceq 'ExecutionOutcomeObserved' })
        $hookProcessIds = @((@($intentEvents) + @($outcomeEvents)) |
            ForEach-Object { [int]$_.hook_process_id })
        $classifiedHookProcessIds = @(Get-PrototypeHookProcessIds `
            -StartTime $start `
            -EndTime $end `
            -CandidateProcessIds @($processes | ForEach-Object { [int]$_.process_id }))
        $allHookProcessIds = @((@($hookProcessIds) + @($classifiedHookProcessIds)) |
            Select-Object -Unique)
        $intentTime = $null
        $outcomeTime = $null
        if ($intentEvents.Count -gt 0) {
            $intentTime = [DateTimeOffset]::Parse($intentEvents[0].observed_at_utc)
        }
        if ($outcomeEvents.Count -gt 0) {
            $outcomeTime = [DateTimeOffset]::Parse($outcomeEvents[0].observed_at_utc)
        }
        $nonHookProcesses = @($processes | Where-Object {
            $allHookProcessIds -notcontains [int]$_.process_id
        })
        $targetProcesses = @($nonHookProcesses | Where-Object {
            $processStart = [DateTimeOffset]::Parse($_.process_start_time_utc)
            $null -ne $intentTime -and $null -ne $outcomeTime -and
                $processStart -ge $intentTime -and $processStart -le $outcomeTime
        })
        $correlation = 'UNMATCHED'
        $correlationReason = 'Required app and OS records were not both available.'
        if ($intentEvents.Count -gt 0 -and $outcomeEvents.Count -gt 0 -and
            $targetProcesses.Count -eq 1) {
            $correlation = 'INFERRED_MATCH'
            $correlationReason = 'OS process start fell between the intent and outcome hooks under the same isolated Codex root; the hook event has no target PID, so this is not a direct match.'
        }
        elseif ($targetProcesses.Count -gt 1) {
            $correlationReason = 'Multiple OS process candidates remained after hook-process exclusion and the intent/outcome time window; the result is not uniquely correlatable.'
        }

        $runResults.Add([pscustomobject][ordered]@{
            case_name = $run.case_name
            codex_exit_code = $run.exit_code
            timed_out = $run.timed_out
            cli_fixed_output_observed = $run.fixed_output_visible_in_command_execution
            cli_command_execution_event_count = $run.command_execution_event_count
            cli_error_summary = @($run.cli_error_summary)
            intent_event_count = $intentEvents.Count
            outcome_event_count = $outcomeEvents.Count
            hook_fixed_output_observed = @($outcomeEvents | Where-Object { $_.fixed_output_observed }).Count -gt 0
            hook_command_sha256 = if ($intentEvents.Count -gt 0) { [string]$intentEvents[0].raw_input_sha256 } else { $null }
            hook_input_schema = if ($intentEvents.Count -gt 0) { $intentEvents[0].input_schema } else { $null }
            intent_observed_at_utc = if ($null -ne $intentTime) { $intentTime.ToString('o') } else { $null }
            outcome_observed_at_utc = if ($null -ne $outcomeTime) { $outcomeTime.ToString('o') } else { $null }
            candidate_process_count_before_hook_exclusion = $processes.Count
            hook_reported_process_ids = @($hookProcessIds | Select-Object -Unique)
            event400_classified_hook_process_ids = @($classifiedHookProcessIds | Select-Object -Unique)
            excluded_hook_process_ids = @($allHookProcessIds)
            hook_process_exclusion_reason = 'Hook PID from saved hook events plus candidate PID classified by an existing Windows PowerShell event 400 containing the prototype hook name; event message body was not saved.'
            candidate_process_count_after_hook_exclusion = $nonHookProcesses.Count
            candidate_process_count_after_time_window = $targetProcesses.Count
            candidate_process_ids_after_time_window = @($targetProcesses | ForEach-Object { [int]$_.process_id })
            target_processes = @($targetProcesses)
            hook_process_count = @($processes | Where-Object { $allHookProcessIds -contains [int]$_.process_id }).Count
            correlation = $correlation
            correlation_reason = $correlationReason
        })
    }

    $failureNotices = @($alternateEvents | Where-Object { $_.test_case -ceq 'MONITOR_SAVE_FAILURE' })
    $failureRun = @($runs | Where-Object { $_.case_name -ceq 'MONITOR_SAVE_FAILURE' })[0]
    $result = [ordered]@{
        schema_version = 1
        generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        codex_path = $CodexPath
        project_scope = 'Disposable %TEMP% project and its one Codex CLI session only; no persistent trust or hook registration.'
        hook_connection_method = 'Per-invocation -c hooks override referencing the hook copy inside the disposable project.'
        project_hooks_connected = $normalEvents.Count -gt 0
        os_source = 'NativeProcessPolling'
        os_poll_timing = if ($observerTimingSummaries.Count -gt 0) {
            $observerTimingSummaries[$observerTimingSummaries.Count - 1]
        } else { $null }
        hook_self_exclusion_source = 'Existing Windows PowerShell event 400; only a hook-name boolean was used and the message was not saved.'
        os_collection_confirmed_before_execution = [DateTimeOffset]::Parse($observerConfirmedAt) -lt [DateTimeOffset]::Parse($runs[0].started_at_utc)
        fixed_command_sha256 = Get-Utf8Sha256 -Text $fixedCommand
        hash_scope = 'UTF-8 without BOM bytes of the JSON-decoded tool_input.command string; no normalization'
        runs = $runResults.ToArray()
        stdin_transport = [ordered]@{
            initial_command_event_count = @($stdinEvents | Where-Object { $_.event_type -ceq 'ExecutionIntentRecorded' }).Count
            follow_up_write_stdin_pretooluse_event_count = @($stdinEvents | Where-Object { $_.event_type -ceq 'FollowUpStdinHookObserved' }).Count
            follow_up_body_saved_by_hook = $false
            transport_fixed_output_observed = @($stdinEvents | Where-Object { $_.event_type -ceq 'ExecutionOutcomeObserved' -and $_.fixed_output_observed }).Count -gt 0
            interpretation = 'A separate fixed transport probe was attempted. A PostToolUse result may arrive through write_stdin, but write_stdin is not a new PreToolUse event.'
        }
        save_failure = [ordered]@{
            primary_write_was_forced_to_fail = $true
            alternate_notice_count = $failureNotices.Count
            alternate_notice_saved = $failureNotices.Count -gt 0
            automatic_deny = $false
            command_still_produced_fixed_output = $failureRun.fixed_output_visible_in_command_execution
            limit = 'If the primary store and alternate notice path both fail, this hook cannot leave a local failure record.'
        }
        raw_cli_output_saved = $false
        raw_os_command_lines_saved = $false
        temporary_project_path_saved = $false
    }
}
finally {
    if ($null -ne $observer) {
        $discard = @(Stop-NativeProcessObserver -Observer $observer)
        $observer = $null
    }

    if (-not $KeepTemporaryProject -and (Test-Path -LiteralPath $projectFullPath)) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($projectFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-prototype-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
        else {
            throw 'Refusing to remove an unvalidated temporary-project path.'
        }
    }
}

if ($null -ne $result) {
    $result.temporary_project_cleaned = -not (Test-Path -LiteralPath $projectFullPath)
    $result | ConvertTo-Json -Depth 20
}
