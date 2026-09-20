import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct ControllerMappingMigrationTests {
    @Test
    func connectedDeviceSelectionSwitchesProfilesWithoutLosingCustomMappings() throws {
        let suiteName = "ControllerMappingMigrationTests.devices.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        let xbox = ConnectedControllerDescriptor(
            id: "xbox-1",
            name: "Xbox Wireless Controller",
            family: .xbox,
            source: .gameController
        )
        let remote = ConnectedControllerDescriptor(
            id: "remote-1",
            name: "小米蓝牙遥控器",
            family: .xiaomiRemote,
            source: .xiaomiRemote
        )
        var selectedIDs: [String] = []
        store.onConnectedDeviceSelectionChange = { selectedIDs.append($0) }
        store.setConnectedDevices([xbox, remote])

        #expect(store.selectedConnectedDeviceID == xbox.id)
        store.setAction(.copy, for: .buttonA)
        store.selectConnectedDevice(remote.id)
        #expect(store.controllerFamily == .xiaomiRemote)
        #expect(store.action(for: .buttonA) == .enter)

        store.setAction(.screenshotTool, for: .buttonY)
        store.selectConnectedDevice(xbox.id)
        #expect(store.controllerFamily == .xbox)
        #expect(store.action(for: .buttonA) == .copy)
        #expect(store.action(for: .buttonY) == .escape)

        store.selectConnectedDevice(remote.id)
        #expect(store.action(for: .buttonY) == .screenshotTool)
        #expect(selectedIDs == [remote.id, xbox.id, remote.id])
    }

    @Test
    func familyMappingLookupRemainsAvailableWhenAnotherProfileIsDisplayed() throws {
        let suiteName = "ControllerMappingMigrationTests.familyLookup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.copy, for: .buttonA)
        store.setControllerFamily(.xiaomiRemote)

        #expect(store.action(for: .buttonA) == .enter)
        #expect(store.action(for: .buttonA, family: .xbox) == .copy)
    }

    @Test
    func changingAProfileDoesNotReplaceTheSelectedSameFamilyDevice() throws {
        let suiteName = "ControllerMappingMigrationTests.sameFamily.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        let first = ConnectedControllerDescriptor(
            id: "xbox-a",
            name: "Xbox Wireless Controller",
            family: .xbox,
            source: .gameController
        )
        let second = ConnectedControllerDescriptor(
            id: "xbox-b",
            name: "Xbox Wireless Controller",
            family: .xbox,
            source: .gameController
        )
        store.setConnectedDevices([first, second])
        store.selectConnectedDevice(second.id)

        store.setControllerFamily(.xbox)

        #expect(store.selectedConnectedDeviceID == second.id)
    }

    @Test func remoteMappingsSurviveReconnectAndRemainSeparateFromGamepads() throws {
        let suite = "ControllerMappingMigrationTests.Remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcut = RecordedKeyboardShortcut(keyCode: 0x2D, keyName: "N", modifiers: [.shift, .command])
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.paste, for: .buttonA)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .buttonA) == .enter)
        store.setAction(.mouseLeft, for: .buttonA)
        store.setAction(.disabled, for: .options)
        store.setOpenApplicationTarget("com.example.remote", for: .buttonY)
        store.setAction(.recordedShortcut, for: .buttonB)
        store.setRecordedShortcut(shortcut, for: .buttonB)
        store.setRecordedShortcutNote("remote shortcut", for: .buttonB)

        store.setControllerFamily(.generic)
        #expect(store.action(for: .buttonA) == .paste)
        #expect(store.openApplicationTarget(for: .buttonY) == nil)
        #expect(store.recordedShortcutConfiguration(for: .buttonB).shortcut == nil)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .buttonA) == .mouseLeft)
        #expect(store.action(for: .options) == .disabled)
        #expect(store.openApplicationTarget(for: .buttonY) == "com.example.remote")
        #expect(store.action(for: .buttonB) == .recordedShortcut)
        #expect(store.recordedShortcutConfiguration(for: .buttonB).shortcut == shortcut)
        #expect(store.recordedShortcutConfiguration(for: .buttonB).note == "remote shortcut")

        let reloaded = ControllerMappingStore(userDefaults: defaults)
        #expect(reloaded.action(for: .buttonA) == .mouseLeft)
        #expect(reloaded.recordedShortcutConfiguration(for: .buttonB).shortcut == shortcut)
        reloaded.setControllerFamily(.xbox)
        #expect(reloaded.action(for: .buttonA) == .paste)
    }

    @Test func legacyRemoteProfileMigratesWithoutApplyingGamepadMigrations() throws {
        let suite = "ControllerMappingMigrationTests.LegacyRemote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "controllerMappings.v1"
        let configuration = RecordedShortcutConfiguration(
            shortcut: RecordedKeyboardShortcut(keyCode: 0x2D, keyName: "N", modifiers: [.shift, .command]),
            note: "legacy remote shortcut"
        )
        defaults.set("xiaomi-remote", forKey: "\(key).controllerFamily")
        defaults.set(["buttonA": "mouseLeft", "options": "disabled", "buttonB": "recordedShortcut"], forKey: key)
        defaults.set(["buttonY": "com.example.remote"], forKey: "\(key).openApplications")
        defaults.set(try JSONEncoder().encode([ControllerInput.buttonB: configuration]), forKey: "\(key).recordedShortcuts")
        let store = ControllerMappingStore(userDefaults: defaults)
        #expect(store.action(for: .buttonA) == .mouseLeft)
        #expect(store.action(for: .options) == .disabled)
        #expect(store.openApplicationTarget(for: .buttonY) == "com.example.remote")
        #expect(store.recordedShortcutConfiguration(for: .buttonB) == configuration)
        store.setControllerFamily(.generic)
        #expect(store.action(for: .options) == .screenshotTool)
        #expect(store.openApplicationTarget(for: .buttonY) == nil)
        #expect(store.recordedShortcutConfiguration(for: .buttonB).shortcut == nil)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .options) == .disabled)
        #expect(store.openApplicationTarget(for: .buttonY) == "com.example.remote")
        #expect(store.recordedShortcutConfiguration(for: .buttonB) == configuration)
    }

    @Test func legacyDisconnectedRemoteKeepsCustomizationsAfterUpgrade() throws {
        let suite = "ControllerMappingMigrationTests.DisconnectedRemote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "controllerMappings.v1"
        let configuration = RecordedShortcutConfiguration(
            shortcut: RecordedKeyboardShortcut(keyCode: 0x2D, keyName: "N", modifiers: [.shift, .command]),
            note: "legacy shortcut"
        )
        // The old version changed the family to generic when the remote disconnected.
        defaults.set("generic", forKey: "\(key).controllerFamily")
        defaults.set(8, forKey: "\(key).schemaVersion")
        defaults.set(["buttonA": "copy", "buttonB": "recordedShortcut", "options": "screenshotTool"], forKey: key)
        defaults.set(["buttonY": "com.example.remote"], forKey: "\(key).openApplications")
        defaults.set(try JSONEncoder().encode([ControllerInput.buttonB: configuration]), forKey: "\(key).recordedShortcuts")
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .buttonA) == .copy)
        #expect(store.action(for: .buttonB) == .recordedShortcut)
        #expect(store.action(for: .options) == .rightCommand)
        #expect(store.openApplicationTarget(for: .buttonY) == "com.example.remote")
        #expect(store.recordedShortcutConfiguration(for: .buttonB) == configuration)
        store.setAction(.mouseLeft, for: .buttonA)
        store.setControllerFamily(.generic)
        #expect(store.action(for: .buttonA) == .copy)
        #expect(store.action(for: .options) == .screenshotTool)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .buttonA) == .mouseLeft)
    }

    @Test
    func legacyCompletedMigrationFlagsAreHonoredWhileAdvancingSchemaVersion() throws {
        let suiteName = "ControllerMappingMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "controllerMappings.v1"
        defaults.set([
            ControllerInput.buttonA.rawValue: ControllerMappedAction.enter.rawValue,
            ControllerInput.dpadUp.rawValue: ControllerMappedAction.radialInput.rawValue,
            ControllerInput.touchpadButton.rawValue: ControllerMappedAction.pushToTalk.rawValue,
            ControllerInput.home.rawValue: ControllerMappedAction.disabled.rawValue,
        ], forKey: storageKey)
        defaults.set(true, forKey: "\(storageKey).dpadUpRightCommandMigrated")
        defaults.set(true, forKey: "\(storageKey).homeButtonToggleOperationModeMigrated")

        let store = ControllerMappingStore(userDefaults: defaults, storageKey: storageKey)

        #expect(store.action(for: .buttonA) == .enter)
        #expect(store.action(for: .dpadUp) == .radialInput)
        #expect(store.action(for: .touchpadButton) == .mouseLeft)
        #expect(store.action(for: .home) == .disabled)
        #expect(defaults.integer(forKey: "\(storageKey).schemaVersion") == 8)
        #expect(defaults.object(forKey: "\(storageKey).homeButtonToggleOperationModeMigrated") == nil)
    }

    @Test
    func currentSchemaDoesNotRewriteCustomizedMappings() throws {
        let suiteName = "ControllerMappingMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "controllerMappings.v1"
        defaults.set([
            ControllerInput.buttonA.rawValue: ControllerMappedAction.enter.rawValue,
            ControllerInput.touchpadButton.rawValue: ControllerMappedAction.pushToTalk.rawValue,
            ControllerInput.home.rawValue: ControllerMappedAction.disabled.rawValue,
        ], forKey: storageKey)
        defaults.set(8, forKey: "\(storageKey).schemaVersion")

        let store = ControllerMappingStore(userDefaults: defaults, storageKey: storageKey)

        #expect(store.action(for: .buttonA) == .enter)
        #expect(store.action(for: .touchpadButton) == .pushToTalk)
        #expect(store.action(for: .home) == .disabled)
        #expect(defaults.integer(forKey: "\(storageKey).schemaVersion") == 8)
    }
}
