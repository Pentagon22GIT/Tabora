# 由来とProvenance

Tabora v1.0.0は、最終検証済みSnapFlow codebaseから派生した新しいproject lineageです。

## Source baseline

- Historical project: SnapFlow
- Final SnapFlow version: 1.3.0
- Historical repository: `Pentagon22GIT/SnapFlow`
- 提供projectに含まれていたhistorical source commit: `005af4b15fc256627e55f4346b05b91f1ae5a93d`
- Final baseline archive SHA-256: `049ab054992cc2aea6737300f538205d4c897d71255448b97417b9d870ecfc23`
- Tabora migration date: 2026-08-18

Final SnapFlow archiveには、上記historical commitより後の検証済みworking-tree changesが含まれています。そのため、このcommit単体ではfinal behavioral baselineを定義できません。archive hashが、移行に使用した正確なbaselineを識別します。

## Lineage rule

TaboraはSnapFlow Git repositoryのrenameでもmirrorでもありません。旧 `.git` directoryとrelease artifactは意図的に除外しています。Taboraは新しいGit historyと新しいproduct identityから開始します。

## Behavior freeze

移行phaseはidentity / presentation / documentation / repository hygieneだけを対象としました。新しいproduct identityまたはbuild artifact名のために厳密に必要な変更を除き、Snap / Group / Resize / Recovery / AX / Mission Control behaviorはSnapFlow Final Baselineと同等であることを要求しました。

historical SnapFlow release noteはTaboraのactive documentationへ複製せず、historical SnapFlow project側に残します。
