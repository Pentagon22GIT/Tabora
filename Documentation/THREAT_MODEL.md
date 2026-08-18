# Threat Model

## 保護対象Asset

- window / workspace stateに対するユーザーのcontrol
- Accessibility / Screen Capture permission境界
- AX windowとWindow Server surfaceの正しい対応付け
- group membershipとshared-resize authorization
- placement / replacement authorizationのstate integrity
- Release identityとOfficial signing trust
- public repository integrity

## Trust boundary

### macOS Accessibility / Window Server

TaboraはAXとWindow Serverからstateを取得しますが、そのstateはdelay、一時的unavailable、incomplete、transition中の変化を含み得ます。temporary AX failureまたはpartial discovery resultを、window disappearanceの証明として扱いません。

### その他のGUI application

他applicationはslow / buggyである可能性があり、大量のwindow作成、surfaceの高速create / destroy、duplicate title、modal sheet表示、move / resizeの一時拒否などを行うことがあります。Taboraはgroup stateを破壊せずfail closedできなければなりません。

### User interaction

pointer-down evidence、native-resize edge、Tabora-owned shared boundary、Mission Control selection、application switchingは時間的に重なる可能性があります。authorizationはfreshなphysical identityと正しいinteraction ownerへ束縛します。

### Build / release supply chain

public repository、GitHub Actions dependency、release tag、hash、code signing certificate、Maintainer environmentは、runtime window managementとは別のtrust boundaryを構成します。

## Threatとmitigation

### 悪意または故障したGUI application

脅威:
- misleading title
- reused / ambiguous Window ID
- AX stallまたは `cannotComplete`
- move / resizeのtemporary inability
- unexpected modal surface

対策:
- physical ownershipが重要な場面ではPID + CGWindowID identityを使用
- AX unknownとconfirmed missingを分離
- optional discovery failureからstructural destructionへ進まない
- exact targetはfail closed

### 大量window / resource exhaustion

脅威:
- broad discoveryによる過剰work
- preview captureのmemory pressure
- irrelevant Window Server churnによるRecovery反復

対策:
- optional discoveryにはbudgetを設定可能だがcorrectness-critical targetにはそのhard capを流用しない
- relevant-scene Recovery
- bounded / disposable preview cache
- group / descriptor単位のrecovery debt

### Identity ambiguity

脅威:
- same-title window
- detached browser tab / window
- hiddenまたは以前存在したsame-PID surfaceの再出現

対策:
- detached adoptionにはcomplete Window Server censusを要求
- title / geometryだけをidentityとして十分とは扱わない
- committed mutation前にphysical evidenceをexact AX targetへ解決する

### Multi-member replacementの誤認可

脅威:
複数member conflictを単なるlogical overlapだけでreplacement可能と判断すると、非一直線layoutの一部を破壊したり、blocked placementをextensionとして既存groupへ誤吸収する可能性があります。またplanning時には正しかったgeometryがcommitまでに変化する可能性があります。

対策:
- multi-member conflictに限り、displaced / retained partition間のcross-partition boundaryが同一axis・同一coordinate・continuous spanであることを要求
- internal boundaryをauthorization evidenceへ流用しない
- blocked multi-member conflictは同一groupに対するextensionもhard veto
- commit直前に対象group revision / member集合 / AX current frameだけを局所再検証
- 再検証失敗やmutation後のfailureをnew-group fallbackへ変換しない
- single-member replacementにはこの追加geometry gateを適用しない

### Cursor / input ownership confusion

脅威:
transient observation failureでTabora shared-resize surfaceが消え、その下のmacOS native resize edgeが露出すると、意図しないgroup departureが起きる可能性があります。

対策:
physical participantがまだ存在する場合のshort quarantineは、最後にvalidatedされたTabora-owned regionだけへ限定します。confirmed occlusionまたはstructural destructionではregionを解放します。

### Mission Control stale evidence

脅威:
あるgroupのtransition evidenceが、別groupまたは後のstale proxy interactionを認可する可能性があります。

対策:
transition evidenceをgroup identity / generationへscopeし、expireまたはconsumeします。

### Signing-key compromise

脅威:
攻撃者がTabora Official private keyを取得すると、configured designated requirementを満たすbinaryを作成できる可能性があります。

対策:
- private keyをrepositoryまたはGitHub Actionsへ保存しない
- certificate fingerprintは公開configurationだけに使用
- compromise時は新しいTabora certificateへrotationし、明示的なuser trust reset手順を案内
- SnapFlow certificateをTaboraへ再利用しない

## Scope外

- macOS自体の脆弱性
- このsourceからdivergeした第三者fork
- すでにユーザーaccountまたはmachineを完全controlしているattacker

Scope外の条件でも、Tabora自身のtrust boundaryに実用的な弱点を示す場合は調査対象になることがあります。
