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
# The hook starts no processes of its own, so a child that had to be
# terminated after its launcher exited is an unexpected leftover, not
# routine cleanup.
$script:orphanCount = 0
$script:assessmentStoreSetupStatus = $null
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
    if (-not $Pass -and $script:stage -like '*/store-setup' -and
        $null -ne $script:assessmentStoreSetupStatus) {
        $row['assessment_store_setup_status'] = $script:assessmentStoreSetupStatus
    }
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
            return [pscustomobject]@{ action = 'unreliable'; reason = 'OPEN_FAILED'; handle = $null; started = $null }
        }

        if ($null -eq $handle) {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'OPEN_RETURNED_NOTHING'; handle = $null; started = $null }
        }

        # Force the native handle now. Until this is touched the pid is not
        # pinned, and every check after it would be open to the reuse this
        # whole function exists to exclude.
        try {
            $null = $handle.SafeHandle
        }
        catch {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'HANDLE_NOT_ACQUIRED'; handle = $null; started = $null }
        }

        $started = $null
        try {
            $started = $handle.StartTime
        }
        catch {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'START_TIME_UNREADABLE'; handle = $null; started = $null }
        }

        $current = $null
        try {
            $current = & $ReadCurrent $ChildId
        }
        catch {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'RECHECK_FAILED'; handle = $null; started = $null }
        }

        if ($null -eq $current) {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'RECHECK_EMPTY'; handle = $null; started = $null }
        }
        if ([string]$current.Name -notlike 'powershell*') {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'RECHECK_IDENTITY_CHANGED'; handle = $null; started = $null }
        }
        if ($null -eq $current.CreationDate) {
            return [pscustomobject]@{ action = 'unreliable'; reason = 'RECHECK_TIMESTAMP_MISSING'; handle = $null; started = $null }
        }
        if (([DateTime]$current.CreationDate) -ne $CreatedAtFirstRead) {
            # The pid changed hands between the two reads that bracket the
            # handle. Whatever is there now is not what was listed.
            return [pscustomobject]@{ action = 'unreliable'; reason = 'IDENTITY_CHANGED'; handle = $null; started = $null }
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
    $ok = $true
    try {
        foreach ($entry in @(Get-CimInstance -ClassName Win32_Process `
            -Filter "ParentProcessId=$ParentId" -ErrorAction Stop)) {

            if ([string]$entry.Name -notlike 'powershell*') { continue }
            if ($null -eq $entry.CreationDate) { $ok = $false; continue }

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
            }
        }
        return [pscustomobject]@{ ok = $ok; items = $found.ToArray() }
    }
    catch {
        foreach ($item in $found) {
            try { $item.handle.Dispose() } catch {
                Write-Verbose 'Observed child handle was already released.'
            }
        }
        return [pscustomobject]@{ ok = $false; items = @() }
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
        # Only ordinary hook runs opt into stdin delivery.  The separate
        # switch keeps an intentional empty byte[] distinct from control runs.
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
    # This state crosses the snapshot scriptblock boundary and is consumed by
    # the final descendant verdict. Keep it as an object reference so a
    # collector failure cannot be lost to scriptblock scoping.
    $snapshotState = [pscustomobject]@{ enumeration_ok = $true }
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
        $savedConsoleInputEncoding = $null
        $consoleInputEncodingNeutralized = $false
        if ($SendStandardInput) {
            try {
                $savedConsoleInputEncoding = [Console]::InputEncoding
                if ($savedConsoleInputEncoding.GetPreamble().Length -gt 0) {
                    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
                    $consoleInputEncodingNeutralized = $true
                }
            }
            catch {
                throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception)
            }
        }
        try {
            if (-not $process.Start()) {
                throw [System.InvalidOperationException]::new('test child process did not start')
            }
        }
        finally {
            if ($consoleInputEncodingNeutralized) {
                try { [Console]::InputEncoding = $savedConsoleInputEncoding }
                catch { throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception) }
            }
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
            catch { $snapshotState.enumeration_ok = $false }
            if ($null -ne $snapshot -and -not $snapshot.ok) { $snapshotState.enumeration_ok = $false }
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
                # .NET Framework creates StandardInput's StreamWriter at
                # Start using Console.InputEncoding. A preamble can be sent
                # before BaseStream: UTF-8 BOM made {} arrive as 5 bytes
                # (EF BB BF 7B 7D) in the measured reproduction.
                try { $standardInputPreambleLength = $standardInput.Encoding.GetPreamble().Length }
                catch { throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED', $_.Exception) }
                if ($standardInputPreambleLength -ne 0) {
                    throw [System.InvalidOperationException]::new('STDIN_PREAMBLE_NOT_NEUTRALIZED')
                }
                # Send the exact bytes from stdin.bin. No StreamWriter text
                # API is used after the guard, so neither decoding nor a
                # preamble can change this payload.
                $write = $standardInput.BaseStream.BeginWrite(
                    $StandardInputBytes, 0, $StandardInputBytes.Length, $null, $null)
                $writeWaitHandle = $write.AsyncWaitHandle
                $writeDeadline = [DateTime]::UtcNow.AddMilliseconds($ShutdownTimeoutMilliseconds)
                while (-not $writeWaitHandle.WaitOne(100)) {
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
                # Close the underlying pipe to deliver EOF after the exact
                # bytes above; Close itself does not perform a text write.
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
            try { . $collectSnapshot } catch { $snapshotState.enumeration_ok = $false }
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
        descendants_enumerated = $snapshotState.enumeration_ok
        descendants_terminated = $reap.terminated
        descendants_identity_unconfirmed = $reap.identity_unconfirmed
        descendants_reaped = $reap.gone
        descendants_verified = ($reap.verified -and $snapshotState.enumeration_ok)
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
    $script:assessmentStoreSetupStatus = $null
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1') -Force
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1') -Force
    Import-Module (Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
    $assessmentInit = New-SumiGuardAssessmentStore -StorePath $assessmentStorePath
    $assessmentProperties = if ($null -eq $assessmentInit) { @() } else { @($assessmentInit.PSObject.Properties.Name) }
    $assessmentSucceeded = (($assessmentProperties -contains 'success') -and [bool]$assessmentInit.success)
    if (-not $assessmentSucceeded) {
        if (($assessmentProperties -contains 'status') -and
            $assessmentInit.status -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$assessmentInit.status)) {
            $script:assessmentStoreSetupStatus = [string]$assessmentInit.status
        }
        else {
            $script:assessmentStoreSetupStatus = 'DIAGNOSTIC_UNAVAILABLE'
        }
    }
    $bodyInit = Initialize-SumiGuardLocalStore -Path $bodyStorePath
    $executionInit = Initialize-SumiGuardExecutionStore -Path $executionStorePath
    $bodyProperties = if ($null -eq $bodyInit) { @() } else { @($bodyInit.PSObject.Properties.Name) }
    $executionProperties = if ($null -eq $executionInit) { @() } else { @($executionInit.PSObject.Properties.Name) }
    $bodySucceeded = (($bodyProperties -contains 'success') -and [bool]$bodyInit.success)
    $executionSucceeded = (($executionProperties -contains 'success') -and [bool]$executionInit.success)
    if (-not ($assessmentSucceeded -and $bodySucceeded -and $executionSucceeded)) {
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

    # Preserve an exact per-case fixture, then send the same byte[] through
    # the direct PowerShell process handle.  The validated BaseStream path does
    # not use StreamWriter text methods, pipelines, cmd redirection, decoding,
    # or re-encoding.
    $inputPath = Join-Path $caseRoot 'stdin.bin'
    [System.IO.File]::WriteAllBytes($inputPath, $InputBytes)
    [byte[]]$inputBytesFromFile = [System.IO.File]::ReadAllBytes($inputPath)

    $childCommandLine = (($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + $value + '"' } else { $value }
    }) -join ' ')
    $script:stage = $CaseName + '/child-run'
    $run = Invoke-SumiGuardTestProcess `
        -FileName $powerShell51 `
        -Arguments $childCommandLine `
        -SendStandardInput `
        -StandardInputBytes $inputBytesFromFile
    $script:childStartCount++
    if ($run.timed_out) { $script:timedOutCount++ }
    if (-not $run.descendants_reaped) { $script:unreapedCount++ }
    if (-not ($run.descendants_verified -and $run.output_complete -and
        $run.exit_observed -and $run.kill_completed)) { $script:unverifiedCount++ }
    if ([int]$run.descendants_terminated -gt 0) { $script:orphanCount++ }
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

        # Happy path: the pid is pinned and handed back with its start time.
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

    # The direct transport must remain byte-exact even when the parent console
    # itself has a UTF-8 preamble. The child only reads raw stdin and returns
    # its bytes as Base64; it creates no descendants.
    try {
        $script:stage = 'assert/stdin-bytes-exact-under-utf8-preamble-console'
        [byte[]]$exactInput = @(0x7b, 0x7d)
        $rawReader = '$stream = [Console]::OpenStandardInput(); try { $buffer = New-Object byte[] 16; $bytes = New-Object System.Collections.Generic.List[byte]; while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { for ($index = 0; $index -lt $read; $index++) { $bytes.Add($buffer[$index]) } }; [Convert]::ToBase64String($bytes.ToArray()) } finally { $stream.Dispose() }'
        $rawReaderEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rawReader))
        $originalInputEncoding = [Console]::InputEncoding
        $exactRun = $null
        try {
            [Console]::InputEncoding = [Text.Encoding]::UTF8
            $exactRun = Invoke-SumiGuardTestProcess -FileName $powerShell51 `
                -Arguments ('-NoProfile -NonInteractive -EncodedCommand ' + $rawReaderEncoded) `
                -SendStandardInput -StandardInputBytes $exactInput
        }
        finally {
            [Console]::InputEncoding = $originalInputEncoding
        }
        $script:childStartCount++
        [byte[]]$receivedBytes = [Convert]::FromBase64String([string]$exactRun.stdout_text.Trim())
        $bytesExact = ($receivedBytes.Length -eq $exactInput.Length)
        if ($bytesExact) {
            for ($index = 0; $index -lt $exactInput.Length; $index++) {
                if ($receivedBytes[$index] -ne $exactInput[$index]) { $bytesExact = $false; break }
            }
        }
        $script:stage = 'add/STDIN_BYTES_EXACT_UNDER_UTF8_PREAMBLE_CONSOLE'
        Add-Result 'STDIN_BYTES_EXACT_UNDER_UTF8_PREAMBLE_CONSOLE' (
            $bytesExact -and [bool]$exactRun.exit_observed -and
            [bool]$exactRun.output_complete -and [bool]$exactRun.descendants_reaped -and
            [bool]$exactRun.descendants_verified -and (-not [bool]$exactRun.timed_out) -and
            ([Console]::InputEncoding.CodePage -eq $originalInputEncoding.CodePage)) -Observed @{
                sent_byte_count = $exactInput.Length; received_byte_count = $receivedBytes.Length
                received_first_byte = $(if ($receivedBytes.Length -eq 0) { $null } else { ('{0:x2}' -f $receivedBytes[0]) })
                input_encoding_restored = ([Console]::InputEncoding.CodePage -eq $originalInputEncoding.CodePage)
            }
    }
    catch {
        Add-Result 'CASE_EXCEPTION_STDIN_BYTES_EXACT_UNDER_UTF8_PREAMBLE_CONSOLE' $false -Observed @{
            exception_type = $_.Exception.GetType().FullName
            script_line_number = [int]$_.InvocationInfo.ScriptLineNumber
            stage = [string]$script:stage
        }
    }

    # Keep observing while a fixed input is pending. The root starts a sleeping
    # child without reading stdin, then exits; the pinned child must be reaped
    # even though the input write fails at the broken pipe.
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

    try {
        $script:stage = 'assert/input-send-snapshot-unverified-control'
        $unverifiedRun = Invoke-SumiGuardTestProcess -FileName $powerShell51 `
            -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 300"' `
            -SendStandardInput -StandardInputBytes ([byte[]]@(0x00)) `
            -SnapshotProvider { [pscustomobject]@{ ok = $false; items = @() } }
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
        if ([int]$directProcess.descendants_terminated -gt 0) { $script:orphanCount++ }
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
            $script:unverifiedCount -eq 0 -and $script:orphanCount -eq 0)
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
        child_processes_terminated_after_launcher_exit = $script:orphanCount
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
