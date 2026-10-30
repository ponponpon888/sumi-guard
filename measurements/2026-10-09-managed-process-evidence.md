# Managed process evidence

- Scope: new alias runner, synthetic tests, and the separately recorded normal-path real-process evidence below.
- Storage: `NOT_ATTEMPTED`.
- At the initial 2026-10-09 record, real process, fixed command, network, and child Codex were not started. Later validation evidence is recorded below.

## Verification

- Synthetic test result: 9/9 passed (test-double only).
- Static check: the alias runner calls the existing assessment-verification connection and is guarded against dot-source execution.
- Static gap: no implementation obtains PID, start time, or `MainModule.FileName` from an actual child `Process`; `PROCESS_CONFIRMED` therefore remains unimplemented for a real child.
- Snapshot comparison: unavailable. The start-time file/hash map was not retained, so no replacement baseline was generated.
- `.demo-data`: current file count is 12; additions, changes, and deletions versus the unavailable baseline are not comparable.
- Real confirmation: not performed.

## 2026-10-09 implementation update

- A real-process adapter is present but was not invoked for this record. It reuses the managed PowerShell `ProcessStartInfo` construction and starts only through the existing assessment/verification connection after evaluation and launch-plan checks, with both explicit switches.
- When used, it obtains PID, start time, and `MainModule.FileName` from the started `Process`; stdout and stderr are captured independently, timeout termination and disposal are handled, and an observed fixed-format child correlation return is supplied to the existing reconciliation path.
- Missing or failed observations remain unobserved and do not manufacture `PROCESS_CONFIRMED`. Storage remains `NOT_ATTEMPTED`; dot-sourcing starts nothing.
- This update does not assert that any historical comparison limitation has been resolved.

## Verification update

- Synthetic result: 10/10 passed through the same connection using test doubles only: normal, path mismatch, ID mismatch, missing observation, observation exception, early exit, start failure, timeout, switch-off, and preflight mismatch.
- No real child process, fixed command, child Codex, or network operation was started.
- A project-start inventory and pre-edit copies of the three changed files were saved outside the project in Temp, reloaded, and verified by SHA-256 before editing.

## 2026-10-09 plan-alignment update

- The runner now fixes the child body, encoded arguments, and `ProcessStartInfo` before evaluation. The same body is supplied as both assessment and launch text; arguments are not rebuilt after reconciliation.
- Argument/body equality is checked in the runner because the existing reconciliation API has no argument field. A failed local plan check prevents observer invocation and Process.Start attempts; it remains unverified rather than inferred.
- `execution_start_count` is retained as the existing connection's observer-invocation count, not a Process.Start-success count. New runner fields separate observer invocations, Process.Start attempts, and successful starts.
- Adapter exceptions are reduced to stage, exception type, and HResult. Existing connection catch results retain its exposed reason-code properties without inferring the underlying cause.
- Real-process execution remains unperformed for this update. Synthetic tests use only observers or adapter overrides and start no child process.
- Verification for this update: 15/15 synthetic cases passed on Windows PowerShell 5.1; real adapter, real child, fixed command, child Codex, and network access were not invoked.

## 2026-10-09 fake-process regression update

- Cause: local `$pid` collided case-insensitively with PowerShell's read-only automatic `$PID`, preventing entry to the adapter's protected start path.
- Fix: the local observation variable is now `$observedProcessId`; the public `observed_pid` property is unchanged.
- Test scope: an internal `ProcessFactoryOverride` is available only as a function parameter, with the production default retaining `Diagnostics.Process` construction. A false-returning fake `Start()` exercises parameter binding, initialization, one start attempt, zero successes, fixed start-failure evidence, and `Dispose()` without starting a child.
- Verification for this update: 16/16 synthetic cases passed on Windows PowerShell 5.1; the fake Process was the only process substitute used.

## 2026-10-09 result-propagation static review

No target was rerun and no test was executed for this review. The prior one-time safe summary is retained: it reported plan verification and `PROCESS_CONFIRMED`, but fields not present in the final runner report remained unobserved in that summary.

| Item | Adapter acquisition variable | Adapter return property | Final runner report | Static classification |
| --- | --- | --- | --- | --- |
| Child exit code | none | none | none | Not acquired. |
| Timeout | `timedOut` | `timed_out` | none | Acquired when the adapter runs, but not returned by the final runner report. |
| Fixed-output match | none | none | none | Not acquired; stdout is used only for correlation parsing. |
| PID | `observedProcessId` | `observed_pid` | none | Conditionally acquired, but no final property or acquisition Boolean is returned. |
| Start time | `time` | `observed_start_time_utc` | none | Conditionally acquired, but no final property or acquisition Boolean is returned. |
| Executable path | `path` from `MainModule.FileName` | `observed_executable_path` | none | Conditionally acquired, but no final property or acquisition Boolean is returned. |
| Correlation ID | `childId` parsed from captured stdout | `execution_id` | `correlation_returned` | The final Boolean is derived from `process_confirmation_status`, not exposed as an isolated ID-comparison result. |

`PROCESS_CONFIRMED` is not supplemented from a plan value. The adapter returns observed `execution_id`, observed `observed_executable_path`, and `process_started`; the existing reconciliation path receives that evidence and compares the observed ID and observed path with its assessment/planned ID and host evidence. The runner forwards its resulting `process_confirmation_status` and `process_confirmation_reason_code` unchanged. PID, start time, child exit code, timeout, and fixed-output match are not inputs to that confirmation decision in the current result path.

## 2026-10-09 observation propagation update

- The adapter now returns child exit code only after a normal observed exit, timeout state, exact stdout contract match, direct correlation-ID comparison, and presence-only Booleans for PID, start time, and executable path. Missing observations remain null.
- Final reporting preserves these adapter fields and keeps `child_execution_status` separate from existing process confirmation. Storage remains `NOT_ATTEMPTED`.
- Synthetic coverage uses only fake Process and capture objects for normal exit, nonzero exit, timeout, output mismatch, missing observation, ID mismatch, and final-report propagation; no real child was started.

## Current validation evidence

- After the exit-code-unavailable correction, `Invoke-ManagedProcessEvidenceTests.ps1`
  completed locally on 2026-10-30 JST under Windows PowerShell
  `5.1.26100.9818`. The parent captured OS exit code `0` immediately after the
  test process call. Its final JSON reported `success=true`, 31 executed and
  passed cases, and zero failures; planned and executed counts were both 31,
  with no unexecuted, duplicate, or unexpected cases.
- The two added cases verify that a null child exit code is not treated as
  successful child execution: one returns null directly and one uses a
  throwing ScriptProperty getter. The ScriptProperty case verifies the
  resulting null/success-status behavior only; it does not prove arrival at
  the product `OBSERVE_EXIT_CODE` catch.
- Earlier local CI and Analyzer records are retained as historical evidence.
  The normal-path real-process evidence below predates the exit-code-unavailable
  correction and has not been rerun as evidence for that corrected behavior.
- An intermediate 2026-10-30 JST CI run recorded three test failures. Its cause
  remains unresolved; the later successful run does not prove that cause was
  resolved, and neither `PSModulePath` nor the parent host is asserted as its
  cause.
- The final post-correction CI-suite run completed on 2026-10-30 JST under
  Windows PowerShell `5.1.26100.9818`. The supervisor captured OS exit code
  `0` immediately after the runner call. Its final JSON reported
  `success=true`, `executed_count=21`, `failures=[]`, and `excluded_count=4`,
  with no `UNCLASSIFIED_TEST` failure. The runner recorded its environment
  before invoking the suite once, with no arguments, through `&` in that same
  process.
- Its `Invoke-ManagedProcessEvidenceTests.ps1` result reported 31/31 passed,
  zero failures, and no unexecuted, duplicate, or unexpected cases. This is
  distinct from the previously confirmed 29-case synthetic result and from the
  normal-path real-process execution evidence below.
- The post-correction Analyzer run completed under Windows PowerShell
  `5.1.26100.9818` with PSScriptAnalyzer `1.25.0`; its captured OS exit code
  was `0`, and its final result reported `success=true`, `error_count=0`,
  `blocking_count=0`, no baseline excess, and no findings for the target demo
  or test files.
- DPAPI-dependent tests were not executed, and operator-machine verification
  was not performed. The CI suite can include existing tests that use real child
  processes; this record does not assert that Managed Process Evidence
  real-process verification was performed.
- A normal-path Managed Process Evidence run on 2026-10-30 JST recorded
  in-run evidence from the demo under Windows PowerShell `5.1.26100.9818`.
  It reported `PROCESS_CONFIRMED`, a matching correlation ID,
  `child_execution_succeeded=true`, `child_exit_code=0`,
  `process_exit_confirmed=true`, and `termination_status=EXITED_NORMALLY`.
  stdout and stderr capture completed, stdout matched the expected value, no
  kill was attempted, and `adapter_exception_type` and
  `adapter_exception_hresult` were null.
- This is execution-internal evidence emitted by the demo. The outer runner's
  OS exit code and elapsed duration were not collected because collection did
  not complete after the demo JSON was emitted. The cause is unresolved; this
  record asserts neither a product-side failure nor successful completion of
  the outer collection.
- Independent post-exit process-identity revalidation was not performed.
  Real-process abnormal and timeout paths also remain unmeasured.
