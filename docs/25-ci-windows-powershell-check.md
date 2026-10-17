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
- `UNCLASSIFIED_TEST`: 実行一覧・除外一覧のどちらにも無い試験ファイルがある。
- `MISSING_TEST`: 実行一覧にあるファイルが存在しない。

## 制約

- 試験ごとのタイムアウトは持たない。ハングはジョブの `timeout-minutes` で打ち切る。
- `actions/checkout` はタグ `v4` で参照している。コミットSHAでの固定は、確認したSHAを
  記録できる状態になってから別途行う。
- PSScriptAnalyzer はランナー上に無い場合だけ PowerShell Gallery から導入する。5.1 は既定で
  TLS 1.0 を提示しGalleryに拒否されるため、導入前に TLS 1.2 を明示している。
- publicリポジトリかつ標準ランナーのため、現在この検査に課金は発生しない。privateへ変更した
  場合、Windows ランナーは分単位2倍で課金対象になる。
