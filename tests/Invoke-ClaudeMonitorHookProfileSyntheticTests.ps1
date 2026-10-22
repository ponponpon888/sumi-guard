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
$script:unverifiedCases = New-Object System.Collections.Generic.List[object]
$script:hookExecutionOrdinal = 0
# The hook starts no processes of its own, so a child that had to be
# terminated after its launcher exited is an unexpected leftover, not
# routine cleanup.
$script:orphanCount = 0
$script:assessmentStoreSetupStatus = $null
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
    if (-not $Pass -and $script:stage -like '*/store-setup' -and
        $null -ne $script:assessmentStoreSetupStatus) {
        $row['assessment_store_setup_status'] = $script:assessmentStoreSetupStatus
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
#
# A tree kill only reaches what is still under the launcher. When cmd exits
# first and leaves its PowerShell behind, that child has no tree to be killed
# with, so it is terminated individually instead. Identifying it by pid alone
# would be wrong, because pids are reused. It is identified by a native
# handle acquired the moment it is observed: while that handle is held the
# kernel keeps the pid reserved, so it cannot come to mean a different
# process, and the handle is the thing terminated later. Start times are
# compared exactly, never within a tolerance.

# Decides what to do about one candidate child, with the two operations that
# can fail injected so the decision can be tested without having to provoke a
# pid reuse or an access denial for real.
#
# The order matters. The native handle is acquired before anything else is
# read, so every later check looks at a pid the kernel is holding for us; the
# start time is read through that handle; and only then is the creation
# timestamp read a second time. Bracketing the handle acquisition that way is
# what rules out a pid that moved before it could be pinned.
#
# Three outcomes, kept apart on purpose. 'skip' means the process is not
# running, which is nothing to clean up. 'record' means it is pinned and
# identified. 'unreliable' means the question could not be answered, which is
# never rounded down to either of the others.
function Get-ObservedChildRegistration {
    param(
        [Parameter(Mandatory = $true)][int]$ChildId,
        [Parameter(Mandatory = $true)][DateTime]$CreatedAtFirstRead,
        [Parameter(Mandatory = $true)][scriptblock]$OpenProcess,
        [Parameter(Mandatory = $true)][scriptblock]$ReadCurrent
    )

    $handle = $null
    $keepHandle = $false
    try {
        try {
            $handle = & $OpenProcess $ChildId
        }
        catch [System.ArgumentException] {
            # GetProcessById raises exactly this when no process holds the id.
            # It is the only exception that means "already gone"; treating any
            # other failure the same way would quietly drop a live child.
            return [pscustomobject]@{ action = 'skip'; reason = 'PROCESS_NOT_RUNNING'; handle = $null; started = $null }
        }
        catch {
            # Access denied and everything else: the child may well be running
            # and we simply cannot establish what it is.
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'OPEN_FAILED'; handle = $null; started = $null
                diagnostic = [pscustomobject][ordered]@{
                    reason_code = 'OPEN_FAILED'; stage = 'CHILD_OPEN_PROCESS'
                    exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
                }
            }
        }

        if ($null -eq $handle) {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'OPEN_RETURNED_NOTHING'; handle = $null; started = $null
                diagnostic = [pscustomobject]@{ reason_code = 'OPEN_RETURNED_NOTHING'; stage = 'CHILD_OPEN_PROCESS' }
            }
        }

        # Force the native handle now. Until this is touched the pid is not
        # pinned, and every check after it would be open to the reuse this
        # whole function exists to exclude.
        try {
            $null = $handle.SafeHandle
        }
        catch {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'HANDLE_NOT_ACQUIRED'; handle = $null; started = $null
                diagnostic = [pscustomobject][ordered]@{
                    reason_code = 'HANDLE_NOT_ACQUIRED'; stage = 'CHILD_PIN_HANDLE'
                    exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
                }
            }
        }

        $started = $null
        try {
            $started = $handle.StartTime
        }
        catch {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'START_TIME_UNREADABLE'; handle = $null; started = $null
                diagnostic = [pscustomobject][ordered]@{
                    reason_code = 'START_TIME_UNREADABLE'; stage = 'CHILD_READ_START_TIME'
                    exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
                }
            }
        }

        $current = $null
        try {
            $current = & $ReadCurrent $ChildId
        }
        catch {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'RECHECK_FAILED'; handle = $null; started = $null
                diagnostic = [pscustomobject][ordered]@{
                    reason_code = 'RECHECK_FAILED'; stage = 'CHILD_RECHECK_PROCESS'
                    exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
                }
            }
        }

        if ($null -eq $current) {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'RECHECK_EMPTY'; handle = $null; started = $null
                diagnostic = [pscustomobject]@{ reason_code = 'RECHECK_EMPTY'; stage = 'CHILD_RECHECK_PROCESS' }
            }
        }
        if ([string]$current.Name -notlike 'powershell*') {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'RECHECK_IDENTITY_CHANGED'; handle = $null; started = $null
                diagnostic = [pscustomobject]@{ reason_code = 'RECHECK_IDENTITY_CHANGED'; stage = 'CHILD_RECHECK_PROCESS' }
            }
        }
        if ($null -eq $current.CreationDate) {
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'RECHECK_TIMESTAMP_MISSING'; handle = $null; started = $null
                diagnostic = [pscustomobject]@{ reason_code = 'RECHECK_TIMESTAMP_MISSING'; stage = 'CHILD_RECHECK_PROCESS' }
            }
        }
        if (([DateTime]$current.CreationDate) -ne $CreatedAtFirstRead) {
            # The pid changed hands between the two reads that bracket the
            # handle. Whatever is there now is not what was listed.
            return [pscustomobject]@{
                action = 'unreliable'; reason = 'IDENTITY_CHANGED'; handle = $null; started = $null
                diagnostic = [pscustomobject]@{ reason_code = 'IDENTITY_CHANGED'; stage = 'CHILD_RECHECK_PROCESS' }
            }
        }

        $keepHandle = $true
        return [pscustomobject]@{ action = 'record'; reason = 'PINNED'; handle = $handle; started = $started }
    }
    finally {
        # Anything that is not being handed back is released here, on every
        # path including the failing ones.
        if (-not $keepHandle -and $null -ne $handle) {
            try { $handle.Dispose() } catch {
                Write-Verbose 'Candidate child handle was already released.'
            }
        }
    }
}

# The PowerShell processes directly below the given one, each pinned by a
# native handle before it is recorded. cmd also brings up a console host that
# the OS owns and that can briefly outlive cmd, so only what this test started
# is tracked.
#
# ok=$false means the list cannot be trusted, which is not the same as an
# empty list. A candidate that could not be pinned or identified sets it; a
# candidate that simply is not running any more does not.
function Get-ChildProcessSnapshot {
    param([Parameter(Mandatory = $true)][int]$ParentId)

    $openProcess = { param($id) [System.Diagnostics.Process]::GetProcessById($id) }
    $readCurrent = {
        param($id)
        @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop) |
            Select-Object -First 1
    }

    $found = New-Object System.Collections.Generic.List[object]
    $diagnostics = New-Object System.Collections.Generic.List[object]
    $ok = $true
    try {
        foreach ($entry in @(Get-CimInstance -ClassName Win32_Process `
            -Filter "ParentProcessId=$ParentId" -ErrorAction Stop)) {

            if ([string]$entry.Name -notlike 'powershell*') { continue }
            if ($null -eq $entry.CreationDate) {
                $ok = $false
                $diagnostics.Add([pscustomobject]@{
                    reason_code = 'CHILD_CREATION_TIMESTAMP_MISSING'; stage = 'CHILD_SNAPSHOT_ENTRY'
                })
                continue
            }

            $registration = Get-ObservedChildRegistration `
                -ChildId ([int]$entry.ProcessId) `
                -CreatedAtFirstRead ([DateTime]$entry.CreationDate) `
                -OpenProcess $openProcess `
                -ReadCurrent $readCurrent

            if ($registration.action -ceq 'record') {
                $found.Add([pscustomobject]@{
                    handle = $registration.handle
                    id = [int]$entry.ProcessId
                    started = $registration.started
                })
            }
            elseif ($registration.action -ceq 'unreliable') {
                $ok = $false
                if ($null -ne $registration.diagnostic) { $diagnostics.Add($registration.diagnostic) }
            }
        }
        return [pscustomobject]@{ ok = $ok; items = $found.ToArray(); diagnostics = $diagnostics.ToArray() }
    }
    catch {
        foreach ($item in $found) {
            try { $item.handle.Dispose() } catch {
                Write-Verbose 'Observed child handle was already released.'
            }
        }
        $diagnostics.Add([pscustomobject][ordered]@{
            reason_code = 'CHILD_SNAPSHOT_QUERY_FAILED'; stage = 'CHILD_SNAPSHOT_QUERY'
            exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
        })
        return [pscustomobject]@{ ok = $false; items = @(); diagnostics = $diagnostics.ToArray() }
    }
}

# Brings the observed children to an end and reports what happened, under one
# deadline that covers both the termination and the confirmation.
#
# Identity comes from the held handle, and the start time read through it must
# match exactly what was recorded. No tolerance: a near miss is a mismatch. A
# child whose identity does not confirm is not terminated, and the run is
# reported as unverified rather than clean, because something is running that
# this helper cannot account for.
function Invoke-ObservedProcessReap {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Observed,
        [ValidateRange(1000, 60000)][int]$TimeoutMilliseconds = 15000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $gone = $true
    $verified = $true
    $terminated = 0
    $unconfirmed = 0
    foreach ($item in $Observed) {
        $handle = $item.handle
        $alreadyKilled = $false
        while ($true) {
            $exited = $null
            try { $exited = [bool]$handle.HasExited } catch { $exited = $null }

            if ($null -eq $exited) {
                if ([DateTime]::UtcNow -gt $deadline) { $verified = $false; break }
                Start-Sleep -Milliseconds 50
                continue
            }
            if ($exited) {
                if ($alreadyKilled) { $terminated++ }
                break
            }

            $sameProcess = $false
            $identityKnown = $true
            try { $sameProcess = ($handle.StartTime -eq $item.started) } catch { $identityKnown = $false }

            if (-not $identityKnown) {
                if ([DateTime]::UtcNow -gt $deadline) { $verified = $false; break }
                Start-Sleep -Milliseconds 50
                continue
            }
            if (-not $sameProcess) {
                $unconfirmed++
                $verified = $false
                break
            }

            if (-not $alreadyKilled) {
                try { $handle.Kill() } catch {
                    Write-Verbose 'Observed child had already ended before the kill.'
                }
                $alreadyKilled = $true
            }
            if ([DateTime]::UtcNow -gt $deadline) { $gone = $false; break }
            Start-Sleep -Milliseconds 50
        }
    }

    return [pscustomobject]@{
        gone = $gone
        verified = $verified
        terminated = $terminated
        identity_unconfirmed = $unconfirmed
    }
}

# Confirms that each recorded pid no longer holds a PowerShell, with the
# lookup injected so the failure path can be tested. A lookup that throws is
# reported as unverified: not being able to ask is not an answer, and must
# not read as "the process is gone".
function Test-RecordedChildGone {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ProcessId,
        [Parameter(Mandatory = $true)][scriptblock]$ReadByProcessId,
        [ValidateRange(1000, 60000)][int]$TimeoutMilliseconds = 10000
    )

    $gone = $true
    $verified = $true
    foreach ($id in $ProcessId) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ($true) {
            $still = $null
            $queryFailed = $false
            try { $still = @(& $ReadByProcessId $id) } catch { $queryFailed = $true }

            if ($queryFailed) {
                $verified = $false
                break
            }
            if ($still.Count -eq 0) { break }
            if ([DateTime]::UtcNow -gt $deadline) { $gone = $false; break }
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
#
# The reap runs in finally, so a failure anywhere after the children were
# observed still ends them. Nothing in that block may throw, because a new
# exception there would replace whatever is already on its way out.
function Invoke-SumiGuardTestProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Arguments,
        [ValidateRange(1000, 120000)][int]$TimeoutMilliseconds = 60000,
        [ValidateRange(1000, 60000)][int]$ShutdownTimeoutMilliseconds = 15000,
        # Only the normal hook path opts into this.  Keeping it separate from
        # the byte[] value makes an empty hook event an intentional EOF-only
        # input rather than indistinguishable from the control tests.
        [switch]$SendStandardInput,
        [AllowEmptyCollection()][byte[]]$StandardInputBytes,
        [scriptblock]$SnapshotProvider,
        # Test seam for the finally path: fails the run at the one moment
        # where children exist but nothing has cleaned them up yet.
        [switch]$TestThrowAfterObservation
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = [bool]$SendStandardInput
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $timedOut = $false
    $killCompleted = $true
    $exitObserved = $false
    $outputComplete = $false
    $enumerationOk = $true
    $descendantUnverifiedReasonCodes = New-Object System.Collections.Generic.List[string]
    $childSnapshotDiagnostics = New-Object System.Collections.Generic.List[object]
    $observed = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[int]
    $reap = $null
    $stdout = ''
    $stderr = ''
    $exitCode = $null
    $processStarted = $false
    $collectSnapshot = $null
    $script:LastObservedChildIds = @()
    $script:LastReapResult = $null
    $script:LastReapFailed = $false
    try {
        if (-not $process.Start()) {
            throw [System.InvalidOperationException]::new('test child process did not start')
        }
        $processStarted = $true
        # Both reads start before any wait so a full pipe cannot block the child.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -eq $SnapshotProvider) {
            $SnapshotProvider = { param($parentId) Get-ChildProcessSnapshot -ParentId $parentId }
        }
        $collectSnapshot = {
            $snapshot = $null
            try { $snapshot = & $SnapshotProvider $process.Id }
            catch {
                $enumerationOk = $false
                $childSnapshotDiagnostics.Add([pscustomobject][ordered]@{
                    reason_code = 'CHILD_SNAPSHOT_QUERY_FAILED'; stage = 'CHILD_SNAPSHOT_QUERY'
                    exception_type = $_.Exception.GetType().FullName; hresult = [int]$_.Exception.HResult
                })
                if (-not $descendantUnverifiedReasonCodes.Contains('CHILD_SNAPSHOT_UNVERIFIED')) {
                    $descendantUnverifiedReasonCodes.Add('CHILD_SNAPSHOT_UNVERIFIED')
                }
            }
            if ($null -ne $snapshot -and -not $snapshot.ok) {
                $enumerationOk = $false
                foreach ($diagnostic in @($snapshot.diagnostics)) { $childSnapshotDiagnostics.Add($diagnostic) }
                if (-not $descendantUnverifiedReasonCodes.Contains('CHILD_SNAPSHOT_UNVERIFIED')) {
                    $descendantUnverifiedReasonCodes.Add('CHILD_SNAPSHOT_UNVERIFIED')
                }
            }
            if ($null -ne $snapshot) {
                foreach ($item in @($snapshot.items)) {
                    if ($seenIds.Add([int]$item.id)) { $observed.Add($item) } else { $item.handle.Dispose() }
                }
            }
        }
        . $collectSnapshot

        if ($SendStandardInput) {
            $standardInput = $null
            $writeWaitHandle = $null
            try {
                $standardInput = $process.StandardInput
                # Do not use StreamWriter text methods here.  stdin.bin was
                # read as bytes, and the exact same bytes go to the child.
                $write = $standardInput.BaseStream.BeginWrite(
                    $StandardInputBytes, 0, $StandardInputBytes.Length, $null, $null)
                $writeWaitHandle = $write.AsyncWaitHandle
                $writeDeadline = [DateTime]::UtcNow.AddMilliseconds($ShutdownTimeoutMilliseconds)
                while (-not $writeWaitHandle.WaitOne(100)) {
                    # The input pipe can be full while the child creates its
                    # own PowerShell child. Keep pinning during that interval.
                    . $collectSnapshot
                    if ([DateTime]::UtcNow -ge $writeDeadline) {
                        throw [System.TimeoutException]::new('standard input write timed out')
                    }
                }
                $standardInput.BaseStream.EndWrite($write)
                $standardInput.BaseStream.Flush()
            }
            finally {
                if ($null -ne $writeWaitHandle) {
                    try { $writeWaitHandle.Dispose() } catch {
                        Write-Verbose 'Standard input write wait handle was already released.'
                    }
                }
                # Closing the writer closes its underlying pipe and delivers
                # EOF; it does not write text or an encoding preamble.
                if ($null -ne $standardInput) {
                    try { $standardInput.Close() } catch {
                        Write-Verbose 'Standard input pipe was already closed.'
                    }
                    try { $standardInput.Dispose() } catch {
                        Write-Verbose 'Standard input writer was already released.'
                    }
                }
            }
        }

        # Children can only be enumerated while their parent is alive, so the
        # looks happen early and more than once. A launcher that exits first
        # still gets its children pinned here, which is what makes reaping
        # them afterwards possible at all.
        foreach ($waitMs in @(250, 750)) {
            if ($process.WaitForExit($waitMs)) { break }
            . $collectSnapshot
        }
        $script:LastObservedChildIds = @($observed | ForEach-Object { [int]$_.id })

        if ($TestThrowAfterObservation) {
            throw [System.InvalidOperationException]::new('synthetic failure after observation')
        }

        if ($process.WaitForExit($TimeoutMilliseconds)) {
            $exitObserved = $true
        }
        else {
            $timedOut = $true
            . $collectSnapshot
            $script:LastObservedChildIds = @($observed | ForEach-Object { [int]$_.id })
            $killCompleted = Invoke-ProcessTreeTermination -ProcessId $process.Id `
                -TimeoutMilliseconds $ShutdownTimeoutMilliseconds
            $exitObserved = $process.WaitForExit($ShutdownTimeoutMilliseconds)
        }

        # Anything the launcher left behind is ended before the output is
        # read. A surviving child inherits the pipe, so reading first would
        # block until that child happened to exit on its own, which is the
        # very wait this helper exists to bound.
        $reap = Invoke-ObservedProcessReap -Observed $observed.ToArray() `
            -TimeoutMilliseconds $ShutdownTimeoutMilliseconds
        $script:LastReapResult = $reap
        if (-not $reap.verified -and
            -not $descendantUnverifiedReasonCodes.Contains('CHILD_REAP_UNVERIFIED')) {
            $descendantUnverifiedReasonCodes.Add('CHILD_REAP_UNVERIFIED')
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
        if ($processStarted -and $null -ne $collectSnapshot) {
            try { . $collectSnapshot } catch { $enumerationOk = $false }
        }
        $script:LastObservedChildIds = @($observed | ForEach-Object { [int]$_.id })
        # The reap is guaranteed here, including on the paths that threw, and
        # runs before the tree kill so the children this run pinned are ended
        # by their own identity rather than incidentally.
        if ($null -eq $reap) {
            try {
                $reap = Invoke-ObservedProcessReap -Observed $observed.ToArray() `
                    -TimeoutMilliseconds $ShutdownTimeoutMilliseconds
                $script:LastReapResult = $reap
                if (-not ($reap.gone -and $reap.verified)) { $script:LastReapFailed = $true }
            }
            catch {
                $script:LastReapFailed = $true
            }
        }

        try {
            if (-not $process.HasExited) { $null = Invoke-ProcessTreeTermination -ProcessId $process.Id }
        }
        catch {
            Write-Verbose 'Final tree cleanup could not run.'
        }

        foreach ($item in $observed) {
            try { $item.handle.Dispose() } catch {
                Write-Verbose 'Observed child handle was already released.'
            }
        }

        # Releasing the launcher must not become the reason this call fails.
        try { $process.Dispose() } catch {
            Write-Verbose 'Launcher process object was already released.'
        }
    }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        timed_out = $timedOut
        exit_observed = $exitObserved
        output_complete = $outputComplete
        kill_completed = $killCompleted
        observed_descendants = $observed.Count
        descendants_enumerated = $enumerationOk
        descendants_terminated = $reap.terminated
        descendants_identity_unconfirmed = $reap.identity_unconfirmed
        descendants_reaped = $reap.gone
        descendants_verified = ($reap.verified -and $enumerationOk)
        descendants_unverified_reason_codes = $descendantUnverifiedReasonCodes.ToArray()
        child_snapshot_diagnostics = $childSnapshotDiagnostics.ToArray()
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
    $script:assessmentStoreSetupStatus = $null
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    $created = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    $createdProperties = if ($null -eq $created) { @() } else { @($created.PSObject.Properties.Name) }
    $createdSucceeded = (($createdProperties -contains 'success') -and [bool]$created.success)
    if (-not $createdSucceeded) {
        if (($createdProperties -contains 'status') -and
            $created.status -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$created.status)) {
            $script:assessmentStoreSetupStatus = [string]$created.status
        }
        else {
            $script:assessmentStoreSetupStatus = 'DIAGNOSTIC_UNAVAILABLE'
        }
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

    # Keep a byte-for-byte input fixture for the case, then read that fixture
    # back as bytes.  It is sent through the direct PowerShell process handle,
    # never through a text writer, a pipeline, or cmd redirection.
    $inputPath = Join-Path $caseRoot 'stdin.bin'
    [System.IO.File]::WriteAllBytes($inputPath, (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($EventJson))
    [byte[]]$inputBytes = [System.IO.File]::ReadAllBytes($inputPath)

    $childCommandLine = (($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value + '"' } else { $value }
    }) -join ' ')
    $script:stage = $CaseName + '/child-run'
    $script:hookExecutionOrdinal++
    $hookExecutionOrdinal = $script:hookExecutionOrdinal
    $run = Invoke-SumiGuardTestProcess `
        -FileName $powerShell51 `
        -Arguments $childCommandLine `
        -SendStandardInput `
        -StandardInputBytes $inputBytes
    $script:childStartCount++
    if ($run.timed_out) { $script:timedOutCount++ }
    if (-not $run.descendants_reaped) { $script:unreapedCount++ }
    if (-not ($run.descendants_verified -and $run.output_complete -and
        $run.exit_observed -and $run.kill_completed)) {
        $reasonCodes = New-Object System.Collections.Generic.List[string]
        if (-not $run.descendants_verified) {
            $descendantReasons = @($run.descendants_unverified_reason_codes)
            if ($descendantReasons.Count -eq 0) {
                # Do not infer a lower-level cause when the helper has none.
                $reasonCodes.Add('DESCENDANT_STATE_UNVERIFIED')
            }
            else {
                foreach ($reasonCode in $descendantReasons) { $reasonCodes.Add([string]$reasonCode) }
            }
        }
        if (-not $run.output_complete) { $reasonCodes.Add('OUTPUT_DRAIN_UNVERIFIED') }
        if (-not $run.exit_observed) { $reasonCodes.Add('LAUNCHER_EXIT_UNVERIFIED') }
        if (-not $run.kill_completed) { $reasonCodes.Add('TREE_TERMINATION_UNVERIFIED') }
        $script:unverifiedCases.Add([pscustomobject][ordered]@{
            case_id = $CaseName
            execution_ordinal = $hookExecutionOrdinal
            reason_codes = $reasonCodes.ToArray()
            child_snapshot_diagnostics = @($run.child_snapshot_diagnostics)
        })
        $script:unverifiedCount++
    }
    if ([int]$run.descendants_terminated -gt 0) { $script:orphanCount++ }
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

    # Control: the launcher exits first and leaves its PowerShell behind.
    # This is the path a tree kill cannot close, because by the time anyone
    # looks there is no tree left to walk: the child has to be ended by its
    # own identity or not at all. cmd lingers just long enough to be
    # enumerated, then exits while the child keeps sleeping.
    #
    # The helper is called directly rather than through Invoke-Hook, so this
    # deliberate leftover is not counted against the run.
    try {
        $script:stage = 'assert/orphaned-child-control'
        $orphanRoot = Join-Path $workRoot 'orphan-control'
        $null = New-Item -ItemType Directory -Path $orphanRoot -Force
        $orphanScript = Join-Path $orphanRoot 'orphan.cmd'
        Set-Content -LiteralPath $orphanScript -Encoding Ascii -Value @(
            '@echo off',
            ('start "" /b "' + $powerShell51 + '" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"'),
            'ping -n 3 127.0.0.1 >nul',
            'exit /b 0')
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $orphanRun = Invoke-SumiGuardTestProcess `
            -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -Arguments ('/s /c "' + $orphanScript + '"') `
            -TimeoutMilliseconds 30000
        $watch.Stop()
        $script:childStartCount++
        $script:stage = 'add/ORPHANED_CHILD_IS_REAPED_AFTER_LAUNCHER_EXITS'
        Add-Result 'ORPHANED_CHILD_IS_REAPED_AFTER_LAUNCHER_EXITS' (
            # The launcher ended on its own: this is not the timeout path.
            -not [bool]$orphanRun.timed_out -and
            [bool]$orphanRun.exit_observed -and
            [int]$orphanRun.observed_descendants -ge 1 -and
            # The child outlived cmd and had to be ended by identity.
            [int]$orphanRun.descendants_terminated -ge 1 -and
            [bool]$orphanRun.descendants_enumerated -and
            [bool]$orphanRun.descendants_verified -and
            [bool]$orphanRun.descendants_reaped -and
            [bool]$orphanRun.output_complete -and
            # Far below the 120s the child asked for.
            $watch.Elapsed.TotalSeconds -lt 60) -Observed @{
                elapsed_seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
                timed_out = [bool]$orphanRun.timed_out
                exit_observed = [bool]$orphanRun.exit_observed
                observed_descendants = [int]$orphanRun.observed_descendants
                descendants_terminated = [int]$orphanRun.descendants_terminated
                descendants_enumerated = [bool]$orphanRun.descendants_enumerated
                descendants_verified = [bool]$orphanRun.descendants_verified
                descendants_reaped = [bool]$orphanRun.descendants_reaped
                output_complete = [bool]$orphanRun.output_complete
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_ORPHANED_CHILD_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Controls for the registration decision. The two failures that matter
    # here cannot be provoked for real on demand, so the two operations that
    # can fail are injected. The process under test is this one, which makes
    # the happy path a real pin of a real process rather than a mock.
    try {
        $script:stage = 'assert/registration-controls'
        $selfRow = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop)[0]
        $selfCreated = [DateTime]$selfRow.CreationDate
        $openSelf = { param($id) [System.Diagnostics.Process]::GetProcessById($id) }
        $readSelf = { param($id) @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop)[0] }

        # CIM initial and recheck values establish this process identity. The
        # retained native handle's start time is checked only against itself.
        $pinned = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated `
            -OpenProcess $openSelf -ReadCurrent $readSelf
        $pinnedOk = ($pinned.action -ceq 'record') -and ($null -ne $pinned.handle)
        if ($pinnedOk) {
            # The handle must already be acquired, not acquired lazily later.
            $pinnedOk = ($null -ne $pinned.handle.SafeHandle) -and
                (-not $pinned.handle.SafeHandle.IsInvalid) -and
                ($pinned.started -eq $pinned.handle.StartTime)
            $pinned.handle.Dispose()
        }
        $script:stage = 'add/LIVE_CHILD_IS_PINNED_WITH_AN_ACQUIRED_HANDLE'
        Add-Result 'LIVE_CHILD_IS_PINNED_WITH_AN_ACQUIRED_HANDLE' $pinnedOk -Observed @{
            action = [string]$pinned.action; reason = [string]$pinned.reason }

        # The pid changed hands between the two reads that bracket the handle.
        # It must not be recorded as ours.
        $shifted = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated.AddMilliseconds(-1) `
            -OpenProcess $openSelf -ReadCurrent $readSelf
        $script:stage = 'add/IDENTITY_CHANGE_IS_NOT_RECORDED'
        Add-Result 'IDENTITY_CHANGE_IS_NOT_RECORDED' (
            ($shifted.action -ceq 'unreliable') -and
            ($shifted.reason -ceq 'IDENTITY_CHANGED') -and
            ($null -eq $shifted.handle)) -Observed @{
                action = [string]$shifted.action; reason = [string]$shifted.reason }

        # No process holds the id. Nothing to clean up, and not an error.
        $absent = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated `
            -OpenProcess { param($id) throw [System.ArgumentException]::new("no process $id") } `
            -ReadCurrent $readSelf
        $script:stage = 'add/ABSENT_PROCESS_IS_SKIPPED_NOT_FAILED'
        Add-Result 'ABSENT_PROCESS_IS_SKIPPED_NOT_FAILED' (
            ($absent.action -ceq 'skip') -and ($absent.reason -ceq 'PROCESS_NOT_RUNNING')) -Observed @{
                action = [string]$absent.action; reason = [string]$absent.reason }

        # Access denied is not "already gone". The child may be running and
        # we cannot say what it is, so the snapshot has to be unreliable.
        $denied = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated `
            -OpenProcess { param($id) throw [System.UnauthorizedAccessException]::new("denied for $id") } `
            -ReadCurrent $readSelf
        $script:stage = 'add/OPEN_DENIED_IS_NOT_TREATED_AS_EXITED'
        Add-Result 'OPEN_DENIED_IS_NOT_TREATED_AS_EXITED' (
            ($denied.action -ceq 'unreliable') -and ($denied.reason -ceq 'OPEN_FAILED')) -Observed @{
                action = [string]$denied.action; reason = [string]$denied.reason }

        # The confirming read itself failing is also unreliable, never a pin.
        $recheckFailed = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated `
            -OpenProcess $openSelf `
            -ReadCurrent { param($id) throw [System.InvalidOperationException]::new("cim unavailable for $id") }
        $script:stage = 'add/RECHECK_FAILURE_IS_NOT_A_PIN'
        Add-Result 'RECHECK_FAILURE_IS_NOT_A_PIN' (
            ($recheckFailed.action -ceq 'unreliable') -and
            ($recheckFailed.reason -ceq 'RECHECK_FAILED') -and
            ($null -eq $recheckFailed.handle)) -Observed @{
                action = [string]$recheckFailed.action; reason = [string]$recheckFailed.reason }

        # No native timestamp can bridge the CIM observation gap without a
        # tolerance. An empty CIM recheck is therefore never a clean exit.
        $emptyRecheck = Get-ObservedChildRegistration -ChildId $PID -CreatedAtFirstRead $selfCreated `
            -OpenProcess $openSelf `
            -ReadCurrent { param($id) $null }
        $script:stage = 'add/RECHECK_EMPTY_REMAINS_UNRELIABLE'
        Add-Result 'RECHECK_EMPTY_REMAINS_UNRELIABLE' (
            ($emptyRecheck.action -ceq 'unreliable') -and
            ($emptyRecheck.reason -ceq 'RECHECK_EMPTY') -and
            ($null -eq $emptyRecheck.handle)) -Observed @{
                action = [string]$emptyRecheck.action; reason = [string]$emptyRecheck.reason }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_REGISTRATION_CONTROLS' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Control: a lookup that cannot run is not evidence of anything. The
    # confirmation used by the reap control below must report that it could
    # not verify, rather than concluding the process is gone.
    try {
        $script:stage = 'assert/verification-failure-control'
        $cannotAsk = Test-RecordedChildGone -ProcessId @($PID) `
            -ReadByProcessId { param($id) throw [System.InvalidOperationException]::new("cim unavailable for $id") } `
            -TimeoutMilliseconds 2000
        $canAsk = Test-RecordedChildGone -ProcessId @($PID) `
            -ReadByProcessId { param($id) @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop) } `
            -TimeoutMilliseconds 2000
        $script:stage = 'add/UNAVAILABLE_LOOKUP_IS_NOT_PROOF_OF_TERMINATION'
        Add-Result 'UNAVAILABLE_LOOKUP_IS_NOT_PROOF_OF_TERMINATION' (
            (-not [bool]$cannotAsk.verified) -and
            # A lookup that does work still finds this process running, so
            # "gone" is not something the control hands out for free either.
            [bool]$canAsk.verified -and (-not [bool]$canAsk.gone)) -Observed @{
                unavailable_verified = [bool]$cannotAsk.verified
                available_verified = [bool]$canAsk.verified
                available_gone = [bool]$canAsk.gone
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_VERIFICATION_FAILURE_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Control: identity is exact. A start time that is merely close is a
    # different process, and a near miss is the case a tolerance would wave
    # through, so it is the one worth testing. This test's own process stands
    # in for the candidate, recorded half a second off its real start time.
    # If the comparison allowed any slack, this case would terminate the test
    # itself.
    try {
        $script:stage = 'assert/near-miss-identity-control'
        $selfHandle = [System.Diagnostics.Process]::GetProcessById($PID)
        try {
            $nearMiss = [pscustomobject]@{
                handle = $selfHandle
                id = $PID
                started = $selfHandle.StartTime.AddMilliseconds(500)
            }
            $nearMissReap = Invoke-ObservedProcessReap -Observed @($nearMiss) -TimeoutMilliseconds 3000
        }
        finally {
            $selfHandle.Dispose()
        }
        $selfAlive = $false
        try {
            $null = [System.Diagnostics.Process]::GetProcessById($PID)
            $selfAlive = $true
        }
        catch {
            $selfAlive = $false
        }
        $script:stage = 'add/NEAR_MISS_START_TIME_IS_NOT_TERMINATED'
        Add-Result 'NEAR_MISS_START_TIME_IS_NOT_TERMINATED' (
            $selfAlive -and
            [int]$nearMissReap.identity_unconfirmed -eq 1 -and
            [int]$nearMissReap.terminated -eq 0 -and
            (-not [bool]$nearMissReap.verified)) -Observed @{
                self_alive = $selfAlive
                identity_unconfirmed = [int]$nearMissReap.identity_unconfirmed
                terminated = [int]$nearMissReap.terminated
                verified = [bool]$nearMissReap.verified
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_NEAR_MISS_IDENTITY_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Control: the run fails after the children are observed but before
    # anything has cleaned them up. The reap has to happen anyway, the
    # original exception has to survive it, and the reap's own outcome has to
    # be recorded. The reap runs ahead of the tree kill in that path, so a
    # terminated count here is the identity-based reap doing the work and not
    # taskkill doing it incidentally.
    try {
        $script:stage = 'assert/throw-after-observation-control'
        $throwRoot = Join-Path $workRoot 'throw-control'
        $null = New-Item -ItemType Directory -Path $throwRoot -Force
        $throwScript = Join-Path $throwRoot 'sleeper.cmd'
        Set-Content -LiteralPath $throwScript -Encoding Ascii -Value @(
            '@echo off',
            ('"' + $powerShell51 + '" -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"'),
            'exit /b 0')

        $script:LastObservedChildIds = @()
        $script:LastReapResult = $null
        $script:LastReapFailed = $false
        $caughtType = ''
        $caughtMessage = ''
        try {
            $null = Invoke-SumiGuardTestProcess `
                -FileName (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -Arguments ('/s /c "' + $throwScript + '"') `
                -TimeoutMilliseconds 30000 `
                -TestThrowAfterObservation
        }
        catch {
            $caughtType = [string]$_.Exception.GetType().FullName
            $caughtMessage = [string]$_.Exception.Message
        }
        $script:childStartCount++

        $recordedIds = @($script:LastObservedChildIds)
        $reapResult = $script:LastReapResult
        # Checked by name as well, so a pid handed to something else
        # afterwards is not read as a survivor. A lookup that cannot run
        # leaves this unverified, and an unverified check fails the case.
        $confirmation = Test-RecordedChildGone -ProcessId $recordedIds `
            -ReadByProcessId {
                param($id)
                @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop |
                    Where-Object { [string]$_.Name -like 'powershell*' })
            } `
            -TimeoutMilliseconds 10000

        $script:stage = 'add/OBSERVED_CHILD_IS_REAPED_WHEN_THE_RUN_THROWS'
        Add-Result 'OBSERVED_CHILD_IS_REAPED_WHEN_THE_RUN_THROWS' (
            # The original failure reached the caller unchanged.
            $caughtType -ceq 'System.InvalidOperationException' -and
            $caughtMessage -ceq 'synthetic failure after observation' -and
            $recordedIds.Count -ge 1 -and
            $null -ne $reapResult -and
            [int]$reapResult.terminated -ge 1 -and
            [bool]$reapResult.gone -and
            [bool]$reapResult.verified -and
            (-not [bool]$script:LastReapFailed) -and
            [bool]$confirmation.verified -and
            [bool]$confirmation.gone) -Observed @{
                caught_type = $caughtType
                caught_message = $caughtMessage
                recorded_children = $recordedIds.Count
                terminated = $(if ($null -eq $reapResult) { -1 } else { [int]$reapResult.terminated })
                reap_gone = $(if ($null -eq $reapResult) { $false } else { [bool]$reapResult.gone })
                reap_verified = $(if ($null -eq $reapResult) { $false } else { [bool]$reapResult.verified })
                reap_failed = [bool]$script:LastReapFailed
                confirmation_gone = [bool]$confirmation.gone
                confirmation_verified = [bool]$confirmation.verified
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_THROW_AFTER_OBSERVATION_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # A root that never reads its fixed input starts a child and then exits.
    # The pending pipe write must keep collecting descendants; the child seen
    # with a pinned handle must still reach the finally reap when EndWrite
    # observes the broken pipe.
    try {
        $script:stage = 'assert/input-send-early-root-exit-control'
        $escapedPowerShell = $powerShell51.Replace("'", "''")
        $earlyExitText = '$null = Start-Process -FilePath ''' + $escapedPowerShell +
            ''' -ArgumentList ''-NoProfile -NonInteractive -Command ""Start-Sleep -Seconds 120""''; Start-Sleep -Milliseconds 1000'
        $earlyExitEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($earlyExitText))
        [byte[]]$fixedInput = New-Object byte[] 1048576
        $script:LastObservedChildIds = @()
        $script:LastReapResult = $null
        $script:LastReapFailed = $false
        $sendCaught = $false
        try {
            $null = Invoke-SumiGuardTestProcess -FileName $powerShell51 `
                -Arguments ('-NoProfile -NonInteractive -EncodedCommand ' + $earlyExitEncoded) `
                -TimeoutMilliseconds 5000 -ShutdownTimeoutMilliseconds 3000 `
                -SendStandardInput -StandardInputBytes $fixedInput
        }
        catch {
            $sendCaught = $true
        }
        $script:childStartCount++
        $recordedIds = @($script:LastObservedChildIds)
        $reapResult = $script:LastReapResult
        $confirmation = Test-RecordedChildGone -ProcessId $recordedIds -ReadByProcessId {
            param($id)
            @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop |
                Where-Object { [string]$_.Name -like 'powershell*' })
        } -TimeoutMilliseconds 10000
        $script:stage = 'add/PENDING_INPUT_EARLY_ROOT_EXIT_REAPS_PINNED_CHILD'
        Add-Result 'PENDING_INPUT_EARLY_ROOT_EXIT_REAPS_PINNED_CHILD' (
            $sendCaught -and $recordedIds.Count -ge 1 -and $null -ne $reapResult -and
            [int]$reapResult.terminated -ge 1 -and [bool]$reapResult.gone -and
            [bool]$reapResult.verified -and (-not [bool]$script:LastReapFailed) -and
            [bool]$confirmation.verified -and [bool]$confirmation.gone) -Observed @{
                send_failed = $sendCaught; recorded_children = $recordedIds.Count
                reap_verified = $(if ($null -eq $reapResult) { $false } else { [bool]$reapResult.verified })
                confirmation_verified = [bool]$confirmation.verified
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_PENDING_INPUT_EARLY_ROOT_EXIT_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # A snapshot provider that cannot answer is never folded into a clean
    # descendant state, even when the root itself exits normally.
    try {
        $script:stage = 'assert/input-send-snapshot-unverified-control'
        $unverifiedRun = Invoke-SumiGuardTestProcess -FileName $powerShell51 `
            -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 300"' `
            -SendStandardInput -StandardInputBytes ([byte[]]@(0x00)) `
            -SnapshotProvider {
                param($parentId)
                [pscustomobject]@{ ok = $false; items = @(); diagnostics = @(
                    [pscustomobject]@{ reason_code = 'TEST_SNAPSHOT_UNVERIFIED'; stage = 'TEST_SNAPSHOT' }) }
            }
        $script:childStartCount++
        $script:stage = 'add/INPUT_SEND_SNAPSHOT_UNVERIFIED_IS_NOT_CLEAN'
        Add-Result 'INPUT_SEND_SNAPSHOT_UNVERIFIED_IS_NOT_CLEAN' (
            [bool]$unverifiedRun.exit_observed -and [bool]$unverifiedRun.output_complete -and
            (-not [bool]$unverifiedRun.descendants_enumerated) -and
            (-not [bool]$unverifiedRun.descendants_verified) -and
            [bool]$unverifiedRun.descendants_reaped) -Observed @{
                exit_observed = [bool]$unverifiedRun.exit_observed
                descendants_enumerated = [bool]$unverifiedRun.descendants_enumerated
                descendants_verified = [bool]$unverifiedRun.descendants_verified
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_INPUT_SEND_SNAPSHOT_UNVERIFIED_CONTROL' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

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
            $script:unverifiedCount -eq 0 -and $script:orphanCount -eq 0)
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
        child_process_unverified_cases = $script:unverifiedCases.ToArray()
        child_processes_terminated_after_launcher_exit = $script:orphanCount
        command_inputs_executed = $false
        body_store_written = $false
        network_access_performed = $false
        test_root_cleaned = $workRootRemoved
        structured_output_only = $true
    }
    $summary | ConvertTo-Json -Depth 8

    if ($summary.success) { exit 0 } else { exit 1 }
}
