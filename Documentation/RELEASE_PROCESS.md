# Release手順

この手順はsource、Community build、Tabora Official buildの分離を維持します。

## 1. 前提条件

- public `Pentagon22GIT/Tabora` repositoryから作業する。
- working treeがcleanであること。
- `VERSION` が予定しているsigned tag（`v<version>`）と一致すること。
- `BUILD_NUMBER` に予定しているbuild numberが入っていること。
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
- Mission Control group proxyが候補集合から欠落しないこと（2 / 3 / 4、snap直後、rapid enter / exit）
- cold launch直後の最初のdragでsnap guideを失わないこと
- previewが低解像度のまま拡大表示されないこと
- Preview ON / OFF
- Mission Control Previewの16 / 32 / 128 MiB、cache解放、多数windowで15秒を跨ぐstale-while-revalidate
- Activity Monitorでidle / 複数group / 多数window / Preview ON・OFFのCPUとEnergy Impactを比較し、定常的な異常負荷がないこと
- settings / shortcuts
- v1.0.1以降では、straight boundaryを持つmulti-member replacement、misaligned boundaryの拒否、blocked後の既存group保持、drag / shortcut / menu parity

期待結果: 意図したrelease差分を除き、既存の安全不変条件と確立済み挙動を維持すること。

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
