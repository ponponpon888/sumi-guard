# SUMI Guard Contribution Guide

## 基本方針

SUMI Guardは、AI開発操作の実行前入力、評価、OS観測を分離して扱うローカル優先の試作です。小さな変更を1つの目的に絞り、公開master、未マージPR、設計のみの提案を混ぜないでください。

- 1つのPRは、文書、実装、テスト、workflowの目的を可能な限り分離する。
- 変更対象と影響する既存テストをPR本文に書く。
- `NO_DETECTION`、評価完了、実行前記録を安全・実行成功・実行済みの証拠として説明しない。
- 署名、受領証、Audit Integrity、容量上限、ReadOnly、CI設定などを追加する場合は、既存の状態定義と別の設計・試験を先に用意する。

## 統合検証候補

`integration/core-privacy-governance-ci` は、確認済みmasterからPR #5（Core Privacy）、#6（security governance）、
#7（CI hardening）を順に取り込んだ検証用ブランチです。ここで確認できるMetadataOnly、ACL拒否、CIトリガー条件は
公開masterの既定動作ではありません。個別PRと統合PRを重複してマージせず、統合候補の結果を確認してから次の判断を行ってください。

## データと隔離

検証は一時ディレクトリと固定の無害な合成データだけで行ってください。

- 実資格情報、実ログ、運用ストア、個人情報、秘密鍵、トークンを使わない。
- コマンド本文には、架空の固定文字列を使う。秘密に似せる場合も、実値ではなく明示的な合成値にする。
- 恒久フック登録、Windows設定、運用ACL、実ユーザーの保存先、既存の`.demo-data`を変更しない。
- 子プロセスを使う試験は、起動したProcessインスタンスを特定してfinallyで終了・回収し、名前による一括終了をしない。
- 本文復号、秘密情報の表示、外部送信、GitHub設定変更を試験の前提にしない。

## 既存の検証経路

関連テストを先に読み、試験の隔離先と清掃処理を確認してください。リポジトリに存在する主な試験は次のとおりです。

- `tests/Invoke-CommandAssessmentTests.ps1`: 評価状態、対応ルール、本文非包含。
- `tests/Invoke-MonitorHookSyntheticTests.ps1`: MONITORフックの入力・評価・保存失敗の合成経路。
- `tests/Invoke-AssessmentStoreTests.ps1`: 評価ストアの状態、相関、容量、本文非包含。
- `tests/Invoke-ManagedAssessmentVerificationTests.ps1` と `tests/Invoke-ManagedAssessmentVerificationConnectionTests.ps1`: 管理下実行の照合境界。
- `tests/Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1`: 無害な子プロセスを使うランナー分岐。
- `tests/Invoke-LocalStoreTests.ps1`、`tests/Invoke-ExecutionAdapterIntegrationTests.ps1`、`tests/Invoke-ReadOnlyCliTests.ps1`: DPAPI CurrentUserに依存するため、GitHub CIでは除外されるローカル試験。

DPAPI非依存の既存CI試験は、Windows PowerShell 5.1で次のランナーから実行されます。

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
  -File .\.github\scripts\Invoke-SumiGuardCiTestSuite.ps1
```

文書のみの変更では、影響範囲を越える全件試験や手動Actionsを起動しないでください。コードやworkflowを変更した場合は、対象テスト、PowerShell 5.1構文、UTF-8 BOM、PSScriptAnalyzer、`git diff --check`を影響範囲に応じて確認します。

## PRの作り方

PR本文には次を含めてください。

1. 目的と変更ファイル。
2. 公開masterに既にある機能と、未マージPR・設計のみの機能の区別。
3. 実行したテスト名と結果、実行していないテストと理由。
4. 実運用ストア、恒久フック、実資格情報へ接続していないこと。
5. 残る制約と、成功・安全・実行済みを主張できない範囲。

未確認のコマンド名、存在しないテスト、未実装の運用手順をPR本文や文書へ追加しないでください。脆弱性の報告方法は [SECURITY.md](SECURITY.md) を参照し、公開Issue・PRへ秘密情報や実ログを貼らないでください。
