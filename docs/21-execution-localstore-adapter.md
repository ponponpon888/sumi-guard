# SUMI Guard 実行記録・LocalStore接続

## 範囲

`SumiGuard.ExecutionAdapter` は、実行前イベントのメタデータと `SumiGuard.LocalStore` の暗号化本文を
`execution_id` で関連付けるPowerShell 5.1モジュールです。最初に合成イベント8件で検証し、その後、
別コードの使い捨て子Codexセッションと固定入力1件で実フック接続を検証しました。通常のCodex
セッションや実際の開発コマンドは収集しません。

公開コマンドは次の6個です。

- `Initialize-SumiGuardExecutionStore`: 専用メタデータ領域を作り、対象ユーザーとSYSTEMだけのACLを設定する
- `Save-SumiGuardExecutionIntent`: 既定では本文をLocalStoreへ暗号化保存後に実行前イベントを記録する。`-MetadataOnly` なら本文を保存せずハッシュと状態のみを記録する
- `Get-SumiGuardExecutionRecord`: 本文を含まない実行記録を一覧またはID指定で読む
- `Get-SumiGuardCollectionFailureNotice`: 本文を含まない収集失敗通知を読む
- `Read-SumiGuardExecutionBody`: `execution_id` を指定した明示操作でのみ本文を復号する
- `Invoke-SumiGuardExecutionRetentionCleanup`: LocalStore清掃を明示実行し、削除状態を追記する

## 保存順序と相関

`Save-SumiGuardExecutionIntent` は、GUID形式の `execution_id` を受け取るか新規発行し、本文の
SHA-256を計算してからLocalStoreへ本文を渡します。ハッシュ対象は、PowerShell文字列を正規化せず
BOMなしUTF-8へ変換したバイト列です。

本文保存に成功した場合だけ `body_ref` を得て、その後に実行前イベントを書きます。したがって、
本文保存の完了前にイベントを「保存済み」としません。両保存領域は同じ `execution_id` と本文参照で
結ばれますが、単一トランザクションではありません。

平文イベントには次の分類の値だけを保存し、コマンド本文、本文断片、秘密値、例外メッセージを
保存しません。

- スキーマ、レコード、実行、本文参照の各ID
- 発生時刻と観測時刻（UTC）
- 本文SHA-256とハッシュ対象の定義
- `content_status`、`collection_status`、`body_reference_status`、失敗理由コード
- LocalStoreの `body_ref`。保存失敗時は `null`

## 成功、部分成功、失敗

| 本文保存 | イベント保存 | 扱い |
|---|---|---|
| 成功 | 成功 | `EVENT_AND_BODY_SAVED`、`CAPTURED_ENCRYPTED`、参照 `AVAILABLE` |
| 方針により省略 | 成功 | `EVENT_SAVED_METADATA_ONLY`、`HASH_ONLY`、`RECORDS_FOUND`、参照 `NOT_STORED` |
| 失敗 | 成功 | `EVENT_SAVED_BODY_COLLECTION_FAILED`、`HASH_ONLY`、`COLLECTION_FAILED` |
| 成功 | 失敗 | `EVENT_SAVE_FAILED_BODY_ORPHANED`、本文を `SAVED_ORPHANED` として失敗通知へ記録 |
| 失敗 | 失敗 | `EVENT_AND_BODY_SAVE_FAILED`。別の失敗通知も書けなければ永続記録は保証できない |

**機密情報の最小化：**運用 `hooks/Invoke-SumiGuardMonitorHook.ps1` は既定で
`-MetadataOnly` を指定するため、生のコマンド本文を保存しません。本文を保存する
運用経路のみ `-CaptureCommandBody` を明示します。ハッシュ自体も、
推測されやすい短いコマンドでは照合され得る点に注意してください。

イベント、失敗通知、保持期限レコードは種類ごとに16MiBの上限で追記拒否し、
超過時に古い監査記録を黙って削除しません。上限超過によるイベントの保存失敗は
`EVENT_SAVE_FAILED_METADATA_ONLY` などの失敗状態として呼び出し元へ返します。
保持期限の自動ローテーションや改ざん耐性はまだありません。

容量超過、暗号化失敗、イベント保存失敗のいずれも `monitor_action=CONTINUE`、
`automatic_deny=false` です。MONITORモードでは収集失敗を実行拒否へ変換しません。本文保存失敗後に
失敗通知の保存も失敗した場合は、実行イベント内の `COLLECTION_FAILED` と呼び出し結果で区別します。
実行イベント自体も保存できない場合、呼び出し結果より外側に別通知先がなければ障害を永続化できません。

## 読み出しと保持期限

通常の一覧と失敗通知の戻り値には本文プロパティを含めません。本文の復号は
`Read-SumiGuardExecutionBody` を明示的に呼び出した場合だけ行います。

参照先が存在しない場合は、保持期限清掃の記録があるものを `DELETED_BY_RETENTION`、記録がないものを
`REFERENCE_MISSING` / `COLLECTION_FAILED` とします。孤立本文は正常な実行イベントとして返しません。

`Invoke-SumiGuardExecutionRetentionCleanup` は明示呼び出しだけで動き、`-WhatIf` を尊重します。
LocalStore清掃後も元の実行イベントを残し、清掃直前に存在し、保持期限候補で、清掃後に消えた参照へ
`BodyRetentionExpired` を追記します。これにより本文削除後も時刻、ハッシュ、取得履歴を読めます。

## ReadOnly派生モジュール

`SumiGuard.ExecutionAdapter.ReadOnly.psm1` は、既存通常版を基準にメタデータ読取りロックだけを変更した
派生モジュールです。`Get-SumiGuardExecutionRecord` と `Get-SumiGuardCollectionFailureNotice` は、既存の
`.sumi-guard-execution-store.lock` を `FileMode.Open / FileAccess.Read / FileShare.Read` で開きます。

読取りロック同士は共存します。書込み側は従来どおり `OpenOrCreate / ReadWrite / FileShare.None` のため、
読取り中の書込みと書込み中の読取りは共有違反になります。共有違反の8桁HResultだけを上限付きで
再試行し、取得ハンドルは `finally` で破棄します。ロックが存在しない場合は作成せず、メタデータの
直接読取りにも迂回せず、既存API形式の固定失敗を返します。

このセキュリティ強化ブランチでは、ReadOnly派生モジュールの外部公開を
`Get-SumiGuardExecutionRecord` と `Get-SumiGuardCollectionFailureNotice` の2関数に
限定しました。内部の書込み関数がファイル内に残る暫定的な互換構成であり、
最終的なコード分離は今後の課題です。

書込み側ロック、公開APIの戻り値、本文を返さない通常読取り、明示復号APIは変更していません。
一時プロジェクトで検証済みですが、本プロジェクトへ配置後の実行確認は未実施です。

## 既知の制約

- 実フック接続は固定入力1件の一回限り試験までです。恒久登録、通常運用、一般入力の網羅性は未検証です。
- フックイベントには対象プロセスPIDがないため、OS観測との相関は `INFERRED_MATCH` であり
  `DIRECT_MATCH` ではありません。
- OS観測はポーリング方式で、短命プロセスを取り逃す可能性があります。
- イベント領域と本文領域は原子的な単一トランザクションではありません。部分成功は状態と失敗通知で扱います。
- LocalStore清掃APIは削除した本文IDを返さないため、保持期限の追記は「清掃直前に存在した期限候補が、
  削除を伴う清掃直後に消えた」ことによる判定です。同一ユーザーによる同時削除は誤分類し得ます。
- 失敗通知先も同じメタデータ領域です。領域全体が書けない場合は、呼び出し元が戻り値を別経路で扱う必要があります。
- NDJSON追記は暗号学的な改ざん検知を備えません。破損行がある場合は正常一覧として扱わず読み取り失敗にします。
- 本文SHA-256だけでは本文を復元・分析できません。本文分析には明示復号が必要です。
- DPAPI CurrentUserとACLは、同じユーザー権限の別プロセス、管理者、侵害済みセッションからの保護境界ではありません。

Codexフックの入力と一回限りのtrust overrideは、OpenAI公式の
[Hooks](https://learn.chatgpt.com/docs/hooks) に記載された `PreToolUse.tool_input.command` と
`--dangerously-bypass-hook-trust` の動作を前提にしています。
