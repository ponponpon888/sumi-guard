# SUMI Guard Claude Code MONITOR フックの導入・解除

## 範囲

`tools/Invoke-SumiGuardClaudeMonitorHookSetup.ps1` は、Claude Code の設定ファイル1つに
SUMI Guard の **MONITOR フック**（PowerShell ツール向け）を登録・解除する運用者向けスクリプトです。
設定の書き換え内容は `SumiGuard.HookSetup` が文字列だけで計画し、スクリプトはファイルの読み書きだけを
担います。

登録する内容は [docs/28](28-claude-code-hook-compatibility.md) で実ホスト接続を確認した形と同じです。

- `matcher: "PowerShell"`、exec 形式（`command` + `args`。Git Bash を経由させない）
- `-HookInputProfile CLAUDE_PRETOOLUSE`
- `-TrustedWindowsPowerShellRoute` と `-CaptureCommandBody` は付けない（判断は運用者に残す）

対象外: 強制フック（`Invoke-SumiGuardEnforcementHook.ps1`）の登録、Codex の設定、`Bash` ツール。

## 使い方

```powershell
# まず何が起きるかだけ見る（何も書かない）
.\tools\Invoke-SumiGuardClaudeMonitorHookSetup.ps1 -Action Install `
  -SettingsPath "$env:USERPROFILE\.claude\settings.json" -StoreRoot "<ストアの置き場>" -WhatIf

# 登録（ストアが無ければ -InitializeStores で作る。Windows のみ）
.\tools\Invoke-SumiGuardClaudeMonitorHookSetup.ps1 -Action Install `
  -SettingsPath "$env:USERPROFILE\.claude\settings.json" -StoreRoot "<ストアの置き場>" -InitializeStores

# 解除（ストアと記録は消さない）
.\tools\Invoke-SumiGuardClaudeMonitorHookSetup.ps1 -Action Uninstall `
  -SettingsPath "$env:USERPROFILE\.claude\settings.json"
```

`-SettingsPath` は既定値を持たせず、毎回明示します。ユーザー全体（`~\.claude\settings.json`）か、
プロジェクトだけ（`<project>\.claude\settings.local.json`）かを取り違えないためです。
設定ファイルのフォルダが無い場合は作らずに止まります。

出力は固定コードの JSON 1行です（パスや設定値は含めません）。終了コードは 0=完了または変更不要、
1=拒否または失敗。

| status | 意味 |
|---|---|
| `INSTALLED` / `UPDATED` / `REMOVED` | 書き換えた。`backup_file_name` に退避ファイル名 |
| `ALREADY_INSTALLED` / `NOT_INSTALLED` | 変更不要。ファイルにも触れていない |
| `WHATIF` | `-WhatIf`。`planned_status` に実行時の結果 |
| `STORES_NOT_READY` | ストアが無い（`missing_stores`）。`-InitializeStores` なしでは作らない |
| `SETTINGS_INVALID_JSON` / `SETTINGS_NOT_OBJECT` / `HOOKS_SHAPE_UNSUPPORTED` | 推測が必要な設定なので触らない |
| `SETTINGS_CHANGED_DURING_WRITE` | 読んだあとに別のプロセス（Claude Code 等）が書き換えた。何も書いていない |
| `VERIFY_FAILED_RESTORED` | 書いた内容を読み戻したら一致しなかった。元に戻した |

## 何を守るか

- **SUMI Guard の項目以外は変えない。** フック項目の識別は `-File` の次の引数が
  `Invoke-SumiGuardMonitorHook.ps1` で終わることだけで行い、独自キーは足しません（Claude Code は
  設定を検証するため、未知のキーで設定全体が無効になるおそれがある）。書く前に「SUMI Guard の項目を
  除いた設定の値」が書き換え前後で同じことを確かめ、違えば `PRESERVATION_CHECK_FAILED` で止まります。
- **2回実行しても同じ。** 同じ引数で登録済みなら `ALREADY_INSTALLED` で、ファイルも退避も作りません。
  ストアの場所を変えて再実行した場合は、古い項目を外して1件だけにします（`UPDATED`）。
  手で別のグループに入れた SUMI Guard の項目も見つけて置き換え、同じグループの他人のフックは残します。
- **書き換え前に退避する。** 既存ファイルを変えるときは、同じフォルダに
  `<名前>.sumi-guard-backup-<UTC時刻>` として元のバイト列をそのまま残します（消すのは運用者）。
- **途中で壊さない。** 一時ファイルに書いてから差し替え、読み戻してバイト単位で照合します。
  読んでから書くまでに設定が変わっていたら書きません。
- **解除で消しすぎない。** 外すのは SUMI Guard の項目だけです。それを外して空になった
  matcher グループ・`PreToolUse`・`hooks` だけを取り除きます。ストアと記録は消しません。
- BOM付きの設定ファイルも読めます。書き出しは BOM なし UTF-8 です。

## 既知の制約

- 書き戻しは PowerShell の `ConvertTo-Json` を通すため、値は同じでも **整形（インデント・改行）は変わります**。
  元の見た目は退避ファイルに残ります。Windows PowerShell 5.1 では記号の一部が `<` のような
  エスケープ表記になることがあります（値としては同じ）。
- 判定の前提は Claude Code の設定形式（`hooks.PreToolUse[].hooks[]`）です。形式が変わった場合は
  推測せず `HOOKS_SHAPE_UNSUPPORTED` で止まります。
- `-InitializeStores` は各モジュールの公開初期化関数を呼ぶだけで、DPAPI と ACL に依存するため
  CI では確かめていません。
- 登録したフックが実際に呼ばれることは、このスクリプトでは確かめません。登録後に Claude Code を
  起動し直し、[docs/28](28-claude-code-hook-compatibility.md) の手順で記録が増えることを確認してください。

## 検証

`tests/Invoke-ClaudeMonitorHookSetupTests.ps1`（合成の設定ファイルと、マーカーだけの代替ストア。CIの対象）:

- 計画: 他の設定（権限・環境変数・他のフック・PostToolUse・日本語と絵文字・数値・null）を保ったまま
  1件だけ追加し、解除すると元の値に戻る／2回目は変更なし／引数変更は1件のまま置き換え／
  共有グループ内の手置き項目だけを外す／空の設定への追加と、解除で空になった入れ物の除去／
  推測が必要な形6種を登録・解除とも拒否／`-File` のない項目を拒否
- スクリプト: 新規作成が BOM なし・退避なし／2回目はバイト単位で不変・退避なし／
  BOM付きの既存設定で退避が元のバイト列と一致し値が保たれる・一時ファイルが残らない／
  `-WhatIf` は何も書かない／ストア不足・壊れたJSON・フォルダなし・ディレクトリ指定・
  `-StoreRoot` なしを書く前に拒否／解除は項目だけを外しストアは残す、繰り返しても変更なし
- 出力にパスや設定値が含まれないこと

未確認: 運用端末の実際の設定ファイルへの登録、`-InitializeStores`、登録後に Claude Code が
フックを呼ぶこと。
