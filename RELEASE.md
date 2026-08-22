# Warren Release Process

This document is the required release checklist for Warren. Keep the release
version, changelog, onboarding fallback, app metadata, and archive name in
sync before publishing anything.

## Before the release commit

1. Choose the next semantic version from the latest tag and record the release
   date. Use a patch version for backwards-compatible fixes and small release
   maintenance; use a minor or major version when the product contract
   changes.
2. Move the completed notes from `CHANGELOG.md`'s `Unreleased` section into a
   dated version section. Leave a fresh `Unreleased` placeholder at the top.
3. Add the same release to both English and Simplified Chinese offline
   fallback lists in `Onboarding/src/i18n.jsx`. The onboarding Worker reads
   `CHANGELOG.md` at runtime, but the fallback must remain useful offline.
4. Update `Support/Info.plist`:
   - Set `CFBundleShortVersionString` to the release version.
   - Increment `CFBundleVersion` by one from the previous release.
5. Update the archive version in `scripts/package.sh` so the generated file is
   named `Warren-<version>.zip`.
6. Review the complete diff for business, interaction, performance, fresh
   checkout, and coupling risks. Record any material risk and its mitigation
   in the release description before publishing.

## Local signing

Every local release build must use a stable macOS code-signing identity. An
ad-hoc signature is tied to the current code hash, so macOS will treat each
rebuilt Warren app and daemon as a new client and ask for TCC or incoming
network permissions again.

Install an Apple Development certificate for local testing or a Developer ID
Application certificate for a distributable build. Check the available
identities with:

```sh
security find-identity -v -p codesigning
```

`scripts/build-app.sh` invokes `scripts/sign-app.sh` automatically. The script
prefers Developer ID Application, then Apple Development, and signs every
Mach-O file inside the app before signing the outer bundle. Set
`WARREN_CODESIGN_IDENTITY` to a certificate name or SHA-1 hash when the
automatic choice is not appropriate:

```sh
WARREN_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  bash scripts/build-app.sh release
```

Verify the result before installing it:

```sh
codesign -dvvv Warren.app 2>&1 | egrep 'Identifier=|TeamIdentifier=|Signature='
codesign --verify --deep --strict --verbose=2 Warren.app
spctl --assess --type execute --verbose=4 Warren.app
```

`TeamIdentifier` must be present and `Signature` must not be `adhoc`. A
local Apple Development build may still be rejected by `spctl` because it is
not notarized; a distributable Developer ID build must pass Gatekeeper after
notarization. After switching from an old ad-hoc build, approve the newly
signed app once; do not use `WARREN_ALLOW_ADHOC_SIGNING=1` for a release.

## Checks and packaging

Run the checks relevant to the changed surfaces before creating the release
commit:

```sh
npm --prefix Onboarding test
npm --prefix Onboarding run build
swift test
go test -race ./Headless/...
```

## Commit, push, and publish

1. Create one release-preparation commit after the checks pass. The commit
   subject must use a type prefix, for example:
   `chore: prepare 0.6.1 release`.
2. Create the matching annotated tag locally at the release commit before
   packaging. `scripts/version.sh` embeds the exact tag when one is present, so
   packaging before tagging would put the commit hash in the shipped binaries.
   Do not reuse an existing release tag.
3. Build the release archive from the tagged release commit:

   ```sh
   WARREN_GNAR_DEFAULT_EDGE="https://edge.example.com" bash scripts/package.sh
   ```

   `WARREN_GNAR_DEFAULT_EDGE` is injected into the headless binaries at
   release build time. It is a public, credential-free URL; do not put an
   enrollment key or account token in it. Users who saved a custom Edge in
   Settings keep that override across releases, while users without an
   override follow the newly embedded default.

   Warren can ship the matching gnar worker in
   `Warren.app/Contents/Resources/gnar`. Set `WARREN_GNAR_BINARY` to the
   release gnar binary before running `scripts/build-app.sh`, or place a
   release binary at `../gnar/target/release/gnar` for local packaging. The
   bundled worker uses `~/.warren/gnar` for its credential store; an explicit
   `WARREN_GNAR_PATH` continues to use the system gnar store unless
   `WARREN_GNAR_CONFIG_DIR` is supplied. Existing system credentials are not
   migrated.

   Confirm that `Warren.app/Contents/Info.plist` contains the release version,
   `Warren.app/Contents/MacOS/warren-headless --version` prints the release
   tag, and `Warren-<version>.zip` exists. Do not commit `Warren.app`, zip
   archives, or generated build output.
4. Push the release commit and tag to the intended remote, then create or
   update the pull request when branch policy permits.
5. If an explicitly authorized emergency direct push is required because a
   pull request is blocked by approval policy, use the repository-local
   `.local/force-push-once.sh` helper when it is available. Run its dry run
   first; prefer `--force-with-lease`, use `--allow-direct-push` only for this
   exceptional case, and verify that branch protection is restored afterward.
6. Deploy the onboarding Worker from the same tagged release commit:

   ```sh
   npm --prefix Onboarding run deploy
   ```

   Confirm the Worker serves the new release notes and that its offline
   English and Simplified Chinese fallbacks match `CHANGELOG.md`.
7. Publish a GitHub release with `Warren-<version>.zip` attached and the
   corresponding `CHANGELOG.md` notes.
8. Verify the tag, release asset, download URL, and onboarding release
   response after publishing.

## Rollback

Do not delete or move a published tag silently. If an archive is defective,
mark the GitHub release as a draft or clearly superseded, prepare a new patch
version, and repeat this checklist. Preserve the previous release asset until
the replacement has been verified.
