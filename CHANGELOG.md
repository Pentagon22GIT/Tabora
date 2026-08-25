# 更新履歴

## 1.2.0 — 開発中

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
- 非有限geometryを拒否するMission Control Preview testで`CGFloat`型を明示し、Swiftの`Double.infinity`との型推論競合を解消する。productionの画像取得・描画経路は変更しない。

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

#### 今回担保する範囲

- 選択時に表示されていた同一group ID・同一member集合だけを前面化対象にする。
- 2 / 3 / 4 memberを同じ全体passで処理し、Group 2失敗を下のGroup 1へfallbackさせない。
- companionの前面化をplacement frame一致やpreview更新へ依存させない。
- 選択済みcomposite画像をdesktop背景へ残さない。
- 成功確認前にforeground modeを変更せず、失敗時にもgroup構造を破壊しない。

#### 今回担保しない範囲

- AccessibilityまたはWindow Serverが全20回の観測中ずっと応答不能な場合の強制成功。
- macOS private Mission Control動作のOS version横断保証。
- このLinux監査環境でのmacOS実機動作確認。`swift test`と実操作確認はmacOS側で必要。
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

- Assist候補をキャンセルした後、同じスナップ済みwindowを画面上端へドラッグすると、provisional peer探索がincoming window自身を既存peerとして採用し、重複Dictionary keyのSwift trapで強制終了する問題を修正。3件のcrash reportはいずれも同一stackであることを確認。
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
