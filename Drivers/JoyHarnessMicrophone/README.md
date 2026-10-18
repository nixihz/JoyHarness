# Joy Harness microphone HAL

Version 4 (1.2.0) publishes only the Xiaomi remote's fixed 48 kHz,
two-channel Float32 loopback device: **Joy Harness 遥控器麦克风**, UID
`tech.keli.joyharness.microphone.device`, internal device/input/output IDs 2/3/4.

The old `tech.keli.joyharness.dualsense.microphone.device` is no longer
published or accepted. DualSense capture now belongs to the separately bundled
[DualSense Audio integration](../DualSenseAudio/JOYHARNESS.md). Updating the
remote component removes the obsolete input while preserving Xiaomi's UID.

Version 3 corrected the zero timestamp period to 16384 frames, above the SDK
minimum of 10923; version 4 retains that clock and all buffering contracts.
The clock interval is independent of the host I/O size and does not add that
many frames of audio buffering.

## Invalidate one device's buffered session

The device-level custom property `0x6a68666c` (`jhfl`) uses global scope and the
main element. It is writable. Any **integer CFNumber in the UInt32 range**
invalidates buffered frames for that device without stopping its consumers,
resetting its Core Audio clock . Reading returns
the current session epoch's low 32 bits as a retained CFNumber.

The property is declared as `kAudioServerPlugInCustomPropertyDataTypeCFPropertyList`.
Use a CFNumber reference, not a raw UInt32: AudioServerPlugIn custom-property
marshalling supports CF property lists, not an arbitrary scalar payload.

```swift
var property = AudioObjectPropertyAddress(
    mSelector: 0x6a68666c,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
let number: CFNumber = NSNumber(value: UInt32(1))
var token = Unmanaged.passUnretained(number).toOpaque()
let status = withExtendedLifetime(number) {
    AudioObjectSetPropertyData(
        deviceID, &property, 0, nil,
        UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &token
    )
}
```

The caller must stop scheduling/rendering the previous producer before flushing;
otherwise an old application buffer delivered after the flush is indistinguishable
from new audio. Flush before a new session as well. Writes already in flight
inside the driver retain their previous epoch and cannot undo a flush. Audio
already returned to a consumer cannot be recalled.

Preparation checks require the Xiaomi UID, input/output streams and a writable `jhfl` property.

## Silence and lifetime

Input reads are non-consuming, so multiple applications can read the same frames.
Only frames with the matching absolute sample stamp and current session epoch
are returned; missing frames and expired ring positions read as silence. A frame
also expires 250 ms after its HAL output write, even if readers keep the device
running and the producer crashes. This deadline uses continuous host time, which
includes sleep. New writes cannot revive older expired frames. The clock itself
continues using Core Audio's absolute host time.

The 65,536-frame ring is storage capacity, not an intentional playback delay.
Keep actual producer/render latency below the expiry deadline. The driver does
not send Bluetooth mic-off commands and does not guarantee physical mute after
an application crash. An actual audio-host test must still verify silent output
after cancellation, process termination and sleep, because already-delivered
consumer buffers are outside the driver's control.

Run `scripts/test_microphone_driver.sh` for ASan/UBSan checks. This exercises both
devices, simultaneous frame positions, non-consuming readers, flush with a reader
still open, clock advancement, producer loss, expiry and malformed requests.
The tests do not install the component or restart Core Audio.

After installing version 2 or newer, with microphone supply stopped, run
`bash scripts/test_microphone_hal_host.sh` for the opt-in host check. It resolves
both live devices and verifies that a CFNumber flush crosses coreaudiod and
verifies the obsolete DualSense UID is absent and flushes Xiaomi, captures no audio
and does not change the default input. This check is not part of CI because it
requires an installed component.
