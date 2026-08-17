# Release Process

This process preserves the separation between source, Community builds, and Tabora Official builds.

## 1. Preconditions

- Work from the public `Pentagon22GIT/Tabora` repository.
- Working tree must be clean.
- `VERSION` must match the intended signed tag (`v<version>`).
- `BUILD_NUMBER` must contain the intended build number.
- No private keys, tokens, credentials, or generated app bundles may be tracked.
- `Config/OfficialSigning.plist` must contain `dev.pent.Tabora` and the fingerprint of a Tabora-specific code-signing certificate.

## 2. Validation

On macOS:

```zsh
zsh -n Scripts/*.sh
swift test
./Scripts/build-community.sh
```

Then run the same functional suite used for the SnapFlow Final Baseline, including at least:

- 2 / 3 / 4 split
- linked/shared resize
- legitimate native-resize departure
- active and inactive replacement snap
- shared-boundary cursor / input ownership
- temporary AX failure behavior
- relevant external occluder arrival/removal
- Recovery
- Mission Control
- Mission Control group proxyが候補集合から欠落しないこと（2 / 3 / 4、snap直後、rapid enter/exit）
- cold launch直後の最初のdragでsnap guideを失わないこと
- previewが低解像度のまま拡大表示されないこと
- Preview
- settings and shortcuts

Expected result: behavior matches the frozen baseline except for Tabora identity / labels / bundle domains.

## 3. Security checks

- Fast CI successful
- Tabora Safety Invariants successful
- latest `main` CodeQL analysis successful before Official release
- dependency / secret alerts reviewed
- release diff contains no private data or generated local artifacts

## 4. Tag

Create a signed annotated tag for the exact clean commit:

```zsh
git tag -s v1.0.0 -m "Tabora v1.0.0"
git verify-tag v1.0.0
```

Do not move or recreate a published release tag.

## 5. Official package

```zsh
./Scripts/package-release.sh
```

The script verifies the signed tag, clean source state, Official identity, source revision, Universal 2 architecture, designated requirement, and produces release assets under `release/v<version>/`.

## 6. Release publication

Publish the generated archive, SHA-256 file, and `release-manifest.json` from the same verified run. Release notes must state any permission or signing-identity change.

## 7. Signing identity changes

If the Tabora Official certificate changes, do not silently preserve the old trust assumption. Publish old/new certificate fingerprints and explain any required TCC reset / re-authorization.
