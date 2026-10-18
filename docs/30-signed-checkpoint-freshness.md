# SUMI Guard: authenticated checkpoint freshness (optional, verification-only)

## Purpose

The existing detached RSA signature authenticates the bytes of one checkpoint.
An old, authentic checkpoint remains valid unless its freshness is checked.
This extension optionally verifies a **second detached RSA signature** over a
freshness policy, then enforces an independently supplied sequence floor and
trusted UTC reference time. It never signs operational data or writes to stores.

## Required trust boundaries

The signed policy and checkpoint are signed in a separate trusted environment.
The monitoring PC receives **no private signing key**. The expected public-key
SHA-256 fingerprint must come from an independently trusted channel.

For rollback verification, the caller must supply `MinimumTrustedSequence` from
an off-device, independently protected monotonic record. That value must not
come solely from the monitored Windows user profile or the checkpoint itself.
Similarly, `TrustedNowUtc` must be obtained independently of a potentially
compromised system clock. This tool cannot authenticate its caller's clock or
sequence input and never updates a sequence floor automatically.

## Signed policy schema

Exactly seven JSON properties; the policy is signed over its **exact file bytes**
with the same pinned RSA 3072-4096-bit key used for the checkpoint signature.

```json
{
  "schema_version": 1,
  "record_type": "SignedAuditCheckpointPolicy",
  "store_kind": "Execution",
  "checkpoint_sha256": "<sha256-of-exact-checkpoint-file-bytes>",
  "sequence": 42,
  "issued_at_utc": "2026-10-18T08:00:00Z",
  "expires_at_utc": "2026-10-18T10:00:00Z"
}
```

`store_kind` must be `Execution` or `Assessment` and must match the CLI option.
The issued/expiry values must be explicitly UTC (Z), with optional fractional
seconds. The expiry must be later than issuance and the signed validity window
must not exceed seven days. The policy sequence must be a positive integer.

The detached policy signature file is Base64 of RSA/SHA-256 PKCS#1 v1.5 over
the exact bytes of this policy file. A separate detached signature over the
checkpoint itself is still mandatory.

## Read-only invocation

```powershell
& .\tools\Test-SumiGuardSignedCheckpoint.ps1 -StoreKind Execution -StorePath $store -CheckpointPath $checkpoint -SignaturePath $checkpointSignature -PublicKeyPath $publicKey -ExpectedPublicKeySha256 $trustedPin -PolicyPath $signedPolicy -PolicySignaturePath $policySignature -MinimumTrustedSequence $externalSequenceFloor -TrustedNowUtc $externalTrustedUtc
```

All four optional inputs (`PolicyPath`, `PolicySignaturePath`,
`MinimumTrustedSequence`, `TrustedNowUtc`) must be present together; missing
or partial inputs fail closed. They are required only when the policy mode
is selected. The old signature-only invocation remains unchanged.

## Validation order

1. Validate the trusted public-key pin and checkpoint signature.
2. Verify the second detached signature over the exact policy bytes.
3. Check the exact policy schema, store kind and SHA-256 of checkpoint bytes.
4. Reject sequences below the externally supplied minimum.
5. Reject invalid/non-UTC time strings, expiry before issuance, validity
   windows exceeding seven days, future-issued and expired policies.
6. Only then run the existing read-only structural audit comparison.

Success preserves the existing `AUTHENTIC_CHECKPOINT_MATCH` status and
additionally sets `signed_policy_verified`, `policy_floor_checked`, and
`policy_time_checked` to `true`. If no policy is supplied, all three remain
`false`. A malformed/expired/stale policy returns exit 2 and a fixed code
such as `POLICY_EXPIRED` or `POLICY_SEQUENCE_BELOW_FLOOR`.

## Security limits

- Without trustworthy **external** floor and time, an attacker may replay
  signed checkpoints or alter the verification arguments.
- Without a trusted signing workflow, a policy's claimed timestamp can be
  backdated or renewed improperly by the holder of the private key.
- This does **not** track whether every event was logged or whether malware
  disabled the hook before a checkpoint was created.
- A valid signature is not evidence the machine is clean. Legitimate log
  appends still produce comparison mismatches.
- The verifier cannot securely store the monotonic floor on the monitored PC.
- Rotation/revocation, trusted time sources, and signer provisioning remain
  outside this PR and require a separate approved design.

## Automated tests

`tests/Invoke-SignedCheckpointTests.ps1` uses an ephemeral in-memory RSA key
and **fixed reference UTC strings**. It tests valid and missing policy mode,
stale sequence, expiry, not-yet-valid time, non-UTC reference, missing external
sequence floor, modified policy bytes, and modified policy signature.
Windows GitHub Actions tests synthetic temp data only, with no operational
private-key export or production mutations.
