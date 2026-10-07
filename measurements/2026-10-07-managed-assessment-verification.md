# 管理下評価照合契約の合成記録

## 対応範囲

新規 `SumiGuard.ManagedAssessmentVerification` は、既存管理下ランナーが既に確認するWindows PowerShell 5.1の実体・版・起動設定を再検証しない。ランナーが渡す証拠について、評価本文と起動本文、評価IDと計画ID、固定実行ファイルと観測実行ファイル、版、起動設定の整合性をメモリ内で検査する。

任意の呼出し元が渡す `InterpreterVerified=true`、自己申告、または合成JSONの真正性を証明するものではない。信頼済みホスト証拠をどの経路で受け渡すかは、次段階の接続対象である。

返却値には本文、本文断片、パス、秘密値、AST、例外Messageを含めない。評価入力状態、実行状態、保存状態は独立し、実プロセス確認は子起動前には `NOT_ATTEMPTED / NOT_STARTED` とする。保存状態は常に `NOT_ATTEMPTED` であり、既存Storeの `SYNTHETIC_TEST` や `MANAGED_EXECUTION` を偽装しない。

## 構文・試験

| 項目 | 結果 |
|---|---|
| 新規モジュール・マニフェスト・試験のUTF-8 BOM | PASS |
| Windows PowerShell 5.1構文エラー | 0 |
| 合成試験 | 12 / 12 PASS |
| 子Codex起動 | 0 |
| 入力コマンド実行 | 0 |
| ネットワークアクセス | 0 |

確認した条件は、正常一致、本文不一致、execution ID不一致、実行ファイル不一致、版不一致、未対応版、起動設定不一致、証拠欠落、自己申告だけの入力、起動計画と実行後確認の分離、実行後ID不一致、結果の非漏えいである。

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.ManagedAssessmentVerification/SumiGuard.ManagedAssessmentVerification.psm1` | `CE1D5A67F457482FDC202CBCDD9522AC239871B6133FF1DDE5782A1A87C3A2E4` |
| `src/SumiGuard.ManagedAssessmentVerification/SumiGuard.ManagedAssessmentVerification.psd1` | `8403A14E7C65BCDBE5674C87DCCCE604597798EF4D2027A38F03D35CD8B5C480` |
| `tests/Invoke-ManagedAssessmentVerificationTests.ps1` | `BBBBBC0961AEF7BCBAC8307615C8C58AE874DFBA75B2703A959E96B13CF6C25E` |

既存ランナー、評価器、AssessmentStore、フック、`.demo-data`への接続・変更は行っていない。
