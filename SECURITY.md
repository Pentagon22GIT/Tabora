# セキュリティポリシー

## 対応対象

| バージョン | セキュリティ修正 |
|---|---|
| 最新の安定Tabora Release | 対応 |
| それ以前 | 原則として最新版への更新で対応 |
| Community版・第三者Fork | 公式サポート対象外 |

## 非公開で報告するもの

次の問題は公開Issueへ投稿せず、GitHubのPrivate Vulnerability Reportingを使用してください。

- Accessibilityまたは画面収録権限の不正利用
- identity / Bundle ID / TCC境界の不正な継承
- 署名・Release検証の回避
- 任意コード実行、ファイル破壊、情報漏えい
- GitHub Actions、build、release supply chainの侵害
- Tabora Official署名秘密鍵の漏えいまたは漏えいの疑い
- 未公開脆弱性を実用的に悪用できる具体的手順

## 報告に含める情報

- Taboraバージョン
- Official / Communityの別
- macOSバージョンとCPUアーキテクチャ
- 再現に必要な最小手順
- 想定される影響
- 既知の回避策
- 必要に応じて機密情報を除いたログ・署名情報

秘密鍵、Token、第三者の個人情報、実画面の機密プレビューは送らないでください。

## 対応方針

1. 影響範囲を切り分けます。
2. 必要に応じてPrivate Security Advisory上で修正します。
3. safety invariants、テスト、Community build、該当する実機検証を実施します。
4. Official releaseでは署名・manifest・SHA-256を検証します。
5. 利用者が必要とする回避・更新手順を公開します。

個人開発のため応答時間を保証できません。重大な問題では修正前に該当Releaseの利用停止を案内する場合があります。

## 署名鍵の侵害

Tabora Officialの自己署名秘密鍵が漏えいした場合は、既存権限の維持より明示的なtrust resetを優先します。

1. 影響するReleaseと旧証明書指紋を明示。
2. 旧証明書を廃止し、Tabora用の新しい証明書を作成。
3. 新旧fingerprintと移行理由を公開。
4. 必要に応じてTCC権限の削除・再許可を案内。
5. 新しいOfficial identityで再配布。

SnapFlowの署名identityはTaboraのOfficial identityとして使用しません。

詳細な脅威境界は[Documentation/THREAT_MODEL.md](Documentation/THREAT_MODEL.md)を参照してください。
