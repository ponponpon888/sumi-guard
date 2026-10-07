[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 150
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$fixedCommand = "Write-Output 'SUMI_GUARD_DEMO_OK'"
$fixedMarker = 'SUMI_GUARD_DEMO_OK'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$demoRoot = Join-Path $projectRoot '.demo-data'
$hookSource = Join-Path $projectRoot 'kit\sumi-guard-protected-hook-test\sumi-guard-protected-hook.ps1'
$observerSource = Join-Path $projectRoot 'kit\sumi-guard-prototype\process-observer.ps1'
$adapterManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'
$localStoreManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$script:Utf8Strict = New-Object Text.UTF8Encoding($false, $true)

function Get-Utf8Sha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    [byte[]]$bytes = $script:Utf8Strict.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$digest = $sha.ComputeHash($bytes)
        try { return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant() }
        finally { [Array]::Clear($digest, 0, $digest.Length) }
    }
    finally {
        $sha.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
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
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-CodexExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = [IO.Path]::GetFullPath($RequestedPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
            [IO.Path]::GetExtension($resolved) -ine '.exe') {
            throw 'Invalid Codex executable.'
        }
        return $resolved
    }
    $native = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($null -ne $native -and (Test-Path -LiteralPath $native.Source -PathType Leaf)) {
        return [IO.Path]::GetFullPath($native.Source)
    }
    $shim = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $shim) {
        $candidate = Join-Path (Split-Path -Parent $shim.Source) `
            'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Codex executable unavailable.'
}

function Read-Ndjson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in [IO.File]::ReadAllLines($Path, $script:Utf8Strict)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $records.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        }
    }
    return $records.ToArray()
}

function Get-CliSummary {
    param([Parameter(Mandatory = $true)][string]$JsonLines)

    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    $fixedOutputObserved = $false
    foreach ($line in ($JsonLines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if ($null -eq $event.PSObject.Properties['item']) { continue }
        $item = $event.item
        if ($null -eq $item.PSObject.Properties['type'] -or
            [string]$item.type -cne 'command_execution') { continue }
        if ($null -ne $item.PSObject.Properties['id']) { [void]$ids.Add([string]$item.id) }
        if ($null -ne $item.PSObject.Properties['aggregated_output'] -and
            ([string]$item.aggregated_output).Contains($fixedMarker)) {
            $fixedOutputObserved = $true
        }
    }
    return [pscustomobject]@{
        command_count = $ids.Count
        fixed_output_observed = $fixedOutputObserved
    }
}

function Get-LogicalLineCount {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ($Text.Length -eq 0) { return 0 }
    $lineCount = 0
    $hasCharactersAfterTerminator = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -eq "`r") {
            $lineCount++
            if ($index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "`n") { $index++ }
            $hasCharactersAfterTerminator = $false
        }
        elseif ($character -eq "`n") {
            $lineCount++
            $hasCharactersAfterTerminator = $false
        }
        else {
            $hasCharactersAfterTerminator = $true
        }
    }
    if ($hasCharactersAfterTerminator) { $lineCount++ }
    return $lineCount
}

function New-Event400DiagnosticFailure {
    param(
        [int]$CandidateCount,
        [string]$ReasonCode
    )

    return [pscustomobject][ordered]@{
        source = 'Windows PowerShell/Event ID 400'
        collection_status = 'COLLECTION_FAILED'
        classification_status = 'UNKNOWN'
        reason_code = $ReasonCode
        candidate_count_before_classification = $CandidateCount
        relevant_event_count = $null
        classified_hook_candidate_count = $null
        classified_hook_candidates = @()
        remaining_candidate_count = $null
        remaining_candidate_process_ids = @()
        ambiguous_reused_pid_count = $null
        message_read_failure_count = $null
        scope = 'child-codex-lineage-and-execution-time-window'
        pid_time_correlation = 'event time from process start -2 seconds through +5 seconds'
        event_message_saved = $false
        matched_text_saved = $false
        command_line_saved = $false
    }
}

function Get-DemoEvent400Diagnostic {
    param(
        [Parameter(Mandatory = $true)][object[]]$CandidateProcesses,
        [Parameter(Mandatory = $true)][DateTimeOffset]$RunStart,
        [Parameter(Mandatory = $true)][DateTimeOffset]$RunEnd,
        [Parameter(Mandatory = $true)][int]$RootProcessId
    )

    $candidates = @($CandidateProcesses)
    if ($candidates.Count -eq 0) {
        return [pscustomobject][ordered]@{
            source = 'Windows PowerShell/Event ID 400'
            collection_status = 'NOT_REQUIRED'
            classification_status = 'NO_CANDIDATES'
            reason_code = $null
            candidate_count_before_classification = 0
            relevant_event_count = 0
            classified_hook_candidate_count = 0
            classified_hook_candidates = @()
            remaining_candidate_count = 0
            remaining_candidate_process_ids = @()
            ambiguous_reused_pid_count = 0
            message_read_failure_count = 0
            scope = 'child-codex-lineage-and-execution-time-window'
            pid_time_correlation = 'event time from process start -2 seconds through +5 seconds'
            event_message_saved = $false
            matched_text_saved = $false
            command_line_saved = $false
        }
    }

    $candidateByPid = @{}
    $ambiguousPids = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        foreach ($candidate in $candidates) {
            $pidValue = [int]$candidate.process_id
            $matchedRoot = [int]$candidate.matched_root_process_id
            $processStart = [DateTimeOffset]::Parse([string]$candidate.process_start_time_utc)
            if ($pidValue -le 0 -or $matchedRoot -ne $RootProcessId -or
                $processStart -lt $RunStart.AddSeconds(-1) -or
                $processStart -gt $RunEnd.AddSeconds(2)) {
                return New-Event400DiagnosticFailure `
                    -CandidateCount $candidates.Count `
                    -ReasonCode 'CANDIDATE_SCOPE_VALIDATION_FAILED'
            }
            if ($candidateByPid.ContainsKey($pidValue)) {
                [void]$ambiguousPids.Add($pidValue)
            }
            else {
                $candidateByPid[$pidValue] = [pscustomobject]@{
                    process_id = $pidValue
                    process_start = $processStart
                }
            }
        }
    }
    catch {
        return New-Event400DiagnosticFailure `
            -CandidateCount $candidates.Count `
            -ReasonCode 'CANDIDATE_PARSE_FAILED'
    }

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Windows PowerShell'
            Id = 400
            StartTime = $RunStart.LocalDateTime.AddSeconds(-1)
            EndTime = $RunEnd.LocalDateTime.AddSeconds(2)
        } -ErrorAction Stop)
    }
    catch {
        if ([string]$_.FullyQualifiedErrorId -notlike '*NoMatchingEventsFound*') {
            return New-Event400DiagnosticFailure `
                -CandidateCount $candidates.Count `
                -ReasonCode 'EVENT_LOG_READ_FAILED'
        }
        $events = @()
    }

    $classifiedPids = New-Object 'System.Collections.Generic.HashSet[int]'
    $relevantEventCount = 0
    $messageReadFailureCount = 0
    foreach ($eventRecord in $events) {
        $pidValue = [int]$eventRecord.ProcessId
        if (-not $candidateByPid.ContainsKey($pidValue) -or $ambiguousPids.Contains($pidValue)) {
            continue
        }
        $eventTime = $null
        try {
            if ($null -eq $eventRecord.TimeCreated) { continue }
            $eventTime = New-Object DateTimeOffset($eventRecord.TimeCreated)
        }
        catch { continue }
        $candidate = $candidateByPid[$pidValue]
        if ($eventTime -lt $RunStart.AddSeconds(-1) -or
            $eventTime -gt $RunEnd.AddSeconds(2) -or
            $eventTime -lt $candidate.process_start.AddSeconds(-2) -or
            $eventTime -gt $candidate.process_start.AddSeconds(5)) {
            continue
        }
        $relevantEventCount++
        $messageMatched = $false
        try {
            if ($null -eq $eventRecord.Message) {
                throw 'Event message is unavailable.'
            }
            $messageMatched = ([string]$eventRecord.Message).Contains(
                'sumi-guard-protected-hook.ps1')
        }
        catch {
            $messageMatched = $false
            $messageReadFailureCount++
        }
        if ($messageMatched) { [void]$classifiedPids.Add($pidValue) }
        $messageMatched = $false
    }

    $classified = @($classifiedPids | Sort-Object | ForEach-Object {
        [pscustomobject][ordered]@{
            process_id = [int]$_
            classification_source = 'Windows PowerShell/Event ID 400'
            child_codex_lineage_correlated = $true
            process_start_time_correlated = $true
        }
    })
    $remainingPids = @($candidateByPid.Keys | ForEach-Object { [int]$_ } |
        Where-Object { -not $classifiedPids.Contains($_) } | Sort-Object)
    $collectionStatus = if ($relevantEventCount -eq 0) { 'NO_RECORD' } else { 'RECORDS_FOUND' }
    $classificationStatus = 'NO_HOOK_RELATED_MATCH'
    if ($classified.Count -gt 0) { $classificationStatus = 'CLASSIFIED' }
    elseif ($relevantEventCount -eq 0) { $classificationStatus = 'NO_RELEVANT_EVENT' }
    if ($messageReadFailureCount -gt 0) {
        $classificationStatus = 'PARTIAL_UNKNOWN_MESSAGE_READ_FAILED'
    }
    if ($ambiguousPids.Count -gt 0) { $classificationStatus = 'PARTIAL_UNKNOWN_PID_REUSE' }

    return [pscustomobject][ordered]@{
        source = 'Windows PowerShell/Event ID 400'
        collection_status = $collectionStatus
        classification_status = $classificationStatus
        reason_code = $null
        candidate_count_before_classification = $candidates.Count
        relevant_event_count = $relevantEventCount
        classified_hook_candidate_count = $classified.Count
        classified_hook_candidates = $classified
        remaining_candidate_count = $remainingPids.Count
        remaining_candidate_process_ids = $remainingPids
        ambiguous_reused_pid_count = $ambiguousPids.Count
        message_read_failure_count = $messageReadFailureCount
        scope = 'child-codex-lineage-and-execution-time-window'
        pid_time_correlation = 'event time from process start -2 seconds through +5 seconds'
        event_message_saved = $false
        matched_text_saved = $false
        command_line_saved = $false
    }
}

function Start-DemoObserver {
    param([string]$RunRoot)

    $rootPidPath = Join-Path $RunRoot 'observer-root-pids.txt'
    $outputPath = Join-Path $RunRoot 'os-processes.ndjson'
    $readyPath = Join-Path $RunRoot 'observer-ready.txt'
    $stopPath = Join-Path $RunRoot 'observer-stop.txt'
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $observerSource,
        '-RootPidFile', $rootPidPath,
        '-OutputPath', $outputPath,
        '-ReadyPath', $readyPath,
        '-StopPath', $stopPath
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell
    $startInfo.Arguments = (($arguments | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' ')
    $startInfo.WorkingDirectory = $RunRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Observer start failed.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
        -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
        throw 'Observer readiness failed.'
    }
    return [pscustomobject]@{
        process = $process
        root_pid_path = $rootPidPath
        output_path = $outputPath
        stop_path = $stopPath
    }
}

function Stop-DemoObserver {
    param($Observer)

    [IO.File]::WriteAllText(
        $Observer.stop_path,
        [DateTimeOffset]::UtcNow.ToString('o'),
        $script:Utf8Strict)
    if (-not $Observer.process.WaitForExit(5000)) {
        Stop-Process -Id $Observer.process.Id -Force -ErrorAction SilentlyContinue
        $Observer.process.WaitForExit()
    }
    $Observer.process.Dispose()
}

function Invoke-DemoCodex {
    param(
        [string]$CodexExecutable,
        [string]$RunRoot,
        [string]$HookCommand,
        [string]$RootPidPath,
        [string]$ExecutionStorePath,
        [string]$LocalStorePath,
        [string]$CommandSha256,
        [int]$RunTimeoutSeconds
    )

    $preHooks = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=20,statusMessage='Recording SUMI Guard demo intent'}]}]"
    $postHooks = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=20,statusMessage='Recording SUMI Guard demo result'}]}]"
    $prompt = "Call exec_command exactly once with shell set to powershell. Set its cmd field to the exact text between the XML tags, without the tags or any added character. Do not call any other tool. <command>$fixedCommand</command> Return only the command output."
    $arguments = @(
        '--no-daemon',
        '--dangerously-bypass-hook-trust',
        '-c', ('hooks.PreToolUse=' + $preHooks),
        '-c', ('hooks.PostToolUse=' + $postHooks),
        '-C', $RunRoot,
        '-s', 'read-only',
        '-a', 'never',
        'exec', '--json', '--skip-git-repo-check', '--ephemeral', '--ignore-rules',
        '--color', 'never', $prompt
    )
    $argumentLine = (($arguments | ForEach-Object {
        ConvertTo-WindowsArgument ([string]$_)
    }) -join ' ')

    $names = @(
        'SUMI_GUARD_EXPECTED_COMMAND_SHA256', 'SUMI_GUARD_EXPECTED_OUTPUT_MARKER',
        'SUMI_GUARD_EXECUTION_STORE_PATH', 'SUMI_GUARD_LOCAL_STORE_PATH',
        'SUMI_GUARD_ADAPTER_MANIFEST', 'SHELL', 'Path'
    )
    $old = @{}
    foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_EXPECTED_COMMAND_SHA256', $CommandSha256, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_EXPECTED_OUTPUT_MARKER', $fixedMarker, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_EXECUTION_STORE_PATH', $ExecutionStorePath, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_LOCAL_STORE_PATH', $LocalStorePath, 'Process')
    [Environment]::SetEnvironmentVariable('SUMI_GUARD_ADAPTER_MANIFEST', $adapterManifest, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SHELL', (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), 'Process')
    $safePath = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot + ';' +
        (Join-Path $env:SystemRoot 'System32\Wbem') + ';' +
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    [Environment]::SetEnvironmentVariable('Path', $safePath, 'Process')

    $process = $null
    $stdoutText = ''
    $stderrText = ''
    $timedOut = $false
    $stderrReadStatus = 'NOT_ATTEMPTED'
    $stderrNonempty = $null
    $stderrClassification = 'UNKNOWN_NOT_ATTEMPTED'
    $stderrLineCount = $null
    $stderrUtf8ReencodedByteCount = $null
    $startedAt = [DateTimeOffset]::UtcNow
    $endedAt = $null
    $rootProcessId = 0
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $CodexExecutable
        $startInfo.Arguments = $argumentLine
        $startInfo.WorkingDirectory = $RunRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Codex start failed.' }
        $rootProcessId = $process.Id
        [IO.File]::AppendAllText(
            $RootPidPath, ([string]$process.Id) + [Environment]::NewLine, $script:Utf8Strict)
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
        $endedAt = [DateTimeOffset]::UtcNow
        $stdoutText = $stdoutTask.Result
        try {
            $stderrText = $stderrTask.Result
            $stderrReadStatus = 'READ_SUCCEEDED'
            $stderrNonempty = $stderrText.Length -gt 0
            $stderrClassification = if ($stderrNonempty) { 'UNKNOWN_NONEMPTY' } else { 'EMPTY' }
        }
        catch {
            $stderrText = ''
            $stderrReadStatus = 'READ_FAILED'
            $stderrNonempty = $null
            $stderrClassification = 'UNKNOWN_READ_FAILED'
        }
        if ($stderrReadStatus -ceq 'READ_SUCCEEDED') {
            try {
                $stderrLineCount = Get-LogicalLineCount -Text $stderrText
                $summaryEncoding = New-Object Text.UTF8Encoding($false, $false)
                $stderrUtf8ReencodedByteCount = $summaryEncoding.GetByteCount($stderrText)
            }
            catch {
                $stderrClassification = 'UNKNOWN_SUMMARY_FAILED'
                $stderrLineCount = $null
                $stderrUtf8ReencodedByteCount = $null
            }
        }
        $summary = Get-CliSummary -JsonLines $stdoutText
        $result = [pscustomobject]@{
            exit_code = $process.ExitCode
            timed_out = $timedOut
            root_process_id = $rootProcessId
            started_at_utc = $startedAt.ToString('o')
            ended_at_utc = $endedAt.ToString('o')
            command_count = $summary.command_count
            fixed_output_observed = $summary.fixed_output_observed
            stderr_nonempty = $stderrNonempty
            stderr_read_status = $stderrReadStatus
            stderr_classification = $stderrClassification
            stderr_line_count = $stderrLineCount
            stderr_utf8_reencoded_byte_count = $stderrUtf8ReencodedByteCount
            stderr_size_measurement =
                'decoded .NET string re-encoded as UTF-8 without BOM; not original stream bytes'
        }
        $stdoutText = ''
        $stderrText = ''
        return $result
    }
    finally {
        foreach ($name in $old.Keys) {
            [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process')
        }
        $stdoutText = ''
        $stderrText = ''
        if ($null -ne $process) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            $process.Dispose()
        }
    }
}

function Test-PlaintextAbsent {
    param([string[]]$Paths, [string]$Text)

    [byte[]]$needle = $script:Utf8Strict.GetBytes($Text)
    try {
        foreach ($root in $Paths) {
            foreach ($path in [IO.Directory]::GetFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
                [byte[]]$bytes = [IO.File]::ReadAllBytes($path)
                try {
                    for ($offset = 0; $offset -le ($bytes.Length - $needle.Length); $offset++) {
                        $match = $true
                        for ($index = 0; $index -lt $needle.Length; $index++) {
                            if ($bytes[$offset + $index] -ne $needle[$index]) { $match = $false; break }
                        }
                        if ($match) { return $false }
                    }
                }
                finally { if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
            }
        }
        return $true
    }
    finally { [Array]::Clear($needle, 0, $needle.Length) }
}

$stage = '前提確認'
$observer = $null
$runRoot = $null
$runRootCleaned = $false
$completed = $false
$safeResult = $null
try {
    foreach ($required in @($hookSource, $observerSource, $adapterManifest, $localStoreManifest)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw 'Required component unavailable.' }
    }
    if (Test-Path -LiteralPath $demoRoot) {
        throw 'Demo store already exists.'
    }
    $codexExecutable = Resolve-CodexExecutable -RequestedPath $CodexPath
    $commandSha256 = Get-Utf8Sha256 -Text $fixedCommand

    $stage = 'デモ保存先作成'
    [void](New-Item -ItemType Directory -Path $demoRoot -ErrorAction Stop)
    $rootMarker = [ordered]@{
        schema_version = 1
        purpose = 'SUMI_GUARD_MANUAL_DEMO'
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        demo_id = [Guid]::NewGuid().ToString('N')
    }
    [IO.File]::WriteAllText(
        (Join-Path $demoRoot '.sumi-guard-demo-root.json'),
        ($rootMarker | ConvertTo-Json -Compress),
        $script:Utf8Strict)

    Import-Module $localStoreManifest -Force -ErrorAction Stop
    Import-Module $adapterManifest -Force -ErrorAction Stop
    $localStorePath = Join-Path $demoRoot 'body-store'
    $executionStorePath = Join-Path $demoRoot 'execution-store'
    $localInit = Initialize-SumiGuardLocalStore -Path $localStorePath
    $executionInit = Initialize-SumiGuardExecutionStore -Path $executionStorePath
    if (-not $localInit.success -or -not $executionInit.success) { throw 'Store initialization failed.' }

    $stage = '一時プロジェクト作成'
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $runRoot = Join-Path $tempRoot ('sumi-guard-demo-run-' + [Guid]::NewGuid().ToString('N'))
    $runRoot = [IO.Path]::GetFullPath($runRoot)
    if (-not $runRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $runRoot) -cnotmatch '^sumi-guard-demo-run-[0-9a-f]{32}$') {
        throw 'Unsafe temporary project path.'
    }
    [void](New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop)
    $codexDirectory = Join-Path $runRoot '.codex'
    [void](New-Item -ItemType Directory -Path $codexDirectory -ErrorAction Stop)
    $hookCopy = Join-Path $codexDirectory 'sumi-guard-protected-hook.ps1'
    Copy-Item -LiteralPath $hookSource -Destination $hookCopy -ErrorAction Stop
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if ($null -ne $git) {
        $null = & $git.Source init --quiet $runRoot
        if ($LASTEXITCODE -ne 0) { throw 'Disposable Git initialization failed.' }
    }

    $stage = 'OS観測開始'
    $observer = Start-DemoObserver -RunRoot $runRoot
    $quotedHook = '"' + $hookCopy + '"'
    $hookCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        $quotedHook

    $stage = '固定コマンド実行'
    $run = Invoke-DemoCodex `
        -CodexExecutable $codexExecutable `
        -RunRoot $runRoot `
        -HookCommand $hookCommand `
        -RootPidPath $observer.root_pid_path `
        -ExecutionStorePath $executionStorePath `
        -LocalStorePath $localStorePath `
        -CommandSha256 $commandSha256 `
        -RunTimeoutSeconds $TimeoutSeconds
    Stop-DemoObserver -Observer $observer
    $observer = $null
    $osObservationPath = Join-Path $executionStorePath 'demo-os-processes.ndjson'
    Copy-Item -LiteralPath (Join-Path $runRoot 'os-processes.ndjson') `
        -Destination $osObservationPath -ErrorAction Stop

    $stage = '保存結果確認'
    $recordResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStorePath -LocalStorePath $localStorePath
    $records = @($recordResult.records)
    $outcomes = @(Read-Ndjson -Path (Join-Path $executionStorePath 'outcomes.ndjson'))
    $hookRuntime = @(Read-Ndjson -Path (Join-Path $executionStorePath 'hook-runtime.ndjson'))
    $observations = @(Read-Ndjson -Path $osObservationPath)
    $failureResult = Get-SumiGuardCollectionFailureNotice -ExecutionStorePath $executionStorePath
    $failures = @($failureResult.notices)
    $hookFailures = @(Read-Ndjson -Path (Join-Path $executionStorePath 'hook-failures.ndjson'))
    if ($run.exit_code -ne 0 -or $run.timed_out -or -not $recordResult.success -or
        $records.Count -ne 1 -or $outcomes.Count -ne 1 -or
        $failures.Count -ne 0 -or $hookFailures.Count -ne 0) {
        throw 'Demo recording validation failed.'
    }
    $record = $records[0]
    $outcome = $outcomes[0]
    if ([string]$record.content_status -cne 'CAPTURED_ENCRYPTED' -or
        [string]$record.collection_status -cne 'RECORDS_FOUND' -or
        [string]$record.body_reference_status -cne 'AVAILABLE' -or
        [string]$outcome.execution_status -cne 'SUCCEEDED' -or
        -not [bool]$outcome.fixed_output_observed -or
        [string]$record.execution_id -cne [string]$outcome.execution_id -or
        [string]$record.body_sha256 -cne $commandSha256 -or
        [string]$outcome.command_sha256 -cne $commandSha256 -or
        -not (Test-PlaintextAbsent -Paths @($executionStorePath, $localStorePath) -Text $fixedMarker)) {
        throw 'Demo metadata consistency failed.'
    }

    $event400Diagnostic = $null
    try {
        $intentTime = [DateTimeOffset]::Parse([string]$record.occurred_at_utc)
        $outcomeTime = [DateTimeOffset]::Parse([string]$outcome.occurred_at_utc)
        $runStart = [DateTimeOffset]::Parse([string]$run.started_at_utc)
        $runEnd = [DateTimeOffset]::Parse([string]$run.ended_at_utc)
        $runtimeHookPids = @($hookRuntime | ForEach-Object { [int]$_.hook_process_id } |
            Where-Object { $_ -gt 0 } | Select-Object -Unique)
        $formalCandidates = @($observations | Where-Object {
            if ([string]$_.event_type -cne 'ProcessObserved') { return $false }
            $processId = [int]$_.process_id
            $matchedRoot = [int]$_.matched_root_process_id
            $processStart = [DateTimeOffset]::Parse([string]$_.process_start_time_utc)
            return $processId -gt 0 -and
                $matchedRoot -eq [int]$run.root_process_id -and
                $runtimeHookPids -notcontains $processId -and
                $processStart -ge $intentTime -and
                $processStart -le $outcomeTime
        })
        $event400Diagnostic = Get-DemoEvent400Diagnostic `
            -CandidateProcesses $formalCandidates `
            -RunStart $runStart `
            -RunEnd $runEnd `
            -RootProcessId ([int]$run.root_process_id)
    }
    catch {
        $event400Diagnostic = New-Event400DiagnosticFailure `
            -CandidateCount 0 `
            -ReasonCode 'DIAGNOSTIC_PREPARATION_FAILED'
    }

    $demoManifest = [ordered]@{
        schema_version = 1
        purpose = 'SUMI_GUARD_MANUAL_DEMO'
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        execution_id = [string]$record.execution_id
        command_sha256 = $commandSha256
        execution_store = 'execution-store'
        local_store = 'body-store'
        os_observation = 'execution-store\demo-os-processes.ndjson'
        body_decrypted = $false
        raw_codex_output_saved = $false
        diagnostics = [ordered]@{
            child_codex = [ordered]@{
                child_codex_exit_code = [int]$run.exit_code
                child_codex_timed_out = [bool]$run.timed_out
                stderr_nonempty = $run.stderr_nonempty
                stderr_read_status = [string]$run.stderr_read_status
                stderr_classification = [string]$run.stderr_classification
                stderr_line_count = $run.stderr_line_count
                stderr_utf8_reencoded_byte_count = $run.stderr_utf8_reencoded_byte_count
                stderr_size_measurement = [string]$run.stderr_size_measurement
                raw_stderr_saved = $false
            }
            event400_hook_classification = $event400Diagnostic
            formal_correlation_changed = $false
        }
    }
    [IO.File]::WriteAllText(
        (Join-Path $demoRoot 'demo-manifest.json'),
        ($demoManifest | ConvertTo-Json -Compress -Depth 10),
        $script:Utf8Strict)
    $safeResult = [pscustomobject]@{
        execution_id = [string]$record.execution_id
        execution_status = [string]$outcome.execution_status
        body_status = [string]$record.body_reference_status
        stderr_classification = [string]$run.stderr_classification
    }
    $completed = $true
}
catch {
    $completed = $false
}
finally {
    if ($null -ne $observer) {
        try { Stop-DemoObserver -Observer $observer } catch { }
        $observer = $null
    }
    if ($null -ne $runRoot -and (Test-Path -LiteralPath $runRoot)) {
        $tempRootForDelete = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $resolvedForDelete = [IO.Path]::GetFullPath($runRoot)
        if ($resolvedForDelete.StartsWith($tempRootForDelete, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -cmatch '^sumi-guard-demo-run-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $runRootCleaned = $null -eq $runRoot -or -not (Test-Path -LiteralPath $runRoot)
}

if (-not $completed -or -not $runRootCleaned) {
    Write-Output ('デモ開始: 失敗（段階: {0}）' -f $stage)
    Write-Output '平文本文と例外詳細は表示していません。'
    Write-Output 'デモ保存先が残った場合は、専用の清掃コマンドを実行してください。'
    exit 1
}

Write-Output 'デモ開始: 完了'
Write-Output ('execution_id: {0}' -f $safeResult.execution_id)
Write-Output ('実行状態: {0}' -f $safeResult.execution_status)
Write-Output ('本文保存状態: {0}（暗号化、未復号）' -f $safeResult.body_status)
Write-Output ('子Codex標準エラー要約: {0}（内容未保存、原因は推測しない）' -f `
    $safeResult.stderr_classification)
Write-Output '子プロセス終了・一時フック設定清掃: 完了'
Write-Output '次に .\demo\Show-SumiGuardDemo.ps1 を実行してください。'
