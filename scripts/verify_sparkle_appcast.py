#!/usr/bin/env python3
"""Validate the signed stable release entry before publishing its appcast."""

import argparse
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def verify(appcast: Path, version: str, dmg_name: str) -> None:
    root = ET.parse(appcast).getroot()
    if root.tag != "rss":
        raise ValueError("Sparkle appcast is not RSS")

    expected_url = (
        f"https://github.com/nixihz/JoyHarness/releases/download/v{version}/{dmg_name}"
    )
    matching = []
    for item in root.findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("appcast item is missing an enclosure")
        url = enclosure.get("url", "")
        if "/releases/latest/download/" in url:
            raise ValueError("appcast contains a mutable latest-release download URL")
        if urlparse(url).scheme != "https":
            raise ValueError(f"appcast contains a non-HTTPS download URL: {url}")
        if not enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature"):
            raise ValueError(f"appcast contains an unsigned update: {url}")
        item_version = item.findtext(f"{{{SPARKLE_NAMESPACE}}}version")
        if item_version is None:
            item_version = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}version")
        if item_version == version:
            matching.append(enclosure)

    if len(matching) != 1 or matching[0].get("url") != expected_url:
        raise ValueError(f"appcast lacks the expected release URL: {expected_url}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", type=Path)
    parser.add_argument("version")
    parser.add_argument("dmg_name")
    args = parser.parse_args()
    verify(args.appcast, args.version, args.dmg_name)
    print(f"Sparkle appcast verified for {args.version}")


if __name__ == "__main__":
    main()
