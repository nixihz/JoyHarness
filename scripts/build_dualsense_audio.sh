#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cmake -S "$root/Drivers/DualSenseAudio" -B "$root/Drivers/DualSenseAudio/build" -G Ninja
cmake --build "$root/Drivers/DualSenseAudio/build"
codesign --verify --strict "$root/Drivers/DualSenseAudio/build/DualSenseAudio.driver"
echo "Built. Install with: sudo $root/Drivers/DualSenseAudio/scripts/install.sh"
