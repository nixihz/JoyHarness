#!/usr/bin/env bash
set -euo pipefail

APP_NAME="JoyHarness"
DISPLAY_NAME="Joy Harness"
MIN_SYSTEM_VERSION="13.0"
MODE="${1:-run}"
case "${MODE}" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PROJECT_ROOT}/Sources/JoyHarness/Info.plist")"
VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/Sources/JoyHarness/Resources/VERSION")"
APP_BUNDLE="${HOME}/.agent-deck/${DISPLAY_NAME}.app"
APP_CONTENTS="${APP_BUNDLE}/Contents"
APP_BINARY="${APP_CONTENTS}/MacOS/${APP_NAME}"
STAGE_ROOT=""
cleanup() {
  if [[ -n "${STAGE_ROOT}" ]]; then
    rm -rf "${STAGE_ROOT}"
  fi
}
trap cleanup EXIT

cd "${PROJECT_ROOT}"
swift build -c debug --product "${APP_NAME}"
BUILT_DIR="$(swift build -c debug --show-bin-path)"
BUILT_BINARY="${BUILT_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BUILT_DIR}/JoyHarness_JoyHarness.bundle"

mkdir -p "${HOME}/.agent-deck"
STAGE_ROOT="$(mktemp -d "${HOME}/.agent-deck/.JoyHarness-build.XXXXXX")"
STAGED_APP_BUNDLE="${STAGE_ROOT}/${DISPLAY_NAME}.app"
STAGED_CONTENTS="${STAGED_APP_BUNDLE}/Contents"
STAGED_BINARY="${STAGED_CONTENTS}/MacOS/${APP_NAME}"
mkdir -p "${STAGED_CONTENTS}/MacOS" "${STAGED_CONTENTS}/Resources"
cp "${BUILT_BINARY}" "${STAGED_BINARY}"
chmod +x "${STAGED_BINARY}"
/usr/bin/ditto "${RESOURCE_BUNDLE}" "${STAGED_CONTENTS}/Resources/JoyHarness_JoyHarness.bundle"
install -m 644 "${PROJECT_ROOT}/Sources/JoyHarness/Resources/JoyHarness.icns" "${STAGED_CONTENTS}/Resources/JoyHarness.icns"
"${PROJECT_ROOT}/scripts/build_microphone_driver.sh" "${STAGE_ROOT}/microphone" local
mkdir -p "${STAGED_CONTENTS}/PlugIns"
/usr/bin/ditto "${STAGE_ROOT}/microphone/JoyHarnessMicrophone.driver" "${STAGED_CONTENTS}/PlugIns/JoyHarnessMicrophone.driver"

cat > "${STAGED_CONTENTS}/Info.plist" <<PLIST
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
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>连接小米遥控器内置麦克风，在按住语音键时接收声音。</string>
</dict>
</plist>
PLIST

"${PROJECT_ROOT}/scripts/sign_macos_app.sh" "${STAGED_APP_BUNDLE}" "${BUNDLE_ID}" local
"${PROJECT_ROOT}/scripts/stop_joy_harness_instances.sh"
mkdir -p "${APP_CONTENTS}"
/usr/bin/rsync -a --delete "${STAGED_CONTENTS}/" "${APP_CONTENTS}/"
codesign --verify --deep --strict "${APP_BUNDLE}"
# Keep the canonical local app out of the quarantine path used by downloaded
# bundles. The path and designated requirement stay stable across test builds.
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo "==> Test app: ${APP_BUNDLE}"
echo "==> Bundle ID: ${BUNDLE_ID}"
codesign -dvvv "${APP_BUNDLE}" 2>&1 | awk -F= '/^Authority=|^TeamIdentifier=|^Identifier=/{print "==> " $0}'

open_app() {
  local launch_args=(-n --stdout "${HOME}/.agent-deck/runtime.log" --stderr "${HOME}/.agent-deck/runtime-error.log")
  local variable
  for variable in AGENT_DECK_RP2040_PORT AGENT_DECK_SOCK JOY_HARNESS_REMOTE_TRACE; do
    if [[ -n "${!variable:-}" ]]; then
      launch_args+=(--env "${variable}=${!variable}")
    fi
  done
  /usr/bin/open "${launch_args[@]}" "${APP_BUNDLE}"
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
    tail -F "${HOME}/.agent-deck/runtime.log" "${HOME}/.agent-deck/runtime-error.log"
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
