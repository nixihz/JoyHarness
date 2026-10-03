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

FRAMEWORK_DEST="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
rm -rf "${FRAMEWORK_DEST}"
/usr/bin/ditto "${FRAMEWORK_SOURCE}" "${FRAMEWORK_DEST}"
# The app binary is built for the host architecture only, so keep just that
# slice of the universal framework. Headers and module maps are build-time only.
ARCH="$(uname -m)"
while IFS= read -r -d '' binary; do
  if lipo "${binary}" -verify_arch "${ARCH}" 2>/dev/null && [[ "$(lipo -archs "${binary}")" != "${ARCH}" ]]; then
    lipo "${binary}" -thin "${ARCH}" -output "${binary}"
  fi
done < <(find "${FRAMEWORK_DEST}/Versions" -type f -perm -u+x -print0)
rm -rf "${FRAMEWORK_DEST}/Headers" "${FRAMEWORK_DEST}/PrivateHeaders" "${FRAMEWORK_DEST}/Modules" \
  "${FRAMEWORK_DEST}/Versions/B/Headers" "${FRAMEWORK_DEST}/Versions/B/PrivateHeaders" "${FRAMEWORK_DEST}/Versions/B/Modules"
