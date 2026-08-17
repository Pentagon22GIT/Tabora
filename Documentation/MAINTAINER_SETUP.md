# Maintainer Setup

## New repository

Create a new public repository:

```text
Pentagon22GIT/Tabora
```

Do not import the SnapFlow `.git` directory. Initialize a new `main` branch from this project after reviewing the complete initial diff.

## Git workflow after Initial Public Baseline

初回Public BaselineをGitHubへ公開した後は、`main`を作業branchとして使用しません。1 branch = 1 purpose / 1 PR = 1 purposeを基本とし、branch名は次の分類を使用します。

```text
feature/<内容>
fix/<内容>
docs/<内容>
security/<内容>
```

通常はbranchからPull Requestを作成し、CI / Safety Invariants / diffを確認後にSquash Mergeします。公開済み`main`への直接push、force push、公開済みcommit/tagのrewriteは禁止です。

## Git hygiene

Before the first commit:

```zsh
git init -b main
git status --short
git add .
git diff --cached --check
git diff --cached
```

Confirm that `.build/`, generated `.app` bundles, release archives, private keys, tokens, and local machine metadata are absent.

## Tabora Official code-signing identity

Tabora専用の自己署名Code Signing identityは初回Public Baseline前に作成済みです。SnapFlow certificate/private keyは再利用しません。現在の公開fingerprintは `B931AC85747B9B12E32751D3776AAFD3430E5A12` です。

証明書を将来ローテーションする場合は、新しいpublic fingerprintを次で確認します:

```zsh
security find-identity -v -p codesigning
```

40-character SHA-1 certificate fingerprintは次に設定します（現在は設定済み）:

```text
Config/OfficialSigning.plist
```

The SHA-1 is used only as the certificate identifier inside the code-signing designated requirement. Release archive integrity uses SHA-256.

The private key must remain in the Maintainer's protected Keychain / backup and must never be committed or added to GitHub Secrets.

Verify after configuration:

```zsh
./Scripts/build-official.sh
./Scripts/verify-official.sh
./Scripts/show-identity.sh
```

Expected Official Bundle ID:

```text
dev.pent.Tabora
```

## GitHub settings

Recommended baseline:

- default branch: `main`
- Pull Requests required for protected `main`
- force push and branch deletion disabled
- signed commits/tags where practical
- Private Vulnerability Reporting enabled
- Dependabot alerts / security updates enabled
- Push protection / secret scanning enabled when available
- GitHub Actions permissions minimized

The project contains three workflow layers:

1. `ci.yml` — fast compile/test/Community build verification
2. `safety-invariants.yml` — focused Tabora safety regression tests and migration identity guard
3. `codeql.yml` — deep static security analysis

Official signing secrets are not used by pull-request workflows.
