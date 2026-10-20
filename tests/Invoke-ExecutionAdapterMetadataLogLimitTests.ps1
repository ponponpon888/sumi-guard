[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$localStoreManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$adapterManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('sumi-guard-metadata-log-limit-tests-' + [Guid]::NewGuid().ToString('N'))
$testRootFullPath = [System.IO.Path]::GetFullPath($testRoot)
$metadataLimit = 16MB
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$adapterModule = $null
$localStoreModule = $null
$activeWriterProcesses = New-Object System.Collections.Generic.List[object]
$childProcessesCleaned = $true

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Evidence
    )

    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        evidence = [pscustomobject]$Evidence
    })
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-DiagnosticText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '<none>' }
    $flattened = ($Value -replace '[\r\n]+', ' ').Trim()
    if ($flattened.Length -gt 300) {
        return $flattened.Substring(0, 300) + '...'
    }
    return $flattened
}

function Get-MetadataPath {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][ValidateSet('Event', 'Failure', 'Retention')][string]$Kind
    )

    switch ($Kind) {
        'Event' { return Join-Path $StorePath 'events.ndjson' }
        'Failure' { return Join-Path $StorePath 'failures.ndjson' }
        'Retention' { return Join-Path $StorePath 'retention.ndjson' }
    }
}

function Get-MetadataLength {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [long]0
    }
    return [long](Get-Item -LiteralPath $Path -Force).Length
}

function Get-MetadataHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-AdapterPrivateWrite {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][ValidateSet('Event', 'Failure', 'Retention')][string]$Kind,
        [Parameter(Mandatory = $true)]$Record
    )

    & $script:adapterModule {
        param($Path, $RecordKind, $Value)
        Write-SumiGuardMetadataRecord -StorePath $Path -Kind $RecordKind -Record $Value
    } $StorePath $Kind $Record
}

function New-ExactMetadataRecord {
    param(
        [Parameter(Mandatory = $true)][long]$TargetBytes,
        [Parameter(Mandatory = $true)][string]$RecordType
    )

    $record = [ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = $RecordType
        multibyte_text = "日本語`nΔ"
        body_ref = $null
        padding = ''
    }
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $line = ($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine
        [long]$length = $script:utf8Strict.GetByteCount($line)
        [long]$delta = $TargetBytes - $length
        if ($delta -eq 0) {
            return [pscustomobject]$record
        }
        if ($delta -gt 0) {
            $record.padding = $record.padding + ('A' * [int]$delta)
        }
        else {
            $remove = [int]([Math]::Min([long]$record.padding.Length, -$delta))
            $record.padding = $record.padding.Substring(0, $record.padding.Length - $remove)
        }
    }
    throw [System.InvalidOperationException]::new(
        ('Could not construct an exact {0}-byte metadata record.' -f $TargetBytes))
}

function New-Store {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = Initialize-SumiGuardExecutionStore -Path $Path
    Assert-Test $result.success ('Execution store initialization failed: {0}' -f $Path)
    Assert-Test $result.acl.valid ('Execution store ACL validation failed: {0}' -f $Path)
}

function New-LocalStore {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = Initialize-SumiGuardLocalStore -Path $Path
    Assert-Test $result.success ('Local store initialization failed: {0}' -f $Path)
}

function New-WriterChildScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$StorePath,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Token
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    Import-Module $Manifest -Force -ErrorAction Stop
    $module = Get-Module 'SumiGuard.ExecutionAdapter' -ErrorAction Stop
    $record = [ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ConcurrentSyntheticRecord'
        token = $Token
        padding = ('B' * 5MB)
    }
    & $module {
        param($Path, $RecordKind, $Value)
        Write-SumiGuardMetadataRecord -StorePath $Path -Kind $RecordKind -Record $Value
    } $StorePath $Kind ([pscustomobject]$record)
    Write-Output 'writer-succeeded'
    exit 0
}
catch [System.IO.IOException] {
    $message = $_.Exception.Message
    if ($message -like 'Metadata log capacity exceeded for *.') {
        [Console]::Error.WriteLine(('capacity-rejected: ' + $message))
        exit 2
    }
    [Console]::Error.WriteLine(('unexpected-io-error: ' + $message))
    exit 1
}
catch {
    [Console]::Error.WriteLine(('unexpected-error: ' + $_.Exception.Message))
    exit 1
}
'@
    [System.IO.File]::WriteAllText(
        $Path,
        $content,
        (New-Object System.Text.UTF8Encoding($false, $true)))
}

function Start-WriterProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Manifest,
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath,
        '-Manifest', $Manifest,
        '-StorePath', $StorePath,
        '-Kind', $Kind,
        '-Token', $Token)
    $argumentText = ($arguments | ForEach-Object {
        ConvertTo-ProcessArgument -Value ([string]$_)
    }) -join ' '
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell51
    $startInfo.Arguments = $argumentText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) {
            throw [System.InvalidOperationException]::new('Could not start the synthetic writer process.')
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        return [pscustomobject][ordered]@{
            token = $Token
            process = $process
            stdout_task = $stdoutTask
            stderr_task = $stderrTask
        }
    }
    catch {
        if ($started) {
            try {
                if (-not $process.HasExited) { $process.Kill() }
                [void]$process.WaitForExit(30000)
            }
            catch {
                $script:childProcessesCleaned = $false
            }
        }
        $process.Dispose()
        throw
    }
}

function Wait-WriterProcess {
    param([int]$TimeoutMilliseconds = 90000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    foreach ($writer in @($script:activeWriterProcesses.ToArray())) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $writer.process.WaitForExit($remaining)) {
            throw [System.TimeoutException]::new('Synthetic writer process timeout.')
        }
        foreach ($task in @($writer.stdout_task, $writer.stderr_task)) {
            $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $task.Wait($remaining)) {
                throw [System.TimeoutException]::new('Synthetic writer output capture timeout.')
            }
        }
        $writer.process.Refresh()
        if ($null -eq $writer.process.ExitCode) {
            throw [System.InvalidOperationException]::new('Synthetic writer exit code was unavailable after termination.')
        }
    }
}

function Stop-WriterProcesses {
    foreach ($writer in @($script:activeWriterProcesses.ToArray())) {
        $process = $writer.process
        try {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        catch {
            $script:childProcessesCleaned = $false
        }
        try { [void]$process.WaitForExit(30000) } catch { $script:childProcessesCleaned = $false }
        try {
            if (-not $process.HasExited) { $script:childProcessesCleaned = $false }
        }
        catch { $script:childProcessesCleaned = $false }
        try { $process.Dispose() } catch { $script:childProcessesCleaned = $false }
    }
    $script:activeWriterProcesses.Clear()
}

try {
    Assert-Test (
        $testRootFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRootFullPath) -like 'sumi-guard-metadata-log-limit-tests-*') `
        'Refusing to use a test path outside the temporary directory.'
    [void](New-Item -ItemType Directory -Path $testRootFullPath -ErrorAction Stop)
    Import-Module $localStoreManifest -Force -ErrorAction Stop
    Import-Module $adapterManifest -Force -ErrorAction Stop
    $localStoreModule = Get-Module 'SumiGuard.LocalStore' -ErrorAction Stop
    $adapterModule = Get-Module 'SumiGuard.ExecutionAdapter' -ErrorAction Stop

    $boundaryStore = Join-Path $testRootFullPath 'boundary-store'
    New-Store -Path $boundaryStore
    foreach ($kind in @('Event', 'Failure', 'Retention')) {
        $path = Get-MetadataPath -StorePath $boundaryStore -Kind $kind
        $exactRecord = New-ExactMetadataRecord -TargetBytes $metadataLimit -RecordType 'ExactBoundaryRecord'
        Invoke-AdapterPrivateWrite -StorePath $boundaryStore -Kind $kind -Record $exactRecord
        Assert-Test ((Get-MetadataLength -Path $path) -eq $metadataLimit) `
            (('{0} did not accept an exact 16 MiB record.' -f $kind))
        $beforeHash = Get-MetadataHash -Path $path
        $rejected = $false
        try {
            Invoke-AdapterPrivateWrite -StorePath $boundaryStore -Kind $kind -Record ([pscustomobject][ordered]@{
                schema_version = 1
                record_id = [Guid]::NewGuid().ToString('N')
                record_type = 'OverflowRecord'
            })
        }
        catch [System.IO.IOException] {
            $rejected = $true
        }
        Assert-Test $rejected ('{0} overflow was not rejected.' -f $kind)
        Assert-Test ((Get-MetadataLength -Path $path) -eq $metadataLimit) `
            ('{0} changed size after rejected append.' -f $kind)
        Assert-Test ((Get-MetadataHash -Path $path) -ceq $beforeHash) `
            ('{0} contents changed after rejected append.' -f $kind)
    }
    Add-TestResult -Name 'metadata_log_boundaries_and_utf8_accounting' -Evidence @{
        max_bytes = $metadataLimit
        exact_boundary_accepted = $true
        overflow_rejected = 'Event,Failure,Retention'
        multibyte_text_and_newline_included = $true
        rejected_files_unchanged = $true
    }

    $concurrentStore = Join-Path $testRootFullPath 'concurrent-store'
    New-Store -Path $concurrentStore
    $writerScript = Join-Path $testRootFullPath 'Invoke-MetadataWriterChild.ps1'
    New-WriterChildScript -Path $writerScript
    try {
        foreach ($token in 1..4) {
            $script:activeWriterProcesses.Add((Start-WriterProcess `
                -ScriptPath $writerScript `
                -Manifest $adapterManifest `
                -StorePath $concurrentStore `
                -Kind Event `
                -Token ([string]$token)))
        }
        Wait-WriterProcess -TimeoutMilliseconds 90000
        $writerResults = @($script:activeWriterProcesses.ToArray() | ForEach-Object {
            $exitCode = $_.process.ExitCode
            if ($null -eq $exitCode) {
                throw [System.InvalidOperationException]::new('Synthetic writer exit code was unavailable.')
            }
            [pscustomobject][ordered]@{
                token = [string]$_.token
                exit_code = [int]$exitCode
                stdout = [string]$_.stdout_task.Result
                stderr = [string]$_.stderr_task.Result
            }
        })
        $exitCodes = @($writerResults | ForEach-Object { $_.exit_code })
        $acceptedCount = @($exitCodes | Where-Object { $_ -eq 0 }).Count
        $rejectedCount = @($exitCodes | Where-Object { $_ -eq 2 }).Count
        Assert-Test ($acceptedCount -eq 3 -and $rejectedCount -eq 1) `
            ('Unexpected concurrent writer result: {0}' -f
                (($writerResults | ForEach-Object {
                    'token={0} exit={1} stderr={2}' -f
                        $_.token,
                        $_.exit_code,
                        (Get-DiagnosticText -Value $_.stderr)
                }) -join ' | '))
        $concurrentPath = Get-MetadataPath -StorePath $concurrentStore -Kind Event
        Assert-Test ((Get-MetadataLength -Path $concurrentPath) -le $metadataLimit) `
            'Concurrent writers exceeded the metadata log limit.'
        Add-TestResult -Name 'concurrent_append_preserves_limit' -Evidence @{
            accepted_writers = $acceptedCount
            rejected_writers = $rejectedCount
            final_bytes = Get-MetadataLength -Path $concurrentPath
            max_bytes = $metadataLimit
        }
    }
    finally {
        Stop-WriterProcesses
    }

    $metadataFailureStore = Join-Path $testRootFullPath 'metadata-failure-store'
    $metadataFailureBodyStore = Join-Path $testRootFullPath 'metadata-failure-body-store'
    New-Store -Path $metadataFailureStore
    New-LocalStore -Path $metadataFailureBodyStore
    $eventPath = Get-MetadataPath -StorePath $metadataFailureStore -Kind Event
    Invoke-AdapterPrivateWrite -StorePath $metadataFailureStore -Kind Event `
        -Record (New-ExactMetadataRecord -TargetBytes $metadataLimit -RecordType 'EventCapacityFixture')
    $metadataFailure = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $metadataFailureStore `
        -LocalStorePath $metadataFailureBodyStore `
        -Body ('日本語' + [Environment]::NewLine + 'metadata-only') `
        -ExecutionId ([Guid]::NewGuid().ToString('N')) `
        -MetadataOnly
    Assert-Test (-not $metadataFailure.success) 'MetadataOnly capacity failure was reported as success.'
    Assert-Test ($metadataFailure.status -ceq 'EVENT_SAVE_FAILED_METADATA_ONLY') `
        'MetadataOnly capacity failure status changed.'
    Assert-Test ($metadataFailure.event_storage_status -ceq 'FAILED' -and
        $metadataFailure.body_storage_status -ceq 'OMITTED_BY_POLICY' -and
        $metadataFailure.collection_status -ceq 'COLLECTION_FAILED' -and
        -not $metadataFailure.automatic_deny) `
        'MetadataOnly capacity failure contract changed.'
    Assert-Test ($metadataFailure.failure_notice_status -ceq 'SAVED') `
        'MetadataOnly capacity failure did not save its finite failure notice.'
    Add-TestResult -Name 'metadata_only_capacity_failure_is_collection_failure' -Evidence @{
        status = $metadataFailure.status
        event_storage_status = $metadataFailure.event_storage_status
        body_storage_status = $metadataFailure.body_storage_status
        collection_status = $metadataFailure.collection_status
        failure_notice_status = $metadataFailure.failure_notice_status
        automatic_deny = $metadataFailure.automatic_deny
        event_bytes_unchanged = ((Get-MetadataLength -Path $eventPath) -eq $metadataLimit)
    }

    $fullFailureStore = Join-Path $testRootFullPath 'full-failure-store'
    $fullFailureBodyStore = Join-Path $testRootFullPath 'full-failure-body-store'
    New-Store -Path $fullFailureStore
    New-LocalStore -Path $fullFailureBodyStore
    Invoke-AdapterPrivateWrite -StorePath $fullFailureStore -Kind Event `
        -Record (New-ExactMetadataRecord -TargetBytes $metadataLimit -RecordType 'EventCapacityFixture')
    Invoke-AdapterPrivateWrite -StorePath $fullFailureStore -Kind Failure `
        -Record (New-ExactMetadataRecord -TargetBytes $metadataLimit -RecordType 'FailureCapacityFixture')
    $fullFailureClock = [Diagnostics.Stopwatch]::StartNew()
    $fullFailure = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $fullFailureStore `
        -LocalStorePath $fullFailureBodyStore `
        -Body ('日本語' + [Environment]::NewLine + 'metadata-only') `
        -ExecutionId ([Guid]::NewGuid().ToString('N')) `
        -MetadataOnly
    $fullFailureClock.Stop()
    Assert-Test (-not $fullFailure.success -and $fullFailure.failure_notice_status -ceq 'FAILED') `
        'Full failure log did not terminate with a failed notice state.'
    Assert-Test ($fullFailureClock.Elapsed.TotalSeconds -lt 30) `
        'Full failure log handling did not terminate promptly.'
    Add-TestResult -Name 'full_failure_log_terminates_without_recursion' -Evidence @{
        success = $fullFailure.success
        status = $fullFailure.status
        failure_notice_status = $fullFailure.failure_notice_status
        elapsed_seconds = [Math]::Round($fullFailureClock.Elapsed.TotalSeconds, 3)
    }

    $retentionStore = Join-Path $testRootFullPath 'retention-store'
    $retentionBodyStore = Join-Path $testRootFullPath 'retention-body-store'
    New-Store -Path $retentionStore
    New-LocalStore -Path $retentionBodyStore
    $retentionExecutionId = [Guid]::NewGuid().ToString('N')
    $bodyId = [Guid]::NewGuid().ToString('N')
    $expiredAt = [DateTimeOffset]::UtcNow.AddDays(-31)
    & $localStoreModule {
        param($Path, $Id, $CreatedAt)
        [byte[]]$cipher = New-Object byte[] 8
        for ($index = 0; $index -lt $cipher.Length; $index++) { $cipher[$index] = 7 }
        $container = New-SumiGuardContainerBytes `
            -CreatedAtUtc $CreatedAt `
            -PlaintextBytes 1 `
            -CipherBytes $cipher
        [System.IO.File]::WriteAllBytes((Join-Path $Path ($Id + '.sgb')), $container)
    } $retentionBodyStore $bodyId $expiredAt
    Invoke-AdapterPrivateWrite -StorePath $retentionStore -Kind Event -Record ([pscustomobject][ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ExecutionIntentRecorded'
        execution_id = $retentionExecutionId
        occurred_at_utc = $expiredAt.ToString('o')
        observed_at_utc = $expiredAt.ToString('o')
        body_sha256 = ('a' * 64)
        hash_scope = 'synthetic'
        content_status = 'CAPTURED_ENCRYPTED'
        collection_status = 'RECORDS_FOUND'
        body_ref = $bodyId
        body_reference_status = 'AVAILABLE'
        failure_reason_code = $null
    })
    Invoke-AdapterPrivateWrite -StorePath $retentionStore -Kind Retention `
        -Record (New-ExactMetadataRecord -TargetBytes $metadataLimit -RecordType 'RetentionCapacityFixture')
    $bodyPath = Join-Path $retentionBodyStore ($bodyId + '.sgb')
    Assert-Test (Test-Path -LiteralPath $bodyPath -PathType Leaf) 'Retention body fixture was not created.'
    $retention = Invoke-SumiGuardExecutionRetentionCleanup `
        -ExecutionStorePath $retentionStore `
        -LocalStorePath $retentionBodyStore `
        -RetentionDays 30 `
        -Confirm:$false
    Assert-Test (-not $retention.success -and $retention.status -ceq 'RETENTION_CLEANUP_PARTIAL') `
        'Retention log capacity failure was reported as success.'
    Assert-Test ($retention.retention_tombstone_failure_count -eq 1) `
        'Retention log capacity failure was not counted.'
    Assert-Test (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) `
        'Retention body was unexpectedly retained after log failure.'
    $afterRetention = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $retentionStore `
        -LocalStorePath $retentionBodyStore `
        -ExecutionId $retentionExecutionId
    Assert-Test ($afterRetention.records[0].body_reference_status -ceq 'REFERENCE_MISSING') `
        'Retention log failure did not expose the body-only deletion limitation.'
    Add-TestResult -Name 'retention_log_failure_is_partial_not_success' -Evidence @{
        cleanup_status = $retention.status
        tombstone_failure_count = $retention.retention_tombstone_failure_count
        body_deleted = $true
        post_cleanup_reference_status = $afterRetention.records[0].body_reference_status
        multi_file_atomicity = $false
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
}
finally {
    try { Stop-WriterProcesses } catch { $script:childProcessesCleaned = $false }
    if (Test-Path -LiteralPath $testRootFullPath) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRootFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-metadata-log-limit-tests-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    results = $results.ToArray()
    failure = $failure
    child_processes_cleaned = $childProcessesCleaned
    test_root_cleaned = -not (Test-Path -LiteralPath $testRootFullPath)
}
$summary | ConvertTo-Json -Depth 10
if ($null -ne $failure) { exit 1 }
