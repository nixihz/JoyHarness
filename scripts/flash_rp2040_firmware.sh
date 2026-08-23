#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UF2="${ROOT}/firmware/rp2040/build/joy_harness_rp2040.uf2"
VOLUME="/Volumes/RPI-RP2"

if [[ ! -f "${UF2}" ]]; then
  "${ROOT}/scripts/build_rp2040_firmware.sh"
fi
if [[ ! -d "${VOLUME}" ]]; then
  echo "RPI-RP2 not found. Hold BOOTSEL while connecting the RP2040, then retry." >&2
  exit 1
fi

cp "${UF2}" "${VOLUME}/"
echo "flashed ${UF2}; the RP2040 will reboot automatically"
