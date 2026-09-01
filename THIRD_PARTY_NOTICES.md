# 第三者コンポーネントに関する通知

Tabora v2.1.0のアプリ本体には、外部Swift Packageや同梱された第三者バイナリ依存はありません。AppleがmacOSの一部として提供するSystem Frameworkへリンクします。v2.1.0の試験的なDesktop間グループ移送は、実行時にAppleの非公開SkyLight frameworkを動的解決します。これは公開API契約ではなく、macOS更新で利用不能になる可能性があります。多言語対応はアプリ内のsource resourceだけで構成し、翻訳SDK、外部翻訳service、追加fontを組み込みません。

- AppKit
- ApplicationServices
- CoreGraphics
- QuartzCore
- Carbon
- ServiceManagement

これらはTaboraのApache License 2.0によって再ライセンスされるものではなく、利用者のmacOSに含まれる各ライセンス条件が適用されます。

GitHub ActionsではGitHub提供の`actions/checkout`と`github/codeql-action`をbuild / analysis時に使用します。これらはTabora.appへ組み込まれません。Workflow参照はSupply Chain保護のため完全なcommit SHAへ固定しています。

外部依存を追加する場合は、Release前にこの文書、Package.resolved（存在する場合）、LICENSE / NOTICE、Security / Privacy文書を監査してください。
