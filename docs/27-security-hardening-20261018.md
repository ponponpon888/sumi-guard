# SUMI Guard セキュリティ強化（2026-10-18）

## 対象と非対象

この文書は `security/sumi-guard-hardening-20261018` ブランチの変更点を記録する。
`master` へのマージ、実運用フックの登録、既存ストアの変更、Windowsローカル
システムへの権限変更は行わない。既定動作は MONITOR（警告のみ、実行拒否なし）。
監視と遮断を混同しない。

## 1. AssessmentStore のACLを閉じる

- 新規作成した評価ストアでは継承を無効化し、実行WindowsユーザーとSYSTEMの
  SIDだけにFullControlを付与する。
- ストアのディレクトリ、marker、lock、assessments.ndjsonのACLを各操作前に
  検査する。予期しない明示/継承ACEがあれば `STORE_ACL_INVALID` として
  **書込みも読取りも拒否**する。保存時に勝手に権限を緩めたり書き換えたりしない。
- 新規ディレクトリを作った後ACLを設定できない場合は記録ファイルを作らない。
  作成途中の空ディレクトリは残る可能性がある。自動削除しない。
- 既存の評価ストアはこの変更だけでは保護されない。旧ストアに継承ACE等が
  あれば拒否される。**明示的な移行が必要**である。ストアの所在、保護対象、
  バックアップ要否、ACL、動作試験を運用端末で確認するまで自動移行しない。
- 同じユーザーで動く悪意あるプロセスや管理者からの改変防止にはならない。

検証: `Invoke-AssessmentStoreTests.ps1` にWindows DACL、対象外ACE、
継承が有効な旧ストアの拒否、無断修復しないことを検査するケースを追加。

## 2. コマンド本文は既定で保存しない

- `Save-SumiGuardExecutionIntent -MetadataOnly` は本文をメモリ内でSHA-256化し、
  コマンド全文をDPAPIにもファイルにも渡さず、メタデータだけを保存する。
- 本文取得結果は `EVENT_SAVED_METADATA_ONLY` / `HASH_ONLY` /
  `NOT_STORED`。方針による省略は収集失敗と混同せず、
  `collection_status=RECORDS_FOUND` にする。本文を後から読む試みは
  `BODY_NOT_CAPTURED` となる。
- 通常のアダプタ直接呼び出しは互換性のため従来どおり暗号化本文を保存する。
  運用MONITORフックは **既定で `-MetadataOnly`** を渡す。
  暗号化本文が必要な隔離運用だけ `-CaptureCommandBody` を明示する。
- フックは保存に失敗してもMONITORとして継続する。denyは実装しない。
- ハッシュは推測されやすい短いコマンドとの照合に利用され得る。保護境界は
  ACLであり、メタデータを公開してよいという意味ではない。
- メモリ内の本文、OS/ホストのログ、他アプリの記録はこの変更の制御外である。
  AIが生成するシークレットの自動検出や、自動マスキングの保証はしない。

検証: `Invoke-ExecutionAdapterIntegrationTests.ps1` に本文ファイルを一切増やさない
テストを追加（Windows運用端末での実行が必要、CIからは除外）。

## 3. 変更操作をReadOnly公開APIから除外

`SumiGuard.ExecutionAdapter.ReadOnly.psm1` の公開関数を
`Get-SumiGuardExecutionRecord` と `Get-SumiGuardCollectionFailureNotice` に
限定。既存の読取りCLIが使用するAPIは維持した。
読み取り専用表示は復号本文を返さない。

現時点では互換のため派生モジュール内に内部実装が残っている。
それ自体はWindowsセキュリティ境界ではないため、将来は読取り専用の
純粋モジュールへ切り出す。

検証: `Invoke-ReadOnlyModuleExportTests.ps1` をCIに追加。DPAPIを実行せず
外部公開名とCLIの参照先を検査する。

## 4. 監査メタデータの容量を制限

`ExecutionAdapter` の `events.ndjson`、`failures.ndjson`、
`retention.ndjson` は、各ファイル最大16MiBで追記を拒否する。
上限判定と追記は既存の排他ロックの範囲で行う。容量超過でも古い証跡は
暗黙に削除しない。単一トランザクションではないため、失敗通知も書けない
状況は残る。ディスク全体の容量上限は保証しない。

検証: `Invoke-ExecutionAdapterIntegrationTests.ps1` で上限を小さくした
合成テストを追加（DPAPI依存のためCI除外）。

## CIの対象と限界

GitHub ActionsのWindows PowerShell 5.1で、構文、BOM、
PSScriptAnalyzer、DPAPI非依存テストを実行する。さらに合成データだけを
使う `isolated-dpapi-smoke` ジョブでDPAPI依存3テストを、
**使い捨てGitHubホスト上でのみ**実行する。
- `tests/Invoke-AssessmentStoreTests.ps1`（新規ACL回帰）
- `tests/Invoke-ReadOnlyModuleExportTests.ps1`（公開API）
- `tests/Invoke-MonitorHookSyntheticTests.ps1`（既存MONITOR契約）
- `tests/Invoke-ExecutionAdapterIntegrationTests.ps1` は隔離Windowsスモークでも実行する（運用端末での再検証は別途必要）

CI成功はWindows実機の保護や常時監視、感染の有無を保証しない。

## さらに必要なこと（本PRでは実施しない）

1. 運用PCの現在の評価ストアのACL調査とバックアップ・移行計画。
2. DPAPI依存テスト3件と限定フック接続の実機検証。
3. モニターの実際の登録経路、信頼ルート、未取得コマンドの測定。
4. GitHub `master` のブランチ保護・必須CI設定（GitHub設定変更は別承認）。
5. 認証済み監査ログ、メタデータ保持期限と安全な明示清掃の設計（読取り専用の非認証ハッシュ照合は docs/28 に試験実装済み）。
6. `ENFORCE_RECORDING` の無害な隔離実証、誤遮断対策、解除動線。

いずれも今回のPRをマージしただけで自動的に有効にはならない。

## 省エネCIとテスト用注入の誤使用対策（2026-10-18）

- feature branchのpushではCIを二重起動せず、PRの更新だけで4ジョブを検証する。master pushと手動実行は維持する。
- 運用フック内のテスト用疑似保存・障害注入は SyntheticTestOnly の明示指定と、一時ディレクトリの固定形および通知・結果ファイルの固定パスが必要。条件に一致しないと TEST_CONFIGURATION_REJECTED を返し、ストアと結果ファイルを書かない。
- この制約は運用時の設定ミスを減らす目的であり、同一ユーザーによる故意の偽装に対するアクセス制御ではない。MONITOR は今までどおり実行をdenyしない。
- 合成テストに明示オプトインなしと想定外パスの拒否を追加した。

## 監査ログ検証器（追加）

- 既存の監査メタデータを読取専用で検査する `tools/Test-SumiGuardAuditIntegrity.ps1` を追加。
- 正しいJSON・ID・SHA形式・重複・保持期限の参照関係を検査し、markerおよび既知NDJSONファイルのSHA-256を計算する。
- `Snapshot` のみでは基準値を認証できないため、改ざんが無かったという証明にはならない。
- `Compare` は別途信頼できる経路で保管した基準値と比較する。正規の追記でも不一致になる。侵害済み同一ユーザーがログと基準値の両方を改変できる場合には対抗できない。
- 本機能は記録形式を変更せず、自動修復・削除・移行・フックの有効化を行わない。

## 2026-10-18: 署名済み監査チェックポイントの検証

運用PCに秘密鍵を置かず、別の信頼環境で署名された基準値を
`tools/Test-SumiGuardSignedCheckpoint.ps1` で検証する仕組みを追加。
公開鍵JSONのハッシュ指紋を独立した経路で取得する必要がある。
合成テストでは使い捨てRSA署名鍵をメモリ上で生成し、署名不一致、
指紋不一致、監査ログ差分、弱い鍵の拒否を検証する。

実運用の署名鍵・HSM・保管先・配布・ロールバック保護は本PRには含まず、
今回の追加は検証器と合成テストのみ。masterや本番を変更しない。
詳細: `docs/29-signed-audit-checkpoint.md`。
