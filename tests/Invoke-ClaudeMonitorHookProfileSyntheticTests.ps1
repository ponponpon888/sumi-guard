<#
    Synthetic tests for the CLAUDE_PRETOOLUSE profile of
    hooks/Invoke-SumiGuardMonitorHook.ps1.

    Every input is fixed string data passed to the hook as hook-event JSON. No
    input is executed: the hook is started as a child Windows PowerShell 5.1
    process with -File, and the command strings inside the events never reach a
    shell, the call operator, Invoke-Expression or Start-Process. The body store
    is not touched; -TestIntentSaveOutcome stands in for the adapter because its
    protection is DPAPI CurrentUser, which keeps this file runnable on a shared
    runner.

    The companion file Invoke-MonitorHookSyntheticTests.ps1 covers the default
    CODEX_PRETOOLUSE profile. This one covers what the second profile changes:
    the identity fields, the execution_id space, the evaluation origin and the
    interpreter decision. A few Codex-profile cases appear here too, to show
    that the existing contract still refuses what it refused before.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hookPath = Join-Path $projectRoot 'hooks\Invoke-SumiGuardMonitorHook.ps1'
$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$canary = 'SYNTHETIC_SECRET_CANARY_9b21'
$detectedCommand = 'Set-MpPreference -DisableRealtimeMonitoring $true'
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
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-claude-hook-' + [Guid]::NewGuid().ToString('N'))

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass,
        # Fixed status and reason codes only, so a failure says what it saw
        # without copying command text into the test output.
        [AllowNull()][hashtable]$Observed
    )

    $row = [ordered]@{ name = $Name; pass = $Pass }
    if ($null -ne $Observed) {
        $row['observed'] = [pscustomobject]$Observed
    }
    $results.Add([pscustomobject]$row)
}

# Reads one field of the object Invoke-Hook returned. Under Set-StrictMode 2.0
# a property access on $null or on an absent member aborts the whole run, which
# would cost every later case, so a missing value comes back as $null instead.
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

function Get-AssessmentField {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Run,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $assessment = Get-DetailField -Run $Run -Name 'assessment'
    if ($null -eq $assessment) { return $null }
    if (@($assessment.PSObject.Properties.Name) -notcontains $Name) { return $null }
    return $assessment.$Name
}

function Get-ObservedDiagnostic {
    param([Parameter(Mandatory = $true)][AllowNull()]$Run)

    $runCount = 0
    if ($null -ne $Run) { $runCount = @($Run).Count }

    if ($null -eq (Get-RunField -Run $Run -Name 'detail')) {
        return @{ detail_present = $false; run_count = $runCount }
    }

    $reasonCode = [string](Get-AssessmentField -Run $Run -Name 'assessment_reason_code')

    return @{
        detail_present = $true
        run_count = $runCount
        hook_input_profile = [string](Get-DetailField -Run $Run -Name 'hook_input_profile')
        hook_status = [string](Get-DetailField -Run $Run -Name 'hook_status')
        execution_id = [string](Get-DetailField -Run $Run -Name 'execution_id')
        evaluation_origin = [string](Get-DetailField -Run $Run -Name 'evaluation_origin')
        assessment_status = [string](Get-DetailField -Run $Run -Name 'assessment_status')
        assessment_reason_code = $reasonCode
        assessment_storage_status = [string](Get-DetailField -Run $Run -Name 'assessment_storage_status')
        intent_storage_status = [string](Get-DetailField -Run $Run -Name 'intent_storage_status')
        interpreter_verified = [bool](Get-DetailField -Run $Run -Name 'interpreter_verified')
        interpreter_kind = [string](Get-DetailField -Run $Run -Name 'interpreter_kind')
        interpreter_reason_code = [string](Get-DetailField -Run $Run -Name 'interpreter_reason_code')
        store_is_empty = [string]::IsNullOrEmpty([string](Get-RunField -Run $Run -Name 'store_text'))
        exit_code = (Get-RunField -Run $Run -Name 'exit_code')
    }
}

# A Claude Code PreToolUse event. It carries no turn_id, because Claude Code
# emits that field only for MessageDisplay. Nothing stands in for it here.
function Get-ClaudeEventJson {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [string]$SessionId = 'claude-session-1',
        [string]$ToolUseId = 'toolu_01ABC',
        [string]$ToolName = 'Bash',
        [string]$HookEventName = 'PreToolUse',
        [switch]$OmitToolUseId
    )

    $hookEvent = [ordered]@{
        hook_event_name = $HookEventName
        tool_name = $ToolName
        session_id = $SessionId
        transcript_path = 'C:\synthetic\transcript.jsonl'
        cwd = 'C:\synthetic'
        permission_mode = 'default'
        tool_input = [ordered]@{ command = $Command; description = 'synthetic' }
    }
    if (-not $OmitToolUseId) {
        $hookEvent['tool_use_id'] = $ToolUseId
    }
    return ($hookEvent | ConvertTo-Json -Compress -Depth 5)
}

# A Codex PreToolUse event, which does carry turn_id.
function Get-CodexEventJson {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [string]$SessionId = 'claude-session-1',
        [string]$TurnId = 'codex-turn-1',
        [string]$ToolUseId = 'toolu_01ABC'
    )

    return ([ordered]@{
        hook_event_name = 'PreToolUse'
        tool_name = 'Bash'
        session_id = $SessionId
        turn_id = $TurnId
        tool_use_id = $ToolUseId
        tool_input = [ordered]@{ command = $Command }
    } | ConvertTo-Json -Compress -Depth 5)
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

function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EventJson,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [string]$ProfileName = 'CLAUDE_PRETOOLUSE',
        [switch]$OmitProfile,
        [string]$Origin,
        [switch]$TrustedRoute
    )

    $caseRoot = Join-Path $workRoot $CaseName
    $assessmentStorePath = Join-Path $caseRoot 'assessment-store'
    $noticePath = Join-Path $caseRoot 'notices\monitor-hook-notices.ndjson'
    $resultPath = Join-Path $caseRoot 'result.json'
    $null = New-Item -ItemType Directory -Path $caseRoot -Force

    $script:stage = $CaseName + '/store-setup'
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    $created = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    if (-not $created.success) {
        throw [System.InvalidOperationException]::new('assessment store setup failed')
    }

    # The event goes in over standard input, which is how a hook host delivers
    # it. It is not passed as -RawHookInputJson: Windows PowerShell 5.1 does not
    # reliably preserve a JSON argument across a native command boundary.
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $hookPath,
        '-ExecutionStorePath', (Join-Path $caseRoot 'execution-store'),
        '-LocalStorePath', (Join-Path $caseRoot 'body-store'),
        '-AssessmentStorePath', $assessmentStorePath,
        '-NoticePath', $noticePath,
        '-ResultPath', $resultPath,
        '-TestIntentSaveOutcome', 'TEST_SUCCESS')
    if (-not $OmitProfile) { $arguments += @('-HookInputProfile', $ProfileName) }
    if ($PSBoundParameters.ContainsKey('Origin')) { $arguments += @('-EvaluationOrigin', $Origin) }
    if ($TrustedRoute) { $arguments += '-TrustedWindowsPowerShellRoute' }

    # The event is written to a file and redirected in by the shell rather than
    # piped with the call operator. A pipeline gives no process handle, so the
    # run would have no time limit and a hook that blocked would hold the suite
    # open indefinitely.
    $inputPath = Join-Path $caseRoot 'stdin.bin'
    [System.IO.File]::WriteAllBytes($inputPath, (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($EventJson))

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
    $exitCode = $run.exit_code

    $script:stage = $CaseName + '/read-result'
    $detail = $null
    if (Test-Path -LiteralPath $resultPath) {
        $detail = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $script:stage = $CaseName + '/read-store'
    $storeText = ''
    $storeFile = Join-Path $assessmentStorePath 'assessments.ndjson'
    if (Test-Path -LiteralPath $storeFile) {
        $storeText = Get-Content -LiteralPath $storeFile -Raw -Encoding UTF8
    }

    $script:stage = $CaseName + '/read-notice'
    $noticeText = ''
    if (Test-Path -LiteralPath $noticePath) {
        $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
    }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        timed_out = $run.timed_out
        descendants_reaped = $run.descendants_reaped
        stdout_text = $stdout
        detail = $detail
        store_text = $storeText
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

# Every artefact a run can leave behind, checked for the command text.
function Test-NoCommandTextLeaked {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Needle
    )

    foreach ($field in @('stdout_text', 'store_text', 'notice_text')) {
        $text = [string](Get-RunField -Run $Run -Name $field)
        if ($text.Contains($Needle)) { return $false }
    }
    $detail = Get-RunField -Run $Run -Name 'detail'
    if ($null -ne $detail) {
        if (($detail | ConvertTo-Json -Depth 10).Contains($Needle)) { return $false }
    }
    return $true
}

try {
    $null = New-Item -ItemType Directory -Path $workRoot -Force

    # The hook is the thing under test, so its own source is checked for the
    # ways a command string could reach execution.
    $hookSource = Get-Content -LiteralPath $hookPath -Raw -Encoding UTF8
    $sourceClean = $true
    foreach ($pattern in @('Invoke-Expression', 'Start-Process', 'iex ', '& $commandText', '. $commandText')) {
        if ($hookSource.Contains($pattern)) { $sourceClean = $false }
    }
    $script:stage = 'add/HOOK_SOURCE_NEVER_EXECUTES_COMMAND_TEXT'
    Add-Result 'HOOK_SOURCE_NEVER_EXECUTES_COMMAND_TEXT' $sourceClean

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

    # 1. The profile accepts an event with no turn_id, and nothing stands in for
    #    the absent field.
    try {
        $script:stage = 'assert/claude-accepts'
        $accepted = Invoke-Hook -CaseName 'claude-accepts' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date')
        $acceptedId = [string](Get-DetailField -Run $accepted -Name 'execution_id')
        $script:stage = 'add/CLAUDE_PROFILE_ACCEPTS_EVENT_WITHOUT_TURN_ID'
        Add-Result 'CLAUDE_PROFILE_ACCEPTS_EVENT_WITHOUT_TURN_ID' (
            [string](Get-DetailField -Run $accepted -Name 'hook_status') -ceq 'COMPLETED' -and
            [string](Get-DetailField -Run $accepted -Name 'hook_input_profile') -ceq 'CLAUDE_PRETOOLUSE' -and
            $acceptedId -match '^[0-9a-f]{32}$' -and
            [string](Get-DetailField -Run $accepted -Name 'assessment_storage_status') -ceq 'SAVED' -and
            [string](Get-DetailField -Run $accepted -Name 'intent_storage_status') -ceq 'TEST_DOUBLE_SAVED') `
            -Observed (Get-ObservedDiagnostic -Run $accepted)
        $script:stage = 'add/CLAUDE_RESULT_RECORDS_NO_TURN_ID'
        Add-Result 'CLAUDE_RESULT_RECORDS_NO_TURN_ID' (
            -not (($accepted.detail | ConvertTo-Json -Depth 10).Contains('turn_id')))
        $script:stage = 'add/CLAUDE_PROFILE_IS_MONITOR_ONLY'
        Add-Result 'CLAUDE_PROFILE_IS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $accepted)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_CLAUDE_ACCEPTS' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 2. The Codex profile still refuses the same event. The existing contract
    #    is not relaxed by the addition of a second profile.
    try {
        $script:stage = 'assert/codex-refuses-claude-shape'
        $refused = Invoke-Hook -CaseName 'codex-refuses-claude-shape' -ProfileName 'CODEX_PRETOOLUSE' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date')
        $script:stage = 'add/CODEX_PROFILE_STILL_REQUIRES_TURN_ID'
        Add-Result 'CODEX_PROFILE_STILL_REQUIRES_TURN_ID' (
            [string](Get-DetailField -Run $refused -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string](Get-DetailField -Run $refused -Name 'interpreter_reason_code') -ceq 'HOOK_INPUT_INVALID' -and
            [string]::IsNullOrEmpty([string](Get-RunField -Run $refused -Name 'store_text'))) `
            -Observed (Get-ObservedDiagnostic -Run $refused)

        $script:stage = 'assert/codex-default-profile'
        $codexDefault = Invoke-Hook -CaseName 'codex-default-profile' -OmitProfile -TrustedRoute `
            -EventJson (Get-CodexEventJson -Command $detectedCommand)
        $script:stage = 'add/CODEX_PROFILE_REMAINS_THE_DEFAULT'
        Add-Result 'CODEX_PROFILE_REMAINS_THE_DEFAULT' (
            [string](Get-DetailField -Run $codexDefault -Name 'hook_input_profile') -ceq 'CODEX_PRETOOLUSE' -and
            [string](Get-DetailField -Run $codexDefault -Name 'evaluation_origin') -ceq 'CODEX_PRETOOLUSE_HOOK' -and
            [string](Get-DetailField -Run $codexDefault -Name 'assessment_status') -ceq 'DETECTED' -and
            [bool](Get-DetailField -Run $codexDefault -Name 'interpreter_verified')) `
            -Observed (Get-ObservedDiagnostic -Run $codexDefault)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_CODEX_CONTRACT' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 3. A Claude event missing an identity field is still out of range.
    try {
        $script:stage = 'assert/claude-missing-tool-use-id'
        $missing = Invoke-Hook -CaseName 'claude-missing-tool-use-id' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date' -OmitToolUseId)
        $script:stage = 'add/CLAUDE_PROFILE_REQUIRES_TOOL_USE_ID'
        Add-Result 'CLAUDE_PROFILE_REQUIRES_TOOL_USE_ID' (
            [string](Get-DetailField -Run $missing -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string]::IsNullOrEmpty([string](Get-RunField -Run $missing -Name 'store_text'))) `
            -Observed (Get-ObservedDiagnostic -Run $missing)

        $script:stage = 'assert/claude-blank-session-id'
        $blank = Invoke-Hook -CaseName 'claude-blank-session-id' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date' -SessionId '   ')
        $script:stage = 'add/CLAUDE_PROFILE_REQUIRES_NONBLANK_SESSION_ID'
        Add-Result 'CLAUDE_PROFILE_REQUIRES_NONBLANK_SESSION_ID' (
            [string](Get-DetailField -Run $blank -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT') `
            -Observed (Get-ObservedDiagnostic -Run $blank)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_CLAUDE_IDENTITY' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 4. execution_id: reproducible for the same event, and separated by host so
    #    that two hosts issuing the same identifiers do not collide.
    try {
        $script:stage = 'assert/execution-id'
        $first = Invoke-Hook -CaseName 'exec-id-first' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date')
        $second = Invoke-Hook -CaseName 'exec-id-second' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-ChildItem')
        $otherToolUse = Invoke-Hook -CaseName 'exec-id-other-tool-use' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date' -ToolUseId 'toolu_02XYZ')
        # Same session_id and tool_use_id as the Claude cases above, under the
        # host that also supplies a turn_id.
        $codexSame = Invoke-Hook -CaseName 'exec-id-codex-same-ids' -ProfileName 'CODEX_PRETOOLUSE' `
            -EventJson (Get-CodexEventJson -Command 'Get-Date')

        $firstId = [string](Get-DetailField -Run $first -Name 'execution_id')
        $secondId = [string](Get-DetailField -Run $second -Name 'execution_id')
        $otherId = [string](Get-DetailField -Run $otherToolUse -Name 'execution_id')
        $codexId = [string](Get-DetailField -Run $codexSame -Name 'execution_id')

        $script:stage = 'add/EXECUTION_ID_IS_REPRODUCIBLE'
        # The command text differs between the two runs and the identity fields
        # do not, so an id that depends only on identity must be equal here.
        Add-Result 'EXECUTION_ID_IS_REPRODUCIBLE' (
            $firstId -match '^[0-9a-f]{32}$' -and $firstId -ceq $secondId) -Observed @{
                first_id = $firstId; second_id = $secondId }

        $script:stage = 'add/EXECUTION_ID_SEPARATES_HOSTS'
        Add-Result 'EXECUTION_ID_SEPARATES_HOSTS' (
            $codexId -match '^[0-9a-f]{32}$' -and $firstId -cne $codexId) -Observed @{
                claude_id = $firstId; codex_id = $codexId }

        $script:stage = 'add/EXECUTION_ID_FOLLOWS_TOOL_USE_ID'
        Add-Result 'EXECUTION_ID_FOLLOWS_TOOL_USE_ID' (
            $otherId -match '^[0-9a-f]{32}$' -and $firstId -cne $otherId) -Observed @{
                first_id = $firstId; other_tool_use_id = $otherId }

        # Two distinct tool calls whose fields differ only in where the
        # boundary falls. Joining the fields with a separator would hash the
        # same string for both and give them one execution id, so the pairs
        # below are the regression: each separator the composition could use
        # is placed inside a field.
        foreach ($pair in @(
            @{ name = 'EXECUTION_ID_RESISTS_NEWLINE_BOUNDARY_SHIFT'
               left = @{ session = "a`nb"; toolUse = 'c' }
               right = @{ session = 'a'; toolUse = "b`nc" } },
            @{ name = 'EXECUTION_ID_RESISTS_PIPE_BOUNDARY_SHIFT'
               left = @{ session = 'a|b'; toolUse = 'c' }
               right = @{ session = 'a'; toolUse = 'b|c' } },
            @{ name = 'EXECUTION_ID_RESISTS_LENGTH_PREFIX_FORGERY'
               left = @{ session = '1:x'; toolUse = 'y' }
               right = @{ session = '1'; toolUse = ':xy' } })) {

            $script:stage = 'assert/' + $pair.name
            $leftRun = Invoke-Hook -CaseName ($pair.name + '-L') `
                -EventJson (Get-ClaudeEventJson -Command 'Get-Date' `
                    -SessionId $pair.left.session -ToolUseId $pair.left.toolUse)
            $rightRun = Invoke-Hook -CaseName ($pair.name + '-R') `
                -EventJson (Get-ClaudeEventJson -Command 'Get-Date' `
                    -SessionId $pair.right.session -ToolUseId $pair.right.toolUse)
            $leftId = [string](Get-DetailField -Run $leftRun -Name 'execution_id')
            $rightId = [string](Get-DetailField -Run $rightRun -Name 'execution_id')
            $script:stage = 'add/' + $pair.name
            Add-Result $pair.name (
                $leftId -match '^[0-9a-f]{32}$' -and
                $rightId -match '^[0-9a-f]{32}$' -and
                $leftId -cne $rightId) -Observed @{ left_id = $leftId; right_id = $rightId }
        }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_EXECUTION_ID' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 5. Origin: the Claude profile records its own value, and an origin that
    #    disagrees with the profile is refused rather than resolved.
    try {
        $script:stage = 'assert/origin-default'
        $originRun = Invoke-Hook -CaseName 'origin-default' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date')
        $originStore = [string](Get-RunField -Run $originRun -Name 'store_text')
        $script:stage = 'add/CLAUDE_PROFILE_STORES_ITS_OWN_ORIGIN'
        Add-Result 'CLAUDE_PROFILE_STORES_ITS_OWN_ORIGIN' (
            [string](Get-DetailField -Run $originRun -Name 'evaluation_origin') -ceq 'CLAUDE_PRETOOLUSE_HOOK' -and
            $originStore.Contains('"evaluation_origin":"CLAUDE_PRETOOLUSE_HOOK"') -and
            -not $originStore.Contains('CODEX_PRETOOLUSE_HOOK') -and
            -not $originStore.Contains('MANAGED_EXECUTION')) `
            -Observed (Get-ObservedDiagnostic -Run $originRun)

        foreach ($pair in @(
            @{ case = 'origin-claude-as-codex'; profile = 'CLAUDE_PRETOOLUSE'; origin = 'CODEX_PRETOOLUSE_HOOK'; name = 'CLAUDE_PROFILE_REFUSES_CODEX_ORIGIN' },
            @{ case = 'origin-claude-as-managed'; profile = 'CLAUDE_PRETOOLUSE'; origin = 'MANAGED_EXECUTION'; name = 'CLAUDE_PROFILE_REFUSES_MANAGED_ORIGIN' },
            @{ case = 'origin-codex-as-claude'; profile = 'CODEX_PRETOOLUSE'; origin = 'CLAUDE_PRETOOLUSE_HOOK'; name = 'CODEX_PROFILE_REFUSES_CLAUDE_ORIGIN' })) {

            $script:stage = 'assert/' + $pair.case
            $eventJson = if ($pair.profile -ceq 'CLAUDE_PRETOOLUSE') {
                Get-ClaudeEventJson -Command 'Get-Date'
            }
            else {
                Get-CodexEventJson -Command 'Get-Date'
            }
            $mismatch = Invoke-Hook -CaseName $pair.case -ProfileName $pair.profile -Origin $pair.origin `
                -EventJson $eventJson
            $script:stage = 'add/' + $pair.name
            Add-Result $pair.name (
                [string](Get-DetailField -Run $mismatch -Name 'hook_status') -ceq 'INVALID_HOOK_CONFIGURATION' -and
                [string](Get-DetailField -Run $mismatch -Name 'interpreter_reason_code') -ceq 'EVALUATION_ORIGIN_PROFILE_MISMATCH' -and
                [string](Get-DetailField -Run $mismatch -Name 'assessment_storage_status') -ceq 'NOT_ATTEMPTED' -and
                [string](Get-DetailField -Run $mismatch -Name 'intent_storage_status') -ceq 'NOT_ATTEMPTED' -and
                [string]::IsNullOrEmpty([string](Get-RunField -Run $mismatch -Name 'store_text')) -and
                (Test-MonitorOnlyResponse -Run $mismatch)) `
                -Observed (Get-ObservedDiagnostic -Run $mismatch)
        }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ORIGIN' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 6. The interpreter decision. Claude Code runs its Bash tool through Git
    #    Bash, so a route assertion cannot make that event a PowerShell one, and
    #    the PowerShell tool name on its own establishes nothing either.
    try {
        $script:stage = 'assert/bash-route-rejected'
        $bashTrusted = Invoke-Hook -CaseName 'bash-route-rejected' -TrustedRoute `
            -EventJson (Get-ClaudeEventJson -Command $detectedCommand -ToolName 'Bash')
        $script:stage = 'add/BASH_ROUTE_ASSERTION_IS_REFUSED'
        Add-Result 'BASH_ROUTE_ASSERTION_IS_REFUSED' (
            -not [bool](Get-DetailField -Run $bashTrusted -Name 'interpreter_verified') -and
            [string](Get-DetailField -Run $bashTrusted -Name 'interpreter_kind') -ceq 'OTHER' -and
            [string](Get-DetailField -Run $bashTrusted -Name 'interpreter_reason_code') -ceq 'ROUTE_ASSERTION_REJECTED_FOR_TOOL' -and
            [string](Get-DetailField -Run $bashTrusted -Name 'assessment_status') -ceq 'UNASSESSABLE' -and
            [string](Get-AssessmentField -Run $bashTrusted -Name 'assessment_reason_code') -ceq 'UNSUPPORTED_LANGUAGE') `
            -Observed (Get-ObservedDiagnostic -Run $bashTrusted)

        $script:stage = 'assert/powershell-name-alone'
        $psAlone = Invoke-Hook -CaseName 'powershell-name-alone' `
            -EventJson (Get-ClaudeEventJson -Command $detectedCommand -ToolName 'PowerShell')
        $script:stage = 'add/POWERSHELL_TOOL_NAME_ALONE_IS_NOT_TRUSTED'
        Add-Result 'POWERSHELL_TOOL_NAME_ALONE_IS_NOT_TRUSTED' (
            -not [bool](Get-DetailField -Run $psAlone -Name 'interpreter_verified') -and
            [string](Get-DetailField -Run $psAlone -Name 'interpreter_kind') -ceq 'UNKNOWN' -and
            [string](Get-DetailField -Run $psAlone -Name 'interpreter_reason_code') -ceq 'TARGET_INTERPRETER_UNVERIFIED' -and
            [string](Get-DetailField -Run $psAlone -Name 'assessment_status') -ceq 'UNASSESSABLE' -and
            [string](Get-AssessmentField -Run $psAlone -Name 'assessment_reason_code') -ceq 'UNSUPPORTED_LANGUAGE') `
            -Observed (Get-ObservedDiagnostic -Run $psAlone)

        $script:stage = 'assert/powershell-with-route'
        $psTrusted = Invoke-Hook -CaseName 'powershell-with-route' -TrustedRoute `
            -EventJson (Get-ClaudeEventJson -Command $detectedCommand -ToolName 'PowerShell')
        $script:stage = 'add/POWERSHELL_TOOL_WITH_ROUTE_ASSERTION_IS_ASSESSED'
        Add-Result 'POWERSHELL_TOOL_WITH_ROUTE_ASSERTION_IS_ASSESSED' (
            [bool](Get-DetailField -Run $psTrusted -Name 'interpreter_verified') -and
            [string](Get-DetailField -Run $psTrusted -Name 'interpreter_kind') -ceq 'WINDOWS_POWERSHELL' -and
            [string](Get-DetailField -Run $psTrusted -Name 'interpreter_reason_code') -ceq 'HOOK_REGISTRATION_RESTRICTS_HOST' -and
            [string](Get-DetailField -Run $psTrusted -Name 'assessment_status') -ceq 'DETECTED' -and
            [string](Get-DetailField -Run $psTrusted -Name 'assessment_storage_status') -ceq 'SAVED') `
            -Observed (Get-ObservedDiagnostic -Run $psTrusted)
        $script:stage = 'add/DETECTION_STAYS_MONITOR_ONLY'
        Add-Result 'DETECTION_STAYS_MONITOR_ONLY' (Test-MonitorOnlyResponse -Run $psTrusted)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INTERPRETER' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 7. A tool the profile does not collect is out of range rather than
    #    assessed under some other name.
    try {
        $script:stage = 'assert/unknown-tool'
        $unknownTool = Invoke-Hook -CaseName 'unknown-tool' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date' -ToolName 'Write')
        $script:stage = 'add/UNCOLLECTED_TOOL_IS_OUT_OF_RANGE'
        Add-Result 'UNCOLLECTED_TOOL_IS_OUT_OF_RANGE' (
            [string](Get-DetailField -Run $unknownTool -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string]::IsNullOrEmpty([string](Get-RunField -Run $unknownTool -Name 'store_text'))) `
            -Observed (Get-ObservedDiagnostic -Run $unknownTool)

        $script:stage = 'assert/post-tool-use'
        $postToolUse = Invoke-Hook -CaseName 'post-tool-use' `
            -EventJson (Get-ClaudeEventJson -Command 'Get-Date' -HookEventName 'PostToolUse')
        $script:stage = 'add/POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT'
        Add-Result 'POST_TOOL_USE_IS_NOT_AN_ENTRY_POINT' (
            [string](Get-DetailField -Run $postToolUse -Name 'hook_status') -ceq 'INVALID_HOOK_INPUT' -and
            [string]::IsNullOrEmpty([string](Get-RunField -Run $postToolUse -Name 'store_text'))) `
            -Observed (Get-ObservedDiagnostic -Run $postToolUse)
    }
    catch {
        Add-Result 'CASE_EXCEPTION_TOOL_RANGE' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # 8. Nothing the run leaves behind carries the command text.
    try {
        $script:stage = 'assert/canary'
        $canaryRun = Invoke-Hook -CaseName 'canary' -TrustedRoute `
            -EventJson (Get-ClaudeEventJson -Command ('Get-Content -Path ' + $canary) -ToolName 'PowerShell')
        $script:stage = 'add/NO_ARTEFACT_CONTAINS_COMMAND_TEXT'
        Add-Result 'NO_ARTEFACT_CONTAINS_COMMAND_TEXT' (
            Test-NoCommandTextLeaked -Run $canaryRun -Needle $canary) `
            -Observed (Get-ObservedDiagnostic -Run $canaryRun)
        $script:stage = 'add/CANARY_RUN_DECLARES_NO_CONTENT'
        Add-Result 'CANARY_RUN_DECLARES_NO_CONTENT' (
            -not [bool](Get-DetailField -Run $canaryRun -Name 'content_included') -and
            -not [bool](Get-DetailField -Run $canaryRun -Name 'body_store_reached'))
    }
    catch {
        Add-Result 'CASE_EXCEPTION_CANARY' $false -Observed @{
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
    $summary = [pscustomobject][ordered]@{
        # A leftover temporary root or a child that outlived its run is a
        # failed run, not a footnote under a successful one.
        success = ($failed.Count -eq 0 -and $null -eq $failure -and
            $workRootRemoved -and $script:timedOutCount -eq 0 -and $script:unreapedCount -eq 0 -and
            $script:unverifiedCount -eq 0)
        powershell_version = $PSVersionTable.PSVersion.ToString()
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
        test_root_cleaned = $workRootRemoved
        structured_output_only = $true
    }
    $summary | ConvertTo-Json -Depth 8

    if ($summary.success) { exit 0 } else { exit 1 }
}


