# 運用MONITORフックの合成試験

`hooks/Invoke-SumiGuardMonitorHook.ps1`（docs/23 段階5）に対する、固定文字列だけを使った
合成試験の記録である。**本文保存の実経路（DPAPI CurrentUser）は実行していない。** 運用端末での
動作検証ではなく、恒久登録も行っていない。

## 対象

| 項目 | 値 |
|---|---|
| コミット | `95f6623` |
| 実行 | https://github.com/ponponpon888/sumi-guard/actions/runs/39026173207 |
| ホスト | GitHub ホスト `windows-latest`、Windows PowerShell `5.1.26100.33438` |
| 試験 | `tests/Invoke-MonitorHookSyntheticTests.ps1` |
| 結果 | 20判定すべて成功（ジョブ `dpapi-independent-tests` が成功） |

## 確認できたこと

設計書の「新しい運用用フックのPre処理順」と評価状態の分離について、次が成立した。

- 信頼経路を宣言した `Set-MpPreference -DisableRealtimeMonitoring $true` が
  `DETECTED` / `SG-CMD-002` / findings 1件になり、評価レコードが `execution_id` に紐づいて
  保存される（`evaluation_origin=MANAGED_EXECUTION`。**この値はこの測定の後に
  `CODEX_PRETOOLUSE_HOOK` へ変更した。** 変更後の測定は
  `measurements/2026-10-17-assessment-origin-hook-value.md`）
- 末尾にコメントを付けても状態と検知件数が変わらない
- 照会（`Get-ScheduledTask -TaskName 'Synthetic'`）は `NO_DETECTION`
- 信頼経路の宣言が無ければ、文字列から推測せず `UNASSESSABLE / UNSUPPORTED_LANGUAGE`
- 空のコマンドは `UNASSESSABLE / CONTENT_UNAVAILABLE`
- 壊れたJSONと `PostToolUse` は `INVALID_HOOK_INPUT` で、評価も本文保存も試行しない
  （`NOT_ATTEMPTED`）。保存ファイルは作られない
- 評価失敗を強制しても本文保存は行われ、`EVALUATION_FAILED` のレコードが保存される
- 本文保存の失敗（戻り値での失敗と例外の両方）でも評価保存は行われ、`INTENT_STORE_FAILED` の
  通知が書かれる。通知に例外本文は含まれない
- 評価保存の失敗は `SAVED` に丸められず、`ASSESSMENT_STORE_FAILED` の通知が書かれる
- `execution_id` は `session_id|turn_id|tool_use_id` だけから決まる（同じ識別情報なら同じ、
  異なれば異なる、32桁の16進）
- カナリア文字列が標準出力・`assessments.ndjson`・通知・結果JSONのいずれにも現れない
- 応答は `systemMessage` 1件のみのJSONで、deny を含まず、終了コードは常に0
- フック自身のソースに `Invoke-Expression`、`Start-Process`、コマンド本文への呼出し演算子が無い
  （静的検査）

## この測定が言えないこと

- 本文保存の実経路。試験は `-TestIntentSaveOutcome` で `SumiGuard.ExecutionAdapter` の呼出しを
  置き換えており、DPAPI CurrentUser による保護、`EVENT_AND_BODY_SAVED`、本文ハッシュの保存は
  検証していない。`body_store_reached` は実経路のときだけ true になる
- 実際のCodexフックからの起動。事象は試験が標準入力へ流した固定文字列である
- 常駐監視、感染判定、誤検知判定、自動遮断、`DIRECT_MATCH`。いずれも未実装
- 初版3ルール以外の検知。`NO_DETECTION` は「有効なルールに一致しなかった」だけを意味する

## 緑までに見つかったもの

12回の実行を要した。フック側の問題は1件で、残りは試験ハーネス側だった。

| 事象 | 内容 |
|---|---|
| フック側 | 本文保存の成功状態を `SAVED` へ固定していた。実経路の `EVENT_AND_BODY_SAVED` と試験の差し替えが区別できなくなるため、アダプタの状態をそのまま残す形に直した |
| 試験側 | 事象JSONを `powershell.exe -File` の引数で渡すと 5.1 では内容により引数が保たれず、フックには「読めない事象」として届いた。標準入力へ変更した |
| 試験側 | `Set-StrictMode -Version 2.0` のもとで、空文字になり得る変数への `.Length` が `PropertyNotFoundException` になり、試験全体が停止していた。`[string]::IsNullOrEmpty` に変更した |
| 試験側 | 1件の例外で試験全体が止まり、他の判定結果が得られなかった。ケースごとに try/catch で隔離し、例外を `CASE_EXCEPTION_<ケース名>` として記録する形にした |

診断のための変更（失敗した判定の観測値、停止位置、例外の行番号、失敗行のログ末尾への再出力）は
`.github/scripts/Invoke-SumiGuardCiTestSuite.ps1` と本試験に残してある。原因の特定に実行を
重ねたのは、最初の版が失敗時に何も言えなかったためである。
