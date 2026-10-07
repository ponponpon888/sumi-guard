# 保存済み記録の読み取り専用CLI

`tools/Show-SumiGuardRecords.ps1` は、ExecutionAdapterとLocalStoreに保存済みの記録を
Windows PowerShell 5.1で確認するための読み取り専用CLIである。本文の復号、表示、清掃、修復は
行わない。この表示はSUMI Guardが取得した記録の状態に限られ、PC全体の安全、感染、誤検知を
判定するものではない。

## 読み取り方針

- 実行イベントと通常の失敗通知は、既存ロックファイルがある場合にExecutionAdapterの公開APIを使う。
- 公開読取APIはロックを `OpenOrCreate` で開くため、まだロックがない空ストアでは、ファイルを作らない
  version 1形式の読取専用フォールバックを使う。
- 容量は、LocalStoreの管理対象名に一致する `.sgb` の32バイト固定ヘッダーだけを検査して集計する。
  暗号化ペイロードは読まず、`Get-SumiGuardBody` と `Read-SumiGuardExecutionBody` は呼ばない。
- 設定値はストアマーカーに永続化されていない。このため表示する上限と保持期間はCLIへ渡した値であり、
  省略時はLocalStoreの既定値（1件1 MiB、合計250 MiB、30日）である。
- 読み取りエラーの例外本文は出力せず、`読み取り失敗` と `COLLECTION_FAILED` だけを表示する。

上記のロック不在時フォールバックは既存通常版 `Show-SumiGuardRecords.ps1` の仕様である。検証済みの
`Show-SumiGuardRecords.ReadOnly.ps1` は `SumiGuard.ExecutionAdapter.ReadOnly.psm1` を明示使用し、
既存ロックを `Open / Read / FileShare.Read` で共有読取りする。共有違反だけを上限付きで再試行し、
書込み側の `FileShare.None` ロックとは相互排他になる。ロックが存在しない場合は作成せず、直接読取りへ
迂回せず固定の読取り失敗を表示する。既存通常版のファイルと動作は変更しない。

## 操作

### 一覧

```powershell
.\tools\Show-SumiGuardRecords.ps1 -Action List `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore `
  -OsObservationPath $observationPath
```

日時、`execution_id`、実行状態、本文保存状態、相関強度を表示する。OS観測が未指定、取得不能、
候補0件または複数の場合は成功へ補完せず `UNMATCHED` とする。

### 詳細

```powershell
.\tools\Show-SumiGuardRecords.ps1 -Action Detail `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore `
  -ExecutionId '00000000000000000000000000000000' `
  -OsObservationPath $observationPath
```

実行前、実行結果、OS候補、候補数、照合根拠、本文参照、本文SHA-256を表示する。本文は復号も表示も
しない。対象がなければ `NO_RECORD`、実行結果がなければ「結果未記録」、本文参照が消えていれば
「参照切れ」、保持清掃の墓標があれば「保持期限により削除」と表示する。

### 保存状態

```powershell
.\tools\Show-SumiGuardRecords.ps1 -Action StoreStatus `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore
```

暗号化コンテナの使用容量、CLI指定の上限と保持期間、参照切れ、保持期限による削除、取得失敗、
失敗通知の件数を表示する。起動時の自動削除や修復は行わない。

## ReadOnly派生版の操作

通常版と同じ引数を `Show-SumiGuardRecords.ReadOnly.ps1` へ渡す。

```powershell
# 一覧
.\tools\Show-SumiGuardRecords.ReadOnly.ps1 -Action List `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore `
  -OsObservationPath $observationPath

# 詳細
.\tools\Show-SumiGuardRecords.ReadOnly.ps1 -Action Detail `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore `
  -ExecutionId '00000000000000000000000000000000' `
  -OsObservationPath $observationPath

# 保存状態
.\tools\Show-SumiGuardRecords.ReadOnly.ps1 -Action StoreStatus `
  -ExecutionStorePath $executionStore `
  -LocalStorePath $localStore
```

一時プロジェクトでは一覧、詳細、保存状態と固定診断値を確認済みで、正式相関は
`未照合 (UNMATCHED)` のままである。本プロジェクトへ配置後の実行確認は未実施である。

## 相関

- `DIRECT_MATCH`: OS観測に同一 `execution_id` があり、候補が1件だけである。
- `INFERRED_MATCH`: 対象PIDの直接一致はないが、フックPIDを除外し、実行前から結果までの時刻窓に
  OS候補が1件だけ残る。
- `UNMATCHED`: 必要情報なし、読取不能、候補0件、候補複数など、上記を満たさない。

欠けた情報を実行成功や安全へ置き換えない。なお、2026-10-03の実フック試験ではCLI標準エラーが
非空だったが、内容を保存していないため原因は未特定である。本CLIはこの点を各表示に明記し、原因を
推測しない。このCLI追加のためにCodex試験は再実行していない。
