#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BINARY="${PROJECT_ROOT}/dist/Joy Harness.app/Contents/MacOS/JoyHarness"
STATUS_PATH="${AGENT_DECK_STATUS_PATH:-${HOME}/.agent-deck/status.json}"
MIN_DELTA="${JOYCON_VERIFY_MIN_DELTA:-30}"
STICK_THRESHOLD="${JOYCON_VERIFY_STICK_THRESHOLD:-0.35}"
EDGE_MARGIN="${JOYCON_VERIFY_EDGE_MARGIN:-100}"

usage() {
  cat <<'USAGE'
usage: ./scripts/verify_joycon_pointer.sh <scenario>

scenarios:
  left-horizontal
  left-vertical
  right-horizontal
  right-vertical
  pair
  --self-test
USAGE
}

classify_direction() {
  local dx="$1" dy="$2" minimum="${3:-${MIN_DELTA}}"
  /usr/bin/awk -v dx="${dx}" -v dy="${dy}" -v minimum="${minimum}" '
    BEGIN {
      absoluteX = dx < 0 ? -dx : dx
      absoluteY = dy < 0 ? -dy : dy
      if (absoluteX < minimum && absoluteY < minimum) {
        print "none"
      } else if (absoluteX > absoluteY * 1.25) {
        print (dx > 0 ? "right" : "left")
      } else if (absoluteY > absoluteX * 1.25) {
        print (dy > 0 ? "up" : "down")
      } else {
        print "diagonal"
      }
    }
  '
}

direction_label() {
  case "$1" in
    up) printf '上' ;;
    right) printf '右' ;;
    down) printf '下' ;;
    left) printf '左' ;;
    none) printf '未移动' ;;
    diagonal) printf '斜向/无法判定' ;;
    *) printf '%s' "$1" ;;
  esac
}

mouse_sample() {
  # JavaScript interpolation must reach osascript unchanged.
  # shellcheck disable=SC2016
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    const point = $.NSEvent.mouseLocation;
    const screens = $.NSScreen.screens;
    let bounds = null;
    for (let index = 0; index < screens.count; index++) {
      const frame = screens.objectAtIndex(index).frame;
      const maxX = frame.origin.x + frame.size.width;
      const maxY = frame.origin.y + frame.size.height;
      if (point.x >= frame.origin.x && point.x <= maxX &&
          point.y >= frame.origin.y && point.y <= maxY) {
        bounds = `${frame.origin.x} ${frame.origin.y} ${maxX} ${maxY}`;
        break;
      }
    }
    if (bounds === null) {
      throw new Error("cursor is outside every screen");
    }
    `${point.x} ${point.y} ${bounds}`;
  '
}

status_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${STATUS_PATH}" 2>/dev/null || true
}

app_is_running() {
  /bin/ps -axo command= | /usr/bin/awk -v expected="${APP_BINARY}" '
    $0 == expected { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

refresh_status() {
  local request_note
  local attempts=0
  request_note="joycon-verify-$(/usr/bin/uuidgen)"
  if ! /usr/bin/python3 "${PROJECT_ROOT}/bin/joy-harness-send" \
      status --note "${request_note}" >/dev/null 2>&1; then
    return 1
  fi
  while [[ "${attempts}" -lt 20 ]]; do
    if [[ "$(status_value note)" == "${request_note}" ]]; then
      return 0
    fi
    /bin/sleep 0.05
    attempts=$((attempts + 1))
  done
  printf '等待 Joy Harness 状态快照超时。\n' >&2
  return 1
}

validate_runtime_state() {
  local active_mode active_orientation accessibility controller_name
  if ! app_is_running; then
    printf 'Joy Harness 新构建已停止。\n' >&2
    return 1
  fi
  if ! refresh_status; then
    printf '无法请求 Joy Harness 刷新状态。\n' >&2
    return 1
  fi
  active_mode="$(status_value joycon_mode)"
  active_orientation="$(status_value joycon_orientation)"
  accessibility="$(status_value accessibility)"
  controller_name="$(status_value controller)"
  if [[ "${active_mode}" != "${expected_mode}" ]]; then
    printf '当前控制器=%s，Joy-Con 模式=%s；需要模式=%s。\n' \
      "${controller_name:-none}" "${active_mode:-none}" "${expected_mode}" >&2
    return 1
  fi
  if [[ -n "${expected_orientation}" && "${active_orientation}" != "${expected_orientation}" ]]; then
    printf '当前握姿=%s；需要握姿=%s。请先在 Joy Harness 中切换。\n' \
      "${active_orientation:-none}" "${expected_orientation}" >&2
    return 1
  fi
  if [[ "${accessibility}" != "true" ]]; then
    printf 'Joy Harness 尚未获得辅助功能权限，无法验证鼠标移动。\n' >&2
    return 1
  fi
}

baseline_is_safe() {
  local x="$1" y="$2" min_x="$3" min_y="$4" max_x="$5" max_y="$6"
  /usr/bin/awk \
    -v x="${x}" -v y="${y}" -v minX="${min_x}" -v minY="${min_y}" \
    -v maxX="${max_x}" -v maxY="${max_y}" -v margin="${EDGE_MARGIN}" '
      BEGIN {
        safe = x - minX >= margin && maxX - x >= margin &&
          y - minY >= margin && maxY - y >= margin
        exit(safe ? 0 : 1)
      }
    '
}

run_self_test() {
  local failures=0 actual sample point_x point_y min_x min_y max_x max_y extra
  while read -r dx dy expected; do
    actual="$(classify_direction "${dx}" "${dy}" 30)"
    if [[ "${actual}" != "${expected}" ]]; then
      printf 'classifier mismatch: dx=%s dy=%s expected=%s actual=%s\n' \
        "${dx}" "${dy}" "${expected}" "${actual}" >&2
      failures=$((failures + 1))
    fi
  done <<'CASES'
0 100 up
100 0 right
0 -100 down
-100 0 left
10 10 none
100 100 diagonal
CASES
  while read -r dx dy expected; do
    actual="$(classify_direction "${dx}" "${dy}" 0.35)"
    if [[ "${actual}" != "${expected}" ]]; then
      printf 'stick classifier mismatch: x=%s y=%s expected=%s actual=%s\n' \
        "${dx}" "${dy}" "${expected}" "${actual}" >&2
      failures=$((failures + 1))
    fi
  done <<'STICK_CASES'
0 0.8 up
0.8 0 right
0 -0.8 down
-0.8 0 left
0.1 0.1 none
STICK_CASES
  sample="$(mouse_sample)"
  read -r point_x point_y min_x min_y max_x max_y extra <<<"${sample}"
  if [[ -z "${point_x}" || -z "${point_y}" || -z "${min_x}" || -z "${min_y}" ||
        -z "${max_x}" || -z "${max_y}" || -n "${extra:-}" ]]; then
    printf 'mouse sample probe returned an invalid value: %s\n' "${sample}" >&2
    failures=$((failures + 1))
  fi
  [[ "${failures}" -eq 0 ]]
  printf 'Joy-Con pointer verifier self-test passed.\n'
}

verify_direction() {
  local expected="$1" stick_name="$2"
  local before after before_x before_y after_x after_y min_x min_y max_x max_y
  local dx dy pointer_direction stick_x stick_y stick_direction extra

  if ! validate_runtime_state; then return 1; fi
  while true; do
    printf '\n[%s] 将鼠标放到当前屏幕中部，然后按 Enter。\n' "$(direction_label "${expected}")"
    if ! read -r _; then
      printf '输入已结束，无法继续实机验证。\n' >&2
      return 1
    fi
    if ! before="$(mouse_sample)"; then
      printf '无法读取鼠标起点。\n' >&2
      return 1
    fi
    if ! read -r before_x before_y min_x min_y max_x max_y extra <<<"${before}" ||
        [[ -z "${before_x}" || -z "${before_y}" || -z "${min_x}" || -z "${min_y}" ||
          -z "${max_x}" || -z "${max_y}" || -n "${extra:-}" ]]; then
      printf '鼠标起点格式无效：%s\n' "${before}" >&2
      return 1
    fi
    if baseline_is_safe "${before_x}" "${before_y}" "${min_x}" "${min_y}" "${max_x}" "${max_y}"; then
      break
    fi
    printf '鼠标距离当前屏幕边缘不足 %s 点，请移到更靠近中部的位置。\n' "${EDGE_MARGIN}"
  done

  printf '只把%s推向物理%s并保持不松，随后按 Enter；期间不要碰鼠标。\n' \
    "${stick_name}" "$(direction_label "${expected}")"
  if ! read -r _; then
    printf '输入已结束，无法采集 Joy-Con 方向。\n' >&2
    return 1
  fi
  if ! validate_runtime_state; then return 1; fi
  stick_x="$(status_value joycon_primary_stick.x)"
  stick_y="$(status_value joycon_primary_stick.y)"
  if [[ -z "${stick_x}" || -z "${stick_y}" ]]; then
    printf '状态快照缺少 Joy-Con primary stick。\n' >&2
    return 1
  fi
  if ! after="$(mouse_sample)"; then
    printf '无法读取鼠标终点。\n' >&2
    return 1
  fi
  extra=""
  if ! read -r after_x after_y min_x min_y max_x max_y extra <<<"${after}" ||
      [[ -z "${after_x}" || -z "${after_y}" || -z "${min_x}" || -z "${min_y}" ||
        -z "${max_x}" || -z "${max_y}" || -n "${extra:-}" ]]; then
    printf '鼠标终点格式无效：%s\n' "${after}" >&2
    return 1
  fi
  printf '已采样，现在可以松开摇杆。\n'

  read -r dx dy <<<"$(/usr/bin/awk \
    -v beforeX="${before_x}" -v beforeY="${before_y}" \
    -v afterX="${after_x}" -v afterY="${after_y}" \
    'BEGIN { printf "%.6f %.6f", afterX - beforeX, afterY - beforeY }')"
  pointer_direction="$(classify_direction "${dx}" "${dy}" "${MIN_DELTA}")"
  stick_direction="$(classify_direction "${stick_x}" "${stick_y}" "${STICK_THRESHOLD}")"
  printf '期望=%s，Joy-Con 轴=%s (%s, %s)，鼠标=%s (%s, %s)\n' \
    "$(direction_label "${expected}")" \
    "$(direction_label "${stick_direction}")" "${stick_x:-missing}" "${stick_y:-missing}" \
    "$(direction_label "${pointer_direction}")" "${dx}" "${dy}"
  [[ "${stick_direction}" == "${expected}" && "${pointer_direction}" == "${expected}" ]]
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

scenario="${1:-}"
case "${scenario}" in
  left-horizontal)
    expected_mode="left"
    expected_orientation="horizontal"
    scenario_label="左 Joy-Con 单支横握"
    stick_name="单支摇杆"
    ;;
  left-vertical)
    expected_mode="left"
    expected_orientation="vertical"
    scenario_label="左 Joy-Con 单支竖握"
    stick_name="单支摇杆"
    ;;
  right-horizontal)
    expected_mode="right"
    expected_orientation="horizontal"
    scenario_label="右 Joy-Con 单支横握"
    stick_name="单支摇杆"
    ;;
  right-vertical)
    expected_mode="right"
    expected_orientation="vertical"
    scenario_label="右 Joy-Con 单支竖握"
    stick_name="单支摇杆"
    ;;
  pair)
    expected_mode="pair"
    expected_orientation=""
    scenario_label="Joy-Con 双支组合"
    stick_name="左 Joy-Con 摇杆"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if ! app_is_running; then
  printf 'Joy Harness 新构建未运行，请先执行 ./scripts/build_and_run.sh --verify。\n' >&2
  exit 3
fi
if [[ ! -f "${STATUS_PATH}" ]]; then
  printf '找不到 Joy Harness 状态文件：%s\n' "${STATUS_PATH}" >&2
  exit 3
fi

if ! validate_runtime_state; then
  printf '请连接对应设备并完成权限/握姿设置后重试。\n' >&2
  exit 3
fi

printf '验证场景：%s\n' "${scenario_label}"
printf '每一向都会同时检查 App 内 Joy-Con 轴与实际鼠标位移。\n'

failures=0
for expected in up right down left; do
  if ! verify_direction "${expected}" "${stick_name}"; then
    failures=$((failures + 1))
  fi
done

printf '\n--- Joy-Con 实机验证结果 ---\n'
printf 'SCENARIO=%s\n' "${scenario}"
printf 'FAILURES=%s\n' "${failures}"
if [[ "${failures}" -eq 0 ]]; then
  printf 'RESULT=PASS\n'
  exit 0
fi
printf 'RESULT=FAIL\n'
exit 1
