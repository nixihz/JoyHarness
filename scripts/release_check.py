#!/usr/bin/env python3

import argparse
import re
import sys
from pathlib import Path


SEMANTIC_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$")
FIRMWARE_PROTOCOL_VERSION = "0.1.0-agentdeck"
DMG_ASSIGNMENT = 'DMG_NAME="Joy-Harness-v${VERSION}-macOS-${ARCH}.dmg"'


def read(root: Path, relative_path: str) -> str:
    try:
        return (root / relative_path).read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"cannot read {relative_path}: {error}") from error


def validate(root: Path, tag: str | None) -> list[str]:
    errors: list[str] = []
    version = read(root, "Sources/JoyHarness/Resources/VERSION").strip()
    if not SEMANTIC_VERSION.fullmatch(version):
        errors.append(f"source version is not semantic: {version!r}")

    if tag is not None:
        if not re.fullmatch(r"v" + SEMANTIC_VERSION.pattern[1:-1], tag):
            errors.append(f"tag must have the form v1.2.3: {tag!r}")
        elif tag != f"v{version}":
            errors.append(f"tag {tag!r} does not match source version {version!r}")

    readme = read(root, "README.md")
    artifact = f"Joy-Harness-v{version}-macOS-arm64.dmg"
    download_line = (
        f"- [Download {artifact}]"
        f"(https://github.com/nixihz/JoyHarness/releases/download/v{version}/{artifact})"
    )
    checksum_line = (
        "- [Download the SHA-256 checksum]"
        f"(https://github.com/nixihz/JoyHarness/releases/download/v{version}/"
        f"{artifact}.sha256)"
    )
    if download_line not in readme:
        errors.append(f"README download artifact does not match {artifact}")
    if checksum_line not in readme:
        errors.append(f"README checksum artifact does not match {artifact}.sha256")

    swift_tests = read(root, "tests/JoyHarnessTests/JoyHarnessTests.swift")
    if f'#expect(AppVersion.current == "{version}")' not in swift_tests:
        errors.append("Swift AppVersion.current expectation does not match source version")
    if f'#expect(AppVersion.displayName == "Joy Harness v{version}")' not in swift_tests:
        errors.append("Swift AppVersion.displayName expectation does not match source version")

    for relative_path in ("scripts/package_dmg.sh", ".github/workflows/release.yml"):
        if DMG_ASSIGNMENT not in read(root, relative_path):
            errors.append(f"DMG naming is inconsistent in {relative_path}")

    firmware = read(root, "firmware/rp2040/src/main.c")
    protocol_versions = re.findall(r'\\"version\\":\\"([^"\\]+)\\"', firmware)
    if not protocol_versions or set(protocol_versions) != {FIRMWARE_PROTOCOL_VERSION}:
        errors.append(
            "firmware protocol version must consistently be "
            f"{FIRMWARE_PROTOCOL_VERSION!r}"
        )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Joy Harness release metadata")
    parser.add_argument("tag", nargs="?", help="optional release tag, for example v0.4.0")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args()

    try:
        errors = validate(arguments.root.resolve(), arguments.tag)
    except ValueError as error:
        errors = [str(error)]
    if errors:
        for error in errors:
            print(f"release-check: {error}", file=sys.stderr)
        return 1
    print("release-check: release metadata is consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
