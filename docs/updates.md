# Releases and in-app updates

UsageBar 1.3.0 introduces Sparkle 2.10.0. Users on 1.2.x must install the DMG once; future versions can be downloaded, verified, installed, and relaunched through Sparkle's standard dialog. Settings and usage data live outside the app bundle and are preserved. We currently ship full app ZIPs, not binary delta patches.

The app checks this feed once a day when automatic checks are enabled:

`https://github.com/kubilayege/UsageBar/releases/latest/download/appcast.xml`

The feed is a release asset, independent of GitHub's REST API rate limit. Automatic checks show an update chip in the popup; clicking it or **Settings → Updates → Check for Updates…** opens Sparkle. The legacy automatic-check preference is migrated once. Sparkle never starts for unbundled development runs, tests, or offscreen renders.

## Signing

- The Ed25519 public key is tracked in `scripts/sparkle-public-key.txt` and embedded as `SUPublicEDKey` in the app.
- The corresponding private key is stored in the repository Actions secret **SPARKLE_PRIVATE_KEY**. A backup is in the maintainer's login Keychain under the Sparkle account `com.kubilay.usagebar.sparkle`.
- `generate_appcast` receives the secret through stdin and signs both the ZIP and the feed. No private key is included in build artifacts or release assets.
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require an authenticated feed and archive verification before extraction.
- The outer app is currently ad-hoc signed, without Developer ID or notarization. Sparkle's nested framework and helper signatures are preserved. Ed25519 update signing is separate from Apple code signing; it does not remove first-install Gatekeeper requirements.

Keep the private key across releases. Do not generate a replacement casually: already-installed apps trust the current public key. Follow [Sparkle's key rotation guidance](https://sparkle-project.org/documentation/) if rotation becomes necessary.

## Publishing

1. Bump the default version in `scripts/build-app.sh` and commit the change. Both `CFBundleVersion` and `CFBundleShortVersionString` use this version.
2. Run **Build** on the intended commit with a version greater than the latest release, release notes, and **publish** enabled. Existing release tags cannot be overwritten.
3. The workflow runs regression tests, builds the app and DMG, packages a signed ZIP, and generates a signed appcast. It verifies the archive with the tracked public key.
4. On the GitHub runner only, `scripts/test-update.py` builds Sparkle's own CLI and updates a temporary older copy of the app. It checks feed and archive tamper rejection, successful replacement, the installed version and code signature, and the subsequent no-update result. It never installs in `/Applications` and refuses to run outside GitHub Actions.
5. The workflow uploads the artifacts, creates a draft with every release asset, then publishes it as latest. Publication happens only after all checks pass.

The release includes the DMG, its SHA-256 file, the Sparkle ZIP, and `appcast.xml`. An artifact-only run does not update the public feed. Do not edit an appcast after signing or overwrite an archive: either invalidates its signature.

Use GitHub Actions for app and DMG builds. Local `swift build`, `make test`, and offscreen previews are allowed; never install or replace UsageBar on the development machine.
