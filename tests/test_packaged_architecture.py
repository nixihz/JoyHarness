import importlib.util
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_packaged_app", ROOT / "scripts/verify_packaged_app.py",
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)

# A real distribution contains these entry points, including the updater's
# separately launched helpers and the CoreAudio plug-in.
FIXTURE_BINARIES = (
    "Contents/MacOS/JoyHarness",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    "Contents/PlugIns/JoyHarnessMicrophone.driver/Contents/MacOS/JoyHarnessMicrophone",
)


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Mach-O tools")
class PackagedArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build_directory = tempfile.TemporaryDirectory()
        cls.build_root = Path(cls.build_directory.name)
        source = cls.build_root / "main.c"
        source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        for arch in ("arm64", "x86_64"):
            subprocess.run(
                ["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=13.0",
                 str(source), "-o", str(cls.build_root / arch)],
                check=True, capture_output=True, text=True,
            )
        subprocess.run(
            ["lipo", "-create", str(cls.build_root / "arm64"),
             str(cls.build_root / "x86_64"), "-output", str(cls.build_root / "universal")],
            check=True, capture_output=True, text=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.build_directory.cleanup()

    def make_app(self, root: Path, arch: str) -> Path:
        app = root / "Joy Harness.app"
        for relative_path in FIXTURE_BINARIES:
            destination = app / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.build_root / "universal", destination)
        feed_name = "appcast.xml" if arch == "arm64" else "appcast-x86_64.xml"
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({
                "JoyHarnessUpdaterEnabled": True,
                "SUFeedURL": f"https://github.com/nixihz/JoyHarness/releases/latest/download/{feed_name}",
            }, stream)
        return app

    def test_accepts_all_binaries_with_target_architecture(self) -> None:
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                app = self.make_app(Path(directory), arch)
                VERIFIER.verify_architecture(app, arch)
                for relative_path in FIXTURE_BINARIES:
                    shutil.copy2(self.build_root / arch, app / relative_path)
                VERIFIER.verify_architecture(app, arch)

    def test_rejects_wrong_architecture_in_each_required_binary(self) -> None:
        for arch, wrong_arch in (("arm64", "x86_64"), ("x86_64", "arm64")):
            for relative_path in FIXTURE_BINARIES:
                with self.subTest(arch=arch, binary=relative_path), tempfile.TemporaryDirectory() as directory:
                    app = self.make_app(Path(directory), arch)
                    shutil.copy2(self.build_root / wrong_arch, app / relative_path)
                    with self.assertRaises(ValueError) as error:
                        VERIFIER.verify_architecture(app, arch)
                    self.assertIn(f"does not support {arch}", str(error.exception))
                    self.assertIn(relative_path, str(error.exception))

    def test_rejects_missing_driver_and_wrong_updater_feed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "arm64")
            with self.assertRaisesRegex(ValueError, "updater feed does not match x86_64"):
                VERIFIER.verify_architecture(app, "x86_64")
            driver = app / "Contents/PlugIns/JoyHarnessMicrophone.driver/Contents/MacOS/JoyHarnessMicrophone"
            driver.unlink()
            with self.assertRaisesRegex(ValueError, "Packaged binary is missing:.*JoyHarnessMicrophone"):
                VERIFIER.verify_architecture(app, "arm64")

    def run_embed(self, root: Path, arch: str, source_arch: str) -> subprocess.CompletedProcess:
        script = root / "scripts/embed_sparkle.sh"
        script.parent.mkdir()
        shutil.copy2(ROOT / "scripts/embed_sparkle.sh", script)
        framework = root / ".build/artifacts/sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        for relative_path in (
            "Versions/B/Sparkle", "Versions/B/Autoupdate",
            "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
        ):
            destination = framework / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.build_root / source_arch, destination)
        commands = root / "commands"
        commands.mkdir()
        uname = commands / "uname"
        uname.write_text(f"#!/bin/sh\nprintf '%s\\n' '{arch}'\n", encoding="utf-8")
        uname.chmod(0o755)
        environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}")
        return subprocess.run(
            [str(script), str(root / "Joy Harness.app")], env=environment,
            capture_output=True, text=True,
        )

    def test_embed_thins_framework_and_helpers_for_both_hosts(self) -> None:
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                result = self.run_embed(root, arch, "universal")
                self.assertEqual(result.returncode, 0, result.stderr)
                framework = root / "Joy Harness.app/Contents/Frameworks/Sparkle.framework"
                binaries = [path for path in framework.rglob("*") if path.is_file()]
                self.assertEqual(len(binaries), 3)
                for binary in binaries:
                    actual = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
                    self.assertEqual(actual, arch, str(binary))

    def test_embed_rejects_framework_without_target_slice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_embed(Path(directory), "x86_64", "arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Sparkle binary does not support x86_64", result.stderr)

    def test_embed_rejects_unsupported_host_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_embed(Path(directory), "i386", "arm64")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unsupported macOS architecture: i386", result.stderr)


if __name__ == "__main__":
    unittest.main()
