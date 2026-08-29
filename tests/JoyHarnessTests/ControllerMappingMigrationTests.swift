import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct ControllerMappingMigrationTests {
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
