# Read-only verification using an independently signed trust-state receipt.
# Receipt freshness depends on a fresh off-device challenge; no network calls.
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
    [Parameter(Mandatory = $true)][string]$AuthorityPublicKeyPath,
    [Parameter(Mandatory = $true)][string]$ExpectedAuthorityPublicKeySha256,
    [Parameter(Mandatory = $true)][string]$ReceiptPath,
    [Parameter(Mandatory = $true)][string]$ReceiptSignaturePath,
    [Parameter(Mandatory = $true)][string]$ExpectedChallengeNonce
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$receiptTool = Join-Path $PSScriptRoot 'Test-SumiGuardAuthorityReceipt.ps1'
$strictTool = Join-Path $PSScriptRoot 'Test-SumiGuardTrustedCheckpoint.ps1'
$status = 'VERIFICATION_FAILED'
$reason = 'VERIFICATION_FAILED'
$exitCode = 2
$receiptVerified = $false
$trustAccepted = $false
$checkpointMatches = $false

function Invoke-SumiGuardReceiptChild {
    param([Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Arguments)
    $lines = @(& $ps51 -NoLogo -NoProfile -NonInteractive -File $Script @Arguments 2>&1)
    $childCode = $LASTEXITCODE
    $raw = ($lines | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 8192) {
        throw 'CHILD_RESPONSE_INVALID'
    }
    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data -or $data -is [array]) {
            throw 'CHILD_RESPONSE_INVALID'
        }
    }
    catch { throw 'CHILD_RESPONSE_INVALID' }
    return [pscustomobject][ordered]@{ exit_code = $childCode; data = $data }
}

try {
    if (-not (Test-Path -LiteralPath $ps51 -PathType Leaf) -or
        -not (Test-Path -LiteralPath $receiptTool -PathType Leaf) -or
        -not (Test-Path -LiteralPath $strictTool -PathType Leaf)) {
        throw 'VERIFIER_UNAVAILABLE'
    }
    $receiptArgs = @(
        '-StoreKind',$StoreKind,
        '-StorePath',$StorePath,
        '-TrustManifestPath',$TrustManifestPath,
        '-ExpectedRootPublicKeySha256',$ExpectedRootPublicKeySha256,
        '-AuthorityPublicKeyPath',$AuthorityPublicKeyPath,
        '-ExpectedAuthorityPublicKeySha256',$ExpectedAuthorityPublicKeySha256,
        '-ReceiptPath',$ReceiptPath,
        '-ReceiptSignaturePath',$ReceiptSignaturePath,
        '-ExpectedChallengeNonce',$ExpectedChallengeNonce)
    $receipt = Invoke-SumiGuardReceiptChild -Script $receiptTool -Arguments $receiptArgs
    if ($receipt.exit_code -ne 0 -or
        [string]$receipt.data.status -cne 'SIGNED_RECEIPT_ACCEPTED' -or
        $receipt.data.success -ne $true -or
        $receipt.data.authority_key_pin_verified -ne $true -or
        $receipt.data.receipt_signature_verified -ne $true -or
        $receipt.data.challenge_matches -ne $true -or
        $receipt.data.store_binding_verified -ne $true -or
        $receipt.data.manifest_binding_verified -ne $true) {
        $status = 'AUTHORITY_RECEIPT_REJECTED'
        $reason = if ($receipt.data.code -is [string] -and
            [string]$receipt.data.code -cmatch '^[A-Z_]{3,48}$') {
            [string]$receipt.data.code
        } else { 'RECEIPT_INVALID' }
        $exitCode = 2
    }
    else {
        $time = [string]$receipt.data.authority_claimed_utc
        $epoch = [string]$receipt.data.minimum_manifest_epoch
        $sequence = [string]$receipt.data.minimum_checkpoint_sequence
        if ($time -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$' -or
            $epoch -cnotmatch '^[1-9][0-9]{0,17}$' -or
            $sequence -cnotmatch '^[1-9][0-9]{0,17}$') {
            throw 'RECEIPT_RESULT_INVALID'
        }
        $receiptVerified = $true
        $strictArgs = @(
            '-StoreKind',$StoreKind,
            '-StorePath',$StorePath,
            '-CheckpointPath',$CheckpointPath,
            '-SignaturePath',$SignaturePath,
            '-SignerPublicKeyPath',$SignerPublicKeyPath,
            '-PolicyPath',$PolicyPath,
            '-PolicySignaturePath',$PolicySignaturePath,
            '-RootPublicKeyPath',$RootPublicKeyPath,
            '-ExpectedRootPublicKeySha256',$ExpectedRootPublicKeySha256,
            '-TrustManifestPath',$TrustManifestPath,
            '-TrustManifestSignaturePath',$TrustManifestSignaturePath,
            '-MinimumTrustedManifestEpoch',$epoch,
            '-MinimumTrustedSequence',$sequence,
            '-TrustedNowUtc',$time)
        $strict = Invoke-SumiGuardReceiptChild -Script $strictTool -Arguments $strictArgs
        $trustAccepted = ($strict.data.root_manifest_authenticated -eq $true -and
            $strict.data.signer_authorized -eq $true -and
            $strict.data.freshness_policy_verified -eq $true)
        if ($strict.exit_code -eq 0 -and
            [string]$strict.data.status -ceq 'AUTHORIZED_CHECKPOINT_MATCH' -and
            $strict.data.success -eq $true -and
            $trustAccepted -and
            $strict.data.checkpoint_signature_verified -eq $true -and
            $strict.data.checkpoint_matches -eq $true) {
            $status = 'ATTESTED_CHECKPOINT_MATCH'
            $reason = 'MATCH'
            $exitCode = 0
            $checkpointMatches = $true
        }
        elseif ($strict.exit_code -eq 1 -and
            $trustAccepted -and
            [string]$strict.data.status -ceq 'AUTHORIZED_CHECKPOINT_CHANGED') {
            $status = 'ATTESTED_CHECKPOINT_CHANGED'
            $reason = 'CHECKPOINT_CHANGED'
            $exitCode = 1
        }
        else {
            $status = 'CHECKPOINT_REJECTED'
            $reason = if ($strict.data.code -is [string] -and
                [string]$strict.data.code -cmatch '^[A-Z_]{3,48}$') {
                [string]$strict.data.code
            } else { 'STRICT_VERIFICATION_FAILED' }
            $exitCode = if ($strict.exit_code -eq 1) { 1 } else { 2 }
        }
    }
}
catch {
    $status = 'VERIFICATION_FAILED'
    $reason = 'VERIFICATION_FAILED'
    $exitCode = 2
}
[pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    code = $reason
    success = ($exitCode -eq 0)
    signed_receipt_verified = $receiptVerified
    signer_trust_verified = $trustAccepted
    checkpoint_matches = $checkpointMatches
    offdevice_challenge_origin_verified = $false
    trusted_authority_clock_independently_verified = $false
    read_only = $true
    audit_store_modified = $false
    private_key_loaded = $false
    network_access_performed = $false
} | ConvertTo-Json -Compress -Depth 4
exit $exitCode
