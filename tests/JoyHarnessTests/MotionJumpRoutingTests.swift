import Foundation
import GameController
import Testing
@testable import JoyHarness

@MainActor
struct MotionJumpRoutingTests {
    private func drainInputQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func snapshotsKeepTriggerEdgesAndAlreadyHeldConflictsWhileQueued() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        var snapshots: [MotionJumpInputSnapshot] = []
        bridge.motionJumpInputHandler = { snapshots.append($0); return true }

        // The face button was already down before L2. Dispatch all three
        // events before draining so a live read on the main queue would lose
        // the press/release and the conflict attached to the first two events.
        gamepad.buttonA.setValue(1)
        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        gamepad.leftTrigger.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        gamepad.buttonA.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        await drainInputQueue()

        #expect(snapshots.count == 3)
        #expect(snapshots.map(\.triggerValue) == [0.8, 0, 0])
        #expect(snapshots.map(\.hasConflictingInput) == [true, true, false])
        #expect(snapshots.first?.allowsGesture == true)
    }

    @Test func diagonalStickBeyondRadialDeadZoneCancelsMotion() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        gamepad.leftThumbstick.xAxis.setValue(0.08)
        gamepad.leftThumbstick.yAxis.setValue(0.08)
        #expect(ButtonBridge.motionJumpSnapshot(gamepad: gamepad).hasConflictingInput)
        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.leftThumbstick.yAxis.setValue(0)
        gamepad.rightThumbstick.xAxis.setValue(0.11)
        gamepad.rightThumbstick.yAxis.setValue(0.11)
        #expect(ButtonBridge.motionJumpSnapshot(gamepad: gamepad).hasConflictingInput)
        gamepad.rightThumbstick.xAxis.setValue(0.05)
        gamepad.rightThumbstick.yAxis.setValue(0.05)
        #expect(!ButtonBridge.motionJumpSnapshot(gamepad: gamepad).hasConflictingInput)
    }

    @Test func endingCalibrationDoesNotLeakHeldButtonOrStick() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge { $0 == .buttonA ? .mouseLeft : .functionModifier }
        bridge.attachController(controller)
        defer { bridge.stop() }
        var capturing = true
        var mouseEvents: [Bool] = []
        var pointerEvents: [Float] = []
        bridge.motionJumpInputHandler = { _ in capturing }
        bridge.mouseButtonHandler = { _, pressed in mouseEvents.append(pressed) }
        bridge.leftStickHandler = { x, _, _ in pointerEvents.append(x) }

        gamepad.buttonA.setValue(1)
        gamepad.leftThumbstick.xAxis.setValue(0.7)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        await drainInputQueue()
        capturing = false
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        #expect(mouseEvents.isEmpty)
        #expect(pointerEvents.allSatisfy { $0 == 0 })

        gamepad.buttonA.setValue(0)
        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        await drainInputQueue()
        gamepad.buttonA.setValue(1)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        await drainInputQueue()
        #expect(mouseEvents == [true])
    }

    @Test func calibrationConsumesBothHomeSourcesAndTheirDelayedEcho() {
        let bridge = ButtonBridge()
        var capturing = true
        var presented = 0
        bridge.motionJumpInputHandler = { _ in capturing }
        bridge.onHarnessSwitcherPresent = { presented += 1 }

        bridge.handleRawHomeButton(isPressed: true)
        capturing = false
        bridge.handleHomeButton(isPressed: true)
        #expect(presented == 0)
        bridge.handleRawHomeButton(isPressed: false)
        bridge.handleHomeButton(isPressed: false)
        bridge.handleRawHomeButton(isPressed: true)
        #expect(presented == 1)
    }

    @Test func nativeModeCustomTriggerAndOverlayRejectGestures() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        var triggerMapping = ControllerMappedAction.functionModifier
        let hub = ControllerHub(
            mappingProvider: { _, input in input == .leftTrigger ? triggerMapping : .disabled },
            controllerProvider: { [controller] },
            currentControllerProvider: { controller }
        )
        defer { hub.stop() }
        hub.refreshControllers()
        var allowed: [Bool] = []
        hub.motionJumpInputHandler = { _, snapshot in allowed.append(snapshot.allowsGesture); return false }
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        triggerMapping = .mouseLeft
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        triggerMapping = .functionModifier
        hub.setOperationMode(.native)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        hub.setOperationMode(.mapping)
        hub.handleRawHomeButton(isPressed: true)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(allowed.prefix(3).elementsEqual([true, false, false]))
        #expect(allowed.last == false)
    }

    @Test func suspendingCalibrationDevicePreservesOtherDevicesHeldOutput() async throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let firstGamepad = try #require(first.extendedGamepad)
        let secondGamepad = try #require(second.extendedGamepad)
        let hub = ControllerHub(
            mappingProvider: { _, input in input == .buttonA ? .mouseLeft : .disabled },
            controllerProvider: { [first, second] },
            currentControllerProvider: { first }
        )
        defer { hub.stop() }
        var mouseEvents: [Bool] = []
        var cancelled: [String] = []
        hub.mouseButtonHandler = { _, pressed in mouseEvents.append(pressed) }
        hub.refreshControllers()
        hub.motionJumpCancelHandler = { cancelled.append($0) }
        let firstID = ControllerHub.motionJumpDeviceID(first)
        #expect(hub.connectedDevices.contains { $0.id == firstID })

        firstGamepad.buttonA.setValue(1)
        firstGamepad.valueChangedHandler?(firstGamepad, firstGamepad.buttonA)
        secondGamepad.buttonA.setValue(1)
        secondGamepad.valueChangedHandler?(secondGamepad, secondGamepad.buttonA)
        await drainInputQueue()
        hub.suspendMotionJumpDevice(id: firstID)
        #expect(cancelled == [firstID])
        #expect(mouseEvents == [true])
        secondGamepad.buttonA.setValue(0)
        secondGamepad.valueChangedHandler?(secondGamepad, secondGamepad.buttonA)
        await drainInputQueue()
        #expect(mouseEvents == [true, false])
    }

    @Test func recordingOneControllerConsumesOnlyThatControllersMappings() async throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let firstGamepad = try #require(first.extendedGamepad)
        let secondGamepad = try #require(second.extendedGamepad)
        let firstID = ControllerHub.motionJumpDeviceID(first)
        let hub = ControllerHub(
            mappingProvider: { _, input in input == .buttonA ? .mouseLeft : .disabled },
            controllerProvider: { [first, second] },
            currentControllerProvider: { first }
        )
        defer { hub.stop() }
        hub.refreshControllers()
        var mouseEvents: [Bool] = []
        hub.mouseButtonHandler = { _, pressed in mouseEvents.append(pressed) }
        hub.motionJumpInputHandler = { id, _ in id == firstID }

        firstGamepad.buttonA.setValue(1)
        firstGamepad.valueChangedHandler?(firstGamepad, firstGamepad.buttonA)
        await drainInputQueue()
        #expect(mouseEvents.isEmpty)
        secondGamepad.buttonA.setValue(1)
        secondGamepad.valueChangedHandler?(secondGamepad, secondGamepad.buttonA)
        await drainInputQueue()
        #expect(mouseEvents == [true])
    }
}
