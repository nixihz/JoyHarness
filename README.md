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

1. **Joy Harness for macOS** reads controller input, controls the mouse, plays haptic feedback, and provides a controller and input dashboard.
2. **RP2040 firmware** turns a Raspberry Pi Pico-compatible board into a `Codex Micro` device recognized by Codex Desktop and receives controller actions from Joy Harness over serial.

Both the controller and RP2040 connect to the Mac; no wiring is required between them. Joy Harness starts a read-only Codex app-server subprocess to retrieve task names and ordering. It does not proxy Codex actions or emulate Codex Micro with keyboard events. Slot selection, approvals, and push-to-talk reach Codex Desktop through the RP2040's native Vendor HID interface. Mouse actions and system shortcuts are sent directly to the foreground macOS application.

## Download

The current release is **v0.7.0** for Apple Silicon Macs (arm64) running macOS 13.0 or later:

- [Download Joy-Harness-v0.7.0-macOS-arm64.dmg](https://github.com/nixihz/JoyHarness/releases/download/v0.7.0/Joy-Harness-v0.7.0-macOS-arm64.dmg)
- [Download the SHA-256 checksum](https://github.com/nixihz/JoyHarness/releases/download/v0.7.0/Joy-Harness-v0.7.0-macOS-arm64.dmg.sha256)
- [View the v0.7.0 release](https://github.com/nixihz/JoyHarness/releases/tag/v0.7.0)

The DMG contains `Joy Harness.app` for manual launch. Use the [source installation](#install-from-source) if you need the local CLI or RP2040 firmware build and flashing tools. See the release notes for signing and notarization details.

Verify the download with:

```bash
shasum -a 256 -c Joy-Harness-v0.7.0-macOS-arm64.dmg.sha256
```

## What's New in v0.7.0

- Keeps standard game controllers and the Xiaomi RC003-MS remote connected at the same time with independent input sessions and selectable mapping profiles.
- Adds a fixed 744 x 600 dashboard workspace, an on-demand connection inspector, and System, Light, and Dark appearance preferences.
- Prevents mapped Xiaomi buttons from leaking native backquote or F5 events and keeps suppression healthy across delayed discovery, reconnects, and Native Mode transitions.
- Preserves Xiaomi mappings, application targets, and recorded shortcuts independently from standard gamepads across reconnects and upgrades.
- Completes buffered voice audio before releasing push-to-talk, while cleaning up immediately on disconnect, disable, or Native Mode.

## What's New in v0.6.1

- Fixed a startup crash in the downloaded app caused by resource bundle lookup depending on the build machine.
- Added a check that loads packaged resources from a relocated app before publishing.

## What's New in v0.6.0

- Redesigned the controller dashboard with a fixed 744 × 600 work area, device artwork, live input feedback, per-button mappings, and a right-side connection inspector.
- Added Xiaomi Bluetooth Remote 2 Pro (RC003-MS) support, including voice input through the bundled microphone component and volume controls.
- Added configurable global shortcuts for all six task slots.
- Fixed pointer movement across offset displays, duplicate Joy-Con HID snapshots, typed controller actions, and app resource packaging.

## What's New in v0.5.1

- Automatically recovers controller pointer movement when the display-synchronized clock stalls or the display configuration changes.
- Makes controller pointer movement more responsive and coalesces redundant Joy-Con input refreshes to reduce paired-controller latency.
- Fixes first launch when the local runtime directory does not exist yet.

## What's New in v0.5.0

- Made controller pointer motion display-synchronized and resilient to main-thread stalls, display changes, and short scheduling delays.
- Hardened local I/O, Codex process recovery, lifecycle cleanup, status freshness, controller mapping migrations, and RP2040 transport buffering.
- Fixed shortcut modifier keys remaining active after key release and affecting later controller-generated clicks.
- Added shared CI and release validation, protocol documentation, and substantially broader regression coverage.

See [docs/CHANGELOG.md](docs/CHANGELOG.md) for full historical release notes.

## What's New in v0.4.0

- Added full support for first-generation Nintendo Switch Joy-Con controllers, including single Joy-Con (L/R) in horizontal or vertical grip, combined Joy-Con pairs, Nintendo physical labels, and IOHID shoulder button disambiguation.
- Added Native Gamepad Mode (passthrough) with automatic switching for foreground game apps (such as JoyDSH) and PS / Home manual toggle.
- Added independent Normal, Fast, and Slow pointer sensitivity adjustments in Settings.
- Added multi-controller concurrent haptics and real-time controller button press feedback on the dashboard.

## What's New in v0.3.0

- Added recordable keyboard shortcuts, including modifier combinations and optional mapping notes.
- Added native double-click and triple-click behavior for controller mouse buttons.
- Changed the DualSense / DualShock touchpad button default to left click while keeping push-to-talk available as a custom mapping.

## What's New in v0.2.5

- Fixed controller pointer movement drifting past screen edges, which made the cursor take a long time to come back.

## What's New in v0.2.4

- Added an `L3` pointer speed boost and DualSense / DualShock touchpad precision pointer control.
- Simplified the app lifecycle by removing the obsolete LaunchAgent; launch at login is managed from Settings.
- Refined the dashboard and Settings windows with compact native macOS title bars and cleaner selection states.
- Added Developer ID signing and Apple notarization to the GitHub Release workflow.

## What's New in v0.2.3

- Made `LT / L2 +` right stick directions customizable; left/right default to browser back/forward (`Command-[` / `Command-]`).
- Added an Open Application mapping action with a per-input app picker.
- Added Natural vs Traditional scroll direction for `LT / L2 +` left stick scrolling in Settings.
- Hold `L3` temporarily boosts pointer speed to `1.8x`.
- DualSense / DualShock touchpad sliding moves the pointer slowly for fine aiming without holding a modifier.

## What's New in v0.2.2

- Added clearer Settings entry points and a General pane with launch-at-login.

## What's New in v0.2.1

- Fixed a launch crash in downloaded Release builds caused by eagerly loading the SwiftPM resource bundle after the version had already been found in the app bundle.

## What's New in v0.2.0

- Added `LT + RT` for Enter, `LT + L3/R3` for copy/paste, and an Options/View shortcut for Lark screenshots.
- Redesigned the dashboard into a compact three-column layout with consistent app version and connection health indicators.
- Centralized version metadata in the `VERSION` resource for the app, installer, and DMG.
- Added graduated Xbox Impulse Trigger feedback and a resistance wall for the DualSense R2 adaptive trigger.
- Added Simplified Chinese and English interfaces with system-language and manual selection modes.

## Features

- **Control Codex away from the keyboard:** switch among six Codex Micro task slots, open the active task, approve or reject permission prompts, and enter `yes` or `no`. Fast mode and task splitting can still be assigned as custom mappings.
- **Push-to-talk:** hold Menu/Options to send Codex Micro `ACT10`, then release to stop. DualSense controllers can also use the touchpad button. Recording remains native to Codex Desktop.
- **DualSense audio diagnostics:** detect the controller microphone exposed over USB and report whether it is the default macOS input. Joy Harness does not claim the recording device or change global audio settings.
- **Graduated trigger feedback:** DualSense R2 provides a light touch, a resistance wall, and a stronger confirmation after the trigger point. Xbox RT uses Impulse Trigger feedback where supported.
- **Control macOS:** move the pointer with the left stick and scroll with the right stick (or LT + left stick); hold L3 to boost pointer speed; on DualSense/DualShock, slide the touchpad for slow precise aiming; use A/B/R3 as left, right, and middle mouse buttons; use X/Y as Backspace and Escape; and access Enter, copy, and paste through the LT layer.
- **Manage six task slots:** move sequentially with LB/RB or jump directly to slots 1-6 with LT combinations. Short haptic pulses report the selected slot number.
- **Global keyboard slot shortcuts:** record or clear a shortcut for each slot in Settings → Slot Shortcuts. None are assigned by default; changes are saved and apply immediately, including in the background. Requires the app to be running and an RP2040 connection; a controller is optional.
- **Diagnose locally:** inspect controller battery and haptic support, RP2040 connection, microphone input, and Accessibility authorization from the dashboard.
- **Native Gamepad Mode (Passthrough):** automatically disable simulated mouse and key mappings when switching into specific applications (such as JoyDSH, Steam, or games) so they can directly receive raw controller events. To switch manually, assign **Toggle Native/Mapping Mode** to a button (the Xiaomi remote's Menu uses it by default); switching gives haptic feedback. Gamepad PS / Home opens the Harness switcher in mapping mode and returns to mapping mode from Native Mode.
- **Customize mappings:** assign base buttons, the D-pad, and the LT layer (including LT + right stick directions) to mouse, system, browser, app-launch, Codex Micro, slot, or disabled actions. Changes apply immediately and persist automatically.
- **Xiaomi RC003-MS:** Xiaomi Bluetooth Remote 2 Pro is detected directly through macOS IOHID. OK, Back, Menu, Voice, Home, D-pad, volume, and custom keys are available in the mapping editor; the Dashboard shows the remote-specific artwork and live highlights.
- **Run in the background:** launch at login can be enabled in Settings, and disconnected controllers or RP2040 boards are detected again while the app is running.

### Capabilities by Hardware

| Connected hardware | Available features |
|---|---|
| Joy Harness app only | Dashboard and local CLI diagnostics |
| App + controller | Mouse, scrolling, system keys, slot-confirmation haptics, and manual haptic tests |
| App + RP2040 | Select Codex Micro task slots with global keyboard shortcuts, controller approval actions are unavailable |
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
- A gamepad recognized by macOS `GameController`, or a Xiaomi Bluetooth Remote 2 Pro (`RC003-MS`) paired as a HID device. Joy Harness directly supports PS5 DualSense, PS4 DualShock 4, Xbox Series controllers, first-generation Joy-Con L/R input, and RC003-MS. Other controllers depend on the inputs and haptics exposed by macOS.
- A Raspberry Pi Pico or compatible RP2040 development board.
- A data-capable USB cable. Charge-only cables cannot flash firmware or expose serial/HID devices.

Controllers can connect over Bluetooth or USB. On the tested Xbox Series controller, haptics work on macOS 26.5.2 over **Bluetooth only**. DualSense R2 resistance is restored through the matching USB or Bluetooth HID output while Joy Harness is in the background, and remains attached when the Xiaomi remote is the selected mapping profile. DualSense microphone input requires USB. Bluetooth still supports controller input and can trigger push-to-talk while Codex records through the Mac microphone, AirPods, or another input device.

Multiple GameController devices can stay connected at the same time, and the Xiaomi RC003-MS remote can be connected alongside them. Xbox, DualSense/DualShock, and the remote keep independent input sessions, so connecting one device no longer disconnects or disables another. First-generation Joy-Con keeps its existing composition priority: when Joy-Con endpoints are present, Joy Harness presents their paired or single logical profile until they disconnect.

First-generation Joy-Con connect individually over Bluetooth. Joy Harness supports an L/R pair as one logical controller and either side alone. For a single Joy-Con, choose **Horizontal** or **Vertical** in the main controller-mapping panel; left and right preferences persist independently, while paired mode ignores them. A Joy-Con (L) vertical trace established the Apple axis basis used by the current transform. The corrected pointer output, right-only, horizontal, and paired modes still require final hardware validation before removing the experimental label; haptics and motion remain conditional on what macOS exposes.

The Xiaomi RC003-MS pairs through **System Settings > Bluetooth** and presents button events through IOHID rather than `GameController`. Start Joy Harness before pressing buttons; the Dashboard should change to `小米蓝牙遥控器` and show the remote artwork. Defaults target voice coding: the D-pad sends matching keyboard arrows, OK sends Enter, Back sends Backspace, Home sends Esc, Volume −/+ selects previous/next task slots, Voice holds Right Command for Spokenly, and Custom triggers Feishu Screenshot. Menu toggles native/mapping mode. Apply this layout with **Settings > Customize Buttons > Restore Default Mappings**; existing custom mappings are preserved on upgrade.
If Karabiner-Elements is installed, disable **Modify events** for this remote in its Devices settings so it releases the HID device. Grant Joy Harness Input Monitoring; `./scripts/build_and_run.sh --logs` shows remote button presses and releases.
The remote's built-in microphone connects directly over ATVV BLE. Enable the bundled microphone component in **Settings > General > Remote Microphone**, then select it as your input. The signed driver is bundled directly with the app; no separate installer or voice bridge is required. First-time installation needs administrator authentication and briefly restarts audio. See the [microphone implementation and validation notes](docs/xiaomi-remote-voice.md).
In mapping mode, the remote's 12 supported keys trigger only Joy Harness mappings, without also sending native arrows, menu commands, or volume changes. Other keyboards are unaffected. The helper retries if the HID event service appears late. Native mode and app exit restore the original system mappings; the helper also restores them if the app crashes. Run `python3 scripts/verify_xiaomi_remote_volume.py` for the physical volume regression check.
Remote mappings, application targets, and recorded shortcuts have their own saved profile and survive reconnects. If initial HID discovery failed, use the Dashboard's rescan action after granting Input Monitoring access.

With the freshly built app running, verify the physical stick-to-pointer directions using the matching hardware scenario:

```bash
./scripts/verify_joycon_pointer.sh left-horizontal
./scripts/verify_joycon_pointer.sh left-vertical
./scripts/verify_joycon_pointer.sh right-horizontal
./scripts/verify_joycon_pointer.sh right-vertical
./scripts/verify_joycon_pointer.sh pair
```

The verifier checks the active Joy-Con mode first, then measures the pointer displacement for physical up, right, down, and left. Paired verification uses the left Joy-Con stick because the right stick scrolls instead of moving the pointer.

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

The easiest option is to copy this repository URL into Codex:

<https://github.com/nixihz/JoyHarness>

Then ask:

> Help me flash the RP2040 firmware from this repository onto my board.

Codex can decide how to access the repository, inspect the included instructions and scripts, and guide you when physical action is required. Keep the RP2040 connected with a data-capable USB cable and follow its prompts.

This repository only provides and supports the bundled RP2040 firmware. For a different microcontroller, you may ask Codex to use this implementation as a reference, but you will need to develop, build, and flash that adaptation yourself.

To build and flash manually, run:

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

The installer builds and launches the release app. Upgrades remove obsolete Joy Harness Codex hooks and `notify` fan-out while preserving unrelated tool configuration. Deployment stops older Joy Harness or AgentDeck instances before launching a single new instance, preventing multiple apps from competing for the controller, serial port, or Unix socket. Enable launch at login from the app's General settings when desired.

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

## Harness Switching

Joy Harness keeps independent controller mappings for Codex, Claude, Cursor, and Antigravity. Press PS/Home, even while Joy Harness is in the background, to open the Harness switcher, which shows each associated app's icon. Move with D-pad Left/Right, LB/RB, or the left stick, then press A to confirm. The last card, **Main Window**, brings up the Joy Harness main window, reopening it if it was closed, instead of switching Harness; open settings from there. Press PS/Home again or B to close it without switching; clicking anywhere, switching apps, or changing Spaces also closes it.

Use **Settings > Harness** to enable Harnesses, associate macOS applications, and choose whether a confirmed selection activates the associated app. A uniquely matched foreground application switches the active Harness automatically; ambiguous terminal apps keep the current manual selection. Codex retains existing mapping storage, while the other Harnesses start without Codex Micro, task-slot, or radial actions and can be customized independently.

## Default Controls

Open **Joy Harness > Settings** from the macOS menu bar, or select the gear in the mapping area, to customize buttons and LT combinations. Settings apply immediately and are stored in the current user's preferences. **Restore Default Mapping** restores the behavior below.

Any mappable input can use **Record Shortcut...**. Select **Click to Record**, then press a single key or a combination using Command, Control, Option, Shift, or Fn. An optional note can describe the shortcut's purpose. The shortcut and note are saved in the current user's preferences; playback targets the foreground application and requires Accessibility permission.

### Mouse and System Controls

| Input | Action | Accessibility required |
|---|---|---|
| Left stick | Move the macOS pointer at 120 Hz with a dead zone and progressive acceleration | Yes |
| DualSense / DualShock touchpad slide | Slow relative pointer movement for fine aiming; no modifier required. Touchpad click remains the mapped touchpad button action (default left mouse button) | Yes |
| Right stick | Vertical and horizontal scrolling in every Harness, no modifier; works while the left stick moves the pointer. Same speed and Natural/Traditional direction as LT + left stick | Yes |
| LT + left stick | Vertical and horizontal scrolling with speed based on stick travel; choose Natural or Traditional direction in Settings. The only scroll input on a single Joy-Con | Yes |
| Hold L3 | Temporarily use the configurable Fast pointer sensitivity (default `1.8x`) | Yes |
| A press/release | Left mouse button, including hold and drag | Yes |
| B press/release | Right mouse button, including hold and drag | Yes |
| R3 press/release | Middle mouse button | Yes |
| X | Backspace with system-rate key repeat | Yes |
| Y | Escape | Yes |
| Xbox: LT + RT; PlayStation: L2 + R2 | Enter | Yes |
| LT + L3 | Copy (`Command-C`) | Yes |
| LT + R3 | Paste (`Command-V`) | Yes |
| LT + right stick Left / Right | Browser back / forward (`Command-[` / `Command-]`) | Yes |
| LT + right stick Up / Down | Disabled by default; assign open app or any other mapped action in Settings | Depends on action |
| Xbox: Options/View; PlayStation: Create | Lark screenshot (`Command-Shift-A`) | Yes |
| D-pad Up press/release | Right Command press/release, useful for voice-input tools | Yes |

These actions target the foreground application, not only Codex Desktop. LT is a function modifier: it changes the left stick to scrolling, L3/R3 to copy/paste, and LT + right stick left/right to browser back/forward. Hold L3 alone to boost pointer speed. While LT is held, the right stick stops scrolling and triggers its four direction mappings instead. The Lark screenshot action requires Lark to be running with its shortcut set to `Command-Shift-A`; it can be remapped if the controller driver does not expose Options/View/Create.

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
| Hold/release DualSense/DualShock touchpad (when mapped to push-to-talk) | `ACT10` press/release | Optional PlayStation push-to-talk input |
| RT / R2 past the resistance wall | `ACT12` | Focus Codex Desktop after the confirmation travel point |
| D-pad Left/Down/Right without LT | `v.oai.rad` | Radial input as angle and magnitude; the right stick scrolls instead |

Joy Harness reads the six most recent task names and ordering through the read-only Codex app-server `thread/list` method. Local state stores only display names, or a first-message summary for unnamed tasks, and never stores full conversation content.

### Haptic Feedback

| Event | Feedback |
|---|---|
| Switch task slots | 1-6 short pulses indicate the selected slot |
| RT/R2 crosses the trigger point | Graduated feel followed by a short confirmation |
| Dashboard or CLI test | Diagnostic patterns for `busy`, `waiting`, `done`, and `error` |

Joy Harness does not subscribe to the Codex task lifecycle and does not automatically vibrate when a task starts, waits for approval, or completes.

## Dashboard

Joy Harness is a background app with a window. Closing the window does not quit the process; explicitly quitting the app stops it without an automatic restart.

The dashboard places the displayed input device beside its individual button mappings. It adapts to Xiaomi remotes, DualSense, DualShock, Xbox, single or paired Joy-Con, and generic controllers. Single Joy-Con has a native horizontal/vertical grip picker. The main window keeps a fixed 744 × 600 pt work area; only the button mapping list scrolls inside its bounded panel.

When more than one device is connected, the dashboard header shows a device switcher, and the dashboard follows whichever device most recently had a button pressed. You can also choose the shown device in that switcher. Devices with the same name are numbered. The switcher only changes what the dashboard shows: every connected device keeps receiving input with its own mappings and trigger feedback, and the device chosen with the **Configure Device** picker at the top of **Settings > Customize Buttons** stays put. Button presses never change that picker; it changes only when you pick another device there or its device disconnects, so you can navigate Settings with one controller while configuring another device. Xiaomi and Joy-Con profiles are stored separately. Xbox and PlayStation standard gamepads use the shared standard-gamepad mapping profile so their common controls remain consistent.

The status snapshot keeps the displayed device's family in `controller_family` and adds `controller_devices`, an array containing each connected device's process-local `id`, `name`, `family`, `source`, and a `selected` flag marking the displayed device. The ID is valid for the current app session and is intended for UI/state correlation, not long-term hardware identification.

Connection details open on demand from the trailing toolbar button without scrolling or compressing the 744 × 600 work area. The inspector retains device capabilities, Joy-Con endpoints, battery, adapter connection, operating mode, Accessibility and Input Monitoring permissions, voice input, recording ownership, and four finite haptic tests. Unknown or stale data is labeled explicitly. Native gamepad mode pauses mappings while retaining physical input feedback.

Tasks remain in the target application. The dashboard has no task list, slot cards, task titles, state banners, or task navigation. Slot names can still appear as configurable mapping actions. Haptic tests do not change task state.

See [DESIGN.md](DESIGN.md) and [implementation notes](docs/design/controller-dashboard.md). For an isolated visual audit of all eight device families, run:

```bash
DASHBOARD_RENDER_DIR=/tmp/joy-dashboard-renders swift test --filter DashboardRenderingTests
```

Run this audit separately from the full test suite: native view rendering occupies the main thread and would interfere with real-time socket and key-repeat tests. It uses temporary status fixtures and isolated preferences, with no simulated device mode in the shipped app.

## Commands

| Command | Purpose |
|---|---|
| `task build` | Build the release macOS executable |
| `task dmg -- 0.7.0` | Build a versioned macOS DMG and SHA-256 checksum |
| `task run` | Build and launch the canonical signed app |
| `task install` | Build, install, and launch the app |
| `task firmware` | Build the RP2040 UF2 firmware |
| `task flash` | Copy firmware to an RP2040 in BOOTSEL mode |
| `task ci` | Run tests, ShellCheck, and a release build |
| `task release-check` | Validate release versions and artifact naming |
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

Build the `.app` and launch it directly:

```bash
./scripts/build_and_run.sh
```

Additional modes:

```bash
./scripts/build_and_run.sh --verify
./scripts/build_and_run.sh --logs
./scripts/build_and_run.sh --debug
```

The script first builds a signed app, stops installed Joy Harness/AgentDeck processes, and replaces the canonical test app at `/Applications/Joy Harness.app`. It prints that exact path and signing identity before launch. Use this app for every hardware test; do not open the `.app` left under `dist/` by the DMG packaging task.

Create a release image for the current Mac architecture with:

```bash
task dmg -- 0.7.0
# Or: bash scripts/package_dmg.sh 0.7.0
```

Artifacts are written to `dist/`. The package script verifies the app signature, `Info.plist`, and DMG integrity. Public distribution without Gatekeeper warnings requires a Developer ID signature and Apple notarization.

## Installation Footprint

`scripts/install.sh` creates or updates:

| Path | Content |
|---|---|
| `/Applications/Joy Harness.app` | Signed Joy Harness app used by local installs and hardware tests |
| `~/.agent-deck/bin/` | App entry point and CLI |
| `~/.local/bin/joy-harness-send` | Symlink to the installed CLI |
| `~/.agent-deck/status.json` | Connection, permission, slot, and state snapshot |
| `~/.agent-deck/pad.sock` | Local CLI/app Unix socket with `0600` permissions |

The development and install commands require Developer ID and use the same canonical app path. The first successful local signature pins the identity in `~/.agent-deck/signing-identity`; later identity changes fail instead of silently changing trust. Grant **Input Monitoring** and **Accessibility** to `/Applications/Joy Harness.app`. Keeping the path and signing requirement stable helps preserve macOS authorization across rebuilds; migrating from an older signature may require reauthorization. Settings > General shows the current app's path and a button to reveal it in Finder.

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
scripts/install.sh              release build, install, launch, and migration cleanup
scripts/build_rp2040_firmware.sh
scripts/flash_rp2040_firmware.sh
scripts/package_dmg.sh          versioned macOS DMG and SHA-256 checksum
scripts/build_and_run.sh        foreground `.app` build and debugging entry point
scripts/verify_joycon_pointer.sh
                                hardware stick-to-pointer direction verifier
tests/                          Swift and Python tests
docs/research/                  controller audio, wireless, and agent integration research
docs/adr/                       architecture decision records
Taskfile.yml                    common task entry points
```

Mapping reference: [every controller and Harness default mapping, with a test checklist and known issues](docs/controller-mappings.md) (Chinese).

Research notes:

- [DualSense Bluetooth microphone feasibility](docs/research/dualsense-wireless-microphone.md)
- [DualSense wireless USB and USB-over-IP options](docs/research/dualsense-wireless-usb-options.md)
- [Xbox controller 3.5 mm headset support on macOS](docs/research/xbox-controller-headset-macos.md)
- [Cursor Agent and Pi Agent integration feasibility](docs/research/cursor-pi-agent-integration.md)
- [First-generation Nintendo Joy-Con support](docs/research/nintendo-switch-generation-1-controller-support.md)

## Current Limitations

- Joy Harness depends on macOS-only GameController, Core Haptics, SwiftUI, and CoreGraphics APIs. Windows and Linux are not supported.
- macOS provides no public controller-lighting API, so feedback uses haptics only.
- Joy Harness does not use Codex Hooks or `notify`; approvals and task-slot actions are handled directly by Codex Micro.
- Joy Harness reads task IDs, display names, and first-message summaries for unnamed tasks, but does not retain full Codex conversation data. Slot ordering remains managed by Codex app-server.
- The daemon continues running and updating `status.json` without a controller; haptic requests are logged as skipped.
- Push-to-talk is entirely managed by Codex Desktop. Joy Harness does not record audio.
