# SUMI Guard — 外部署名された時刻・連番受領証（検証のみ）

## 目的

既存の `Test-SumiGuardTrustedCheckpoint.ps1` は、署名鍵の失効を判定する
`MinimumTrustedManifestEpoch`、チェックポイント連番の下限、
`TrustedNowUtc` を呼び出し元から受け取ります。
**監視PC自身の時計や書換可能な設定値だけでは、これらを信用できません。**

追加した検証器は、独立した信頼情報発行者が署名した
「受領証」（receipt）からこれらの値を抽出し、署名と束縛条件を
確認してから既存の厳格な検証器に渡します。

- `tools/Test-SumiGuardAuthorityReceipt.ps1`：署名・公開鍵指紋・対象識別・
  チャレンジの一致を検証する**読取り専用**CLI。
- `tools/Test-SumiGuardAttestedCheckpoint.ps1`：受領証検証に成功した場合のみ、
  `Test-SumiGuardTrustedCheckpoint.ps1` を呼び出す**読取り専用**入口。
- 合成テスト：`tests/Invoke-SignerTrustLifecycleTests.ps1` の追加ケース。

このPRは署名するサーバー、時刻取得サービス、HTTPアクセス、
本番証明書、鍵配布、外部認証処理、PCの設定変更を行いません。

## 独立した信頼関係

受領証の署名者鍵は監査ログのルート鍵**とは異なる公開鍵**とします。
両方の公開鍵のSHA-256指紋を独立した信頼経路で配布・固定してください。
受領証にはルート鍵指紋、監査ストアのマーカーSHA-256、
署名者の失効情報一覧SHA-256を含め、他の構成へ転用できないようにします。

**特に重要：チャレンジは監視PC以外の独立した信頼経路で新規発行し、
当該検証要求と紐付け、再利用を禁止する必要があります。**
今回の検証器は64文字の小文字16進数としてチャレンジの
*値の一致だけ*を検査します。チャレンジの発行源・乱数品質・
再利用の有無を検証器自身が証明することはできません。

## 署名される受領証の形式

受領証はUTF-8 JSON、正確に13フィールドとします。
独立した情報発行者が正当な現在時刻・状態を確認した上で、
**JSONファイルのバイト列そのもの**に RSA/SHA-256 PKCS#1 v1.5
切り離し署名を行う想定です。

```json
{
  "schema_version": 1,
  "record_type": "SumiGuardAuthorityReceipt",
  "purpose": "CHECKPOINT_TRUST_STATE",
  "challenge_nonce": "<64-lowercase-hex-characters>",
  "store_kind": "Execution",
  "store_marker_sha256": "<64-lowercase-hex-characters>",
  "trust_manifest_sha256": "<64-lowercase-hex-characters>",
  "root_public_key_sha256": "<64-lowercase-hex-characters>",
  "minimum_manifest_epoch": 42,
  "minimum_checkpoint_sequence": 42,
  "trusted_at_utc": "2026-10-18T09:00:00Z",
  "issued_at_utc": "2026-10-18T08:59:59Z",
  "expires_at_utc": "2026-10-18T09:01:59Z"
}
```

`issued_at_utc` から `expires_at_utc` は最長2分。
主張される `trusted_at_utc` は期間内で、時刻はUTCの `Z` 形式必須。
**2分の期間検査は、現時点での有効期限を証明する処理ではありません。**
端末内の未認証時計は期限判定には使いません。発行者が本当に
チャレンジを受けて「今」署名したかは外部サービス側の責任です。

受領証と切り離した署名、独立発行者の公開鍵JSONは監査ストア外に
配置します。公開鍵JSONは既存のルート公開鍵と同じ4フィールド形式、
RSA 3072〜4096ビット、公開指数65537です。公開鍵JSONの
**正確なファイルバイト列**のSHA-256指紋を別の信頼経路で取得します。

## 検証コマンド

あらかじめ独立した信頼経路から受け取ったファイルと指紋を
変数に設定した上で呼び出す例です。

```powershell
& .\tools\Test-SumiGuardAttestedCheckpoint.ps1 -StoreKind Execution -StorePath $store -CheckpointPath $checkpoint -SignaturePath $checkpointSignature -SignerPublicKeyPath $signerPublicKey -PolicyPath $policy -PolicySignaturePath $policySignature -RootPublicKeyPath $rootPublicKey -ExpectedRootPublicKeySha256 $rootPin -TrustManifestPath $trustManifest -TrustManifestSignaturePath $trustManifestSignature -AuthorityPublicKeyPath $authorityPublicKey -ExpectedAuthorityPublicKeySha256 $authorityPin -ReceiptPath $receipt -ReceiptSignaturePath $receiptSignature -ExpectedChallengeNonce $freshOffdeviceNonce
```

受領証の検証結果が成功して初めて、受領証の連番・時刻が
既存の失効検証器に引き渡されます。異常時は固定エラーコードで
**失敗**します。受領証が通っても、改ざん検知以外に
OS全体の安全性や監視漏れの無さを証明するものではありません。

## セキュリティ上の制限

1. **実運用の時刻発行者・独立チャレンジ発行サービスは未実装。**
   したがって現段階では「ライブ時刻が検証できた」という保証はありません。
2. 受領証のチャレンジを任意のローカル入力に任せれば、
   昔の署名を再提示するリプレイ攻撃を防げません。
3. 署名者が誤った時刻や古い連番を証言すれば、
   RSA署名そのものは不正な状態を見抜きません。
4. 受領証から既存検証器へ進む間にファイルを変更できる同一ユーザーの
   悪意あるプロセスや管理者には、完全な排他・防御境界がありません。
5. ブランチ内の旧CLIを直接呼べば、本受領証検証を省略できます。
   実運用時の入口制限・監査・リカバリーは別の承認された設計が必要です。
6. 受領証署名用の秘密鍵はこのリポジトリに存在せず、
   合成テストの鍵だけを使い捨てのCI上で生成します。
7. 本番サービスやPC、GitHub Secrets、`master`は変更しません。
