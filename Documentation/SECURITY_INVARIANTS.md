# Security / Correctness不変条件

これらの不変条件はSnapFlow最終安定化から継承され、v1.1.0のApp Constraint / shared-resize boundary ownership / atomic group departureを含め、2 / 3 / 4 split layoutへ同等に適用されます。

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
2. indeterminate foreground stateではautomatic desktop-click authorizationをfail closedする。Mission Controlのexplicit proxy selectionはexact PID / Window Server ID + AX stable identity + livenessで対象を再検証し、frame equalityを存在証明やmutation前提に使わない。proxy handoff完了は全memberのfrontmost orderingで確認する。
3. Mission Control transform evidenceはcontroller側で`groupID + captured member set`へ束縛したshort-lived leaseとして保持し、proxy selection authorization tokenとは分離する。expiry / membership change / invalidation後に再利用せず、あるgroupのincomplete evidenceで別groupが既に証明したtransform leaseを失効させない。
4. proxy orderingは対象group自身の全memberのexact Window Server identityを必須とする。foreign group memberはproxy boundsと実geometryが交差する場合だけordering requirementへ加え、交差するforeign surfaceのidentityが不明ならfail closedする。
5. ordering verification失敗時にinteractiveなstale proxyを表示したままにしない。選択済みproxy transactionのcancel / invalidationでは、そのexact groupのcoverをWindow Serverからorder outする。
6. Mission Controlのexplicit group activationは`groupID + activation generation + captured member set + captured preferred member`へ束縛する。このexact proxy click自体がforeground mutationの認可であり、対象実windowが既にfrontmostであることやplacement frame一致を事前条件にしてはいけない。
7. 各AXRaise retryは全memberを先頭から処理する独立passとし、部分進捗を持ち越さない。一度complete passがacceptされたことを完了とみなさず、全memberのWindow Server frontmostを確認する。
8. transient ordering / presentation observation failureでstructural group membershipを破壊したり、本来validなMission Control candidateを恒久retireしてはいけない。recovery debtはgroup-scopedのまま維持する。
9. explicit group activationの有限retry終了後、Recoveryはその選択を再始動してはいけない。未完了handoffだけをcancelし、structural group membershipは保持する。
10. proxy選択確認中はderived preview / ordering refresh / Mission Control exit由来のkey resignでcaptured selection generationを変更してはいけない。確認開始からcallback成立または明示失敗までは通常selection polling / desktop click / resize presentation refreshへ所有権を渡さない。一つのexact候補を消費したら同じMission Control exitに属する他proxyの保留確認とtokenを失効させる。selected compositeをhandoff coverとして使う場合はexact transactionへ束縛し、成功・cancelでretireし、短いvisibility fail-safe後は透明かつnoninteractiveにしなければならない。
11. Mission Control変形の基準は、同じ物理window identityについてAXとWindow Serverが通常desktop geometryで一致した観測だけから更新する。`placement.appliedFrame`、片軸resize、未settleのconstraint reflow、transform未証明のunresolved observationをtransition authorizationへ昇格させない。
12. 選択済みproxyをWindow Serverの復帰途中で`orderOut`してper-window AXRaise列を露出させてはいけない。frozen compositeは最初のexact whole-group orderingを覆う用途だけに限定し、実window mutationを後置しない。最初のpass完了後だけ証明済みtransform中の重複orderingを有限に抑止できる。normal geometry復帰後の未settle orderingは1回だけ再観測し、なお未確認なら既存retryへ戻す。geometry復帰をforeground認可やactivation成功の必須条件にせず、変形中のfrontmost評価をactivation完了として受理しない。

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
