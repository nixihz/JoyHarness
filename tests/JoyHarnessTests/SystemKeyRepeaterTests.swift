import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct SystemKeyRepeaterTests {
    // CI can delay main-actor tasks; wait for observable repeats, not a fixed scheduling window.
    private func waitForRepeats(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func heldArrowsRepeatIndependentlyAndStopOnRelease() async throws {
        var events: [SystemKey] = []
        let repeater = SystemKeyRepeater(initialDelay: 20_000_000, interval: 10_000_000) { events.append($0) }
        defer { repeater.stopAll() }
        let arrows: [SystemKey] = [.arrowUp, .arrowDown, .arrowLeft, .arrowRight]
        for key in arrows { repeater.start(key) }
        try await waitForRepeats { arrows.allSatisfy { key in events.filter { $0 == key }.count > 1 } }
        for key in arrows { #expect(events.filter { $0 == key }.count > 1) }

        repeater.stop(.arrowLeft)
        let leftCount = events.filter { $0 == .arrowLeft }.count
        let count = events.count
        try await waitForRepeats { events.count > count }
        #expect(events.filter { $0 == .arrowLeft }.count == leftCount)
        #expect(events.count > count)

        repeater.stopAll()
        let finalCount = events.count
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(events.count == finalCount)
    }

    @Test func quickTapAndNonRepeatingShortcutsDoNotRepeat() async throws {
        var events: [SystemKey] = []
        let repeater = SystemKeyRepeater(initialDelay: 20_000_000, interval: 10_000_000) { events.append($0) }
        defer { repeater.stopAll() }
        repeater.start(.arrowUp)
        repeater.stop(.arrowUp)
        for key in [SystemKey.enter, .copy, .paste, .rightCommand] { repeater.start(key) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(events.isEmpty)
        let event = try #require(MouseBridge.makeSystemKeyEvent(.arrowUp, pressed: true, isRepeat: true))
        #expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 1)
    }

    @Test func remoteModeChangeAndDisconnectCancelHeldRepeat() async throws {
        var repeats = 0
        let repeater = SystemKeyRepeater(initialDelay: 20_000_000, interval: 10_000_000) { _ in repeats += 1 }
        defer { repeater.stopAll() }
        let bridge = ButtonBridge(mappingProvider: { ControllerMappingStore.defaultMappings(for: .xiaomiRemote)[$0] ?? .disabled })
        bridge.systemKeyHandler = { key, pressed in
            if pressed { repeater.start(key) } else { repeater.stop(key) }
        }
        bridge.setRemoteControllerActive(true)
        for disconnect in [false, true] {
            bridge.setOperationMode(.mapping)
            bridge.handleRemoteButton(.dpadUp, isPressed: true)
            let before = repeats
            try await waitForRepeats { repeats > before }
            #expect(repeats > before)
            if disconnect { bridge.setRemoteControllerActive(false) }
            else { bridge.setOperationMode(.native) }
            let stopped = repeats
            try await Task.sleep(nanoseconds: 80_000_000)
            #expect(repeats == stopped)
        }
    }
}
