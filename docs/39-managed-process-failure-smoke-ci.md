# Managed Process Evidence: fixed failure-path smoke check (CI)

## Purpose

Phase 2 adds an opt-in real-child complement to the synthetic failure cases.
`tests/Invoke-ManagedProcessEvidenceFailureSmokeTests.ps1 -RunSmoke` starts
exactly two fixed Windows PowerShell 5.1 children through the managed process
adapter on an ephemeral GitHub Actions `windows-latest` runner:

1. A child writes a random correlation marker and exits with the fixed code
   `7`.
2. A child sleeps for ten seconds without writing a marker; the fixed plan has
   a one-second timeout, so the adapter must kill and confirm exit of the
   specific `Process` instance it started.

The test accepts no caller command text, enables no hook or monitor, performs
no network operation, and writes no persistent store. It checks only Boolean
results, status values, duration, and exception types; it does not print the
child output, PID, executable path, or host identity.

The GitHub Actions workflow runs it in the separate
`managed-process-failure-smoke` job. The normal fixed-child check remains in
`managed-process-real-smoke`; see [docs/38](38-managed-process-real-smoke-ci.md).

## Success criteria

Both scenarios must establish a verified launch plan, with one observer
invocation and one successful `Process.Start`. The nonzero child emits its
marker and must be `PROCESS_CONFIRMED`. The timeout child is intentionally
killed before it emits a marker and therefore must **not** be promoted to
`PROCESS_CONFIRMED`.

- The nonzero child must report normal exit, exit code `7`, matching marker,
  completed output capture, and `NONZERO_EXIT` with
  `child_execution_succeeded=false`. It must not time out or be killed.
- The timeout child must report `TIMED_OUT` with
  `child_execution_succeeded=false`, a kill attempt and success, confirmed
  exit, `KILL_CONFIRMED`, and completed output capture.

Neither outcome is treated as a successful child execution. A partial result,
including an unconfirmed exit after a kill attempt, fails the job.

## Run explicitly

From the repository root on Windows PowerShell 5.1:

```powershell
.\tests\Invoke-ManagedProcessEvidenceFailureSmokeTests.ps1 -RunSmoke
```

Without `-RunSmoke`, the script starts no child and exits `2`. The normal
DPAPI-independent test runner excludes this script explicitly; it is not a
synthetic test.

## Interpretation limits

A green job establishes only the two documented fixed failure paths for the
runner and commit tested. It does not establish arbitrary-command safety,
live-hook behavior, operator-machine DPAPI/ACL behavior, independent OS
observation, process-tree cleanup, kill failure handling, output-read failure,
or post-exit PID-reuse resistance. Those boundaries remain synthetic-only or
out of scope.
