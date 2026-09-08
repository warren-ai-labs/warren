# Warren Release Process

This document is the required release checklist for Warren. Keep the release
version, changelog, onboarding fallback, app metadata, and archive name in
sync before publishing anything.

## Before the release commit

1. Choose the next semantic version from the latest tag and record the release
   date. Use a patch version for backwards-compatible fixes and small release
   maintenance; use a minor or major version when the product contract
   changes. The private repository is the only release source; the public
   repository is a filtered mirror updated by GitHub Actions.
2. Move the completed notes from `CHANGELOG.md`'s `Unreleased` section into a
   dated version section. Leave a fresh `Unreleased` placeholder at the top.
3. Add the same release to both English and Simplified Chinese offline
   fallback lists in `Onboarding/src/i18n.jsx`. The onboarding Worker reads
   `CHANGELOG.md` at runtime, but the fallback must remain useful offline.
4. Update `Support/Info.plist`:
   - Set `CFBundleShortVersionString` to the release version.
   - Increment `CFBundleVersion` by one from the previous release.
5. Do not edit a version literal in `scripts/package.sh`. The release package
   derives its archive name from the exact tag and refuses a dirty or untagged
   checkout.
6. Review the complete diff for business, interaction, performance, fresh
   checkout, and coupling risks. Record any material risk and its mitigation
   in the release description before publishing.
7. Confirm that the private `origin` and filtered `public` remotes are the
   intended repositories. Never push the unfiltered checkout directly to
   `public`.

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

`TeamIdentifier` must be present and `Signature` must not be `adhoc`. An
Apple Development build is suitable for internal testing only and may be
rejected by `spctl` because it is not notarized. A distributable build must
use Developer ID Application, be notarized, and pass Gatekeeper:

```sh
xcrun notarytool submit "Warren-<version>.zip" \
  --keychain-profile "$WARREN_NOTARY_PROFILE" --wait
xcrun stapler staple Warren.app
xcrun stapler validate Warren.app
spctl --assess --type execute --verbose=4 Warren.app
```

Staple before producing the final download archive. If the archive was
submitted for notarization before stapling, recreate `Warren-<version>.zip`
from the stapled app and regenerate its `.sha256` file before publishing:

```sh
ditto -c -k --keepParent Warren.app "Warren-<version>.zip"
shasum -a 256 "Warren-<version>.zip" > "Warren-<version>.zip.sha256"
```

After switching from an old ad-hoc build, approve the newly signed app once;
do not use `WARREN_ALLOW_ADHOC_SIGNING=1` for a release.

## Checks and packaging

Run the checks relevant to the changed surfaces before creating the release
commit:

```sh
bash scripts/verify.sh
npm --prefix Onboarding test
npm --prefix Onboarding run build
git diff --check
```

The release gate must include the Relay service, Web checks, Headless race
tests, Swift package tests, and the non-visual UI probes covered by
`scripts/verify.sh`; do not replace it with a single package-local test.

## Commit, push, and publish

1. Create one release-preparation commit after the checks pass. The commit
   subject must use a type prefix, for example:
   `chore: prepare 0.6.1 release`.
2. Create the matching annotated tag locally at the release commit before
   packaging. `scripts/version.sh` embeds the exact tag when one is present, so
   packaging before tagging would put the commit hash in the shipped binaries.
   Do not reuse an existing release tag:

   ```sh
   release_tag=v<major>.<minor>.<patch>
   git tag -a "$release_tag" -m "Warren ${release_tag#v}"
   ```

3. Build the release archive from the tagged release commit:

   ```sh
   bash scripts/package.sh
   ```

   `scripts/package.sh` is a release-only entry point: it verifies the exact
   tag, clean checkout, and app version; invokes `scripts/build-app.sh release`;
   stamps `build-variant.txt` as `release`; and writes a SHA-256 file beside
   the archive. `mise run build` and `mise run dev` intentionally produce
   debug artifacts and stamp the marker as `build`; they are not release
   commands.

   The package task produces an arm64 macOS archive for macOS 13 and later and
   must run on an arm64 Apple Silicon Mac. Ghostline v1 statically links its
   terminal core; the app has no v0 bridge, migration binary, or separate
   Ghostty checkout to package.

   This release is a coordinated protocol boundary with selective persistence
   migration. Pre-4.0 clients are rejected during authentication. Host state
   schemas 1 and 2 migrate in place to schema 3; unknown or future schemas
   still fail closed. Compatible Ghostline v1 sessions use the rolling handoff
   path, but old Ghostline v0 sockets, legacy PTY aliases, and pre-canonical
   Agent projections are not migrated and require recreation or a fresh cache.
   Back up `~/.warren` before upgrading an existing Host.

   Public Access is provided by the independently deployed Relay. Confirm that
   the release contains the headless Relay connector and that no external
   worker or credential directory is packaged into `Warren.app`.

   Confirm that `Warren.app/Contents/Info.plist` contains the release version,
   `Warren.app/Contents/Resources/build-variant.txt` contains `release`,
   `Warren.app/Contents/MacOS/warren-headless --version` prints the release
   tag, `Warren-<version>.zip` and `Warren-<version>.zip.sha256` exist, and the
   independently deployed Relay accepts the release protocol. Do not commit
   `Warren.app`, archives, or generated build output.
4. Push the release commit and annotated tag to the private `origin` only, then
   create or update the pull request when branch policy permits. For a direct
   release from `main`:

   ```sh
   git push origin main "$release_tag"
   ```

5. Wait for `sync-oss` to complete. It serializes public updates, excludes
   proprietary paths, and creates an immutable tag on the filtered public
   commit. Verify both refs before creating the GitHub Release:

   ```sh
   git ls-remote public "refs/heads/main" "refs/tags/$release_tag"
   ```

   The public tag intentionally points to a different mirror commit from the
   private tag. Do not push the private commit or tag directly to `public`.
6. Publish the GitHub Release in `warren-ai-labs/warren` with both
   `Warren-<version>.zip` and `Warren-<version>.zip.sha256` attached, plus the
   corresponding `CHANGELOG.md` notes and any signing caveat.
7. Deploy the onboarding Worker from the same tagged release commit:

   ```sh
   npm --prefix Onboarding run deploy
   ```

   Confirm the Worker serves the new release notes and that its offline
   English and Simplified Chinese fallbacks match `CHANGELOG.md`.
   Deploy after the public GitHub Release exists; the Worker resolves
   `releases/latest` and may serve a cached response for several minutes.
   Confirm that the Worker serves the new release tag, archive URL, and release
   notes after its cache refreshes; verify the checksum asset directly on the
   GitHub Release page.

## Rollback

Do not delete or move a published tag silently. If an archive is defective,
mark the GitHub release as a draft or clearly superseded, prepare a new patch
version, and repeat this checklist. Preserve the previous release asset until
the replacement has been verified. Do not repair or prune historical refs or
objects as part of a release; a release is based on the new exact tag, and
known damaged legacy data remains outside the migration scope.
