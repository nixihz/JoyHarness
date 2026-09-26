# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

[简体中文](CHANGELOG.zh-CN.md)

## [0.7.1] - 2026-09-26

### Added
- Add a PS/Home Harness switcher for Codex, Claude, Cursor, and Pi, with immediate presentation, independent mappings, application associations, and unique foreground-app matching.

### Fixed
- Release active mapped outputs while the Harness switcher is open and prevent non-Codex Harnesses from sending Codex Micro press or radial input.

### Changed
- Maintenance and performance improvements.

## [0.7.0] - 2026-09-21

### Added
- Support simultaneous standard game controller and Xiaomi remote sessions with a connected-device picker and independent mapping profiles.
- Add an on-demand connection inspector, fixed dashboard workspace, and System, Light, and Dark appearance preferences.

### Fixed
- Prevent Xiaomi remote mappings from also emitting the native backquote or F5 key by correctly matching Bluetooth services; restore native keys in Native Mode and on exit.
- Keep retrying native key suppression when the remote's HID event service appears late; stop retrying after success or when leaving mapping mode.
- Store Xiaomi mappings, application targets, and recorded shortcuts separately from gamepads, preserving existing remote settings across reconnects and upgrades.
- Accept the final BLE audio after the voice key is released and wait for playback before releasing the recording shortcut; immediately cancel audio on disconnect, disable, or Native Mode.
- Retry Xiaomi HID discovery from the Dashboard's rescan action after an initial open failure.

## [0.6.1] - 2026-09-20

### Fixed
- Fixed downloaded apps crashing at startup when SwiftPM searched the app root or build machine for resources instead of Contents/Resources.
- Validate version and controller artwork by executing the relocated packaged app before creating a DMG.

## [0.6.0] - 2026-09-19

### Added
- Support for Xiaomi Bluetooth Remote 2 Pro (RC003-MS), with voice input through a bundled virtual microphone component and volume controls.
- Configurable global shortcuts for all six task slots.

### Changed
- Redesigned the controller dashboard with a fixed 744 × 600 layout, device artwork, live input feedback, per-button mappings, and expandable connection details.
- Haptic tests now produce finite feedback without changing task state.

### Fixed
- Bundle the signed microphone driver directly with the app and enable it through administrator authorization, removing the installer certificate requirement.
- Pointer movement across displays with offset positions.
- Duplicate Joy-Con HID snapshots.
- Handling of typed controller actions.
- Resource staging in packaged macOS apps.

## [0.5.1] - 2026-09-01

### Fixed
- Recover controller pointer movement when the display-synchronized clock stalls.
- Create the local runtime directory before acquiring the single-instance lock.

### Changed
- Reduce controller pointer latency and coalesce redundant Joy-Con input refreshes.

## [0.5.0] - 2026-08-30

### Added
- Runtime recovery for the local Codex app-server process, including bounded retries and predictable handling of malformed responses and timeouts.
- Bounded, atomic buffering for local socket, serial, and RP2040 firmware transport paths.
- Shared CI and release validation, local protocol documentation, mapping migration coverage, and expanded regression tests.

### Changed
- Controller pointer updates now use a display-synchronized clock, adapt to display changes, remain independent of main-thread stalls, and preserve delayed movement through bounded catch-up.
- Runtime lifecycle cleanup, status freshness, controller mapping persistence, local protocols, and firmware transport reliability are more robust.

### Fixed
- Shortcut modifier flags are cleared on key-up so Command and other modifiers do not leak into subsequent controller-generated mouse clicks.

## [0.4.0] - 2026-08-28

### Added
- Full support for first-generation Nintendo Switch Joy-Con controllers:
  - Single Joy-Con (L/R) in horizontal or vertical grip with independent orientation persistence.
  - Paired Joy-Con (L+R) aggregate logical controller.
  - IOHID shoulder button disambiguation (SL/SR vs L/ZL vs R/ZR) without losing public GameController fields.
  - 6-axis IMU telemetry (acceleration G and gyro DPS) parsing and reporting.
  - Dedicated Joy-Con artwork and dynamic button highlight layouts in the dashboard.
- Native Gamepad Mode (passthrough):
  - Automatic suppression of keyboard/mouse mapping when whitelist game apps (e.g. JoyDSH) are in the foreground.
  - Manual mode toggle via PS / Home button with dedicated haptic confirmation feedback.
  - New "Native Mode" tab in Settings with app whitelist management.
- Pointer sensitivity configuration:
  - Independent Normal, Fast (boost), and Slow (precision/touchpad) slider adjustments in Settings.
- Multi-controller concurrent haptics across all connected sides in a pair.
- Real-time controller button press feedback on the dashboard.
- Diagnostic script `scripts/verify_joycon_pointer.sh` for stick-to-pointer physical direction verification.

## [0.3.0] - 2026-08-26

### Added
- Recordable keyboard shortcuts, supporting modifier key combinations (Command, Control, Option, Shift, Fn) and optional notes.
- Native double-click and triple-click recognition for controller mouse buttons.

### Changed
- DualSense / DualShock touchpad button default changed from push-to-talk to left mouse click (push-to-talk remains available as a custom mapping).

## [0.2.5] - 2026-08-25

### Fixed
- Controller pointer coordinate drift beyond screen display bounds.

## [0.2.4] - 2026-08-24

### Added
- `L3` hold pointer speed boost (`1.8x`).
- DualSense / DualShock touchpad sliding for slow precision aiming.
- Developer ID Application codesigning and Apple notarization in release automation.

### Changed
- Dashboard and Settings windows updated with compact macOS native title bars.
- Launch-at-login moved from obsolete LaunchAgent to in-app settings management.

## [0.2.3] - 2026-08-24

### Added
- Customizable `LT + Right Stick` direction mappings (defaults left/right to browser back/forward `Command-[` / `Command-]`).
- Open Application mapping action with per-input app picker.
- Natural vs Traditional scroll direction preference in Settings.

## [0.2.2] - 2026-08-24

### Added
- General settings pane with launch-at-login toggle.
- Clearer Settings entry points from dashboard and menu bar.

## [0.2.1] - 2026-08-24

### Fixed
- Launch crash in release builds caused by eagerly loading the SwiftPM resource bundle when the app bundle version was already present.

## [0.2.0] - 2026-08-23

### Added
- `LT + RT` for Enter, `LT + L3/R3` for copy/paste, and Options/View for Lark screenshot (`Command-Shift-A`).
- Redesigned three-column dashboard with connection health status.
- Centralized `VERSION` metadata resource for the app, installer, and DMG.
- Graduated Xbox Impulse Trigger feedback and DualSense R2 resistance wall adaptive feedback.
- Simplified Chinese and English bilingual interface support.

## [0.1.0] - 2026-08-23

### Added
- Initial public release of Joy Harness.
- Six Codex Micro task slots with sequential and direct switching, approval (`ACT07`), and rejection (`ACT08`).
- RP2040 USB CDC serial bridge and Vendor HID integration with Codex Desktop.
- Gamepad mouse control, stick scrolling, mouse buttons, Backspace, and Escape.
- Native push-to-talk via Menu/Options button (`ACT10`).
- Local diagnostics dashboard with battery, haptics, RP2040, and permissions monitoring.
- DMG packaging workflow.

[0.7.1]: https://github.com/nixihz/JoyHarness/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/nixihz/JoyHarness/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/nixihz/JoyHarness/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/nixihz/JoyHarness/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/nixihz/JoyHarness/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nixihz/JoyHarness/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/nixihz/JoyHarness/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nixihz/JoyHarness/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/nixihz/JoyHarness/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/nixihz/JoyHarness/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/nixihz/JoyHarness/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/nixihz/JoyHarness/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/nixihz/JoyHarness/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nixihz/JoyHarness/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nixihz/JoyHarness/releases/tag/v0.1.0
