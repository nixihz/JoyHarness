import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "bin" / "joy-harness-send"
SPEC = importlib.util.spec_from_loader(
    "joy_harness_send", SourceFileLoader("joy_harness_send", str(SCRIPT_PATH))
)
assert SPEC is not None and SPEC.loader is not None
JOY_HARNESS_SEND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(JOY_HARNESS_SEND)


class SocketCLITests(unittest.TestCase):
    def test_send_accepts_structured_success(self) -> None:
        result, request, error = self.send_against_response(b'{"ok":true}\n')

        self.assertEqual(result, 0)
        self.assertEqual(request, b'{"state": "waiting"}\n')
        self.assertEqual(error, "")

    def test_send_reports_structured_server_error(self) -> None:
        result, _, error = self.send_against_response(
            b'{"ok":false,"error":"invalid_state"}\n'
        )

        self.assertEqual(result, 1)
        self.assertIn("invalid_state", error)

    def test_send_remains_compatible_with_legacy_success(self) -> None:
        result, _, error = self.send_against_response(b"ok\n")

        self.assertEqual(result, 0)
        self.assertEqual(error, "")

    def test_send_rejects_empty_and_invalid_responses(self) -> None:
        empty_result, _, empty_error = self.send_against_response(b"")
        invalid_result, _, invalid_error = self.send_against_response(b"not-json\n")

        self.assertEqual(empty_result, 1)
        self.assertIn("invalid daemon response", empty_error)
        self.assertEqual(invalid_result, 1)
        self.assertIn("invalid daemon response", invalid_error)

    def test_send_reports_response_timeout(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp") as temporary_directory:
            socket_path = Path(temporary_directory) / "jh.sock"
            listening_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listening_socket.bind(str(socket_path))
            listening_socket.listen(1)

            def serve() -> None:
                with listening_socket:
                    connection, _ = listening_socket.accept()
                    with connection:
                        while connection.recv(4096):
                            pass
                        time.sleep(0.1)

            server = threading.Thread(target=serve)
            server.start()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = JOY_HARNESS_SEND.send(
                    {"state": "waiting"}, socket_path, timeout=0.02
                )

            server.join(timeout=1)
            self.assertFalse(server.is_alive())
            self.assertEqual(result, 1)
            self.assertIn("response failed", stderr.getvalue())

    def send_against_response(self, response: bytes) -> tuple[int, bytes, str]:
        with tempfile.TemporaryDirectory(dir="/tmp") as temporary_directory:
            socket_path = Path(temporary_directory) / "jh.sock"
            listening_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listening_socket.bind(str(socket_path))
            listening_socket.listen(1)
            received = bytearray()

            def serve() -> None:
                with listening_socket:
                    connection, _ = listening_socket.accept()
                    with connection:
                        while True:
                            chunk = connection.recv(4096)
                            if not chunk:
                                break
                            received.extend(chunk)
                        connection.sendall(response)

            server = threading.Thread(target=serve)
            server.start()
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = JOY_HARNESS_SEND.send(
                    {"state": "waiting"}, socket_path, timeout=0.5
                )
            server.join(timeout=1)
            self.assertFalse(server.is_alive())
            return result, bytes(received), stderr.getvalue()


if __name__ == "__main__":
    unittest.main()
