#!/usr/bin/env python3
"""Exercise startup resource loading from a relocated, assembled macOS app."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='joy-harness-startup-') as directory:
        app = Path(directory) / args.app.name
        subprocess.run(['/usr/bin/ditto', str(args.app.resolve()), str(app)], check=True)
        result = subprocess.run(
            [str(app / 'Contents/MacOS/JoyHarness'), '--verify-bundle-resources',
             '-ApplePersistenceIgnoreState', 'YES'],
            capture_output=True, text=True, timeout=20,
        )
        if result.returncode != 0 or 'Packaged resources verified:' not in result.stdout:
            raise SystemExit(f'Packaged app startup check failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
        print(result.stdout.strip())


if __name__ == '__main__':
    main()
