import Testing
@testable import JoyHarness

struct AIVoiceDDCBrightnessTests {
    @Test func getVCPRequestMatchesThePacketAcceptedByTheRedmiHDMIBridge() {
        // Captured, validated read-only request; 0xfd (without source address)
        // produced transport success with invalid bytes on this same hardware.
        #expect(AIVoiceDDCProtocol.getBrightnessRequest() == [0x82, 0x01, 0x10, 0xac])
    }

    @Test func setVCPEncodesAbsoluteBrightnessWithoutSendingAnyHardwareCommand() {
        #expect(AIVoiceDDCProtocol.setBrightnessRequest(60) == [0x84, 0x03, 0x10, 0x00, 0x3c, 0x94])
        #expect(AIVoiceDDCProtocol.setBrightnessRequest(0x0123) == [0x84, 0x03, 0x10, 0x01, 0x23, 0x8a])
    }

    @Test func realRedmiReplyReportsSixtyPercent() throws {
        let captured: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 0x64, 0, 0x3c, 0xfc]
        let reply = try #require(AIVoiceDDCProtocol.decodeBrightnessReply(captured))
        #expect(reply.current == 60)
        #expect(reply.maximum == 100)
        #expect(reply.normalized == 0.6)
    }

    @Test func nonHundredMaximumUsesTheMonitorsActualScale() throws {
        let captured: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 1, 0, 0, 0x80, 0x25]
        let reply = try #require(AIVoiceDDCProtocol.decodeBrightnessReply(captured))
        #expect(reply.current == 128)
        #expect(reply.maximum == 256)
        #expect(reply.normalized == 0.5)
    }

    @Test func transportSuccessWithNullGarbageOrCorruptRepliesIsNotBrightness() {
        let replies: [[UInt8]] = [
            [0x6e, 0x80, 0xbe], // Real null response from this bridge at 0x37.
            [0xc6, 0xb8, 0x22, 0xf1, 0xdd, 0x7a, 0xbf, 0x43, 0xb5, 0x31, 0x4e],
            [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 0x64, 0, 0x3c, 0xfd], // Bad checksum.
            [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 0x64, 0, 0x3c], // Truncated.
        ]
        for reply in replies { #expect(AIVoiceDDCProtocol.decodeBrightnessReply(reply) == nil) }
    }

    @Test func validChecksumCannotHideUnsupportedWrongFeatureOrInvalidRange() {
        let replies: [[UInt8]] = [
            [0x6e, 0x88, 0x02, 1, 0x10, 0, 0, 0x64, 0, 0x3c, 0xfd], // Unsupported.
            [0x6e, 0x88, 0x02, 0, 0x12, 0, 0, 0x64, 0, 0x3c, 0xfe], // Contrast reply.
            [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 0, 0, 0, 0xa4], // Zero maximum.
            [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 0x64, 0, 0x65, 0xa5], // Over maximum.
        ]
        for reply in replies { #expect(AIVoiceDDCProtocol.decodeBrightnessReply(reply) == nil) }
    }

    @Test func ambiguousOrDisconnectedDisplaysNeverChooseAnArbitraryControlProxy() {
        #expect(AIVoiceDDCProtocol.uniqueProxy(displayID: 1, externalDisplayIDs: [1], externalProxyIDs: [42]) == 42)
        #expect(AIVoiceDDCProtocol.uniqueProxy(displayID: 1, externalDisplayIDs: [1, 2], externalProxyIDs: [42]) == nil)
        #expect(AIVoiceDDCProtocol.uniqueProxy(displayID: 1, externalDisplayIDs: [1], externalProxyIDs: [42, 43]) == nil)
        #expect(AIVoiceDDCProtocol.uniqueProxy(displayID: 1, externalDisplayIDs: [2], externalProxyIDs: [42]) == nil)
        #expect(AIVoiceDDCProtocol.uniqueProxy(displayID: 1, externalDisplayIDs: [], externalProxyIDs: [42]) == nil)
    }
}
