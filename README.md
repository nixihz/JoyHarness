<p align="center">
  <img src="Sources/JoyHarness/Resources/Brand/joy-harness-logo-readme.png" alt="Joy Harness logo" width="760">
</p>

<h1 align="center">Joy Harness</h1>

<p align="center">
  <img src="Sources/JoyHarness/Resources/Brand/joy-harness-app-icon-v5.png" alt="Joy Harness app icon" width="112">
</p>

<p align="center">
  <a href="docs/README.zh-CN.md">简体中文</a>
</p>

Joy Harness is a physical control system for Codex Desktop on macOS. It connects a PS5 DualSense, Xbox controller, or another extended gamepad recognized by macOS to mouse controls, system shortcuts, six Codex Micro task slots, permission approvals, push-to-talk, haptic confirmation, and a local diagnostics dashboard.

The system has two parts:

1. **Joy Harness for macOS** reads controller input, controls the mouse, plays haptic feedback, and provides a six-slot dashboard.
2. **RP2040 firmware** turns a Raspberry Pi Pico-compatible board into a `Codex Micro` device recognized by Codex Desktop and receives controller actions from Joy Harness over serial.

Both the controller and RP2040 connect to the Mac; no wiring is required between them. Joy Harness starts a read-only Codex app-server subprocess to retrieve task names and ordering. It does not proxy Codex actions or emulate Codex Micro with keyboard events. Slot selection, approvals, and push-to-talk reach Codex Desktop through the RP2040's native Vendor HID interface. Mouse actions and system shortcuts are sent directly to the foreground macOS application.

## Download

The current release is **v0.2.1** for Apple Silicon Macs (arm64) running macOS 13.0 or later:

- [Download Joy-Harness-v0.2.1-macOS-arm64.dmg](https://github.com/nixihz/JoyHarness/releases/download/v0.2.1/Joy-Harness-v0.2.1-macOS-arm64.dmg)
- [Download the SHA-256 checksum](https://github.com/nixihz/JoyHarness/releases/download/v0.2.1/Joy-Harness-v0.2.1-macOS-arm64.dmg.sha256)
- [View the v0.2.1 release](https://github.com/nixihz/JoyHarness/releases/tag/v0.2.1)

The DMG contains `Joy Harness.app` for manual launch. Use the [source installation](#install-from-source) if you need launch-at-login, the local CLI, or RP2040 firmware build and flashing tools. The v0.2.1 release is ad-hoc signed and not notarized by Apple, so the first launch may require right-clicking the app and choosing **Open**, or allowing it under **System Settings > Privacy & Security**.

Verify the download with:

```bash
shasum -a 256 -c Joy-Harness-v0.2.1-macOS-arm64.dmg.sha256
```

## What's New in v0.2.1

- Fixed a launch crash in downloaded Release builds caused by eagerly loading the SwiftPM resource bundle after the version had already been found in the app bundle.

## What's New in v0.2.0

- Added `LT + RT` for Enter, `LT + L3/R3` for copy/paste, and an Options/View shortcut for Lark screenshots.
- Redesigned the dashboard into a compact three-column layout with consistent app version and connection health indicators.
- Centralized version metadata in the `VERSION` resource for the app, installer, and DMG.
- Added graduated Xbox Impulse Trigger feedback and a resistance wall for the DualSense R2 adaptive trigger.
- Added Simplified Chinese and English interfaces with system-language and manual selection modes.

![Xbox controller layout](Sources/JoyHarness/Resources/controller-dashboard.png)

![PS5 DualSense controller layout](Sources/JoyHarness/Resources/controller-dashboard-dualsense.png)

## Features

- **Control Codex away from the keyboard:** switch among six Codex Micro task slots, open the active task, approve or reject permission prompts, and enter `yes` or `no`. Fast mode and task splitting can still be assigned as custom mappings.
- **Push-to-talk:** hold Menu/Options to send Codex Micro `ACT10`, then release to stop. DualSense controllers can also use the touchpad button. Recording remains native to Codex Desktop.
- **DualSense audio diagnostics:** detect the controller microphone exposed over USB and report whether it is the default macOS input. Joy Harness does not claim the recording device or change global audio settings.
- **Graduated trigger feedback:** DualSense R2 provides a light touch, a resistance wall, and a stronger confirmation after the trigger point. Xbox RT uses Impulse Trigger feedback where supported.
- **Control macOS:** move and scroll with the left stick; use A/B/R3 as left, right, and middle mouse buttons; use X/Y as Backspace and Escape; and access Enter, copy, and paste through the LT layer.
- **Manage six task slots:** move sequentially with LB/RB or jump directly to slots 1-6 with LT combinations. Short haptic pulses report the selected slot number.
- **Diagnose locally:** inspect the active slot, controller battery and haptic support, RP2040 connection, microphone input, and Accessibility authorization from the dashboard.
- **Customize mappings:** assign base buttons, the D-pad, and the LT layer to mouse, system, Codex Micro, slot, or disabled actions. Changes apply immediately and persist automatically.
- **Run in the background:** a LaunchAgent starts Joy Harness at login, and disconnected controllers or RP2040 boards are detected again when reconnected.

### Capabilities by Hardware

| Connected hardware | Available features |
|---|---|
| Joy Harness app only | Dashboard and local CLI diagnostics |
| App + controller | Mouse, scrolling, system keys, slot-confirmation haptics, and manual haptic tests |
| App + RP2040 | Select or open Codex Micro task slots from the dashboard; controller approval actions are unavailable |
| App + controller + RP2040 | Full controller input for Codex, mouse control, push-to-talk, and haptic confirmation |

## How It Works

```text
Joy Harness macOS app -- Core Haptics --> Controller haptics
        ^
        | GameController
        +-------------------------------- DualSense / Xbox / compatible controller

Controller input --> Joy Harness --> USB CDC serial --> RP2040
                                                        |
                                                        | Vendor HID
                                                        v
                                             Codex Desktop / Codex Micro

Left stick, A/B/X/Y, R3 --> Joy Harness --> CoreGraphics --> Foreground macOS app
```

The RP2040 firmware exposes two USB interfaces:

- `Codex Micro` Vendor HID, read by Codex Desktop for task slots, approvals, push-to-talk, and radial input.
- `Joy Harness Bridge` USB CDC serial, used by Joy Harness to forward controller events to the RP2040.

Joy Harness accepts a serial device only after receiving the compatible `READY agentdeck-rp2040` handshake, so unrelated serial devices are ignored. The legacy handshake name is retained for compatibility with existing firmware.

## Requirements

### Software

Using the DMG does not require Xcode, Python, or Git. The following tools are needed only for source installation, CLI use, or firmware builds.

| Component | Requirement | Purpose |
|---|---|---|
| macOS | 13.0 or later | SwiftUI, GameController, Core Haptics, and Accessibility APIs |
| Codex Desktop | A version with Codex Micro support | Receives RP2040 Vendor HID input |
| Xcode Command Line Tools | Swift 5.9+ and a macOS SDK | Builds the macOS app |
| Python | Python 3 | Runs the local status and diagnostics CLI |
| Git | GitHub access | Downloads Pico SDK 2.2.0 for the first firmware build |

Check the local environment:

```bash
xcode-select -p
swift --version
python3 --version
git --version
```

Install Xcode Command Line Tools if needed:

```bash
xcode-select --install
```

### Hardware

The RP2040 is optional for mouse control, system shortcuts, the dashboard, and manual haptic tests. Codex Micro task slots, approvals, and push-to-talk require the complete hardware path:

- A Mac running macOS.
- An extended gamepad recognized by macOS `GameController`. Joy Harness directly supports PS5 DualSense, PS4 DualShock 4, and Xbox Series controllers. Other controllers depend on the inputs and haptics exposed by macOS.
- A Raspberry Pi Pico or compatible RP2040 development board.
- A data-capable USB cable. Charge-only cables cannot flash firmware or expose serial/HID devices.

Controllers can connect over Bluetooth or USB. On the tested Xbox Series controller, haptics work on macOS 26.5.2 over **Bluetooth only**. DualSense microphone input requires USB. Bluetooth still supports controller input and can trigger push-to-talk while Codex records through the Mac microphone, AirPods, or another input device.

The DualSense microphone appears as `DualSense Wireless Controller` or `Wireless Controller` even when connected over USB. Select it under **System Settings > Sound > Input**. Joy Harness reports the actual USB transport and whether the device is the default input. The controller's physical mute button is not exposed through the public GameController API.

### Firmware Build Tools

Install CMake, Ninja, and ARM GCC with Homebrew:

```bash
brew install cmake ninja arm-none-eabi-gcc
```

The `task` command is a convenience rather than a requirement:

```bash
brew install go-task
task --version
```

### macOS Permissions

| Permission | Grant to | Effect |
|---|---|---|
| Accessibility | Joy Harness | Mouse, Enter, copy, paste, screenshots, and other system keys |
| Input Monitoring | Joy Harness | Controller input while the app is in the background |
| Input Monitoring | Codex Desktop | Physical Codex Micro input |
| Microphone | Codex Desktop | Native push-to-talk recording; Joy Harness does not request microphone access |

Permissions are under **System Settings > Privacy & Security**. Without Accessibility access, RP2040/Codex Micro actions and haptics still work, but mouse and system-key actions do not.

## Install from Source

Run all commands from the repository root.

### 1. Build and Flash the RP2040

```bash
task firmware
# Without task: bash scripts/build_rp2040_firmware.sh
```

The first build downloads Pico SDK 2.2.0 to `~/.agent-deck/toolchains/pico-sdk`. The firmware is written to:

```text
firmware/rp2040/build/joy_harness_rp2040.uf2
```

Hold the board's `BOOTSEL` button while connecting it to the Mac. When the `RPI-RP2` volume appears in Finder, run:

```bash
task flash
# Without task: bash scripts/flash_rp2040_firmware.sh
```

The board reboots automatically after the UF2 is copied. Raspberry Pi Pico is the default board target. Override it for a compatible board or reuse an existing SDK with:

```bash
PICO_BOARD=<board-name> task firmware
PICO_SDK_PATH=/absolute/path/to/pico-sdk task firmware
```

### 2. Install Joy Harness

```bash
task install
# Without task: bash scripts/install.sh
```

The installer builds the release app and registers its LaunchAgent. Upgrades remove obsolete Joy Harness Codex hooks and `notify` fan-out while preserving unrelated tool configuration. Deployment stops older Joy Harness or AgentDeck instances before launching a single new instance, preventing multiple apps from competing for the controller, serial port, or Unix socket.

### 3. Connect and Restart

1. Connect the controller over Bluetooth or USB. Prefer Bluetooth for Xbox haptics and USB for the DualSense microphone.
2. Keep the flashed RP2040 connected to the Mac with a data cable.
3. Fully quit and reopen Codex Desktop so it rescans the `Codex Micro` HID device.
4. Grant Accessibility to Joy Harness and Input Monitoring to Codex Desktop.

### 4. Verify

```bash
task status
# Or: cat ~/.agent-deck/status.json
```

A healthy complete connection includes at least:

```json
{
  "accessibility": true,
  "haptics": true,
  "mode": "physical-codex-micro",
  "rp2040": true
}
```

`haptics: false` means the current controller has no available Core Haptics engine; regular button input still works. `accessibility: false` disables mouse and system-key actions but does not affect RP2040/Codex Micro input.

Test one haptic state and the full sequence:

```bash
~/.agent-deck/bin/joy-harness-send waiting
task demo
```

Finally, open a task in Codex Desktop and verify approval with `LT + A`, rejection with `LT + B`, slot switching with LB/RB, and push-to-talk by holding Menu/Options.

## Default Controls

Open **Joy Harness > Settings** from the macOS menu bar, or select the gear in the mapping area, to customize buttons and LT combinations. Settings apply immediately and are stored in the current user's preferences. **Restore Default Mapping** restores the behavior below.

### Mouse and System Controls

| Input | Action | Accessibility required |
|---|---|---|
| Left stick | Move the macOS pointer at 120 Hz with a dead zone and progressive acceleration | Yes |
| LT + left stick | Vertical and horizontal scrolling with speed based on stick travel | Yes |
| Hold L3 | Temporarily increase pointer speed to `1.8x` | Yes |
| A press/release | Left mouse button, including hold and drag | Yes |
| B press/release | Right mouse button, including hold and drag | Yes |
| R3 press/release | Middle mouse button | Yes |
| X | Backspace with system-rate key repeat | Yes |
| Y | Escape | Yes |
| Xbox: LT + RT; PlayStation: L2 + R2 | Enter | Yes |
| LT + L3 | Copy (`Command-C`) | Yes |
| LT + R3 | Paste (`Command-V`) | Yes |
| Xbox: Options/View; PlayStation: Create | Lark screenshot (`Command-Shift-A`) | Yes |
| D-pad Up press/release | Right Command press/release, useful for voice-input tools | Yes |

These actions target the foreground application, not only Codex Desktop. LT is a function modifier: it changes the left stick to scrolling and L3/R3 to copy/paste. The Lark screenshot action requires Lark to be running with its shortcut set to `Command-Shift-A`; it can be remapped if the controller driver does not expose Options/View/Create.

### Codex Micro Controls

| Input | Micro input | Action |
|---|---|---|
| Xbox: LT + A; PlayStation: L2 + Cross | `ACT07` | Approve the current permission request |
| Xbox: LT + B; PlayStation: L2 + Circle | `ACT08` | Reject the current permission request |
| Xbox: LT + Y; PlayStation: L2 + Triangle | Keyboard input | Type `yes` without submitting |
| Xbox: LT + X; PlayStation: L2 + Square | Keyboard input | Type `no` without submitting |
| LB / RB | `AG00`-`AG05` | Select previous/next task slot with wraparound |
| LT + Up / Left / Down / Right | `AG00`-`AG03` | Select task slots 1/2/3/4 counterclockwise |
| LT + LB / RB | `AG04` / `AG05` | Select task slots 5/6 |
| Hold/release Menu or Options | `ACT10` press/release | Native Codex Desktop push-to-talk |
| Hold/release DualSense/DualShock touchpad | `ACT10` press/release | Alternate PlayStation push-to-talk input |
| RT / R2 past the resistance wall | `ACT12` | Focus Codex Desktop after the confirmation travel point |
| D-pad Left/Down/Right without LT and right stick | `v.oai.rad` | Radial input as angle and magnitude |

Joy Harness reads the six most recent task names and ordering through the read-only Codex app-server `thread/list` method. Local state stores only display names, or a first-message summary for unnamed tasks, and never stores full conversation content.

### Haptic Feedback

| Event | Feedback |
|---|---|
| Switch task slots | 1-6 short pulses indicate the selected slot |
| RT/R2 crosses the trigger point | Graduated feel followed by a short confirmation |
| Dashboard or CLI test | Diagnostic patterns for `busy`, `waiting`, `done`, and `error` |

Joy Harness does not subscribe to the Codex task lifecycle and does not automatically vibrate when a task starts, waits for approval, or completes.

## Dashboard

Joy Harness is a background app with a window. Closing the window does not quit the process, and the LaunchAgent keeps it running. The dashboard shows:

- Six task slots, the active slot, and the full controller mapping.
- Controller name, haptic availability, RP2040 connection, and physical Codex Micro mode.
- Accessibility and voice-input diagnostics.
- Controls to open the active task and test haptic states.

Dashboard task commands require a connected RP2040. Task names come from Codex app-server, with first-message summaries used for unnamed tasks.

## Commands

| Command | Purpose |
|---|---|
| `task build` | Build the release macOS executable |
| `task dmg -- 0.2.1` | Build a versioned macOS DMG and SHA-256 checksum |
| `task run` | Run Joy Harness in the foreground with SwiftPM |
| `task install` | Build and install the app and LaunchAgent |
| `task firmware` | Build the RP2040 UF2 firmware |
| `task flash` | Copy firmware to an RP2040 in BOOTSEL mode |
| `task status` | Print `~/.agent-deck/status.json` |
| `task send -- waiting` | Send one haptic state manually |
| `task demo` | Play every haptic state in sequence |
| `task test` | Run Swift and Python tests |

The CLI can also inspect the daemon and control slots:

```bash
python3 bin/joy-harness-send ping
python3 bin/joy-harness-send status
python3 bin/joy-harness-send --action slot-next
python3 bin/joy-harness-send --action slot-previous
python3 bin/joy-harness-send --action slot-open
python3 bin/joy-harness-send error --note manual-test
```

## Development

Build the `.app` and launch it without the LaunchAgent:

```bash
./scripts/build_and_run.sh
```

Additional modes:

```bash
./scripts/build_and_run.sh --verify
./scripts/build_and_run.sh --logs
./scripts/build_and_run.sh --debug
```

The script first stops installed Joy Harness/AgentDeck processes and LaunchAgents to avoid contention for the Unix socket or RP2040 serial port. Run `task install` afterward to restore the background service.

Create a release image for the current Mac architecture with:

```bash
task dmg -- 0.2.1
# Or: bash scripts/package_dmg.sh 0.2.1
```

Artifacts are written to `dist/`. The package script verifies the app signature, `Info.plist`, and DMG integrity. Public distribution without Gatekeeper warnings requires a Developer ID signature and Apple notarization.

## Installation Footprint

`scripts/install.sh` creates or updates:

| Path | Content |
|---|---|
| `~/.agent-deck/Joy Harness.app` | Signed Joy Harness app |
| `~/Library/LaunchAgents/tech.joyharness.daemon.plist` | Login LaunchAgent |
| `~/.agent-deck/bin/` | App entry point and CLI |
| `~/.local/bin/joy-harness-send` | Symlink to the installed CLI |
| `~/.agent-deck/status.json` | Connection, permission, slot, and state snapshot |
| `~/.agent-deck/pad.sock` | Local CLI/app Unix socket with `0600` permissions |
| `~/.agent-deck/daemon.log` | Background log |

When upgrading an older hooks/`notify` installation, the installer backs up the affected configuration before removing obsolete Joy Harness entries. New installations do not write to `~/.codex/hooks.json` or Codex `notify` configuration. Legacy `agent-deck-send`, `AgentDeck`, and `~/.agent-deck` names remain for upgrade compatibility.

## Troubleshooting

### Firmware tools or Ninja are missing

```bash
brew install cmake ninja arm-none-eabi-gcc
```

Confirm that `cmake`, `ninja`, and `arm-none-eabi-gcc` are on `PATH`.

### The `RPI-RP2` volume is missing

Disconnect the RP2040, hold `BOOTSEL`, reconnect it, and retry after the `RPI-RP2` volume appears in Finder. If it still does not appear, try a known data-capable USB cable.

### `rp2040` remains `false` in `status.json`

Confirm that firmware is flashed and the board has left BOOTSEL mode, then inspect:

```bash
tail -f ~/.agent-deck/daemon.log
ls /dev/cu.usbmodem* /dev/cu.usbserial* 2>/dev/null
```

With multiple serial devices, select one temporarily:

```bash
AGENT_DECK_RP2040_PORT=/dev/cu.usbmodemXXXX task run
```

### Controller input works but haptics do not

- Confirm that `haptics` is `true` in `status.json`.
- Prefer Bluetooth for Xbox Series controllers.
- Run `~/.agent-deck/bin/joy-harness-send waiting` to test the local haptic path.
- Check `daemon.log` for `no haptic engine` or `rumble skipped`.

### Mouse or system shortcuts do not work

Allow Joy Harness under **System Settings > Privacy & Security > Accessibility**, then restart the app. This permission affects mouse and system shortcuts only, not RP2040 Codex Micro actions.

### Codex does not receive slot or approval input

- Confirm that `rp2040` is `true`.
- Fully quit and restart Codex Desktop so it rescans HID devices.
- Grant Input Monitoring to Codex Desktop.
- Confirm that the installed Codex Desktop version supports native Codex Micro.

## Project Structure

```text
Sources/JoyHarness/             macOS app, dashboard, controller, mouse, haptics, and serial bridge
Sources/JoyHarness/Resources/   dashboard images, logo, and macOS app icon
firmware/rp2040/                RP2040 Codex Micro firmware and USB descriptors
bin/joy-harness-send            local Unix socket CLI
scripts/install.sh              release build, install, migration cleanup, and LaunchAgent setup
scripts/build_rp2040_firmware.sh
scripts/flash_rp2040_firmware.sh
scripts/package_dmg.sh          versioned macOS DMG and SHA-256 checksum
scripts/build_and_run.sh        foreground `.app` build and debugging entry point
tests/                          Swift and Python tests
docs/research/                  controller audio, wireless, and agent integration research
Taskfile.yml                    common task entry points
```

Research notes:

- [DualSense Bluetooth microphone feasibility](docs/research/dualsense-wireless-microphone.md)
- [DualSense wireless USB and USB-over-IP options](docs/research/dualsense-wireless-usb-options.md)
- [Xbox controller 3.5 mm headset support on macOS](docs/research/xbox-controller-headset-macos.md)
- [Cursor Agent and Pi Agent integration feasibility](docs/research/cursor-pi-agent-integration.md)

## Current Limitations

- Joy Harness depends on macOS-only GameController, Core Haptics, SwiftUI, and CoreGraphics APIs. Windows and Linux are not supported.
- macOS provides no public controller-lighting API, so feedback uses haptics only.
- Joy Harness does not use Codex Hooks or `notify`; approvals and task-slot actions are handled directly by Codex Micro.
- Joy Harness reads task IDs, display names, and first-message summaries for unnamed tasks, but does not retain full Codex conversation data. Slot ordering remains managed by Codex app-server.
- The daemon continues running and updating `status.json` without a controller; haptic requests are logged as skipped.
- Push-to-talk is entirely managed by Codex Desktop. Joy Harness does not record audio.
