# Tabora

Taboraは、macOSのウィンドウを画面端・四隅・分割領域へ配置し、接続したウィンドウを共有境界からまとめてリサイズできる、無料・オープンソースのメニューバーアプリです。

Tabora v1.0.0は、技術的に完成したSnapFlow Final v1.3.0の挙動を凍結し、製品identity、version、ドキュメント、署名trust domain、GitHub基盤だけを新しいプロジェクトとして移行したものです。移行そのものによるSnap / Group / Resize / Recovery / AX / Mission Controlのアルゴリズム変更は行いません。由来と移行境界は[ORIGIN.md](Documentation/ORIGIN.md)と[MIGRATION_AUDIT.md](Documentation/MIGRATION_AUDIT.md)を参照してください。

Tabora v2.0.0は、実際のWindow→Space membershipを用いるグループ分離判定と、Mission Control上のグループProxyを別Desktopへドロップして実ウィンドウ群を移送する試験的機能を追加します。移送はMission Control内で予約し、exact PID + Window IDで一致した実ウィンドウ画像へ入力透過の予約shadowを表示します。Shadowは受理済み予約scene中だけ起動する表示専用10 Hz observerで管理し、操作中は即時hideしてWindow Server geometry取得も止めます。mouse-up後はOSのretilingが静止したことを複数frameで確認してから復帰し、settle後は各group 1枚のsentinelだけを判定対象にします。Mission Controlのlive thumbnail frameはon-screen Window Server listから取得し、予約済みexact PID + CGWindowIDだけをfilterして使います。終了側はfadeせずfail-closedで即時退避し、application activationなどの早期hint後に古いone-shot/capture refreshがShadowを再点灯させないrearm gateを持ちます。閉じた後は複数グループをFIFOで一件ずつ移送します。通常移送はz-orderを変更しませんが、「移動準備中／移動待機」のqueued Proxyを明示選択した場合だけ、成功済みgroupを全FIFO terminal後に一度だけ前面化するpost-migration intentを記録します。移送は初期OFFで、非公開APIは独立Bridge / Backendへ隔離しています。Shadow observerとforeground intentはtransport/FIFO/rollbackへ状態を返しません。詳細は[PRIVATE_API_GROUP_SPACE_MIGRATION.md](Documentation/PRIVATE_API_GROUP_SPACE_MIGRATION.md)を参照してください。

## 主な機能

- 左右半分、上下半分、四隅、最大化へのスナップ
- 残り領域を使う配置アシスト
- 試験的なOption（⌥）ホールド式2 / 3 / 4分割Assist切り替え（初期OFF）
- 2 / 3 / 4ウィンドウ構成を含む接続グループ
- 共有境界による連動リサイズ
- macOS風 / Windows風 / 統合型の共有リサイズ表示
- スナップ済みウィンドウの移動時復元
- inactive / active双方の置き換えスナップ
- 通常クリック、Mission Control、アプリ切替等に連動した接続グループ前面化
- 低頻度Recovery watchdogによる一時的なAX / Window Server不整合からの復旧
- 任意のグローバルショートカット
- 任意の配置候補プレビュー
- Mission ControlのグループProxyによるDesktop間移送（試験的・初期OFF）

詳細な構成は[ARCHITECTURE.md](Documentation/ARCHITECTURE.md)、最前面監視のevent / gate / fallback境界は[FOREGROUND_MONITORING.md](Documentation/FOREGROUND_MONITORING.md)を参照してください。

## 動作環境

- macOS 13以降
- Swift 5.9以降（ソースからビルドする場合）
- AppKit / Accessibility / Window Server APIを使用するためmacOS上でのビルド・実行が必要

試験的なDesktop間グループ移送はApple非公開のSkyLight APIを実行時に解決します。設定は初期OFFで、対応symbol / class / selector / display解決のいずれかが不足する環境では移送を開始しません。APIを呼び出せない場合は警告し、設定画面にも現在状態とmacOS 26.5.2 / 26.6.2での動作確認情報を表示します。macOS更新後の動作は保証されません。

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

## プライバシー

Taboraはウィンドウ情報と設定をローカルで扱います。解析、広告、テレメトリー、クラッシュレポート自動送信は実装していません。プレビュー画像は利用者が有効にした場合だけ取得し、メモリ上で使用します。

詳細: [PRIVACY.md](PRIVACY.md)

## セキュリティ

Accessibilityと画面収録は強い権限です。公式版を確認するときは名前やアイコンだけでなく、公式repository、Release、署名、ハッシュを組み合わせて確認してください。

- [Security Policy](SECURITY.md)
- [Threat Model](Documentation/THREAT_MODEL.md)
- [Security Invariants](Documentation/SECURITY_INVARIANTS.md)

脆弱性は公開IssueではなくGitHub Private Vulnerability Reportingから報告してください。

## Contribution

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
