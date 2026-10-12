import AppKit
import Testing
@testable import JoyHarness

@MainActor
struct EdgeLightTests {
    @Test func draggingAcrossDisplaysSnapsToAllFourEdgesAndClampsCorners() {
        let screen = NSRect(x: -1280, y: 120, width: 1280, height: 800)
        let samples: [(NSPoint, ScreenEdge)] = [
            (NSPoint(x: -640, y: 919), .top), (NSPoint(x: -1, y: 520), .right),
            (NSPoint(x: -640, y: 121), .bottom), (NSPoint(x: -1279, y: 520), .left),
        ]
        for (point, edge) in samples {
            let placement = EdgeLightPlacement.snapped(to: point, in: screen, displayID: 42)
            #expect(placement.edge == edge)
            #expect(placement.displayID == 42)
            #expect(screen.contains(placement.frame(in: screen, expanded: true)))
            #expect(screen.contains(placement.frame(in: screen, expanded: false)))
        }
        let nearCorner = EdgeLightPlacement.snapped(to: NSPoint(x: -1270, y: 919), in: screen, displayID: nil)
        #expect(nearCorner.fraction == 0)
        #expect(nearCorner.frame(in: screen, expanded: true).minX == screen.minX)
    }

    @Test func hoverKeepsTheOuterEdgeFixedOnEverySide() {
        let screen = NSRect(x: 80, y: -900, width: 1440, height: 900)
        for edge in ScreenEdge.allCases {
            let placement = EdgeLightPlacement(edge: edge, fraction: 0.8)
            let quiet = placement.frame(in: screen, expanded: false)
            let hover = placement.frame(in: screen, expanded: true)
            switch edge {
            case .top: #expect(quiet.maxY == hover.maxY)
            case .bottom: #expect(quiet.minY == hover.minY)
            case .left: #expect(quiet.minX == hover.minX)
            case .right: #expect(quiet.maxX == hover.maxX)
            }
        }
    }

    @Test func keyboardSnapshotPreservesSixSlotOrderAndNativeReadTransitions() throws {
        var report: [UInt8] = [7, 0x4A, 0x48, 1, 0x3F, 0]
        let colors: [[UInt8]] = [[0xFF, 0x00, 0x33], [0x30, 0x4F, 0xFE], [0x00, 0xFF, 0x4C],
                                [0xFF, 0x6D, 0x00], [0xFF, 0xFF, 0xFF], [0, 0, 0]]
        for (index, color) in colors.enumerated() {
            report += [index == 5 ? 0 : 1, 255, 0, 0] + color
        }
        report += [UInt8](repeating: 0, count: 16)
        let snapshot = try #require(CodexMicroSnapshot(report: report))
        #expect(snapshot.slots.map(\.state) == [.error, .busy, .done, .waiting, .idle, nil])
        #expect(snapshot.slots[5].isOff)
        // 完成会话在客户端被查看后变白，即使它仍占据相同槽位。
        report.replaceSubrange(24..<27, with: [255, 255, 255])
        let viewed = try #require(CodexMicroSnapshot(report: report))
        #expect(viewed.slots[2].state == .idle)
        #expect(viewed.slots[2].colorRGB == 0xFFFFFF)
        report.replaceSubrange(24..<27, with: [0, 255, 76])
        #expect(CodexMicroSnapshot(report: report)?.slots[2].state == .done)
        #expect(CodexMicroSnapshot(report: Array(report.dropLast())) == nil)
        report[3] = 2
        #expect(CodexMicroSnapshot(report: report) == nil)
    }

    @Test func inkOnlyReleasesForNewTopEdgeCompletionAndStopsWhenRead() {
        var ink = EdgeLightInkState()
        let working = [EdgeLightSlot(identity: "micro-0", title: "", state: .busy)]
        let unread = [EdgeLightSlot(identity: "micro-0", title: "", state: .done)]
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 0)
        #expect(ink.plumes.isEmpty)
        ink.update(working, enabled: true, edge: .top, reduceMotion: false, now: 1)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 2)
        #expect(ink.plumes.count == 1)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 3)
        #expect(ink.plumes.first?.startedAt == 2)
        ink.update([EdgeLightSlot(identity: "micro-0", title: "", state: .idle)],
                   enabled: true, edge: .top, reduceMotion: false, now: 4)
        #expect(ink.plumes.isEmpty)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 5)
        #expect(ink.plumes.count == 1)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 10)
        #expect(ink.plumes.count == 1)
        ink.acknowledge(slot: 0)
        #expect(ink.plumes.isEmpty)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 3606)
        #expect(ink.plumes.isEmpty)
        ink.update(working, enabled: true, edge: .top, reduceMotion: false, now: 3607)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 3608)
        #expect(ink.plumes.count == 1)
    }

    @Test func inkStopsEmittingAtThreeSecondsButItsTailContinuesAndExpires() throws {
        let plume = EdgeLightInkPlume(slot: 0, identity: "micro-0", startedAt: 0)
        let flowing = plume.particles(at: 2.9)
        #expect(try #require(flowing.last).age < 0.2)
        let tail = plume.particles(at: 5)
        #expect(!tail.isEmpty)
        #expect(tail.allSatisfy { $0.emission < 3 && $0.age >= 2 })
        #expect(!plume.particles(at: 10).isEmpty)
        #expect(plume.particles(at: 11).isEmpty)
        #expect(plume.particles(at: 3600).isEmpty)
        var ink = EdgeLightInkState()
        ink.update([EdgeLightSlot(identity: "micro-0", title: "", state: .busy)],
                   enabled: true, edge: .top, reduceMotion: false, now: 0)
        let unread = [EdgeLightSlot(identity: "micro-0", title: "", state: .done)]
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 1)
        ink.expire(at: 12)
        #expect(ink.plumes.isEmpty)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 13)
        #expect(ink.plumes.isEmpty)
        let sources = EdgeLightInkPlume.emitterOffsets(width: 32)
        #expect(try #require(sources.first) < -12)
        #expect(try #require(sources.last) > 12)
        #expect(sources.contains(0))
    }

    @Test func inkDoesNotReplayAfterMovingEnablingOrReconnecting() {
        let working = [EdgeLightSlot(identity: "micro-0", title: "", state: .busy)]
        let unread = [EdgeLightSlot(identity: "micro-0", title: "", state: .done)]
        for edge in [ScreenEdge.left, .right, .bottom] {
            var ink = EdgeLightInkState()
            ink.update(working, enabled: true, edge: edge, reduceMotion: false, now: 0)
            ink.update(unread, enabled: true, edge: edge, reduceMotion: false, now: 1)
            ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 2)
            #expect(ink.plumes.isEmpty)
        }
        for (enabled, reduceMotion) in [(false, false), (true, true)] {
            var ink = EdgeLightInkState()
            ink.update(working, enabled: true, edge: .top, reduceMotion: false, now: 0)
            ink.update(unread, enabled: enabled, edge: .top, reduceMotion: reduceMotion, now: 1)
            ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 2)
            #expect(ink.plumes.isEmpty)
        }
        var ink = EdgeLightInkState()
        ink.update(working, enabled: true, edge: .top, reduceMotion: false, now: 0)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 1)
        ink.update([EdgeLightSlot(identity: "micro-0", title: "", state: nil)],
                   enabled: true, edge: .top, reduceMotion: false, now: 2)
        ink.update(unread, enabled: true, edge: .top, reduceMotion: false, now: 3)
        #expect(ink.plumes.isEmpty)
    }

    @Test func positionAndTogglePersistWithoutAnotherSettingsControl() throws {
        let suite = "edge-lights-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = EdgeLightSettings(defaults: defaults)
        first.isEnabled = true
        first.placement = EdgeLightPlacement(edge: .left, fraction: 0.25, displayID: 42)
        let restored = EdgeLightSettings(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(restored.placement.edge == .left)
        #expect(restored.placement.fraction == 0.25)
        #expect(restored.placement.displayID == 42)
    }

    @Test func randomEffectIsChosenOncePerCompletionAndRemainsStableDuringPolling() throws {
        var state = EdgeLightInkState()
        let busy = [EdgeLightSlot(identity: "micro-0", title: "", state: .busy)]
        let done = [EdgeLightSlot(identity: "micro-0", title: "", state: .done)]
        var draws = 0
        let choose: () -> EdgeLightCompletionEffect = {
            draws += 1
            return draws == 1 ? .petals : .morningGlory
        }
        state.update(busy, enabled: true, edge: .top, reduceMotion: false, now: 0,
                     effect: .random, chooseRandom: choose)
        state.update(done, enabled: true, edge: .top, reduceMotion: false, now: 1,
                     effect: .random, chooseRandom: choose)
        state.update(done, enabled: true, edge: .top, reduceMotion: false, now: 2,
                     effect: .random, chooseRandom: choose)
        #expect(draws == 1)
        #expect(state.plumes.first?.effect == .petals)
        state.acknowledge(slot: 0)
        state.update(done, enabled: true, edge: .top, reduceMotion: false, now: 3,
                     effect: .random, chooseRandom: choose)
        #expect(state.plumes.isEmpty)
        #expect(draws == 1)
        state.update(busy, enabled: true, edge: .top, reduceMotion: false, now: 4,
                     effect: .random, chooseRandom: choose)
        state.update(done, enabled: true, edge: .top, reduceMotion: false, now: 5,
                     effect: .random, chooseRandom: choose)
        #expect(draws == 2)
        #expect(state.plumes.first?.effect == .morningGlory)
        state.update(busy, enabled: true, edge: .top, reduceMotion: false, now: 6)
        state.update(done, enabled: true, edge: .top, reduceMotion: false, now: 7,
                     effect: .rainbowInk, chooseRandom: choose)
        #expect(draws == 2)
        #expect(state.plumes.first?.effect == .rainbowInk)
        let suite = "random-effect-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EdgeLightSettings(defaults: defaults)
        settings.completionEffect = .random
        #expect(EdgeLightSettings(defaults: defaults).completionEffect == .random)
    }

    @Test func effectSelectionSurvivesRestartAndUnknownPreferencesFallBackSafely() throws {
        let suite = "edge-effects-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-effect", forKey: EdgeLightSettings.effectKey)
        let settings = EdgeLightSettings(defaults: defaults)
        #expect(settings.completionEffect == .greenInk)
        var applied: [EdgeLightCompletionEffect] = []
        settings.onEffectChange = { applied.append($0) }
        settings.completionEffect = .morningGlory
        settings.completionEffect = .morningGlory
        #expect(applied == [.morningGlory])
        settings.isEnabled = false
        let restarted = EdgeLightSettings(defaults: defaults)
        #expect(restarted.completionEffect == .morningGlory)
        #expect(!restarted.isEnabled)
    }

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

    @Test func draggingBackToTheStartingLampNeverOpensItAndSmallClickJitterStillWorks() {
        var gesture = EdgeLightPointerGesture()
        gesture.begin(at: NSPoint(x: 100, y: 100), slot: 2)
        let startedDragging = gesture.move(to: NSPoint(x: 150, y: 100))
        #expect(startedDragging)
        _ = gesture.move(to: NSPoint(x: 100, y: 100))
        #expect(gesture.end(over: 2) == nil)
        gesture.begin(at: NSPoint(x: 100, y: 100), slot: 3)
        _ = gesture.move(to: NSPoint(x: 102, y: 101))
        #expect(gesture.end(over: 3) == 3)
        gesture.begin(at: .zero, slot: 1)
        #expect(gesture.end(over: 2) == nil)
    }

    @Test func unknownAndApprovalStatusesDoNotMasqueradeAsIdleOrRunning() {
        #expect(PadState.fromCodexStatus("notLoaded") == nil)
        #expect(PadState.fromCodexStatus("future-status") == nil)
        #expect(PadState.fromCodexStatus("active", activeFlags: ["waitingOnUserInput"]) == .waiting)
        #expect(PadState.fromCodexStatus("active", activeFlags: ["waitingOnApproval"]) == .waiting)
    }
}
