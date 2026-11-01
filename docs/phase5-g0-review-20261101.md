# SUMI GUARD Phase 5 - G0 Design Review

Status: REVIEW PENDING - NOT APPROVED
Date: 2026-11-01
Base: 70ee880d85220c710ccac73f7a933d1be8c59f64

## 1. Scope

Review OS process provenance architecture before
starting any native observation implementation.

Reference documents:
- phase5-os-provenance-threat-model-20261101.md
- phase5-os-provenance-adr-20261101.md

This review does not authorize runtime activation.

## 2. Design Findings

F01 - PID Reuse
Severity: HIGH
PID alone cannot identify a durable process instance.
Retained-handle behavior must be tested.

F02 - Timestamp Provenance
Severity: HIGH
FILETIME uses 100-ns units but does not establish
measurement accuracy or authenticated origin.

F03 - Same-Process Tampering
Severity: HIGH
An in-process observer cannot defend against
malicious code controlling that process.

F04 - Collector Authentication
Severity: HIGH
A serialized result cannot prove which component
produced the evidence.

F05 - Handle Lifetime
Severity: MEDIUM
Handle acquisition, retention, error paths and
release require explicit measurement.

F06 - Diagnostic Promotion
Severity: HIGH
Caller-provided precision labels and status fields
must not promote the result into a trusted match.

## 3. Option Assessment

Option A:
Restricted, opt-in, retained-handle measurement lab.
CANDIDATE for future implementation approval.
Does not establish independent provenance.

Option B:
Separate authenticated observer.
DESIGN RESEARCH ONLY.
Authentication and replay protection are undefined.

Option C:
Privileged or kernel-backed observer.
NOT AUTHORIZED.

## 4. Proposed Lab Constraints

- Windows PowerShell 5.1 supported.
- Fixed, owned test process only.
- No arbitrary PID public collection interface.
- No administrative privilege.
- No SeDebugPrivilege.
- No PROCESS_ALL_ACCESS.
- No persistent service or monitoring.
- No hooks, WMI subscriptions or ETW activation.
- No external API dependency.
- Retain and release native handles explicitly.
- Record native API failure codes.
- Never infer missing evidence.
- No production DIRECT_MATCH enablement.

## 5. Required Evidence

- Test execution identifier
- Handle acquisition outcome
- PID obtained from the retained handle
- Creation FILETIME from the same handle
- Executable identity from the same handle
- Observation timestamps
- Native API error details
- Handle release outcome
- Evidence limitations
- No trust promotion

## 6. G0 Go / No-Go Criteria

GO only for lab preparation when:
- The execution and handle owner are defined.
- Test process scope is fixed.
- Privilege requirements are documented.
- Failure and resource cleanup are specified.
- Expected negative tests are documented.
- In-process spoofing limitations are explicit.
- Production match states remain unchanged.

NO-GO if:
- Arbitrary process collection is introduced.
- Privilege elevation becomes necessary.
- Handle ownership is ambiguous.
- Evidence authenticity is inferred from JSON.
- Timestamp formatting is treated as accuracy.
- The implementation changes production trust states.

## 7. Unresolved Questions

Q01: Who owns and retains the native process handle?
Q02: Is the measurement made before or after exit?
Q03: How are partial API failures represented?
Q04: How is handle cleanup proven?
Q05: How are PID reuse tests made deterministic?
Q06: What observation source can be authenticated?
Q07: What risks remain under same-user compromise?
Q08: Which tests require actual Windows OS access?

## 8. Recommendation

Proceed with documentation and test-harness planning.

Do not start native implementation until G0 is
explicitly approved.

Do not treat the merge of design documents as
security approval.

## 9. Gate Status

G0: REVIEW PENDING
G1: NOT STARTED
G2: NOT STARTED
G3: NOT STARTED
G4: NOT AUTHORIZED

Production DIRECT_MATCH: DISABLED
Phase 4C/4D integration: UNMATCHED