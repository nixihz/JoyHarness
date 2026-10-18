import CoreGraphics
import Foundation
import GameController
import Testing
@testable import JoyHarness

@MainActor
@Suite(.serialized)
struct FunctionPointerBoostTests {
    /// Follow the same ButtonBridge -> MouseBridge outputs as the application,
    /// so routing the stick into scroll mode cannot pass as a pointer boost.
    private final class MotionOutput {
        var leftStick = CGPoint.zero
        var leftStickScrolls = false
        var scrollStick = CGPoint.zero
        var boostActive = false
        var boostEvents: [Bool] = []

        init(bridge: ButtonBridge) {
            bridge.leftStickHandler = { [self] x, y, scrolling in
                leftStick = CGPoint(x: CGFloat(x), y: CGFloat(y))
                leftStickScrolls = scrolling
            }
            bridge.rightStickHandler = { [self] x, y in
                scrollStick = CGPoint(x: CGFloat(x), y: CGFloat(y))
            }
            bridge.mouseSpeedBoostHandler = { [self] active in
                boostActive = active
                boostEvents.append(active)
            }
        }

        var velocities: StickMotionVelocities {
            MouseBridge.stickMotionVelocities(
                leftStick: leftStick,
                leftStickScrolls: leftStickScrolls,
                scrollStick: scrollStick,
                pointerSpeedMultiplier: MouseBridge.pointerSpeedMultiplier(
                    precisionActive: false,
                    speedBoostActive: boostActive
                ),
                scrollDirection: .traditional
            )
        }
    }

    private func snapshot(_ held: [ControllerInput] = []) -> JoyConInputSnapshot {
        JoyConInputSnapshot(
            buttons: Dictionary(uniqueKeysWithValues: held.map { ($0, true) }),
            primaryStick: JoyConStick(x: 0.6, y: 0.4),
            secondaryStick: .neutral
        )
    }

    @Test(arguments: [
        ControllerFamily.generic, .dualSense, .dualShock, .xbox, .joyConPair,
    ])
    func functionLayerAcceleratesThePointerWithoutScrolling(family: ControllerFamily) {
        let bridge = ButtonBridge(controllerFamily: family)
        let output = MotionOutput(bridge: bridge)
        bridge.applyJoyConSnapshot(snapshot())
        let normal = output.velocities
        #expect(normal.pointer.x > 0)
        #expect(normal.pointer.y < 0)

        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        let accelerated = output.velocities
        #expect(!output.leftStickScrolls)
        #expect(accelerated.pointer.x > normal.pointer.x)
        #expect(accelerated.pointer.y < normal.pointer.y)
        #expect(accelerated.scroll == .zero)
        #expect(output.boostEvents == [true])

        bridge.applyJoyConSnapshot(snapshot())
        #expect(output.velocities == normal)
        #expect(output.boostEvents == [true, false])
    }

    @Test(arguments: [ControllerFamily.joyConLeft, .joyConRight])
    func singleJoyConKeepsItsOnlyStickAvailableForScrolling(family: ControllerFamily) {
        let bridge = ButtonBridge(controllerFamily: family) { input in
            input == .leftShoulder ? .functionModifier : .disabled
        }
        let output = MotionOutput(bridge: bridge)
        bridge.applyJoyConSnapshot(snapshot())
        let normal = output.velocities
        #expect(normal.pointer != .zero)

        bridge.applyJoyConSnapshot(snapshot([.leftShoulder]))
        #expect(output.leftStickScrolls)
        #expect(output.velocities.pointer == .zero)
        #expect(output.velocities.scroll != .zero)
        #expect(output.boostEvents.isEmpty)

        bridge.applyJoyConSnapshot(snapshot())
        #expect(output.velocities == normal)
    }

    @Test(arguments: [ControllerInput.leftThumbstickButton, .joyConSL], [false, true])
    func functionAndMappedBoostRemainActiveUntilBothRelease(
        boostInput: ControllerInput,
        releaseFunctionFirst: Bool
    ) {
        let bridge = ButtonBridge { input in
            if input == .leftTrigger { return .functionModifier }
            if input == boostInput { return .mouseSpeedBoost }
            return .disabled
        }
        let output = MotionOutput(bridge: bridge)
        // Press L3 before Fn so its held action stays the base-layer boost.
        bridge.applyJoyConSnapshot(snapshot([boostInput]))
        let accelerated = output.velocities
        #expect(accelerated.pointer != .zero)
        bridge.applyJoyConSnapshot(snapshot([boostInput, .leftTrigger]))
        #expect(output.velocities == accelerated)
        #expect(output.boostEvents == [true])

        bridge.applyJoyConSnapshot(snapshot(releaseFunctionFirst ? [boostInput] : [.leftTrigger]))
        #expect(output.velocities == accelerated)
        #expect(output.boostEvents == [true])

        bridge.applyJoyConSnapshot(snapshot())
        #expect(output.velocities.pointer.x < accelerated.pointer.x)
        #expect(output.velocities.scroll == .zero)
        #expect(output.boostEvents == [true, false])
    }

    enum StopAction: CaseIterable {
        case reset, suspend, native
    }

    @Test(arguments: StopAction.allCases)
    func stoppingMappedOutputClearsFunctionAndMappedBoost(action: StopAction) {
        let bridge = ButtonBridge { input in
            switch input {
            case .leftTrigger: .functionModifier
            case .joyConSL: .mouseSpeedBoost
            default: .disabled
            }
        }
        let output = MotionOutput(bridge: bridge)
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger, .joyConSL]))
        #expect(output.boostEvents == [true])
        #expect(output.velocities.pointer != .zero)

        switch action {
        case .reset: bridge.resetInputState()
        case .suspend: bridge.suspendMappedOutputs()
        case .native: bridge.setOperationMode(.native)
        }

        #expect(output.boostEvents == [true, false])
        #expect(output.velocities.pointer == .zero)
        #expect(output.velocities.scroll == .zero)
        // A later neutral report must not release the already-cleared boost again.
        bridge.applyJoyConSnapshot(.neutral)
        #expect(output.boostEvents == [true, false])
    }

    @Test
    func gameControllerL2BoostsMovingPointerAndHonorsTriggerRemapping() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        var triggerAction = ControllerMappedAction.functionModifier
        let bridge = ButtonBridge { input in
            input == .leftTrigger ? triggerAction : .disabled
        }
        bridge.attachController(controller)
        defer { bridge.stop() }
        let output = MotionOutput(bridge: bridge)
        var mousePresses: [Bool] = []
        bridge.mouseButtonHandler = { button, pressed in
            #expect(button == .left)
            mousePresses.append(pressed)
        }
        gamepad.leftThumbstick.xAxis.setValue(0.6)
        gamepad.leftThumbstick.yAxis.setValue(0.4)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        let normal = output.velocities
        #expect(normal.pointer != .zero)

        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.velocities.pointer.x > normal.pointer.x)
        #expect(output.velocities.pointer.y < normal.pointer.y)
        #expect(output.velocities.scroll == .zero)
        #expect(output.boostEvents == [true])

        gamepad.leftTrigger.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.velocities == normal)
        #expect(output.boostEvents == [true, false])

        triggerAction = .mouseLeft
        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(mousePresses == [true])
        #expect(output.velocities == normal)
        #expect(output.boostEvents == [true, false])

        gamepad.leftTrigger.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(mousePresses == [true, false])
    }

    @Test
    func interceptedGameControllerL2DoesNotPulseBoostAndRequiresAFreshPress() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        let output = MotionOutput(bridge: bridge)
        var consumesFunction = true
        bridge.inputInterceptor = { input, pressed in
            input == .leftTrigger && pressed && consumesFunction
        }
        gamepad.leftThumbstick.xAxis.setValue(0.6)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        let normal = output.velocities
        #expect(normal.pointer.x > 0)

        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        // Checking the entire event history catches even a transient true/false
        // pair that would leave the final pointer velocity looking normal.
        #expect(output.boostEvents.isEmpty)
        #expect(output.velocities == normal)

        consumesFunction = false
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        #expect(output.boostEvents.isEmpty)
        #expect(output.velocities == normal)

        gamepad.leftTrigger.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.boostEvents.isEmpty)
        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.boostEvents == [true])
        #expect(output.velocities.pointer.x > normal.pointer.x)
        #expect(output.velocities.scroll == .zero)
    }

    @Test
    func suspendedGameControllerL2StaysUnboostedUntilReleasedAndPressedAgain() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        let output = MotionOutput(bridge: bridge)
        gamepad.leftThumbstick.xAxis.setValue(0.6)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        let normal = output.velocities
        #expect(normal.pointer.x > 0)

        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.boostEvents == [true])
        bridge.suspendMappedOutputs()
        #expect(output.boostEvents == [true, false])
        #expect(output.velocities.pointer == .zero)

        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        await drainInputQueue()
        #expect(output.boostEvents == [true, false])
        #expect(output.velocities == normal)

        gamepad.leftTrigger.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.boostEvents == [true, false])
        gamepad.leftTrigger.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftTrigger)
        await drainInputQueue()
        #expect(output.boostEvents == [true, false, true])
        #expect(output.velocities.pointer.x > normal.pointer.x)
        #expect(output.velocities.scroll == .zero)
    }

    enum FunctionInputConsumer: CaseIterable {
        case overlay, interceptor
    }

    @Test(arguments: FunctionInputConsumer.allCases)
    func consumedJoyConPairFunctionRequiresReleaseBeforeBoostCanResume(
        consumer: FunctionInputConsumer
    ) {
        let bridge = ButtonBridge(controllerFamily: .joyConPair)
        let output = MotionOutput(bridge: bridge)
        var consumesFunction = false
        bridge.overlayStickHandler = { _, _ in
            consumer == .overlay && consumesFunction
        }
        bridge.inputInterceptor = { input, pressed in
            consumer == .interceptor && consumesFunction && input == .leftTrigger && pressed
        }
        bridge.applyJoyConSnapshot(snapshot())
        let normal = output.velocities
        #expect(normal.pointer.x > 0)

        consumesFunction = true
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents.isEmpty)

        consumesFunction = false
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents.isEmpty)
        #expect(output.velocities == normal)

        bridge.applyJoyConSnapshot(snapshot())
        #expect(output.boostEvents.isEmpty)
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents == [true])
        #expect(output.velocities.pointer.x > normal.pointer.x)
        #expect(output.velocities.scroll == .zero)
    }

    @Test
    func suspendedJoyConPairFunctionStaysUnboostedUntilReleasedAndPressedAgain() {
        let bridge = ButtonBridge(controllerFamily: .joyConPair)
        let output = MotionOutput(bridge: bridge)
        bridge.applyJoyConSnapshot(snapshot())
        let normal = output.velocities
        #expect(normal.pointer.x > 0)
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents == [true])

        bridge.suspendMappedOutputs()
        #expect(output.boostEvents == [true, false])
        #expect(output.velocities.pointer == .zero)
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents == [true, false])
        #expect(output.velocities == normal)

        bridge.applyJoyConSnapshot(snapshot())
        #expect(output.boostEvents == [true, false])
        bridge.applyJoyConSnapshot(snapshot([.leftTrigger]))
        #expect(output.boostEvents == [true, false, true])
        #expect(output.velocities.pointer.x > normal.pointer.x)
        #expect(output.velocities.scroll == .zero)
    }

    @Test
    func releasingModifierInAnotherHarnessAllowsItsNextPress() {
        var menuIsModifier = true
        let bridge = ButtonBridge(controllerFamily: .joyConPair) { input in
            input == .menu && menuIsModifier ? .functionModifier : .disabled
        }
        let output = MotionOutput(bridge: bridge)
        bridge.applyJoyConSnapshot(snapshot([.menu]))
        bridge.suspendMappedOutputs()
        #expect(output.boostEvents == [true, false])

        menuIsModifier = false
        bridge.applyJoyConSnapshot(snapshot([.menu]))
        bridge.applyJoyConSnapshot(snapshot())
        menuIsModifier = true
        bridge.applyJoyConSnapshot(snapshot([.menu]))

        #expect(output.boostEvents == [true, false, true])
        #expect(output.velocities.pointer.x > 0)
        #expect(output.velocities.scroll == .zero)
    }

    private func drainInputQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
