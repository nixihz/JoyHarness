import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class LaunchAgentMigrationTests(unittest.TestCase):
    def test_install_migrates_agentdeck_service_to_joy_harness(self) -> None:
        script = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")

        self.assertIn("tech.joyharness.daemon.plist", script)
        self.assertIn("<string>tech.joyharness.daemon</string>", script)
        self.assertIn('tech.agentdeck.daemon"', script)
        self.assertIn('pkill -x "JoyHarness"', script)
        self.assertIn('pkill -x "AgentDeck"', script)

    def test_development_run_unloads_installed_daemons(self) -> None:
        script = (ROOT / "script" / "build_and_run.sh").read_text(encoding="utf-8")

        self.assertIn(
            "for service in tech.joyharness.daemon tech.agentdeck.daemon "
            "tech.codexpad.daemon; do",
            script,
        )


if __name__ == "__main__":
    unittest.main()
