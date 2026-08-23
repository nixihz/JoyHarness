#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_INPUT="${1:-0.1.0}"
VERSION="${VERSION_INPUT#v}"
APP_NAME="Joy Harness"
BUNDLE_ID="tech.joyharness.daemon"
ARCH="$(uname -m)"
DIST_DIR="${ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="Joy-Harness-v${VERSION}-macOS-${ARCH}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joy-harness-package.XXXXXX")"
DMG_ROOT="${WORK_DIR}/dmg-root"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid version: ${VERSION_INPUT} (expected 1.2.3 or v1.2.3)" >&2
  exit 2
fi

echo "==> Building Joy Harness ${VERSION} for ${ARCH}"
cd "${ROOT}"
swift build -c release --product JoyHarness
BUILT_DIR="$(swift build -c release --show-bin-path)"
BUILT_BINARY="${BUILT_DIR}/JoyHarness"
RESOURCE_BUNDLE="${BUILT_DIR}/JoyHarness_JoyHarness.bundle"

if [[ ! -x "${BUILT_BINARY}" || ! -d "${RESOURCE_BUNDLE}" ]]; then
  echo "release build is missing its binary or resource bundle" >&2
  exit 1
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
install -m 755 "${BUILT_BINARY}" "${APP_BUNDLE}/Contents/MacOS/JoyHarness"
/usr/bin/ditto "${RESOURCE_BUNDLE}/" "${APP_BUNDLE}/Contents/Resources/"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>JoyHarness</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>JoyHarness.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

"${ROOT}/scripts/sign_macos_app.sh" "${APP_BUNDLE}" "${BUNDLE_ID}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
plutil -lint "${APP_BUNDLE}/Contents/Info.plist"

mkdir -p "${DMG_ROOT}"
/usr/bin/ditto "${APP_BUNDLE}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

rm -f "${DMG_PATH}" "${CHECKSUM_PATH}"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"

(
  cd "${DIST_DIR}"
  shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo "==> Created ${DMG_PATH}"
echo "==> Checksum ${CHECKSUM_PATH}"
