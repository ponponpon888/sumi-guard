# Claude Code PreToolUse response prototype (2026-10-22)

## Status: serializer and synthetic tests only

This prototype prepares a **candidate deny response** for Claude Code's
`PreToolUse` hook protocol. It is not installed, registered, called from an
operational hook, or enabled on the operator machine.

- Core logic: `src/SumiGuard.ClaudeResponse/`
- Synthetic tests: `tests/Invoke-ClaudeResponseSyntheticTests.ps1`
- Existing monitor hook `hooks/Invoke-SumiGuardMonitorHook.ps1`: **unchanged**.
- Existing decision module: `SumiGuard.EnforcementDecision`; it is still
  independently testable without a host.

The official Claude Code protocol documents the response envelope
`hookSpecificOutput.hookEventName=PreToolUse`,
`permissionDecision=deny`, and a fixed
`permissionDecisionReason`:
https://code.claude.com/docs/en/hooks

## Output contract

The formatter accepts the pure recording-decision object. It emits **only**
the following JSON if all strict preconditions are met:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SUMI Guard: required recording not confirmed."}}
```

For MONITOR, invalid input, non-allowlisted routes, an allowed result,
missing fields, or unrecognized reason codes, it emits no decision (`null`
in PowerShell). It never emits `permissionDecision=allow` or `ask`,
which would change normal host permission handling.

A DENY candidate is emitted only if all these fields agree:

1. schema 1, requested and effective mode both ENFORCE_RECORDING;
2. decision DENY, decision_only true, hook_response_generated false;
3. command_executed false, with one of the fixed expected recording-failure
   reason codes.

The only denial reason sent to Claude is a fixed ASCII message. The
formatter ignores extra object properties, including source text,
exception messages, credentials and file paths.

## What this does not prove

- The response was actually written to a Claude Code subprocess's stdout.
- The host received, parsed, and enforced the denial. That requires a
  disposable *real-host* PreToolUse experiment.
- The evaluator observed the same exact command and interpreter that a
  real runner will execute.
- The decision's adapter result is authentic. The current pure function
  receives an object from its caller; it cannot authenticate the storage
  result. A strict, controlled caller boundary is still required.
- Host timeout, crashes, stdin decode errors or hook registration errors
  will deny execution. In general these paths may fail open.
- This detects or blocks dangerous commands: ENFORCE_RECORDING protects
  evidence collection and is not an anti-malware feature.

## Required next step (not implemented here)

Create a disposable Claude Code child session and use a harmless
sentinel command to measure whether Claude respects an actual denial.
Use an isolated temp directory, mock/fixed input, and a throwaway local
hook registration only. Before any operational setting change, verify
the exact version, host-specific payload and enforcement semantics.

Do not enable on the normal host, alter global/project hook
registrations, or merge based solely on CI. Revisit privacy consequences
of full-body recording: the default MONITOR mode is metadata-only by
design. Forcing full-body storage may expose secrets despite DPAPI.
