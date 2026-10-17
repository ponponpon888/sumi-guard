# Windows PowerShell 5.1 の継続的検査

`.github/workflows/windows-powershell-5.1-check.yml` は、GitHub Actions の `windows-latest`
上で Windows PowerShell 5.1 を使い、構文、文字コード、静的解析、合成入力だけの試験を実行する。
この検査はリポジトリ内のコードに対する機械的な点検であり、運用端末での動作検証ではない。

## この検査が言えること

- リポジトリ内のすべての `.ps1` / `.psm1` / `.psd1` が Windows PowerShell 5.1 のパーサーで
  構文解析できる（実行はしない）。
- 非ASCIIを含むスクリプトに UTF-8 BOM がある。5.1 は BOM のないファイルをアクティブな
  ANSI コードページで解釈するため、BOM が落ちると固定の日本語警告文が実行時に文字化けする。
- PSScriptAnalyzer が Error 深刻度の指摘を出さない。
- `SumiGuard.LocalStore` を読み込まない試験スクリプト11件が、クリーンな Windows ホストで
  成功を報告し、終了コード0で終わる。

## この検査が言えないこと

- DPAPI CurrentUser による本文保護の正しさ。該当試験は実行対象から除外している（下記）。
- 独立したOS観測、`DIRECT_MATCH`、感染判定、誤検知判定、自動遮断。いずれも未実装である。
- 運用端末での動作。GitHub ホストランナーは使い捨ての別ユーザープロファイルであり、
  ここでの結果は `measurements/` に残す測定記録の代わりにはならない。
- Warning 以下の深刻度の指摘がないこと。Error 以外は、下記の基準値を超えないことだけを
  失敗条件にしている。既存の指摘がなくなったことは意味しない。

緑になった実行は「上記の点検範囲で機械的な不一致が出なかった」という意味に限られる。
安全、無感染、完成のいずれも意味しない。

## ジョブ構成

| ジョブ | スクリプト | 失敗条件 |
|---|---|---|
| `syntax-and-encoding` | `.github/scripts/Invoke-SumiGuardSyntaxCheck.ps1` | 構文エラー、または非ASCIIかつBOMなし |
| `script-analyzer` | `.github/scripts/Invoke-SumiGuardAnalyzerCheck.ps1` | Error 深刻度の指摘が1件以上、またはルール別件数が基準値を超える |
| `dpapi-independent-tests` | `.github/scripts/Invoke-SumiGuardCiTestSuite.ps1` | 終了コード非0、JSON要約が読めない、または `success=false` |

各スクリプトは既存の試験スクリプトと同じ形式で、JSON要約を標準出力へ出し、失敗時に終了コード1
を返す。試験は親プロセスから `powershell.exe`（`System32\WindowsPowerShell\v1.0`）を明示指定して
子プロセスで実行するため、5.1 以外のホストで動くことはない。

試験ごとの引数は実行一覧に持つ。`Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` は
`-RunSyntheticTests` が無いと8ケースを実行せず `mode=idle` で終了コード0を返すため、この引数を
渡す。あわせて、同スクリプトが開始前にスナップショットを取る `.demo-data` はデモ実行で生成される
ものでリポジトリに無いため、ランナーが空のディレクトリを作って `-DemoDataPath` で渡し、実行後に
削除する。

## 静的解析の基準値

`.github/analyzer-baseline.json` に、リポジトリが現在抱えているルール別の件数を持つ。
検査は次を失敗とする。

- あるルールの件数が基準値を超えた
- 基準値ファイルに無いルールの指摘が出た

件数が基準値を下回った場合は失敗させず、`BELOW_BASELINE` として「基準値を下げられる」と
出力する。直したら同じコミットで数字を下げる、という運用にするためである。

件数が10件以下のルールは、ログ末尾に `ACTIONABLE FINDINGS` としてファイルと行番号つきで
もう一度出す。手を入れられる大きさのものだけを、ログ全体を取得せずに読めるようにするため
（しきい値は `-ActionableFindingLimit`、0で無効）。

Error 深刻度だけを失敗条件にすると、既存の Warning 99件・Information 101件はいくら増えても
通ってしまう。かといって一度に全部直すのは、判定内容を変えない保証が取れない。基準値を置けば、
今日のコストを0にしたまま、後退だけを止められる。

2026-10-17 時点の基準値（commit `64ddf6b`、PSScriptAnalyzer 1.25.0 の実測）は次のとおり。

| ルール | 件数 |
|---|---|
| `Information/PSAvoidUsingPositionalParameters` | 82 |
| `Warning/PSUseShouldProcessForStateChangingFunctions` | 36 |
| `Information/PSProvideCommentHelp` | 19 |
| `Warning/PSUseSingularNouns` | 16 |
| `Warning/PSAvoidAssignmentToAutomaticVariable` | 12 |
| `Warning/PSAvoidUsingWriteHost` | 0 |
| `Warning/PSReviewUnusedParameter` | 8 |
| `Warning/PSAvoidUsingEmptyCatchBlock` | 8 |
| `Warning/PSUseDeclaredVarsMoreThanAssignments` | 5 |
| `Warning/PSAvoidUsingCmdletAliases` | 0 |
| `Warning/PSUseApprovedVerbs` | 1 |

### 基準値が最初に止めたのはCI自身の変更だった

基準値を入れた直後の実行（`64ddf6b`）は
`ABOVE_BASELINE: Warning/PSAvoidUsingWriteHost: 12 findings, baseline 9` で失敗した。
ルール別集計と基準値比較を追加したときに、`.github/scripts/` のログ出力が3件増えていた。
`PSAvoidUsingWriteHost` の12件はすべて `.github/scripts/` の3本にあり、リポジトリ本体には無い。

これらのスクリプトは、人が読む行をCIログへ出し、標準出力にはJSON要約を流す。同じ標準出力へ
2種類の形式を混ぜないために `Write-Host` を使っているので、3本に
`SuppressMessageAttribute('PSAvoidUsingWriteHost', ...)` を付けて理由を残した。

同じ実行で `PSAvoidAssignmentToAutomaticVariable` は12件に下がった（基準値14）。`$input` の
代入が1行に2箇所あったためである。基準値は実測値へ下げた。

### 件数の少ないルールの指摘（2026-10-17、実行 39027315699）

`ACTIONABLE FINDINGS` で全24件の場所が取れた。分類は次のとおり。

#### 直したもの

- `kit/sumi-guard-real-hook-assessment-check/Invoke-SumiGuardRealHookAssessmentCheck.ps1:94`
  の `%`（`ForEach-Object` の別名）を正式名に変更した。意味は同じで、このファイルは
  ハッシュを記録した検証済みスクリプトではない。基準値を1から0へ下げた。

#### 判断が必要なもの（このPRでは触っていない）

| 箇所 | 内容 | なぜ判断が必要か |
|---|---|---|
| `kit/sumi-guard-prototype/process-observer.ps1:3,4` | `-RootPidFile` と `-OutputPath` が **Mandatory なのに本体で未参照** | 呼び出し側が必ず渡す値を無視している。出力先の指定が効いていない可能性がある。READMEにSHA-256を記録した検証済みスクリプトであり、変更すると測定記録との対応が切れる |
| `demo/Invoke-SumiGuardManagedAssessmentStoreDemo.ps1:58` | `$EmitJapaneseDisplay` が未参照 | 渡しても何も起きないスイッチである。実装するか削除するかは仕様の判断 |
| `kit/sumi-guard-protected-hook-test/sumi-guard-protected-hook.ps1:250` | `$bodySha256` を代入しているが読んでいない | 本文ハッシュを計算・取得して捨てている。このファイルは `measurements/2026-10-03-protected-hook-integration-test.md` と対応している |
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psm1:29` | 内部関数 `Throw-SumiGuardAssessmentStoreError` が非承認動詞 | 改名は呼び出し箇所をまたぐ。`New-` にして呼び出し側で `throw` する形が定石だが、保存層の変更になる |

#### 理由を付けて残すもの

- **空のcatch 8件**。`src/SumiGuard.AssessmentStore` の3件は、例外チェーンを辿る途中の
  非準拠な例外の読み飛ばし（50行）と、一時ファイル・バックアップの削除失敗（758、762行）で、
  いずれも後始末であり、保存の成否判定には影響しない。`demo/` の2件と
  `kit/sumi-guard-protected-hook-test/` の2件も後始末、`kit/sumi-guard-prototype/process-observer.ps1`
  の1件は検証済みスクリプトである。ただし「記録失敗を暗黙の成功にしない」という方針との
  整合は未判断で、基準値で増えないことだけ担保している
- **`$discard` 2件**（`kit/sumi-guard-protected-hook-test/invoke-sumi-guard-protected-hook-test.ps1:711`、
  `kit/sumi-guard-prototype/invoke-sumi-guard-prototype.ps1:631`）。出力の破棄であり、
  `$null =` が定石だが動作は同じ。後者は検証済みスクリプト
- **`$stderr` 2件**（`tests/Invoke-RealHookRunnerSyntheticTests.ps1:40,173`）。標準エラーを
  捕捉して判定に使っていない。判定を足すかは試験の仕様の判断
- **`$CallerInterpreterVerified`**（`src/SumiGuard.ManagedAssessmentVerification/SumiGuard.ManagedAssessmentVerification.psm1:25`）。
  **未使用であること自体が仕様である。** docs/24 の信頼境界が「上位層による言語宣言は根拠に
  できない」としており、`tests/Invoke-ManagedAssessmentVerificationTests.ps1` の
  `SELF_DECLARATION_NOT_TRUSTED` が `-CallerInterpreterVerified $true` を渡して、それでも
  `interpreter_verified` が false のままであることを確認している。削除すると「宣言が無視される
  こと」を試験できなくなる。理由を書いた `SuppressMessageAttribute` をコード側に付けて残し、
  基準値を9から8へ下げた。当初このPRでは「判断が必要」に分類していたが、呼び出し側を確認して
  誤りと分かったため訂正した
- **試験の未使用パラメーター4件**（`tests/Invoke-ManagedAssessmentVerificationConnectionTests.ps1:49`
  の `body`・`eid`・`verified`、`tests/Invoke-PowerShellCommandCliTests.ps1:33,42` の `Unused`）。
  差し替え用スクリプトブロックの引数と、意図して未使用にしている引数である

### 自動変数への代入のうち、実害があったもの

`kit/sumi-guard-hook-assessment-store-test/SumiGuard.HookAssessmentStoreAdapter.psm1` が、
解析したフック入力を `$input` に代入していた。`$input` は関数スコープのパイプライン列挙子で
あり、代入するとその関数のパイプライン入力が壊れる。現在この関数はパイプライン入力を
受けないため動いているが、受けるようにした時点で静かに壊れる種類の箇所である。
`$hookInput` に変更した。このモジュールは `tests/Invoke-HookAssessmentStoreAdapterTests.ps1`
がCIで実行するため、変更はCIで検証される。

残る `PSAvoidAssignmentToAutomaticVariable` は `$event` への代入である。`$event` が自動変数に
なるのはイベント購読スクリプトブロックの中だけで、通常のスコープでは実害が出ない。うち3件は
`kit/sumi-guard-prototype/` の検証済みスクリプト（READMEにSHA-256を記録している3本）にあり、
変更すればハッシュと測定記録の対応が切れる。隔離環境での再検証が必要になるため、この変更では
触っていない。

### 空のcatchブロック

8件ある。うち `kit/sumi-guard-prototype/process-observer.ps1` の1件は検証済みスクリプトであり
触っていない。残りは一時ファイルの削除失敗など後始末の箇所だが、「記録失敗を暗黙の成功に
しない」という設計方針と、どこまで整合させるかは未判断である。基準値に載せて、増えないことだけ
担保している。

## 実行対象から除外した試験

| 試験 | 理由 |
|---|---|
| `tests/Invoke-LocalStoreTests.ps1` | `SumiGuard.LocalStore` を読み込む。DPAPI CurrentUser の保護はランナーのユーザープロファイルに結び付くため、ここでの結果は運用端末と対応しない |
| `tests/Invoke-ExecutionAdapterIntegrationTests.ps1` | 同じ DPAPI CurrentUser 依存 |
| `tests/Invoke-ReadOnlyCliTests.ps1` | 同じ DPAPI CurrentUser 依存 |

除外一覧は `Invoke-SumiGuardCiTestSuite.ps1` 内に理由付きで持つ。`tests/` にあって
実行一覧・除外一覧のどちらにも無いファイルは `UNCLASSIFIED_TEST` として失敗させる。
試験を追加したとき、CIの対象外のまま気付かれないことを防ぐための失敗である。

## 失敗の種類

試験ランナーは次を区別する。

- `NONZERO_EXIT`: 試験が非0で終了した。
- `SUMMARY_UNPARSED`: 終了コード0だがJSON要約を読めなかった。要約を出さない変更の検出を意図する。
- `SUMMARY_FAILURE`: 終了コード0だが要約が `success=false` を報告した。
- `NO_SUCCESS_FIELD`: 終了コード0だが要約に、その試験の `success_property` が無い。1件も判定していない実行（idle、dry）を成功と数えないための失敗である。
- `UNCLASSIFIED_TEST`: 実行一覧・除外一覧のどちらにも無い試験ファイルがある。
- `MISSING_TEST`: 実行一覧にあるファイルが存在しない。

## 初回実行で見つかったもの

初回実行（commit `1024cbd`）で、既存試験2件が GitHub ホストランナーで失敗した。どちらも
CI側の不具合ではなく、作業端末の環境に依存していた箇所である。

- `tests/Invoke-HookAssessmentStoreAdapterTests.ps1` と
  `kit/sumi-guard-hook-assessment-store-test/SumiGuard.HookAssessmentStoreAdapter.psm1` が、
  リポジトリ位置を `C:\Dev\sumi-guard` と直書きしていた。`Import-Module` が
  `System.IO.FileNotFoundException` で失敗し、`failure_stage=INITIALIZATION` で終了コード1に
  なった。両方を `$PSScriptRoot` からの相対解決に変更した。作業端末の配置が
  `C:\Dev\sumi-guard` であれば解決結果は同じであり、試験内容と判定は変えていない。
  試験ファイルだけ直した2回目の実行（`c8957df`）でも同じ失敗が残り、モジュール側の
  直書きが分かった。
- `tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` は、存在しない
  `.demo-data` を開始前スナップショットで走査し、`stage=pre_snapshot` の
  `MethodInvocationException` で終了コード2になった。あわせて `-RunSyntheticTests` を
  渡していなかったため、仮に通っていても8ケースは実行されていなかった。試験側は変更せず、
  ランナーが引数で対応する。
- 同スクリプトの要約は全体の成否を `success` ではなく `synthetic_all_passed` で報告する。
  2回目の実行では `NO_SUCCESS_FIELD` で失敗したため、実行一覧に `success_property` を
  持たせ、試験ごとにどのプロパティを見るかを指定する形にした。

`kit/sumi-guard-real-hook-assessment-check/Invoke-SumiGuardRealHookAssessmentCheck.ps1` にも
同じ `C:\Dev\sumi-guard` の直書きがあり、こちらも `$PSScriptRoot` 相対へ変更した。ただし
このスクリプトは実フックとCodexを必要とするためCIでは実行していない。CIが確認したのは構文と
文字コードだけであり、**動作は運用端末での実行で確認する必要がある**。配置が
`C:\Dev\sumi-guard` であれば解決結果は同じである。

## 制約

- 試験ごとのタイムアウトは持たない。ハングはジョブの `timeout-minutes` で打ち切る。
- `actions/checkout` はタグ `v4` で参照している。コミットSHAでの固定は、確認したSHAを
  記録できる状態になってから別途行う。
- PSScriptAnalyzer はランナー上に無い場合だけ PowerShell Gallery から導入する。5.1 は既定で
  TLS 1.0 を提示しGalleryに拒否されるため、導入前に TLS 1.2 を明示している。
- publicリポジトリかつ標準ランナーのため、現在この検査に課金は発生しない。privateへ変更した
  場合、Windows ランナーは分単位2倍で課金対象になる。
- `push` と `pull_request` の両方で起動する。PRが開いている間のブランチへのpushは、同じ
  コミットに対して2回実行される。publicでは課金が無いためそのままにしている。forkからのPRを
  対象に残すための構成である。
- 初回の測定は `measurements/2026-10-17-ci-windows-powershell-check.md` にある。
