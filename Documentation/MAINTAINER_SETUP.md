# Maintainerセットアップ

## 新規repository

新しいpublic repositoryを作成します。

```text
Pentagon22GIT/Tabora
```

SnapFlowの `.git` directoryはimportしません。project全体のinitial diffを確認したうえで、このprojectから新しい `main` branchを初期化します。

## Initial Public Baseline後のGit workflow

Initial Public BaselineをGitHubへ公開した後は、`main`を作業branchとして使用しません。1 branch = 1 purpose / 1 PR = 1 purposeを基本とし、branch名は次の分類を使用します。

```text
feature/<内容>
fix/<内容>
docs/<内容>
security/<内容>
```

通常はbranchからPull Requestを作成し、CI / Safety Invariants / diffを確認後にSquash Mergeします。公開済み`main`への直接push、force push、公開済みcommit / tagのrewriteは禁止です。

## Git hygiene

初回commit前は次を確認します。

```zsh
git init -b main
git status --short
git add .
git diff --cached --check
git diff --cached
```

`.build/`、生成済み `.app` bundle、release archive、private key、token、local machine metadataが含まれていないことを確認します。

## Tabora Official code-signing identity

Tabora専用の自己署名Code Signing identityはInitial Public Baseline前に作成済みです。SnapFlow certificate / private keyは再利用しません。現在の公開fingerprintは `B931AC85747B9B12E32751D3776AAFD3430E5A12` です。

将来certificateをrotationする場合は、新しいpublic fingerprintを次で確認します。

```zsh
security find-identity -v -p codesigning
```

40-character SHA-1 certificate fingerprintは次へ設定します（現在は設定済みです）。

```text
Config/OfficialSigning.plist
```

SHA-1はcode-signing designated requirement内でcertificate identifierとしてのみ使用します。Release archiveのintegrity確認にはSHA-256を使用します。

private keyはMaintainerの保護されたKeychain / backupにのみ保持し、commitやGitHub Secretsへの追加を絶対に行いません。

設定後は次を検証します。

```zsh
./Scripts/build-official.sh
./Scripts/verify-official.sh
./Scripts/show-identity.sh
```

期待するOfficial Bundle ID:

```text
dev.pent.Tabora
```

## GitHub設定

推奨baseline:

- default branch: `main`
- protected `main`ではPull Requestを必須化
- force pushとbranch deletionを禁止
- 可能な範囲でsigned commit / signed tagを要求
- Private Vulnerability Reportingを有効化
- Dependabot alerts / security updatesを有効化
- 利用可能な場合はPush protection / secret scanningを有効化
- GitHub Actions permissionを最小化

projectは次の3層workflowを持ちます。

1. `ci.yml` — 高速compile / test / Community build検証
2. `safety-invariants.yml` — Tabora固有のsafety regression testとmigration identity guard
3. `codeql.yml` — 深いstatic security analysis

Pull Request workflowではOfficial signing secretを使用しません。
