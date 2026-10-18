#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/joyharness-controls.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT
xcrun clang -std=c11 -fblocks -Wall -Wextra -Werror \
  "${ROOT}/tests/test_dualsense_controls.c" -o "${TEST_DIR}/controls-test"
"${TEST_DIR}/controls-test"
