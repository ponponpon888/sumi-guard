# フック記録の `evaluation_origin` 追加の測定

`SumiGuard.AssessmentStore` の `evaluation_origin` に `CODEX_PRETOOLUSE_HOOK` を追加し、
運用MONITORフックの既定値をこの値へ変更した変更の記録である。GitHub Actions 上の
Windows PowerShell 5.1 での機械的点検であり、**運用端末での動作検証ではない**。DPAPI
CurrentUser による本文保護、実フック経由の動作、独立したOS観測については何も言わない。

## 対象

| 項目 | 値 |
|---|---|
| コミット | `96143c3` |
| ブランチ | `ci/windows-powershell-5.1-check` |
| 実行 | https://github.com/ponponpon888/sumi-guard/actions/runs/39034865828 |
| ランナー | GitHub ホスト `windows-latest` |
| ホスト | Windows PowerShell `5.1.26100.33438` |
| 実行日時 | 2026-10-17 13:01:34Z 開始、13:02:21Z 終了（3ジョブ） |
| 結果 | 3ジョブすべて成功（`syntax-and-encoding` / `dpapi-independent-tests` / `script-analyzer`） |

DPAPI非依存の12試験はすべて `reported_success=true`、除外は従来どおり3試験である。

## 確認できたこと

`tests/Invoke-AssessmentStoreTests.ps1`（13ケース、追加2ケース）で次が成立した。

- `CODEX_PRETOOLUSE_HOOK` と関連実行IDを指定した保存が成功し、読み戻した記録の
  `evaluation_origin` と `execution_id` が指定どおりである
- 同一ストア内で、`CODEX_PRETOOLUSE_HOOK` の記録が1件、`MANAGED_EXECUTION` の記録が1件として
  数えられる。つまり両者は保存後も区別できる
- 関連実行IDを与えない `CODEX_PRETOOLUSE_HOOK` の保存は `INVALID_ASSESSMENT` で拒否され、
  レコード件数は増えない
- 表示は、フック記録を「種別: フック経由の実行前評価」および
  「実行されたかどうかは、この記録では確認できません」と出し、`説明未定義` を出さない。
  管理下実行の記録の表示は「種別: 管理下実行の評価」のままで、フックのラベルは混ざらない
- `SYNTHETIC_TEST` の既存条件（関連実行IDを持ってはならない、試験データと明示表示する）は
  変更していない

`tests/Invoke-MonitorHookSyntheticTests.ps1`（21判定、追加1判定）で次が成立した。

- 信頼経路で検知したときに保存された記録の本文に
  `"evaluation_origin":"CODEX_PRETOOLUSE_HOOK"` が含まれ、`MANAGED_EXECUTION` は含まれない。
  フック自身の報告ではなく、保存された記録の側で区別できることを確認した

## 言えないこと

- 実運用のCodexフックから起動したときに同じ記録が残るかは未検証である（恒久登録していない）
- 本文保存の実経路（DPAPI CurrentUser）は実行していない。合成試験は
  `-TestIntentSaveOutcome` で `SumiGuard.ExecutionAdapter` の呼出しを置き換えている
- `Invoke-ReadOnlyCliTests.ps1` は DPAPI 依存のため除外されている。ReadOnly派生版の表示に
  ついては、この測定では何も言わない

## 途中で判明した、試験側の欠陥（2件）

1件目はCIの観測性である。最初の実行（`5c110cf`、実行 39034511447）では
`Invoke-AssessmentStoreTests.ps1` が12件中1件失敗したが、CIの失敗行には
`[test_count=12 passed_count=11]` しか出ず、どのケースのどの判定が落ちたのかが出なかった。
失敗ケースを列挙する関数が `results` という名前の配列だけを見ており、この試験の要約は
`tests` という名前で出していたためである。`results` / `tests` / `cases` のいずれでも
列挙するようにした。

2件目は試験の順序依存である。`ATOMIC_SAVE_FAILURE_PRESERVES_STORE` は、起動時に取得した
保存モジュールの実体へ試験用フラグを設定して原子的書込みの失敗を強制していた。表示CLIは
保存モジュールを `-Force` で再読込するため、表示を呼ぶケースが先に走ると実体が置き換わり、
古い実体へ設定したフラグは効かない。強制失敗が起きないまま保存が成功し、「ストアが保全された」
という結論だけが崩れる。表示を呼ぶケースが追加順の後ろにある限り見えない依存であった。
モジュール実体をケース内で取得する形に直し、評価表示の判定は既存の表示ケース群の隣へ移した。

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psm1` | `FBD604B01576CF0E9FA019167FF3AAB0B08D780CD5FF5069DF9CC68036E46132` |
| `hooks/Invoke-SumiGuardMonitorHook.ps1` | `8830D19D0E87FB63BBF59BF94B2F7DD01BC0167948F9E5D6E31812C1F51E7560` |
| `tools/Show-SumiGuardAssessments.ps1` | `044159B53C95F36CB40507113AE5F19392769D0CC9C03809FE5654C805D6EF8F` |
| `tests/Invoke-AssessmentStoreTests.ps1` | `48747347917DD7263B7207B4E28B71DC2EDAEBAF4C7659113CAD86A8508669F7` |
| `tests/Invoke-MonitorHookSyntheticTests.ps1` | `8DC949B684B0FB1F34BB940C0F600BB00D585F479177EA13A16749046092D02B` |
| `.github/scripts/Invoke-SumiGuardCiTestSuite.ps1` | `8B84BBF09D78BF695BF0016A4697F5F48FC769485C0A475A57ACF898FCB099EA` |
| `docs/23-suspicious-execution-warning-design.md` | `2C6F0DF9743529D570004AED7210D5870FC5ED57102D10BFDD4DCEC137FF6A7A` |

## 不変性

既存の `evaluation_origin` 2値の条件は緩めていない。追加した値は、関連実行IDを必須とする
側に入れた。既存の保存済みレコードの書式と内容は変更していない。
