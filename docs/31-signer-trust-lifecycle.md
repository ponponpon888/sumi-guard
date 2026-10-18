# SUMI Guard — オフライン署名者の失効・更新プロトタイプ

## 目的と範囲

`Test-SumiGuardSignerTrust.ps1` は、監視PCとは独立したルート署名者により
**生バイト列が署名された信頼一覧**を読み取り専用で検証します。
`Test-SumiGuardTrustedCheckpoint.ps1` は信頼一覧で許可された署名者の
チェックポイントと、既存の署名付き有効期間ポリシーを検証します。

これは検証専用です。ルート秘密鍵や実運用の署名者秘密鍵を生成・
保存・アップロード・配布しません。本番通信、cron、NTP、時刻
サービス、サーバー/HSM、GitHub Secrets、既存ストアの変更も実施しません。

## 信頼境界

- **オフラインルート秘密鍵**：監視PC以外の安全な環境で保管。
- **監視PCに渡すルート公開鍵**：JSONファイルと、その完全な
  ファイルバイト列のSHA-256を別の信頼できる経路から受け取る。
- **署名済み信頼一覧**：ルート秘密鍵でRSA-PKCS#1 v1.5 / SHA-256署名。
  署名対象はJSONの**厳密なファイルバイト列**。署名はBase64形式の別ファイル。
- **外部の単調増加更新番号（epoch）の下限**：管理PCの変更可能なローカル
  設定ではなく、独立した強固な管理台帳で更新・配布する。
- **外部の信頼できるUTC時刻**：呼び出し元が渡す。
  このツール自身は時刻の出所や正しさを認証できない。
- **チェックポイント連番の下限**：署名者一覧のepochとは別系統の番号。
  こちらも独立した外部保護が必要。

NIST SP 800-57 Part 1 Rev. 5 は鍵のライフサイクル管理と失効を扱います。
https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final

信頼時刻の将来の候補であるRFC 3161タイムスタンプは、
署名・データ対応関係・鮮度の検証が必要です。本PRはこれを実装しません。
https://www.rfc-editor.org/rfc/rfc3161.html

## 信頼一覧の仕様

以下の例は**ダミー形式**で、実運用の署名は含みません。

```json
{
  "schema_version": 1,
  "record_type": "SumiGuardSignerTrustManifest",
  "manifest_epoch": 42,
  "issued_at_utc": "2026-10-18T08:00:00Z",
  "expires_at_utc": "2026-10-18T10:00:00Z",
  "signers": [
    {
      "public_key_sha256": "<sha256-of-exact-signer-public-key-json-bytes>",
      "purpose": "AUDIT_CHECKPOINT",
      "state": "ACTIVE",
      "not_before_utc": "2026-10-18T08:00:00Z",
      "not_after_utc": "2026-10-18T12:00:00Z"
    }
  ]
}
```

キーごとの状态：`ACTIVE`、`RETIRED`、`REVOKED`。
`RETIRED` と `REVOKED` は**検証時点で不許可**とする保守的な
ルールです。古い正当な署名の履歴検証は別のアーカイブポリシーを設計してください。

ルート鍵JSONは以前のチェックポイント用と同じ公開鍵4フィールドです。
RSA公開鍵は3072〜4096ビット、指数65537。
有効な署名者一覧は最長7日、署名者の有効期間は最長366日です。
未知の鍵・重複した公開鍵指紋・無効な署名・不正なフィールド・
無効なUTC時刻・弱いルート鍵を拒否します。
設定値の可否は署名の真正性を検証してから判断します。

## 最も重要な失効手順

1. 信頼環境で旧鍵Aの`REVOKED`を宣言し、新鍵Bを`ACTIVE`とする
   新しい信頼一覧に署名する。**epochを増加**させる。
2. 独立した運用台帳で、**最低許容epochを新番号へ更新**する。
3. 信頼一覧、切り離した署名、更新番号下限をそれぞれ正しい
   信頼経路で配布する。
4. 検証器はAの署名を拒否しBを許可する。
5. 旧epochの一覧が再提示されても、外部下限未満なら拒否する。

**外部下限が更新されない場合、同じルート鍵で署名された古い有効な
一覧を再提示され、失効済みの鍵が許可される可能性があります。**
よって本PRのコードだけでは失効通知の到達や巻き戻し防止を保証しません。

ルート秘密鍵そのものが侵害された場合、ルート署名で新ルートを
承認するだけでは十分ではありません。新しいルート公開鍵の指紋を
独立した本人確認と管理手順で再配布する必要があります。

## 厳格な読み取り専用検証

次のコマンドは事前に準備された変数を使用します。鍵・時刻・epochの
入手元が本当に信頼できることを、別の管理手順で確認してください。

```powershell
& .\tools\Test-SumiGuardTrustedCheckpoint.ps1 -StoreKind Execution -StorePath $store -CheckpointPath $checkpoint -SignaturePath $checkpointSignature -SignerPublicKeyPath $signerPublicKey -PolicyPath $signedPolicy -PolicySignaturePath $policySignature -RootPublicKeyPath $rootPublicKey -ExpectedRootPublicKeySha256 $independentRootPin -TrustManifestPath $trustManifest -TrustManifestSignaturePath $trustSignature -MinimumTrustedManifestEpoch $independentManifestEpoch -MinimumTrustedSequence $independentCheckpointSequence -TrustedNowUtc $independentUtc
```

成功：`AUTHORIZED_CHECKPOINT_MATCH`、exit 0。
監査ログの差分・失効・鍵の不許可：exit 1。
入力・署名・検証障害：exit 2。
**実行拒否（deny）、フックの変更、書込み・修復は一切行いません。**

この厳格な入口を使用せず、以前の`Test-SumiGuardSignedCheckpoint.ps1`
に直接アクセスした場合、ルート署名された鍵失効一覧の検証は**省略**されます。
この互換入口は自動的には廃止していません。

## テストと未実装

`tests/Invoke-SignerTrustLifecycleTests.ps1` はGitHub-hosted Windows上で
一時的なRSAルート鍵と2つの署名者鍵をメモリ上で作成し、旧鍵の失効と
新鍵への切替、公開鍵指紋不一致、epoch・期限検査、署名改変を検査します。
実運用の秘密鍵はどこにも保存しません。

外部での信頼できる時刻の**取得・証明**、epoch配信、署名システム、
鍵紛失時の復旧、失効情報の即時配布、手動/自動鍵更新は**未実装**です。
これらが揃うまではDraft PRを維持し、master・本番・PC設定へ反映しません。

## 外部で署名された時刻・連番情報（検証器試作）

別の独立した時刻・連番情報発行者が署名する受領証を検証してから、
上記の鍵失効・チェックポイント検証を呼び出す試作を追加しました。
受領証は監査ストアのマーカー、信頼一覧SHA-256、ルート公開鍵指紋と
乱数チャレンジに紐付けます。

**独立した乱数チャレンジの発行・真正性確認、受領証の取得、信頼できる
署名機関の運用・時間証明は未実装**であり、本当に新しい受領証が発行されたか
を検証器単独で証明することはできません。詳細は
`docs/32-authority-receipt.md` を参照してください。
