import Foundation
import GameController
import Testing
@testable import JoyHarness

@MainActor
struct MotionJumpPSIntegrationTests {
    @Test(arguments: [false, true])
    func delayedGCL2CannotRestartMotionAfterRawPSTapOrVoiceCancellation(rawReleaseFirst: Bool) async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        bridge.aiVoiceEnabled = true
        var snapshots: [MotionJumpInputSnapshot] = []
        bridge.motionJumpInputHandler = { snapshots.append($0); return false }
        let now = ProcessInfo.processInfo.systemUptime
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: now - 0.03))
        bridge.handleDualSensePSInput(.init(isPressed: true, leftTriggerValue: 1, timestamp: now - 0.02))
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 1, timestamp: now - 0.01))
        bridge.cancelAIVoiceInput()
        pad.leftTrigger.setValue(1)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.last?.hasConflictingInput == true)
        if rawReleaseFirst {
            bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0,
                                                timestamp: ProcessInfo.processInfo.systemUptime))
        }
        pad.leftTrigger.setValue(0)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.last?.triggerValue == 0)
        if !rawReleaseFirst {
            bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0,
                                                timestamp: ProcessInfo.processInfo.systemUptime))
        }
        pad.leftTrigger.setValue(1)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.last?.hasConflictingInput == false)
    }

    @Test func lateGCNeutralDoesNotUnlockChordWhileRawL2RemainsHeld() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        bridge.aiVoiceEnabled = true
        var snapshots: [MotionJumpInputSnapshot] = []
        bridge.motionJumpInputHandler = { snapshots.append($0); return false }
        let now = ProcessInfo.processInfo.systemUptime
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: now - 0.03))
        bridge.handleDualSensePSInput(.init(isPressed: true, leftTriggerValue: 1, timestamp: now - 0.02))
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 1, timestamp: now - 0.01))
        bridge.cancelAIVoiceInput()
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        // This old GC neutral must not satisfy the release requirement before
        // GC has even observed the current L2 press. Raw then finishes first.
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0,
                                            timestamp: ProcessInfo.processInfo.systemUptime))
        pad.leftTrigger.setValue(1)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.map(\.hasConflictingInput) == [true, true])
    }

    @Test func rawHIDInterruptionRecoversMotionAfterFreshGCRelease() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        bridge.aiVoiceEnabled = true
        var snapshots: [MotionJumpInputSnapshot] = []
        bridge.motionJumpInputHandler = { snapshots.append($0); return false }
        pad.leftTrigger.setValue(1)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        let now = ProcessInfo.processInfo.systemUptime
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: now - 0.02))
        bridge.handleDualSensePSInput(.init(isPressed: true, leftTriggerValue: 1, timestamp: now - 0.01))
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 1, timestamp: now))
        bridge.interruptDualSensePSInput()
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.last?.hasConflictingInput == true)
        pad.leftTrigger.setValue(0)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        // Multi-DualSense routing can repeat interruption before the queued
        // release arrives; it must not continually move the neutral fence.
        bridge.interruptDualSensePSInput()
        await drain()
        #expect(snapshots.last?.hasConflictingInput == true)
        pad.leftTrigger.setValue(1)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        #expect(snapshots.last?.hasConflictingInput == false)
    }

    @Test func delayedRawReportsCannotDuplicateOrReleaseGameControllerL2() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        var triggers: [Float] = []
        bridge.motionJumpInputHandler = { triggers.append($0.triggerValue); return false }
        pad.leftTrigger.setValue(0.9)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        // A queued raw neutral report arrives after the GC press; it must
        // not finish the gesture. Neither may the later raw press restart it.
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: 1))
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0.9, timestamp: 1.02))
        pad.leftTrigger.setValue(0)
        pad.valueChangedHandler?(pad, pad.leftTrigger)
        await drain()
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0.9, timestamp: 1.04))
        #expect(triggers == [0.9, 0])
    }

    @Test func rawPSCancelsGestureAndIsConsumedDuringCalibration() {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        var cancels = 0
        var voiceStarts = 0
        var switcherOpens = 0
        bridge.motionJumpIsCapturing = { true }
        bridge.motionJumpCancelHandler = { cancels += 1 }
        bridge.onAIVoiceBegin = { voiceStarts += 1 }
        bridge.onHarnessSwitcherPresent = { switcherOpens += 1 }
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: 1))
        for frame in 1...10 {
            bridge.handleDualSensePSInput(.init(isPressed: true, leftTriggerValue: 0.9, timestamp: 1 + Double(frame) * 0.1))
        }
        bridge.handleDualSensePSInput(.init(isPressed: false, leftTriggerValue: 0, timestamp: 2.1))
        #expect(cancels > 0)
        #expect(voiceStarts == 0)
        #expect(switcherOpens == 0)
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
