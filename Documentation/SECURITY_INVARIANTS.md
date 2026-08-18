# Security / Correctness不変条件

これらの不変条件はSnapFlow最終安定化から継承され、2 / 3 / 4 split layoutへ同等に適用されます。

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
2. 2 members以上を一度にdisplaceするreplacementは、displaced partitionとretained partitionの共有境界が同一axis・同一coordinate上でgapなく一本へmergeできる場合だけ認可する。
3. blocked multi-member replacementは、そのgroupに対するreplacementだけでなくextensionも認可しないhard vetoとして扱う。
4. 「既存groupへ吸収できない」ことをnew group生成の直接認可理由にしてはいけない。既存のindependent split eligibilityへ戻す。
5. multi-member replacementのcommit直前再検証は対象group / member geometryへ限定し、global discoveryや常時observerを追加しない。
6. mutation開始後のidentity / geometry / AX / reconcile failureはrollbackし、new-group fallbackとして再試行しない。

## Shared resizeとcursor ownership

1. Tabora-owned shared interaction regionはownershipがfreshに検証されている間、input ownershipを維持する。
2. temporary uncertainty時にquarantineできるのは最後にvalidatedされたTabora-owned regionだけであり、通常のnative edgeへ広げてはいけない。
3. confirmed destruction / occlusionではTabora input ownershipを解放する。
4. shared-resize authorizationとnative-resize departureを区別可能なまま維持する。

## Recovery

1. 低頻度Recovery watchdogは独立して維持する。
2. Recoveryはrelevant group surfaceと、validated Tabora interaction regionへ影響し得るexternal surfaceを観測する。
3. 遠方の無関係なwindow churnでbroad recovery workを強制しない。
4. relevant external occluderの出現、消失、ordering changeを検出可能にする。
5. 1 observation epochの結果をrollback / transition後のfresh authorizationとして黙って再利用しない。
6. fast observer / presentation retryはboundedにし、未解決のliveness debtは第二high-frequency loopを作らず独立低頻度watchdogへ戻す。

## Foreground / Mission Control

1. Z-order / occlusionはWindow Server evidence、operation targetはAXから得る。
2. indeterminate foreground stateではautomatic authorizationをfail closedする。
3. Mission Control transition evidenceはgroup-scopedかつshort-livedとし、expiry / rebuild / invalidation後に再利用しない。
4. ordering verification失敗時にinteractiveなstale proxyを表示したままにしない。
5. transient ordering / presentation observation failureでstructural group membershipを破壊したり、本来validなMission Control candidateを恒久retireしてはいけない。recovery debtはgroup-scopedのまま維持する。

## Previewとoptional data

1. Preview imageはderived / disposable stateである。
2. Preview cache pressure / failureでplacement correctnessを変えてはいけない。
3. optional candidate discoveryをstructural authorityにしてはいけない。
4. Preview resolutionは2 / 3 / 4 layoutおよびmultiple group全体でmemory-boundedに保ち、quality変更のためidentity / ordering authorizationを弱めてはいけない。

## Release trust

1. Tabora OfficialとCommunity identityは分離する。
2. SnapFlow signing identityをTabora Officialへ再利用しない。
3. private key、token、password、local secretをpublic repositoryへ入れない。
4. Tabora certificate fingerprintが明示設定されていない場合、Official build verificationは失敗しなければならない。
