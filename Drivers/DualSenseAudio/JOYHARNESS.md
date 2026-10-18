# Joy Harness integration

Upstream: https://github.com/Unravl/dualsense-audio-macos
Pinned commit: 4fbb5f47446ebe2e8e5d8964e822de2cabf6958e (MIT; LICENSE retained).

This local integration keeps the upstream Opus/audio transport and HAL intact.
Changes:
- The build links the repository's pinned Opus 1.5.2 portable sources statically, without a Homebrew codec dependency.
- The root helper acquires Game Mode before starting real mic capture, restores the prior policy after the last HAL client closes, and journals the lease for crash recovery. Xcode's gamepolicyctl is required. An existing forced-on setting is preserved.
- A separate read-only XPC service publishes only CRC-validated control reports and session state. Only root and the active console user may subscribe. It never exposes audio, shared audio memory, or commands to open the microphone. Joy Harness verifies the server's root identity and validates reports again.
- Options presses and the L2 + PS gesture survive the driver's exclusive HID capture. Other GameController input is gated while capturing.

Build: `bash scripts/build_dualsense_audio.sh` from the JoyHarness repository root.
Install: `sudo Drivers/DualSenseAudio/scripts/install.sh` after building.
Uninstall: `sudo Drivers/DualSenseAudio/scripts/uninstall.sh`.
The original unmodified source/build remains at `/Users/brian/Developer/dualsense-audio-macos` on the development machine for local rollback.

Game Mode is automatic in this integration; do not follow the upstream README's advice to leave it forced on.


## Managed installation in Joy Harness

General settings → PS5 Controller Microphone now owns enable/update/repair,
input selection, and uninstall. The app embeds the signed HAL and helper;
existing standalone installations migrate in place without changing the UID,
helper label or audio app selections. No second application is required.
The bundled build currently supports Apple silicon / macOS 26 and requires
`/Applications/Xcode.app` for Game Mode. Intel builds omit these components.

All binaries are staged and verified against their expected code hashes before
any installed file is replaced. A failed transaction restores prior artifacts
and the prior service. Pending Game Mode restoration blocks removal. Updating
also upgrades an already-installed JoyHarnessMicrophone HAL to v4, preserving
Xiaomi and removing the obsolete DualSense loopback input. Uninstall removes
only this DualSense helper/driver/job; Xiaomi and controller mappings remain.

Local build, install, and DMG packaging all use `scripts/embed_dualsense_audio.sh`.
Administrators authenticate through the app's system prompt. Source/build
folders are development artifacts and are not needed at runtime.
