#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_SDK_PATH="${HOME}/.agent-deck/toolchains/pico-sdk"
LEGACY_SDK_PATH="${HOME}/.codex-pad/toolchains/pico-sdk"
if [[ -z "${PICO_SDK_PATH:-}" && ! -f "${DEFAULT_SDK_PATH}/external/pico_sdk_import.cmake" && -f "${LEGACY_SDK_PATH}/external/pico_sdk_import.cmake" ]]; then
  SDK_PATH="${LEGACY_SDK_PATH}"
else
  SDK_PATH="${PICO_SDK_PATH:-${DEFAULT_SDK_PATH}}"
fi
BUILD_DIR="${ROOT}/firmware/rp2040/build"
for prefix in /opt/homebrew/opt /usr/local/opt; do
  if [[ -x "${prefix}/arm-none-eabi-gcc@9/bin/arm-none-eabi-gcc" ]]; then
    export PATH="${prefix}/arm-none-eabi-gcc@9/bin:${PATH}"
    break
  fi
done
for prefix in /opt/homebrew/opt /usr/local/opt; do
  if [[ -d "${prefix}/arm-none-eabi-binutils/bin" ]]; then
    export PATH="${prefix}/arm-none-eabi-binutils/bin:${PATH}"
    break
  fi
done

for command in cmake arm-none-eabi-gcc; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "missing ${command}; install with: brew install cmake arm-none-eabi-gcc" >&2
    exit 1
  fi
done

if [[ ! -f "${SDK_PATH}/external/pico_sdk_import.cmake" ]]; then
  mkdir -p "$(dirname "${SDK_PATH}")"
  git clone --depth 1 --branch 2.2.0 https://github.com/raspberrypi/pico-sdk.git "${SDK_PATH}"
  git -C "${SDK_PATH}" submodule update --init --depth 1 lib/tinyusb
fi

cmake -S "${ROOT}/firmware/rp2040" -B "${BUILD_DIR}" -G Ninja \
  -DPICO_SDK_PATH="${SDK_PATH}" \
  -DPICO_BOARD="${PICO_BOARD:-pico}"
cmake --build "${BUILD_DIR}" --parallel

echo "firmware: ${BUILD_DIR}/agentdeck_rp2040.uf2"
