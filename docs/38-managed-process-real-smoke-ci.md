# Managed Process Evidence: real-child smoke check (CI)

## Purpose

This is a **single harmless child process** check that complements, but does
not replace, the 31 synthetic Managed Process Evidence cases. The check is
opt-in when run directly and is executed as a separate GitHub Actions job
(`managed-process-real-smoke`) on an ephemeral `windows-latest` runner.

`tests/Invoke-ManagedProcessEvidenceRealSmokeTests.ps1 -RunSmoke` uses
`Invoke-SumiGuardManagedProcessEvidenceConnection` with the actual process
adapter and a new random correlation identifier. The existing product plan
constructs a fixed Windows PowerShell 5.1 `-EncodedCommand` which outputs a
single correlation marker and exits. The check supplies no arbitrary user
command and does not enable any hook, monitor, or persistent storage.

## Success criteria

The test fails closed unless all of the following are reported:

- The fixed command body and arguments match the preflight plan.
- The launch plan is verified; the process is confirmed through reconciliation.
- Exactly one observer call and one successful `Process.Start` are reported.
- The adapter obtained the PID, start time, and executable path (presence only).
- The child returned the matching correlation identifier.
- Exit was confirmed normally with exit code `0`.
- Stdout exactly matched the expected marker; stdout and stderr capture
  completed, with no timeout or kill.
- The child success status is `SUCCEEDED`; the adapter completed with no
  reported exception type.
- The storage status remains `NOT_ATTEMPTED`.

The output contains Boolean failures, duration, and at most an exception
**type**. It intentionally omits child stdout/stderr, executable path,
process ID, host-specific identity, and exception message.

## Run explicitly

From the repository root on Windows PowerShell 5.1:

```powershell
.\tests\Invoke-ManagedProcessEvidenceRealSmokeTests.ps1 -RunSmoke
```

Invoking the test without `-RunSmoke` starts nothing and exits `2`.
The synthetic/DPAPI-independent suite excludes this script with an explicit
reason, since it performs real process execution in its own CI job.

## Interpretation limits

A green job establishes the documented normal-path evidence **only for the
GitHub-hosted Windows runner and the tested commit**. It does **not** establish:

- DPAPI CurrentUser behavior or permissions on an operator machine.
- Independent OS-observer correlation, attack attribution, or `DIRECT_MATCH`.
- Independent post-exit process identity revalidation or PID-reuse resistance.
- Real-process nonzero-exit, abnormal termination, kill failure, or timeout
  behavior. Those paths remain covered only by synthetic cases.
- Safety of arbitrary commands, live hooks, enforcement, or production use.

The job has a five-minute limit. If it fails, review the structured failed
checks rather than treating a partial `PROCESS_CONFIRMED` result as successful
child execution.
