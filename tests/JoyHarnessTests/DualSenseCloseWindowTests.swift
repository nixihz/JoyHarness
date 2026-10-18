import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct DualSenseCloseWindowTests {
    @Test(arguments: HarnessProviderID.builtIns + [HarnessProviderID(rawValue: "custom.close-window")])
    func oldProfileClosesWindowsWithoutSelectingDualSenseInSettings(provider: HarnessProviderID) throws {
        let suiteName = "DualSenseCloseWindowTests.runtime.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "controllerMappings.v1"
        let profileKey = provider == .codex ? storageKey : "\(storageKey).providers.\(provider.rawValue)"
        let oldAction: ControllerMappedAction = provider == .codex ? .approve : .disabled
        let stored = [
            ControllerInput.functionButtonA.rawValue: oldAction.rawValue,
            ControllerInput.buttonA.rawValue: ControllerMappedAction.copy.rawValue,
        ]
        defaults.set(stored, forKey: profileKey)
        defaults.set(true, forKey: "\(profileKey).dualSenseNavigationDefaultsMigrated")
        defaults.set(ControllerFamily.joyConLeft.rawValue, forKey: "\(storageKey).controllerFamily")
        let store = ControllerMappingStore(userDefaults: defaults, storageKey: storageKey, harnessProvider: provider)

        // Input routing and the Dashboard must agree even when Settings edits
        // another device. Reading DualSense must not rewrite Xbox's shared key.
        #expect(store.action(for: .functionButtonA, family: .dualSense).controllerAction == .systemKey(.closeWindow))
        #expect(store.profile(for: .dualSense).mappings[.functionButtonA] == .closeWindow)
        #expect(store.action(for: .buttonA, family: .dualSense) == .copy)
        #expect(store.controllerFamily == .joyConLeft)
        #expect(store.action(for: .functionButtonA, family: .xbox) == oldAction)
        #expect((defaults.dictionary(forKey: profileKey) as? [String: String])?["functionButtonA"] == oldAction.rawValue)
        #expect(!defaults.bool(forKey: "\(profileKey).dualSenseCloseWindowDefaultMigrated"))

        // Selecting the profile persists its migration. An explicit override
        // back to the old action survives both device switches and a restart.
        store.setControllerFamily(.dualSense)
        #expect(store.action(for: .functionButtonA) == .closeWindow)
        #expect(defaults.bool(forKey: "\(profileKey).dualSenseCloseWindowDefaultMigrated"))
        store.setAction(oldAction, for: .functionButtonA)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .functionButtonA, family: .dualSense) == oldAction)
        let reloaded = ControllerMappingStore(userDefaults: defaults, storageKey: storageKey, harnessProvider: provider)
        #expect(reloaded.action(for: .functionButtonA, family: .dualSense) == oldAction)
    }

    @Test
    func harnessSwitchRefreshesTheCloseShortcutAndPreservesCustomActions() throws {
        let suiteName = "DualSenseCloseWindowTests.switching.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "controllerMappings.v1"
        defaults.set(ControllerFamily.joyConLeft.rawValue, forKey: "\(storageKey).controllerFamily")
        defaults.set(["functionButtonA": "approve"], forKey: storageKey)
        defaults.set(["functionButtonA": "paste"], forKey: "\(storageKey).providers.claude")
        defaults.set(["functionButtonA": "disabled"], forKey: "\(storageKey).providers.cursor")
        let store = ControllerMappingStore(userDefaults: defaults, storageKey: storageKey)

        #expect(store.action(for: .functionButtonA, family: .dualSense) == .closeWindow)
        store.setHarnessProvider(.claude)
        #expect(store.action(for: .functionButtonA, family: .dualSense) == .paste)
        store.setHarnessProvider(.cursor)
        #expect(store.action(for: .functionButtonA, family: .dualSense) == .closeWindow)
        store.setHarnessProvider(.codex)
        #expect(store.action(for: .functionButtonA, family: .dualSense) == .closeWindow)
        #expect(store.controllerFamily == .joyConLeft)
    }
}
