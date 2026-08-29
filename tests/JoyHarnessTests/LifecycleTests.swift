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
    func mouseBridgeCanRestartWithoutRetainingItsTimer() {
        let bridge = MouseBridge()

        bridge.start()
        bridge.start()
        #expect(bridge.isRunning)

        bridge.stop()
        bridge.stop()
        #expect(!bridge.isRunning)

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
