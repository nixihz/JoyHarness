import Foundation
import GameController
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceInputCaptureTests {
    private func drainInputQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func heldSticksRearmIndependentlyAfterVoiceEnds() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        var left: [Float] = [], right: [Float] = []
        bridge.leftStickHandler = { x, _, _ in left.append(x) }
        bridge.rightStickHandler = { x, _ in right.append(x) }
        bridge.setAIVoiceCaptureActive(true)
        gamepad.leftThumbstick.xAxis.setValue(0.7)
        gamepad.rightThumbstick.xAxis.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        bridge.setAIVoiceCaptureActive(false)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })

        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        gamepad.leftThumbstick.xAxis.setValue(0.6)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        #expect(left.last == 0.6)
        #expect(right.allSatisfy { $0 == 0 })

        gamepad.rightThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        gamepad.rightThumbstick.xAxis.setValue(0.9)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        #expect(right.last == 0.9)
    }

    @Test func queuedVoiceEventsCannotReplayAfterPhysicalSticksAreNeutral() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        var left: [Float] = [], right: [Float] = []
        bridge.leftStickHandler = { x, _, _ in left.append(x) }
        bridge.rightStickHandler = { x, _ in right.append(x) }
        bridge.setAIVoiceCaptureActive(true)
        gamepad.leftThumbstick.xAxis.setValue(0.7)
        gamepad.rightThumbstick.xAxis.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.rightThumbstick.xAxis.setValue(0)
        bridge.setAIVoiceCaptureActive(false)
        await drainInputQueue()
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })

        // Both channels were physically neutral on release, so the next fresh
        // push is allowed without an unnecessary extra neutral callback.
        gamepad.leftThumbstick.xAxis.setValue(0.6)
        gamepad.rightThumbstick.xAxis.setValue(0.9)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        #expect(left.last == 0.6)
        #expect(right.last == 0.9)
    }

    @Test func heldRightStickCannotBecomeModifierShortcutUntilRecentered() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge {
            switch $0 {
            case .leftTrigger: .functionModifier
            case .functionRightStickRight: .arrowRight
            default: .disabled
            }
        }
        bridge.attachController(controller)
        defer { bridge.stop() }
        var keys: [Bool] = []
        bridge.systemKeyHandler = { key, pressed in if key == .arrowRight { keys.append(pressed) } }
        bridge.setAIVoiceCaptureActive(true)
        gamepad.rightThumbstick.xAxis.setValue(0.9)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        bridge.setAIVoiceCaptureActive(false)
        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(keys.isEmpty)
        gamepad.rightThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        gamepad.rightThumbstick.xAxis.setValue(0.9)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightThumbstick.xAxis)
        await drainInputQueue()
        #expect(keys == [true])
    }

    @Test func touchpadNeedsAllContactsLiftedAndFreshMovementAfterVoice() {
        let bridge = ButtonBridge()
        var clock: TimeInterval = 1
        bridge.homeButtonClock = { clock }
        var deltas: [CGFloat] = []
        bridge.touchpadPointerHandler = { x, _ in deltas.append(x) }
        bridge.sampleTouchpadPointer(x: 0.1, y: 0.2, timestamp: 0.1)
        bridge.sampleTouchpadPointer(x: 0.2, y: 0.2, timestamp: 0.2)
        #expect(deltas.count == 1)
        deltas.removeAll()
        bridge.setAIVoiceCaptureActive(true)
        bridge.sampleTouchpadPointer(x: 0.3, y: 0.2, timestamp: 1.1)
        clock = 2
        bridge.setAIVoiceCaptureActive(false)
        bridge.sampleTouchpadPointer(x: 0.4, y: 0.2, timestamp: 2.1)
        bridge.sampleTouchpadPointer(x: 0, y: 0, secondaryTouching: true, timestamp: 2.2)
        bridge.sampleTouchpadPointer(x: 0.5, y: 0.2, timestamp: 2.3)
        #expect(deltas.isEmpty)
        bridge.sampleTouchpadPointer(x: 0, y: 0, timestamp: 2.4)
        bridge.sampleTouchpadPointer(x: 0.6, y: 0.2, timestamp: 2.5)
        #expect(deltas.isEmpty)
        bridge.sampleTouchpadPointer(x: 0.7, y: 0.2, timestamp: 2.6)
        #expect(deltas.count == 1)
        #expect(abs((deltas.last ?? 0) - 24) < 0.001)
    }

    @Test func joyConSticksAlsoRequireNeutralAfterVoice() {
        let bridge = ButtonBridge()
        var clock: TimeInterval = 1
        bridge.homeButtonClock = { clock }
        var left: [Float] = [], right: [Float] = []
        bridge.leftStickHandler = { x, _, _ in left.append(x) }
        bridge.rightStickHandler = { x, _ in right.append(x) }
        let held = JoyConInputSnapshot(buttons: [:], primaryStick: .init(x: 0.7, y: 0),
                                      secondaryStick: .init(x: 0.8, y: 0))
        bridge.setAIVoiceCaptureActive(true)
        clock = 1.1
        bridge.applyJoyConSnapshot(held)
        clock = 2
        bridge.setAIVoiceCaptureActive(false)
        clock = 2.1
        bridge.applyJoyConSnapshot(held)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })
        clock = 2.2
        bridge.applyJoyConSnapshot(.neutral)
        clock = 2.3
        bridge.applyJoyConSnapshot(held)
        #expect(left.last == 0.7)
        #expect(right.last == 0.8)
    }
}
