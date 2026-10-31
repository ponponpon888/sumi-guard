# Changelog

All notable changes to SUMI Guard. Dates are JST. Each release links the
measurement records that back its claims; a claim without a record is not made.

## Unreleased

### Added

- **Enforcement demo** `demo/Start-SumiGuardEnforcementDemo.ps1`: six scenes
  (off, recorded, denied, unlisted tool, kill switch, kill switch removed)
  against the real enforcement hook, fed through standard input without
  calling Claude. Disposable `%TEMP%` folder only; optional asciicast output
  for the README GIF. Host behaviour on deny is backed by the gate 2 and 4
  records, not by the demo.
- **CI**: `tests/Invoke-EnforcementDemoSyntheticTests.ps1` runs the demo with
  the hook's test seam in place of the DPAPI store and checks every scene,
  the cast file, cleanup, and that no path or user name is printed.
- **Claude Code MONITOR hook setup** (`tools/Invoke-SumiGuardClaudeMonitorHookSetup.ps1`,
  `SumiGuard.HookSetup`): `-Action Install` registers the MONITOR hook for the
  PowerShell tool in one named settings file, using the registration verified
  in docs/28; `-Action Uninstall` removes only that entry. Everything else in
  the file is checked to be unchanged before writing, a second Install is a
  no-op, a changed file is backed up beside itself, written through a
  temporary file and read back. `-WhatIf` writes nothing. Never registers the
  enforcement hook and never deletes a store.
  ([docs/42](docs/42-claude-monitor-hook-setup.md))
- **CI**: `tests/Invoke-ClaudeMonitorHookSetupTests.ps1` (synthetic settings
  and stand-in stores, DPAPI-independent).

## [0.2.0-preview] - 2026-10-28

Opt-in `ENFORCE_RECORDING` ("do not run what cannot be recorded") for one
Claude Code route, with all four safety gates closed by measurement. The
default is still MONITOR, and nothing registers the enforcement hook for you.

### Added

- **Recording decision and Claude deny response** (`SumiGuard.EnforcementDecision`,
  `SumiGuard.ClaudeResponse`): pure functions that turn a recording result into
  ALLOW / DENY with a fixed reason code, and a DENY into the fixed Claude Code
  `PreToolUse` deny JSON. No command text, path or exception text can reach
  the response. ([docs/33](docs/33-recording-enforcement-decision-stage.md),
  [docs/34](docs/34-claude-pretooluse-response-prototype.md))
- **Operator setting and kill switch** (`SumiGuard.EnforcementControl`):
  `enforcement.json` in a control directory restricted to the user and SYSTEM;
  creating `ENFORCEMENT_OFF` there returns to MONITOR on the next call; any
  doubt about the setting also means MONITOR.
  ([docs/36](docs/36-gate4-enforcement-control.md))
- **Bounded lock wait and narrower reasons**: `LOCK_TIMEOUT` and
  `STORE_CAPACITY_REACHED` are reported separately from other body-store failures.
- **Notice file**: one fixed-field line per deny or fail-open, separate from
  the recording stores, size-capped, with an action hint
  (`RUN_RETENTION_CLEANUP`, `RETRY_LATER`, `CHECK_STORE_ACL`).
- **Opt-in enforcement hook** `hooks/Invoke-SumiGuardEnforcementHook.ps1`:
  steps aside unless the operator enforces this exact route; records the
  encrypted body; denies when the recording is not confirmed; fails open with
  a notice on unreadable input or its own failure.
  ([docs/37](docs/37-gate4-enforcement-hook.md))
- **Operator check tools** `tools/Invoke-SumiGuardGate3OperatorCheck.ps1` and
  `tools/Invoke-SumiGuardGate4OperatorCheck.ps1`, writing redacted result files.
- **README safety-gate table** with the record behind each gate.

### Measured

| Gate | Result | Record |
|---|---|---|
| 2. Host honours deny | PASS, Claude Code 2.1.309 | [2026-10-23](measurements/2026-10-23-claude-pretooluse-deny-gate2.md) |
| 3. DPAPI and ACL on the operator machine | PASS, 31/31 cases | [2026-10-27](measurements/2026-10-27-gate3-operator-check.md) |
| 4. Enforcement hook on one route, kill switch | PASS, Claude Code 2.1.310, Bash | [2026-10-28](measurements/2026-10-28-gate4-operator-check.md) |

### Fixed

- Hook tests now send standard input as exact bytes; Windows PowerShell 5.1
  could prepend a BOM. (#16)
- Under strict mode in Windows PowerShell 5.1, listing the properties of an
  empty object threw; the hook, control, decision and response modules no
  longer do this.

### CI

- Failing test cases are also written as workflow annotations, so a failure
  can be named without downloading the job log.

### Not included

- Codex enforcement (gate 2 was measured on Claude Code only).
- Routes other than tools with a `tool_input.command` string.
- Automatic hook registration; enabling enforcement for daily use stays a
  manual operator decision.

## [0.1.0-preview] - 2026-10-20

First public preview: MONITOR-only local audit of Claude Code and Codex
`PreToolUse` events on Windows, metadata-only by default, with DPAPI-protected
body storage on explicit opt-in, read-only CLI, and Windows PowerShell 5.1 CI.

[0.2.0-preview]: https://github.com/ponponpon888/sumi-guard/compare/v0.1.0-preview...v0.2.0-preview
[0.1.0-preview]: https://github.com/ponponpon888/sumi-guard/releases/tag/v0.1.0-preview
