# Tabora

Taboraは、macOSのウィンドウを画面端・四隅・分割領域へ配置し、接続したウィンドウを共有境界からまとめてリサイズできる、無料・オープンソースのメニューバーアプリです。

## インストールと更新

1. [公式リリース](https://github.com/Pentagon22GIT/Tabora/releases/latest)から本体のZIP、SHA-256、マニフェストを取得します。
2. ハッシュと署名を確認し、展開した `Tabora.app` を `/Applications` または `~/Applications` に移動します。
3. 初回起動時に表示言語を選び、アクセシビリティを許可します。画像プレビューとログイン時の起動は任意です。

公式版はTabora専用の証明書による自己署名です。更新時はTaboraを終了して本体を置き換えてください。設定・サイズ制約は引き継がれます。メニューの「更新を確認…」は公式リリースをブラウザで開きます。

## ウィンドウの操作

| やりたいこと | 操作 |
|---|---|
| 画面を分割する | ウィンドウを画面の端や隅へドラッグし、空いた枠に置くウィンドウを候補から選びます。 |
| 分割幅を変える | 「共有リサイズ」を有効にして境界をドラッグすると、両側のウィンドウが一緒に変形します。 |
| もう一つ枠を作る | 「グループの枠をさらに分割」を有効にし、半分を占めるウィンドウを同じ側の隅へ配置します。空いた隅に候補が出ます。 |
| ジェスチャーで配置する | 「ジェスチャー」で8方向スナップを有効にし、Optionを押しながら2本指でスワイプします。 |
| グループの窓を選び直す | 「相対的ジェスチャ」と「ジェスチャーでグループを再配置」を有効にします。グループ全体が手前にあるとき、自分の枠へスワイプして候補を選びます。キャンセルすると元の配置を保ちます。 |

分割率はディスプレイごとに設定できます。実際の配置では、各ウィンドウの最小・最大サイズに合わせて境界を調整します。キーボードで操作する場合は「コマンド設定」でショートカットを割り当てます。

### Mission Control

グループの表示にはアプリアイコンまたはウィンドウ画像を使います。「試験的機能」では、Mission Control内での画像更新と、グループの別Desktopへの移送を個別に有効にできます。移送にはAppleの非公開APIを使用するため、macOSの更新によって利用できなくなる場合があります。

## 動作環境と権限

動作保証の対象はmacOS 26以降です。macOS 13〜15向けの互換処理も維持しています。表示言語は日本語、英語、韓国語、簡体字中国語、繁体字中国語から選べます。

| 権限 | 用途 |
|---|---|
| アクセシビリティ | ウィンドウの位置やサイズを取得し、配置・リサイズします。 |
| 画面収録（任意） | 「プレビューをウィンドウ画像にする」がオンのとき、配置候補やMission Controlに対象ウィンドウの画像を表示します。オフではアプリアイコンを使います。 |

権限は「システム設定 → プライバシーとセキュリティ」で変更できます。画像はメモリ内だけで扱います。設定やサイズ制約の保存先、権限の解除については[プライバシーポリシー](PRIVACY.md)を参照してください。

## 設定とデータの削除

「設定 → 一般 → 削除する項目を選ぶ…」で、設定のみ、アプリ別サイズ制約のみ、全ディスプレイの分割率のみ、または全データとアプリ本体を選択できます。実行前に再確認し、対象は実行中のエディションだけです。全削除はログイン項目を解除し、本体をゴミ箱へ移動します。画像キャッシュはメモリ内だけにあり、終了時に解放します。

本体の自動削除は `/Applications` または自分の `~/Applications` にある実行中のTaboraに限定します。開発フォルダ、ダウンロード先、シンボリックリンクからの本体削除は拒否します。OSの権限・診断記録、他エディション、他のコピー、手動で書き出したファイル、未知のファイル、空の保存ディレクトリは削除しません。

## Community版をビルド

開発用のCommunity版は公式版と別のBundle ID・署名を使い、設定と権限も独立しています。ビルドにはmacOS 26のスクリーンショットAPIを含むSDKが必要です。

```zsh
git clone https://github.com/Pentagon22GIT/Tabora.git
cd Tabora
./Scripts/build-community.sh
```

出力先は次のとおりです。

```text
build/community/Tabora Community.app
```

既存の出力先は保護されます。再ビルドには環境変数 `TABORA_BUILD_OUTPUT_DIR` で未使用の絶対パスを指定できます。インストールには次のスクリプトを使用します。

```zsh
./Scripts/install-community.sh
```

## 詳細資料

- 全体構成と処理境界: [ARCHITECTURE.md](Documentation/ARCHITECTURE.md)
- プロジェクトの由来と移行監査: [ORIGIN.md](Documentation/ORIGIN.md) / [MIGRATION_AUDIT.md](Documentation/MIGRATION_AUDIT.md)
- 多言語対応の対象と保守手順: [LOCALIZATION.md](Documentation/LOCALIZATION.md)
- Mission ControlのDesktop間グループ移送: [PRIVATE_API_GROUP_SPACE_MIGRATION.md](Documentation/PRIVATE_API_GROUP_SPACE_MIGRATION.md)
- 最前面監視のevent・gate・fallback境界: [FOREGROUND_MONITORING.md](Documentation/FOREGROUND_MONITORING.md)
- 常駐負荷と性能の実測結果: [PERFORMANCE_VALIDATION.md](Documentation/PERFORMANCE_VALIDATION.md)
- セキュリティ境界: [THREAT_MODEL.md](Documentation/THREAT_MODEL.md) / [SECURITY_INVARIANTS.md](Documentation/SECURITY_INVARIANTS.md)
- バージョンごとの変更履歴: [CHANGELOG.md](CHANGELOG.md)

## セキュリティ

Accessibilityと画面収録は強い権限です。公式版を確認するときは名前やアイコンだけでなく、公式repository、Release、署名、ハッシュを組み合わせて確認してください。

- [Security Policy](SECURITY.md)
- [Threat Model](Documentation/THREAT_MODEL.md)
- [Security Invariants](Documentation/SECURITY_INVARIANTS.md)

脆弱性は公開IssueではなくGitHub Private Vulnerability Reportingから報告してください。

## Contribution

Contributionは[CONTRIBUTING.md](CONTRIBUTING.md)に従ってください。通常の変更でも`./Scripts/test.sh all`とCommunity buildを実行し、window identity / group membership / shared resize / Recovery / Mission Controlの安全不変条件を弱めないことを要求します。

## License

Copyright 2026 Pentagon22GIT

Apache License 2.0で公開します。詳細は[LICENSE](LICENSE)と[NOTICE](NOTICE)を参照してください。
