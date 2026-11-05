# プライバシーポリシー

最終更新日: 2026-11-05（v2.4.0ローカル開発版）

Taboraはローカルで動作するmacOSアプリです。v2.4.0のソースには、解析、広告、テレメトリー、クラッシュレポート自動送信、ユーザーアカウント、アプリ自身によるHTTP通信を実装していません。

## ローカルで扱う情報

### Accessibility / Window Server情報

ウィンドウの配置・識別・前面順・復元・共有リサイズのため、Accessibility APIとWindow Serverから次のような情報を一時的に扱います。

- PID / CGWindowIDなどのアプリ・ウィンドウidentity
- ウィンドウ位置・サイズ
- ウィンドウタイトル
- 前面順、現在の表示状態
- 操作可否・AX属性

これらはSnap / Assist / Group / Recovery / Mission Control連携等のローカル機能に使用します。ウィンドウ一覧、タイトル、座標履歴を外部サーバーへ送信する処理はありません。

### App Constraint記録

Taboraが要求したサイズを対象アプリ自身が拒否し、settle後のaccepted boundaryを確認できた場合に限り、アプリ固有のサイズ制約候補をローカルで記録できます。通常のresize履歴や単なるAX失敗は制約として記録しません。

試験的なDesktop間グループ移送を有効にした場合、TaboraはWindow ServerからウィンドウID、Space ID、Space種別、Managed Display識別子を実行中のメモリへ読み取ります。これらは移送・分離確認だけに使用し、ネットワーク送信や新規の永続ファイル保存は行いません。

記録対象には、必要に応じて次が含まれます。

- アプリ表示名
- native appのBundle IDとDesignated Requirement
- Chrome Web Appの場合はparent Chrome identityとcanonical Web App ID
- minWidth / minHeight / maxWidth / maxHeightのcandidate / known state
- アプリ単位の記録許可
- constraintの確認待ち・要確認・dormant状態
- 記録の更新時刻

永続keyにはPID、CGWindowID、AX element hash、ウィンドウタイトル、ウィンドウ位置・サイズ履歴、アプリversion、bundle pathを使用しません。Chrome Web App間でconstraint値を自動共有しません。

App Constraint recordは次のローカルJSONへ保存します。

```text
~/Library/Application Support/Tabora/<Bundle ID>/constraints-v1.json
```

このファイルはschema version付きでatomic writeし、外部サーバーへ送信する処理はありません。ユーザーが設定からrecordを削除した場合、そのrecordのlearned values、permission、pending candidate、dormant stateを削除します。

### Preview画像

Preview取得・Mission Control安定判定のデバッグ診断機能は、Debug / Releaseのいずれにも含めません。診断専用の取得時間計測も行わず、画像取得情報や安定判定情報を統合ログへ出力する処理はありません。アプリ独自の画像ファイル、診断ログファイル、不具合レポートファイルを自動作成する処理はありません。設定保存とメモリ内の画像キャッシュは従来どおりです。Appleが生成・管理するOS側のレポートや、配布アプリに含まれない開発者用リリースツールの記録は、このアプリ本体の処理とは別です。

「配置候補にウィンドウ画像を表示」を有効にした場合だけ、画面収録権限を使用して配置候補およびMission Control連携で表示する対象ウィンドウのプレビュー画像を取得します。

- 初期状態では任意機能です。
- 表示用のメモリキャッシュで扱います。
- キャッシュはboundedな派生データとして破棄可能です。
- 配置候補はpanelが必要とした対象を取得します。Mission Controlの通常Preview cacheは新規member、確定resize/display移動、確定HOT→COLD-visibleだけをtriggerとして更新し、Space等でGroupが不可視になった`COLD-not-visible`だけでは画像を取得しません。時間経過やcache ageを理由とした定期取得も行いません。
- 初期OFFの試験的設定「Mission Control内で最新の画像に切り替える」とプレビュー表示を両方有効にし、Mission Controlを開いた場合だけ、開始時に可視だったSpace上のgroupについて、変形geometryが安定した後にSkyLightの全サイズ取得で一時画像を取得する場合があります。全透明・寸法不足・縦横比不一致・取得失敗の時だけ、Core Graphicsの対象window直接取得を一度fallbackとして使用します。全サイズ取得の前後で画面収録許可と対象windowのownerを確認し、新たな権限promptや別windowへの代替取得は行いません。この画像はMission Control表示/選択handoff専用で通常Preview cacheへ保存せず、session終了またはhandoff終了でメモリから破棄します。
- 内部更新をOFFにすると取得sessionを失効し、一時画像を破棄します。通常時のプレビューは維持します。内部更新の取得が空の場合は同じ認可session内だけで1回再試行します。
- Mission Control一時画像には通常Preview cacheとは別のbounded memory limitとsessionあたりの取得上限を設け、直接window取得transactionを同時に1本へ制限します。連続開閉で旧要求が未完了の場合は新しい取得を重ねず、session失効後はglobal capture admission待機後と画像縮小処理前にも認可を再確認して、不要な取得・派生処理を可能な限り早く棄却します。
- 設定画面のメモリ上限は、通常キャッシュとMission Control中だけの一時キャッシュを合わせた合計値です。表示値の半分を通常キャッシュ枠、残り半分を一時キャッシュ枠として使用し、初期表示64 MiBでは各32 MiBです。
- 通常Preview取得の実Window Server並列数は既存global gateに従います。1秒ごとの画像取得、directory scan、画像ファイルscanは行いません。
- group memberのresize後は最新geometryを時間差の複数観測で確認してから通常Previewを再取得します。連続resizeは物理windowごとの最新候補へまとめます。
- 設定をOFFにした時点で待機中の取得と再適用予約を失効し、取得直前にも現在の設定を確認します。
- ディスクへ保存する処理はありません。
- ネットワーク送信する処理はありません。

共有リサイズ中の仮想表示はAppKitの表示要素とアプリアイコンを使用し、ウィンドウ内容の画像取得を必要としません。

### 入力イベント

ドラッグ、共有リサイズ、キャンセル等を判断するために必要なマウス・キーイベントを監視します。ショートカット登録時はキーコードと修飾キーをローカル設定へ保存します。入力文字列やポインタ履歴を収集・送信する処理はありません。

## 永続保存

`UserDefaults.standard`へ、ショートカット、スナップ判定範囲、表示方式、Recovery/前面化に関係するユーザー設定、App Constraintの記録確認ON/OFF、選択した表示言語などのscalar設定を保存します。表示言語は初回起動時だけmacOSの最優先言語から決定し、対応する言語codeを`appLanguage`と`AppleLanguages`へ保存します。言語一覧や選択結果を外部へ送信しません。

App Constraintのアプリ別record本体は`UserDefaults`へ詰め込まず、前述の専用Application Support JSONへ保存します。

Official (`dev.pent.Tabora`) と Community (`dev.pent.Tabora.community`) は別Bundle IDであるため、UserDefaultsの設定domainとApp Constraint recordの保存directoryを分離します。Taboraは新規productであり、SnapFlowのUserDefaults domainを自動移行・読み込みする処理を追加していません。

## 実験的workspace設定

利用者が実験的なSpace edge delay設定を操作した場合、Taboraは`/usr/bin/defaults`でmacOS Dockの`workspaces-edge-delay`を読み書きし、適用時に`/usr/bin/killall Dock`を実行します。これはmacOS全体の設定変更であり、設定画面上でも明示します。Tabora終了時に自動復元する処理はありません。

## ネットワーク通信

Tabora自身に`URLSession`等のHTTP clientはありません。「更新を確認…」を選ぶと次の固定URLを既定ブラウザへ渡します。

```text
https://github.com/Pentagon22GIT/Tabora/releases/latest
```

その後のブラウザ通信にはGitHubと使用ブラウザのポリシーが適用されます。Taboraはブラウザの通信内容を受け取りません。

## 権限の解除

```text
システム設定 > プライバシーとセキュリティ > Accessibility
システム設定 > プライバシーとセキュリティ > 画面収録
```

プレビュー画像だけを停止する場合はTaboraの設定から無効化できます。

## Community版とFork

この文書は公式repositoryの当該ソースに基づきます。第三者Forkや改造版には追加の保存・通信処理が含まれる可能性があります。


## v2.4.0 ローカル開発版の変更

初回案内の完了状態を `initialSetupCompleted` として現在のエディションのUserDefaultsへ保存します。初回案内中はウィンドウ操作controllerを開始しません。画像取得とログイン項目は利用者が選択した場合だけ有効にします。初回案内の表示・選択に関する分析データは送信しません。

管理中のウィンドウの終了を早く反映するため、既存のフォーカス通知と共通のAXObserverで、対象ウィンドウの破棄通知を登録します。管理から外れた対象の登録は解除し、定期ポーリングを追加しません。アプリ停止・無効化・ユーザーセッション停止でも管理対象の登録を解除します。

「一般」の削除機能は現在のエディションの設定domainと `Application Support/Tabora/<bundle ID>/constraints-v1.json` だけを消去します。本体の削除を選ぶ場合はログイン項目を解除し、実行中のアプリをゴミ箱へ移動します。OSが管理する権限・診断記録、未知のファイル、他のコピーは変更しません。空の保存ディレクトリを再帰的に消す処理はありません。画像キャッシュは終了によりメモリから解放されます。

案内の表示履歴は `viewedAppInformationRevision` として端末内に保存します。これは案内の再表示を制御する情報であり、利用規約への同意記録ではありません。通常更新・言語変更では再表示せず、重要な内容の改訂時に再表示します。更新時の案内を閉じても利用を開始でき、権限設定は変更しません。設定だけを削除した場合は初回完了状態と実際に表示した案内の版を残し、全アンインストールでは両方とも削除します。

設定だけの削除でも、現在のエディションのログイン時の起動登録を解除します。制約記録だけの削除ではログイン項目と一般設定を変更しません。削除処理には実行中のBundle IDとアプリのパスが一致することを要求し、別エディションを対象にする呼び出しを拒否します。
