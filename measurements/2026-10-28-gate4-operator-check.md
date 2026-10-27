# Gate 4: opt-in enforcement hook on the operator machine (2026-10-28)

## Result

**PASS.** A real Claude Code honoured the SUMI Guard enforcement hook on one
route, `claude-code:PreToolUse:Bash`: a recorded call ran, an unrecordable call
was blocked, and the kill switch let the next call through without the hook
doing anything. Verdict `PASS_GATE4_OPERATOR_CHECKS`, no problems reported.

This closes gate 4 of the README gate table for this host, version and route.

## Environment

| Item | Value |
|---|---|
| Run | 2026-10-28 01:31:40 to 01:33:05 JST (85 s) |
| Commit | `aabf531853820114a5beddb4fe090a8fe42aac77` on `test/gate4-operator-check-20261028` |
| Tracked changes | 0 |
| Claude Code | 2.1.310, `claude -p`, model haiku, max 4 turns, `--allowedTools Bash` |
| PowerShell | Windows PowerShell 5.1.26100.9711 |
| OS | Windows 10.0.26300 |
| Tool | `tools/Invoke-SumiGuardGate4OperatorCheck.ps1` |

Everything lived in one new folder under `%TEMP%` (control directory, execution
store, body store, work folder, one settings file per run), kept as evidence.
The hook was loaded only per run with `--settings`. `~/.claude/settings.json`,
project settings and existing hooks were not changed.

## Runs

| | A: enforcement on, stores healthy | B: body store ACL widened | C: `ENFORCEMENT_OFF` created |
|---|---|---|---|
| Hook ran | yes | yes | yes |
| Hook status | `ENFORCED` | `ENFORCED` | `NOT_ENFORCED` |
| Setting | `CONFIG_LOADED` | `CONFIG_LOADED` | `KILL_SWITCH_ACTIVE` |
| Intent | `EVENT_AND_BODY_SAVED` | `EVENT_SAVED_BODY_COLLECTION_FAILED` | `NOT_ATTEMPTED` |
| Decision / reason | ALLOW / `RECORDING_CONFIRMED` | DENY / `BODY_STORE_FAILED` | ALLOW / `MONITOR_ONLY` |
| Response sent to Claude Code | none | the fixed deny JSON | none |
| Deny text in Claude's stream | no | **yes** | no |
| Marker file created by the command | **yes** | **no** | **yes** |
| New notices | 0 | 1 (DENY, `BODY_STORE_FAILED`) | 0 |
| Claude exit code | 0 | 0 | 0 |

Execution store events: 1 after A (body captured, `CAPTURED_ENCRYPTED`), 2 after
B (the event of the denied call, without body), still 2 after C. So with the
kill switch on, the hook recorded nothing, as designed.

In B, widening the body store ACL made LocalStore refuse the store, the adapter
saved the event without the body, and the decision denied the call. LocalStore's
reason in this case (`STORE_VALIDATION_FAILED`) is not one of the narrowed
reasons, so the generic `BODY_STORE_FAILED` was reported, as docs/36 specifies.

## Files measured

SHA-256 of all 7 files the tool hashed matches commit `aabf531`:

| File | SHA-256 |
|---|---|
| `hooks/Invoke-SumiGuardEnforcementHook.ps1` | `fbd552d42515b547878170ebfdbb3e7522f6092b2d7ee7b79bd20f328dec5fa4` |
| `src/SumiGuard.EnforcementControl/SumiGuard.EnforcementControl.psm1` | `4aa17db61085e1b772d6ec2ad5e591e0b03a069a90c2770a907de63f47dcd194` |
| `src/SumiGuard.EnforcementDecision/SumiGuard.EnforcementDecision.psm1` | `ff47fa78a29ed9cf6e5f6fd898b672776912083028e3bd1d670e8f88e7424422` |
| `src/SumiGuard.ClaudeResponse/SumiGuard.ClaudeResponse.psm1` | `236fedd2e037220c0c390f3c8e735bbf1c05fccd3aabbf7dbebfc80a0e64a536` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psm1` | `3af55a64e9db20527e4ba8e1679e1ddc92a45970ea739007a4e7a8cd50e9190f` |
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psm1` | `eb591d08c38093033ee9d99f8bedb0626c9a5080fa3a458f779b97c26768bf3d` |
| `tools/Invoke-SumiGuardGate4OperatorCheck.ps1` | `23640f9ffc7d47fb885817d0ff1c73cae800f44986bbbc2bfa4ea4369b2f14b0` |

## Not shown by this measurement

- Interactive Claude Code, other Claude Code versions, other models, Codex.
- Other routes (the `PowerShell` tool, `Write`, `Edit`), and tools without
  `tool_input.command`, which this first version does not enforce.
- A lock timeout or capacity limit on the real store (covered only by
  synthetic tests), and a hook crash or timeout under a real host (fail-open
  by design, docs/26).
- Long-running use. Enforcement is still not registered in any permanent
  setting; turning it on for daily use is a separate operator decision, with
  `ENFORCEMENT_OFF` as the way back.
