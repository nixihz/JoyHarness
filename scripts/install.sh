#!/usr/bin/env bash
# Install Joy Harness and remove obsolete Codex hook/notify integration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${ROOT}/Sources/JoyHarness/Resources/VERSION")"
BIN_DIR="${HOME}/.agent-deck/bin"
APP_DIR="${HOME}/.agent-deck/Joy Harness.app"
LEGACY_APP_DIR="${HOME}/.agent-deck/AgentDeck.app"
APP_CONTENTS="${APP_DIR}/Contents"
APP_EXE="${APP_CONTENTS}/MacOS/JoyHarness"
mkdir -p "${HOME}/.agent-deck"
STAGE_ROOT="$(mktemp -d "${HOME}/.agent-deck/.JoyHarness-stage.XXXXXX")"
STAGED_APP_DIR="${STAGE_ROOT}/Joy Harness.app"
STAGED_CONTENTS="${STAGED_APP_DIR}/Contents"
STAGED_APP_EXE="${STAGED_CONTENTS}/MacOS/JoyHarness"
trap 'rm -rf "${STAGE_ROOT}"' EXIT
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
PLIST="${LAUNCH_AGENTS}/tech.joyharness.daemon.plist"
LEGACY_AGENTDECK_PLIST="${LAUNCH_AGENTS}/tech.agentdeck.daemon.plist"
LEGACY_CODEXPAD_PLIST="${LAUNCH_AGENTS}/tech.codexpad.daemon.plist"
SEND="${ROOT}/bin/joy-harness-send"

mkdir -p "${HOME}/.agent-deck" "${BIN_DIR}" "${LAUNCH_AGENTS}"
mkdir -p "${STAGED_CONTENTS}/MacOS" "${STAGED_CONTENTS}/Resources"

echo "==> Building Joy Harness"
cd "${ROOT}"
swift build -c release
BUILT_DIR="$(swift build -c release --show-bin-path)"
BUILT="${BUILT_DIR}/JoyHarness"
RESOURCE_BUNDLE="${BUILT_DIR}/JoyHarness_JoyHarness.bundle"
install -m 755 "${BUILT}" "${STAGED_APP_EXE}"
/usr/bin/ditto "${RESOURCE_BUNDLE}/" "${STAGED_CONTENTS}/Resources/"
cat > "${STAGED_CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>JoyHarness</string>
  <key>CFBundleIdentifier</key>
  <string>tech.joyharness.daemon</string>
  <key>CFBundleName</key>
  <string>Joy Harness</string>
  <key>CFBundleIconFile</key>
  <string>JoyHarness.icns</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
"${ROOT}/scripts/sign_macos_app.sh" "${STAGED_APP_DIR}" "tech.joyharness.daemon"
"${ROOT}/scripts/stop_joy_harness_instances.sh"
for legacy_plist in "${LEGACY_AGENTDECK_PLIST}" "${LEGACY_CODEXPAD_PLIST}"; do
  if [[ -f "${legacy_plist}" ]]; then
    unlink "${legacy_plist}"
  fi
done
rm -rf "${APP_DIR}" "${LEGACY_APP_DIR}"
mv "${STAGED_APP_DIR}" "${APP_DIR}"
# Drop download/quarantine markers so LaunchAgent startup is less likely to be
# treated as an untrusted first-run payload by Gatekeeper/XProtect.
xattr -cr "${APP_DIR}" 2>/dev/null || true
if [[ -e "${BIN_DIR}/JoyHarness" && ! -L "${BIN_DIR}/JoyHarness" ]]; then
  mv "${BIN_DIR}/JoyHarness" "${BIN_DIR}/JoyHarness.legacy"
elif [[ -L "${BIN_DIR}/JoyHarness" ]]; then
  unlink "${BIN_DIR}/JoyHarness"
fi
ln -s "${APP_EXE}" "${BIN_DIR}/JoyHarness"
if [[ -e "${BIN_DIR}/AgentDeck" && ! -L "${BIN_DIR}/AgentDeck" ]]; then
  mv "${BIN_DIR}/AgentDeck" "${BIN_DIR}/AgentDeck.legacy"
fi
ln -sfn "${APP_EXE}" "${BIN_DIR}/AgentDeck"
install -m 755 "${SEND}" "${BIN_DIR}/joy-harness-send"
ln -sfn "${BIN_DIR}/joy-harness-send" "${BIN_DIR}/agent-deck-send"
mkdir -p "${HOME}/.local/bin"
ln -sfn "${BIN_DIR}/joy-harness-send" "${HOME}/.local/bin/joy-harness-send" 2>/dev/null || true
ln -sfn "${BIN_DIR}/joy-harness-send" "${HOME}/.local/bin/agent-deck-send" 2>/dev/null || true

# Remove the lifecycle integration installed by older Joy Harness versions.
python3 - <<'PY'
import json
import re
from pathlib import Path
home = Path.home()
hooks_path = home / ".codex" / "hooks.json"
cfg = Path.home() / ".codex" / "config.toml"
chain_path = home / ".agent-deck" / "notify-chain.json"
legacy_chain_path = home / ".codex-pad" / "notify-chain.json"
legacy_descriptions = {
    "Xbox / gamepad haptic bridge for Codex runtime states (Codex-Pad).",
    "Xbox / gamepad haptic bridge for Codex runtime states (Joy Harness).",
    "Minimal Codex runtime state bridge for Joy Harness.",
}
removed_hooks_source = False

def backup_config():
    backup = cfg.with_suffix(".toml.bak-joyharness-removal")
    if not backup.exists():
        backup.write_text(cfg.read_text(encoding="utf-8"), encoding="utf-8")

if hooks_path.exists():
    original_hooks = hooks_path.read_text(encoding="utf-8")
    data = json.loads(original_hooks)
    hooks = data.get("hooks", {}) if isinstance(data, dict) else {}
    changed = False
    for event in list(hooks):
        kept_groups = []
        for group in hooks.get(event, []):
            handlers = [
                handler for handler in group.get("hooks", [])
                if "hook_bridge.py" not in str(handler.get("command", ""))
            ]
            if handlers:
                kept_group = dict(group)
                kept_group["hooks"] = handlers
                kept_groups.append(kept_group)
            if len(handlers) != len(group.get("hooks", [])):
                changed = True
        if kept_groups:
            hooks[event] = kept_groups
        else:
            hooks.pop(event, None)
    if changed:
        removed_hooks_source = True
        backup = hooks_path.with_suffix(".json.bak-joyharness-removal")
        if not backup.exists():
            backup.write_text(original_hooks, encoding="utf-8")
        if data.get("description") in legacy_descriptions:
            data.pop("description", None)
        if hooks:
            data["hooks"] = hooks
        else:
            data.pop("hooks", None)
        if data:
            hooks_path.write_text(
                json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        else:
            hooks_path.unlink()
        print(f"removed obsolete Joy Harness hooks from {hooks_path}")

legacy_chain = []
chain_source = chain_path if chain_path.exists() else legacy_chain_path
if chain_source.exists():
    legacy_chain = json.loads(chain_source.read_text(encoding="utf-8"))
    if not isinstance(legacy_chain, list):
        raise SystemExit(f"cannot restore invalid notify chain from {chain_source}")

def remove_fanout(command):
    if not isinstance(command, list):
        return command
    if any(
        isinstance(item, str) and item.endswith("notify_fanout.py")
        for item in command
    ):
        return legacy_chain
    cleaned = []
    index = 0
    while index < len(command):
        item = command[index]
        if item == "--previous-notify" and index + 1 < len(command):
            encoded = command[index + 1]
            try:
                nested = json.loads(encoded)
            except (TypeError, json.JSONDecodeError):
                cleaned.extend([item, encoded])
            else:
                restored = remove_fanout(nested)
                if restored:
                    cleaned.extend([
                        item,
                        json.dumps(restored, separators=(",", ":")),
                    ])
            index += 2
            continue
        cleaned.append(item)
        index += 1
    return cleaned

if cfg.exists():
    lines = cfg.read_text(encoding="utf-8").splitlines(keepends=True)
    for index, line in enumerate(lines):
        if not re.match(r"^notify\s*=", line):
            continue
        raw = line.split("=", 1)[1].strip()
        try:
            notify = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"cannot parse existing notify config: {exc}")
        if "notify_fanout.py" not in str(notify):
            break
        backup_config()
        restored = remove_fanout(notify)
        if restored:
            lines[index] = f"notify = {json.dumps(restored)}\n"
        else:
            del lines[index]
        cfg.write_text("".join(lines), encoding="utf-8")
        print(f"removed obsolete Joy Harness notify fan-out from {cfg}")
        break

if removed_hooks_source and not hooks_path.exists() and cfg.exists():
    lines = cfg.read_text(encoding="utf-8").splitlines(keepends=True)
    source_prefix = f'[hooks.state."{hooks_path}:'
    cleaned = []
    skipping = False
    changed = False
    for line in lines:
        if line.startswith(source_prefix):
            skipping = True
            changed = True
            continue
        if skipping and re.match(r"^\[.*\]\s*$", line):
            skipping = False
        if not skipping:
            cleaned.append(line)
    for index, line in enumerate(cleaned):
        if line.strip() != "[hooks.state]":
            continue
        next_index = index + 1
        while next_index < len(cleaned) and not cleaned[next_index].strip():
            next_index += 1
        if (
            next_index == len(cleaned)
            or not cleaned[next_index].startswith("[hooks.state.")
        ):
            del cleaned[index:next_index]
            changed = True
        break
    if changed:
        backup_config()
        cfg.write_text("".join(cleaned), encoding="utf-8")
        print(f"removed obsolete Joy Harness hook trust state from {cfg}")

for obsolete_chain in (chain_path, legacy_chain_path):
    if obsolete_chain.exists():
        obsolete_chain.unlink()
PY

for obsolete in "${BIN_DIR}/hook_bridge.py" "${BIN_DIR}/notify_fanout.py"; do
  if [[ -f "${obsolete}" ]]; then
    unlink "${obsolete}"
  fi
done

# LaunchAgent
cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>tech.joyharness.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_EXE}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/.agent-deck/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/.agent-deck/daemon.log</string>
</dict>
</plist>
EOF

for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$(id -u)" "${PLIST}" 2>/dev/null; then
    break
  fi
  if [[ "${attempt}" == "5" ]]; then
    echo "failed to bootstrap Joy Harness LaunchAgent after ${attempt} attempts" >&2
    exit 1
  fi
  echo "LaunchAgent still stopping; retrying bootstrap (${attempt}/5)" >&2
  sleep 1
done
launchctl enable "gui/$(id -u)/tech.joyharness.daemon" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/tech.joyharness.daemon"

echo
echo "Installed."
echo "  app:     ${APP_DIR}"
echo "  daemon:  ${APP_EXE}"
echo "  send:    ${BIN_DIR}/joy-harness-send"
echo "  status:  ~/.agent-deck/status.json"
echo
echo "Next:"
echo "  1. Connect Xbox controller (Bluetooth or USB)"
echo "  2. Flash and connect the RP2040: task firmware && task flash"
echo "  3. Restart Codex Desktop so it detects the Codex Micro HID"
echo "  4. Grant Input Monitoring to Codex Desktop when prompted"
echo "  5. Test haptics: ${BIN_DIR}/joy-harness-send waiting"
