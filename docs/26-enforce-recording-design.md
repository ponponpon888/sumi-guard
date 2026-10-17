# SUMI Guard ENFORCE_RECORDING（強制モード）設計

## 文書の位置付け

本書は、docs/19 が「将来の明示的な選択肢」とした `ENFORCE_RECORDING` の設計である。設計だけで
あり、実装、フック登録、設定変更は行っていない。既定は `MONITOR` のままである。

docs/19 が課した条件は次のとおりで、本書はこれに従う。

- ユーザーが明示的に有効化した場合だけ、一次保存失敗を deny へ変更できる別モードとする
- 監視モードの既定値を暗黙に強制モードへ昇格させない
- 通知経路を含む障害試験を通した場合だけ提供する
- 監視モードとは別の明示設定と、解除手順を持つ

## 強制するものと、しないもの

`ENFORCE_RECORDING` が強制するのは**実行前記録が残ることだけ**である。「危険だから止める」モード
ではない。

- 強制する: `ExecutionIntentRecorded` と本文が永続化できなかったとき、実行を deny する
- 強制しない: `assessment_status` が `DETECTED` でも deny しない。検知による遮断は本書の対象外

この分離は意図的である。docs/23 の `NO_DETECTION` は「有効なルールに一致しなかった」だけを
意味し、安全の保証ではない。検知を deny の根拠にすると、誤検知の代価が「実行の停止」になり、
初版3ルールの精度に対して釣り合わない。一方「記録できないなら実行させない」は、ルールの精度に
依存せず、追跡可能性という一点だけを守る。

## 失敗の種類と、deny / allow の割り当て

`SumiGuard.ExecutionAdapter` は事実を返すだけで、`monitor_action = 'CONTINUE'`、
`automatic_deny = $false` を固定で返す。失敗を deny に変える方針はフック側に置く。アダプタは
変更しない。

| 失敗 | アダプタの状態 | 強制モードでの扱い | 理由 |
|---|---|---|---|
| ストアの検証失敗（未初期化、ACL不備、reparse） | `EXECUTION_STORE_VALIDATION_FAILED` | **deny** | 記録先が無い。以後の実行も記録できない |
| 本文ハッシュの計算失敗 | `BODY_HASH_FAILED` | **deny** | 同じ本文かを後から比較できない |
| 本文保存の失敗（イベントは保存） | `EVENT_SAVED_BODY_COLLECTION_FAILED` | **deny** | ハッシュとメタデータだけでは、後からダウンロード・無効化・永続化を判定できない（docs/19） |
| 容量上限に到達 | 保存失敗 | **deny** + 保持期間清掃を促す通知 | 記録できない状態が続くため。ただし作業停止の主要因になり得る（下記） |
| ロック競合 | 保存失敗 | 上限付き再試行の後に **deny** | 競合は一時的なことが多い。再試行で解消するなら止めない |
| 評価レコードの保存失敗 | `ASSESSMENT_STORE_FAILED` | **allow** + 別通知 | 評価は MONITOR の範囲であり、追跡可能性は実行前記録で担保される |
| 評価そのものの失敗 | `EVALUATION_FAILED` | **allow** | 判定不能は実行の是非を意味しない（docs/23） |
| フック入力が読めない | `INVALID_HOOK_INPUT` | **allow** + 別通知 | 事象を識別できないので、どの実行に対する deny かを特定できない |
| 通知経路の失敗 | `NOTICE_NOT_PERSISTED` | 元の判定を変えない | 通知は記録の代替ではない。deny の根拠にも allow の根拠にもしない |

`INVALID_HOOK_INPUT` を allow にするかは判断が必要な点である。強制モードの趣旨からは「記録が
無いのだから deny」とも言えるが、読めない事象はコマンド実行とも限らず、deny の対象を特定できない。
本書は allow を採る。

## 応答の形

`kit/sumi-guard-prototype/sumi-guard-hook.ps1` と
`kit/sumi-guard-protected-hook-test/sumi-guard-protected-hook.ps1` が、次の形を既に使っている。

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"固定文"}}
```

ただし `measurements/2026-10-03-sumi-guard-prototype.md` は「自動deny: なし」と記録している。
形は実装されているが、**ホストが deny を実際に尊重して実行を止めるかは実測されていない**。
したがって強制モードの最初の実証は、使い捨て子Codexと無害な固定入力で「deny が尊重されること」
を確認する段から始める。これを確認するまでは強制モードを提供しない。

`permissionDecisionReason` には固定文だけを入れる。コマンド本文、引数、パス、例外本文は入れない。

## 不変条件

- deny は `PreToolUse` でだけ返す。`PostToolUse` では実行結果の記録だけを行い、deny しない
- deny の理由は固定コードと固定文に限る。本文や一致断片を含めない
- deny しても、記録できなかったという事実の通知は別経路へ試みる
- `MONITOR` と `ENFORCE_RECORDING` を1つの設定で混在させない。経路ごとに別の明示設定とする
- フック自身が応答を書けない失敗（フックのクラッシュ、標準出力の書き込み失敗）では、構造的に
  allow になる。強制モードでも「記録の無い実行」を完全には防げない。これは残る穴として表示する

最後の項目は強制モードの限界である。MONITOR が「記録できなくても止めない」ことを明示するのと
同じ理由で、強制モードも「止められない場合がある」ことを明示する。

## 作業を全停止させないための制約

強制モードは fail-closed であり、設定を誤ると開発作業が止まる。次を設計に含める。

- 既定は `MONITOR`。強制モードは明示設定でのみ有効になる
- 対象経路を列挙で限定する。列挙に無い経路は `MONITOR` のまま扱う
- ロック競合は上限付き再試行（回数と待ち時間を設定値にする）を経てから deny する
- 容量上限に到達したときは、deny と同時に保持期間清掃の手順を固定文で示す
- 解除は設定の削除だけで完了し、フックの再登録や再起動を必要としない

## 状態とレコード

実行前イベントに次を追加する。既存の `collection_status`、`content_status`、
`assessment_status` は上書きしない。

| 項目 | 値 |
|---|---|
| `enforcement_mode` | `MONITOR` / `ENFORCE_RECORDING` |
| `enforcement_action` | `ALLOWED` / `DENIED_RECORDING_FAILED` |
| `enforcement_reason_code` | `STORE_VALIDATION_FAILED` / `BODY_HASH_FAILED` / `BODY_STORE_FAILED` / `STORE_CAPACITY_REACHED` / `LOCK_TIMEOUT` |
| `retry_count` | ロック競合で再試行した回数 |

deny した実行は、記録が残っていないからこそ deny されている。したがって deny 自体の記録も
一次保存に書けない可能性がある。deny の事実は別通知経路に書き、そこにも書けなければ
「記録できていない」と表示する。deny を記録できたことを前提にしない。

## 障害試験の計画

合成試験で次を確認する。CIで実行できるものと、運用端末が必要なものを分ける。

CIで確認できるもの（DPAPIと実ホストに依存しない範囲）。

1. 各失敗の注入に対して、割り当て表どおりに deny / allow が決まること
2. deny 応答が固定文だけを含み、カナリア文字列・パス・例外本文を含まないこと
3. ロック競合が再試行回数の上限まで試され、上限後に deny になること
4. 評価の失敗と評価保存の失敗では deny にならないこと
5. 対象経路の列挙に無い入力は `MONITOR` として扱われること
6. フック内部エラーのとき、応答が allow 側に倒れることと、その事実が記録されること

運用端末が必要なもの。

7. ホストが `permissionDecision = 'deny'` を尊重して実行を止めること（未実測。最初の実証）
8. DPAPI CurrentUser の保存失敗を実際に起こしたときの挙動
9. 容量上限に到達した状態からの復帰手順

## 解除手順

1. 強制モードの設定を削除する（または対象経路の列挙から外す）
2. 次の `PreToolUse` から `MONITOR` に戻る。フックの再登録は不要
3. 解除した時刻と理由を測定記録に残す

## 段階的導入

1. deny が尊重されることの実証（使い捨て子Codex、無害な固定入力、1件）
2. 合成試験で割り当て表と不変条件を確認
3. 1経路だけで有効化し、deny の発生件数と誤 deny の有無を測定
4. 測定後にのみ、対象経路を増やす

## この文書が言えないこと

- 実装していない。本書の時点で `hooks/Invoke-SumiGuardMonitorHook.ps1` は常に allow であり、
  `automatic_deny` は固定で `$false` である
- ホストが deny を尊重するかは未実測である
- 強制モードは「記録が残ること」だけを強制し、実行の安全性について何も言わない
- フック自身が応答を書けない失敗では allow になるため、記録の無い実行を完全には防げない
