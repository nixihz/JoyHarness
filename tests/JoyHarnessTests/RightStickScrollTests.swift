import CoreGraphics
import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct RightStickScrollTests {
    private struct StickSample: Equatable {
        let x: Float
        let y: Float
    }

    @Test
    func pairRightStickScrollsInsteadOfDrivingRadialInput() {
        let bridge = ButtonBridge()
        var scrollSamples: [StickSample] = []
        var radialDistances: [Float] = []
        bridge.rightStickHandler = { scrollSamples.append(StickSample(x: $0, y: $1)) }
        bridge.joystickHandler = { _, distance in
            radialDistances.append(distance)
            return true
        }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [:],
            primaryStick: .neutral,
            secondaryStick: JoyConStick(x: 0.3, y: -0.9)
        ))

        #expect(scrollSamples.last == StickSample(x: 0.3, y: -0.9))
        #expect(radialDistances.allSatisfy { $0 == 0 })
    }

    @Test
    func holdingLTTurnsTheRightStickIntoShortcutsInsteadOfScrolling() {
        let bridge = ButtonBridge { input in
            switch input {
            case .leftTrigger: .functionModifier
            case .functionRightStickRight: .browserForward
            default: .disabled
            }
        }
        var scrollSamples: [StickSample] = []
        var systemKeys: [(SystemKey, Bool)] = []
        bridge.rightStickHandler = { scrollSamples.append(StickSample(x: $0, y: $1)) }
        bridge.systemKeyHandler = { systemKeys.append(($0, $1)) }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.leftTrigger: true],
            primaryStick: .neutral,
            secondaryStick: JoyConStick(x: 1, y: 0)
        ))

        #expect(scrollSamples.last == StickSample(x: 0, y: 0))
        #expect(systemKeys.first?.0 == .browserForward)
        #expect(systemKeys.first?.1 == true)
    }

    @Test
    func dpadStillDrivesRadialInput() {
        let bridge = ButtonBridge()
        var radialDistances: [Float] = []
        bridge.joystickHandler = { _, distance in
            radialDistances.append(distance)
            return true
        }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.dpadLeft: true],
            primaryStick: .neutral,
            secondaryStick: .neutral
        ))

        #expect(radialDistances.last == 1)
    }

    @Test
    func resetAndSuspendStopRightStickScrolling() {
        let bridge = ButtonBridge()
        var scrollSamples: [StickSample] = []
        bridge.rightStickHandler = { scrollSamples.append(StickSample(x: $0, y: $1)) }
        let tilted = JoyConInputSnapshot(
            buttons: [:],
            primaryStick: .neutral,
            secondaryStick: JoyConStick(x: 0, y: 0.8)
        )

        bridge.applyJoyConSnapshot(tilted)
        bridge.suspendMappedOutputs()
        #expect(scrollSamples.last == StickSample(x: 0, y: 0))

        bridge.applyJoyConSnapshot(tilted)
        #expect(scrollSamples.last == StickSample(x: 0, y: 0.8))
        bridge.resetInputState()
        #expect(scrollSamples.last == StickSample(x: 0, y: 0))
    }

    @Test
    func rightStickScrollsWhileTheLeftStickKeepsMovingThePointer() {
        let velocities = MouseBridge.stickMotionVelocities(
            leftStick: CGPoint(x: 0.8, y: 0),
            leftStickScrolls: false,
            scrollStick: CGPoint(x: 0, y: -0.9),
            pointerSpeedMultiplier: 1,
            scrollDirection: .traditional
        )

        #expect(velocities.pointer.x > 0)
        #expect(velocities.pointer.y == 0)
        #expect(velocities.scroll.x == 0)
        #expect(velocities.scroll.y < 0)
    }

    @Test
    func rightStickAndLTLeftStickScrollAtTheSameSpeed() {
        let rightStick = MouseBridge.stickMotionVelocities(
            leftStick: .zero,
            leftStickScrolls: false,
            scrollStick: CGPoint(x: 0.2, y: 0.7),
            pointerSpeedMultiplier: 1,
            scrollDirection: .natural
        )
        let functionLeftStick = MouseBridge.stickMotionVelocities(
            leftStick: CGPoint(x: 0.2, y: 0.7),
            leftStickScrolls: true,
            scrollStick: .zero,
            pointerSpeedMultiplier: 1,
            scrollDirection: .natural
        )

        #expect(functionLeftStick.pointer == .zero)
        #expect(functionLeftStick.scroll == rightStick.scroll)
        #expect(rightStick.scroll != .zero)
    }

    @Test
    func scrollDirectionPreferenceAppliesToTheRightStick() {
        let traditional = MouseBridge.stickMotionVelocities(
            leftStick: .zero,
            leftStickScrolls: false,
            scrollStick: CGPoint(x: 0, y: 0.6),
            pointerSpeedMultiplier: 1,
            scrollDirection: .traditional
        )
        let natural = MouseBridge.stickMotionVelocities(
            leftStick: .zero,
            leftStickScrolls: false,
            scrollStick: CGPoint(x: 0, y: 0.6),
            pointerSpeedMultiplier: 1,
            scrollDirection: .natural
        )

        #expect(traditional.scroll.y > 0)
        #expect(natural.scroll.y == -traditional.scroll.y)
    }
}
