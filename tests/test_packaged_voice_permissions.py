import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_voice_packaging", ROOT / "scripts/verify_packaged_app.py",
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
MICROPHONE_KEY = "NSMicrophoneUsageDescription"
SPEECH_KEY = "NSSpeechRecognitionUsageDescription"
AUDIO_ENTITLEMENT = "com.apple.security.device.audio-input"


class VoicePackagingContractTests(unittest.TestCase):
    def test_every_packaging_route_has_parseable_microphone_and_speech_descriptions(self) -> None:
        metadata = [plistlib.loads((ROOT / "Sources/JoyHarness/Info.plist").read_bytes())]
        for script_name in ("build_and_run.sh", "install.sh", "package_dmg.sh"):
            script = (ROOT / "scripts" / script_name).read_text(encoding="utf-8")
            match = re.search(r"(<\?xml.*?</plist>)", script, flags=re.DOTALL)
            self.assertIsNotNone(match, script_name)
            metadata.append(plistlib.loads(match.group(1).encode("utf-8")))
        for plist in metadata:
            for key in (MICROPHONE_KEY, SPEECH_KEY):
                self.assertIsInstance(plist.get(key), str)
                self.assertTrue(plist[key].strip())
                self.assertEqual(plist[key], metadata[0][key])

    def test_signing_passes_voice_entitlement_only_to_outer_app(self) -> None:
        # Exercise the real shell argument construction without requiring a
        # signing certificate or modifying any installed app.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Fixture.app"
            (app / "Contents/Frameworks/Sparkle.framework").mkdir(parents=True)
            commands = root / "commands"
            commands.mkdir()
            log = root / "codesign.jsonl"
            codesign = commands / "codesign"
            codesign.write_text(
                f"#!{sys.executable}\nimport json, os, sys\n"
                "with open(os.environ['JOY_TEST_CODESIGN_LOG'], 'a') as stream:\n"
                "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n",
                encoding="utf-8",
            )
            codesign.chmod(0o755)
            environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                               JOY_HARNESS_SIGNING_IDENTITY="-", JOY_TEST_CODESIGN_LOG=str(log))
            subprocess.run([str(ROOT / "scripts/sign_macos_app.sh"), str(app), "test.fixture"],
                           env=environment, check=True, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            signed = [call for call in calls if "--sign" in call]
            self.assertEqual(len(signed), 6)  # five Sparkle entries plus the app
            for call in signed:
                if call[-1] == str(app):
                    flag = call.index("--entitlements")
                    entitlements = plistlib.loads(Path(call[flag + 1]).read_bytes())
                    self.assertEqual(entitlements, {AUDIO_ENTITLEMENT: True})
                else:
                    self.assertNotIn("--entitlements", call)
            log.write_text("")
            driver = root / "Fixture.driver"
            driver.mkdir()
            subprocess.run([str(ROOT / "scripts/sign_macos_app.sh"), str(driver), "test.fixture.driver"],
                           env=environment, check=True, capture_output=True, text=True)
            driver_calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertTrue(any("--sign" in call for call in driver_calls))
            self.assertTrue(all("--entitlements" not in call for call in driver_calls))


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS codesign and Mach-O tools")
class SignedVoicePermissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build_directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.build_directory.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        cls.binary = cls.root / "Fixture"
        subprocess.run(["xcrun", "clang", str(source), "-o", str(cls.binary)],
                       check=True, capture_output=True, text=True)
        cls.entitlements = cls.root / "voice.plist"
        cls.entitlements.write_bytes(plistlib.dumps({AUDIO_ENTITLEMENT: True}))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build_directory.cleanup()

    def sign(self, binary: Path, *, microphone: bool) -> None:
        arguments = ["codesign", "--force", "--sign", "-"]
        if microphone:
            arguments.extend(["--entitlements", str(self.entitlements)])
        subprocess.run(arguments + [str(binary)], check=True, capture_output=True, text=True)

    def make_app(self, root: Path, *, microphone: bool = True) -> Path:
        app = root / "Fixture.app"
        for index, relative in enumerate(VERIFIER.REQUIRED_BINARIES + VERIFIER.DUALSENSE_BINARIES):
            destination = app / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.binary, destination)
            self.sign(destination, microphone=microphone and index == 0)
        metadata = {MICROPHONE_KEY: "录制本次命令", SPEECH_KEY: "在设备上识别指令"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        return app

    def test_accepts_real_signed_main_binary_with_unprivileged_helpers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            VERIFIER.verify_voice_permissions(app)

    def test_rejects_missing_or_blank_privacy_description_before_launch(self) -> None:
        for key, invalid in ((MICROPHONE_KEY, None), (SPEECH_KEY, "   "), (SPEECH_KEY, True)):
            with self.subTest(key=key, invalid=invalid), tempfile.TemporaryDirectory() as directory:
                app = self.make_app(Path(directory))
                metadata = {MICROPHONE_KEY: "录音", SPEECH_KEY: "识别", key: invalid}
                if invalid is None:
                    del metadata[key]
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
                with self.assertRaisesRegex(ValueError, key):
                    VERIFIER.verify_voice_permissions(app)

    def test_rejects_unsigned_audio_access_even_when_plist_describes_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), microphone=False)
            with self.assertRaisesRegex(ValueError, "missing the signed audio-input entitlement"):
                VERIFIER.verify_voice_permissions(app)

    def test_rejects_accidental_audio_entitlement_on_each_nested_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            for relative in VERIFIER.REQUIRED_BINARIES[1:] + VERIFIER.DUALSENSE_BINARIES:
                with self.subTest(binary=relative):
                    binary = app / relative
                    self.sign(binary, microphone=True)
                    with self.assertRaisesRegex(ValueError, "leaked to nested code"):
                        VERIFIER.verify_voice_permissions(app)
                    self.sign(binary, microphone=False)


if __name__ == "__main__":
    unittest.main()
