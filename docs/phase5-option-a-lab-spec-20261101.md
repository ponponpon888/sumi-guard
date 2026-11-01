# SUMI GUARD Phase 5 - Option A Laboratory Specification

Status: PROPOSED - IMPLEMENTATION NOT AUTHORIZED
Date: 2026-11-01
Base: 364a911122cb7b4a71fe56ab55f780ffa730f7ed

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

Record which cases are synthetic and which are real.

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
- Test cleanup after normal success and injected failures.
- Do not claim that Dispose terminates the child.
- Parent-crash orphan prevention is not established.
- Preserve G0: REVIEW PENDING until explicit approval.
- No runtime hooks or production trust-state changes.
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