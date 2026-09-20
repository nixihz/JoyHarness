import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct RemoteMicrophoneOutputTests {
    @Test(arguments: [false, true])
    func releasesShortcutOnlyAfterBLEStopAndLastPlayback(hidReleaseFirst: Bool) async throws {
        let playback = FakeMicrophonePlayback()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        defer { output.stop() }
        var releases = 0
        output.prepareForPress()
        output.handle(.started)
        output.append([Int16](repeating: 10, count: 240))
        if hidReleaseFirst { output.releaseWhenFinished { releases += 1 } }
        output.append([Int16](repeating: 20, count: 240))
        output.handle(.ended)
        if !hidReleaseFirst { output.releaseWhenFinished { releases += 1 } }
        #expect(playback.samples.count == 480)
        #expect(releases == 0)
        playback.finishNextBuffer()
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(releases == 0)
        #expect(!playback.stopped)
        playback.finishNextBuffer()
        await waitUntil { releases == 1 }
        #expect(releases == 1)
        #expect(output.deliveredSamples == 480)
        #expect(playback.stopped)
        #expect(output.failure == nil)
    }

    @Test(arguments: [false, true])
    func disablingOrDisconnectingImmediatelyClearsDrainingAudio(disconnect: Bool) {
        let playback = FakeMicrophonePlayback()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        let voice = XiaomiRemoteVoice()
        voice.onStreamEvent = { output.handle($0) }
        output.prepareForPress()
        output.handle(.started)
        output.append([Int16](repeating: 10, count: 4_800))
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        output.handle(.ended)
        #expect(!playback.stopped)
        if disconnect { voice.stop() }
        else { voice.enabled = false }
        #expect(playback.stopped)
        #expect(releases == 1)
        output.append([1, 2, 3])
        #expect(playback.samples.count == 4_800)
    }

    @Test func missingBLEStopEventuallyReleasesShortcut() async {
        let playback = FakeMicrophonePlayback()
        let output = RemoteMicrophoneOutput(streamEndTimeout: 0.02, makePlayback: { playback })
        defer { output.stop() }
        output.prepareForPress()
        output.handle(.started)
        output.append([1, 2, 3])
        var released = false
        output.releaseWhenFinished { released = true }
        playback.finishNextBuffer()
        await waitUntil { released }
        #expect(released)
        #expect(playback.stopped)
    }

    @Test func rapidRepressCompletesOldReleaseWithoutStoppingNewStream() async throws {
        let first = FakeMicrophonePlayback()
        let second = FakeMicrophonePlayback()
        var backends = [first, second]
        let output = RemoteMicrophoneOutput(makePlayback: { backends.removeFirst() })
        defer { output.stop() }
        var events: [Bool] = [true]
        output.prepareForPress()
        output.handle(.started)
        output.append([1, 2, 3])
        output.releaseWhenFinished { events.append(false) }
        // A new HID press can precede the old BLE AUDIO_STOP.
        output.prepareForPress()
        events.append(true)
        output.handle(.ended)
        output.handle(.started)
        output.append([4, 5, 6])
        first.finishNextBuffer() // Late playback callbacks cannot affect the new generation.
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(events == [true, false, true])
        #expect(first.stopped)
        #expect(!second.stopped)
        #expect(second.samples == [4, 5, 6])
        #expect(output.deliveredSamples == 0)
        output.releaseWhenFinished { events.append(false) }
        output.handle(.ended)
        second.finishNextBuffer()
        await waitUntil { events.count == 4 }
        #expect(events == [true, false, true, false])
    }

    @Test func newBLESessionCanPrecedeTheNextHIDPress() async throws {
        let first = FakeMicrophonePlayback()
        let second = FakeMicrophonePlayback()
        var backends = [first, second]
        let output = RemoteMicrophoneOutput(makePlayback: { backends.removeFirst() })
        defer { output.stop() }
        output.prepareForPress()
        output.handle(.started)
        output.append([1, 2, 3])
        var releases = 0
        output.releaseWhenFinished { releases += 1 }
        output.handle(.ended)
        output.handle(.started)
        output.prepareForPress()
        output.append([4, 5, 6])
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(releases == 1)
        #expect(first.stopped)
        #expect(!second.stopped)
        #expect(second.samples == [4, 5, 6])
    }

    @Test func lateHIDReleaseDoesNotStopTheNextBLESession() async {
        let first = FakeMicrophonePlayback()
        let second = FakeMicrophonePlayback()
        var backends = [first, second]
        let output = RemoteMicrophoneOutput(makePlayback: { backends.removeFirst() })
        defer { output.stop() }
        output.prepareForPress() // HID down for session 1.
        output.handle(.started)
        output.append([1, 2, 3])
        output.handle(.ended)
        output.handle(.started) // BLE is ahead of both HID edges for the next press.
        var releases = 0
        output.releaseWhenFinished { releases += 1 } // Delayed HID up for session 1.
        output.prepareForPress() // HID down for session 2.
        output.append([4, 5, 6])
        #expect(releases == 1)
        #expect(first.stopped)
        #expect(!second.stopped)
        #expect(second.samples == [4, 5, 6])
    }

    private func waitUntil(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeMicrophonePlayback: RemoteMicrophonePlayback {
    private(set) var samples: [Int16] = []
    private(set) var stopped = false
    private var completions: [() -> Void] = []

    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        samples += pcm
        completions.append(completion)
        return !stopped
    }

    func stop() { stopped = true }
    func finishNextBuffer() { completions.removeFirst()() }
}
