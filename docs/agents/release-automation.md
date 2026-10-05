# Release automation

`.github/workflows/release.yml` publishes versioned DMGs for Apple Silicon
(`arm64`) and Intel (`x86_64`, also called AMD64), both requiring macOS 13.0 or
later. A normal release builds from `main`: `macos-26` tests and packages arm64
natively, and `macos-26-intel` tests and packages x86_64 natively. Each job checks
the packaged app's resource loading from a temporary location, the binary
architecture, DMG and checksum. Signing and notarization run separately for each
architecture. Only after both jobs succeed does the workflow upload all assets to
one draft GitHub Release and publish it.

## Run a release

1. Prepare version references and draft changelogs from Conventional Commits:
   ```bash
   python3 scripts/prepare_release.py <version>
   ```
   Or invoke the `.agents/skills/release/SKILL.md` skill with prompt: `帮我发版 vX.Y.Z`.
   The script updates both architectures' current download links, checksum
   commands, filenames and visible release labels. It preserves historical
   README summaries. Review the diff, translate the Chinese changelog's commit
   subjects, and write the new English and Chinese README summaries yourself;
   the script does not translate subjects or generate What's New sections.

2. Validate the prepared release, then commit and push it:
   ```bash
   task ci
   task release-check
   git commit -am "chore: prepare v<version> release"
   git push origin main
   ```

3. Dispatch the GitHub Actions release workflow:
   ```bash
   gh workflow run release.yml --ref main -f version=<version> -f prerelease=false -f backfill_arch=none
   ```

`backfill_arch=none` is the default and releases both architectures. This mode
rejects invalid versions and versions whose tag or Release already exists.
Stable releases require a plain `major.minor.patch` version; a version with a
suffix must use `prerelease=true`.

4. Monitor the run and verify the published Release has both DMGs, matching
   SHA-256 files, and both architecture feeds when Sparkle is enabled. Fetch the
   new tag locally after publication.

## Add a missing architecture to an existing release

Use `backfill_arch=x86_64` or `backfill_arch=arm64` only for the latest published
stable release. For example, to add Intel to v0.8.2:

```bash
gh workflow run release.yml --ref main -f version=0.8.2 -f prerelease=false -f backfill_arch=x86_64
```

This mode resolves the existing tag to its commit SHA and builds the application
from that exact source. It overlays only the workflow's newer packaging tooling
so the missing architecture can be built; application source, resources and
version metadata remain those of the tag. Run it from the updated `main`
workflow without preparing a new version or moving the tag.

The workflow rejects drafts, prereleases, releases other than the latest stable
release, and any requested architecture whose assets already exist. It natively
tests, packages, signs and notarizes the missing architecture before adding its
DMG, checksum and eligible Sparkle feed. Existing assets remain intact and the
tag is never moved. After completion, check the added files and feed, and confirm
the original tag SHA and existing asset checksums are unchanged.

## Signing modes

With none of the release secrets configured, the workflow creates an ad-hoc
signed, unnotarized DMG and adds the Gatekeeper limitation to the release notes.

For a public Developer ID release, configure all five repository secrets:

| Secret | Content |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |

For a signed, notarized stable release, also configure
`SPARKLE_EDDSA_PRIVATE_KEY` with the Sparkle EdDSA private key. Its matching
public key is stored in `config/sparkle-public-key.txt`; never commit the private
key. The workflow fails before building a signed stable release if this secret
is missing. Ad-hoc and prerelease builds do not use it.

The workflow fails before building if only part of this set is configured. With
the full set, it imports the application certificate into a temporary keychain, signs the bundled
microphone driver and the app
with Hardened Runtime and a trusted timestamp, signs the DMG, submits it with
`notarytool`, staples the ticket, validates Gatekeeper acceptance, and regenerates
the checksum after stapling.

Encode binary secrets without line wrapping before adding them to GitHub:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n'
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

The microphone driver is bundled at `Joy Harness.app/Contents/PlugIns/JoyHarnessMicrophone.driver`.
It uses the same Developer ID Application identity as the app and is included in
DMG notarization. There is no `.pkg` or Developer ID Installer dependency.
The Settings action installs the bundled driver after administrator authentication,
verifies its staged signature before replacing the installed copy, and reloads CoreAudio.

If Apple rejects a submission, the workflow prints the notarization report and
stops before stapling or publishing.

Never commit certificates, API keys, or their passwords to the repository.

## Sparkle updates

Only a signed, notarized stable release enables Sparkle in its app bundle. The
workflow signs each notarized DMG for Sparkle with EdDSA. Apple Silicon keeps
`appcast.xml` and Intel uses `appcast-x86_64.xml`; each app bundle points to its
own architecture's feed under
`https://github.com/nixihz/JoyHarness/releases/latest/download/`.
Appcast enclosures use version-specific Release download URLs so older entries
continue to point to their original DMGs. Each architecture's existing feed is
carried forward when a new eligible stable version is published. Backfilling an
architecture adds only its feed, preserving the other architecture's update path.

Only such releases are marked GitHub `latest`. The workflow explicitly publishes
ad-hoc stable releases and prereleases with `--latest=false`, without an appcast
asset. Source installs and debug builds also leave Sparkle disabled. Users of a
release predating Sparkle must manually install the first eligible version.

Local packaging and appcast checks do not prove an end-to-end update from a
published, notarized Release. Confirm the feed, download, and Sparkle install
flow when the first eligible stable release is published.

## Packaged resource check

`python3 scripts/verify_packaged_app.py "dist/Joy Harness.app"` copies the app
to a temporary directory and executes its version and controller-artwork loaders.
The check runs during DMG packaging and source installation before replacing the
installed app. It catches SwiftPM accessor differences between local and CI builds;
unit tests or signature verification alone do not prove packaged resources load.
