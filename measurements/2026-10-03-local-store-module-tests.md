# SUMI Guard ローカル保存モジュール単体試験（2026-10-03）

## 対象

- PowerShell: Windows PowerShell 5.1.26100.9444
- モジュール: `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psm1`
- モジュールSHA-256: `eb591d08c38093033ee9d99f8bedb0626c9a5080fa3a458f779b97c26768bf3d`
- マニフェストSHA-256: `e63d2334433599e190d9bd3549174d7f48aac3f84c7d2002c002811bccac12ce`
- 試験スクリプトSHA-256: `35c3f1f0c4ac59aad102e54b52ce25ca8cb44d0716b4361476836ac284774ce3`
- 最終試験完了: 2026-10-03 16:30 JST

試験は `%TEMP%` 配下の固有ディレクトリだけを使用し、終了時に削除した。架空本文そのものは
試験結果へ保存していない。既存のCodex実行試験は再実行していない。

## 結果

全6項目が合格した。

| 試験 | 結果 | 根拠 |
|---|---|---|
| 初期値 | 合格 | 1件1,048,576バイト、合計262,144,000バイト、保持30日 |
| DPAPI往復とACL | 合格 | 保存 `SAVED`、復号 `DECRYPTED`、架空本文一致、保存先バイト列に平文なし、ACLは対象ユーザーとSYSTEMのみ |
| 暗号化失敗 | 合格 | `ENCRYPTION_FAILED`、本文ファイル数不変、一時ファイル0、失敗結果と保存先バイト列に平文なし |
| 容量境界 | 合格 | 1件境界と暗号化コンテナ合計の正確な境界は保存、超過は `ITEM_LIMIT_EXCEEDED` / `TOTAL_LIMIT_EXCEEDED` |
| 同時書き込み | 合格 | 2プロセス相当の同時要求のうち1件だけ保存、1件を `TOTAL_LIMIT_EXCEEDED`、確定ファイル1件 |
| 保持と削除範囲 | 合格 | 31日前の管理本文1件だけ削除。新規本文、管理外ファイル、保存先外ファイルは保持。再帰削除なし |

## コード非変更確認

検証済み3スクリプトは変更しておらず、SHA-256は最終対応確認レポートと一致した。

| ファイル | SHA-256 |
|---|---|
| `sumi-guard-hook.ps1` | `716009de6b2d7cf23e7cf8da227f5492b8a2c417da86b507306ee85d91ed51ec` |
| `process-observer.ps1` | `5b4509a2829b1b3d0c5ac17f47350c4238fed40474acf48c11cca9839b36d227` |
| `invoke-sumi-guard-prototype.ps1` | `f2510e810aa925a800c51f7666679c4644f25683e0cbf8d40eb568357340a9c2` |
