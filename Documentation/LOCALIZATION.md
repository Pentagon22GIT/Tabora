# 多言語対応

この文書はTabora v2.1.0以降のアプリ内localizationの対象、初期言語決定、適用境界、resource構成、Release監査手順を定義します。README、CHANGELOG、`Documentation/`などの開発文書は日本語を正本とし、多言語化の対象外です。

## 対応言語

| 言語 | resource identifier | 初回判定の代表例 |
| --- | --- | --- |
| 日本語 | `ja` | `ja`, `ja-JP` |
| English | `en` | `en`, `en-US` |
| 한국어 | `ko` | `ko`, `ko-KR` |
| 简体中文 | `zh-Hans` | `zh`, `zh-Hans`, `zh-CN`, `zh-SG` |
| 繁體中文 | `zh-Hant` | `zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO` |

初回起動時は`Locale.preferredLanguages`の先頭要素だけを評価します。未対応言語、値を取得できない場合、不正な保存値は日本語へfallbackします。決定した値は`UserDefaults`の`appLanguage`と`AppleLanguages`へ保存し、以後はmacOSの言語順やアプリ更新によって自動変更しません。

## Resourceとsource of truth

- `Sources/Tabora/Resources/<language>.lproj/Localizable.strings`がアプリ内表示の正本です。
- `Sources/Tabora/Resources/<language>.lproj/InfoPlist.strings`がAccessibilityと画面収録の権限説明を提供します。
- key集合とformat placeholderは5言語で完全一致させます。選択言語の翻訳が解決できない場合は日本語resourceへfallbackし、日本語resource自体の欠落はtestとOfficial package検証で防ぎます。
- 文脈に合うmacOS標準の表現を優先し、単語単位の直訳より操作結果と安全上の意味を一致させます。format placeholder、改行、単位、ショートカット記号は原文の意味を維持します。
- Swift sourceへ新しい利用者向け表示literalを直接追加せず、`L10n.text`または`L10n.format`を使用します。

対象には設定、メニューバー、Alert、sheet、非modal panel、Snap / Assist / Resize overlay、App Constraint、Mission Control Proxy / reservation shadow、権限説明を含みます。debug-only log、symbol、永続key、URL、Bundle ID、開発文書は翻訳しません。

## 言語選択と再起動境界

言語選択は設定の「一般」に置き、各項目をその言語自身の名称で表示します。選択を変えた時点ではアプリ全体を書き換えず、適用ボタンだけを選択先の翻訳へ即時更新します。これにより現在の言語を読めない利用者も適用操作を識別できます。

適用時は次の境界を守ります。

1. 現在と同じ言語なら何もしない。
2. App Constraintの明示計測中ならlocalized alertを表示し、計測もprocessも中断しない。
3. 実行元が`.app` bundleでない場合、またはrelaunch helperを起動できない場合は保存せず終了しない。
4. helperを起動できた後だけ選択を保存して同期し、現在processを正常終了する。
5. helperは親processの終了を最大15秒確認し、終了後に同じbundle pathを`/usr/bin/open -g`で一度だけ開く。期限内に終了しなければ再起動しない。
6. 次回起動で保存済み言語を一度だけ読み、全UIを同じ言語resourceから構築する。

この経路はwindow placement、group、resize、Recovery、Mission Control migration stateを移行・再生しません。通常のアプリ終了と新規起動の境界を使用します。

## 追加・変更時の監査

- すべての利用者向け文字列の生成点を`rg`で再走査し、menu、Alert、panel、overlay、accessibility label、権限説明を確認する。
- `LocalizationTests`で初回mapping、初回だけの保存、不正値の日本語修復、5言語のkey集合、placeholder、InfoPlist key、Swift sourceの日本語literal不在を確認する。
- `Package.swift`、Community / Official build、Official verificationが5つの`.lproj`と両`.strings`をbundleへ含めることを確認する。
- 各言語でcold launch、設定全カテゴリ、メニュー、Snap / Assist / Resize、App Constraint、Mission Controlのpopup / overlayを実機確認する。
- 言語選択時に適用ボタンだけが即時翻訳され、適用後に同じappが一度だけ再起動し、全表示と権限説明が選択言語になることを確認する。
- 計測中の拒否、helper起動失敗、未対応言語、不正な保存値が既存処理を中断せず日本語または現在processへ安全に収束することを確認する。

新しい言語や文字列を追加するReleaseでは、翻訳だけでなく同じkey / placeholder / packaging / runtime surface監査をRelease条件とします。
