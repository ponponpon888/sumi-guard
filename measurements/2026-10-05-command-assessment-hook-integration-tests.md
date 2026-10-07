# CommandAssessment隔離フック接続試験

## 実施範囲

2026-10-05に、`docs/23-suspicious-execution-warning-design.md`と既存の保護ストレージ用
試作フックを基準として、合成`PreToolUse`入力からメモリ内CommandAssessmentまでの接続を
新規ファイルだけで試作・検証した。

- 実Codex起動、実フック登録、常設差し替えは行っていない。
- 実行記録または評価記録の保存、通知、遮断、隔離、削除、外部送信は行っていない。
- 疑わしいコマンドは合成JSON内の文字列としてだけ渡し、実行していない。
- 既存フック、評価モジュール、ReadOnly版、`.demo-data`は変更していない。

## インタープリター確認

現行の実測済みフック入力だけでは、対象コマンドがWindows PowerShellで実行されることを
`PreToolUse`時点で確認できない。

- 実測された`tool_input`の対象プロパティは`command`であり、本文外の`shell`は確認されていない。
- `tool_name=Bash`は対象ツールの識別にだけ使い、PowerShellの証拠にはしない。
- 既存の隔離ランチャーは子プロセス環境の`SHELL`へWindows PowerShell 5.1本体のパスを設定し、
  プロンプトでも`powershell`を要求しているが、個々のPreToolUse入力に結び付いた信頼済み情報ではない。
- `command_windows`がPowerShellでフックを起動することは、フック自身の実行言語の証拠であり、
  対象コマンドの実行言語の証拠ではない。
- 既存測定のOSプロセス観測は実行後の証拠であり、保存前評価の事前条件には使えない。

したがって、現行形では`InterpreterVerified=false`とし、評価結果は
`UNASSESSABLE / UNSUPPORTED_LANGUAGE`になる。検知を通すための固定trueは設けていない。

試作用アダプターは、将来ホストが次の両方を本文外から提供できる場合だけ確認済みとする接続面を持つ。

1. 信頼済み起動設定から渡された、実在しreparse pointではない標準Windows PowerShell 5.1本体の正規パス
2. ホストが`tool_input.shell`として渡すPowerShell識別値

この二重条件は合成入力でのみ確認した。現行の実フック入力には2番目がないため、実接続可能とは
判定していない。将来の実装では、ホスト提供項目の仕様・真正性と、起動設定からアダプター引数までの
信頼境界を別途確定する必要がある。

## 接続方式

新規`SumiGuard.IsolatedHookAssessmentAdapter`は次の順序で処理する。

1. JSONを解析し、`PreToolUse`、`Bash`、識別子、`tool_input`の形を検証する。
2. 既存フックと同じく、`session_id|turn_id|tool_use_id`のBOMなしUTF-8 SHA-256先頭32桁を
   `execution_id`とする。
3. 対象本文とは別に渡された起動実行ファイルとホストの`shell`項目を照合する。
4. 確認できた場合だけ、保存前のコマンド文字列を既存CommandAssessmentへメモリ内で渡す。
5. 評価結果を実行状態とは別の参照引数へ返す。

アダプターは成功パイプラインへ出力しない。合成試験は全呼出しでパイプライン出力0件を検証した。
将来のフックラッパーは参照引数の評価結果を明示的に受け取り、Codexのフック制御用stdoutへ
警告データを流さない必要がある。このラッパー、保存先、通知経路は今回実装していない。

返却エンベロープには`execution_status`を含めず、評価状態との分離を維持する。本文、本文断片、
URL、パス、秘密値、AST、例外メッセージも返さない。

## 構文・文字コード

| 項目 | 結果 |
|---|---|
| Windows PowerShell | `5.1.26100.9444` |
| アダプター構文エラー | 0 |
| マニフェスト構文エラー | 0 |
| 統合試験構文エラー | 0 |
| 新規3ファイルUTF-8 BOM | PASS |
| StrictMode | version 2.0 |

## 統合試験結果

Tempの隔離作業域と配置先`C:\Dev\sumi-guard`で、Windows PowerShell 5.1により
新規統合試験を実行した。修正後は両方で9件すべて合格し、配置先試験の終了コードは0だった。

| ケース | 確認内容 | 結果 |
|---|---|---|
| `CURRENT_BASH_SHAPE_IS_UNVERIFIED` | `Bash`と本文だけでは未確認、`UNASSESSABLE` | PASS |
| `TRUSTED_EVIDENCE_DETECTS_KNOWN_RULE` | 二重の合成信頼情報から`SG-CMD-002`を検知 | PASS |
| `TRUSTED_EVIDENCE_NORMAL_INPUT` | 対応範囲内の正常例が`NO_DETECTION` | PASS |
| `UNVERIFIED_INTERPRETER_IS_UNASSESSABLE` | 非PowerShell指定を未確認として扱う | PASS |
| `MISSING_COMMAND_IS_CONTENT_UNAVAILABLE` | 本文欠落を`CONTENT_UNAVAILABLE`として区別 | PASS |
| `INVALID_JSON_IS_REJECTED` | 不正JSONを固定状態で拒否 | PASS |
| `EVALUATION_FAILURE_IS_DISTINCT` | 内部評価失敗を`EVALUATION_FAILED`として区別 | PASS |
| `RESULT_OMITS_SENSITIVE_INPUT` | 本文・秘密値・URL・パス・例外メッセージを返さない | PASS |
| `EXECUTION_ID_MATCHES_EXISTING_HOOK_RULE` | 既存フックと同じID規則、実行状態と分離 | PASS |

試験結果が明示した非実行・非保存状態は次のとおりである。

- `hook_control_stdout_emitted=false`
- `command_inputs_executed=false`
- `network_access_performed=false`
- `external_processes_started_by_test_data=false`
- `dynamic_code_evaluation_performed=false`
- `records_saved=false`
- `notifications_sent=false`

隔離作業域での初回試験は9件中7件合格だった。新規コード内で、nullの`execution_id`が
文字列型引数により空文字へ変換される点と、入れ子で読み込まれた評価モジュールを試験が通常の
可視範囲だけで検索する点を修正した。期待結果、検知条件、インタープリター確認条件は緩和していない。

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `kit/sumi-guard-command-assessment-hook-test/SumiGuard.IsolatedHookAssessmentAdapter.psm1` | `2F9486AE57E8BC12F7447D9375263E1AE87943557C8194E8C8C39E3E4EA759A2` |
| `kit/sumi-guard-command-assessment-hook-test/SumiGuard.IsolatedHookAssessmentAdapter.psd1` | `F7D0AD792B1F2A7E9A796E6B0AB21330E03CB59C19A6A92ED9C46231754B377E` |
| `tests/Invoke-CommandAssessmentHookIntegrationTests.ps1` | `E6B1D369EDC9DAF29835841445DA44A138F830074D0D05A8D7A0EF62DD78616D` |
| 参照: `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psm1` | `9D53C732AED7EF028E28464B2DFA2B93CD04D7F5A9AF79C5DC4360F75A90E729` |
| 参照: `docs/23-suspicious-execution-warning-design.md` | `C3C73A1B6C90D7460D4548EB893A43C929D8F4D92BFEF2418DD7DE0B1E1AD835` |
| 参照: `kit/sumi-guard-protected-hook-test/sumi-guard-protected-hook.ps1` | `70E52BDE3D527921CC5467D01B5D3EEF619D1DBC2DAD01E36E65701A9B0730EB` |

## 不変性

開始時スナップショットと新規3ファイル配置・統合試験後を、ファイル集合、サイズ、更新日時、
SHA-256で照合した。

| 対象 | 追加 | 変更 | 削除 |
|---|---:|---:|---:|
| 既存成果物 | 0 | 0 | 0 |
| `.demo-data` | 0 | 0 | 0 |

意図した追加はアダプター、マニフェスト、統合試験の3ファイルだけだった。本測定記録は、
この照合後に4件目の新規ファイルとして追加する。

## 未接続の範囲

- 実Codexが提供する、対象インタープリターを事前確認できる信頼済み項目は未確定である。
- 現行入力に`shell`がないため、実フックから検知状態へ進む接続は成立していない。
- 既存フックへの組込み、差し替え、登録、評価結果の永続化は未実装である。
- Codexフック制御stdoutと評価結果を取り扱う常設ラッパーは未実装である。
- PostToolUse、実行結果、通知、表示、遮断、隔離、削除、遡及評価は未接続である。
- PC全体またはCodex外の実行を監視するものではない。

