# Gate 3: operator-machine DPAPI and ACL check (2026-10-27)

## Result

All 4 DPAPI-dependent test scripts passed on the operator's Windows machine,
31 of 31 cases, at commit `773e835` (PR #18). Gate 3 of
[docs/33](../docs/33-recording-enforcement-decision-stage.md) is closed for the
scope described in [docs/35](../docs/35-gate3-operator-check.md).

The runner's own verdict was `INCONCLUSIVE_WORKTREE_NOT_CLEAN`. See
"Why the runner said INCONCLUSIVE" below for why the result still corresponds
to the commit.

## Environment

| Item | Value |
|---|---|
| Run | 2026-10-27 20:35:06 to 20:35:44 JST (38 s) |
| Commit | `773e83521123ea8c2ab09e9e4d6a9cccff21717a` on `test/gate3-operator-check-20261027` |
| PowerShell | Windows PowerShell 5.1.26100.9711 (Desktop) |
| OS | Windows 10.0.26300 |
| Elevated | No (ordinary user token) |
| Run from inside an agent | No (`agent_environment_variables_present` empty) |
| Settings changed | None |

## Cases

| Test script | Cases | Result |
|---|---|---|
| `Invoke-LocalStoreTests.ps1` | 6: defaults, dpapi_round_trip_and_acl, encryption_failure_no_plaintext_fallback, capacity_boundaries, concurrent_capacity_lock, retention_and_deletion_scope | PASS 6/6 |
| `Invoke-LocalStoreOperatorHardeningTests.ps1` | 8: dpapi_blob_is_current_user_scope, dpapi_master_key_belongs_to_current_user, dpapi_entropy_is_bound, tampered_ciphertext_fails_closed, body_file_acl_is_inherited_restriction, widened_store_acl_is_refused, inherited_store_acl_is_refused, existing_plain_directory_is_not_adopted | PASS 8/8 |
| `Invoke-ExecutionAdapterIntegrationTests.ps1` | 12: stores_initialized, metadata_only_omits_command_body, metadata_only_event_failure_is_collection_failure, real_monitor_to_adapter_metadata_only, timed_out_child_is_reaped, execution_id_body_reference_round_trip, capacity_failure_monitor_continues, encryption_failure_monitor_continues, event_failure_after_body_save, unexpected_missing_reference, retention_preserves_event_and_classifies_body, plaintext_non_disclosure | PASS 12/12 |
| `Invoke-ReadOnlyCliTests.ps1` | 5: readonly_api_surface, normal_list_and_detail, distinct_empty_and_missing_states, access_failure_is_sanitized, read_only_and_no_plaintext | PASS 5/5 |

Every script reported its disposable test root removed.

The two DPAPI blob cases confirm the field offsets assumed in the new test
(flags at byte 40, master key GUID at byte 24): the blob carried no
`LOCAL_MACHINE` flag, and the master key it named was found in the running
user's own DPAPI key directory.

## Why the runner said INCONCLUSIVE

The checkout held 3 untracked files, left from work on 2026-10-09 that was
never committed:

- `demo/Invoke-SumiGuardManagedProcessEvidenceDemo.ps1`
- `measurements/2026-10-09-managed-process-evidence.md`
- `tests/Invoke-ManagedProcessEvidenceTests.ps1`

No tracked file references them, and none of the four test scripts loads them.
The SHA-256 of all 11 files the runner hashed matches commit `773e835` exactly:

| File | SHA-256 |
|---|---|
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psm1` | `eb591d08c38093033ee9d99f8bedb0626c9a5080fa3a458f779b97c26768bf3d` |
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psd1` | `e63d2334433599e190d9bd3549174d7f48aac3f84c7d2002c002811bccac12ce` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psm1` | `d18d40a944c880e0962e9346fb61e4909468cd5cf625105b4693d6b450114194` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.ReadOnly.psm1` | `08885ad00bd535311226cdea33176da78d7c63a852920f640a3100bb2c9b7bdd` |
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psm1` | `66c079c305a1f6b0d6f31b1877a40598048f0c04b629dd34f23d062b84e8fa07` |
| `hooks/Invoke-SumiGuardMonitorHook.ps1` | `4e001117ee819c09c6eb548290371746ec3ca08e09ed6b9639c9b06d177ac424` |
| `tools/Invoke-SumiGuardGate3OperatorCheck.ps1` | `2467168b9395bd55d691529e0e148b38e2ca48929dffd16b728c5b964ee13630` |
| `tests/Invoke-LocalStoreTests.ps1` | `35c3f1f0c4ac59aad102e54b52ce25ca8cb44d0716b4361476836ac284774ce3` |
| `tests/Invoke-LocalStoreOperatorHardeningTests.ps1` | `db582346a46de8e6acfafbb18a4816163373bcaf32a549ca291062a2d78c5190` |
| `tests/Invoke-ExecutionAdapterIntegrationTests.ps1` | `f59983e51b5bde763b88ea9f15c9a7987e329a0358be4236203298f5b5cdeec5` |
| `tests/Invoke-ReadOnlyCliTests.ps1` | `b86638469ab8daa48816f059719f8b440b4333897b8dad5bc24e9a2092becb6d` |

The LocalStore module, its manifest and its test have the same hashes as in the
2026-10-03 records, so those were not changed between the two measurements.

The 3 untracked files were left untouched. Whether to commit or discard that
10/09 work is a separate decision.

## Not shown by this measurement

- Another Windows user being unable to decrypt.
- Roaming profile, Credential Guard, or domain-backed DPAPI keys.
- Anything about live enforcement. Gate 4 (bounded retries, notifications,
  kill switch, production safety) remains open. Enforcement stays disabled;
  MONITOR and `hooks/Invoke-SumiGuardMonitorHook.ps1` are unchanged.
