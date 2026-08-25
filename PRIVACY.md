# プライバシーポリシー

最終更新日: 2026-08-25

Taboraはローカルで動作するmacOSアプリです。現在のv1.2.0ソースを静的監査した範囲では、解析、広告、テレメトリー、クラッシュレポート自動送信、ユーザーアカウント、アプリ自身によるHTTP通信を実装していません。

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

v1.2.0でも、Taboraが要求したサイズを対象アプリ自身が拒否し、settle後のaccepted boundaryを確認できた場合に限り、アプリ固有のサイズ制約候補をローカルで記録できます。通常のresize履歴や単なるAX失敗は制約として記録しません。

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

「配置候補にウィンドウ画像を表示」を有効にした場合だけ、画面収録権限を使用して配置候補およびMission Control連携で表示する対象ウィンドウのプレビュー画像を取得します。

- 初期状態では任意機能です。
- 表示用のメモリキャッシュで扱います。
- キャッシュはboundedな派生データとして破棄可能です。
- 配置候補はpanelが必要とした対象を取得します。Mission Control連携はgroup proxy構築時のcache missに加え、groupが存在して機能が有効な間、通常desktopの操作停止中に15秒以上古いactive memberだけを非同期で更新します。
- Mission Control画像はexact window IDを対象に最大2件並列で取得します。1秒ごとの画像取得、directory scan、画像ファイルscanは行いません。
- group memberのresize後は最後のframe変更から2秒静止したことを確認し、既存Recoveryの安全な通常desktop観測から再取得します。連続resizeは最新の1期限へまとめます。
- 設定をOFFにした時点で待機中の取得と再適用予約を失効し、取得直前にも現在の設定を確認します。
- ディスクへ保存する処理はありません。
- ネットワーク送信する処理はありません。

共有リサイズ中の仮想表示はAppKitの表示要素とアプリアイコンを使用し、ウィンドウ内容の画像取得を必要としません。

### 入力イベント

ドラッグ、共有リサイズ、キャンセル等を判断するために必要なマウス・キーイベントを監視します。ショートカット登録時はキーコードと修飾キーをローカル設定へ保存します。入力文字列やポインタ履歴を収集・送信する処理はありません。

## 永続保存

`UserDefaults.standard`へ、ショートカット、スナップ判定範囲、表示方式、Recovery/前面化に関係するユーザー設定、App Constraintの記録確認ON/OFFなどのscalar設定を保存します。

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
