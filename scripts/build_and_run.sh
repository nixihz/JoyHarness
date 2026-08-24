#!/usr/bin/env bash
set -euo pipefail

APP_NAME="JoyHarness"
DISPLAY_NAME="Joy Harness"
MIN_SYSTEM_VERSION="13.0"
MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PROJECT_ROOT}/Sources/JoyHarness/Info.plist")"
VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/Sources/JoyHarness/Resources/VERSION")"
APP_BUNDLE="${PROJECT_ROOT}/dist/${DISPLAY_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_BINARY="${APP_CONTENTS}/MacOS/${APP_NAME}"

"${PROJECT_ROOT}/scripts/stop_joy_harness_instances.sh"
cd "${PROJECT_ROOT}"
swift build -c debug --product "${APP_NAME}"
BUILT_DIR="$(swift build -c debug --show-bin-path)"
BUILT_BINARY="${BUILT_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BUILT_DIR}/JoyHarness_JoyHarness.bundle"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_CONTENTS}/MacOS"
cp "${BUILT_BINARY}" "${APP_BINARY}"
chmod +x "${APP_BINARY}"
RESOURCE_BUNDLE="$(swift build -c debug --show-bin-path)/JoyHarness_JoyHarness.bundle"
mkdir -p "${APP_CONTENTS}/Resources"
/usr/bin/ditto "${RESOURCE_BUNDLE}/" "${APP_CONTENTS}/Resources/"

cat > "${APP_CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${DISPLAY_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>JoyHarness.icns</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

"${PROJECT_ROOT}/scripts/sign_macos_app.sh" "${APP_BUNDLE}" "${BUNDLE_ID}"

open_app() {
  /usr/bin/open -n "${APP_BUNDLE}"
}

case "${MODE}" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "${APP_BINARY}"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"${APP_NAME}\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"${BUNDLE_ID}\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f -x "${APP_BINARY}" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
