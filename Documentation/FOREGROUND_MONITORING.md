# Foreground monitoring boundary

## 目的

connected groupの最前面保証を維持しながら、常駐中の独立10 Hz pollingを廃止する。監視は「変化を見つけること」、認可は「どのwindowを前面化してよいか」、表示は「resize handleを再表示してよいか」に分離する。

## 所有関係

| 層 | 所有するもの | 所有しないもの |
| --- | --- | --- |
| `ForegroundSelectionMonitor` | exact Window Server selection baseline、変化通知 | timer、group、AXRaise、solo/automatic、handle |
| foreground monitoring extension | lifecycle gate、event/fallback同期、Recovery接続 | group foreground認可の意味 |
| `SnapController+GroupForeground` | desktop click、system selection、owned mutation、solo/automatic | long-lived polling |
| explicit Mission Control transaction | exact proxy group/member/preferred、有限raise/検証 | generic PID selection |
| handle presentation | complete geometry、frontmost/occlusion/liveness検証 | foreground mutation認可 |

## 通常ライン

1. mouse-up、AX focused/main、workspace activation、またはMission Control callbackが到着する。
2. exact Window Server selectionをfallback baselineへ同期し、同じ変化の再生を防ぐ。
   ただしowned AXRaise中にWindow ServerとAX focus/mainが食い違うsame-PID通知は同期せず、次のexact fallbackが外部選択かを判定できる状態を保つ。
3. drag / resize / Assist / Snap / restore / Space / owned mutationとの排他gateを確認する。
   controller停止中またはlogin session非アクティブ中は、queue済みeventを含めてこの認可gateで拒否する。
4. desktop/system selectionは有限settlementでexact PID + CGWindowIDを2回確認する。
5. exact system selection確定時に、以前の`automatic`認可を全て`disabled`へ閉じる。group-localな`soloPresented`は維持する。
6. system selectionでgroup全体が未前面または不明なら`soloPresented`へ移るが、companionをraiseしない。
7. Mission Controlでの個別選択やCommand-Tabの結果として全memberが既に前面であることをWindow Serverが証明した場合、そのgroupだけを`automatic`へ再開放する。この経路自身はAXRaiseを発行しない。
8. exact Mission Control proxy選択または明示的group操作だけがwhole-group mutationを認可する。
9. whole-group mutation直前のfrontmost判定はGroupのstrict orderingを維持しつつ、対象Groupの物理Display frame内へgeometryをscopeする。隣接Display側の1 pt境界許容だけではoccludedとせず、同一Displayの外部windowまたは実際にDisplayを跨いだwindowは従来どおりraise対象とする。
10. 全memberのfrontmost、geometry、occlusionがそれぞれ確認できた場合だけhandleを再表示する。

## 取りこぼしライン

既存Recoveryの1 Hz tickが1回だけselectionを読む。変化を検出した後は通常ラインと同じ有限settlementへ合流する。別timerは作らないため、group数、solo状態、unknown状態、AX observer失敗が監視頻度を増やすことはない。通常イベントが届いた場合はbaselineを同期し、次のRecoveryで二重処理しない。

## 性能境界

- 旧独立monitorは待機中も毎秒10回selectionを取得した。新構成は通常時event-drivenで、取りこぼし確認も既存Recoveryに相乗りする毎秒最大1回である。したがってselection query上限は約90%削減、foreground専用timer wakeupは100%削除される。
- 通常eventは既存の有限settlementへ直行する。初期exact snapshotがある場合は通常約60 ms、AX / workspace通知からは2回の安定観測を含め通常約120 msで分類する。automatic再開放は同じfrontmost評価結果を使い、追加poll、追加delay、追加AXRaiseを持たない。
- OS event取りこぼし時だけ既存Recovery tickまで最大約1秒を要する。これは高頻度loopを復活させないための意図したfallback latencyである。
- whole-app CPU低下率はPreview、handle occlusion、Recovery等の残存負荷に依存するためコードだけでは確定しない。比較計測では同じgroup数、同じPreview状態、無操作60秒を揃え、selection query回数とCPU timeを別々に測る。

## 排他境界

次の開始時はpending settlementをcancelし、baselineを破棄する。

- pointer drag / native resize / shared resize
- Assist / Snap / rollback / Restore
- Mission Control proxy selection / group Space migration
- active Space / display topology / login session変更。ただしactive Space通知がexact Mission Control Proxy確認またはactivationの途中に入った場合、その所有groupとgenerationだけは完了または明示失敗まで維持し、他のProxy・通常raise・Snap / Assist / drag pending workは従来どおり破棄する
- Tabora UIまたはconstraint measurement
- controller disable / stop

操作後の最初のfallback観測はbaseline確立だけに使い、古い選択を認可へ変換しない。

Mission Control Proxy確認は従来の0.14秒で最初に判定する。macOSのMission Control終了とAppKit/workspace activation publicationだけが遅れている場合、同じcandidate generation、group/member集合、presentation generation、有効transition tokenを維持している間だけ0.06秒、0.10秒の有限再観測を許可する。各遅延callbackは最初に自身のselection generationが現在値と一致することを要求し、取消済みcallbackは同じProxyで後から開始された候補を終了・releaseしない。いずれかのidentity/tokenが変化した場合または上限到達時は現在generationの所有者だけが明示cancelし、通常foreground fallbackへクリックを寄付しない。migration presentation ownershipだけではActive Space cleanupからProxy selectionを保護しない。

`automatic`の閉鎖境界は、exactな新規system selection、monitor lifecycle終了（Tabora / linked resize / connected raiseのOFF、login session非アクティブ、connected layout消失）、controller stop、group dissolution / resetである。通常のSnap / resize / migration transaction開始だけでは閉じない。transaction自身が認可とrollback stateを所有するためで、成功時は検証済みpostconditionから再設定し、失敗時はcaptured stateを復元する。

## 同一アプリ複数window

mouse-downのevent-routing情報とWindow Server sceneからPID + CGWindowIDを固定する。既存placementにexact bindingがあればそれを優先する。未登録windowではoptional runtime resolverで同じPIDのAX elementをWindowIDへ変換し、target IDへ一意一致したelementだけを採用する。resolverが利用不能、応答不能、duplicateの場合は従来のgeometry/title mutual-unique matcherへ戻る。focused windowへの置換は行わない。

Space移送では各memberのAX stable identityから解決したWindowIDが全件存在し、かつ相互に一意であることをcapture条件にする。同一アプリであることは拒否理由にしないが、一つのphysical surfaceを複数memberまたは複数の待機transactionが要求する曖昧なcaptureはdispatch前に停止する。captureからterminalまでは通常foreground fallbackを停止し、明示的なProxy選択認可だけを独立して扱う。

## Multi-display foreground境界

foregroundはDisplayのactive / inactive状態ではなく、対象Groupと競合可能なphysical surfaceを基準にします。別の可視Displayを操作中でも、対象GroupがそのDisplay上でstrict frontmostならクリック時に不要なwhole-group `AXRaise`を発行しません。別Displayにしか存在しないsurfaceはGroupのDisplay内へ実面積を持たない限り競合しません。

このscopeは最前面条件を緩めるものではありません。対象Display内でGroupより前に通常windowが存在する場合、Group member間へ外部surfaceが挟まる場合、または外部windowがDisplay境界を越えてGroup側へ実際に侵入する場合は、従来どおりconnected raiseを認可します。

同じdisplay-scoped strict evaluationは、explicit Groupになる前のprovisional Snap peerの前面確認にも使用します。これにより隣接Display境界の共有1 pt許容だけで正当なpeerを除外せず、本物のocclusion時はfail closedを維持します。

## 互換性監査表

| シナリオ | 必須結果 | 2026-09-01実機確認 |
| --- | --- | --- |
| group memberを通常クリック | 既存のexact click認可を維持し、必要ならgroupを前面化 | ✓ |
| 別の可視Display上ですでにtopのgroupを直接クリック | 不要なwhole-group `AXRaise`を発行せず、実windowを再orderingしない | ✓ (2026-09-05) |
| 別の可視Display上でgroupの前に実windowがある状態からクリック | display scopeに関係なく本物のocclusionを検出し、従来どおりwhole-group raise | ✓ (2026-09-05) |
| Mission Controlでgroup proxy選択 | exact captured groupだけを有限raiseし、成功後automatic | ✓ |
| Mission Controlで実windowを1枚選択 | companionをraiseせずsolo、group構造は維持 | ✓ |
| Mission Controlでmemberを順番に選択 | 途中はsoloのまま。全member前面を証明した最後の選択で、そのgroupだけautomaticへ移る | ✓ |
| Command-Tabでgroupが物理的に揃う | 全member前面を証明できた時だけautomaticへ移り、追加AXRaiseは発行しない | ✓ |
| group外windowをsystem選択 | 以前のautomaticをdisabledへ閉じ、group-localなsoloは維持 | ✓ |
| frontmost判定が不明 | fail-closedでselected groupをsoloとし、automaticを持ち越さない | ✓ |
| 同一アプリの複数windowをdrag | pointerのCGWindowIDへ一意対応したAX windowだけを操作 | ✓ |
| snap後に上端maximize | snap transaction終了/rollback owner以外はframe・groupを変更しない | ✓ |
| shared/native resize | selection settlementをcancelし、resize owner終了後に再baseline | ✓ |
| Space移送 | migration owner中はfallback停止、commit/rollback後に再baseline | ✓ |
| session lock / disable / stop | monitor停止、pending work cancel、復帰時はfresh baseline | ✓ |

## 今後の変更点

OS updateで`_AXUIElementGetWindow`が変化した場合は`TaboraSkyLightBridge`と`RuntimeWindowIDResolver`を確認する。selection observationの変更は`ForegroundSelectionMonitor`とmonitoring extensionだけを対象にし、`GroupForeground`の認可規則、Mission Control transaction、handle verificationを同時に緩和しない。
