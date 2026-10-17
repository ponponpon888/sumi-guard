# 実フック入力のインタープリター確認経路

## 結論

現行のCodex `PreToolUse` 実フック入力からは、対象コマンドを実際に解釈するシェルまたは実行ファイルを、本文外の信頼できる情報として確認できない。したがって現行実フックは `InterpreterKind=UNKNOWN`、`InterpreterVerified=false` を維持し、評価結果は `UNASSESSABLE / UNSUPPORTED_LANGUAGE` とする。

`tool_name=Bash`、フック自身を起動する `command_windows`、コマンド本文中の `powershell` 文字列、または利用者の「PowerShellとして評価してほしい」という宣言は、対象インタープリターの証明に用いない。

実用化へ進む推奨経路は、既存の管理下Windows PowerShellランナーを基礎にした明示的な管理下実行である。Codex実フックの対象言語確認を解決済みとは扱わない。

## 実装状況（2026-10-17）

本書の「次の最小実装対象」4項目は、いずれも実装済みである。

| 項目 | 実体 | 試験 | 測定記録 |
|---|---|---|---|
| 1. 本文を含まない評価入力エンベロープへ確認結果を渡す | `demo/Invoke-SumiGuardManagedAssessmentVerificationDemo.ps1` | `tests/Invoke-ManagedAssessmentVerificationConnectionTests.ps1`（20判定） | `measurements/2026-10-07-managed-assessment-verification-connection.md` |
| 2. 本文・実行ファイル・版・起動設定・execution ID の一致を確認する純粋関数 | `src/SumiGuard.ManagedAssessmentVerification/` の `Test-SumiGuardManagedAssessmentEvidence` | `tests/Invoke-ManagedAssessmentVerificationTests.ps1`（12判定） | `measurements/2026-10-07-managed-assessment-verification.md` |
| 3. 不一致・欠落・内側解釈不明を `InterpreterVerified=false` と固定の評価不能状態にする | 同上（`COMMAND_MISMATCH`、`ID_MISMATCH`、`EXECUTABLE_MISMATCH`、`VERSION_MISMATCH`、`CONFIGURATION_MISMATCH`、`MISSING_EVIDENCE`） | 同上 | 同上 |
| 4. この経路でのみ評価ストアと日本語警告表示へ接続する | `demo/Invoke-SumiGuardManagedAssessmentStoreDemo.ps1`、`tools/Show-SumiGuardAssessments.ps1`（`MANAGED_EXECUTION` を「管理下実行の評価」と表示） | `tests/Invoke-ManagedAssessmentStoreDemoTests.ps1`（4判定） | `measurements/2026-10-05-managed-assessment-store-demo.md` |

実フックへの保存・通知・遮断には接続していない。本書の結論どおり、実フック入力は
`InterpreterKind=UNKNOWN` / `InterpreterVerified=false` のままである。
docs/23 段階5の運用フック（`hooks/Invoke-SumiGuardMonitorHook.ps1`）も、信頼経路の宣言が
無ければ `UNASSESSABLE / UNSUPPORTED_LANGUAGE` を返す。

### 意図して使われていないパラメーター

`Test-SumiGuardManagedAssessmentEvidence` の `$CallerInterpreterVerified` は、受け取ったうえで
**一度も読まない**。本書の信頼境界が「利用者または上位層による言語宣言は根拠にできない」と
しているため、宣言を渡しても結果が変わらないことを示すために存在する。
`tests/Invoke-ManagedAssessmentVerificationTests.ps1` の `SELF_DECLARATION_NOT_TRUSTED` が
`-CallerInterpreterVerified $true` を渡し、それでも `interpreter_verified` が false のままで
あることを確認している。

PSScriptAnalyzer はこれを `PSReviewUnusedParameter` として指摘するが、未使用であること自体が
仕様である。削除すると「宣言が無視されること」を試験できなくなるため、コード側に理由を
書いた `SuppressMessageAttribute` を付けて残した。

## 調査対象と根拠

| 根拠 | 確認内容 | 結論 |
|---|---|---|
| ローカルCodex配布物 | `C:\Users\kuron\AppData\Roaming\npm\node_modules\@openai\codex\package.json` | `@openai/codex` は `0.160.0`。配布物にPreToolUse入力の対象シェルを証明する公開型定義は確認できなかった。 |
| 公式フック仕様 | [OpenAI Hooks documentation](https://learn.chatgpt.com/docs/hooks) | PreToolUseは `tool_name` とツール固有の `tool_input` を渡す。`Bash` はツールパス／matcherであり、対象シェルを示すフィールドではない。 |
| 評価器 | `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psm1` の `Invoke-SumiGuardCommandAssessment` | `WINDOWS_POWERSHELL` かつ `InterpreterVerified=true` のときだけAST評価へ進む。それ以外は `UNASSESSABLE / UNSUPPORTED_LANGUAGE`。 |
| 実フック入口 | `kit/sumi-guard-real-hook-assessment-check/sumi-guard-real-hook-assessment.ps1` | `PreToolUse`、`tool_name=Bash`、識別子、`tool_input.command`を検証するが、ホストが証明した対象実行ファイルは受け取らない。 |
| 管理下ランナー | `demo/Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1` の `Get-SumiGuardManagedPowerShellVerification` | 標準Windows PowerShell 5.1の絶対パス、実体・版、起動設定をランナー自身が確認してからだけ確認済みとする。 |

公式仕様は、`PreToolUse`のmatcherがツール名を対象にすること、Bash経路の入力が`tool_input.command`であることを示す。一方で、同仕様に対象コマンドのシェル実体・起動引数・ホストが選んだ実行ファイルをフックへ渡すフィールドは記載されていない。これは「その情報が存在しない」ことの将来にわたる保証ではなく、今回確認したローカル版と公開契約からは利用できない、という結論である。

## 信頼境界

| 情報源 | 分類 | `InterpreterVerified` の根拠にできるか |
|---|---|---|
| 管理下ランナーが固定したWindows PowerShell 5.1絶対パス、実体・版、起動設定 | ホスト側の確認済み情報 | できる。ただし、そのランナーが実行対象へ渡した本文だけに適用する。 |
| フック入力の `tool_name=Bash` | ツール種別 | できない。BashはCodexのツール名であり、対象本文の解釈系ではない。 |
| フック自身のPowerShellホスト、`command_windows` | フックの実行環境 | できない。対象ツールの実行言語とは別である。 |
| `tool_input.command`内の文字列、`powershell`、`-ExecutionPolicy` | 本文からの推測 | できない。引用文字列、ラッパー、多段実行を区別できない。 |
| 利用者または上位層による言語宣言 | 宣言された解析対象 | できない。評価専用CLIでは表示用の宣言として扱えても、実行経路の証明ではない。 |

外側シェルの確認は、内側の `-Command`、`-File`、別シェル呼出し、または動的生成本文の解釈系を自動的には証明しない。管理下経路でも、対象本文と起動引数の一致を確認し、内側解釈が別言語・動的入力へ移る場合は、その範囲を `UNASSESSABLE` とする。

## 現行実フックの扱い

現行の実フックは次を維持する。

1. PreToolUse入力から決定的な `execution_id` を計算する。
2. 本文をメモリ内で既存評価器へ渡すが、`InterpreterKind=UNKNOWN` と `InterpreterVerified=false` を渡す。
3. 既存評価器の契約により `UNASSESSABLE / UNSUPPORTED_LANGUAGE` を得る。
4. 実行状態、保存状態、フック応答状態を混同しない。現行実フックの保存は `NOT_ATTEMPTED` のままである。

この結果は検知なしでも安全でもない。本文のAST解析を実施できる前提が未証明であることを表す。

## 将来、ホスト証拠が追加された場合の最小契約

ホストが将来、各PreToolUse呼出しに結び付いた改ざん不能な実行記述を渡す場合だけ、別名のアダプターが次を確認する。

1. 信頼済みホスト情報に、対象ツールが起動する実行ファイルの正規絶対パス、バージョン、起動引数、入力本文の対応識別子が含まれる。
2. その実行ファイルが許可したWindows PowerShell 5.1実体と一致し、起動設定が評価した本文を実際に渡す形式である。
3. `session_id`、`turn_id`、`tool_use_id`から計算したIDと、ホスト証拠の対象呼出しIDが一致する。
4. 本文・起動設定・実行ファイルのいずれかが欠落または不一致なら、`UNKNOWN/false`として評価器へ渡す。
5. 外側PowerShellから内側別インタープリター、エンコード済み本文、動的解決へ移る部分は、確認済みの外側経路と混同せず既存評価器の評価不能理由へ委ねる。

このアダプターは、未信頼JSON内の自己申告を信頼済み証拠へ昇格させない。評価結果の保存、ユーザー通知、deny応答は別段階であり、本契約には含めない。

## 選択肢と推奨

| 選択肢 | 実行言語の証明 | 実フックへの適用 | 推奨度 |
|---|---|---|---|
| 現行PreToolUseをそのまま評価 | 不可 | `UNASSESSABLE`を維持 | 継続する安全な既定 |
| 評価専用CLIで言語を宣言 | 実行証明ではない | 未実行の解析結果だけ | 補助用途 |
| 管理下Windows PowerShellランナー | 実体・版・起動設定・本文一致をランナーが確認 | 管理下ランナーが起動する固定／許可本文だけ | **次の実装対象** |
| 将来のホスト証拠アダプター | 仕様・真正性が確定した場合だけ | その証拠が結び付くPreToolUseだけ | 仕様待ち |

推奨は管理下ランナーを評価・保存・表示の接続点にすることである。これはPC全体やCodex実フックの監視開始ではなく、ランナーが決定し証明できる狭い経路でのみ検知結果を得る方式である。

## 次の最小実装対象

1. 既存管理下ランナーの確認結果を、本文を含まない別名の評価入力エンベロープへ明示的に渡す。
2. 本文一致、実行ファイル、版、起動設定、execution IDの一致を確認する純粋関数と合成試験を追加する。
3. 不一致・欠落・内側解釈不明を、`InterpreterVerified=false`および固定の評価不能状態として確認する。
4. この経路でのみ評価結果専用ストアと日本語警告表示へ接続する。実フックの保存・通知・遮断には接続しない。

実フック接続を再検討する前提は、公式またはローカル実装で、対象インタープリター・起動実体・起動設定・呼出しIDの結合を示す信頼済みフィールドが確認できることである。
