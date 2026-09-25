import CoreGraphics
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

        for provider in HarnessProviderID.allCases where provider != .codex {
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
    func claudeShouldersCycleSessionsAndRightTriggerOpensSearch() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )
        // Claude desktop Go menu: ⌘⇧[ Previous Session, ⌘⇧] Next Session, ⌘⇧K Search….
        let expectedKeyCodes: [(ControllerInput, CGKeyCode)] = [
            (.leftShoulder, 0x21),
            (.rightShoulder, 0x1E),
            (.rightTrigger, 0x28),
        ]

        for (input, keyCode) in expectedKeyCodes {
            guard case .systemKey(let key) = store.action(for: input).controllerAction else {
                Issue.record("\(input) does not send a keyboard shortcut")
                continue
            }
            let pressed = key.eventDescriptor(pressed: true)
            #expect(pressed.keyCode == keyCode)
            #expect(pressed.flags == [.maskCommand, .maskShift])
            #expect(key.eventDescriptor(pressed: false).flags.isEmpty)
            #expect(!key.repeatsWhileHeld)
        }

        store.setHarnessProvider(.codex)
        #expect(store.action(for: .leftShoulder) == .previousSlot)
        #expect(store.action(for: .rightShoulder) == .nextSlot)
        #expect(store.action(for: .rightTrigger) == .focusCodex)
    }

    @Test
    func claudeSessionDefaultsStayOnClaudeAndSkipMissingInputs() {
        let claudeActions: Set<ControllerMappedAction> = [
            .claudePreviousSession,
            .claudeNextSession,
            .claudeSearch,
        ]

        for family in [ControllerFamily.joyConLeft, .joyConRight, .xiaomiRemote] {
            let defaults = ControllerMappingStore.defaultMappings(for: family, provider: .claude)
            #expect(defaults[.leftShoulder] == .claudePreviousSession)
            #expect(defaults[.rightShoulder] == .claudeNextSession)
            #expect(defaults[.rightTrigger] == .disabled)
        }
        for provider in HarnessProviderID.allCases where provider != .claude {
            let defaults = ControllerMappingStore.defaultMappings(for: .xbox, provider: provider)
            #expect(Set(defaults.values).isDisjoint(with: claudeActions))
        }
    }

    @Test
    func savedClaudeProfileGainsSessionShortcutsOnceWithoutOverwritingCustomKeys() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let claudeKey = "\(fixture.storageKey).providers.claude"
        fixture.defaults.set(
            [
                ControllerInput.leftShoulder.rawValue: ControllerMappedAction.disabled.rawValue,
                ControllerInput.rightShoulder.rawValue: ControllerMappedAction.copy.rawValue,
                ControllerInput.rightTrigger.rawValue: ControllerMappedAction.disabled.rawValue,
            ],
            forKey: claudeKey
        )
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        store.setHarnessProvider(.claude)
        #expect(store.action(for: .leftShoulder) == .claudePreviousSession)
        #expect(store.action(for: .rightShoulder) == .copy)
        #expect(store.action(for: .rightTrigger) == .claudeSearch)
        let storedMappings = try #require(
            fixture.defaults.dictionary(forKey: claudeKey) as? [String: String]
        )
        #expect(storedMappings[ControllerInput.rightTrigger.rawValue] == ControllerMappedAction.claudeSearch.rawValue)

        store.setAction(.disabled, for: .leftShoulder)
        let reloaded = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )
        #expect(reloaded.action(for: .leftShoulder) == .disabled)
        #expect(reloaded.action(for: .rightTrigger) == .claudeSearch)
    }

    @Test
    func connectedControllerOutsideSettingsGainsClaudeSessionShortcuts() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        fixture.defaults.set(
            [
                ControllerInput.leftShoulder.rawValue: ControllerMappedAction.disabled.rawValue,
                ControllerInput.rightShoulder.rawValue: ControllerMappedAction.disabled.rawValue,
            ],
            forKey: "\(fixture.storageKey).profiles.xiaomi-remote.providers.claude"
        )
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )

        #expect(store.controllerFamily == .xbox)
        #expect(store.action(for: .leftShoulder, family: .xiaomiRemote) == .claudePreviousSession)
        #expect(store.action(for: .rightShoulder, family: .xiaomiRemote) == .claudeNextSession)

        store.setControllerFamily(.xiaomiRemote)
        store.setAction(.disabled, for: .leftShoulder)
        store.setControllerFamily(.xbox)
        #expect(store.action(for: .leftShoulder, family: .xiaomiRemote) == .disabled)
        #expect(store.action(for: .rightShoulder, family: .xiaomiRemote) == .claudeNextSession)
    }

    @Test
    func providersPersistIndependentMappings() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let expected: [(HarnessProviderID, ControllerMappedAction)] = [
            (.codex, .copy),
            (.claude, .paste),
            (.cursor, .escape),
            (.antigravity, .enter),
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
        store.setHarnessProvider(.antigravity)
        store.setHarnessProvider(.claude)
        #expect(store.action(for: .buttonA) == .approve)

        let reloaded = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey,
            harnessProvider: .claude
        )
        #expect(reloaded.action(for: .buttonA) == .approve)
    }

    @Test
    func gamepadHomeShowsTheSwitcherInsteadOfItsUnusedMapping() throws {
        let fixture = try DefaultsFixture()
        defer { fixture.remove() }
        let store = ControllerMappingStore(
            userDefaults: fixture.defaults,
            storageKey: fixture.storageKey
        )

        store.setControllerFamily(.dualSense)
        let defaultTitle = store.mappedActionDisplayName(for: .home)
        store.setAction(.escape, for: .home)

        #expect(store.isReservedForHarnessSwitcher(.home))
        #expect(!store.isReservedForHarnessSwitcher(.buttonA))
        #expect(store.mappedActionDisplayName(for: .home) == defaultTitle)
        #expect(defaultTitle != ControllerMappedAction.toggleOperationMode.displayName)
        #expect(defaultTitle != ControllerMappedAction.escape.displayName)

        store.setControllerFamily(.xiaomiRemote)
        store.setAction(.enter, for: .home)

        #expect(!store.isReservedForHarnessSwitcher(.home))
        #expect(store.mappedActionDisplayName(for: .home) == ControllerMappedAction.enter.displayName)
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
