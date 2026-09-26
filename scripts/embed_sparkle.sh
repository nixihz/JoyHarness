#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?usage: embed_sparkle.sh <app-bundle>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ROOT}/.build/artifacts"
FRAMEWORK_SOURCE="$(find "${ARTIFACTS}" -type d -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
if [[ -z "${FRAMEWORK_SOURCE}" ]]; then
  echo "Sparkle framework missing from SwiftPM artifacts; run swift build first" >&2
  exit 1
fi

mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
/usr/bin/ditto "${FRAMEWORK_SOURCE}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
