# Gate 4, part 1: setting, kill switch, bounded lock wait, notices (2026-10-28)

## Status: modules and synthetic tests only

Gate 4 of [docs/33](33-recording-enforcement-decision-stage.md) asks for
bounded retries with diagnostic codes, notifications, and a tested kill switch
before even one narrowly scoped live path is enabled. This change adds those
parts as library code. **Nothing calls them yet.** No hook is registered, the
MONITOR hook is unchanged, and enforcement stays disabled.

Part 2 (a separate, opt-in enforcement hook that wires setting, adapter,
decision, response and notice together) and the one-route operator
measurement come after this. Gate 4 is not closed by this change.

## Operator setting and kill switch

New module `src/SumiGuard.EnforcementControl/`.

The setting lives in an operator-owned control directory, for example
`%LOCALAPPDATA%\SumiGuard\enforcement`, never in a repository and never taken
from hook input. `Initialize-SumiGuardEnforcementControlDirectory` creates it
restricted to the current user and SYSTEM, with a marker file. It never writes
a setting, and it never adopts or re-permissions an existing directory.

`enforcement.json`:

```json
{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"],"lock_timeout_milliseconds":2000}
```

| Key | Rule |
|---|---|
| `schema_version` | integer 1 |
| `mode` | `MONITOR` or `ENFORCE_RECORDING`, exact case |
| `routes` | array of up to 16 distinct `host:event:tool` ids; matched case-sensitively |
| `lock_timeout_milliseconds` | optional integer 100 to 10000, default 2000 |

Any other key makes the whole file invalid.

`Get-SumiGuardEnforcementSetting` never throws. Every doubt becomes
`requested_mode = MONITOR` with a fixed `setting_status`:

| setting_status | When |
|---|---|
| `KILL_SWITCH_ACTIVE` | `ENFORCEMENT_OFF` exists in the control directory, as a file or a directory. Checked first, so it wins even over a broken directory or file |
| `CONFIG_ABSENT` | No control directory, or no `enforcement.json` |
| `CONTROL_DIRECTORY_INVALID` | Relative path, reparse point in the path, or no marker (not created by Initialize) |
| `CONTROL_DIRECTORY_ACL_NOT_RESTRICTED` | Inheritance on, or any rule for someone other than the user and SYSTEM |
| `CONFIG_ACL_NOT_RESTRICTED` | The file itself grants someone else access |
| `CONFIG_TOO_LARGE` | Over 16 KiB |
| `CONFIG_INVALID` | Not strict UTF-8 JSON, unknown key, wrong type or value |
| `INVALID_ROUTE_ID` | The caller's route id is not `host:event:tool` |
| `CONFIG_UNREADABLE` | Any other read error |
| `CONFIG_LOADED` | Valid; `route_allowlisted` is true only for a listed route |

The result feeds `Get-SumiGuardRecordingDecision` directly:
`-RequestedMode $s.requested_mode -RouteAllowlisted $s.route_allowlisted`.

### Turning it off

- Immediately: create an empty file named `ENFORCEMENT_OFF` in the control directory.
- Permanently: delete `enforcement.json`.

Both take effect on the next hook call, with no re-registration and no restart.
Removing `ENFORCEMENT_OFF` restores the previous setting.

## Bounded lock wait and diagnostic codes

`Save-SumiGuardExecutionIntent` gains `-BodyLockTimeoutMilliseconds` (100 to
10000, default 10000, the previous behaviour). LocalStore polls its lock every
25 ms until the budget is spent, so this is the bounded retry docs/26 asks
for; no second retry loop is added, because re-saving after an event was
written would duplicate the execution id.

The adapter result now also carries `body_failure_reason_code`, LocalStore's
fixed status when the body was not saved, else null. The decision narrows
`BODY_STORE_FAILED` with it:

| LocalStore code | Decision reason |
|---|---|
| `STORE_LOCK_TIMEOUT` | `LOCK_TIMEOUT` |
| `ITEM_LIMIT_EXCEEDED`, `TOTAL_LIMIT_EXCEEDED` | `STORE_CAPACITY_REACHED` |
| anything else | `BODY_STORE_FAILED` (unchanged) |

Both new reasons are still DENY, and the Claude response formatter accepts
them, with the same fixed denial text.

## Notices

`Write-SumiGuardEnforcementNotice` appends one line to
`enforcement-notices.ndjson` in the control directory, separate from the
recording stores, so a deny caused by a broken store can still be noted.

```json
{"schema_version":1,"recorded_at_utc":"...","route_id":"claude-code:PreToolUse:Bash","decision":"DENY","reason_code":"STORE_CAPACITY_REACHED","execution_id":"<32 hex or null>","action_hint":"RUN_RETENTION_CLEANUP"}
```

- Fields are validated against fixed patterns; anything else is refused with
  `INVALID_NOTICE_FIELD`. No command text, path or exception text can enter.
- `action_hint`: `RUN_RETENTION_CLEANUP` for capacity, `RETRY_LATER` for lock
  timeout, `CHECK_STORE_ACL` for store validation, else null.
- The file stops at 1 MiB (`NOTICE_FILE_FULL`); it is never rotated or truncated.
- A held file is retried 20 times, 25 ms apart (`NOTICE_LOCK_TIMEOUT`).
- It never throws. Per docs/26, `NOTICE_NOT_PERSISTED` never changes a decision.

## Verification

`tests/Invoke-EnforcementControlSyntheticTests.ps1` runs in the CI suite (it
uses Windows ACLs but not DPAPI). The decision and response synthetic tests
gain the lock and capacity cases. The adapter integration test, which is
DPAPI-dependent and runs only on the operator machine, now also checks
`body_failure_reason_code`.

## Limits

- A process running as the same user can delete the setting, create the kill
  switch, or append to the notice file. The control directory keeps other
  users out; it does not protect the operator from their own processes.
  Disabling only ever moves toward MONITOR.
- Nothing here is called by a hook yet. Whether a host honours a deny was
  measured in gate 2; whether this wiring behaves on the operator machine is
  part 2.
