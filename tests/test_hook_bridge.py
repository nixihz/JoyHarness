from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "codex-hooks" / "hook_bridge.py"


class HookBridgeTests(unittest.TestCase):
    def capture(self, event: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        with tempfile.TemporaryDirectory() as temporary:
            socket_path = Path(temporary) / "pad.sock"
            received: list[dict] = []
            ready = threading.Event()

            def daemon() -> None:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(str(socket_path))
                    server.listen(1)
                    ready.set()
                    connection, _ = server.accept()
                    with connection:
                        raw = b""
                        while chunk := connection.recv(4096):
                            raw += chunk
                        received.append(json.loads(raw.decode("utf-8")))
                        connection.sendall(b"ok\n")

            server_thread = threading.Thread(target=daemon)
            server_thread.start()
            self.assertTrue(ready.wait(timeout=2))
            environment = os.environ.copy()
            environment["AGENT_DECK_SOCK"] = str(socket_path)
            result = subprocess.run(
                ["python3", str(BRIDGE)],
                input=json.dumps({"hook_event_name": event, "session_id": "thread-123"}),
                text=True,
                capture_output=True,
                env=environment,
                timeout=2,
                check=False,
            )
            server_thread.join(timeout=2)
            self.assertFalse(server_thread.is_alive())
            self.assertEqual(len(received), 1)
            return result, received[0]

    def test_prompt_submit_sets_busy(self) -> None:
        result, message = self.capture("UserPromptSubmit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            message,
            {"state": "busy", "note": "UserPromptSubmit", "thread_id": "thread-123"},
        )

    def test_permission_request_only_signals_waiting(self) -> None:
        result, message = self.capture("PermissionRequest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            message,
            {"state": "waiting", "note": "PermissionRequest", "thread_id": "thread-123"},
        )

    def test_offline_daemon_returns_immediately(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["AGENT_DECK_SOCK"] = str(Path(temporary) / "missing.sock")
            result = subprocess.run(
                ["python3", str(BRIDGE)],
                input=json.dumps({"hook_event_name": "PermissionRequest"}),
                text=True,
                capture_output=True,
                env=environment,
                timeout=1,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
