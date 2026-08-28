# Release automation

`.github/workflows/release.yml` publishes a versioned Apple Silicon DMG from
the `main` branch. It runs the complete test suite, packages the app, verifies
the DMG and checksum, creates a draft GitHub Release, uploads both assets, and
publishes the release only after every previous step succeeds.

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
exists. It does not modify an existing release.

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

The workflow fails before building if only part of this set is configured. With
the full set, it imports the certificate into a temporary keychain, signs the app
with Hardened Runtime and a trusted timestamp, signs the DMG, submits it with
`notarytool`, staples the ticket, validates Gatekeeper acceptance, and regenerates
the checksum after stapling.

Encode binary secrets without line wrapping before adding them to GitHub:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n'
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

Never commit certificates, API keys, or their passwords to the repository.
