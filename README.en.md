# SUMI Guard

[![Windows PowerShell 5.1 CI](https://github.com/ponponpon888/sumi-guard/actions/workflows/windows-powershell-5.1-check.yml/badge.svg)](https://github.com/ponponpon888/sumi-guard/actions/workflows/windows-powershell-5.1-check.yml)

<img src="docs/assets/sumi-guard-social-preview.png" alt="SUMI Guard — Local-First AI Tool Audit" width="100%">

**A local-first audit prototype for Claude Code and Codex pre-tool events on Windows.**

[日本語](README.md) · [Changelog](CHANGELOG.md) · [Security](SECURITY.md) · [Threat model](THREAT_MODEL.md) · [Claude Code compatibility](docs/28-claude-code-hook-compatibility.md)

SUMI Guard records host-supplied pre-execution input, assessment output, and independent OS process observations as separate evidence types. Its MONITOR hook never denies execution. Metadata-only recording is the default, so command bodies are not stored unless explicitly enabled.

> SUMI Guard is an audit prototype, not antivirus or endpoint protection. A pre-tool event is not proof that a command ran, and `NO_DETECTION` does not mean safe or malware-free.

## What it does

- Accepts profile-specific `PreToolUse` input from Claude Code and Codex
- Assesses PowerShell source without executing it
- Separates execution-event metadata from assessment records
- Stores SHA-256 and required metadata by default, not the command body
- Uses Windows DPAPI CurrentUser and a restricted ACL when body capture is explicitly enabled
- Correlates application events with OS observations without overstating evidence strength

## Architecture

```mermaid
flowchart TD
    A["Claude Code / Codex"] -->|PreToolUse| B["SUMI Guard MONITOR"]
    B --> C["AssessmentStore"]
    B --> D["ExecutionStore"]
    B -. explicit opt-in .-> E["LocalStore / DPAPI"]
    F["OS process observation"] --> G["Evidence correlation"]
    D --> G
```

## Verified paths

| Host | Environment | Verified |
|---|---|---|
| Claude Code | 2.1.304 / Windows PowerShell 5.1 | Hook reachability, strict UTF-8 including Japanese and emoji, one execution record, one assessment record, no body container, no raw-command leak |
| Codex | Disposable child session on Windows | Real `PreToolUse`, ExecutionAdapter, LocalStore, independent OS observation, `INFERRED_MATCH` |
| GitHub Actions | Windows PowerShell 5.1 | Syntax, encoding, PSScriptAnalyzer, and DPAPI-independent synthetic tests |

The Claude Code live test ran on 2026-10-20 with project-local settings and temporary initialized stores. It did not use an operational store, a permanent hook, or global Claude settings.

## Safety gates before enforcement

The default MONITOR hook records and never blocks. The stricter
`ENFORCE_RECORDING` mode ("do not run what cannot be recorded", designed in
[docs/26](docs/26-enforce-recording-design.md), Japanese) stays disabled until
four gates are passed in order, each closed by a measurement record.

| Gate | What it checks | Status | Record |
|---|---|---|---|
| 1. Decision and response | Deny/allow from recording results, and the deny response sent to Claude Code (synthetic tests) | Done (CI) | [docs/33](docs/33-recording-enforcement-decision-stage.md), [docs/34](docs/34-claude-pretooluse-response-prototype.md) |
| 2. Host honours deny | A real Claude Code stops on the SUMI Guard deny and lets an unrelated call through (disposable session, fixed benign input) | Done for Claude Code 2.1.309, 2026-10-23. Codex not measured | [Measurement](measurements/2026-10-23-claude-pretooluse-deny-gate2.md) |
| 3. Encryption and permissions | DPAPI CurrentUser, ACLs, storage failures and event provenance on the operator's Windows machine (disposable stores) | Done, 31/31 cases, 2026-10-27 | [Measurement](measurements/2026-10-27-gate3-operator-check.md) |
| 4. Operational safety | Operator-only setting, kill switch, bounded lock wait, notices; then one route enabled and measured | Done for Claude Code 2.1.310, Bash route, 2026-10-28 | [docs/36](docs/36-gate4-enforcement-control.md), [docs/37](docs/37-gate4-enforcement-hook.md), [Measurement](measurements/2026-10-28-gate4-operator-check.md) |

All four gates are closed. Enforcement is still not registered in any permanent setting: enabling it for daily use is a separate operator decision, and `ENFORCEMENT_OFF` turns it back off. `hooks/Invoke-SumiGuardMonitorHook.ps1` stays MONITOR-only.

## Three-minute isolated demo

```powershell
git clone https://github.com/ponponpon888/sumi-guard.git
Set-Location .\sumi-guard

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Start-SumiGuardDemo.ps1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Show-SumiGuardDemo.ps1

# Explicit cleanup after inspection
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Clear-SumiGuardDemo.ps1 -ConfirmDemoRemoval
```

The demo uses only fixed benign input and writes under `.demo-data`, which is excluded from Git. Review [demo/README.md](demo/README.md) before running it.

## Security boundaries

- MONITOR is the default; the hook does not automatically deny or block execution.
- DPAPI CurrentUser and ACLs do not protect against the same Windows user, administrators, or a compromised user session.
- Polling-based OS observation may miss short-lived processes.
- Never put secrets, credentials, or real command bodies in public issues.

See [SECURITY.md](SECURITY.md), [THREAT_MODEL.md](THREAT_MODEL.md), and the detailed [Japanese README](README.md).

## Author

**Shingo Kumon**

- [GitHub](https://github.com/ponponpon888)
- [Web](https://www.shingokumon.com)
- [X](https://x.com/shingo_kumon)
- [Contact](https://www.shingokumon.com/contact)
