# SUMI Guard 手動デモ

固定された無害なコマンド1件を、使い捨て子Codexの実行前フックからExecutionAdapterとLocalStoreへ
保存し、読み取り専用CLIで一覧、詳細、保存状態の順に確認するデモである。通常の開発入力、常駐監視、
恒久フック、PC全体の安全判定には使わない。

PowerShellを開き、次の3段階を実行する。

```powershell
Set-Location 'C:\Dev\sumi-guard'

# 開始: 固定入力を1回記録する
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Start-SumiGuardDemo.ps1

# 確認: 一覧 → 詳細 → 保存状態
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Show-SumiGuardDemo.ps1

# 清掃: デモ専用記録だけを削除する
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Clear-SumiGuardDemo.ps1 -ConfirmDemoRemoval
```

保存先はプロジェクト直下の `.demo-data` で、Git管理対象から除外される。開始スクリプトは既存の
デモ記録を上書きしない。再実行する場合は、先に明示的な清掃を行う。

本文はDPAPI CurrentUserで暗号化され、開始・確認のどちらも復号しない。確認スクリプトは
`demo-manifest.json` から `execution_id` を取得するため、利用者によるID入力や変数定義は不要である。
子Codexとフックコピーは `%TEMP%` の使い捨てプロジェクトだけで使用し、終了時に削除する。

OS観測はポーリング方式であり、短命プロセスを取り逃す可能性がある。相関候補が1件に絞れなければ
読み取り専用CLIは `UNMATCHED` と表示し、成功へ補完しない。実フック試験で標準エラーが非空だった
過去事象は原因未特定のままであり、本デモも標準エラー本文を保存しない。

## ReadOnly派生版での確認

既存のデモ記録を、検証済みの共有読取りロックを使って表示する場合は次を明示実行する。

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Show-SumiGuardDemo.ReadOnly.ps1
```

このShowは `tools/Show-SumiGuardRecords.ReadOnly.ps1` をプロジェクトルート基準の絶対パスで呼び出す。
既存ロックがなければ作成や直接読取りへ迂回せず失敗する。既存のStart、Show、Clearと通常版CLIは
変更していない。一時プロジェクトでの検証後に本プロジェクトへ配置したものであり、配置後の実行確認は
まだ行っていない。正式相関は `UNMATCHED` のまま、元のアクセス拒否原因と子Codex標準エラーが
非空だった原因も未確定である。

## 強制モードの3分デモ（Claude を呼ばない）

「記録できない操作は実行させない」強制モード（`ENFORCE_RECORDING`）を、6つの場面で見せるデモです。
Claude Code がフックに渡すのと同じ形の入力を、本物の強制フック
`hooks/Invoke-SumiGuardEnforcementHook.ps1` へ標準入力で直接渡し、フックの返答・記録・通知を表示します。
Claude も Codex も呼ばないので、費用はかかりません。

```powershell
Set-Location C:\Dev\sumi-guard
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\demo\Start-SumiGuardEnforcementDemo.ps1
```

| 場面 | 状態 | フックの返答 |
|---|---|---|
| 1 | 設定なし | なし（いつもどおり） |
| 2 | Bash だけ強制、保存先は正常 | なし（記録して通す） |
| 3 | 本文の保存先の権限を広げて壊す | 拒否の JSON、通知1件 |
| 4 | 3 のまま、PowerShell の道具 | なし（対象外） |
| 5 | `ENFORCEMENT_OFF` を置く | なし（緊急停止） |
| 6 | `ENFORCEMENT_OFF` を消す | 拒否の JSON（戻る） |

- 使うのは `%TEMP%` の使い捨てフォルダだけで、終わると削除します（`-KeepEvidence` で残せます）。
  `~/.claude/settings.json`、プロジェクト設定、既存のフック、運用ストアには触れません。
- 本文は本物の DPAPI CurrentUser で暗号化して保存します。
- 場面の間は3秒待ちます。`-PauseSeconds 0` で待たずに、`-Interactive` で Enter ごとに進みます。
- `-CastPath <file>.cast` で画面の流れを asciicast v2 で書き出します（README 用 GIF の元）。
  一時フォルダのパスやユーザー名は書き出しません。
- 全場面が想定どおりなら終了コード 0、違う場面があれば 1、始められなければ 2 です。

このデモが確かめるのは、フックが何を返し、何を記録し、何を通知するかまでです。Claude Code が
拒否の JSON を受け取って実際に実行を止めることは、ゲート2・4の測定記録
（[2026-10-23](../measurements/2026-10-23-claude-pretooluse-deny-gate2.md)、
[2026-10-28](../measurements/2026-10-28-gate4-operator-check.md)）が根拠で、このデモでは確かめていません。
CI では `-AdapterMode SYNTHETIC`（暗号化保存の代わりにフックの試験用の差し替えを使う）で
`tests/Invoke-EnforcementDemoSyntheticTests.ps1` が同じ6場面を毎回確かめます。
