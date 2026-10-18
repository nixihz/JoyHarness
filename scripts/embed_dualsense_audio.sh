#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?app bundle required}"
mode="${2:-local}"
# This validated upstream build currently targets Apple silicon / macOS 26.
[[ "$(uname -m)" == arm64 ]] || exit 0
bash "$root/scripts/build_dualsense_audio.sh"
mkdir -p "$app/Contents/PlugIns" "$app/Contents/Library/LaunchServices" "$app/Contents/Resources/DualSenseAudio"
ditto "$root/Drivers/DualSenseAudio/build/DualSenseAudio.driver" "$app/Contents/PlugIns/DualSenseAudio.driver"
install -m 755 "$root/Drivers/DualSenseAudio/build/ds5audiod" "$app/Contents/Library/LaunchServices/ds5audiod"
install -m 644 "$root/Drivers/DualSenseAudio/LICENSE" "$app/Contents/Resources/DualSenseAudio/LICENSE"
"$root/scripts/sign_macos_app.sh" "$app/Contents/PlugIns/DualSenseAudio.driver" com.psgrok.DualSenseAudio "$mode"
"$root/scripts/sign_macos_app.sh" "$app/Contents/Library/LaunchServices/ds5audiod" tech.keli.joyharness.dualsense-helper "$mode"
