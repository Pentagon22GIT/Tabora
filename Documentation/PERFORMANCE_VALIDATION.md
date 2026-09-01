# 常駐負荷・性能検証記録

この文書は、Taboraの平常時常駐コストを実測し、アプリ自身の直接負荷だけでなく、WindowServerへ委託される表示処理、システム全体、メモリ、Wakeup、Battery、Thermalまで含めて検証した記録です。

バージョンごとに別ファイルを増やさず、今後の再計測もこの文書へ測定日・対象バージョン・条件を追記します。

## 最新の検証

- 計測日: **2026-09-01**
- 対象: **Tabora v2.0.0 (Build 14)**
- Source Revision: `d41b500a2b9f3e94cb067eb517b7dba52e7b526a`
- macOS: **26.6.2 (25G83)**
- CPU: **10コア**
- 電源: **Battery Power / Low Power Mode OFF**
- Thermal: 全観測で `nominal`
- 計測時間: 各Phase **120秒**
- 解析: 開始直後の安定化区間を除外し、平常状態だけを比較
- Window構成: Chrome 3枚 + Finder 3枚の同一6ウィンドウ
- Group構成: 3分割Group × 2組
- Phase間では指定設定だけを変更し、Group構成、上下関係、ウィンドウ構成を維持

### 検証Phase

| Phase | 条件 | 主目的 |
| --- | --- | --- |
| R0 | Machine Baseline | OSと観測環境の基礎値 |
| R1 | 6 Window / Tabora OFF | 同一6ウィンドウ環境の基準 |
| R2 | Tabora Core / Groupなし | Tabora基本常駐 |
| R3 | 2 Group維持 | Group保持コスト |
| R4 | Foreground ON | 最前面連動の常駐増分 |
| R5 | Preview ON | Previewを含む平常コスト |
| R6 | Migration + Assist ON | Full Resident |

全7 Phaseは有効な計測として完了し、R1〜R6では同じ6 Window IDが計測前後で維持されました。

## 最終CPU評価

CPU timeは `ms/s`（1秒あたりに消費したCPU時間）で統一します。`10 ms/s = 1コアの1%`です。10コア全体に対する比率は1コア換算値の1/10です。

### Tabora自身の直接負荷

| Phase | CPU ms/s | 1コア換算 | 10コア全体換算 | Wakeup /s |
| --- | ---: | ---: | ---: | ---: |
| R2 Core | 0.0587 | 0.00587% | 0.000587% | 1.970 |
| R3 2 Group | 0.0653 | 0.00653% | 0.000653% | 2.180 |
| R4 Foreground | 0.1084 | 0.01084% | 0.001084% | 2.230 |
| R5 Preview | 0.1310 | 0.01310% | 0.001310% | 2.450 |
| R6 Full Resident | **0.1343** | **0.01343%** | **0.001343%** | **2.460** |

Taboraプロセス自身のFull Resident CPUは **0.1343 ms/s**、1コアの **0.01343%** に留まりました。Migration + Assistまで有効にしてもR5とR6の直接CPUはほぼ同値で、待機中に新しい高頻度pollingを追加していない設計と整合します。

### WindowServer負荷

WindowServerは同じ6ウィンドウだけを置いたR1を基準とし、各Phaseとの差をTaboraによる委託増分として評価します。

| Phase | WindowServer CPU ms/s | 1コアCPU | R1比の委託増分 |
| --- | ---: | ---: | ---: |
| R0 Machine Baseline | 7.1569 | 0.7157% | — |
| R1 6 Window / Tabora OFF | **5.7547** | **0.5755%** | 基準 |
| R2 Core | 7.0476 | 0.7048% | +1.2929 ms/s |
| R3 2 Group | 16.0748 | 1.6075% | +10.3201 ms/s |
| R4 Foreground | 17.0093 | 1.7009% | +11.2546 ms/s |
| R5 Preview | 47.0755 | 4.7075% | +41.3208 ms/s |
| R6 Full Resident | **44.0187** | **4.4019%** | **+38.2640 ms/s** |

R5/R6では中央値に対して短いCPUピークが現れ、Preview更新を含む表示処理が連続した一定負荷ではなく、周期的なWindowServer処理として現れることを確認しました。R5のWindowServer CPU中央値は約1.3%、95 percentileは約24%、R6は中央値約0.6%、95 percentile約24%でした。

### Tabora + WindowServerの総合常駐コスト

`総合負荷 = Tabora直接CPU + (WindowServer各Phase - WindowServer R1)` とします。

| Phase | Tabora直接 | WindowServer委託増分 | 総合 ms/s | 1コア換算 | 10コア全体換算 |
| --- | ---: | ---: | ---: | ---: | ---: |
| R2 Core | 0.0587 | 1.2929 | **1.3516** | **0.1352%** | **0.0135%** |
| R3 2 Group | 0.0653 | 10.3201 | **10.3853** | **1.0385%** | **0.1039%** |
| R4 Foreground | 0.1084 | 11.2546 | **11.3630** | **1.1363%** | **0.1136%** |
| R5 Preview | 0.1310 | 41.3208 | **41.4518** | **4.1452%** | **0.4145%** |
| R6 Full Resident | 0.1343 | 38.2640 | **38.3983** | **3.8398%** | **0.3840%** |

通常のFull Resident状態では、Taboraがシステムへ発生させるCPU workは **約38.4 ms/s**、すなわち **1コアの約3.84% / 10コア全体の約0.384%** です。

R5/R6を合わせると、Previewを含む通常常駐状態は **約38.4〜41.5 ms/s**、1コア換算 **約3.84〜4.15%**、10コア全体では **約0.384〜0.415%** の範囲に収まります。

R6では総合CPUの約 **99.65%** がWindowServer側の委託増分で、Taboraプロセス自身は約 **0.35%** です。このため、Tabora自身のCPUだけを見ると極端に小さく、実際の平常コストは主にmacOSへ委託した表示処理として現れます。

## 機能別の増分

R2〜R5の連続した構成差から、常駐CPU増分を分解すると次の通りです。

| 追加条件 | 総合CPU増分 | 1コア換算 | 10コア全体換算 | 評価 |
| --- | ---: | ---: | ---: | --- |
| Tabora Core: R1→R2 | +1.3516 ms/s | +0.1352% | +0.0135% | 非常に小さい |
| 2 Group維持: R2→R3 | +9.0337 ms/s | +0.9034% | +0.0903% | 小さい固定コスト |
| Foreground: R3→R4 | **+0.9777 ms/s** | **+0.0978%** | **+0.0098%** | 極めて小さい |
| Preview: R4→R5 | **+30.0888 ms/s** | **+3.0089%** | **+0.3009%** | 最大の常駐増分 |

ForegroundはTabora側の監視経路を含めても10コア全体の約 **0.0098%** の追加に留まります。独立10 Hz pollingを廃止し、event-driven + 1 Hz Recovery fallbackへ移した設計の効果と整合します。

最大の増分はPreviewです。ただしWindowServerの中央値と上位percentileの差から、常時CPUを占有する形ではなく、画像更新・compositor処理時の短い山として平均値へ反映されています。

## Memory

### Tabora Physical Footprint

| Phase | 平均 | 最大 |
| --- | ---: | ---: |
| R2 Core | 48.3 MiB | 48.3 MiB |
| R3 2 Group | 146.2 MiB | 146.2 MiB |
| R4 Foreground | 141.8 MiB | 141.8 MiB |
| R5 Preview | 199.9 MiB | 242.3 MiB |
| R6 Full Resident | **203.5 MiB** | **247.8 MiB** |

Preview有効時は画像cacheによりメモリが増えますが、更新ピーク後に低下し、計測中に単調増加するリーク形状は確認されませんでした。R5/R6の最大値も設定されたbounded cacheを含む一時的な増加として収まっています。

WindowServerの観測メモリ平均はR1約409.7 MiB、R5約495.5 MiB、R6約458.5 MiBでした。ただしWindowServerはTabora以外の画面合成も共有するため、この絶対差をTabora専用メモリとしては扱いません。

## System / Battery / Thermal

### System CPU

| Phase | System CPU平均 |
| --- | ---: |
| R0 | 1.974% |
| R1 | 2.277% |
| R2 | 1.958% |
| R3 | 2.219% |
| R4 | 2.170% |
| R5 | 2.566% |
| R6 | 2.833% |

System CPUは他のmacOS processを含むため、機能差の直接値には使用しません。重要なのは、Tabora自身とWindowServerを分離した値で常駐コストを説明でき、System全体にも異常な持続上昇が現れていないことです。

### Battery

Battery sensorは更新が段階的なため、短いPhase間の平均差より中央値を重視します。

| Phase | 放電平均 | 放電中央値 |
| --- | ---: | ---: |
| R0 | 2.905 W | 2.477 W |
| R1 | 2.392 W | 2.378 W |
| R2 | 2.710 W | 2.937 W |
| R3 | 2.538 W | 2.643 W |
| R4 | 2.484 W | 2.411 W |
| R5 | 2.477 W | 2.349 W |
| R6 | 3.826 W | **2.470 W** |

R1〜R6の中央値は **約2.35〜2.94 W** の範囲で、機能追加に合わせた単調増加はありません。Full Resident R6の中央値は2.470 Wで、6 Window baseline R1の2.378 Wとの差は約 **+0.092 W** です。この差は短時間Battery sensorの粒度と背景変動の範囲を含むため、特定機能の消費電力として直接帰属しません。

Battery残量は各Phase内で安定し、Low Power ModeはOFFでした。温度は約30.24℃から30.12℃の範囲で推移し、全サンプルでthermal stateは`nominal`、page-outは0でした。

## 総合判定

- **Tabora直接CPU:** Full Residentで1コア0.01343%。極めて小さい。
- **WindowServer委託CPU:** Full ResidentのR1基準増分は1コア3.8264%。総合負荷の大部分を占める。
- **総合CPU:** Full Residentで1コア約3.84%、10コア全体約0.384%。通常常駐アプリとしてシステム処理を強制的に低下させる水準ではない。
- **Foreground:** 追加コストは10コア全体約0.0098%。最適化後の常駐監視は十分低コスト。
- **Preview:** 最大のCPU増分。主にWindowServer側の周期的な短時間処理として現れる。
- **Migration + Assist idle:** Tabora直接CPU・WakeupともPreview状態から実質的な増加を示さず、休眠設計を支持する。
- **Memory:** Full Resident平均約203.5 MiB、最大約247.8 MiB。リーク形状なし。
- **Battery / Thermal:** Battery中央値に単調な悪化なし。thermalは全観測nominal、page-out 0。

したがって、**Taboraは平常状態で十分低い常駐CPUコストを維持しており、アプリ自身の処理は極めて小さい。表示系の主要コストはWindowServerへ委託されるPreview関連処理だが、それを含めても10コア全体の通常負荷は約0.4%前後に収まる**、というのが2026-09-01時点の最終実測結果です。

## 最終監査チェック

計測時点の対象バージョンに対して、次を完了済みとします。

- [x] R0〜R6の全Phaseを同一基準で完了
- [x] 6 Windowのidentityと構成をPhase前後で確認
- [x] 3分割Group × 2組の安定状態を維持
- [x] Tabora直接CPU / Wakeup / Memoryを確認
- [x] WindowServer CPU / Memoryを確認
- [x] Tabora + WindowServerの総合CPUを1コア・10コア換算で検証
- [x] Group / Foreground / Preview / Full Residentの差分を比較
- [x] System CPUを比較し、異常な持続負荷がないことを確認
- [x] Battery放電、温度、Low Power Mode、Thermal stateを確認
- [x] page-out 0とメモリの非単調増加を確認
- [x] Migration + Assist有効時に新しいidle polling増加がないことを確認
- [x] Foreground監視の低頻度fallback設計と実測値の整合を確認
- [x] 既存Architecture / Security Invariants / Foreground / Migration文書との整合を確認
- [x] 設定画面の2 / 3 / 4分割Assist表記を現在仕様へ統一
- [x] README / CHANGELOG / Privacy / Third-party notice / Version / Build Numberのv2.0.1整合を確認

この記録は性能の最新確認点です。今後、常駐監視方式、Preview更新方式、WindowServerへの継続的な表示処理を変更した場合は、同じPhase構成で再計測し、この文書へ新しい検証記録を追記します。
