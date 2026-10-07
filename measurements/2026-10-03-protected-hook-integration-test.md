# SUMI Guard 実フック・暗号化保存接続試験（2026-10-03）

## 結論

指定された無害な固定コマンド1件について、実際のCodex `PreToolUse` から
`SumiGuard.ExecutionAdapter` / `SumiGuard.LocalStore` へ接続し、実行前イベント、暗号化本文、
別イベントの実行結果、独立したOSプロセス観測を取得できた。フックに対象PIDがないため相関は
`INFERRED_MATCH` であり、`DIRECT_MATCH` ではない。

既存8件の合成試験は、ExecutionAdapterとLocalStoreを変更していないため再実行していない。
検証済み3スクリプトも変更せず、既存OS観測器を読み取り実行した。

## 条件

- 最終測定完了: 2026-10-03 17:08:19 JST
- PowerShell: Windows PowerShell 5.1.26100.9444
- Codex CLI: 0.160.0
- モード: `MONITOR`
- 入力: 指定された固定コマンド1件だけ
- コマンドSHA-256: `9771f35a0ab7af3153a9733f2c7c53f22ad0bb76d1082f7e7dfb8b6ceb03e7ac`
- ハッシュ範囲: JSON復号後の `tool_input.command` を無正規化でBOMなしUTF-8へ変換したバイト列
- 隔離: `%TEMP%` 配下の使い捨てプロジェクトと、その子Codexプロセスだけの `-c hooks...`
- trust: 当該子プロセスだけ `--dangerously-bypass-hook-trust` を使用し、永続登録なし
- 適用される `AGENTS.md`: `C:\`、`C:\Dev`、`C:\Dev\sumi-guard` に存在せず

## 結果

| 確認項目 | 結果 | 本文を含まない根拠 |
|---|---|---|
| 実行前イベント | 成功 | `ExecutionIntentRecorded` 1件、`RECORDS_FOUND` |
| 本文暗号化保存 | 成功 | `CAPTURED_ENCRYPTED`、本文参照 `AVAILABLE` |
| 明示復号 | 成功 | `BODY_DECRYPTED`、固定本文と一致 |
| 実行結果の別記録 | 成功 | `ExecutionOutcomeObserved` 1件、`SUCCEEDED` |
| CLI実行 | 成功 | 終了コード0、タイムアウトなし、実コマンドID 1件、開始・完了のライフサイクル行2件 |
| メタデータ整合 | 成功 | `execution_id`、本文SHA-256、本文参照、取得状態がPre/Post間で一致 |
| 失敗通知 | なし | フック失敗通知0件 |
| 平文非漏えい | 成功 | メタデータ、失敗通知、暗号化保存領域、要約結果に固定本文なし |
| 後片付け | 成功 | 一時プロジェクト残存0件、試験PID残存0件 |

CLI標準エラーは非空だったが、秘密情報を保存しない要件に従って内容を保持していない。終了コード、
フック、本文保存、固定出力、OS観測はいずれも成功しており、本試験の成否には影響しなかった。

## OS観測と相関

- ソース: `NativeProcessPolling`
- 収集開始: 子Codex実行前に確認
- 全候補: 5 PID
- フック実行記録由来PID: 205392、190396
- 既存Windows PowerShellイベント400によるフック補助分類PID: 190396、204004、205392、175088
- 重複除外後のフックPID: 4件
- フック除外後候補: 1件
- 実行前・結果時刻窓適用後候補: 1件
- 対象候補: PID 205084、親PID 200400、開始 2026-10-03 17:08:12.233 JST、`powershell.exe`
- 相関: `INFERRED_MATCH`

相関根拠は、同じ隔離子Codexルートの子孫であり、フック自身を除外した後、実行前イベントと結果イベント
の間に開始したPowerShell候補が1件だけ残ったことです。イベント400の本文は保存せず、新フック名が
含まれるかという真偽判定だけを使いました。

OSポーリング間隔の実測値は次のとおりです。

| 項目 | 値 |
|---|---:|
| 設定値 | 20 ms |
| 実測件数 | 167 |
| 実測平均 | 101.154 ms |
| 実測最小 | 22.665 ms |
| 実測最大 | 480.260 ms |

## 使用コードのSHA-256

| ファイル | SHA-256 |
|---|---|
| `kit/sumi-guard-protected-hook-test/sumi-guard-protected-hook.ps1` | `70e52bde3d527921cc5467d01b5d3eef619d1dbc2dad01e36e65701a9b0730eb` |
| `kit/sumi-guard-protected-hook-test/invoke-sumi-guard-protected-hook-test.ps1` | `bf0a8d0f3a7654a5e33acd868b94fcf3291610983e3df0b88895bb7b2cc87361` |
| `kit/sumi-guard-prototype/process-observer.ps1` | `5b4509a2829b1b3d0c5ac17f47350c4238fed40474acf48c11cca9839b36d227` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psm1` | `cb03e584a9bfb04ddf2bf9cf1e298267190710c98af838d72c3f0ef6ce19ddb9` |
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.psd1` | `d251675a0932a8d110ab24fb4ba599207d7896e88faa456a882bc3768350ee86` |
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psm1` | `eb591d08c38093033ee9d99f8bedb0626c9a5080fa3a458f779b97c26768bf3d` |
| `src/SumiGuard.LocalStore/SumiGuard.LocalStore.psd1` | `e63d2334433599e190d9bd3549174d7f48aac3f84c7d2002c002811bccac12ce` |
| Codex 0.160.0 native executable | `fdda5fa3cf3fb3d000b876720742857676293e4315e4b045fae6f8bd7e866d1d` |

試験直前と試験後で、新フックと最終ランナーの内容は変更していない。

## 既存3スクリプトの非変更確認

| ファイル | SHA-256 |
|---|---|
| `sumi-guard-hook.ps1` | `716009de6b2d7cf23e7cf8da227f5492b8a2c417da86b507306ee85d91ed51ec` |
| `process-observer.ps1` | `5b4509a2829b1b3d0c5ac17f47350c4238fed40474acf48c11cca9839b36d227` |
| `invoke-sumi-guard-prototype.ps1` | `f2510e810aa925a800c51f7666679c4644f25683e0cbf8d40eb568357340a9c2` |

3値は既存の最終対応確認レポートと一致する。

## 未達・制約

- フックイベントに対象PIDがないため、相関は `DIRECT_MATCH` ではない。
- OSポーリングは短命プロセスを取り逃す可能性がある。
- 実フック接続の検証範囲は固定コマンド1件で、通常の開発入力や一般的な完全性は未検証。
- イベント保存と本文保存は単一トランザクションではなく、部分成功は既存の状態分類に依存する。
- DPAPI CurrentUserとACLは、同じユーザー権限の別プロセスに対する保護境界ではない。
- CLI標準エラーが非空だった理由は、内容を保存しなかったため未特定。
