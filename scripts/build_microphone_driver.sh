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
