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
- resizeから約2秒の安定後にMission Control Previewが現在内容へ更新されること
- Preview ON / OFF
- Mission Control Previewの16 / 32 / 128 MiB、cache解放、多数windowで15秒を跨ぐstale-while-revalidate
- Activity Monitorでidle / 複数group / 多数window / Preview ON・OFFのCPUとEnergy Impactを比較し、定常的な異常負荷がないこと
- settings / shortcuts
- v1.0.1以降では、straight boundaryを持つmulti-member replacement、misaligned boundaryの拒否、blocked後の既存group保持、drag / shortcut / menu parity

非公開APIを変更したReleaseでは、[PRIVATE_API_GROUP_SPACE_MIGRATION.md](PRIVATE_API_GROUP_SPACE_MIGRATION.md)のmacOS更新時の保守手順とRelease確認表も必須とします。compile成功やdispatch戻り値だけを互換性の根拠にせず、実Window→Space membershipで物理到達を確認します。

期待結果: 意図したrelease差分を除き、既存の安全不変条件と確立済み挙動を維持すること。

### 最新の完了記録

**2026-09-01 / 検証対象 v2.0.0 (Build 14) / 次期v2.0.1調整時点**

- [x] 2 / 3 / 4 split、shared resize、replacement、Recoveryを実機確認
- [x] Mission Control Proxy選択、Foreground、Desktop間group migrationを実機確認
- [x] Preview / Assist / App Constraint / Space移送の相互境界を監査
- [x] Private API runtime capabilityと実Window→Space membershipをmacOS 26.6.2で確認
- [x] 平常時のTabora直接CPUとWindowServer委託CPUを統合し、Full Residentを1コア約3.84% / 10コア全体約0.384%と確認
- [x] Memory / Wakeup / System CPU / Battery / Thermalを確認し、常駐上の異常増加がないことを確認
- [x] Architecture / Security Invariants / Foreground / Migration / Privacy / README / CHANGELOGの整合を確認
- [x] Fast CI / Tabora Safety Invariants / CodeQLのRelease監査状態を確認
- [x] dependency / secret alertとrelease差分のprivate data混入がないことを確認

性能検証の詳細は[PERFORMANCE_VALIDATION.md](PERFORMANCE_VALIDATION.md)に記録する。将来のReleaseではこの完了記録を根拠に手順自体を省略せず、変更範囲に応じて再確認する。

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
