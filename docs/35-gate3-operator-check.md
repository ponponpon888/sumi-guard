# Gate 3: operator-machine DPAPI and ACL check (2026-10-27)

## Status: check prepared, not yet measured

Gate 3 of [docs/33](33-recording-enforcement-decision-stage.md) asks for
DPAPI CurrentUser, ACLs, body-storage failures and full event provenance to be
verified on the operator's Windows machine, using disposable stores. The
GitHub-hosted CI deliberately excludes every DPAPI-dependent test, because a
runner's user profile says nothing about the operator's. The newest measurement
records for those tests are from 2026-10-03; the LocalStore module changed on
10/08 and the execution adapter and its tests on 10/20, with no operator-machine
record since.

This change adds one runner and one new test script. Nothing is installed,
registered or enabled. MONITOR and the operational hook are unchanged.

## How to run

From the operator's own Windows PowerShell 5.1 window (not from inside Claude
Code or Codex), in a clean checkout of the commit to be measured:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Dev\sumi-guard\tools\Invoke-SumiGuardGate3OperatorCheck.ps1
```

It prints `verdict: ...` and writes
`%USERPROFILE%\Downloads\sumi-guard_gate3_result_<yyyyMMdd>.json`.

| Verdict | Meaning |
|---|---|
| `PASS_GATE3_OPERATOR_CHECKS` | All four test scripts passed on this machine, at the recorded commit |
| `FAIL_GATE3_OPERATOR_CHECKS` | At least one case failed; the file names the case |
| `INCONCLUSIVE_WORKTREE_NOT_CLEAN` | Uncommitted changes; the result would not correspond to a commit |
| `INCONCLUSIVE_NOT_WINDOWS_POWERSHELL_51` | Not run under Windows PowerShell 5.1 |
| `INCONCLUSIVE_NOT_A_GIT_CHECKOUT` / `INCONCLUSIVE_TEST_NOT_RUN` | No commit to attribute the result to / a test script was missing |

## What runs

| Test script | Gate 3 item |
|---|---|
| `Invoke-LocalStoreTests.ps1` | DPAPI round trip, store ACL, encryption failure without plaintext fallback, capacity, lock, retention |
| `Invoke-LocalStoreOperatorHardeningTests.ps1` (new) | See below |
| `Invoke-ExecutionAdapterIntegrationTests.ps1` | Body-storage failures with MONITOR continuing, execution id to body reference round trip (event provenance), plaintext non-disclosure |
| `Invoke-ReadOnlyCliTests.ps1` | Read-only access to the stores |

New cases, each independent and each in its own disposable store:

- `dpapi_blob_is_current_user_scope`: the stored ciphertext is a DPAPI blob
  without the `CRYPTPROTECT_LOCAL_MACHINE` flag.
- `dpapi_master_key_belongs_to_current_user`: the master key the blob names
  exists in the running user's own DPAPI key directory.
- `dpapi_entropy_is_bound`: the blob does not open with wrong or missing
  entropy, and does open with the module's entropy.
- `tampered_ciphertext_fails_closed`: one flipped byte gives
  `DECRYPTION_FAILED`, with no plaintext in the result.
- `body_file_acl_is_inherited_restriction`: a body file grants access only to
  the user and SYSTEM, inherited from the store.
- `widened_store_acl_is_refused`: after an `Everyone` read rule is added, the
  store is refused for initialize, save and read, and no body is written.
- `inherited_store_acl_is_refused`: re-enabling inheritance has the same effect.
- `existing_plain_directory_is_not_adopted`: an ordinary existing directory is
  not turned into a store, and its ACL is left as it was.

## Privacy of the result file

The runner keeps only case names, statuses, counts, exception types and fixed
assertion text. Exception text from other sources is dropped by the new test,
and the runner replaces the repository path, temp path, profile path, SID,
user name and computer name before writing. No body text, SID, master key id
or path is written. The file is meant to be pasted back for the measurement
record.

## What this does not show

- Another Windows user being unable to decrypt (needs a second account).
- Behaviour under a roaming profile, Credential Guard, or a domain-backed
  DPAPI key.
- Anything about live enforcement. Gate 4 (bounded retries, notifications,
  kill switch, production safety) is still open, and enforcement stays disabled.
