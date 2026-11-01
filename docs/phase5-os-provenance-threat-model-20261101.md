# SUMI GUARD Phase 5
## OS Process Provenance - Threat Model and Verification Plan

Status: DESIGN ONLY
Base: b7d3ee0ab845340b617c9edacaa9ace9dbbafbfb
Date: 2026-11-01
Owner: SUMI GUARD

## 1. Goal

Determine what evidence is necessary to link an operating-system
process instance to a managed execution without trusting only
a caller-supplied PID, timestamp, path, or status flag.

Phase 5 does not enable production identity matching.

Goals:
- Define the trust boundary of OS observations.
- Define process-handle-bound evidence requirements.
- Distinguish timestamp representation from actual accuracy.
- Specify fail-closed conditions and verification experiments.
- Establish a review gate before any production trust upgrade.

Non-goals:
- Starting persistent monitoring or hooks.
- Enabling WMI subscriptions or ETW.
- Arbitrary-PID surveillance.
- Elevating privileges or installing a Windows service.
- Enabling DIRECT_MATCH or changing existing runtime behavior.

## 2. Existing Baseline

Phase 3:
- Managed execution can record process identity evidence.
- Confirmation uses an in-memory object identity marker.
- The marker is process-local, not a remote attestation.
- A caller-supplied PROCESS_CONFIRMED string is not proof.

Phase 4A:
- Pure correlation engine.
- A public API accepts caller-supplied observations.
- Synthetic DIRECT_MATCH is not a production trust boundary.
- Reported TICKS_100NS is currently an input claim.
- INFERRED_MATCH must not be interpreted as authenticated provenance.

Phase 4B:
- Explicitly opted-in, local self-PID CIM collection.
- Two ordered Win32_Process observations.
- CreationDate precision remains unverified.
- No arbitrary-PID public collector.

Phase 4C and Phase 4D:
- Read-only diagnostic integration.
- Timestamp, identity, order and contract validation.
- Final integration result always remains UNMATCHED.
- No trust promotion from CIM observation to process identity.

## 3. Protected Assets and Threat Actors

Assets:
- Correct process-instance identity.
- Process creation timestamp and executable identity.
- Evidence origin and collection order.
- Trust-level classification.
- Auditability of failed observations.
- Integrity of the correlation decision.

Threat actors:
T1: Accidental malformed or stale data.
T2: PID reuse after process termination.
T3: Same-user code modifying PowerShell objects or functions.
T4: A compromised observation adapter or local process.
T5: A privileged attacker or compromised OS.

T5 cannot be fully defeated by a user-mode PowerShell design.
Any stronger protection requires an explicitly defined
higher-trust environment and separate security review.

## 4. Trust Boundaries

Boundary A: Caller data to diagnostic module
- All fields are untrusted.
- Status labels and flags establish no authority.

Boundary B: CIM provider to PowerShell process
- CIM data is an observation, not attestation.
- CreationDate is not proof of 100-nanosecond accuracy.
- Seven decimal digits do not prove source precision.

Boundary C: Native process handle to collector
- An open handle refers to a process object.
- Read PID and creation time through the same retained handle.
- Validate process image path through the same handle.
- Handle acquisition, lifetime and release must be auditable.
- Reopening by PID is not equivalent to retaining the handle.

Boundary D: Collector to decision engine
- A JSON object alone cannot authenticate its origin.
- Cross-process identity needs an explicit authenticated boundary.
- A broker running as the same compromised user may be forgeable.
- Sequence numbers, nonces and hashes are not sufficient alone.
- Broker permissions, session binding and replay resistance
  require independent verification.

## 5. Evidence Proposal

Candidate evidence fields:
- schema_version
- execution_id
- collector_instance_id
- observation_nonce
- pid_from_handle
- creation_filetime_utc
- executable_path_from_handle
- handle_acquisition_status
- collection_started_utc
- collection_completed_utc
- collector_version
- collection_status
- failure_reason
- win32_error_code
- provenance_level

Evidence fields are records, not proof by themselves.

Never derive provenance_level from a caller-controlled field.
Never infer source accuracy from a string representation.

Potential native APIs:
- GetProcessId
- GetProcessTimes
- QueryFullProcessImageNameW

Minimum intended access:
PROCESS_QUERY_LIMITED_INFORMATION, when permitted.

Do not request PROCESS_ALL_ACCESS or SeDebugPrivilege.
Do not enable termination, injection or memory modification rights.

## 6. Design Alternatives

Option A: In-process native handle inspection
Advantages:
- Small implementation footprint.
- Useful for measurement and regression testing.

Limitations:
- Same-process attacker can tamper with results.
- Cannot provide independent provenance.

Option B: Separate, authenticated local observer
Advantages:
- Clearer trust boundary.
- Possibility of retaining the process handle and reporting
  consistent observations from an isolated component.

Limitations:
- Same-user compromise still requires threat analysis.
- Authentication, access control and replay protection
  require validation.
- No security guarantee merely from process separation.

Option C: Privileged or kernel-backed observation
Advantages:
- Potentially stronger observation isolation.

Limitations:
- Substantial operational, compatibility and security cost.
- New attack surface and deployment complexity.
- Not authorized for this phase.

Decision:
Evaluate A as a measurement baseline.
Design B as a candidate, not an approved deployment.
Do not implement C without a separate decision.

## 7. Verification Matrix

V01: Correct managed process instance.
V02: PID reused after original process exits.
V03: Handle retained across process termination.
V04: Handle unavailable or closed prematurely.
V05: Access denied when querying process details.
V06: Creation time unavailable.
V07: Creation FILETIME changes unexpectedly.
V08: Executable path differs from expected image.
V09: CIM CreationDate differs from handle-bound creation time.
V10: Short-lived process ends between observations.
V11: Observer timestamps are reversed.
V12: Observations exceed allowed relative time windows.
V13: Caller forges PROCESS_CONFIRMED.
V14: Caller forges TICKS_100NS precision.
V15: Caller forges collector identity or broker flags.
V16: Replayed observation nonce.
V17: Wrong execution ID or collector session.
V18: Observer crashes during capture.
V19: Evidence is truncated or partially written.
V20: Concurrent executions cannot exchange identities.
V21: A same-user process tampers with the result.
V22: No privileged rights are acquired.
V23: No WMI subscription, ETW or monitoring is activated.
V24: No production match state is promoted.

Each case must record:
- Test name and expected fail-closed result.
- Observation source and permitted operations.
- Whether native OS access occurred.
- Actual results and exact failure reason.
- Whether the test is synthetic or a real OS measurement.
- Residual threat not covered by the test.

A successful synthetic test is not proof of resistance against
a malicious administrator, kernel code or same-user injection.

## 8. Acceptance Gates

G0 - Threat model reviewed:
- Explicit actor and privilege assumptions.
- Assets and trust boundaries documented.
- Design accepted before code changes.

G1 - Native observation laboratory:
- Opt-in only and fixed, owned test process.
- No persistent service, hook, WMI subscription or ETW.
- Handle acquisition and release tests.
- Negative cases for unavailable evidence.

G2 - Provenance boundary:
- Define how the collector is authenticated.
- Demonstrate rejection of forged and replayed reports.
- Verify how identity is tied to a single process instance.
- Document residual same-user compromise risks.

G3 - Independent security review:
- Separate code reviewer and test report.
- All findings and exceptions tracked.
- CI, Windows PowerShell 5.1 and real OS results preserved.

G4 - Production decision:
- Explicit approval required for any trust promotion.
- No automatic migration from UNMATCHED.
- No reclassification based only on PID or timestamps.
- Failure must preserve existing fail-closed semantics.

## 9. Decisions and Open Questions

D1: Do not enable production DIRECT_MATCH in Phase 5.
D2: Do not raise privilege or start a persistent observer.
D3: Keep existing Phase 3 and Phase 4 APIs unchanged initially.
D4: Treat FILETIME 100-ns units as representation, not accuracy.
D5: Prefer retained-handle measurement over repeated PID lookup.

Open questions:
- Which actor must be trusted to create and hold the handle?
- What isolation exists between collector and calling process?
- How will collector identity and message integrity be verified?
- What happens if an observed process exits immediately?
- What is the minimum acceptable provenance level?
- What risks remain under a compromised Windows user account?
- Which Windows versions and security configurations are supported?

## 10. Required Review Output

Before implementation, produce:
1. Threat-model findings and unresolved assumptions.
2. Architecture decision record for A versus B.
3. Evidence schema and trust-level definitions.
4. Test harness plan, including fail-closed cases.
5. Privilege and deployment impact assessment.
6. Explicit go/no-go decision for native implementation.

This document authorizes design review only.
It does not authorize trust promotion or runtime activation.

## 11. References

Microsoft Process Handles and Identifiers:
https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers

Microsoft GetProcessTimes:
https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes

Microsoft GetProcessId:
https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessid

Microsoft QueryFullProcessImageNameW:
https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew

Microsoft Process Security and Access Rights:
https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights

Microsoft Win32_Process:
https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process