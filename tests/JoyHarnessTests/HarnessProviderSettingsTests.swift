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

        #expect(settings.providers.map(\.id) == [.codex, .claude, .cursor, .pi])
        #expect(settings.providers.allSatisfy { $0.isEnabled })
        #expect(settings.activeProviderID == .codex)
        #expect(settings.provider(for: .claude)?.displayName(language: .simplifiedChinese) == "Claude")
        #expect(settings.provider(for: .cursor)?.displayName(language: .english) == "Cursor")
        #expect(settings.provider(for: .pi)?.systemImage == "function")
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

        #expect(settings.activeProviderID == .pi)
        #expect(settings.activeProvider?.id == .pi)
        #expect(!settings.select(.cursor))

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let reloaded = HarnessProviderSettings(userDefaults: reloadedDefaults)
        #expect(reloaded.activeProviderID == .pi)
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

    private func makeDefaults() throws -> (String, UserDefaults) {
        let suiteName = "HarnessProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
