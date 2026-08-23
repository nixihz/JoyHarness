#!/usr/bin/env bash
# Install Joy Harness: build daemon, wire ~/.codex hooks and notify fan-out.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
HOOKS_DST="${HOME}/.codex/hooks.json"
SEND="${ROOT}/bin/joy-harness-send"
BRIDGE="${BIN_DIR}/hook_bridge.py"
FANOUT="${BIN_DIR}/notify_fanout.py"

mkdir -p "${HOME}/.agent-deck" "${BIN_DIR}" "${HOME}/.codex" "${LAUNCH_AGENTS}"
mkdir -p "${STAGED_CONTENTS}/MacOS" "${STAGED_CONTENTS}/Resources"

echo "==> Building Joy Harness"
cd "${ROOT}"
swift build -c release
BUILT_DIR="$(swift build -c release --show-bin-path)"
BUILT="${BUILT_DIR}/JoyHarness"
RESOURCE_BUNDLE="${BUILT_DIR}/JoyHarness_JoyHarness.bundle"
install -m 755 "${BUILT}" "${STAGED_APP_EXE}"
/usr/bin/ditto "${RESOURCE_BUNDLE}/" "${STAGED_CONTENTS}/Resources/"
cat > "${STAGED_CONTENTS}/Info.plist" <<'EOF'
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
install -m 755 "${ROOT}/codex-hooks/hook_bridge.py" "${BRIDGE}"
install -m 755 "${ROOT}/codex-hooks/notify_fanout.py" "${FANOUT}"
mkdir -p "${HOME}/.local/bin"
ln -sfn "${BIN_DIR}/joy-harness-send" "${HOME}/.local/bin/joy-harness-send" 2>/dev/null || true
ln -sfn "${BIN_DIR}/joy-harness-send" "${HOME}/.local/bin/agent-deck-send" 2>/dev/null || true

# hooks.json
python3 - <<'PY' "${ROOT}" "${HOOKS_DST}" "${BRIDGE}"
import json, sys
from pathlib import Path
root, dst, bridge = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
tpl = (root / "codex-hooks" / "hooks.template.json").read_text(encoding="utf-8")
tpl = tpl.replace("__BRIDGE__", str(bridge))
new_hooks = json.loads(tpl)

if dst.exists():
    existing = json.loads(dst.read_text(encoding="utf-8"))
    # Backup once
    bak = dst.with_suffix(".json.bak-agentdeck")
    if not bak.exists():
        bak.write_text(json.dumps(existing, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    merged = existing if isinstance(existing, dict) else {"hooks": {}}
    hooks = merged.setdefault("hooks", {})
    for event, groups in new_hooks.get("hooks", {}).items():
        # Replace only our bridge hooks; keep others
        kept = []
        for group in hooks.get(event, []):
            handlers = [
                h for h in group.get("hooks", [])
                if "hook_bridge.py" not in str(h.get("command", ""))
            ]
            if handlers:
                g = dict(group)
                g["hooks"] = handlers
                kept.append(g)
        hooks[event] = kept + groups
    if "description" not in merged:
        merged["description"] = new_hooks.get("description", "")
    dst.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"merged hooks → {dst}")
else:
    dst.write_text(json.dumps(new_hooks, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote hooks → {dst}")
PY

# notify fan-out (preserve existing notify)
python3 - <<PY
import json, re
from pathlib import Path

cfg = Path.home() / ".codex" / "config.toml"
fanout = Path("${FANOUT}")
chain_path = Path.home() / ".agent-deck" / "notify-chain.json"
legacy_chain_path = Path.home() / ".codex-pad" / "notify-chain.json"

if not chain_path.exists() and legacy_chain_path.exists():
    chain_path.write_text(legacy_chain_path.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"migrated previous notify chain → {chain_path}")

text = cfg.read_text(encoding="utf-8") if cfg.exists() else ""
# Codex documents notify as a single-line string array. Parse the whole line so
# JSON embedded in an argument cannot terminate the match at its inner ']'.
lines = text.splitlines(keepends=True)
notify_indexes = [
    index for index, line in enumerate(lines)
    if re.match(r"^notify\s*=", line)
]
existing = []
primary_index = notify_indexes[0] if notify_indexes else None
if primary_index is not None:
    raw = lines[primary_index].split("=", 1)[1].strip()
    try:
        existing = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"cannot parse existing notify config: {exc}")

def migrate_fanout(value):
    if isinstance(value, list):
        migrated = [migrate_fanout(item) for item in value]
        return migrated
    if not isinstance(value, str) or "notify_fanout.py" not in value:
        return value
    if value.endswith("notify_fanout.py") and not value.lstrip().startswith("["):
        return str(fanout)
    try:
        nested = json.loads(value)
    except json.JSONDecodeError:
        return value
    return json.dumps(migrate_fanout(nested), separators=(",", ":"))

migrated = migrate_fanout(existing)
already = any("notify_fanout.py" in str(x) for x in migrated)
if already:
    if migrated != existing or len(notify_indexes) > 1:
        new_line = f"notify = {json.dumps(migrated)}\n"
        lines[primary_index] = new_line
        for index in reversed(notify_indexes[1:]):
            del lines[index]
        cfg.write_text("".join(lines), encoding="utf-8")
        print(f"migrated notify fanout path in {cfg}")
    else:
        print("notify already points at installed fanout; leaving config.toml alone")
else:
    if existing:
        chain_path.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
        print(f"saved previous notify chain → {chain_path}")
    else:
        chain_path.write_text("[]\n", encoding="utf-8")

    new_line = f'notify = ["python3", "{fanout}"]\n'
    if primary_index is not None:
        lines[primary_index] = new_line
        for index in reversed(notify_indexes[1:]):
            del lines[index]
        text = "".join(lines)
    else:
        text = (text.rstrip() + "\n\n" + new_line) if text else new_line
    bak = cfg.with_suffix(".toml.bak-agentdeck")
    if cfg.exists() and not bak.exists():
        bak.write_text(cfg.read_text(encoding="utf-8"), encoding="utf-8")
    cfg.write_text(text, encoding="utf-8")
    print(f"updated notify in {cfg}")
PY

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
echo "  hooks:   ${HOOKS_DST}"
echo "  status:  ~/.agent-deck/status.json"
echo
echo "Next:"
echo "  1. Connect Xbox controller (Bluetooth or USB)"
echo "  2. Flash and connect the RP2040: task firmware && task flash"
echo "  3. Restart Codex Desktop so it detects the Codex Micro HID"
echo "  4. Grant Input Monitoring to Codex Desktop when prompted"
echo "  5. Test haptics: ${BIN_DIR}/joy-harness-send waiting"
