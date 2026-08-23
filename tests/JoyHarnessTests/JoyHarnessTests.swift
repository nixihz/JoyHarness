import Foundation
import Testing
@testable import JoyHarness

struct JoyHarnessTests {
    @Test
    func rp2040HandshakeAcceptsCurrentAndLegacyFirmware() {
        #expect(RP2040Bridge.isReadyLine("READY agentdeck-rp2040 0.1.0"))
        #expect(RP2040Bridge.isReadyLine("READY agentdeck-rp2040"))
        #expect(RP2040Bridge.isReadyLine("READY codexpad-rp2040 0.1.0"))
        #expect(RP2040Bridge.isReadyLine("READY codexpad-rp2040"))
        #expect(!RP2040Bridge.isReadyLine("READY other-device 0.1.0"))
        #expect(!RP2040Bridge.isReadyLine("agentdeck-rp2040"))
    }

    @Test
    func stateParsingIsCaseAndWhitespaceInsensitive() {
        #expect(PadState.parse(" Waiting\n") == .waiting)
        #expect(PadState.parse("unknown") == nil)
    }

    @Test
    func dashboardStatusDecodesSixPhysicalMicroSlots() throws {
        let slots = (1...6).map { slot in
            """
            {"slot":\(slot),"selected":\(slot == 3),"thread_id":"","title":"","state":"idle"}
            """
        }.joined(separator: ",")
        let json = """
        {
          "state":"waiting",
          "selected_slot":3,
          "slots":[\(slots)],
          "controller":"Xbox Wireless Controller",
          "haptics":true,
          "accessibility":false,
          "microphone":false,
          "rp2040":true,
          "mode":"physical-codex-micro",
          "note":"PermissionRequest",
          "ts":"2026-08-23T03:47:42Z"
        }
        """

        let status = try JSONDecoder().decode(DashboardStatus.self, from: Data(json.utf8))
        #expect(status.slots.count == 6)
        #expect(status.selectedSlot == 3)
        #expect(status.selected?.displayTitle == "Micro 槽位")
        #expect(status.padState == .waiting)
        #expect(status.rp2040)
    }

    @Test
    func visualSlotSelectionUsesTheNativeMicroAgentKey() {
        let bridge = ButtonBridge()
        var sent: [(String, Int)] = []
        bridge.keyHandler = { key, action in
            sent.append((key, action))
            return true
        }

        bridge.selectSlot(4)

        #expect(bridge.selectedSlot == 4)
        #expect(sent.first?.0 == "AG04")
        #expect(sent.first?.1 == 1)
    }

    @Test
    func faceButtonsControlMouseAndKeyboardByDefault() {
        #expect(ButtonBridge.faceAction(for: .a, functionPressed: false) == .mouseButton(.left))
        #expect(ButtonBridge.faceAction(for: .b, functionPressed: false) == .mouseButton(.right))
        #expect(ButtonBridge.faceAction(for: .x, functionPressed: false) == .systemKey(.backspace))
        #expect(ButtonBridge.faceAction(for: .y, functionPressed: false) == .systemKey(.escape))
    }

    @Test
    func functionModifierRestoresCodexFaceButtonActions() {
        #expect(ButtonBridge.faceAction(for: .a, functionPressed: true) == .microKey("ACT07"))
        #expect(ButtonBridge.faceAction(for: .b, functionPressed: true) == .microKey("ACT08"))
        #expect(ButtonBridge.faceAction(for: .x, functionPressed: true) == .microKey("ACT06"))
        #expect(ButtonBridge.faceAction(for: .y, functionPressed: true) == .microKey("ACT09"))
    }

    @Test
    func functionModifiedDPadSelectsSlotsCounterclockwise() {
        #expect(ButtonBridge.slot(for: .up) == 0)
        #expect(ButtonBridge.slot(for: .left) == 1)
        #expect(ButtonBridge.slot(for: .down) == 2)
        #expect(ButtonBridge.slot(for: .right) == 3)
    }

    @Test
    func defaultMappingsPreserveExistingControllerBehavior() {
        let store = ControllerMappingStore()
        #expect(store.action(for: .buttonA).controllerAction == .mouseButton(.left))
        #expect(store.action(for: .buttonB).controllerAction == .mouseButton(.right))
        #expect(store.action(for: .leftTrigger) == .functionModifier)
        #expect(store.action(for: .functionButtonA).controllerAction == .microKey("ACT07"))
        #expect(store.action(for: .functionDpadUp).controllerAction == .selectSlot(0))
        #expect(store.action(for: .functionDpadLeft).controllerAction == .selectSlot(1))
        #expect(store.action(for: .functionDpadDown).controllerAction == .selectSlot(2))
        #expect(store.action(for: .functionDpadRight).controllerAction == .selectSlot(3))
    }

    @Test
    func customMappingPersistsAndCanBeReset() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.quickAction, for: .buttonA)

        let reloaded = ControllerMappingStore(userDefaults: defaults)
        #expect(reloaded.action(for: .buttonA) == .quickAction)
        reloaded.resetDefaults()
        #expect(reloaded.action(for: .buttonA) == .mouseLeft)
    }

    @Test
    func rightStickUsesScreenOrientedRadialAngles() {
        #expect(abs(ButtonBridge.radialAngle(x: 1, y: 0) - 0) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: 0, y: -1) - 0.25) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: -1, y: 0) - 0.5) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: 0, y: 1) - 0.75) < 0.000_001)
    }

    @Test
    func mouseStickUsesADeadZoneAndAcceleratesTowardTheEdge() {
        #expect(MouseBridge.pointerVelocity(x: 0.1, y: 0.1) == .zero)

        let precision = MouseBridge.pointerVelocity(x: 0.2, y: 0)
        let medium = MouseBridge.pointerVelocity(x: 0.5, y: 0)
        let maximum = MouseBridge.pointerVelocity(x: 1, y: 0)
        #expect(precision.x > 0)
        #expect(medium.x > precision.x)
        #expect(maximum.x > medium.x)
        #expect(maximum.y == 0)
    }

    @Test
    func mouseStickKeepsEnoughTravelForPrecisionAdjustments() {
        let quarter = MouseBridge.pointerVelocity(x: 0.25, y: 0).x
        let precisionEdge = MouseBridge.pointerVelocity(x: 0.35, y: 0).x
        let fast = MouseBridge.pointerVelocity(x: 0.75, y: 0).x
        let maximum = MouseBridge.pointerVelocity(x: 1, y: 0).x

        #expect(quarter > 0 && quarter <= 20)
        #expect(precisionEdge > quarter && precisionEdge <= 65)
        #expect(fast >= 500)
        #expect(abs(maximum - 1_250) < 0.000_001)
    }

    @Test
    func mouseStickConvertsControllerUpToScreenUp() {
        let velocity = MouseBridge.pointerVelocity(x: 0, y: 1)
        #expect(velocity.x == 0)
        #expect(velocity.y < 0)
    }

    @Test
    func mouseVelocitySmoothingIsFrameRateIndependent() {
        let oneFrame = MouseBridge.smoothingFactor(
            deltaTime: 1.0 / 120.0,
            responseTime: 0.05
        )
        let twoFrames = 1 - pow(1 - oneFrame, 2)
        let direct = MouseBridge.smoothingFactor(
            deltaTime: 1.0 / 60.0,
            responseTime: 0.05
        )

        #expect(abs(twoFrames - direct) < 0.000_001)
    }

    @Test
    func mouseSpeedBoostScalesVelocityWithoutChangingDirection() {
        let normal = MouseBridge.pointerVelocity(x: 0.6, y: -0.3)
        let boosted = MouseBridge.pointerVelocity(
            x: 0.6,
            y: -0.3,
            speedMultiplier: 1.8
        )

        #expect(abs(boosted.x - normal.x * 1.8) < 0.000_001)
        #expect(abs(boosted.y - normal.y * 1.8) < 0.000_001)
    }

    @Test
    func scrollStickUsesDeadZoneAndPreservesBothAxes() {
        #expect(MouseBridge.scrollVelocity(x: 0.1, y: 0.1) == .zero)

        let vertical = MouseBridge.scrollVelocity(x: 0, y: 0.6)
        let horizontal = MouseBridge.scrollVelocity(x: -0.6, y: 0)
        let diagonal = MouseBridge.scrollVelocity(x: 0.5, y: -0.5)

        #expect(vertical.x == 0)
        #expect(vertical.y > 0)
        #expect(horizontal.x < 0)
        #expect(horizontal.y == 0)
        #expect(diagonal.x > 0)
        #expect(diagonal.y < 0)
    }
}
