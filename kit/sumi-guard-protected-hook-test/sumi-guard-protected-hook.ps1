[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
        if ($bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Get-ExecutionId {
    param([Parameter(Mandatory = $true)]$HookInput)

    $identity = ([string]$HookInput.session_id) + '|' +
        ([string]$HookInput.turn_id) + '|' +
        ([string]$HookInput.tool_use_id)
    return (Get-Utf8Sha256 -Text $identity).Substring(0, 32)
}

function Get-RequiredEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw [System.InvalidOperationException]::new('Required test configuration is unavailable.')
    }
    return $value
}

function Assert-MetadataPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )

    $store = [System.IO.Path]::GetFullPath($ExecutionStorePath).TrimEnd([char[]]@('\', '/'))
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath).TrimEnd([char[]]@('\', '/'))
    if ($parent -cne $store -or [System.IO.Path]::GetFileName($fullPath) -cne $ExpectedName) {
        throw [System.IO.InvalidDataException]::new('Metadata path is outside the execution store.')
    }
    if (Test-Path -LiteralPath $fullPath) {
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [System.IO.InvalidDataException]::new('Metadata path cannot be a reparse point.')
        }
    }
    return $fullPath
}

function Enter-MetadataLock {
    param([Parameter(Mandatory = $true)][string]$ExecutionStorePath)

    $lockPath = Join-Path $ExecutionStorePath '.sumi-guard-hook-metadata.lock'
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt 5000) {
        try {
            return New-Object System.IO.FileStream(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 25
        }
    }
    throw [System.TimeoutException]::new('Metadata lock was unavailable.')
}

function Write-SafeMetadataRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][ValidateSet('hook-runtime.ndjson', 'outcomes.ndjson', 'hook-failures.ndjson')][string]$Name,
        [Parameter(Mandatory = $true)]$Record
    )

    $path = Assert-MetadataPath `
        -ExecutionStorePath $ExecutionStorePath `
        -Path (Join-Path $ExecutionStorePath $Name) `
        -ExpectedName $Name
    $json = $Record | ConvertTo-Json -Compress -Depth 8
    [byte[]]$bytes = $script:Utf8Strict.GetBytes($json + [Environment]::NewLine)
    $lock = $null
    $stream = $null
    try {
        $lock = Enter-MetadataLock -ExecutionStorePath $ExecutionStorePath
        $stream = New-Object System.IO.FileStream(
            $path,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Write-HookFailureNotice {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [AllowNull()][string]$BodyRef
    )

    $notice = [pscustomobject][ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'CollectionFailureNotice'
        execution_id = $ExecutionId
        occurred_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        collection_status = 'COLLECTION_FAILED'
        content_status = 'CONTENT_UNKNOWN'
        failed_stage = $Stage
        reason_code = $ReasonCode
        body_ref = $BodyRef
        body_reference_status = 'UNKNOWN'
        content_included = $false
        monitor_action = 'CONTINUE'
        automatic_deny = $false
    }
    try {
        Write-SafeMetadataRecord `
            -ExecutionStorePath $ExecutionStorePath `
            -Name 'hook-failures.ndjson' `
            -Record $notice
    }
    catch {
        # Deliberately empty, and the only such place in this hook: the failure
        # notice is itself the fallback channel, so a failure here has nowhere
        # left to be recorded from inside the hook. Standard output is the hook
        # protocol and standard error would turn a recording failure into a tool
        # error, so neither is used. The hook still continues; making a recording
        # failure consequential is the ENFORCE_RECORDING design
        # (docs/26-enforce-recording-design.md), not something this fallback can
        # do. Every other recording failure in this hook writes a notice here.
    }
}

function Write-UnexpectedCommandDeny {
    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason =
                'SUMI Guard isolated protected-storage test permits only its declared harmless fixed command.'
        }
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 5))
}

$executionId = [Guid]::NewGuid().ToString('N')
$executionStore = $null
try {
    $rawHookInput = [Console]::In.ReadToEnd()
    $hookInput = $rawHookInput | ConvertFrom-Json -ErrorAction Stop
    $hookEventName = [string]$hookInput.hook_event_name
    $toolName = [string]$hookInput.tool_name
    if (($hookEventName -cne 'PreToolUse' -and $hookEventName -cne 'PostToolUse') -or
        $toolName -cne 'Bash') {
        exit 0
    }

    $command = ''
    if ($null -ne $hookInput.tool_input -and $null -ne $hookInput.tool_input.command) {
        $command = [string]$hookInput.tool_input.command
    }
    $commandSha256 = Get-Utf8Sha256 -Text $command
    $expectedSha256 = Get-RequiredEnvironmentValue -Name 'SUMI_GUARD_EXPECTED_COMMAND_SHA256'
    if ($commandSha256 -cne $expectedSha256) {
        if ($hookEventName -ceq 'PreToolUse') {
            Write-UnexpectedCommandDeny
        }
        exit 0
    }

    $executionId = Get-ExecutionId -HookInput $hookInput
    $executionStore = Get-RequiredEnvironmentValue -Name 'SUMI_GUARD_EXECUTION_STORE_PATH'
    $localStore = Get-RequiredEnvironmentValue -Name 'SUMI_GUARD_LOCAL_STORE_PATH'
    $adapterManifest = Get-RequiredEnvironmentValue -Name 'SUMI_GUARD_ADAPTER_MANIFEST'
    $runtimeRecord = [pscustomobject][ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'HookRuntimeObserved'
        execution_id = $executionId
        occurred_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        hook_event_name = $hookEventName
        hook_process_id = $PID
        command_sha256 = $commandSha256
        collection_status = 'RECORDS_FOUND'
        content_status = 'CONTENT_NOT_INCLUDED'
        body_ref = $null
    }
    try {
        Write-SafeMetadataRecord `
            -ExecutionStorePath $executionStore `
            -Name 'hook-runtime.ndjson' `
            -Record $runtimeRecord
    }
    catch {
        # A runtime record that was not written used to leave no trace at all.
        # The same notice path the outcome-store failure uses is taken here, so
        # the gap is visible to a reader of the store.
        Write-HookFailureNotice `
            -ExecutionStorePath $executionStore `
            -ExecutionId $executionId `
            -Stage 'hook-runtime-store' `
            -ReasonCode 'RUNTIME_WRITE_FAILED' `
            -BodyRef $null
    }

    $null = Import-Module -Name $adapterManifest -Force -ErrorAction Stop
    if ($hookEventName -ceq 'PreToolUse') {
        $saveResult = SumiGuard.ExecutionAdapter\Save-SumiGuardExecutionIntent `
            -ExecutionStorePath $executionStore `
            -LocalStorePath $localStore `
            -Body $command `
            -ExecutionId $executionId
        if (-not $saveResult.success) {
            $bodyRef = $null
            if ($saveResult.PSObject.Properties.Name -contains 'body_ref') {
                $bodyRef = [string]$saveResult.body_ref
            }
            Write-HookFailureNotice `
                -ExecutionStorePath $executionStore `
                -ExecutionId $executionId `
                -Stage 'execution-adapter-pretooluse' `
                -ReasonCode ([string]$saveResult.status) `
                -BodyRef $bodyRef
        }
        exit 0
    }

    $recordResult = SumiGuard.ExecutionAdapter\Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore `
        -LocalStorePath $localStore `
        -ExecutionId $executionId
    $bodyRef = $null
    $bodySha256 = $commandSha256
    $contentStatus = 'CONTENT_UNKNOWN'
    $collectionStatus = 'COLLECTION_FAILED'
    $bodyReferenceStatus = 'UNKNOWN'
    if ($recordResult.success -and $recordResult.record_count -eq 1) {
        $record = $recordResult.records[0]
        $bodyRef = [string]$record.body_ref
        $bodySha256 = [string]$record.body_sha256
        $contentStatus = [string]$record.content_status
        $collectionStatus = [string]$record.collection_status
        $bodyReferenceStatus = [string]$record.body_reference_status
    }

    $expectedOutputMarker = Get-RequiredEnvironmentValue -Name 'SUMI_GUARD_EXPECTED_OUTPUT_MARKER'
    $responseJson = $hookInput.tool_response | ConvertTo-Json -Compress -Depth 20
    $fixedOutputObserved = $responseJson.Contains($expectedOutputMarker)
    $executionStatus = 'OUTPUT_NOT_CONFIRMED'
    if ($fixedOutputObserved) {
        $executionStatus = 'SUCCEEDED'
    }
    $outcome = [pscustomobject][ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ExecutionOutcomeObserved'
        execution_id = $executionId
        occurred_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        command_sha256 = $commandSha256
        execution_status = $executionStatus
        fixed_output_observed = $fixedOutputObserved
        content_status = $contentStatus
        collection_status = $collectionStatus
        body_ref = $bodyRef
        body_sha256 = $bodySha256
        body_reference_status = $bodyReferenceStatus
        response_body_included = $false
    }
    try {
        Write-SafeMetadataRecord `
            -ExecutionStorePath $executionStore `
            -Name 'outcomes.ndjson' `
            -Record $outcome
    }
    catch {
        Write-HookFailureNotice `
            -ExecutionStorePath $executionStore `
            -ExecutionId $executionId `
            -Stage 'outcome-store' `
            -ReasonCode 'OUTCOME_WRITE_FAILED' `
            -BodyRef $bodyRef
    }
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($executionStore)) {
        Write-HookFailureNotice `
            -ExecutionStorePath $executionStore `
            -ExecutionId $executionId `
            -Stage 'hook-processing' `
            -ReasonCode 'HOOK_PROCESSING_FAILED' `
            -BodyRef $null
    }
}

exit 0
