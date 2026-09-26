import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct ControllerMappingProviderTests {
    @Test
    func codexReadsAndWritesLegacyStorageKeys() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let shortcut = RecordedKeyboardShortcut(
            keyCode: 0x2D,
            keyName: "N",
            modifiers: [.command]
        )
        let configuration = RecordedShortcutConfiguration(
            shortcut: shortcut,
            note: "Legacy shortcut"
        )
        fixture.defaults.set(
            [ControllerInput.buttonA.rawValue: ControllerMappedAction.copy.rawValue],
            forKey: fixture.storageKey
        )
        fixture.defaults.set(
            [ControllerInput.buttonX.rawValue: "com.apple.Safari"],
            forKey: "\(fixture.storageKey).openApplications"
        )
        fixture.defaults.set(
            try JSONEncoder().encode([ControllerInput.buttonY: configuration]),
            forKey: "\(fixture.storageKey).recordedShortcuts"
        )
        fixture.defaults.set(8, forKey: "\(fixture.storageKey).schemaVersion")

        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        #expect(store.harnessProvider == .codex)
        #expect(store.action(for: .buttonA) == .copy)
        #expect(store.openApplicationTarget(for: .buttonX) == "com.apple.Safari")
        #expect(store.recordedShortcutConfiguration(for: .buttonY) == configuration)

        store.setAction(.paste, for: .buttonA)
        let storedMappings = try #require(
            fixture.defaults.dictionary(forKey: fixture.storageKey) as? [String: String]
        )
        #expect(storedMappings[ControllerInput.buttonA.rawValue] == ControllerMappedAction.paste.rawValue)
        #expect(fixture.defaults.object(forKey: "\(fixture.storageKey).providers.codex") == nil)
    }

    @Test
    func nonCodexDefaultsKeepGeneralActionsWithoutCodexSpecificActions() {
        let forbiddenActions: Set<ControllerMappedAction> = [
            .radialInput,
            .approve,
            .deny,
            .toggleFastMode,
            .splitThread,
            .pushToTalk,
            .focusCodex,
            .previousSlot,
            .nextSlot,
            .slot1,
            .slot2,
            .slot3,
            .slot4,
            .slot5,
            .slot6,
        ]

        for provider in [HarnessProviderID.claude, .cursor, .pi] {
            let defaults = ControllerMappingStore.defaultMappings(for: .xbox, provider: provider)
            #expect(Set(defaults.values).isDisjoint(with: forbiddenActions))
            #expect(defaults[.buttonA] == .mouseLeft)
            #expect(defaults[.buttonX] == .backspace)
            #expect(defaults[.options] == .screenshotTool)
            #expect(defaults[.dpadUp] == .rightCommand)
            #expect(defaults[.leftTrigger] == .functionModifier)
        }
    }

    @Test
    func providersPersistIndependentMappings() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let expected: [(HarnessProviderID, ControllerMappedAction)] = [
            (.codex, .copy),
            (.claude, .paste),
            (.cursor, .escape),
            (.pi, .mouseMiddle),
        ]
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        for (provider, action) in expected {
            store.setHarnessProvider(provider)
            store.setAction(action, for: .buttonA)
        }

        for (provider, action) in expected.reversed() {
            store.setHarnessProvider(provider)
            #expect(store.action(for: .buttonA) == action)
        }

        let reloadedClaude = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )
        #expect(reloadedClaude.action(for: .buttonA) == .paste)
        let claudeKey = "\(fixture.storageKey).providers.claude"
        let storedClaudeMappings = try #require(
            fixture.defaults.dictionary(forKey: claudeKey) as? [String: String]
        )
        #expect(storedClaudeMappings[ControllerInput.buttonA.rawValue] == ControllerMappedAction.paste.rawValue)
    }

    @Test
    func providerSwitchRestoresApplicationTargetsAndRecordedShortcuts() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let codexShortcut = RecordedKeyboardShortcut(
            keyCode: 0x08,
            keyName: "C",
            modifiers: [.command, .shift]
        )
        let claudeShortcut = RecordedKeyboardShortcut(
            keyCode: 0x23,
            keyName: "P",
            modifiers: [.control, .option]
        )
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        store.setOpenApplicationTarget("com.openai.codex", for: .buttonX)
        store.setRecordedShortcut(codexShortcut, for: .buttonY)
        store.setRecordedShortcutNote("Codex action", for: .buttonY)

        store.setHarnessProvider(.claude)
        #expect(store.openApplicationTarget(for: .buttonX) == nil)
        #expect(store.recordedShortcutConfiguration(for: .buttonY).shortcut == nil)
        store.setOpenApplicationTarget("com.anthropic.claudefordesktop", for: .buttonX)
        store.setRecordedShortcut(claudeShortcut, for: .buttonY)
        store.setRecordedShortcutNote("Claude action", for: .buttonY)

        store.setHarnessProvider(.codex)
        #expect(store.openApplicationTarget(for: .buttonX) == "com.openai.codex")
        #expect(store.recordedShortcutConfiguration(for: .buttonY) == .init(
            shortcut: codexShortcut,
            note: "Codex action"
        ))

        store.setHarnessProvider(.claude)
        #expect(store.openApplicationTarget(for: .buttonX) == "com.anthropic.claudefordesktop")
        #expect(store.recordedShortcutConfiguration(for: .buttonY) == .init(
            shortcut: claudeShortcut,
            note: "Claude action"
        ))
    }

    @Test
    func providerAndControllerFamilyFormIndependentProfiles() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        store.setControllerFamily(.joyConLeft)
        store.setAction(.copy, for: .buttonA)
        store.setHarnessProvider(.claude)
        store.setAction(.paste, for: .buttonA)
        store.setControllerFamily(.joyConRight)
        store.setAction(.escape, for: .buttonA)
        store.setHarnessProvider(.codex)
        store.setAction(.mouseMiddle, for: .buttonA)

        store.setControllerFamily(.joyConLeft)
        #expect(store.action(for: .buttonA) == .copy)
        store.setHarnessProvider(.claude)
        #expect(store.action(for: .buttonA) == .paste)
        store.setControllerFamily(.joyConRight)
        #expect(store.action(for: .buttonA) == .escape)
        store.setHarnessProvider(.codex)
        #expect(store.action(for: .buttonA) == .mouseMiddle)
    }

    @Test
    func nonCodexCustomCodexActionSurvivesSwitchAndReload() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )

        store.setAction(.approve, for: .buttonA)
        store.setHarnessProvider(.pi)
        store.setHarnessProvider(.claude)
        #expect(store.action(for: .buttonA) == .approve)

        let reloaded = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )
        #expect(reloaded.action(for: .buttonA) == .approve)
    }
}

private struct DefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let storageKey: String

    init() throws {
        suiteName = "ControllerMappingProviderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        storageKey = "controllerMappings.\(UUID().uuidString)"
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
