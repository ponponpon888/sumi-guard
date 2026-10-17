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
- Warning 以下の深刻度の指摘がないこと。現在は Error だけを失敗条件にしており、
  Warning と Information は件数と内容を出力するだけである。

緑になった実行は「上記の点検範囲で機械的な不一致が出なかった」という意味に限られる。
安全、無感染、完成のいずれも意味しない。

## ジョブ構成

| ジョブ | スクリプト | 失敗条件 |
|---|---|---|
| `syntax-and-encoding` | `.github/scripts/Invoke-SumiGuardSyntaxCheck.ps1` | 構文エラー、または非ASCIIかつBOMなし |
| `script-analyzer` | `.github/scripts/Invoke-SumiGuardAnalyzerCheck.ps1` | Error 深刻度の指摘が1件以上 |
| `dpapi-independent-tests` | `.github/scripts/Invoke-SumiGuardCiTestSuite.ps1` | 終了コード非0、JSON要約が読めない、または `success=false` |

各スクリプトは既存の試験スクリプトと同じ形式で、JSON要約を標準出力へ出し、失敗時に終了コード1
を返す。試験は親プロセスから `powershell.exe`（`System32\WindowsPowerShell\v1.0`）を明示指定して
子プロセスで実行するため、5.1 以外のホストで動くことはない。

試験ごとの引数は実行一覧に持つ。`Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` は
`-RunSyntheticTests` が無いと8ケースを実行せず `mode=idle` で終了コード0を返すため、この引数を
渡す。あわせて、同スクリプトが開始前にスナップショットを取る `.demo-data` はデモ実行で生成される
ものでリポジトリに無いため、ランナーが空のディレクトリを作って `-DemoDataPath` で渡し、実行後に
削除する。

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
同じ `C:\Dev\sumi-guard` の直書きが残っている。このスクリプトはCIの対象外（実フックとCodexを
必要とする）ため、この変更では触っていない。

## 制約

- 試験ごとのタイムアウトは持たない。ハングはジョブの `timeout-minutes` で打ち切る。
- `actions/checkout` はタグ `v4` で参照している。コミットSHAでの固定は、確認したSHAを
  記録できる状態になってから別途行う。
- PSScriptAnalyzer はランナー上に無い場合だけ PowerShell Gallery から導入する。5.1 は既定で
  TLS 1.0 を提示しGalleryに拒否されるため、導入前に TLS 1.2 を明示している。
- publicリポジトリかつ標準ランナーのため、現在この検査に課金は発生しない。privateへ変更した
  場合、Windows ランナーは分単位2倍で課金対象になる。
