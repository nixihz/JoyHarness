#!/usr/bin/env python3
"""Verify packaged architectures, voice permissions, and relocated resources."""
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
DUALSENSE_BINARIES = (
    'Contents/Library/LaunchServices/ds5audiod',
    'Contents/PlugIns/DualSenseAudio.driver/Contents/MacOS/DualSenseAudio',
)

def required_binaries(app: Path):
    helper = app / DUALSENSE_BINARIES[0]
    return REQUIRED_BINARIES + (DUALSENSE_BINARIES if helper.exists() else ())

APPCAST_NAMES = {'arm64': 'appcast.xml', 'x86_64': 'appcast-x86_64.xml'}
VOICE_USAGE_KEYS = ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription')
AUDIO_INPUT_ENTITLEMENT = 'com.apple.security.device.audio-input'


def signed_entitlements(binary: Path) -> dict:
    result = subprocess.run(
        ['codesign', '-d', '--entitlements', '-', '--xml', str(binary)], capture_output=True,
    )
    if result.returncode != 0:
        raise ValueError(f'Cannot inspect signed entitlements: {binary}\n'
                         + result.stderr.decode('utf-8', errors='replace').strip())
    if not result.stdout.strip():
        return {}
    entitlements = plistlib.loads(result.stdout)
    if not isinstance(entitlements, dict):
        raise ValueError(f'Invalid signed entitlements: {binary}')
    return entitlements


def verify_voice_permissions(app: Path) -> None:
    with (app / 'Contents/Info.plist').open('rb') as stream:
        metadata = plistlib.load(stream)
    for key in VOICE_USAGE_KEYS:
        value = metadata.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f'Packaged app is missing voice permission description: {key}')
    main_binary = app / REQUIRED_BINARIES[0]
    if signed_entitlements(main_binary).get(AUDIO_INPUT_ENTITLEMENT) is not True:
        raise ValueError('Packaged app is missing the signed audio-input entitlement')
    for relative_path in required_binaries(app)[1:]:
        if signed_entitlements(app / relative_path).get(AUDIO_INPUT_ENTITLEMENT):
            raise ValueError(f'App audio-input entitlement leaked to nested code: {relative_path}')
    print('Packaged voice permissions verified: microphone, on-device speech, app-only audio input')


def verify_architecture(app: Path, arch: str) -> None:
    if arch not in APPCAST_NAMES:
        raise ValueError(f'unsupported macOS architecture: {arch}')
    if arch == "arm64" and not (app / DUALSENSE_BINARIES[0]).is_file():
        raise ValueError("Packaged DualSense helper is missing")
    for relative_path in required_binaries(app):
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
    print(f'Packaged architectures verified: {arch} ({len(required_binaries(app))} binaries)')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--arch', choices=tuple(APPCAST_NAMES), default=platform.machine())
    args = parser.parse_args()
    try:
        verify_architecture(args.app, args.arch)
        verify_voice_permissions(args.app)
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
