# 隔離PreToolUse評価・保存・応答アダプター記録

## 範囲

`kit/sumi-guard-hook-assessment-store-test` の新規別名アダプターは、合成PreToolUse JSONを検証し、既存方式でexecution_idを算出する。本文を保存する前に既存CommandAssessmentでメモリ内評価し、AssessmentStoreには許可済み評価メタデータだけを保存する。応答は `systemMessage` だけを持つ構造化オブジェクトとして生成し、通常CLIの表示行や本文をstdoutへ流さない。

実インタープリターは現行入力から確認できない。`tool_name`、JSON内の`tool_input.shell`、フックの起動ホストを証拠にしない。通常の合成入力は `UNASSESSABLE` とし、信頼済みWindows PowerShell証拠を渡す経路は、この隔離合成試験の外部パラメーターだけに限定する。

PreToolUseは実行を証明しないため、保存起点は `SYNTHETIC_TEST`、関連execution_idはnullである。計算したexecution_idと評価器戻り値のexecution_idはメモリ内で照合する。実行済みの `MANAGED_EXECUTION` 記録を偽装しない。

## 検証

Windows PowerShell 5.1で新規試験を実行した。

| 項目 | 結果 |
|---|---|
| UTF-8 BOM | 合格 |
| 構文エラー | 0 |
| 合成試験 | 9/9合格 |
| 終了コード | 0 |
| 入力コマンド実行 | 0 |
| 構造化応答以外の出力 | 0 |
| 使い捨てストア残存 | 0 |

確認項目は、現行入力の評価不能、信頼済み合成経路のSG-CMD-001〜003検知、不正入力、評価失敗、保存失敗、ID整合性、本文非漏えい、構造化応答だけである。利用者UIに `systemMessage` が実際に表示されるかは、この隔離試験では未確認である。

実フック登録・実行、常駐化、外部通知、遮断、隔離は実施していない。
