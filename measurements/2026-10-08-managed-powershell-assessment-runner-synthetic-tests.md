# 管理下 PowerShell 評価ランナー: 子プロセス捕捉の合成試験（厳格判定版）

## 対象

| 項目 | 値 |
|---|---|
| ファイル | `tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` |
| コミット | `10b826c` |
| SHA-256（実行直前） | `5D1EF06A1C1320A9322FC13B284C71E31340C6665F799C568837331C8CAE1CB7` |
| SHA-256（実行直後） | `5D1EF06A1C1320A9322FC13B284C71E31340C6665F799C568837331C8CAE1CB7`（直前と一致） |
| 作業ツリー（実行の前後） | 差分なし（`git status --porcelain` が空） |

## 試験の内容

無害な固定コードだけを渡した `powershell.exe -NoProfile -NonInteractive -EncodedCommand` の子プロセスを8ケース起動し、
各ケースについて次の6項目がすべて期待値と一致したときだけ PASS とする。期待値は、各ケースが確かめたい分岐からコードを読んで決めた。

- 状態（`expected_state`）
- 子の終了コード
- stdout が空かどうか / stderr が空かどうか
- diagnostic の stage と exception_type（diagnostic が無いケースは null）

| ケース | 確かめたい分岐 |
|---|---|
| normal_json | JSON 1件の正常経路 |
| invalid_json | `ConvertFrom-Json` の読取り失敗（ArgumentException） |
| empty_output | stdout が空（`IsNullOrWhiteSpace` → FormatException） |
| multiple_reports | JSON は読めるが報告が2件（`Count -ne 1` → FormatException） |
| nonzero_exit | 子の終了コード 7、出力は正常 |
| parse_exception | `force_parse` による強制失敗（FormatException） |
| post_snapshot_exception | 事後スナップショットの強制失敗（InvalidOperationException） |
| parallel_capture | stdout と stderr の両方の捕捉 |

## 実行

| 項目 | 値 |
|---|---|
| 起動元 | Claude Code のシェル（PowerShell 7 のツール）から、`System.Diagnostics.Process` で1回だけ起動 |
| コマンド | `powershell -NoProfile -ExecutionPolicy Bypass -File C:\Dev\sumi-guard\tests\Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1 -RunSyntheticTests` |
| 作業ディレクトリ | `C:\Users\kuron` |
| `-ConfirmReal` | 付けていない |
| Windows PowerShell | 5.1.26100.9444（同じ `powershell` を別に起動して `$PSVersionTable` で取得） |
| 開始 / 終了 | 2026-10-08T00:22:43+09:00 / 2026-10-08T00:22:47+09:00 |

## 結果

| 項目 | 結果 |
|---|---|
| 入口の終了コード | 0 |
| stderr | 0 バイト |
| `synthetic_test_count` | 8 |
| PASS | 8 / 8（全ケースで `mismatches` が空） |
| `synthetic_all_passed` | true |
| `target_start_count` | 0 |
| `real_confirmation_gate_open` | false |
| 起動した子プロセス | 無害な固定コードの `powershell.exe` 8回のみ。本物の対象・子 Codex・実フックは起動していない |
| 事後照合 | `force_post` のケースを除く7ケースで `POST_OK`（対象ファイルと `.demo-data` の SHA-256 が実行前と一致） |

## 生出力（stdout）

下のコードブロックは stdout を一字も変えずに入れたもの。改行は子の出力どおり CRLF のまま残している
（このリポジトリは `.gitattributes` の `* -text` で改行を変換しない）。

- stdout: 10,595 バイト、SHA-256 `6FAD6212AE74BD50920EDEFA33469DB86CCCB5E2E592FA274E85142BF8500755`

```text
IMMEDIATE case=normal_json exit=0 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=invalid_json exit=0 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=empty_output exit=0 stdout_nonempty=False stderr_nonempty=False
IMMEDIATE case=multiple_reports exit=0 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=nonzero_exit exit=7 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=parse_exception exit=0 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=post_snapshot_exception exit=0 stdout_nonempty=True stderr_nonempty=False
IMMEDIATE case=parallel_capture exit=0 stdout_nonempty=True stderr_nonempty=True
{
    "synthetic_test_count":  8,
    "synthetic_all_passed":  true,
    "target_start_count":  0,
    "real_confirmation_gate_open":  false,
    "results":  [
                    {
                        "case_name":  "normal_json",
                        "expected_state":  "PARSE_OK_POST_OK",
                        "actual_state":  "PARSE_OK_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  null,
                        "expected_diagnostic_type":  null,
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  null
                    },
                    {
                        "case_name":  "invalid_json",
                        "expected_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "actual_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  "parse",
                        "expected_diagnostic_type":  "System.ArgumentException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "parse",
                                           "exception_type":  "System.ArgumentException",
                                           "hresult":  "0x80070057"
                                       }
                    },
                    {
                        "case_name":  "empty_output",
                        "expected_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "actual_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  true,
                        "actual_stdout_empty":  true,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  "parse",
                        "expected_diagnostic_type":  "System.FormatException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "parse",
                                           "exception_type":  "System.FormatException",
                                           "hresult":  "0x80131537"
                                       }
                    },
                    {
                        "case_name":  "multiple_reports",
                        "expected_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "actual_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  "parse",
                        "expected_diagnostic_type":  "System.FormatException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "parse",
                                           "exception_type":  "System.FormatException",
                                           "hresult":  "0x80131537"
                                       }
                    },
                    {
                        "case_name":  "nonzero_exit",
                        "expected_state":  "EXIT_7_PARSE_OK_POST_OK",
                        "actual_state":  "EXIT_7_PARSE_OK_POST_OK",
                        "expected_exit_code":  7,
                        "actual_exit_code":  7,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  null,
                        "expected_diagnostic_type":  null,
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  null
                    },
                    {
                        "case_name":  "parse_exception",
                        "expected_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "actual_state":  "PARSE_SAFE_FAILURE_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  "parse",
                        "expected_diagnostic_type":  "System.FormatException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "parse",
                                           "exception_type":  "System.FormatException",
                                           "hresult":  "0x80131537"
                                       }
                    },
                    {
                        "case_name":  "post_snapshot_exception",
                        "expected_state":  "PARSE_OK_POST_SAFE_FAILURE",
                        "actual_state":  "PARSE_OK_POST_SAFE_FAILURE",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  true,
                        "actual_stderr_empty":  true,
                        "expected_diagnostic_stage":  "post_snapshot",
                        "expected_diagnostic_type":  "System.InvalidOperationException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "post_snapshot",
                                           "exception_type":  "System.InvalidOperationException",
                                           "hresult":  "0x80131509"
                                       }
                    },
                    {
                        "case_name":  "parallel_capture",
                        "expected_state":  "CAPTURE_BOTH_PARSE_SAFE_FAILURE_POST_OK",
                        "actual_state":  "CAPTURE_BOTH_PARSE_SAFE_FAILURE_POST_OK",
                        "expected_exit_code":  0,
                        "actual_exit_code":  0,
                        "expected_stdout_empty":  false,
                        "actual_stdout_empty":  false,
                        "expected_stderr_empty":  false,
                        "actual_stderr_empty":  false,
                        "expected_diagnostic_stage":  "parse",
                        "expected_diagnostic_type":  "System.ArgumentException",
                        "mismatches":  [

                                       ],
                        "result":  "PASS",
                        "immediate_summary_generated":  true,
                        "post_reconciliation_attempted":  true,
                        "diagnostic":  {
                                           "stage":  "parse",
                                           "exception_type":  "System.ArgumentException",
                                           "hresult":  "0x80070057"
                                       }
                    }
                ]
}
```

## 未確認事項

- 親を PowerShell 7（`pwsh`）で起動した場合は試していない。invalid_json と parallel_capture の `System.ArgumentException` は Windows PowerShell 5.1 の `ConvertFrom-Json` で確認したもの。
- 子プロセスの起動以外にネットワーク・保存の操作がないことはコードを読んで確認したもので、実行時の監視はしていない。
- 事後照合はこの試験自身の照合（対象ファイルと `.demo-data` の SHA-256）であり、別途の外部照合はしていない。
