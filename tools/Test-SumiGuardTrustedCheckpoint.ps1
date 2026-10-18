# Strict read-only checkpoint verification: root-signed signer authorization
# followed by checkpoint signature and signed freshness checks.
# All trust inputs MUST be obtained independently of the monitored PC.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Execution','Assessment')][string]$StoreKind,
    [Parameter(Mandatory = $true)][string]$StorePath,
    [Parameter(Mandatory = $true)][string]$CheckpointPath,
    [Parameter(Mandatory = $true)][string]$SignaturePath,
    [Parameter(Mandatory = $true)][string]$SignerPublicKeyPath,
    [Parameter(Mandatory = $true)][string]$PolicyPath,
    [Parameter(Mandatory = $true)][string]$PolicySignaturePath,
    [Parameter(Mandatory = $true)][string]$RootPublicKeyPath,
    [Parameter(Mandatory = $true)][string]$ExpectedRootPublicKeySha256,
    [Parameter(Mandatory = $true)][string]$TrustManifestPath,
    [Parameter(Mandatory = $true)][string]$TrustManifestSignaturePath,
    [Parameter(Mandatory = $true)][ValidateRange(1,2147483647)][long]$MinimumTrustedManifestEpoch,
    [Parameter(Mandatory = $true)][ValidateRange(1,2147483647)][long]$MinimumTrustedSequence,
    [Parameter(Mandatory = $true)][string]$TrustedNowUtc
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$trustTool = Join-Path $PSScriptRoot 'Test-SumiGuardSignerTrust.ps1'
$checkpointTool = Join-Path $PSScriptRoot 'Test-SumiGuardSignedCheckpoint.ps1'
$status = 'VERIFICATION_FAILED'
$code = 'VERIFICATION_FAILED'
$exitCode = 2
$rootVerified = $false
$signerAuthorized = $false
$checkpointSignatureVerified = $false
$policyVerified = $false
$checkpointMatches = $false

function Invoke-SumiGuardChild {
    param([Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Arguments)
    $lines = @(& $ps51 -NoLogo -NoProfile -NonInteractive -File $Script @Arguments 2>&1)
    $childCode = $LASTEXITCODE
    $json = ($lines | Out-String).Trim()
    if ($json.Length -gt 8192 -or [string]::IsNullOrWhiteSpace($json)) {
        throw 'INVALID_CHILD_RESPONSE'
    }
    try {
        $response = $json | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $response -or $response -is [array]) {
            throw 'INVALID_CHILD_RESPONSE'
        }
    }
    catch { throw 'INVALID_CHILD_RESPONSE' }
    return [pscustomobject][ordered]@{
        exit_code = $childCode
        data = $response
    }
}

try {
    if (-not (Test-Path -LiteralPath $ps51 -PathType Leaf) -or
        -not (Test-Path -LiteralPath $trustTool -PathType Leaf) -or
        -not (Test-Path -LiteralPath $checkpointTool -PathType Leaf)) {
        throw 'VERIFIER_UNAVAILABLE'
    }
    $trustArgs = @(
        '-RootPublicKeyPath', $RootPublicKeyPath,
        '-ExpectedRootPublicKeySha256', $ExpectedRootPublicKeySha256,
        '-TrustManifestPath', $TrustManifestPath,
        '-TrustManifestSignaturePath', $TrustManifestSignaturePath,
        '-SignerPublicKeyPath', $SignerPublicKeyPath,
        '-MinimumTrustedManifestEpoch', [string]$MinimumTrustedManifestEpoch,
        '-TrustedNowUtc', $TrustedNowUtc)
    $trust = Invoke-SumiGuardChild -Script $trustTool -Arguments $trustArgs
    $rootVerified = ($trust.data.root_pin_verified -eq $true -and
        $trust.data.manifest_signature_verified -eq $true)
    if ($trust.exit_code -ne 0 -or
        $trust.data.status -cne 'SIGNER_AUTHORIZED' -or
        $trust.data.success -ne $true -or
        $trust.data.trusted_epoch_checked -ne $true -or
        $trust.data.trusted_time_checked -ne $true) {
        $status = 'TRUST_REJECTED'
        $code = if ($trust.data.code -is [string] -and
            [string]$trust.data.code -cmatch '^[A-Z_]{3,40}$') {
            [string]$trust.data.code
        } else { 'TRUST_INVALID' }
        $exitCode = if ($trust.exit_code -eq 1) { 1 } else { 2 }
    }
    else {
        $pin = [string]$trust.data.signer_public_key_sha256
        if ($pin -cnotmatch '^[a-f0-9]{64}$') {
            throw 'TRUST_INVALID'
        }
        $signerAuthorized = $true
        $checkpointArgs = @(
            '-StoreKind', $StoreKind,
            '-StorePath', $StorePath,
            '-CheckpointPath', $CheckpointPath,
            '-SignaturePath', $SignaturePath,
            '-PublicKeyPath', $SignerPublicKeyPath,
            '-ExpectedPublicKeySha256', $pin,
            '-PolicyPath', $PolicyPath,
            '-PolicySignaturePath', $PolicySignaturePath,
            '-MinimumTrustedSequence', [string]$MinimumTrustedSequence,
            '-TrustedNowUtc', $TrustedNowUtc)
        $checkpoint = Invoke-SumiGuardChild -Script $checkpointTool -Arguments $checkpointArgs
        $checkpointSignatureVerified = $checkpoint.data.checkpoint_signature_verified -eq $true
        $policyVerified = $checkpoint.data.signed_policy_verified -eq $true -and
            $checkpoint.data.policy_floor_checked -eq $true -and
            $checkpoint.data.policy_time_checked -eq $true
        if ($checkpoint.exit_code -eq 0 -and
            $checkpoint.data.status -ceq 'AUTHENTIC_CHECKPOINT_MATCH' -and
            $checkpoint.data.success -eq $true -and
            $checkpointSignatureVerified -and $policyVerified -and
            $checkpoint.data.store_matches_checkpoint -eq $true) {
            $status = 'AUTHORIZED_CHECKPOINT_MATCH'
            $code = 'MATCH'
            $exitCode = 0
            $checkpointMatches = $true
        }
        elseif ($checkpoint.exit_code -eq 1 -and
            $checkpoint.data.status -ceq 'AUTHENTIC_CHECKPOINT_MISMATCH' -and
            $checkpointSignatureVerified -and $policyVerified) {
            $status = 'AUTHORIZED_CHECKPOINT_CHANGED'
            $code = 'CHECKPOINT_CHANGED'
            $exitCode = 1
        }
        else {
            $status = 'VERIFICATION_FAILED'
            $code = if ($checkpoint.data.reason_code -is [string] -and
                [string]$checkpoint.data.reason_code -cmatch '^[A-Z_]{3,40}$') {
                [string]$checkpoint.data.reason_code
            } else { 'CHECKPOINT_REJECTED' }
            $exitCode = 2
        }
    }
}
catch {
    $status = 'VERIFICATION_FAILED'
    $code = 'VERIFY_FAILED'
    $exitCode = 2
}
[pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    code = $code
    success = $exitCode -eq 0
    root_manifest_authenticated = $rootVerified
    signer_authorized = $signerAuthorized
    checkpoint_signature_verified = $checkpointSignatureVerified
    freshness_policy_verified = $policyVerified
    checkpoint_matches = $checkpointMatches
    read_only = $true
    network_time_fetched = $false
    trusted_external_time_verified = $false
    private_key_loaded = $false
    audit_store_modified = $false
} | ConvertTo-Json -Compress -Depth 4
exit $exitCode
