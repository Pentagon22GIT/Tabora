# 常駐負荷・性能検証記録

この文書は、Taboraの**平常時常駐コスト**を継続的に比較するための開発記録です。
操作中の瞬間負荷やUI応答時間ではなく、各機能を有効にしたまま操作せず維持した状態で、Tabora自身とWindowServerへ委託される常駐負荷を確認します。

バージョンごとに文書を分割せず、最新の有効な常駐性能基準と、比較に必要な正式過去基準だけを保持します。

---

## 現在の常駐性能基準

- 最終計測版: **Tabora Community v2.2.0 (Build 17)**
- 計測日: **2026-09-05**
- macOS: **26.6.2 (25G83)**
- CPU: **10コア**
- 電源: **Battery Power**
- 計測時間: 各Phase **120秒**
- 解析対象: 各Phaseの先頭20サンプルを除外した **100サンプル**
- Window構成: **6 Window / 2 Group**
- 計測中はGroupの上下関係と配置を維持し、window click、layout変更、Mission Control操作、Assist実行、Space移送を行わない

### Phase

| Phase | 条件 | 用途 |
| --- | --- | --- |
| R0 | Machine Baseline | 計測環境確認 |
| R1 | 6 Window / Tabora OFF | Window構成確認 |
| R2 | Tabora Core / Groupなし | **追加機能比較の基準** |
| R3 | 2 Group維持 | Group保持 |
| R4 | Foreground ON | 最前面連動を有効化した平常状態 |
| R5 | Preview ON / 32 MiB | Previewを有効化した平常状態 |
| R6 | Migration + Assist ON | Full Resident |

R0〜R6は機能実行時のベンチマークではありません。R4でもwindowをクリックせず、R5では画像更新を意図的に発火させず、R6ではMission Control移送やAssistを実行しません。

---

## v2.2.3 (Build 20) の扱い

**v2.2.3では常駐性能を再計測しません。**

v2.2.3の実動コードとテストは安定版v2.2.1と同一であり、v2.2.2で追加した非同期操作、Preview、Mission Control Proxyの変更を継承しません。常駐timer、polling、画像取得trigger、Recovery頻度、Window Server / AXの常時観測も変更していません。

したがって、常駐コストの正式比較値はv2.2.0 Build 17の計測を引き続き基準とし、v2.2.3について未計測の性能値や改善率を新たに記載しません。

---

## v2.2.1 (Build 18) の扱い

**v2.2.1では常駐性能を再計測しません。**

v2.2.1の主な変更は、Preview HOT/COLDの判定境界、未知occluderの有限確認、可視マルチディスプレイでのforeground判定、provisional Snap peerのdisplay scopeです。これらはwindow selection、occlusion変化、Space/display遷移、Snap操作などの**イベント発生時に実行される経路**です。

現在のR0〜R6常駐計測は、計測中にwindow clickやforeground transitionを発生させない条件で固定しています。そのため同じ計測を繰り返しても、v2.2.1で変更したイベント経路を直接評価する測定にはなりません。

またv2.2.1では、常駐画像取得timer、foreground専用polling、Space polling、新しい1 Hz処理、常時AX censusを追加していません。したがって、**常駐コストの正式比較値はv2.2.0 Build 17の計測を引き続き基準とし、v2.2.1について未計測の性能値や改善率を新たに記載しません。**

将来、常駐監視頻度、Preview取得方式、Recovery tick、常時Window Server/AX observation、常駐表示処理を変更した場合は再計測します。

---

## 比較方法

性能比較では、同一計測内の **R2 Tabora Core** を基準にした差分を使用します。

- `R3 - R2`: Group保持
- `R4 - R3`: Foregroundを有効化した平常状態
- `R5 - R4`: Previewを有効化した平常状態
- `R6 - R5`: Migration + Assistを有効化した平常状態
- `R5 - R2`: CoreからPreviewまで
- `R6 - R2`: CoreからFull Residentまで

世代間比較でも、各世代の絶対値ではなく同じPhase差を比較します。

次の値は改善率の根拠に使用しません。

- 異なる計測日のR0 / R1 / R2絶対値
- 異なる計測日のSystem Power / Battery絶対値
- collector定義が異なるTabora直接CPUの絶対値
- 単発最大値だけを使った比較

OSの背景処理やWindowServer状態は計測ごとに変動するため、基準からの増分、平均、中央値、p95を優先します。

---

## WindowServer

`top`の`%CPU`は1コア基準で、`1% = 10 ms/s`としてCPU timeへ換算しています。

| Phase | WindowServer平均 | 1コアCPU | 中央値 | p95 | 最大 | Memory平均 | 最大 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| R2 Core | 5.70 ms/s | 0.570% | 0.3% | 0.50% | 20.5% | 370.4 MiB | 422 MiB |
| R3 2 Group | 6.41 ms/s | 0.641% | 0.5% | 0.605% | 8.0% | 388.4 MiB | 415 MiB |
| R4 Foreground | 6.22 ms/s | 0.622% | 0.5% | 0.605% | 8.2% | 387.1 MiB | 416 MiB |
| R5 Preview | 6.98 ms/s | 0.698% | 0.5% | 1.31% | 6.0% | 387.1 MiB | 411 MiB |
| R6 Full Resident | 6.15 ms/s | 0.615% | 0.5% | 0.70% | 5.7% | 382.4 MiB | 415 MiB |

R2の20.5%は単発値で、後続Phaseへ継続していません。常駐評価では平均・中央値・p95とPhase差を使用します。

### R2 Core基準

| Phase | R2からの増分 | 1コア換算 |
| --- | ---: | ---: |
| R3 2 Group | **+0.71 ms/s** | +0.071% |
| R4 Foreground | **+0.52 ms/s** | +0.052% |
| R5 Preview | **+1.28 ms/s** | +0.128% |
| R6 Full Resident | **+0.45 ms/s** | +0.045% |

### 追加機能ごとの差

| 比較 | 追加状態 | WindowServer差 | 1コア換算 |
| --- | --- | ---: | ---: |
| R3 − R2 | 2 Group | +0.71 ms/s | +0.071% |
| R4 − R3 | Foreground | −0.19 ms/s | −0.019% |
| R5 − R4 | Preview | **+0.76 ms/s** | **+0.076%** |
| R6 − R5 | Migration + Assist | −0.83 ms/s | −0.083% |

負値は性能改善量として扱わず、背景変動が小さい機能差を上回った値として保持します。

---

## v2.0.0との正規化比較

正式な過去比較点として、2026-09-01の **Tabora v2.0.0** R0〜R6検証を使用します。

| 到達状態 | v2.0.0: R2基準差 | v2.2.0: R2基準差 | 変化 |
| --- | ---: | ---: | ---: |
| R3 2 Group | +9.0272 ms/s | **+0.71 ms/s** | 約92.1%縮小 |
| R4 Foreground | +9.9617 ms/s | **+0.52 ms/s** | 約94.8%縮小 |
| R5 Preview | +40.0279 ms/s | **+1.28 ms/s** | 約96.8%縮小 |
| R6 Full Resident | +36.9711 ms/s | **+0.45 ms/s** | 約98.8%縮小 |

絶対値ではなく、各計測内でR2 Coreを0とした追加コストを比較しています。

### Preview固有差 — R4 → R5

| Version | WindowServer増分 | 1コア換算 |
| --- | ---: | ---: |
| v2.0.0 | +30.0662 ms/s | +3.0066% |
| v2.2.0 | **+0.76 ms/s** | **+0.076%** |

v2.0.0のR5/R6では約24%のp95を伴う周期的なWindowServer spikeがありました。v2.2.0ではR5 p95 **1.31%**、R6 p95 **0.70%**で、同じ周期形状は残っていません。

この差は、通常Previewを時間経過で更新せず、初回・確定geometry・確定HOT→COLD-visibleなどのイベントへ限定した現在の取得方式と整合します。

---

## Taboraプロセス直接負荷

v2.2.0計測内でのTabora process-energy値です。v2.0.0は異なるcollector定義のため、直接CPUの世代間絶対比較には使用しません。

| Phase | Tabora CPU平均 | 1コアCPU | R2からの増分 | 増分1コア換算 | Interrupt Wakeups平均 |
| --- | ---: | ---: | ---: | ---: | ---: |
| R2 Core | 2.2479 ms/s | 0.2248% | — | — | 0.992/s |
| R3 2 Group | 2.5480 ms/s | 0.2548% | +0.3001 ms/s | +0.0300% | 1.003/s |
| R4 Foreground | 3.9112 ms/s | 0.3911% | +1.6633 ms/s | +0.1663% | 1.022/s |
| R5 Preview | 4.0865 ms/s | 0.4087% | +1.8386 ms/s | +0.1839% | 1.322/s |
| R6 Full Resident | 4.1133 ms/s | 0.4113% | +1.8654 ms/s | +0.1865% | 1.331/s |

R5→R6のMigration + Assist追加差は **+0.0268 ms/s / 1コア+0.00268%**、Interrupt Wakeup差は約+0.0085/sです。

---

## CPU / GPU / ANE / SoC Power

| Phase | CPU Power平均 | GPU Power平均 | ANE Power平均 | Combined平均 | GPU active平均 | GPU active中央値 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| R2 Core | 185.47 mW | 0.50 mW | 0 mW | 185.96 mW | 0.189% | 0% | 0% |
| R3 2 Group | 156.31 mW | 0.16 mW | 0 mW | 156.47 mW | 0.197% | 0% | 0.012% |
| R4 Foreground | 152.72 mW | 0.07 mW | 0 mW | 152.79 mW | 0.099% | 0% | 0% |
| R5 Preview | 154.30 mW | 0.15 mW | 0 mW | 154.43 mW | 0.209% | 0% | 0.25% |
| R6 Full Resident | 150.91 mW | 0.07 mW | 0 mW | 150.98 mW | 0.104% | 0% | 0% |

System側の背景変動を含むため、Combined Powerの負差をTaboraの省電力効果として扱いません。機能追加に伴う持続的な正方向増加があるかを確認します。

- R4→R5 Preview: Combined **+1.64 mW**
- R5→R6 Migration + Assist: Combined **−3.45 mW**
- GPU active中央値: 全Phase **0%**
- ANE Power: 全Phase **0 mW**

平常計測ではPreview / Full Residentによる継続的なGPU / ANE稼働は記録されていません。

---

## Memory / VM

Tabora自身のPhysical Footprintはv2.0.0と同じ定義では取得していないため、Preview cacheやMission Control transient cacheの実RAM量を世代間比較しません。

WindowServer MemoryはR2〜R6で平均約370〜388 MiBの範囲です。WindowServerはTabora以外の合成資源も共有するため、Tabora専用Memoryとして扱いません。

各Phase内のPageout / Swapin / Swapout増分は **0** でした。

---

## 開発上の基準

v2.2.0 Build 17の計測から、常駐性能について次を基準として保持します。

- Preview固有のR4→R5 WindowServer増分: **+0.76 ms/s / 1コア+0.076%**
- Core→PreviewのR2→R5増分: **+1.28 ms/s / 1コア+0.128%**
- Core→Full ResidentのR2→R6増分: **+0.45 ms/s / 1コア+0.045%**
- R5 p95: **1.31%**
- R6 p95: **0.70%**
- Tabora直接Full Resident: **4.1133 ms/s / 1コア0.4113%**
- Tabora直接R2→R6増分: **+1.8654 ms/s / 1コア+0.1865%**
- Migration + Assist idle差: **+0.0268 ms/s / 1コア+0.00268%**
- GPU active中央値: **0%**
- Pageout / Swap増分: **0**

これらは平常状態の比較基準です。window click、foreground raise、Snap、Mission Control、Space移送、resize操作そのものの瞬間コストを表す値ではありません。

---

## 再計測ルール

次のいずれかを変更した場合は、同じR0〜R6構成で常駐性能を再計測します。

1. 常駐timer / polling頻度
2. Previewの時間ベースまたは周期取得方式
3. foreground selectionの常駐監視方式
4. Recovery tickの頻度または対象範囲
5. Window Server / AXの常時census
6. 常駐overlay / observerの更新頻度
7. cache / capture admissionが平常時の取得頻度を変える変更

比較ではR2 Coreを基準にし、同じPhase差・同じcollector定義を使用します。負のPhase差は0へ丸めず、背景変動を含む実測値として保持します。
