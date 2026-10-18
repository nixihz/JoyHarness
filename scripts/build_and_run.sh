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
APP_BUNDLE="/Applications/${DISPLAY_NAME}.app"
LEGACY_USER_APP_BUNDLE="${HOME}/.agent-deck/${DISPLAY_NAME}.app"
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
"${PROJECT_ROOT}/scripts/embed_sparkle.sh" "${STAGED_APP_BUNDLE}"
"${PROJECT_ROOT}/scripts/build_microphone_driver.sh" "${STAGE_ROOT}/microphone" local
mkdir -p "${STAGED_CONTENTS}/PlugIns"
/usr/bin/ditto "${STAGE_ROOT}/microphone/JoyHarnessMicrophone.driver" "${STAGED_CONTENTS}/PlugIns/JoyHarnessMicrophone.driver"
"${PROJECT_ROOT}/scripts/embed_dualsense_audio.sh" "${STAGED_APP_BUNDLE}" local

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
  <string>连接手柄及小米遥控器内置麦克风，在用户明确开启供音或按住语音键时接收声音。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>用于按住 L2 并点按 PS 后录制 AI 语音指令，以及通过遥控器麦克风传送声音。AI 录音松开 L2 后处理，取消则丢弃。也用于在用户明确开启后，把 DualSense 的声音作为系统麦克风提供给 Codex 等应用；停止供音不会撤回外部应用已接收的声音。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>在设备上将 AI 语音指令转换为文字；本地识别不可用时不会自动上传到云端。</string>
</dict>
</plist>
PLIST

"${PROJECT_ROOT}/scripts/sign_macos_app.sh" "${STAGED_APP_BUNDLE}" "${BUNDLE_ID}" local
python3 "${PROJECT_ROOT}/scripts/verify_packaged_app.py" "${STAGED_APP_BUNDLE}"
"${PROJECT_ROOT}/scripts/stop_joy_harness_instances.sh"
PREVIOUS_APP_BUNDLE="${STAGE_ROOT}/Previous ${DISPLAY_NAME}.app"
FAILED_APP_BUNDLE="${STAGE_ROOT}/Failed ${DISPLAY_NAME}.app"
if [[ -e "${APP_BUNDLE}" ]]; then
  mv "${APP_BUNDLE}" "${PREVIOUS_APP_BUNDLE}"
fi
if ! mv "${STAGED_APP_BUNDLE}" "${APP_BUNDLE}"; then
  [[ ! -e "${PREVIOUS_APP_BUNDLE}" ]] || mv "${PREVIOUS_APP_BUNDLE}" "${APP_BUNDLE}"
  exit 1
fi
if ! codesign --verify --deep --strict "${APP_BUNDLE}"; then
  mv "${APP_BUNDLE}" "${FAILED_APP_BUNDLE}"
  [[ ! -e "${PREVIOUS_APP_BUNDLE}" ]] || mv "${PREVIOUS_APP_BUNDLE}" "${APP_BUNDLE}"
  exit 1
fi
rm -rf "${LEGACY_USER_APP_BUNDLE}"
# Keep the canonical local app out of the quarantine path used by downloaded
# bundles. The path and designated requirement stay stable across test builds.
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo "==> Test app: ${APP_BUNDLE}"
echo "==> Bundle ID: ${BUNDLE_ID}"
codesign -dvvv "${APP_BUNDLE}" 2>&1 | awk -F= '/^Authority=|^TeamIdentifier=|^Identifier=/{print "==> " $0}'

open_app() {
  local launch_args=(-n --stdout "${HOME}/.agent-deck/runtime.log" --stderr "${HOME}/.agent-deck/runtime-error.log")
  local variable
  for variable in AGENT_DECK_RP2040_PORT AGENT_DECK_SOCK JOY_HARNESS_REMOTE_TRACE JOY_HARNESS_DUALSENSE_MIC_PREVIEW; do
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
