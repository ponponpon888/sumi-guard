<#
    Regression tests for how hooks/Invoke-SumiGuardMonitorHook.ps1 reads its
    event from standard input.

    The hook used to read standard input through [Console]::In, which decodes
    with the console input code page. On a system whose code page is not UTF-8
    that turned a host's UTF-8 event into mojibake, and a leading BOM into
    stray characters before the first brace, so the event failed to parse and
    the hook recorded nothing while still exiting 0.

    Every case here writes raw bytes to the child's standard input stream and
    never adjusts the console encoding of either process. Changing the test's
    own encoding would hide exactly the defect these cases exist to catch. The
    non-ASCII inputs are built from code points rather than typed into this
    file, so the bytes under test come from the test body and not from however
    this file happens to be stored on disk.

    The adapter runs for real here, but only on its MetadataOnly path, which
    the hook takes unless -CaptureCommandBody is given. That path hashes the
    command and writes an event without ever protecting a body, so it reaches
    no DPAPI call and this file belongs in the code-page-independent suite.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hookPath = Join-Path $projectRoot 'hooks\Invoke-SumiGuardMonitorHook.ps1'
$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$results = New-Object System.Collections.Generic.List[object]
$script:stage = 'start'
$failure = $null
$childStartCount = 0
# A child that had to be killed on a timeout, or that left something running,
# is a failure of the run even when every assertion passed.
$script:timedOutCount = 0
$script:unreapedCount = 0
# A run whose waits could not be completed, or whose children could not be
# checked, has not shown that it left nothing behind. That is a failure too.
$script:unverifiedCount = 0
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-stdin-' + [Guid]::NewGuid().ToString('N'))

# Built from code points so the bytes under test do not depend on this file's
# own encoding. Katakana plus a CJK pair, then a non-BMP character, which is a
# surrogate pair in memory and four bytes in UTF-8.
$japaneseText = -join @(0x30C6, 0x30B9, 0x30C8, 0x6F22, 0x5B57 | ForEach-Object { [char]$_ })
$emojiText = [char]::ConvertFromUtf32(0x1F512)

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        [AllowNull()][hashtable]$Observed
    )

    $row = [ordered]@{ name = $Name; pass = $Pass }
    if ($null -ne $Observed) { $row['observed'] = [pscustomobject]$Observed }
    $results.Add([pscustomobject]$row)
}

function Get-RunField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Run) { return $null }
    $first = @($Run)[0]
    if ($null -eq $first) { return $null }
    if (@($first.PSObject.Properties.Name) -notcontains $Name) { return $null }
    return $first.$Name
}

function Get-DetailField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $detail = Get-RunField -Run $Run -Name 'detail'
    if ($null -eq $detail) { return $null }
    if (@($detail.PSObject.Properties.Name) -notcontains $Name) { return $null }
    return $detail.$Name
}

function Get-ObservedDiagnostic {
    param([Parameter(Mandatory = $true)][AllowNull()]$Run)

    if ($null -eq (Get-RunField -Run $Run -Name 'detail')) {
        return @{ detail_present = $false; exit_code = (Get-RunField -Run $Run -Name 'exit_code') }
    }

    return @{
        detail_present = $true
        sent_byte_count = (Get-RunField -Run $Run -Name 'sent_byte_count')
        sent_first_bytes = [string](Get-RunField -Run $Run -Name 'sent_first_bytes')
        hook_status = [string](Get-DetailField -Run $Run -Name 'hook_status')
        hook_input_profile = [string](Get-DetailField -Run $Run -Name 'hook_input_profile')
        hook_input_decode_status = [string](Get-DetailField -Run $Run -Name 'hook_input_decode_status')
        interpreter_reason_code = [string](Get-DetailField -Run $Run -Name 'interpreter_reason_code')
        assessment_status = [string](Get-DetailField -Run $Run -Name 'assessment_status')
        intent_storage_status = [string](Get-DetailField -Run $Run -Name 'intent_storage_status')
        event_count = (Get-RunField -Run $Run -Name 'event_count')
        body_sha256 = [string](Get-RunField -Run $Run -Name 'body_sha256')
        body_file_count = (Get-RunField -Run $Run -Name 'body_file_count')
        exit_code = (Get-RunField -Run $Run -Name 'exit_code')
    }
}

# Everything below answers one question: when a run is over, is anything this
# test started still alive, and do we actually know? Each step that could hang
# gets its own limit, and each step that could fail gets its own reported
# state, because a step that could not answer must never read as "nothing
# left running".

# The PowerShell processes directly below the given one. cmd also brings up a
# console host that the OS owns and that can briefly outlive cmd, so only what
# this test started is tracked and that host is not mistaken for a leak. A
# failed query returns ok=$false instead of an empty list: "could not look" is
# not "looked and found nothing".
function Get-ChildProcessSnapshot {
    param([Parameter(Mandatory = $true)][int]$ParentId)

    $ids = New-Object System.Collections.Generic.List[int]
    try {
        foreach ($entry in @(Get-CimInstance -ClassName Win32_Process `
            -Filter "ParentProcessId=$ParentId" -ErrorAction Stop)) {
            if ([string]$entry.Name -like 'powershell*') {
                $ids.Add([int]$entry.ProcessId)
            }
        }
        return [pscustomobject]@{ ok = $true; ids = $ids.ToArray() }
    }
    catch {
        return [pscustomobject]@{ ok = $false; ids = @() }
    }
}

# Waits for each id to disappear within a grace period and keeps the three
# outcomes apart: gone, still running, and could not be determined. An
# undetermined check is reported as unverified and never rounded to gone.
function Test-ProcessIdGone {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ProcessId,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $gone = $true
    $verified = $true
    foreach ($id in $ProcessId) {
        while ($true) {
            $state = 'unknown'
            try {
                $handle = [System.Diagnostics.Process]::GetProcessById($id)
                try {
                    $state = if ($handle.HasExited) { 'gone' } else { 'alive' }
                }
                finally {
                    $handle.Dispose()
                }
            }
            catch [System.ArgumentException] {
                # GetProcessById throws this exact type when no process with
                # that id is running, which is the answer we want.
                $state = 'gone'
            }
            catch {
                # Anything else means the question was not answered.
                $state = 'unknown'
            }

            if ($state -ceq 'gone') { break }
            if ([DateTime]::UtcNow -gt $deadline) {
                if ($state -ceq 'alive') { $gone = $false } else { $verified = $false }
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }
    return [pscustomobject]@{ gone = $gone; verified = $verified }
}

# taskkill under its own limit. Left unbounded it is simply one more way for
# the suite to hang, and its output is drained so it cannot block on a full
# pipe. /T takes the tree below this id only, so nothing this test did not
# start is touched, including on the abnormal paths.
function Invoke-ProcessTreeTermination {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [ValidateRange(1000, 60000)][int]$TimeoutMilliseconds = 15000
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $startInfo.Arguments = '/T /F /PID ' + $ProcessId
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $killer = New-Object System.Diagnostics.Process
    $killer.StartInfo = $startInfo
    try {
        if (-not $killer.Start()) { return $false }
        $null = $killer.StandardOutput.ReadToEndAsync()
        $null = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit($TimeoutMilliseconds)) {
            try { $killer.Kill() } catch {
                Write-Verbose 'taskkill cleanup did not need a Kill call.'
            }
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
    finally {
        $killer.Dispose()
    }
}

# Runs one child under a time limit and reports, as separate states, whether
# it finished in time, whether its exit was observed, whether its output was
# collected, whether the kill completed, and whether everything it started is
# gone.
#
# Waiting on cmd proves nothing about the PowerShell cmd started, and reading
# that output without a limit can block on a pipe a surviving grandchild still
# holds, which would hand back the hang the timeout just removed. Every wait
# here is therefore bounded, and a wait that runs out is reported rather than
# folded into a clean result.
function Invoke-SumiGuardTestProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Arguments,
        [ValidateRange(1000, 120000)][int]$TimeoutMilliseconds = 60000,
        [ValidateRange(1000, 60000)][int]$ShutdownTimeoutMilliseconds = 15000
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $timedOut = $false
    $killCompleted = $true
    $exitObserved = $false
    $outputComplete = $false
    $enumerationOk = $true
    $observed = @()
    $stdout = ''
    $stderr = ''
    $exitCode = $null
    try {
        if (-not $process.Start()) {
            throw [System.InvalidOperationException]::new('test child process did not start')
        }
        # Both reads start before any wait so a full pipe cannot block the child.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # One look for the grandchild while the run is still in progress. A run
        # that finishes first simply has nothing to list, which is not a leak.
        if (-not $process.WaitForExit(250)) {
            $snapshot = Get-ChildProcessSnapshot -ParentId $process.Id
            $enumerationOk = $snapshot.ok
            $observed = @($snapshot.ids)
        }

        if ($process.WaitForExit($TimeoutMilliseconds)) {
            $exitObserved = $true
        }
        else {
            $timedOut = $true
            if ($observed.Count -eq 0 -and $enumerationOk) {
                $snapshot = Get-ChildProcessSnapshot -ParentId $process.Id
                $enumerationOk = $snapshot.ok
                $observed = @($snapshot.ids)
            }
            $killCompleted = Invoke-ProcessTreeTermination -ProcessId $process.Id `
                -TimeoutMilliseconds $ShutdownTimeoutMilliseconds
            $exitObserved = $process.WaitForExit($ShutdownTimeoutMilliseconds)
        }

        $outputComplete = $true
        if ($stdoutTask.Wait($ShutdownTimeoutMilliseconds)) { $stdout = [string]$stdoutTask.Result }
        else { $outputComplete = $false }
        if ($stderrTask.Wait($ShutdownTimeoutMilliseconds)) { $stderr = [string]$stderrTask.Result }
        else { $outputComplete = $false }

        if ($exitObserved) {
            try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
        }
    }
    finally {
        # Last resort, still scoped to this run's own tree.
        try {
            if (-not $process.HasExited) { $null = Invoke-ProcessTreeTermination -ProcessId $process.Id }
        }
        catch {
            Write-Verbose 'Final tree cleanup could not run.'
        }
        $process.Dispose()
    }

    $reap = Test-ProcessIdGone -ProcessId $observed
    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        timed_out = $timedOut
        exit_observed = $exitObserved
        output_complete = $outputComplete
        kill_completed = $killCompleted
        observed_descendants = $observed.Count
        descendants_enumerated = $enumerationOk
        descendants_reaped = $reap.gone
        descendants_verified = ($reap.verified -and $enumerationOk)
        stdout_text = $stdout
        stderr_text = $stderr
    }
}

# Protected bodies in the local store are named <32 lowercase hex>.sgb. An
# "is the body store empty" check that looked for any other extension would
# report zero whether or not a body had been written, which is why the name
# the store actually uses is matched here and why the matcher itself is given
# a positive control below.
function Get-BodyContainerCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^[0-9a-f]{32}\.sgb$' }).Count
}

# The reference hash: UTF-8 bytes of the original command string, which is what
# the adapter is expected to have recorded.
function Get-ExpectedBodySha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body)

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    [byte[]]$bytes = $utf8.GetBytes($Body)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

# The event JSON is assembled by hand. ConvertTo-Json escapes non-ASCII to
# \uXXXX, which would send pure ASCII over the wire and test nothing.
function Get-EventJsonText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )

    # Each profile collects a different set of tool names, so the event names
    # the tool that profile actually accepts.
    $identity = if ($ProfileName -ceq 'CLAUDE_PRETOOLUSE') {
        '"tool_name":"PowerShell","session_id":"stdin-session","tool_use_id":"toolu_stdin"'
    }
    else {
        '"tool_name":"Bash","session_id":"stdin-session","turn_id":"stdin-turn","tool_use_id":"toolu_stdin"'
    }

    return '{"hook_event_name":"PreToolUse",' + $identity +
        ',"tool_input":{"command":"' + $Command + '"}}'
}

function Invoke-HookWithStandardInput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$InputBytes,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [string]$ProfileName = 'CODEX_PRETOOLUSE'
    )

    $caseRoot = Join-Path $workRoot $CaseName
    $executionStorePath = Join-Path $caseRoot 'execution-store'
    $bodyStorePath = Join-Path $caseRoot 'body-store'
    $assessmentStorePath = Join-Path $caseRoot 'assessment-store'
    $noticePath = Join-Path $caseRoot 'notices\monitor-hook-notices.ndjson'
    $resultPath = Join-Path $caseRoot 'result.json'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force

    $script:stage = $CaseName + '/store-setup'
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1') -Force
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
    $assessmentInit = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    $bodyInit = Initialize-SumiGuardLocalStore -Path $bodyStorePath
    $executionInit = Initialize-SumiGuardExecutionStore -Path $executionStorePath
    if (-not ($assessmentInit.success -and $bodyInit.success -and $executionInit.success)) {
        throw [System.InvalidOperationException]::new('store setup failed')
    }

    # -TestIntentSaveOutcome is left at ADAPTER so the recorded hash comes from
    # the real adapter rather than from a test double.
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $hookPath,
        '-HookInputProfile', $ProfileName,
        '-ExecutionStorePath', $executionStorePath,
        '-LocalStorePath', $bodyStorePath,
        '-AssessmentStorePath', $assessmentStorePath,
        '-NoticePath', $noticePath,
        '-ResultPath', $resultPath,
        '-TrustedWindowsPowerShellRoute')

    # Standard input comes from a file of exact bytes, redirected by the shell,
    # rather than from Process.StandardInput.
    #
    # Touching Process.StandardInput creates a StreamWriter over the pipe whose
    # encoding is Console.InputEncoding. When that encoding carries a preamble,
    # which it does when the parent console is UTF-8, the writer emits a BOM
    # ahead of anything written to its BaseStream. The harness would then
    # prepend a BOM to every case: the no-BOM cases would silently become BOM
    # cases, and a double BOM would reach the BOM cases. Redirecting from a
    # file keeps the bytes the test wrote the bytes the hook reads, and no
    # console encoding is altered anywhere to achieve it.
    $inputPath = Join-Path $caseRoot 'stdin.bin'
    [System.IO.File]::WriteAllBytes($inputPath, $InputBytes)

    $childCommandLine = (($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value + '"' } else { $value }
    }) -join ' ')
    # /s /c makes cmd strip exactly the outer quotes and take the rest as is.
    $commandLine = '/s /c "' + '"' + $powerShell51 + '" ' + $childCommandLine +
        ' < "' + $inputPath + '"' + '"'

    $script:stage = $CaseName + '/child-run'
    $run = Invoke-SumiGuardTestProcess `
        -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') `
        -Arguments $commandLine
    $script:childStartCount++
    if ($run.timed_out) { $script:timedOutCount++ }
    if (-not $run.descendants_reaped) { $script:unreapedCount++ }
    if (-not ($run.descendants_verified -and $run.output_complete -and
        $run.exit_observed -and $run.kill_completed)) { $script:unverifiedCount++ }
    $stdout = [string]$run.stdout_text
    $stderr = [string]$run.stderr_text
    $exitCode = $run.exit_code

    $script:stage = $CaseName + '/read-result'
    $detail = $null
    if (Test-Path -LiteralPath $resultPath) {
        $detail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    # The event file is read as bytes and decoded as UTF-8 here too, for the
    # same reason the hook does: -Encoding UTF8 on Get-Content is fine, but
    # reading the hash out of a mis-decoded line would be its own bug.
    $script:stage = $CaseName + '/read-event'
    $eventCount = 0
    $bodySha256 = ''
    $eventPath = Join-Path $executionStorePath 'events.ndjson'
    if (Test-Path -LiteralPath $eventPath) {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $eventText = $utf8.GetString([System.IO.File]::ReadAllBytes($eventPath))
        foreach ($line in ($eventText -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $eventCount++
            $record = $line | ConvertFrom-Json
            if (@($record.PSObject.Properties.Name) -contains 'body_sha256') {
                $bodySha256 = [string]$record.body_sha256
            }
        }
    }

    $script:stage = $CaseName + '/read-body-store'
    $bodyFileCount = Get-BodyContainerCount -Path $bodyStorePath

    $script:stage = $CaseName + '/read-notice'
    $noticeText = ''
    if (Test-Path -LiteralPath $noticePath) {
        $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
    }

    # The leading bytes actually written, so a failed case reports what went
    # over the wire rather than only what the hook made of it.
    $sentPrefix = (@($InputBytes | Select-Object -First 6) | ForEach-Object { $_.ToString('x2') }) -join ' '

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        timed_out = $run.timed_out
        descendants_reaped = $run.descendants_reaped
        observed_descendants = $run.observed_descendants
        sent_byte_count = $InputBytes.Length
        sent_first_bytes = $sentPrefix
        stdout_text = $stdout
        stderr_text = $stderr
        detail = $detail
        event_count = $eventCount
        body_sha256 = $bodySha256
        body_file_count = $bodyFileCount
        notice_text = $noticeText
    }
}

function Test-MonitorOnlyResponse {
    param([Parameter(Mandatory = $true)]$Run)

    if ((Get-RunField -Run $Run -Name 'exit_code') -ne 0) { return $false }

    $response = $null
    try { $response = (Get-RunField -Run $Run -Name 'stdout_text') | ConvertFrom-Json } catch { return $false }
    if ($null -eq $response) { return $false }

    $names = @($response.PSObject.Properties.Name)
    if ($names.Count -ne 1 -or $names[0] -cne 'systemMessage') { return $false }

    $lowered = ([string](Get-RunField -Run $Run -Name 'stdout_text')).ToLowerInvariant()
    foreach ($word in @('"deny"', 'permissiondecision', 'block')) {
        if ($lowered.Contains($word)) { return $false }
    }

    if ($null -eq $Run.detail) { return $false }
    return ((-not [bool](Get-DetailField -Run $Run -Name 'automatic_deny')) -and
        ([string](Get-DetailField -Run $Run -Name 'monitor_action') -ceq 'WARN_ONLY'))
}

# A run that recorded the command the host sent: one event, and a hash equal to
# the one computed here from the original string.
function Test-RecordedBody {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )

    return (
        [string](Get-DetailField -Run $Run -Name 'hook_status') -ceq 'COMPLETED' -and
        [string](Get-DetailField -Run $Run -Name 'hook_input_decode_status') -ceq 'DECODED' -and
        (Get-RunField -Run $Run -Name 'event_count') -eq 1 -and
        [string](Get-RunField -Run $Run -Name 'body_sha256') -ceq (Get-ExpectedBodySha256 -Body $Command) -and
        (Get-RunField -Run $Run -Name 'body_file_count') -eq 0)
}

try {
    $null = New-Item -ItemType Directory -Path $workRoot -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
    [byte[]]$bomBytes = @(0xEF, 0xBB, 0xBF)

    # Control for the waiting machinery itself. Every other case here finishes
    # on its own, so none of them exercises the timeout, the tree kill or the
    # reap check, and all of those could be broken while the suite stayed
    # green. This child waits far longer than its limit on purpose: the run has
    # to come back inside the limit, the PowerShell under cmd has to be seen
    # and then confirmed gone, and every bounded wait has to have completed.
    #
    # The helper is called directly rather than through Invoke-Hook, so this
    # deliberate timeout is not counted against the run.
    try {
        $script:stage = 'assert/waiting-child-control'
        $sleeper = '"' + $powerShell51 + '" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $controlRun = Invoke-SumiGuardTestProcess `
            -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -Arguments ('/s /c "' + $sleeper + '"') `
            -TimeoutMilliseconds 3000
        $watch.Stop()
        $script:childStartCount++
        $script:stage = 'add/WAITING_CHILD_RETURNS_WITHIN_LIMIT_AND_IS_REAPED'
        Add-Result 'WAITING_CHILD_RETURNS_WITHIN_LIMIT_AND_IS_REAPED' (
            [bool]$controlRun.timed_out -and
            # Well under the 120s the child asked for: the limit, not the
            # child, decided when this returned.
            $watch.Elapsed.TotalSeconds -lt 60 -and
            [int]$controlRun.observed_descendants -ge 1 -and
            [bool]$controlRun.descendants_enumerated -and
            [bool]$controlRun.descendants_verified -and
            [bool]$controlRun.descendants_reaped -and
            [bool]$controlRun.kill_completed -and
            [bool]$controlRun.exit_observed -and
            [bool]$controlRun.output_complete) -Observed @{
                elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
                timed_out = [bool]$controlRun.timed_out
                observed_descendants = [int]$controlRun.observed_descendants
                descendants_enumerated = [bool]$controlRun.descendants_enumerated
                descendants_verified = [bool]$controlRun.descendants_verified
                descendants_reaped = [bool]$controlRun.descendants_reaped
                kill_completed = [bool]$controlRun.kill_completed
                exit_observed = [bool]$controlRun.exit_observed
                output_complete = [bool]$controlRun.output_complete
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_WAITING_CHILD_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Positive control for the body-store check. Every case below asserts that
    # no body container was written; that assertion is only worth anything if
    # the counter would notice one. Fixed names on disk, no store involved.
    try {
        $script:stage = 'assert/body-container-detector'
        $detectorRoot = Join-Path $workRoot 'body-container-detector'
        $null = New-Item -ItemType Directory -Path $detectorRoot -Force
        $emptyCount = Get-BodyContainerCount -Path $detectorRoot
        Set-Content -LiteralPath (Join-Path $detectorRoot '0123456789abcdef0123456789abcdef.sgb') -Value 'x' -Encoding Ascii
        $oneCount = Get-BodyContainerCount -Path $detectorRoot
        # Names that are not containers must not be counted.
        Set-Content -LiteralPath (Join-Path $detectorRoot 'notes.txt') -Value 'x' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $detectorRoot 'abcd.sgb') -Value 'x' -Encoding Ascii
        $stillOneCount = Get-BodyContainerCount -Path $detectorRoot
        $script:stage = 'add/BODY_CONTAINER_DETECTOR_WORKS'
        Add-Result 'BODY_CONTAINER_DETECTOR_WORKS' (
            $emptyCount -eq 0 -and $oneCount -eq 1 -and $stillOneCount -eq 1) -Observed @{
                empty = $emptyCount; with_container = $oneCount; with_decoys = $stillOneCount }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_BODY_CONTAINER_DETECTOR' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Cases 1-3 over both profiles: ASCII, non-ASCII, and a leading BOM. Each
    # must decode to the original command and record its hash.
    foreach ($profileName in @('CODEX_PRETOOLUSE', 'CLAUDE_PRETOOLUSE')) {
        $shortName = if ($profileName -ceq 'CLAUDE_PRETOOLUSE') { 'claude' } else { 'codex' }

        foreach ($case in @(
            @{ key = 'ascii'; command = 'Get-Date'; bom = $false },
            @{ key = 'japanese'; command = ('Write-Output ' + $japaneseText); bom = $false },
            @{ key = 'emoji'; command = ('Write-Output ' + $emojiText); bom = $false },
            @{ key = 'bom'; command = ('Write-Output ' + $japaneseText); bom = $true })) {

            try {
                $caseName = $shortName + '-' + $case.key
                $script:stage = 'assert/' + $caseName
                $json = Get-EventJsonText -Command ([string]$case.command) -ProfileName $profileName
                [byte[]]$payload = $utf8NoBom.GetBytes($json)
                if ($case.bom) { $payload = $bomBytes + $payload }

                $run = Invoke-HookWithStandardInput -InputBytes $payload -CaseName $caseName -ProfileName $profileName
                $script:stage = 'add/' + $caseName
                Add-Result ($caseName.ToUpperInvariant().Replace('-', '_') + '_IS_RECORDED') (
                    (Test-RecordedBody -Run $run -Command ([string]$case.command)) -and
                    (Test-MonitorOnlyResponse -Run $run)) -Observed (Get-ObservedDiagnostic -Run $run)
            }
            catch {
                Add-Result ('CASE_EXCEPTION_' + $shortName + '_' + $case.key) $false -Observed @{
                    exception_type = $_.Exception.GetType().FullName
                    script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
                    stage = [string]$script:stage
                }
            }
        }
    }

    # A BOM sequence that is not at the very start stays part of the content.
    # Only the leading one is consumed, and nothing else is stripped.
    try {
        $script:stage = 'assert/interior-bom'
        $interiorCommand = 'Write-Output ' + ([char]0xFEFF) + 'tail'
        $json = Get-EventJsonText -Command $interiorCommand -ProfileName 'CODEX_PRETOOLUSE'
        $run = Invoke-HookWithStandardInput -InputBytes ($utf8NoBom.GetBytes($json)) -CaseName 'interior-bom'
        $script:stage = 'add/INTERIOR_BOM_IS_PART_OF_THE_CONTENT'
        Add-Result 'INTERIOR_BOM_IS_PART_OF_THE_CONTENT' (
            Test-RecordedBody -Run $run -Command $interiorCommand) -Observed (Get-ObservedDiagnostic -Run $run)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INTERIOR_BOM' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Case 4: malformed UTF-8. A lone continuation byte cannot begin a sequence.
    # It must be a fixed failure state, not a U+FFFD substitution that would be
    # assessed and hashed as though it were the command the host sent.
    try {
        $script:stage = 'assert/invalid-utf8'
        $prefix = $utf8NoBom.GetBytes('{"hook_event_name":"PreToolUse","tool_name":"PowerShell","session_id":"stdin-session","turn_id":"stdin-turn","tool_use_id":"toolu_stdin","tool_input":{"command":"Write-Output ')
        $suffix = $utf8NoBom.GetBytes('"}}')
        [byte[]]$invalid = $prefix + [byte[]]@(0x80, 0xFF) + $suffix
        $run = Invoke-HookWithStandardInput -InputBytes $invalid -CaseName 'invalid-utf8'
        $script:stage = 'add/INVALID_UTF8_IS_A_FIXED_FAILURE'
        Add-Result 'INVALID_UTF8_IS_A_FIXED_FAILURE' (
            [string](Get-DetailField -Run $run -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string](Get-DetailField -Run $run -Name 'hook_input_decode_status') -ceq 'NOT_UTF8' -and
            [string](Get-DetailField -Run $run -Name 'interpreter_reason_code') -ceq 'HOOK_INPUT_NOT_UTF8' -and
            [string](Get-DetailField -Run $run -Name 'assessment_status') -ceq 'NOT_OBTAINED' -and
            [string](Get-DetailField -Run $run -Name 'intent_storage_status') -ceq 'NOT_ATTEMPTED' -and
            (Get-RunField -Run $run -Name 'event_count') -eq 0) -Observed (Get-ObservedDiagnostic -Run $run)
        $script:stage = 'add/INVALID_UTF8_IS_MONITOR_ONLY'
        Add-Result 'INVALID_UTF8_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $run)
        $script:stage = 'add/INVALID_UTF8_LEAKS_NO_REPLACEMENT_CHARACTER'
        # U+FFFD anywhere in an artefact would mean a malformed byte had been
        # substituted and carried forward instead of refused.
        $replacement = ([char]0xFFFD).ToString()
        $leaked = $false
        foreach ($field in @('stdout_text', 'stderr_text', 'notice_text')) {
            if (([string](Get-RunField -Run $run -Name $field)).Contains($replacement)) { $leaked = $true }
        }
        $detailJson = ''
        if ($null -ne (Get-RunField -Run $run -Name 'detail')) {
            $detailJson = (Get-RunField -Run $run -Name 'detail') | ConvertTo-Json -Depth 10
        }
        if ($detailJson.Contains($replacement)) { $leaked = $true }
        Add-Result 'INVALID_UTF8_LEAKS_NO_REPLACEMENT_CHARACTER' (-not $leaked)
        $script:stage = 'add/INVALID_UTF8_NOTICE_OMITS_DETAIL'
        Add-Result 'INVALID_UTF8_NOTICE_OMITS_DETAIL' (
            [string]::IsNullOrEmpty([string](Get-RunField -Run $run -Name 'notice_text')) -and
            [string]::IsNullOrEmpty([string](Get-RunField -Run $run -Name 'stderr_text')))
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INVALID_UTF8' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # UTF-16 is not detected and re-interpreted. Its bytes are simply not valid
    # UTF-8, so the run ends in the same fixed failure state.
    try {
        $script:stage = 'assert/utf16'
        $utf16 = [System.Text.Encoding]::Unicode.GetBytes((Get-EventJsonText -Command 'Get-Date' -ProfileName 'CODEX_PRETOOLUSE'))
        $run = Invoke-HookWithStandardInput -InputBytes $utf16 -CaseName 'utf16'
        $script:stage = 'add/UTF16_IS_NOT_DETECTED'
        Add-Result 'UTF16_IS_NOT_DETECTED' (
            [string](Get-DetailField -Run $run -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            (Get-RunField -Run $run -Name 'event_count') -eq 0 -and
            (Test-MonitorOnlyResponse -Run $run)) -Observed (Get-ObservedDiagnostic -Run $run)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_UTF16' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Case 5: nothing to read, and well-formed UTF-8 that is not an event.
    try {
        $script:stage = 'assert/empty-input'
        $empty = Invoke-HookWithStandardInput -InputBytes ([byte[]]@()) -CaseName 'empty-input'
        $script:stage = 'add/EMPTY_INPUT_IS_INVALID_NOT_UNDECODABLE'
        Add-Result 'EMPTY_INPUT_IS_INVALID_NOT_UNDECODABLE' (
            [string](Get-DetailField -Run $empty -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string](Get-DetailField -Run $empty -Name 'hook_input_decode_status') -ceq 'DECODED' -and
            [string](Get-DetailField -Run $empty -Name 'interpreter_reason_code') -ceq 'HOOK_INPUT_INVALID' -and
            (Get-RunField -Run $empty -Name 'event_count') -eq 0 -and
            (Test-MonitorOnlyResponse -Run $empty)) -Observed (Get-ObservedDiagnostic -Run $empty)

        $script:stage = 'assert/invalid-json'
        $notJson = Invoke-HookWithStandardInput -InputBytes ($utf8NoBom.GetBytes('this is not json')) -CaseName 'invalid-json'
        $script:stage = 'add/INVALID_JSON_IS_SEPARATE_FROM_NOT_UTF8'
        Add-Result 'INVALID_JSON_IS_SEPARATE_FROM_NOT_UTF8' (
            [string](Get-DetailField -Run $notJson -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string](Get-DetailField -Run $notJson -Name 'hook_input_decode_status') -ceq 'DECODED' -and
            [string](Get-DetailField -Run $notJson -Name 'interpreter_reason_code') -ceq 'HOOK_INPUT_INVALID' -and
            (Get-RunField -Run $notJson -Name 'event_count') -eq 0 -and
            (Test-MonitorOnlyResponse -Run $notJson)) -Observed (Get-ObservedDiagnostic -Run $notJson)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_EMPTY_OR_INVALID_JSON' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # The direct-argument contract is unchanged: a value passed on the command
    # line is used as given and standard input is not consulted.
    try {
        $script:stage = 'assert/direct-argument'
        $caseRoot = Join-Path $workRoot 'direct-argument'
        $assessmentStorePath = Join-Path $caseRoot 'assessment-store'
        $null = New-Item -ItemType Directory -Path $caseRoot -Force
        Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
        $null = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
        $resultPath = Join-Path $caseRoot 'result.json'
        $directJson = Get-EventJsonText -Command 'Get-Date' -ProfileName 'CODEX_PRETOOLUSE'
        # -EncodedCommand carries the JSON across the process boundary intact.
        # Passing it as a plain -File argument lets the native command line
        # parser rewrite its quotes, and the hook would then be judged on an
        # argument the test never actually sent. No value here contains a
        # single quote, so single-quoted literals are exact.
        $inner = "& '$hookPath' " +
            "-RawHookInputJson '$directJson' " +
            "-ExecutionStorePath '$(Join-Path $caseRoot 'execution-store')' " +
            "-LocalStorePath '$(Join-Path $caseRoot 'body-store')' " +
            "-AssessmentStorePath '$assessmentStorePath' " +
            "-NoticePath '$(Join-Path $caseRoot 'notices\n.ndjson')' " +
            "-ResultPath '$resultPath' " +
            "-TestIntentSaveOutcome 'TEST_SUCCESS'"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        # Through the same helper as the other cases, so this path is under a
        # time limit too and its descendants are checked.
        $directProcess = Invoke-SumiGuardTestProcess `
            -FileName $powerShell51 `
            -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
        $script:childStartCount++
        if ($directProcess.timed_out) { $script:timedOutCount++ }
        if (-not $directProcess.descendants_reaped) { $script:unreapedCount++ }
        if (-not ($directProcess.descendants_verified -and $directProcess.output_complete -and
            $directProcess.exit_observed -and $directProcess.kill_completed)) { $script:unverifiedCount++ }
        $directDetail = $null
        if (Test-Path -LiteralPath $resultPath) {
            $directDetail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $directRun = [pscustomobject]@{ detail = $directDetail }
        $script:stage = 'add/DIRECT_ARGUMENT_CONTRACT_IS_UNCHANGED'
        Add-Result 'DIRECT_ARGUMENT_CONTRACT_IS_UNCHANGED' (
            [string](Get-DetailField -Run $directRun -Name 'hook_status') -ceq 'COMPLETED' -and
            [string](Get-DetailField -Run $directRun -Name 'hook_input_decode_status') -ceq 'DIRECT_ARGUMENT' -and
            [string](Get-DetailField -Run $directRun -Name 'intent_storage_status') -ceq 'TEST_DOUBLE_SAVED') `
            -Observed @{
                hook_status = [string](Get-DetailField -Run $directRun -Name 'hook_status')
                hook_input_decode_status = [string](Get-DetailField -Run $directRun -Name 'hook_input_decode_status')
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_DIRECT_ARGUMENT' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        stage = [string]$script:stage
        exception_type = $_.Exception.GetType().FullName
        target = [string]$_.CategoryInfo.TargetName
        script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
    }
}
finally {
    $workRootRemoved = $true
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        $workRootRemoved = -not (Test-Path -LiteralPath $workRoot)
    }

    $failed = @($results | Where-Object { -not $_.pass })
    # A leftover temporary root or a child that outlived its run is a failed
    # run, not a footnote under a successful one: reporting success while
    # either is true would hide exactly the states these fields exist to catch.
    $summary = [pscustomobject][ordered]@{
        success = ($failed.Count -eq 0 -and $null -eq $failure -and
            $workRootRemoved -and $script:timedOutCount -eq 0 -and $script:unreapedCount -eq 0 -and
            $script:unverifiedCount -eq 0)
        powershell_version = $PSVersionTable.PSVersion.ToString()
        console_input_encoding = [Console]::InputEncoding.WebName
        failure_stage = $(if ($null -eq $failure) { $null } else { [string]$failure.stage })
        failure_line = $(if ($null -eq $failure) { $null } else { [int]$failure.script_line_number })
        failure_exception_type = $(if ($null -eq $failure) { $null } else { [string]$failure.exception_type })
        last_completed_case = $(if ($results.Count -eq 0) { $null } else { [string]$results[$results.Count - 1].name })
        test_count = $results.Count
        passed_count = $results.Count - $failed.Count
        failed_count = $failed.Count
        failed_cases = @($failed | ForEach-Object { $_.name })
        failure = $failure
        results = $results.ToArray()
        hook_child_processes_started = $childStartCount
        child_processes_timed_out = $script:timedOutCount
        child_processes_left_running = $script:unreapedCount
        child_process_state_unverified = $script:unverifiedCount
        command_inputs_executed = $false
        body_store_written = $false
        network_access_performed = $false
        console_encoding_modified = $false
        test_root_cleaned = $workRootRemoved
        structured_output_only = $true
    }
    $summary | ConvertTo-Json -Depth 8

    if ($summary.success) { exit 0 } else { exit 1 }
}


