import Foundation
import Testing
@testable import JoyHarness

struct DashboardPresentationTests {
    @Test func newlyPressedInputTakesPriorityOverAHeldButton() {
        #expect(DashboardPresentation.inputToReveal(
            pressed: [.buttonA, .dpadDown], previous: [.buttonA],
            displayed: ControllerInput.availableInputs(for: .dualSense)
        ) == .dpadDown)
        #expect(DashboardPresentation.inputToReveal(
            pressed: [.buttonA], previous: [.buttonA, .dpadDown],
            displayed: ControllerInput.availableInputs(for: .dualSense)
        ) == nil)
    }

    @Test func functionChordRevealsItsOwnRowInsteadOfTheModifier() {
        #expect(DashboardPresentation.inputToReveal(
            pressed: [.leftTrigger, .functionDpadDown], previous: [],
            displayed: ControllerInput.availableInputs(for: .dualSense)
        ) == .functionDpadDown)
        #expect(DashboardPresentation.inputToReveal(
            pressed: [.touchpadButton, .dpadDown], previous: [],
            displayed: ControllerInput.availableInputs(for: .xbox)
        ) == .dpadDown)
    }

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

    @Test func outdatedStatusShowsOnlyTheRefreshNotice() throws {
        let missing = try status(["accessibility": false, "input_monitoring": false, "rp2040": false])
        for freshness in [StatusFreshness.stale, .unavailable] {
            #expect(DashboardPresentation(status: missing, freshness: freshness).notices == [.stale])
        }
    }

    @Test func nativeModeReplacesMappingPrerequisiteNotices() throws {
        let p = DashboardPresentation(
            status: try status(["operation_mode": "native", "accessibility": false, "rp2040": false]),
            freshness: .fresh
        )
        #expect(p.notices == [.nativeMode])
    }

    @Test func noticesListEachMissingPrerequisiteButNotUnknownOnes() throws {
        let unknownMonitoring = DashboardPresentation(
            status: try status(["accessibility": false, "input_monitoring": NSNull(), "rp2040": false]),
            freshness: .fresh
        )
        #expect(unknownMonitoring.notices == [.accessibility, .adapter])

        let deniedMonitoring = DashboardPresentation(
            status: try status(["accessibility": true, "input_monitoring": false, "rp2040": true]),
            freshness: .fresh
        )
        #expect(deniedMonitoring.notices == [.inputMonitoring])

        let ready = DashboardPresentation(
            status: try status(["accessibility": true, "input_monitoring": true, "rp2040": true]),
            freshness: .fresh
        )
        #expect(ready.notices.isEmpty)
    }

    @Test func batterySymbolNeverOverstatesTheLevel() throws {
        let p = DashboardPresentation(status: try status(), freshness: .fresh)
        #expect(p.batterySymbol(0) == "battery.0")
        #expect(p.batterySymbol(0.3) == "battery.25")
        #expect(p.batterySymbol(0.62) == "battery.50")
        #expect(p.batterySymbol(0.99) == "battery.75")
        #expect(p.batterySymbol(1) == "battery.100")
        #expect(p.batterySymbol(nil) == nil)
        #expect(p.batterySymbol(.nan) == nil)
        #expect(DashboardPresentation(status: try status(), freshness: .stale).batterySymbol(0.8) == nil)
    }

    @Test func headerNamesTheDisplayedDeviceInsteadOfTheCombinedStatus() {
        let devices = [
            ConnectedControllerDescriptor(id: "a", name: "Xbox Wireless Controller", family: .xbox, source: .gameController),
            ConnectedControllerDescriptor(id: "b", name: "Xbox Wireless Controller", family: .xbox, source: .gameController),
            ConnectedControllerDescriptor(id: "c", name: "", family: .xiaomiRemote, source: .xiaomiRemote),
        ]
        let combined = "Xbox Wireless Controller + Xiaomi Remote"
        #expect(DashboardPresentation.headerTitle(devices: devices, displayedID: "b", fallback: combined)
            == "Xbox Wireless Controller 2")
        #expect(DashboardPresentation.headerTitle(devices: devices, displayedID: "c", fallback: combined)
            == ControllerFamily.xiaomiRemote.displayName)
        #expect(DashboardPresentation.headerTitle(devices: devices, displayedID: "gone", fallback: combined) == combined)
    }
}
