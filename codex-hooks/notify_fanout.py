#!/usr/bin/env python3
"""Codex notify fan-out: keep prior notify targets, also drive Joy Harness."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

SOCK = Path(os.environ.get("AGENT_DECK_SOCK", Path.home() / ".agent-deck" / "pad.sock"))
CHAIN_PATH = Path.home() / ".agent-deck" / "notify-chain.json"


def pad_done(note: str, thread_id: str) -> None:
    if not SOCK.exists():
        return
    payload = json.dumps(
        {"state": "done", "note": note, "thread_id": thread_id},
        ensure_ascii=False,
    ) + "\n"
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
    except OSError:
        pass


def chain_original(argv_tail: list[str]) -> None:
    if not CHAIN_PATH.exists():
        return
    try:
        chain = json.loads(CHAIN_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(chain, list) or not chain:
        return
    cmd = [str(x) for x in chain] + argv_tail
    try:
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass


def main() -> int:
    # Codex appends JSON as the final argv for notify.
    payload = {}
    if len(sys.argv) > 1:
        try:
            payload = json.loads(sys.argv[-1])
        except json.JSONDecodeError:
            payload = {}

    event = payload.get("type") or "notify"
    if event == "agent-turn-complete" or not payload:
        pad_done(
            note=str(event),
            thread_id=str(payload.get("thread-id") or payload.get("thread_id") or ""),
        )

    # Forward original argv after our script name (same shape Codex used).
    chain_original(sys.argv[1:])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
