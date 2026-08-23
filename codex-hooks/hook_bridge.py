#!/usr/bin/env python3
"""Codex hook → agent-deck state bridge. Reads hook JSON on stdin."""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path

SOCK = Path(os.environ.get("AGENT_DECK_SOCK", Path.home() / ".agent-deck" / "pad.sock"))

# Map Codex hook_event_name → pad state
EVENT_STATE = {
    "SessionStart": "idle",
    "SessionEnd": "idle",
    "UserPromptSubmit": "busy",
    "PreToolUse": "busy",
    "PostToolUse": "busy",
    "PermissionRequest": "waiting",
    "Stop": "done",
    "SubagentStart": "busy",
    "SubagentStop": "busy",
}


def post(
    state: str,
    note: str,
) -> bool:
    if not SOCK.exists():
        return False
    command = {"state": state, "note": note}
    payload = json.dumps(command, ensure_ascii=False) + "\n"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.4)
            s.connect(str(SOCK))
            s.sendall(payload.encode("utf-8"))
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            try:
                s.recv(32)
            except OSError:
                pass
        return True
    except OSError:
        return False


def main() -> int:
    raw = sys.stdin.read()
    event = "unknown"
    try:
        data = json.loads(raw) if raw.strip() else {}
        event = data.get("hook_event_name") or data.get("event") or "unknown"
    except json.JSONDecodeError:
        data = {}

    # Allow: python hook_bridge.py waiting
    if len(sys.argv) > 1 and sys.argv[1] in {"idle", "busy", "waiting", "done", "error"}:
        state = sys.argv[1]
    else:
        state = EVENT_STATE.get(event, "busy")

    post(
        state,
        note=event,
    )

    # Hooks that expect JSON on stdout (Stop / SubagentStop) — empty continue is fine.
    if event in {"Stop", "SubagentStop"}:
        print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
