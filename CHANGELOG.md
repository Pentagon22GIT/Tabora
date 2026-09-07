# 更新履歴

## 2.2.3 — 2026-09-07

### 安定基盤への復旧

- v2.2.2で追加した非同期操作、Mission Control Proxy、Preview geometry確認に関する実動コード変更をすべて撤回し、`Sources`、`Tests`、`Package.swift`を安定版v2.2.1と同一内容へ戻した。
- v2.2.2で確認された、対象アプリ終了後もGroupが破棄されずMission Control用の取得画像が背景に残る問題などの不安定動作を解消するため、新しいcleanup、監視、gate、timer、pollingは追加せず、既知の安定動作へ復帰した。
- 安全性強化を目的とする変更であっても、既存の入力終了、Group解散、Preview破棄、rollback、通常操作と利用体験を動作ライン全体で保証できない場合は安定版へ取り込まない保守方針へ戻した。

### Release / documentation

- v2.2.2の変更内容は履歴として本CHANGELOGに保持する一方、同版で追加した非同期操作の恒久仕様は現行仕様から撤回した。Architecture、Security Invariants、Foreground、Migration、Release、Performance文書をv2.2.1の実装境界へ同期した。
- Versionを`2.2.3`、build numberを`20`へ更新した。実動コードと常駐処理はv2.2.1から変更していないため、v2.2.3について新しい性能値や改善率は主張しない。

## 2.2.2 — 2026-09-06（撤回）

> 以下はv2.2.2リリース時点の変更記録です。実動コード変更と追加仕様はv2.2.3へ継承していません。

### 非同期操作とrollbackの安定化

- Snap rollbackまたはGroup Space Migrationが実windowの更新を所有している間は、Restore、Snap、shared resize、App Constraint計測など、同じAX frame operationを置き換え得る新しい操作を開始しない共通gateを追加した。Mission Control終了待ちのmigrationはまだframeを書き込まないため、このgateで不必要に通常Desktop観測を止めない。
- Group Space Migrationのdestination layoutが期限切れ・失効・環境無効化へ進む場合、実行中memberのAX frame generationを先に取り消してから復元またはgroup解散へ移る。期限切れ後に返った古いcallbackは同一PID laneの次memberを開始できず、復元開始後のwindowを旧layoutが再変更しない。
- 通常Desktop安定確認およびFIFOの次transaction開始は、private moveを直接発行せず共通transaction driverへ戻す。capture後に別操作が開始された場合やgroup構造・controller条件が変化した場合は、dispatch直前の再検証でmoveを開始しない。

### Mission Control Proxy / Preview

- 取り消された古いMission Control Proxy選択確認callbackは、自身のselection generationが現在値と一致する場合だけ後続処理へ進む。短時間に取消・再選択した場合も、旧callbackが同じProxy上の新しい候補を終了させない。
- Previewのresize/display変更確認中にwindowの位置だけが変わっても、PID、Window ID、stable identity、display、pixel sizeが同じなら同一候補として有限確認を継続する。位置は取得pixelを変えないため、確認待ちが残留して後続Preview取得を止め続ける状態を解消した。size、display、physical identityが変わった場合は従来どおり同一候補として受理しない。
- 変更した競合境界に対して7件のpolicy / batch / asynchronous selection testを追加した。

### Documentation / performance

- 非同期window mutationの所有者、世代失効、復元へのhandoff、遅延callbackの扱いを`Documentation/ASYNC_TRANSACTION_OWNERSHIP.md`へ恒久仕様として追加し、Architecture、Security Invariants、Foreground、Migration、Release文書を同期した。
- Versionを`2.2.2`、build numberを`19`へ更新した。
- v2.2.2は既存の非同期処理に所有権確認と取消順序を追加する安定化であり、常駐timer、polling、画像取得trigger、Recovery頻度、Window Server / AXの常時観測を変更しない。したがって、バージョン変更による平常時常駐性能への影響はなく、正式な性能基準はv2.2.0 Build 17の値を維持する。

## 2.2.1 — 2026-09-05

### Mission Control Preview / HOT・COLD

- PreviewのHOT/COLD判定をGroup単位のまま再整理し、可視状態はcompleteなWindow Server observationとexact member identityから判定する。全memberが現在のon-screen censusから外れた場合は`COLD-not-visible`としてHOT leaseを終了し、この不可視化だけではCOLD画像を取得しない。部分観測・取得不能は`indeterminate`として直前状態を破壊しない。
- 可視Groupの前面判定はmemberごとの実frameとz-orderを基準にし、Group unionの空白や別memberのrearmost順序だけで外部windowをoccluderにしない。共有Window Server snapshotの既存1 pt境界許容は変更せず、Preview側で物理Display内へscopeする。
- layer-0の外部surfaceは、物理的にmemberを覆う候補だけをAXで限定分類する。`AXStandardWindow`のnon-modal contentは通常occluder、`AXDialog` / `AXSystemDialog` / modal / exact attached sheetはauxiliaryとして扱う。未知または独自subroleはauxiliaryと断定せず`UNKNOWN`へ残す。
- `UNKNOWN`はexact candidate単位のsemantic evidenceを維持しつつ、Group全体の連続physical occlusionへ有限confirmation budgetを持たせる。候補window IDが入れ替わり続けても0.15秒確認を無期限に再生成せず、明示的なauxiliary証拠がない連続occlusionはbounded physical fallbackでCOLDへ収束する。
- HOT→`COLD-visible`だけを`coldConfirmed`取得理由とし、`COLD-not-visible`へ移った時点で旧visible epochのCOLD取得authorizationを失効する。すでに開始済みの同期CG取得は物理中断せず、completion / staging commit時のrevision確認で旧結果を採用しない。`geometryConfirmed`は独立して維持する。
- Preview OFFではPreview専用visibility / semantic classificationを上流から実行せず、HOT/COLD state、待機要求、cache、transient authorizationを失効する。Foreground / Resize / Space structural logicはPreview設定から分離したまま維持する。
- Space切替後も構造上保持されるoff-Space Groupをgeneric handle/proxy failure debtへ積まない。復帰時は既存Space reconciliationでactiveへ戻してから通常presentationを再構築する。

### Foreground / Multi-display

- connected Groupの最前面条件は従来どおりstrictなまま維持し、可視な別Displayにしか存在しないwindowが共有1 pt境界許容によってGroupをoccludeしたように見えるcross-display誤判定だけを除去した。frontmost evaluationでは対象Groupの物理Display `screen.frame`へgeometryをclipし、同一Displayの本物のoccluderと実際にDisplayを跨ぐwindowは引き続きraise対象とする。
- この修正により、別の可視Display上ですでにtopの非active Groupをクリックした時に不要な`AXRaise`が発生して実windowが一度再orderingされる表示揺れを解消した。foregroundは引き続きevent-drivenで、Groupが本当にoccludedなら従来どおりwhole-group raiseを実行する。
- explicit Groupになる前のprovisional Snap peer判定にも同じDisplay scopeを適用し、隣接Display境界のsynthetic overlapだけで正当なpeerを除外しない。Snap成立条件とstrict frontmost条件は変更しない。

### Documentation / performance

- Architecture、Security Invariants、Foreground、Release、Migration、Privacy、Performance記録をv2.2.1の実装境界へ同期した。active documentationは一時的な検証環境やcollector固有diagnosticではなく、再現可能な仕様、検証条件、実測値を正本とする構成へ整理した。
- 常駐性能の最終計測基準は**v2.2.0 Build 17 / 2026-09-05**を維持する。v2.2.1の変更はwindow click、foreground transition、occlusion、Space/display遷移、Snap操作で発火するevent-driven経路であり、無操作R0〜R6計測では変更箇所を直接評価しないため再計測しない。v2.2.1について新しい常駐性能値や改善率は主張しない。

## 2.2.0 — 2026-09-03

### Mission Control Preview / power efficiency

- Mission Control member previewの15秒定期取得とfreshness判定を撤廃した。画像取得は新規memberの初回、最新geometryが2観測で確定したresize/display移動、完全なWindow Server evidenceでHOTからCOLDへの遷移が2観測で確定した時だけ開始する。独立した定期取得timerや第二global discovery loopは追加しない。
- resize確定は固定2秒待機ではなく、最後のgeometry変化から0.15秒後の一回再観測へ変更した。連続変化中は候補を物理window単位で最新keyへ置換し、取得は開始しない。COLD待機中にresizeされた場合はgeometry取得へ統合する。
- COLD/geometry取得へ物理window単位の1秒cooldownを設けた。cooldownは確定済み要求を破棄せず再開時刻まで保持し、初回取得は待たせない。実行中取得より後に成立したトリガーも同じ取得で消費せず、1件の追従要求として保持する。
- 待機要求はactive windowごとに最大1件へ合流し、実行枠4件・OperationQueue上限8件を超えても要求辞書から除去しない。複数displayをround-robinし、各display内はenqueue順のFIFOとして、多数groupでも新しい要求が古い未取得groupを追い越し続けないようにした。
- Mission Control / Space / display変形中は単一のdesktop stability gateで新規取得を閉じ、実行中operationを世代失効する。完了画像は通常desktopでidentity・display・geometry・byte budgetを再検証するまでstagingし、変形途中の縮小画像や余白付き画像をcacheへ確定しない。
- 初回取得中に同一display内で位置だけが変わった場合は、PID + Window ID + stable identityとpixel sizeが一致する最新keyへ結果を継承する。size/display変更や途中geometry revision不一致の結果は採用せず、同じkeyへ戻った場合も確定geometry triggerで撮り直す。
- cache、staging、実行中要求、確認候補、cooldown履歴を現在の物理window集合へ収束させた。Previewは引き続き派生状態であり、取得失敗や待機はgroup identity、foreground認可、Space移送、Snap/Assist/resize ownershipを変更しない。
- 通常Preview cacheとは独立したMission Control session限定のtransient previewを追加した。Mission Control突入直前の通常DesktopでcompleteなWindow Server観測によりgroup全体がHOTと証明された場合だけ、その全memberを対象として認可集合をsession開始時に一度固定する。部分遮蔽groupを分割取得・部分差し替えせず、unknownで保持された旧HOTも認可へ使わない。Mission Control内でHOT/COLDを再評価せず、既存Proxyのframe/order/transformは変えずpixelだけ差し替え、結果は通常cacheへ昇格しない。
- transient previewは2回の同一geometry観測を維持したまま最初の0.08秒再観測で取得を開始する。試験導入したScreenCaptureKit `desktopIndependentWindow`は、Mission Control変形済みsurfaceを元サイズの透明canvas内へ小さく返す実機事象があったため撤回した。通常cacheと同じbounds-onlyの直接window画素を使い、割当がnominal pixel数を超えるmemberだけbest-resolutionを要求する。元windowとの縦横比、PID/window identity、byte budget、開始時に固定したsession planが一致した場合だけ置換する。
- transient取得は通常cacheと同じbyte上限を独立上限とし、Mission Control中のnormal + transient画像を設定UIに表示する合計上限内へ制限する。表示値の半分を通常cache、残り半分をtransientへ割り当てる。sessionあたりmember取得は最大24件、直接window取得transactionは最大1本とし、通常Preview/Assistと同じglobal capture admissionも通す。MC連続開閉で旧要求が残る場合は新しい取得を重ねず、その回は通常Previewへ安全にfallbackできる。session失効はglobal capture枠取得後にも再確認し、すでに発行済みの同期CG取得が戻った後も縮小・再sample前後でgenerationを再確認して、終了済みsessionの派生処理を継続しない。
- managed displayごとのCurrent Spaceをread-onlyで観測し、MC transient対象を可視Spaceへ限定した。Display消失時はgroupを即破棄せず、全memberがmacOSによって同一user Spaceかつ同一物理Displayへ移され、既存zone関係のcomplete connected geometryも維持されたことを再観測できた場合だけgroup ID/member/zoneを維持してdisplay ownershipをrebindする。分散・unknownは非破壊で保持する。
- Display復旧はscreen-change通知所有の0.15/0.35/0.75/1.25秒settlementで解決し、残ったexact candidateだけを最大6秒の期限付きdebtとして既存1 Hz watchdogへ委託する。旧display geometryは現在接続中または未解決debtが参照するIDだけへ収束させる。1 Hzへ画像取得、全Space/全group discovery、恒久的なdisplay recovery pollingは追加しない。
- 1 Hz watchdogでdisplay rebindが成立した場合は、そのtick後半の既存full presentation refreshへ成功結果を合流し、同じtick内でWindow Server snapshotとhandle/proxy再構築を重ねて実行しない。
- Group Space Migrationの未確定Proxy観測にあった固定120秒expiryを撤廃した。同じMission Control lifecycleが続く限り既存0.10秒monitorを維持し、通常Desktop復帰、Proxy選択、group退役、機能/controller/session無効化、構造不一致、migration成立という既存終了経路だけで閉じる。監視頻度の変更、新しいtimer/watchdog/pollは追加しない。
- 通常Mission Control PreviewとAssistで、global capture admission待機中に所有operationがcancelされたrequestを物理CG取得直前で棄却するよう既存`shouldCapture`契約を補完した。HOT/COLD、geometry、Space判定は増やさず、追加Window Server/AX問い合わせも行わない。すでに発行済みの同期CG取得は強制中断せず、従来どおりlogical cancellationで結果を破棄する。

### Audit / documentation

- queue overflow、同一/複数displayの公平性、後着trigger、HOT/COLDのunknown保持、cooldown、Mission Control transform gate、cache上限をsourceとpolicy testで再監査した。
- 試験的機能のMission Control画像メモリ上限は、通常cacheとtransient cacheを合わせた合計値を表示するようにした。保存値、既存UserDefaults key、各cacheの実上限は変更せず、初期表示64 MiBの半分を通常cache、残り半分をMission Control中だけの一時cacheとして明記した。
- 2026-09-05の同一R0〜R6形式による再計測へ性能記録を更新し、それ以前のv2.2.0暫定値は比較・結論・基準から除外した。
- Versionは`2.2.0`、build numberは`17`。MC transient / Display topology追加は常駐1 Hzへ恒久処理を追加しない境界として文書化し、常駐性能基準は2026-09-05再計測を使用する。

## 2.1.0 — 2026-09-01

### Localization

- アプリ内に表示される設定、メニュー、Alert、Panel、Snap / Assist / Resize、App Constraint、Mission Control連携を日本語、英語、韓国語、簡体字中国語、繁体字中国語へ対応した。READMEや`Documentation/`は日本語の正本を維持する。
- 初回起動時だけmacOSの最優先言語から初期値を決定し、未対応・取得不能・不正な保存値は日本語へfallbackする。決定した言語は`UserDefaults`へ保存し、後のOS言語変更やアップデートでは自動変更しない。
- 設定の「一般」に言語選択を追加した。選択肢は各言語の自称表記とし、適用ボタンだけを選択先の言語へリアルタイム更新する。適用後は保存を同期してアプリを安全に終了し、親processの終了確認後に同じapp bundleを再起動する。
- App Constraintの明示計測中は言語変更による再起動を拒否する。helper起動に失敗した場合は選択を保存せず、現在processを継続してlocalized errorを表示する。
- 全言語でlocalization key、format placeholder、権限説明の集合が一致すること、およびSwift sourceに日本語の表示literalが残っていないことをtestとOfficial検証へ追加した。

### Compatibility / documentation

- Snap / Group / Resize / Recovery / AX / Mission Control migrationの処理ロジックと安全不変条件は変更していない。
- Versionを`2.1.0`、build numberを`16`へ更新し、README、Architecture、Privacy、Release、性能・移送の最終確認点、第三者通知を現行実装へ同期した。

## 2.0.1 — 2026-09-01

### Documentation / validation

- v2.0.0の平常状態を同一6ウィンドウ・2 Group構成で再検証し、Tabora直接CPU、WindowServer委託CPU、総合CPU、Wakeup、Memory、System CPU、Battery、Thermalを`Documentation/PERFORMANCE_VALIDATION.md`へ統合した。Full Residentの総合CPUは約38.4 ms/s、1コア約3.84%、10コア全体約0.384%。
- 最新の実機監査結果をForeground / Mission Control migrationの確認表へ反映し、現在の文書と実装の整合を再確認した。

### Settings

- 試験的Assistの設定表示を旧来の「4分割Assistを3分割へ切り替える」から現在の双方向2 / 3 / 4分割仕様に合わせ、タイトルと説明を更新した。動作ロジック、永続設定key、初期値は変更しない。

## 2.0.0 — 2026-08-29

### Space group migration

- Mission Control上のTaboraグループProxyを別Desktopへドロップし、所属する実ウィンドウを同じdestination Spaceへ移送する試験的機能を追加した。初期値はOFF。
- private SkyLight / underscored AX APIを独立Objective-C bridgeと交換可能なObservation / Transport portへ隔離した。
- source / destination visible frame間の比率投影、既知App Constraintによるcanonical調整、実geometryの接続・非重複確認を行う移送用layout plannerを追加した。
- 通常のSpace分離判定は、利用可能な環境では実Window→Space membershipを`knownSame / knownDifferent / unknown`で直接観測する。`unknown`は非破壊で、確定した外部分離だけをatomic group departureへ渡す。
- move operationのdispatchと物理成功を区別し、全memberのdestination membership確認を不可逆なphysical commit境界とした。commit前の失敗はdispatch直前のexact origin復元を検証し、commit後の失敗はSpaceを戻さずdestinationでgroupだけを解散する。
- Proxyドロップはfocus / AXRaiseを認可しない。通常Proxy選択は従来のforeground transactionを維持し、capture済みの「移動準備中／移動待機」Proxyを明示選択した場合だけpost-migration foreground intentを記録する。intentは成功済みgroupに限定し、全FIFO terminal後に選択順で一度だけ処理して最後に選択されたgroupを最前面にする。通常移送と失敗terminalではraiseしない。実行直前には通常selection-driven raiseをcancelし、controller/session停止、機能OFF、reset、wake、display topology変更では保存intentとschedule済みflushを破棄して旧environmentのクリックを再生しない。
- 非公開APIの実行時capabilityが不足またはdispatchを拒否した場合、通常Desktopへ安全に復帰してから一度だけ警告し、設定から機能をOFFにできるようにした。設定には現在のAPI状態とmacOS 26.5.2 / 26.6.2での動作確認情報を表示する。
- 実機調査用の一時HUDと永続migration logを撤去し、変化しやすいmove symbol / class / selector / ABIを`TaboraSkyLightMoveRuntime`へ分離した。
- Proxy destination確定直後のmember Space / AX publicationが一時的に`unknown`となる競合を、既存0.10秒migration monitor上の有限10回再観測へ変更した。confirmed missing、member分離、identity重複、構造変更は再試行せず従来どおり拒否し、move dispatch後の再dispatchは行わない。
- migrationで消費したProxyの退役と再生成をgroup単位で管理する。dispatch前失敗に加え`completed`直後も、同じMission Control compositor tailへ消費済みProxyが一瞬再生成されないようgroup-localなnormal Desktop rearmを要求する。これはpresentationだけの短いquarantineで、physical/group commitやforeground intentを待たせない。rollbackは不要な旧scene quarantineを持ち越さない。
- 新規groupのProxy publication直後にsource Spaceが未確定となる初期化競合へ、同一Proxyに限定した有限baseline再取得を追加した。Mission Control変形後は未確定値をsourceへ採用せず、destination所属を観測したProxyでは通常group選択より移送を優先する。move未dispatchの通常選択cancelはterminal failure隔離から分離し、次回だけProxyが欠落する経路を閉じた。
- 移送後layoutのAX frame書き込みをPID単位のlaneへ整理した。同一アプリの複数windowは位置・サイズ・位置の有限補正を直列化し、異なるアプリのlaneは並列性を維持する。完了期限は最長laneのmember数に応じて従来の1window当たり1.8秒を保持し、後続windowの補正途中でbatchを失効させない。
- Proxy dropのdestination確定と実window moveを別sceneへ分離した。Mission Control内ではpreflight/captureまでに留め、通常Desktopが2回・0.15秒以上安定してからProxyを退役しprivate moveを一度だけ発行する。同一PIDの通常windowを続けてMission Control移送した時の残留縮小transformを、AX再試行やProxy保持ではなくWindowServer operationの非重複境界で遮断する。
- move未dispatchの待機中cancelではsource向けの偽rollbackを発行しない。completed/rolledBackは既にMission Control scene外で終端するため旧quarantineを継承せず、次回Mission ControlでProxy画像が一度欠落する回帰を閉じた。
- destination capture済みProxyはMission Control内でgeometryとmanaged-window identityを固定し、暗転表示と「移動予約済み／Mission Controlを閉じると移動」で受付完了を示す。実window、Proxy ordering、collection behaviorは変更せず、同じgroupの重複captureを拒否する。
- 同一Mission Control sessionで複数groupをcaptureできるFIFO待機列を追加した。各groupのcapture・通常Desktop evidenceは独立して保持し、stable member IDと物理Window IDのキュー横断重複も拒否する。Mission Control終了後のprivate move、membership検証、layout、rollbackは一件ずつ直列実行してWindowServer operationを重ねない。
- Active Space変更の共通cleanupが移送中のAX frame batchまで`cancelAllFrameOperations()`で中断し、後続layout failureからdestination group解散へ入る競合を修正した。dispatch後からlayout/rollback終了まではmigrationがframe-operation所有者となり、Snap/Assist/resizeの既存cancel境界は変更しない。
- FIFO dispatch直前にcaptured member全体のstable identity、Window ID、単一user Space membershipを再検証する。source以外へ個別移動済みのexact memberも現在地からdestinationへ集約し、既にdestinationにいるmemberはmove対象から除外する。失敗時はTaboraが動かしたmemberだけを実行時originごとの直列batchで復元し、元から分離していたgroupは復元後に解散する。identity変更/non-user Spaceは拒否し、unknownだけは有限10回再観測する。
- capture後にmemberが別Spaceへ移されても、対象groupの少なくとも1 memberが通常Desktop geometryへ復帰した実測をMission Control終了証拠として利用し、Active Space通知が発生しない終了方法でFIFOが永久待機する境界を閉じた。全memberが非active Spaceの場合は従来どおり通知なしに推測しない。
- migration captureから全FIFOのterminalまで通常foreground fallbackによるconnected raiseを停止し、入口で失効させたfocus/clickを移動先で再生しない。Proxyの明示選択は既存の独立transactionを維持する。
- Mission Control選択とpost-migration foreground復元で、exact Window Server identityとManagedWindow再構成の直後に同じAX role/position/sizeを再取得していた重複liveness sweepを撤去した。AXRaise/focusの`interactiveOperation` 0.45秒budgetは短縮せず、遅いAX clientへの実操作余裕とfail-closed semanticsを維持したままmain run loopの重複待ちだけを削減する。
- Mission Control縮小後にも読めるよう、移動予約済みProxyのtitle/subtitleを段階的に拡大した。Proxy全体の暗転率とanimationなしの表示更新は維持し、主statusの最大サイズを48 ptへ調整する。
- 予約済みProxyの中央へ「移動準備中／移動待機」を表示し、複数予約時のFIFO位置は副表示へまとめる。member別番号は撤去し、titleを最大48 pt、subtitleを最大18 ptとして縦長・横長を含むProxy boundsへ自動的に収める。dispatch境界でProxyを同期再描画・再撮影する「移動中」切替は撤去し、待機表示のまま既存順序で退役する。同じProxyをMission Control内で再ドロップした場合は安定観測された最新destinationへcaptureを更新する。sourceへ戻した場合は失敗用のProxy退役・再armへ入れず、同じmanaged Proxyのqueued pixelと選択保留だけを解除して通常画像へ戻す。
- 受理済みcaptureの実member thumbnailへ、PID + CGWindowID完全一致の入力透過な予約shadowを追加した。「移動予約中」は最大26 ptとし、実frameに合わせて縮小する。Shadow更新を広い`refreshResizeHandles()`経路から分離し、受理済み予約scene中だけ動く表示専用10 Hz observerへ移した。pointer down/drag中はShadowを即時退避し、timerは保持したままWindow Server geometry readを0にする。mouse-up後はexact frame集合が1.5 pt以内で3 sample・0.18秒以上静止してから復帰し、WindowManagerの最後のretiling frameへ追従しない。初回表示は2 sample・0.08秒へ短縮する。settle後は全member位置取得を止め、各group 1枚のexact sentinelだけを10 Hzでprobeして、変化時だけfull geometry取得へ戻す。application activationなどの早期exit hintはpending one-shotをcancelし、後からcapture refreshが来てもlifecycle rearm debtを維持してclosing中の一瞬の再点灯を防ぐ。unresolved/normalは即時消去し、normal 2回でtimerを停止する。監視強化時にShadow geometry取得を`CGWindowListCreateDescriptionFromArray`へ置き換えたことでMission Controlのlive thumbnail frame経路を失う回帰があったため、取得元を既知の`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`へ戻し、exact PID + CGWindowIDは取得後filterに限定した。fade・Shadow専用burst監視・新規pointer monitor/event tapは持たず、Observer/Presenterの状態をtransport判断、FIFO、cancel、rollback、AX mutation、focus/raise、Space writeへ返さない。
- Reservation Shadow専用Observerが既存`lastGroupWindowServerEvidenceByIdentity`へ残存依存していたため、Active Space cleanupでcacheが消えると`.unresolved`のまま描画不能になる回帰を修正した。Shadow transform baselineはaccepted captureのexact PID + CGWindowID + `sourceFrame`としてObserver自身へ凍結し、Active Space変更はscene終了ではなく即時hide＋再証明のlifecycle hintへ戻した。これにより表示監視の独立性をtransport/presentation cacheの両方向で成立させた。
- physical commit後のAX layoutを覆っていた`GroupSpaceMigrationHandoffOverlay`を撤去した。実windowの更新が一時的に見えることは許容し、Tabora自身がdestination Desktopへfloating画像を重ねる経路をなくした。transport、membership verify、layout、group commit、Proxy rearmの順序は変更しない。
- Mission Control Proxy選択のconfirmation待機またはforeground activation中にActive Space通知が入ると、共通cleanupが選択transaction自体を破棄する競合を修正した。Active Space cleanupはexact selection ownerのProxyとactivation generationだけを維持し、unrelated Proxy、通常raise、Snap / Assist / drag pending workは従来どおり破棄する。migration presentation ownershipはこの例外へ含めない。
- Proxy確認の最初の0.14秒判定を維持しつつ、Mission Control終了後のAppKit/workspace frontmost publicationだけが遅れる場合に、同じcandidate / member / presentation generation / transition tokenへ限定した0.06秒、0.10秒の有限再観測を追加した。identity変化または上限到達は明示cancelし、通常foreground fallbackへ選択を再生しない。
- group表示番号を`SnapGroupStore`に現在存在する全groupのstable sort indexへ統一した。通常Proxyのpresentable subset indexとmigration側の累積`creationOrder`の二重化を廃止し、削除済みgroupがあっても通常Proxyとreservation shadowで同じ番号を表示する。
- 全migration terminal後のforeground-intent flushが別groupの通常Proxy activationをglobal invalidationで中断できた競合を閉じた。通常Proxy confirmation / activation中はflushを保留し、そのtransactionの成功または明示失敗から再評価する。

### Assist 2 / 3 / 4分割拡張

- 既存の試験的Option Assistを双方向へ拡張した。単一Halfが配置済みで、反対側の2 Quarterへ異なる2windowをApp Constraint込みで割り当て可能な場合だけ、Option中に残りHalfを2候補面へ分割する。
- 分割側を1枚選択した後は既存の3分割Assistへ合流し、通常のSnap transaction、再resize、group reconcile、残り1枠探索を使用する。候補がなければ既存終了経路で閉じ、専用の分割geometryやgroup形式は追加しない。
- 上端maximizeはrestoreと下層groupのocclusionを管理する可逆な表示layerとして維持しつつ、split membershipとしてAssist候補から除外しない。選択後は通常Snap transactionがmaximize layerを解除し、既存の2 / 3 / 4分割経路へ合流する。

### Foreground observation / pointer identity

- connected groupの最前面観測を`ForegroundSelectionMonitor`と専用controller extensionへ分離した。独立した10 Hz timerを廃止し、通常のmouse / AX / workspace / Mission Control eventを即時経路、既存1 Hz Recoveryを取りこぼし専用fallbackとした。
- fallbackは選択の観測だけを担当し、group raise認可、solo解除、Mission Control認可、handle表示を所有しない。drag、resize、Assist、Snap、Space移送、rollback、停止・無効化ではbaselineを破棄し、transaction前の選択を後から再生しない。
- 同一アプリの複数windowをドラッグする際、mouse-downで取得したPID + CGWindowIDと各AX windowのruntime WindowIDを一意照合する経路を追加した。private resolverが利用不能・一時失敗の場合は従来のfail-closed geometry/title照合へ戻り、別windowを代用しない。Space移送captureも全memberのWindowIDが存在し一意であることを要求し、同一surfaceの重複dispatchを拒否する。
- Snapから上端maximize、shared/native resize、Assist、Mission Control foreground、Space移送、session停止/復帰との排他境界を交差監査し、既存の有限settlement、atomic rollback、group-local authorizationを維持した。
- selection-driven認可自身にcontroller running / login session active条件を追加し、stopまたはsession lock直前にqueueされたAX/workspace callbackが後からforeground settlementを開始する経路を閉じた。
- owned AXRaise中のsame-PID外部選択でWindow ServerとAX focus/mainのpublication順がずれた場合、未確定通知がfallback baselineを先に消費しないようにした。AXの二回目通知がなくても1 Hz exact fallbackが外部Window IDを分類できる。
- Mission Controlでmemberを一枚ずつ選択した場合やCommand-Tabの結果としてgroup全体が物理的に前面へ揃った場合、追加AXRaiseを行わず、その全member前面証明を使って対象groupのautomatic foreground gateを再開放する。
- exactな新規system selectionが確定した時点で以前のautomatic認可を閉じ、同じ観測で全member前面を証明できたgroupだけを再開放するfail-closed遷移へ統一した。group-localなsolo isolation、明示Proxy選択、Snap/resize transactionの認可は維持する。

## 1.2.1 — 2026-08-25

### Mission Control Preview

- v1.2.0で導入した中央aspect-fill cropを撤回し、古いPreview画像を新geometryへ一時継承する間の描画をv1.1.1までの全面投影へ戻した。fresh capture完了前に画像の中央だけが過度に拡大され、内容が大きく切り取られる表示退行を解消する。
- resize終了後2秒の安定待ち、既存1 Hz Recoveryからの再取得、連続resizeのdebounce、1回最大2件・outstanding最大4件・同時実行2件の取得上限は維持する。
- Assist／Snap中のresize後取得保留、Preview OFF時の待機Operation・retry・cache・再適用通知の即時失効、完了時のsetting／generation再検証は維持する。

### Audit / Compatibility

- Mission Control画像の準備、geometry継承、非同期取得、cache反映、proxy再構築、Mission Control復帰までを横断監査し、表示退行以外に同時修正が必要な重大な競合や脆弱性がないことを確認した。
- 試験的なOptionホールド式3 / 4分割Assist切り替え、通常Snap、2 / 3 / 4 group、shared resize、replacement、App Constraint、Mission Control foreground authorization、Recoveryの構造認可は変更しない。
- Preview画像をidentity、group membership、placement、foreground認可へ使用しない既存の安全境界を維持する。

## 1.2.0 — 2026-08-25

### Assist 3 / 4分割拡張

- 試験的機能（初期OFF）として、隣接するQuarterが2枚配置されたAssist中にOption（⌥）を押している間だけ、残り2つのQuarterを1つのHalfへ統合する。Optionを離すと4分割候補へ戻り、切り替えはPicker geometryだけを更新してwindow frame、group、restore、replacement、Mission Control stateを変更しない。
- Option状態は通常コマンドのCarbon HotKey／keyboard event経路へ登録せず、Picker sessionが所有する約60 Hzのcombined-session modifier-state確認で直接検出する。eventは消費せず、session終了・cancel・drag・shared resize・Space/display遷移・設定OFFでtimerを破棄する。
- 次のPickerはSnap transaction終了直前に表示されるため、transaction完了の復帰点でOption監視可否を再評価する。配置中の安全gateは維持しつつ、表示済みPickerだけが監視未開始になる経路を残さない。
- 通常時は残り2面へ異なる2windowを割り当てられるかをdistinct matchingで判定し、1windowだけが統合Halfへ成立する場合は自動で3分割、0windowならAssistを終了する。Option中はQuarter側の2window判定を使わず、統合Half側の1window判定へ切り替える。ShiftによるmacOS標準のscroll軸変換を避け、統合表示のまま縦候補一覧を操作できるようにする。
- 切り替え時はPanel animationを無効にして即時差し替えし、既存Pickerのbounded preview loader/cacheを維持する。表示形式の変更を理由に候補画像を再取得せず、選択時には従来どおり現在のAX / App Constraint / replacement状態を再検証する。
- キー割り当てUIと保存値参照は撤去した。以前のbuildが保存した割り当て値は削除・移行処理を追加せず未参照のUserDefaults値として残し、公開buildの実行経路へ持ち込まない。

### Mission Control Preview

- group memberのサイズ変更をframe-key世代として追跡し、最後の変更から2秒静止した後、既存1 Hz Recoveryの安全な通常desktop gateから最大2件ずつ再取得する。連続resizeは最新geometryの1期限へdebounceし、outstanding最大4件・同時実行2件を維持する。
- resize安定待ちはHOT定期更新・COLD最終取得・memory再encodeを含む通常取得から迂回できない共通gateとする。既存の初回／COLD最終／HOT定期取得を従来順で先に処理し、安定後取得は残り容量だけを使用する。Assist／Snap中は新しい安定後laneだけを保留し、候補画像との追加競合を避ける。
- 新geometryへ一時継承した古い画像は中央aspect-fill cropで描画し、fresh capture完了前も縦横比を変えて引き伸ばさない。
- Preview設定OFFをproxy再構築から独立した即時失効処理へ変更。OFF時に待機Operation、request、deadline、cache、再適用通知を破棄し、取得直前は現在の設定、完了時は設定とgenerationを再検証する。AssistやSnapがpresentationを所有していても予約取得を残さない。

### Compatibility / Safety

- 通常Snap、既存2 / 3 / 4 group、shared resize、replacement、App Constraint、Mission Control foreground authorization、Recoveryの構造認可は変更しない。
- Previewは引き続き表示専用の破棄可能データであり、identity、group membership、placement、foreground認可には使用しない。

## 1.1.1 — 2026-08-24

### Security / Resource Safety

- Mission Control画像をmember単位のHOT / cooling / COLDへ分離。新規memberは1回取得し、露出中のmemberだけ15秒更新、隠れたmemberは3秒settle後の最終取得1回で凍結する。単独memberだけの前面化と複数displayも同じWindow Server露出判定を使う。
- group/member数やメモリ上限の変更で1枚当たりの配分が縮小しても、既存画像を先に削除せずstale-while-reencodeで差し替える。現在候補をLRU順で画像なしへ落とさない。
- 定期更新を1回最大2件、実行中と待機中を合計最大4件へ制限。HOT member数に比例するWindow Server取得backlogを作らず、rotationで古い候補を順番に更新する。
- login sessionが非アクティブな間はMission Control画像取得と10 Hzの選択pollingを停止し、1 Hz Recoveryはevent monitor再登録だけを維持する。復帰時は古い派生結果を採用せず、現在のdesktop evidenceから再開する。
- Assist候補画像は枚数を制限せず、ユニーク候補数で32 MiBを均等分割して全候補を取得する。候補数増加時は欠落ではなく解像度を下げ、panel終了時は待機中取得をcancelして世代不一致の遅延結果を破棄する。
- Mission ControlとAssistがglobal画像取得2枠を競合した場合、両方ともmain threadを塞がず最大0.45秒だけ取得枠を待つ。同時取得数2と有限retryは維持し、一時的な競合だけでretryを消費する経路を防ぐ。
- UserDefaults内の座標・待機時間設定が破損してNaN / infinityになった場合は、タイマーや表示座標へ流す前に既存の初期値へ戻す。正常な設定値の範囲とUXは変更しない。
- AX frame operationの所有keyへPIDを追加し、単調増加tokenと終了時cleanupを導入。別processのelement hash衝突と、終了済みoperation stateの無期限保持を防止する。

### Correctness / Scope

- Mission Control preview、Assist picker、session observer、selection polling、Recovery、AX mutationの開始から終了までを横断監査し、派生処理の上限とcancel ownershipだけを変更した。
- 通常時の10 Hz selection polling、1 Hz Recovery、15秒preview freshness、Mission Control foreground ordering、group identity、snap/resize geometry、App Constraintの学習条件は変更していない。
- AX呼び出し全体への新規deadlineとpassive censusの縮小は、未知状態をmissingへ誤変換する危険があるため本版には含めない。Preview activityの判定不能はCOLDへ落とさず前回状態を保持する。

## 1.1.0 — 2026-08-23

### Mission Control / Multi-display

- Mission Control復帰の根本経路を再構築。選択proxyのexact group ID / member集合 / preferred memberを固定し、その明示選択を全member foreground mutationの認可として直接使用する。実windowが既にfrontmostであることをmutation前に要求する循環条件を撤去した。
- companion raiseを止めていた`placement.appliedFrame`基準のdesktop geometry gateをactivation経路から完全撤去。この値はApp Constraint、共有resize、丸め、復元後の現在frameと一致する保証がなく、前回修正にも残っていた。
- 各retryは動作確認済みresize toggleと同じ「全companionをraiseし、preferred mainを最後にactivate/raise」を先頭から再実行する。部分成功を次回へ持ち越さず、最大20回の有限retry後もWindow Serverで全memberのfrontmostが確認できなければhandoffだけを中止する。
- proxy key eventから0.14秒の選択確認中はpreview update、ordering revalidation、通常update、window resignによるpresentation generation変更を禁止。Mission Control exit自身のkey resignで正しいクリックcallbackが失われる競合を除去した。
- 複数proxyの一時的なkey変化では最初の遅延callbackを採用せず、最後にkeyとなったproxyの世代・group ID・member集合が完全一致する場合だけ選択を消費する。Group 2の選択をGroup 1の古いcallbackへ取り違えない。
- 選択callbackが成立した時点で大きなcomposite proxyを即時order outし、desktop上のfloating coverとして残さない。成功判定にもproxyを参加させない。
- first-callback-wins型selection claim、終了後250 ms quarantine、Recoveryからのactivation再始動を撤去。排他は最新proxy候補とcontrollerのactive exact-group transactionが所有する。
- 成功・失敗・stale構造拒否・外部中断のすべてで、Mission Control遷移中に保留されたfocus/click通知を通常desktop selectionへ再生しない。失敗時はgroup membership、placement lock、従来foreground modeを保持する。

#### 保証範囲

- 選択時に表示されていた同一group ID・同一member集合だけを前面化対象にする。
- 2 / 3 / 4 memberを同じ全体passで処理し、Group 2失敗を下のGroup 1へfallbackさせない。
- companionの前面化をplacement frame一致やpreview更新へ依存させない。
- 選択済みcomposite画像をdesktop背景へ残さない。
- 成功確認前にforeground modeを変更せず、失敗時にもgroup構造を破壊しない。

#### 対象外

- AccessibilityまたはWindow Serverが全20回の観測中ずっと応答不能な場合の強制成功。
- macOS private Mission Control動作のOS version横断保証。
- display境界を越えた直後にdrag callbackなしでmouse-upした場合もdrop時点でdisplay transitionを再評価し、底面を揃えたSidecar等の境界で1pxの越境が外部display snapへ化ける経路を修正。

### 共有リサイズ境界 / UI

- 3 / 4分割のjunctionを交点の単一input ownerとし、single-axis boundary control・hit region・hover・cursor ownershipをjunction exclusion外へ退避する共通geometryへ変更。
- 2分割はjunctionが存在しないため従来の中央配置を維持し、3分割・4分割専用offsetは追加しない。
- valid groupのhandle presentationが失われた場合にgroup単位のliveness debtを検出し、bounded fast retryから既存1 Hz Recoveryへ引き継ぐ復帰経路を追加。
- 別group同士の境界が画面上で交差してもjunctionを合成せず、departure / handle cleanupも対象groupへ限定。
- shared resize中のgroup departureでinteraction終了が他groupのhandleを一時非表示にした場合も、departure commit完了前にremaining groupのhandle presentationを同期再構築し、1 Hz Recovery待ちにしない。

### Placement / Group policy

- App Constraintで実境界が50%位置から移動していても、incoming snapの所属判定をlive physical contactではなくproposed zone topologyから行い、frontmost既存groupへ合法にextensionできる場合は新規Group 2を作らない。
- proposed topologyでgroup extension / initial constraint planを共通化し、左右・上下を同じshared-boundary solverへ通す。3 / 4分割専用patchは追加しない。
- 片側halfをquarter 2枚だけで保持しているgroupへ、そのhalf全体を1枚で明示snapした場合は、incoming zoneが旧groupのlogical cellsを完全一致で覆う時だけfull-group replacementとして認可し、旧groupをAtomic Group Departureでretireする。部分重なりや不確実観測は認可根拠にしない。
- multi-member replacementで正式にdisplacedされたwindowは、操作開始時の古いlock snapshotをAssist除外根拠として残さず、commit後のauthoritative lock / group stateに従って候補へ復帰できるようにする。
- initial placementの未使用`targetFrame` bindingを除去し、plan生成成功時にcandidate targetが含まれる既存invariantへ整理。

### Settings UI

- 設定画面上部に `一般 / コマンド / サイズ制約 / 試験的機能` の4カテゴリ切替を追加し、既存設定値・action・永続keyは変更せず表示だけを整理。
- コマンドページの短い内容を上端へ固定し、document viewの余白配分で項目が上下に分離する表示崩れを修正。
- アプリ別のサイズ制約をアプリ名・記録許可・サイズ取得・読み取り専用の値確認・削除へ整理し、常時表示の数値と手動編集経路を撤去。
- 試験的機能へMission Control画像メモリ上限（16〜128 MiB）と手動キャッシュ解放を追加。既存の全member均等配分は維持する。
- リサイズ方向表示を新規環境でデフォルトONへ変更。既存UserDefaultsの明示設定は保持する。
- アプリ別のサイズ制約の「値を確認」でaccessory viewがゼロサイズになり値が見えない問題を修正し、最小幅・最小高・最大幅・最大高を`pt`単位で表示。「制約を確認」は実際の動作に合わせて「サイズを取得」へ変更。

### Snap / Assist

- Assist候補をキャンセルした後、同じスナップ済みwindowを画面上端へドラッグすると、provisional peer探索がincoming window自身を既存peerとして採用し、重複Dictionary keyのSwift trapで強制終了する経路を修正。
- Assist panelが消費したmouse-downに対応するmouse-upをdesktop clickとして再処理しないよう、pointer sequence ownershipを分離。

### Mission Control Preview

- frame不変のウィンドウ画像が無期限に残るcache key問題を、通常デスクトップ・操作停止中だけ動く15秒のstale-while-revalidateで修正。古い画像を表示したまま非同期取得し、Mission Control変形中はpresentationを再構築しない。
- メモリ上限変更時は派生画像cacheと進行中generationだけを無効化し、group identity・member順序・foreground認可・Recovery timerには変更を加えない。

### App Constraint / Correctness

- アプリ自身のconfirmed size rejectionだけをmin/max constraint候補として扱う自己学習・認証式App Constraintを追加。通常resize、AX unknown、screen limitは学習根拠にしない。
- known constraintをAX write前の2 / 3 / 4共通legal-range solverへ適用し、shared minimum / maximumと反対側participantの不等式をintersectionしてboundaryをclamp。
- shared resizeのeffective boundaryが変化しない場合はtarget再生成・scheduler submit・AX write・overlay更新を抑制。
- confirmed rejectionでcommit済みgroupが成立不能になった場合は、group destruction認可とcleanupを分離したAtomic Group Departureからhandle / toggle / proxy / placement / resize ownershipを即時retire。
- App Constraint recordを専用Codable storeへatomic保存し、app単位の記録許可、pending candidate、known値、explicit verificationを管理。
- 「サイズ制約」設定を追加し、「アプリ別のサイズ制約」で記録確認ON/OFF、app別min/max、今後の記録許可、サイズ取得、読み取り専用の値確認、record削除を提供。
- 「サイズを取得」は同一アプリに複数の標準windowがある場合、計測対象をユーザーが選択してから開始する。
- 明示的なサイズ取得中は固定プログレス表示で4辺の計測と原位置復元を通知し、完了後は別alertを重ねず、同じ表示の「完了」を押すまで結果を保持する。計測ロック自体は復元完了時に解除し、確認待ちで通常操作を停止し続けない。
- 初回スナップでscreen / system limitでは説明できないoperation-localなサイズ差を観測した場合、永続値やgroup構造を変更せず許可UIだけを先行予約する。confirmed rejectionの永続学習基準と1.8秒のbounded settlementは短縮せず、許可後の全辺明示計測だけをknown値として使用する。
- App Constraint recordのdormant lifecycleをevent-drivenに同期し、matching identityの実観測はsilent reactivate、確認済みreplacement / observed bundle disappearanceだけをdormant根拠とし、LaunchServices不確実性だけでは状態を変更しない。

## 1.0.1 — 2026-08-18

### バグ修正 / Correctness

- 3分割以上で、配置対象側が複数windowへ細分化されている場合にsplit placementがキャンセルされる問題を修正。
- single-member replacementの既存経路は変更せず、2 members以上のconflictだけをmulti-member replacementとして追加判定。
- displaced partitionとretained partitionの共有境界が同一axis・同一coordinate上で連続した一本の直線になる場合だけreplacementを認可。
- blocked multi-member conflictは同一groupへのextensionとして再吸収せず、既存のindependent split eligibilityへ戻す。
- multi-member replacementはcommit直前に対象group revision / member集合 / AX current frameだけを局所再検証し、失敗時はnew-group fallbackへ変換せずfail closed / rollback。
- 3分割専用・4分割専用のmember count patchは追加せず、2 / 3 / 4共通geometry policyとして実装。

### UI改善

- 左右端長押しで四隅候補へ切り替わる初回transitionは、点滅後も左右ハーフguideの外形を動かさず、内部へ横区切りを即時表示する方式へ変更。
- 通常snap overlay、四隅候補表示後のhover / selection、snap完了など他のanimationは変更しない。
- 四隅候補表示では選択中candidateの青いfillを通常snap guideと同じ濃さに揃え、非選択側は薄いfillを維持しつつguide線を残して、両候補の存在と現在の選択先を明確に判別できるコントラストへ調整。

### Documentation

- Architecture、Threat Model、Security / Correctness Invariants、Release Process、Origin、Migration Audit、Maintainer Setupを日本語化。
- v1.0.1のmulti-member replacement authorizationと回帰条件をSecurity / Architecture文書へ反映。

## 1.0.0 — 2026-08-18

### Identity

- SnapFlow Final v1.3.0を凍結Baselineとして、新規製品Taboraへ移行。
- Product / executable / package / test targetを`Tabora`へ変更。
- Official Bundle IDを`dev.pent.Tabora`、Community Bundle IDを`dev.pent.Tabora.community`へ分離。
- Taboraを新しいproject lineageとしてversionを`1.0.0`、build numberを`1`から開始。
- SnapFlowの公式署名証明書を引き継がず、Tabora専用Official Code Signing identityを作成・設定。

### Documentation / Repository

- README、Security、Privacy、Contributing、Support、Third-Party NoticesをTabora用に再構築。
- Origin、Architecture、Threat Model、Release Process、Security Invariants、Migration Auditを整備。
- GitHub metadataを`Pentagon22GIT/Tabora`向けに更新。
- Fast CI / Tabora Safety Invariants / CodeQLの3層を用意。
- 旧`.git`、`.build`、既存build/release成果物、過去SnapFlow release文書、Finder metadataを新規projectから除外。

### Behavior / Pre-release stabilization

- identity migrationそのものではSnap / Group / Resize / Recovery / AX / Mission Control / cursor / placementの挙動を変更せず、その後の初回公開前stabilizationとして観測済みblockerを修繕。
- cold launch時のevent monitor readinessをbounded rearmし、global mouse eventのpointer位置をmonitor callback時点で固定して最初のdragの取りこぼしを防止。
- Mission Control proxy orderingをfail-closedのままbounded再検証し、一時的なWindow Server ordering不成立で候補が恒久的に欠落しないRecovery debtを追加。
- AX / display / geometryの一時不成立によるMission Control presentation suppressionはgroup単位の有限fast retryに制限し、解消しない場合は既存1 Hz Recoveryへ移行。
- Mission Control previewの固定720×480 capを廃止し、32 MiB LRU cache budgetを現在presentation可能な全memberで共有するadaptive per-image budgetへ変更。
- いずれの修正も`members.count == 3`等の分割数専用分岐を追加せず、2 / 3 / 4共通経路へ適用。
