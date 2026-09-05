# 常駐負荷・性能検証記録

この文書は、Taboraの平常時常駐コストを、アプリ自身の直接CPU、WindowServerへ委託される表示処理、CPU/GPU/ANE電力、GPU稼働、Memory/VM状態まで含めて検証するための継続記録です。

バージョンごとに文書を分割せず、同じR0〜R6構成で再計測し、最新の有効な結果と過去の正式比較基準だけを残します。

---

## 最新の検証 — 2026-09-05

- 対象: **Tabora Community v2.2.0 public candidate**
- 計測セッション: `2026-09-05_014152`
- macOS: **26.6.2 (25G83)**
- CPU: **10コア**
- 電源: **Battery Power**
- 計測時間: 各Phase **120秒**
- 解析対象: 各Phaseの先頭20サンプルを除外した **100サンプル**
- WindowServer PID: 全Phase **419で固定**
- R2〜R6 Tabora PID: **11602で固定**
- `powermetrics_exit=0`
- `top_exit=0`
- Window / Group / Phase間操作条件は、過去の正式R0〜R6検証と同じ形式を維持

### 検証Phase

| Phase | 条件                    | 主目的                   |
| ----- | ----------------------- | ------------------------ |
| R0    | Machine Baseline        | 計測環境の健全性確認のみ |
| R1    | 6 Window / Tabora OFF   | 6 Window状態の環境確認   |
| R2    | Tabora Core / Groupなし | **機能増分比較の基準**   |
| R3    | 2 Group維持             | Group保持コスト          |
| R4    | Foreground ON           | 最前面連動の常駐増分     |
| R5    | Preview ON / 32 MiB     | Previewを含む平常コスト  |
| R6    | Migration + Assist ON   | Full Resident            |

R0〜R6は操作中の瞬間性能ではなく、各機能を有効化した**安定した平常状態の常駐コスト**を測定する。R5/R6ではMission Controlを開かず、AssistやMigrationの実操作も発動させない。

---

# 比較方法

今回から世代間比較の基準を明確にする。

## 使用する比較

性能改善の評価では、**同一Campaign内のR2 Tabora Coreを基準にした差分**を主に使用する。

- `R3 - R2`: Group保持を加えた差
- `R4 - R3`: Foregroundを加えた差
- `R5 - R4`: Previewを加えた差
- `R6 - R5`: Migration + Assistを加えた差
- `R5 - R2`: CoreからPreviewまでの累積差
- `R6 - R2`: CoreからFull Residentまでの累積差

世代間では、**各世代の絶対値同士ではなく、同じ基準から計算した差分同士**を比較する。

## 使用しない比較

以下はコード改善率の根拠として使用しない。

- R0絶対値の世代間比較
- R1絶対値の世代間比較
- R2絶対値の世代間比較
- 異なるCampaignの素のSystem Power / Battery値の比較
- 異なるcollectorで取得したTabora直接CPUの絶対値比較

同じMac・OS・Window構成でも、CPU温度、OSバックグラウンド処理、WindowServerの一時的状態などにより基礎値は変動する。このため、**基準値そのものではなく、同じCampaign内で基準から何が増えたか**を比較する。

R0/R1は計測環境の破綻検出には使用するが、性能改善率の計算には使用しない。

---

# データ品質

今回の7 Phaseは、常駐比較用データとして有効と判断する。

- R0〜R6すべてWindowServer `top` **120サンプル**
- 各Phaseの先頭20を除外し **100サンプル**を解析
- `powermetrics`も全Phase **120サンプル**、解析対象100サンプル
- CPU Power / GPU Power / ANE Power / Combined Power / GPU active residencyは全Phaseで解析可能
- R2〜R6でTabora process-energy行を継続取得
- WindowServer PIDは全Phase419で不変
- R2〜R6 Tabora PIDは11602で不変
- 各Phase内 Pageout増分 **0**
- 各Phase内 Swapin / Swapout増分 **0**
- Battery Powerを維持

`powermetrics.stderr`には `Second underflow occured.` が記録されているが、対象100サンプルのCPU/GPU/ANE/Combined PowerおよびGPU residencyは欠損していない。

また、WindowServer CPUは`top`と`powermetrics`の2系列で取得できており、主要なR2基準差がほぼ一致している。これは今回のWindowServer評価を補強する独立クロスチェックとして扱う。

---

# WindowServer — 現行Campaign

`top` の `%CPU` は1コア基準であり、`1% = 10 ms/s`としてCPU timeへ換算する。

以下の絶対値は**今回Campaign内部の記録**であり、過去バージョンの素の値とは比較しない。

| Phase            | WindowServer平均 | 1コアCPU | 中央値 |    p95 |  最大 | Memory平均 |    最大 |
| ---------------- | ---------------: | -------: | -----: | -----: | ----: | ---------: | ------: |
| R2 Core          |        5.70 ms/s |   0.570% |   0.3% |  0.50% | 20.5% |  370.4 MiB | 422 MiB |
| R3 2 Group       |        6.41 ms/s |   0.641% |   0.5% | 0.605% |  8.0% |  388.4 MiB | 415 MiB |
| R4 Foreground    |        6.22 ms/s |   0.622% |   0.5% | 0.605% |  8.2% |  387.1 MiB | 416 MiB |
| R5 Preview       |        6.98 ms/s |   0.698% |   0.5% |  1.31% |  6.0% |  387.1 MiB | 411 MiB |
| R6 Full Resident |        6.15 ms/s |   0.615% |   0.5% |  0.70% |  5.7% |  382.4 MiB | 415 MiB |

単発最大値は背景処理の影響を強く受けるため、評価では平均・中央値・p95とPhase差を優先する。特にR2には20.5%の単発サンプルがあるが、後続Phaseへ継続していない。

## R2 Core基準のWindowServer増分

| Phase            |   R2からの増分 | 1コア換算 | `powermetrics`でのR2差 | 評価                  |
| ---------------- | -------------: | --------: | ---------------------: | --------------------- |
| R3 2 Group       | **+0.71 ms/s** |   +0.071% |            +0.632 ms/s | 小さい増分            |
| R4 Foreground    | **+0.52 ms/s** |   +0.052% |            +0.479 ms/s | Core基準で小さい      |
| R5 Preview       | **+1.28 ms/s** |   +0.128% |            +1.247 ms/s | Preview込みでも小さい |
| R6 Full Resident | **+0.45 ms/s** |   +0.045% |            +0.428 ms/s | Coreと実質近い        |

`top`と`powermetrics`のR2基準差が非常に近く、R5/R6の小さい増分が単一collector固有の計算結果ではないことを確認できる。

## Phaseごとの追加コスト

| 比較    | 追加機能           | WindowServer差 |   1コア換算 | 判断                 |
| ------- | ------------------ | -------------: | ----------: | -------------------- |
| R3 − R2 | 2 Group            |     +0.71 ms/s |     +0.071% | 小さい               |
| R4 − R3 | Foreground         |     −0.19 ms/s |     −0.019% | 正の増分を検出しない |
| R5 − R4 | Preview            | **+0.76 ms/s** | **+0.076%** | 非常に小さい         |
| R6 − R5 | Migration + Assist |     −0.83 ms/s |     −0.083% | 正の増分を検出しない |

負値は性能改善量として解釈しない。背景変動が対象機能の小さい常駐差を上回ったことを示す値として、そのまま保持する。

---

# v2.0.0との正規化比較

正式な過去比較点として、2026-09-01の **Tabora v2.0.0** R0〜R6検証を使用する。

比較するのは各Phaseの素のWindowServer値ではなく、**それぞれのCampaignのR2 Coreからの増分**である。

## Core基準からの委託増分

| 到達状態         | v2.0.0: R2基準差 | v2.2.0: R2基準差 |        差分縮小 |
| ---------------- | ---------------: | ---------------: | --------------: |
| R3 2 Group       |     +9.0272 ms/s |   **+0.71 ms/s** | **約92.1%縮小** |
| R4 Foreground    |     +9.9617 ms/s |   **+0.52 ms/s** | **約94.8%縮小** |
| R5 Preview       |    +40.0279 ms/s |   **+1.28 ms/s** | **約96.8%縮小** |
| R6 Full Resident |    +36.9711 ms/s |   **+0.45 ms/s** | **約98.8%縮小** |

この比較はR2そのものの絶対値を比較していない。各Campaign内でCoreを0として、追加機能によってWindowServer側へどれだけ負荷が増えたかを比較している。

特に重要なのはR5/R6である。v2.0.0ではCoreからPreviewまで約40.0 ms/s、Full Residentまで約37.0 ms/sのWindowServer増分が観測されていたが、今回v2.2.0ではそれぞれ**1.28 ms/s / 0.45 ms/s**に留まる。

改善率は単一測定からコード効率を小数点単位で断定するための値ではないが、**委託常駐負荷の桁が変わった**ことを示すには十分大きい差である。

## Preview固有差 — R4 → R5

Preview追加直前のR4を基準にすると、比較はさらに直接的になる。

| Version | R4 → R5 WindowServer増分 |   1コア換算 |
| ------- | -----------------------: | ----------: |
| v2.0.0  |            +30.0662 ms/s |    +3.0066% |
| v2.2.0  |           **+0.76 ms/s** | **+0.076%** |

Previewを有効にしたことによる同一Campaign内増分は、v2.0.0からv2.2.0で**約97.5%縮小**した。

これは周期的freshness取得を常用せず、初回・Resize・HOT/COLD確定・必要イベントを中心に取得する現在のPreview設計と整合する。

## WindowServer spike形状

v2.0.0のR5/R6ではWindowServer p95が約24%で、Preview更新に対応する大きな周期的spikeが確認されていた。

今回のv2.2.0では、

- R5 p95: **1.31%**
- R6 p95: **0.70%**
- R5最大: 6.0%
- R6最大: 5.7%

となった。

今回も短いWindowServer spike自体は存在するが、同様の短い山はR2〜R4にも存在し、v2.0.0で見られたPreview固有の約47秒周期・約24% p95級の形状は確認されない。

したがって、平均差だけでなく**spike形状の観点でもPreview常駐取得の負担は大幅に縮小している**と評価する。

---

# Taboraプロセス直接負荷 — 今回Campaign内のみ

今回の`powermetrics`ではR2〜R6のTabora process-energy行を100サンプルずつ取得できた。

ただし、2026-09-01 v2.0.0のTabora直接CPUは専用Benchmark Appによる累積CPU timeから算出しており、collectorと定義が異なる。そのため**v2.0.0との絶対値比較・改善率計算には使用しない**。

今回Campaign内のPhase差を見るためには使用できる。

| Phase            | Tabora CPU平均 | 1コアCPU | R2からの増分 | 増分の1コア換算 | Interrupt Wakeups平均 |
| ---------------- | -------------: | -------: | -----------: | --------------: | --------------------: |
| R2 Core          |    2.2479 ms/s |  0.2248% |            — |               — |               0.992/s |
| R3 2 Group       |    2.5480 ms/s |  0.2548% | +0.3001 ms/s |        +0.0300% |               1.003/s |
| R4 Foreground    |    3.9112 ms/s |  0.3911% | +1.6633 ms/s |        +0.1663% |               1.022/s |
| R5 Preview       |    4.0865 ms/s |  0.4087% | +1.8386 ms/s |        +0.1839% |               1.322/s |
| R6 Full Resident |    4.1133 ms/s |  0.4113% | +1.8654 ms/s |        +0.1865% |               1.331/s |

## 追加機能ごとの差

- Group: R2→R3 **+0.3001 ms/s**
- Foreground: R3→R4 **+1.3632 ms/s**
- Preview: R4→R5 **+0.1753 ms/s**
- Migration + Assist idle: R5→R6 **+0.0268 ms/s**

Migration + Assistを有効にしただけのR5→R6は、Tabora自身で**1コア+0.00268%**に相当する差しかなく、Interrupt Wakeupも約+0.0085/sである。平常状態で追加監視が大きく積み上がっている形は見られない。

Foregroundは今回CampaignのTabora直接差では最も大きいが、R3→R4でも1コア約+0.136%に留まり、R4以降でさらに同程度の増分が段階的に積み上がる形ではない。

---

# CPU / GPU / ANE / SoC Power

電力値も同一Campaign内の差を中心に解釈する。絶対値を過去Campaignと比較して改善率にはしない。

| Phase            | CPU Power平均 | GPU Power平均 | ANE Power平均 | Combined平均 | GPU active平均 | 中央値 |    p95 |
| ---------------- | ------------: | ------------: | ------------: | -----------: | -------------: | -----: | -----: |
| R2 Core          |     185.47 mW |       0.50 mW |          0 mW |    185.96 mW |         0.189% |     0% |     0% |
| R3 2 Group       |     156.31 mW |       0.16 mW |          0 mW |    156.47 mW |         0.197% |     0% | 0.012% |
| R4 Foreground    |     152.72 mW |       0.07 mW |          0 mW |    152.79 mW |         0.099% |     0% |     0% |
| R5 Preview       |     154.30 mW |       0.15 mW |          0 mW |    154.43 mW |         0.209% |     0% |  0.25% |
| R6 Full Resident |     150.91 mW |       0.07 mW |          0 mW |    150.98 mW |         0.104% |     0% |     0% |

R2から後続PhaseへCombined Powerが低下していることを、Taboraが電力を削減した証拠とは扱わない。System側の背景変動を含むためである。

意味があるのは、機能追加による**持続的な正方向の増加が観測されるか**である。

- R4→R5 Preview: Combined **+1.64 mW**
- R5→R6 Migration + Assist: Combined **−3.45 mW**
- GPU Power中央値: 全Phase **0 mW**
- GPU active中央値: 全Phase **0%**
- ANE Power: 全Phase **0 mW**

したがって今回の平常状態では、PreviewやFull ResidentによってGPU/ANEが継続稼働したり、SoC電力が段階的に増加し続けたりする形は確認されない。

R5のGPU active平均0.209%は少数の短いGPU活動で上がっているが、中央値0%、p95 0.25%であり、常時GPU稼働とは異なる。

---

# Memory / VM

今回のTerminal BenchmarkではTabora自身のPhysical Footprintをv2.0.0と同じ定義では取得していないため、Preview cache 32 MiBやMission Control transient cacheの実RAM増分を世代間比較しない。

WindowServer MemoryはR2〜R6で平均約370〜388 MiBの範囲にあり、R3以降で単調増加していない。WindowServerはTabora以外の画面合成資源も共有するため、この値をTabora専用Memoryとして扱わない。

各Phase内では、

- Pageout増分: **0**
- Swapin増分: **0**
- Swapout増分: **0**

であり、今回の120秒安定計測中にメモリ逼迫を示す挙動は確認されない。

---

# 最新評価

| 評価対象                   | 2026-09-05判断                                                         |
| -------------------------- | ---------------------------------------------------------------------- |
| 比較方式                   | **R2 Core基準差を世代間比較に使用。R0/R1/R2の素の値比較は行わない**    |
| 2 Group WindowServer       | R2差 +0.71 ms/s。v2.0.0の+9.0272から約92.1%縮小                        |
| Foreground WindowServer    | R3→R4で正の増分を検出しない                                            |
| Preview WindowServer       | **R4→R5 +0.76 ms/s / 1コア+0.076%**                                    |
| Preview normalized         | **R2→R5 +1.28 ms/s。v2.0.0の+40.0279から約96.8%縮小**                  |
| Full Resident normalized   | **R2→R6 +0.45 ms/s / 1コア+0.045%。v2.0.0の+36.9711から約98.8%縮小**   |
| WindowServer cross-check   | `top`と`powermetrics`のR2差がほぼ一致                                  |
| Preview p95                | **1.31%**。v2.0.0の約24%級spikeから大幅縮小                            |
| Full Resident p95          | **0.70%**。高い周期的spikeなし                                         |
| Tabora直接 Full Resident   | 4.1133 ms/s、1コア0.4113%。過去とはcollectorが異なるため絶対比較しない |
| Tabora直接 R2→R6増分       | +1.8654 ms/s、1コア+0.1865%                                            |
| Migration + Assist直接増分 | R5→R6 +0.0268 ms/s、1コア+0.00268%                                     |
| GPU                        | R5/R6中央値0%。継続稼働なし                                            |
| ANE                        | 全Phase 0 mW                                                           |
| Combined SoC Power         | 機能追加に伴う持続的・単調な増加なし                                   |
| Pageout / Swap             | 全Phase増分0                                                           |

---

# 結論

2026-09-05の **Tabora Community v2.2.0 public candidate**は、過去の正式検証と同じR0〜R6形式・安定状態で再計測した結果、平常時の常駐コストが非常に安定している。

最も重要なのは絶対値ではなく、**同じCampaign内のR2 Coreを0とした追加コスト**である。

WindowServerでは、

- Core → Preview: **+1.28 ms/s / 1コア+0.128%**
- Core → Full Resident: **+0.45 ms/s / 1コア+0.045%**

に留まった。

v2.0.0の同じR2基準差はそれぞれ+40.0279 ms/s、+36.9711 ms/sであり、基礎値の違いを相殺した比較でも、Preview込み委託増分は約96.8%、Full Resident委託増分は約98.8%縮小している。

Preview固有のR4→R5も、v2.0.0の+30.0662 ms/sから今回+0.76 ms/sへ縮小した。さらにR5 p95は1.31%、R6 p95は0.70%で、以前の約24%級の周期的WindowServer spikeは確認されない。

Tabora自身についても、今回同一collector内ではR5→R6のMigration + Assist追加差が+0.0268 ms/s、1コア+0.00268%であり、Full Resident化によって新たな高頻度常駐処理が積み上がっている証拠はない。

GPU active中央値は全Phase0%、ANE Powerも全Phase0 mW、Pageout/Swapも全Phase0である。

以上から、今回の正式候補コードは、**Preview取得方式の変更によってWindowServerへ委託する平常コストを大幅に縮小しつつ、Group / Foreground / Migration / Assistを含むFull Resident状態でも常駐負荷を小さい範囲に維持している**と評価する。

この結果は「PCやOSの素の負荷が低かったから」という絶対値比較ではなく、**各Campaign自身のCore基準からの差分比較**によって確認したものである。

---

## 今後の再計測ルール

常駐監視方式、Preview更新方式、WindowServerへの継続表示処理を変更した場合は、同じR0〜R6構成で再計測する。

比較時は以下を守る。

1. R0は環境監査に使用し、世代間性能比較に使用しない。
2. R1は6 Window環境監査に使用し、コード改善率の基準に使用しない。
3. **R2 Coreを機能追加前の基準として、R3〜R6との差を比較する。**
4. 世代間比較は同じPhase差・同じcollectorの組み合わせだけで行う。
5. Tabora直接CPUはcollectorが異なるCampaign間で絶対比較しない。
6. WindowServerは同じ`top`定義のPhase差を主要な世代間比較値とする。
7. 平均だけでなく中央値・p95・spike形状を確認する。
8. 負のPhase差は0へ丸めず、背景変動として保持する。
9. System Power / Batteryの負値を「Taboraが省電力化した」と解釈しない。
10. 暫定Campaignを正式再計測で置き換えた場合、旧暫定値は比較系列から完全に除外する。
