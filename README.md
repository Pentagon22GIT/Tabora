# Tabora

Taboraは、macOSのウィンドウを画面端・四隅・分割領域へ配置し、接続したウィンドウを共有境界からまとめてリサイズできる、無料・オープンソースのメニューバーアプリです。

Tabora v1.0.0は、技術的に完成したSnapFlow Final v1.3.0の挙動を凍結し、製品identity、version、ドキュメント、署名trust domain、GitHub基盤だけを新しいプロジェクトとして移行したものです。移行そのものによるSnap / Group / Resize / Recovery / AX / Mission Controlのアルゴリズム変更は行いません。由来と移行境界は[ORIGIN.md](Documentation/ORIGIN.md)と[MIGRATION_AUDIT.md](Documentation/MIGRATION_AUDIT.md)を参照してください。

## 主な機能

- 左右半分、上下半分、四隅、最大化へのスナップ
- 残り領域を使う配置アシスト
- 2 / 3 / 4ウィンドウ構成を含む接続グループ
- 共有境界による連動リサイズ
- macOS風 / Windows風 / 統合型の共有リサイズ表示
- スナップ済みウィンドウの移動時復元
- inactive / active双方の置き換えスナップ
- 通常クリック、Mission Control、アプリ切替等に連動した接続グループ前面化
- 低頻度Recovery watchdogによる一時的なAX / Window Server不整合からの復旧
- 任意のグローバルショートカット
- 任意の配置候補プレビュー

詳細な構成は[ARCHITECTURE.md](Documentation/ARCHITECTURE.md)を参照してください。

## 動作環境

- macOS 13以降
- Swift 5.9以降（ソースからビルドする場合）
- AppKit / Accessibility / Window Server APIを使用するためmacOS上でのビルド・実行が必要

## 必要な権限

### Accessibility

ウィンドウの取得、移動、サイズ変更、ドラッグ状態の確認に使用します。

```text
システム設定 > プライバシーとセキュリティ > Accessibility
```

### 画面収録

設定で配置候補のウィンドウ画像を有効にした場合だけ使用します。通常のスナップや共有リサイズには不要です。

```text
システム設定 > プライバシーとセキュリティ > 画面収録
```

TaboraはSnapFlowとは別Bundle ID・別署名identityの新しいアプリです。SnapFlowへ与えたTCC権限をTaboraが引き継ぐことを前提にせず、必要な権限はTaboraへ改めて許可してください。

## Official / Community

| 種類 | Official | Community |
|---|---|---|
| 表示名 | Tabora | Tabora Community |
| Bundle ID | `dev.pent.Tabora` | `dev.pent.Tabora.community` |
| 用途 | Maintainerによる正式配布 | 開発・検証・改造 |
| 署名 | Tabora専用の固定自己署名identity | Ad-hoc |
| 権限領域 | Official固有 | Officialと分離 |

SnapFlowの公式署名identityはTaboraへ流用しません。Tabora専用の自己署名Code Signing identityは作成済みで、`Config/OfficialSigning.plist`には公開SHA-1 fingerprint `B931AC85747B9B12E32751D3776AAFD3430E5A12` が設定されています。秘密鍵・`.p12`・passwordはrepositoryへ含めません。

## Official版のインストール

Official Releaseが公開されている場合は、公式repositoryのReleasesから同じReleaseに含まれる`Tabora-<version>.zip`、`.sha256`、`release-manifest.json`を取得し、SHA-256と署名identityを確認してから展開します。`Tabora.app`を`~/Applications`または`/Applications`へ移動し、macOSの案内に従って初回起動と必要な権限を許可してください。

TaboraはApple Developer ID / Notarizationを前提にしない自己署名OSSとして設計されています。Gatekeeper警告を無効化するコマンドやquarantine属性の強制削除を標準手順にはしません。

## Community版をビルド

```zsh
git clone https://github.com/Pentagon22GIT/Tabora.git
cd Tabora
chmod +x Scripts/*.sh
./Scripts/build-community.sh
```

出力先:

```text
build/community/Tabora Community.app
```

インストールまで行う場合:

```zsh
./Scripts/install-community.sh
```

## Official版

Official版はMaintainerだけが作成します。Tabora専用の署名証明書を設定したうえで、cleanなGit状態から次を使用します。

```zsh
./Scripts/build-official.sh
./Scripts/verify-official.sh
```

Release手順は[RELEASE_PROCESS.md](Documentation/RELEASE_PROCESS.md)、初期署名・repository設定は[MAINTAINER_SETUP.md](Documentation/MAINTAINER_SETUP.md)を参照してください。

## 更新

メニューバーの「更新を確認…」は次の公式GitHub Releasesページを既定ブラウザで開きます。

```text
https://github.com/Pentagon22GIT/Tabora/releases/latest
```

Tabora自身にHTTPクライアント、自動更新ダウンローダー、自己置換処理はありません。

## Privacy

Taboraはウィンドウ情報と設定をローカルで扱います。解析、広告、テレメトリー、クラッシュレポート自動送信は実装していません。プレビュー画像は利用者が有効にした場合だけ取得し、メモリ上で使用します。

詳細: [PRIVACY.md](PRIVACY.md)

## Security

Accessibilityと画面収録は強い権限です。公式版を確認するときは名前やアイコンだけでなく、公式repository、Release、署名、ハッシュを組み合わせて確認してください。

- [Security Policy](SECURITY.md)
- [Threat Model](Documentation/THREAT_MODEL.md)
- [Security Invariants](Documentation/SECURITY_INVARIANTS.md)

脆弱性は公開IssueではなくGitHub Private Vulnerability Reportingから報告してください。

## Contributing

Contributionは[CONTRIBUTING.md](CONTRIBUTING.md)に従ってください。通常の変更でも`swift test`とCommunity buildを実行し、window identity / group membership / shared resize / Recovery / Mission Controlの安全不変条件を弱めないことを要求します。

## プロジェクト構成

```text
Tabora/
├── Sources/Tabora/
├── Tests/TaboraTests/
├── Scripts/
├── Config/
├── Documentation/
├── .github/
├── build/
│   ├── official/
│   └── community/
└── release/
```

`build/`と`release/`は成果物の出力先です。この配布projectでは既存成果物を含めません。SwiftPMが生成する`.build/`、旧Git履歴、Finder metadataも含めません。

## License

Copyright 2026 Pentagon22GIT

Apache License 2.0で公開します。詳細は[LICENSE](LICENSE)と[NOTICE](NOTICE)を参照してください。
