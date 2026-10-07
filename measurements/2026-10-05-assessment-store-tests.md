# 評価結果専用ストア・表示試験

## 実施範囲

2026-10-05に、`docs/23-suspicious-execution-warning-design.md`と
`SumiGuard.CommandAssessment`の固定出力を基準として、評価結果専用の保存モジュール、一覧・詳細CLI、
使い捨てストアによる合成試験を新規ファイルだけで追加した。

- 実フック、管理下ランナー、既存ストア、ReadOnly版には接続していない。
- 常設ストア、通知、遮断、本文復号、外部送信、設定変更は行っていない。
- 疑わしいコマンド例はCommandAssessmentへ文字列として渡しただけで実行していない。
- 既存コードと`.demo-data`は変更していない。

## 保存仕様

公開関数は次の3個である。

- `New-SumiGuardAssessmentStore`: 専用ストアを明示作成する。
- `Save-SumiGuardAssessment`: 評価結果から許可項目だけを再構成して保存する。
- `Get-SumiGuardAssessmentRecord`: 一覧または評価ID指定で読み取る。

保存先は専用ディレクトリ内のマーカー、ロック、`assessments.ndjson`で構成する。保存レコードは
次の項目だけを持つ。

- スキーマ版、評価ID、固定レコード種別
- nullableな関連`execution_id`
- 評価日時、評価状態、固定理由コード
- 評価範囲、評価起点、ルールセット版
- ルールID、ルール版、重大度、固定理由コードからなるfindings
- `content_included=false`、`source_excerpt_included=false`

入力オブジェクト全体はシリアライズしない。コマンド本文、断片、URL、パス、秘密値、AST、
例外メッセージ・詳細、実行状態は保存しない。

`evaluation_origin`は`SYNTHETIC_TEST`または`MANAGED_EXECUTION`である。合成評価では、評価器内部の
execution_idを実行との関連IDとして採用せず、保存レコードの`execution_id`をnullにする。
管理下実行では、本文とは別の`RelatedExecutionId`を必須とし、評価結果内IDとの完全一致を確認する。

評価状態は`DETECTED`、`NO_DETECTION`、`UNASSESSABLE`、`EVALUATION_FAILED`に限定し、状態ごとの
理由コードとfindings件数を検証する。既知3ルールはルールID、版、重大度、理由コードの組合せを
固定する。文字列型、最大長、形式、重複ルールIDも検証する。

保存処理の成否は評価状態と別の`status`で返す。`INVALID_ASSESSMENT`、
`DUPLICATE_ASSESSMENT_ID`、`CAPACITY_EXCEEDED`、`STORE_FILE_INCOMPLETE`、
`ATOMIC_WRITE_FAILED`等を`NO_DETECTION`や`EVALUATION_FAILED`へ置き換えない。

## ロック・原子的書込み・読取り

- 書込みは既存ロックを`Open / ReadWrite / FileShare.None`で取得する。
- 読取りは既存ロックを`Open / Read / FileShare.Read`で取得する。
- 共有違反は8桁HResultの`80070020`または`80070021`だけを上限付きで再試行する。
- 読取りはロック・データ・マーカーを作成せず、書込みアクセスを要求しない。
- ロック不在時は作成やロックなし読取りへ迂回しない。
- 書込みは同一ディレクトリの一時ファイルをflush後、明示バックアップ付き`File.Replace`で置換する。
- 置換前の障害では旧ファイルを維持し、一時ファイルをfinallyで削除する。
- 末尾改行のないファイルは不完全とし、自動修復・追記を行わない。
- 評価ID重複は拒否し、ストア作成時の`maximum_bytes`を超える置換は行わない。

## 表示仕様

`tools/Show-SumiGuardAssessments.ps1`は、`-StorePath`だけなら一覧、`-AssessmentId`も指定すれば
詳細を表示する。

- `DETECTED`: 「検知あり」と既知ルールの固定日本語説明
- `NO_DETECTION`: 「対応範囲で該当なし」
- `UNASSESSABLE`: 「評価不能」と固定理由
- `EVALUATION_FAILED`: 「評価処理失敗」と固定理由
- `PARTIAL_UNASSESSABLE`: 確認できた検知結果に加えて、一部評価不能の制約を明示
- `SYNTHETIC_TEST`: 必ず「試験データ」「実際に実行された操作の記録ではない」と表示
- 管理下実行: 評価記録だけでは実行状態を確認できないと表示
- 未知コード: コードを示して「説明未定義」とし、意味を推測しない

「安全」という判定は表示しない。CLIは本文や生レコードを出力せず、モジュールが明示的に返した
評価メタデータだけを固定文へ変換する。

## 構文・文字コード

| 項目 | 結果 |
|---|---|
| Windows PowerShell | `5.1.26100.9444` |
| モジュール構文エラー | 0 |
| マニフェスト構文エラー | 0 |
| 表示CLI構文エラー | 0 |
| 合成試験構文エラー | 0 |
| 新規4ファイルUTF-8 BOM | PASS |
| StrictMode | version 2.0 |

## 合成試験結果

Temp隔離作業域と配置先`C:\Dev\sumi-guard`で新規試験を実行し、最終的に11件すべて合格した。
配置先試験の終了コードは0、使い捨てストアの削除も成功した。

| ケース | 主な確認 | 結果 |
|---|---|---|
| `FOUR_STATES_AND_PARTIAL_ROUND_TRIP` | 4状態、部分評価、保存・読戻し、合成ID非関連化 | PASS |
| `MANAGED_EXECUTION_RELATION_IS_EXPLICIT` | 管理下実行だけ明示execution_idを関連付け | PASS |
| `DUPLICATE_ID_IS_REJECTED` | 重複評価IDを拒否し件数不変 | PASS |
| `INVALID_INPUT_IS_REJECTED` | 不許可値、型、最大長を拒否 | PASS |
| `ATOMIC_SAVE_FAILURE_PRESERVES_STORE` | 置換前障害で旧ハッシュ維持、一時ファイルなし | PASS |
| `CAPACITY_LIMIT_IS_ENFORCED` | 容量超過を拒否し既存1件を維持 | PASS |
| `INCOMPLETE_FILE_IS_NOT_REPAIRED` | 不完全ファイルの読取り・追記を拒否 | PASS |
| `READ_DOES_NOT_CREATE_MISSING_LOCK` | 読取りが欠落ロックを作成しない | PASS |
| `STORED_AND_DISPLAYED_DATA_OMIT_SECRETS` | 合成秘密・URL・パスを保存・表示しない | PASS |
| `DISPLAY_DISTINGUISHES_ALL_STATES_AND_PARTIAL` | 4状態、部分制約、非安全表示 | PASS |
| `UNKNOWN_CODES_ARE_NOT_GUESSED` | 未知コードを説明未定義として表示 | PASS |

試験結果は次も明示した。

- `suspicious_commands_executed=false`
- `command_content_saved=false`
- `raw_exception_details_saved=false`
- `external_communication_performed=false`
- `disposable_store_cleanup=true`

初回は必須パラメーターを持つCLIを試験が引数なしでドットソースしたためケース開始前に停止した。
試験側だけで使い捨てパスを渡した。次の試験は5/11で、.NET Frameworkの`File.Replace`へ
バックアップ名nullを渡したため置換が失敗していた。原子的置換を、同一ディレクトリの明示バックアップ
付きに修正した。評価条件、容量条件、非漏えい条件は緩和していない。

## SHA-256

| ファイル | SHA-256 |
|---|---|
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psm1` | `09A5D50DED32A288A37D9EB14F5069D4236C88E0C1323533BE1BEE1BBFE457E0` |
| `src/SumiGuard.AssessmentStore/SumiGuard.AssessmentStore.psd1` | `3721B556700ECA92C5A78CA00799665D5C82C7551C170152E97EB62B4F2678A7` |
| `tools/Show-SumiGuardAssessments.ps1` | `5AAA99B5F2D07BBC147C3205A71F2B95C87673ED27CAE37768B50AD8DDF777C2` |
| `tests/Invoke-AssessmentStoreTests.ps1` | `E385B24B631C52CAE1F38DB33999AFB516F96050DA13DD9BF67EF545EA2C1C73` |
| 参照: `src/SumiGuard.CommandAssessment/SumiGuard.CommandAssessment.psm1` | `9D53C732AED7EF028E28464B2DFA2B93CD04D7F5A9AF79C5DC4360F75A90E729` |
| 参照: `docs/23-suspicious-execution-warning-design.md` | `C3C73A1B6C90D7460D4548EB893A43C929D8F4D92BFEF2418DD7DE0B1E1AD835` |

## 不変性

開始時と、新規4ファイル配置・試験後を、ファイル集合、サイズ、更新日時、SHA-256で照合した。

| 対象 | 追加 | 変更 | 削除 |
|---|---:|---:|---:|
| 既存成果物 | 0 | 0 | 0 |
| `.demo-data` | 0 | 0 | 0 |

意図した追加はモジュール、マニフェスト、表示CLI、合成試験の4ファイルだけだった。本測定記録は、
この照合後に5件目の新規ファイルとして追加する。

## 次の接続点

次段階では、評価器が返した固定結果を、本文とは別に`Save-SumiGuardAssessment`へ渡す接続が必要である。

- 合成評価は`EvaluationOrigin=SYNTHETIC_TEST`、関連execution_idなしで保存する。
- 管理下ランナーは、評価対象と起動対象の一致を確認した後、
  `EvaluationOrigin=MANAGED_EXECUTION`と実際のexecution_idを渡せる。
- 実フックはインタープリターを信頼済み情報から確認できる経路が確立するまで接続しない。
- 実行Intent保存と評価保存は別結果として扱い、片方の失敗を他方の成功・失敗へ丸めない。

今回はこれらの接続、常設ストア作成、既存表示への統合、通知、遮断を行っていない。

