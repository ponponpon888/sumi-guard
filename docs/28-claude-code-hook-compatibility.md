# Claude Code フック互換性と CLAUDE_PRETOOLUSE プロファイル

## この文書の位置付け

実ホストから SUMI Guard への限定フック接続試験に向けて、Claude Code の `PreToolUse` フック仕様を
公式資料と実装の双方で調査し、既存フックへ最小の変更として `CLAUDE_PRETOOLUSE` プロファイルを
追加した記録です。

本書は**合成データによる実装・試験と、実 Claude ホストでの限定接続試験の記録**です。
2026-10-20 に Claude Code 2.1.304 からプロジェクトローカルの `PreToolUse` フックへ接続し、
試験用一時ストアへの記録と本文非保存を確認しました。運用ストアの使用、恒久フック登録、
グローバル設定の変更、Release は行っていません。Codex の W2（起動試行・フック未到達・認証条件
未成立）とは別の作業であり、片方の結果をもう片方の根拠にしないでください。

## 調査の根拠

| 根拠 | 確認内容 |
|---|---|
| 公式フック仕様 | [Claude Code hooks](https://code.claude.com/docs/en/hooks)。`PreToolUse` の入力・出力・終了コード・matcher・既定タイムアウト |
| ローカル実装 | `%USERPROFILE%\.local\bin\claude.exe`、`2.1.304`。フック入力の組み立て、共通フィールドのスキーマ、出力スキーマを実体で確認 |
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
| `execution_id` の材料 | `session_id\|turn_id\|tool_use_id`（変更なし） | `CLAUDE_PRETOOLUSE_HOOK` + 各項目を「長さ:値」で連結 |
| `evaluation_origin` | `CODEX_PRETOOLUSE_HOOK`、`MANAGED_EXECUTION` | `CLAUDE_PRETOOLUSE_HOOK` のみ |

既定は `CODEX_PRETOOLUSE` です。既存の必須フィールド、`execution_id` の算出、評価origin、
`INVALID_HOOK_INPUT` 時に通知を書かない挙動を含め、Codex 経路の契約は変更していません。

### 欠落した `turn_id` を補完しない

`CLAUDE_PRETOOLUSE` は `turn_id` を要求せず、代わりの値も置きません。`execution_id` は
プロファイル名を接頭辞に含む別の文字列から算出するため、識別空間がホストごとに分かれます。
同じ `session_id` と `tool_use_id` を持つ2ホストのイベントは、異なる `execution_id` になります。
Codex 側の算出式は変更していないため、既存ストアの ID は従来どおり解決します。

各項目は区切り文字で連結せず、**「長さ:値」の形**で連結します。区切り文字で繋ぐと、その文字が
項目の中に現れたときに境界がずれます。`session_id="a<LF>b"` と `tool_use_id="c"` が、
`session_id="a"` と `tool_use_id="b<LF>c"` と同じ文字列になり、別々のツール呼び出しが1つの
`execution_id` を共有してしまいます。長さは内容から偽造できないため、項目の組と文字列は1対1に
対応します。改行・`|`・`長さ:` 形式の偽造を試みる3件を回帰試験で確認しています。

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

## 試験用ストアの初期化

フック登録より先に、3ストアを各モジュールの公開関数で初期化する必要があります。フックは
セキュリティ境界を曖昧にしないため、未初期化ストアを自動作成しません。

```powershell
Import-Module "<repo>\src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1" -Force
Import-Module "<repo>\src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1" -Force
Import-Module "<repo>\src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1" -Force

SumiGuard.LocalStore\Initialize-SumiGuardLocalStore -Path "<試験用一時領域>\body-store"
SumiGuard.ExecutionAdapter\Initialize-SumiGuardExecutionStore -Path "<試験用一時領域>\execution-store"
SumiGuard.AssessmentStore\New-SumiGuardAssessmentStore -StorePath "<試験用一時領域>\assessment-store"
```

各結果の `success` が真であることを確認してから登録します。未初期化のまま接続した最初の試行では
`STORE_ACL_INVALID` / `EXECUTION_STORE_VALIDATION_FAILED` となり、MONITOR としてツール実行は
継続しましたが記録されませんでした。

## 試験用ローカル登録（実施済み）

2026-10-20 の限定接続試験では、ユーザー全体の設定や共有設定を変更せず、対象プロジェクトの
`.claude/settings.local.json` にだけ登録しました。このファイルはリポジトリ共通の
`.git/info/exclude` でローカル除外し、作業ツリーへ含めていません。

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

`-TrustedWindowsPowerShellRoute` は含めていません。接続試験では未確認のまま
`UNASSESSABLE` となることを確認しました。経路の宣言はその後に別途判断します。
`-CaptureCommandBody` も付けていません。

## 実 Claude ホスト接続試験（2026-10-20）

Windows PowerShell 5.1 と Claude Code 2.1.304 の実環境で、`PowerShell` ツールを1回だけ実行し、
日本語と BMP 外の絵文字を含む次の出力が欠落・文字化けせず復元されることを確認しました。

```text
SUMI_GUARD_LIVE_TEST_2_日本語_😀
```

フックの応答は次のとおりでした。

```text
SUMI Guard MONITOR: evaluation=UNASSESSABLE; assessment_storage=SAVED; intent_storage=EVENT_SAVED_METADATA_ONLY; response=monitor-only.
```

記録を公開 API で読み戻し、次を確認しました。

| 確認項目 | 実測値 |
|---|---|
| Execution record | `RECORDS_READ`、1件 |
| Assessment record | `RECORDS_READ`、1件 |
| 本文の扱い | `content_status=HASH_ONLY`、`body_reference_status=NOT_STORED` |
| 評価 | `UNASSESSABLE`、`evaluation_origin=CLAUDE_PRETOOLUSE_HOOK` |
| 評価レコードへの本文混入 | `content_included=False` |
| LocalStore の本文容器 | `.sgb` 0件 |
| 一時領域内の生コマンド文字列 | 0件 |
| Git 作業ツリー | 差分なし |

これにより、実ホストからフックへの到達、stdin の UTF-8 復号、実行・評価ストアへのメタデータ保存、
MONITOR の非遮断動作、本文非保存を同一試行で確認しました。

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
親コンソールが `utf-8` の場合と `shift_jis` の場合の双方で 28/28 PASS を確認しており、
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

stdin の回帰試験 `tests/Invoke-MonitorHookStandardInputEncodingTests.ps1`（28判定）を追加しました。
BOM なし ASCII、BOM なし日本語、BOM なし絵文字（BMP 外）、先頭 BOM、内部 BOM、不正 UTF-8、
UTF-16、空入力、不正 JSON、直接入力を、Codex・Claude 両プロファイルで確認します。
正常系は、記録件数が1件であることと、元のコマンド文字列から計算した UTF-8 SHA-256 が
保存された `body_sha256` と一致することを確認します。アダプタは実物を使い、`MetadataOnly`
経路のみを通るため本文は保存されず、DPAPI にも到達しません。

本文非保存の確認は、LocalStore が実際に使う容器名 `<32桁の小文字16進>.sgb` を数えます。
別の拡張子を探す検査は本文の有無にかかわらず0を返すため、検査自体が機能することを
`BODY_CONTAINER_DETECTOR_WORKS` で別に確認します（容器名のファイルを1件置いて1と数え、
`notes.txt` と `abcd.sgb` を置いても1のまま）。

子プロセスはすべて時間上限の下で起動します。`cmd` を待つだけではその下の PowerShell が
残り得るため、上限超過時は `taskkill /T` で木ごと停止し、実行中に観測した PowerShell が
終了したことを猶予付きで確認します。一時領域の削除失敗、時間上限超過、子プロセスの残存は
いずれも `success=false` と終了コード1に反映します（判定がすべて通っていても失敗扱いです）。

新規の合成試験 `tests/Invoke-ClaudeMonitorHookProfileSyntheticTests.ps1`（36判定）を追加し、
DPAPI 非依存の CI 試験一覧へ登録しました。本文は保存せず、`-TestIntentSaveOutcome TEST_SUCCESS`
でアダプタを代替するため、共有ランナーでも実行できます。DPAPI 依存の3試験は従来どおり CI から
除外したままで、本試験を混入させていません。

確認している範囲は、`turn_id` なしイベントの受理、Codex 側が同じイベントを引き続き拒否すること、
識別子欠落・空白の拒否、`execution_id` の再現性とホスト間の非衝突、origin の保存と不一致時の拒否、
`Bash` に対する経路宣言の拒否、`PowerShell` のツール名だけでは確認済みにならないこと、収集対象外の
ツールと `PostToolUse` が範囲外であること、全経路で deny が出ないこと、通知・結果・ストア・標準出力の
いずれにもコマンド文字列が残らないことです。

## 未実施

- 運用ストアの使用、恒久フック登録、グローバル設定の変更、Release。
- `-TrustedWindowsPowerShellRoute` を伴う確認済み経路としての評価。
- `master` へのマージ。
