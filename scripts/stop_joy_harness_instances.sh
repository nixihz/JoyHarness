#!/usr/bin/env bash
set -euo pipefail

PROCESS_PATTERN="${JOY_HARNESS_PROCESS_PATTERN:-/(Joy Harness|AgentDeck)\.app/Contents/MacOS/(JoyHarness|AgentDeck)$}"

matching_pids() {
  pgrep -f "${PROCESS_PATTERN}" 2>/dev/null || true
}

terminate_matching_processes() {
  local signal="$1"
  local pid
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] || continue
    kill "-${signal}" "${pid}" 2>/dev/null || true
  done < <(matching_pids)
}

wait_for_exit() {
  local attempts="$1"
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    [[ -z "$(matching_pids)" ]] && return 0
    sleep 0.1
  done
  return 1
}

terminate_matching_processes TERM
if ! wait_for_exit 30; then
  terminate_matching_processes KILL
  wait_for_exit 10 || {
    echo "failed to stop existing Joy Harness processes: $(matching_pids | tr '\n' ' ')" >&2
    exit 1
  }
fi
