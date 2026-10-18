# Synthetic trust lifecycle tests. All RSA private keys remain in memory.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Repo = Split-Path -Parent $PSScriptRoot
$script:TrustTool = Join-Path $script:Repo 'tools\Test-SumiGuardSignerTrust.ps1'
$script:Wrapper = Join-Path $script:Repo 'tools\Test-SumiGuardTrustedCheckpoint.ps1'
$script:ReceiptVerifier = Join-Path $script:Repo 'tools\Test-SumiGuardAuthorityReceipt.ps1'
$script:AttestedWrapper = Join-Path $script:Repo 'tools\Test-SumiGuardAttestedCheckpoint.ps1'
$script:AuditTool = Join-Path $script:Repo 'tools\Test-SumiGuardAuditIntegrity.ps1'
$script:Ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8 = New-Object Text.UTF8Encoding($false,$true)
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Stage = 'INIT'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = Join-Path $tempRoot ('sumi-guard-trust-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$failure = $null
$script:RootRsa = $null
$script:SignerA = $null
$script:SignerB = $null
$script:AuthorityRsa = $null
$script:TrustedUtc = '2026-10-18T09:00:00Z'
$script:ExternalEpochFloor = 42

function Add-Check {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',
        Justification = 'Stores disposable synthetic-test check results in memory.')]
    param([string]$Name,[bool]$Pass)
    $script:Results.Add([pscustomobject]@{ name=$Name; pass=$Pass })
}

function Write-PublicKeyFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',
        Justification = 'Writes only a disposable public key, never a private key.')]
    param($Rsa,[string]$Path)
    $key = $Rsa.ExportParameters($false)
    $public = [ordered]@{
        schema_version = 1
        algorithm = 'RSA-SHA256-PKCS1-v1_5'
        modulus_base64 = [Convert]::ToBase64String($key.Modulus)
        exponent_base64 = [Convert]::ToBase64String($key.Exponent)
    }
    [IO.File]::WriteAllText($Path,($public | ConvertTo-Json -Compress),$script:Utf8)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-SignedFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',
        Justification = 'Creates detached test signatures using in-memory synthetic keys.')]
    param($Rsa,[string]$InputPath,[string]$SignaturePath)
    [byte[]]$inputBytes = [IO.File]::ReadAllBytes($InputPath)
    try {
        [byte[]]$sig = $Rsa.SignData(
            $inputBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        try {
            [IO.File]::WriteAllText($SignaturePath,[Convert]::ToBase64String($sig),$script:Utf8)
        }
        finally { [Array]::Clear($sig,0,$sig.Length) }
    }
    finally { [Array]::Clear($inputBytes,0,$inputBytes.Length) }
}

function Write-TrustManifestFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',
        Justification = 'Only modifies disposable test manifest data.')]
    param([string]$StateA='ACTIVE',[string]$StateB='ACTIVE',
        [int]$Epoch=42,[string]$Expiry='2026-10-18T10:00:00Z')
    $manifest = [ordered]@{
        schema_version = 1
        record_type = 'SumiGuardSignerTrustManifest'
        manifest_epoch = $Epoch
        issued_at_utc = '2026-10-18T08:00:00Z'
        expires_at_utc = $Expiry
        signers = @(
            [ordered]@{
                public_key_sha256=$script:PinA;purpose='AUDIT_CHECKPOINT'
                state=$StateA;not_before_utc='2026-10-18T08:00:00Z'
                not_after_utc='2026-10-18T12:00:00Z'
            },
            [ordered]@{
                public_key_sha256=$script:PinB;purpose='AUDIT_CHECKPOINT'
                state=$StateB;not_before_utc='2026-10-18T08:00:00Z'
                not_after_utc='2026-10-18T12:00:00Z'
            }
        )
    }
    [IO.File]::WriteAllText($script:TrustManifestPath,
        ($manifest | ConvertTo-Json -Compress -Depth 7),$script:Utf8)
    Write-SignedFixture -Rsa $script:RootRsa -InputPath $script:TrustManifestPath -SignaturePath $script:TrustSigPath
}

function Invoke-TrustFixture {
    param([string]$SignerPath,[string]$RootPin,[string]$NowUtc='2026-10-18T09:00:00Z',
        [int]$MinEpoch=$script:ExternalEpochFloor)
    $argsList = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$script:TrustTool,
        '-RootPublicKeyPath',$script:RootPublicPath,
        '-ExpectedRootPublicKeySha256',$RootPin,
        '-TrustManifestPath',$script:TrustManifestPath,
        '-TrustManifestSignaturePath',$script:TrustSigPath,
        '-SignerPublicKeyPath',$SignerPath,
        '-MinimumTrustedManifestEpoch',[string]$MinEpoch,
        '-TrustedNowUtc',$NowUtc)
    $lines = @(& $script:Ps51 @argsList)
    $childExit = $LASTEXITCODE
    return [pscustomobject]@{
        exit_code = $childExit
        data = (($lines -join [Environment]::NewLine).Trim() | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Invoke-FullFixture {
    param([string]$SignerPath,[string]$CheckpointSig,[string]$PolicySig,[string]$RootPin)
    $argsList = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$script:Wrapper,
        '-StoreKind','Execution','-StorePath',$script:StorePath,
        '-CheckpointPath',$script:CheckpointPath,
        '-SignaturePath',$CheckpointSig,
        '-SignerPublicKeyPath',$SignerPath,
        '-PolicyPath',$script:PolicyPath,
        '-PolicySignaturePath',$PolicySig,
        '-RootPublicKeyPath',$script:RootPublicPath,
        '-ExpectedRootPublicKeySha256',$RootPin,
        '-TrustManifestPath',$script:TrustManifestPath,
        '-TrustManifestSignaturePath',$script:TrustSigPath,
        '-MinimumTrustedManifestEpoch',[string]$script:ExternalEpochFloor,
        '-MinimumTrustedSequence','42',
        '-TrustedNowUtc',$script:TrustedUtc)
    $lines = @(& $script:Ps51 @argsList)
    $childExit = $LASTEXITCODE
    return [pscustomobject]@{
        exit_code=$childExit
        data=(($lines -join [Environment]::NewLine).Trim() | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Write-AuthorityReceiptFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',
        Justification = 'Only signs synthetic receipt JSON under a GUID test directory.')]
    param(
        [string]$Nonce = $script:AuthorityChallenge,
        [string]$TrustedAt = '2026-10-18T09:00:00Z',
        [string]$Issued = '2026-10-18T08:59:59Z',
        [string]$Expires = '2026-10-18T09:01:59Z'
    )
    $storeMarker = Join-Path $script:StorePath '.sumi-guard-execution-store.json'
    $message = [ordered]@{
        schema_version = 1
        record_type = 'SumiGuardAuthorityReceipt'
        purpose = 'CHECKPOINT_TRUST_STATE'
        challenge_nonce = $Nonce
        store_kind = 'Execution'
        store_marker_sha256 = (Get-FileHash -LiteralPath $storeMarker -Algorithm SHA256).Hash.ToLowerInvariant()
        trust_manifest_sha256 = (Get-FileHash -LiteralPath $script:TrustManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        root_public_key_sha256 = $script:RootPin
        minimum_manifest_epoch = 42
        minimum_checkpoint_sequence = 42
        trusted_at_utc = $TrustedAt
        issued_at_utc = $Issued
        expires_at_utc = $Expires
    }
    [IO.File]::WriteAllText($script:ReceiptPath,
        ($message | ConvertTo-Json -Compress),$script:Utf8)
    Write-SignedFixture -Rsa $script:AuthorityRsa -InputPath $script:ReceiptPath -SignaturePath $script:ReceiptSigPath
}

function Invoke-ReceiptFixture {
    param(
        [string]$Challenge = $script:AuthorityChallenge,
        [string]$AuthorityPin = $script:AuthorityPin,
        [string]$RootPin = $script:RootPin
    )
    $parts = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$script:ReceiptVerifier,
        '-StoreKind','Execution','-StorePath',$script:StorePath,
        '-TrustManifestPath',$script:TrustManifestPath,
        '-ExpectedRootPublicKeySha256',$RootPin,
        '-AuthorityPublicKeyPath',$script:AuthorityPublicPath,
        '-ExpectedAuthorityPublicKeySha256',$AuthorityPin,
        '-ReceiptPath',$script:ReceiptPath,
        '-ReceiptSignaturePath',$script:ReceiptSigPath,
        '-ExpectedChallengeNonce',$Challenge)
    $lines = @(& $script:Ps51 @parts)
    $childExit = $LASTEXITCODE
    return [pscustomobject]@{
        exit_code = $childExit
        data = (($lines -join [Environment]::NewLine).Trim() | ConvertFrom-Json -ErrorAction Stop)
    }
}

function Invoke-AttestedFixture {
    param(
        [string]$Challenge = $script:AuthorityChallenge,
        [string]$AuthorityPin = $script:AuthorityPin
    )
    $parts = @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$script:AttestedWrapper,
        '-StoreKind','Execution','-StorePath',$script:StorePath,
        '-CheckpointPath',$script:CheckpointPath,
        '-SignaturePath',$script:SignatureA,
        '-SignerPublicKeyPath',$script:SignerKeyA,
        '-PolicyPath',$script:PolicyPath,
        '-PolicySignaturePath',$script:PolicySignatureA,
        '-RootPublicKeyPath',$script:RootPublicPath,
        '-ExpectedRootPublicKeySha256',$script:RootPin,
        '-TrustManifestPath',$script:TrustManifestPath,
        '-TrustManifestSignaturePath',$script:TrustSigPath,
        '-AuthorityPublicKeyPath',$script:AuthorityPublicPath,
        '-ExpectedAuthorityPublicKeySha256',$AuthorityPin,
        '-ReceiptPath',$script:ReceiptPath,
        '-ReceiptSignaturePath',$script:ReceiptSigPath,
        '-ExpectedChallengeNonce',$Challenge)
    $lines = @(& $script:Ps51 @parts)
    $childExit = $LASTEXITCODE
    return [pscustomobject]@{
        exit_code = $childExit
        data = (($lines -join [Environment]::NewLine).Trim() | ConvertFrom-Json -ErrorAction Stop)
    }
}

try {
    if (-not $work.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $work) -cnotmatch '^sumi-guard-trust-lifecycle-[0-9a-f]{32}$') {
        throw 'UNSAFE_TEMP_PATH'
    }
    $null = New-Item -ItemType Directory -Path $work -ErrorAction Stop
    $script:StorePath = Join-Path $work 'execution-store'
    $null = New-Item -ItemType Directory -Path $script:StorePath -ErrorAction Stop
    $marker = [ordered]@{
        schema_version=1;store_id=[Guid]::NewGuid().ToString('N')
        body_provider='SumiGuard.LocalStore'
    }
    [IO.File]::WriteAllText((Join-Path $script:StorePath '.sumi-guard-execution-store.json'),
        ($marker | ConvertTo-Json -Compress),$script:Utf8)
    $lockStream = New-Object IO.FileStream(
        (Join-Path $script:StorePath '.sumi-guard-execution-store.lock'),
        [IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $lockStream.Dispose()
    $record = [ordered]@{
        schema_version=1;record_id=[Guid]::NewGuid().ToString('N')
        record_type='ExecutionIntentRecorded';execution_id=[Guid]::NewGuid().ToString('N')
        occurred_at_utc=$script:TrustedUtc;body_sha256=('a'*64)
        content_status='HASH_ONLY';collection_status='RECORDS_FOUND'
        body_ref=$null
    }
    $eventPath = Join-Path $script:StorePath 'events.ndjson'
    [IO.File]::WriteAllText($eventPath,
        (($record | ConvertTo-Json -Compress)+[Environment]::NewLine),$script:Utf8)
    $initialHash = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    $script:Stage = 'CRYPTO_SETUP'
    $script:RootRsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    $script:SignerA = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    $script:SignerB = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    # Use disposable in-memory test keys, never persistent CSP key containers.
    foreach ($ephemeral in @($script:RootRsa,$script:SignerA,$script:SignerB)) {
        $ephemeral.PersistKeyInCsp = $false
    }
    $script:RootPublicPath = Join-Path $work 'root-key.json'
    $keyAPath = Join-Path $work 'signer-a.json'
    $keyBPath = Join-Path $work 'signer-b.json'
    $rootPin = Write-PublicKeyFixture -Rsa $script:RootRsa -Path $script:RootPublicPath
    $script:PinA = Write-PublicKeyFixture -Rsa $script:SignerA -Path $keyAPath
    $script:PinB = Write-PublicKeyFixture -Rsa $script:SignerB -Path $keyBPath

    $script:CheckpointPath = Join-Path $work 'checkpoint.json'
    $rawOutput = @(& $script:Ps51 -NoLogo -NoProfile -NonInteractive -File $script:AuditTool -StoreKind Execution -StorePath $script:StorePath -Action Snapshot)
    if ($LASTEXITCODE -ne 0) { throw 'SNAPSHOT_FAILED' }
    $checkpointJson = ($rawOutput -join [Environment]::NewLine).Trim()
    [IO.File]::WriteAllText($script:CheckpointPath,$checkpointJson,$script:Utf8)
    $sigA = Join-Path $work 'checkpoint-a.sig'
    $sigB = Join-Path $work 'checkpoint-b.sig'
    Write-SignedFixture -Rsa $script:SignerA -InputPath $script:CheckpointPath -SignaturePath $sigA
    Write-SignedFixture -Rsa $script:SignerB -InputPath $script:CheckpointPath -SignaturePath $sigB
    $script:PolicyPath = Join-Path $work 'checkpoint-policy.json'
    $snapshotDigest = (Get-FileHash -LiteralPath $script:CheckpointPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $policy = [ordered]@{
        schema_version=1;record_type='SignedAuditCheckpointPolicy'
        store_kind='Execution';checkpoint_sha256=$snapshotDigest;sequence=42
        issued_at_utc='2026-10-18T08:00:00Z'
        expires_at_utc='2026-10-18T10:00:00Z'
    }
    [IO.File]::WriteAllText($script:PolicyPath,($policy | ConvertTo-Json -Compress),$script:Utf8)
    $policySigA = Join-Path $work 'policy-a.sig'
    $policySigB = Join-Path $work 'policy-b.sig'
    Write-SignedFixture -Rsa $script:SignerA -InputPath $script:PolicyPath -SignaturePath $policySigA
    Write-SignedFixture -Rsa $script:SignerB -InputPath $script:PolicyPath -SignaturePath $policySigB
    # No need to retain signing leaf keys after generating synthetic evidence.
    $script:SignerA.Dispose()
    $script:SignerA = $null
    $script:SignerB.Dispose()
    $script:SignerB = $null
    $script:TrustManifestPath = Join-Path $work 'root-signed-trust.json'
    $script:TrustSigPath = Join-Path $work 'root-signed-trust.sig'
    Write-TrustManifestFixture


    # Independent synthetic trust-state authority; only its public key leaves memory.
    $script:Stage = 'AUTHORITY_SETUP'
    $script:AuthorityRsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    $script:AuthorityRsa.PersistKeyInCsp = $false
    $script:AuthorityPublicPath = Join-Path $work 'authority-public.json'
    $script:AuthorityPin = Write-PublicKeyFixture -Rsa $script:AuthorityRsa -Path $script:AuthorityPublicPath
    $script:RootPin = $rootPin
    $script:SignerKeyA = $keyAPath
    $script:SignatureA = $sigA
    $script:PolicySignatureA = $policySigA
    $script:AuthorityChallenge = ('a' * 64)
    $script:ReceiptPath = Join-Path $work 'authority-receipt.json'
    $script:ReceiptSigPath = Join-Path $work 'authority-receipt.sig'
    Write-AuthorityReceiptFixture

    $script:Stage = 'SIGNED_RECEIPT'
    $acceptedReceipt = Invoke-ReceiptFixture
    Add-Check -Name 'ROOT_INDEPENDENT_SIGNED_RECEIPT_ACCEPTED' -Pass (
        $acceptedReceipt.exit_code -eq 0 -and
        $acceptedReceipt.data.status -ceq 'SIGNED_RECEIPT_ACCEPTED' -and
        $acceptedReceipt.data.receipt_signature_verified -eq $true -and
        $acceptedReceipt.data.challenge_matches -eq $true -and
        $acceptedReceipt.data.store_binding_verified -eq $true -and
        $acceptedReceipt.data.manifest_binding_verified -eq $true -and
        $acceptedReceipt.data.challenge_origin_verified -eq $false)

    $script:Stage = 'ATTESTED_FULL_VERIFICATION'
    $attested = Invoke-AttestedFixture
    Add-Check -Name 'SIGNED_RECEIPT_AUTHORIZES_COMPLETE_READONLY_CHECK' -Pass (
        $attested.exit_code -eq 0 -and
        $attested.data.status -ceq 'ATTESTED_CHECKPOINT_MATCH' -and
        $attested.data.signed_receipt_verified -eq $true -and
        $attested.data.signer_trust_verified -eq $true -and
        $attested.data.checkpoint_matches -eq $true -and
        $attested.data.private_key_loaded -eq $false)

    $script:Stage = 'CHALLENGE_SWAP'
    $badNonce = ('b' * 64)
    $wrongChallenge = Invoke-ReceiptFixture -Challenge $badNonce
    Add-Check -Name 'CHALLENGE_NONCE_MISMATCH_REJECTED' -Pass (
        $wrongChallenge.exit_code -eq 2 -and
        $wrongChallenge.data.code -ceq 'CHALLENGE_MISMATCH')
    $strictWrongChallenge = Invoke-AttestedFixture -Challenge $badNonce
    Add-Check -Name 'WRONG_CHALLENGE_NEVER_REACHES_CHECKPOINT' -Pass (
        $strictWrongChallenge.exit_code -eq 2 -and
        $strictWrongChallenge.data.status -ceq 'AUTHORITY_RECEIPT_REJECTED' -and
        $strictWrongChallenge.data.signer_trust_verified -eq $false)

    $script:Stage = 'AUTHORITY_PIN_SWAP'
    $badAuthorityPin = if ($script:AuthorityPin[0] -ceq 'a') {
        'b' + $script:AuthorityPin.Substring(1)
    } else { 'a' + $script:AuthorityPin.Substring(1) }
    $wrongAuthority = Invoke-ReceiptFixture -AuthorityPin $badAuthorityPin
    Add-Check -Name 'INDEPENDENT_AUTHORITY_PIN_MISMATCH_REJECTED' -Pass (
        $wrongAuthority.exit_code -eq 2 -and
        $wrongAuthority.data.code -ceq 'AUTHORITY_PIN_MISMATCH')

    $script:Stage = 'CHALLENGE_FORMAT'
    $badFormat = Invoke-ReceiptFixture -Challenge 'invalid'
    Add-Check -Name 'INVALID_NONCE_FORMAT_REJECTED' -Pass (
        $badFormat.exit_code -eq 2 -and
        $badFormat.data.code -ceq 'TRUST_INPUT_INVALID')

    $script:Stage = 'AUTHORITY_KEY_SEPARATION'
    $sameKey = Invoke-ReceiptFixture -AuthorityPin $script:RootPin
    Add-Check -Name 'AUTHORITY_AND_ROOT_MUST_BE_SEPARATE_KEYS' -Pass (
        $sameKey.exit_code -eq 2 -and
        $sameKey.data.code -ceq 'AUTHORITY_KEY_NOT_SEPARATE')

    $script:Stage = 'ROOT_PIN_BINDING'
    $badRootPin = if ($script:RootPin[0] -ceq 'a') {
        'b' + $script:RootPin.Substring(1)
    } else { 'a' + $script:RootPin.Substring(1) }
    $wrongRootBinding = Invoke-ReceiptFixture -RootPin $badRootPin
    Add-Check -Name 'RECEIPT_BINDS_EXPECTED_ROOT_PUBLIC_KEY' -Pass (
        $wrongRootBinding.exit_code -eq 2 -and
        $wrongRootBinding.data.code -ceq 'ROOT_BINDING_MISMATCH')

    $script:Stage = 'SIGNED_RECEIPT_MUTATION'
    $receiptOriginal = [IO.File]::ReadAllText($script:ReceiptPath,$script:Utf8)
    [IO.File]::WriteAllText($script:ReceiptPath,
        $receiptOriginal.Replace('"minimum_manifest_epoch":42','"minimum_manifest_epoch":43'),
        $script:Utf8)
    $tamperedReceipt = Invoke-ReceiptFixture
    Add-Check -Name 'RECEIPT_EDIT_WITH_OLD_SIGNATURE_REJECTED' -Pass (
        $tamperedReceipt.exit_code -eq 2 -and
        $tamperedReceipt.data.code -ceq 'RECEIPT_SIGNATURE_INVALID')
    [IO.File]::WriteAllText($script:ReceiptPath,$receiptOriginal,$script:Utf8)

    $script:Stage = 'MANIFEST_BINDING'
    Write-TrustManifestFixture -Epoch 43
    $differentManifest = Invoke-ReceiptFixture
    Add-Check -Name 'RECEIPT_BINDS_TRUST_MANIFEST_DIGEST' -Pass (
        $differentManifest.exit_code -eq 2 -and
        $differentManifest.data.code -ceq 'MANIFEST_BINDING_MISMATCH')
    Write-TrustManifestFixture -Epoch 42

    $script:Stage = 'ATTESTED_REVOKED_SIGNER'
    Write-TrustManifestFixture -StateA REVOKED -Epoch 43
    Write-AuthorityReceiptFixture
    $revokeAttested = Invoke-AttestedFixture
    Add-Check -Name 'ATTESTED_GATEWAY_REFUSES_REVOKED_SIGNER' -Pass (
        $revokeAttested.exit_code -eq 1 -and
        $revokeAttested.data.status -ceq 'CHECKPOINT_REJECTED' -and
        $revokeAttested.data.code -ceq 'SIGNER_REVOKED' -and
        $revokeAttested.data.signed_receipt_verified -eq $true -and
        $revokeAttested.data.signer_trust_verified -eq $false)
    Write-TrustManifestFixture -Epoch 42
    Write-AuthorityReceiptFixture

    $script:Stage = 'STORE_MARKER_BINDING'
    $markerPath = Join-Path $script:StorePath '.sumi-guard-execution-store.json'
    $markerOriginal = [IO.File]::ReadAllText($markerPath,$script:Utf8)
    [IO.File]::WriteAllText($markerPath,($markerOriginal + ' '),$script:Utf8)
    $differentStore = Invoke-ReceiptFixture
    Add-Check -Name 'RECEIPT_BINDS_STORE_MARKER_DIGEST' -Pass (
        $differentStore.exit_code -eq 2 -and
        $differentStore.data.code -ceq 'STORE_BINDING_MISMATCH')
    [IO.File]::WriteAllText($markerPath,$markerOriginal,$script:Utf8)

    $script:Stage = 'SIGNED_WIDE_WINDOW'
    Write-AuthorityReceiptFixture -Expires '2026-10-18T09:02:01Z'
    $wide = Invoke-ReceiptFixture
    Add-Check -Name 'SIGNED_RECEIPT_WINDOW_OVER_TWO_MINUTES_REJECTED' -Pass (
        $wide.exit_code -eq 2 -and
        $wide.data.code -ceq 'RECEIPT_WINDOW_INVALID')
    Write-AuthorityReceiptFixture

    $script:Stage = 'SIGNED_NONUTC_CLAIM'
    Write-AuthorityReceiptFixture -TrustedAt '2026-10-18T18:00:00+09:00'
    $wrongUtc = Invoke-ReceiptFixture
    Add-Check -Name 'NON_UTC_TIME_CLAIM_REJECTED' -Pass (
        $wrongUtc.exit_code -eq 2 -and
        $wrongUtc.data.code -ceq 'RECEIPT_TIME_INVALID')
    Write-AuthorityReceiptFixture

    $script:Stage = 'ACTIVE_CHECKPOINT'
    $active = Invoke-FullFixture -SignerPath $keyAPath -CheckpointSig $sigA -PolicySig $policySigA -RootPin $rootPin
    Add-Check -Name 'ROOT_SIGNED_ACTIVE_CHECKPOINT_ACCEPTED' -Pass (
        $active.exit_code -eq 0 -and $active.data.status -ceq 'AUTHORIZED_CHECKPOINT_MATCH' -and
        $active.data.root_manifest_authenticated -eq $true -and
        $active.data.freshness_policy_verified -eq $true)

    $script:Stage = 'KEY_ROTATION'
    $rotated = Invoke-FullFixture -SignerPath $keyBPath -CheckpointSig $sigB -PolicySig $policySigB -RootPin $rootPin
    Add-Check -Name 'SECOND_ACTIVE_SIGNER_ACCEPTED' -Pass (
        $rotated.exit_code -eq 0 -and $rotated.data.signer_authorized -eq $true)

    $script:Stage = 'ROOT_PIN'
    $wrongPin = if ($rootPin[0] -ceq 'a') { 'b'+$rootPin.Substring(1) }
        else { 'a'+$rootPin.Substring(1) }
    $wrongRoot = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $wrongPin
    Add-Check -Name 'ROOT_PIN_SUBSTITUTION_REJECTED' -Pass (
        $wrongRoot.exit_code -eq 2 -and $wrongRoot.data.code -ceq 'ROOT_PIN_MISMATCH')

    $script:Stage = 'REVOKED'
    # The offline authority increments the signed epoch; an independent
    # registry must advance the minimum floor to make the old manifest stale.
    Write-TrustManifestFixture -StateA REVOKED -Epoch 43
    $script:ExternalEpochFloor = 43
    $revoked = Invoke-FullFixture -SignerPath $keyAPath -CheckpointSig $sigA -PolicySig $policySigA -RootPin $rootPin
    Add-Check -Name 'REVOKED_SIGNER_BLOCKED_BEFORE_CHECKPOINT_CHECK' -Pass (
        $revoked.exit_code -eq 1 -and $revoked.data.code -ceq 'SIGNER_REVOKED' -and
        $revoked.data.checkpoint_signature_verified -eq $false)

    $script:Stage = 'NEW_KEY_AFTER_REVOCATION'
    $healthy = Invoke-FullFixture -SignerPath $keyBPath -CheckpointSig $sigB -PolicySig $policySigB -RootPin $rootPin
    Add-Check -Name 'ROTATED_SIGNER_ACTIVE_AFTER_REVOCATION' -Pass (
        $healthy.exit_code -eq 0 -and $healthy.data.status -ceq 'AUTHORIZED_CHECKPOINT_MATCH')

    $script:Stage = 'RETIRED'
    Write-TrustManifestFixture -StateA REVOKED -StateB RETIRED -Epoch 44
    $script:ExternalEpochFloor = 44
    $retired = Invoke-TrustFixture -SignerPath $keyBPath -RootPin $rootPin
    Add-Check -Name 'RETIRED_SIGNER_REJECTED' -Pass (
        $retired.exit_code -eq 1 -and $retired.data.code -ceq 'SIGNER_RETIRED')

    $script:Stage = 'STALE_MANIFEST'
    Write-TrustManifestFixture -Epoch 41
    $stale = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $rootPin
    Add-Check -Name 'OLD_ROOT_SIGNED_MANIFEST_REJECTED' -Pass (
        $stale.exit_code -eq 1 -and $stale.data.code -ceq 'MANIFEST_EPOCH_BELOW_FLOOR')

    $script:Stage = 'EXPIRED_MANIFEST'
    Write-TrustManifestFixture -Epoch 44 -Expiry '2026-10-18T08:59:59Z'
    $expired = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $rootPin
    Add-Check -Name 'EXPIRED_ROOT_SIGNED_MANIFEST_REJECTED' -Pass (
        $expired.exit_code -eq 1 -and $expired.data.code -ceq 'MANIFEST_EXPIRED')

    $script:Stage = 'UNKNOWN_KEY'
    Write-TrustManifestFixture -Epoch 44
    $unknownPath = Join-Path $work 'unknown-signer-key.json'
    $existingSignerJson = [IO.File]::ReadAllText($keyBPath,$script:Utf8)
    [IO.File]::WriteAllText($unknownPath,($existingSignerJson + ' '),$script:Utf8)
    $unknown = Invoke-TrustFixture -SignerPath $unknownPath -RootPin $rootPin
    Add-Check -Name 'SIGNER_NOT_IN_ROOT_MANIFEST_REJECTED' -Pass (
        $unknown.exit_code -eq 1 -and $unknown.data.code -ceq 'SIGNER_UNKNOWN')

    $script:Stage = 'INVALID_TRUSTED_UTC'
    $wrongTime = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $rootPin -NowUtc '2026-10-18T18:00:00+09:00'
    Add-Check -Name 'NON_UTC_TRUST_REFERENCE_REJECTED' -Pass (
        $wrongTime.exit_code -eq 2 -and $wrongTime.data.code -ceq 'TIME_INVALID')

    $script:Stage = 'DUPLICATE_TRUSTED_SIGNER'
    $manifestText = [IO.File]::ReadAllText($script:TrustManifestPath,$script:Utf8)
    [IO.File]::WriteAllText($script:TrustManifestPath,
        $manifestText.Replace($script:PinB,$script:PinA),$script:Utf8)
    Write-SignedFixture -Rsa $script:RootRsa -InputPath $script:TrustManifestPath -SignaturePath $script:TrustSigPath
    $duplicate = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $rootPin
    Add-Check -Name 'DUPLICATE_SIGNER_IN_VALIDLY_SIGNED_MANIFEST_REJECTED' -Pass (
        $duplicate.exit_code -eq 2 -and $duplicate.data.code -ceq 'MANIFEST_SCHEMA_INVALID')
    Write-TrustManifestFixture -Epoch 44

    $script:Stage = 'MANIFEST_TAMPERING'
    Write-TrustManifestFixture -Epoch 44
    $beforeManifest = [IO.File]::ReadAllText($script:TrustManifestPath,$script:Utf8)
    [IO.File]::WriteAllText($script:TrustManifestPath,
        $beforeManifest.Replace('"state":"ACTIVE"','"state":"REVOKED"'),$script:Utf8)
    $forged = Invoke-TrustFixture -SignerPath $keyAPath -RootPin $rootPin
    Add-Check -Name 'MODIFIED_TRUST_MANIFEST_SIGNATURE_REJECTED' -Pass (
        $forged.exit_code -eq 2 -and $forged.data.code -ceq 'MANIFEST_SIGNATURE_INVALID')

    $script:Stage = 'FINAL_READONLY'
    Add-Check -Name 'AUDIT_RECORDS_UNMODIFIED' -Pass (
        (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash -ceq $initialHash)
}
catch {
    $failure = [pscustomobject]@{
        stage = [string]$script:Stage
        exception_type = $_.Exception.GetType().FullName
    }
}
finally {
    foreach ($privateKey in @($script:RootRsa,$script:SignerA,$script:SignerB,$script:AuthorityRsa)) {
        if ($null -ne $privateKey) { $privateKey.Dispose() }
    }
    if (Test-Path -LiteralPath $work) {
        $full = [IO.Path]::GetFullPath($work)
        if ($full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $full) -cmatch '^sumi-guard-trust-lifecycle-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
        else { $failure = [pscustomobject]@{stage='UNSAFE_CLEANUP_PATH'} }
    }
}
$bad = @($script:Results | Where-Object { -not $_.pass })
$passed = $null -eq $failure -and $bad.Count -eq 0
[pscustomobject][ordered]@{
    success = $passed
    test_count = $script:Results.Count
    passed_count = $script:Results.Count-$bad.Count
    failed_cases = @($bad | ForEach-Object { $_.name })
    failure = $failure
    fixture_cleaned = -not (Test-Path -LiteralPath $work)
    operational_private_keys_exported = $false
    production_store_accessed = $false
    network_calls_made = $false
} | ConvertTo-Json -Compress -Depth 5
if ($passed) { exit 0 } else { exit 1 }
