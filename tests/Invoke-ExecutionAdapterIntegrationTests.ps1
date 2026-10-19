[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$localStoreManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$adapterManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'
$assessmentStoreManifest = Join-Path $projectRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('sumi-guard-adapter-tests-' + [Guid]::NewGuid().ToString('N'))
$testRootFullPath = [System.IO.Path]::GetFullPath($testRoot)
$results = New-Object System.Collections.Generic.List[object]
$safeObjects = New-Object System.Collections.Generic.List[object]
$failure = $null

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

function ConvertTo-HookProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    # Paths and switches are fixed test arguments. The event JSON is sent over
    # stdin so command text never enters the child process command line.
    return '"' + $Value + '"'
}

function Get-RealHookEventJson {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command)

    return ([ordered]@{
        hook_event_name = 'PreToolUse'
        tool_name = 'Bash'
        session_id = 'synthetic-real-adapter-session'
        turn_id = 'synthetic-real-adapter-turn'
        tool_use_id = 'synthetic-real-adapter-tool'
        tool_input = [ordered]@{ command = $Command }
    } | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-RealMonitorHook {
    param(
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [Parameter(Mandatory = $true)][string]$AssessmentStorePath,
        [Parameter(Mandatory = $true)][string]$NoticePath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EventJson
    )

    $powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $HookPath,
        '-ExecutionStorePath', $ExecutionStorePath,
        '-LocalStorePath', $LocalStorePath,
        '-AssessmentStorePath', $AssessmentStorePath,
        '-NoticePath', $NoticePath,
        '-ResultPath', $ResultPath,
        '-TrustedWindowsPowerShellRoute')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell51
    $startInfo.Arguments = (($arguments | ForEach-Object {
        ConvertTo-HookProcessArgument -Value ([string]$_)
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw [System.InvalidOperationException]::new('real monitor hook did not start')
        }
        $process.StandardInput.Write($EventJson)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject][ordered]@{
            exit_code = $process.ExitCode
            child_process_exited = $process.HasExited
            stdout_text = $stdout
            stderr_text = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-ByteSequenceInFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )

    [byte[]]$haystack = [System.IO.File]::ReadAllBytes($Path)
    try {
        if ($Needle.Length -eq 0 -or $haystack.Length -lt $Needle.Length) {
            return $false
        }
        for ($offset = 0; $offset -le ($haystack.Length - $Needle.Length); $offset++) {
            $match = $true
            for ($index = 0; $index -lt $Needle.Length; $index++) {
                if ($haystack[$offset + $index] -ne $Needle[$index]) {
                    $match = $false
                    break
                }
            }
            if ($match) { return $true }
        }
        return $false
    }
    finally {
        if ($haystack.Length -gt 0) {
            [Array]::Clear($haystack, 0, $haystack.Length)
        }
    }
}

function Test-PlaintextAbsentFromTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    [byte[]]$needle = $encoding.GetBytes($Text)
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
        if ($needle.Length -gt 0) {
            [Array]::Clear($needle, 0, $needle.Length)
        }
    }
}

try {
    if (-not $testRootFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $testRootFullPath) -notlike 'sumi-guard-adapter-tests-*') {
        throw 'Refusing to create the test root outside the resolved temporary directory.'
    }
    [void](New-Item -ItemType Directory -Path $testRootFullPath -ErrorAction Stop)
    Import-Module $localStoreManifest -Force -ErrorAction Stop
    Import-Module $adapterManifest -Force -ErrorAction Stop
    $localStoreModule = Get-Module 'SumiGuard.LocalStore' -ErrorAction Stop
    $adapterModule = Get-Module 'SumiGuard.ExecutionAdapter' -ErrorAction Stop

    $bodyStore = Join-Path $testRootFullPath 'body-store'
    $executionStore = Join-Path $testRootFullPath 'execution-store'
    $bodyStoreInit = Initialize-SumiGuardLocalStore -Path $bodyStore
    $executionStoreInit = Initialize-SumiGuardExecutionStore -Path $executionStore
    Assert-Test $bodyStoreInit.success 'LocalStore initialization failed.'
    Assert-Test $executionStoreInit.success 'Execution-store initialization failed.'
    Assert-Test $executionStoreInit.acl.valid 'Execution-store ACL validation failed.'
    Add-TestResult -Name 'stores_initialized' -Evidence @{
        local_store_status = $bodyStoreInit.status
        execution_store_status = $executionStoreInit.status
        execution_store_acl_restricted = $true
    }

    $syntheticSecret = @('SUMI', 'GUARD', 'SYNTHETIC', 'SECRET', '20261003') -join '_'

    # Policy-based omission is a successful collection, not a storage failure.
    # It must not create a protected-body file or a false failure notice.
    $metadataExecutionId = [Guid]::NewGuid().ToString('N')
    $bodiesBefore = @(Get-ChildItem -LiteralPath $bodyStore -Filter '*.sgb' -File).Count
    $metadataOnly = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -Body $syntheticSecret `
        -ExecutionId $metadataExecutionId `
        -MetadataOnly
    Assert-Test $metadataOnly.success 'Metadata-only intent save failed.'
    Assert-Test ($metadataOnly.status -ceq 'EVENT_SAVED_METADATA_ONLY') 'Metadata-only status changed.'
    Assert-Test ($metadataOnly.body_storage_status -ceq 'OMITTED_BY_POLICY') 'Body policy was not recorded.'
    $bodiesAfter = @(Get-ChildItem -LiteralPath $bodyStore -Filter '*.sgb' -File).Count
    Assert-Test ($bodiesAfter -eq $bodiesBefore) 'Metadata-only path wrote a body container.'
    $metaList = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $metadataExecutionId
    Assert-Test ($metaList.success -and $metaList.record_count -eq 1) 'Metadata-only record missing.'
    $metaRecord = $metaList.records[0]
    Assert-Test ($metaRecord.content_status -ceq 'HASH_ONLY') 'Metadata-only content status wrong.'
    Assert-Test ($metaRecord.collection_status -ceq 'RECORDS_FOUND') 'Metadata-only was misclassified as failure.'
    Assert-Test ([string]::IsNullOrEmpty([string]$metaRecord.failure_reason_code)) 'Metadata-only failure reason unexpected.'
    Assert-Test ($metaRecord.body_reference_status -ceq 'NOT_STORED') 'Body reference incorrectly available.'
    $noBody = Read-SumiGuardExecutionBody `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $metadataExecutionId
    Assert-Test (-not $noBody.success -and $noBody.status -ceq 'BODY_NOT_CAPTURED') `
        'Metadata-only record unexpectedly allowed body read.'
    $metadataNotices = Get-SumiGuardCollectionFailureNotice `
        -ExecutionStorePath $executionStore `
        -ExecutionId $metadataExecutionId
    Assert-Test ($metadataNotices.success -and $metadataNotices.notice_count -eq 0) `
        'Metadata-only path emitted a false failure notice.'
    $safeObjects.Add($metadataOnly)
    $safeObjects.Add($metaList)
    $safeObjects.Add($noBody)
    Add-TestResult -Name 'metadata_only_omits_command_body' -Evidence @{
        adapter_status = $metadataOnly.status
        body_files_created = 0
        read_status = $noBody.status
        failure_notices = 0
    }

    # End-to-end MONITOR -> real ExecutionAdapter verification. This test lives
    # in the DPAPI-dependent integration suite because it imports LocalStore;
    # the hook still runs in a child Windows PowerShell 5.1 process and receives
    # no -CaptureCommandBody switch.
    $realCaseRoot = Join-Path $testRootFullPath 'real-hook-adapter'
    $realBodyStore = Join-Path $realCaseRoot 'body-store'
    $realExecutionStore = Join-Path $realCaseRoot 'execution-store'
    $realAssessmentStore = Join-Path $realCaseRoot 'assessment-store'
    $realNoticePath = Join-Path $realCaseRoot 'notices\monitor-hook-notices.ndjson'
    $realResultPath = Join-Path $realCaseRoot 'result.json'
    $realHookPath = Join-Path $projectRoot 'hooks\Invoke-SumiGuardMonitorHook.ps1'
    $null = New-Item -ItemType Directory -Path $realCaseRoot -Force
    $null = Import-Module $assessmentStoreManifest -Force -ErrorAction Stop
    $realAssessmentInit = New-SumiGuardAssessmentStore -StorePath $realAssessmentStore
    Assert-Test $realAssessmentInit.success 'Real-hook assessment-store initialization failed.'
    $realBodyInit = Initialize-SumiGuardLocalStore -Path $realBodyStore
    $realExecutionInit = Initialize-SumiGuardExecutionStore -Path $realExecutionStore
    Assert-Test $realBodyInit.success 'Real-hook LocalStore initialization failed.'
    Assert-Test $realExecutionInit.success 'Real-hook execution-store initialization failed.'

    $realHookBody = "Write-Output '$syntheticSecret'"
    $realHookRun = Invoke-RealMonitorHook `
        -HookPath $realHookPath `
        -ExecutionStorePath $realExecutionStore `
        -LocalStorePath $realBodyStore `
        -AssessmentStorePath $realAssessmentStore `
        -NoticePath $realNoticePath `
        -ResultPath $realResultPath `
        -EventJson (Get-RealHookEventJson -Command $realHookBody)
    Assert-Test ($realHookRun.exit_code -eq 0 -and $realHookRun.child_process_exited) `
        'Real MONITOR hook did not exit cleanly.'
    Assert-Test (-not $realHookRun.stdout_text.Contains($syntheticSecret)) `
        'Synthetic body leaked to MONITOR stdout.'
    Assert-Test (-not $realHookRun.stderr_text.Contains($syntheticSecret)) `
        'Synthetic body leaked to MONITOR stderr.'

    $realDetail = Get-Content -LiteralPath $realResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $realExecutionId = [string]$realDetail.execution_id
    Assert-Test (-not [string]::IsNullOrWhiteSpace($realExecutionId)) `
        'Real MONITOR hook did not produce an execution identity.'
    $realRecords = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $realExecutionStore `
        -LocalStorePath $realBodyStore `
        -ExecutionId $realExecutionId
    Assert-Test ($realRecords.success -and $realRecords.record_count -eq 1) `
        'Real adapter did not generate exactly one execution record.'
    $realRecord = $realRecords.records[0]
    $realAssessmentRecords = Get-SumiGuardAssessmentRecord -StorePath $realAssessmentStore
    Assert-Test ($realAssessmentRecords.success -and $realAssessmentRecords.record_count -eq 1) `
        'Real MONITOR hook did not generate an assessment record.'
    $realAssessmentRecord = $realAssessmentRecords.records[0]

    $realHash = [Security.Cryptography.SHA256]::Create()
    try {
        $realExpectedHash = ([BitConverter]::ToString($realHash.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($realHookBody)))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $realHash.Dispose()
    }
    $realBodyFiles = @(Get-ChildItem -LiteralPath $realBodyStore -Recurse -File -Filter '*.sgb')
    $realReadBody = Read-SumiGuardExecutionBody `
        -ExecutionStorePath $realExecutionStore `
        -LocalStorePath $realBodyStore `
        -ExecutionId $realExecutionId
    $realNotices = Get-SumiGuardCollectionFailureNotice `
        -ExecutionStorePath $realExecutionStore `
        -ExecutionId $realExecutionId
    $realResponse = $realHookRun.stdout_text | ConvertFrom-Json
    $realResponseNames = @($realResponse.PSObject.Properties.Name)
    Assert-Test ($realResponseNames.Count -eq 1 -and $realResponseNames[0] -ceq 'systemMessage') `
        'Real MONITOR response was not structured output only.'
    Assert-Test ([string]$realDetail.evaluation_origin -ceq 'CODEX_PRETOOLUSE_HOOK') `
        'Real MONITOR origin was not preserved.'
    Assert-Test ([string]$realAssessmentRecord.evaluation_origin -ceq 'CODEX_PRETOOLUSE_HOOK' -and
        [string]$realAssessmentRecord.record_type -ne 'MANAGED_EXECUTION') `
        'Pre-execution hook was represented as managed execution.'
    Assert-Test (-not $realDetail.automatic_deny -and $realDetail.monitor_action -ceq 'WARN_ONLY') `
        'Real MONITOR path changed deny behavior.'
    Assert-Test (Test-PlaintextAbsentFromTree -Path $realCaseRoot -Text $syntheticSecret) `
        'Synthetic body leaked to a real-hook generated file.'
    Assert-Test ($realBodyFiles.Count -eq 0) 'Real MONITOR path wrote an encrypted body file.'
    Assert-Test ($realRecord.content_status -ceq 'HASH_ONLY' -and
        $realRecord.collection_status -ceq 'RECORDS_FOUND' -and
        $realRecord.body_reference_status -ceq 'NOT_STORED' -and
        $realRecord.body_sha256 -ceq $realExpectedHash) `
        'Real adapter metadata did not match the expected hash-only record.'
    Assert-Test (-not $realReadBody.success -and $realReadBody.status -ceq 'BODY_NOT_CAPTURED') `
        'Real MONITOR path unexpectedly allowed body read.'
    Assert-Test ($realNotices.success -and $realNotices.notice_count -eq 0) `
        'Real MetadataOnly path emitted a false failure notice.'
    $safeObjects.Add($realRecords)
    $safeObjects.Add($realAssessmentRecords)
    $safeObjects.Add($realReadBody)
    Add-TestResult -Name 'real_monitor_to_adapter_metadata_only' -Evidence @{
        execution_record_count = $realRecords.record_count
        assessment_record_count = $realAssessmentRecords.record_count
        adapter_status = [string]$realDetail.intent_storage_status
        content_status = [string]$realRecord.content_status
        body_reference_status = [string]$realRecord.body_reference_status
        body_hash_matches = ($realRecord.body_sha256 -ceq $realExpectedHash)
        body_files_created = $realBodyFiles.Count
        body_read_status = [string]$realReadBody.status
        failure_notices = $realNotices.notice_count
        evaluation_origin = [string]$realAssessmentRecord.evaluation_origin
        child_process_exited = [bool]$realHookRun.child_process_exited
        automatic_deny = [bool]$realDetail.automatic_deny
    }

    $normalExecutionId = [Guid]::NewGuid().ToString('N')
    $normal = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -Body $syntheticSecret `
        -ExecutionId $normalExecutionId
    Assert-Test $normal.success 'Normal adapter save failed.'
    Assert-Test ($normal.status -ceq 'EVENT_AND_BODY_SAVED') 'Normal adapter status is incorrect.'
    Assert-Test ($normal.execution_id -ceq $normalExecutionId) 'Execution ID changed during save.'
    Assert-Test ($normal.event_storage_status -ceq 'SAVED') 'Event was not saved.'
    Assert-Test ($normal.body_storage_status -ceq 'SAVED') 'Body was not saved.'
    $normalList = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $normalExecutionId
    Assert-Test $normalList.success 'Normal metadata read failed.'
    Assert-Test ($normalList.record_count -eq 1) 'Normal execution record count is incorrect.'
    $normalRecord = $normalList.records[0]
    Assert-Test ($normalRecord.execution_id -ceq $normalExecutionId) 'Metadata execution ID is incorrect.'
    Assert-Test ($normalRecord.body_ref -ceq $normal.body_ref) 'Metadata body reference is incorrect.'
    Assert-Test ($normalRecord.content_status -ceq 'CAPTURED_ENCRYPTED') 'Captured status is incorrect.'
    Assert-Test ($normalRecord.collection_status -ceq 'RECORDS_FOUND') 'Collection status is incorrect.'
    Assert-Test ($normalRecord.body_reference_status -ceq 'AVAILABLE') 'Body reference is not available.'
    Assert-Test ($normalRecord.PSObject.Properties.Name -notcontains 'body') `
        'Normal metadata output included a body property.'
    $normalRead = Read-SumiGuardExecutionBody `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $normalExecutionId
    Assert-Test $normalRead.success 'Explicit body read failed.'
    Assert-Test ($normalRead.status -ceq 'BODY_DECRYPTED') 'Explicit body-read status is incorrect.'
    Assert-Test ($normalRead.body -ceq $syntheticSecret) 'Explicitly decrypted body did not match.'
    $safeObjects.Add($normal)
    $safeObjects.Add($normalList)
    Add-TestResult -Name 'execution_id_body_reference_round_trip' -Evidence @{
        event_status = $normal.status
        metadata_content_status = $normalRecord.content_status
        body_reference_status = $normalRecord.body_reference_status
        explicit_read_status = $normalRead.status
        decrypted_body_matches = $true
        normal_listing_includes_body = $false
    }

    $capacityExecutionId = [Guid]::NewGuid().ToString('N')
    $capacity = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -Body $syntheticSecret `
        -ExecutionId $capacityExecutionId `
        -MaxItemBytes 8
    Assert-Test (-not $capacity.success) 'Capacity overflow unexpectedly succeeded.'
    Assert-Test ($capacity.status -ceq 'EVENT_SAVED_BODY_COLLECTION_FAILED') `
        'Capacity-overflow adapter status is incorrect.'
    Assert-Test ($capacity.content_status -ceq 'HASH_ONLY') 'Capacity overflow did not retain hash-only state.'
    Assert-Test ($capacity.collection_status -ceq 'COLLECTION_FAILED') `
        'Capacity overflow did not record collection failure.'
    Assert-Test ($capacity.monitor_action -ceq 'CONTINUE' -and -not $capacity.automatic_deny) `
        'Capacity overflow did not remain in MONITOR behavior.'
    $capacityRecordResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $capacityExecutionId
    $capacityRecord = $capacityRecordResult.records[0]
    Assert-Test ($null -eq $capacityRecord.body_ref) 'Capacity failure stored a body reference.'
    Assert-Test ($capacityRecord.failure_reason_code -ceq 'ITEM_LIMIT_EXCEEDED') `
        'Capacity failure reason is incorrect.'
    $capacityNotices = Get-SumiGuardCollectionFailureNotice `
        -ExecutionStorePath $executionStore `
        -ExecutionId $capacityExecutionId
    Assert-Test ($capacityNotices.notice_count -eq 1) 'Capacity failure notice is missing.'
    $safeObjects.Add($capacity)
    $safeObjects.Add($capacityRecordResult)
    $safeObjects.Add($capacityNotices)
    Add-TestResult -Name 'capacity_failure_monitor_continues' -Evidence @{
        adapter_status = $capacity.status
        content_status = $capacityRecord.content_status
        collection_status = $capacityRecord.collection_status
        failure_reason_code = $capacityRecord.failure_reason_code
        monitor_action = $capacity.monitor_action
        automatic_deny = $capacity.automatic_deny
    }

    $encryptionExecutionId = [Guid]::NewGuid().ToString('N')
    try {
        & $localStoreModule { $script:SumiGuardTestForceEncryptionFailure = $true }
        $encryptionFailure = Save-SumiGuardExecutionIntent `
            -ExecutionStorePath $executionStore `
            -LocalStorePath $bodyStore `
            -Body $syntheticSecret `
            -ExecutionId $encryptionExecutionId
    }
    finally {
        & $localStoreModule { $script:SumiGuardTestForceEncryptionFailure = $false }
    }
    Assert-Test (-not $encryptionFailure.success) 'Encryption failure unexpectedly succeeded.'
    Assert-Test ($encryptionFailure.status -ceq 'EVENT_SAVED_BODY_COLLECTION_FAILED') `
        'Encryption-failure adapter status is incorrect.'
    Assert-Test ($encryptionFailure.monitor_action -ceq 'CONTINUE' -and
        -not $encryptionFailure.automatic_deny) 'Encryption failure did not remain in MONITOR behavior.'
    $encryptionRecordResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $encryptionExecutionId
    $encryptionRecord = $encryptionRecordResult.records[0]
    Assert-Test ($encryptionRecord.failure_reason_code -ceq 'ENCRYPTION_FAILED') `
        'Encryption failure reason is incorrect.'
    Assert-Test ($encryptionRecord.collection_status -ceq 'COLLECTION_FAILED') `
        'Encryption failure collection status is incorrect.'
    $encryptionNotices = Get-SumiGuardCollectionFailureNotice `
        -ExecutionStorePath $executionStore `
        -ExecutionId $encryptionExecutionId
    Assert-Test ($encryptionNotices.notice_count -eq 1) 'Encryption failure notice is missing.'
    $safeObjects.Add($encryptionFailure)
    $safeObjects.Add($encryptionRecordResult)
    $safeObjects.Add($encryptionNotices)
    Add-TestResult -Name 'encryption_failure_monitor_continues' -Evidence @{
        adapter_status = $encryptionFailure.status
        content_status = $encryptionRecord.content_status
        collection_status = $encryptionRecord.collection_status
        failure_reason_code = $encryptionRecord.failure_reason_code
        monitor_action = $encryptionFailure.monitor_action
        automatic_deny = $encryptionFailure.automatic_deny
    }

    $eventFailureExecutionId = [Guid]::NewGuid().ToString('N')
    try {
        & $adapterModule { $script:SumiGuardTestForceEventWriteFailure = $true }
        $eventFailure = Save-SumiGuardExecutionIntent `
            -ExecutionStorePath $executionStore `
            -LocalStorePath $bodyStore `
            -Body $syntheticSecret `
            -ExecutionId $eventFailureExecutionId
    }
    finally {
        & $adapterModule { $script:SumiGuardTestForceEventWriteFailure = $false }
    }
    Assert-Test (-not $eventFailure.success) 'Injected event failure unexpectedly succeeded.'
    Assert-Test ($eventFailure.status -ceq 'EVENT_SAVE_FAILED_BODY_ORPHANED') `
        'Event failure did not report an orphaned body.'
    Assert-Test ($eventFailure.body_storage_status -ceq 'SAVED_ORPHANED') `
        'Orphaned-body storage state is incorrect.'
    Assert-Test ($eventFailure.failure_notice_status -ceq 'SAVED') 'Orphan failure notice was not saved.'
    Assert-Test ($eventFailure.monitor_action -ceq 'CONTINUE' -and -not $eventFailure.automatic_deny) `
        'Event failure did not remain in MONITOR behavior.'
    $eventFailureRecords = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $eventFailureExecutionId
    Assert-Test ($eventFailureRecords.record_count -eq 0) 'Failed event write produced a primary event.'
    $eventFailureNotices = Get-SumiGuardCollectionFailureNotice `
        -ExecutionStorePath $executionStore `
        -ExecutionId $eventFailureExecutionId
    Assert-Test ($eventFailureNotices.notice_count -eq 1) 'Event failure notice count is incorrect.'
    Assert-Test ($eventFailureNotices.notices[0].body_reference_status -ceq 'ORPHANED_BODY') `
        'Failure notice did not classify the body as orphaned.'
    Assert-Test (Test-Path -LiteralPath (Join-Path $bodyStore ($eventFailure.body_ref + '.sgb')) -PathType Leaf) `
        'Orphaned encrypted body was not present.'
    $safeObjects.Add($eventFailure)
    $safeObjects.Add($eventFailureRecords)
    $safeObjects.Add($eventFailureNotices)
    Add-TestResult -Name 'event_failure_after_body_save' -Evidence @{
        adapter_status = $eventFailure.status
        body_storage_status = $eventFailure.body_storage_status
        event_storage_status = $eventFailure.event_storage_status
        failure_notice_status = $eventFailure.failure_notice_status
        failure_notice_body_state = $eventFailureNotices.notices[0].body_reference_status
        primary_event_count = $eventFailureRecords.record_count
    }

    $missingExecutionId = [Guid]::NewGuid().ToString('N')
    $missingSave = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -Body $syntheticSecret `
        -ExecutionId $missingExecutionId
    Assert-Test $missingSave.success 'Missing-reference fixture save failed.'
    $missingBodyPath = Join-Path $bodyStore ($missingSave.body_ref + '.sgb')
    $resolvedBodyStore = [System.IO.Path]::GetFullPath($bodyStore)
    $resolvedMissingBody = [System.IO.Path]::GetFullPath($missingBodyPath)
    Assert-Test ($resolvedMissingBody.StartsWith(
        $resolvedBodyStore + [System.IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'Missing-reference fixture path escaped the body store.'
    [System.IO.File]::Delete($resolvedMissingBody)
    $missingList = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $missingExecutionId
    Assert-Test ($missingList.records[0].body_reference_status -ceq 'REFERENCE_MISSING') `
        'Unexpectedly missing body was not classified as a broken reference.'
    $missingRead = Read-SumiGuardExecutionBody `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $missingExecutionId
    Assert-Test ($missingRead.status -ceq 'BODY_REFERENCE_MISSING') `
        'Unexpectedly missing body read status is incorrect.'
    $safeObjects.Add($missingSave)
    $safeObjects.Add($missingList)
    $safeObjects.Add($missingRead)
    Add-TestResult -Name 'unexpected_missing_reference' -Evidence @{
        listing_status = $missingList.records[0].body_reference_status
        explicit_read_status = $missingRead.status
        collection_status = $missingList.records[0].body_reference_collection_status
    }

    $expiredExecutionId = [Guid]::NewGuid().ToString('N')
    try {
        & $localStoreModule {
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow.AddDays(-31) }
        }
        & $adapterModule {
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow.AddDays(-31) }
        }
        $expiredSave = Save-SumiGuardExecutionIntent `
            -ExecutionStorePath $executionStore `
            -LocalStorePath $bodyStore `
            -Body $syntheticSecret `
            -ExecutionId $expiredExecutionId
    }
    finally {
        & $localStoreModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow } }
        & $adapterModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow } }
    }
    Assert-Test $expiredSave.success 'Expired fixture save failed.'
    $retention = Invoke-SumiGuardExecutionRetentionCleanup `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -RetentionDays 30 `
        -Confirm:$false
    Assert-Test $retention.success 'Integrated retention cleanup failed.'
    Assert-Test ($retention.retention_tombstone_count -eq 1) `
        'Integrated retention did not create exactly one tombstone.'
    $expiredList = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $expiredExecutionId
    Assert-Test ($expiredList.record_count -eq 1) 'Expired execution event was not preserved.'
    Assert-Test ($expiredList.records[0].body_reference_status -ceq 'DELETED_BY_RETENTION') `
        'Expired body was not classified as retention-deleted.'
    $expiredRead = Read-SumiGuardExecutionBody `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $expiredExecutionId
    Assert-Test ($expiredRead.status -ceq 'BODY_DELETED_BY_RETENTION') `
        'Expired explicit read status is incorrect.'
    $missingAfterRetention = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $bodyStore `
        -ExecutionId $missingExecutionId
    Assert-Test ($missingAfterRetention.records[0].body_reference_status -ceq 'REFERENCE_MISSING') `
        'Unexpected missing reference was incorrectly reclassified as retention-deleted.'
    $safeObjects.Add($expiredSave)
    $safeObjects.Add($retention)
    $safeObjects.Add($expiredList)
    $safeObjects.Add($expiredRead)
    Add-TestResult -Name 'retention_preserves_event_and_classifies_body' -Evidence @{
        cleanup_status = $retention.status
        execution_record_preserved = $true
        expired_body_status = $expiredList.records[0].body_reference_status
        expired_read_status = $expiredRead.status
        unexpected_missing_status_remains = $missingAfterRetention.records[0].body_reference_status
    }

    $safeJson = $safeObjects.ToArray() | ConvertTo-Json -Compress -Depth 12
    Assert-Test (-not $safeJson.Contains($syntheticSecret)) `
        'A normal result or failure result included the synthetic secret.'
    Assert-Test (Test-PlaintextAbsentFromTree -Path $executionStore -Text $syntheticSecret) `
        'Execution metadata or failure files included the synthetic secret.'
    Assert-Test (Test-PlaintextAbsentFromTree -Path $bodyStore -Text $syntheticSecret) `
        'Encrypted body-store files included the synthetic secret in plaintext.'
    Add-TestResult -Name 'plaintext_non_disclosure' -Evidence @{
        normal_and_failure_results_include_secret = $false
        metadata_and_failure_files_include_secret = $false
        encrypted_store_includes_plaintext_secret = $false
        explicit_read_was_the_only_body_return_path = $true
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
}
finally {
    $localModuleForReset = Get-Module 'SumiGuard.LocalStore' -ErrorAction SilentlyContinue
    if ($null -ne $localModuleForReset) {
        & $localModuleForReset {
            $script:SumiGuardTestForceEncryptionFailure = $false
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow }
        }
    }
    $adapterModuleForReset = Get-Module 'SumiGuard.ExecutionAdapter' -ErrorAction SilentlyContinue
    if ($null -ne $adapterModuleForReset) {
        & $adapterModuleForReset {
            $script:SumiGuardTestForceEventWriteFailure = $false
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow }
        }
    }
    if (Test-Path -LiteralPath $testRootFullPath) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRootFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-adapter-tests-*') {
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

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    tests = $results.ToArray()
    failure = $failure
    synthetic_body_included = $false
    test_root_cleaned = -not (Test-Path -LiteralPath $testRootFullPath)
}
$summary | ConvertTo-Json -Depth 10
if ($null -ne $failure) {
    exit 1
}
