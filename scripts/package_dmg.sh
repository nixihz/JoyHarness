#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_VERSION="$(tr -d '[:space:]' < "${ROOT}/Sources/JoyHarness/Resources/VERSION")"
VERSION_INPUT="${1:-${DEFAULT_VERSION}}"
VERSION="${VERSION_INPUT#v}"
APP_NAME="Joy Harness"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT}/Sources/JoyHarness/Info.plist")"
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64) APPCAST_NAME="appcast.xml" ;;
  x86_64) APPCAST_NAME="appcast-x86_64.xml" ;;
  *) echo "unsupported macOS architecture: ${ARCH} (expected arm64 or x86_64)" >&2; exit 2 ;;
esac
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
# Release builds keep local symbols for debugging; the shipped binary does not need them.
strip -x "${APP_BUNDLE}/Contents/MacOS/JoyHarness"
/usr/bin/ditto "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/JoyHarness_JoyHarness.bundle"
install -m 644 "${ROOT}/Sources/JoyHarness/Resources/JoyHarness.icns" "${APP_BUNDLE}/Contents/Resources/JoyHarness.icns"
"${ROOT}/scripts/embed_sparkle.sh" "${APP_BUNDLE}"
"${ROOT}/scripts/build_microphone_driver.sh" "${WORK_DIR}/microphone" distribution
mkdir -p "${APP_BUNDLE}/Contents/PlugIns"
/usr/bin/ditto "${WORK_DIR}/microphone/JoyHarnessMicrophone.driver" "${APP_BUNDLE}/Contents/PlugIns/JoyHarnessMicrophone.driver"
"${ROOT}/scripts/embed_dualsense_audio.sh" "${APP_BUNDLE}" distribution

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
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>连接手柄及小米遥控器内置麦克风，在用户明确开启供音或按住语音键时接收声音。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>用于按住 L2 并点按 PS 后录制 AI 语音指令，以及通过遥控器麦克风传送声音。AI 录音松开 L2 后处理，取消则丢弃。也用于在用户明确开启后，把 DualSense 的声音作为系统麦克风提供给 Codex 等应用；停止供音不会撤回外部应用已接收的声音。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>在设备上将 AI 语音指令转换为文字；本地识别不可用时不会自动上传到云端。</string>
</dict>
</plist>
PLIST

if [[ "${JOY_HARNESS_ENABLE_SPARKLE:-0}" == "1" ]]; then
  if [[ "${JOY_HARNESS_SIGNING_IDENTITY:-}" != "Developer ID Application:"* ]]; then
    echo "Sparkle releases require a Developer ID Application identity" >&2
    exit 1
  fi
  PUBLIC_KEY_FILE="${ROOT}/config/sparkle-public-key.txt"
  if [[ ! -s "${PUBLIC_KEY_FILE}" ]]; then
    echo "Sparkle public key is missing: ${PUBLIC_KEY_FILE}" >&2
    exit 1
  fi
  PUBLIC_KEY="$(tr -d '[:space:]' < "${PUBLIC_KEY_FILE}")"
  /usr/libexec/PlistBuddy -c 'Add :JoyHarnessUpdaterEnabled bool true' "${APP_BUNDLE}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/nixihz/JoyHarness/releases/latest/download/${APPCAST_NAME}" "${APP_BUNDLE}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${PUBLIC_KEY}" "${APP_BUNDLE}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUAllowsAutomaticUpdates bool false' "${APP_BUNDLE}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "${APP_BUNDLE}/Contents/Info.plist"
fi

"${ROOT}/scripts/sign_macos_app.sh" "${APP_BUNDLE}" "${BUNDLE_ID}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
plutil -lint "${APP_BUNDLE}/Contents/Info.plist"
python3 "${ROOT}/scripts/verify_packaged_app.py" "${APP_BUNDLE}" --arch "${ARCH}"

mkdir -p "${DMG_ROOT}"
/usr/bin/ditto "${APP_BUNDLE}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

rm -f "${DMG_PATH}" "${CHECKSUM_PATH}"
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format ULMO \
  "${DMG_PATH}"

if [[ "${JOY_HARNESS_SIGNING_IDENTITY:-}" == "Developer ID Application:"* ]]; then
  echo "==> Signing ${DMG_PATH} with ${JOY_HARNESS_SIGNING_IDENTITY}"
  codesign --force --sign "${JOY_HARNESS_SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"
  codesign --verify --verbose=2 "${DMG_PATH}"
fi

hdiutil verify "${DMG_PATH}"

(
  cd "${DIST_DIR}"
  shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo "==> Created ${DMG_PATH}"
echo "==> Checksum ${CHECKSUM_PATH}"
