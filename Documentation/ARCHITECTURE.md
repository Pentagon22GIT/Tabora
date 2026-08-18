# アーキテクチャ

この文書は、SnapFlow Final Baselineから継承したTabora v1.0.0の構造と、その後のv1.0.1安定化で追加された限定的なplacement認可を説明するものです。これは実装の説明文書であり、実コードとは別の新しい挙動を定義するものではありません。

## アプリケーション起動と設定

- `AppMain.swift` はメニューバーアプリのライフサイクル、メニューコマンド、グローバルショートカット登録、更新リンクの表示、Accessibility設定への導線を管理します。
- `AppSettings.swift` は現在のアプリの `UserDefaults.standard` domainへユーザー設定を保存し、`ServiceManagement` を使ってログイン項目登録を管理します。
- `SettingsWindowController.swift` は別の永続化層を追加せずに設定画面を表示します。

## ウィンドウ観測とidentity

- `AXWindowService.swift` はAccessibilityによる観測とWindow Server identityを組み合わせます。
- `WindowSafetyPolicies.swift` は、一時的な観測失敗とconfirmed disappearanceを区別するための安全state / authorization policyを保持します。
- physicalなWindow Server surfaceを特定する必要がある場面ではPID + CGWindowIDを使用し、AX geometryはmutationおよびnative resizeのgeometry domainとして扱います。

## Placementとsnap制御

- `SnapController.swift` はdrag観測、snap選択、Assist、restore state、Recovery、高位アプリstateを統括します。
- `SnapZone.swift` と `SplitLayout.swift` はtarget zoneとlayout関係をモデル化します。
- placement logicは3分割専用分岐ではなく、2 / 3 / 4 window構成へ共通の構造規則を適用します。
- v1.0.1では、既存groupの複数memberを一度に置き換える場合だけ、displaced partitionとretained partitionの共有境界が同一axis・同一coordinate上で連続した一本の直線として成立することをplacement認可条件へ追加します。
- single-member replacementは従来経路を維持します。multi-member replacementが不適格な場合は、そのgroupに対するreplacement / extensionを認可せず、既存のindependent split判定へ戻します。
- multi-member replacementの認可はmutation開始前に行い、commit直前には対象groupのrevision、member集合、AX current frameだけを局所再検証します。再検証失敗はfail-closedとし、new-group fallbackへ変換しません。

## 明示的groupとresize

- `SnapGroup.swift` は永続的なgroup関係とgroup-level stateをモデル化します。
- `SnapController+ExplicitGroups.swift` はgroup membershipと構造変化をreconcileします。
- `SnapController+HandleResize.swift`、`ResizeHandleOverlay.swift`、`ResizeHandleGeometry.swift` はshared resizeのpresentationとinteractionを担当します。
- `SnapController+NativeResize.swift` は、本来のnative resize / departureとTabora-owned shared resizeを区別します。
- `LiveResizeScheduler.swift` はlive resize requestをcoalesceし、stale targetが蓄積しないようにします。
- `VirtualResizeOverlay.swift` は軽量なresize presentationを提供します。

## ForegroundとMission Control

- `SnapController+GroupForeground.swift` はWindow Server ordering evidenceとAX operation targetを使ってgroup foregroundingを認可します。
- `MissionControlGroupProxy.swift` はMission Control proxy挙動とscopeされたtransition authorizationを担当します。proxy orderingはhidden / non-interactive状態で検証し、一時的なordering失敗にはboundedな再検証を行い、その後は候補を恒久的に失わせず低頻度Recovery debtへ移します。
- AX / display / geometryの一時的不確実性によるMission Control presentation suppressionはgroup単位で追跡します。fast retryは有限で、未解決のdebtは独立した1 Hz Recovery watchdogで再観測します。
- selection evidenceはboundedかつgroup-specificであり、stale transition evidenceを後の無関係なaction認可へ再利用してはいけません。

## AssistとPreview

- `WindowPickerPanel.swift` はcandidate windowを表示します。
- `AXWindowService.previewCGImage` はPreview機能が有効な場合だけpreview画像を取得します。
- Preview dataはderived / bounded / disposable stateであり、window identityやplacement correctnessの権威にはなりません。Mission Control previewは固定720×480 capではなく、現在presentation可能な全memberで既存32 MiB cache budgetを共有します。

## Recovery

Taboraは独立した低頻度Recovery watchdogを維持します。Recoveryはlost mouse-up、Assist cleanup、presentation recovery、observer re-arm、一時的なAX / Window Server failureに対する安全網です。mouse event monitorはstartup / re-enable時にbounded readiness burstを受け、その後のRecoveryでは1 Hz tickごとに単一のre-arm attemptだけを行います。正常時のRecoveryを制限のない第二global discovery loopにしてはいけません。

## 設定とOS integration

- `ExperimentalWorkspaceSettings.swift` は、ユーザーが明示的に適用・復元した場合だけDockの `workspaces-edge-delay` preferenceを読み書きし、Dockを再起動します。
- login item登録には `ServiceManagement` を使用します。

## Build identity

- Official: `dev.pent.Tabora`
- Community: `dev.pent.Tabora.community`

両identityは意図的に別々のtrust domain / TCC domainを使用します。
