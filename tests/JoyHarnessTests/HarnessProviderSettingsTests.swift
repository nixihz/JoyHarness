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
            $0.activateApplicationOnSelection = false
        }
        #expect(settings.select(.claude))
        #expect(defaults.data(forKey: HarnessProviderSettings.storageKey) != nil)

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reloaded = HarnessProviderSettings(userDefaults: reloadedDefaults)
        let claude = try #require(reloaded.provider(for: .claude))

        #expect(reloaded.activeProviderID == .claude)
        #expect(claude.bundleIdentifier == "dev.example.claude")
        #expect(claude.appName == "Claude Workbench")
        #expect(!claude.activateApplicationOnSelection)
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
        for id in HarnessProviderID.allCases {
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
        #expect(codex.isAssociated(bundleIdentifier: "dev.example.other", appName: " codex "))
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

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "HarnessProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
