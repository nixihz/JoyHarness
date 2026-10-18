import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct JoyConRailButtonTests {
    @Test(arguments: JoyConSide.allCases)
    func hidStickClickWorksWithoutAnAppleButtonAndKeepsThePeerStick(side: JoyConSide) throws {
        let own: ControllerInput = side == .left ? .leftThumbstickButton : .rightThumbstickButton
        let peer: ControllerInput = side == .left ? .rightThumbstickButton : .leftThumbstickButton
        let ownMask: UInt8 = side == .left ? 0x08 : 0x04
        let peerMask: UInt8 = side == .left ? 0x04 : 0x08
        let apple = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [peer: true], primaryStick: .neutral, secondaryStick: .neutral
            ), availableInputs: [peer]
        )
        for shared: UInt8 in [ownMask, peerMask, 0] {
            let hid = try #require(JoyConHIDInputReportParser.shoulders(
                from: [0x30, 0, 0, 0, shared, 0], side: side
            ))
            let single = JoyConSingleShoulderAdapter.apply(
                hid, to: apple, side: side, orientation: .vertical
            )
            #expect(single.availableInputs.contains(.leftThumbstickButton))
            #expect(single.snapshot.buttons[.leftThumbstickButton] == (shared == ownMask))
            let pair = JoyConPairedShoulderAdapter.apply(hid, to: apple, side: side)
            #expect(pair.availableInputs.contains(own))
            #expect(pair.snapshot.buttons[own] == (shared == ownMask))
            #expect(pair.snapshot.buttons[peer] == true)
        }
    }

    @Test
    func leftVerticalDefaultsRoutePhysicalButtonsAndReleaseTheirOriginalActions() throws {
        let defaults = ControllerMappingStore.defaultMappings(for: .joyConLeft, provider: .codex)
        let bridge = ButtonBridge(controllerFamily: .joyConLeft) { defaults[$0] ?? .disabled }
        var events: [String] = []
        bridge.systemKeyHandler = { events.append("key:\($0):\($1)") }
        bridge.mouseButtonHandler = { events.append("mouse:\($0):\($1)") }
        bridge.mouseSpeedBoostHandler = { events.append("boost:\($0)") }
        bridge.onSlotSelected = { events.append("slot:\($0 + 1)") }
        bridge.keyHandler = { _, _ in true }

        // Real HID masks, rather than feeding logical inputs directly: also
        // verifies direction labels, rail buttons and the ZL modifier path.
        let cases: [(UInt8, Bool, [String])] = [
            (0x02, false, ["key:escape:true", "key:escape:false"]),
            (0x04, false, ["mouse:right:true", "mouse:right:false"]),
            (0x01, false, ["key:enter:true", "key:enter:false"]),
            (0x08, false, ["key:backspace:true", "key:backspace:false"]),
            (0x40, false, ["mouse:left:true", "mouse:left:false"]),
            (0x00, true, ["boost:true", "boost:false"]),
            (0x82, false, ["slot:1"]),
            (0x84, false, ["slot:2"]),
            (0x81, false, ["slot:3"]),
            (0x88, false, ["slot:4"]),
            (0xc0, false, ["mouse:middle:true", "mouse:middle:false"]),
            (0x80, true, ["key:enter:true", "key:enter:false"]),
            (0x20, false, ["slot:2"]),
            (0x10, false, ["slot:4"]),
        ]
        for (mask, stickPressed, expected) in cases {
            events = []
            bridge.syncSelectedSlot(2)
            bridge.applyJoyConSnapshot(try sample(mask, stickPressed: stickPressed).snapshot)
            // Repeated report must not duplicate a press.
            bridge.applyJoyConSnapshot(try sample(mask, stickPressed: stickPressed).snapshot)
            if mask & 0x80 != 0 {
                // Releasing ZL first must not run a base-layer action.
                bridge.applyJoyConSnapshot(try sample(mask & 0x7f, stickPressed: stickPressed).snapshot)
            }
            bridge.applyJoyConSnapshot(try sample(0).snapshot)
            #expect(events == expected, "HID mask \(mask), stick \(stickPressed)")
        }
    }

    @Test
    func verticalZLModifierExposesCombinationsAndRoutesHIDPresses() throws {
        let suite = "JoyConZLModifierTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = ControllerMappingStore(userDefaults: preferences)
        let device = ConnectedControllerDescriptor(
            id: "joycon-left", name: "Joy-Con (L)", family: .joyConLeft, source: .gameController,
            availableInputs: [.buttonA, .leftShoulder, .rightShoulder, .joyConSL, .joyConSR]
        )
        store.setConnectedDevices([device])
        store.selectConnectedDevice(device.id)
        store.setDisplayedDevice(device.id)
        store.setJoyConOrientation(.vertical)
        store.setAction(.nextSlot, for: .rightShoulder)
        store.setAction(.approve, for: .functionButtonA)
        #expect(!store.availableInputs.contains(.functionButtonA))
        store.setAction(.functionModifier, for: .rightShoulder)
        #expect(store.availableInputs.contains(.functionButtonA))
        #expect(store.displayedInputs(for: .joyConLeft).contains(.functionButtonA))
        #expect(!store.availableInputs.contains(.functionRightShoulder))

        let reloaded = ControllerMappingStore(userDefaults: preferences)
        reloaded.setControllerFamily(.joyConLeft)
        let bridge = ButtonBridge(controllerFamily: .joyConLeft) { reloaded.action(for: $0) }
        var keyPresses: [Int] = []
        var clicks = 0
        var scrolling = false
        bridge.keyHandler = { key, pressed in
            #expect(key == "ACT07")
            keyPresses.append(pressed)
            return true
        }
        bridge.mouseButtonHandler = { _, _ in clicks += 1 }
        bridge.leftStickHandler = { _, _, value in scrolling = value }
        bridge.applyJoyConSnapshot(try sample(0x80).snapshot) // ZL
        #expect(scrolling)
        bridge.applyJoyConSnapshot(try sample(0x88).snapshot) // ZL + left face button
        #expect(keyPresses == [1])
        bridge.applyJoyConSnapshot(try sample(0x08).snapshot) // release ZL first
        #expect(!scrolling)
        bridge.applyJoyConSnapshot(try sample(0).snapshot)
        #expect(keyPresses == [1, 0])
        #expect(clicks == 0)

        store.setHarnessProvider(.claude)
        #expect(store.availableInputs.contains(.functionButtonA))
        store.setHarnessProvider(.codex)
        #expect(store.availableInputs.contains(.functionButtonA))
        store.setControllerFamily(.xiaomiRemote)
        store.setControllerFamily(.joyConLeft)
        #expect(store.availableInputs.contains(.functionButtonA))
        store.setAction(.nextSlot, for: .rightShoulder)
        #expect(!store.availableInputs.contains(.functionButtonA))
    }

    private func sample(_ buttons: UInt8, side: JoyConSide = .left, stickPressed: Bool = false) throws -> JoyConProfileSample {
        var report: [UInt8] = [0x30, 0, 0, 0, 0, 0]
        report[side == .left ? 5 : 3] = buttons
        report[4] = stickPressed ? (side == .left ? 0x08 : 0x04) : 0
        let hid = try #require(JoyConHIDInputReportParser.shoulders(from: report, side: side))
        return JoyConSingleShoulderAdapter.apply(
            hid,
            to: JoyConProfileSample(
                snapshot: JoyConInputSnapshot(
                    buttons: [:],
                    primaryStick: .neutral,
                    secondaryStick: .neutral
                ),
                availableInputs: []
            ),
            side: side,
            orientation: .vertical
        )
    }

    @Test(arguments: JoyConSide.allCases)
    func verticalRailReportsDriveIndependentSpeedModes(side: JoyConSide) throws {
        let family: ControllerFamily = side == .left ? .joyConLeft : .joyConRight
        var defaults = ControllerMappingStore.defaultMappings(for: family, provider: .codex)
        defaults[.joyConSL] = .mouseSpeedBoost
        defaults[.joyConSR] = .mousePrecision
        let bridge = ButtonBridge { defaults[$0] ?? .disabled }
        var boost: [Bool] = []
        var precision: [Bool] = []
        bridge.mouseSpeedBoostHandler = { boost.append($0) }
        bridge.mousePrecisionHandler = { precision.append($0) }

        bridge.applyJoyConSnapshot(try sample(0x20, side: side).snapshot)
        #expect(boost == [true])
        #expect(precision.isEmpty)
        bridge.applyJoyConSnapshot(try sample(0x30, side: side).snapshot)
        #expect(boost == [true])
        #expect(precision == [true])
        bridge.applyJoyConSnapshot(try sample(0x10, side: side).snapshot)
        #expect(boost == [true, false])
        #expect(precision == [true])
        bridge.applyJoyConSnapshot(try sample(0, side: side).snapshot)
        #expect(precision == [true, false])
    }

    @Test
    func releasingSLDoesNotCancelAHeldStickClickAndResetReleasesPrecision() throws {
        var defaults = ControllerMappingStore.defaultMappings(for: .joyConLeft, provider: .codex)
        defaults[.joyConSL] = .mouseSpeedBoost
        defaults[.joyConSR] = .mousePrecision
        let bridge = ButtonBridge { defaults[$0] ?? .disabled }
        var boost: [Bool] = []
        var precision: [Bool] = []
        bridge.mouseSpeedBoostHandler = { boost.append($0) }
        bridge.mousePrecisionHandler = { precision.append($0) }

        bridge.applyJoyConSnapshot(try sample(0x20).snapshot)
        bridge.applyJoyConSnapshot(try sample(0x20, stickPressed: true).snapshot)
        bridge.applyJoyConSnapshot(try sample(0, stickPressed: true).snapshot)
        #expect(boost == [true])
        bridge.applyJoyConSnapshot(try sample(0).snapshot)
        #expect(boost == [true, false])
        bridge.applyJoyConSnapshot(try sample(0x10).snapshot)
        bridge.resetInputState()
        #expect(precision == [true, false])
    }

    @Test
    func railRemappingPersistsWithoutChangingStickClick() throws {
        let suite = "JoyConRailButtonTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setControllerFamily(.joyConLeft)
        store.setAction(.mouseMiddle, for: .joyConSL)
        let reloaded = ControllerMappingStore(userDefaults: defaults)
        reloaded.setControllerFamily(.joyConLeft)
        let bridge = ButtonBridge { reloaded.action(for: $0) }
        var clicks: [Bool] = []
        bridge.mouseButtonHandler = { button, down in
            #expect(button == .middle)
            clicks.append(down)
        }
        bridge.applyJoyConSnapshot(try sample(0x20).snapshot)
        bridge.applyJoyConSnapshot(try sample(0).snapshot)
        #expect(clicks == [true, false])
        #expect(reloaded.action(for: .leftThumbstickButton) == .mouseSpeedBoost)
    }
}
