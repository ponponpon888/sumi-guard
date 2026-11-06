# SUMI GUARD Phase 5 - Option A Laboratory Specification

Status: PARKED (2026-11-06) - was PROPOSED, IMPLEMENTATION NOT AUTHORIZED
Date: 2026-11-01
Base: 364a911122cb7b4a71fe56ab55f780ffa730f7ed
Revision: 2026-11-06

Revision summary (2026-11-06, written against master 78ec013).
Every addition below is a PROPOSAL for G0 review. It does
not approve G0, start G1, or change any gate in section 12.
- section 9: CIM comparison added as the last real Windows case,
  left UNDECIDED between Option A and Option B
  (recommendation: Option A).
- section 9: G1 items added - synthetic V08, V18, V19; one
  verification method each for A06-A09; the limit of the
  section 10B duplicate-handle check.
- section 10C: termination only through the retained original
  Process object; the measurement duplicate gets no
  termination right.
- section 10D (new): output record fields, constant
  provenance_level, standard output only.
- section 10E (new): explicit opt-in execution, CI decision at G1,
  timeout margin and elapsed-time recording.
- New file docs/phase5-g0-approval-template-20261106.md:
  an empty approval record template (NOT APPROVED).

## Parking note (2026-11-06)

G0 is neither approved nor rejected; the gate states in
section 12 are unchanged.

Reason: SUMI Guard is not the parent of the process that
runs an AI command. The only way to become that parent is to
rewrite the command through PreToolUse updatedInput. The
official documentation says permission rules are evaluated
against the input the hook returns, not the input Claude
sent (https://code.claude.com/docs/en/hooks, PreToolUse
decision control). A rewrite therefore silently disables the
user's deny rules; this was reported in
anthropics/claude-code#89448 (Windows, Windows PowerShell
5.1). The issue was closed as not_planned by an inactivity
bot on 2026-10-19; the behavior remains as documented in the
official hooks reference. This lab would therefore not
improve INFERRED_MATCH for AI commands.

Resume when: Option B (an independent, authenticated
observer) becomes feasible.

SUMI Guard does not use updatedInput.

## 1. Objective

Measure the identity and lifecycle of one explicitly
owned Windows test process through its retained handle.

This is a measurement laboratory, not OS attestation.

## 2. Ownership - Q01

The lab runner owns the child process and its handle.

- Launch a fixed, controlled test executable.
- Retain the Process instance returned by launch.
- Never substitute a later PID-based lookup.
- Never accept an arbitrary target PID.
- Never expose an arbitrary-process collector.
- Do not transfer handle ownership to caller data.

## 3. Observation Timing - Q02

- Capture identity during the process lifetime.
- Preserve the same handle for the exit scenario.
- Test post-exit behavior without reopening by PID.
- Record unavailable values as failures.
- Do not assume all APIs succeed after termination.

## 4. Partial Failure - Q03

Every observation records:
- success or failure
- native error code, if available
- operation name
- measurement time
- missing or unavailable fields

A partial result never becomes authenticated evidence.

## 5. Resource Cleanup - Q04

Use try/finally for deterministic cleanup.

- Dispose managed Process resources.
- Release every separately acquired native handle.
- Do not close a borrowed handle twice.
- Test failure paths and repeated executions.
- Verify cleanup without modifying unrelated processes.
- Disposing a Process wrapper does not terminate its child.
- Define bounded cleanup for the exact child started by this run.
- Never terminate using a stale or unverified PID.
- Parent-crash orphan prevention requires a separate design
  and negative test; it is not guaranteed by this lab.
- Document the actual rights of the retained process handle.
- Do not assume query-limited rights from an API name alone.

## 6. PID Reuse - Q05

Use synthetic inputs to reproduce PID reuse cases.

Do not force Windows to recycle process identifiers.

A live test may observe a process exit but must not
interpret PID equality alone as process identity.

## 7. Authentication Boundary - Q06

Option A provides no independent collector authentication.

The output is a local measurement record.

No JSON field, nonce, hash or precision label creates
authentication by itself.

## 8. Same-User Threat Model - Q07

A compromised same-user process may modify
in-process code, objects or outputs.

Option A does not defend against that attacker.

An independently authenticated observer remains
a separate future architecture decision.

## 9. Verification - Q08

Synthetic cases:
- forged provenance flag
- forged timestamp precision
- mismatched execution ID
- reversed observation order
- missing values
- stale observations
- PID reuse scenario
- replayed observation
- concurrent identity mix-up

Real Windows cases:
- owned test process start
- handle acquisition
- PID through retained handle
- creation time through retained handle
- executable path through retained handle
- process exit during observation
- API error recording
- handle cleanup
- CIM comparison (UNDECIDED - see below)

Record which cases are synthetic and which are real.

CIM comparison - UNDECIDED (proposal, 2026-11-06).
ADR section 7 lists "Measure differences against CIM observations"
and threat model V09 covers a CIM CreationDate that differs
from the handle-bound creation time. Whether G1 includes it
stays open until the operator decides:

- Option A: include it as the last real Windows case.
  The only PID used is the value read through the retained
  handle (GetProcessId on the section 10B duplicate). The CIM query
  is read-only and its result is for comparison only; it
  never feeds a trust, match or provenance decision.
  If Option A is chosen, section 2 "Never substitute a later
  PID-based lookup" gets one stated exception, limited to
  this single comparison case: a read-only CIM lookup by
  that handle-derived PID, used only to compare values.
- Option B: leave it out of G1 and carry it to G2.

Recommended: Option A. Not decided; the operator decides.

G1 items to fill (proposal, 2026-11-06):
- Add synthetic cases for threat model V08 (executable path
  differs from expected image), V18 (observer crashes during
  capture) and V19 (evidence truncated or partially written).
- A06: run the real cases from a non-elevated session,
  record the elevation state, and confirm no code path
  enables a privilege.
- A07: confirm by review that the only handle source is the
  retained Process object and that no OpenProcess call or
  PID input exists.
- A08 (regression): tests/Invoke-OsProcessIntegrationSyntheticTests.ps1
  and tests/Invoke-OsProcessVerificationSyntheticTests.ps1
  still pass unchanged and still assert UNMATCHED.
- A09 (regression): tests/Invoke-OsProcessCorrelationSyntheticTests.ps1
  cases PUBLIC_API_CANNOT_ENABLE_DIRECT_MATCH and
  PRODUCTION_DIRECT_MATCH_DISABLED still pass unchanged.
- Limit of section 10B "Verify the duplicate refers to the owned
  process": it compares GetProcessId on the duplicate with
  Process.Id of the same retained object, so it is a
  consistency check inside the lab process, not an
  independent confirmation.

## 10. Strict Implementation Boundaries

- Windows PowerShell 5.1 compatible.
- Opt-in execution only.
- No production hooks or monitoring.
- No WMI subscriptions or ETW.
- No administrative elevation.
- No SeDebugPrivilege.
- No PROCESS_ALL_ACCESS.
- No external API dependency.
- No persistent service.
- No arbitrary PID lookup.
- No production DIRECT_MATCH.
- No Phase 3 or Phase 4 trust promotion.
- No automatic activation after installation.

### 10A. Fixed Child Process Contract

- Platform: Windows 11 / Windows PowerShell 5.1.
- Executable: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
- Resolve the absolute path before launch.
- Fixed arguments:
  -NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 15"
- UseShellExecute must be false.
- Do not accept arbitrary executable paths, arguments or PIDs.
- Acquire the owned Process handle promptly after launch.
- If handle acquisition fails, report failure without a PID reopen.
- The child is expected to exit naturally after its bounded sleep.
- Use a bounded 20-second completion check.
- A timeout is a failure, not successful observation.

### 10B. Handle Ownership Contract

- The managed Process object owns its original handle.
- Never call CloseHandle on Process.Handle.
- Duplicate the retained original handle using DuplicateHandle.
- Use PROCESS_QUERY_LIMITED_INFORMATION (0x1000) for the
  duplicated measurement handle.
- Make the duplicate non-inheritable.
- Use dwOptions=0, not DUPLICATE_SAME_ACCESS.
- Verify the duplicate refers to the owned process.
- Run GetProcessId, GetProcessTimes and
  QueryFullProcessImageNameW on the same duplicate.
- Never substitute OpenProcess using a PID.
- Close the duplicated handle exactly once in finally.
- Dispose the Process wrapper separately.
- The original handle may carry broader rights;
  do not describe it as query-limited without verification.
- Any duplication or native-query failure is fail-closed.

### 10C. Completion and Failure Contract

- Record successful natural completion separately from timeout.
- Record failures from each native API independently.
- Never invent missing measurements or success flags.
- Cleanup may affect only the exact child started by this run.
- Never use a stale PID as a termination target.
- If termination is needed, validate the retained process
  instance and restrict the action to that owned test child.
- Proposal (2026-11-06): termination, when needed, goes only
  through the retained original Process object. It is never
  done through the duplicated measurement handle
  (PROCESS_QUERY_LIMITED_INFORMATION), and the duplicate is
  never given a termination right.
- Test cleanup after normal success and injected failures.
- Do not claim that Dispose terminates the child.
- Parent-crash orphan prevention is not established.
- Preserve G0: REVIEW PENDING until explicit approval.
- No runtime hooks or production trust-state changes.

### 10D. Output Record (proposal, 2026-11-06)

Fields this lab can emit, chosen from threat model section 5:
- schema_version
- execution_id (the lab run identifier)
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

Not emitted: collector_instance_id and observation_nonce.
Option A has no independent collector and no replay
protection (section 7), so these values would suggest an
authentication the lab does not have.

provenance_level is a constant written by the lab code path.
It is never built from input, arguments or another field.
It describes the collection method only; whether the
measurement succeeded is read from collection_status.

The level is ADR section 6 L2 at most. L2 is not resistance to
tampering within the same process.

Output goes to standard output only. The lab writes to no
store, registers no hook and saves no file. The operator may
redirect standard output.

### 10E. Execution Environment (proposal, 2026-11-06)

- Real Windows cases run only behind an explicit opt-in
  switch. They are not part of the default CI test suite.
- Whether to add them as a CI job is decided at G1, after
  the local results are reviewed.
- The CI suite runner fails on a test file that is in
  neither its included nor its excluded list, so a real-case
  test script must be added to the excluded list with the
  reason.
- The 20-second completion check against the 15-second
  child sleep leaves a small margin.
- A timeout is a failure. Record the elapsed time of every
  real case.
- On a slow or heavily loaded machine, a timeout may be a
  false failure rather than a defect. Results must say so
  when a timeout occurs.

## 11. Acceptance Criteria

A01: All synthetic negative cases fail closed.
A02: Owned test process identity can be measured.
A03: PID, creation time and image path are read
     through the retained process handle.
A04: Missing measurements are never fabricated.
A05: Handles are released on success and failure.
A06: No privilege elevation is required.
A07: No unrelated process is accessed.
A08: Existing Phase 4 diagnostic integration remains
     UNMATCHED.
A09: No production DIRECT_MATCH is enabled.
A10: Independent review identifies residual risks.

## 12. Gate Decision

G0: REVIEW PENDING - NOT APPROVED
G1: NOT STARTED
G2: NOT STARTED
G3: NOT STARTED
G4: NOT AUTHORIZED

GO:
- Review this specification.
- Prepare synthetic test cases.
- Define the native API contract.

NO-GO:
- Start native collection before G0 approval.
- Enable production correlation trust promotion.
- Install persistent OS monitoring.
- Claim authenticated process provenance.

Approval must be explicit and separately recorded.