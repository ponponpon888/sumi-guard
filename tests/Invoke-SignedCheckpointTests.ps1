# Disposable RSA signing and verification tests. No production keys or stores.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:VerifierPath = Join-Path $script:Root 'tools\Test-SumiGuardSignedCheckpoint.ps1'
$script:IntegrityToolScript = Join-Path $script:Root 'tools\Test-SumiGuardAuditIntegrity.ps1'
$script:PowerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Stage = 'SETUP'
$failure = $null
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = Join-Path $tempRoot ('sumi-guard-signed-checkpoint-' + [Guid]::NewGuid().ToString('N'))
$rsa = $null
$sha = $null
[byte[]]$privateSignature = $null

function Add-Result {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Records an in-memory result for the isolated synthetic test only.')]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][bool]$Pass)
    $script:Results.Add([pscustomobject][ordered]@{ name = $Name; pass = $Pass })
}

function Invoke-SignedCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Store,
        [Parameter(Mandatory = $true)][string]$Checkpoint,
        [Parameter(Mandatory = $true)][string]$Signature,
        [Parameter(Mandatory = $true)][string]$PublicKey,
        [Parameter(Mandatory = $true)][string]$Pin,
        [string]$PolicyPath = '',
        [string]$PolicySignaturePath = '',
        [long]$MinimumTrustedSequence = 42,
        [string]$TrustedNowUtc = '2026-10-18T09:00:00Z',
        [switch]$OmitTrustedSequence
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:VerifierPath,
        '-StoreKind', 'Execution',
        '-StorePath', $Store,
        '-CheckpointPath', $Checkpoint,
        '-SignaturePath', $Signature,
        '-PublicKeyPath', $PublicKey,
        '-ExpectedPublicKeySha256', $Pin)
    if ($PolicyPath) {
        $arguments += @('-PolicyPath', $PolicyPath)
        if ($PolicySignaturePath) {
            $arguments += @('-PolicySignaturePath', $PolicySignaturePath)
        }
        if (-not $OmitTrustedSequence) {
            $arguments += @('-MinimumTrustedSequence', [string]$MinimumTrustedSequence)
        }
        if ($TrustedNowUtc) {
            $arguments += @('-TrustedNowUtc', $TrustedNowUtc)
        }
    }
    $output = @(& $script:PowerShell51 @arguments)
    $code = $LASTEXITCODE
    $json = ($output -join [Environment]::NewLine).Trim()
    $data = $json | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject][ordered]@{
        code = $code
        output = $json
        data = $data
    }
}

try {
    if ((Split-Path -Leaf $work) -cnotmatch '^sumi-guard-signed-checkpoint-[0-9a-f]{32}$' -or
        -not $work.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'UNSAFE_TEST_PATH'
    }
    $null = New-Item -ItemType Directory -Path $work -ErrorAction Stop
    $store = Join-Path $work 'execution-store'
    $null = New-Item -ItemType Directory -Path $store -ErrorAction Stop
    $markerPath = Join-Path $store '.sumi-guard-execution-store.json'
    $lockPath = Join-Path $store '.sumi-guard-execution-store.lock'
    $auditPath = Join-Path $store 'events.ndjson'
    $marker = [ordered]@{
        schema_version = 1
        store_id = [Guid]::NewGuid().ToString('N')
        body_provider = 'SumiGuard.LocalStore'
    }
    [IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Compress), $script:Utf8)
    $stream = New-Object IO.FileStream(
        $lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stream.Dispose()
    $eventRecord = [ordered]@{
        schema_version = 1
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ExecutionIntentRecorded'
        execution_id = [Guid]::NewGuid().ToString('N')
        occurred_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        body_sha256 = ('a' * 64)
        content_status = 'HASH_ONLY'
        collection_status = 'RECORDS_FOUND'
        body_ref = $null
    }
    $originalRecord = ($eventRecord | ConvertTo-Json -Compress) + [Environment]::NewLine
    [IO.File]::WriteAllText($auditPath, $originalRecord, $script:Utf8)
    $originalHash = (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash

    $script:Stage = 'SNAPSHOT'
    $snapshotOutput = @(& $script:PowerShell51 -NoLogo -NoProfile -NonInteractive -File $script:IntegrityToolScript -StoreKind Execution -StorePath $store -Action Snapshot)
    if ($LASTEXITCODE -ne 0) { throw 'SNAPSHOT_FAILED' }
    $snapshotJson = ($snapshotOutput -join [Environment]::NewLine).Trim()
    $snapshot = $snapshotJson | ConvertFrom-Json -ErrorAction Stop
    if ($snapshot.status -cne 'STRUCTURE_VALID_UNANCHORED') { throw 'SNAPSHOT_INVALID' }
    $checkpoint = Join-Path $work 'checkpoint.json'
    [IO.File]::WriteAllText($checkpoint, $snapshotJson, $script:Utf8)

    $script:Stage = 'SIGN_WITH_TEST_KEY'
    # Windows PowerShell 5.1 uses RSACryptoServiceProvider; setting KeySize
    # after construction does not change its generated key size.
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(3072)
    $public = $rsa.ExportParameters($false)
    if ($public.Modulus.Length -ne 384) { throw 'EXPECTED_3072_BIT_TEST_KEY' }
    $publicRecord = [ordered]@{
        schema_version = 1
        algorithm = 'RSA-SHA256-PKCS1-v1_5'
        modulus_base64 = [Convert]::ToBase64String($public.Modulus)
        exponent_base64 = [Convert]::ToBase64String($public.Exponent)
    }
    $keyPath = Join-Path $work 'public-key.json'
    [IO.File]::WriteAllText($keyPath, ($publicRecord | ConvertTo-Json -Compress), $script:Utf8)
    $sha = [Security.Cryptography.SHA256]::Create()
    $keyBytes = [IO.File]::ReadAllBytes($keyPath)
    $pin = ([BitConverter]::ToString($sha.ComputeHash($keyBytes))).Replace('-', '').ToLowerInvariant()
    [Array]::Clear($keyBytes, 0, $keyBytes.Length)
    $checkpointBytes = [IO.File]::ReadAllBytes($checkpoint)
    $privateSignature = $rsa.SignData(
        $checkpointBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [Array]::Clear($checkpointBytes, 0, $checkpointBytes.Length)
    $sigPath = Join-Path $work 'checkpoint.sig'
    $sigText = [Convert]::ToBase64String($privateSignature)
    [IO.File]::WriteAllText($sigPath, $sigText, $script:Utf8)
    # Signed test policy with a fixed externally supplied clock, so CI results
    # are independent of the date the disposable runner executes.
    $policyPath = Join-Path $work 'signed-policy.json'
    $policySigPath = Join-Path $work 'signed-policy.sig'
    $policySnapshotBytes = [IO.File]::ReadAllBytes($checkpoint)
    $checkpointHash = ([BitConverter]::ToString($sha.ComputeHash($policySnapshotBytes))).Replace('-', '').ToLowerInvariant()
    [Array]::Clear($policySnapshotBytes, 0, $policySnapshotBytes.Length)
    $policy = [ordered]@{
        schema_version = 1
        record_type = 'SignedAuditCheckpointPolicy'
        store_kind = 'Execution'
        checkpoint_sha256 = $checkpointHash
        sequence = [long]42
        issued_at_utc = '2026-10-18T08:00:00Z'
        expires_at_utc = '2026-10-18T10:00:00Z'
    }
    $policyRaw = $policy | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($policyPath, $policyRaw, $script:Utf8)
    [byte[]]$policyPlainBytes = $script:Utf8.GetBytes($policyRaw)
    [byte[]]$policySignedBytes = $rsa.SignData(
        $policyPlainBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [Array]::Clear($policyPlainBytes, 0, $policyPlainBytes.Length)
    $policySignatureText = [Convert]::ToBase64String($policySignedBytes)
    [IO.File]::WriteAllText($policySigPath, $policySignatureText, $script:Utf8)
    [Array]::Clear($policySignedBytes, 0, $policySignedBytes.Length)
    # A correctly signed policy with an intentionally incorrect checkpoint hash.
    # The cryptographic signature alone must not make a different baseline pass.
    $wrongBindingPolicyPath = Join-Path $work 'policy-wrong-checkpoint.json'
    $wrongBindingSigPath = Join-Path $work 'policy-wrong-checkpoint.sig'
    $wrongHash = ('f' * 64)
    if ($checkpointHash -ceq $wrongHash) { $wrongHash = ('0' * 64) }
    $wrongPolicyRaw = $policyRaw.Replace($checkpointHash, $wrongHash)
    [IO.File]::WriteAllText($wrongBindingPolicyPath, $wrongPolicyRaw, $script:Utf8)
    [byte[]]$wrongPolicyBytes = $script:Utf8.GetBytes($wrongPolicyRaw)
    [byte[]]$wrongPolicySignature = $rsa.SignData(
        $wrongPolicyBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [IO.File]::WriteAllText($wrongBindingSigPath,
        [Convert]::ToBase64String($wrongPolicySignature), $script:Utf8)
    [Array]::Clear($wrongPolicyBytes, 0, $wrongPolicyBytes.Length)
    [Array]::Clear($wrongPolicySignature, 0, $wrongPolicySignature.Length)
    # The private test key is never exported and never written to any file.
    $rsa.Dispose()
    $rsa = $null

    $script:Stage = 'VALID_SIGNATURE'
    $valid = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'SIGNED_CHECKPOINT_AND_STORE_MATCH' -Pass (
        $valid.code -eq 0 -and $valid.data.status -ceq 'AUTHENTIC_CHECKPOINT_MATCH' -and
        $valid.data.key_pin_verified -eq $true -and
        $valid.data.checkpoint_signature_verified -eq $true -and
        $valid.data.store_matches_checkpoint -eq $true)
    Add-Result -Name 'VALID_CHECK_IS_READ_ONLY' -Pass (
        (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash -ceq $originalHash -and
        $valid.data.audit_store_modified -eq $false -and
        $valid.data.private_key_loaded -eq $false)


    $script:Stage = 'SIGNED_POLICY_VALID'
    $policyValid = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath
    Add-Result -Name 'SIGNED_FRESH_POLICY_MATCH' -Pass (
        $policyValid.code -eq 0 -and
        $policyValid.data.status -ceq 'AUTHENTIC_CHECKPOINT_MATCH' -and
        $policyValid.data.signed_policy_verified -eq $true -and
        $policyValid.data.policy_floor_checked -eq $true -and
        $policyValid.data.policy_time_checked -eq $true)

    $script:Stage = 'POLICY_CHECKPOINT_BINDING'
    $wrongBinding = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $wrongBindingPolicyPath -PolicySignaturePath $wrongBindingSigPath
    Add-Result -Name 'VALIDLY_SIGNED_WRONG_CHECKPOINT_HASH_REJECTED' -Pass (
        $wrongBinding.code -eq 2 -and
        $wrongBinding.data.reason_code -ceq 'POLICY_CHECKPOINT_MISMATCH' -and
        $wrongBinding.data.signed_policy_verified -eq $true)

    $script:Stage = 'ROLLBACK_SEQUENCE'
    $oldSequence = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath -MinimumTrustedSequence 43
    Add-Result -Name 'OLD_SIGNED_SEQUENCE_REJECTED' -Pass (
        $oldSequence.code -eq 2 -and
        $oldSequence.data.reason_code -ceq 'POLICY_SEQUENCE_BELOW_FLOOR' -and
        $oldSequence.data.signed_policy_verified -eq $true -and
        $oldSequence.data.policy_floor_checked -eq $false)

    $script:Stage = 'EXPIRY'
    $expired = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath -TrustedNowUtc '2026-10-18T10:00:00Z'
    Add-Result -Name 'EXPIRED_POLICY_REJECTED' -Pass (
        $expired.code -eq 2 -and
        $expired.data.reason_code -ceq 'POLICY_EXPIRED' -and
        $expired.data.policy_time_checked -eq $false)

    $script:Stage = 'FUTURE'
    $future = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath -TrustedNowUtc '2026-10-18T07:59:59Z'
    Add-Result -Name 'POLICY_NOT_YET_VALID_REJECTED' -Pass (
        $future.code -eq 2 -and $future.data.reason_code -ceq 'POLICY_NOT_YET_VALID')

    $script:Stage = 'UNTRUSTED_TIME_FORMAT'
    $badTime = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath -TrustedNowUtc '2026-10-18T09:00:00+09:00'
    Add-Result -Name 'NON_UTC_REFERENCE_TIME_REJECTED' -Pass (
        $badTime.code -eq 2 -and $badTime.data.reason_code -ceq 'POLICY_TIME_INVALID')

    $script:Stage = 'REQUIRED_OFFDEVICE_FLOOR'
    $noFloor = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath -OmitTrustedSequence
    Add-Result -Name 'MISSING_TRUSTED_FLOOR_REJECTED' -Pass (
        $noFloor.code -eq 2 -and $noFloor.data.reason_code -ceq 'POLICY_INPUT_INCOMPLETE')

    $script:Stage = 'MISSING_POLICY_SIGNATURE'
    $noPolicySig = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath
    Add-Result -Name 'MISSING_POLICY_SIGNATURE_REJECTED' -Pass (
        $noPolicySig.code -eq 2 -and $noPolicySig.data.reason_code -ceq 'POLICY_INPUT_INCOMPLETE')

    $script:Stage = 'POLICY_TAMPER'
    [IO.File]::WriteAllText($policyPath, $policyRaw.Replace('"sequence":42', '"sequence":43'), $script:Utf8)
    $policyTampered = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $policySigPath
    Add-Result -Name 'ALTERED_POLICY_WITH_OLD_SIGNATURE_REJECTED' -Pass (
        $policyTampered.code -eq 2 -and
        $policyTampered.data.reason_code -ceq 'POLICY_SIGNATURE_INVALID')
    [IO.File]::WriteAllText($policyPath, $policyRaw, $script:Utf8)

    $script:Stage = 'POLICY_SIGNATURE_TAMPER'
    $alteredPolicySigPath = Join-Path $work 'tampered-policy.sig'
    [byte[]]$mutatedPolicySignature = [Convert]::FromBase64String($policySignatureText)
    $mutatedPolicySignature[0] = $mutatedPolicySignature[0] -bxor 1
    [IO.File]::WriteAllText($alteredPolicySigPath,
        [Convert]::ToBase64String($mutatedPolicySignature), $script:Utf8)
    [Array]::Clear($mutatedPolicySignature, 0, $mutatedPolicySignature.Length)
    $policySigTampered = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin -PolicyPath $policyPath -PolicySignaturePath $alteredPolicySigPath
    Add-Result -Name 'POLICY_SIGNATURE_TAMPERING_REJECTED' -Pass (
        $policySigTampered.code -eq 2 -and
        $policySigTampered.data.reason_code -ceq 'POLICY_SIGNATURE_INVALID')

    $script:Stage = 'AUDIT_CHANGE'
    [IO.File]::WriteAllText($auditPath, $originalRecord.Replace(('a' * 64), ('b' * 64)), $script:Utf8)
    $changed = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'VALID_SIGNATURE_DETECTS_CHANGED_AUDIT_LOG' -Pass (
        $changed.code -eq 1 -and
        $changed.data.status -ceq 'AUTHENTIC_CHECKPOINT_MISMATCH' -and
        $changed.data.checkpoint_signature_verified -eq $true)
    [IO.File]::WriteAllText($auditPath, $originalRecord, $script:Utf8)

    $script:Stage = 'CHECKPOINT_TAMPER'
    [IO.File]::WriteAllText($checkpoint, $snapshotJson.Replace('"action":"Snapshot"', '"action":"Compare"'), $script:Utf8)
    $baselineChanged = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'ALTERED_BASELINE_REJECTED_BY_SIGNATURE' -Pass (
        $baselineChanged.code -eq 2 -and
        $baselineChanged.data.reason_code -ceq 'CHECKPOINT_SIGNATURE_INVALID' -and
        $baselineChanged.data.store_matches_checkpoint -eq $false)
    [IO.File]::WriteAllText($checkpoint, $snapshotJson, $script:Utf8)

    $script:Stage = 'INVALID_SIGNATURE'
    $sigMutant = Join-Path $work 'changed.sig'
    [byte[]]$changedSignature = [Convert]::FromBase64String($sigText)
    $changedSignature[0] = $changedSignature[0] -bxor 1
    [IO.File]::WriteAllText($sigMutant, [Convert]::ToBase64String($changedSignature), $script:Utf8)
    [Array]::Clear($changedSignature, 0, $changedSignature.Length)
    $wrongSig = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigMutant -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'MODIFIED_SIGNATURE_REJECTED' -Pass (
        $wrongSig.code -eq 2 -and
        $wrongSig.data.reason_code -ceq 'CHECKPOINT_SIGNATURE_INVALID')

    $script:Stage = 'WRONG_PIN'
    $newFirst = if ($pin[0] -ceq 'a') { 'b' } else { 'a' }
    $badPin = $newFirst + $pin.Substring(1)
    $wrongPin = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $keyPath -Pin $badPin
    Add-Result -Name 'PUBLIC_KEY_SUBSTITUTION_WITH_WRONG_PIN_REJECTED' -Pass (
        $wrongPin.code -eq 2 -and
        $wrongPin.data.reason_code -ceq 'PUBLIC_KEY_PIN_MISMATCH' -and
        $wrongPin.data.checkpoint_signature_verified -eq $false)

    $script:Stage = 'BAD_PUBLIC_KEY'
    $smallKeyPath = Join-Path $work 'small-key.json'
    [byte[]]$tooSmall = New-Object byte[] 256
    $tooSmall[0] = 128
    $badPublic = [ordered]@{
        schema_version = 1
        algorithm = 'RSA-SHA256-PKCS1-v1_5'
        modulus_base64 = [Convert]::ToBase64String($tooSmall)
        exponent_base64 = 'AQAB'
    }
    [IO.File]::WriteAllText($smallKeyPath, ($badPublic | ConvertTo-Json -Compress), $script:Utf8)
    $badKeyBytes = [IO.File]::ReadAllBytes($smallKeyPath)
    $smallPin = ([BitConverter]::ToString($sha.ComputeHash($badKeyBytes))).Replace('-', '').ToLowerInvariant()
    [Array]::Clear($badKeyBytes, 0, $badKeyBytes.Length)
    $weak = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature $sigPath -PublicKey $smallKeyPath -Pin $smallPin
    Add-Result -Name 'RSA_KEY_BELOW_3072_BITS_REJECTED' -Pass (
        $weak.code -eq 2 -and $weak.data.reason_code -ceq 'PUBLIC_KEY_INVALID')
    [Array]::Clear($tooSmall, 0, $tooSmall.Length)

    $script:Stage = 'BASELINE_LOCATION'
    $inside = Join-Path $store 'checkpoint-inside-store.json'
    [IO.File]::WriteAllText($inside, $snapshotJson, $script:Utf8)
    $unsafe = Invoke-SignedCheck -Store $store -Checkpoint $inside -Signature $sigPath -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'CHECKPOINT_INSIDE_AUDIT_STORE_REJECTED' -Pass (
        $unsafe.code -eq 2 -and
        $unsafe.data.reason_code -ceq 'INPUT_INSIDE_AUDIT_STORE')
    [IO.File]::Delete($inside)

    $script:Stage = 'MISSING_SIGNATURE'
    $missing = Invoke-SignedCheck -Store $store -Checkpoint $checkpoint -Signature (Join-Path $work 'absent.sig') -PublicKey $keyPath -Pin $pin
    Add-Result -Name 'MISSING_SIGNATURE_FAILS_CLOSED' -Pass (
        $missing.code -eq 2 -and $missing.data.reason_code -ceq 'INPUT_FILE_INVALID')

    $script:Stage = 'FINAL_IMMUTABILITY'
    Add-Result -Name 'PRODUCTION_DATA_UNTOUCHED' -Pass (
        (Get-FileHash -LiteralPath $auditPath -Algorithm SHA256).Hash -ceq $originalHash)
}
catch {
    $failure = [pscustomobject]@{
        stage = [string]$script:Stage
        exception_type = $_.Exception.GetType().FullName
    }
}
finally {
    if ($null -ne $rsa) { $rsa.Dispose() }
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $privateSignature) {
        [Array]::Clear($privateSignature, 0, $privateSignature.Length)
    }
    if (Test-Path -LiteralPath $work) {
        $full = [IO.Path]::GetFullPath($work)
        if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $full) -cmatch '^sumi-guard-signed-checkpoint-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
        else { $failure = [pscustomobject]@{ stage = 'UNSAFE_CLEANUP_PATH' } }
    }
}
$failed = @($script:Results | Where-Object { -not $_.pass })
$success = ($null -eq $failure -and $failed.Count -eq 0)
[pscustomobject][ordered]@{
    success = $success
    test_count = $script:Results.Count
    passed_count = ($script:Results.Count - $failed.Count)
    failed_cases = @($failed | ForEach-Object { $_.name })
    failure = $failure
    fixture_cleaned = -not (Test-Path -LiteralPath $work)
    private_key_written_to_disk = $false
    production_store_accessed = $false
    command_inputs_executed = $false
} | ConvertTo-Json -Compress -Depth 4
if ($success) { exit 0 } else { exit 1 }
