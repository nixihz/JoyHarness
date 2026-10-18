import Foundation
import GameController
import Testing
@testable import JoyHarness

private final class MicrophoneIsolationTestController: GCController {
    private let pad = GCDualSenseGamepad()
    override var extendedGamepad: GCExtendedGamepad? { pad }
    override var vendorName: String? { "DualSense Wireless Controller" }
}

@MainActor
struct DualSenseMicrophoneInputIsolationTests {
    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func sendMenu(_ pad: GCExtendedGamepad, _ pressed: Bool) async {
        pad.buttonMenu.setValue(pressed ? 1 : 0)
        pad.valueChangedHandler?(pad, pad.buttonMenu)
        await drain()
    }

    @Test func changingPTTRoutingDuringHoldStillReleasesPreviouslySentACT10() async throws {
        let controller = MicrophoneIsolationTestController()
        let pad = try #require(controller.extendedGamepad)
        let hub = ControllerHub(mappingProvider: { _, input in input == .menu ? .pushToTalk : .disabled },
            controllerProvider: { [controller] }, currentControllerProvider: { controller })
        defer { hub.stop() }
        var routed = false
        hub.shouldRouteDualSensePTT = { input in routed && input == .menu }
        var events: [Int] = []
        hub.keyHandler = { key, action in
            if key == "ACT10" { events.append(action) }
            return true
        }
        hub.refreshControllers()
        await sendMenu(pad, true)
        routed = true
        await sendMenu(pad, false)
        #expect(events == [1, 0])

        // A press consumed by the raw-microphone owner cannot turn into a
        // legacy ACT10 halfway through the hold when availability changes.
        await sendMenu(pad, true)
        routed = false
        await sendMenu(pad, true)
        await sendMenu(pad, false)
        #expect(events == [1, 0])
        await sendMenu(pad, true)
        await sendMenu(pad, false)
        #expect(events == [1, 0, 1, 0])
    }

    @Test func ambiguousDualSenseEndpointsPreserveOrdinaryPTT() async throws {
        let first = MicrophoneIsolationTestController(), second = MicrophoneIsolationTestController()
        let firstPad = try #require(first.extendedGamepad), secondPad = try #require(second.extendedGamepad)
        let hub = ControllerHub(mappingProvider: { _, input in input == .menu ? .pushToTalk : .disabled },
            controllerProvider: { [first, second] }, currentControllerProvider: { first })
        defer { hub.stop() }
        hub.shouldRouteDualSensePTT = { _ in true }
        var events: [Int] = []
        hub.keyHandler = { key, action in if key == "ACT10" { events.append(action) }; return true }
        hub.refreshControllers()
        await sendMenu(firstPad, true)
        await sendMenu(secondPad, true)
        await sendMenu(firstPad, false)
        #expect(events == [1])
        await sendMenu(secondPad, false)
        #expect(events == [1, 0])
    }

    @Test func onlyTheChosenPhysicalInputReplacesPTTAndOtherBindingsStayIntact() async throws {
        let controller = MicrophoneIsolationTestController()
        let pad = try #require(controller.extendedGamepad)
        let hub = ControllerHub(mappingProvider: { _, input in
            switch input {
            case .menu, .buttonA: .pushToTalk
            default: .disabled
            }
        }, controllerProvider: { [controller] }, currentControllerProvider: { controller })
        defer { hub.stop() }
        hub.shouldRouteDualSensePTT = { $0 == .menu }
        var events: [Int] = []
        hub.keyHandler = { key, action in if key == "ACT10" { events.append(action) }; return true }
        hub.refreshControllers()
        await sendMenu(pad, true)
        await sendMenu(pad, false)
        #expect(events.isEmpty)
        pad.buttonA.setValue(1); pad.valueChangedHandler?(pad, pad.buttonA)
        await drain()
        pad.buttonA.setValue(0); pad.valueChangedHandler?(pad, pad.buttonA)
        await drain()
        #expect(events == [1, 0])
    }

    @Test func confirmedNeutralRecoveryDoesNotSwallowTheNextRealPress() async throws {
        let controller = MicrophoneIsolationTestController()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge { input in input == .menu ? .pushToTalk : .disabled }
        bridge.attachController(controller)
        defer { bridge.stop() }
        var events: [Int] = []
        var highlight: [Bool] = []
        bridge.keyHandler = { key, action in if key == "ACT10" { events.append(action) }; return true }
        bridge.onInputStateChange = { input, pressed in if input == .menu { highlight.append(pressed) } }
        await sendMenu(pad, true)
        bridge.setExternalMicrophoneIsolation(true)
        #expect(events == [1, 0])
        await sendMenu(pad, false) // Deliberately discarded while audio owns HID.
        bridge.setExternalMicrophoneIsolation(false) // Caller has verified raw neutral.
        await sendMenu(pad, true)
        await sendMenu(pad, false)
        #expect(events == [1, 0, 1, 0])
        #expect(highlight == [true, false, true, false])
    }

    @Test func queuedGCPressFromBeforeIsolationCannotReappearAfterRecovery() async throws {
        let controller = MicrophoneIsolationTestController()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge { input in input == .menu ? .pushToTalk : .disabled }
        bridge.attachController(controller)
        defer { bridge.stop() }
        var events: [Int] = []
        bridge.keyHandler = { _, action in events.append(action); return true }
        pad.buttonMenu.setValue(1)
        pad.valueChangedHandler?(pad, pad.buttonMenu) // Enqueued, not yet delivered.
        bridge.setExternalMicrophoneIsolation(true)
        pad.buttonMenu.setValue(0)
        pad.valueChangedHandler?(pad, pad.buttonMenu)
        bridge.setExternalMicrophoneIsolation(false)
        await drain()
        #expect(events.isEmpty)
        await sendMenu(pad, true)
        await sendMenu(pad, false)
        #expect(events == [1, 0])
    }
}
