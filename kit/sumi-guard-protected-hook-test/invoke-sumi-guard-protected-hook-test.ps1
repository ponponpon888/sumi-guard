[CmdletBinding()]
param(
    [string]$CodexPath = '',
    [int]$TimeoutSeconds = 150,
    [switch]$KeepTemporaryProject
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$fixedCommand = "Write-Output 'SUMI_GUARD_PROTECTED_TEST_OK'"
$fixedMarker = 'SUMI_GUARD_PROTECTED_TEST_OK'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
$hookSource = Join-Path $scriptRoot 'sumi-guard-protected-hook.ps1'
$observerSource = Join-Path $projectRoot 'kit\sumi-guard-prototype\process-observer.ps1'
$adapterManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'
$localStoreManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Get-Utf8Sha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    [byte[]]$bytes = $script:Utf8Strict.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$digest = $sha256.ComputeHash($bytes)
        try {
            return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            [Array]::Clear($digest, 0, $digest.Length)
        }
    }
    finally {
        $sha256.Dispose()
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
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
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $script:Utf8Strict)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $items.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        }
    }
    return $items.ToArray()
}

function Resolve-CodexExecutable {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = [System.IO.Path]::GetFullPath($RequestedPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
            [System.IO.Path]::GetExtension($resolved) -ine '.exe') {
            throw 'The supplied Codex path is not a native executable.'
        }
        return $resolved
    }

    $native = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($null -ne $native -and (Test-Path -LiteralPath $native.Source -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($native.Source)
    }

    $shim = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $shim) {
        $candidate = Join-Path (Split-Path -Parent $shim.Source) `
            'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The native Codex executable was not found. Supply -CodexPath.'
}

function Get-CliExecutionSummary {
    param([Parameter(Mandatory = $true)][string]$JsonLines)

    $lifecycleEventCount = 0
    $commandIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $fixedOutputObserved = $false
    foreach ($line in ($JsonLines -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($null -eq $event.PSObject.Properties['item']) { continue }
        $item = $event.item
        if ($null -eq $item.PSObject.Properties['type'] -or
            [string]$item.type -cne 'command_execution') {
            continue
        }
        $lifecycleEventCount++
        if ($null -ne $item.PSObject.Properties['id'] -and
            -not [string]::IsNullOrWhiteSpace([string]$item.id)) {
            [void]$commandIds.Add([string]$item.id)
        }
        if ($null -ne $item.PSObject.Properties['aggregated_output'] -and
            ([string]$item.aggregated_output).Contains($fixedMarker)) {
            $fixedOutputObserved = $true
        }
    }
    return [pscustomobject][ordered]@{
        command_count = $commandIds.Count
        lifecycle_event_count = $lifecycleEventCount
        fixed_output_observed = $fixedOutputObserved
    }
}

function Start-NativeProcessObserver {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$ObserverScript
    )

    $rootPidFile = Join-Path $ProjectPath 'observer-root-pids.txt'
    $outputPath = Join-Path $ProjectPath 'os-processes.ndjson'
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
    $argumentLine = (($arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
    }) -join ' ')

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
    }
}

function Stop-NativeProcessObserver {
    param([Parameter(Mandatory = $true)]$Observer)

    [System.IO.File]::WriteAllText(
        $Observer.stop_path,
        [DateTimeOffset]::UtcNow.ToString('o'),
        $script:Utf8Strict)
    if (-not $Observer.process.WaitForExit(5000)) {
        Stop-Process -Id $Observer.process.Id -Force -ErrorAction SilentlyContinue
        $Observer.process.WaitForExit()
    }
    $Observer.process.Dispose()
    return @(Read-Ndjson -Path $Observer.output_path)
}

function Get-ProtectedHookProcessIds {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$StartTime,
        [Parameter(Mandatory = $true)][DateTimeOffset]$EndTime,
        [Parameter(Mandatory = $true)][int[]]$CandidateProcessIds
    )

    if ($CandidateProcessIds.Count -eq 0) { return @() }
    $ids = New-Object System.Collections.Generic.List[int]
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Windows PowerShell'
            Id = 400
            StartTime = $StartTime.LocalDateTime.AddSeconds(-1)
            EndTime = $EndTime.LocalDateTime.AddSeconds(2)
        } -ErrorAction Stop | Where-Object {
            $CandidateProcessIds -contains [int]$_.ProcessId
        })
        foreach ($eventRecord in $events) {
            if (([string]$eventRecord.Message).Contains('sumi-guard-protected-hook.ps1')) {
                $ids.Add([int]$eventRecord.ProcessId)
            }
        }
    }
    catch {
        return @()
    }
    return $ids.ToArray()
}

function Test-ByteSequenceInFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )

    [byte[]]$haystack = [System.IO.File]::ReadAllBytes($Path)
    try {
        if ($Needle.Length -eq 0 -or $haystack.Length -lt $Needle.Length) { return $false }
        for ($offset = 0; $offset -le ($haystack.Length - $Needle.Length); $offset++) {
            $matched = $true
            for ($index = 0; $index -lt $Needle.Length; $index++) {
                if ($haystack[$offset + $index] -ne $Needle[$index]) {
                    $matched = $false
                    break
                }
            }
            if ($matched) { return $true }
        }
        return $false
    }
    finally {
        if ($haystack.Length -gt 0) { [Array]::Clear($haystack, 0, $haystack.Length) }
    }
}

function Test-PlaintextAbsentFromTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [byte[]]$needle = $script:Utf8Strict.GetBytes($Text)
    try {
        foreach ($filePath in [System.IO.Directory]::GetFiles(
            $Path,
            '*',
            [System.IO.SearchOption]::AllDirectories)) {
            if (Test-ByteSequenceInFile -Path $filePath -Needle $needle) {
                return $false
            }
        }
        return $true
    }
    finally {
        if ($needle.Length -gt 0) { [Array]::Clear($needle, 0, $needle.Length) }
    }
}

function Invoke-IsolatedCodexRun {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$HookCommand,
        [Parameter(Mandatory = $true)][string]$RootPidFile,
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [Parameter(Mandatory = $true)][string]$AdapterPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCommandSha256,
        [Parameter(Mandatory = $true)][int]$RunTimeoutSeconds
    )

    $preHooksToml = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=20,statusMessage='Recording protected SUMI Guard intent'}]}]"
    $postHooksToml = "[{matcher='^Bash$',hooks=[{type='command',command='$HookCommand',command_windows='$HookCommand',timeout=20,statusMessage='Recording protected SUMI Guard result'}]}]"
    $prompt = "Call exec_command exactly once with shell set to powershell. Set its cmd field to the exact text between the XML tags, without the tags or any added character. Do not call any other tool. <command>$fixedCommand</command> Return only the command output."
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
        $prompt
    )
    $argumentLine = (($arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
    }) -join ' ')

    $environmentNames = @(
        'SUMI_GUARD_EXPECTED_COMMAND_SHA256',
        'SUMI_GUARD_EXPECTED_OUTPUT_MARKER',
        'SUMI_GUARD_EXECUTION_STORE_PATH',
        'SUMI_GUARD_LOCAL_STORE_PATH',
        'SUMI_GUARD_ADAPTER_MANIFEST',
        'SHELL',
        'Path'
    )
    $oldEnvironment = @{}
    foreach ($name in $environmentNames) {
        $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    [Environment]::SetEnvironmentVariable(
        'SUMI_GUARD_EXPECTED_COMMAND_SHA256', $ExpectedCommandSha256, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SUMI_GUARD_EXPECTED_OUTPUT_MARKER', $fixedMarker, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SUMI_GUARD_EXECUTION_STORE_PATH', $ExecutionStorePath, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SUMI_GUARD_LOCAL_STORE_PATH', $LocalStorePath, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SUMI_GUARD_ADAPTER_MANIFEST', $AdapterPath, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SHELL', (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), 'Process')
    $safePath = (Join-Path $env:SystemRoot 'System32') + ';' +
        $env:SystemRoot + ';' +
        (Join-Path $env:SystemRoot 'System32\Wbem') + ';' +
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    [Environment]::SetEnvironmentVariable('Path', $safePath, 'Process')

    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutText = ''
    $stderrText = ''
    $timedOut = $false
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
        if (-not $process.Start()) { throw 'Codex process did not start.' }
        [System.IO.File]::AppendAllText(
            $RootPidFile,
            ([string]$process.Id) + [Environment]::NewLine,
            $script:Utf8Strict)
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
    $summary = Get-CliExecutionSummary -JsonLines $stdoutText
    $exitCode = $process.ExitCode
    $rootProcessId = $process.Id
    $stderrNonempty = -not [string]::IsNullOrWhiteSpace($stderrText)
    $stdoutText = ''
    $stderrText = ''
    $process.Dispose()
    return [pscustomobject][ordered]@{
        root_process_id = $rootProcessId
        started_at_utc = $startedAt.ToString('o')
        ended_at_utc = $endedAt.ToString('o')
        exit_code = $exitCode
        timed_out = $timedOut
        command_execution_count = $summary.command_count
        command_lifecycle_event_count = $summary.lifecycle_event_count
        fixed_output_observed = $summary.fixed_output_observed
        stderr_nonempty = $stderrNonempty
        raw_stdout_saved = $false
        raw_stderr_saved = $false
    }
}

$requiredFiles = @($hookSource, $observerSource, $adapterManifest, $localStoreManifest)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw 'A required SUMI Guard test component is unavailable.'
    }
}
$CodexPath = Resolve-CodexExecutable -RequestedPath $CodexPath
$fixedCommandSha256 = Get-Utf8Sha256 -Text $fixedCommand
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('sumi-guard-protected-hook-test-' + [Guid]::NewGuid().ToString('N'))
$testRootFullPath = [System.IO.Path]::GetFullPath($testRoot)
if (-not $testRootFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $testRootFullPath) -notlike 'sumi-guard-protected-hook-test-*') {
    throw 'Refusing to use a test root outside the resolved temporary directory.'
}

$observer = $null
$result = $null
try {
    [void](New-Item -ItemType Directory -Path $testRootFullPath -ErrorAction Stop)
    $codexDirectory = Join-Path $testRootFullPath '.codex'
    [void](New-Item -ItemType Directory -Path $codexDirectory -ErrorAction Stop)
    $hookCopy = Join-Path $codexDirectory 'sumi-guard-protected-hook.ps1'
    Copy-Item -LiteralPath $hookSource -Destination $hookCopy -ErrorAction Stop

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if ($null -ne $git) {
        & $git.Source init --quiet $testRootFullPath
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the disposable Git project.' }
    }

    $null = Import-Module -Name $localStoreManifest -Force -ErrorAction Stop
    $null = Import-Module -Name $adapterManifest -Force -ErrorAction Stop
    $localStorePath = Join-Path $testRootFullPath 'body-store'
    $executionStorePath = Join-Path $testRootFullPath 'execution-store'
    $localStoreInit = Initialize-SumiGuardLocalStore -Path $localStorePath
    $executionStoreInit = Initialize-SumiGuardExecutionStore -Path $executionStorePath
    if (-not $localStoreInit.success -or -not $executionStoreInit.success) {
        throw 'Protected test stores could not be initialized.'
    }

    $observer = Start-NativeProcessObserver `
        -ProjectPath $testRootFullPath `
        -ObserverScript $observerSource
    $observerReadyAt = [DateTimeOffset]::Parse($observer.confirmed_at_utc)
    $quotedHook = '"' + $hookCopy + '"'
    $hookCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        $quotedHook
    $run = Invoke-IsolatedCodexRun `
        -CodexExecutable $CodexPath `
        -ProjectPath $testRootFullPath `
        -HookCommand $hookCommand `
        -RootPidFile $observer.root_pid_file `
        -ExecutionStorePath $executionStorePath `
        -LocalStorePath $localStorePath `
        -AdapterPath $adapterManifest `
        -ExpectedCommandSha256 $fixedCommandSha256 `
        -RunTimeoutSeconds $TimeoutSeconds

    $observations = @(Stop-NativeProcessObserver -Observer $observer)
    $observer = $null
    $processObservations = @($observations | Where-Object {
        $_.event_type -ceq 'ProcessObserved'
    })
    $timingSummaries = @($observations | Where-Object {
        $_.event_type -ceq 'ObserverTimingSummary'
    })
    $timingSummary = $null
    if ($timingSummaries.Count -gt 0) {
        $timingSummary = $timingSummaries[$timingSummaries.Count - 1]
    }

    $recordsResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStorePath `
        -LocalStorePath $localStorePath
    $records = @($recordsResult.records)
    $hookRuntime = @(Read-Ndjson -Path (Join-Path $executionStorePath 'hook-runtime.ndjson'))
    $outcomes = @(Read-Ndjson -Path (Join-Path $executionStorePath 'outcomes.ndjson'))
    $hookFailures = @(Read-Ndjson -Path (Join-Path $executionStorePath 'hook-failures.ndjson'))

    $intentRecord = $null
    if ($records.Count -eq 1) { $intentRecord = $records[0] }
    $outcomeRecord = $null
    if ($outcomes.Count -eq 1) { $outcomeRecord = $outcomes[0] }

    $explicitDecryptMatches = $false
    $explicitReadStatus = 'NOT_ATTEMPTED'
    if ($null -ne $intentRecord) {
        $bodyRead = Read-SumiGuardExecutionBody `
            -ExecutionStorePath $executionStorePath `
            -LocalStorePath $localStorePath `
            -ExecutionId ([string]$intentRecord.execution_id)
        $explicitReadStatus = [string]$bodyRead.status
        if ($bodyRead.success) {
            $explicitDecryptMatches = [string]$bodyRead.body -ceq $fixedCommand
        }
        $bodyRead = $null
    }

    $metadataConsistent = $false
    if ($null -ne $intentRecord -and $null -ne $outcomeRecord) {
        $metadataConsistent =
            [string]$intentRecord.execution_id -ceq [string]$outcomeRecord.execution_id -and
            [string]$intentRecord.body_sha256 -ceq $fixedCommandSha256 -and
            [string]$outcomeRecord.command_sha256 -ceq $fixedCommandSha256 -and
            [string]$intentRecord.body_ref -ceq [string]$outcomeRecord.body_ref -and
            [string]$intentRecord.content_status -ceq 'CAPTURED_ENCRYPTED' -and
            [string]$intentRecord.collection_status -ceq 'RECORDS_FOUND' -and
            [string]$intentRecord.body_reference_status -ceq 'AVAILABLE' -and
            [string]$outcomeRecord.body_reference_status -ceq 'AVAILABLE'
    }

    $runStart = [DateTimeOffset]::Parse($run.started_at_utc)
    $runEnd = [DateTimeOffset]::Parse($run.ended_at_utc)
    $candidatesBeforeExclusion = @($processObservations | Where-Object {
        $processStart = [DateTimeOffset]::Parse($_.process_start_time_utc)
        [int]$_.matched_root_process_id -eq [int]$run.root_process_id -and
            $processStart -ge $runStart.AddSeconds(-1) -and
            $processStart -le $runEnd.AddSeconds(2)
    })
    $runtimeHookPids = @($hookRuntime | ForEach-Object { [int]$_.hook_process_id } |
        Select-Object -Unique)
    $event400HookPids = @(Get-ProtectedHookProcessIds `
        -StartTime $runStart `
        -EndTime $runEnd `
        -CandidateProcessIds @($candidatesBeforeExclusion | ForEach-Object { [int]$_.process_id }))
    $excludedHookPids = @((@($runtimeHookPids) + @($event400HookPids)) |
        Select-Object -Unique)
    $candidatesAfterHookExclusion = @($candidatesBeforeExclusion | Where-Object {
        $excludedHookPids -notcontains [int]$_.process_id
    })

    $intentTime = $null
    $outcomeTime = $null
    if ($null -ne $intentRecord) {
        $intentTime = [DateTimeOffset]::Parse([string]$intentRecord.occurred_at_utc)
    }
    if ($null -ne $outcomeRecord) {
        $outcomeTime = [DateTimeOffset]::Parse([string]$outcomeRecord.occurred_at_utc)
    }
    $targetCandidates = @($candidatesAfterHookExclusion | Where-Object {
        $processStart = [DateTimeOffset]::Parse($_.process_start_time_utc)
        $null -ne $intentTime -and $null -ne $outcomeTime -and
            $processStart -ge $intentTime -and $processStart -le $outcomeTime
    })
    $correlation = 'UNMATCHED'
    $correlationReason = 'A unique OS process candidate was not available.'
    if ($records.Count -eq 1 -and $outcomes.Count -eq 1 -and $targetCandidates.Count -eq 1) {
        $correlation = 'INFERRED_MATCH'
        $correlationReason =
            'One non-hook OS process started between the protected intent and outcome under the isolated Codex root; no target PID is present in the hook event.'
    }
    elseif ($targetCandidates.Count -gt 1) {
        $correlationReason =
            'Multiple OS candidates remained after hook-process exclusion and the intent/outcome time window.'
    }

    $plaintextAbsent =
        (Test-PlaintextAbsentFromTree -Path $executionStorePath -Text $fixedMarker) -and
        (Test-PlaintextAbsentFromTree -Path $localStorePath -Text $fixedMarker)
    $bodyPropertyAbsent = $true
    if ($recordsResult.PSObject.Properties.Name -contains 'body') { $bodyPropertyAbsent = $false }
    foreach ($record in $records) {
        if ($record.PSObject.Properties.Name -contains 'body') { $bodyPropertyAbsent = $false }
    }

    $hookIntentSaved = $records.Count -eq 1
    $outcomeSaved = $outcomes.Count -eq 1
    $encryptedBodySaved = $null -ne $intentRecord -and
        [string]$intentRecord.content_status -ceq 'CAPTURED_ENCRYPTED' -and
        [string]$intentRecord.body_reference_status -ceq 'AVAILABLE'
    $overallSuccess =
        $run.exit_code -eq 0 -and -not $run.timed_out -and
        $run.command_execution_count -eq 1 -and $run.fixed_output_observed -and
        $hookIntentSaved -and $outcomeSaved -and
        $encryptedBodySaved -and $explicitDecryptMatches -and
        $metadataConsistent -and $plaintextAbsent -and $bodyPropertyAbsent -and
        $correlation -ceq 'INFERRED_MATCH'

    $safeTargetCandidates = @($targetCandidates | ForEach-Object {
        [pscustomobject][ordered]@{
            process_id = [int]$_.process_id
            parent_process_id = [int]$_.parent_process_id
            process_start_time_utc = [string]$_.process_start_time_utc
            process_name = [string]$_.process_name
            matched_root_process_id = [int]$_.matched_root_process_id
        }
    })
    $intentStatus = $null
    $bodyReferenceStatus = $null
    $outcomeStatus = $null
    if ($null -ne $intentRecord) {
        $intentStatus = [string]$intentRecord.collection_status
        $bodyReferenceStatus = [string]$intentRecord.body_reference_status
    }
    if ($null -ne $outcomeRecord) {
        $outcomeStatus = [string]$outcomeRecord.execution_status
    }
    $result = [ordered]@{
        schema_version = 1
        success = $overallSuccess
        generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        mode = 'MONITOR'
        scope = 'One disposable child Codex session and one harmless fixed command.'
        hook_connection = 'Per-invocation -c hooks override with one-time trust bypass; no persistent registration.'
        fixed_command_sha256 = $fixedCommandSha256
        hash_scope = 'UTF-8 without BOM bytes of JSON-decoded tool_input.command; no normalization'
        pretooluse = [ordered]@{
            execution_intent_count = $records.Count
            saved = $hookIntentSaved
            collection_status = $intentStatus
        }
        protected_body = [ordered]@{
            encrypted_saved = $encryptedBodySaved
            reference_status = $bodyReferenceStatus
            explicit_read_status = $explicitReadStatus
            explicit_decrypt_matches = $explicitDecryptMatches
            body_in_normal_output = -not $bodyPropertyAbsent
        }
        outcome = [ordered]@{
            event_count = $outcomes.Count
            saved_separately = $outcomeSaved
            execution_status = $outcomeStatus
            fixed_output_observed_by_hook = $null -ne $outcomeRecord -and
                [bool]$outcomeRecord.fixed_output_observed
        }
        cli = [ordered]@{
            exit_code = $run.exit_code
            timed_out = $run.timed_out
            command_execution_count = $run.command_execution_count
            command_lifecycle_event_count = $run.command_lifecycle_event_count
            fixed_output_observed = $run.fixed_output_observed
            stderr_nonempty = $run.stderr_nonempty
            raw_output_saved = $false
        }
        os_observation = [ordered]@{
            source = 'NativeProcessPolling'
            collection_confirmed_before_execution = $observerReadyAt -lt $runStart
            poll_timing = $timingSummary
            candidate_count_before_hook_exclusion = $candidatesBeforeExclusion.Count
            hook_runtime_process_ids = @($runtimeHookPids)
            event400_hook_process_ids = @($event400HookPids)
            excluded_hook_process_ids = @($excludedHookPids)
            exclusion_reason =
                'HookRuntimeObserved PID plus Windows PowerShell event 400 hook-name classification; event message was not saved.'
            candidate_count_after_hook_exclusion = $candidatesAfterHookExclusion.Count
            candidate_count_after_time_window = $targetCandidates.Count
            target_candidates = $safeTargetCandidates
        }
        correlation = [ordered]@{
            classification = $correlation
            reason = $correlationReason
        }
        consistency = [ordered]@{
            execution_id_hash_reference_and_states_match = $metadataConsistent
            hook_failure_notice_count = $hookFailures.Count
        }
        non_disclosure = [ordered]@{
            fixed_plaintext_absent_from_metadata_and_body_store = $plaintextAbsent
            raw_cli_output_saved = $false
            raw_os_command_line_saved = $false
            event_log_message_saved = $false
        }
    }
    $resultJson = $result | ConvertTo-Json -Compress -Depth 20
    if ($resultJson.Contains($fixedMarker) -or $resultJson.Contains($fixedCommand)) {
        throw 'The sanitized result unexpectedly contains fixed plaintext.'
    }
}
finally {
    if ($null -ne $observer) {
        $discard = @(Stop-NativeProcessObserver -Observer $observer)
        $observer = $null
    }
    if (-not $KeepTemporaryProject -and (Test-Path -LiteralPath $testRootFullPath)) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRootFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-protected-hook-test-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
        else {
            throw 'Refusing to remove an unvalidated test path.'
        }
    }
}

if ($null -ne $result) {
    $result.temporary_project_cleaned = -not (Test-Path -LiteralPath $testRootFullPath)
    $result | ConvertTo-Json -Depth 20
    if (-not $result.success) { exit 1 }
}
