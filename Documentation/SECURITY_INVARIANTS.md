# Security / Correctness不変条件

これらの不変条件はSnapFlow最終安定化から継承され、v1系の安全境界とv2.0.0のSpace membership / group migrationを含め、2 / 3 / 4 split layoutへ同等に適用されます。

## Space membership / group migration

1. Window→Spaceの空・複数・取得失敗は`unknown`であり、`knownDifferent`へ昇格しない。
2. Tabora所有migrationでない確定Space分離だけが通常group departureを認可する。active migration所有groupを通常reconcilerが破棄してはいけない。
3. Experimental OFFまたはminimum runtime capability不足ではMigration Lineの入口を開かず、move transportへ到達しない。
4. private moveのdispatch成功を物理成功とみなさない。全captured memberがexact destination membershipを持つことを再観測した時点だけをphysical commitとする。
5. physical commit前の失敗は、dispatch直前に記録した実行時originへTaboraが移動したexact memberだけを戻す。originごとのmoveは直列に確認し、identity不明・rollback不完全時はgroupを解散する。capture前からユーザーが分離していたgroupを元groupとして復元しない。
6. physical commit後は設定OFF、構造変化、layout失敗、frame失敗、group rebuild失敗のいずれでもsource Spaceへ戻さない。
7. 移送callbackはtransaction IDとphaseに束縛し、旧callbackが新transactionまたは終了済みgroupを更新しない。
8. Proxyドロップはforeground mutationを認可しない。通常Proxy選択callbackとmigration triggerを同一イベントとして扱わない。capture済みqueued Proxyの明示選択だけはtransportから独立したpost-migration foreground intentとして記録できるが、全FIFO terminal前、失敗terminal、source取消ではAXRaise/activateを実行してはいけない。
9. private symbol / selector / ABIは`TaboraSkyLightBridge`とSpace backend外へ漏らさず、Layout / SnapGroup / foreground層はprivate APIを知らない。
10. destination layoutは既知App Constraint、visible frame内収容、非重複、実geometry接続を満たしたframeだけをgroup commitへ渡す。

## 派生処理とライフサイクル

- Mission Controlのgroup数・member数が増えても、1回の周期更新とoutstanding capture数は固定上限を超えない。
- memberのHOT/COLDは完全なWindow Server evidenceだけで更新し、判定不能をCOLDとして扱わない。隠れたmemberは有限のcooling final capture後に定期取得を停止する。
- previewは派生表示であり、取得失敗・上限超過・cancelによってgroup identity、foreground認可、placement、resize ownershipを変更しない。
- Preview=ONの現在候補を枚数やLRU順で恒久的に画像なしへ落とさない。候補増加時は全候補のper-image byte budgetを縮小し、画像解像度で総量を調整する。
- global画像取得数の上限はMission ControlとAssistで共有する。両系統の取得枠待機はbackground threadの有限時間に限定し、main thread、構造状態、画像枚数の打ち切りに流用しない。
- login session非アクティブ中はdesktop由来のcaptureとforeground selection観測を停止するが、event monitorを復帰させるRecovery coreは維持する。
- 非同期frame mutationはPIDを含むwindow identityと単調増加tokenに所有され、cancel/完了後のcallbackは後続operationを完了させない。
- 永続設定から読み出した座標、距離、待機時間は有限値に正規化してからgeometryやtimerへ渡す。
- Preview OFFはproxy再構築の可否に依存せず、待機取得・retry・deadline・完了適用を失効する。OFF後のproviderはcurrent settingを再確認し、古いgenerationの結果をcacheへ入れない。
- resize-settled previewは物理windowごとに最新geometryの1期限だけを保持し、quiet period到達後も既存global admission上限を超えない。
- resize-settled deadlineが存在するgeometryは他の画像取得laneから取得を開始できず、deadline後の専用laneだけが許可する。専用laneは既存HOT／COLD処理より低優先度とし、Assist／Snap中は開始しない。
- 2 / 3 / 4分割Assist切り替えはPicker表示だけを変更し、選択前にwindow frame、group membership、restore state、Mission Control stateを変更しない。
- AssistのOption monitorはPicker sessionだけが所有し、通常コマンド用Carbon HotKeyやkeyboard event経路へ流さずeventも消費しない。Picker表示session外ではmodifier-state timerを保持しない。
- Option monitorはSnap transaction中には開始しない。ただし次のPickerが先に提示された場合はtransaction完了の復帰点で監視可否を必ず再評価し、表示中sessionを監視なしで残さない。
- 2面と1面の切り替えは同じpreview loader/cacheを保持し、表示形式の変更だけを理由にWindow Server captureを再予約しない。Quarter 2面の完成可否はzoneごとの候補数合計ではなく異なるwindowのmatchingで判定し、単一Halfからの分割も同じ条件を要求する。
- maximize placementはrestore / occlusion layerとして記録してよいが、split membershipを持たないためAssistの予約済み候補集合へ入れてはいけない。候補選択前にmaximize状態を破棄せず、通常Snap commitでだけsplit placementへ遷移する。

## Window state semantics

1. structural existenceと現在のinteraction eligibilityは同じではない。
2. temporary AX failure / timeout / `cannotComplete` はconfirmed disappearanceではない。
3. partial / failed discoveryはauthoritative empty resultではない。
4. memberが一時的に操作不能であることだけを理由に既存group membershipを破壊してはいけない。
5. correctness-criticalなexact targetをoptional broad-discovery budgetへ依存させてはいけない。

## Identityとgeometry

1. Window Server evidenceはphysical surfaceとZ-orderの識別に使用できる。
2. AX geometryはAX native-resize比較とcommitted AX mutationのbaselineである。
3. native-resize baselineとしてCG geometryとAX current geometryを直接比較してはいけない。
4. ownershipが重要な場面ではPID + CGWindowIDを組み合わせて扱う。
5. detached-window censusがincompleteな場合、ambiguous surfaceをadoptせずfail closedする。

## Group integrity

1. unknown observation stateだけでgroupをretireしてはいけない。
2. 正当なnative resize、正当なdrag departure、confirmed member closureは有効なdeparture pathとして維持する。
3. passive geometry mismatchだけからuser departureを捏造してはいけない。
4. degradation confirmationには、同一observation epoch内の反復callではなくfresh evidenceを要求する。
5. 1 groupのtransient failureが無関係なgroupのhandleを停止したり、無関係なrecovery debtを消費してはいけない。
6. これらの規則は2 / 3 / 4 window groupに共通であり、3-window layoutは高感度regression caseではあっても別behavior classではない。

## Placement / replacement authorization

1. single-member replacementの既存認可経路へ、multi-member専用geometry条件を追加してはいけない。
2. 2 members以上を一度にdisplaceするreplacementは、原則としてdisplaced partitionとretained partitionの共有境界が同一axis・同一coordinate上でgapなく一本へmergeできる場合だけ認可する。retained memberが0になる全group置換だけは、incoming zoneが旧groupのnon-overlapping logical cellsを完全一致で覆うことを別の明示認可条件とする。部分重なり・unionだけでの一致・maximize・unknown observationをこの例外へ含めない。
3. blocked multi-member replacementは、そのgroupに対するreplacementだけでなくextensionも認可しないhard vetoとして扱う。
4. 「既存groupへ吸収できない」ことをnew group生成の直接認可理由にしてはいけない。既存のindependent split eligibilityへ戻す。
5. multi-member replacementのcommit直前再検証は対象group / member geometryへ限定し、global discoveryや常時observerを追加しない。
6. mutation開始後のidentity / geometry / AX / reconcile failureはrollbackし、new-group fallbackとして再試行しない。

## Shared resizeとcursor ownership

1. Tabora-owned shared interaction regionはownershipがfreshに検証されている間、input ownershipを維持する。
2. temporary uncertainty時にquarantineできるのは最後にvalidatedされたTabora-owned regionだけであり、通常のnative edgeへ広げてはいけない。
3. confirmed destruction / occlusionではTabora input ownershipを解放する。
4. shared-resize authorizationとnative-resize departureを区別可能なまま維持する。
5. 同一pointer位置のshared resize input ownerは一つだけにする。junction領域はjunctionが所有し、single-axis boundary control / hit region / hover / cursorはjunction exclusion zone外へ限定する。
6. junctionの合成は同一group topologyで実際に接続するboundary間だけに限定し、画面上で偶然交差した別groupのboundaryを結合しない。
7. handle-presentableなvalid groupでexpected handleが表示されない状態をstructural group departureへ変換せず、presentation liveness debtとしてgroup / descriptor単位でRecoveryへ渡す。
8. effective shared boundaryが前回値から変わらない場合、不要なtarget再生成 / scheduler submit / AX write / overlay updateを行わない。

## App Constraint

1. 通常resize履歴をApp Constraintとして記録しない。Taboraが実際に送ったAX mutationについて、settle後accepted boundaryと原因分類を確認できた`confirmedAppRejection`だけをlearning evidenceにする。
2. `requested != accepted`だけでconstraintを確定しない。screen limit / system limit / peer known constraint / AX failure / liveness unknown / orthogonal ambiguityはapp rejectionではない。
3. `ConstraintBoundState.unknown`またはAX / Window Serverの一時的不確実性だけでgroupをretireしてはいけない。constraint由来departureは`confirmedAppRejection`だけが認可する。
4. persistent solver inputはknown boundだけとし、candidateをactive geometryへ入れない。known値をpassive runtime triggerで上書きしない。
5. known min/maxはAX writeより前に適用し、shared boundaryに参加する全participantの不等式を2 / 3 / 4共通solverでintersectionする。同一shared dimensionではminimumは最も厳しい大きい値、maximumは最も厳しい小さい値を支配条件とする。
6. screen usable edgeやSystemGeometryPolicyをapp固有maximumとして学習しない。測れないboundはunknownのまま維持する。
7. active shared-resize sessionは開始時のconstraint generation / legal rangeへ固定し、session途中のregistry変更をstale authorizationとして流用しない。
8. persistent App Constraint identityへPID / CGWindowID / AX element hash / version / bundle pathを使用しない。native appはcode identity、Chrome Web Appはparent Chrome code identity + canonical Web App IDへ束縛する。
9. Chrome本体とChrome Web App、異なるChrome Web App間でconstraint値を自動共有しない。
10. operation-localなサイズ差は許可UIの先行予約に使用してよいが、persistent candidate / known値 / group departureの認可には使用しない。許可UIを早めるためにconfirmed rejectionのbounded settlement時間を短縮しない。
11. 明示計測の進捗表示は外部window mutationの所有者ではない。元frameの復元完了時に計測抑制を解除し、結果確認の「完了」待ちだけを理由に通常のsnap / resize / Recoveryを停止し続けない。
12. explicit measurementでunknownだったことは既存knownが誤りである証拠ではない。knownをunknownへ戻すのは明示的な値削除 / record削除だけとする。

## Recovery

1. 低頻度Recovery watchdogは独立して維持する。
2. Recoveryはrelevant group surfaceと、validated Tabora interaction regionへ影響し得るexternal surfaceを観測する。
3. 遠方の無関係なwindow churnでbroad recovery workを強制しない。
4. relevant external occluderの出現、消失、ordering changeを検出可能にする。
5. 1 observation epochの結果をrollback / transition後のfresh authorizationとして黙って再利用しない。
6. fast observer / presentation retryはboundedにし、未解決のliveness debtは第二high-frequency loopを作らず独立低頻度watchdogへ戻す。

## Atomic group departure

1. group destructionの認可理由とcleanup commitを分離する。
2. 認可済みdepartureの完了時には対象groupのexplicit membership、placement / restore / snapshot、active/finalizing shared resize ownership、scheduler generation、handle descriptor / visible handle / hit region / cursor、virtual resize presentation、Mission Control proxy、degradation / stale evidenceを残さない。
3. toggle等のpresentation cleanupを1 Hz Recovery待ちにしてはいけない。
4. departure generationより古いcallback / retryがretired groupのhandleを再生成してはいけない。
5. Group AのdepartureでGroup Bのhandle / hover / proxy / recovery debtを変更しない。group-specific cleanupへglobal `hideAll()`を代用しない。

## Foreground / Mission Control

1. Z-order / occlusionはWindow Server evidence、operation targetはAXから得る。
2. indeterminate foreground stateではautomatic desktop-click authorizationをfail closedする。Mission Controlのexplicit proxy selectionはexact PID / Window Server ID + AX stable identity + usable AX window reconstructionで対象を再検証し、frame equalityを存在証明やmutation前提に使わない。proxy handoff完了は全memberのfrontmost orderingで確認する。
3. Mission Control transform evidenceはcontroller側で`groupID + captured member set`へ束縛したshort-lived leaseとして保持し、proxy selection authorization tokenとは分離する。expiry / membership change / invalidation後に再利用せず、あるgroupのincomplete evidenceで別groupが既に証明したtransform leaseを失効させない。
4. proxy orderingは対象group自身の全memberのexact Window Server identityを必須とする。foreign group memberはproxy boundsと実geometryが交差する場合だけordering requirementへ加え、交差するforeign surfaceのidentityが不明ならfail closedする。
5. ordering verification失敗時にinteractiveなstale proxyを表示したままにしない。選択済みproxy transactionのcancel / invalidationでは、そのexact groupのcoverをWindow Serverからorder outする。
6. Mission Controlのexplicit group activationは`groupID + activation generation + captured member set + captured preferred member`へ束縛する。このexact proxy click自体がforeground mutationの認可であり、対象実windowが既にfrontmostであることやplacement frame一致を事前条件にしてはいけない。
7. 各AXRaise retryは全memberを先頭から処理する独立passとし、部分進捗を持ち越さない。一度complete passがacceptされたことを完了とみなさず、全memberのWindow Server frontmostを確認する。
8. transient ordering / presentation observation failureでstructural group membershipを破壊したり、本来validなMission Control candidateを恒久retireしてはいけない。recovery debtはgroup-scopedのまま維持する。
9. explicit group activationの有限retry終了後、Recoveryはその選択を再始動してはいけない。未完了handoffだけをcancelし、structural group membershipは保持する。
10. proxy選択確認中はderived preview / ordering refresh / Mission Control exit由来のkey resignまたはActive Space cleanupでcaptured selection generationを変更してはいけない。確認開始からcallback成立または明示失敗までは通常selection fallback / desktop click / resize presentation refreshへ所有権を渡さない。AppKit/workspaceのfrontmost publicationだけが遅れている場合は、同じgeneration・group・member集合・有効tokenに限定した有限settlementだけを許可し、最初の0.14秒判定を含む全待機をtoken lifetimeより短くする。Active Space cleanupは確認所有Proxyまたは確定済みactivation Proxyだけを保存し、migration presentation ownershipを保存根拠にしてはいけない。一つのexact候補を消費したら同じMission Control exitに属する他proxyの保留確認とtokenを失効させる。selected compositeをhandoff coverとして使う場合はexact transactionへ束縛し、成功・cancelでretireし、短いvisibility fail-safe後は透明かつnoninteractiveにしなければならない。
11. passive selection monitorはselection changeの通知だけを生成でき、AXRaise、group foreground mode変更、solo解除、Mission Control認可、handle表示を直接実行してはいけない。通常イベントとfallbackは同一snapshotへ同期し、同じselectionを二重処理しない。
12. foreground fallbackは既存1 Hz Recovery以外のlong-lived timerを持ってはいけない。solo、unknown、AX observer失敗、同一アプリ複数windowを理由に高頻度loopへ昇格してはならない。通常foregroundの有限0.06秒settlementはselection change後だけに限定し、explicit Mission Control confirmationの有限追加観測は10項のexact ownership条件から独立して開始してはいけない。
13. drag、resize、Assist、Snap、restore、Space transition/migration、owned foreground mutation、disable/stopの開始ではpre-transaction selection baselineを失効させる。終了後の最初のfallback sampleはbaselineだけを作り、過去のselectionを新しい認可へ変換してはいけない。
14. 同一PIDのpointer targetはmouse-down時のCGWindowIDとAX elementのruntime WindowIDが一意一致した場合だけexact解決できる。duplicate、unavailable、transient failureは別windowへの代用根拠にせず、従来matcherへfail closedで戻す。private resolver失敗をwindow disappearanceとして扱ってはいけない。
15. event経路を含むselection-driven authorizationはcontroller runningかつlogin session activeを自身のgateで要求する。observer停止やtimer停止だけを安全境界にせず、stop後にqueue済みcallbackが到着してもforeground settlementを開始してはいけない。
16. owned foreground mutation中、Window Serverが外部same-PID surfaceへ先行してAX focus/mainが旧memberを示す通知は、fallback baselineを消費してはいけない。exact owned selectionだけを同期済みとして消費し、`awaitExactWindowIdentity`またはAX-only owned判定は次のexact fallbackへ引き継ぐ。
17. exactな新規system selectionは以前の全`automatic`認可を閉じる。選択対象groupを同じ観測で再開放できるのは、全memberのexact Window Server identityとfrontmost orderingが証明された場合だけとし、この認可経路自身はAXRaiseを発行しない。`indeterminate`は再開放根拠にせず、他groupの`soloPresented`を解除しない。
18. foreground monitor lifecycleの終了、controller stop、group dissolution / resetは`automatic`を閉じる。Snap / resize / migration transaction開始はrollback ownershipを保持するため単独では認可stateを変更せず、成功時の検証済みpostconditionまたは失敗時のcaptured stateだけをcommitする。
19. Mission Control変形の基準は、同じ物理window identityについてAXとWindow Serverが通常desktop geometryで一致した観測だけから更新する。`placement.appliedFrame`、片軸resize、未settleのconstraint reflow、transform未証明のunresolved observationをtransition authorizationへ昇格させない。
20. 選択済みproxyをWindow Serverの復帰途中で`orderOut`してper-window AXRaise列を露出させてはいけない。frozen compositeは最初のexact whole-group orderingを覆う用途だけに限定し、実window mutationを後置しない。最初のpass完了後だけ証明済みtransform中の重複orderingを有限に抑止できる。normal geometry復帰後の未settle orderingは1回だけ再観測し、なお未確認なら既存retryへ戻す。geometry復帰をforeground認可やactivation成功の必須条件にせず、変形中のfrontmost評価をactivation完了として受理しない。
21. Space migrationのdestination確定後、dispatch前のmember Space / AX / destination displayが一時的にunknownの場合だけ有限再観測できる。known-different、confirmed missing、duplicate identity、構造不一致をretryへ弱めず、move dispatch後に同じdestination命令を再発行してはいけない。
22. migrationに使用したProxyはprivate move dispatch直前、通常Desktopへ分離された後に必ず退役させる。dispatch前cancelに加え`completed`直後も、消費済みProxyを同じMission Control compositor tailへ再生成しないためnormal desktop geometryが時間差を持つ複数観測で確認されるまで対象groupのProxy再生成とresize handle presentationを禁止する。このquarantineはpresentationだけに限定し、実window commit、FIFO、post-migration foreground intentを待たせてはいけない。非active destinationまたは解散済みgroupのquarantineで無関係なgroupを抑止してはいけない。
23. Proxy destinationの確定と実window moveを同じMission Control sceneで実行してはいけない。exact capture後は`awaitingNormalDesktopDispatch`に留まり、対象group全体または少なくとも1 memberのnormal geometry、もしくはcapture後のactive Space変更を伴う通常Desktopを2回・0.15秒以上観測してから、Proxy退役とprivate moveをこの順で一度だけ行う。単独のunavailable観測を退出証明にせず、transform再観測はdispatch readinessを失効させる。
24. `awaitingNormalDesktopDispatch`中のProxyは、capture時のmanaged-window identityと移動後geometryを固定し、受付済みの視覚表示だけを変更する。実window、window level、collection behavior、orderingをMission Control中に変更せず、同一groupの再captureと通常の即時foreground selectionを認可しない。queued Proxyの明示選択はexact group/member/preferredへ束縛したone-shot intentだけを記録し、その場でraiseしてはいけない。
25. 同一Mission Control sessionで複数groupをcaptureしても、private moveはFIFOで一件ずつ実行する。各captureのmember集合、source/destination、layout、readiness evidenceを混合せず、先行transactionのterminal処理が完了するまで後続transportをdispatchしない。
26. destination move未dispatchのcancel / shutdown / environment invalidationはrollbackを発行してはいけない。destination dispatch後かつphysical commit前だけ、記録済み実行時originへのrollbackを許可する。`completed`の短いnormal-desktop rearmは消費済みProxyの同一scene再生成を防ぐpresentation quarantineに限定し、physical/group commitを巻き戻してはいけない。`rolledBack`へ不要な旧scene quarantineを持ち越して次回Proxy画像を欠落させてはいけない。
27. Active Space変更の共通cleanupは、`dispatchingMove`、membership verify、rollback、destination layout、group rebuildが所有するAX frame operationをcancelしてはいけない。migration所有中だけ`cancelAllFrameOperations()`から除外し、Snap、Assist、shared resize、Restore、constraint measurementの既存所有境界を変更しない。
28. queued moveのdispatch直前にcaptured member全体のstable identity、Window ID、単一user Space membershipを再検証する。source以外に移動済みのexact memberも現在地からdestinationへ集約するが、destination到着済みmemberへmoveを再発行しない。Window ID変更/non-user Spaceは拒否し、unknownだけを有限再観測する。失敗時rollbackは各memberの実行時originを越えてはならない。
29. `awaitingNormalDesktopDispatch`中の同一Proxyが別user Spaceへ再ドロップされた場合は、同じsettlement条件とsource member preflightを満たした最新destinationで既存captureを置換する。FIFO順位を変えず、不確定membershipからdestinationを更新しない。sourceへ戻った場合は専用terminalで未dispatch予約をcancelし、同一managed Proxyのqueued pixelと選択保留だけを解除する。失敗用の退役・再armを適用して透明なmanaged surfaceや次回画像欠落を作ってはいけない。
30. 複数groupの待機列はgroup IDだけで排他判定してはいけない。capture時とretarget時にstable member IDと物理Window IDの両方が他transactionと非交差であることを要求し、同じsurfaceを二つのmoveへ予約しない。
31. Mission Control終了後にcaptured groupがSpace分離している場合、対象groupの少なくとも1 memberが通常Desktop geometryへ戻った実測はdispatch settleを開始できる。全memberが非active Spaceで通常geometryを観測できない状態をMission Control終了と推測してはならず、capture後のActive Space変更を要求する。
32. migration captureからterminalまで通常foreground selection fallbackは新しいconnected raiseを開始してはいけない。入口で既存baselineと保留signalを失効させ、terminal後はfresh observationから再開する。queued Proxyのpost-migration foreground intentはこのfallbackと共有せず、成功済みintentだけを全FIFO terminal後にone-shotで処理する。
33. Mission Control予約shadowは受理済みcaptureのPID + CGWindowID完全一致だけを描画し、同一アプリ、title、geometryによる代替を禁止する。表示監視は`GroupSpaceMigrationReservationShadowObserver`へ分離し、受理済みreservation scene中だけ10 Hzのread-only observationを許可する。Observerは受理時のexact PID + CGWindowID + desktop `sourceFrame`をpresentation-only baselineとして凍結し、Active Space cleanupで消去されるcontrollerのWindow Server evidence cacheを参照してはならない。Observerは`refreshResizeHandles()`、migration timer、FIFO、dispatch、rollback、AX/Space mutation、focus/raiseを呼ばず、そのstate/結果をtransport側から参照してはいけない。left mouse操作中はShadowを即時退避し、timer ownershipを維持してもWindow Server geometry readを0にする。mouse-up後はexact frame集合が連続安定するまで復帰せず、初回は2 sample + 0.08秒、pointer/retiling後は3 sample + 0.18秒、lifecycle hint後は3 sample + 0.22秒を下限とする。settle後は全memberをShadow geometry更新へ使う処理を停止し、各group 1枚のexact sentinel probeだけを10 Hzで許可する。Mission Control thumbnail geometryは`CGWindowListCopyWindowInfo`のon-screen listから取得し、exact PID + CGWindowIDで取得後filterする。`CGWindowListCreateDescriptionFromArray`をShadowのlive Mission Control geometry sourceとして使用してはならない。sentinel変化時だけfull acquisitionへ戻す。application activationおよびActive Space変更はpending one-shotをcancelして即時hideする早期hintであり、accepted reservation sceneをその通知だけで終了してはならない。normal desktopは凍結baselineに対する専用観測で確定し、normal 2回でsceneとtimerを閉じる。fade、burst polling、新規pointer monitor/event tapを禁止し、機能OFF、最後のreservation終了、controller/session停止、display topology invalidationではtimerとpresentationを必ず閉じる。現在観測に存在しないidentityは旧位置へ保持せず、重複identity、geometry欠落、panel/observer失敗は表示だけをfail closedにする。
34. physical commit後のmigration layoutをTabora生成のfloating画像coverで覆ってはいけない。実windowのAX frame更新が見えることはpresentation上の許容事項とし、その表示を隠す目的でProxy snapshot、追加panel、window level変更、ordering mutationをtransport / layout / commit境界へ追加してはいけない。
35. queued Proxyの明示選択で記録したpost-migration foreground intentは、`completed`したexact groupだけを対象とし、全migration FIFOが空になるまで実行してはいけない。通常Proxyのconfirmationまたはactivationが所有中ならflushを開始せず、そのexact transactionのterminalから再評価する。複数intentは選択sequenceの昇順でgroup全体を処理し、最後のintentを最後にraiseする。各groupでは現在のfront-to-back follower順を保存するためback-to-frontでraiseし、preferred/mainを最後にactivate + raiseする。exact Window Server identityとManagedWindow再構成の直後に同一AX role/position/sizeを重複観測してmain run loopを占有してはいけないが、実際の`AXRaise` / focus mutationは既存`interactiveOperation` budgetを維持し、短いpresentation timeoutへ置き換えて明示選択を取りこぼしてはいけない。group/member/preferredの再検証またはmutationに失敗したintentは破棄し、retry、transport、group membership、foreground modeを変更してはいけない。controller/session停止、機能OFF、reset、wake、display topology invalidationでは保存intentとschedule済みflushをgenerationごと破棄し、旧environmentの明示選択を後から再生してはいけない。
36. groupの表示番号は現在存在する全groupのstable sort indexだけから導出する。累積`creationOrder`や一時的にpresentableなProxy集合を表示番号として使わず、通常Proxyとmigration reservation/shadowで同じordinalを使用する。

## Previewとoptional data

1. Preview imageはderived / disposable stateである。
2. Preview cache pressure / failureでplacement correctnessを変えてはいけない。
3. optional candidate discoveryをstructural authorityにしてはいけない。
4. Preview resolutionは2 / 3 / 4 layoutおよびmultiple group全体でmemory-boundedに保ち、quality変更のためidentity / ordering authorizationを弱めてはいけない。
5. Mission Control previewのfreshness更新はactive memberへ限定し、bounded concurrencyで非同期実行する。capture completionはselection / snap / resize / measurement / restore transactionを横切ってproxy構造を直接変更してはいけない。
6. Preview imageをディスクへ永続化せず、cache refreshをdirectory / file scanとして実装しない。

## Release trust

1. Tabora OfficialとCommunity identityは分離し、App Constraintのpermission / known recordもBundle ID別の保存domainへ分ける。
2. SnapFlow signing identityをTabora Officialへ再利用しない。
3. private key、token、password、local secretをpublic repositoryへ入れない。
4. Tabora certificate fingerprintが明示設定されていない場合、Official build verificationは失敗しなければならない。
