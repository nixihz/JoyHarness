import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("plan_release", ROOT / "scripts/plan_release.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.previous_cwd = Path.cwd()
        self.addCleanup(os.chdir, self.previous_cwd)
        os.chdir(self.directory.name)
        self.git("init", "-q")
        self.version_file = Path("Sources/JoyHarness/Resources/VERSION")
        self.version_file.parent.mkdir(parents=True)
        self.version_file.write_text("1.2.3\n")
        self.git("add", ".")
        self.git("commit", "-qm", "original release")
        self.tag_sha = self.git("rev-parse", "HEAD")
        self.git("tag", "v1.2.3")
        self.version_file.write_text("1.2.4\n")
        self.git("commit", "-qam", "later application changes")
        self.main_sha = self.git("rev-parse", "HEAD")
        environment = patch.dict(os.environ, GITHUB_REF="refs/heads/main",
                                 GITHUB_SHA=self.main_sha, GITHUB_REPOSITORY="example/repo")
        environment.start()
        self.addCleanup(environment.stop)
        self.release = {
            "id": 123, "draft": False, "prerelease": False,
            "assets": [{"name": name} for name in (
                "appcast.xml", "Joy-Harness-v1.2.3-macOS-arm64.dmg",
                "Joy-Harness-v1.2.3-macOS-arm64.dmg.sha256",
            )],
        }

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.invalid", *args],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()

    def test_new_release_builds_both_architectures_from_dispatch_commit(self):
        with patch.object(planner, "release_api", return_value=None):
            plan = planner.plan("v1.2.4", False, "none")
        self.assertEqual(plan["source_sha"], self.main_sha)
        self.assertEqual(plan["version"], "1.2.4")
        import json
        matrix = json.loads(plan["matrix"])["include"]
        self.assertEqual({entry["arch"] for entry in matrix}, {"arm64", "x86_64"})
        self.assertEqual(len({entry["runner"] for entry in matrix}), 2)

    def test_backfill_pins_original_tag_despite_newer_application_changes(self):
        before = self.git("status", "--porcelain")
        with patch.object(planner, "release_api", return_value=self.release):
            plan = planner.plan("1.2.3", False, "x86_64")
        self.assertEqual(plan["source_sha"], self.tag_sha)
        self.assertNotEqual(plan["source_sha"], self.main_sha)
        import json
        self.assertEqual([entry["arch"] for entry in json.loads(plan["matrix"])["include"]], ["x86_64"])
        self.assertEqual(self.git("rev-parse", "v1.2.3"), self.tag_sha)
        self.assertEqual(self.git("status", "--porcelain"), before)

    def test_backfill_refuses_each_existing_asset_without_overwriting(self):
        for name in ("appcast-x86_64.xml", "Joy-Harness-v1.2.3-macOS-x86_64.dmg",
                     "Joy-Harness-v1.2.3-macOS-x86_64.dmg.sha256"):
            with self.subTest(name=name):
                release = copy.deepcopy(self.release)
                release["assets"].append({"name": name})
                with patch.object(planner, "release_api", return_value=release):
                    with self.assertRaisesRegex(ValueError, "overwrite existing assets"):
                        planner.plan("1.2.3", False, "x86_64")

    def test_backfill_rejects_unpublished_prerelease_or_nonlatest_release(self):
        for release, latest in ((None, self.release),
                                (dict(self.release, draft=True), self.release),
                                (dict(self.release, prerelease=True), self.release),
                                (self.release, dict(self.release, id=124))):
            with self.subTest(release=release, latest=latest):
                with patch.object(planner, "release_api", side_effect=[release, latest]):
                    with self.assertRaisesRegex(ValueError, "published stable|latest stable"):
                        planner.plan("1.2.3", False, "x86_64")

    def test_new_release_rejects_existing_tag_and_source_version_mismatch(self):
        with patch.object(planner, "release_api", return_value=None):
            with self.assertRaisesRegex(ValueError, "already exists"):
                planner.plan("1.2.3", False, "none")
            with self.assertRaisesRegex(ValueError, "does not match source version"):
                planner.plan("9.9.9", False, "none")

    def test_invalid_requests_stop_before_network_calls(self):
        for version, prerelease, arch, ref in (
            ("1.2.3-rc.1", False, "none", "refs/heads/main"),
            ("1.2.3.4", False, "none", "refs/heads/main"),
            ("1.2.3;echo bad", False, "none", "refs/heads/main"),
            ("1.2.3", False, "amd64", "refs/heads/main"),
            ("1.2.3", False, "none", "refs/heads/feature"),
        ):
            with self.subTest(version=version, arch=arch, ref=ref):
                with patch.dict(os.environ, GITHUB_REF=ref), patch.object(planner, "release_api") as api:
                    with self.assertRaises(ValueError):
                        planner.plan(version, prerelease, arch)
                    api.assert_not_called()

    def test_api_failure_is_not_treated_as_missing_release(self):
        for stderr, missing in (("gh: Not Found (HTTP 404)", True),
                                ("gh: Forbidden (HTTP 403)", False),
                                ("TLS handshake timeout", False)):
            with self.subTest(stderr=stderr), patch.object(planner.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 1, "", stderr)):
                if missing:
                    self.assertIsNone(planner.release_api("tags/v1.2.3"))
                else:
                    with self.assertRaises(RuntimeError):
                        planner.release_api("tags/v1.2.3")


if __name__ == "__main__":
    unittest.main()
