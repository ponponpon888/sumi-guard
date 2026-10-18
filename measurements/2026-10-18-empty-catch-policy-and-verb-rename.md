# 空のcatch方針の判断と、内部例外関数の改名の測定

docs/25 で未判断として残していた「空のcatchと『記録失敗を暗黙の成功にしない』方針の整合」を
判断し、違反3件を直した記録である。併せて内部例外関数を承認動詞へ改名した。GitHub Actions 上の
Windows PowerShell 5.1 での機械的点検であり、**運用端末での動作検証ではない**。

## 対象

| 項目 | 値 |
|---|---|
| コミット | `912514a` |
| ブランチ | `ci/windows-powershell-5.1-check` |
| 実行 | https://github.com/ponponpon888/sumi-guard/actions/runs/39178225176 |
| ランナー | GitHub ホスト `windows-latest` |
| ホスト | Windows PowerShell `5.1.26100.33438`、PSScriptAnalyzer 1.25.0 |
| 実行日時 | 2026-10-18 23:51:15Z 開始、23:51:58Z 終了（3ジョブ） |
| 結果 | 3ジョブすべて成功。DPAPI非依存の12試験すべて成功、除外3試験 |

## 空のcatch: 判断と実測

採用した規則は docs/25 に書いた。8件すべてを判定し、違反3件を直した。実測の件数は8件から
5件へ下がり、基準値を5へ下げた。残る5件の位置は実行ログの `ACTIONABLE FINDINGS` に出ている。

| 残った箇所 | 判断の根拠 |
|---|---|
| `kit\sumi-guard-protected-hook-test\sumi-guard-protected-hook.ps1:156` | 通知自体の書込み失敗。最後の記録経路であり内部に記録先が無い |
| `kit\sumi-guard-prototype\process-observer.ps1:186` | 保護プロセスの実行ファイル取得失敗。`null` として観測に残る。検証済みスクリプト |
| `src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psm1:63` | 例外チェーン走査。呼び出し側は既定コード付きの失敗を受け取る |
| `src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psm1:784` | `finally` の一時ファイル削除。失敗は既報告、残留は試験が確認 |
| `src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psm1:788` | `finally` のバックアップ削除。同上 |

直した3件のうち、CIが動作まで確認できるのは
`demo/Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1` の1件だけである。
`tests/Invoke-ManagedPowerShellAssessmentDemoTests.ps1` に追加した2判定（報告に
`child_process_stop_failed` が存在すること、通常経路で `false` であること）が成功した。
`demo/Start-SumiGuardDemo.ps1` と `kit/.../sumi-guard-protected-hook.ps1` は構文と解析器まで
しか確認していない。

## 改名: 判断と実測

`Throw-SumiGuardAssessmentStoreError` を `New-SumiGuardAssessmentStoreError` へ改名し、呼び出し
46箇所を `throw (New-... -Code 'X')` へ変更した。`PSUseApprovedVerbs` は1件から0件になり、
基準値を0へ下げた。保存層の失敗系は `tests/Invoke-AssessmentStoreTests.ps1` の13ケースが
確認しており、改名後も全ケース成功した。

## 途中で分かったこと: 抑止属性はルールの実名でしか効かない

改名で `New-` 動詞の関数が1つ増えるため、`PSUseShouldProcess` の抑止属性を先に付けておいた。
これは効かず、実行 39178106034（`7857502`）は
`ABOVE_BASELINE: Warning/PSUseShouldProcessForStateChangingFunctions: 37 findings, baseline 36`
で失敗した。短縮名ではなく実名 `PSUseShouldProcessForStateChangingFunctions` を書く必要がある。
実名へ直した次の実行で36件に戻り、基準値内に収まった。

基準値は、ルール名を一致させられないと「抑止したつもり」を静かに通さずに止める。これは
基準値ラチェットが自分の変更を止めた4度目である。

## 言えないこと

- `Start-SumiGuardDemo.ps1` の停止失敗経路と、キットのフックの通知経路は、実際に失敗を
  起こして確認していない。CIは構文と解析器までである
- `kit/.../sumi-guard-protected-hook.ps1` は `body_sha256` の追加に続く2度目の変更であり、
  `measurements/2026-10-03-protected-hook-integration-test.md` との対応は引き続き切れている。
  運用端末での再実行が必要である
- 残した5件の空のcatchは、規則に適合すると判断したものであり、失敗を起こして確認した
  わけではない

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psm1` | `3F3D6431DF5A1638B307A98F75E5F72456C9A0B984ACF6D367AAAEB310588AD8` |
| `demo/Invoke-SumiGuardManagedPowerShellAssessmentDemo.ps1` | `AC01552026C97067752387AD25D0172DCAC3EBA0ED79280FE4B8C68A60A139B5` |
| `demo/Start-SumiGuardDemo.ps1` | `E0E2F5F0345D7C167BA7B9B7A56E4904C0372ECB67E5D3A0E38E640E9A2258BA` |
| `kit/sumi-guard-protected-hook-test/sumi-guard-protected-hook.ps1` | `0477AAFF63F6B919B14DB016691AA4320C9AC4977BEF1233F1E0B7EF1126B800` |
| `tests/Invoke-ManagedPowerShellAssessmentDemoTests.ps1` | `8ED976153F4C947AB0B408B18AC4EE9432020962A0DFA46165E8450D93011E37` |
| `.github/analyzer-baseline.json` | `8D61C45538EBAD868E49A2EE058606609270ED92901560B9C5226231F40B6445` |
| `docs/25-ci-windows-powershell-check.md` | `BB0FD9DFA76A040C472AF94591D0C1B85AF30DABA587C5D1FC4E8A40ADD6800B` |
