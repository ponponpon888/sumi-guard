# ReadOnly共有読取りロック検証・配置記録

## 範囲

既存通常版を変更せず、次のReadOnly派生版3ファイルを一時プロジェクトで検証した。

- `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.ReadOnly.psm1`
- `tools/Show-SumiGuardRecords.ReadOnly.ps1`
- `demo/Show-SumiGuardDemo.ReadOnly.ps1`

検証では本文を復号せず、生標準出力と生標準エラーを保存・表示していない。

## 読取りロック仕様

- メタデータ読取りは既存ロックを `FileMode.Open / FileAccess.Read / FileShare.Read` で開く。
- 読取り同士は共存する。
- 既存書込み側の `OpenOrCreate / ReadWrite / FileShare.None` とは相互排他になる。
- 共有違反の8桁HResultだけを上限付きで再試行する。
- 取得したハンドルは `finally` で破棄する。
- ロック不在時は作成せず、メタデータの直接読取りへ迂回せず固定失敗とする。
- 書込み側ロック、API戻り値、正式相関判定、本文非復号の仕様は変更しない。

## 一時プロジェクトでの検証結果

Windows PowerShell 5.1構文検査は3ファイルともエラー0だった。

ロック検証5項目はすべて合格した。

| 項目 | 結果 |
|---|---|
| 読取りロック同士の共存 | PASS |
| 読取りロックによる書込み拒否 | PASS |
| 書込みロックによる読取り拒否 | PASS |
| 解放後の再取得 | PASS |
| ロック不在時にファイルを作成しない | PASS |

Show検証器の合成9ケースはすべて合格した。

| ケース | 結果 |
|---|---|
| Windows PowerShell 5.1構文 | PASS |
| 正常出力 | PASS |
| サイズ数値違いの検出 | PASS |
| 計測方法違いの検出 | PASS |
| セクション欠落 | PASS |
| 途中失敗 | PASS |
| 空出力 | PASS |
| デコード不能 | PASS |
| 次見出しのない最後の保存状態 | PASS |

実表示では、一覧、詳細、保存状態、子Codex標準エラー読取状態、Event 400診断、詳細内の正式相関、
固定失敗表示の不在を含む全条件が合格した。Show終了コードは0、Show自身の標準エラーは空だった。
標準エラーサイズ39 bytesは元ストリームではなく、デコード済み.NET文字列をBOMなしUTF-8へ
再エンコードした後の値である。

正式相関は `未照合 (UNMATCHED)` のままである。元のアクセス拒否の具体的原因と、子Codex標準エラーが
非空・1行だった原因は未確定である。

## 候補SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.ExecutionAdapter/SumiGuard.ExecutionAdapter.ReadOnly.psm1` | `A425D13F89E0DE8194D57BF83698B4500C111E782734ADF107554002BA3ECCBF` |
| `tools/Show-SumiGuardRecords.ReadOnly.ps1` | `520E9B161733F2071B1BF8D86179E18C0495993FEFB0BE7A41FA2B6C71305ECA` |
| `demo/Show-SumiGuardDemo.ReadOnly.ps1` | `D7AC455FADFA72A66DAE898C339C035BC6322DF4D1A7E35C00471AE4C5FBCFC5` |

## 配置状態

2026-10-05に `C:\Dev\sumi-guard` へReadOnly派生版3ファイルを追加し、既存通常版は変更していない。
配置時にコピー元とのSHA-256一致、依存相対パス、Windows PowerShell 5.1構文を静的確認する。
本プロジェクトへ配置後のShow、Start、Clear、既存試験による実行確認は行わない。

## 配置先でのReadOnly Show確認

2026-10-05に `C:\Dev\sumi-guard` をProjectRootとして、Windows PowerShell 5.1の
`-File`で `demo\Show-SumiGuardDemo.ReadOnly.ps1` を1回だけ実行した。
元の `.demo-data\demo-manifest.json` に診断プロパティはなく、旧マニフェスト向けの
「未記録」固定表示を期待する合成9ケースに全件合格した後で実行した。

Show終了コードは0、Show自身の標準エラーは空だった。stdoutは非空で、CP932の厳格な
ラウンドトリップと固定ラベル9件中9件の一意一致を根拠にデコードした。一覧、詳細、
保存状態の完了、診断欄11行の「未記録」、詳細内の `未照合 (UNMATCHED)`、Showおよび
CLIの固定失敗表示がないことは、すべて合格した。

実行前後で既存CLI、ExecutionAdapter、LocalStore、ReadOnly派生版3ファイルのSHA-256は
すべて一致した。`.demo-data` の追加、変更、削除はいずれも0件だった。生出力と生標準
エラーは表示・保存せず、本文の復号も行っていない。
