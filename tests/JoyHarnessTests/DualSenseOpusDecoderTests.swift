import Foundation
import Testing
@testable import JoyHarness

/// These 71-byte non-speech packets come from an independently built official
/// Opus 1.5.2 `opus_demo`, not JoyHarness's encoder or decoder. Source samples:
/// round(12000 * sin(2*pi*440*i/48000)), 8 * 480 samples, signed little-endian.
/// Command: opus_demo -e restricted-lowdelay 48000 1 56800 -cbr -framesize 10
/// -complexity 0 tone.pcm tone.bit. Expected samples below come from a separate
/// `opus_demo -d 48000 1 tone.bit reference.pcm` invocation. These are codec
/// vectors, not a claim that a real DualSense has emitted these packets.
let dualSenseTonePackets: [[UInt8]] = [
    "f05860636da7d26b81e13c0e71bf5a3b7509d329dd59201304c27bd311b0fc691ddc834b3e1e694d243d5f9aa76195602232f0ba42a0de2f92a58d66a8775b27302ac1561c3b99",
    "f062fb40854fc20ab8cb3071b650b39ca31e1673d86579fa86767705d173e649a13c6fe9126e0b2ce4e08c6ab48bf4ac616e38d0cd9d49ae8a7b56b59563850e67e68bf95c9ff7",
    "f063137e0836f0243daffcb59865a9bd1bb1cedd4c3961eb1055eb20e14cd423ff16d88a1b36f7927478d87f6ff03707c40d2db90518c51d5b9cd90d263c6ea7546ebc2734d426",
].map(dualSenseFixtureBytes)

func dualSenseFixtureBytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}

struct DualSenseOpusDecoderTests {
    @Test func stereoTOCUsedByControllerIsDownmixedToMono() throws {
        // Independent opus_demo encoder: same options as above, channels 2,
        // bandwidth SWB, left 440 Hz and right 220 Hz. Reference decoder has
        // channels=1. 0xD4 is also the TOC observed in community mic captures.
        let packet = dualSenseFixtureBytes("d45895fad7497dca9585358b155399ca5256c7ca0da488ff6e24cbc80c958ed8889b96f8cf3a00e59f6f70d595580948541b9facd290fb1b8b0086ff7dd3859af2912b50f06b98")
        let pcm = try DualSenseOpusDecoder().decode(Data(packet))
        #expect(pcm.count == 480)
        for (offset, expected) in [(100, 225), (200, -1400), (300, -9809), (400, 3386), (479, 749)] {
            #expect(abs(pcm[offset] * 32768 - Float(expected)) <= 2)
        }
    }

    @Test func fixedReferenceToneDecodesAtExpectedScaleAndTime() throws {
        let decoder = try DualSenseOpusDecoder()
        let offsets = [0, 1, 100, 200, 300, 400, 479]
        let expected: [[Float]] = [
            [0, 0, 755, -11236, -8703, -4579, 11617],
            [11446, 11233, 11590, 8781, 3774, -2172, -11367],
            [-11587, -11769, -8663, -3110, 3438, 8650, 6825],
        ]
        for (index, packet) in dualSenseTonePackets.enumerated() {
            let pcm = try decoder.decode(Data(packet))
            #expect(pcm.count == 480)
            #expect(pcm.allSatisfy { $0.isFinite })
            for (offset, reference) in zip(offsets, expected[index]) {
                // Official opus_demo returns quantized Int16; our HAL needs
                // Float32. Two integer units allow cross-architecture rounding.
                #expect(abs(pcm[offset] * 32768 - reference) <= 2)
            }
        }
        #expect(DualSenseOpusDecoder.libraryVersion == "libopus 1.5.2")
    }

    @Test func resetClearsConcealmentAndPreviousSessionPredictor() throws {
        let decoder = try DualSenseOpusDecoder()
        for packet in dualSenseTonePackets { _ = try decoder.decode(Data(packet)) }
        _ = try decoder.concealLostFrame()
        try decoder.reset()
        #expect(throws: DualSenseOpusDecoder.Failure.concealmentBeforeAudio) { try decoder.concealLostFrame() }
        let pcm = try decoder.decode(Data(dualSenseTonePackets[0]))
        #expect(abs(pcm[200] * 32768 - (-11236)) <= 2)
        #expect(abs(pcm[479] * 32768 - 11617) <= 2)
    }

    @Test func concealmentIsBoundedAndCannotInventInitialReadiness() throws {
        let decoder = try DualSenseOpusDecoder()
        #expect(throws: DualSenseOpusDecoder.Failure.concealmentBeforeAudio) { try decoder.concealLostFrame() }
        _ = try decoder.decode(Data(dualSenseTonePackets[0]))
        for _ in 0..<3 {
            let pcm = try decoder.concealLostFrame()
            #expect(pcm.count == 480 && pcm.allSatisfy { $0.isFinite })
        }
        #expect(throws: DualSenseOpusDecoder.Failure.concealmentLimit) { try decoder.concealLostFrame() }
        _ = try decoder.decode(Data(dualSenseTonePackets[1]))
        #expect(try decoder.concealLostFrame().count == 480)
    }

    @Test func invalidFormatsFailBeforeAudioIsPublished() throws {
        let decoder = try DualSenseOpusDecoder()
        #expect(throws: DualSenseOpusDecoder.Failure.invalidPacketLength(0)) { try decoder.decode(Data()) }
        var longer = dualSenseTonePackets[0]
        longer[0] = 0xf8 // 20 ms CELT frame, cannot fit our 10 ms timeline.
        #expect(throws: DualSenseOpusDecoder.Failure.unexpectedFrameCount(960)) { try decoder.decode(Data(longer)) }
        #expect(throws: DualSenseOpusDecoder.Failure.concealmentBeforeAudio) { try decoder.concealLostFrame() }
    }
}
