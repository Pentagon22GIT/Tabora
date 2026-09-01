# 非公開APIを用いたグループのDesktop間移送

**最終更新:** 2026-09-01
**動作確認済み環境:** macOS 26.5.2 / 26.6.2  
**対象:** Mission Control上のグループProxy移送、Window→Space観測、将来のABI保守

## 目的

Mission Controlを開いたままTaboraのグループProxyを別Desktopへドロップすると、移動先が安定して確定した時点でexact member集合と移送計画をcaptureする。Mission Controlを閉じて通常Desktopが安定した後、Proxyが表す実ウィンドウを同じSpaceへ移送し、移送先の表示領域と既知のApp Constraintに合わせて配置を検証・再構成する。

非公開APIは交換可能にするが、triggerから完了、rollback、または安全なgroup解散に到達するまでの実行所有権は`GroupSpaceMigrationLine`から分断しない。

この機能は試験的機能であり初期値はOFFである。対応可否はOSバージョン文字列では決めず、その実行環境で必要なsymbol、class、selector、ABI、観測関数を解決できるかで決める。

## ユーザー操作と既存機能の境界

1. 通常Desktopで2個以上のウィンドウからSnap Groupを作る。
2. Mission Controlを開く。
3. TaboraのグループProxyを別Desktopへドラッグして離す。
4. Proxyのdestination membershipが安定した時点でpreflightとcaptureを完了する。実ウィンドウはまだ変更せず、Proxyには受付済み表示を重ねてそのgeometryを固定する。
5. 同じMission Control sessionで別groupも移動された場合は、captureを独立したFIFO待機列へ追加する。同じgroupの重複captureは拒否する。
6. Mission Controlを閉じ、変形のない通常Desktopを0.15秒以上にわたり複数回確認してから、使用済みProxyを退役させて実ウィンドウ移送を一件ずつ開始する。
7. 全memberの物理到達を確認してから、移動先のlayoutを適用・検証する。

Proxyのドロップは選択ではない。通常の移送だけではアプリのactivate、focus変更、`AXRaise`、z-order拡張を行わず、移動先の相対的なWindow Server順序をOSへ委ねる。例外は、capture済みで「移動準備中／移動待機」を表示しているqueued Proxyをユーザーが明示選択した場合だけである。この選択はtransportを変更せず、`groupID + exact member集合 + preferred member`に束縛したone-shotのpost-migration foreground intentとして記録する。実際のraiseは当該transactionの`completed`後かつ同じFIFOの全migrationがterminalへ到達した後だけ行い、失敗・rollback・source取消ではintentを破棄する。複数intentが存在する場合は選択順にgroup全体をraiseし、最後に選択されたgroupを最後に処理する。group内では現在のfront-to-back順を保存するようfollowersを逆順にraiseし、preferred/mainを最後にactivate + raiseする。通常のforeground modeは変更しない。controller/session停止、機能OFF、reset、wake、display topology invalidationでは保存intentとmain queueへschedule済みのflushをgenerationごと破棄し、旧environmentのクリック意図を後から再生しない。

## 実行ライン

| 段階 | 成立条件 | 不成立時 |
|---|---|---|
| 通常提示 | exact group/member/Proxy Window IDと単一user source Space | baselineを作らず既存Recoveryへ戻る |
| Mission Control観測 | 同じProxy identity、最大120秒 | 当該sessionだけ退役し通常復帰後に再arm |
| destination settle | sourceと異なる単一user Space、2観測・0.10秒以上・button up、またはactive Space通知による強い証拠 | 候補を保持または破棄し、実windowは変更しない |
| preflight/capture | feature ON、同一groupのcaptureなし、全memberがsourceに存在、AX identity/Window ID/display/layoutがexact、全Window IDが相互に一意 | 一時的なSpace/AX publication unknownだけ既存0.10秒monitorで最大10回再観測。confirmed不成立はProxyだけを退役し、実windowは変更しない |
| queued presentation | groupごとにexact capture済み、transport未dispatch | 移動済みProxyのgeometry/identityを固定してstatus/FIFO位置を更新し、同じcaptureの実member thumbnailだけをPID + CGWindowID完全一致の入力透過shadowで覆う。同一groupの重複captureと通常の即時foreground selectionは拒否する。queued Proxyの明示選択だけはpost-migration foreground intentとして記録し、transport終了まで実行しない |
| scene separation | Mission Control変形が終了し、対象group全体または少なくとも1 memberのnormal geometry、もしくはcapture後のactive Space変更を伴う通常Desktopを2観測・0.15秒以上確認 | captureを保持し、moveをdispatchしない。transform再観測で通常Desktop evidenceを破棄 |
| dispatch | 全memberのcapture済みWindow IDと現在の単一user Spaceを再確認し、destination外のexact memberだけをoperationへ渡す | identity変更/non-user Spaceはcancel、unknownは有限再観測。API失敗は警告を予約 |
| verify | 全captured memberがdestinationの単一membershipかつ同じWindow ID | deadlineで実行時origin rollbackへ進む |
| physical commit | 全memberのdestination到達を実測 | この境界より前だけTaboraが移動したmemberのorigin復元が可能 |
| layout | destination entry frame取得、planned frame適用、実frame一致 | entry frame復元を試み、destinationでgroup解散 |
| rebuild | 同じgroup ID/member/zoneをdestination displayで再構成 | destinationでgroup解散 |
| finish | Space分離evidence消去。sourceへ戻した取消は同じProxyを通常表示へ戻す。`completed`とdispatch前cancelは、消費済みProxyを同じcompositor tailへ再生成しないため既存のgroup-local normal Desktop rearmを通してからfresh Proxy/handleを復帰する | 必ず定義済みterminal stateへ収束。rearmはpresentationだけに限定し、physical/group commit、FIFO、post-migration foreground intentを待たせない |

`transport.move == .dispatched`は物理成功ではない。非公開関数のopaque戻り値にも成功判定を与えない。全memberのWindow→Space membership再観測だけがphysical commitを認可する。

capture前のpreflight再観測はdestination確定直後のWindow Server publicationとAX応答が揃わない場合だけ最大10回（約1秒）待つ。この時点では全memberがcapture sourceに揃うこと、identity一意、group/proxy構造、layout成立を要求する。capture後のdispatch preflightでは同じstable identityとWindow IDを再確認し、各memberの現在の単一user Spaceを実行時originとして記録する。一度destination moveをdispatchした後は同じ命令を再発行せず、membership verifyと記録済みoriginへのrollbackだけを使用する。

### Mission Control sceneとprivate moveの分離境界

destination確定後もprivate moveはMission Control内でdispatchしない。`awaitingNormalDesktopDispatch`でcaptureを保持し、対象group全体または少なくとも1 memberのnormal geometry、もしくはcapture後のactive Space変更を伴う「証明済みtransformなし」の通常Desktopを2回・0.15秒以上観測した場合だけ、使用済みProxyを退役させて`dispatchingMove`へ進む。後者は全source memberが非activeとなる場合の境界であり、単なる`unavailable`だけではdispatchを認可しない。transformを再観測した場合はdispatch readinessをゼロから取り直す。

複数groupがcaptureされた場合、各transactionはmember集合、source/destination、layout、通常Desktop evidenceを独立して保持する。group IDだけでなくstable member IDと物理Window IDも待機列全体で相互に重ならないことをcapture時とretarget時に確認する。先頭だけをactive transport ownerとし、terminal処理が終了した時点で次を昇格させる。後続が既に通常Desktop安定条件を満たしていても、先行のmove/verify/layout/rollbackとは重ねず直列にdispatchする。

待機表示は中央statusを先頭では「移動準備中」、後続では「移動待機」とし、複数予約時の`n/total`は副表示へまとめる。member previewごとの番号は表示しない。titleは最大48 pt、subtitleは最大18 ptとし、Proxy boundsの幅と高さから独立して上限を求めるため、縦長・横長・不均等な2-member groupでも外へはみ出さない。dispatch境界では追加の同期描画やProxy snapshot取得を行わず、待機表示のまま既存順序でProxyを退役する。表示変更はProxy viewのpixelだけであり、managed-window identity、frame、level、collection behavior、WindowServer orderingを変更しない。同じProxyを別Desktopへ再ドロップした場合は、button-upを含む既存settlementとsource member preflightを再度通し、FIFO位置を保ったまま最新destination/layoutへcaptureを置き換える。sourceへ戻した場合は実moveを発行せず`cancelledAtSource`へ閉じ、同じProxyのqueued表示と選択保留を解除する。失敗用の`orderOut`、通常Desktop再arm、Proxy再生成は行わない。

実member側の予約shadowはtransport authorityを持たない。capture受理後だけ exact PID + CGWindowID集合を登録し、受理済み予約scene中だけ`GroupSpaceMigrationReservationShadowObserver`を起動する。Observerは受理済みcaptureのexact PID + CGWindowID + desktop `sourceFrame`を自身のpresentation-only baselineとして凍結し、Active Space cleanupで消去される`lastGroupWindowServerEvidenceByIdentity`には依存しない。`refreshResizeHandles()`や`GroupSpaceMigrationLine`のtickへ接続せず、0.10秒間隔の独立timerで表示専用の`transformed / normal / unresolved`だけを分類する。初回reservationやretargetはmain queue次turnのcoalesced one-shotからsettlementを開始するが、既存migration callbackを同期blockしない。pointer down/dragではshadowを即時退避し、timer ownershipとpointer/exit監視は維持したままWindow Server geometry取得を完全にskipする。mouse-upは復帰認可ではなくgeometry acquisition開始であり、exact PID + CGWindowID集合のframeが1.5 pt以内で連続安定したことを要求する。初回表示は2 stable samples + 0.08秒以上、pointer/retiling後の復帰は3 stable samples + 0.18秒以上、lifecycle exit hint後の再armは3 stable samples + 0.22秒以上を要求するため、WindowManagerの最後の数フレームへ追従して復帰しない。settle後は全memberをShadow位置更新へ使う処理を停止し、各予約groupにつきdeterministicなexact sentinel 1枚だけを10 Hzでprobeする。Window Server geometryの取得元は、Mission Control上の実表示frameを観測してきた`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], ...)`を維持し、exact PID + CGWindowIDはその結果をfilterするためだけに使う。`CGWindowListCreateDescriptionFromArray`へ最適化してはならない。sentinelが移動・消失・normal化した場合だけ即時hideしてfull reserved-member acquisitionへ戻る。application activation等の早期exit hintはpending one-shotをcancelし、retarget/capture refreshが後から来てもlifecycle rearm debtを解除しないため、Mission Control closing中のstale transformで一度だけ再点灯する経路を閉じる。Active Space変更はShadowを即時hideする早期lifecycle hintであり、それ単独ではaccepted reservation sceneを終了しない。専用Observerが凍結baselineからMission Control継続またはnormal desktopを再証明する。新しいpointer monitor、event tap、burst pollingは追加しない。displayごとに最大1枚の`.stationary`・入力透過panelを使い、Observer/Presenter stateをtransport readiness、FIFO、cancel、rollback、AX layout、foreground認可へ渡さず、AX mutation、focus、raise、Space writeを追加しない。

sourceへ戻した取消では該当groupだけを即時撤去する。予約shadowにはfadeを持たせず、left mouse down、unresolved/normal観測など「Mission Control表示継続が疑わしい」境界では`orderOut`を優先して即時退避する。Active Space変更とapplication activationは予約truthやobserver lifetimeを閉じず、shadowを即時hideしてfresh transform再証明を要求する早期hintとして扱う。Active Space変更時に既存presentation evidence cacheが消去されても、Shadow Observerはcapture時に凍結したbaselineだけで継続判定できる。専用10 Hz observerのgateは、移動機能ON、controller running、user session active、linked resize ON、application interaction非抑止、かつ受理済みreservation sceneの存在で開き、最後のreservation終了、normal desktop確定、機能OFF、controller/session停止、display topology invalidationでtimerをinvalidateする。shadow panelの生成・layering・geometry取得・observer samplingに失敗しても移送は従来どおり続行する。ShadowはMission Control内の予約表示だけを担当し、physical commit後の通常Desktopへ画像coverを引き継がない。

Active Space変更はこのFIFOを取り消す環境無効化ではない。Mission Control終了後にgroupの一部memberだけがactive Desktopへ通常geometryで戻った場合も、縮小変形終了のgroup-local証拠として通常Desktop settleへ使用する。全memberが非active Spaceで通常geometryを観測できない場合は推測せず、capture後のActive Space通知を要求する。destinationへ移動する操作中に既存の共通cleanupが`cancelAllFrameOperations()`を実行しても、`dispatchingMove`以降のmigration frame batch、membership verify、rollback、layout、rebuildはmigration所有として保護する。待機中はAX frame operationを持たないため、この除外を広げない。

各transactionは実dispatch直前にmemberのstable identity、capture済みWindow ID、現在の単一user Spaceを再検証する。全memberが既にexact destinationなら重複moveを省略する。それ以外はdestination外にいるexact memberだけを、sourceまたはユーザーが同じMission Control session中に移した別Desktopからdestinationへ集約する。これにより同名・同一PIDの別windowを取り込まず、既に到着済みのsurfaceへ重複命令を送らない。Window ID変更とnon-user Spaceは即時拒否し、`unknown`だけを0.10秒monitorで最大10回再観測する。

この分離は、Mission Control自身がProxyへ適用中のmanaged-window transformと、Taboraが実application surfaceへ投入する非同期move operationを同一sceneで重ねないための境界である。同一PIDの別windowを続けてMission Control移送した時に、先行surfaceの縮小transformが残留する競合をAX直列化やProxy保持で補修しない。move/layoutは通常Desktopで開始されるが、`completed`直後だけは消費済みProxyを同じMission Control compositor tailへ再生成しないよう、既存のgroup-local normal-desktop rearm（2観測・0.15秒以上）を通してからfresh Proxy/handleを再構築する。これは実window移送・layout・foreground intentの完了条件ではなくpresentation quarantineだけである。`rolledBack`は従来どおり追加quarantineを持ち越さず、dispatch前cancelはrollback APIを発行せず現在のtransformからの通常復帰確認を行う。

physical commit後のAX layoutではTabora生成の画像coverを表示しない。Proxyはdispatch前に従来どおり退役し、その後は実windowのframe更新を直接行う。更新途中のgeometry変化が一時的に見えることは許容し、presentation上の点滅を隠すためにfloating panel、Proxy snapshot、追加orderingを通常Desktopへ持ち込まない。これによりmigration presentationが実windowより前面へ一瞬現れる経路をなくし、transport / membership / layout / commitの安全境界は変更しない。

### Transactionと不可逆境界

`captured → awaitingNormalDesktopDispatch`では実moveは未実行である。feature OFF、controller/session/display無効化、または構造不一致なら`cancelledBeforeStart`へ閉じ、rollbackを発行しない。`dispatchingMove → verifyingMove`でdestination commandを受理した後だけ、timeout時にTaboraが実際に移動対象へ入れたWindow IDを実行時originごとのbatchへ分け、一件ずつmembership確認してから次のoriginを処理する。全originがcapture sourceなら確認成功を`rolledBack`とする。dispatch前からmemberが別Spaceにあった場合はTabora自身の変更だけを復元して`dissolvedAfterOriginRestore`とし、ユーザーの分離状態を虚偽groupとして保持しない。identityを再確認できない場合、rollback API失敗、または不完全timeoutは`dissolvedAfterIncompleteRollback`とする。

`physicalCommitted → applyingLayout → rebuildingGroup`ではsourceへ戻さない。後続失敗はdestination entry frameへの有限な復元を試み、group metadataだけを解散する。これにより、物理的にdestinationへ到達したウィンドウをアプリ側のlayout失敗で別Spaceへ再移送しない。

terminal stateは`completed`、`rolledBack`、`cancelledBeforeStart`、`cancelledAtSource`、`dissolvedAfterOriginRestore`、`dissolvedAtDestination`、`dissolvedAfterIncompleteRollback`に限定する。`cancelledAtSource`だけはWindowServerがsourceへ戻した同一Proxyを保持し、その他のcancel/失敗から独立させる。非同期frame callbackはtransaction IDとphaseへ束縛し、終了済みまたは後続transactionへ書き込ませない。

## Layout、サイズ検証、状態再構成

capture時にsource/destinationの`visibleFrame`、memberの現在frame、zone、App Constraint、restore frameを固定する。source上の比率をdestinationへ投影し、次をすべて満たすframeだけを採用する。

- 座標と寸法が有限かつ正で、destination visible frame内に収まる。
- 既知のminimum/maximum width/heightを満たす。
- member間に面積を持つ重なりがない。
- 既存resize-handle geometryで全memberが一つのconnected componentになる。

単純投影がconstraintに違反する場合だけ既存`canonicalConstraintPartition`へ渡し、logical zoneを維持した最小限の境界調整を行う。confirmed infeasibleまたはindeterminateなら移送開始前に拒否する。適用後はAXから実frameを再取得し、各辺1 pt以内で一致した場合だけgroup commitへ進む。

commitでは同じgroup ID/member集合/zoneをdestination displayへreconcileし、`lockedPlacements`のdisplay/frame/Window IDと、スナップ前へ戻す`restoreFrames`の座標domainをdestinationへ更新する。途中失敗時の解散は既存atomic group departureへ合流し、placement、restore、handle、Proxy cleanupを重複実装しない。

## 通常のSpace分離との関係

Tabora所有migration以外でgroup memberのSpaceが分かれた場合は、実membershipを三値で扱う。

- `knownSame`: groupを維持する。
- `knownDifferent`: 同じfingerprintを2回かつ0.15秒以上確認した後、既存atomic departureで解散する。
- `unknown`: groupを破棄しない。必要ならpresentationだけを抑止する。

観測capability自体がない場合だけ従来のWindow Server/AX間接判定へ限定的に戻る。active migrationが所有するgroupは通常分離reconcilerから除外し、意図的な一時分裂を外部操作と誤認しない。

## 非公開APIの呼び出し方式

Bridgeは実行時に次を解決する。

- `_AXUIElementGetWindow`
- `SLSCopySpacesForWindows`
- `SLSSpaceGetType`
- `SLSCopyManagedDisplayForSpace`
- `SLSBridgedMoveWindowsToManagedSpaceOperation`
- `initWithWindows:spaceID:`
- `SLSPerformAsynchronousBridgedWindowManagementOperation`のexport、または確認済みexact local Mach-O symbol

perform関数はexportを先に`dlsym`し、存在しない場合だけSkyLight Mach-Oのsymbol tableからallowlist上の完全一致名を解決する。現在確認済みのlocal symbolは次である。

```text
__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation
```

local resolverはloaded image、`LC_SYMTAB`、`__LINKEDIT`、symbol/string範囲、NUL終端、ASLR slide、実行可能segment所属を検証する。prefix/部分一致、類似symbol推測、旧move APIへの自動fallbackは行わない。

operation classとinitializerは照会時・dispatch直前に再取得する。initializerは引数数4、object戻り値、windows object引数、64-bit Space ID引数であることを検証する。operation生成nil、Objective-C例外、runtime不足はfail-closedとする。dispatch関数のABIは確認済みのopaque 64-bit戻り値として宣言するが、その値を物理成功には使用しない。

## 変更頻度によるファイル分離

| 変更頻度 | ファイル | 修正責務 |
|---|---|---|
| 高い | `Sources/TaboraSkyLightBridge/TaboraSkyLightMoveRuntime.m` | move symbol/class/selector/ABI、operation生成、dispatch |
| 条件付き | `Sources/TaboraSkyLightBridge/TaboraMachOSymbolResolver.*` | Mach-O構造またはlocal symbol解決方式が変わった場合だけ |
| 低い | `Sources/TaboraSkyLightBridge/TaboraSkyLightBridge.m` | Window→Space等の観測Bridgeと公開C境界 |
| 低い | `Sources/Tabora/WindowSpaces/SkyLightWindowSpaceBackend.swift` | Bridge結果を三値観測/dispatch resultへ変換 |
| 安定 | `Sources/Tabora/GroupSpaceMigration/*` | transaction、verify、rollback、layout policy |
| 安定 | `Sources/Tabora/SnapController+GroupSpaceMigration.swift` | 既存group/placement/AX frameとの統合 |
| 既存保護 | `Sources/Tabora/SnapController+GroupForeground.swift` | 明示選択時の前面化。move ABI修正では変更しない |

`SLS*`、private class/selector、Objective-C ABIをSwift transaction、Layout、SnapGroupへ漏らさない。underscored AX WindowID呼び出しは`RuntimeWindowIDResolver`だけに集約し、Space backendとpointer identityが同じoptional wrapperを使う。Apple側の変更時は、まずこの変動境界だけを調査し、membership verificationやrollbackの意味を同時に変更しない。

## API不成立時のユーザー通知

設定の試験的機能欄には、実行時capabilityの現在状態と`動作確認済み: macOS 26.5.2 / 26.6.2（2026-08-30）`を表示する。

警告境界はOSバージョンではなく、次の実際の不成立である。

- 通常DesktopでProxy観測を準備した時点で、membership/Space種別APIが不足する。
- destination確定後のpreflightで必要capabilityが不足する。
- valid capture後のmove dispatchがruntime unavailableまたはrejectedになる。
- pre-commit rollback dispatchがunavailableまたはrejectedになる。

Mission Control中にmodal UIを出して既存interactionを壊さない。移送候補に紐づく警告は、そのexact groupが通常Desktopへ戻った証拠を得てから一度だけ表示する。観測入口自体が利用不能な場合は、通常DesktopでのProxy準備境界から通知する。警告では機能をOFFにすることを推奨し、ワンクリックで設定をOFFにできる。

通常のAX一時失敗、Proxy source publication遅延、未知membership、layout不成立をAPI変更と誤報しない。同じfailure kind/detailはアプリsession内で重複表示しない。設定画面の状態は常に再照会できる。

## 確立経緯と実機確認

初期実装ではperform exportを`dlsym`できず、trigger/destination検知が成立していてもmove capability不足で停止した。実機ログから入口ではなくperform解決だけが欠けていることを特定し、確認済みlocal C++ symbolのexact Mach-O解決を追加した。classの遅延登録を考慮してmove capabilityも再評価するようにした。

macOS 26.5.2でアプリ再起動直後から取得した実機記録では、同じ2-member groupについてSpace `1 → 3`と`3 → 1`の往復が成立した。両試行でexact local Mach-O resolver、operation class、initializer、ABI、handoff、全Window IDのdestination membership、layout検証、`completed`を確認し、rollback、timeout、dispatch rejectionは発生しなかった。

macOS 26.6.2でも同じ非公開move APIのruntime解決と実ウィンドウのSpace間移送が成立することを追加確認した。これは確認済み環境の追加であり、OSバージョン番号によるallowlist化ではない。利用可否は各起動環境のruntime capabilityと実dispatch結果で引き続き判定する。

Proxy作成直後にsource Spaceが`unknown`となるWindowServer publication遅延に対し、通常Desktopで同一group・member集合・Proxy Window IDを維持している間だけ0.10秒間隔・最大10回のbaseline再取得を行う。Mission Control変形を観測した時点で未確定baselineは破棄し、destinationをsourceとして採用しない。Proxyのdestination所属が確認された場合は通常のProxy選択確認より移送sessionを優先し、まだmoveをdispatchしていない選択cancelだけを理由に次回presentationをquarantineしない。恒久版は診断HUDと`GroupSpaceMigration.log`を生成しない。

destination drop直後にもmember SpaceまたはAX elementが一時的に`unknown`となる場合がある。これはdispatch前の有限再観測対象であり、単発のunknownだけでcandidateを破棄しない。一方、dispatchが受付済みでも全memberのdestination membershipが期限内に成立しない場合はOS/private API側の停止をTaboraから成功へ偽装せず、記録済み実行時originへの直列rollbackへ収束させる。

全memberのdestination到達後に実行するframe適用では、同一PIDへ複数のAX位置・サイズ変更を同時発行しない。PIDごとに直列laneを作り、異なるPIDだけを並列実行する。batch期限は最長laneに対して1window当たり従来の1.8秒を確保する。いずれかが失敗した場合は成功扱いにせず、destination entry frame復元とgroup解散の既存経路へ収束させる。

同一PIDの別windowを後続でMission Control移送した時の縮小・操作不能表示は、frame適用より前に再現したためAX laneの問題ではない。既存のprivate API利用例と照合してoperationの即時解放はABI利用例と一致した。一方、Tabora固有だったのはMission Controlのactive transform中に同じ非同期move APIを重ねる点である。このためoperation保持や追加アニメーションではなく、scene separationを恒久境界とした。

## macOS更新時の保守手順

1. 設定のAPI状態または自動警告で不足境界とdetailを確認する。
2. 2-member groupで一度だけ再現し、通常Desktopへ戻る。連続試行で状態を上書きしない。
3. `TaboraSkyLightMoveRuntime.m`でexport、exact local symbol、class、selector、initializer ABIを現行OSと照合する。
4. local symbol解決自体が壊れた場合だけ`TaboraMachOSymbolResolver.*`のMach-O前提を調べる。
5. 観測関数が不足している場合だけstable Bridgeの該当関数を調べる。
6. 新しいexact ABIを追加しても、fuzzy探索や未検証の旧API fallbackは追加しない。
7. `swift test`と通常buildを行い、Objective-C nullability warningを含め警告を残さない。
8. source→destination、destination→sourceの往復を行い、全member membership、layout、restore frame、group ID/member/zone、Proxy再armを確認する。
9. timeout/feature OFF/構造変更のpre-commit rollbackと、post-commit layout失敗時にsourceへ戻らないことを確認する。
10. Proxy選択の前面化、通常Snap/Assist/drag/shared resize/restore、別groupのpresentationが変化していないことを回帰確認する。
11. Proxy選択confirmation前後へActive Space通知を挿入し、選択groupだけが維持され、unrelated Proxyと通常pending operationがcleanupされることを確認する。migration ownershipだけの状態では通常Proxy selectionを保存しない。
12. groupを複数作成・削除した後も、通常Proxyとreservation shadowが現在存在するgroupのstable indexによる同じ表示番号を使用することを確認する。

## Release確認表

最新完了記録: **2026-09-01 / Tabora v2.0.0 (Build 14) / macOS 26.6.2**

- [x] 2/3/4 member、同一/異なるアプリ。
- [x] 同一アプリ複数memberで各AX elementが別Window IDへ解決され、重複ID captureがdispatch前に拒否されること。
- [x] 同一displayおよび別display、異なるvisible frame/scale、大小destination。
- [x] exact projectionとconstraint-adjusted projection、confirmed infeasible。
- [x] dispatch no-op timeout、部分移送、単一origin／複数origin rollback成功・不完全。
- [x] frame apply失敗、entry frame復元、group rebuild失敗。
- [x] 移送中のfeature OFF、window close、display/session変化、controller停止。
- [x] Mission Control cancel、Proxy選択との排他、往復移送、失敗後再試行。
- [x] destination確定後もMission Control中は実memberのmembershipが変化せず、通常Desktop安定後に一度だけmoveがdispatchされること。
- [x] capture直後に移動先Proxyへ受付済み表示が出て、Preview内容、frame、Window ID、ordering、collection behaviorを変更しないこと。同じProxyを再操作しても重複transactionを生成しないこと。
- [x] 予約済みProxyを第三のDesktopへ再ドロップするとFIFO位置を維持したまま最新destinationへ移送されること。sourceへ戻すと実moveなしで予約が解除され、同じProxy画像と選択判定が残り、次回Mission Controlでも候補画像が欠落しないこと。
- [x] physical commit後のAX layoutでTabora生成のfloating handoff coverが一切表示されず、実window更新だけが見えること。cover撤去によってtransport、membership verify、layout completion、group commit、Proxy rearmの順序が変化しないこと。
- [x] 同じMission Control sessionで異なる2groupを別Desktopへ移動し、両captureが保持され、終了後にdrop順のFIFOで一件ずつ完了すること。先行groupのverify/layout/rollback中に後続moveをdispatchしないこと。
- [x] FIFO処理中にdestination Desktopへ切り替えても、Active Space cleanupがmigrationのframe batchをcancelせず、両groupがlayout/commitまで完了すること。
- [x] capture後にmemberを一枚だけ別user Spaceへ手動移動した場合もcapture済みWindow IDが一致するそのmemberをdestinationへ集約すること。既にdestinationにいるmemberはprivate move対象から除外し、全member到着済みならmoveを発行しないこと。移送失敗時は各memberを実行時originへ戻し、capture前から分離していたgroupは復元後に解散すること。
- [x] group移送完了後にMission Controlを再度開き、同一PID/別PIDの通常windowを移送しても縮小transform、操作不能surface、group画像欠落が起きないこと。
- [x] `completed`とdispatch前cancelでは、消費済みProxyを同じMission Control compositor tailへ再生成しないため対象groupだけnormal Desktop rearmを通すこと。`rolledBack`やdestination dissolutionでは不要な旧scene quarantineを残さないこと。
- [x] 通常の外部Space分離における`knownSame/knownDifferent/unknown`。
- [x] 通常移送だけではfocus、activate、AXRaise、既存foreground modeを変更しないこと。queued Proxyを明示選択した場合だけ、全FIFO terminal後のone-shot foreground intentを許可し、失敗terminalでは実行しないこと。

private APIの互換性はcompile成功だけでは保証できない。対応環境ごとにruntime capabilityと実membershipによる往復確認をRelease条件とする。
