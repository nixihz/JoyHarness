#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ROOT}/Sources/JoyHarness/Resources/Brand/joy-harness-logo-concept-v5.png"
OUTPUT="${ROOT}/Sources/JoyHarness/Resources/JoyHarness.icns"
WORK_DIR="$(mktemp -d)"
ICONSET="${WORK_DIR}/JoyHarness.iconset"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${ICONSET}"

make_icon() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -z "${size}" "${size}" "${SOURCE}" --out "${ICONSET}/${name}" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "${ICONSET}" -o "${OUTPUT}"
echo "generated ${OUTPUT}"
