# Claude Code フック互換性と CLAUDE_PRETOOLUSE プロファイル

## この文書の位置付け

実ホストから SUMI Guard への限定フック接続試験に向けて、Claude Code の `PreToolUse` フック仕様を
公式資料と実装の双方で調査し、既存フックへ最小の変更として `CLAUDE_PRETOOLUSE` プロファイルを
追加した記録です。

本書は**合成データによる実装と試験までの記録**です。実 Claude ホストへの接続、運用ストアの使用、
恒久フック登録、Release のいずれも行っていません。Codex の W2（起動試行・フック未到達・認証条件
未成立）とは別の作業であり、片方の結果をもう片方の根拠にしないでください。

## 調査の根拠

| 根拠 | 確認内容 |
|---|---|
| 公式フック仕様 | [Claude Code hooks](https://code.claude.com/docs/en/hooks)。`PreToolUse` の入力・出力・終了コード・matcher・既定タイムアウト |
| ローカル実装 | `C:\Users\kumon\.local\bin\claude.exe`、`2.1.304`。フック入力の組み立て、共通フィールドのスキーマ、出力スキーマを実体で確認 |
| 既存設計 | `docs/23` 段階5、`docs/24` の信頼境界 |

公式資料だけでなく実装を併せて確認したのは、`turn_id` の有無が文書の節をまたいでおり、資料だけでは
「記載が無い」と「存在しない」を区別できなかったためです。

## 非互換点

### 1. `PreToolUse` に `turn_id` が無い

Claude Code の `PreToolUse` ペイロードは、共通フィールドに `hook_event_name`、`tool_name`、
`tool_input`、`tool_use_id` を加えたものです。共通フィールドは `session_id`、`transcript_path`、
`cwd`、`prompt_id`（任意）、`permission_mode`（任意）、`agent_id`（任意）、`agent_type`（任意）、
`scratchpad_dir`、`effort` で、`turn_id` を含みません。

実装中の `turn_id` は全件が `MessageDisplay` 用（zod スキーマの
`hook_event_name:"MessageDisplay", turn_id:"UUID of the current turn."` とその送出側）であり、
`PreToolUse` には現れません。

変更前の `Test-SumiGuardPreToolInput` は6項目すべての存在を必須にしていたため、Claude Code の
イベントは `INVALID_HOOK_INPUT` となり、**評価も保存も通知も行われないまま終了**します。
終了コードは0、`systemMessage` も正常に返るため、登録は成功したように見えます。
「接続できたのに記録が無い」状態を生むため、この挙動を正常動作と取り違えないでください。

`prompt_id` は `turn_id` に最も近い識別子ですが、最初のユーザー入力まで存在しない任意項目です。
`turn_id` の代替として必須にはできません。

### 2. `tool_name=Bash` の意味が異なる

Claude Code の Windows 版では `Bash` ツールは **Git Bash** で実行されます（実装中の
"the command is executed through Git Bash"、"Git Bash was not found and the PowerShell tool is
disabled" の記述で確認）。Codex の `Bash` と異なり、対象は実際に bash です。
Windows 版にはこれとは別に `PowerShell` ツール（Windows PowerShell 5.1）があります。

したがって `Bash` に対して `-TrustedWindowsPowerShellRoute` を指定すると、bash のコマンド文字列を
PowerShell AST として評価することになります。これは `docs/24` の信頼境界に反する偽の確認済み主張です。
単なる互換性の穴ではなく、設定すれば実害が出る箇所として扱います。

## 互換している点（変更不要）

| 項目 | 確認結果 |
|---|---|
| 応答契約 | `{"systemMessage":"..."}` + 終了コード0 は有効。`systemMessage` は全イベント共通の任意出力。`permissionDecision` を返さないため実行は継続し、MONITOR の意味論が保たれます |
| 入力経路 | stdin。到達しますが、復号は後述のとおり修正が必要でした |
| `tool_input.command` | `Bash`・`PowerShell` 両ツールに存在 |
| タイムアウト | command フックの既定は600秒。`PreToolUse` はタイムアウトしても既定で遮断しません。`onFailure:"block"` は MONITOR では指定しません |
| 終了コード | 0=正常、2=遮断。本フックは常に0のため遮断事故は起きません |

## プロファイル分離の設計

`-HookInputProfile` で入力形状を選びます。形状をフィールドの有無から推測すると、一方のホストの
壊れたイベントが他方の正当なイベントとして読めてしまうため、推測せず登録時に宣言します。

| 項目 | `CODEX_PRETOOLUSE`（既定） | `CLAUDE_PRETOOLUSE` |
|---|---|---|
| 必須の識別子 | `session_id`、`turn_id`、`tool_use_id` | `session_id`、`tool_use_id` |
| 収集するツール名 | `Bash` | `Bash`、`PowerShell` |
| `execution_id` の材料 | `session_id\|turn_id\|tool_use_id` | `CLAUDE_PRETOOLUSE_HOOK` + LF + `session_id` + LF + `tool_use_id` |
| `evaluation_origin` | `CODEX_PRETOOLUSE_HOOK`、`MANAGED_EXECUTION` | `CLAUDE_PRETOOLUSE_HOOK` のみ |

既定は `CODEX_PRETOOLUSE` です。既存の必須フィールド、`execution_id` の算出、評価origin、
`INVALID_HOOK_INPUT` 時に通知を書かない挙動を含め、Codex 経路の契約は変更していません。

### 欠落した `turn_id` を補完しない

`CLAUDE_PRETOOLUSE` は `turn_id` を要求せず、代わりの値も置きません。`execution_id` は
プロファイル名を接頭辞に含む別の文字列から算出するため、識別空間がホストごとに分かれます。
同じ `session_id` と `tool_use_id` を持つ2ホストのイベントは、異なる `execution_id` になります。
Codex 側の算出式は変更していないため、既存ストアの ID は従来どおり解決します。

### origin はプロファイルと一致させる

プロファイルと矛盾する `-EvaluationOrigin` は解決せず拒否します。Claude Code のイベントを
`CODEX_PRETOOLUSE_HOOK` や `MANAGED_EXECUTION` として記録すると、実際には行われていない観測を
主張することになるためです。不一致時は `INVALID_HOOK_CONFIGURATION` となり、評価も保存も行わず、
固定コード `EVALUATION_ORIGIN_PROFILE_MISMATCH` の通知だけを残します。
どちらのoriginも、他方や `MANAGED_EXECUTION` へ格上げしません。

### インタープリターの判定

| プロファイル | `tool_name` | 信頼経路の宣言 | 結果 |
|---|---|---|---|
| `CLAUDE_PRETOOLUSE` | `Bash` | あり | **拒否**。`UNKNOWN` ではなく `OTHER`、`ROUTE_ASSERTION_REJECTED_FOR_TOOL`、`UNASSESSABLE / UNSUPPORTED_LANGUAGE` |
| `CLAUDE_PRETOOLUSE` | `Bash` | なし | `OTHER`、`TARGET_INTERPRETER_UNVERIFIED`、`UNASSESSABLE` |
| `CLAUDE_PRETOOLUSE` | `PowerShell` | なし | `UNKNOWN`、`TARGET_INTERPRETER_UNVERIFIED`、`UNASSESSABLE` |
| `CLAUDE_PRETOOLUSE` | `PowerShell` | あり | `WINDOWS_POWERSHELL`、`HOOK_REGISTRATION_RESTRICTS_HOST`、評価へ進む |

ツール名だけでは確認済みになりません。`PowerShell` という名前はツールの識別であって、実行ファイル・
版・起動設定の証拠ではないためです。確認済みになるのは、運用者が登録時に経路を宣言し、かつツール名が
それと矛盾しない場合だけです。宣言は信頼範囲を狭める方向にだけ働き、広げることはありません。

`docs/24` の結論は変わりません。Claude Code のフック入力にも、対象インタープリターの実体・版・
起動設定を示す信頼済みフィールドはありません。

## 登録（未実施）

登録は**まだ行っていません**。接続試験を承認する場合の形は次のとおりです。グローバル設定
（`~/.claude/settings.json`）ではなく、対象プロジェクトの `.claude/settings.json` に限定します。

`args` を使う exec 形式にします。`args` を省くと Windows では Git Bash を経由するため、Windows
パスの引用が壊れます。exec 形式はシェルを介さず直接起動します。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "args": [
              "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
              "-File", "<repo>\\hooks\\Invoke-SumiGuardMonitorHook.ps1",
              "-HookInputProfile", "CLAUDE_PRETOOLUSE",
              "-ExecutionStorePath", "<試験用一時領域>\\execution-store",
              "-LocalStorePath", "<試験用一時領域>\\body-store",
              "-AssessmentStorePath", "<試験用一時領域>\\assessment-store"
            ]
          }
        ]
      }
    ]
  }
}
```

`-TrustedWindowsPowerShellRoute` は含めていません。接続試験の初回は未確認のまま
`UNASSESSABLE` を確認し、経路の宣言はその後に別途判断します。`-CaptureCommandBody` も付けません。

## stdin の UTF-8 復号（別コミットで修正済み）

### 修正前の欠陥

フックは `[Console]::In.ReadToEnd()` で stdin を読んでいました。Windows PowerShell 5.1 はこれを
コンソール入力コードページで復号します。一方 Claude Code は stdin へ UTF-8 の JSON を書き込み、
`JSON.stringify` は非 ASCII をエスケープしません。コードページが UTF-8 でない環境では、
日本語などを含むコマンドが化けて JSON が壊れ、**記録を残さないまま終了**していました。
終了コードは0、`systemMessage` も返るため成功に見えます。Claude・Codex 両経路に影響します。

### 修正内容

`Read-SumiGuardHookInputText` が標準入力を**バイト列として**読み、コードページを介さずに
復号します。

- 復号は `UTF8Encoding($false, $true)` による厳密な UTF-8 です。
- 先頭の UTF-8 BOM（`EF BB BF`）だけを任意で取り除きます。
- UTF-16 などへの自動判定は行いません。UTF-16 のバイト列は「別の符号化」ではなく
  「不正な UTF-8」として扱います。
- 先頭以外の BOM 列は内容の一部として保持します。
- 不正な UTF-8 を U+FFFD で補完しません。置換した1バイトが、ホストが送った本文として
  評価・ハッシュ化されてしまうためです。固定の失敗状態
  （`INVALID_HOOK_INPUT` / `HOOK_INPUT_NOT_UTF8`）とし、評価も保存も行いません。
  本文・例外詳細は結果にも通知にも出さず、deny も返しません。
- `-RawHookInputJson` による直接入力の契約は変更していません。値が渡された場合は
  標準入力を読まず、その文字列をそのまま使います（`hook_input_decode_status=DIRECT_ARGUMENT`）。

### 試験で判明した計測上の落とし穴

回帰試験は子プロセスへ**実バイト列**を渡します。当初 `Process.StandardInput` の `BaseStream`
へ書いていましたが、これは正しく測れません。`Process.StandardInput` に触れた時点で
`Console.InputEncoding` を持つ `StreamWriter` が生成され、その符号化に preamble がある場合
（親コンソールが UTF-8 のとき）、`BaseStream` へ書いたバイトの**前に BOM が挿入される**ためです。
その状態では「BOM なし」の事例が黙って「BOM あり」になり、「BOM あり」の事例には BOM が
二重に届きます。

このため試験は、厳密なバイト列をファイルへ書き、シェルのリダイレクトで子プロセスの標準入力に
与えます。いずれのプロセスでもコンソール符号化を変更していません（`console_encoding_modified=false`）。
親コンソールが `utf-8` の場合と `shift_jis` の場合の双方で 17/17 PASS を確認しており、
結果がコードページに依存しないことを示します。

### 既存試験への影響

`tests/Invoke-ExecutionAdapterIntegrationTests.ps1` は、`master`（`c048f2d`）および本ブランチの
修正前のコミットでは `Real MONITOR hook did not produce an execution identity.` で決定的に
失敗していました（各2回実行して同一）。本修正後は **12/12 PASS** で、実フック統合の
`real_monitor_to_adapter_metadata_only` を含みます。

`docs/27` が `87e6fb2` で記録した 12/12 PASS は、その SHA における実施済みの証拠として
そのまま保持します。当時その実行が成功した理由は確認していません。コンソールのコードページが
当時の差異であったとは**断定しません**。確認できているのは、本修正の前は上記2点で失敗し、
後は成功する、という事実だけです。

## 試験

stdin の回帰試験 `tests/Invoke-MonitorHookStandardInputEncodingTests.ps1`（17判定）を追加しました。
BOM なし ASCII、BOM なし日本語、BOM なし絵文字（BMP 外）、先頭 BOM、内部 BOM、不正 UTF-8、
UTF-16、空入力、不正 JSON、直接入力を、Codex・Claude 両プロファイルで確認します。
正常系は、記録件数が1件であることと、元のコマンド文字列から計算した UTF-8 SHA-256 が
保存された `body_sha256` と一致することを確認します。アダプタは実物を使い、`MetadataOnly`
経路のみを通るため本文は保存されず（`body_file_count=0`）、DPAPI にも到達しません。

新規の合成試験 `tests/Invoke-ClaudeMonitorHookProfileSyntheticTests.ps1`（23判定）を追加し、
DPAPI 非依存の CI 試験一覧へ登録しました。本文は保存せず、`-TestIntentSaveOutcome TEST_SUCCESS`
でアダプタを代替するため、共有ランナーでも実行できます。DPAPI 依存の3試験は従来どおり CI から
除外したままで、本試験を混入させていません。

確認している範囲は、`turn_id` なしイベントの受理、Codex 側が同じイベントを引き続き拒否すること、
識別子欠落・空白の拒否、`execution_id` の再現性とホスト間の非衝突、origin の保存と不一致時の拒否、
`Bash` に対する経路宣言の拒否、`PowerShell` のツール名だけでは確認済みにならないこと、収集対象外の
ツールと `PostToolUse` が範囲外であること、全経路で deny が出ないこと、通知・結果・ストア・標準出力の
いずれにもコマンド文字列が残らないことです。

## 未実施

- 実 Claude ホストへの接続と、フックへ到達したうえでの検証。
- 運用ストアの使用、恒久フック登録、グローバル設定の変更、Release。
- `master` へのマージ、push、PR 作成。
