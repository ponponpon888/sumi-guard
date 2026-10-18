# Read-only verification of an offline root-signed signer lifecycle manifest.
# This verifier requires independent root pin, manifest epoch floor and UTC time.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPublicKeyPath,
    [Parameter(Mandatory = $true)][string]$ExpectedRootPublicKeySha256,
    [Parameter(Mandatory = $true)][string]$TrustManifestPath,
    [Parameter(Mandatory = $true)][string]$TrustManifestSignaturePath,
    [Parameter(Mandatory = $true)][string]$SignerPublicKeyPath,
    [Parameter(Mandatory = $true)][ValidateRange(1,2147483647)][long]$MinimumTrustedManifestEpoch,
    [Parameter(Mandatory = $true)][string]$TrustedNowUtc
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$code = 'VERIFY_FAILED'
$status = 'VERIFICATION_FAILED'
$exitCode = 2
$rootPinVerified = $false
$manifestSignatureVerified = $false
$trustedEpochChecked = $false
$trustedTimeChecked = $false
$signerDigest = $null
$manifestEpoch = $null
$rsa = $null
$sha = $null
[byte[]]$rootBytes = $null
[byte[]]$manifestBytes = $null
[byte[]]$signatureFile = $null
[byte[]]$signature = $null
[byte[]]$signerBytes = $null
[byte[]]$modulus = $null

function Test-SumiGuardSafePath {
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

function Read-SumiGuardTrustInput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaximumBytes
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-SumiGuardSafePath -Path $Path)) {
        throw 'INPUT_INVALID'
    }
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        if ($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes) {
            throw 'INPUT_INVALID'
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -le 0) { throw 'INPUT_INVALID' }
            $offset += $count
        }
        if ($stream.Length -ne $bytes.Length) { throw 'INPUT_INVALID' }
        return ,$bytes
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertTo-SumiGuardTrustedUtc {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') {
        throw 'TIME_INVALID'
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw 'TIME_INVALID'
    }
    if ($parsed.Offset -ne [TimeSpan]::Zero) { throw 'TIME_INVALID' }
    return $parsed
}

function Test-SumiGuardExactFieldSet {
    param([Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names)
    if ($null -eq $Value -or $Value -is [array]) { return $false }
    $fields = @($Value.PSObject.Properties.Name)
    if ($fields.Count -ne $Names.Count) { return $false }
    foreach ($name in $Names) {
        if ($fields -cnotcontains $name) { return $false }
    }
    return $true
}

function Get-SumiGuardSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
}

try {
    if ($ExpectedRootPublicKeySha256 -cnotmatch '^[a-fA-F0-9]{64}$') {
        throw 'ROOT_PIN_INVALID'
    }
    $trustedNow = ConvertTo-SumiGuardTrustedUtc -Value $TrustedNowUtc
    $rootBytes = Read-SumiGuardTrustInput -Path $RootPublicKeyPath -MaximumBytes 4096
    $sha = [Security.Cryptography.SHA256]::Create()
    if ((Get-SumiGuardSha256 -Bytes $rootBytes) -cne
        $ExpectedRootPublicKeySha256.ToLowerInvariant()) {
        throw 'ROOT_PIN_MISMATCH'
    }
    $rootPinVerified = $true
    try {
        $rootPublic = $script:Utf8.GetString($rootBytes) | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SumiGuardExactFieldSet -Value $rootPublic -Names @(
            'schema_version','algorithm','modulus_base64','exponent_base64'))) {
            throw 'ROOT_PUBLIC_KEY_INVALID'
        }
        if ($rootPublic.schema_version -isnot [int] -or
            $rootPublic.schema_version -ne 1 -or
            [string]$rootPublic.algorithm -cne 'RSA-SHA256-PKCS1-v1_5' -or
            [string]$rootPublic.exponent_base64 -cne 'AQAB' -or
            [string]$rootPublic.modulus_base64 -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
            throw 'ROOT_PUBLIC_KEY_INVALID'
        }
        $modulus = [Convert]::FromBase64String([string]$rootPublic.modulus_base64)
        if ($modulus.Length -lt 384 -or $modulus.Length -gt 512 -or
            ($modulus.Length % 64) -ne 0 -or $modulus[0] -eq 0) {
            throw 'ROOT_PUBLIC_KEY_INVALID'
        }
    }
    catch { throw 'ROOT_PUBLIC_KEY_INVALID' }

    $manifestBytes = Read-SumiGuardTrustInput -Path $TrustManifestPath -MaximumBytes 32768
    $signatureFile = Read-SumiGuardTrustInput -Path $TrustManifestSignaturePath -MaximumBytes 8192
    try {
        $signatureText = $script:Utf8.GetString($signatureFile).Trim()
        if ($signatureText -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') {
            throw 'MANIFEST_SIGNATURE_FILE_INVALID'
        }
        $signature = [Convert]::FromBase64String($signatureText)
        if ($signature.Length -ne $modulus.Length) {
            throw 'MANIFEST_SIGNATURE_FILE_INVALID'
        }
    }
    catch { throw 'MANIFEST_SIGNATURE_FILE_INVALID' }

    $rsaParameters = New-Object Security.Cryptography.RSAParameters
    $rsaParameters.Modulus = $modulus
    $rsaParameters.Exponent = [byte[]]@(1,0,1)
    $rsa = [Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($rsaParameters)
    $manifestSignatureVerified = $rsa.VerifyData(
        $manifestBytes, $signature,
        [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $manifestSignatureVerified) { throw 'MANIFEST_SIGNATURE_INVALID' }

    try {
        $manifest = $script:Utf8.GetString($manifestBytes) |
            ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SumiGuardExactFieldSet -Value $manifest -Names @(
            'schema_version','record_type','manifest_epoch',
            'issued_at_utc','expires_at_utc','signers'))) {
            throw 'MANIFEST_SCHEMA_INVALID'
        }
        if ($manifest.schema_version -isnot [int] -or
            [int]$manifest.schema_version -ne 1 -or
            [string]$manifest.record_type -cne 'SumiGuardSignerTrustManifest' -or
            ($manifest.manifest_epoch -isnot [int] -and
                $manifest.manifest_epoch -isnot [long]) -or
            [long]$manifest.manifest_epoch -lt 1 -or
            $manifest.signers -isnot [array] -or
            @($manifest.signers).Count -lt 1 -or
            @($manifest.signers).Count -gt 32) {
            throw 'MANIFEST_SCHEMA_INVALID'
        }
        $manifestEpoch = [long]$manifest.manifest_epoch
        $issued = ConvertTo-SumiGuardTrustedUtc -Value ([string]$manifest.issued_at_utc)
        $expires = ConvertTo-SumiGuardTrustedUtc -Value ([string]$manifest.expires_at_utc)
        if ($expires -le $issued -or
            ($expires - $issued) -gt [TimeSpan]::FromDays(7)) {
            throw 'MANIFEST_SCHEMA_INVALID'
        }
        $seen = @{}
        foreach ($entry in $manifest.signers) {
            if (-not (Test-SumiGuardExactFieldSet -Value $entry -Names @(
                'public_key_sha256','purpose','state','not_before_utc','not_after_utc'))) {
                throw 'MANIFEST_SCHEMA_INVALID'
            }
            $pin = [string]$entry.public_key_sha256
            if ($pin -cnotmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($pin) -or
                [string]$entry.purpose -cne 'AUDIT_CHECKPOINT' -or
                [string]$entry.state -cnotin @('ACTIVE','RETIRED','REVOKED')) {
                throw 'MANIFEST_SCHEMA_INVALID'
            }
            $seen[$pin] = $true
            $start = ConvertTo-SumiGuardTrustedUtc -Value ([string]$entry.not_before_utc)
            $end = ConvertTo-SumiGuardTrustedUtc -Value ([string]$entry.not_after_utc)
            if ($end -le $start -or
                ($end - $start) -gt [TimeSpan]::FromDays(366)) {
                throw 'MANIFEST_SCHEMA_INVALID'
            }
        }
    }
    catch { throw 'MANIFEST_SCHEMA_INVALID' }

    if ($manifestEpoch -lt $MinimumTrustedManifestEpoch) {
        $status = 'TRUST_REJECTED'
        $code = 'MANIFEST_EPOCH_BELOW_FLOOR'
        $exitCode = 1
    }
    else {
        $trustedEpochChecked = $true
        if ($trustedNow -lt $issued) {
            $status = 'TRUST_REJECTED'
            $code = 'MANIFEST_NOT_YET_VALID'
            $exitCode = 1
        }
        elseif ($trustedNow -ge $expires) {
            $status = 'TRUST_REJECTED'
            $code = 'MANIFEST_EXPIRED'
            $exitCode = 1
        }
        else {
            $trustedTimeChecked = $true
            $signerBytes = Read-SumiGuardTrustInput -Path $SignerPublicKeyPath -MaximumBytes 4096
            $signerDigest = Get-SumiGuardSha256 -Bytes $signerBytes
            $entry = @($manifest.signers | Where-Object {
                [string]$_.public_key_sha256 -ceq $signerDigest })
            if ($entry.Count -ne 1) {
                $status = 'TRUST_REJECTED'
                $code = 'SIGNER_UNKNOWN'
                $exitCode = 1
            }
            elseif ([string]$entry[0].state -ceq 'REVOKED') {
                $status = 'TRUST_REJECTED'
                $code = 'SIGNER_REVOKED'
                $exitCode = 1
            }
            elseif ([string]$entry[0].state -ceq 'RETIRED') {
                $status = 'TRUST_REJECTED'
                $code = 'SIGNER_RETIRED'
                $exitCode = 1
            }
            else {
                $start = ConvertTo-SumiGuardTrustedUtc -Value ([string]$entry[0].not_before_utc)
                $end = ConvertTo-SumiGuardTrustedUtc -Value ([string]$entry[0].not_after_utc)
                if ($trustedNow -lt $start) {
                    $status = 'TRUST_REJECTED'
                    $code = 'SIGNER_NOT_YET_ACTIVE'
                    $exitCode = 1
                }
                elseif ($trustedNow -ge $end) {
                    $status = 'TRUST_REJECTED'
                    $code = 'SIGNER_EXPIRED'
                    $exitCode = 1
                }
                else {
                    $status = 'SIGNER_AUTHORIZED'
                    $code = 'AUTHORIZED'
                    $exitCode = 0
                }
            }
        }
    }
}
catch {
    $known = @(
        'ROOT_PIN_INVALID','ROOT_PIN_MISMATCH','ROOT_PUBLIC_KEY_INVALID',
        'INPUT_INVALID','MANIFEST_SIGNATURE_FILE_INVALID',
        'MANIFEST_SIGNATURE_INVALID','MANIFEST_SCHEMA_INVALID','TIME_INVALID'
    )
    $code = if ($known -ccontains [string]$_.Exception.Message) {
        [string]$_.Exception.Message
    } else { 'VERIFY_FAILED' }
    $status = 'VERIFICATION_FAILED'
    $exitCode = 2
}
finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if ($null -ne $sha) { $sha.Dispose() }
    foreach ($buffer in @($rootBytes,$manifestBytes,$signatureFile,$signature,
        $signerBytes,$modulus)) {
        if ($null -ne $buffer -and $buffer.Length -gt 0) {
            [Array]::Clear($buffer,0,$buffer.Length)
        }
    }
}
[pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    code = $code
    success = ($exitCode -eq 0)
    signer_public_key_sha256 = $(if ($exitCode -eq 0) { $signerDigest } else { $null })
    root_pin_verified = $rootPinVerified
    manifest_signature_verified = $manifestSignatureVerified
    trusted_epoch_checked = $trustedEpochChecked
    trusted_time_checked = $trustedTimeChecked
    read_only = $true
    private_key_loaded = $false
} | ConvertTo-Json -Compress -Depth 4
exit $exitCode
