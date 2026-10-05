#!/usr/bin/env python3
"""Pin release source and reject unsafe new releases or architecture backfills."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


RUNNERS = {"arm64": "macos-26", "x86_64": "macos-26-intel"}


def command(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def release_api(path: str) -> dict | None:
    result = subprocess.run(
        ["gh", "api", f"repos/{os.environ['GITHUB_REPOSITORY']}/releases/{path}"],
        capture_output=True, text=True,
    )
    if result.returncode:
        if "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def feed_name(arch: str) -> str:
    return "appcast.xml" if arch == "arm64" else "appcast-x86_64.xml"


def validate_backfill(release: dict | None, latest: dict | None,
                      version: str, arch: str) -> None:
    if not release or release["draft"] or release["prerelease"]:
        raise ValueError("Backfill requires an existing published stable release")
    if not latest or latest["id"] != release["id"]:
        raise ValueError("Backfill is limited to the latest stable release")
    dmg = f"Joy-Harness-v{version}-macOS-{arch}.dmg"
    names = {asset["name"] for asset in release["assets"]}
    collisions = names.intersection({dmg, f"{dmg}.sha256", feed_name(arch)})
    if collisions:
        raise ValueError(f"Backfill would overwrite existing assets: {sorted(collisions)}")


def plan(version_input: str, prerelease: bool, backfill_arch: str) -> dict[str, str]:
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Releases must be dispatched from the main branch")
    version = version_input.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?", version):
        raise ValueError(f"Invalid version: {version_input}")
    if not prerelease and not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Stable releases require a version without a prerelease suffix")
    if backfill_arch not in ("none", *RUNNERS):
        raise ValueError(f"Unsupported backfill architecture: {backfill_arch}")
    tag = f"v{version}"
    release = release_api(f"tags/{tag}")
    tag_result = subprocess.run(
        ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
        capture_output=True, text=True,
    )
    if backfill_arch == "none":
        if tag_result.returncode == 0 or release:
            raise ValueError(f"Tag or Release already exists: {tag}")
        source_sha = os.environ["GITHUB_SHA"]
        arches = list(RUNNERS)
    else:
        if prerelease:
            raise ValueError("Backfill requires prerelease=false")
        validate_backfill(release, release_api("latest"), version, backfill_arch)
        if tag_result.returncode:
            raise ValueError(f"Published release tag is missing: {tag}")
        source_sha = tag_result.stdout.strip()
        arches = [backfill_arch]
    source_version = command("git", "show", f"{source_sha}:Sources/JoyHarness/Resources/VERSION")
    if source_version != version:
        raise ValueError(f"Release version {version} does not match source version {source_version}")
    matrix = {"include": [{"arch": arch, "runner": RUNNERS[arch]} for arch in arches]}
    return {
        "version": version, "tag": tag, "source_sha": source_sha,
        "matrix": json.dumps(matrix, separators=(",", ":")),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--prerelease", choices=("true", "false"), default="false")
    parser.add_argument("--backfill-arch", default="none")
    args = parser.parse_args()
    result = plan(args.version, args.prerelease == "true", args.backfill_arch)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        for key, value in result.items():
            output.write(f"{key}={value}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
