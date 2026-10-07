# コマンド評価モジュール合成試験

## 実施範囲

2026-10-05に、`docs/23-suspicious-execution-warning-design.md`の第1段階として、
メモリ内評価モジュールと文字列合成試験だけを実装・実行した。

- 対象: 確認済みWindows PowerShell経路の初期コマンド文字列
- ルール: `SG-CMD-001`、`SG-CMD-002`、`SG-CMD-003`
- 状態: `DETECTED`、`NO_DETECTION`、`UNASSESSABLE`、`EVALUATION_FAILED`
- 非対象: フック接続、評価記録の保存、通知、遮断、隔離、削除、外部送信

入力はPowerShell ASTとして解析しただけで、コマンド実行、ドットソース、
`Invoke-Expression`、URLアクセス、外部プロセス起動、動的コード評価には渡していない。

## 実装

公開関数は`Invoke-SumiGuardCommandAssessment`である。本文とは別に
`InterpreterKind`と`InterpreterVerified`を必須で受け、
`WINDOWS_POWERSHELL`かつ確認済みの場合だけ本文を解析する。

返却値は次の固定情報だけを持つ。

- スキーマ、レコード、実行の各IDと評価時刻
- 評価状態と固定の評価理由コード
- ルールセット版
- ルールID、ルール版、重大度、固定理由コードからなるfindings
- `content_included=false`、`source_excerpt_included=false`
- `monitor_action=WARN_ONLY`、`automatic_deny=false`

コマンド本文、断片、URL、パス、変数名、秘密値、AST、例外メッセージ、`execution_status`は返さない。
重大度は操作の注意度であり、悪意や感染の確定ではない。

### SG-CMD-001

既知の取得コマンドと実行処理が、パイプ、同一変数、または同一の保存先を介して結び付く場合だけ、
`DOWNLOAD_TO_EXECUTION_FLOW`を検知する。ダウンロードだけ、または取得後のハッシュ確認だけでは
検知しない。

### SG-CMD-002

次の既知操作について、無効化方向を静的に確認できた場合だけ
`SECURITY_CONTROL_DISABLE_MUTATION`を検知する。

- Defenderの既知`Disable*`設定をtrueへ変更
- Firewallまたはログの`Enabled`をfalseへ変更
- Windows Event Logサービスの停止または無効化
- `auditpol`による監査無効化・クリア
- `wevtutil`によるログ無効化

参照コマンドと、同じ設定を有効化する操作は区別する。

### SG-CMD-003

次の既知の登録・変更操作を`PERSISTENCE_REGISTRATION_MUTATION`として検知する。

- Scheduled Taskの登録または`/create`
- Run/RunOnceキーへの追加・変更
- サービスの自動起動設定
- 静的に確認できるStartupフォルダーへの配置

一覧取得と削除は区別する。正当な管理用途でも構造条件に該当し得る。

## 評価不能との競合

確定したfindingと未解決の動的処理が同じ入力にある場合、確認済みの警告を失わないため
`DETECTED / PARTIAL_UNASSESSABLE`とする。確定findingがなく、動的解決、未対応構文、
未確認インタープリター、未検査EncodedCommandがある場合は`UNASSESSABLE`とする。
内部の予期しない障害は`EVALUATION_FAILED / RULE_ENGINE_ERROR`とする。

`NO_DETECTION`は、確認できた対応範囲で初期3ルールに一致しなかったという意味だけであり、
安全性を保証しない。

## 構文・文字コード

| 項目 | 結果 |
|---|---|
| Windows PowerShell | `5.1.26100.9444` |
| モジュール構文エラー | 0 |
| マニフェスト構文エラー | 0 |
| 合成試験構文エラー | 0 |
| モジュールUTF-8 BOM | PASS |
| マニフェストUTF-8 BOM | PASS |
| 合成試験UTF-8 BOM | PASS |
| StrictMode | version 2.0 |

## 合成試験結果

配置先`C:\Dev\sumi-guard`から新規合成試験を1回実行し、33件すべて合格した。

| 分類 | 件数 | 主な確認内容 | 結果 |
|---|---:|---|---|
| 静的な非実行経路 | 1 | 試験・モジュールに呼出し演算子、ネットワーク、外部起動、動的評価の実行経路なし | PASS |
| SG-CMD-001 | 3 | OutFile変数からの実行、パイプ実行、ダウンロードのみ | PASS |
| SG-CMD-002 | 7 | Defender、監査、ログ、大小文字、有効化、参照 | PASS |
| SG-CMD-003 | 7 | Scheduled Task、Runキー、自動サービス、一覧、削除、大小文字 | PASS |
| 状態・境界・非漏えい | 15 | コメント、引用文字列、経路未確認、構文エラー、動的・難読化、EncodedCommand、Bypass、混在、内部障害、出力非漏えい | PASS |
| 合計 | 33 | 4評価状態と固定出力 | PASS |

試験結果が明示した実行状態は次のとおりである。

- `command_inputs_executed=false`
- `network_access_performed=false`
- `external_processes_started_by_test_data=false`
- `dynamic_code_evaluation_performed=false`
- `execution_status_included=false`

ステージでの初回試験は、`NO_DETECTION`の空findings配列を結果生成関数の必須配列引数が拒否し、
3ケース目の後で終了した。新規モジュールの同引数へ`AllowEmptyCollection`を追加した。評価条件や
期待結果は変更していない。修正後はステージと配置先の双方で33件すべて合格した。

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psm1` | `9D53C732AED7EF028E28464B2DFA2B93CD04D7F5A9AF79C5DC4360F75A90E729` |
| `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psd1` | `7890D4AF6822B81A5584234CB0C4B84FD8EAEC7B961FB898D0F4CF223952A4AC` |
| `tests/Invoke-CommandAssessmentTests.ps1` | `F7DB7DD038115B9AC440B2E1CDA6CE06FAB69D98DB3ED5B1AC838996BB770527` |

## 不変性

実装前と試験後に、既存成果物と`.demo-data`のファイル集合、サイズ、更新日時、SHA-256を照合した。

| 対象 | 追加 | 変更 | 削除 |
|---|---:|---:|---:|
| 既存成果物 | 0 | 0 | 0 |
| `.demo-data` | 0 | 0 | 0 |

意図した追加は評価モジュール、マニフェスト、合成試験の3ファイルだけだった。本測定記録は、
この照合後に新規追加する。

## 制約と未対応事項

- PowerShell経路の確認は呼出し側が本文とは別に渡す。本文中の自己申告から推測しない。
- 第1段階の既知コマンド、既知別名、静的な引数・限定データフローだけを評価する。
- `EncodedCommand`はデコードせず、単独で危険判定しない。
- `ExecutionPolicy Bypass`単独では検知しない。
- 動的なコマンド名、動的な対象、未対応構文は安全側へ補完せず評価不能とする。
- 大量削除と重要設定変更は未実装である。
- PC全体、Codex外の実行、`write_stdin`の後続入力は監視しない。
- フック接続、評価保存、通知配信、表示CLI、遮断、隔離、削除は未実装である。
- 既存暗号化本文の復号や遡及評価は行っていない。
- 既存試験、実フック、Start、Clearは実行していない。

