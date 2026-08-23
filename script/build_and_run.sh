#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentDeck"
BUNDLE_ID="tech.agentdeck.daemon"
MIN_SYSTEM_VERSION="13.0"
MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_BINARY="${APP_CONTENTS}/MacOS/${APP_NAME}"

pkill -x "${APP_NAME}" 2>/dev/null || true
cd "${PROJECT_ROOT}"
swift build -c debug --product "${APP_NAME}"
BUILT_DIR="$(swift build -c debug --show-bin-path)"
BUILT_BINARY="${BUILT_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BUILT_DIR}/AgentDeck_AgentDeck.bundle"

mkdir -p "${APP_CONTENTS}/MacOS"
cp "${BUILT_BINARY}" "${APP_BINARY}"
chmod +x "${APP_BINARY}"
RESOURCE_BUNDLE="$(swift build -c debug --show-bin-path)/AgentDeck_AgentDeck.bundle"
mkdir -p "${APP_CONTENTS}/Resources"
/usr/bin/ditto "${RESOURCE_BUNDLE}/" "${APP_CONTENTS}/Resources/"
/usr/bin/ditto "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/AgentDeck_AgentDeck.bundle"

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
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>AgentDeck records while the controller Menu button is held and sends the audio to the selected Codex task.</string>
</dict>
</plist>
PLIST

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
    pgrep -x "${APP_NAME}" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
