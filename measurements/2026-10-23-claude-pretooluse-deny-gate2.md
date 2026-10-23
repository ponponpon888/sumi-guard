# Gate 2: real Claude Code honors the SUMI Guard PreToolUse deny (2026-10-23)

## Result

**PASS.** A real Claude Code process blocked a tool call when the hook returned the
deny response produced by `SumiGuard.EnforcementDecision` +
`SumiGuard.ClaudeResponse` from `master` `85b8dc5`, and let an unrelated call through.

| Observation | Value |
|---|---|
| Claude Code | 2.1.309, `claude -p`, model haiku, max 6 turns |
| Hook invocations | 2 (no retry or workaround after the deny) |
| Control call (`Write` -> `control.txt`) | hook emitted nothing, file **created** |
| Sentinel call (`Write` -> `SUMI_GUARD_DENY_SENTINEL.txt`) | hook emitted deny, reason `RECORDING_NOT_VERIFIED`, file **not created** |
| Deny reason in Claude's stream | `SUMI Guard: required recording not confirmed.` present |
| Hook errors | 0 |
| Cost | about USD 0.005 per run |

This closes gate 2 of [docs/34](../docs/34-claude-pretooluse-response-prototype.md)
for this host and version only.

## Setup (isolated, nothing persistent changed)

- A fresh folder under `%TEMP%` held a throwaway hook and a settings file.
- The hook was loaded only for this run with `claude -p --settings <file>`.
  `~/.claude/settings.json`, project settings and existing hooks were not modified.
- Matcher: `Bash|PowerShell|Write|Edit`. Permission: `--allowedTools 'Write'`, so a
  blocked call can only come from the hook, not from a missing allow rule.
- The hook read the PreToolUse JSON from stdin. Only when `tool_input` contained
  `SUMI_GUARD_DENY_SENTINEL` did it call:

```powershell
$decision = Get-SumiGuardRecordingDecision -RequestedMode ENFORCE_RECORDING `
    -RouteAllowlisted $true -HookInputStatus VALID -AdapterResult $null
$wire = ConvertTo-SumiGuardClaudePreToolUseResponse -RecordingDecision $decision
[Console]::Out.Write($wire)   # exit 0
```

- Every invocation appended a metadata-only log line (tool name, matched, emitted,
  reason, exception type). No command text was logged.

The verdict required all of: the hook ran, no hook errors, the control file was
created, a deny was emitted, and the sentinel file was absent. Any missing piece
is reported as inconclusive, never as a pass.

## First attempt was inconclusive (PowerShell tool)

The first run asked for `New-Item -ItemType File -Path control.txt` through the
`PowerShell` tool with `--allowedTools 'PowerShell(New-Item:*)'`. The hook ran and
let it through, but Claude Code then denied the call itself:
`permission_denied`, `decision_reason_type: subcommandResults`,
"Command contains malformed syntax that cannot be parsed: pwsh exited with code 1".
The pwsh error text was unreadable (code page mismatch). Claude stopped before the
sentinel call, so nothing about SUMI Guard was measured.

This is a Claude Code permission-parser issue on this machine, independent of
SUMI Guard. It is worth a separate check because it may also affect ordinary
`PowerShell(...)` allow rules.

## Not shown by this measurement

- Behavior through the `PowerShell` or `Bash` tools (not reached, see above).
- Interactive Claude Code, other versions, Codex.
- Hook crash, timeout or malformed-output paths (these may fail open).
- Any real recording: the decision used no adapter result, so it was always DENY.
- Wiring into `hooks/Invoke-SumiGuardMonitorHook.ps1`. MONITOR is unchanged.

Gates 3 and 4 of docs/34 (Windows DPAPI/ACL on the operator machine, production
safety) remain open. Enforcement stays disabled.
