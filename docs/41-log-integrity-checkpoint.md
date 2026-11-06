# SUMI Guard 記録の改ざん検知（先頭チェックポイント）

## 範囲

`SumiGuard.LogIntegrity` は、追記だけで増えていく4種のNDJSON記録について、ある時点までの
中身があとから書き換えられていないかを確かめる読み取り専用モジュールです。

| 種類 (`-Kind`) | ファイル | 書き手 |
|---|---|---|
| `Event` | `events.ndjson` | ExecutionAdapter |
| `Failure` | `failures.ndjson` | ExecutionAdapter |
| `Retention` | `retention.ndjson` | ExecutionAdapter |
| `Assessment` | `assessments.ndjson` | AssessmentStore |

公開コマンドは次の2個です。

- `Get-SumiGuardLogCheckpoint -StorePath -Kind`: 記録の現在の「完結した最後の行」までの
  SHA-256、バイト数、行数をチェックポイントとして返す
- `Test-SumiGuardLogCheckpoint -StorePath -Checkpoint`: チェックポイントと今の記録を照合する

運用者向けに `tools/Invoke-SumiGuardLogCheckpoint.ps1` があります。

```powershell
# 作成（保存先はストアの外。既存ファイルは上書きしない）
.\tools\Invoke-SumiGuardLogCheckpoint.ps1 -StorePath <store> -Kind Event -OutFile <外部の場所>\events-20261031.json
# 照合（終了コード 0=INTACT、2=MODIFIED/TRUNCATED、1=照合できなかった）
.\tools\Invoke-SumiGuardLogCheckpoint.ps1 -StorePath <store> -CheckpointFile <外部の場所>\events-20261031.json
```

## 何を検知するか

チェックポイントは、記録の先頭から最後の改行（LF）までのバイト列の **素のSHA-256** です。
記録は追記だけで増えるため、正常なら後の記録も必ず同じバイト列で始まります。

| 照合結果 | 意味 | `success` |
|---|---|---|
| `INTACT` | 先頭部分が一致。`appended_bytes` はその後に追記された量 | `true` |
| `MODIFIED` | 先頭部分のどこかで書き換え・削除・並べ替え・挿入があった | `false` |
| `TRUNCATED` | 記録がチェックポイント時点より短い、または消えている | `false` |

`success` は `INTACT` のときだけ `true` です。`success` だけを見る呼び出し元が、変更された記録を
正常と取り違えないためです。照合自体ができなかった場合（ストアがない、チェックポイントの形式が
不正など）は `verification_completed = false` で区別します。

素のSHA-256なので、SUMI Guard を使わずに検算できます（例: 先頭 `covered_bytes` バイトを
切り出して `Get-FileHash -Algorithm SHA256` や `sha256sum` にかける）。

書きかけの最後の行（改行で終わっていない末尾）はチェックポイントに含めず、
`incomplete_tail_bytes` として件数だけ返します。改行がCRLFでもLFでも同じに扱います。

## 何を検知しないか

- **チェックポイントをストアと同じ権限の場所に置くと意味がありません。** 鍵のないハッシュなので、
  記録を書き換えられる者は、書き換え後の記録に合うチェックポイントも作れます。改ざんを示せるのは、
  チェックポイントを記録の書き手が変えられない場所（別の端末、別アカウント、印刷、チャットへの
  貼り付け、Gitの別リポジトリなど）に保管したときだけです。モジュールはチェックポイントを保存せず、
  ツールはストアの中への保存を `CHECKPOINT_PATH_INSIDE_STORE` で拒否します。
- チェックポイント作成 **前** に起きた変更、および作成 **後** に追記された部分への変更は分かりません。
  次のチェックポイントを取るまでの追記分は保護されません。
- どの行が変わったかは示しません。間隔を空けて複数のチェックポイントを取れば範囲を絞れます。
- 本文ストア（`.sgb`）の削除や差し替えは対象外です（暗号文の改変はLocalStoreの復号失敗で分かります）。
- 署名、鍵管理、受領証、改ざん不能な外部保管の代わりにはなりません（[THREAT_MODEL](../THREAT_MODEL.md) の
  「外部監査基準」の残余リスクはそのままです）。

## 書き手を止めない読み方

照合はストアのロックを取りません。記録ファイルを `FileShare.ReadWrite | Delete` で開くため、
フックが追記中（ExecutionAdapter）でも、ファイルを差し替え中（AssessmentStore の `File.Replace`）でも、
書き込みを待たせたり失敗させたりしません。強制モードで記録の失敗が実行の拒否につながる以上、
点検が原因で拒否を起こさないことを優先しています。

どちらの書き手も既存のバイト列を変えずに後ろへ足すだけなので、読んでいる先頭部分は書き込み中も
変わりません。作成時は開いた時点の長さを一度だけ読み、それ以降の追記は次回に回します。

## 返さないもの

戻り値とツールの出力は、固定コード、件数、バイト数、SHA-256だけです。記録の中身、パス、
例外メッセージは含めません（`content_included = false`）。

## 検証

`tests/Invoke-LogIntegrityTests.ps1`（合成データのみ、DPAPI非依存、CIの対象）:

- 素のSHA-256との一致、未完の末尾の除外、CRLF
- 追記後は `INTACT`、同じ長さの書き換え・追記で隠した削除・並べ替えは `MODIFIED`、
  短縮・削除は `TRUNCATED`
- 不正なチェックポイント12種を例外なしで `CHECKPOINT_INVALID`
- ロックファイルのないストア、ディレクトリ、シンボリックリンクの拒否
- 書き手の開いたハンドルがあっても照合できること
- ツールの上書き拒否・ストア内保存の拒否・BOMなし出力・終了コード
- AssessmentStore の実際の保存（`File.Replace`）を挟んでも `INTACT`、その後の書き換えで `MODIFIED`
  （Windowsのみ。それ以外では `not_run` に理由付きで記録）
- 全出力に本文・パスが含まれないこと

未確認: 運用端末の実ストアでの照合、ExecutionAdapter の実書き込みと同時に照合した場合の
挙動（CIではDPAPI依存のため実ストアを作れない）。
