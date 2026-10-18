import AVFoundation
import Foundation
import Testing
@testable import JoyHarness

struct AIVoiceAudioTests {
    @Test
    func wavEncodesSignedSamplesAndContainerLengths() {
        let recording = AIVoiceWAV.recording(samples: [-32_768, -1, 0, 32_767], sampleRate: 16_000)
        let bytes = [UInt8](recording.wavData)
        #expect(bytes.count == 52)
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        #expect(Array(bytes[4..<8]) == [44, 0, 0, 0])
        #expect(String(decoding: bytes[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(Array(bytes[20..<24]) == [1, 0, 1, 0]) // PCM, mono
        #expect(Array(bytes[24..<28]) == [0x80, 0x3e, 0, 0]) // 16 kHz
        #expect(Array(bytes[28..<32]) == [0, 0x7d, 0, 0]) // 32 kB/sec
        #expect(Array(bytes[40..<44]) == [8, 0, 0, 0])
        #expect(Array(bytes[44...]) == [0, 128, 255, 255, 0, 0, 255, 127])
        #expect(recording.duration == 0.00025)
    }

    @Test
    func silenceAndBriefClicksDoNotBecomeCommands() {
        let silence = AIVoiceWAV.recording(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
        var click = Array(repeating: Int16(0), count: 16_000)
        click[100] = 30_000
        let shortNoise = AIVoiceWAV.recording(samples: click, sampleRate: 16_000)
        let audible = AIVoiceWAV.recording(samples: Array(repeating: 1_000, count: 3_200), sampleRate: 16_000)
        #expect(!silence.containsAudibleAudio)
        #expect(!shortNoise.containsAudibleAudio)
        #expect(audible.containsAudibleAudio)
        #expect(audible.duration == 0.2)
    }

    @Test
    func microphoneFormatIsDownmixedAndResampledWithoutHardware() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 2, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let capture = AIVoiceAudioAccumulator(converter: converter, output: output)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try #require(buffer.floatChannelData)
        for chunk in 0..<100 {
            for frame in 0..<480 {
                let sample = Float(sin(Double(chunk * 480 + frame) * 2 * .pi * 440 / 48_000)) * 0.25
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
            #expect(capture.append(buffer).error == nil)
        }
        let recording = try capture.finish().get()
        #expect(recording.sampleRate == 16_000)
        #expect(abs(recording.duration - 1) < 0.01)
        #expect(recording.containsAudibleAudio)
        #expect(capture.append(buffer).level == nil)
        capture.discard()
        #expect(throws: AIVoiceAudioError.self) { try capture.finish().get() }
    }

    @Test
    func delayedReleaseDropsLaterAudioBeforeResamplingIncludingFilterTail() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 2, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let capture = AIVoiceAudioAccumulator(converter: try #require(AVAudioConverter(from: input, to: output)),
                                              output: output, requiresTimestamps: true)
        // Release occurs 50 ms into the second block. The last 350 ms has
        // already reached the tap before the main queue processes that release.
        for chunk in 0..<5 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let channels = try #require(buffer.floatChannelData)
            for frame in 0..<4_800 {
                let afterRelease = chunk * 4_800 + frame >= 7_200
                channels[0][frame] = afterRelease ? 0.9 : 0
                channels[1][frame] = afterRelease ? 0.9 : 0
            }
            #expect(capture.append(buffer, at: 100 + Double(chunk) * 0.1).error == nil)
        }
        let recording = try capture.finish(at: 100.15).get()
        #expect(recording.duration <= 0.15)
        #expect(recording.duration >= 0.1498)
        #expect(!recording.containsAudibleAudio)
        // Post-release input would leak backward through a resampling filter
        // if the implementation converted first and cropped output afterward.
        #expect(recording.wavData.dropFirst(44).allSatisfy { $0 == 0 })
    }

    @Test
    func timestampedReleaseRequiresATrustworthyCaptureTimeline() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        let missing = AIVoiceAudioAccumulator(converter: try #require(AVAudioConverter(from: input, to: output)),
                                              output: output)
        _ = missing.append(buffer)
        #expect(throws: AIVoiceAudioError.self) { try missing.finish(at: 100).get() }
        for timestamp in [99.9, 100.5, Double.nan] {
            let capture = AIVoiceAudioAccumulator(converter: try #require(AVAudioConverter(from: input, to: output)),
                                                  output: output, requiresTimestamps: true)
            #expect(capture.append(buffer, at: 100).error == nil)
            #expect(capture.append(buffer, at: timestamp).error != nil)
            #expect(throws: AIVoiceAudioError.self) { try capture.finish(at: 100.01).get() }
        }
    }

    @Test
    func rawPCMCacheRejectsOverBudgetCaptureAndCannotBeFinalized() throws {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                               channels: 2, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let capture = AIVoiceAudioAccumulator(converter: try #require(AVAudioConverter(from: input, to: output)),
                                              output: output, memoryLimitBytes: 4_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 { buffer.floatChannelData?[channel].initialize(repeating: 0.2, count: 480) }
        #expect(capture.append(buffer).error == nil) // 3,840 bytes
        let update = capture.append(buffer)
        if case .memoryLimit? = update.error {} else { Issue.record("Expected memory budget cancellation") }
        #expect(throws: AIVoiceAudioError.self) { try capture.finish().get() }
    }
}
