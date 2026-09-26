import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CURRENT_VERSION = (
    ROOT / "Sources" / "JoyHarness" / "Resources" / "VERSION"
).read_text(encoding="utf-8").strip()


class ReleaseAutomationTests(unittest.TestCase):
    def test_release_credentials_accept_existing_five_secrets(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Validate release secrets\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])
        keys = (
            "CERTIFICATE_BASE64", "CERTIFICATE_PASSWORD",
            "API_KEY_BASE64", "API_KEY_ID", "API_ISSUER_ID",
        )
        for count, mode in ((0, "unnotarized"), (1, None), (4, None), (5, "notarized")):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "github-env"
                env = dict(os.environ, GITHUB_ENV=str(output))
                env.update({key: "test-value" if index < count else "" for index, key in enumerate(keys)})
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
                if mode is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("partially configured", result.stderr)
                    self.assertFalse(output.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"RELEASE_MODE={mode}", output.read_text())

    def test_notarization_rejection_prints_report_and_stops_before_stapling(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        block = workflow.split('          NOTARY_RESULT=', 1)[1]
        block = '          NOTARY_RESULT=' + block.split('          xcrun stapler staple', 1)[0]
        for status in ("Accepted", "Invalid"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                script = '''set -euo pipefail
RUNNER_TEMP="$1"
DMG_PATH=release.dmg
API_KEY_PATH=unused
API_KEY_ID=unused
API_ISSUER_ID=unused
xcrun() {
  if [[ "$2" == submit ]]; then
    printf '{"id":"submission-id","status":"%s"}\\n' "$STATUS"
  elif [[ "$2" == log ]]; then
    echo 'notarization rejection details'
  else
    return 99
  fi
}
'''
                result = subprocess.run(
                    ["bash", "-c", f'STATUS={status}\n' + script + textwrap.dedent(block) + '\necho ready-to-staple\n', "test", directory],
                    capture_output=True,
                    text=True,
                )
                if status == "Accepted":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("ready-to-staple", result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("notarization rejection details", result.stdout)
                    self.assertNotIn("ready-to-staple", result.stdout)

    def test_release_check_accepts_consistent_repository_metadata(self) -> None:
        result = subprocess.run(
            ["python3", "scripts/release_check.py"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release metadata is consistent", result.stdout)

    def test_release_check_rejects_metadata_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory)
            for relative_path in (
                "README.md",
                "Sources/JoyHarness/Resources/VERSION",
                "tests/JoyHarnessTests/JoyHarnessTests.swift",
                "scripts/package_dmg.sh",
                ".github/workflows/release.yml",
                "firmware/rp2040/src/main.c",
            ):
                source = ROOT / relative_path
                destination = checkout / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            (checkout / "README.md").write_text(
                (checkout / "README.md").read_text(encoding="utf-8").replace(
                    f"Joy-Harness-v{CURRENT_VERSION}-macOS-arm64.dmg",
                    "Joy-Harness-v9.9.9-macOS-arm64.dmg",
                    1,
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "scripts" / "release_check.py"),
                    "--root",
                    str(checkout),
                ],
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("README download artifact", result.stderr)

    def test_release_check_validates_optional_tag(self) -> None:
        accepted = subprocess.run(
            ["python3", "scripts/release_check.py", f"v{CURRENT_VERSION}"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        missing_prefix = subprocess.run(
            ["python3", "scripts/release_check.py", "0.4.0"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        wrong_version = subprocess.run(
            ["python3", "scripts/release_check.py", "v9.9.9"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertNotEqual(missing_prefix.returncode, 0)
        self.assertIn("tag must have the form", missing_prefix.stderr)
        self.assertNotEqual(wrong_version.returncode, 0)
        self.assertIn("does not match source version", wrong_version.stderr)

    def test_release_check_rejects_executable_metadata_drift(self) -> None:
        mutations = {
            "tests/JoyHarnessTests/JoyHarnessTests.swift": (
                f'AppVersion.current == "{CURRENT_VERSION}"',
                'AppVersion.current == "9.9.9"',
                "AppVersion.current expectation",
            ),
            "scripts/package_dmg.sh": (
                'DMG_NAME="Joy-Harness-v${VERSION}-macOS-${ARCH}.dmg"',
                'DMG_NAME="JoyHarness-${VERSION}-${ARCH}.dmg"',
                "DMG naming is inconsistent",
            ),
            "firmware/rp2040/src/main.c": (
                "0.1.0-agentdeck",
                "9.9.9-unknown",
                "firmware protocol version",
            ),
        }
        required_paths = (
            "README.md",
            "Sources/JoyHarness/Resources/VERSION",
            "tests/JoyHarnessTests/JoyHarnessTests.swift",
            "scripts/package_dmg.sh",
            ".github/workflows/release.yml",
            "firmware/rp2040/src/main.c",
        )

        for mutated_path, (old, new, expected_error) in mutations.items():
            with self.subTest(path=mutated_path), tempfile.TemporaryDirectory() as temporary_directory:
                checkout = Path(temporary_directory)
                for relative_path in required_paths:
                    source = ROOT / relative_path
                    destination = checkout / relative_path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, destination)
                target = checkout / mutated_path
                target.write_text(
                    target.read_text(encoding="utf-8").replace(old, new),
                    encoding="utf-8",
                )

                result = subprocess.run(
                    [
                        "python3",
                        str(ROOT / "scripts" / "release_check.py"),
                        "--root",
                        str(checkout),
                    ],
                    capture_output=True,
                    text=True,
                )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, result.stderr)

    def test_shared_release_checks_are_used_by_ci_and_release(self) -> None:
        taskfile = (ROOT / "Taskfile.yml").read_text(encoding="utf-8")
        ci_workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        release_workflow = (
            ROOT / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("release-check:", taskfile)
        self.assertIn("python3 scripts/release_check.py", taskfile)
        self.assertIn("task release-check", ci_workflow)
        self.assertIn("task ci", release_workflow)
        self.assertIn('task release-check -- "${TAG}"', release_workflow)
        self.assertIn("task firmware", release_workflow)
        self.assertIn("brew install --cask gcc-arm-embedded", ci_workflow)
        self.assertIn("brew install --cask gcc-arm-embedded", release_workflow)
        self.assertNotIn("brew install go-task cmake ninja arm-none-eabi-gcc", ci_workflow)
        self.assertNotIn(
            "brew install go-task shellcheck cmake ninja arm-none-eabi-gcc",
            release_workflow,
        )

    def test_release_workflow_has_a_guarded_one_click_flow(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn('refs/heads/main', workflow)
        self.assertIn("Sources/JoyHarness/Resources/VERSION", workflow)
        self.assertIn("does not match source version", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("--draft", workflow)
        self.assertNotIn("PRERELEASE_ARGS", workflow)
        self.assertIn("create_release --prerelease", workflow)
        self.assertIn("README.md", workflow)
        self.assertIn('gh release edit "${TAG}" --draft=false --latest=false', workflow)
        self.assertIn('gh release edit "${TAG}" --draft=false --latest', workflow)

    def test_release_workflow_supports_complete_or_empty_signing_config(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        expected_secrets = {
            "DEVELOPER_ID_CERTIFICATE_BASE64",
            "DEVELOPER_ID_CERTIFICATE_PASSWORD",
            "APPLE_API_KEY_P8_BASE64",
            "APPLE_API_KEY_ID",
            "APPLE_API_ISSUER_ID",
        }
        for secret in expected_secrets:
            self.assertIn(f"secrets.{secret}", workflow)

        self.assertIn("Signing/notarization secrets are only partially configured", workflow)
        self.assertIn("xcrun notarytool submit", workflow)
        self.assertIn("xcrun stapler staple", workflow)
        self.assertIn("shasum -a 256", workflow)

    def test_developer_id_signing_enables_distribution_options(self) -> None:
        signing_script = (ROOT / "scripts" / "sign_macos_app.sh").read_text(
            encoding="utf-8"
        )
        package_script = (ROOT / "scripts" / "package_dmg.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('"Developer ID Application:"*', signing_script)
        self.assertIn("--options runtime --timestamp", signing_script)
        self.assertIn('"Developer ID Application:"*', package_script)
        self.assertIn('codesign --verify --verbose=2 "${DMG_PATH}"', package_script)

    def test_only_signed_stable_release_becomes_latest(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        step = workflow.split("      - name: Publish release\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("      - name:", 1)[0])

        for release_mode, prerelease, expected in (
            ("notarized", "false", "--latest"),
            ("notarized", "true", "--latest=false"),
            ("unnotarized", "false", "--latest=false"),
        ):
            with self.subTest(release_mode=release_mode, prerelease=prerelease):
                environment = dict(os.environ, RELEASE_MODE=release_mode,
                                   PRERELEASE=prerelease, TAG="v1.2.3")
                result = subprocess.run(
                    ["bash", "-c", 'gh() { printf "%s\\n" "$*"; }\n' + script],
                    env=environment, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)
                if expected == "--latest":
                    self.assertNotIn("--latest=false", result.stdout)

    def test_stable_release_rejects_version_suffix(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        step = workflow.split("      - name: Validate release request\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("          SOURCE_VERSION=", 1)[0])

        for version, prerelease, valid in (
            ("1.2.3", "false", True),
            ("1.2.3-rc.1", "false", False),
            ("1.2.3.4", "false", False),
            ("1.2.3-rc.1", "true", True),
        ):
            with self.subTest(version=version, prerelease=prerelease):
                environment = dict(os.environ, VERSION_INPUT=version,
                                   PRERELEASE_INPUT=prerelease,
                                   GITHUB_REF="refs/heads/main")
                result = subprocess.run(
                    ["bash", "-c", script], env=environment,
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode == 0, valid, result.stderr)
                if not valid:
                    self.assertIn("Stable releases require", result.stderr)

    def test_appcast_verifier_rejects_unsigned_or_mutable_update(self) -> None:
        version = "1.2.3"
        dmg_name = "Joy-Harness-v1.2.3-macOS-arm64.dmg"
        stable_url = (
            "https://github.com/nixihz/JoyHarness/releases/download/"
            f"v{version}/{dmg_name}"
        )
        xml = '''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:version>1.2.3</sparkle:version>
<enclosure url="{url}" sparkle:edSignature="signature" /></item></channel></rss>'''
        with tempfile.TemporaryDirectory() as directory:
            appcast = Path(directory) / "appcast.xml"
            for url, signed, valid in (
                (stable_url, True, True),
                (stable_url, False, False),
                ("https://github.com/nixihz/JoyHarness/releases/latest/download/" + dmg_name,
                 True, False),
            ):
                with self.subTest(url=url, signed=signed):
                    content = xml.format(url=url)
                    if not signed:
                        content = content.replace(' sparkle:edSignature="signature"', "")
                    appcast.write_text(content, encoding="utf-8")
                    result = subprocess.run(
                        ["python3", "scripts/verify_sparkle_appcast.py",
                         str(appcast), version, dmg_name],
                        cwd=ROOT, capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode == 0, valid, result.stderr)


if __name__ == "__main__":
    unittest.main()
