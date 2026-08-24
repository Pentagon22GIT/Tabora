# アーキテクチャ

この文書は、SnapFlow Final Baselineから継承したTaboraの構造と、v1.0.1までのplacement安定化、v1.1.0で追加されたApp Constraint / shared-resize boundary ownership / atomic group departure、v1.1.1の派生処理budget / cancel ownershipを説明するものです。これは実装の説明文書であり、実コードとは別の新しい挙動を定義するものではありません。

## アプリケーション起動と設定

- `AppMain.swift` はメニューバーアプリのライフサイクル、メニューコマンド、グローバルショートカット登録、更新リンクの表示、Accessibility設定への導線を管理します。
- `AppSettings.swift` は現在のアプリの `UserDefaults.standard` domainへscalarなユーザー設定を保存し、`ServiceManagement` を使ってログイン項目登録を管理します。
- `ConstraintStore.swift` はアプリ別App Constraint recordをschema version付きJSONとしてApplication SupportのBundle ID別directoryへatomic writeします。Official / Community間でrecordを暗黙共有せず、record単位でvalidationして1 recordの破損を他recordの消失へ波及させません。
- `SettingsWindowController.swift` は上部固定のカテゴリ切替で一般 / コマンド / サイズ制約 / 試験的機能を表示し、「アプリ別のサイズ制約」でApp Constraintの記録許可・読み取り専用の値表示・明示計測・record削除をローカルstoreへ反映します。手動の数値編集経路は持ちません。

## ウィンドウ観測とidentity

- `AXWindowService.swift` はAccessibilityによる観測とWindow Server identityを組み合わせます。
- `WindowSafetyPolicies.swift` は、一時的な観測失敗とconfirmed disappearanceを区別するための安全state / authorization policyを保持します。
- physicalなWindow Server surfaceを特定する必要がある場面ではPID + CGWindowIDを使用し、AX geometryはmutationおよびnative resizeのgeometry domainとして扱います。
- `AppConstraintIdentityResolver.swift` はruntime window identityとは独立したpersistent app identityを解決します。native appはBundle ID + Designated Requirement、Chrome Web Appはparent Chrome code identity + canonical Web App IDへ束縛し、PID / CGWindowID / AX element hash / version / pathをpersistent keyにしません。

## Placementとsnap制御

- `SnapController.swift` はdrag観測、snap選択、Assist、restore state、Recovery、高位アプリstateを統括します。
- `SnapZone.swift` と `SplitLayout.swift` はtarget zoneとlayout関係をモデル化します。
- placement logicは3分割専用分岐ではなく、2 / 3 / 4 window構成へ共通の構造規則を適用します。
- v1.0.1では、既存groupの複数memberを一度に置き換える場合だけ、displaced partitionとretained partitionの共有境界が同一axis・同一coordinate上で連続した一本の直線として成立することをplacement認可条件へ追加します。
- single-member replacementは従来経路を維持します。multi-member replacementが不適格な場合は、そのgroupに対するreplacement / extensionを認可せず、既存のindependent split判定へ戻します。
- multi-member replacementの認可はmutation開始前に行い、commit直前には対象groupのrevision、member集合、AX current frameだけを局所再検証します。再検証失敗はfail-closedとし、new-group fallbackへ変換しません。
- v1.1.0ではknown App ConstraintをAX mutation前に`SplitLayoutGeometry.allowedBoundaryRange`へ合成します。shared boundaryへ参加するwindowのmin/max不等式を2 / 3 / 4共通トポロジーでintersectionし、feasibleならrequested boundaryを合法範囲へclamp、infeasibleならprovisional group / toggle / proxyをcommitしません。Previewとinitial placementは同じgeometry planを使用します。
- placement authorizationでは、App Constraint適用後のruntime frameがnominal 50%境界へ既に接触していることを要求しません。incoming zoneと既存layout zoneからproposed shared-boundary topologyを作り、そのtopologyを対象にknown constraintを解きます。live handle / group validationは引き続き実frameから行い、proposed topologyをauthoritative runtime existence evidenceには使いません。
- v1.1.0のfull-group replacementは、incoming zoneが既存groupのlogical cellsを完全一致で覆い、commit直前のgroup revision / member集合 / AX current frame再検証にも成功した場合だけ認可します。この場合だけ旧groupを共通Atomic Group Departureで完全retireし、incomingはprovisional singleとして開始します。部分重なりを理由にgroup全体を壊しません。
- v1.1.1ではWindow Serverの完全なsurface evidenceからmember単位の露出を判定します。新規memberは1回取得、露出中は15秒周期、露出を失ったmemberは3秒settle後の最終取得でCOLD freezeします。一部memberだけが前面なら、そのmemberだけHOTです。判定不能時は前回状態を保持します。
- 周期取得はglobal admission（1 tick最大2件、outstanding最大4件）へ通します。generic proxy updateはstale画像を表示するだけで、別keyの再取得を連鎖させません。
- login session非アクティブ中はpreview captureとselection pollingを停止します。Recovery coreのevent monitor rearmは維持し、復帰後はgenerationを更新して古い派生結果を拒否します。
- Assist pickerのpreview loaderは32 MiBの画像budgetをユニーク候補数で分割し、枚数を理由に候補を打ち切りません。hide時はqueued workとcallback ownershipを破棄します。Window Serverが有限retry後も取得元画像を返さない場合のみ、既存のicon/placeholder表示へfallbackします。
- Assistの候補除外はplacement開始時snapshotを永続的な権威にせず、replacement commit後のcurrent lock / explicit-group stateで再評価します。

## 明示的groupとresize

- `SnapGroup.swift` は永続的なgroup関係とgroup-level stateをモデル化します。
- `SnapController+ExplicitGroups.swift` はgroup membershipと構造変化をreconcileします。
- `SnapController+HandleResize.swift`、`ResizeHandleOverlay.swift`、`ResizeHandleGeometry.swift` はshared resizeのpresentationとinteractionを担当します。junctionを交点のsingle ownerとし、single-axis boundary control / hit region / hover / cursorはjunction exclusion zone外の同一free interval geometryから生成します。
- valid groupがhandle-presentableなのにexpected handleが表示されない場合はpresentation liveness debtとして扱います。bounded fast retryで解決しないdebtだけを既存1 Hz Recoveryへhandoffし、structural group membershipとは分離します。
- `SnapController+NativeResize.swift` は、本来のnative resize / departureとTabora-owned shared resizeを区別します。
- `SnapController+ExplicitGroups.swift` はgroup departureの認可とcleanup commitを分離します。認可済みdepartureでは対象groupのplacement / restore / resize session / scheduler generation / handle / hit region / cursor / Mission Control proxy等をgroup-localにretireします。shared resize interaction終了が一時的に隠していた無関係groupのhandleは同じdeparture commit内で再構築し、Recovery待ちにしません。
- `LiveResizeScheduler.swift` はlive resize requestをcoalesceし、stale targetが蓄積しないようにします。
- `VirtualResizeOverlay.swift` は軽量なresize presentationを提供します。

## App Constraint

- `AppConstraintModels.swift` は4 bound (`minWidth / minHeight / maxWidth / maxHeight`) のunknown / candidate / known、アプリ単位のRecordingPermission、persistent identityをモデル化します。
- `ConstraintProbe.swift` はTaboraが実際に送ったAX mutationのrequested frameとsettle後accepted frameを比較し、screen / system / peer constraint / AX failure / orthogonal ambiguityを除外した`confirmedAppRejection`だけを学習・constraint由来departureの根拠にします。通常resize履歴は学習しません。
- `ConstraintStore.swift` 内のregistryはknownだけをactive solverへ公開し、candidateをactive geometryへ入れません。known contradictionはpersistent knownを上書きせず、session-onlyの厳しいoverrideとして次interactionへ反映します。
- shared resize sessionはdrag開始時のregistry generationとlegal rangeへ固定します。drag中のpermission / measurement変更で境界rangeをジャンプさせず、次interactionから新constraintを使用します。
- `ConstraintMeasurementEngine.swift` はユーザーが「サイズを取得」を明示実行した場合、またはサイズ差の許可画面で「取得する」を選んだ場合だけ、取得可能な4 boundを軸ごとに測定します。同一アプリにeligible windowが複数ある通常の設定経路ではユーザーが計測対象を選択し、スナップ由来の許可経路ではそのexact triggering windowだけを再検証して使用します。各測定前後にoriginal frame復元を試み、screen usable edgeへ到達しただけのmaximumや曖昧な結果をknownへしません。explicit measurementでunknownだっただけでは既存knownを削除しません。進捗は固定の非modal panelへ表示し、物理復元完了時にinteraction suppressionを解除した後、同じpanelを結果表示へ切り替えてユーザーの「完了」操作まで保持します。
- 初回スナップのoperation-local alternativeは現在の配置の再計画と許可UIの先行予約にだけ使用できます。screen / system limitを除外できない差は対象外とし、この段階ではconstraint値を永続化せずgroup departureも認可しません。persistent learningとconstraint由来departureは従来どおりbounded settlement後の`confirmedAppRejection`だけが認可し、許可後に実行した全辺明示計測だけが追加のknown値を書き込みます。
- App Constraint lifecycleは起動時とapplication launch / terminate eventでrecord単位に再評価します。matching identityの実観測は既存recordをsilent reactivateし、署名不一致またはこのprocessで観測済みのbundle消失だけをdormant根拠にします。LaunchServicesの一時的不確実性は`unknown`として既存lifecycle stateを変更しません。
- commit済みgroupのshared resize中に`confirmedAppRejection`が発生した場合、accepted current frameを残したままgroup relationshipだけをatomic departureでretireします。AX timeout / liveness unknownだけではgroupを破壊しません。

## ForegroundとMission Control

- `SnapController+GroupForeground.swift` は通常desktop clickのWindow Server / AX一致を認可します。Mission Control proxy clickは別の明示認可であり、captured exact group/member集合にだけ束縛して、toggleと同型の全member raiseへ接続します。実windowのfrontmostやplacement frame一致をmutation前に要求しません。
- `MissionControlGroupProxy.swift` はMission Control proxy挙動とscopeされたtransition authorizationを担当します。選択確認中はproxyのgeneration、ordering、preview presentationを固定し、Mission Control exit由来のwindow resignでは確認をcancelしません。確認開始時点から通常のselection polling / desktop click / resize presentation rebuildを停止し、一つのexact候補が成立した時点で他proxyの保留確認とtransition tokenを同じmain-loop turnで失効させます。callback成立後のselected compositeは、Window Serverが選択surfaceを復帰させている途中で構造的に削除せず、最初のexact whole-group orderingを覆うtransaction-owned handoffとしてのみ保持します。
- AX / display / geometryの一時的不確実性によるMission Control presentation suppressionはgroup単位のevidenceから判定します。証明済みtransformはcontroller側の`groupID + member set`に束縛したshort-lived leaseとして保持し、proxy click用selection tokenとは共有しません。未解決・利用不能な観測だけではglobal transform leaseを開始せず、あるgroupのincomplete observationは別groupが証明済みのtransformを取り消しません。fast retryは有限で、未解決のdebtは独立した1 Hz Recovery watchdogで再観測します。
- proxy選択からgroup foreground完了までは`groupID + activation generation + captured member set + preferred member`を所有する一つのtransactionです。各retryは同じexact member全体をraiseし直し、Window Server settlement確認だけが完了条件です。selected compositeはこのtransactionの成功またはcancelでretireし、通常完了より長く表示される場合は0.50秒のfail-safeで透明・noninteractive化します。透明化だけを理由にselection surfaceを遷移途中で`orderOut`せず、最終retireはtransaction所有者が行います。
- Mission Control変形検出のdesktop baselineは`placement.appliedFrame`ではなく、同じPID + CGWindowIDについてAX frameとWindow Server frameが通常desktop上で一致した最後の観測です。片軸だけが変化するshared/native resizeを等方的なMission Control scaleとして認証しません。
- selected proxyの静止compositeは最初のper-window AXRaise列を覆いますが、実window ordering自体は待機させず同じtransactionで実行します。最初のcomplete pass後に限り、証明済みMission Control scaleが残る間は重複AXRaise / focusを受動観測へ置き換えます。normal geometryへ戻った最初のWindow Server orderingが未settleなら1回だけ再観測し、それでも全member frontmostを確認できない場合は既存のwhole-group retryへ戻ります。変形中の縮小配置をfrontmost完了として受理せず、受動観測には既存retry上限と同じ有限上限を設けます。
- selection evidenceはboundedかつgroup-specificであり、stale transition evidenceを後の無関係なaction認可へ再利用してはいけません。

## AssistとPreview

- Mission ControlとAssistは同時取得数2のglobal gateを共有します。両系統ともbackground threadで最大0.45秒の枠待機を行います。main threadを塞がず、一時的な枠競合とWindow Serverが画像を返さない場合を分離します。
- `WindowPickerPanel.swift` はcandidate windowを表示します。
- `AXWindowService.previewCGImage` はPreview機能が有効な場合だけpreview画像を取得します。
- Assist候補画像は候補panelが必要としたwindowだけを非同期取得し、0.45秒以内に完了しなければplaceholderを先に表示します。枚数上限は設けず、ユニーク候補数で32 MiBを均等分割して全候補を取得します。遅れて完了した画像は同じpanelへ適用し、一時的な取得失敗は0.18秒、0.55秒の有限backoffで最大3回まで試行します。
- Mission Control画像はproxy構築時にcache missした対象だけを非同期取得し、以後は通常desktopで操作transactionが停止している時だけ、1 Hz Recoveryから15秒のfreshness gateを通過したactive memberをstale-while-revalidateします。したがって1秒ごとの画像取得でもファイル走査でもありません。画像取得はWindow Serverのexact window IDを対象とし、utility queueと共通capture gateの両方で最大2件並列です。
- Preview dataはderived / bounded / disposable stateであり、window identityやplacement correctnessの権威にはなりません。Mission Control previewは固定720×480 capではなく、現在presentation可能な全memberで設定されたcache budget（初期値32 MiB）を均等共有し、実byte costが割当を超える画像は割当内まで縮小します。現在候補はLRU順では削除せず、OSが画像自体を返さない場合だけicon fallbackを使用します。cacheはメモリ内だけに保持し、無効化・機能OFF・終了時に世代を切って破棄します。

## Recovery

Taboraは独立した低頻度Recovery watchdogを維持します。Recoveryはlost mouse-up、Assist cleanup、handle presentation / occlusion recovery、observer re-arm、一時的なAX / Window Server failureに対する安全網です。mouse event monitorはstartup / re-enable時にbounded readiness burstを受け、その後のRecoveryでは1 Hz tickごとに単一のre-arm attemptだけを行います。tickは画像ファイルやディスクを走査しませんが、presentation liveness判定のためWindow Serverのon-screen snapshotを取得します。これは常駐時の主要な定常観測コストであるため、正常時のRecoveryをこれ以上高頻度化したり、制限のない第二global discovery loopを追加してはいけません。

## 設定とOS integration

- `ExperimentalWorkspaceSettings.swift` は、ユーザーが明示的に適用・復元した場合だけDockの `workspaces-edge-delay` preferenceを読み書きし、Dockを再起動します。
- login item登録には `ServiceManagement` を使用します。

## Build identity

- Official: `dev.pent.Tabora`
- Community: `dev.pent.Tabora.community`

両identityは意図的に別々のtrust domain / TCC domainを使用します。
