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
        #expect(available.contains(.menu))
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
        #expect(defaults[.buttonA] == .enter)
        #expect(defaults[.buttonB] == .backspace)
        #expect(defaults[.menu] == .toggleOperationMode)
        #expect(defaults[.options] == .rightCommand)
        #expect(defaults[.home] == .escape)
        #expect(defaults[.dpadUp] == .arrowUp)
        #expect(defaults[.dpadDown] == .arrowDown)
        #expect(defaults[.dpadLeft] == .arrowLeft)
        #expect(defaults[.dpadRight] == .arrowRight)
        #expect(defaults[.leftShoulder] == .previousSlot)
        #expect(defaults[.rightShoulder] == .nextSlot)
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

        let menuPress = parser.parse(usagePage: 0x0C, usage: 0x40, value: 1)
        #expect(menuPress == [XiaomiRemoteParsedEvent(input: .menu, isPressed: true)])

        let powerPress = parser.parse(usagePage: 0x0C, usage: 0x30, value: 1)
        #expect(powerPress == [XiaomiRemoteParsedEvent(input: .home, isPressed: true)])

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
    func capturedRC003KeyboardSequenceIncludesPressesAndReleases() {
        // Physical RC003-MS traces, including the second round of button capture.
        // The remote reports Back on the nonstandard Keyboard usage 0xF1.
        let observed: [(UInt32, ControllerInput)] = [
            (0x52, .dpadUp), (0x4F, .dpadRight), (0x51, .dpadDown),
            (0x50, .dpadLeft), (0x28, .buttonA), (0xF1, .buttonB), (0x65, .menu),
            (0x81, .leftShoulder), (0x80, .rightShoulder), (0x35, .buttonY), (0x4A, .home),
            (0x3E, .options),
        ]
        let parser = XiaomiRemoteHIDParser()
        for (usage, input) in observed {
            #expect(parser.parse(usagePage: 0x07, usage: UInt32.max, value: Int(usage)).isEmpty)
            #expect(parser.parse(usagePage: 0x07, usage: 0x01, value: 0).isEmpty)
            #expect(parser.parse(usagePage: 0x07, usage: usage, value: 1) == [
                XiaomiRemoteParsedEvent(input: input, isPressed: true),
            ])
            #expect(parser.parse(usagePage: 0x07, usage: usage, value: 0) == [
                XiaomiRemoteParsedEvent(input: input, isPressed: false),
            ])
        }
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

        var tappedKeys: [(SystemKey, Bool)] = []
        bridge.systemKeyHandler = { key, pressed in
            tappedKeys.append((key, pressed))
        }

        bridge.setRemoteControllerActive(true)

        // Replay the physical RC003-MS Voice usage through parser and bridge.
        let parser = XiaomiRemoteHIDParser()
        for event in parser.parse(usagePage: 0x07, usage: 0x3E, value: 1) {
            bridge.handleRemoteButton(event.input, isPressed: event.isPressed)
        }
        #expect(publishedStates[.options] == true)
        #expect(tappedKeys.contains(where: { $0.0 == .rightCommand && $0.1 }))

        for event in parser.parse(usagePage: 0x07, usage: 0x3E, value: 0) {
            bridge.handleRemoteButton(event.input, isPressed: event.isPressed)
        }
        #expect(publishedStates[.options] == false)
        #expect(tappedKeys.map { $0.0 } == [.rightCommand, .rightCommand])
        #expect(tappedKeys.map { $0.1 } == [true, false])

        // The default confirmation key works in ordinary text fields.
        bridge.handleRemoteButton(.buttonA, isPressed: true)
        #expect(publishedStates[.buttonA] == true)
        #expect(tappedKeys.contains(where: { $0.0 == .enter && $0.1 }))

        bridge.handleRemoteButton(.buttonA, isPressed: false)
        #expect(publishedStates[.buttonA] == false)

        bridge.handleRemoteButton(.menu, isPressed: true)
        bridge.handleRemoteButton(.menu, isPressed: false)
        #expect(bridge.operationMode == .native)
        bridge.handleRemoteButton(.menu, isPressed: true)
        bridge.handleRemoteButton(.menu, isPressed: false)
        #expect(bridge.operationMode == .mapping)
    }

    @Test
    func reconnectReleasesRemoteHomeState() throws {
        let suiteName = "XiaomiRemoteTests.HomeReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("xiaomi-remote", forKey: "controllerMappings.v1.controllerFamily")
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.toggleOperationMode, for: .home)
        let bridge = ButtonBridge(mappingProvider: { store.action(for: $0) })
        var modeChanges = 0
        bridge.onOperationModeChange = { _ in modeChanges += 1 }

        bridge.setRemoteControllerActive(true)
        bridge.handleRemoteButton(.home, isPressed: true)
        bridge.resetInputState()
        bridge.handleRemoteButton(.home, isPressed: true)

        #expect(modeChanges == 2)
    }

    @Test
    @MainActor
    func connectedRemoteSurvivesGameControllerDiscoveryStartup() {
        let bridge = ButtonBridge()
        var family: ControllerFamily = .generic
        bridge.onControllerChange = { _, nextFamily in family = nextFamily }
        defer { bridge.stop() }

        bridge.setRemoteControllerActive(true)
        bridge.start()
        #expect(family == .xiaomiRemote)

        bridge.setRemoteControllerActive(false)
        #expect(family != .xiaomiRemote)
    }

    @Test
    @MainActor
    func controllerHubKeepsRemoteSessionIndependentFromGameControllerSessions() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        var devices: [ConnectedControllerDescriptor] = []
        hub.onConnectedDevicesChange = { devices = $0 }

        hub.setRemoteControllerActive(true)
        #expect(devices.count == 1)
        #expect(devices.first?.family == .xiaomiRemote)
        #expect(devices.first?.source == .xiaomiRemote)

        hub.setRemoteControllerActive(true)
        #expect(devices.count == 1)

        hub.setRemoteControllerActive(false)
        #expect(devices.isEmpty)
    }
}
