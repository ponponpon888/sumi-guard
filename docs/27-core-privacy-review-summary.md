# Core Privacy / ReadOnly API / 容量上限 統合レビュー要約

## この文書の位置付け

PR #8、#9、#10を一体として最終確認するための読み取りベースのレビュー要約です。マージ判断に必要な
事実、証拠が属するSHA、未実施の範囲、戻し方を1か所に集約します。

この文書自体はmasterへのマージを前提にしていません。確認時点で、**公開masterにはPR #8、#9、#10の
いずれも反映されていません**。以下で「候補」と書いた動作は、未マージブランチ上でのみ確認できる
動作であり、公開masterの既定動作ではありません。

## 対象SHAとPR依存関係

公開masterの基準コミットは `36e56934d26fdc7ce2296ef39a6c50113dc405b8` です。候補は次の順に積まれて
います。各PRのbaseは直前のPRのブランチであり、独立した並列PRではありません。

| 段階 | PR | ブランチ | head SHA | base |
|---|---|---|---|---|
| 公開済み | — | `master` | `36e56934d26fdc7ce2296ef39a6c50113dc405b8` | — |
| 1 | [#8](https://github.com/ponponpon888/sumi-guard/pull/8) | `integration/core-privacy-governance-ci` | `8ae5b98` | `master` |
| 2 | [#9](https://github.com/ponponpon888/sumi-guard/pull/9) | `security/readonly-api-surface` | `43f9d64` | `integration/core-privacy-governance-ci` |
| 3 | [#10](https://github.com/ponponpon888/sumi-guard/pull/10) | `security/metadata-log-limits` | `8f46ad3` | `security/readonly-api-surface` |
| 4 | この文書 | `docs/core-privacy-review-summary` | 本PRのhead | `security/metadata-log-limits` |

依存関係は **#8 → #9 → #10 → この文書PR** です。PR #8はさらに個別PR #5（Core Privacy）、#6
（security governance）、#7（CI hardening）を取り込んだ統合候補であり、個別PRと#8を重複して
マージしない方針です。

`master` から候補HEADまでの差分は17ファイル、1,406挿入、31削除です。ローカルの `master` ref が
`origin/master` より古い場合、`git diff master..HEAD` は候補の変更量を過大に表示します。比較は
`origin/master`（`36e5693`）を基準にしてください。

## 候補に含まれる動作

### 既定MetadataOnlyの適用範囲

**MONITORフックの既定** です。`hooks/Invoke-SumiGuardMonitorHook.ps1` は `-CaptureCommandBody`
（既定off）を取り、`-MetadataOnly:(-not $CaptureCommandBody)` としてアダプタを呼びます。したがって
フック経由では、明示指定がない限り本文を保存せずハッシュとメタデータだけを記録します。

**直接アダプタ呼出しの契約は別です。** `Save-SumiGuardExecutionIntent` の `-MetadataOnly` は既定off
のスイッチのままで、直接呼び出した場合は従来どおり本文保存経路に入ります。この2つを同じ既定として
説明しないでください。

### ReadOnly公開API

`SumiGuard.ExecutionAdapter.ReadOnly` の公開関数は**2件**です。

- `Get-SumiGuardExecutionRecord`
- `Get-SumiGuardCollectionFailureNotice`

これは公開一覧の制限です。モジュール内部には書込み関数が残っており、内部関数の実行不能やOS権限
境界を主張するものではありません。

### メタデータログの容量上限

`events.ndjson`、`failures.ndjson`、`retention.ndjson` の**3種類それぞれに16MiB**（16,777,216バイト）
の上限があります。

- 判定は既存の書込みロック内で、UTF-8バイト数と改行を含めた追記後サイズに対して行います。
- 上限ちょうどは許可し、超過は**追記前に拒否**します。拒否時に対象ファイルのサイズと内容は変わりません。
- **削除、切詰め、自動ローテーションは行いません。** 上限に達したログは、容量超過を記録失敗として
  返し続けます。暗黙の成功や `NO_RECORD` へ格下げしません。
- 上限値はLocalStoreの本文容量（1件1MiB、合計250MiB、保持30日）とは別の指標です。混同しないでください。

### retentionの非原子性（公開masterの既存の性質）

本文削除とtombstone記録は複数ファイルにまたがり、**原子的ではありません**。本文を削除した後に
retentionログへtombstoneを書けなかった場合、

- 清掃結果は `RETENTION_CLEANUP_PARTIAL` となり、成功扱いにはなりません。
- `retention_tombstone_failure_count` に失敗件数が残ります。
- 以降その記録の参照状態は `REFERENCE_MISSING` になり得ます。

**これは候補が追加した制限ではありません。** `RETENTION_CLEANUP_PARTIAL`、`REFERENCE_MISSING`、
`retention_tombstone_failure_count` はいずれも公開masterに既に存在します。候補が追加したのは、
retentionログが容量上限に達した場合にこの区別が保たれることの検証（`#10`）であり、原子性そのものの
改善ではありません。

## 実施済みのテストとCI、証拠が属するSHA

証拠は実行されたSHAに属します。後続SHAでの再実行に置き換えないでください。

| 証拠 | 属するSHA | 内容 |
|---|---|---|
| CI run [39310044529](https://github.com/ponponpon888/sumi-guard/actions/runs/39310044529) | `8ae5b98`（#8） | 3ジョブPASS。DPAPI非依存試験12件実行／3件除外 |
| CI run [39316609193](https://github.com/ponponpon888/sumi-guard/actions/runs/39316609193) | `43f9d64`（#9） | 3ジョブPASS。12件実行／3件除外 |
| CI run [39354719330](https://github.com/ponponpon888/sumi-guard/actions/runs/39354719330) | `8f46ad3`（#10） | 3ジョブPASS。13件実行／3件除外 |
| `tests/Invoke-ExecutionAdapterMetadataLogLimitTests.ps1` 5/5 PASS | `8f46ad3` | CI・ローカル通常PowerShell 5.1の双方。CI実行対象に登録済み |
| `tests/Invoke-ReadOnlyCliTests.ps1` 5/5 PASS | `43f9d64` | ローカル通常PowerShell 5.1のみ。**CIでは除外**（DPAPI CurrentUser依存） |
| ReadOnly公開API 2関数の契約確認 | `43f9d64` | manifest、`Export-ModuleMember`、実インポート結果が一致 |
| PR #5の通常PowerShell 12/12 PASS | `4e6ada5`（#5） | #8の統合ブランチで再実行していない |

`#10` の容量上限テストが確認する5件は次のとおりです。

| テスト | 主な証跡 |
|---|---|
| `metadata_log_boundaries_and_utf8_accounting` | 上限ちょうど16,777,216バイトを受理、超過をEvent/Failure/Retentionすべてで拒否、拒否後のサイズ・ハッシュ不変 |
| `concurrent_append_preserves_limit` | 4プロセス同時追記で3件成功・1件容量超過拒否、最終15,729,048バイト ≤ 16,777,216 |
| `metadata_only_capacity_failure_is_collection_failure` | `EVENT_SAVE_FAILED_METADATA_ONLY` / `COLLECTION_FAILED` / denyなし、失敗通知は `SAVED` |
| `full_failure_log_terminates_without_recursion` | 失敗ログ満杯時も再帰せず `failure_notice_status=FAILED` で即時終了 |
| `retention_log_failure_is_partial_not_success` | `RETENTION_CLEANUP_PARTIAL`、tombstone失敗1件、後続参照は `REFERENCE_MISSING` |

### CIが言えないこと

CIはWindows PowerShell 5.1の構文・UTF-8 BOM、PSScriptAnalyzer、DPAPI非依存の合成試験だけを確認します。
DPAPI CurrentUser依存の3件（`Invoke-LocalStoreTests.ps1`、`Invoke-ExecutionAdapterIntegrationTests.ps1`、
`Invoke-ReadOnlyCliTests.ps1`）は明示的に除外されています。CIの合格から、運用ストア、実資格情報、
恒久フック、DPAPI運用境界、外部監査基準への適合は導けません。

## 進捗と未実施の範囲

- **W0: 完了。** 候補上の実装と対象テスト、CIの確認が揃っています。
- **W2: 保留。** 認証条件が成立していないため着手していません。実運用ストアや実ホスト接続の検証
  成功として扱える証拠はありません。
- **未実施:** 運用ストアの変更、恒久フック登録、Release作成・公開配布。認証・信頼設定の変更も
  行っていません。
- **非公開脆弱性報告窓口: 有効状態を確認できていません。** 確認時点でリポジトリAPIに
  `private_vulnerability_reporting` の状態は現れず、`secret_scanning` と
  `dependabot_security_updates` は `disabled` でした。有効な非公開報告窓口を案内できる状態では
  ありません。

## マージ候補と、運用開始・公開配布の条件

これらは別の判断です。片方の達成をもう片方の根拠にしないでください。

### マージ候補として満たしているもの

- 候補HEADで3ジョブCI PASS、対象テストの結果と属するSHAが特定済み。
- 公開masterの既定動作と候補の動作を文書で区別済み。
- schema 1、実行前イベントの意味、直接アダプタ呼出し契約を変更していない。
- PR #2の署名・受領証・監査整合性の実装は混入していない。

### 運用開始に追加で必要なもの（未達）

- W2の認証条件の成立と、実ホスト接続の検証。
- 運用端末と同じユーザー境界でのDPAPI依存3試験の実行。
- 運用ストアのACL、DPAPIユーザー境界、恒久フック登録、通知失敗、復旧手順を固定の合成データで確認。
- 容量上限に達した後の運用手順（削除・ローテーションを行わない前提での運用設計）の決定。

### 公開配布に追加で必要なもの（未達）

- Release tag、安定版番号、サポート範囲の定義。
- 有効な非公開脆弱性報告窓口の用意と、`SECURITY.md` の更新。
- 外部監査基準を主張する場合は、署名・鍵管理・失効・受領証・改ざん不能な外部保管の設計と実装。
  いずれも候補に含まれていません。

## マージする場合の順序と、各段階で更新する文書

base が直前のPRのブランチなので、順序を飛ばせません。下から順にマージします。

| 順 | 対象 | マージ後に更新する文書 |
|---|---|---|
| 1 | #8 → `master` | 4文書のmaster基準SHA。#5/#6/#7を「未マージ」から「公開済み」へ移動。`integration/core-privacy-governance-ci` を候補として説明している箇所 |
| 2 | #9 → `master` | ReadOnly公開API2件を公開masterの仕様として記載。`THREAT_MODEL.md` のReadOnly行 |
| 3 | #10 → `master` | 3種NDJSONの16MiB上限、削除・切詰め・ローテーションなし、retention非原子性を公開masterの仕様として記載。`README.md` の容量上限の節 |
| 4 | この文書PR → `master` | この文書の「公開masterには反映されていません」という前提を、実際の状態に合わせて更新 |

各段階で、前段のPRのブランチが削除されると後続PRのbaseは自動的に繰り上がります。繰り上がり後の
baseが意図どおりか、マージ前に確認してください。

### マージ後に説明が古くなる箇所

マージすると次の記述が事実と合わなくなります。マージと同じ段階で直してください。

- `README.md`、`SECURITY.md`、`THREAT_MODEL.md` が参照する公開master SHA
  `36e56934d26fdc7ce2296ef39a6c50113dc405b8`。
- 4文書にある「PR #2、#5、#6、#7、#8、#9、#10はDraft・未マージ」という一覧。
- `README.md`・`CONTRIBUTING.md`・`THREAT_MODEL.md` の「統合検証候補」「候補の動作であり公開masterの
  既定動作ではない」という条件付けの文。
- `THREAT_MODEL.md` の「PR #5の既定MetadataOnlyは未マージ」という残余リスク欄。
- この文書の冒頭と「対象SHAとPR依存関係」の表。
- PR #2が先にマージされた場合、`docs/27` の番号がPR #2の `docs/27-security-hardening-20261018.md`
  と重複します。どちらかを採番し直してください。この候補にPR #2は含まれていないため、本文書は
  この候補での次番として `27` を使っています。

## 元へ戻す方法

共有履歴に対する `git reset` と `git push --force` は使いません。

- **マージ前:** 対象PRをDraftのまま閉じ、リモートブランチを削除します。`master` は変化しないため
  戻す操作は不要です。ローカルworktreeは `git worktree remove` で破棄します。
- **マージ後:** そのマージコミットに対して `git revert -m 1 <merge-sha>` で打ち消しコミットを作り、
  通常pushします。履歴は書き換えません。
- **複数段を戻す場合:** 新しいマージから古いマージへ向かって順に revert します。`#10` → `#9` → `#8`
  の順です。逆順にすると打ち消しが競合します。
- revert後は、上の「マージ後に説明が古くなる箇所」を逆向きに戻す必要があります。文書が実態より
  進んだ状態で残らないようにしてください。

## レビューで確認した事項

| 確認項目 | 結果 |
|---|---|
| ReadOnly公開関数が2件のまま | PASS。manifest、`Export-ModuleMember`、実インポート結果の3点が一致（実インポートで2件、通常アダプタは6件） |
| PR #2の署名・受領証等の混入 | なし。PR #2固有の `docs/27`〜`docs/32`、署名・監査整合性のテストとtoolsはいずれも候補に存在しない。4文書の言及は「masterにない／実装済みと扱わない」という除外の記述のみ |
| 16MiB上限が3種のログに適用 | PASS。`MetadataLogMaxBytes = 16MB` を通常・ReadOnly両モジュールが持ち、`Event`/`Failure`/`Retention` の3経路で同じ判定を通る |
| 容量超過時の削除・切詰め・ローテーション | なし。該当する実装を確認できず、拒否のみ |
| 既定MetadataOnlyの適用範囲と直接呼出し契約の区別 | 実装と説明が一致。フックは `-CaptureCommandBody` 既定offでMetadataOnly、アダプタの `-MetadataOnly` は既定offのまま |
| retention非原子性とPARTIAL／REFERENCE_MISSING | 実装と説明が一致。該当テストで確認済み |
| 新規テストのCI登録 | PASS。`$includedTests` は13要素で、容量上限テストを含む。CIログの実行件数13と一致 |
| 文書の相対リンク | 全件解決（`SECURITY.md`→2件、`THREAT_MODEL.md`→1件、`CONTRIBUTING.md`→1件、および本文中の参照先） |

### 指摘事項

1. **ローカル `master` ref が古い（レビュー手順の注意／コード欠陥ではない）。** ローカル `master` が
   `ec17286` を指す状態では、`git diff master..HEAD` が38ファイル・4,176挿入と表示され、実際の候補
   差分（17ファイル・1,406挿入）より大きく見えます。`origin/master` を基準にしてください。
2. **CI試験一覧の区切りが不統一（軽微・本PRでは修正しない）。**
   `.github/scripts/Invoke-SumiGuardCiTestSuite.ps1` の `$includedTests` は、末尾2要素の間だけ
   カンマがなく改行区切りになっています。`@()` 内では改行区切りも有効で、要素数13とCIの実行件数13を
   確認済みのため動作上の問題はありません。文書作業に無関係な修正を混ぜないため、ここでは直して
   いません。
3. **DPAPI依存試験はCIで検証されない。** `#9` の主要な根拠である `Invoke-ReadOnlyCliTests.ps1` は
   CI除外対象です。この証拠はローカル通常PowerShellの実行結果のみで、運用端末と同じユーザー境界での
   確認は別途必要です。

上記以外に、実装と説明の不一致は確認できませんでした。
