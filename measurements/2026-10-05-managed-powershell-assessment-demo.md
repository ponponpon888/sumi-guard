# 管理下Windows PowerShell評価デモ

## 実施範囲

2026-10-05に、ランナー自身が実行先と実行本文を固定する管理下経路について、CommandAssessmentの
評価対象と実際の起動対象を一致させる小規模デモを追加・検証した。

- 実行可能な本文は、ランナー内に固定した無害な`Write-Output`コマンド1件だけである。
- 外部入力は`-RunFixedCommand`スイッチだけであり、コマンド、実行ファイル、引数、タイムアウトを
  利用者から受け取らない。
- 実Codex、既存フック、常設登録、保存、通知、一般コマンドの遮断には接続していない。
- 既存コード、既存フック、ReadOnly版、`.demo-data`は変更していない。

## 実行先を確認した根拠

実行先は次の標準Windows PowerShell 5.1本体の絶対パスへ固定した。

`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`

ランナーは、子プロセスを開始する前に次をすべて確認する。

1. 固定先が実在するファイルであり、reparse pointではない。
2. ランナー自身の実プロセスパスが固定先と一致する。
3. `$PSHOME`が固定先のディレクトリと一致する。
4. `PSEdition=Desktop`、エンジン版が5.1である。
5. 実際に使用する`ProcessStartInfo`の`FileName`と引数が固定設定に一致する。
6. `UseShellExecute=false`、stdout/stderrのリダイレクト、非表示起動が設定されている。

確認結果は次のとおりだった。

| 項目 | 結果 |
|---|---|
| エンジン版 | `5.1.26100.9444` |
| PSEdition | `Desktop` |
| 実プロセスパス | 標準絶対パスと一致 |
| 実行ファイル版 | `10.0.26100.8972 (WinBuild.160101.0800)` |
| 実行ファイルSHA-256 | `8BB6FA8C283B4D92120B1EF249A9B311B0F804D4CABBE9981159976C8BE76A5E` |
| 起動引数 | `-Version 5.1 -NoLogo -NoProfile -NonInteractive -Command`と固定内部本文 |
| 起動設定照合 | PASS |

`InterpreterVerified=true`は、このランナーが上記条件を満たした呼出しにだけ設定する。フックJSONの
`shell`自己申告、`tool_name=Bash`、環境変数`SHELL`は根拠にしていない。

## 評価と実行の対応

ランナーは同じ固定設定オブジェクトから、評価用本文と起動用本文を取得し、完全一致を確認する。
実行前の条件は次のすべてである。

- 管理下インタープリター確認が成功
- 評価本文と起動本文が完全一致
- 評価状態が`NO_DETECTION`
- 評価理由がなし
- findingが0件
- `-RunFixedCommand`が明示指定済み

`NO_DETECTION`は安全保証ではなく、この固定デモ本文が現行ルールに該当しなかったという意味だけである。
条件が1件でも異なれば子プロセスを開始しない。評価状態と実行状態は別フィールドで報告する。

固定子プロセスのstdoutとstderrは、両方の`ReadToEndAsync`を開始してから待機する。出力本文は返さず、
stdoutの固定期待値一致Boolean、終了コード、stderr非空Boolean、タイムアウトBooleanだけを返す。
タイムアウト時と例外時の`finally`では、そのランナーが生成した`Process`だけを終了・回収する。

## 構文・合成試験

| 項目 | 結果 |
|---|---|
| Windows PowerShell | `5.1.26100.9444` |
| ランナー構文エラー | 0 |
| 合成試験構文エラー | 0 |
| 新規2ファイルUTF-8 BOM | PASS |
| StrictMode | version 2.0 |
| 配置先合成試験 | 10/10 PASS |
| 合成試験中の管理下子プロセス起動 | 0回 |

| ケース | 主な確認 | 結果 |
|---|---|---|
| `RUNNER_ACCEPTS_ONLY_RUN_SWITCH` | 任意コマンド・実行先の外部引数なし | PASS |
| `MANAGED_HOST_AND_LAUNCH_ARE_VERIFIED` | 実体、版、実プロセス、起動設定 | PASS |
| `FIXED_COMMAND_IS_ASSESSED_WITHOUT_EXECUTION` | 既定では評価のみ、起動0回 | PASS |
| `EXPECTED_STATE_GATE_IS_EXACT` | 明示スイッチと固定期待状態だけを許可 | PASS |
| `SUSPICIOUS_SYNTHETIC_INPUT_IS_ASSESSMENT_ONLY` | 合成検知例は評価器だけへ渡し実行しない | PASS |
| `UNASSESSABLE_INPUT_CANNOT_START` | 評価不能時は起動しない | PASS |
| `EVALUATION_FAILURE_CANNOT_START` | 評価失敗時は起動しない | PASS |
| `COMMAND_MISMATCH_CANNOT_START` | 本文不一致時は起動しない | PASS |
| `PARALLEL_CAPTURE_AND_TIMEOUT_CLEANUP_EXIST` | 並行読取り開始と所有子プロセス終了処理 | PASS |
| `REPORT_OMITS_COMMAND_AND_RAW_STREAMS` | 本文、生stdout/stderr、例外メッセージを返さない | PASS |

Temp隔離作業域の初回試験は8/10、2回目は9/10だった。新規コード内だけで、既存評価APIが
理由なしを空文字として返す仕様への照合と、PowerShell 5.1の関数AST・null配列化の扱いを修正した。
`NO_DETECTION`、理由なし、finding 0件という実行ゲート自体は緩和していない。最終的にTempと
配置先の双方で10/10合格した。

## 固定コマンド実行結果

合成試験合格後、標準Windows PowerShell 5.1本体の`-File`でランナーを呼び、
`-RunFixedCommand`を明示して1回だけ実行した。

| 項目 | 結果 |
|---|---|
| ランナープロセス終了コード | 0 |
| `interpreter_verified` | `true` |
| 評価状態 | `NO_DETECTION` |
| 評価finding | 0件 |
| 評価対象・起動対象一致 | `true` |
| 子プロセス起動回数 | 1 |
| 実行状態 | `SUCCEEDED` |
| stdout固定期待値一致 | `true` |
| 子プロセス終了コード | 0 |
| stderr非空 | `false` |
| タイムアウト | `false` |
| 生stdout/stderrの返却 | なし |

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `demo/Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1` | `97533BE416F83A10F66273FD3097CF1710D0EEB8CF1D50D0C9909B6B5F97440B` |
| `tests/Invoke-ManagedPowerShellAssessmentDemoTests.ps1` | `797DBDA5F752E47F60395EC19CDC235B2EEC8F6433113D7823009F0C9114E8DA` |
| 参照: `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psm1` | `9D53C732AED7EF028E28464B2DFA2B93CD04D7F5A9AF79C5DC4360F75A90E729` |

## 不変性

開始時スナップショットと、配置・合成試験・固定コマンド実行後を、ファイル集合、サイズ、更新日時、
SHA-256で照合した。

| 対象 | 追加 | 変更 | 削除 |
|---|---:|---:|---:|
| 既存成果物 | 0 | 0 | 0 |
| `.demo-data` | 0 | 0 | 0 |

意図した追加はランナーと合成試験の2ファイルだけだった。本測定記録は、この照合後に3件目の
新規ファイルとして追加する。

## 対象外

- Codex実フックのインタープリター確認問題は解決していない。
- PC全体、Codex、他のシェル、利用者の一般コマンドは監視していない。
- 既存フックへの組込み、常設登録、評価結果保存、通知、遮断は行っていない。
- 疑わしい合成入力、評価不能入力、評価失敗入力、不一致入力は実行していない。
- 外部通信、本文復号、設定変更、既存試験は行っていない。

