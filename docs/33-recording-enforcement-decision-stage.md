# Recording enforcement decision — isolated first stage (2026-10-22)

## Status and scope

This change is **decision-only**. It does not turn on automatic blocking, does not
modify `hooks/Invoke-SumiGuardMonitorHook.ps1`, and does not register any
Claude/Codex hooks or touch a Windows user's configuration, production store,
GitHub mainline, or production deployment.

The new `SumiGuard.EnforcementDecision` module exports only
`Get-SumiGuardRecordingDecision`. It produces a fixed-code recommendation
(`ALLOW` or `DENY`) without emitting a host permission decision, executing
a command, or persisting anything.

It is an incremental implementation of the separate
[ENFORCE_RECORDING design](26-enforce-recording-design.md), **not** a
dangerous-command blocker. A detection result cannot trigger deny here.

## Pure decision contract

Inputs:

- `RequestedMode`: `MONITOR` (default) or `ENFORCE_RECORDING`.
- `RouteAllowlisted`: false by default. An eventual trusted host/runner
  must derive this from **operator-owned configuration**, never from command
  text, hook JSON, or instructions in a repository.
- `HookInputStatus`: `VALID` or `INVALID`.
- `AdapterResult`: actual result of a caller-verified ExecutionAdapter
  invocation. **An arbitrary object is not proof of recording.**

Outputs: schema version, requested/effective mode, abstract decision,
fixed reason code, and explicit `decision_only=true`,
`hook_response_generated=false`, `command_executed=false`.

| Condition | Abstract decision | Reason |
|---|---|---|
| Default MONITOR | ALLOW | MONITOR_ONLY |
| Strict mode requested, route not allowlisted | ALLOW | ROUTE_NOT_ALLOWLISTED (effective MONITOR) |
| Strict mode, invalid/unidentified hook input | ALLOW | INVALID_HOOK_INPUT_NOT_ENFORCED |
| Strict mode, body **and** event saved, adapter success true, both states SAVED | ALLOW | RECORDING_CONFIRMED |
| Strict mode, metadata-only receipt | DENY | BODY_NOT_CAPTURED |
| Strict mode, body failure but event saved | DENY | BODY_STORE_FAILED |
| Strict mode, store validation failure | DENY | STORE_VALIDATION_FAILED |
| Strict mode, body hash failure | DENY | BODY_HASH_FAILED |
| Strict mode, event save failure | DENY | EVENT_SAVE_FAILED |
| Strict mode, missing/unknown/inconsistent status | DENY | RECORDING_NOT_VERIFIED |

A status string alone never produces ALLOW under strict mode: adapter
`success` must be a boolean true and both storage statuses must be SAVED.
Unsupported errors remain generic instead of fabricating a specific
capacity or lock failure from insufficient adapter evidence.

The invalid-input allow decision follows the existing design's explicit
fail-open choice. A crashed hook or a host that ignores its response can
also fail open. Neither issue is solved by this module.

## Privacy and limits

Strict recording requires protected command-body persistence; the currently
default metadata-only MONITOR path is deliberately insufficient. Command
bodies can include credentials. Using strict recording would therefore
require explicit operator opt-in, DPAPI/ACL verification on the actual
Windows machine, bounded storage, sensitive-data handling, and rollback.

The pure module has no API for allowlisted-route discovery, session
authentication, plugin configuration, host validation, retry scheduling,
notification persistence, or application of an actual deny. No claim of
effective host blocking, complete command capture, tamper-proof logs,
AV/EDR coverage, or Windows-wide protection is made.

## Verification

`tests/Invoke-EnforcementDecisionSyntheticTests.ps1` exercises MONITOR,
route scope, invalid input, complete/partial recording, missing evidence,
failures, inconsistent statuses, and output privacy, with fixed mock
adapter results. Registered in the existing Windows PowerShell 5.1 CI
synthetic suite. A passing CI run verifies these decision cases only;
it does **not** prove that Codex or Claude Code honors deny.

## Next gates before any live enforcement

1. Review this decision mapping against actual adapter results and the
   design; fix any failing synthetic/CI result.
2. Establish a **separate**, explicitly opt-in host hook with trusted
   allowlist and reversible configuration; never mutate default MONITOR.
3. In a disposable child session, prove that the chosen host actually
   honors a deny response on a harmless fixed command. Test malformed
   input, stdout failure, timeout, and host mismatch.
4. Verify DPAPI CurrentUser, ACLs, body-storage failures, and full event
   provenance on the operator's Windows machine using disposable stores.
5. Introduce bounded retries/diagnostic codes, notifications and a tested
   kill switch before even one narrowly-scoped live path is enabled.

Do not merge or enable enforcement based on this document alone.
