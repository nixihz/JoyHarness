#!/usr/bin/env bash
set -euo pipefail
# Opt-in integration check: requires the v4 HAL component installed and idle.
# Flushes only the Xiaomi device; never captures audio or changes defaults.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-hal-host.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror \
  "${ROOT}/tests/test_microphone_hal_host.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "${TEST_DIR}/hal-host-test"
"${TEST_DIR}/hal-host-test"
