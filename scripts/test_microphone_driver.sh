#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${ROOT}/.build/microphone-tests"
mkdir -p "${OUTPUT}"
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined \
  -Wno-unused-parameter -framework CoreAudio -framework CoreFoundation \
  "${ROOT}/tests/test_microphone_driver.c" -o "${OUTPUT}/test_microphone_driver"
"${OUTPUT}/test_microphone_driver"
