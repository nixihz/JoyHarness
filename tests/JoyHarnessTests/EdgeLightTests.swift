import AppKit
import Testing
@testable import JoyHarness

@MainActor
struct EdgeLightTests {
    @Test func rolloutHandlesPartialWritesTruncationAndUnrelatedEvents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func event(_ type: String) -> Data { Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\"}}\n".utf8) }
        try event("task_started").write(to: url)
        var reader = CodexRolloutStateReader()
        #expect(reader.state(at: url.path) == .busy)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let completion = event("task_complete")
        try handle.write(contentsOf: completion.prefix(15))
        #expect(reader.state(at: url.path) == .busy)
        try handle.write(contentsOf: completion.dropFirst(15) + event("token_count"))
        try handle.close()
        #expect(reader.state(at: url.path) == .done)
        try event("turn_aborted").write(to: url)
        #expect(reader.state(at: url.path) == .idle)
        try FileManager.default.removeItem(at: url)
        #expect(reader.state(at: url.path) == nil)
    }

    @Test func longRunningTurnFindsItsStartBeforeTheRecentOutputAndKeepsIncrementalState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8)
        let output = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8)
        for _ in 0..<12_000 { data.append(output) }
        try data.write(to: url)
        var reader = CodexRolloutStateReader()
        #expect(reader.state(at: url.path) == .busy)
        #expect(reader.state(at: url.path) == .busy)
    }

    @Test func unknownAndApprovalStatusesDoNotMasqueradeAsIdleOrRunning() {
        #expect(PadState.fromCodexStatus("notLoaded") == nil)
        #expect(PadState.fromCodexStatus("future-status") == nil)
        #expect(PadState.fromCodexStatus("active", activeFlags: ["waitingOnUserInput"]) == .waiting)
        #expect(PadState.fromCodexStatus("active", activeFlags: ["waitingOnApproval"]) == .waiting)
    }
}
