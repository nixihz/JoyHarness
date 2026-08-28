import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ReleaseAutomationTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
