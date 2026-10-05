---
name: joyharness-release
description: Publish a new Joy Harness release or add a missing Mac architecture to the latest stable release. Prepares versions and changelog drafts, validates the repository, and runs the native arm64 and x86_64 GitHub Actions packaging, signing, notarization and release workflow.
---

# Joy Harness releases

Use this skill for new versions, release publication, or adding a missing Apple
Silicon / Intel package to an existing release. Follow the relevant branch below.
See [release automation](../../../docs/agents/release-automation.md) for signing
secrets, Sparkle behavior, and packaged resource checks.

## Publish a new version

1. Identify the previous release tag and inspect the commits since it. Use the
   version requested by the user; otherwise choose a Semantic Version based on
   the changes. Run `python3 scripts/prepare_release.py <version>`.
2. Review all six release files: `Sources/JoyHarness/Resources/VERSION`,
   `tests/JoyHarnessTests/JoyHarnessTests.swift`, `README.md`,
   `docs/README.zh-CN.md`, `docs/CHANGELOG.md`, and `docs/CHANGELOG.zh-CN.md`.
   Verify current download URLs, bare artifact names, checksum commands, visible
   release labels and local packaging commands for both `arm64` and `x86_64`.
   The script drafts changelog categories but preserves commit subjects in their
   original language. Translate the Chinese entry and write the new README
   What's New summaries manually; preserve historical summaries.
3. Run `task ci` and `task release-check`. Resolve failures before committing the
   preparation, then commit and push the release changes to `main`.
4. Dispatch the release workflow:
   ```bash
   gh workflow run release.yml --ref main -f version=<version> -f prerelease=false -f backfill_arch=none
   ```
   Use `prerelease=true` for a prerelease version. `backfill_arch=none` is the
   default: `macos-26` builds arm64 and `macos-26-intel` builds x86_64. Both run
   native tests, packaging and architecture checks, plus signing and
   notarization when configured. All builds must succeed before one Release is
   published with both architectures.
5. Monitor the dispatched run to completion. Fetch the new tag and verify both
   DMGs, their SHA-256 files, and, for a signed notarized stable release, both
   Sparkle feeds: `appcast.xml` for arm64 and `appcast-x86_64.xml` for Intel.
   Report the Release URL, tag and verified outcome.

## Add a missing architecture

1. Confirm the requested version is the latest published stable release and
   record its tag commit SHA and existing asset checksums. The selected
   architecture's assets must be absent. Use `x86_64` for Intel (AMD64) or
   `arm64` for Apple Silicon.
2. Ensure the updated workflow and packaging tools are on `main`; validate any
   changes with `task ci` and `task release-check`. Keep the version metadata and
   existing tag unchanged. The workflow builds application source and resources
   from the original tag SHA, overlaying only newer packaging tooling.
3. Dispatch the backfill. For v0.8.2 Intel:
   ```bash
   gh workflow run release.yml --ref main -f version=0.8.2 -f prerelease=false -f backfill_arch=x86_64
   ```
   `backfill_arch=arm64` selects the corresponding Apple Silicon job. Backfill
   rejects drafts, prereleases, versions other than the latest stable release,
   and existing assets for the selected architecture. It never moves the tag or
   overwrites existing assets.
4. Monitor the run to completion and verify the added DMG, checksum and eligible
   architecture-specific Sparkle feed. Confirm the tag SHA and all previous
   asset checksums are unchanged, then report the direct download and Release
   links with the validation result.
