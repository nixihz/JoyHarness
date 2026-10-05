#!/usr/bin/env python3
"""
Release preparation script for Joy Harness.

Automates:
1. Detecting the previous tag and parsing conventional commits since that tag.
2. Drafting changelog entries with English and Chinese category headings.
3. Updating version references across all project files:
   - Sources/JoyHarness/Resources/VERSION
   - tests/JoyHarnessTests/JoyHarnessTests.swift
   - README.md
   - docs/README.zh-CN.md
   - docs/CHANGELOG.md
   - docs/CHANGELOG.zh-CN.md

Commit subjects remain in their original language. Translate the Chinese
changelog and write the README What's New summaries during release review.
"""

import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def get_latest_tag() -> str:
    res = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout.strip()
    return "v0.1.0"


def get_commits_since_tag(tag: str) -> list[str]:
    res = subprocess.run(
        ["git", "log", f"{tag}..HEAD", "--pretty=format:%s"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if res.returncode == 0 and res.stdout.strip():
        return [line.strip() for line in res.stdout.strip().split("\n") if line.strip()]
    return []


def parse_conventional_commits(commits: list[str]) -> dict[str, list[str]]:
    categories = {
        "feat": [],
        "fix": [],
        "perf": [],
        "docs": [],
        "refactor": [],
        "test": [],
        "chore": [],
        "other": [],
    }

    for msg in commits:
        if msg.startswith("chore: prepare v"):
            continue
        match = re.match(r"^([a-z]+)(\([^\)]+\))?:\s*(.+)$", msg, re.IGNORECASE)
        if match:
            type_name = match.group(1).lower()
            subject = match.group(3).strip()
            if type_name in categories:
                categories[type_name].append(subject)
            else:
                categories["other"].append(msg)
        else:
            categories["other"].append(msg)

    return categories


def suggest_next_version(current_version: str, categories: dict[str, list[str]]) -> str:
    clean_v = current_version.lstrip("v")
    parts = clean_v.split(".")
    major = int(parts[0]) if len(parts) > 0 else 0
    minor = int(parts[1]) if len(parts) > 1 else 0
    patch = int(parts[2]) if len(parts) > 2 else 0

    if categories.get("feat"):
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def update_file(path: Path, old_content: str, new_content: str, dry_run: bool = False) -> None:
    if old_content == new_content:
        return
    print(f"  -> Updating {path.relative_to(ROOT)}")
    if not dry_run:
        path.write_text(new_content, encoding="utf-8")


def update_readme_references(content: str, version: str) -> str:
    """Update current downloads and commands while preserving release history."""
    sections = re.split(r"(?=^## )", content, flags=re.MULTILINE)
    for index, section in enumerate(sections):
        if re.match(r"## (?:What's New in v|v[0-9][^\n]* 更新)", section):
            continue
        section = re.sub(
            r"(The current release is|当前版本为) \*\*v[^*]+\*\*",
            lambda match: f"{match[1]} **v{version}**",
            section,
        )
        section = re.sub(
            r"releases/download/v[0-9a-zA-Z.-]+/(?=Joy-Harness-v[0-9a-zA-Z.-]+-macOS-(?:arm64|x86_64)\.dmg)",
            f"releases/download/v{version}/",
            section,
        )
        section = re.sub(
            r"Joy-Harness-v[0-9a-zA-Z.-]+-macOS-(arm64|x86_64)\.dmg",
            lambda match: f"Joy-Harness-v{version}-macOS-{match[1]}.dmg",
            section,
        )
        section = re.sub(r"releases/tag/v[0-9a-zA-Z.-]+", f"releases/tag/v{version}", section)
        section = re.sub(r"View the v[0-9a-zA-Z.-]+ release", f"View the v{version} release", section)
        section = re.sub(r"查看 v[0-9a-zA-Z.-]+ Release", f"查看 v{version} Release", section)
        section = re.sub(r"task dmg -- [0-9a-zA-Z.-]+", f"task dmg -- {version}", section)
        section = re.sub(r"scripts/package_dmg\.sh [0-9a-zA-Z.-]+", f"scripts/package_dmg.sh {version}", section)
        sections[index] = section
    return "".join(sections)


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare Joy Harness Release")
    parser.add_argument("version", nargs="?", help="Target version (e.g. 0.5.0)")
    parser.add_argument("--dry-run", action="store_true", help="Print changes without modifying files")
    args = parser.parse_args()

    latest_tag = get_latest_tag()
    latest_version = latest_tag.lstrip("v")
    commits = get_commits_since_tag(latest_tag)
    categories = parse_conventional_commits(commits)

    target_version = args.version.lstrip("v") if args.version else suggest_next_version(latest_version, categories)
    today = datetime.date.today().isoformat()

    print(f"==> Joy Harness Release Preparation: v{target_version}")
    print(f"    Previous tag: {latest_tag}")
    print(f"    Commits found: {len(commits)}")

    # 1. Update VERSION
    version_file = ROOT / "Sources" / "JoyHarness" / "Resources" / "VERSION"
    update_file(version_file, version_file.read_text(encoding="utf-8"), f"{target_version}\n", args.dry_run)

    # 2. Update JoyHarnessTests.swift
    test_file = ROOT / "tests" / "JoyHarnessTests" / "JoyHarnessTests.swift"
    test_content = test_file.read_text(encoding="utf-8")
    test_content = re.sub(r'#expect\(AppVersion\.current == "[^"]+"\)', f'#expect(AppVersion.current == "{target_version}")', test_content, count=1)
    test_content = re.sub(r'#expect\(AppVersion\.displayName == "Joy Harness v[^"]+"\)', f'#expect(AppVersion.displayName == "Joy Harness v{target_version}")', test_content, count=1)
    update_file(test_file, test_file.read_text(encoding="utf-8"), test_content, args.dry_run)

    # 3. Update README.md
    readme_file = ROOT / "README.md"
    readme = readme_file.read_text(encoding="utf-8")
    readme = update_readme_references(readme, target_version)
    update_file(readme_file, readme_file.read_text(encoding="utf-8"), readme, args.dry_run)

    # 4. Update docs/README.zh-CN.md
    readme_zh_file = ROOT / "docs" / "README.zh-CN.md"
    readme_zh = readme_zh_file.read_text(encoding="utf-8")
    readme_zh = update_readme_references(readme_zh, target_version)
    update_file(readme_zh_file, readme_zh_file.read_text(encoding="utf-8"), readme_zh, args.dry_run)

    # 5. Update docs/CHANGELOG.md
    changelog_file = ROOT / "docs" / "CHANGELOG.md"
    changelog = changelog_file.read_text(encoding="utf-8")
    if f"## [{target_version}]" not in changelog:
        items = []
        if categories["feat"]:
            items.append("### Added\n" + "\n".join(f"- {s}" for s in categories["feat"]))
        if categories["fix"]:
            items.append("### Fixed\n" + "\n".join(f"- {s}" for s in categories["fix"]))
        if categories["perf"] or categories["refactor"]:
            items.append("### Changed\n" + "\n".join(f"- {s}" for s in categories["perf"] + categories["refactor"]))
        if not items:
            items.append("### Changed\n- Maintenance and performance improvements.")
        
        entry = f"## [{target_version}] - {today}\n\n" + "\n\n".join(items) + "\n\n"
        changelog = re.sub(r'(## \[[0-9a-zA-Z.-]+\] - [0-9-]+)', f"{entry}\\1", changelog, count=1)

        # Compare link at bottom
        compare_link = f"[{target_version}]: https://github.com/nixihz/JoyHarness/compare/{latest_tag}...v{target_version}\n"
        changelog = re.sub(r'(\[[0-9a-zA-Z.-]+\]: https://github\.com/nixihz/JoyHarness/compare/)', f"{compare_link}\\1", changelog, count=1)
        update_file(changelog_file, changelog_file.read_text(encoding="utf-8"), changelog, args.dry_run)

    # 6. Update docs/CHANGELOG.zh-CN.md
    changelog_zh_file = ROOT / "docs" / "CHANGELOG.zh-CN.md"
    changelog_zh = changelog_zh_file.read_text(encoding="utf-8")
    if f"## [{target_version}]" not in changelog_zh:
        items_zh = []
        if categories["feat"]:
            items_zh.append("### 新增\n" + "\n".join(f"- {s}" for s in categories["feat"]))
        if categories["fix"]:
            items_zh.append("### 修复\n" + "\n".join(f"- {s}" for s in categories["fix"]))
        if categories["perf"] or categories["refactor"]:
            items_zh.append("### 优化与重构\n" + "\n".join(f"- {s}" for s in categories["perf"] + categories["refactor"]))
        if not items_zh:
            items_zh.append("### 变更\n- 日常维护与性能优化。")

        entry_zh = f"## [{target_version}] - {today}\n\n" + "\n\n".join(items_zh) + "\n\n"
        changelog_zh = re.sub(r'(## \[[0-9a-zA-Z.-]+\] - [0-9-]+)', f"{entry_zh}\\1", changelog_zh, count=1)

        compare_link = f"[{target_version}]: https://github.com/nixihz/JoyHarness/compare/{latest_tag}...v{target_version}\n"
        changelog_zh = re.sub(r'(\[[0-9a-zA-Z.-]+\]: https://github\.com/nixihz/JoyHarness/compare/)', f"{compare_link}\\1", changelog_zh, count=1)
        update_file(changelog_zh_file, changelog_zh_file.read_text(encoding="utf-8"), changelog_zh, args.dry_run)

    print(f"\n✓ Release preparation complete for v{target_version}.")
    print("Next steps:")
    print("  1. Review git diff, translate the Chinese changelog, and write both README What's New summaries")
    print("  2. Validate: task ci && task release-check")
    print(f"  3. Commit and push: git commit -am 'chore: prepare v{target_version} release' && git push")
    print(f"  4. Trigger release: gh workflow run release.yml --ref main -f version={target_version} -f prerelease=false -f backfill_arch=none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
