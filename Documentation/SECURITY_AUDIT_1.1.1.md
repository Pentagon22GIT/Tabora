# Tabora v1.1.1 セキュリティ・リソース監査

監査日: 2026-08-24

## 対象経路

- Mission Control proxy更新 → preview cache判定 → Window Server取得 → main thread反映 → Recovery更新
- login session離脱/復帰 → polling/capture停止 → event monitor維持 → desktop presentation再構築
- Assist表示 → preview要求 → timeout placeholder → picker終了/cancel → 遅延結果
- Mission Control / Assistのglobal capture競合 → 取得枠待機 → 有限timeout → retry / fallback
- Snap/Resize要求 → AX frame operation所有 → retry/timer → 完了/cancel → 後続operation
- UserDefaults読込 → 有限性・範囲検査 → geometry / timer適用

## v1.1.1で実装した対策

1. Window Serverの完全なsurface evidenceから、各group memberをHOT/COLD判定する。一部memberだけが露出する場合はそのmemberだけHOTとする。
2. 新規memberは1回取得し、HOT memberだけ15秒更新する。HOTから外れたmemberは3秒settle後に最終取得を1回行い、その後は凍結する。判定不能時は前回状態を保持する。
   frame-onlyのcache key変化は新規memberとみなさず、COLD画像を新keyへ引き継ぐ。これにより背景windowの座標揺れが再取得loopを作らない。
3. Mission Controlの周期画像取得を1回最大2件、outstanding最大4件へ制限し、rotationで公平に更新する。stale画像は表示を継続するが、generic proxy updateから取得を連鎖させない。
   member数・メモリ配分変更時も旧画像を表示したまま新budgetで再encodeし、現在候補をLRU削除しない。初回/cooling取得の一時的なnilだけを1回再試行する。
4. login session非アクティブ中はpreview captureとselection pollingを停止し、復帰時に旧generationの結果を拒否する。
5. Assist候補画像は枚数を打ち切らず、ユニーク候補数で32 MiBを均等分割する。全候補を取得し、候補数が増えた場合は解像度を下げる。一時的なnil取得は有限backoffで最大3回試行し、終了時にqueued operationとcallback/cache ownershipを破棄する。
6. AX frame operation keyをPID + element hashとし、tokenをoperation終了後も再利用しない。完了/cancel時に所有表を清掃する。
7. global画像取得数2を維持したまま、Mission ControlとAssistの両方にbackgroundで最大0.45秒の取得枠待機を認める。片方の一時的な使用でもう片方の有限retryが即時失敗になる経路を閉じる。main threadからは待機しない。
8. edge threshold、corner band、side dwell、cursor distanceの非有限値を既存初期値へfallbackし、設定破損が座標やdeadlineへ流れないようにする。

## 維持した動作

- Mission Control画像の15秒freshness、初回の非同期取得、stale-while-revalidate表示。
- 通常sessionの10 Hz selection polling、1 Hz Recovery、既存のbounded Mission Control retry。
- group/member identity、foreground ordering、Snap/Assist/Resize geometry、App Constraintの記録認可。
- 画像が取得できない場合のicon/placeholder fallback。

## 候補画像の保証境界

- 枚数上限やLRUによって、現在表示対象の候補画像を意図的に欠落させない。候補数が増えた場合は、合計budget内で全候補の解像度を下げる。
- メモリ配分の縮小中は旧画像を表示したまま新画像を作るため、差し替えの短時間だけ設定budgetを超える可能性がある。これは画像消失を避けるための有限のstale-while-reencodeであり、完了後は各画像の分割budget内に収束する。
- Window Serverが対象IDの画像を返さない、対象にCGWindowIDがない、または対象が取得中に消滅した場合は画像を保証できない。この場合は構造状態を変更せずicon/placeholderへfallbackする。

## 最終ゼロベース監査結果

- 権限取得、pointer入力、Snap / Assist / Resize、group生成・解除、Mission Control、App Constraint記録、Recovery、session離脱・復帰、設定永続化、build / release scriptの開始からcleanupまでを再監査した。
- 外部への画像・window title・制約値の送信、preview画像のディスク保存、ユーザー入力のshell文字列化、秘密情報の埋め込みは確認されなかった。
- observer / event monitor / timer / AX frame operation / preview operationはstop、cancel、generation更新へのcleanup経路を持つ。永続的に増加するsnapshot historyは30件に制限され、preview work / cacheは別の固定budgetを持つ。
- 今回、候補画像のglobal capture競合と非有限設定値の2件を修正した。それ以外に、現在の安定構造を変更して直ちに対応すべき重大なコード脆弱性は静的監査で確認されなかった。

### 残る外部境界と監査制約

- `CGWindowListCreateImage`はOS APIの同期呼び出しであり、Taboraから呼び出し中の強制cancelはできない。同時実行数と待機時間を有限にし、結果をderived stateに限定する。
- 受領した監査基準には`Config/OfficialSigning.plist`が含まれていないため、build scriptの形式検査とfail-closed経路は監査したが、実ファイルのfingerprint一致は監査対象外とする。
- 監査環境にSwift / macOS SDKがないため、compile、unit test実行、AX / Mission Control実機操作はmacOS側の最終gateとする。

## 本版で見送った変更

- 全AX呼び出しへのoperation deadline: unknownをmissingとして扱う既存経路との意味衝突を避けるため、計測を伴う独立変更とする。
- AX census範囲の縮小とper-window backoff: foreground/復帰の見逃しリスクが、今回確認した負荷対策の利益を上回る。
- foreground/group structural stateへのHOT/COLD追加: Preview controller内の派生状態だけで実装し、group identityやforeground認可には逆流させない。
- 通常時polling/recovery間隔の変更: 現在安定しているクリック前面化とRecovery latencyを保持した。

## 検証

- Preview取得枠待機の上限/main-thread非待機と、非有限設定の初期値fallbackの単体テストを追加した。
- member単位の露出/判定不能、固定budget、rotation、cooling境界、session停止、PID別operation ownership、Pickerの全候補byte分割の単体テストを追加した。
- cancel後のgeneration拒否、終了時cleanup、preview failure時の構造非変更をコード経路で再監査した。
- 監査環境にはSwift/macOS framework toolchainがないため、最終的な`swift test`とMission Control/Assist実操作はmacOS上で行う。
