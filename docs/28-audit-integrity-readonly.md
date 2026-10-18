# SUMI Guard: Read-only audit integrity verifier

## Scope

`tools/Test-SumiGuardAuditIntegrity.ps1` verifies existing SUMI Guard audit metadata
without creating, changing, decrypting, repairing, or deleting any store file.
It supports PowerShell 5.1 and two explicit modes:

- `Snapshot`: checks structure and prints file digests; returns `STRUCTURE_VALID_UNANCHORED`.
  This is **not** evidence that a log is authentic or untampered.
- `Compare`: checks structure, then compares to a separately retained baseline.
  Returns `MATCHES_SUPPLIED_BASELINE` or `BASELINE_MISMATCH`.

The verifier reads the execution marker, the assessment marker (whichever applies),
and these canonical records only: `events.ndjson`, `failures.ndjson`,
`retention.ndjson` (Execution), and `assessments.ndjson` (Assessment).
Snapshot includes the marker SHA-256, file presence, byte size, SHA-256, and record count.
It never returns command content, decrypted bodies, exception text, or caller paths.

## Usage

Choose the appropriate existing store; use one store per invocation:

```powershell
$store = 'C:\path\to\existing\execution-store'
$baseline = 'D:\independent-evidence\execution-baseline.json'

# Read-only structural snapshot; saving the returned JSON is an explicit operator action.
$snapshot = & .\tools\Test-SumiGuardAuditIntegrity.ps1 -StoreKind Execution -StorePath $store -Action Snapshot
$snapshot

# Only after reviewing a known-good snapshot, save it outside the monitored store.
$snapshot | Set-Content -LiteralPath $baseline -Encoding UTF8

# Read-only comparison with that independently stored snapshot.
& .\tools\Test-SumiGuardAuditIntegrity.ps1 -StoreKind Execution -StorePath $store -Action Compare -BaselinePath $baseline
```

**Baseline trust matters.** A baseline written after an attack, or one the same attacker
can modify along with the audit store, provides no meaningful authenticity guarantee.
Keep it in a separately controlled trusted location. The verifier rejects a baseline
within the audited store, but it cannot prove an external baseline is genuinely trusted.

## Structural checks

- Valid marker type/version and GUID; no reparse points in existing store paths.
- An existing lock is opened for shared read without creating one. The verifier
  stops if the lock is missing or unavailable.
- Strict UTF-8 without BOM, complete LF/CRLF-terminated NDJSON records, parseable
  JSON objects, recognized record types, schema version, 32-hex record identifiers,
  unique record IDs, and 64-hex execution body hashes.
- No unexpected plaintext-body or command-text fields; assessment records must
  explicitly record that content/excerpts are omitted.
- Retention references must correspond to a body reference in an execution event.
- File size is capped at **16 MiB per audited NDJSON file** for bounded reads.
  An AssessmentStore configured above this size remains valid for ordinary use,
  but this verifier will refuse to inspect any one file above 16 MiB.

## Exit codes and interpretation

| Exit | Status | Interpretation |
|---|---|---|
| 0 | STRUCTURE_VALID_UNANCHORED | Structurally valid; no authenticity baseline provided |
| 0 | MATCHES_SUPPLIED_BASELINE | Same marker and canonical file bytes as the supplied baseline |
| 1 | BASELINE_MISMATCH | Valid structure, but the marker or one or more files changed |
| 2 | VALIDATION_FAILED | Missing lock, bad structure, untrusted input shape, or read failure |

Legitimate new events and retention records also change hashes: a mismatch alone
is **not proof of compromise**. Review the cause before creating any new trusted baseline.
Missing canonical files are recorded as `present=false`; creating an empty file
afterward is detectable when compared against a prior baseline.

## Not covered

- No HMAC/signature, protected signing key, external timestamping or immutable audit log.
- No validation of encrypted `.sgb` payloads, OS observation, tool host behavior,
  `outcomes.ndjson`, hook notices or arbitrary unknown files.
- No guarantee against an administrator or malware running as the same Windows user
  altering both logs and baseline or evading the hook entirely.
- No repairs, migrations, auto-blocking, hook registration, or changes to `master`.

## Regression checks

`tests/Invoke-AuditIntegrityTests.ps1` creates disposable synthetic fixtures.
It covers a baseline match, valid-JSON tamper, marker swap, truncated NDJSON,
duplicate IDs, unexpected content, dangling retention references, new optional
file creation, in-store baseline refusal, missing lock, and an AssessmentStore.
The test runner cleans only its own GUID-named temporary directory.

## Signed checkpoint verification option

The verification-only wrapper `tools/Test-SumiGuardSignedCheckpoint.ps1`
validates a separately trusted RSA public-key fingerprint and a detached
signature over checkpoint bytes before invoking this read-only comparison.
It performs no signing-key management or file writes. See
`docs/29-signed-audit-checkpoint.md` for operational trust requirements.
