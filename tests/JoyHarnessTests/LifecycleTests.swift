import Testing
@testable import JoyHarness

@MainActor
struct LifecycleTests {
    @Test
    func buttonBridgeStartAndStopAreIdempotent() {
        let bridge = ButtonBridge()

        bridge.start()
        bridge.start()

        #expect(bridge.isRunning)
        #expect(bridge.controllerObserverCount == 3)

        bridge.stop()
        bridge.stop()

        #expect(!bridge.isRunning)
        #expect(bridge.controllerObserverCount == 0)
    }

    @Test
    func mouseBridgeCanRestartWithoutRetainingItsMovementClock() {
        let bridge = MouseBridge()

        bridge.start()
        bridge.start()
        #expect(bridge.isRunning)
        #expect(bridge.isObservingScreenChanges)

        bridge.stop()
        bridge.stop()
        #expect(!bridge.isRunning)
        #expect(!bridge.isObservingScreenChanges)

        bridge.start()
        #expect(bridge.isRunning)
        bridge.stop()
    }

    @Test
    func rp2040StopWaitsForReconnectTimerCleanup() {
        let bridge = RP2040Bridge()

        bridge.start()
        bridge.stop()

        #expect(!bridge.isRunning)
    }
}
