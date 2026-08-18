# SnapFlow Final → Tabora v1.0.0 移行監査

日付: 2026-08-18

## Baseline

移行では、提供されたSnapFlow Final project archiveをbehavior baselineとして使用しました。

- SnapFlow Final version: 1.3.0
- Baseline archive SHA-256: `049ab054992cc2aea6737300f538205d4c897d71255448b97417b9d870ecfc23`
- baseline内のhistorical Git HEAD: `005af4b15fc256627e55f4346b05b91f1ae5a93d`
- baselineには検証済みのuncommitted working-tree changesが含まれていました。そのため、historical commit単体ではなくarchive自体がfrozen source stateを定義します。

## 移行だけで行った変更

- Swift package / executable target: `SnapFlow` → `Tabora`
- source target directory: `Sources/SnapFlow` → `Sources/Tabora`
- test target directory / imports: `SnapFlowTests` / `SnapFlow` → `TaboraTests` / `Tabora`
- application entry typeとuser-visible product stringをTaboraへ変更
- productを直接表すdiagnostic queue / notification identity stringをTaboraへ変更
- update URLを `Pentagon22GIT/Tabora` へ変更

## Identity変更

- Version: `1.3.0` → `1.0.0`
- Build number: `13` → `1`
- Official Bundle ID: `dev.pent.SnapFlow` → `dev.pent.Tabora`
- Community Bundle ID: `dev.pent.SnapFlow.community` → `dev.pent.Tabora.community`
- build artifact: `SnapFlow*.app` / `SnapFlow-<version>.zip` → `Tabora*.app` / `Tabora-<version>.zip`
- Info.plist provenance key: `SnapFlowEdition` / `SnapFlowSourceRevision` / `SnapFlowSourceDirty` → `Tabora...`
- 旧SnapFlow certificate fingerprintを削除し、Tabora専用Official fingerprint `B931AC85747B9B12E32751D3776AAFD3430E5A12` を設定済み（公開fingerprintのみ。private keyはrepository外）

## Documentation / repository変更

- active documentationをTabora v1.0.0向けに再構築
- version固有のhistorical SnapFlow release / validation文書をactive Tabora repositoryから除外
- 旧 `.git`、`.build`、build output、release output、`.DS_Store`、`__MACOSX`を除外
- project-owned `build/official`、`build/community`、`release` output directoryはdistributed project folder内に空の状態で維持
- GitHub URL、template、workflow、security metadataをTaboraへ移行
- 中間CI layerとしてsafety invariant workflowを追加

## Behavior変更の分類

**意図したbehavior変更: なし。**

移行中にtimer interval、geometry calculation、AX mutation rule、group membership algorithm、Recovery algorithm、Mission Control authorization rule、cursor rule、snap decision、resize ruleを意図的には変更していません。

3-window layoutを移行専用の特殊対象にはしていません。継承した構造規則は2 / 3 / 4 split layoutで共通です。

## 移行環境で実施した検証

- file / directory identity audit
- active code / config / scripts / GitHub metadata全体の旧product名scan
- frozen baselineに対するsource / test transformの完全比較
- 既存build scriptがbaseline scriptのidentity-only transformであることを確認
- `swift package dump-package` がpackage / product `Tabora`、target `Tabora` / `TaboraTests` で成功
- 全Sources / Testsに対する `swiftc -parse` が成功
- `swift test` は実行を試みたが、このLinux環境には `AppKit` moduleがないためcompile段階で失敗
- この環境には `zsh` がないためzsh script syntaxは実行していない。script自体は検証済みbaseline scriptのidentity-only transform
- secret / generated-artifact hygiene scan
- Markdown local-link / YAML syntax check
- package ZIP再構築とcontent audit

## この文書では成功扱いしない検証

移行環境はAppKit / Accessibility / Window Server integrationを持つmacOS runtimeではありません。そのため、この文書はTaboraのruntime functional-equivalence test、Community app build、Official app build、Mission Control挙動、TCC挙動がmacOSで成功したとは主張しません。

SnapFlow Final Baseline自体は移行前にユーザーが動作確認済みです。Tabora Official Release前には、同等のmacOS functional suiteを改めて実行する必要があります。
