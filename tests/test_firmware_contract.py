import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FirmwareContractTests(unittest.TestCase):
    def test_transport_queue_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = Path(temporary_directory) / "firmware-queue-contract"
            subprocess.run(
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(ROOT / "firmware" / "rp2040" / "src"),
                    str(ROOT / "tests" / "firmware_queue_contract.c"),
                    str(ROOT / "firmware" / "rp2040" / "src" / "transport_queue.c"),
                    "-o",
                    str(executable),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                [str(executable)], check=True, capture_output=True, text=True
            )

        self.assertEqual(result.stdout, "firmware queue contracts passed\n")


if __name__ == "__main__":
    unittest.main()
