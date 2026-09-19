import Foundation
import Testing
@testable import JoyHarness

struct RemoteVoiceTests {
    @Test func parsesStandardBatteryLevelCharacteristic() {
        #expect(XiaomiRemoteVoice.normalizedBatteryLevel(Data([100])) == 1)
        #expect(XiaomiRemoteVoice.normalizedBatteryLevel(Data([42])) == 0.42)
        #expect(XiaomiRemoteVoice.normalizedBatteryLevel(Data([101])) == nil)
        #expect(XiaomiRemoteVoice.normalizedBatteryLevel(Data()) == nil)
    }

    @Test func acceptsActualRC003CapabilityReply() {
        let caps = RemoteVoiceCapabilities(Data([0x0b, 1, 0, 2, 3, 0, 0x78, 0, 0]))
        #expect(caps?.version == 0x100)
        #expect(caps?.frameBytes == 120)
        #expect(RemoteVoiceCapabilities(Data([0x0b, 1, 0, 0, 2, 0, 0x78, 0, 0])) != nil)
    }

    @Test func rejectsUnsupportedOrMalformedNegotiation() {
        #expect(RemoteVoiceCapabilities(Data()) == nil)
        #expect(RemoteVoiceCapabilities(Data([0x0b, 1, 0, 1, 3, 0, 0x78])) == nil)
        #expect(RemoteVoiceCapabilities(Data([0x0b, 2, 0, 2, 3, 0, 0x78])) == nil)
        #expect(RemoteVoiceCapabilities(Data([0x0b, 1, 0, 2, 3, 0, 0])) == nil)
    }

    @Test func decoderUsesHighNibbleFirstAndCarriesState() {
        var decoder = RemoteADPCMDecoder()
        #expect(decoder.decode(Data([0x17, 0xf0])) == [1, 12, -18, -14])
        decoder.reset()
        let first = decoder.decode(Data([0x17]))
        let second = decoder.decode(Data([0xf0]))
        #expect(first + second == [1, 12, -18, -14])
        decoder.reset()
        // Independent reference: Python audioop.adpcm2lin(..., 2, (0, 0)).
        #expect(decoder.decode(Data([0x17, 0xf0, 0x8c, 0x42, 0xa9, 0xb5, 0xd6, 0xe3])) ==
            [1, 12, -18, -14, -17, -48, -10, 15, -7, -19, -44, -6, -62, 35, -138, 27])
    }

    @Test func decoderSaturatesInsteadOfOverflowing() {
        var decoder = RemoteADPCMDecoder()
        #expect(decoder.decode(Data(repeating: 0x77, count: 100)).last == 32767)
        #expect(decoder.decode(Data(repeating: 0xff, count: 100)).last == -32768)
    }

    @Test func fragmentsAndOldSessionAudioDoNotLeak() {
        var stream = RemoteVoiceStream()
        #expect(stream.append(Data(repeating: 0x77, count: 120), frameBytes: 120).isEmpty)
        stream.start(session: 8)
        #expect(stream.append(Data(repeating: 0x77, count: 20), frameBytes: 120).isEmpty)
        #expect(stream.append(Data(repeating: 0x77, count: 100), frameBytes: 120).count == 240)
        #expect(stream.sampleCount == 240)
        stream.stop()
        #expect(stream.append(Data(repeating: 0xff, count: 120), frameBytes: 120).isEmpty)
        stream.start(session: 9)
        #expect(stream.append(Data(repeating: 0, count: 120), frameBytes: 120) == Array(repeating: Int16(0), count: 240))
    }

    @Test func syncDiscardsIncompleteFrameAndResetsPredictor() {
        var stream = RemoteVoiceStream()
        stream.start(session: 1)
        _ = stream.append(Data(repeating: 0x77, count: 119), frameBytes: 120)
        stream.synchronize(sample: 1000, index: 0)
        let samples = stream.append(Data(repeating: 0, count: 120), frameBytes: 120)
        #expect(samples == Array(repeating: Int16(1000), count: 240))
    }

    @Test func enhancerRaisesQuietSpeechWithoutClipping() {
        var enhancer = RemoteVoiceEnhancer()
        let input = Array(repeating: Int16(1_000), count: 16_000)
        let output = enhancer.process(input)
        #expect(output.count == input.count)
        #expect(output.dropFirst(2_000).allSatisfy { abs($0) < 0.01 })

        enhancer.reset()
        let speech = (0..<1_000).map { Int16((sin(Double($0) * 0.15) * 4_000).rounded()) }
        let enhanced = enhancer.process(speech)
        #expect(enhanced.max() ?? 0 > 0.15)
        #expect(enhanced.allSatisfy { abs($0) < 1 })
    }

    @Test func enhancerKeepsFilterStateAcrossPackets() {
        var split = RemoteVoiceEnhancer()
        let input = (0..<500).map { Int16((sin(Double($0) * 0.1) * 2_000).rounded()) }
        let first = split.process(Array(input.prefix(250)))
        let second = split.process(Array(input.suffix(250)))

        var whole = RemoteVoiceEnhancer()
        let combined = whole.process(input)
        #expect(first + second == combined)
    }
}
