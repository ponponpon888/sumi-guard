# SUMI Guard 実フック・暗号化保存接続試験

このディレクトリは、固定された無害なコマンド1件だけを使い、Codex `PreToolUse`、
`SumiGuard.ExecutionAdapter`、`SumiGuard.LocalStore`、既存のOSプロセス観測器を接続する試験コードです。
運用用フックではありません。

ランナーは `%TEMP%` 配下に固有プロジェクトを作り、子Codexプロセスの `-c hooks...` にだけフックを
設定します。`--dangerously-bypass-hook-trust` はその子プロセスだけで使い、永続trust、恒久フック、
監査設定を変更しません。終了時に一時プロジェクトと試験用保存領域を削除します。

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\kit\sumi-guard-protected-hook-test\invoke-sumi-guard-protected-hook-test.ps1
```

フックは期待するコマンドSHA-256と一致した `Bash` 呼び出しだけを記録します。Preフックでは本文を
LocalStoreへ暗号化保存し、Postフックでは本文やツール応答を保存せず、実行結果と本文参照だけを別の
NDJSONイベントへ保存します。成功時のフック標準出力は空です。

標準出力は本文を含まない試験要約JSONです。`-KeepTemporaryProject` は診断用ですが、保持した領域には
明示復号可能な試験本文が残るため、通常の試験では指定しません。
