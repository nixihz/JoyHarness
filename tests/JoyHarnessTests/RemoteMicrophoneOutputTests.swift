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
        #expect(!playback.stopped)
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
        #expect(!playback.stopped)
    }

    @Test func audioDeviceReconfigurationResumesBeforeDroppingSpeech() async throws {
        let playback = FakeMicrophonePlayback()
        playback.interruptBeforeNextSchedule()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        defer { output.stop() }
        output.prepareForPress()
        output.handle(.started)

        let speech: [Int16] = [120, -240, 360]
        output.append(speech)

        #expect(playback.samples == speech)
        #expect(!playback.stopped)
        #expect(output.failure == nil)
        try #require(playback.pendingBufferCount == 1)
        playback.finishNextBuffer()
        await waitUntil { output.deliveredSamples == speech.count }
        #expect(output.deliveredSamples == speech.count)
    }

    @Test func consecutiveSessionsReuseThePreparedPlaybackEngine() async {
        let playback = FakeMicrophonePlayback()
        var playbackCreations = 0
        let output = RemoteMicrophoneOutput(makePlayback: {
            playbackCreations += 1
            return playback
        })
        defer { output.stop() }

        var releases = 0
        var expectedSamples: [Int16] = []
        for session in 1...20 {
            let speech = [Int16(session), Int16(-session), Int16(session * 2)]
            expectedSamples += speech
            output.prepareForPress()
            output.handle(.started)
            output.append(speech)
            output.releaseWhenFinished { releases += 1 }
            output.handle(.ended)
            playback.finishNextBuffer()
            await waitUntil { releases == session }

            #expect(playbackCreations == 1)
            #expect(!playback.stopped)
            #expect(output.failure == nil)
        }

        #expect(playbackCreations == 1)
        #expect(releases == 20)
        #expect(playback.samples == expectedSamples)
        #expect(output.failure == nil)
    }

    @Test func warmUpPreparesPlaybackBeforeTheFirstVoiceSession() {
        let playback = FakeMicrophonePlayback()
        var playbackCreations = 0
        let output = RemoteMicrophoneOutput(makePlayback: {
            playbackCreations += 1
            return playback
        })
        defer { output.stop() }

        output.warmUp()
        output.warmUp()
        output.prepareForPress()
        output.handle(.started)
        output.append([1, 2, 3])

        #expect(playbackCreations == 1)
        #expect(playback.samples == [1, 2, 3])
        #expect(!playback.stopped)
    }

    @Test func slowerPlaybackClockDoesNotAbortLongSpeech() async {
        let playback = FakeMicrophonePlayback()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        defer { output.stop() }
        output.prepareForPress()
        output.handle(.started)

        let packet = [Int16](repeating: 10, count: 240)
        // Ninety seconds of 15 ms packets, with the consumer falling one packet
        // behind every 100 packets to model independent BLE and CoreAudio clocks.
        var maximumQueuedSamples = 0
        var maximumScheduledBuffers = 0
        for index in 0..<6_000 {
            output.append(packet)
            maximumQueuedSamples = max(maximumQueuedSamples, output.queuedSamples)
            maximumScheduledBuffers = max(maximumScheduledBuffers, playback.pendingBufferCount)
            if index % 100 != 0 {
                playback.finishNextBuffer()
                await Task.yield()
            }
        }

        #expect(!playback.stopped)
        #expect(output.failure == nil)
        #expect(output.droppedSamples > 0)
        #expect(maximumQueuedSamples <= 8_000)
        #expect(maximumScheduledBuffers <= 4)

        await finishPlaybackBuffers(8, playback: playback, output: output)

        let laterSpeech = [Int16](repeating: 20, count: 240)
        output.append(laterSpeech)
        await finishAllPlayback(playback, output: output)
        #expect(playback.samples.suffix(laterSpeech.count) == laterSpeech[...])
        #expect(!playback.stopped)
        #expect(output.failure == nil)
    }

    @Test func fullBufferEvictsOldestUnplayedSamplesAndKeepsLatestSpeech() async {
        let playback = FakeMicrophonePlayback()
        let output = RemoteMicrophoneOutput(makePlayback: { playback })
        defer { output.stop() }
        output.prepareForPress()
        output.handle(.started)

        for packet in 0..<34 {
            output.append([Int16](repeating: Int16(packet), count: 240))
        }
        for _ in 0..<40 {
            guard playback.pendingBufferCount > 0 else { break }
            let delivered = output.deliveredSamples
            playback.finishNextBuffer()
            await waitUntil { output.deliveredSamples > delivered }
        }

        #expect(output.droppedSamples == 160)
        #expect(playback.samples.count == 8_000)
        #expect(playback.samples.suffix(240) == [Int16](repeating: 33, count: 240)[...])
        #expect(!playback.stopped)
        #expect(output.failure == nil)
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

    private func finishPlaybackBuffers(
        _ count: Int,
        playback: FakeMicrophonePlayback,
        output: RemoteMicrophoneOutput
    ) async {
        for _ in 0..<count {
            await waitUntil { playback.pendingBufferCount > 0 }
            let delivered = output.deliveredSamples
            playback.finishNextBuffer()
            await waitUntil { output.deliveredSamples > delivered }
        }
    }

    private func finishAllPlayback(
        _ playback: FakeMicrophonePlayback,
        output: RemoteMicrophoneOutput
    ) async {
        while output.queuedSamples > 0 {
            await finishPlaybackBuffers(1, playback: playback, output: output)
        }
    }
}

private final class FakeMicrophonePlayback: RemoteMicrophonePlayback {
    private(set) var samples: [Int16] = []
    private(set) var stopped = false
    private var completions: [() -> Void] = []
    private var interrupted = false
    var pendingBufferCount: Int { completions.count }

    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        guard !interrupted, !stopped else { return false }
        samples += pcm
        completions.append(completion)
        return true
    }

    func interruptBeforeNextSchedule() { interrupted = true }
    func recoverFromInterruption() -> Bool {
        guard !stopped else { return false }
        interrupted = false
        return true
    }
    func stop() { stopped = true }
    func finishNextBuffer() { completions.removeFirst()() }
}
