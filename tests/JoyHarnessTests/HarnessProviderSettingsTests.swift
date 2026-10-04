import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct HarnessProviderSettingsTests {
    @Test
    func builtInProvidersHaveStableIdentityAndLocalizedPresentation() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)

        #expect(settings.providers.map(\.id) == [.codex, .claude, .cursor, .antigravity])
        #expect(settings.providers.allSatisfy { $0.isEnabled })
        #expect(settings.activeProviderID == .codex)
        #expect(settings.provider(for: .claude)?.displayName(language: .simplifiedChinese) == "Claude")
        #expect(settings.provider(for: .cursor)?.displayName(language: .english) == "Cursor")
        #expect(settings.provider(for: .antigravity)?.systemImage == "arrow.up.circle.fill")
    }

    @Test
    func configurationAndActiveProviderSurviveReload() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.claude) {
            $0.bundleIdentifier = "  dev.example.claude  "
            $0.appName = "  Claude Workbench  "
            $0.applicationPath = "/Users/example/Tools/Claude Workbench.app"
        }
        #expect(settings.select(.claude))
        #expect(defaults.data(forKey: HarnessProviderSettings.storageKey) != nil)

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reloaded = HarnessProviderSettings(userDefaults: reloadedDefaults)
        let claude = try #require(reloaded.provider(for: .claude))

        #expect(reloaded.activeProviderID == .claude)
        #expect(claude.bundleIdentifier == "dev.example.claude")
        #expect(claude.appName == "Claude Workbench")
        #expect(claude.applicationPath == "/Users/example/Tools/Claude Workbench.app")
    }

    @Test
    func disablingActiveProviderSelectsFirstRemainingEnabledProvider() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.codex) { $0.isEnabled = false }
        settings.configure(.claude) { $0.isEnabled = false }
        #expect(settings.select(.cursor))

        settings.configure(.cursor) { $0.isEnabled = false }

        #expect(settings.activeProviderID == .antigravity)
        #expect(settings.activeProvider?.id == .antigravity)
        #expect(!settings.select(.cursor))

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reloaded = HarnessProviderSettings(userDefaults: reloadedDefaults)
        #expect(reloaded.activeProviderID == .antigravity)
    }

    @Test
    func enablingAProviderRestoresSelectionWhenAllWereDisabled() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        for id in HarnessProviderID.builtIns {
            settings.configure(id) { $0.isEnabled = false }
        }
        #expect(settings.activeProviderID == nil)

        settings.configure(.cursor) { $0.isEnabled = true }

        #expect(settings.activeProviderID == .cursor)
    }

    @Test
    func bundleIdentifierHasPriorityOverConflictingApplicationName() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.codex) {
            $0.bundleIdentifier = "dev.example.codex"
            $0.appName = "Codex"
        }
        settings.configure(.claude) {
            $0.bundleIdentifier = "dev.example.claude"
            $0.appName = "Claude"
        }

        let match = settings.match(
            bundleIdentifier: " DEV.EXAMPLE.CODEX ",
            appName: "Claude"
        )

        #expect(match?.id == .codex)
    }

    @Test
    func applicationNameMatchesOnlyOneEnabledProvider() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.codex) { $0.appName = "Shared Terminal" }
        settings.configure(.claude) { $0.appName = "Shared Terminal" }

        #expect(settings.match(bundleIdentifier: nil, appName: "shared terminal") == nil)

        settings.configure(.claude) { $0.isEnabled = false }

        #expect(settings.match(bundleIdentifier: nil, appName: " SHARED TERMINAL ")?.id == .codex)
    }

    @Test
    func ambiguousBundleIdentifierDoesNotFallBackToApplicationName() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.codex) { $0.bundleIdentifier = "dev.example.shared" }
        settings.configure(.claude) { $0.bundleIdentifier = "dev.example.shared" }

        let match = settings.match(
            bundleIdentifier: "dev.example.shared",
            appName: "Claude"
        )

        #expect(match == nil)
    }

    @Test
    func antigravityMatchesItsAgentAppButNotTheSeparateIDE() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)

        #expect(settings.match(
            bundleIdentifier: "com.google.antigravity",
            appName: "Antigravity"
        )?.id == .antigravity)
        #expect(settings.match(
            bundleIdentifier: "com.google.antigravity-ide",
            appName: "Antigravity IDE"
        ) == nil)
    }

    @Test
    func activeProviderChangeCallbackSeesTheStoredHarness() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        var observed: [(reported: HarnessProviderID?, stored: HarnessProviderID?)] = []
        settings.onActiveProviderChange = { providerID in
            observed.append((providerID, settings.activeProviderID))
        }

        #expect(settings.select(.claude))
        #expect(settings.select(.claude))
        settings.configure(.claude) { $0.isEnabled = false }

        #expect(observed.map(\.reported) == [.claude, .codex])
        #expect(observed.map(\.stored) == [.claude, .codex])
    }

    @Test
    func applicationAssociationIgnoresMissingIdentities() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        settings.configure(.cursor) {
            $0.bundleIdentifier = " "
            $0.appName = ""
        }
        let codex = try #require(settings.provider(for: .codex))
        let cursor = try #require(settings.provider(for: .cursor))

        #expect(codex.isAssociated(bundleIdentifier: "COM.OPENAI.CODEX", appName: "Terminal"))
        #expect(!codex.isAssociated(bundleIdentifier: "dev.example.other", appName: " codex "))
        #expect(codex.isAssociated(bundleIdentifier: nil, appName: " codex "))
        #expect(!codex.isAssociated(bundleIdentifier: "dev.example.other", appName: "Terminal"))
        #expect(!cursor.isAssociated(bundleIdentifier: nil, appName: nil))
        #expect(!cursor.isAssociated(bundleIdentifier: " ", appName: ""))
        #expect(HarnessSwitcherOption(configuration: cursor, isApplicationConnected: false)
            .applicationStatus == .notAssociated)
        #expect(HarnessSwitcherOption(configuration: codex, isApplicationConnected: false)
            .applicationStatus == .notRunning)
    }

    @Test
    func browsedApplicationNameDropsOnlyTheTrailingExtension() {
        #expect(ApplicationPresentation.name(forDisplayName: "Claude.app") == "Claude")
        #expect(ApplicationPresentation.name(forDisplayName: "Claude") == "Claude")
        #expect(ApplicationPresentation.name(forDisplayName: "My.appliance.app") == "My.appliance")
        #expect(ApplicationPresentation.name(forDisplayName: ".app") == ".app")
    }

    @Test
    func legacyPreferencesRestoreWithoutLosingAssociationsOrSelection() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyJSON = """
        {"providers":[
          {"id":"codex","isEnabled":false,"bundleIdentifier":"com.openai.codex","appName":"Codex","activateApplicationOnSelection":true},
          {"id":"cursor","isEnabled":true,"bundleIdentifier":"dev.example.editor","appName":"Work Editor","activateApplicationOnSelection":false}
        ],"activeProviderID":"cursor"}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: HarnessProviderSettings.storageKey)

        let settings = HarnessProviderSettings(userDefaults: defaults)
        #expect(settings.activeProviderID == .cursor)
        #expect(settings.provider(for: .codex)?.isEnabled == false)
        #expect(settings.provider(for: .cursor)?.bundleIdentifier == "dev.example.editor")
        #expect(settings.provider(for: .cursor)?.appName == "Work Editor")
        #expect(settings.provider(for: .claude)?.isEnabled == true)

        _ = settings.addApplication(bundleIdentifier: "dev.example.terminal", appName: "Terminal")
        let reloaded = HarnessProviderSettings(userDefaults: defaults)
        #expect(reloaded.activeProviderID == .cursor)
        #expect(reloaded.provider(for: .codex)?.isEnabled == false)
        #expect(reloaded.provider(for: .cursor)?.appName == "Work Editor")
    }

    @Test
    func addedApplicationsSurviveReloadAndMatchForegroundApplications() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let terminalID = try #require(settings.addApplication(
            bundleIdentifier: "  dev.example.terminal  ",
            appName: "  Work Terminal  ",
            applicationPath: "/Users/example/Tools/Work Terminal.app"
        ))
        let editorID = try #require(settings.addApplication(bundleIdentifier: "dev.example.editor", appName: "Editor"))
        settings.configure(editorID) { $0.isEnabled = false }
        #expect(settings.select(terminalID))

        let reloaded = HarnessProviderSettings(userDefaults: defaults)
        let terminal = try #require(reloaded.provider(for: terminalID))
        #expect(reloaded.providers.suffix(2).map(\.id) == [terminalID, editorID])
        #expect(reloaded.activeProviderID == terminalID)
        #expect(terminal.displayName(language: .simplifiedChinese) == "Work Terminal")
        #expect(terminal.displayName(language: .english) == "Work Terminal")
        #expect(terminal.applicationPath == "/Users/example/Tools/Work Terminal.app")
        #expect(reloaded.match(bundleIdentifier: "DEV.EXAMPLE.TERMINAL", appName: "Other")?.id == terminalID)
        #expect(reloaded.match(bundleIdentifier: "dev.example.editor", appName: "Editor") == nil)
        #expect(reloaded.enabledProviders.contains { $0.id == terminalID })
        #expect(!reloaded.enabledProviders.contains { $0.id == editorID })
    }

    @Test
    func readdingApplicationsReusesCustomAndBuiltInHarnesses() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let id = try #require(settings.addApplication(bundleIdentifier: "dev.example.editor", appName: "Editor"))
        settings.configure(id) {
            $0.isEnabled = false
        }
        settings.configure(.claude) { $0.isEnabled = false }

        #expect(settings.addApplication(bundleIdentifier: " DEV.EXAMPLE.EDITOR ", appName: "Editor 2") == id)
        #expect(settings.addApplication(bundleIdentifier: "COM.ANTHROPIC.CLAUDEFORDESKTOP", appName: "Claude") == .claude)
        #expect(settings.providers.count == 5)
        #expect(settings.provider(for: id)?.isEnabled == true)
        #expect(settings.provider(for: id)?.displayName == "Editor 2")
        #expect(settings.provider(for: .claude)?.isEnabled == true)
    }

    @Test
    func sameNamedAppsWithDifferentIdentitiesRemainSeparate() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let first = try #require(settings.addApplication(bundleIdentifier: "dev.example.editor", appName: "Editor"))
        let second = try #require(settings.addApplication(bundleIdentifier: "dev.example.editor.beta", appName: "Editor"))
        let pathOnly = try #require(settings.addApplication(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Tools/Tool.app"
        ))
        let otherPath = try #require(settings.addApplication(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Beta/Tool.app"
        ))
        #expect(first != second)
        #expect(pathOnly != otherPath)
        #expect(settings.match(bundleIdentifier: "dev.example.editor.beta", appName: "Editor")?.id == second)
        #expect(settings.match(bundleIdentifier: nil, appName: "Editor") == nil)
        #expect(settings.match(bundleIdentifier: "dev.example.unrelated", appName: "Editor") == nil)
        #expect(settings.match(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Beta/Tool.app"
        )?.id == otherPath)
        #expect(settings.match(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Unknown/Tool.app"
        ) == nil)
        #expect(settings.addApplication(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Tools/../Beta/Tool.app"
        ) == otherPath)
        #expect(settings.addApplication(bundleIdentifier: " ", appName: "\n") == nil)
        #expect(settings.providers.count == 8)
    }

    @Test
    func exactApplicationPathWinsOverLegacyNameOnlyAssociation() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let id = try #require(settings.addApplication(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Tools/Tool.app"
        ))
        settings.configure(.codex) {
            $0.bundleIdentifier = nil
            $0.appName = "Tool"
        }

        #expect(settings.match(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Tools/Tool.app"
        )?.id == id)
        #expect(settings.match(bundleIdentifier: nil, appName: "Tool") == nil)
        settings.configure(id) { $0.isEnabled = false }
        #expect(settings.addApplication(
            bundleIdentifier: nil, appName: "Tool", applicationPath: "/Users/example/Tools/Tool.app"
        ) == id)
        #expect(settings.provider(for: id)?.isEnabled == true)
        #expect(settings.provider(for: .codex)?.applicationPath == nil)
        #expect(settings.providers.count == 5)
    }

    @Test
    func removingActiveCustomHarnessReconcilesAndPersistsSelection() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        for id in HarnessProviderID.builtIns { settings.configure(id) { $0.isEnabled = false } }
        let first = try #require(settings.addApplication(bundleIdentifier: nil, appName: "First"))
        let second = try #require(settings.addApplication(bundleIdentifier: nil, appName: "Second"))
        #expect(settings.activeProviderID == first)
        settings.removeApplication(first)
        #expect(settings.activeProviderID == second)
        settings.removeApplication(.codex)

        let reloaded = HarnessProviderSettings(userDefaults: defaults)
        #expect(reloaded.activeProviderID == second)
        #expect(reloaded.provider(for: first) == nil)
        #expect(reloaded.provider(for: .codex) != nil)
        reloaded.removeApplication(second)
        #expect(HarnessProviderSettings(userDefaults: defaults).activeProviderID == nil)
    }

    @Test
    func customMappingsStayIndependentAcrossSelectionReassociationAndReload() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let first = try #require(settings.addApplication(bundleIdentifier: "dev.example.first", appName: "First"))
        let second = try #require(settings.addApplication(bundleIdentifier: "dev.example.second", appName: "Second"))
        let mappings = ControllerMappingStore(userDefaults: defaults)
        mappings.setAction(.copy, for: .buttonA)
        mappings.setHarnessProvider(first)
        #expect(mappings.action(for: .buttonA) == .mouseLeft)
        #expect(mappings.action(for: .rightTrigger) == .disabled)
        mappings.setAction(.paste, for: .buttonA)
        mappings.setHarnessProvider(second)
        #expect(mappings.action(for: .buttonA) == .mouseLeft)
        mappings.setAction(.escape, for: .buttonA)
        settings.configure(first) {
            $0.bundleIdentifier = "dev.example.replacement"
            $0.appName = "Replacement"
        }
        mappings.setHarnessProvider(.codex)
        #expect(mappings.action(for: .buttonA) == .copy)

        let reloaded = HarnessProviderSettings(userDefaults: defaults)
        let restoredID = try #require(reloaded.match(bundleIdentifier: "dev.example.replacement", appName: nil)?.id)
        #expect(ControllerMappingStore(userDefaults: defaults, harnessProvider: restoredID).action(for: .buttonA) == .paste)
        #expect(ControllerMappingStore(userDefaults: defaults, harnessProvider: second).action(for: .buttonA) == .escape)
    }

    @Test
    func browsedApplicationOutsideApplicationsRetainsItsLocationAfterReload() throws {
        let (suiteName, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Harness-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = HarnessProviderSettings(userDefaults: defaults)
        let id = try #require(settings.addApplication(bundleIdentifier: nil, appName: "Local Tool", applicationPath: url.path))
        let reloaded = HarnessProviderSettings(userDefaults: defaults)
        let provider = try #require(reloaded.provider(for: id))
        #expect(provider.installedApplicationURL(urlForBundleIdentifier: { _ in nil }, applicationDirectories: [])?.path == url.path)

        try FileManager.default.removeItem(at: url)
        #expect(provider.installedApplicationURL(urlForBundleIdentifier: { _ in nil }, applicationDirectories: []) == nil)
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "HarnessProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
