import AppKit
import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AppearanceRegressionTests {
    @Test
    func darkToSystemClearsTheApplicationAppearanceOverride() throws {
        let suiteName = "AppearanceRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var appliedAppearances: [NSAppearance.Name?] = []
        let settings = AppearanceSettings(userDefaults: defaults) { preference in
            appliedAppearances.append(preference.appearanceName)
        }

        settings.preference = .dark
        settings.preference = .system

        #expect(appliedAppearances == [nil, .darkAqua, nil])
        #expect(defaults.string(forKey: AppearanceSettings.storageKey) == "system")
    }
}
