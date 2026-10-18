# SUMI Guard - Signed Audit Checkpoints (verification only)

## Goal

A trusted, separate signing environment can authenticate a previously reviewed
audit checkpoint. SUMI Guard checks the detached RSA signature and a pinned
public-key fingerprint, then compares the current audit records with that
checkpoint. The verifier never writes to an audit store.

The signing key must not be installed on the monitored PC or committed to GitHub.
This PR implements verification only, not operational signing or key provisioning.

## Inputs

- Checkpoint: exact UTF-8 bytes of a successful output from
  `Test-SumiGuardAuditIntegrity.ps1 -Action Snapshot`. Approval of the
  checkpoint must be an independent operator decision.
- Signature: Base64-encoded detached RSA/SHA-256 PKCS#1 v1.5 signature over the
  exact checkpoint file bytes.
- Public key JSON: exactly `schema_version` (1), `algorithm`
  (`RSA-SHA256-PKCS1-v1_5`), `modulus_base64` and `exponent_base64`
  (`AQAB`, public exponent 65537). RSA key size: 3072-4096 bits.
- Key fingerprint: 64 hexadecimal characters representing SHA-256 over the
  **exact public-key JSON file bytes**. Obtain the expected fingerprint through
  an independently trusted channel, not solely from the same directory.

Checkpoint, signature and public-key files must be outside the audited store.
Files and path components must not be reparse points. Input sizes are bounded.

## Verification

From a trusted shell, after independently obtaining the checkpoint, public
key, signature and expected public-key fingerprint:

```powershell
& .\tools\Test-SumiGuardSignedCheckpoint.ps1 -StoreKind Execution -StorePath $store -CheckpointPath $checkpoint -SignaturePath $signature -PublicKeyPath $publicKey -ExpectedPublicKeySha256 $trustedFingerprint
```

Return codes:

| Exit | Status | Meaning |
|---|---|---|
| 0 | `AUTHENTIC_CHECKPOINT_MATCH` | Trusted key fingerprint and signature validated; store matches the checkpoint |
| 1 | `AUTHENTIC_CHECKPOINT_MISMATCH` | Signature verified; audited records differ |
| 2 | `VERIFICATION_FAILED` | Missing, invalid, or unverifiable input or failed structural comparison |

A legitimate appended event also changes the files, so a mismatch is not
necessarily evidence of compromise. Never automatically approve or replace an
older checkpoint based on a mismatch.

## Security limitations

The signature authenticates checkpoint bytes, not the completeness of collected
activity, the trusted signing time, or the current health of the Windows system.
An old authentic checkpoint may be replayed without externally protected
timestamps and anti-rollback state. Independently manage key custody, rotation,
revocation and trusted time before operational use.

This implementation has no private-key operations, no signing-key storage,
no remote service, no audit-file modifications and no hook activation.
The synthetic CI test creates a disposable RSA key in memory and does not
export the private part or use any live audit data.
