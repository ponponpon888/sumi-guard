# SUMI Guard Security

## 対象範囲と現在の状態

この文書の対象は、公開リポジトリ `ponponpon888/sumi-guard` の確認済み
`master`コミット `3db6ab022548e080c04a4f568f685fe6b37f380b` です。

- Release tag、安定版番号、長期サポート契約は確認できません。
- 実装・検証対象のホストは Windows PowerShell 5.1 です。既存workflowは5.1の構文、UTF-8 BOM、PSScriptAnalyzer、DPAPIに依存しない合成試験を確認します。
- `SumiGuard.LocalStore` は Windows DPAPI `CurrentUser` とWindows ACLに依存します。DPAPI依存試験はGitHub CIでは実行されず、運用端末と同じユーザー境界で別途確認が必要です。
- PR #8、#9、#10はmasterへマージ済みです。PR #5、#6、#7の変更はPR #8経由で取り込み済みです。PR #2の署名・受領証・監査整合性は含みません。

公開masterでは次の制御を実装しています。これはRelease、恒久フック登録、実運用接続の完了を意味しません。

- MONITORフックの既定MetadataOnly（本文保存は `-CaptureCommandBody` の明示指定時だけ）。直接アダプタ呼出し `Save-SumiGuardExecutionIntent` の `-MetadataOnly` は既定offのままで、従来の本文保存契約が適用されます。この2つを同じ既定として扱いません。
- AssessmentStoreの不正ACL拒否（自動修復なし）、CIの`push`をmasterだけにする条件。
- ReadOnly派生モジュールの公開関数を読取り用2件（`Get-SumiGuardExecutionRecord`、`Get-SumiGuardCollectionFailureNotice`）へ限定。公開一覧の制限であり、内部関数の実行不能やOS権限境界を主張するものではありません。
- `events.ndjson`、`failures.ndjson`、`retention.ndjson` の3種類それぞれに16MiBの上限。上限ちょうどは許可、超過は追記前に拒否し、容量超過で削除・切詰め・自動ローテーションは行いません。上限到達後は記録失敗を返し続け、暗黙の成功へ格下げしません。

保持期間清掃の本文削除とtombstone記録が原子的でないことは、今回追加した制限ではなく公開masterの既存の性質です。本文削除後にtombstoneを書けない場合は `RETENTION_CLEANUP_PARTIAL` となり、参照状態は `REFERENCE_MISSING` になり得ます。PR #10が追加したのは、retentionログが容量上限に達した場合にこの区別が保たれることの検証であり、原子性そのものの改善ではありません。

実装の対象SHA、証拠が属するSHA、マージ記録、戻し方は [docs/27-core-privacy-review-summary.md](docs/27-core-privacy-review-summary.md) を参照してください。

SUMI Guardはローカル優先の監査試作です。実行前入力、評価結果、OS観測は別の証拠です。実行前入力の記録は実行済みの証明ではなく、`NO_DETECTION` は安全・無感染・完全捕捉の保証ではありません。

## 脆弱性の報告窓口

確認時点で、GitHub APIのリポジトリ設定に `private_vulnerability_reporting` の有効状態は表示されませんでした。同じ確認で `secret_scanning` と `dependabot_security_updates` は `disabled` でした。GitHubのprivate vulnerability reportingが有効であること、または別の非公開報告窓口が提供されていることを確認できないため、**現在、有効な非公開報告窓口は本リポジトリから案内できません**。

この文書はメールアドレス、応答期限、修正期限、サポート保証を新たに設定するものではありません。非公開窓口が有効化・明示された場合は、実際の設定と導線を確認したうえでこの文書を更新します。

### 報告時の禁止事項

公開Issue、公開PR、公開コメントへ、次の情報を貼らないでください。

- パスワード、APIキー、アクセストークン、秘密鍵、Cookie、資格情報
- 実運用の本文、実ログ、個人情報、顧客情報、内部ホスト名
- 復号済み本文、標準出力・標準エラーの生データ、運用ストアのコピー

報告可能な非機密の準備物は、対象コミット、影響するファイル、再現条件、影響の説明、修正前後の安全な期待結果、秘密を含まない合成データです。ログが必要な場合は、固定の架空文字列へ置き換え、元ログを添付しないでください。

非公開の報告経路が明示されるまでは、公開の場への脆弱性詳細の投稿を避け、リポジトリ管理者が非公開窓口を用意したことを確認してから送付してください。この文書は報告の受領や応答を保証しません。

## 現在確認できる防御と限界

- MONITORフックは失敗しても通常はdenyへ変換せず、固定コードの状態を返します。これは可用性を優先する既定であり、記録の完全性や安全を保証しません。
- 本文を保存する経路では、LocalStoreがDPAPI CurrentUserで保護し、保存先のACLとreparse pointを検査します。暗号化後の本文は呼出し元プロセスのメモリに存在し、同一Windowsユーザーの別プロセス、管理者、侵害済みユーザーセッションには対抗できません。
- 通常の評価結果は対応ルールの範囲だけです。外部コンテンツ、未確認のインタープリター、動的生成、短命プロセス、後続 `write_stdin` 入力を完全には扱いません。
- GitHub CIは構文・文字コード・静的解析・DPAPI非依存の合成試験を確認します。運用ストア、実資格情報、恒久フック、DPAPI CurrentUserの運用境界、外部監査基準への適合はCIの合格から導けません。

脅威、制御、試験、残余リスクの対応は [THREAT_MODEL.md](THREAT_MODEL.md) を参照してください。変更を提案する場合は [CONTRIBUTING.md](CONTRIBUTING.md) の隔離条件に従ってください。
