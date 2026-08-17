# SnapFlow Final → Tabora v1.0.0 Migration Audit

Date: 2026-08-18

## Baseline

The migration uses the supplied SnapFlow Final project archive as the behavior baseline.

- SnapFlow Final version: 1.3.0
- Baseline archive SHA-256: `049ab054992cc2aea6737300f538205d4c897d71255448b97417b9d870ecfc23`
- Historical Git HEAD contained in the baseline: `005af4b15fc256627e55f4346b05b91f1ae5a93d`
- The baseline contained validated uncommitted working-tree changes; the archive, not the historical commit alone, defines the frozen source state.

## Migration-only changes

- Swift package / executable target: `SnapFlow` → `Tabora`
- source target directory: `Sources/SnapFlow` → `Sources/Tabora`
- test target directory/imports: `SnapFlowTests` / `SnapFlow` → `TaboraTests` / `Tabora`
- application entry type and user-visible product strings renamed to Tabora
- diagnostic queue / notification identity strings renamed where they directly represented the product
- update URL changed to `Pentagon22GIT/Tabora`

## Identity changes

- Version: `1.3.0` → `1.0.0`
- Build number: `13` → `1`
- Official Bundle ID: `dev.pent.SnapFlow` → `dev.pent.Tabora`
- Community Bundle ID: `dev.pent.SnapFlow.community` → `dev.pent.Tabora.community`
- build artifacts: `SnapFlow*.app` / `SnapFlow-<version>.zip` → `Tabora*.app` / `Tabora-<version>.zip`
- Info.plist provenance keys: `SnapFlowEdition` / `SnapFlowSourceRevision` / `SnapFlowSourceDirty` → `Tabora...`
- old SnapFlow certificate fingerprint removed; Tabora専用Official fingerprint `B931AC85747B9B12E32751D3776AAFD3430E5A12` を設定済み（公開fingerprintのみ。private keyはrepository外）

## Documentation / repository changes

- active docs rebuilt for Tabora v1.0.0
- historical version-specific SnapFlow release/validation documents excluded from the active Tabora repository
- old `.git`, `.build`, build outputs, release outputs, `.DS_Store`, and `__MACOSX` excluded
- project-owned `build/official`, `build/community`, and `release` output directories retained empty in the distributed project folder
- GitHub URLs, templates, workflows, and security metadata migrated to Tabora
- safety invariant workflow added as the middle CI layer

## Behavior change classification

**Behavior change: none intended.**

No timer interval, geometry calculation, AX mutation rule, group membership algorithm, Recovery algorithm, Mission Control authorization rule, cursor rule, snap decision, or resize rule was intentionally changed during migration.

Three-window layouts were not treated as a special migration target. The inherited structural rules are shared across 2 / 3 / 4 split layouts.

## Validation performed in the migration environment

- file/directory identity audit
- old-product-name scan across active code/config/scripts/GitHub metadata
- exact source/test transform audit against the frozen baseline
- existing build scripts verified as identity-only transformations of the baseline scripts
- `swift package dump-package` succeeded with package/product `Tabora` and targets `Tabora` / `TaboraTests`
- `swiftc -parse` succeeded for all Sources and Tests
- `swift test` was attempted and failed at compile time because this Linux environment has no `AppKit` module
- zsh script syntax was not executed because `zsh` is not installed in this environment; the scripts themselves are identity-only transforms of the already validated baseline scripts
- secret / generated-artifact hygiene scans
- Markdown local-link and YAML syntax checks
- package ZIP reconstruction and content audit

## Validation not claimed here

The migration environment is not a macOS runtime with AppKit / Accessibility / Window Server integration. Therefore this document does not claim that Tabora runtime functional-equivalence tests, Community app build, Official app build, Mission Control behavior, or TCC behavior passed on macOS.

The SnapFlow Final Baseline itself was user-confirmed operational before migration. Tabora must still be run through the same macOS functional suite before an Official release.
