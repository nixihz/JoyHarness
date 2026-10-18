# DualSense Audio for macOS

Use a PS5 DualSense controller's **built-in speaker and microphone** on a Mac over Bluetooth.

The driver adds two sound devices that show up whenever the controller is connected:

- **DualSense Speaker**: an output device. Pick it in System Settings → Sound, or in any app.
- **DualSense Microphone**: an input device for Voice Memos, voice chat, dictation and other apps.

macOS has no built-in support for the DualSense's speaker or microphone over Bluetooth. This project talks to the
controller's Bluetooth audio protocol directly.

Tested on macOS 26.6 (Apple silicon) with a retail DualSense. Not affiliated with or endorsed by Sony.

## Before you start: the microphone needs Game Mode

macOS normally gives game controllers too little Bluetooth bandwidth for the microphone, so about half of the
audio is lost and speech is unintelligible. The speaker isn't affected.

The mic is clear while macOS **Game Mode** is on. Game Mode turns on by itself while a fullscreen game is in front.
To use the mic outside games, turn Game Mode on with Apple's `gamepolicyctl` tool, which comes with
[Xcode](https://apps.apple.com/app/xcode/id497799835):

```sh
# Force Game Mode on
/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl game-mode set on

# Back to normal (automatic)
/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl game-mode set auto
```

Forced Game Mode applies to the whole Mac: it gives background tasks lower priority and doubles the Bluetooth
sampling rate for controllers and AirPods. Set it back to `auto` when you're done.

## Requirements

- A Mac with Apple silicon, running macOS 26 or later
- A DualSense controller (not DualSense Edge)
- Xcode command line tools, [Homebrew](https://brew.sh), and Homebrew's `opus`, `cmake` and `ninja` packages
- An administrator password, to install the driver

## Install

**1. Pair the controller.** With the controller off, hold the **Create** button and the **PS** button together
until the light bar flashes. Then connect "DualSense Wireless Controller" in System Settings → Bluetooth.

**2. Install the build tools** (skip the parts you already have):

```sh
xcode-select --install
brew install opus cmake ninja
```

**3. Build and install.** Run these in Terminal:

```sh
git clone https://github.com/Unravl/dualsense-audio-macos.git
cd dualsense-audio-macos
cmake -S . -B build -G Ninja
cmake --build build
sudo ./scripts/install.sh
```

Installing restarts Core Audio, which briefly interrupts any sound playing on the Mac. When it finishes,
**DualSense Speaker** and **DualSense Microphone** appear in System Settings → Sound whenever the controller is
connected.

Run `install.sh` with `sudo` from Terminal. If it's started another way, such as an AppleScript administrator
prompt, macOS may block it from reading the build folder when that folder is in a protected location like
`~/Documents`.

## Uninstall

From the cloned folder:

```sh
sudo ./scripts/uninstall.sh
```

This removes the driver and the helper service, and releases the controller. Both scripts are safe to run more
than once.

## Using it

- Select **DualSense Speaker** or **DualSense Microphone** in System Settings → Sound, or in an app's own audio
  settings. The devices disappear when the controller disconnects and come back when it reconnects.
- The speaker plays at the controller's maximum volume plus a small boost. Use the normal macOS volume keys or
  slider to turn it down.
- **While an app is recording from the DualSense Microphone, the controller's buttons don't reach games or other
  apps.** The driver takes the controller exclusively for as long as the mic is recording. Without this, other apps
  misread the microphone data as random button presses, stick movement and touchpad clicks, which can move and
  click your mouse cursor. The controller works normally again as soon as recording stops.

## Limits

- **Speaker:** mono (the controller has one speaker), at low bitrate (about 25 kbps Opus). Every audio packet has
  to fit within the small Bluetooth packets macOS allows for game controllers.
- **Microphone:** clear only while Game Mode is on (see above). Otherwise about half of the audio is lost.
- One controller at a time, Bluetooth only. A USB-connected DualSense already works as a normal USB audio
  device without this driver.

## How it works

- `ds5audiod` is a small helper service that launchd runs as root. It owns the controller: it opens the
  DualSense's Bluetooth HID connection, encodes speaker audio and decodes the microphone.
- `DualSenseAudio.driver` is a Core Audio plug-in that publishes the two sound devices. It exchanges audio with
  the helper through shared memory, and control messages over XPC.

They're separate because Core Audio runs plug-ins in a sandbox as the `_coreaudiod` user, and macOS doesn't let
that user open HID devices.

Installed files:

| File | What it is |
| --- | --- |
| `/Library/Audio/Plug-Ins/HAL/DualSenseAudio.driver` | Core Audio plug-in |
| `/Library/Application Support/DualSenseAudio/ds5audiod` | Helper service |
| `/Library/LaunchDaemons/com.psgrok.DualSenseAudio.helper.plist` | launchd job for the helper |

## Troubleshooting

Live logs from the helper, the plug-in and the diagnostic tool:

```sh
log stream --predicate 'subsystem == "com.psgrok.DualSenseAudio"'
```

Check that the helper service is running:

```sh
sudo launchctl print system/com.psgrok.DualSenseAudio.helper
```

`build/ds5audio` is a diagnostic tool that talks to the controller directly, without Core Audio or the helper.
Stop any app using the DualSense devices before running `tone`, `play` or `record`.

| Command | What it does |
| --- | --- |
| `ds5audio status` | Connection state and link statistics. `input_reports_per_sec` is about 67 normally and about 133 with Game Mode on. |
| `ds5audio tone [seconds] [hz]` | Plays a test tone on the controller speaker (default 5 s, 440 Hz). |
| `ds5audio play <file.wav>` | Plays a 48 kHz WAV file (16-bit or float, mono or stereo). |
| `ds5audio record <seconds> <out.wav>` | Records the microphone to a WAV file and prints how much audio was lost. |

While an app records from the DualSense Microphone, the helper holds the controller exclusively, so `ds5audio`
can't open it and `status` reports `connected=no`.

## Credits

The DualSense Bluetooth audio protocol was worked out from these open-source projects:

- [PadForge](https://github.com/hifihedgehog/PadForge)
- [DS5Dongle](https://github.com/awalol/DS5Dongle)
- [LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5)

Audio is encoded and decoded with [Opus](https://opus-codec.org).

## License

[MIT](LICENSE). DualSense and PlayStation are trademarks of Sony Interactive Entertainment.
