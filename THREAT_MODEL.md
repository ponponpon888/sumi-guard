# SUMI Guard Threat Model

## 文書の位置付け

これは、公開 `master` の確認済みコミット `3db6ab022548e080c04a4f568f685fe6b37f380b` を対象にした読み取りベースの脅威整理です。実装済みの制御、既存テスト、残余リスクを分けて記載します。未マージPRや設計書の提案を、実装済みの制御として数えません。

### 公開済み・未マージ・設計の区別

- **公開済み**: `master` に含まれる `hooks/`、`src/`、`tools/`、既存 `tests/`、`.github/workflows/`。
- **取り込み済み**: PR #8、#9、#10。PR #5、#6、#7の変更はPR #8経由で取り込み済みです。PR #2の署名・受領証・監査整合性は含みません。
- **公開masterの制御**: MONITORフックの既定MetadataOnly、AssessmentStoreの不正ACL拒否（自動修復なし）、master限定push CI、ReadOnly公開API2件、3種NDJSONログの各16MiB上限を含みます。直接アダプタ呼出しは従来の本文保存契約を維持します。証拠の帰属とマージ記録は [docs/27-core-privacy-review-summary.md](docs/27-core-privacy-review-summary.md) を参照してください。
- **設計のみ**: `docs/19`、`docs/23`、`docs/24`、`docs/26` に記載された将来の相関、インタープリター検証、ENFORCE_RECORDING等。設計書の存在は実装・運用検証を意味しません。

## 保護対象

1. **資格情報**: コマンド本文、引数、トークン、秘密鍵、Cookie、環境由来の機密値。
2. **開発の可用性**: 監査機能の失敗が、意図せず開発操作を停止・遮断しないこと。反対に、記録失敗を成功と誤表示しないこと。
3. **証拠の意味**: 実行前入力、評価、実行済み状態、OS観測、相関の確度を混同しないこと。
4. **ログ機密性**: 保存記録、失敗通知、標準出力・標準エラー、CIログに本文や例外詳細を不要に残さないこと。

## 信頼境界

| 境界 | 前提と扱い |
|---|---|
| 外部コンテンツ | コマンド本文、ファイル内容、ネットワーク由来文字列は攻撃者が制御し得る入力として扱う。本文を安全な証拠とはみなさない。 |
| AIホスト | `PreToolUse`入力を渡す主体。フック入力は実行前の情報であり、対象プロセスの実行や実行結果を証明しない。ホストがdenyを尊重することもmasterでは保証しない。 |
| 管理下ランナー | 明示的に管理された実行経路でのみ、起動ファイル・引数・本文の一致を別途確認できる。通常フックの入力にその証明があるとは扱わない。 |
| Windowsユーザー | DPAPI `CurrentUser` とACLは通常の別ユーザーアクセスを抑えるが、同じユーザー権限の別プロセス、管理者、侵害済みセッションを信頼境界の外へ押し出せない。 |
| 外部監査基準 | 署名、失効、受領証、監査整合性などの要求は、masterの保存記録だけでは満たしたと判断しない。 |
| GitHub CI | 公開リポジトリ上の構文、解析、合成試験を確認する場所。運用端末のDPAPI、ACL、恒久フック、実資格情報を再現しない。 |

## 脅威と対応

| 脅威 | 公開masterの制御 | 既存テスト・検証資料 | 残余リスク／未確認事項 |
|---|---|---|---|
| コマンド本文や資格情報が評価・通知・CIログへ漏れる | CommandAssessmentは本文を評価するが、評価レコードは`content_included=false`、フック通知は固定コード・例外本文なし。保存本文はLocalStoreのDPAPI保護経路へ渡る。 | `tests/Invoke-CommandAssessmentTests.ps1`、`tests/Invoke-MonitorHookSyntheticTests.ps1`、`docs/19`、`docs/20` | MONITORは既定MetadataOnlyで、本文保存は明示指定時だけ。評価中の本文はメモリに存在し、直接アダプタ呼出しは既定で本文を保存する。本文漏えいを完全には防がない。 |
| 保存先のACL・reparse pointが弱く、記録を読取・改変・差替えされる | LocalStore、ExecutionAdapter、AssessmentStoreがACL、継承、reparse point、markerを検査する。既存ストアを無条件に修復する制御ではない。 | `tests/Invoke-LocalStoreTests.ps1`、`tests/Invoke-ExecutionAdapterIntegrationTests.ps1`、`docs/20`、`docs/21` | DPAPI依存3試験は候補 `87e6fb2` で通常PowerShellから23/23 PASS（CIでは除外）。管理者、同一ユーザー、侵害済みセッション、特殊ACLプロバイダー、ネットワーク共有は未検証。 |
| 記録失敗を成功・安全・実行済みと誤表示する | `collection_status`、`content_status`、保存状態、`automatic_deny`を分離。MONITORは評価・保存失敗を固定通知と状態へ反映し、実行済みへ格上げしない。 | `tests/Invoke-MonitorHookSyntheticTests.ps1`、`tests/Invoke-AssessmentStoreTests.ps1`、`docs/19`、`docs/23` | 通知経路自体も失敗し得る。masterは記録失敗時にdenyするENFORCE_RECORDINGを実装していない。 |
| 実行前イベントを実行済みの証拠として利用する | `CODEX_PRETOOLUSE_HOOK`、`MANAGED_EXECUTION`、`SYNTHETIC_TEST`を区別し、`ExecutionIntentRecorded`を実行結果と別扱いにする。 | `tests/Invoke-AssessmentStoreTests.ps1`、`tests/Invoke-ManagedAssessmentVerificationTests.ps1`、`docs/24` | フックイベントに対象PIDや実行結果がない。OS観測との相関は`INFERRED_MATCH`までで、`DIRECT_MATCH`や実行成功を保証しない。 |
| `NO_DETECTION`を安全保証として誤解する | README、評価器、評価テストで、対応ルールに一致しない状態と安全を分離する。対応ルールは限定された3ルール。 | `tests/Invoke-CommandAssessmentTests.ps1`、`README.md`、`docs/23` | 未知の言語、動的生成、難読化、未対応の危険操作、入力欠落は検知できないか評価不能になる。 |
| 外部コンテンツやAIホストが不正な入力を渡す | フックはイベント名、ツール名、識別子、`tool_input.command`の存在と型を検証し、無効入力を評価・保存・denyへ補完しない。 | `tests/Invoke-MonitorHookSyntheticTests.ps1`、`tests/Invoke-CommandAssessmentHookIntegrationTests.ps1` | ホスト自体の真正性、呼出し順、設定、対象シェルはフックJSONだけでは証明できない。`TrustedWindowsPowerShellRoute`は管理された呼出し条件でのみ意味を持つ。 |
| OS観測が短命プロセスや後続入力を取り逃す | OS観測とアプリ側イベントを別記録し、相関不能を`UNMATCHED`等で残す。 | `kit/sumi-guard-prototype/`、`tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1`、`docs/19` | ポーリングは短命プロセスを取り逃し得る。`write_stdin`による後続本文は現行フックで取得できない。常駐監視は未実装。 |
| ReadOnly表示が記録を変更する | ReadOnly派生モジュールは読取り用2関数だけを公開し、既存ロックを共有読取で開く。空ストアでロックを新規作成せず、本文を返さない。 | `tests/Invoke-ReadOnlyCliTests.ps1`、`docs/22`、`measurements/2026-10-05-readonly-lock-validation.md` | リポジトリ配置後の運用確認、全Windowsファイルシステム差異、管理者による変更耐性は未検証。 |
| メタデータログが無制限に増え、保存先の容量を圧迫する | 公開masterは3種NDJSONを各16MiBで判定し、超過を追記前に拒否して記録失敗として返す。削除・切詰め・自動ローテーションは行わない。 | `tests/Invoke-ExecutionAdapterMetadataLogLimitTests.ps1`（`8f46ad3`で検証）、[docs/27](docs/27-core-privacy-review-summary.md) | 上限到達後に記録を継続する手段はない。容量監視、退避、保管方針は運用側で別途必要。 |
| 本文削除とtombstone記録の不一致を成功と誤表示する | 公開masterの既存制御。本文削除後にretentionログへtombstoneを書けない場合を `RETENTION_CLEANUP_PARTIAL` とし、`retention_tombstone_failure_count` を残し、参照状態を `REFERENCE_MISSING` として扱う。成功へ格上げしない。 | `tests/Invoke-ExecutionAdapterMetadataLogLimitTests.ps1` の `retention_log_failure_is_partial_not_success`（候補 `8f46ad3` で追加した検証）、`docs/21` | 複数ファイル間の原子性はない。削除済み本文は復元できず、tombstone欠落の補正は手動確認に依存する。PR #10が追加したのは容量満杯時の検証であり、原子性そのものの改善ではない。 |
| GitHub CIを運用端末のセキュリティ証明と誤解する | workflowはPowerShell 5.1構文・BOM、PSScriptAnalyzer、DPAPI非依存の合成試験を実行し、DPAPI依存試験を明示的に除外する。 | `.github/workflows/windows-powershell-5.1-check.yml`、`.github/scripts/Invoke-SumiGuardCiTestSuite.ps1`、`docs/25` | CIに運用ストア、実資格情報、恒久フック、DPAPI CurrentUser、実ホストのdeny尊重を持ち込まない。secret scanning、Dependabot、private vulnerability reportingは確認時点で有効と確認できない。 |
| 外部監査基準に対する証拠の真正性を過大評価する | schema 1、ハッシュ、時刻、状態、相関の意味を記録するが、限界を文書化する。 | `docs/19`、`docs/21`、`docs/24` | 署名、鍵管理、失効、受領証、Audit Integrity、改ざん不能な外部保管はmasterにない。PR #2の提案や将来設計を実装済みと扱わない。 |

## 残余リスクの扱い

- 未確認の経路は、成功・安全・実行済みへ補完せず、未検証または評価不能として残す。
- 実運用に接続する前に、本文保存方針、運用ストアのACL、DPAPIユーザー境界、フック登録、通知失敗、復旧手順を固定の合成データで別途確認する。
- fail-closedが必要な場合は、既定MONITORを変更せず、[docs/26-enforce-recording-design.md](docs/26-enforce-recording-design.md)の未実装・未実測条件を満たしてから別の明示モードとして扱う。
