import Foundation
import Testing
@testable import JoyHarness

struct ControllerInputIsolationGateTests {
    @Test func callbackQueuedBeforeCaptureCannotEscapeAfterCaptureHasAlreadyEnded() throws {
        let gate = ControllerInputIsolationGate()
        let queuedBeforeCapture = try #require(gate.token())
        gate.setBlocked(true)
        #expect(gate.token() == nil)
        #expect(!gate.permits(queuedBeforeCapture))
        gate.setBlocked(false)

        // This is the common UI-queue race: the callback reaches the mapping
        // after both transitions. Checking only isBlocked would replay it.
        #expect(!gate.isBlocked)
        #expect(!gate.permits(queuedBeforeCapture))
        let freshCallback = try #require(gate.token())
        #expect(gate.permits(freshCallback))
    }

    @Test func repeatedStatusUpdatesDoNotDropFreshControlsButEveryCaptureCycleInvalidatesThem() throws {
        let gate = ControllerInputIsolationGate()
        let initial = try #require(gate.token())
        gate.setBlocked(false)
        gate.setBlocked(false)
        #expect(gate.permits(initial))
        gate.setBlocked(true)
        gate.setBlocked(true)
        #expect(gate.token() == nil)
        gate.setBlocked(false)
        let betweenCaptures = try #require(gate.token())
        #expect(gate.permits(betweenCaptures))
        gate.setBlocked(true)
        gate.setBlocked(false)
        #expect(!gate.permits(initial))
        #expect(!gate.permits(betweenCaptures))
        let freshCallback = try #require(gate.token())
        #expect(gate.permits(freshCallback))
    }

    @Test func isolatingOneDeviceDoesNotSuppressAnotherDevicesAlreadyQueuedCallback() throws {
        let dualSense = ControllerInputIsolationGate()
        let otherController = ControllerInputIsolationGate()
        let dualSenseCallback = try #require(dualSense.token())
        let otherCallback = try #require(otherController.token())
        dualSense.setBlocked(true)
        #expect(!dualSense.permits(dualSenseCallback))
        #expect(otherController.permits(otherCallback))
        dualSense.setBlocked(false)
        #expect(!dualSense.permits(dualSenseCallback))
        #expect(otherController.permits(otherCallback))
    }
}
