# SUMI GUARD Phase 5 - Architecture Decision Record

Status: PROPOSED - NOT APPROVED
Date: 2026-11-01
Base: b7d3ee0ab845340b617c9edacaa9ace9dbbafbfb

## 1. Decision

Option A: Candidate for a restricted native observation lab.
Option B: Architecture research only.
Option C: Out of scope.

No option is approved for production trust promotion.

## 2. Primary Security Invariant

No caller-controlled PID, timestamp, path, precision label,
collector label, or PROCESS_CONFIRMED string establishes
authenticated process provenance.

The Phase 4C/4D diagnostic integration result remains UNMATCHED.

INFERRED_MATCH must never be interpreted as authenticated
OS identity or provenance.

DIRECT_MATCH remains disabled.

## 3. Option A: Measurement Laboratory

Proposed scope:
- Explicit operator opt-in.
- Fixed, owned test process only.
- Retain a real process handle during observation.
- Read PID and creation time from the retained handle.
- Read executable image identity from the same handle.
- Report native errors without inventing missing values.
- Release acquired handles deterministically.
- Never raise privilege.
- No service, persistent monitoring, hook, ETW or WMI subscription.

Candidate APIs:
- GetProcessId
- GetProcessTimes
- QueryFullProcessImageNameW

Use PROCESS_QUERY_LIMITED_INFORMATION when supported.

Never request PROCESS_ALL_ACCESS or SeDebugPrivilege.

## 4. Option A Limitations

An in-process observer does not protect against malicious
code in that same process.

A native handle ties measurements to a process object,
but a serialized report cannot prove who produced it.

FILETIME units do not prove actual measurement accuracy.

A native API returning success does not authenticate
the reporting PowerShell code.

The observer must never set production DIRECT_MATCH.

## 5. Option B: Independent Observer

Before implementation, document:
- Observer identity and ownership.
- Authenticated communication protocol.
- Session binding and execution identifiers.
- Replay resistance and nonce management.
- Least-privilege access controls.
- Evidence integrity and retention.
- Failure and process-crash behavior.
- Same-user compromise assumptions.

Separate processes alone do not create a secure boundary.

## 6. Evidence Trust Levels

L0: Caller-supplied fields; no provenance.
L1: Local observation; source authenticity unproven.
L2: Retained-handle native measurement in a defined lab.
L3: Independently authenticated observer evidence.

L2 is not proof against same-process tampering.
L3 is a proposed classification, not an implemented claim.

No level automatically enables DIRECT_MATCH.

## 7. Required Verification

Run synthetic tests before native tests.

Real OS lab:
- Verify PID and creation time from one retained handle.
- Compare executable identity from that same handle.
- Inspect behavior when the process exits.
- Confirm handle release and error reporting.
- Measure differences against CIM observations.
- Verify that no privileged access was requested.
- Confirm no background monitoring is activated.

Negative cases:
- Handle unavailable.
- Access denied.
- Process exits during observation.
- Creation timestamp unavailable.
- Image path unavailable or changed.
- Wrong execution identity.
- Stale observation.
- Forged provenance field.
- Replay of old evidence.
- Concurrent execution mix-up.

All negative cases must fail closed.

## 8. Acceptance Gates

G0: Design review and explicit operator approval.
G1: Restricted native measurement laboratory.
G2: Independent provenance boundary design and tests.
G3: Independent security assessment.
G4: Separate production trust-promotion approval.

Current decision:
G0 - PROPOSED, review pending.
G1 - NOT STARTED.
G2 - NOT STARTED.
G3 - NOT STARTED.
G4 - NOT AUTHORIZED.

## 9. Operational Safety

Windows PowerShell 5.1 compatibility required.
No network API or third-party dependency for the lab.
No administrative privileges.
No persistent monitoring or service installation.
No modification of Phase 3 or Phase 4 trust semantics.
No analyzer baseline increase.
No production hooks activated.

## 10. Go / No-Go Recommendation

GO for preparing an isolated Option A measurement
specification and synthetic test plan.

NO-GO for production provenance claims, independent
observer deployment, and DIRECT_MATCH enablement.

An explicit review decision is required before
implementing the native laboratory.