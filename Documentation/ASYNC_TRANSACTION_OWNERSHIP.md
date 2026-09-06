# 非同期window操作の所有権

## 目的

TaboraはSnap、Restore、shared resize、App Constraint計測、Mission ControlのDesktop間移送で、同じ実windowへ時間差のあるAccessibility操作を送ることがあります。この文書は、古い処理と新しい処理が同じwindowを同時に変更しないための共通境界を定義します。

## 基本規則

1. 実windowのframeを書き込むtransactionは、開始から完了または明示的取消まで一つの所有者を持つ。
2. 新しい所有者へ渡す前に、古いframe operationのgenerationを失効させる。
3. 古いcallbackは、自身のgeneration、transaction ID、phase、member identityが現在値と一致する場合だけ後続処理を開始できる。
4. timeoutは「古い処理を無視する」だけでは完了しない。実行中operationを取り消してから復元または次transactionへhandoffする。
5. presentation、Preview、進捗表示はwindow mutationの所有者にならない。

## 所有者と開始制限

| 所有者 | 所有期間 | 競合する新規操作 |
| --- | --- | --- |
| Snap rollback | rollback開始から全snapshotの復元完了まで | event Snap、shortcut Snap、Restore、shared resize、App Constraint計測 |
| Group Space Migration | `dispatchingMove`からrollback、layout、rebuildのterminalまで | event Snap、shortcut Snap、Restore、shared resize、App Constraint計測 |
| Restore | 対象snapshotの適用と必要なrollback完了まで | 既存のapplication interaction suppressionで遮断 |
| shared resize rollback | scheduler停止から元frame復元完了まで | 既存のresize ownershipで遮断 |
| App Constraint計測 | 最初のprobeから元frame復元完了まで | 既存のmeasurement suppressionで遮断 |

Mission Control移送の`awaitingNormalDesktopDispatch`は実windowへframeを書き込んでいません。この待機phaseをwindow mutation所有として扱うと、Mission Control終了を伝える通常Desktop観測まで止めるため、所有開始は`dispatchingMove`以降に限定します。待機中に別操作が始まった場合は、dispatch直前に共通transaction driverがcontroller状態とgroup構造を再検証し、条件不成立ならprivate moveを開始しません。

## Migration frame batch

移送後layoutはPIDごとのlaneで実行します。同一PIDのwindowは直列、異なるPIDは並列です。

- `begin(memberID:)`が成功したmemberだけをin-flightとして扱う。
- callbackは`resolve(memberID:succeeded:)`が現在batchで受理された場合だけ、同じlaneの次memberを開始できる。
- timeoutまたは取消ではin-flight memberのAX frame operationを先に取り消す。
- timeout後のfailure completionは、取消完了後にdestination entry frame復元へ進む。
- environment invalidationによるcancelはfailure completionを起動しない。migration owner自身がgroup解散とterminalを処理する。

これにより、復元が始まった後に古いlane callbackが次のwindowへ旧layoutを書き込む経路を閉じます。

## Mission Control Proxy selection

Proxy選択確認はselection generation、candidate generation、group ID、member集合、presentation generation、transition tokenへ束縛します。取り消された遅延callbackは、最初に自身のselection generationを確認し、一致しなければ何も変更せず終了します。古いcallbackから現在の`selectionConfirmationIsPending`を閉じたり、新しい候補をreleaseしたりしてはいけません。

## Preview geometry confirmation

Previewの取得画像はwindowの位置ではなくpixel sizeと物理surfaceに依存します。geometry確認中に位置だけが変わった場合、次をすべて満たせば同じ候補の有限確認を継続します。

- PIDが同じ
- Window IDが同じ
- stable identityが同じ
- display IDが同じ
- pixel width / heightが同じ

size、display、PID、Window ID、stable identityのいずれかが変わった場合は同じ候補として扱いません。位置変更を新規取得triggerにはせず、確認候補を残留させて他の有限Preview debtを止め続けることも避けます。

## 性能境界

これらは既存のevent、timeout、callbackで行う定数時間のidentity / generation確認です。常駐timer、polling、画像取得trigger、Recovery頻度、Window Server census、AX censusを追加しません。平常時常駐性能の測定条件と取得頻度は変更しません。

## 変更時の確認

- timeout後に遅れて返ったframe callbackが次memberを開始しない。
- 復元開始前に旧in-flight generationがすべて失効する。
- environment invalidationがlayout failure用の復元callbackを重複起動しない。
- Snap rollback中に新しい計測、Snap、Restore、shared resizeを開始しない。
- Mission Control移送待機中は通常Desktop観測を維持し、dispatch時に現在の構造を再検証する。
- Proxy選択を取消して直ちに再選択しても、旧callbackが新候補を終了しない。
- Preview resize確認中の位置移動では確認を継続し、size/display/identity変更では継続しない。
