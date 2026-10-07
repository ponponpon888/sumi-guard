# SUMI Guard 実行記録・LocalStore接続統合試験（2026-10-03）

## 対象と条件

- 最終試験完了: 2026-10-03 16:52 JST
- PowerShell: Windows PowerShell 5.1.26100.9444
- 入力: 固定の架空本文から作る合成実行前イベントだけ
- 保存場所: `%TEMP%` 配下の試験ごとの固有ディレクトリ
- 適用される `AGENTS.md`: `C:\`、`C:\Dev`、`C:\Dev\sumi-guard` に存在せず

既存Codex試験、検証済み3スクリプト、実際の開発コマンドは実行していない。恒久フック、常駐処理、
監査設定は変更していない。試験終了時に専用一時ディレクトリを削除し、同名の残存は0件だった。
架空本文そのもの、実行ID、本文参照はこのレポートへ保存していない。

## 最終試験結果

最終コードに対する8項目はすべて合格した。

| 試験 | 結果 | 本文を含まない根拠 |
|---|---|---|
| 保存領域初期化 | 合格 | LocalStoreと実行メタデータ領域を作成し、実行領域ACL検査に合格 |
| `execution_id` 往復 | 合格 | `EVENT_AND_BODY_SAVED`、参照 `AVAILABLE`、明示復号だけが元の架空本文と一致 |
| 容量超過 | 合格 | `ITEM_LIMIT_EXCEEDED`、`HASH_ONLY`、`COLLECTION_FAILED`、MONITOR継続 |
| 暗号化失敗 | 合格 | `ENCRYPTION_FAILED`、`HASH_ONLY`、`COLLECTION_FAILED`、MONITOR継続 |
| 本文成功後のイベント失敗 | 合格 | `EVENT_SAVE_FAILED_BODY_ORPHANED`、主イベント0件、失敗通知は `ORPHANED_BODY` |
| 予期しない参照切れ | 合格 | 一覧 `REFERENCE_MISSING`、明示読出し `BODY_REFERENCE_MISSING` |
| 保持期限清掃 | 合格 | イベント保持、本文 `DELETED_BY_RETENTION`、取得失敗とは別状態 |
| 平文非漏えい | 合格 | 通常結果、失敗結果、メタデータ、失敗通知、暗号化保存領域に架空本文なし |

全ケースで `automatic_deny=false` を維持した。暗号化本文を返したのは明示読出しAPIの試験呼び出しだけで、
通常一覧と保存・失敗結果は本文を返さなかった。

## 最終コードSHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psm1` | `cb03e584a9bfb04ddf2bf9cf1e298267190710c98af838d72c3f0ef6ce19ddb9` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psd1` | `d251675a0932a8d110ab24fb4ba599207d7896e88faa456a882bc3768350ee86` |
| `tests/Invoke-ExecutionAdapterIntegrationTests.ps1` | `e1653a99ed9a950c4729f1d17d7e32e856d03f9d57f805fc606e230efe69aac9` |

統合先であるLocalStoreの対応ハッシュは次のとおり。

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psm1` | `eb591d08c38093033ee9d99f8bedb0626c9a5080fa3a458f779b97c26768bf3d` |
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psd1` | `e63d2334433599e190d9bd3549174d7f48aac3f84c7d2002c002811bccac12ce` |

## 既存3スクリプトの非変更確認

| ファイル | SHA-256 |
|---|---|
| `sumi-guard-hook.ps1` | `716009de6b2d7cf23e7cf8da227f5492b8a2c417da86b507306ee85d91ed51ec` |
| `process-observer.ps1` | `5b4509a2829b1b3d0c5ac17f47350c4238fed40474acf48c11cca9839b36d227` |
| `invoke-sumi-guard-prototype.ps1` | `f2510e810aa925a800c51f7666679c4644f25683e0cbf8d40eb568357340a9c2` |

3値は既存の最終対応確認レポートと一致する。
