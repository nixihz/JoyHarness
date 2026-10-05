import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PrepareReleaseTests(unittest.TestCase):
    def create_checkout(self, root: Path) -> dict[str, str]:
        """Provide release inputs, including historical download instructions."""
        files = {
            "Sources/JoyHarness/Resources/VERSION": "0.8.2\n",
            "tests/JoyHarnessTests/JoyHarnessTests.swift": (
                '#expect(AppVersion.current == "0.8.2")\n'
                '#expect(AppVersion.displayName == "Joy Harness v0.8.2")\n'
            ),
        }
        for filename, banner, label, history_title in (
            ("README.md", "The current release is", "View the v0.8.2 release", "What's New in v0.8.2"),
            ("docs/README.zh-CN.md", "当前版本为", "查看 v0.8.2 Release", "v0.8.2 更新"),
        ):
            downloads = []
            for arch in ("arm64", "x86_64"):
                artifact = f"Joy-Harness-v0.8.2-macOS-{arch}.dmg"
                url = f"https://github.com/nixihz/JoyHarness/releases/download/v0.8.2/{artifact}"
                downloads.extend((f"[{artifact}]({url})", f"[SHA-256]({url}.sha256)", f"shasum -a 256 -c {artifact}.sha256", artifact))
            files[filename] = (
                f"## Download\n{banner} **v0.8.2**\n"
                + "\n".join(downloads)
                + f"\n[{label}](https://github.com/nixihz/JoyHarness/releases/tag/v0.8.2)\n"
                + f"## {history_title}\n"
                + "Previous download: https://github.com/nixihz/JoyHarness/releases/download/v0.8.2/Joy-Harness-v0.8.2-macOS-arm64.dmg\n"
                + "## Local packaging\ntask dmg -- 0.8.2\nbash scripts/package_dmg.sh 0.8.2\n"
            )
        for filename in ("docs/CHANGELOG.md", "docs/CHANGELOG.zh-CN.md"):
            files[filename] = (
                "# Changelog\n\n## [0.8.2] - 2026-10-05\n\nPrevious release.\n\n"
                "[0.8.2]: https://github.com/nixihz/JoyHarness/compare/v0.8.1...v0.8.2\n"
            )
        for relative_path, content in files.items():
            destination = root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content, encoding="utf-8")
        (root / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/prepare_release.py", root / "scripts/prepare_release.py")
        return files

    def run_prepare(self, root: Path, *arguments: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(root / "scripts/prepare_release.py"), *arguments],
            cwd=root,
            capture_output=True,
            text=True,
        )

    def test_version_bump_updates_both_architectures_and_preserves_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            original = self.create_checkout(checkout)
            result = self.run_prepare(checkout, "0.9.0-rc.1")
            self.assertEqual(result.returncode, 0, result.stderr)
            for filename, label in (
                ("README.md", "View the v0.9.0-rc.1 release"),
                ("docs/README.zh-CN.md", "查看 v0.9.0-rc.1 Release"),
            ):
                with self.subTest(filename=filename):
                    updated = (checkout / filename).read_text(encoding="utf-8")
                    current = updated.split("## ", 2)[1]
                    self.assertNotIn("0.8.2", current)
                    self.assertIn(f"[{label}](https://github.com/nixihz/JoyHarness/releases/tag/v0.9.0-rc.1)", current)
                    for arch in ("arm64", "x86_64"):
                        artifact = f"Joy-Harness-v0.9.0-rc.1-macOS-{arch}.dmg"
                        self.assertIn(f"/releases/download/v0.9.0-rc.1/{artifact}", current)
                        self.assertIn(f"/releases/download/v0.9.0-rc.1/{artifact}.sha256", current)
                        self.assertIn(f"shasum -a 256 -c {artifact}.sha256", current)
                        self.assertIn(f"\n{artifact}\n", current)
                    old_history = original[filename].split("## ")[2]
                    self.assertEqual(updated.split("## ")[2], old_history)
                    self.assertIn("task dmg -- 0.9.0-rc.1", updated)
                    self.assertIn("bash scripts/package_dmg.sh 0.9.0-rc.1", updated)
            self.assertEqual((checkout / "Sources/JoyHarness/Resources/VERSION").read_text(), "0.9.0-rc.1\n")

    def test_dry_run_leaves_release_files_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            original = self.create_checkout(checkout)
            result = self.run_prepare(checkout, "0.9.0", "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Updating docs/README.zh-CN.md", result.stdout)
            for filename, content in original.items():
                with self.subTest(filename=filename):
                    self.assertEqual((checkout / filename).read_text(encoding="utf-8"), content)


if __name__ == "__main__":
    unittest.main()
