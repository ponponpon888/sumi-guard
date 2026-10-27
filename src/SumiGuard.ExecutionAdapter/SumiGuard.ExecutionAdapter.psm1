Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$localStoreManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
if (-not (Test-Path -LiteralPath $localStoreManifest -PathType Leaf)) {
    throw 'SumiGuard.LocalStore module was not found.'
}
Import-Module $localStoreManifest -ErrorAction Stop

$script:SchemaVersion = 1
$script:MarkerFileName = '.sumi-guard-execution-store.json'
$script:LockFileName = '.sumi-guard-execution-store.lock'
$script:EventFileName = 'events.ndjson'
$script:FailureFileName = 'failures.ndjson'
$script:RetentionFileName = 'retention.ndjson'
$script:MetadataLogMaxBytes = 16MB
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SumiGuardTestForceEventWriteFailure = $false
$script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow }

function New-SumiGuardAdapterResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Status,
        [hashtable]$Properties = @{}
    )

    $value = [ordered]@{
        success = $Success
        status = $Status
    }
    foreach ($key in $Properties.Keys) {
        $value[$key] = $Properties[$key]
    }
    return [pscustomobject]$value
}

function Get-SumiGuardAdapterUtcNow {
    return [DateTimeOffset](& $script:SumiGuardUtcNowProvider)
}

function Resolve-SumiGuardExecutionStorePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw [System.ArgumentException]::new('Execution-store path is empty.')
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $trimChars = [char[]]@('\', '/')
    if ($fullPath.TrimEnd($trimChars) -ceq $rootPath.TrimEnd($trimChars)) {
        throw [System.ArgumentException]::new('A filesystem root cannot be an execution store.')
    }
    return $fullPath.TrimEnd($trimChars)
}

function Test-SumiGuardAdapterReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-SumiGuardAdapterPathContainsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $relativePath = $fullPath.Substring($rootPath.Length)
    $parts = $relativePath.Split(
        [char[]]@('\', '/'),
        [StringSplitOptions]::RemoveEmptyEntries)
    $currentPath = $rootPath
    foreach ($part in $parts) {
        $currentPath = Join-Path $currentPath $part
        if (Test-Path -LiteralPath $currentPath) {
            if (Test-SumiGuardAdapterReparsePoint -Path $currentPath) {
                return $true
            }
        }
    }
    return $false
}

function Set-SumiGuardExecutionStoreAcl {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($currentSid, $systemSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow)
        [void]$security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StorePath -AclObject $security -ErrorAction Stop
}

function Test-SumiGuardExecutionStoreAcl {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $systemSid = 'S-1-5-18'
    $security = Get-Acl -LiteralPath $StorePath -ErrorAction Stop
    $rules = @($security.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]))
    $hasCurrent = $false
    $hasSystem = $false
    $unexpected = 0
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        $allow = $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        $full = (($rule.FileSystemRights -band
            [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl)
        if (($sid -cne $currentSid -and $sid -cne $systemSid) -or -not $allow) {
            $unexpected++
            continue
        }
        if ($sid -ceq $currentSid -and $full) { $hasCurrent = $true }
        if ($sid -ceq $systemSid -and $full) { $hasSystem = $true }
    }
    return [pscustomobject][ordered]@{
        valid = $security.AreAccessRulesProtected -and $hasCurrent -and $hasSystem -and $unexpected -eq 0
        inheritance_disabled = $security.AreAccessRulesProtected
        current_user_full_control = $hasCurrent
        system_full_control = $hasSystem
        unexpected_rule_count = $unexpected
    }
}

function Assert-SumiGuardExecutionStore {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $resolvedPath = Resolve-SumiGuardExecutionStorePath -Path $StorePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new('Execution store does not exist.')
    }
    if (Test-SumiGuardAdapterPathContainsReparsePoint -Path $resolvedPath) {
        throw [System.IO.InvalidDataException]::new('Execution-store path contains a reparse point.')
    }
    $markerPath = Join-Path $resolvedPath $script:MarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
        (Test-SumiGuardAdapterReparsePoint -Path $markerPath)) {
        throw [System.IO.InvalidDataException]::new('Execution-store marker is missing or invalid.')
    }
    try {
        $marker = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -ErrorAction Stop
        $storeId = [Guid]::Empty
        if ([int]$marker.schema_version -ne $script:SchemaVersion -or
            -not [Guid]::TryParseExact([string]$marker.store_id, 'N', [ref]$storeId)) {
            throw 'Invalid execution-store marker.'
        }
    }
    catch {
        throw [System.IO.InvalidDataException]::new('Execution-store marker is invalid.')
    }
    $acl = Test-SumiGuardExecutionStoreAcl -StorePath $resolvedPath
    if (-not $acl.valid) {
        throw [System.UnauthorizedAccessException]::new('Execution-store ACL is not restricted.')
    }
    return $resolvedPath
}

function Enter-SumiGuardExecutionStoreLock {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [int]$TimeoutMilliseconds = 10000
    )

    $path = Join-Path $StorePath $script:LockFileName
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            return New-Object System.IO.FileStream(
                $path,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 25
        }
    }
    throw [System.TimeoutException]::new('Timed out waiting for the execution-store lock.')
}

function Get-SumiGuardRecordPath {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][ValidateSet('Event', 'Failure', 'Retention')][string]$Kind
    )

    switch ($Kind) {
        'Event' { return Join-Path $StorePath $script:EventFileName }
        'Failure' { return Join-Path $StorePath $script:FailureFileName }
        'Retention' { return Join-Path $StorePath $script:RetentionFileName }
    }
}

function Write-SumiGuardMetadataRecord {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][ValidateSet('Event', 'Failure', 'Retention')][string]$Kind,
        [Parameter(Mandatory = $true)]$Record
    )

    if ($Kind -ceq 'Event' -and $script:SumiGuardTestForceEventWriteFailure) {
        throw [System.IO.IOException]::new('SUMI Guard test fault: event write failure.')
    }
    $json = $Record | ConvertTo-Json -Compress -Depth 8
    [byte[]]$bytes = $script:Utf8Strict.GetBytes($json + [Environment]::NewLine)
    $lock = $null
    $stream = $null
    try {
        $lock = Enter-SumiGuardExecutionStoreLock -StorePath $StorePath
        $path = Get-SumiGuardRecordPath -StorePath $StorePath -Kind $Kind
        $stream = New-Object System.IO.FileStream(
            $path,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read)
        if ($stream.Length -gt ($script:MetadataLogMaxBytes - [long]$bytes.LongLength)) {
            throw [System.IO.IOException]::new(
                ('Metadata log capacity exceeded for {0}.' -f $Kind))
        }
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

function Read-SumiGuardMetadataRecordsUnsafe {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][ValidateSet('Event', 'Failure', 'Retention')][string]$Kind
    )

    $path = Get-SumiGuardRecordPath -StorePath $StorePath -Kind $Kind
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    if (Test-SumiGuardAdapterReparsePoint -Path $path) {
        throw [System.IO.InvalidDataException]::new('Metadata files cannot be reparse points.')
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($path, $script:Utf8Strict)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $records.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        }
        catch {
            throw [System.IO.InvalidDataException]::new('Metadata contains an invalid record.')
        }
    }
    return $records.ToArray()
}

function Get-SumiGuardBodySha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body)

    [byte[]]$bytes = $script:Utf8Strict.GetBytes($Body)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        [byte[]]$digest = $sha.ComputeHash($bytes)
        try {
            return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        }
        finally {
            [Array]::Clear($digest, 0, $digest.Length)
        }
    }
    finally {
        $sha.Dispose()
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function New-SumiGuardFailureRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$FailedStage,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [AllowNull()][string]$BodyRef,
        [Parameter(Mandatory = $true)][string]$BodyReferenceStatus,
        [Parameter(Mandatory = $true)][string]$ContentStatus
    )

    return [pscustomobject][ordered]@{
        schema_version = $script:SchemaVersion
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'CollectionFailureNotice'
        execution_id = $ExecutionId
        occurred_at_utc = (Get-SumiGuardAdapterUtcNow).ToUniversalTime().ToString('o')
        collection_status = 'COLLECTION_FAILED'
        content_status = $ContentStatus
        failed_stage = $FailedStage
        reason_code = $ReasonCode
        body_ref = $BodyRef
        body_reference_status = $BodyReferenceStatus
        content_included = $false
        monitor_action = 'CONTINUE'
    }
}

function Test-SumiGuardBodyReferenceExists {
    param(
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [Parameter(Mandatory = $true)][string]$BodyRef
    )

    $id = [Guid]::Empty
    if (-not [Guid]::TryParseExact($BodyRef, 'N', [ref]$id)) {
        return $false
    }
    try {
        $storePath = [System.IO.Path]::GetFullPath($LocalStorePath)
        if (-not (Test-Path -LiteralPath $storePath -PathType Container) -or
            (Test-SumiGuardAdapterPathContainsReparsePoint -Path $storePath)) {
            return $false
        }
        $path = Join-Path $storePath ($BodyRef.ToLowerInvariant() + '.sgb')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        return -not (Test-SumiGuardAdapterReparsePoint -Path $path)
    }
    catch {
        return $false
    }
}

function Initialize-SumiGuardExecutionStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $resolvedPath = Resolve-SumiGuardExecutionStorePath -Path $Path
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'INVALID_EXECUTION_STORE_PATH'
    }
    $inspectPath = if (Test-Path -LiteralPath $resolvedPath) {
        $resolvedPath
    } else {
        Split-Path -Parent $resolvedPath
    }
    try {
        if ([string]::IsNullOrWhiteSpace($inspectPath) -or
            (Test-SumiGuardAdapterPathContainsReparsePoint -Path $inspectPath)) {
            return New-SumiGuardAdapterResult -Success $false -Status 'REPARSE_PATH_NOT_ALLOWED'
        }
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'STORE_PATH_INSPECTION_FAILED'
    }

    if (Test-Path -LiteralPath $resolvedPath) {
        try {
            $validated = Assert-SumiGuardExecutionStore -StorePath $resolvedPath
            return New-SumiGuardAdapterResult -Success $true -Status 'READY' -Properties @{
                store_path = $validated
                created = $false
                acl = Test-SumiGuardExecutionStoreAcl -StorePath $validated
            }
        }
        catch {
            return New-SumiGuardAdapterResult `
                -Success $false `
                -Status 'EXISTING_DIRECTORY_NOT_VALID_EXECUTION_STORE'
        }
    }

    try {
        [void](New-Item -ItemType Directory -Path $resolvedPath -ErrorAction Stop)
        Set-SumiGuardExecutionStoreAcl -StorePath $resolvedPath
        $acl = Test-SumiGuardExecutionStoreAcl -StorePath $resolvedPath
        if (-not $acl.valid) { throw 'Execution-store ACL validation failed.' }
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'EXECUTION_STORE_CREATE_FAILED'
    }

    try {
        $marker = [ordered]@{
            schema_version = $script:SchemaVersion
            store_id = [Guid]::NewGuid().ToString('N')
            created_at_utc = (Get-SumiGuardAdapterUtcNow).ToUniversalTime().ToString('o')
            body_provider = 'SumiGuard.LocalStore'
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $resolvedPath $script:MarkerFileName),
            ($marker | ConvertTo-Json -Compress),
            $script:Utf8Strict)
        $validated = Assert-SumiGuardExecutionStore -StorePath $resolvedPath
        return New-SumiGuardAdapterResult -Success $true -Status 'CREATED' -Properties @{
            store_path = $validated
            created = $true
            acl = $acl
        }
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'EXECUTION_STORE_MARKER_FAILED'
    }
}

function Save-SumiGuardExecutionIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
        [string]$ExecutionId = '',
        [ValidateRange(1, 2147483647)][int]$MaxItemBytes = 1MB,
        [long]$MaxTotalBytes = 250MB,
        # How long the body save waits for the LocalStore lock before giving
        # up with STORE_LOCK_TIMEOUT. This is the bounded retry: the store
        # polls the lock every 25 ms until this budget is spent.
        [ValidateRange(100, 10000)][int]$BodyLockTimeoutMilliseconds = 10000,
        # Privacy-first intent capture: hash metadata without storing raw command text.
        # Opt in to encrypted body storage only where explicitly required.
        [switch]$MetadataOnly
    )

    try {
        $executionStore = Assert-SumiGuardExecutionStore -StorePath $ExecutionStorePath
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'EXECUTION_STORE_VALIDATION_FAILED' `
            -Properties @{ monitor_action = 'CONTINUE'; automatic_deny = $false }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        $ExecutionId = [Guid]::NewGuid().ToString('N')
    }
    else {
        $parsedExecutionId = [Guid]::Empty
        if (-not [Guid]::TryParseExact($ExecutionId, 'N', [ref]$parsedExecutionId)) {
            return New-SumiGuardAdapterResult -Success $false -Status 'INVALID_EXECUTION_ID' `
                -Properties @{ monitor_action = 'CONTINUE'; automatic_deny = $false }
        }
        $ExecutionId = $ExecutionId.ToLowerInvariant()
    }

    try {
        $bodySha256 = Get-SumiGuardBodySha256 -Body $Body
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'BODY_HASH_FAILED' -Properties @{
            execution_id = $ExecutionId
            monitor_action = 'CONTINUE'
            automatic_deny = $false
        }
    }

    $bodyResult = $null
    $bodySaved = $false
    if (-not $MetadataOnly) {
        $bodyResult = SumiGuard.LocalStore\Save-SumiGuardBody `
            -StorePath $LocalStorePath `
            -Body $Body `
            -MaxItemBytes $MaxItemBytes `
            -MaxTotalBytes $MaxTotalBytes `
            -LockTimeoutMilliseconds $BodyLockTimeoutMilliseconds
        $bodySaved = [bool]$bodyResult.success
    }
    $bodyRef = if ($bodySaved) { [string]$bodyResult.body_id } else { $null }
    $contentStatus = if ($bodySaved) { 'CAPTURED_ENCRYPTED' } else { 'HASH_ONLY' }
    $collectionStatus = if ($bodySaved -or $MetadataOnly) { 'RECORDS_FOUND' } else { 'COLLECTION_FAILED' }
    $bodyReferenceStatus = if ($bodySaved) { 'AVAILABLE' } else { 'NOT_STORED' }
    $failureReason = if ($MetadataOnly -or $bodySaved) { $null } else { [string]$bodyResult.status }
    $now = (Get-SumiGuardAdapterUtcNow).ToUniversalTime()
    $event = [pscustomobject][ordered]@{
        schema_version = $script:SchemaVersion
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ExecutionIntentRecorded'
        execution_id = $ExecutionId
        occurred_at_utc = $now.ToString('o')
        observed_at_utc = $now.ToString('o')
        body_sha256 = $bodySha256
        hash_scope = 'json-decoded-string-to-utf8-without-bom-no-normalization-v1'
        content_status = $contentStatus
        collection_status = $collectionStatus
        body_ref = $bodyRef
        body_reference_status = $bodyReferenceStatus
        failure_reason_code = $failureReason
    }

    $eventSaved = $false
    try {
        Write-SumiGuardMetadataRecord -StorePath $executionStore -Kind Event -Record $event
        $eventSaved = $true
    }
    catch {
        $eventSaved = $false
    }

    if (-not $eventSaved) {
        $orphanStatus = if ($bodySaved) { 'ORPHANED_BODY' } else { 'NOT_STORED' }
        $eventFailureStatus = if ($bodySaved) {
            'EVENT_SAVE_FAILED_BODY_ORPHANED'
        }
        elseif ($MetadataOnly) {
            'EVENT_SAVE_FAILED_METADATA_ONLY'
        }
        else {
            'EVENT_AND_BODY_SAVE_FAILED'
        }
        $bodyStorageStatus = if ($bodySaved) { 'SAVED_ORPHANED' }
            elseif ($MetadataOnly) { 'OMITTED_BY_POLICY' } else { 'FAILED' }
        $notice = New-SumiGuardFailureRecord `
            -ExecutionId $ExecutionId `
            -FailedStage 'event-store' `
            -ReasonCode 'EVENT_SAVE_FAILED' `
            -BodyRef $bodyRef `
            -BodyReferenceStatus $orphanStatus `
            -ContentStatus $contentStatus
        $noticeSaved = $false
        try {
            Write-SumiGuardMetadataRecord -StorePath $executionStore -Kind Failure -Record $notice
            $noticeSaved = $true
        }
        catch {
            $noticeSaved = $false
        }
        $failureNoticeStatus = if ($noticeSaved) { 'SAVED' } else { 'FAILED' }
        return New-SumiGuardAdapterResult -Success $false -Status $eventFailureStatus -Properties @{
            execution_id = $ExecutionId
            body_storage_status = $bodyStorageStatus
            event_storage_status = 'FAILED'
            body_failure_reason_code = $failureReason
            failure_notice_status = $failureNoticeStatus
            collection_status = 'COLLECTION_FAILED'
            content_status = $contentStatus
            body_ref = $bodyRef
            monitor_action = 'CONTINUE'
            automatic_deny = $false
        }
    }

    $noticeStatus = 'NOT_REQUIRED'
    if (-not $bodySaved -and -not $MetadataOnly) {
        $notice = New-SumiGuardFailureRecord `
            -ExecutionId $ExecutionId `
            -FailedStage 'body-store' `
            -ReasonCode ([string]$bodyResult.status) `
            -BodyRef $null `
            -BodyReferenceStatus 'NOT_STORED' `
            -ContentStatus $contentStatus
        try {
            Write-SumiGuardMetadataRecord -StorePath $executionStore -Kind Failure -Record $notice
            $noticeStatus = 'SAVED'
        }
        catch {
            $noticeStatus = 'FAILED'
        }
    }

    $adapterStatus = if ($MetadataOnly) {
        'EVENT_SAVED_METADATA_ONLY'
    }
    elseif ($bodySaved) {
        'EVENT_AND_BODY_SAVED'
    }
    else {
        'EVENT_SAVED_BODY_COLLECTION_FAILED'
    }
    $bodyStorageStatus = if ($MetadataOnly) { 'OMITTED_BY_POLICY' }
        elseif ($bodySaved) { 'SAVED' } else { 'FAILED' }
    return New-SumiGuardAdapterResult -Success ($bodySaved -or [bool]$MetadataOnly) -Status $adapterStatus -Properties @{
        execution_id = $ExecutionId
        event_storage_status = 'SAVED'
        body_storage_status = $bodyStorageStatus
        body_failure_reason_code = $failureReason
        failure_notice_status = $noticeStatus
        collection_status = $collectionStatus
        content_status = $contentStatus
        body_ref = $bodyRef
        body_sha256 = $bodySha256
        monitor_action = 'CONTINUE'
        automatic_deny = $false
    }
}

function Get-SumiGuardExecutionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [string]$ExecutionId = ''
    )

    try {
        $store = Assert-SumiGuardExecutionStore -StorePath $ExecutionStorePath
        $lock = Enter-SumiGuardExecutionStoreLock -StorePath $store
        try {
            $events = @(Read-SumiGuardMetadataRecordsUnsafe -StorePath $store -Kind Event)
            $retention = @(Read-SumiGuardMetadataRecordsUnsafe -StorePath $store -Kind Retention)
        }
        finally {
            $lock.Dispose()
        }
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'METADATA_READ_FAILED' -Properties @{
            records = @()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExecutionId)) {
        $events = @($events | Where-Object { $_.execution_id -ceq $ExecutionId.ToLowerInvariant() })
    }
    $expiredRefs = @{}
    foreach ($item in $retention) {
        if ($null -ne $item.body_ref) {
            $expiredRefs[[string]$item.body_ref] = $true
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($event in $events) {
        $ref = if ($null -ne $event.body_ref) { [string]$event.body_ref } else { $null }
        $referenceStatus = 'NOT_STORED'
        $referenceCollectionStatus = [string]$event.collection_status
        if ($null -ne $ref) {
            if ($expiredRefs.ContainsKey($ref)) {
                $referenceStatus = 'DELETED_BY_RETENTION'
                $referenceCollectionStatus = 'RECORDS_FOUND'
            }
            elseif (Test-SumiGuardBodyReferenceExists -LocalStorePath $LocalStorePath -BodyRef $ref) {
                $referenceStatus = 'AVAILABLE'
                $referenceCollectionStatus = 'RECORDS_FOUND'
            }
            else {
                $referenceStatus = 'REFERENCE_MISSING'
                $referenceCollectionStatus = 'COLLECTION_FAILED'
            }
        }
        $records.Add([pscustomobject][ordered]@{
            schema_version = $event.schema_version
            record_id = $event.record_id
            record_type = $event.record_type
            execution_id = $event.execution_id
            occurred_at_utc = $event.occurred_at_utc
            observed_at_utc = $event.observed_at_utc
            body_sha256 = $event.body_sha256
            hash_scope = $event.hash_scope
            content_status = $event.content_status
            collection_status = $event.collection_status
            body_ref = $ref
            body_reference_status = $referenceStatus
            body_reference_collection_status = $referenceCollectionStatus
            failure_reason_code = $event.failure_reason_code
        })
    }
    return New-SumiGuardAdapterResult -Success $true -Status 'RECORDS_READ' -Properties @{
        record_count = $records.Count
        records = $records.ToArray()
        body_included = $false
    }
}

function Get-SumiGuardCollectionFailureNotice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [string]$ExecutionId = ''
    )

    try {
        $store = Assert-SumiGuardExecutionStore -StorePath $ExecutionStorePath
        $lock = Enter-SumiGuardExecutionStoreLock -StorePath $store
        try {
            $notices = @(Read-SumiGuardMetadataRecordsUnsafe -StorePath $store -Kind Failure)
        }
        finally {
            $lock.Dispose()
        }
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'FAILURE_NOTICE_READ_FAILED' `
            -Properties @{ notices = @() }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionId)) {
        $notices = @($notices | Where-Object { $_.execution_id -ceq $ExecutionId.ToLowerInvariant() })
    }
    return New-SumiGuardAdapterResult -Success $true -Status 'FAILURE_NOTICES_READ' -Properties @{
        notice_count = $notices.Count
        notices = $notices
        body_included = $false
    }
}

function Read-SumiGuardExecutionBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [Parameter(Mandatory = $true)][string]$ExecutionId
    )

    $recordResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $ExecutionStorePath `
        -LocalStorePath $LocalStorePath `
        -ExecutionId $ExecutionId
    if (-not $recordResult.success) {
        return New-SumiGuardAdapterResult -Success $false -Status 'METADATA_READ_FAILED'
    }
    if ($recordResult.record_count -eq 0) {
        return New-SumiGuardAdapterResult -Success $false -Status 'EXECUTION_NOT_FOUND'
    }
    if ($recordResult.record_count -ne 1) {
        return New-SumiGuardAdapterResult -Success $false -Status 'DUPLICATE_EXECUTION_ID'
    }
    $record = $recordResult.records[0]
    switch ([string]$record.body_reference_status) {
        'DELETED_BY_RETENTION' {
            return New-SumiGuardAdapterResult -Success $false -Status 'BODY_DELETED_BY_RETENTION' `
                -Properties @{ execution_id = $record.execution_id; body_included = $false }
        }
        'NOT_STORED' {
            return New-SumiGuardAdapterResult -Success $false -Status 'BODY_NOT_CAPTURED' -Properties @{
                execution_id = $record.execution_id
                collection_status = $record.collection_status
                failure_reason_code = $record.failure_reason_code
                body_included = $false
            }
        }
        'REFERENCE_MISSING' {
            return New-SumiGuardAdapterResult -Success $false -Status 'BODY_REFERENCE_MISSING' -Properties @{
                execution_id = $record.execution_id
                collection_status = 'COLLECTION_FAILED'
                body_included = $false
            }
        }
    }

    $bodyResult = SumiGuard.LocalStore\Get-SumiGuardBody `
        -StorePath $LocalStorePath `
        -BodyId $record.body_ref
    if (-not $bodyResult.success) {
        return New-SumiGuardAdapterResult -Success $false -Status 'BODY_READ_FAILED' -Properties @{
            execution_id = $record.execution_id
            local_store_status = $bodyResult.status
            collection_status = 'COLLECTION_FAILED'
            body_included = $false
        }
    }
    return New-SumiGuardAdapterResult -Success $true -Status 'BODY_DECRYPTED' -Properties @{
        execution_id = $record.execution_id
        body_ref = $record.body_ref
        body = $bodyResult.body
        body_sha256 = $record.body_sha256
        body_included = $true
    }
}

function Invoke-SumiGuardExecutionRetentionCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
        [Parameter(Mandatory = $true)][string]$LocalStorePath,
        [ValidateRange(1, 36500)][int]$RetentionDays = 30
    )

    $before = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $ExecutionStorePath `
        -LocalStorePath $LocalStorePath
    if (-not $before.success) {
        return New-SumiGuardAdapterResult -Success $false -Status 'METADATA_READ_FAILED'
    }
    $cutoff = (Get-SumiGuardAdapterUtcNow).ToUniversalTime().AddDays(-$RetentionDays)
    $availableBefore = @($before.records | Where-Object {
        $occurredAt = [DateTimeOffset]::MinValue
        $_.body_reference_status -ceq 'AVAILABLE' -and
            $null -ne $_.body_ref -and
            [DateTimeOffset]::TryParse([string]$_.occurred_at_utc, [ref]$occurredAt) -and
            $occurredAt -lt $cutoff
    })
    if (-not $PSCmdlet.ShouldProcess($LocalStorePath, 'Remove expired SUMI Guard bodies')) {
        return New-SumiGuardAdapterResult -Success $true -Status 'RETENTION_CLEANUP_NOT_RUN' `
            -Properties @{ execution_records_preserved = $true; body_included = $false }
    }
    $cleanup = SumiGuard.LocalStore\Remove-SumiGuardExpiredBody `
        -StorePath $LocalStorePath `
        -RetentionDays $RetentionDays `
        -Confirm:$false
    $store = $null
    try {
        $store = Assert-SumiGuardExecutionStore -StorePath $ExecutionStorePath
    }
    catch {
        return New-SumiGuardAdapterResult -Success $false -Status 'EXECUTION_STORE_VALIDATION_FAILED'
    }

    $tombstoneCount = 0
    $tombstoneFailureCount = 0
    $deletedBodyCount = 0
    if ($cleanup.PSObject.Properties.Name -contains 'deleted_count') {
        $deletedBodyCount = [int]$cleanup.deleted_count
    }
    if ($deletedBodyCount -gt 0) {
        foreach ($record in $availableBefore) {
            if (Test-SumiGuardBodyReferenceExists `
                -LocalStorePath $LocalStorePath `
                -BodyRef ([string]$record.body_ref)) {
                continue
            }
            $tombstone = [pscustomobject][ordered]@{
                schema_version = $script:SchemaVersion
                record_id = [Guid]::NewGuid().ToString('N')
                record_type = 'BodyRetentionExpired'
                execution_id = $record.execution_id
                occurred_at_utc = (Get-SumiGuardAdapterUtcNow).ToUniversalTime().ToString('o')
                collection_status = 'RECORDS_FOUND'
                content_status = 'CONTENT_UNKNOWN'
                body_ref = $record.body_ref
                body_reference_status = 'DELETED_BY_RETENTION'
            }
            try {
                Write-SumiGuardMetadataRecord -StorePath $store -Kind Retention -Record $tombstone
                $tombstoneCount++
            }
            catch {
                $tombstoneFailureCount++
            }
        }
    }

    $success = [bool]$cleanup.success -and $tombstoneFailureCount -eq 0
    $cleanupStatus = if ($success) {
        'RETENTION_CLEANUP_COMPLETED'
    }
    else {
        'RETENTION_CLEANUP_PARTIAL'
    }
    return New-SumiGuardAdapterResult -Success $success -Status $cleanupStatus -Properties @{
        local_store_cleanup_status = $cleanup.status
        deleted_body_count = $deletedBodyCount
        retention_tombstone_count = $tombstoneCount
        retention_tombstone_failure_count = $tombstoneFailureCount
        execution_records_preserved = $true
        body_included = $false
    }
}

Export-ModuleMember -Function @(
    'Initialize-SumiGuardExecutionStore',
    'Save-SumiGuardExecutionIntent',
    'Get-SumiGuardExecutionRecord',
    'Get-SumiGuardCollectionFailureNotice',
    'Read-SumiGuardExecutionBody',
    'Invoke-SumiGuardExecutionRetentionCleanup'
)
