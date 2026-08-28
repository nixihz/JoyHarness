---
name: joyharness-release
description: Automate Joy Harness release lifecycle. Parses conventional commits into English and Chinese changelogs, synchronizes version across all project files, runs unit tests, commits and pushes to main, and dispatches the GitHub Actions DMG packaging, Developer ID signing, and release workflow.
---

# Joy Harness Release Automation

Automate the full end-to-end release lifecycle for Joy Harness using Conventional Commits and GitHub Actions.

## When to use

Use this skill whenever the user asks to:
- "发版" / "发布 release" / "发布新版本"
- "prepare release" / "release vX.Y.Z" / "publish release"
- Bump version and trigger the release workflow

## Workflow Steps

### Step 1: Analyze Commits and Determine Version

1. Identify the previous release tag:
   ```bash
   git describe --tags --abbrev=0
   ```
2. Scan commits since the last tag:
   ```bash
   git log $(git describe --tags --abbrev=0)..HEAD --pretty=format:"* %s (%h)"
   ```
3. Classify the conventional commits into categories:
   - `feat:` -> Features / 新功能
   - `fix:` -> Bug Fixes / 修复
   - `perf:` -> Performance / 性能优化
   - `docs:` -> Documentation / 文档
   - `refactor:` / `test:` / `chore:` / `ci:` -> Maintenance / 维护与重构
4. Determine target version (e.g., `0.5.0` or `0.4.1`) based on Semantic Versioning, or use the version requested by the user.

### Step 2: Prepare Release Files

Run the automated preparation script or update the 6 files:
```bash
python3 scripts/prepare_release.py <version>
```

Verify that the following 6 files have been synchronized:
1. `Sources/JoyHarness/Resources/VERSION`: contains `<version>`
2. `tests/JoyHarnessTests/JoyHarnessTests.swift`: `#expect(AppVersion.current == "<version>")`
3. `README.md`: updated download URLs, SHA-256 command, `task dmg -- <version>`, and `## What's New in v<version>`
4. `docs/README.zh-CN.md`: updated Chinese download URLs, SHA-256 command, `task dmg -- <version>`, and `## v<version> 更新`
5. `docs/CHANGELOG.md`: added `## [<version>] - YYYY-MM-DD` section and compare link
6. `docs/CHANGELOG.zh-CN.md`: added Chinese `## [<version>] - YYYY-MM-DD` section and compare link

### Step 3: Run Validation Suite

Ensure all tests pass before making any release commit:
```bash
swift test && python3 -m unittest discover -s tests -v
```

### Step 4: Commit and Push

1. Stage and commit changes:
   ```bash
   git add Sources/JoyHarness/Resources/VERSION tests/JoyHarnessTests/JoyHarnessTests.swift README.md docs/README.zh-CN.md docs/CHANGELOG.md docs/CHANGELOG.zh-CN.md
   git commit -m "chore: prepare v<version> release"
   ```
2. Push to `main`:
   ```bash
   git push origin main
   ```

### Step 5: Dispatch GitHub Actions Release Workflow

1. Trigger the release workflow:
   ```bash
   gh workflow run release.yml --ref main -f version=<version> -f prerelease=false
   ```
2. Monitor workflow progress with `gh run watch <run_id>`.
3. Once completed, sync the newly created tag to local:
   ```bash
   git fetch --tags
   ```
4. Verify the published release:
   ```bash
   gh release view v<version>
   ```

### Step 6: Summary

Present a clear summary of the published release to the user with the release URL, tag, and key highlights.
