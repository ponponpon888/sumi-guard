# Windows PowerShell 5.1 継続的検査の初回測定

GitHub Actions 上の機械的点検の記録である。運用端末での動作検証ではなく、DPAPI CurrentUser、
独立したOS観測、`DIRECT_MATCH`、感染判定、誤検知判定、自動遮断のいずれについても何も言わない。

## 対象

| 項目 | 値 |
|---|---|
| コミット | `857d91b` |
| ブランチ | `ci/windows-powershell-5.1-check` |
| 実行 | https://github.com/ponponpon888/sumi-guard/actions/runs/39022754876 |
| ランナー | GitHub ホスト `windows-latest` |
| ホスト | Windows PowerShell `5.1.26100.33438`（`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`） |
| チェックアウト先 | `D:\a\sumi-guard\sumi-guard` |
| 実行日時 | 2026-10-17 09:52:19Z 開始、09:53:04Z 終了（3ジョブ） |

3ジョブすべて成功。

## 構文と文字コード（`syntax-and-encoding`）

| 項目 | 値 |
|---|---|
| 解析ファイル数 | 50 |
| 指摘数 | 0 |
| スクリプト実行 | なし（`scripts_executed=false`） |

`.ps1` / `.psm1` / `.psd1` の全50ファイルが Windows PowerShell 5.1 のパーサーを通り、非ASCIIを
含むファイルの UTF-8 BOM 欠落も0件だった。パーサーに渡しただけで、実行はしていない。

## 静的解析（`script-analyzer`）

| 項目 | 値 |
|---|---|
| PSScriptAnalyzer | 1.25.0 |
| 失敗条件 | Error 深刻度 |
| Error | 0 |
| Warning | 95 |
| Information | 101 |
| 失敗対象 | 0 |

Warning と Information は出力するだけで失敗条件に入れていない。したがってこの実行は
「Error 深刻度が0件」までしか言わない。Warning 95件の内容（`PSUseSingularNouns`、
`PSAvoidAssignmentToAutomaticVariable`、`PSAvoidUsingPositionalParameters` など）は未対応である。

## DPAPI非依存の試験（`dpapi-independent-tests`）

実行11件、除外3件、失敗0件（`success=true`、`failures` は空）。11件すべて終了コード0かつ
要約が成功を報告した。

| 試験 | 終了コード | 要約の成否 |
|---|---|---|
| `Invoke-AssessmentStoreTests.ps1` | 0 | true |
| `Invoke-CommandAssessmentHookIntegrationTests.ps1` | 0 | true |
| `Invoke-CommandAssessmentTests.ps1` | 0 | true |
| `Invoke-HookAssessmentStoreAdapterTests.ps1` | 0 | true |
| `Invoke-ManagedAssessmentStoreDemoTests.ps1` | 0 | true |
| `Invoke-ManagedAssessmentVerificationConnectionTests.ps1` | 0 | true |
| `Invoke-ManagedAssessmentVerificationTests.ps1` | 0 | true |
| `Invoke-ManagedPowerShellAssessmentDemoTests.ps1` | 0 | true |
| `Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` | 0 | true（`synthetic_all_passed`） |
| `Invoke-PowerShellCommandCliTests.ps1` | 0 | true |
| `Invoke-RealHookRunnerSyntheticTests.ps1` | 0 | true |

`Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` は `-RunSyntheticTests` と、
ランナーが作る空ディレクトリへの `-DemoDataPath` を渡して実行した。`synthetic_all_passed` は
この実行経路にしか無いプロパティなので、8ケースが実行されたうえでの成功である。

除外した3件（`Invoke-LocalStoreTests.ps1`、`Invoke-ExecutionAdapterIntegrationTests.ps1`、
`Invoke-ReadOnlyCliTests.ps1`）は実行していない。この実行は3件について何も言わない。

## 緑までに見つかったもの

| 実行 | コミット | 結果 |
|---|---|---|
| 1回目 | `1024cbd` | 試験ジョブ失敗2件 |
| 2回目 | `c8957df` | 試験ジョブ失敗2件（内容は別） |
| 3回目 | `857d91b` | 3ジョブ成功 |

- `tests/Invoke-HookAssessmentStoreAdapterTests.ps1` と
  `kit/sumi-guard-hook-assessment-store-test/SumiGuard.HookAssessmentStoreAdapter.psm1` が
  リポジトリ位置を `C:\Dev\sumi-guard` と直書きしていた。作業端末のその配置以外では
  `Import-Module` が `System.IO.FileNotFoundException` で失敗する状態だった。
  両方を `$PSScriptRoot` 相対に変更した。1回目は試験側しか直さなかったため、2回目も同じ
  失敗が残った。
- `tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1` は、リポジトリに無い
  `.demo-data` を開始前スナップショットで走査して `stage=pre_snapshot` の
  `MethodInvocationException` を出していた。あわせて `-RunSyntheticTests` が無いと
  `mode=idle` で終了コード0になり、8ケースを実行せずに成功と見える状態だった。
- 同スクリプトの要約は全体の成否を `success` ではなく `synthetic_all_passed` で報告する。
  2回目はこれを `NO_SUCCESS_FIELD` として検出した。実行一覧に `success_property` を持たせた。

試験の判定内容は変更していない。変更したのはリポジトリ位置の解決方法と、ランナーが渡す引数、
およびCI側の判定である。

## この測定が言えないこと

- 運用端末での動作。ランナーは使い捨ての別ユーザープロファイルである。
- DPAPI CurrentUser による本文保護の正しさ。該当3件は実行していない。
- `DIRECT_MATCH`、常駐監視、感染判定、誤検知判定、自動遮断。いずれも未実装である。
- Warning 以下の深刻度の指摘がないこと。95件と101件が残っている。
