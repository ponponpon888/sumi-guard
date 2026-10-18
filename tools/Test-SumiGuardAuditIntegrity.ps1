# Audit metadata verifier. Does not create or change files.
# Digest comparison requires a baseline kept independently of the audited store.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Execution', 'Assessment')][string]$StoreKind,
    [Parameter(Mandatory = $true)][string]$StorePath,
    [ValidateSet('Snapshot', 'Compare')][string]$Action = 'Snapshot',
    [string]$BaselinePath,
    [ValidateRange(100, 5000)][int]$LockTimeoutMilliseconds = 2000
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:MaximumAuditedFileBytes = 16MB

function Test-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split(
        [char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'REPARSE_PATH_REJECTED'
            }
        }
    }
    return $full
}

function Get-RequiredField {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Name)
    if ($Record.PSObject.Properties.Name -cnotcontains $Name) {
        throw 'RECORD_INVALID'
    }
    return $Record.$Name
}

function Test-AuditRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][hashtable]$Seen,
        [Parameter(Mandatory = $true)][hashtable]$BodyRefs,
        [Parameter(Mandatory = $true)][hashtable]$ExpiredRefs
    )
    if ($null -eq $Record -or $Record -is [array]) { throw 'RECORD_INVALID' }
    if ((Get-RequiredField -Record $Record -Name 'schema_version') -isnot [int] -or
        [int]$Record.schema_version -ne 1) { throw 'RECORD_INVALID' }
    foreach ($field in @('body', 'command', 'command_text', 'source_excerpt', 'exception_message')) {
        if ($Record.PSObject.Properties.Name -ccontains $field) {
            throw 'UNEXPECTED_CONTENT_FIELD'
        }
    }
    $types = @{
        'events.ndjson' = 'ExecutionIntentRecorded'
        'failures.ndjson' = 'CollectionFailureNotice'
        'retention.ndjson' = 'BodyRetentionExpired'
        'assessments.ndjson' = 'ExecutionSafetyAssessment'
    }
    if ((Get-RequiredField -Record $Record -Name 'record_type') -cne $types[$FileName]) {
        throw 'RECORD_INVALID'
    }
    $idField = if ($FileName -ceq 'assessments.ndjson') { 'assessment_id' } else { 'record_id' }
    $recordId = Get-RequiredField $Record $idField
    if ($recordId -isnot [string] -or $recordId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'RECORD_INVALID'
    }
    if ($Seen.ContainsKey($recordId)) { throw 'RECORD_DUPLICATE' }
    $Seen[$recordId] = $true
    if ($FileName -ceq 'assessments.ndjson') {
        if ((Get-RequiredField -Record $Record -Name 'content_included') -ne $false -or
            (Get-RequiredField -Record $Record -Name 'source_excerpt_included') -ne $false -or
            (Get-RequiredField -Record $Record -Name 'assessment_status') -cnotin @(
                'DETECTED', 'NO_DETECTION', 'UNASSESSABLE', 'EVALUATION_FAILED')) {
            throw 'RECORD_INVALID'
        }
        if ($null -ne $Record.execution_id -and
            ([string]$Record.execution_id -cnotmatch '^[0-9a-f]{32}$')) {
            throw 'RECORD_INVALID'
        }
        return
    }
    $executionId = Get-RequiredField -Record $Record -Name 'execution_id'
    if ($executionId -isnot [string] -or $executionId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'RECORD_INVALID'
    }
    if ($FileName -ceq 'events.ndjson') {
        $bodyHash = Get-RequiredField -Record $Record -Name 'body_sha256'
        if ($bodyHash -isnot [string] -or $bodyHash -cnotmatch '^[0-9a-f]{64}$') {
            throw 'RECORD_INVALID'
        }
        $bodyRef = Get-RequiredField -Record $Record -Name 'body_ref'
        if ($null -ne $bodyRef) {
            if ($bodyRef -isnot [string] -or $bodyRef -cnotmatch '^[0-9a-f]{32}$') {
                throw 'RECORD_INVALID'
            }
            $BodyRefs[$bodyRef] = $true
        }
    }
    if ($FileName -ceq 'retention.ndjson') {
        $bodyRef = Get-RequiredField -Record $Record -Name 'body_ref'
        if ($bodyRef -isnot [string] -or $bodyRef -cnotmatch '^[0-9a-f]{32}$') {
            throw 'RECORD_INVALID'
        }
        $ExpiredRefs[$bodyRef] = $true
    }
}

function Read-AuditFile {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Seen,
        [Parameter(Mandatory = $true)][hashtable]$BodyRefs,
        [Parameter(Mandatory = $true)][hashtable]$ExpiredRefs
    )
    $path = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject][ordered]@{
            name = $Name; present = $false; length = 0; sha256 = $null; record_count = 0
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'AUDIT_FILE_INVALID' }
    $null = Test-NoReparsePath -Path $path
    $stream = $null
    [byte[]]$bytes = $null
    $sha = $null
    try {
        $stream = New-Object IO.FileStream(
            $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt $script:MaximumAuditedFileBytes) { throw 'AUDIT_FILE_TOO_LARGE' }
        $length = [int]$stream.Length
        $bytes = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $got = $stream.Read($bytes, $offset, $length - $offset)
            if ($got -le 0) { throw 'AUDIT_FILE_CHANGED' }
            $offset += $got
        }
        if ($stream.Length -ne $length) { throw 'AUDIT_FILE_CHANGED' }
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        $count = 0
        if ($length -gt 0) {
            if ($bytes[$length - 1] -ne 10) { throw 'AUDIT_FILE_INCOMPLETE' }
            if ($length -ge 3 -and $bytes[0] -eq 239 -and
                $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
                throw 'AUDIT_FILE_ENCODING_INVALID'
            }
            try { $data = $script:Utf8.GetString($bytes) }
            catch { throw 'AUDIT_FILE_ENCODING_INVALID' }
            $lines = $data.Split([char]10)
            for ($i = 0; $i -lt ($lines.Length - 1); $i++) {
                $line = $lines[$i].TrimEnd([char]13)
                if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 131072) {
                    throw 'AUDIT_FILE_FORMAT_INVALID'
                }
                try { $record = $line | ConvertFrom-Json -ErrorAction Stop }
                catch { throw 'AUDIT_FILE_FORMAT_INVALID' }
                Test-AuditRecord -Record $record -FileName $Name -Seen $Seen -BodyRefs $BodyRefs -ExpiredRefs $ExpiredRefs
                $count++
            }
        }
        return [pscustomobject][ordered]@{
            name = $Name
            present = $true
            length = $length
            sha256 = $digest
            record_count = $count
        }
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

$status = 'VALIDATION_FAILED'
$failureCode = $null
$exitCode = 2
$verifiedFiles = @()
$markerSha256 = $null
$lock = $null
try {
    $store = [IO.Path]::GetFullPath($StorePath).TrimEnd([char[]]@('\', '/'))
    $root = [IO.Path]::GetPathRoot($store).TrimEnd([char[]]@('\', '/'))
    if ([string]::IsNullOrWhiteSpace($store) -or
        [string]::Equals($store, $root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $store -PathType Container)) {
        throw 'STORE_INVALID'
    }
    $null = Test-NoReparsePath -Path $store
    $markerName = if ($StoreKind -ceq 'Execution') {
        '.sumi-guard-execution-store.json'
    } else { '.sumi-guard-assessment-store.json' }
    $lockName = if ($StoreKind -ceq 'Execution') {
        '.sumi-guard-execution-store.lock'
    } else { '.sumi-guard-assessment-store.lock' }
    $names = @(if ($StoreKind -ceq 'Execution') {
        'events.ndjson'; 'failures.ndjson'; 'retention.ndjson'
    } else { 'assessments.ndjson' })
    $markerPath = Join-Path $store $markerName
    $lockPath = Join-Path $store $lockName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'MARKER_INVALID' }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'LOCK_MISSING' }
    $null = Test-NoReparsePath -Path $markerPath
    $null = Test-NoReparsePath -Path $lockPath
    try {
        if ((Get-Item -LiteralPath $markerPath -Force).Length -gt 65536) { throw 'MARKER_INVALID' }
        $marker = [IO.File]::ReadAllText($markerPath, $script:Utf8) | ConvertFrom-Json -ErrorAction Stop
        $markerId = [Guid]::Empty
        if ([int]$marker.schema_version -ne 1 -or
            -not [Guid]::TryParseExact([string]$marker.store_id, 'N', [ref]$markerId)) {
            throw 'MARKER_INVALID'
        }
        if ($StoreKind -ceq 'Assessment' -and
            [string]$marker.store_type -cne 'SumiGuard.AssessmentStore') {
            throw 'MARKER_INVALID'
        }
        $markerSha256 = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch { throw 'MARKER_INVALID' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($null -eq $lock -and $clock.ElapsedMilliseconds -lt $LockTimeoutMilliseconds) {
        try {
            $lock = New-Object IO.FileStream(
                $lockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        }
        catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    }
    if ($null -eq $lock) { throw 'LOCK_UNAVAILABLE' }

    $seen = @{}
    $bodyRefs = @{}
    $expiredRefs = @{}
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        $item = Read-AuditFile -Directory $store -Name $name -Seen $seen -BodyRefs $bodyRefs -ExpiredRefs $expiredRefs
        $list.Add($item)
    }
    foreach ($bodyRef in $expiredRefs.Keys) {
        if (-not $bodyRefs.ContainsKey($bodyRef)) { throw 'RETENTION_REFERENCE_MISSING' }
    }
    $verifiedFiles = $list.ToArray()
    if ($Action -ceq 'Snapshot') {
        if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) { throw 'UNEXPECTED_BASELINE' }
        $status = 'STRUCTURE_VALID_UNANCHORED'
        $exitCode = 0
    }
    else {
        if ([string]::IsNullOrWhiteSpace($BaselinePath)) { throw 'BASELINE_REQUIRED' }
        $baselineFull = [IO.Path]::GetFullPath($BaselinePath)
        if ($baselineFull.StartsWith(
            $store + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
            throw 'BASELINE_INSIDE_STORE'
        }
        if (-not (Test-Path -LiteralPath $baselineFull -PathType Leaf)) { throw 'BASELINE_INVALID' }
        $null = Test-NoReparsePath -Path $baselineFull
        try {
            if ((Get-Item -LiteralPath $baselineFull -Force).Length -gt 65536) {
                throw 'BASELINE_INVALID'
            }
            $baseline = [IO.File]::ReadAllText($baselineFull, $script:Utf8) | ConvertFrom-Json -ErrorAction Stop
            if ([int]$baseline.schema_version -ne 1 -or
                [string]$baseline.store_kind -cne $StoreKind -or
                [string]$baseline.marker_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [string]$baseline.status -cne 'STRUCTURE_VALID_UNANCHORED' -or
                $baseline.success -ne $true -or @($baseline.files).Count -ne $names.Count) {
                throw 'BASELINE_INVALID'
            }
            for ($i = 0; $i -lt $names.Count; $i++) {
                $entry = $baseline.files[$i]
                if ([string]$entry.name -cne $names[$i] -or
                    $entry.present -isnot [bool] -or
                    [long]$entry.length -lt 0 -or
                    [int]$entry.record_count -lt 0 -or
                    ($entry.present -and [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$')) {
                    throw 'BASELINE_INVALID'
                }
            }
        }
        catch { throw 'BASELINE_INVALID' }
        $equal = ([string]$baseline.marker_sha256 -ceq [string]$markerSha256)
        for ($i = 0; $i -lt $names.Count; $i++) {
            $a = $verifiedFiles[$i]
            $b = $baseline.files[$i]
            if ($a.present -ne $b.present -or
                [long]$a.length -ne [long]$b.length -or
                [string]$a.sha256 -cne [string]$b.sha256 -or
                [int]$a.record_count -ne [int]$b.record_count) {
                $equal = $false
            }
        }
        $status = if ($equal) { 'MATCHES_SUPPLIED_BASELINE' } else { 'BASELINE_MISMATCH' }
        $exitCode = if ($equal) { 0 } else { 1 }
    }
}
catch {
    $known = @(
        'REPARSE_PATH_REJECTED', 'RECORD_INVALID', 'RECORD_DUPLICATE',
        'UNEXPECTED_CONTENT_FIELD', 'AUDIT_FILE_INVALID', 'AUDIT_FILE_TOO_LARGE',
        'AUDIT_FILE_CHANGED', 'AUDIT_FILE_INCOMPLETE', 'AUDIT_FILE_ENCODING_INVALID',
        'AUDIT_FILE_FORMAT_INVALID', 'STORE_INVALID', 'MARKER_INVALID',
        'LOCK_MISSING', 'LOCK_UNAVAILABLE', 'RETENTION_REFERENCE_MISSING',
        'UNEXPECTED_BASELINE', 'BASELINE_REQUIRED', 'BASELINE_INVALID',
        'BASELINE_INSIDE_STORE'
    )
    $failureCode = if ($known -ccontains [string]$_.Exception.Message) {
        [string]$_.Exception.Message
    } else { 'READ_VALIDATION_FAILED' }
    $status = 'VALIDATION_FAILED'
    $exitCode = 2
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
[pscustomobject][ordered]@{
    schema_version = 1
    store_kind = $StoreKind
    marker_sha256 = $markerSha256
    action = $Action
    status = $status
    success = ($exitCode -eq 0)
    baseline_compared = ($Action -ceq 'Compare' -and $exitCode -ne 2)
    failure_code = $failureCode
    files = @($verifiedFiles)
    read_only = $true
    existing_audit_files_modified = $false
    decrypted_bodies_read = $false
} | ConvertTo-Json -Compress -Depth 6
exit $exitCode
