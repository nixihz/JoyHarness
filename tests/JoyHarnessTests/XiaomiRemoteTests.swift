import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct XiaomiRemoteTests {
    @Test
    func xiaomiRemoteFamilyContractAndDefaults() {
        let family = ControllerFamily.xiaomiRemote
        #expect(family.rawValue == "xiaomi-remote")
        #expect(family.displayName.contains("小米") || family.displayName.contains("Xiaomi"))
        #expect(family.isXiaomiRemote)
        #expect(!family.isJoyCon)

        let artwork = family.dashboardArtworkDescriptors()
        #expect(artwork.count == 1)
        #expect(artwork[0].resource == "controller-dashboard-xiaomi-remote")

        let available = ControllerInput.availableInputs(for: .xiaomiRemote)
        #expect(available.contains(.buttonA))
        #expect(available.contains(.buttonB))
        #expect(available.contains(.options))
        #expect(available.contains(.home))
        #expect(available.contains(.dpadUp))
        #expect(available.contains(.dpadDown))
        #expect(available.contains(.dpadLeft))
        #expect(available.contains(.dpadRight))
        #expect(available.contains(.leftShoulder))
        #expect(available.contains(.rightShoulder))
        #expect(available.contains(.buttonY))
        #expect(!available.contains(.leftThumbstickButton))
        #expect(!available.contains(.leftTrigger))
        #expect(!available.contains(.touchpadButton))

        let defaults = ControllerMappingStore.defaultMappings(for: .xiaomiRemote)
        #expect(defaults[.buttonA] == .approve)
        #expect(defaults[.buttonB] == .deny)
        #expect(defaults[.options] == .pushToTalk)
        #expect(defaults[.home] == .toggleOperationMode)
        #expect(defaults[.dpadUp] == .previousSlot)
        #expect(defaults[.dpadDown] == .nextSlot)
        #expect(defaults[.dpadLeft] == .slot1)
        #expect(defaults[.dpadRight] == .slot2)
        #expect(defaults[.buttonY] == .screenshotTool)
    }

    @Test
    func xiaomiRemoteHIDParserReportsConsumerAndDesktopUsages() {
        let parser = XiaomiRemoteHIDParser()

        // OK / Select (Consumer 0x41)
        let okPress = parser.parse(usagePage: 0x0C, usage: 0x41, value: 1)
        #expect(okPress == [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: true)])
        let okRelease = parser.parse(usagePage: 0x0C, usage: 0x41, value: 0)
        #expect(okRelease == [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: false)])

        // Back (Consumer 0x224)
        let backPress = parser.parse(usagePage: 0x0C, usage: 0x224, value: 1)
        #expect(backPress == [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: true)])

        // Voice Command (Consumer 0xCF)
        let voicePress = parser.parse(usagePage: 0x0C, usage: 0xCF, value: 1)
        #expect(voicePress == [XiaomiRemoteParsedEvent(input: .options, isPressed: true)])

        // Home (Consumer 0x223)
        let homePress = parser.parse(usagePage: 0x0C, usage: 0x223, value: 1)
        #expect(homePress == [XiaomiRemoteParsedEvent(input: .home, isPressed: true)])

        // Direction Up (Generic Desktop 0x90)
        let upPress = parser.parse(usagePage: 0x01, usage: 0x90, value: 1)
        #expect(upPress == [XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: true)])

        // Hat switch sequence
        let hatUp = parser.parse(usagePage: 0x01, usage: 0x39, value: 0) // Up
        #expect(hatUp.contains(XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: true)))

        let hatNeutral = parser.parse(usagePage: 0x01, usage: 0x39, value: 8) // Neutral
        #expect(hatNeutral.contains(XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: false)))
    }

    @Test
    func buttonBridgeRoutesXiaomiRemoteInputs() throws {
        let suiteName = "XiaomiRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("xiaomi-remote", forKey: "controllerMappings.v1.controllerFamily")
        let store = ControllerMappingStore(userDefaults: defaults)
        let bridge = ButtonBridge(mappingProvider: { store.action(for: $0) })

        var publishedStates: [ControllerInput: Bool] = [:]
        bridge.onInputStateChange = { input, pressed in
            publishedStates[input] = pressed
        }

        var tappedKeys: [(String, Int)] = []
        bridge.keyHandler = { key, action in
            tappedKeys.append((key, action))
            return true
        }

        bridge.setRemoteControllerActive(true)

        // Test Voice -> Push to Talk (ACT10)
        bridge.handleRemoteButton(.options, isPressed: true)
        #expect(publishedStates[.options] == true)
        #expect(tappedKeys.contains(where: { $0.0 == "ACT10" && $0.1 == 1 }))

        bridge.handleRemoteButton(.options, isPressed: false)
        #expect(publishedStates[.options] == false)
        #expect(tappedKeys.contains(where: { $0.0 == "ACT10" && $0.1 == 0 }))

        // Test OK -> Approve (ACT07)
        bridge.handleRemoteButton(.buttonA, isPressed: true)
        #expect(publishedStates[.buttonA] == true)
        #expect(tappedKeys.contains(where: { $0.0 == "ACT07" && $0.1 == 1 }))

        bridge.handleRemoteButton(.buttonA, isPressed: false)
        #expect(publishedStates[.buttonA] == false)
    }
}
