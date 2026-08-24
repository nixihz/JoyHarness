import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallationTests(unittest.TestCase):
    def test_install_has_no_launch_agent_integration(self) -> None:
        script = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        stop_script = (
            ROOT / "scripts" / "stop_joy_harness_instances.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('scripts/stop_joy_harness_instances.sh"', script)
        self.assertIn('/usr/bin/open -n "${APP_DIR}"', script)
        self.assertNotIn("pkill -x", script)
        self.assertNotIn("LaunchAgent", script)
        self.assertNotIn("launchctl", script)
        self.assertNotIn("launchctl", stop_script)

    def test_install_removes_obsolete_codex_integration(self) -> None:
        script = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")

        self.assertNotIn('install -m 755 "${ROOT}/codex-hooks/', script)
        self.assertIn("hook_bridge.py", script)
        self.assertIn("notify_fanout.py", script)
        self.assertIn("bak-joyharness-removal", script)
        self.assertIn("remove_fanout", script)
        self.assertIn("removed_hooks_source", script)
        self.assertIn("source_prefix", script)

    def test_development_run_stops_installed_app(self) -> None:
        script = (ROOT / "scripts" / "build_and_run.sh").read_text(encoding="utf-8")

        self.assertIn('scripts/stop_joy_harness_instances.sh"', script)
        self.assertIn('pgrep -f -x "${APP_BINARY}"', script)

    def test_shared_stop_step_terminates_bundle_process_by_full_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = (
                Path(temporary_directory)
                / "Joy Harness.app"
                / "Contents"
                / "MacOS"
                / "JoyHarness"
            )
            executable.parent.mkdir(parents=True)
            executable.symlink_to("/usr/bin/yes")
            process = subprocess.Popen(
                [str(executable)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.addCleanup(lambda: process.poll() is None and process.kill())

            environment = os.environ.copy()
            environment["JOY_HARNESS_PROCESS_PATTERN"] = (
                f"^{re.escape(str(executable))}$"
            )
            subprocess.run(
                [str(ROOT / "scripts" / "stop_joy_harness_instances.sh")],
                check=True,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertIsNotNone(process.wait(timeout=2))

    def test_all_app_builds_use_the_shared_signing_step(self) -> None:
        development = (ROOT / "scripts" / "build_and_run.sh").read_text(encoding="utf-8")
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")

        self.assertIn('scripts/sign_macos_app.sh"', development)
        self.assertIn('scripts/sign_macos_app.sh"', installer)
        self.assertNotIn('"${APP_BUNDLE}/JoyHarness_JoyHarness.bundle"', development)

    def test_installed_and_development_apps_use_the_shared_version(self) -> None:
        development = (ROOT / "scripts" / "build_and_run.sh").read_text(encoding="utf-8")
        installer = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")

        for script in (development, installer):
            self.assertIn("Sources/JoyHarness/Resources/VERSION", script)
            self.assertIn("CFBundleShortVersionString", script)
            self.assertIn("CFBundleVersion", script)

    def test_all_app_builds_use_the_info_plist_bundle_identifier(self) -> None:
        expected = 'PlistBuddy -c \'Print :CFBundleIdentifier\''

        for relative_path in (
            "scripts/build_and_run.sh",
            "scripts/install.sh",
            "scripts/package_dmg.sh",
        ):
            script = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(expected, script)
            self.assertNotIn('BUNDLE_ID="tech.keli.joyharness"', script)

    def test_signing_step_produces_a_valid_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            app = Path(temporary_directory) / "Fixture.app"
            executable = app / "Contents" / "MacOS" / "Fixture"
            executable.parent.mkdir(parents=True)
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(0o755)
            with (app / "Contents" / "Info.plist").open("wb") as plist_file:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "Fixture",
                        "CFBundleIdentifier": "tech.joyharness.fixture",
                        "CFBundleName": "Fixture",
                        "CFBundlePackageType": "APPL",
                    },
                    plist_file,
                )

            environment = os.environ.copy()
            environment["JOY_HARNESS_SIGNING_IDENTITY"] = "-"
            subprocess.run(
                [
                    str(ROOT / "scripts" / "sign_macos_app.sh"),
                    str(app),
                    "tech.joyharness.fixture",
                ],
                check=True,
                env=environment,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["codesign", "--verify", "--deep", "--strict", str(app)],
                check=True,
                capture_output=True,
                text=True,
            )


if __name__ == "__main__":
    unittest.main()
