# SUMI Guard 最小試作

このディレクトリは、`docs/19-sumi-guard-execution-audit.md` の最小試作を再実行するための
PowerShell 5.1 用コードです。運用用の監査器ではありません。

試作は次を行います。

- `%TEMP%` 配下に固有の一時Gitプロジェクトを作成する
- 一時プロジェクト内のフックを、その子Codexプロセスだけの `-c hooks...` で接続する
- `--dangerously-bypass-hook-trust` をその一回だけ使い、フック信頼を永続保存しない
- 別プロセスからOSプロセステーブルを短時間だけ読み、対象子孫のPID・親PID・開始時刻・イメージを得る
- 固定コマンドの意図、OS起動、結果を照合する
- 別ケースで `write_stdin` の取得境界とMONITORモードの一次保存失敗を確認する
- 生のCLI出力、コマンドライン、イベントメッセージを保存せず、一時プロジェクトを削除する

実行例:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kit\sumi-guard-prototype\invoke-sumi-guard-prototype.ps1 `
  -CodexPath 'C:\path\to\codex.exe'
```

標準出力は秘密情報を含まない要約JSONです。試作フックが一次保存に失敗しても、MONITORモードでは
実行を拒否せず、本文なしの `CollectionFailureNotice` を別ファイルへ保存します。一次保存と別通知が
両方失敗した場合はローカル証跡が残らない限界があります。

隔離のため、想定した固定コマンド以外の `Bash` ツール呼び出しは試作フックが拒否します。この拒否は
保存失敗によるものではありません。フックスクリプト自身はCodexツールを呼ばないため、再帰的な
`PreToolUse` は発生しません。

プロジェクト `.codex/hooks.json` を一回限りのtrust overrideだけで読み込ませる方法は、このPCの
Codex CLI 0.160.0では実動作を確認できませんでした。そのため恒久trustを書かず、より狭い
CLIプロセス単位の設定を使います。OS監視器はコマンドラインを読みません。試作フック自身のPID除外に
既存の `Windows PowerShell` イベント400を使う場合も、メッセージは保存せずフック名の有無だけを
判定します。
