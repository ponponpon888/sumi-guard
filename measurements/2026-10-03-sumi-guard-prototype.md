# SUMI Guard 最小試作結果（2026-10-03）

## 結論

無害な固定コマンド `Write-Output 'SUMI_GUARD_PROTOTYPE_OK'` について、実行前フック、実行結果、
独立したOSプロセス観測を取得できた。相関は、フックイベント自身に対象PIDがないため
`INFERRED_MATCH` であり、`DIRECT_MATCH` ではない。

恒久フック、永続trust、監査設定、保護設定、インストールは変更していない。試験用ファイルと
プロセスは `%TEMP%` 配下の固有プロジェクトに限定し、終了時に削除した。

## 接続方法とOSソース

- Codex CLI: 0.160.0
- フック接続: 一時プロジェクト内のスクリプトを、子Codexプロセスだけの `-c hooks...` で参照
- フックtrust: `--dangerously-bypass-hook-trust` を当該プロセスだけで使用。永続trustは未登録
- OSソース: 別プロセスによる `System.Diagnostics.Process` と `NtQueryInformationProcess` の短時間ポーリング
- OS保存項目: PID、親PID、開始時刻、イメージ、子CodexのルートPID
- 非保存: OSコマンドライン、生のCLI出力、イベントログ本文
- フック自身の除外補助: 既存の `Windows PowerShell` イベント400を読み、試作フック名の有無だけを判定

`Win32_ProcessStartTrace` の購読はアクセス拒否だった。既存PowerShellイベントログは有効だったが、
対象プロセスとフックプロセスを単独では確実に分離できなかったため、どちらもOS観測の成功根拠には
していない。

## A: 初期コマンド

- `PreToolUse` 発火: 1件
- 元本文取得: 成功。`tool_input.command` は `System.String`
- SHA-256: `6e1138905ea1fcabf0b32a0f0e075548564912d52e89f8611c6ae6f0f89af25b`
- ハッシュ範囲: JSON復号後の `tool_input.command` を無正規化でUTF-8（BOMなし）へ変換したバイト列
- 実行前記録: 2026-10-03 15:13:45.416 JST
- OS開始記録: 2026-10-03 15:13:45.528 JST、PID 187372、親PID 195388
- イメージ: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
- 終了結果記録: 2026-10-03 15:13:46.748 JST
- 固定出力: CLIの `command_execution` と `PostToolUse.tool_response` の双方で確認
- 相関: `INFERRED_MATCH`

根拠は、同じ隔離子Codex（PID 195388）の直下で、OS開始が実行前イベントと実行結果イベントの間に
発生したこと、本文ハッシュと固定出力が一致したことである。候補PID 193932はイベント400の
フック名判定で試作フック自身と確認し、対象から除外した。ログ本文は保存していない。

実測した入力スキーマのトップレベルには `cwd`、`hook_event_name`、`model`、`permission_mode`、
`session_id`、`tool_input`、`tool_name`、`tool_use_id`、`transcript_path`、`turn_id` があり、
`tool_input` の取得対象プロパティは `command` だった。

## B: 後続 write_stdin

固定の待機コマンド `$line = Read-Host; Write-Output $line` を最初の `exec_command` とし、
`Write-Output 'SUMI_GUARD_PROTOTYPE_OK'` を後からデータとして送った。送信文字列は実行していない。

- 初期コマンドの `PreToolUse`: 1件
- 初期コマンドのSHA-256: `0c3e2cd0ec0178b74d14de5a47824ea6cfc6181a8d619fcb9d94714784522ae1`
- 実行前記録: 2026-10-03 15:14:02.818 JST
- OS開始記録: 2026-10-03 15:14:02.932 JST、PID 134152、親PID 162556
- 終了結果記録: 2026-10-03 15:14:17.093 JST
- 固定出力: CLIの `command_execution` と `PostToolUse.tool_response` の双方で確認
- 後続 `write_stdin` の新規 `PreToolUse`: 0件
- 後続本文のフック保存: なし
- 相関: `INFERRED_MATCH`

候補PID 188164はイベント400のフック名判定で試作フック自身と確認し、対象から除外した。
この結果は、Aの初期 `tool_input.command` は実行前に取得できる一方、Bの後続入力は同じフック経路では
本文取得できないという境界を実測したものになる。

## MONITOR保存失敗

一次保存先にディレクトリを指定して書き込み失敗を発生させた。

- 一次保存: 失敗
- 別経路の `CollectionFailureNotice`: 2件（Pre/Post）
- 通知にコマンド本文: なし
- 自動deny: なし
- 固定コマンドの実行と固定出力: 成功

一次保存と別通知の両方が失敗した場合、ローカル証跡を残せない限界は残る。

## 未達・限界

- フックと対象OSプロセスに共通PIDがないため、相関は直接一致ではない
- OSポーリングは短命プロセスを取り逃す可能性があり、完全な監査境界ではない
- プロジェクト `.codex/hooks.json` は一回限りのtrust指定だけでは実動作を確認できなかったため、
  CLIプロセス単位のフック設定を使用した
- 暗号化保存、WAL取り込み、UI、AI分析、自動遮断、常駐化は試作範囲外

次の最小作業は、フックイベントへOS側PIDを安全に受け渡せる接続点の有無を確認し、
`INFERRED_MATCH` を `DIRECT_MATCH` に上げられるかを検証すること。これは恒久設定を導入する前に、
同じ固定入力だけで別試験として行う。
