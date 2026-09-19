import Foundation
import Testing
@testable import JoyHarness

struct DashboardPresentationTests {
    private func status(_ changes: [String: Any] = [:]) throws -> DashboardStatus {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardStatus.empty)) as? [String: Any])
        json["controller"] = "Test controller"
        json["controller_connected"] = true
        json["controller_family"] = "xiaomi-remote"
        json["ts"] = "2027-01-15T08:00:00Z"
        for (key, value) in changes { json[key] = value }
        return try JSONDecoder().decode(DashboardStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func connectionDoesNotRequireHaptics() throws {
        let p = DashboardPresentation(status: try status(), freshness: .fresh)
        #expect(p.connected == true)
        #expect(!p.canTestHaptics)
        #expect(!p.mappingPaused)
    }

    @Test func staleAndUnavailableAreUnknown() throws {
        for freshness in [StatusFreshness.stale, .unavailable] {
            let p = DashboardPresentation(status: try status(["haptics": true]), freshness: freshness)
            #expect(p.connected == nil)
            #expect(!p.canTestHaptics)
            #expect(p.mappingPaused)
            #expect(p.authorization(true) == p.unknown)
            #expect(p.controllerRows.allSatisfy { $0.1 == p.unknown })
        }
    }

    @Test func unknownPermissionsAndBatteryRemainUnknown() throws {
        let p = DashboardPresentation(status: try status(), freshness: .fresh)
        #expect(p.authorization(nil) == p.unknown)
        #expect(p.authorization(false) != p.unknown)
        #expect(p.capability(nil) == p.unknown)
        #expect(p.batteryDescription(nil) == p.unknown)
        #expect(p.batteryDescription(.nan) == p.unknown)
        #expect(p.batteryDescription(0) == "0%")
    }

    @Test func nativeModePausesMappingsButAllowsHardwareTest() throws {
        let p = DashboardPresentation(status: try status(["operation_mode": "native", "haptics": true]), freshness: .fresh)
        #expect(p.mappingPaused)
        #expect(p.canTestHaptics)
    }

    @MainActor @Test func inputsClearWhenStateBecomesUnusable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("status.json")
        let now = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
        let repo = StatusRepository(statusURL: url, now: { now }, reportError: { _ in })
        #expect(repo.write(try status()))
        let store = DashboardStore(repository: repo)
        for changed in [
            try status(["controller_connected": false]),
            try status(["controller_family": "xbox"]),
            try status(["operation_mode": "native"]),
            try status(["ts": "2020-01-01T00:00:00Z"]),
        ] {
            #expect(repo.write(try status()))
            store.reload()
            store.setControllerInput(.buttonA, pressed: true)
            #expect(store.pressedControllerInputs == [.buttonA])
            store.setControllerInput(.buttonA, pressed: false)
            #expect(store.lastControllerInputs == [.buttonA])
            store.setControllerInput(.buttonB, pressed: true)
            #expect(repo.write(changed))
            store.reload()
            #expect(store.pressedControllerInputs.isEmpty)
            #expect(store.lastControllerInputs.isEmpty)
        }
        store.setControllerInput(.buttonA, pressed: true)
        try FileManager.default.removeItem(at: url)
        store.reload()
        #expect(store.pressedControllerInputs.isEmpty)
        #expect(store.lastControllerInputs.isEmpty)
    }

    @Test func nativeJoyConPublishesPhysicalInputWithoutMappedActions() {
        let bridge = ButtonBridge { _ in .mouseLeft }
        bridge.setOperationMode(.native)
        var changes: [(ControllerInput, Bool)] = []
        var mappedActions = 0
        bridge.onInputStateChange = { changes.append(($0, $1)) }
        bridge.mouseButtonHandler = { _, _ in mappedActions += 1 }
        var pressed = JoyConInputSnapshot.neutral
        pressed.buttons[.buttonA] = true
        bridge.applyJoyConSnapshot(pressed)
        bridge.applyJoyConSnapshot(.neutral)
        #expect(changes.count == 2)
        #expect(changes.first?.0 == .buttonA)
        #expect(changes.first?.1 == true)
        #expect(changes.last?.1 == false)
        #expect(mappedActions == 0)
    }

    @Test func joyConAnchorsRotateAndComposeWithTheArtwork() throws {
        for family in [ControllerFamily.joyConLeft, .joyConRight] {
            let vertical = ControllerInputHighlightModel.layout(for: family, orientation: .vertical)
            let horizontal = ControllerInputHighlightModel.layout(for: family, orientation: .horizontal)
            for input in [ControllerInput.buttonA, .buttonB, .buttonX, .buttonY, .leftThumbstickButton, .menu, .options] {
                let v = try #require(vertical[input])
                let h = try #require(horizontal[input])
                let clockwise = family == .joyConRight
                #expect(abs(h.center.x - (clockwise ? 1 - v.center.y : v.center.y)) < 0.0001)
                #expect(abs(h.center.y - (clockwise ? v.center.x : 1 - v.center.x)) < 0.0001)
            }
        }
        let pair = ControllerInputHighlightModel.layout(for: .joyConPair)
        #expect(try #require(pair[.dpadLeft]).center.x < 0.5)
        #expect(try #require(pair[.buttonB]).center.x > 0.5)
        // Nintendo B is the bottom face button; A is to its right.
        #expect(try #require(pair[.buttonA]).center.y > #require(pair[.buttonB]).center.y)
    }

    @Test func hardwareTestsAreFiniteAndFailWithoutAnEngine() {
        let engine = HapticEngine()
        for state in [PadState.busy, .waiting, .done, .error] {
            let events = HapticEngine.testEvents(for: state)
            #expect(!events.isEmpty)
            #expect(events.allSatisfy { $0.0 >= 0 && $0.3 > 0 && $0.0 + $0.3 < 1 })
            #expect(!engine.testFeedback(state))
        }
    }
}
