[CmdletBinding()]
param()

# Synthetic tests for SumiGuard.LogIntegrity and tools/Invoke-SumiGuardLogCheckpoint.ps1.
# Every store is a disposable folder under %TEMP%. No DPAPI, no hook, no real
# command. The AssessmentStore case runs only on Windows because that store
# sets a Windows DACL; elsewhere it is reported as not run, never as passed.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$srcRoot = Join-Path $projectRoot 'src'
$integrityManifest = Join-Path (Join-Path $srcRoot 'SumiGuard.LogIntegrity') 'SumiGuard.LogIntegrity.psd1'
$assessmentManifest = Join-Path (Join-Path $srcRoot 'SumiGuard.AssessmentStore') 'SumiGuard.AssessmentStore.psd1'
$commandAssessmentManifest = Join-Path (Join-Path $srcRoot 'SumiGuard.CommandAssessment') 'SumiGuard.CommandAssessment.psd1'
$toolPath = Join-Path (Join-Path $projectRoot 'tools') 'Invoke-SumiGuardLogCheckpoint.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ('sumi-guard-log-integrity-tests-' + [Guid]::NewGuid().ToString('N'))))
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$secretMarker = 'SYNTHETIC_SECRET_LOG_9c41e2'
$executionLock = '.sumi-guard-execution-store.lock'
$results = New-Object System.Collections.Generic.List[object]
$notRun = New-Object System.Collections.Generic.List[object]
$observedOutputs = New-Object System.Collections.Generic.List[string]
$failure = $null
$currentCase = '<none>'

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [InvalidOperationException]::new($Message)
    }
}

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Evidence
    )

    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        evidence = [pscustomobject]$Evidence
    })
}

function Watch-Output {
    param([Parameter(Mandatory = $true)]$Value)

    $observedOutputs.Add(($Value | ConvertTo-Json -Depth 6 -Compress))
    return $Value
}

function Initialize-ExecutionStore {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path $path
    [IO.File]::WriteAllBytes((Join-Path $path $executionLock), (New-Object byte[] 0))
    return $path
}

function Write-LogText {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$FileName = 'events.ndjson'
    )

    [IO.File]::WriteAllBytes((Join-Path $StorePath $FileName), $utf8.GetBytes($Text))
}

function Add-LogText {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$FileName = 'events.ndjson'
    )

    $stream = New-Object IO.FileStream(
        (Join-Path $StorePath $FileName),
        [IO.FileMode]::Append,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read)
    try {
        [byte[]]$bytes = $utf8.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SyntheticLine {
    param([Parameter(Mandatory = $true)][int]$Number)

    return ('{"schema_version":1,"sequence":' + $Number + ',"note":"' + $secretMarker + '"}' + "`n")
}

function Get-Checkpoint {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [string]$Kind = 'Event'
    )

    $result = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath $StorePath -Kind $Kind)
    Assert-Test ($result.success -and $result.status -ceq 'CHECKPOINT_CREATED') (
        'Checkpoint was not created: ' + $result.status)
    return $result
}

function Test-Checkpoint {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][AllowNull()]$Checkpoint
    )

    return Watch-Output (Test-SumiGuardLogCheckpoint -StorePath $StorePath -Checkpoint $Checkpoint)
}

function Get-ExpectedSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-Tool {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $toolPath) + $Arguments
    $output = & $hostExecutable @all 2>&1
    $code = $LASTEXITCODE
    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    $observedOutputs.Add($text)
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    return [pscustomobject]@{
        exit_code = $code
        text = $text
        summary = $parsed
    }
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    Import-Module -Name $integrityManifest -Force -ErrorAction Stop

    $currentCase = 'checkpoint_digest_is_plain_sha256_of_complete_lines'
    $store = Initialize-ExecutionStore -Name 'plain'
    $complete = (Get-SyntheticLine 1) + (Get-SyntheticLine 2)
    Write-LogText -StorePath $store -Text ($complete + '{"unfinished":')
    $created = Get-Checkpoint -StorePath $store
    Assert-Test ($created.checkpoint.covered_bytes -eq $utf8.GetByteCount($complete)) 'Covered bytes did not stop at the last line feed.'
    Assert-Test ($created.checkpoint.covered_lines -eq 2) 'Covered line count is wrong.'
    Assert-Test ($created.checkpoint.sha256 -ceq (Get-ExpectedSha256 $complete)) 'Digest is not the plain SHA-256 of the covered prefix.'
    Assert-Test ($created.incomplete_tail_bytes -eq 14) 'Unfinished last line was not reported.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        covered_lines = $created.checkpoint.covered_lines
        incomplete_tail_bytes = $created.incomplete_tail_bytes
        digest_matches_independent_sha256 = $true
    })

    $currentCase = 'appended_lines_after_checkpoint_are_intact'
    Add-LogText -StorePath $store -Text ('"x"}' + "`n" + (Get-SyntheticLine 3))
    $intact = Test-Checkpoint -StorePath $store -Checkpoint $created.checkpoint
    Assert-Test ($intact.success -and $intact.status -ceq 'INTACT') ('Expected INTACT, got ' + $intact.status)
    Assert-Test ($intact.appended_bytes -gt 0) 'Appended bytes were not reported.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $intact.status
        appended_bytes = $intact.appended_bytes
    })

    $currentCase = 'json_round_trip_checkpoint_verifies'
    $roundTrip = $created.checkpoint | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $roundTripResult = Test-Checkpoint -StorePath $store -Checkpoint $roundTrip
    Assert-Test ($roundTripResult.status -ceq 'INTACT') ('Round-tripped checkpoint did not verify: ' + $roundTripResult.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $roundTripResult.status })

    $currentCase = 'same_length_byte_edit_is_modified'
    $editStore = Initialize-ExecutionStore -Name 'edit'
    $editText = (Get-SyntheticLine 1) + (Get-SyntheticLine 2) + (Get-SyntheticLine 3)
    Write-LogText -StorePath $editStore -Text $editText
    $editCheckpoint = (Get-Checkpoint -StorePath $editStore).checkpoint
    Write-LogText -StorePath $editStore -Text ($editText.Replace('"sequence":2', '"sequence":7'))
    $edited = Test-Checkpoint -StorePath $editStore -Checkpoint $editCheckpoint
    Assert-Test ((-not $edited.success) -and $edited.status -ceq 'MODIFIED') ('Expected MODIFIED, got ' + $edited.status)
    Assert-Test ($edited.verification_completed) 'A finding must be a completed verification.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $edited.status
        success = $edited.success
        verification_completed = $edited.verification_completed
    })

    $currentCase = 'deleted_middle_line_with_padding_is_modified'
    $padText = (Get-SyntheticLine 1) + (Get-SyntheticLine 3) + (Get-SyntheticLine 4) + (Get-SyntheticLine 5)
    Write-LogText -StorePath $editStore -Text $padText
    $deleted = Test-Checkpoint -StorePath $editStore -Checkpoint $editCheckpoint
    Assert-Test ($deleted.status -ceq 'MODIFIED') ('Expected MODIFIED after a deletion hidden by appends, got ' + $deleted.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $deleted.status })

    $currentCase = 'reordered_lines_are_modified'
    Write-LogText -StorePath $editStore -Text ((Get-SyntheticLine 2) + (Get-SyntheticLine 1) + (Get-SyntheticLine 3))
    $reordered = Test-Checkpoint -StorePath $editStore -Checkpoint $editCheckpoint
    Assert-Test ($reordered.status -ceq 'MODIFIED') ('Expected MODIFIED after reordering, got ' + $reordered.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $reordered.status })

    $currentCase = 'shortened_log_is_truncated'
    Write-LogText -StorePath $editStore -Text ((Get-SyntheticLine 1) + (Get-SyntheticLine 2))
    $truncated = Test-Checkpoint -StorePath $editStore -Checkpoint $editCheckpoint
    Assert-Test ((-not $truncated.success) -and $truncated.status -ceq 'TRUNCATED') ('Expected TRUNCATED, got ' + $truncated.status)
    Remove-Item -LiteralPath (Join-Path $editStore 'events.ndjson') -Force
    $missing = Test-Checkpoint -StorePath $editStore -Checkpoint $editCheckpoint
    Assert-Test ($missing.status -ceq 'TRUNCATED' -and $missing.current_bytes -eq 0) ('Expected TRUNCATED for a deleted log, got ' + $missing.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        shortened_status = $truncated.status
        deleted_status = $missing.status
    })

    $currentCase = 'crlf_lines_are_covered'
    $crlfStore = Initialize-ExecutionStore -Name 'crlf'
    $crlfText = '{"a":1}' + "`r`n" + '{"b":2}' + "`r`n"
    Write-LogText -StorePath $crlfStore -Text $crlfText
    $crlf = Get-Checkpoint -StorePath $crlfStore
    Assert-Test ($crlf.checkpoint.covered_lines -eq 2 -and $crlf.incomplete_tail_bytes -eq 0) 'CRLF lines were not counted as complete.'
    Assert-Test ($crlf.checkpoint.sha256 -ceq (Get-ExpectedSha256 $crlfText)) 'CRLF digest mismatch.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ covered_lines = $crlf.checkpoint.covered_lines })

    $currentCase = 'empty_and_missing_logs_checkpoint_as_zero'
    $emptyStore = Initialize-ExecutionStore -Name 'empty'
    $missingLog = Get-Checkpoint -StorePath $emptyStore -Kind 'Failure'
    Assert-Test ((-not $missingLog.log_present) -and $missingLog.checkpoint.covered_bytes -eq 0) 'Missing log was not a zero checkpoint.'
    Assert-Test ($missingLog.checkpoint.sha256 -ceq (Get-ExpectedSha256 '')) 'Zero checkpoint digest is not SHA-256 of nothing.'
    $stillMissing = Test-Checkpoint -StorePath $emptyStore -Checkpoint $missingLog.checkpoint
    Write-LogText -StorePath $emptyStore -Text (Get-SyntheticLine 1) -FileName 'failures.ndjson'
    $afterFirst = Test-Checkpoint -StorePath $emptyStore -Checkpoint $missingLog.checkpoint
    Assert-Test ($stillMissing.status -ceq 'INTACT' -and $afterFirst.status -ceq 'INTACT') 'Zero checkpoint did not stay INTACT as the log grew.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        missing_status = $stillMissing.status
        after_first_line_status = $afterFirst.status
    })

    $currentCase = 'checkpoint_kind_selects_the_log'
    $kindStore = Initialize-ExecutionStore -Name 'kinds'
    Write-LogText -StorePath $kindStore -Text (Get-SyntheticLine 1) -FileName 'retention.ndjson'
    $retention = Get-Checkpoint -StorePath $kindStore -Kind 'Retention'
    Write-LogText -StorePath $kindStore -Text (Get-SyntheticLine 9) -FileName 'events.ndjson'
    $retentionCheck = Test-Checkpoint -StorePath $kindStore -Checkpoint $retention.checkpoint
    Write-LogText -StorePath $kindStore -Text (Get-SyntheticLine 8) -FileName 'retention.ndjson'
    $retentionChanged = Test-Checkpoint -StorePath $kindStore -Checkpoint $retention.checkpoint
    Assert-Test ($retentionCheck.status -ceq 'INTACT' -and $retentionChanged.status -ceq 'MODIFIED') 'Checkpoint did not follow its own log kind.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        other_log_changed = $retentionCheck.status
        own_log_changed = $retentionChanged.status
    })

    $currentCase = 'invalid_checkpoints_are_refused_without_throwing'
    $good = $created.checkpoint
    $variants = [ordered]@{
        null_value = $null
        hashtable = @{ schema = $good.schema }
        wrong_schema = [pscustomobject]@{ schema = 'sumi-guard-log-checkpoint/2'; log_kind = 'Event'; covered_bytes = 1; covered_lines = 1; sha256 = $good.sha256 }
        unknown_kind = [pscustomobject]@{ schema = $good.schema; log_kind = 'event'; covered_bytes = 1; covered_lines = 1; sha256 = $good.sha256 }
        upper_hex = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 1; covered_lines = 1; sha256 = $good.sha256.ToUpperInvariant() }
        negative_bytes = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = -1; covered_lines = 0; sha256 = $good.sha256 }
        lines_exceed_bytes = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 2; covered_lines = 3; sha256 = $good.sha256 }
        bytes_without_lines = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 5; covered_lines = 0; sha256 = $good.sha256 }
        fractional_bytes = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 1.5; covered_lines = 1; sha256 = $good.sha256 }
        string_bytes = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = '1'; covered_lines = 1; sha256 = $good.sha256 }
        extra_property = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 1; covered_lines = 1; sha256 = $good.sha256; store_path = $store }
        missing_digest = [pscustomobject]@{ schema = $good.schema; log_kind = 'Event'; covered_bytes = 1; covered_lines = 1 }
    }
    $refused = 0
    foreach ($key in $variants.Keys) {
        $invalid = Test-Checkpoint -StorePath $store -Checkpoint $variants[$key]
        Assert-Test ((-not $invalid.success) -and $invalid.status -ceq 'CHECKPOINT_INVALID' -and (-not $invalid.verification_completed)) (
            'Invalid checkpoint variant was not refused: ' + $key + ' -> ' + $invalid.status)
        $refused++
    }
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ refused_variants = $refused })

    $currentCase = 'stores_without_the_writer_lock_are_refused'
    $noLock = Join-Path $testRoot 'no-lock'
    $null = New-Item -ItemType Directory -Path $noLock
    Write-LogText -StorePath $noLock -Text (Get-SyntheticLine 1)
    $noLockCreate = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath $noLock -Kind 'Event')
    $noLockVerify = Test-Checkpoint -StorePath $noLock -Checkpoint $created.checkpoint
    $absent = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath (Join-Path $testRoot 'absent') -Kind 'Event')
    $wrongStore = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath $store -Kind 'Assessment')
    Assert-Test ($noLockCreate.status -ceq 'STORE_LOCK_MISSING' -and $noLockVerify.status -ceq 'STORE_LOCK_MISSING') 'Store without lock was accepted.'
    Assert-Test ($absent.status -ceq 'STORE_NOT_FOUND') ('Missing store gave ' + $absent.status)
    Assert-Test ($wrongStore.status -ceq 'STORE_LOCK_MISSING') 'An execution store was accepted as an assessment store.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $noLock $executionLock))) 'A lock file was created by a read-only check.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        no_lock = $noLockCreate.status
        missing_store = $absent.status
        wrong_store_type = $wrongStore.status
        lock_created = $false
    })

    $currentCase = 'directory_in_place_of_log_is_refused'
    $dirStore = Initialize-ExecutionStore -Name 'dir-log'
    $null = New-Item -ItemType Directory -Path (Join-Path $dirStore 'events.ndjson')
    $dirLog = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath $dirStore -Kind 'Event')
    Assert-Test ($dirLog.status -ceq 'LOG_NOT_A_FILE') ('Directory log gave ' + $dirLog.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $dirLog.status })

    $currentCase = 'symbolic_link_log_is_refused'
    $linkStore = Initialize-ExecutionStore -Name 'link'
    $linkTarget = Join-Path $testRoot 'outside.ndjson'
    [IO.File]::WriteAllBytes($linkTarget, $utf8.GetBytes((Get-SyntheticLine 1)))
    $linkCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $linkStore 'events.ndjson') -Target $linkTarget -ErrorAction Stop
        $linkCreated = $true
    }
    catch {
        $linkCreated = $false
    }
    if ($linkCreated) {
        $linked = Watch-Output (Get-SumiGuardLogCheckpoint -StorePath $linkStore -Kind 'Event')
        Assert-Test ($linked.status -ceq 'REPARSE_PATH_NOT_ALLOWED') ('Linked log gave ' + $linked.status)
        Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $linked.status })
    }
    else {
        $notRun.Add([pscustomobject][ordered]@{
            name = $currentCase
            reason = 'This host did not allow creating a symbolic link.'
        })
    }

    $currentCase = 'open_writer_handle_does_not_block_a_check'
    $writerStore = Initialize-ExecutionStore -Name 'writer'
    Write-LogText -StorePath $writerStore -Text (Get-SyntheticLine 1)
    $writer = New-Object IO.FileStream(
        (Join-Path $writerStore 'events.ndjson'),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read)
    try {
        $whileOpen = Get-Checkpoint -StorePath $writerStore
        [void]$writer.Seek(0, [IO.SeekOrigin]::End)
        [byte[]]$more = $utf8.GetBytes((Get-SyntheticLine 2))
        $writer.Write($more, 0, $more.Length)
        $writer.Flush()
        $whileOpenCheck = Test-Checkpoint -StorePath $writerStore -Checkpoint $whileOpen.checkpoint
    }
    finally {
        $writer.Dispose()
    }
    Assert-Test ($whileOpenCheck.status -ceq 'INTACT' -and $whileOpenCheck.appended_bytes -gt 0) 'Check failed beside an open writer handle.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        writer_share = 'Read'
        status = $whileOpenCheck.status
    })

    $currentCase = 'tool_writes_outside_store_and_verifies'
    $toolStore = Initialize-ExecutionStore -Name 'tool-store'
    Write-LogText -StorePath $toolStore -Text ((Get-SyntheticLine 1) + (Get-SyntheticLine 2))
    $checkpointFile = Join-Path $testRoot 'kept-elsewhere.checkpoint.json'
    $toolCreate = Invoke-Tool -Arguments @('-StorePath', $toolStore, '-Kind', 'Event', '-OutFile', $checkpointFile)
    Assert-Test ($toolCreate.exit_code -eq 0 -and $null -ne $toolCreate.summary -and $toolCreate.summary.status -ceq 'CHECKPOINT_WRITTEN') (
        'Tool create failed: ' + $toolCreate.exit_code)
    [byte[]]$written = [IO.File]::ReadAllBytes($checkpointFile)
    Assert-Test (-not ($written.Length -ge 3 -and $written[0] -eq 0xEF -and $written[1] -eq 0xBB -and $written[2] -eq 0xBF)) 'Checkpoint file has a BOM.'
    $toolAgain = Invoke-Tool -Arguments @('-StorePath', $toolStore, '-Kind', 'Event', '-OutFile', $checkpointFile)
    $toolInside = Invoke-Tool -Arguments @('-StorePath', $toolStore, '-Kind', 'Event', '-OutFile', (Join-Path $toolStore 'inside.json'))
    Assert-Test ($toolAgain.exit_code -eq 1 -and $toolAgain.summary.status -ceq 'CHECKPOINT_FILE_EXISTS') 'Tool overwrote an existing checkpoint.'
    Assert-Test ($toolInside.exit_code -eq 1 -and $toolInside.summary.status -ceq 'CHECKPOINT_PATH_INSIDE_STORE') 'Tool wrote a checkpoint inside the store.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $toolStore 'inside.json'))) 'A refused checkpoint file exists.'
    Add-LogText -StorePath $toolStore -Text (Get-SyntheticLine 3)
    $toolIntact = Invoke-Tool -Arguments @('-StorePath', $toolStore, '-CheckpointFile', $checkpointFile)
    Write-LogText -StorePath $toolStore -Text ((Get-SyntheticLine 1) + (Get-SyntheticLine 3) + (Get-SyntheticLine 3))
    $toolModified = Invoke-Tool -Arguments @('-StorePath', $toolStore, '-CheckpointFile', $checkpointFile)
    Assert-Test ($toolIntact.exit_code -eq 0 -and $toolIntact.summary.status -ceq 'INTACT') 'Tool verify did not report INTACT.'
    Assert-Test ($toolModified.exit_code -eq 2 -and $toolModified.summary.status -ceq 'MODIFIED') 'Tool verify did not report MODIFIED with exit 2.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        create_exit = $toolCreate.exit_code
        overwrite_refused = $toolAgain.summary.status
        inside_store_refused = $toolInside.summary.status
        intact_exit = $toolIntact.exit_code
        modified_exit = $toolModified.exit_code
        checkpoint_file_bom = $false
    })

    $currentCase = 'assessment_store_replace_keeps_prefix'
    if ($onWindows) {
        Import-Module -Name $commandAssessmentManifest -Force -ErrorAction Stop
        Import-Module -Name $assessmentManifest -Force -ErrorAction Stop
        $assessmentStore = Join-Path $testRoot 'assessment-store'
        $createStore = New-SumiGuardAssessmentStore -StorePath $assessmentStore
        Assert-Test ($createStore.success) ('Assessment store create failed: ' + $createStore.status)
        $first = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText "Write-Output 'log integrity sample one'" `
            -ExecutionId '00000000000000000000000000004101' `
            -InterpreterKind 'WINDOWS_POWERSHELL' `
            -InterpreterVerified $true
        $second = SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
            -CommandText "Write-Output 'log integrity sample two'" `
            -ExecutionId '00000000000000000000000000004102' `
            -InterpreterKind 'WINDOWS_POWERSHELL' `
            -InterpreterVerified $true
        $saveFirst = Save-SumiGuardAssessment -StorePath $assessmentStore -Assessment $first -EvaluationOrigin 'SYNTHETIC_TEST'
        Assert-Test ($saveFirst.success) ('First save failed: ' + $saveFirst.status)
        $assessmentCheckpoint = (Get-Checkpoint -StorePath $assessmentStore -Kind 'Assessment').checkpoint
        $saveSecond = Save-SumiGuardAssessment -StorePath $assessmentStore -Assessment $second -EvaluationOrigin 'SYNTHETIC_TEST'
        Assert-Test ($saveSecond.success) ('Second save failed: ' + $saveSecond.status)
        $afterReplace = Test-Checkpoint -StorePath $assessmentStore -Checkpoint $assessmentCheckpoint
        Assert-Test ($afterReplace.status -ceq 'INTACT' -and $afterReplace.appended_bytes -gt 0) (
            'Assessment save broke the prefix: ' + $afterReplace.status)
        $recordPath = Join-Path $assessmentStore 'assessments.ndjson'
        [byte[]]$recordBytes = [IO.File]::ReadAllBytes($recordPath)
        $recordText = $utf8.GetString($recordBytes)
        $tampered = $recordText.Replace('00000000000000000000000000004101', '00000000000000000000000000004109')
        Assert-Test ($tampered -cne $recordText) 'Tamper step did not change the record.'
        [IO.File]::WriteAllBytes($recordPath, $utf8.GetBytes($tampered))
        $afterTamper = Test-Checkpoint -StorePath $assessmentStore -Checkpoint $assessmentCheckpoint
        Assert-Test ($afterTamper.status -ceq 'MODIFIED') ('Tampered assessment log gave ' + $afterTamper.status)
        Add-TestResult -Name $currentCase -Evidence ([ordered]@{
            after_second_save = $afterReplace.status
            after_same_length_edit = $afterTamper.status
        })
    }
    else {
        $notRun.Add([pscustomobject][ordered]@{
            name = $currentCase
            reason = 'AssessmentStore sets a Windows DACL; this host is not Windows.'
        })
    }

    $currentCase = 'results_carry_no_content_or_path'
    $leaks = 0
    foreach ($text in $observedOutputs) {
        if ($text.Contains($secretMarker) -or
            $text.IndexOf($testRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.Contains('sumi-guard-log-integrity-tests-') -or
            $text.Contains('.ndjson')) {
            $leaks++
        }
    }
    Assert-Test ($leaks -eq 0) ('Result or tool output exposed content or a path in ' + $leaks + ' outputs.')
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        outputs_checked = $observedOutputs.Count
        leaks = $leaks
    })
}
catch {
    # Assertion messages are this script's own fixed text, so they may reach the
    # CI annotation. Any other exception reports its type only: its message can
    # carry a runner path.
    $ownAssertion = $_.Exception -is [InvalidOperationException] -and
        $_.Exception.GetType() -eq [InvalidOperationException]
    $failure = [pscustomobject][ordered]@{
        failure_stage = $currentCase
        failure_line = $_.InvocationInfo.ScriptLineNumber
        type = $_.Exception.GetType().FullName
        message = if ($ownAssertion) { $_.Exception.Message } else { '<withheld>' }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedForDelete = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-log-integrity-tests-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    results = $results.ToArray()
    not_run = $notRun.ToArray()
    failure = $failure
    failure_stage = if ($null -ne $failure) { $failure.failure_stage } else { $null }
    failure_line = if ($null -ne $failure) { $failure.failure_line } else { $null }
    failure_exception_type = if ($null -ne $failure) { $failure.type } else { $null }
    failed_cases = if ($null -ne $failure) { @($failure.failure_stage + ': ' + $failure.message) } else { @() }
    test_root_cleaned = -not (Test-Path -LiteralPath $testRoot)
}
$summary | ConvertTo-Json -Depth 10
if ($null -ne $failure) { exit 1 }
