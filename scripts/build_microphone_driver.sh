#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?usage: build_microphone_driver.sh <output-directory> [local|distribution]}"
SIGNING_MODE="${2:-local}"
DRIVER="${OUTPUT}/JoyHarnessMicrophone.driver"
mkdir -p "${DRIVER}/Contents/MacOS"
install -m 644 "${ROOT}/Drivers/JoyHarnessMicrophone/Info.plist" "${DRIVER}/Contents/Info.plist"
xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
  -mmacosx-version-min=13.0 -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  "${ROOT}/Drivers/JoyHarnessMicrophone/Driver.c" \
  -o "${DRIVER}/Contents/MacOS/JoyHarnessMicrophone"
"${ROOT}/scripts/sign_macos_app.sh" "${DRIVER}" tech.keli.joyharness.microphone "${SIGNING_MODE}"
PKGBUILD_ARGS=(
  --component "${DRIVER}"
  --scripts "${ROOT}/Drivers/JoyHarnessMicrophone/InstallerScripts"
  --install-location /Library/Audio/Plug-Ins/HAL
  --identifier tech.keli.joyharness.microphone.pkg --version 1.0.0
)
if [[ -n "${JOY_HARNESS_INSTALLER_SIGNING_IDENTITY:-}" ]]; then
  PKGBUILD_ARGS+=(--sign "${JOY_HARNESS_INSTALLER_SIGNING_IDENTITY}" --timestamp)
fi
/usr/bin/pkgbuild "${PKGBUILD_ARGS[@]}" \
  "${OUTPUT}/JoyHarnessMicrophone.pkg"
if [[ -n "${JOY_HARNESS_INSTALLER_SIGNING_IDENTITY:-}" ]]; then
  /usr/sbin/pkgutil --check-signature "${OUTPUT}/JoyHarnessMicrophone.pkg"
fi
