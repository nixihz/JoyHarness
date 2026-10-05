#!/usr/bin/env python3
"""Verify packaged Mach-O architectures and resource loading after relocation."""
import argparse
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile


SPARKLE_VERSION = 'Contents/Frameworks/Sparkle.framework/Versions/B'
REQUIRED_BINARIES = (
    'Contents/MacOS/JoyHarness',
    f'{SPARKLE_VERSION}/Sparkle',
    f'{SPARKLE_VERSION}/Autoupdate',
    f'{SPARKLE_VERSION}/Updater.app/Contents/MacOS/Updater',
    f'{SPARKLE_VERSION}/XPCServices/Installer.xpc/Contents/MacOS/Installer',
    f'{SPARKLE_VERSION}/XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
    'Contents/PlugIns/JoyHarnessMicrophone.driver/Contents/MacOS/JoyHarnessMicrophone',
)
APPCAST_NAMES = {'arm64': 'appcast.xml', 'x86_64': 'appcast-x86_64.xml'}


def verify_architecture(app: Path, arch: str) -> None:
    if arch not in APPCAST_NAMES:
        raise ValueError(f'unsupported macOS architecture: {arch}')
    for relative_path in REQUIRED_BINARIES:
        binary = app / relative_path
        if not binary.is_file():
            raise ValueError(f'Packaged binary is missing: {relative_path}')
        result = subprocess.run(
            ['lipo', str(binary), '-verify_arch', arch], capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise ValueError(f'Packaged binary does not support {arch}: {relative_path}\n{result.stderr.strip()}')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        metadata = plistlib.load(stream)
    if metadata.get('JoyHarnessUpdaterEnabled'):
        expected_feed = (
            'https://github.com/nixihz/JoyHarness/releases/latest/download/'
            + APPCAST_NAMES[arch]
        )
        if metadata.get('SUFeedURL') != expected_feed:
            raise ValueError(f'Packaged updater feed does not match {arch}: expected {expected_feed}')
    print(f'Packaged architectures verified: {arch} ({len(REQUIRED_BINARIES)} binaries)')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--arch', choices=tuple(APPCAST_NAMES), default=platform.machine())
    args = parser.parse_args()
    try:
        verify_architecture(args.app, args.arch)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error
    with tempfile.TemporaryDirectory(prefix='joy-harness-startup-') as directory:
        app = Path(directory) / args.app.name
        subprocess.run(['/usr/bin/ditto', str(args.app.resolve()), str(app)], check=True)
        result = subprocess.run(
            [str(app / 'Contents/MacOS/JoyHarness'), '--verify-bundle-resources',
             '-ApplePersistenceIgnoreState', 'YES'],
            capture_output=True, text=True, timeout=20,
        )
        if result.returncode != 0 or 'Packaged resources verified:' not in result.stdout:
            raise SystemExit(f'Packaged app startup check failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
        print(result.stdout.strip())


if __name__ == '__main__':
    main()
