# Gate 4, part 2: opt-in enforcement hook (2026-10-28)

## Status: hook and synthetic tests only, not registered anywhere

`hooks/Invoke-SumiGuardEnforcementHook.ps1` wires the part 1 pieces
([docs/36](36-gate4-enforcement-control.md)) into one Claude Code
`PreToolUse` hook:

```
setting (EnforcementControl) -> adapter -> decision -> Claude response -> notice
```

It is a separate script. `hooks/Invoke-SumiGuardMonitorHook.ps1` is
unchanged and stays MONITOR-only. Nothing in this change registers either
hook or touches any Claude Code setting.

## Behaviour

| Situation | Records? | Standard output | Notice |
|---|---|---|---|
| No setting, `MONITOR`, kill switch, unlisted route, broken setting | No | Nothing | No |
| Event with no usable `tool_name` (no route) | No | Nothing | No |
| Enforced route, recording confirmed (event and encrypted body saved) | Yes | Nothing (normal permission flow) | No |
| Enforced route, recording not confirmed | Attempted | The fixed deny JSON | DENY + reason + hint |
| Enforced route, event unreadable (no `tool_input.command`, missing ids) | No | Nothing (docs/26 fail-open) | ALLOW `INVALID_HOOK_INPUT_NOT_ENFORCED` |
| Any internal failure of the hook | Unknown | Nothing (fail-open) | ALLOW `HOOK_INTERNAL_ERROR`, if the notice path works |

- Route id: `claude-code:PreToolUse:<tool_name>`. Only routes listed in the
  operator's `enforcement.json` are enforced.
- On an enforced route the hook always captures the body (DPAPI CurrentUser),
  with the lock wait from the setting. Metadata-only is not a receipt.
- The exit code is always 0. Standard output is either empty or exactly
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SUMI Guard: required recording not confirmed."}}`.
- A notice that cannot be written never changes the decision.
- Execution ids use their own prefix, so they never collide with ids the
  MONITOR hook writes for the same tool call.
- This first version enforces only tools whose `tool_input` has a `command`
  string (Bash, PowerShell). Listing another tool makes its events
  "unreadable" and therefore allowed with a notice.

## Verification

`tests/Invoke-EnforcementHookSyntheticTests.ps1` (CI) runs the hook in-process
with `-RawHookInputJson` and a test seam instead of the adapter: stepping
aside in every non-enforced state, allow on confirmed recording, deny with the
right reason and hint for lock timeout, capacity, invalid store, metadata-only
and adapter exception, fail-open with notice for unreadable input and internal
error, deny unchanged when the notice file is full, kill switch effective on
the next call and reversible, no command text in any output, and stable
execution ids separate from the MONITOR hook's.

## Not shown yet (the operator measurement that closes gate 4)

- Real standard input from Claude Code, the real adapter with DPAPI, and the
  host honouring this hook's deny.
- `tools/Invoke-SumiGuardGate4OperatorCheck.ps1` runs it. From the operator's
  own Windows PowerShell 5.1 window (not inside Claude Code or Codex):

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Dev\sumi-guard\tools\Invoke-SumiGuardGate4OperatorCheck.ps1
  ```

  It makes one folder under `%TEMP%` (control directory, stores, work folder,
  one settings file per run) and calls `claude -p --model haiku --max-turns 4
  --allowedTools Bash --settings <file>` three times:

  | Run | State | Expected |
  |---|---|---|
  | A | enforcement on, stores healthy | recorded with the encrypted body, the command runs, no notice |
  | B | body store ACL widened | DENY, the command does not run, one DENY notice |
  | C | `ENFORCEMENT_OFF` created | hook steps aside, the command runs, no notice, no new event |

  Result: `%USERPROFILE%\Downloads\sumi-guard_gate4_result_<yyyyMMdd>.json`,
  with booleans, counts and fixed codes only. Verdicts:
  `PASS_GATE4_OPERATOR_CHECKS`, `FAIL_DENY_NOT_HONORED` (the command ran after
  a deny), `FAIL_GATE4_OPERATOR_CHECKS`, or `INCONCLUSIVE_*` when the
  measurement itself did not happen (hook never ran, another tool was used,
  uncommitted changes to tracked files, Claude Code not found).
  `~/.claude/settings.json`, project settings and existing hooks are not
  changed. Untracked files do not block the run.
