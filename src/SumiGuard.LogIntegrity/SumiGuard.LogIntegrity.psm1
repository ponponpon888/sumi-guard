Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Prefix checkpoints for the append-only NDJSON metadata logs.
#
# A checkpoint is the plain SHA-256 of a log's bytes up to and including its
# last complete line, plus that byte and line count. The logs are only ever
# appended to, so a later copy of the same log must start with exactly those
# bytes. Any edit, deletion, reordering or insertion inside the covered prefix
# changes the digest; a log shorter than the covered prefix was truncated or
# replaced. Lines appended after the checkpoint are reported, not judged.
#
# What a checkpoint does not do: it is unkeyed, so anyone who can rewrite the
# log can also compute a matching checkpoint. It only shows tampering when the
# checkpoint itself is kept somewhere the log's writer cannot change. This
# module never stores a checkpoint, and it never reads, returns or prints log
# content or paths. See docs/41-log-integrity-checkpoint.md.
#
# Reads do not take the store lock. The handle is opened with
# FileShare.ReadWrite|Delete so a hook that is appending (ExecutionAdapter) or
# replacing the file (AssessmentStore) is never made to wait or fail because a
# check is running. Both writers keep the existing bytes unchanged, so the
# prefix being hashed is stable while they write.

$script:CheckpointSchema = 'sumi-guard-log-checkpoint/1'
$script:CheckpointProperties = @(
    'schema', 'log_kind', 'covered_bytes', 'covered_lines', 'sha256', 'created_at_utc')
$script:LogDefinitions = @{
    Event = @{ file = 'events.ndjson'; lock = '.sumi-guard-execution-store.lock' }
    Failure = @{ file = 'failures.ndjson'; lock = '.sumi-guard-execution-store.lock' }
    Retention = @{ file = 'retention.ndjson'; lock = '.sumi-guard-execution-store.lock' }
    Assessment = @{ file = 'assessments.ndjson'; lock = '.sumi-guard-assessment-store.lock' }
}
$script:LogKinds = @('Event', 'Failure', 'Retention', 'Assessment')
$script:BufferBytes = 65536

function ConvertTo-SumiGuardLogIntegrityResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Status,
        [Collections.IDictionary]$Properties = @{}
    )

    $result = [ordered]@{
        success = $Success
        status = $Status
    }
    foreach ($key in $Properties.Keys) {
        $result[$key] = $Properties[$key]
    }
    $result['content_included'] = $false
    return [pscustomobject]$result
}

# The fixed code travels in Data so that no exception message, path or log
# byte can reach a result.
function ConvertTo-SumiGuardLogIntegrityError {
    param([Parameter(Mandatory = $true)][string]$Code)

    $exception = [InvalidOperationException]::new('SUMI Guard log integrity failure.')
    $exception.Data['SumiGuardLogIntegrityCode'] = $Code
    return $exception
}

function Get-SumiGuardLogIntegrityErrorCode {
    param(
        [Parameter(Mandatory = $true)]$Exception,
        [Parameter(Mandatory = $true)][string]$DefaultCode
    )

    $current = $Exception
    for ($level = 0; $level -le 3 -and $null -ne $current; $level++) {
        if ($current.Data -and $current.Data.Contains('SumiGuardLogIntegrityCode')) {
            return [string]$current.Data['SumiGuardLogIntegrityCode']
        }
        $current = $current.InnerException
    }
    return $DefaultCode
}

function Test-SumiGuardLogIntegritySharingViolation {
    param([Parameter(Mandatory = $true)]$Exception)

    $current = $Exception
    for ($level = 0; $level -le 3 -and $null -ne $current; $level++) {
        $hex = ([BitConverter]::ToUInt32(
            [BitConverter]::GetBytes([int]$current.HResult), 0)).ToString(
                'X8', [Globalization.CultureInfo]::InvariantCulture)
        if ($hex -ceq '80070020' -or $hex -ceq '80070021') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-SumiGuardLogIntegrityReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $remainder = $fullPath.Substring($root.Length)
    $current = $root
    foreach ($segment in $remainder.Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

# Resolves the log of one kind inside a store directory. The store must
# already carry its writer's lock file; nothing here creates files.
function Get-SumiGuardLogIntegrityTarget {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($StorePath)) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'STORE_NOT_FOUND')
    }
    $definition = $script:LogDefinitions[$Kind]
    $storeFullPath = [IO.Path]::GetFullPath($StorePath)
    $lockPath = Join-Path $storeFullPath $definition.lock
    $logPath = Join-Path $storeFullPath $definition.file

    if (Test-SumiGuardLogIntegrityReparsePath -Path $storeFullPath) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'REPARSE_PATH_NOT_ALLOWED')
    }
    if (-not (Test-Path -LiteralPath $storeFullPath -PathType Container)) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'STORE_NOT_FOUND')
    }
    if (Test-SumiGuardLogIntegrityReparsePath -Path $lockPath) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'REPARSE_PATH_NOT_ALLOWED')
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'STORE_LOCK_MISSING')
    }
    if (Test-SumiGuardLogIntegrityReparsePath -Path $logPath) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'REPARSE_PATH_NOT_ALLOWED')
    }
    $exists = Test-Path -LiteralPath $logPath
    if ($exists -and -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw (ConvertTo-SumiGuardLogIntegrityError -Code 'LOG_NOT_A_FILE')
    }
    return [pscustomobject]@{
        log_path = $logPath
        exists = $exists
    }
}

function Open-SumiGuardLogForRead {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return New-Object IO.FileStream(
                $Path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                $share,
                $script:BufferBytes)
        }
        catch {
            if (-not (Test-SumiGuardLogIntegritySharingViolation -Exception $_.Exception)) {
                throw (ConvertTo-SumiGuardLogIntegrityError -Code 'READ_FAILED')
            }
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) {
                throw (ConvertTo-SumiGuardLogIntegrityError -Code 'READ_TIMEOUT')
            }
            Start-Sleep -Milliseconds ([Math]::Min(25, $remaining))
        }
    }
}

# Returns the index of the last LF (0x0A) before $Length, or -1.
function Find-SumiGuardLastLineFeed {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][long]$Length
    )

    [byte[]]$buffer = New-Object byte[] $script:BufferBytes
    $end = $Length
    while ($end -gt 0) {
        $start = [Math]::Max([long]0, $end - $buffer.Length)
        $count = [int]($end - $start)
        [void]$Stream.Seek($start, [IO.SeekOrigin]::Begin)
        $read = 0
        while ($read -lt $count) {
            $chunk = $Stream.Read($buffer, $read, $count - $read)
            if ($chunk -le 0) {
                throw (ConvertTo-SumiGuardLogIntegrityError -Code 'READ_FAILED')
            }
            $read += $chunk
        }
        for ($index = $count - 1; $index -ge 0; $index--) {
            if ($buffer[$index] -eq 10) {
                return $start + $index
            }
        }
        $end = $start
    }
    return [long]-1
}

# SHA-256 of the first $Length bytes and the number of LF bytes in them.
function Get-SumiGuardLogPrefixDigest {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][long]$Length
    )

    [byte[]]$buffer = New-Object byte[] $script:BufferBytes
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [void]$Stream.Seek(0, [IO.SeekOrigin]::Begin)
        $remaining = $Length
        [long]$lines = 0
        while ($remaining -gt 0) {
            $want = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $Stream.Read($buffer, 0, $want)
            if ($read -le 0) {
                throw (ConvertTo-SumiGuardLogIntegrityError -Code 'READ_FAILED')
            }
            for ($index = 0; $index -lt $read; $index++) {
                if ($buffer[$index] -eq 10) { $lines++ }
            }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $remaining -= $read
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $hex = ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
        return [pscustomobject]@{
            sha256 = $hex
            lines = $lines
        }
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-SumiGuardCheckpointInteger {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32]) {
        return [long]$Value
    }
    if ($Value -is [uint64] -and $Value -le [uint64][long]::MaxValue) {
        return [long]$Value
    }
    if (($Value -is [double] -or $Value -is [decimal]) -and
        $Value -ge 0 -and $Value -le 9007199254740991 -and
        [Math]::Floor($Value) -eq $Value) {
        return [long]$Value
    }
    return $null
}

# Accepts the object Get-SumiGuardLogCheckpoint returned, or the same object
# after a ConvertTo-Json / ConvertFrom-Json round trip. Anything else is
# refused rather than interpreted.
function ConvertFrom-SumiGuardLogCheckpoint {
    param([AllowNull()]$Checkpoint)

    if ($null -eq $Checkpoint -or $Checkpoint -isnot [pscustomobject]) {
        return $null
    }
    $names = @($Checkpoint.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $names) {
        if ($script:CheckpointProperties -cnotcontains $name) { return $null }
    }
    foreach ($required in @('schema', 'log_kind', 'covered_bytes', 'covered_lines', 'sha256')) {
        if ($names -cnotcontains $required) { return $null }
    }
    if ($Checkpoint.schema -isnot [string] -or $Checkpoint.schema -cne $script:CheckpointSchema) {
        return $null
    }
    if ($Checkpoint.log_kind -isnot [string] -or $script:LogKinds -cnotcontains $Checkpoint.log_kind) {
        return $null
    }
    if ($Checkpoint.sha256 -isnot [string] -or $Checkpoint.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        return $null
    }
    $bytes = ConvertTo-SumiGuardCheckpointInteger -Value $Checkpoint.covered_bytes
    $lines = ConvertTo-SumiGuardCheckpointInteger -Value $Checkpoint.covered_lines
    if ($null -eq $bytes -or $null -eq $lines) { return $null }
    if ($bytes -lt 0 -or $lines -lt 0 -or $lines -gt $bytes) { return $null }
    if (($bytes -eq 0) -ne ($lines -eq 0)) { return $null }
    return [pscustomobject]@{
        log_kind = [string]$Checkpoint.log_kind
        covered_bytes = [long]$bytes
        covered_lines = [long]$lines
        sha256 = [string]$Checkpoint.sha256
    }
}

function Get-SumiGuardLogCheckpoint {
    <#
    .SYNOPSIS
    Returns a prefix checkpoint for one NDJSON log in a SUMI Guard store.
    .DESCRIPTION
    Reads the log without taking the store lock and returns the plain SHA-256,
    byte count and line count of its bytes up to the last complete line. The
    checkpoint is returned, not stored: keep it outside the store, or it proves
    nothing. No log content or path is returned.
    .PARAMETER StorePath
    The store directory. It must already contain its writer's lock file.
    .PARAMETER Kind
    Event, Failure, Retention (execution store) or Assessment (assessment store).
    .PARAMETER ReadTimeoutMilliseconds
    How long to retry opening the log while a sharing violation persists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Event', 'Failure', 'Retention', 'Assessment')]
        [string]$Kind,
        [ValidateRange(100, 60000)][int]$ReadTimeoutMilliseconds = 2000
    )

    $stream = $null
    try {
        $target = Get-SumiGuardLogIntegrityTarget -StorePath $StorePath -Kind $Kind
        $coveredBytes = [long]0
        $currentBytes = [long]0
        $digest = $null
        if ($target.exists) {
            $stream = Open-SumiGuardLogForRead -Path $target.log_path `
                -TimeoutMilliseconds $ReadTimeoutMilliseconds
            # Snapshot the length once. Bytes appended after this point, and
            # an unfinished last line, are left for the next checkpoint.
            $currentBytes = $stream.Length
            $lastLineFeed = Find-SumiGuardLastLineFeed -Stream $stream -Length $currentBytes
            $coveredBytes = $lastLineFeed + 1
            $digest = Get-SumiGuardLogPrefixDigest -Stream $stream -Length $coveredBytes
        }
        else {
            $digest = Get-SumiGuardLogPrefixDigest -Stream ([IO.MemoryStream]::new()) -Length 0
        }
        $checkpoint = [pscustomobject][ordered]@{
            schema = $script:CheckpointSchema
            log_kind = $Kind
            covered_bytes = $coveredBytes
            covered_lines = [long]$digest.lines
            sha256 = $digest.sha256
            created_at_utc = [DateTimeOffset]::UtcNow.ToString(
                'yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
        }
        return ConvertTo-SumiGuardLogIntegrityResult -Success $true -Status 'CHECKPOINT_CREATED' -Properties ([ordered]@{
            log_present = [bool]$target.exists
            incomplete_tail_bytes = [long]($currentBytes - $coveredBytes)
            checkpoint = $checkpoint
        })
    }
    catch {
        return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status (
            Get-SumiGuardLogIntegrityErrorCode -Exception $_.Exception -DefaultCode 'CHECKPOINT_FAILED')
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# success is $true only for INTACT, so a caller that reads success alone can
# never take a changed log for an intact one. verification_completed tells a
# finding (MODIFIED, TRUNCATED) apart from a check that could not run.
function Test-SumiGuardLogCheckpoint {
    <#
    .SYNOPSIS
    Checks that a SUMI Guard NDJSON log still starts with a checkpoint's bytes.
    .DESCRIPTION
    Returns INTACT (success = $true), MODIFIED or TRUNCATED, or a fixed error
    code with verification_completed = $false. The log kind comes from the
    checkpoint. No log content or path is returned.
    .PARAMETER StorePath
    The store directory the checkpoint was taken from.
    .PARAMETER Checkpoint
    The checkpoint object from Get-SumiGuardLogCheckpoint, directly or after a
    ConvertTo-Json / ConvertFrom-Json round trip.
    .PARAMETER ReadTimeoutMilliseconds
    How long to retry opening the log while a sharing violation persists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][AllowNull()]$Checkpoint,
        [ValidateRange(100, 60000)][int]$ReadTimeoutMilliseconds = 2000
    )

    $stream = $null
    try {
        $expected = ConvertFrom-SumiGuardLogCheckpoint -Checkpoint $Checkpoint
        if ($null -eq $expected) {
            return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status 'CHECKPOINT_INVALID' -Properties @{
                verification_completed = $false
            }
        }
        $target = Get-SumiGuardLogIntegrityTarget -StorePath $StorePath -Kind $expected.log_kind
        $common = [ordered]@{
            verification_completed = $true
            log_kind = $expected.log_kind
            covered_bytes = $expected.covered_bytes
            covered_lines = $expected.covered_lines
        }
        if (-not $target.exists) {
            if ($expected.covered_bytes -eq 0) {
                $common['appended_bytes'] = [long]0
                return ConvertTo-SumiGuardLogIntegrityResult -Success $true -Status 'INTACT' -Properties $common
            }
            $common['current_bytes'] = [long]0
            return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status 'TRUNCATED' -Properties $common
        }
        $stream = Open-SumiGuardLogForRead -Path $target.log_path `
            -TimeoutMilliseconds $ReadTimeoutMilliseconds
        $currentBytes = $stream.Length
        if ($currentBytes -lt $expected.covered_bytes) {
            $common['current_bytes'] = [long]$currentBytes
            return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status 'TRUNCATED' -Properties $common
        }
        $digest = Get-SumiGuardLogPrefixDigest -Stream $stream -Length $expected.covered_bytes
        if ($digest.sha256 -cne $expected.sha256 -or $digest.lines -ne $expected.covered_lines) {
            return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status 'MODIFIED' -Properties $common
        }
        $common['appended_bytes'] = [long]($currentBytes - $expected.covered_bytes)
        return ConvertTo-SumiGuardLogIntegrityResult -Success $true -Status 'INTACT' -Properties $common
    }
    catch {
        return ConvertTo-SumiGuardLogIntegrityResult -Success $false -Status (
            Get-SumiGuardLogIntegrityErrorCode -Exception $_.Exception -DefaultCode 'VERIFY_FAILED') -Properties @{
            verification_completed = $false
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

Export-ModuleMember -Function @('Get-SumiGuardLogCheckpoint', 'Test-SumiGuardLogCheckpoint')
