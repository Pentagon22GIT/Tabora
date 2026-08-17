# Contributing to Tabora

Contributionを歓迎します。別途明示しない限り、提出されたContributionはApache License 2.0の条件でTaboraへ提供されます。

## 開発手順

```zsh
git switch main
git pull --ff-only origin main
git switch -c feature/short-description
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

branchは目的に応じて`feature/`、`fix/`、`docs/`、`security/`を使用し、1 branch = 1目的を基本とします。公開後の`main`へ直接開発せず、Pull Requestを経由してSquash Mergeします。

## Pull Request

- 1つのPull Requestでは1つの目的を扱ってください。
- 動作変更には理由、影響範囲、確認方法を記載してください。
- Window existence / interaction eligibility / discovery completenessを混同しないでください。
- AXのtemporary failureをconfirmed missingとして扱わないでください。
- 2 / 3 / 4 split、shared resize、native-resize departure、Recovery、Mission Controlの既存安全不変条件を弱めないでください。
- Accessibility、Screen Capture、署名、build/release、外部通信へ触れる場合はSecurity / Privacyへの影響も記載してください。
- 秘密鍵、Token、個人情報、実画面の機密情報を含めないでください。
- Official Bundle IDやOfficial署名identityをCommunity buildへ使用しないでください。

最低限:

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

安全性に関係する変更では、`.github/workflows/safety-invariants.yml`が対象とするテスト群も確認してください。

## セキュリティ問題

未公開の脆弱性はIssueや通常PRへ投稿せず、[SECURITY.md](SECURITY.md)の非公開報告手順を使用してください。
