Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

$script:StoreSchemaVersion = 1
$script:ContainerVersion = 1
$script:MarkerFileName = '.sumi-guard-store.json'
$script:LockFileName = '.sumi-guard-store.lock'
$script:ContainerExtension = '.sgb'
$script:ContainerHeaderBytes = 32
$script:DefaultMaxItemBytes = 1MB
$script:DefaultMaxTotalBytes = 250MB
$script:DefaultRetentionDays = 30
$script:ContainerMagic = [System.Text.Encoding]::ASCII.GetBytes('SUMIGD01')
$script:DpapiEntropy = [System.Text.Encoding]::UTF8.GetBytes('SUMI Guard LocalStore DPAPI CurrentUser v1')
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SumiGuardTestForceEncryptionFailure = $false
$script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow }

function New-SumiGuardResult {
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

function Get-SumiGuardUtcNow {
    return [DateTimeOffset](& $script:SumiGuardUtcNowProvider)
}

function Clear-SumiGuardByteArray {
    param([byte[]]$Bytes)

    if ($null -ne $Bytes -and $Bytes.Length -gt 0) {
        [Array]::Clear($Bytes, 0, $Bytes.Length)
    }
}

function Resolve-SumiGuardStorePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw [System.ArgumentException]::new('Store path is empty.')
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $trimChars = [char[]]@('\', '/')
    if ($fullPath.TrimEnd($trimChars) -ceq $rootPath.TrimEnd($trimChars)) {
        throw [System.ArgumentException]::new('A filesystem root cannot be a SUMI Guard store.')
    }
    return $fullPath.TrimEnd($trimChars)
}

function Test-SumiGuardReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-SumiGuardPathContainsReparsePoint {
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
            if (Test-SumiGuardReparsePoint -Path $currentPath) {
                return $true
            }
        }
    }
    return $false
}

function Set-SumiGuardStoreAcl {
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

function Test-SumiGuardStoreAcl {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $systemSid = 'S-1-5-18'
    $expectedSids = @($currentSid, $systemSid)
    $security = Get-Acl -LiteralPath $StorePath -ErrorAction Stop
    $rules = @($security.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]))
    $hasCurrentUserFullControl = $false
    $hasSystemFullControl = $false
    $unexpectedRuleCount = 0

    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        $isAllow = $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        $isFullControl = (($rule.FileSystemRights -band
            [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl)
        if ($expectedSids -notcontains $sid -or -not $isAllow) {
            $unexpectedRuleCount++
            continue
        }
        if ($sid -ceq $currentSid -and $isFullControl) {
            $hasCurrentUserFullControl = $true
        }
        if ($sid -ceq $systemSid -and $isFullControl) {
            $hasSystemFullControl = $true
        }
    }

    return [pscustomobject][ordered]@{
        valid = $security.AreAccessRulesProtected -and
            $hasCurrentUserFullControl -and
            $hasSystemFullControl -and
            $unexpectedRuleCount -eq 0
        inheritance_disabled = $security.AreAccessRulesProtected
        current_user_full_control = $hasCurrentUserFullControl
        system_full_control = $hasSystemFullControl
        unexpected_rule_count = $unexpectedRuleCount
    }
}

function Assert-SumiGuardLocalStore {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $resolvedPath = Resolve-SumiGuardStorePath -Path $StorePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new('The SUMI Guard store does not exist.')
    }
    if (Test-SumiGuardPathContainsReparsePoint -Path $resolvedPath) {
        throw [System.IO.InvalidDataException]::new(
            'A path containing a reparse point cannot be used as a SUMI Guard store.')
    }

    $markerPath = Join-Path $resolvedPath $script:MarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw [System.IO.InvalidDataException]::new('The SUMI Guard store marker is missing.')
    }
    if (Test-SumiGuardReparsePoint -Path $markerPath) {
        throw [System.IO.InvalidDataException]::new('The SUMI Guard store marker cannot be a reparse point.')
    }

    try {
        $marker = [System.IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -ErrorAction Stop
        $markerStoreId = [Guid]::Empty
        if ([int]$marker.schema_version -ne $script:StoreSchemaVersion -or
            -not [Guid]::TryParseExact([string]$marker.store_id, 'N', [ref]$markerStoreId)) {
            throw [System.IO.InvalidDataException]::new('The SUMI Guard store marker is invalid.')
        }
    }
    catch {
        throw [System.IO.InvalidDataException]::new('The SUMI Guard store marker is invalid.')
    }

    $aclStatus = Test-SumiGuardStoreAcl -StorePath $resolvedPath
    if (-not $aclStatus.valid) {
        throw [System.UnauthorizedAccessException]::new('The SUMI Guard store ACL is not restricted as required.')
    }
    return $resolvedPath
}

function Enter-SumiGuardStoreLock {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [int]$TimeoutMilliseconds = 10000
    )

    $lockPath = Join-Path $StorePath $script:LockFileName
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
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
    throw [System.TimeoutException]::new('Timed out waiting for the SUMI Guard store lock.')
}

function Test-SumiGuardManagedFileName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return $Name -cmatch '^[0-9a-f]{32}\.sgb$'
}

function Read-SumiGuardContainerHeader {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-SumiGuardReparsePoint -Path $Path) {
        throw [System.IO.InvalidDataException]::new('Managed body files cannot be reparse points.')
    }
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt $script:ContainerHeaderBytes) {
            throw [System.IO.InvalidDataException]::new('Managed body file is shorter than its header.')
        }
        [byte[]]$magic = $reader.ReadBytes($script:ContainerMagic.Length)
        if ([Convert]::ToBase64String($magic) -cne
            [Convert]::ToBase64String($script:ContainerMagic)) {
            throw [System.IO.InvalidDataException]::new('Managed body file magic is invalid.')
        }
        $version = $reader.ReadInt32()
        $createdUtcTicks = $reader.ReadInt64()
        $plainTextBytes = $reader.ReadInt64()
        $cipherTextBytes = $reader.ReadInt32()
        if ($version -ne $script:ContainerVersion -or $createdUtcTicks -le 0 -or
            $plainTextBytes -lt 0 -or $cipherTextBytes -le 0 -or
            $stream.Length -ne ($script:ContainerHeaderBytes + [long]$cipherTextBytes)) {
            throw [System.IO.InvalidDataException]::new('Managed body file header is invalid.')
        }
        $createdUtcDate = New-Object DateTime($createdUtcTicks, [DateTimeKind]::Utc)
        return [pscustomobject][ordered]@{
            version = $version
            created_at_utc = (New-Object DateTimeOffset($createdUtcDate))
            plaintext_bytes = $plainTextBytes
            ciphertext_bytes = $cipherTextBytes
            stored_bytes = $stream.Length
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-SumiGuardManagedBodyFiles {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    foreach ($path in [System.IO.Directory]::GetFiles(
        $StorePath,
        '*' + $script:ContainerExtension,
        [System.IO.SearchOption]::TopDirectoryOnly)) {
        $name = [System.IO.Path]::GetFileName($path)
        if (Test-SumiGuardManagedFileName -Name $name) {
            Get-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Get-SumiGuardQuotaUsage {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    [long]$totalPlaintext = 0
    [long]$totalStored = 0
    [long]$count = 0
    foreach ($file in @(Get-SumiGuardManagedBodyFiles -StorePath $StorePath)) {
        $header = Read-SumiGuardContainerHeader -Path $file.FullName
        if ($totalPlaintext -gt ([long]::MaxValue - [long]$header.plaintext_bytes) -or
            $totalStored -gt ([long]::MaxValue - [long]$header.stored_bytes)) {
            throw [System.OverflowException]::new('SUMI Guard quota usage overflowed.')
        }
        $totalPlaintext += [long]$header.plaintext_bytes
        $totalStored += [long]$header.stored_bytes
        $count++
    }
    return [pscustomobject][ordered]@{
        body_count = $count
        total_plaintext_bytes = $totalPlaintext
        total_stored_bytes = $totalStored
    }
}

function Protect-SumiGuardBytes {
    param([Parameter(Mandatory = $true)][byte[]]$PlainBytes)

    if ($script:SumiGuardTestForceEncryptionFailure) {
        throw [System.Security.Cryptography.CryptographicException]::new(
            'SUMI Guard test fault: encryption failure.')
    }
    [byte[]]$cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $PlainBytes,
        $script:DpapiEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ,$cipher
}

function Unprotect-SumiGuardBytes {
    param([Parameter(Mandatory = $true)][byte[]]$CipherBytes)

    [byte[]]$plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $CipherBytes,
        $script:DpapiEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ,$plain
}

function New-SumiGuardContainerBytes {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$CreatedAtUtc,
        [Parameter(Mandatory = $true)][long]$PlaintextBytes,
        [Parameter(Mandatory = $true)][byte[]]$CipherBytes
    )

    $memory = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($memory)
    try {
        $writer.Write($script:ContainerMagic)
        $writer.Write([int]$script:ContainerVersion)
        $writer.Write([long]$CreatedAtUtc.UtcDateTime.Ticks)
        $writer.Write([long]$PlaintextBytes)
        $writer.Write([int]$CipherBytes.Length)
        $writer.Write($CipherBytes)
        $writer.Flush()
        [byte[]]$container = $memory.ToArray()
        return ,$container
    }
    finally {
        $writer.Dispose()
        $memory.Dispose()
    }
}

function Initialize-SumiGuardLocalStore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $resolvedPath = Resolve-SumiGuardStorePath -Path $Path
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'INVALID_STORE_PATH'
    }

    $reparseCheckPath = if (Test-Path -LiteralPath $resolvedPath) {
        $resolvedPath
    } else {
        Split-Path -Parent $resolvedPath
    }
    try {
        if ([string]::IsNullOrWhiteSpace($reparseCheckPath) -or
            (Test-SumiGuardPathContainsReparsePoint -Path $reparseCheckPath)) {
            return New-SumiGuardResult -Success $false -Status 'REPARSE_PATH_NOT_ALLOWED'
        }
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_PATH_INSPECTION_FAILED'
    }

    if (Test-Path -LiteralPath $resolvedPath) {
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
            return New-SumiGuardResult -Success $false -Status 'STORE_PATH_NOT_DIRECTORY'
        }
        try {
            $validated = Assert-SumiGuardLocalStore -StorePath $resolvedPath
            $aclStatus = Test-SumiGuardStoreAcl -StorePath $validated
            return New-SumiGuardResult -Success $true -Status 'READY' -Properties @{
                store_path = $validated
                created = $false
                acl = $aclStatus
            }
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'EXISTING_DIRECTORY_NOT_VALID_STORE'
        }
    }

    try {
        [void](New-Item -ItemType Directory -Path $resolvedPath -ErrorAction Stop)
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_DIRECTORY_CREATE_FAILED'
    }
    try {
        Set-SumiGuardStoreAcl -StorePath $resolvedPath
        $aclStatus = Test-SumiGuardStoreAcl -StorePath $resolvedPath
        if (-not $aclStatus.valid) {
            return New-SumiGuardResult -Success $false -Status 'ACL_RESTRICTION_FAILED'
        }
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'ACL_RESTRICTION_FAILED'
    }

    try {
        $markerPath = Join-Path $resolvedPath $script:MarkerFileName
        $marker = [ordered]@{
            schema_version = $script:StoreSchemaVersion
            store_id = [Guid]::NewGuid().ToString('N')
            created_at_utc = (Get-SumiGuardUtcNow).ToUniversalTime().ToString('o')
            encryption = 'Windows DPAPI CurrentUser'
        }
        $markerJson = $marker | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($markerPath, $markerJson, $script:Utf8Strict)
        $validated = Assert-SumiGuardLocalStore -StorePath $resolvedPath
        return New-SumiGuardResult -Success $true -Status 'CREATED' -Properties @{
            store_path = $validated
            created = $true
            acl = $aclStatus
        }
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_MARKER_CREATE_FAILED'
    }
}

function Save-SumiGuardBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory = $true)][string]$StorePath,
        [ValidateRange(1, 2147483647)][int]$MaxItemBytes = $script:DefaultMaxItemBytes,
        [long]$MaxTotalBytes = $script:DefaultMaxTotalBytes,
        [ValidateRange(100, 60000)][int]$LockTimeoutMilliseconds = 10000
    )

    if ($MaxTotalBytes -lt 1) {
        return New-SumiGuardResult -Success $false -Status 'INVALID_TOTAL_LIMIT'
    }
    try {
        $resolvedPath = Assert-SumiGuardLocalStore -StorePath $StorePath
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_VALIDATION_FAILED'
    }

    [byte[]]$plainBytes = $null
    [byte[]]$cipherBytes = $null
    [byte[]]$containerBytes = $null
    $lock = $null
    $temporaryPath = $null
    try {
        try {
            $plainBytes = $script:Utf8Strict.GetBytes($Body)
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'BODY_ENCODING_FAILED'
        }
        if ($plainBytes.LongLength -gt $MaxItemBytes) {
            return New-SumiGuardResult -Success $false -Status 'ITEM_LIMIT_EXCEEDED' -Properties @{
                body_bytes = $plainBytes.LongLength
                max_item_bytes = $MaxItemBytes
            }
        }

        try {
            $cipherBytes = Protect-SumiGuardBytes -PlainBytes $plainBytes
            $containerBytes = New-SumiGuardContainerBytes `
                -CreatedAtUtc (Get-SumiGuardUtcNow).ToUniversalTime() `
                -PlaintextBytes $plainBytes.LongLength `
                -CipherBytes $cipherBytes
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'ENCRYPTION_FAILED'
        }

        try {
            $lock = Enter-SumiGuardStoreLock `
                -StorePath $resolvedPath `
                -TimeoutMilliseconds $LockTimeoutMilliseconds
        }
        catch [System.TimeoutException] {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_TIMEOUT'
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_FAILED'
        }

        try {
            $usage = Get-SumiGuardQuotaUsage -StorePath $resolvedPath
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'STORE_SCAN_FAILED'
        }
        if ([long]$containerBytes.LongLength -gt $MaxTotalBytes -or
            [long]$usage.total_stored_bytes -gt
            ($MaxTotalBytes - [long]$containerBytes.LongLength)) {
            return New-SumiGuardResult -Success $false -Status 'TOTAL_LIMIT_EXCEEDED' -Properties @{
                current_total_stored_bytes = [long]$usage.total_stored_bytes
                attempted_stored_bytes = $containerBytes.LongLength
                max_total_stored_bytes = $MaxTotalBytes
            }
        }

        $id = [Guid]::NewGuid().ToString('N')
        $finalPath = Join-Path $resolvedPath ($id + $script:ContainerExtension)
        $temporaryPath = Join-Path $resolvedPath ('.pending-' + $id + '.tmp')
        try {
            [System.IO.File]::WriteAllBytes($temporaryPath, $containerBytes)
            [System.IO.File]::Move($temporaryPath, $finalPath)
            $temporaryPath = $null
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'WRITE_FAILED'
        }

        return New-SumiGuardResult -Success $true -Status 'SAVED' -Properties @{
            body_id = $id
            body_bytes = $plainBytes.LongLength
            stored_bytes = $containerBytes.LongLength
            total_stored_bytes_after_save =
                ([long]$usage.total_stored_bytes + [long]$containerBytes.LongLength)
            encryption = 'Windows DPAPI CurrentUser'
        }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        Clear-SumiGuardByteArray -Bytes $plainBytes
        Clear-SumiGuardByteArray -Bytes $cipherBytes
        Clear-SumiGuardByteArray -Bytes $containerBytes
    }
}

function Get-SumiGuardBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$BodyId,
        [ValidateRange(100, 60000)][int]$LockTimeoutMilliseconds = 10000
    )

    $parsedId = [Guid]::Empty
    if (-not [Guid]::TryParseExact($BodyId, 'N', [ref]$parsedId)) {
        return New-SumiGuardResult -Success $false -Status 'INVALID_BODY_ID'
    }
    try {
        $resolvedPath = Assert-SumiGuardLocalStore -StorePath $StorePath
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_VALIDATION_FAILED'
    }

    $lock = $null
    [byte[]]$cipherBytes = $null
    [byte[]]$plainBytes = $null
    try {
        try {
            $lock = Enter-SumiGuardStoreLock `
                -StorePath $resolvedPath `
                -TimeoutMilliseconds $LockTimeoutMilliseconds
        }
        catch [System.TimeoutException] {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_TIMEOUT'
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_FAILED'
        }

        $path = Join-Path $resolvedPath ($BodyId.ToLowerInvariant() + $script:ContainerExtension)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return New-SumiGuardResult -Success $false -Status 'BODY_NOT_FOUND'
        }
        try {
            $header = Read-SumiGuardContainerHeader -Path $path
            $stream = New-Object System.IO.FileStream(
                $path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read)
            try {
                [void]$stream.Seek($script:ContainerHeaderBytes, [System.IO.SeekOrigin]::Begin)
                $cipherBytes = New-Object byte[] ([int]$header.ciphertext_bytes)
                $offset = 0
                while ($offset -lt $cipherBytes.Length) {
                    $read = $stream.Read($cipherBytes, $offset, $cipherBytes.Length - $offset)
                    if ($read -le 0) {
                        throw [System.IO.EndOfStreamException]::new('Encrypted body ended unexpectedly.')
                    }
                    $offset += $read
                }
            }
            finally {
                $stream.Dispose()
            }
            $plainBytes = Unprotect-SumiGuardBytes -CipherBytes $cipherBytes
            if ($plainBytes.LongLength -ne [long]$header.plaintext_bytes) {
                return New-SumiGuardResult -Success $false -Status 'DECRYPTION_LENGTH_MISMATCH'
            }
            $body = $script:Utf8Strict.GetString($plainBytes)
            return New-SumiGuardResult -Success $true -Status 'DECRYPTED' -Properties @{
                body_id = $BodyId.ToLowerInvariant()
                body = $body
                body_bytes = $plainBytes.LongLength
                created_at_utc = $header.created_at_utc.ToString('o')
            }
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'DECRYPTION_FAILED'
        }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        Clear-SumiGuardByteArray -Bytes $plainBytes
        Clear-SumiGuardByteArray -Bytes $cipherBytes
    }
}

function Remove-SumiGuardExpiredBody {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [ValidateRange(1, 36500)][int]$RetentionDays = $script:DefaultRetentionDays,
        [ValidateRange(100, 60000)][int]$LockTimeoutMilliseconds = 10000
    )

    try {
        $resolvedPath = Assert-SumiGuardLocalStore -StorePath $StorePath
    }
    catch {
        return New-SumiGuardResult -Success $false -Status 'STORE_VALIDATION_FAILED'
    }

    $lock = $null
    try {
        try {
            $lock = Enter-SumiGuardStoreLock `
                -StorePath $resolvedPath `
                -TimeoutMilliseconds $LockTimeoutMilliseconds
        }
        catch [System.TimeoutException] {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_TIMEOUT'
        }
        catch {
            return New-SumiGuardResult -Success $false -Status 'STORE_LOCK_FAILED'
        }

        $cutoff = (Get-SumiGuardUtcNow).ToUniversalTime().AddDays(-$RetentionDays)
        $deletedCount = 0
        $retainedCount = 0
        $skippedLinkCount = 0
        $skippedNonManagedCount = 0
        $invalidManagedCount = 0
        $deleteFailureCount = 0
        $trimChars = [char[]]@('\', '/')
        $rootWithSeparator = $resolvedPath.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar

        foreach ($path in [System.IO.Directory]::GetFiles(
            $resolvedPath,
            '*' + $script:ContainerExtension,
            [System.IO.SearchOption]::TopDirectoryOnly)) {
            $fullPath = [System.IO.Path]::GetFullPath($path)
            $name = [System.IO.Path]::GetFileName($fullPath)
            if (-not $fullPath.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-SumiGuardManagedFileName -Name $name)) {
                $skippedNonManagedCount++
                continue
            }
            if (Test-SumiGuardReparsePoint -Path $fullPath) {
                $skippedLinkCount++
                continue
            }
            try {
                $header = Read-SumiGuardContainerHeader -Path $fullPath
            }
            catch {
                $invalidManagedCount++
                continue
            }
            if ($header.created_at_utc -ge $cutoff) {
                $retainedCount++
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($fullPath, 'Delete expired SUMI Guard body')) {
                $retainedCount++
                continue
            }
            try {
                [System.IO.File]::Delete($fullPath)
                $deletedCount++
            }
            catch {
                $deleteFailureCount++
            }
        }

        $status = if ($deleteFailureCount -eq 0) {
            'CLEANUP_COMPLETED'
        } else {
            'CLEANUP_PARTIAL'
        }
        return New-SumiGuardResult `
            -Success ($deleteFailureCount -eq 0) `
            -Status $status `
            -Properties @{
                retention_days = $RetentionDays
                cutoff_utc = $cutoff.ToString('o')
                deleted_count = $deletedCount
                retained_count = $retainedCount
                skipped_link_count = $skippedLinkCount
                skipped_nonmanaged_count = $skippedNonManagedCount
                invalid_managed_count = $invalidManagedCount
                delete_failure_count = $deleteFailureCount
            }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'Initialize-SumiGuardLocalStore',
    'Save-SumiGuardBody',
    'Get-SumiGuardBody',
    'Remove-SumiGuardExpiredBody'
)
