# Release手順

この手順はsource、Community build、Tabora Official buildの分離を維持します。

## 1. 前提条件

- public `Pentagon22GIT/Tabora` repositoryから作業する。
- working treeがcleanであること。
- `VERSION` が予定しているsigned tag（`v<version>`）と一致すること。
- `BUILD_NUMBER` は最新の公開releaseに含まれるbuild number + 1とすること。未stage / 未releaseの試行ごとに番号を増やさないこと。
- private key、token、credential、生成済みapp bundleをtrackしないこと。
- `Config/OfficialSigning.plist` に `dev.pent.Tabora` とTabora専用code-signing certificate fingerprintが設定されていること。

## 2. 検証

macOS上で次を実行します。

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

その後、SnapFlow Final Baselineで使用したfunctional suiteと同等以上の確認を行います。最低限:

- 2 / 3 / 4 split
- linked / shared resize
- 正当なnative-resize departure
- active / inactive replacement snap
- shared-boundary cursor / input ownership
- temporary AX failure時の挙動
- relevant external occluderの出現 / 消失
- Recovery
- Mission Control
- 新規設定で内部画像更新がOFFであること、OFFでは通常画像を維持し、内部再取得を開始しないこと。ON/OFFの変更、取得枠待機中のOFF、連続開閉・選択中の遅延結果を確認すること
- Debug / Releaseの両方でPreview取得・安定判定の診断出力と診断専用の計時処理が含まれないこと。今回のソースから再ビルドし、旧バイナリを検証・配布に流用しないこと。設定保存・サイズ制約・プレビュー機能は維持すること
- 内部画像更新ONではクリック中の完成画像が同じsessionのbutton解放後に適用され、選択・終了後には適用されないこと。nil時の再試行は1回で止まり、通常画像・HOT/COLD・group選択を阻害しないこと
- 「一般 → 拡張機能」がウィンドウ移動とドラッグ判定の間にあり、Option Assistの保存済みON/OFFが維持されること。5言語で新しい試験的設定と説明が表示されること
- 試験的なDesktop間グループ移送をOFFのままにした時、既存Proxy選択・前面化・通常Space分離が変化しないこと
- 試験的なDesktop間グループ移送をONにし、2 / 3 / 4 memberでsource→destination→sourceの往復、全member membership、移送後layout、restore frame、group再構成を確認すること
- 非公開move runtimeを意図的に利用不能とした検証buildで、通常Desktop復帰後に一度だけ警告され、設定からOFFにできること。設定欄のAPI状態と動作確認済み環境も確認すること
- pre-commit timeout / feature OFF / structure変化ではdispatch済みmemberが実行時originへ復元されることを確認し、post-commit layout失敗ではSpaceを戻さずdestinationでgroupだけが解散すること
- Mission Controlから通常Desktopへ戻った直後、および移送完了後に再度Proxyを選択した時、2 / 3 / 4 memberで数秒単位のmain-thread停止が発生しないこと。AX応答が遅いappでも実際のAXRaise/focus budgetは0.45秒の既存interactive値を維持し、短いtimeoutによる明示選択の取りこぼしを導入していないこと
- physical commit後のlayout中にTabora生成のfloating group画像が最前面へ出ないこと。実window自身のframe更新が一時的に見えることは許容し、cover撤去後もmembership verify、layout、group commit、Proxy rearmが従来順序で完了すること
- Mission Control group proxyが候補集合から欠落しないこと（2 / 3 / 4、snap直後、rapid enter / exit）
- cold launch直後の最初のdragでsnap guideを失わないこと
- resize直後のMission Control Previewがfresh capture完了前も全面を表示し、中央aspect-fill cropで過度に拡大・切り取りされないこと
- resize停止後の0.15秒one-shot再観測でMission Control Previewが現在内容へ更新され、連続resize中は取得を開始しないこと
- Preview ON / OFF
- Mission Control Previewの合計表示32 / 64 / 256 MiB（各値の半分を通常cache、残り半分をtransientへ割当）、cache解放、多数group/displayでのFIFO完走、HOT/COLD連続往復とresize連打時のcooldown・要求合流
- Activity Monitorでidle / 複数group / 多数window / Preview ON・OFFのCPUとEnergy Impactを比較し、定常的な異常負荷がないこと
- settings / shortcuts
- 5言語の設定、メニュー、Alert、Panel、権限説明を確認し、言語選択時に適用ボタンだけが選択先言語へ即時更新されること
- 言語適用で同じapp bundleが一度だけ再起動し、全UIへ反映されること。App Constraint計測中は再起動せず、helper起動失敗時は現在processと保存言語を維持すること
- 初回言語決定、日本語fallback、保存後にmacOS言語変更へ追従しないこと、および全言語のkey / placeholder一致を`LocalizationTests`で確認すること
- v1.0.1以降では、straight boundaryを持つmulti-member replacement、misaligned boundaryの拒否、blocked後の既存group保持、drag / shortcut / menu parity

非公開APIを変更したReleaseでは、[PRIVATE_API_GROUP_SPACE_MIGRATION.md](PRIVATE_API_GROUP_SPACE_MIGRATION.md)のmacOS更新時の保守手順とRelease確認表も必須とします。compile成功やdispatch戻り値だけを互換性の根拠にせず、実Window→Space membershipで物理到達を確認します。

期待結果: 意図したrelease差分を除き、既存の安全不変条件と確立済み挙動を維持すること。

### 現行Release状態

**Tabora v2.3.0 (Build 21) / 2026-10-12 — macOS検証未完了**

- [x] 取得方式の選択を共通ルーティングへ集約し、Mission Control内では全サイズ取得を優先し、必要時のみ通常取得へfallbackする実装へ更新
- [x] 通常取得と補完が同じcapture枠を保持し、group適用・cache分離・終了時破棄へ既存経路で接続することをコードレビュー
- [x] Version / Build、README、設計・権限文書を同期
- [x] Preview取得・安定判定のデバッグ診断機能と専用計時をソースから削除（Debug / Release共通）。設定保存と公開ツールは維持
- [ ] 再ビルドしたCommunity / Officialで診断文字列・出力経路の除去と、既存画像取得・設定保存の実動作を確認
- [ ] macOS上で`swift test`とCommunity buildを完走（追加6テストを含む）
- [ ] macOS 26 / 27で同じwindow内容・寸法を比較し、通常画像と全サイズ画像の実画素の文字輪郭、透明余白、欠落、色、縦横比を確認。寸法が大きいだけでは合格にしない
- [ ] 1x / Retina、2 / 3 / 4分割、多数group、multi-displayで補完の適用とメモリ・応答時間を確認
- [ ] 補完不可・画面収録拒否/取消・window終了時に新しい誤対象画像が表示されず、既存の表示/破棄経路へ戻ることを確認
- [ ] Mission Controlの連続開閉、Preview OFF、cache解放、選択handoff、Space移送、sleep/wakeで旧結果が復活しないことを確認
- [ ] 既存の2 / 3 / 4 split、shared resize、Assist、foreground、Space migrationのfunctional suiteを完走
- [ ] 対象アプリ終了後にGroup、Mission Control Proxy、Preview画像が残らないことを実機確認

上の未完了項目が残る間は、修正済み正式配布版やmacOS 27互換性確認済みとは扱いません。過去の実機確認を今回の変更へ自動継承しません。

### 常駐性能

常駐性能の比較基準は **v2.2.0 Build 17 / 2026-09-05** のR0〜R6です。今回の全サイズ優先取得は操作中の取得経路変更なので、実測まで高速化や負荷不変を主張しません。[PERFORMANCE_VALIDATION.md](PERFORMANCE_VALIDATION.md)を正本とします。

## 3. Security確認

- Fast CI成功
- Tabora Safety Invariants成功
- Official Release前にlatest `main` のCodeQL analysis成功
- dependency / secret alertを確認済み
- release diffにprivate dataや生成されたlocal artifactが含まれていない

## 4. Tag

正確なclean commitにsigned annotated tagを作成します。

```zsh
VERSION_VALUE="$(cat VERSION)"
git tag -s "v${VERSION_VALUE}" -m "Tabora v${VERSION_VALUE}"
git verify-tag "v${VERSION_VALUE}"
```

公開済みrelease tagを移動・再作成してはいけません。

## 5. Official package

```zsh
./Scripts/package-release.sh
```

scriptはsigned tag、clean source state、Official identity、source revision、Universal 2 architecture、designated requirementを検証し、`release/v<version>/` 配下へrelease assetを生成します。

## 6. Release公開

同一のverified runから生成されたarchive、SHA-256 file、`release-manifest.json`を公開します。permissionまたはsigning identityに変更がある場合はRelease noteへ明記します。

## 7. Signing identity変更

Tabora Official certificateを変更する場合、旧trust assumptionを黙って維持してはいけません。旧 / 新certificate fingerprintを公開し、必要なTCC reset / re-authorizationを説明します。
