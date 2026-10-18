# Read-only verifier for a separately signed time-and-floor receipt.
# The tool cannot prove the challenge came from a trusted independent source.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Execution','Assessment')][string]$StoreKind,
    [Parameter(Mandatory = $true)][string]$StorePath,
    [Parameter(Mandatory = $true)][string]$TrustManifestPath,
    [Parameter(Mandatory = $true)][string]$ExpectedRootPublicKeySha256,
    [Parameter(Mandatory = $true)][string]$AuthorityPublicKeyPath,
    [Parameter(Mandatory = $true)][string]$ExpectedAuthorityPublicKeySha256,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptSignaturePath,
    [Parameter(Mandatory = $true)][string]$ExpectedChallengeNonce
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false,$true)
$status = 'RECEIPT_REJECTED'
$reason = 'VERIFICATION_FAILED'
$exitCode = 2
$keyPinVerified = $false
$signatureVerified = $false
$challengeMatched = $false
$storeBound = $false
$manifestBound = $false
$trustedTimeClaim = $null
$minimumEpoch = $null
$minimumSequence = $null
$sha = $null
$rsa = $null
[byte[]]$authorityKeyBytes = $null
[byte[]]$receiptBytes = $null
[byte[]]$signatureFile = $null
[byte[]]$signature = $null
[byte[]]$manifestBytes = $null
[byte[]]$markerBytes = $null
[byte[]]$modulus = $null

function Test-SumiGuardReceiptPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split(
        [char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { return $false }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    return $true
}

function Read-SumiGuardReceiptFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaximumBytes
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-SumiGuardReceiptPath -Path $Path)) { throw 'INPUT_FILE_INVALID' }
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes) {
            throw 'INPUT_FILE_INVALID'
        }
        [byte[]]$bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length - $offset)
            if ($read -le 0) { throw 'INPUT_FILE_INVALID' }
            $offset += $read
        }
        if ($stream.Length -ne $bytes.Length) { throw 'INPUT_FILE_INVALID' }
        return ,$bytes
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Test-SumiGuardReceiptFieldSet {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames
    )
    if ($null -eq $Value -or $Value -is [array]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $ExpectedNames.Count) { return $false }
    foreach ($name in $ExpectedNames) {
        if ($actual -cnotcontains $name) { return $false }
    }
    return $true
}

function ConvertTo-SumiGuardReceiptUtc {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        throw 'RECEIPT_TIME_INVALID'
    }
    $date = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,[ref]$date) -or
        $date.Offset -ne [TimeSpan]::Zero) {
        throw 'RECEIPT_TIME_INVALID'
    }
    return $date
}

function Get-SumiGuardReceiptHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()
}

try {
    if ($ExpectedAuthorityPublicKeySha256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
        $ExpectedRootPublicKeySha256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
        $ExpectedChallengeNonce -cnotmatch '^[0-9a-f]{64}$') {
        throw 'TRUST_INPUT_INVALID'
    }
    if ($ExpectedAuthorityPublicKeySha256.ToLowerInvariant() -ceq
        $ExpectedRootPublicKeySha256.ToLowerInvariant()) {
        throw 'AUTHORITY_KEY_NOT_SEPARATE'
    }
    $fullStore = [IO.Path]::GetFullPath($StorePath).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath $fullStore -PathType Container) -or
        -not (Test-SumiGuardReceiptPath -Path $fullStore)) { throw 'STORE_INVALID' }
    $markerName = if ($StoreKind -ceq 'Execution') {
        '.sumi-guard-execution-store.json'
    } else { '.sumi-guard-assessment-store.json' }
    $markerPath = Join-Path $fullStore $markerName
    foreach ($inputPath in @($AuthorityPublicKeyPath,$ReceiptPath,
        $ReceiptSignaturePath,$TrustManifestPath)) {
        $full = [IO.Path]::GetFullPath($inputPath)
        if ([string]::Equals($full,$fullStore,[StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($fullStore+[IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'INPUT_INSIDE_STORE'
        }
    }
    $authorityKeyBytes = Read-SumiGuardReceiptFile -Path $AuthorityPublicKeyPath -MaximumBytes 4096
    $sha = [Security.Cryptography.SHA256]::Create()
    if ((Get-SumiGuardReceiptHash -Bytes $authorityKeyBytes) -cne
        $ExpectedAuthorityPublicKeySha256.ToLowerInvariant()) {
        throw 'AUTHORITY_PIN_MISMATCH'
    }
    $keyPinVerified = $true
    try {
        $publicKey = $script:Utf8.GetString($authorityKeyBytes) | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SumiGuardReceiptFieldSet -Value $publicKey -ExpectedNames @(
            'schema_version','algorithm','modulus_base64','exponent_base64')) -or
            $publicKey.schema_version -isnot [int] -or $publicKey.schema_version -ne 1 -or
            [string]$publicKey.algorithm -cne 'RSA-SHA256-PKCS1-v1_5' -or
            [string]$publicKey.exponent_base64 -cne 'AQAB' -or
            [string]$publicKey.modulus_base64 -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
            throw 'AUTHORITY_KEY_INVALID'
        }
        $modulus = [Convert]::FromBase64String([string]$publicKey.modulus_base64)
        if ($modulus.Length -lt 384 -or $modulus.Length -gt 512 -or
            ($modulus.Length % 64) -ne 0 -or $modulus[0] -eq 0) {
            throw 'AUTHORITY_KEY_INVALID'
        }
    }
    catch { throw 'AUTHORITY_KEY_INVALID' }
    $receiptBytes = Read-SumiGuardReceiptFile -Path $ReceiptPath -MaximumBytes 8192
    $signatureFile = Read-SumiGuardReceiptFile -Path $ReceiptSignaturePath -MaximumBytes 8192
    try {
        $signatureText = $script:Utf8.GetString($signatureFile).Trim()
        if ($signatureText -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
            throw 'RECEIPT_SIGNATURE_FILE_INVALID'
        }
        $signature = [Convert]::FromBase64String($signatureText)
        if ($signature.Length -ne $modulus.Length) {
            throw 'RECEIPT_SIGNATURE_FILE_INVALID'
        }
    }
    catch { throw 'RECEIPT_SIGNATURE_FILE_INVALID' }
    $p = New-Object Security.Cryptography.RSAParameters
    $p.Modulus = $modulus
    $p.Exponent = [byte[]]@(1,0,1)
    $rsa = [Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($p)
    $signatureVerified = $rsa.VerifyData(
        $receiptBytes,$signature,[Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $signatureVerified) { throw 'RECEIPT_SIGNATURE_INVALID' }

    try {
        $receipt = $script:Utf8.GetString($receiptBytes) | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SumiGuardReceiptFieldSet -Value $receipt -ExpectedNames @(
            'schema_version','record_type','purpose','challenge_nonce',
            'store_kind','store_marker_sha256','trust_manifest_sha256',
            'root_public_key_sha256','minimum_manifest_epoch',
            'minimum_checkpoint_sequence','trusted_at_utc',
            'issued_at_utc','expires_at_utc')) -or
            $receipt.schema_version -isnot [int] -or $receipt.schema_version -ne 1 -or
            [string]$receipt.record_type -cne 'SumiGuardAuthorityReceipt' -or
            [string]$receipt.purpose -cne 'CHECKPOINT_TRUST_STATE' -or
            [string]$receipt.store_kind -cne $StoreKind -or
            [string]$receipt.challenge_nonce -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$receipt.store_marker_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$receipt.trust_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$receipt.root_public_key_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($receipt.minimum_manifest_epoch -isnot [int] -and
                $receipt.minimum_manifest_epoch -isnot [long]) -or
            ($receipt.minimum_checkpoint_sequence -isnot [int] -and
                $receipt.minimum_checkpoint_sequence -isnot [long]) -or
            [long]$receipt.minimum_manifest_epoch -lt 1 -or
            [long]$receipt.minimum_checkpoint_sequence -lt 1) {
            throw 'RECEIPT_SCHEMA_INVALID'
        }
        $issued = ConvertTo-SumiGuardReceiptUtc -Value ([string]$receipt.issued_at_utc)
        $expires = ConvertTo-SumiGuardReceiptUtc -Value ([string]$receipt.expires_at_utc)
        $attested = ConvertTo-SumiGuardReceiptUtc -Value ([string]$receipt.trusted_at_utc)
        if ($expires -le $issued -or
            ($expires - $issued) -gt [TimeSpan]::FromMinutes(2) -or
            $attested -lt $issued -or $attested -gt $expires) {
            throw 'RECEIPT_WINDOW_INVALID'
        }
    }
    catch {
        if ($_.Exception.Message -ceq 'RECEIPT_TIME_INVALID') {
            throw 'RECEIPT_TIME_INVALID'
        }
        if ($_.Exception.Message -ceq 'RECEIPT_WINDOW_INVALID') {
            throw 'RECEIPT_WINDOW_INVALID'
        }
        throw 'RECEIPT_SCHEMA_INVALID'
    }
    if ([string]$receipt.challenge_nonce -cne $ExpectedChallengeNonce) {
        throw 'CHALLENGE_MISMATCH'
    }
    $challengeMatched = $true
    if ([string]$receipt.root_public_key_sha256 -cne
        $ExpectedRootPublicKeySha256.ToLowerInvariant()) {
        throw 'ROOT_BINDING_MISMATCH'
    }
    $markerBytes = Read-SumiGuardReceiptFile -Path $markerPath -MaximumBytes 65536
    if ((Get-SumiGuardReceiptHash -Bytes $markerBytes) -cne
        [string]$receipt.store_marker_sha256) {
        throw 'STORE_BINDING_MISMATCH'
    }
    $storeBound = $true
    $manifestBytes = Read-SumiGuardReceiptFile -Path $TrustManifestPath -MaximumBytes 32768
    if ((Get-SumiGuardReceiptHash -Bytes $manifestBytes) -cne
        [string]$receipt.trust_manifest_sha256) {
        throw 'MANIFEST_BINDING_MISMATCH'
    }
    $manifestBound = $true
    $minimumEpoch = [long]$receipt.minimum_manifest_epoch
    $minimumSequence = [long]$receipt.minimum_checkpoint_sequence
    $trustedTimeClaim = [string]$receipt.trusted_at_utc
    $status = 'SIGNED_RECEIPT_ACCEPTED'
    $reason = 'SIGNATURE_AND_BINDINGS_VALID'
    $exitCode = 0
}
catch {
    $known = @(
        'TRUST_INPUT_INVALID','AUTHORITY_KEY_NOT_SEPARATE','STORE_INVALID',
        'INPUT_INSIDE_STORE','INPUT_FILE_INVALID','AUTHORITY_PIN_MISMATCH',
        'AUTHORITY_KEY_INVALID','RECEIPT_SIGNATURE_FILE_INVALID',
        'RECEIPT_SIGNATURE_INVALID','RECEIPT_SCHEMA_INVALID',
        'RECEIPT_TIME_INVALID','RECEIPT_WINDOW_INVALID','CHALLENGE_MISMATCH',
        'ROOT_BINDING_MISMATCH','STORE_BINDING_MISMATCH',
        'MANIFEST_BINDING_MISMATCH'
    )
    $reason = if ($known -ccontains [string]$_.Exception.Message) {
        [string]$_.Exception.Message
    } else { 'VERIFICATION_FAILED' }
    $status = 'RECEIPT_REJECTED'
    $exitCode = 2
}
finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if ($null -ne $sha) { $sha.Dispose() }
    foreach ($buffer in @($authorityKeyBytes,$receiptBytes,$signatureFile,
        $signature,$manifestBytes,$markerBytes,$modulus)) {
        if ($null -ne $buffer -and $buffer.Length -gt 0) {
            [Array]::Clear($buffer,0,$buffer.Length)
        }
    }
}
[pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    code = $reason
    success = $exitCode -eq 0
    authority_key_pin_verified = $keyPinVerified
    receipt_signature_verified = $signatureVerified
    challenge_matches = $challengeMatched
    store_binding_verified = $storeBound
    manifest_binding_verified = $manifestBound
    minimum_manifest_epoch = $(if ($exitCode -eq 0) { $minimumEpoch } else { $null })
    minimum_checkpoint_sequence = $(if ($exitCode -eq 0) { $minimumSequence } else { $null })
    authority_claimed_utc = $(if ($exitCode -eq 0) { $trustedTimeClaim } else { $null })
    challenge_origin_verified = $false
    trusted_clock_independently_checked = $false
    read_only = $true
    private_key_loaded = $false
    network_access_performed = $false
} | ConvertTo-Json -Compress -Depth 4
exit $exitCode
