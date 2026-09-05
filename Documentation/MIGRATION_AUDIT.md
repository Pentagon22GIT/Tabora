# SnapFlow Final → Tabora v1.0.0 移行記録

移行日: 2026-08-18

この文書は、SnapFlow FinalからTaboraへproduct identityを分離した時点のsource lineageと、移行で変更した範囲を固定する開発記録です。現在のruntime検証手順は`RELEASE_PROCESS.md`、Space移送の保守境界は`PRIVATE_API_GROUP_SPACE_MIGRATION.md`を正本とします。

## Baseline

- SnapFlow Final version: `1.3.0`
- Baseline archive SHA-256: `049ab054992cc2aea6737300f538205d4c897d71255448b97417b9d870ecfc23`
- baseline内historical Git HEAD: `005af4b15fc256627e55f4346b05b91f1ae5a93d`

Final archiveにはhistorical HEADより後のworking-tree changesが含まれるため、移行元の正確なsource stateはcommit単体ではなくarchive hashで識別します。

## 移行時の変更範囲

- Swift package / executable target: `SnapFlow` → `Tabora`
- source target directory: `Sources/SnapFlow` → `Sources/Tabora`
- test target directory / imports: `SnapFlowTests` / `SnapFlow` → `TaboraTests` / `Tabora`
- application entry typeとuser-visible product stringをTaboraへ変更
- productを直接表すdiagnostic queue / notification identity stringをTaboraへ変更
- update URLを`Pentagon22GIT/Tabora`へ変更

### Identity

- Version: `1.3.0` → `1.0.0`
- Build number: `13` → `1`
- Official Bundle ID: `dev.pent.SnapFlow` → `dev.pent.Tabora`
- Community Bundle ID: `dev.pent.SnapFlow.community` → `dev.pent.Tabora.community`
- build artifact: `SnapFlow*.app` / `SnapFlow-<version>.zip` → `Tabora*.app` / `Tabora-<version>.zip`
- Info.plist provenance key: `SnapFlowEdition` / `SnapFlowSourceRevision` / `SnapFlowSourceDirty` → `Tabora...`
- Tabora Official certificate fingerprint: `B931AC85747B9B12E32751D3776AAFD3430E5A12`

private signing keyはrepository外で管理します。

## Repository / documentation

- active documentationをTabora向けに再構築
- version固有のSnapFlow release / validation文書をactive Tabora documentationから分離
- 旧`.git`、generated build output、release output、`.DS_Store`、`__MACOSX`を配布sourceから除外
- GitHub URL、template、workflow、security metadataをTaboraへ移行
- safety invariant workflowを追加

## Behavior freeze

移行phaseではproduct identity、presentation、repository構成、documentationだけを変更対象とし、次のruntime behaviorを意図的に変更しませんでした。

- timer interval
- geometry calculation
- AX mutation rule
- group membership algorithm
- Recovery algorithm
- Mission Control authorization
- cursor ownership
- snap decision
- resize rule

2 / 3 / 4 split layoutには同じ構造規則を適用し、3-window layoutだけを移行専用behaviorにはしていません。

## 移行時のsource整合基準

移行では次をsource-levelの完了条件として使用しました。

- active code / config / scripts / GitHub metadataから旧product identityを除去
- frozen baselineに対するsource / test transformをidentity変更範囲へ限定
- package / product / target identityを`Tabora` / `TaboraTests`へ統一
- Sources / TestsのSwift syntaxを維持
- secret / generated-artifact hygieneを維持
- Markdown local link / workflow metadataを新repositoryへ同期
- package ZIPの内容とartifact namingをTabora identityへ統一

AppKit、Accessibility、Window Server、TCC、Mission Controlを必要とするruntime validationは移行sourceの成立条件とは分離し、macOS Release validationとして管理します。

## 現行sourceとの関係

現行開発基盤: **Tabora v2.2.1 (Build 18)**

v2.2.1ではPreview HOT/COLD、multi-display foreground、provisional Snap peerの判定境界を更新していますが、`WindowSpaces` / `GroupSpaceMigration` / `TaboraSkyLightBridge`のmigration transport、FIFO、rollback、destination layout contractは変更していません。

Desktop間group migrationはmacOS 26.5.2 / 26.6.2で成立を確認した履歴を保持します。OS versionによるallowlistではなく、各起動時のruntime capabilityと実Window→Space membershipによって利用可否と物理成功を判定する設計は現行sourceでも維持されています。

現在のRelease確認項目は[RELEASE_PROCESS.md](RELEASE_PROCESS.md)、移送実装の詳細は[PRIVATE_API_GROUP_SPACE_MIGRATION.md](PRIVATE_API_GROUP_SPACE_MIGRATION.md)、常駐性能基準は[PERFORMANCE_VALIDATION.md](PERFORMANCE_VALIDATION.md)を参照してください。
