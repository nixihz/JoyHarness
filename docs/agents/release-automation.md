# Release automation

`.github/workflows/release.yml` publishes a versioned Apple Silicon DMG from
the `main` branch. It runs the complete test suite, packages the app, verifies
the packaged app’s resource loading from a temporary location, the DMG and
checksum, creates a draft GitHub Release, uploads its assets, and publishes the
release only after every previous step succeeds.

## Run a release

1. Prepare release files and changelog automatically from Conventional Commits:
   ```bash
   python3 scripts/prepare_release.py <version>
   ```
   Or invoke the `.agents/skills/release/SKILL.md` skill with prompt: `帮我发版 vX.Y.Z`.

2. Commit and push the release preparation:
   ```bash
   git commit -am "chore: prepare v<version> release"
   git push origin main
   ```

3. Dispatch the GitHub Actions release workflow:
   ```bash
   gh workflow run release.yml --ref main -f version=<version> -f prerelease=false
   ```

The workflow rejects invalid versions and versions whose tag or Release already
exists. Stable releases require a plain `major.minor.patch` version; a version
with a suffix must use `prerelease=true`. The workflow does not modify an
existing release.

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
workflow signs the notarized DMG for Sparkle with EdDSA, adds `appcast.xml` as a
third Release asset, and checks the published feed at
`https://github.com/nixihz/JoyHarness/releases/latest/download/appcast.xml`.
Appcast enclosures use version-specific Release download URLs so older entries
continue to point to their original DMGs. The existing feed is carried forward
when a new eligible stable version is published.

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
