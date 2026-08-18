# 更新履歴

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
