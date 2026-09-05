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

**Tabora v2.2.1 (Build 18) / 2026-09-05**

v2.2.1は、v2.2.0で確立したtrigger-only Previewとevent-driven foregroundを維持したまま、HOT/COLDのvisibility境界とmulti-displayのphysical scopeを修正するReleaseです。新しい常駐polling、画像取得timer、Space polling、全Desktop AX censusは追加しません。

- [x] Preview HOT/COLDをGroup-level state + member-relative physical observationへ整理し、`COLD-visible`と`COLD-not-visible`を分離
- [x] dialog / system dialog / modal / exact sheetだけを明示的auxiliaryとして除外し、未知/custom subroleは`UNKNOWN`へ保持
- [x] UNKNOWN candidateが入れ替わってもGroup-level physical occlusion confirmationを無期限に再開しない有限budgetを実装
- [x] not-visible境界で旧`coldConfirmed` commit authorizationだけを失効し、`geometryConfirmed`を独立維持
- [x] Preview OFF時にPreview専用visibility / semantic classificationを上流から停止
- [x] off-Space Groupをgeneric presentation failure debtへ積まず、復帰時は既存Space reconciliationから再構築
- [x] multi-display foregroundのstrict判定を対象Groupのphysical Displayへscopeし、隣接Displayの共有1 pt境界spillによる不要なwhole-group raiseを除去
- [x] 同じdisplay-scoped strict判定をprovisional Snap peerへ適用し、Snap成立条件を緩めずcross-display誤除外を防止
- [x] 可視な別Display上ですでにtopのGroupを直接操作した場合、foreground ONのまま不要な実window再orderingが発生しないことを実操作で確認
- [x] Group上に実際のoccluderが存在する場合は従来どおりevent-driven whole-group raiseが成立することを実操作で確認
- [x] 可視Display間の移動で余分なPreview画像取得が発生しないことを実操作で確認
- [ ] final sourceで`swift test`とCommunity buildをmacOS上で完走
- [ ] Release asset生成前に2 / 3 / 4 split、shared resize、Mission Control、Space migration、Preview ON/OFFの最終functional suiteを完走

### 常駐性能

常駐性能の正式基準は **v2.2.0 Build 17 / 2026-09-05** のR0〜R6計測を維持します。v2.2.1で変更した経路はwindow click、foreground transition、occlusion、Space/display遷移、Snap操作などのイベント発生時に動作し、無操作の常駐計測では変更箇所を直接評価しません。

v2.2.1では常駐timer / polling / capture triggerを追加していないため、同じ無操作計測を新しい性能値として重複記録しません。既存値をv2.2.1で計測した値として読み替えることも行いません。正式な常駐比較値は[PERFORMANCE_VALIDATION.md](PERFORMANCE_VALIDATION.md)を正本とします。

過去Releaseの実機確認履歴はCHANGELOGと各機能文書に保持し、現行Releaseではこの手順を省略せず変更範囲に応じて再確認します。

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
