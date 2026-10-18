# SUMI Guard

SUMI Guardは、アプリ側の実行前イベントと独立したOSプロセス観測を分けて記録し、両者の対応を
評価するためのローカル監視試作です。

## 現在の状態

現在は、無害な固定入力だけで検証した監視試作です。通常実行、後続標準入力、MONITORモードでの
保存失敗という既存3ケースを検証し、アプリ記録とOS記録の `INFERRED_MATCH` まで確認済みです。
フックイベントに対象PIDがないため、`DIRECT_MATCH` を確認したものではありません。

別の固定入力1件では、実際のCodex `PreToolUse` からExecutionAdapterとLocalStoreへ接続し、本文の
暗号化保存、明示復号、独立したOS観測、別イベントの実行結果までを `INFERRED_MATCH` で確認しました。
これは使い捨て子Codexセッションだけの接続試験であり、通常運用への接続ではありません。

次の制約があります。

- 起動後に `write_stdin` で渡される後続標準入力の本文は取得できません。
- OS観測はポーリング方式であり、短命なプロセスを取り逃す可能性があります。
- 常駐監視、感染判定、誤検知判定、自動遮断は未実装です。
- 現在の結果は固定入力による試作検証であり、一般のコマンドや実データに対する完全性を保証しません。

## セキュリティ強化ブランチ（2026-10-18、PRレビュー前）

このブランチでは、評価ストアのACLをCurrentUserとSYSTEMへ制限し、既存の弱い
ACLを暗黙に書き換えず `STORE_ACL_INVALID` で拒否します。
ローカルの既存評価ストアがある場合は、バックアップとACLの確認を行ったうえで別途
移行手順を実施してください。自動移行はありません。

運用MONITORフックは、コマンドに機密情報が混在する可能性を考慮して、
**既定ではハッシュと状態だけを保存し、コマンド本文をディスクに保存しません**。
本当に必要な隔離経路だけ `-CaptureCommandBody` を明示して暗号化本文を記録します。
これは既存の実行アダプタを直接呼ぶ場合の従来動作とは異なります。

実行メタデータはNDJSONファイル1件あたり16MiBで追記を拒否し、暗黙の削除や
ローテーションは行いません。ReadOnly派生モジュールの外部公開APIは一覧と
失敗通知の2関数に限定しました。既定MONITORは引き続き**警告のみ・自動遮断なし**です。

このブランチには使い捨てGitHub WindowsホストのDPAPIスモーク試験を追加していますが、運用PCでのDPAPI統合試験は未実施です。権限変更、シークレットの
自動検知、OS全体の監視、侵害の自動遮断を保証するものではありません。
詳細は `docs/27-security-hardening-20261018.md` を参照してください。

## 署名されたチェックポイントの有効期限・巻き戻し確認

署名検証ツールに、署名済みポリシーの連番と有効期間を検証する
**オプション機能**を追加しました。基準値とポリシーの両方を
独立環境で署名し、PCに渡すのは公開鍵・署名・ポリシーだけです。

最小連番（巻き戻し判定の下限）と現在時刻は**別の信頼できる経路から入力**し、
不足した場合は検証を拒否します。ローカルPCの時計や任意に変更できる
設定値だけでは、巻き戻し防止の保証にはなりません。
`docs/30-signed-checkpoint-freshness.md` に詳細を記載しました。

## 署名された監査チェックポイントの検証

`tools/Test-SumiGuardSignedCheckpoint.ps1` は、別の信頼環境で署名された
監査チェックポイントのRSA署名と公開鍵指紋を確認してから、現在の監査ログと
照合する読取り専用CLIです。監視PCで秘密鍵を使用せず、既存ログを変更しません。
使い捨てテスト鍵を使用する合成テストは
`tests/Invoke-SignedCheckpointTests.ps1`、運用前の制限事項は
`docs/29-signed-audit-checkpoint.md` を参照してください。

## 監査ログの読取り専用整合性確認

`tools/Test-SumiGuardAuditIntegrity.ps1` は、Execution/Assessmentストアの
既知の監査メタデータを**書き換えず**に構造検査し、ファイルごとのSHA-256を計算します。
`Snapshot` は未認証の基準値候補を表示するだけであり、改ざんがないという証明ではありません。
`Compare` は監査ストア**外の信頼できる基準値**との一致・不一致を確認します。
予期せぬ変更と正規の追記は区別できません。暗号化本文やOS全体の安全性は検証しません。
詳細は `docs/28-audit-integrity-readonly.md` を参照してください。

## 構成

- `kit/sumi-guard-prototype/`: 検証済みPowerShell 5.1スクリプトと使用方法
- `kit/sumi-guard-protected-hook-test/`: 実フックと暗号化保存を結ぶ一回限りの接続試験
- `demo/`: 固定入力を開始・確認・清掃する手動デモ
- `src/SumiGuard.LocalStore/`: 独立したDPAPI CurrentUserローカル保存モジュール
- `src/SumiGuard.ExecutionAdapter/`: 実行前イベントと暗号化本文を `execution_id` で結ぶ接続モジュール
- `tests/Invoke-LocalStoreTests.ps1`: ローカル保存モジュールの単体試験
- `tests/Invoke-ExecutionAdapterIntegrationTests.ps1`: 合成イベントだけを使う接続統合試験
- `hooks/Invoke-SumiGuardMonitorHook.ps1`: Codex PreToolUse を保存前に評価し、評価結果だけを別保存する運用フック（MONITOR、denyしない）
- `tests/Invoke-MonitorHookSyntheticTests.ps1`: 運用フックの合成試験。固定文字列だけを渡し、本文保存の実経路は置き換える
- `tools/Show-SumiGuardRecords.ps1`: 本文を復号しない保存済み記録の読み取り専用CLI
- `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.ReadOnly.psm1`: 既存ロックを共有読取りで開くReadOnly派生モジュール
- `tools/Show-SumiGuardRecords.ReadOnly.ps1`: ReadOnly派生モジュールを明示使用するCLI
- `demo/Show-SumiGuardDemo.ReadOnly.ps1`: ReadOnly CLIを使うデモ表示
- `tests/Invoke-ReadOnlyCliTests.ps1`: 読み取り専用CLIの合成データ試験
- `tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1`: 無害な子プロセス8ケースで、出力の捕捉・JSON読取り・事後照合の分岐と理由を判定する合成試験
- `docs/19-sumi-guard-execution-audit.md`: 設計書
- `docs/20-local-store.md`: 保存形式、容量、保持、制約
- `docs/21-execution-localstore-adapter.md`: 接続API、状態、失敗時の扱い
- `docs/22-read-only-cli.md`: 読み取り専用CLIの操作、状態、相関、制約
- `.github/workflows/windows-powershell-5.1-check.yml`: Windows PowerShell 5.1 での構文・文字コード・静的解析・合成入力試験の継続的検査
- `.github/scripts/Invoke-SumiGuardSyntaxCheck.ps1`: 全PowerShellファイルを実行せず構文解析し、非ASCIIのBOM欠落を検出する検査
- `.github/scripts/Invoke-SumiGuardAnalyzerCheck.ps1`: PSScriptAnalyzer をError深刻度と、ルール別の基準値超えで失敗させる検査
- `.github/analyzer-baseline.json`: 現在抱えているルール別件数の基準値。超えたら失敗、下回ったら下げる
- `.github/scripts/Invoke-SumiGuardCiTestSuite.ps1`: DPAPI非依存の試験だけを実行し、除外理由を保持するランナー
- `docs/25-ci-windows-powershell-check.md`: 継続的検査の範囲、言えないこと、除外した試験と理由
- `docs/26-enforce-recording-design.md`: 記録失敗時に実行を拒否する強制モードの設計（未実装、既定は MONITOR）
- `docs/28-audit-integrity-readonly.md`: 監査ログの読取り専用構造検証・基準値照合と限界
- `docs/29-signed-audit-checkpoint.md`: 認証された監査チェックポイントの仕様と限界
- `docs/30-signed-checkpoint-freshness.md`: 署名付き連番・有効期間・信頼できる時刻/下限の要件
- `tools/Test-SumiGuardSignedCheckpoint.ps1`: 公開鍵指紋・RSA署名・監査ログの整合性照合
- `tests/Invoke-SignedCheckpointTests.ps1`: 使い捨てRSA鍵を使った合成回帰テスト
- `tools/Test-SumiGuardAuditIntegrity.ps1`: 監査ログを変更しない照合CLI
- `tests/Invoke-AuditIntegrityTests.ps1`: 合成ログの改ざん・欠損・重複回帰テスト
- `measurements/2026-10-17-ci-windows-powershell-check.md`: 継続的検査の初回測定結果
- `measurements/2026-10-17-monitor-hook-synthetic-tests.md`: 運用MONITORフックの合成試験結果（本文保存の実経路は未検証）
- `measurements/2026-10-03-sumi-guard-prototype.md`: 最小試作の測定結果
- `measurements/2026-10-03-sumi-guard-final-code-correspondence.md`: 最終コードと測定結果の対応確認
- `measurements/2026-10-03-local-store-module-tests.md`: 保存モジュールの単体試験結果
- `measurements/2026-10-03-execution-localstore-integration-tests.md`: 接続統合試験と最終ハッシュ
- `measurements/2026-10-03-protected-hook-integration-test.md`: 実フック・暗号化保存・OS観測の測定結果
- `measurements/2026-10-03-read-only-cli-tests.md`: 読み取り専用CLIの合成試験と不変性確認
- `measurements/2026-10-04-manual-demo.md`: 手動デモの実フック実行とCLI表示結果

実行方法と隔離条件は `kit/sumi-guard-prototype/README.md` を参照してください。同じ試験の再実行は、
コード変更後の対応確認など明確な必要性がある場合に限ります。

## 検証済みスクリプト

| ファイル | SHA-256 |
|---|---|
| `sumi-guard-hook.ps1` | `716009de6b2d7cf23e7cf8da227f5492b8a2c417da86b507306ee85d91ed51ec` |
| `process-observer.ps1` | `5b4509a2829b1b3d0c5ac17f47350c4238fed40474acf48c11cca9839b36d227` |
| `invoke-sumi-guard-prototype.ps1` | `f2510e810aa925a800c51f7666679c4644f25683e0cbf8d40eb568357340a9c2` |

これらの値は最終対応確認レポートと一致しています。スクリプトを変更した場合は、構文検査だけでなく
隔離した動作検証を行い、新しい測定結果とハッシュの対応を残す必要があります。

## ローカル保存モジュール

ローカル保存の保護、容量上限、明示的な保持期間清掃を、既存3スクリプトへ接続しない独立モジュール
として実装しています。常駐化、UI、AI分析、感染判定、自動遮断、`DIRECT_MATCH` 化は含みません。

```powershell
Import-Module .\src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1

$store = Initialize-SumiGuardLocalStore -Path "$env:LOCALAPPDATA\SUMI Guard\body-store"
$saved = Save-SumiGuardBody -StorePath $store.store_path -Body '架空の試験本文'
$loaded = Get-SumiGuardBody -StorePath $store.store_path -BodyId $saved.body_id

# 明示的に実行した場合だけ、既定30日を超えた管理対象本文を削除する
Remove-SumiGuardExpiredBody -StorePath $store.store_path -Confirm:$false
```

本文はDPAPI CurrentUserで暗号化され、平文へのフォールバックは行いません。保存先ACLは対象ユーザーと
SYSTEMのみに限定します。1件上限は暗号化前UTF-8本文の1MiB、合計上限は暗号化コンテナの実保存量
250MiB、保持期間は30日です。

DPAPI CurrentUserとユーザーACLは、別ユーザーからの通常アクセスを制限するためのものです。同じ
ユーザー権限で動く別プロセス、管理者、侵害済みユーザーセッションからの読み取り・改変・削除は
防止できません。復号後の本文は呼び出し元プロセスのメモリに存在します。

## 実行記録との接続

`SumiGuard.ExecutionAdapter` は、合成した実行前イベントの `execution_id`、本文SHA-256、取得状態、
LocalStoreの本文参照だけを平文メタデータへ保存します。本文保存が完了してからイベントを書き、
容量超過や暗号化失敗でもMONITOR動作を継続して `COLLECTION_FAILED` を記録します。通常の一覧APIは
本文を返さず、`Read-SumiGuardExecutionBody` を明示的に呼び出した場合だけ復号します。

合成イベントでの8件の統合試験に加え、一回限りの子Codexセッションと固定入力1件で実フック接続を
確認済みです。新しい試験は検証済みOS観測器をそのまま再利用しましたが、既存3スクリプト自体は
変更していません。通常のCodexセッション、実際の開発内容、常駐監視には接続していません。

## 保存済み記録の確認

読み取り専用CLIは、一覧、本文を表示しない詳細、保存状態を日本語で表示します。保存済み本文は
復号せず、起動時の清掃や修復も行いません。表示はSUMI Guard自身が取得した範囲に限られ、PC全体の
安全判定ではありません。

```powershell
# 一覧
.\tools\Show-SumiGuardRecords.ps1 -Action List `
  -ExecutionStorePath $executionStore -LocalStorePath $localStore

# 詳細（本文は表示しない）
.\tools\Show-SumiGuardRecords.ps1 -Action Detail `
  -ExecutionStorePath $executionStore -LocalStorePath $localStore `
  -ExecutionId $executionId -OsObservationPath $observationPath

# 使用容量、上限、保持期間、参照切れ等
.\tools\Show-SumiGuardRecords.ps1 -Action StoreStatus `
  -ExecutionStorePath $executionStore -LocalStorePath $localStore
```

公開APIがロックファイルを新規作成する動作を持つため、まだロックがない空ストアではファイルを
作成しない読取専用フォールバックを使います。詳細は `docs/22-read-only-cli.md` を参照してください。

検証済みReadOnly派生版は、メタデータ読取り時に既存ロックを `Open / Read / FileShare.Read` で開き、
共有違反だけを上限付きで再試行します。読取り同士は共存し、既存の書込みロックとは相互排他です。
ロックが存在しない場合は作成せず、メタデータへ直接迂回せず固定の読取り失敗とします。既存通常版の
ファイルと動作は変更していません。

```powershell
# 一覧
.\tools\Show-SumiGuardRecords.ReadOnly.ps1 -Action List `
  -ExecutionStorePath $executionStore -LocalStorePath $localStore

# 検証済みデモ記録の表示（一覧 → 詳細 → 保存状態）
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Show-SumiGuardDemo.ReadOnly.ps1
```

ReadOnly派生版は一時プロジェクトでロック5項目、合成9ケース、実表示の全条件を確認済みです。
本プロジェクトへ配置した後の実行確認はまだ行っていません。正式相関は `UNMATCHED` のままで、
元のアクセス拒否原因と子Codex標準エラーが非空だった原因も未確定です。詳細と候補SHA-256は
`measurements/2026-10-05-readonly-lock-validation.md` を参照してください。

## 手動デモ

次のコマンドは、固定の無害な入力1件をデモ専用保存先へ記録し、読み取り専用CLIで
「一覧 → 詳細 → 保存状態」の順に表示します。未定義変数や `execution_id` の手入力は不要です。

```powershell
Set-Location 'C:\Dev\sumi-guard'

# 開始
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Start-SumiGuardDemo.ps1

# 確認
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Show-SumiGuardDemo.ps1

# 清掃
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Clear-SumiGuardDemo.ps1 -ConfirmDemoRemoval
```

保存先は `.demo-data` で、Git管理対象外です。開始時に既存デモを上書きせず、再実行には先行する
明示清掃が必要です。暗号化本文は開始・確認のどちらでも復号・表示しません。子Codex限定の一時
フック設定と一時プロジェクトは終了時に削除します。詳細は `demo/README.md` を参照してください。

### 1. ローカル保存の保護

- 保存対象を伏せ字後のイベント、失敗通知、必要なメタデータに限定する。
- 保存ディレクトリとファイルのWindowsアクセス権を定義し、他ユーザーからの読み取りを制限する。
- 本モジュールへ明示的に渡された本文だけをDPAPI CurrentUserで暗号化する。
- 認証情報やトークンをログへ書かないことを、書き込み前の検査と失敗状態で確認する。

### 2. 容量上限

- 1件の暗号化前UTF-8本文と、暗号化コンテナの合計実保存量に上限を設定する。
- 上限接近と上限到達を区別し、本文を含まない状態通知を残す。
- 上限到達時に暗黙の成功や `NO_RECORD` とせず、保存不能を `COLLECTION_FAILED` として扱う。
- 削除またはローテーションの対象順序と、保護対象から除外する記録を事前に定義する。

### 3. 保持期間

- コンテナヘッダーの保存時刻を起算点とし、初期値を30日にする。
- 期限切れ記録の削除手順を、実行中ファイルや整合取得中のデータと競合しない形で設計する。
- 削除件数、失敗、残存容量だけを記録し、削除対象の秘密情報を通知へ複製しない。
- 定期実行は登録せず、`Remove-SumiGuardExpiredBody` の明示呼び出しだけで清掃する。

## PowerShell source assessment only

The following command parses explicitly supplied Windows PowerShell 5.1 source in memory. It does not execute or save the source, and it does not verify an execution host.

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File .\tools\Test-SumiGuardPowerShellCommand.ps1 -CommandText 'Get-ScheduledTask'
```

Exit code `0` means evaluation completed; `2` means evaluator failure; `3` means CLI internal failure. A completed `NO_DETECTION` result means only “no match within the supported rules,” not safe.

The assessment-only CLI never executes or saves `CommandText`. It labels declared Windows PowerShell 5.1 source separately from a verified execution interpreter. It omits a whole-assessment reason when no fixed reason code exists; detected findings still show their rule ID, severity, and fixed Japanese explanation.

The CLI displays Japanese fixed warnings for detected rules, but never prints the supplied source. It is assessment-only and does not establish that any execution interpreter was verified.
