import Foundation
import Testing
@testable import JoyHarness

/// Fixed independent oracles, not packets produced by the implementation under
/// test. Outputs were emitted by unmodified ControlDeck commit 4282692787c2c664
/// using its Swift protocol file. The state vector explicitly removes mute/LED
/// validity bits; its adjusted CRC was recalculated by Python binascii.
/// Input framing is synthetic, with CRCs computed
/// by Python binascii.crc32(0xA1 + report); it is NOT a hardware-capture fixture.
struct DualSenseBluetoothAudioProtocolTests {
    @Test func outputFramingMatchesPinnedReferenceImplementation() {
        let vectors: [([UInt8], String)] = [
            (DualSenseBluetoothAudioProtocol.microphoneStreamReport(active: true, sequence: 7),
             "32709107ff40404040400792400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d3b069cb"),
            (DualSenseBluetoothAudioProtocol.microphoneStreamReport(active: false, sequence: 8),
             "32809107fe4040404040089240000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000076abd4b7"),
            (DualSenseBluetoothAudioProtocol.microphoneStateReport(active: true, muted: false, sequence: 5),
             "315010c08000000000080900000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000043cb5387"),
            (DualSenseBluetoothAudioProtocol.audioInitializationReport(sequence: 1),
             "3210903f8000000000000009000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000701defab"),
        ]
        for (actual, expected) in vectors { #expect(actual == dualSenseFixtureBytes(expected)) }
    }

    @Test func staleMuteSnapshotCannotWriteMuteOrLED() {
        let unmutedStop = DualSenseBluetoothAudioProtocol.microphoneStateReport(active: false, muted: false, sequence: 6)
        // Power-save/mute and mute LED are independent from microphone gain.
        #expect(unmutedStop[4] & 0x03 == 0)
        #expect(unmutedStop[9] == 0)
        #expect(unmutedStop[11] == 0)
        #expect(unmutedStop[12] == 0)
        let mutedStart = DualSenseBluetoothAudioProtocol.microphoneStateReport(active: true, muted: true, sequence: 6)
        #expect(mutedStart[4] & 0x03 == 0)
        #expect(mutedStart[9] == 8)
        #expect(mutedStart[11] == 0)
        #expect(mutedStart[12] == 0)
    }

    @Test func callbackLengthDisambiguatesStrippedHeaderThatEqualsReportID() {
        // Header 0x31 = sequence 3 + control subtype 1, not a second report ID.
        let report = dualSenseFixtureBytes("313170809085123400a851050000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000206af669")
        for bytes in [report, Array(report.dropFirst())] {
            guard case .control(let frame) = DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: bytes) else {
                Issue.record("Valid independently CRC-sealed control fixture was rejected")
                continue
            }
            #expect(frame.leftStickX == 112)
            #expect(frame.rightStickY == 133)
            #expect(frame.leftTrigger == 18)
            #expect(frame.rightTrigger == 52)
            #expect(frame.buttons0 == 0xa8 && frame.buttons1 == 0x51 && frame.buttons2 == 0x05)
            #expect(frame.microphoneMuted)
            #expect(!frame.isNeutral)
        }
    }

    @Test(arguments: [
        "31f200f05860636da7d26b81e13c0e71bf5a3b7509d329dd59201304c27bd311b0fc691ddc834b3e1e694d243d5f9aa76195602232f0ba42a0de2f92a58d66a8775b27302ac1561c3b99c6ab5a71",
        "310300f05860636da7d26b81e13c0e71bf5a3b7509d329dd59201304c27bd311b0fc691ddc834b3e1e694d243d5f9aa76195602232f0ba42a0de2f92a58d66a8775b27302ac1561c3b991c97547e",
    ])
    func microphoneVariantsNeverBecomeControls(hex: String) {
        let report = dualSenseFixtureBytes(hex)
        for bytes in [report, Array(report.dropFirst())] {
            guard case .microphone(let packet) = DualSenseBluetoothAudioProtocol.classifyInput(
                reportID: 0x31, bytes: bytes, arrivalNanoseconds: 123_456
            ) else {
                Issue.record("Mic fixture was not isolated from controller state")
                continue
            }
            #expect(packet.opusPayload == Data(dualSenseTonePackets[0]))
            #expect(packet.arrivalNanoseconds == 123_456)
            #expect(packet.sequence == (hex.hasPrefix("31f2") ? 15 : 0))
        }
    }

    @Test func corruptCRCUnknownSubtypeAndL2CAPPrefixFailClosed() {
        let known = dualSenseFixtureBytes("31f200f05860636da7d26b81e13c0e71bf5a3b7509d329dd59201304c27bd311b0fc691ddc834b3e1e694d243d5f9aa76195602232f0ba42a0de2f92a58d66a8775b27302ac1561c3b99c6ab5a71")
        var corrupt = known
        corrupt[40] ^= 1
        #expect(DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: corrupt) == .unknown(.invalidCRC))
        let unknown = dualSenseFixtureBytes("31f400f05860636da7d26b81e13c0e71bf5a3b7509d329dd59201304c27bd311b0fc691ddc834b3e1e694d243d5f9aa76195602232f0ba42a0de2f92a58d66a8775b27302ac1561c3b992169602c")
        #expect(DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: unknown) == .unknown(.unknownSubtype(4)))
        #expect(DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: [0xa1] + known) == .unknown(.invalidLength(79)))
        #expect(DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x01, bytes: known) == .unknown(.unsupportedReportID(1)))
    }

    @Test(arguments: [0, 1, 12, 76, 79, 142])
    func truncatedOrOversizedReportsCannotLookLikeControls(length: Int) {
        let bytes = [UInt8](repeating: 0x31, count: length)
        #expect(DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: bytes) == .unknown(.invalidLength(length)))
    }
}
