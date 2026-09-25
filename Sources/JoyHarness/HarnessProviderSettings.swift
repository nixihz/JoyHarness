import Combine
import Foundation

enum HarnessProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case antigravity

    var id: Self { self }
}

struct HarnessProviderConfiguration: Identifiable, Equatable, Sendable {
    let id: HarnessProviderID
    let simplifiedChineseName: String
    let englishName: String
    let systemImage: String
    var isEnabled: Bool
    var bundleIdentifier: String?
    var appName: String?
    var activateApplicationOnSelection: Bool

    var displayName: String {
        displayName(language: L10n.language)
    }

    func displayName(language: SupportedLanguage) -> String {
        language == .simplifiedChinese ? simplifiedChineseName : englishName
    }

    var hasAssociatedApplication: Bool {
        bundleIdentifier != nil || appName != nil
    }

    func matchesBundleIdentifier(_ value: String?) -> Bool {
        Self.matches(bundleIdentifier, value)
    }

    func matchesAppName(_ value: String?) -> Bool {
        Self.matches(appName, value)
    }

    /// Whether a running application belongs to this Harness by either of its
    /// configured identities.
    func isAssociated(bundleIdentifier: String?, appName: String?) -> Bool {
        matchesBundleIdentifier(bundleIdentifier) || matchesAppName(appName)
    }

    private static func matches(_ configuredValue: String?, _ currentValue: String?) -> Bool {
        guard let configuredValue = HarnessProviderSettings.normalized(configuredValue),
              let currentValue = HarnessProviderSettings.normalized(currentValue) else {
            return false
        }
        return configuredValue.caseInsensitiveCompare(currentValue) == .orderedSame
    }
}

@MainActor
final class HarnessProviderSettings: ObservableObject {
    static let storageKey = "harnessProviderSettings.v1"

    static let defaultProviders: [HarnessProviderConfiguration] = [
        HarnessProviderConfiguration(
            id: .codex,
            simplifiedChineseName: "Codex",
            englishName: "Codex",
            systemImage: "terminal.fill",
            isEnabled: true,
            bundleIdentifier: "com.openai.codex",
            appName: "Codex",
            activateApplicationOnSelection: true
        ),
        HarnessProviderConfiguration(
            id: .claude,
            simplifiedChineseName: "Claude",
            englishName: "Claude",
            systemImage: "brain.head.profile",
            isEnabled: true,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude",
            activateApplicationOnSelection: true
        ),
        HarnessProviderConfiguration(
            id: .cursor,
            simplifiedChineseName: "Cursor",
            englishName: "Cursor",
            systemImage: "cursorarrow.rays",
            isEnabled: true,
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            appName: "Cursor",
            activateApplicationOnSelection: true
        ),
        HarnessProviderConfiguration(
            id: .antigravity,
            simplifiedChineseName: "Antigravity",
            englishName: "Antigravity",
            systemImage: "arrow.up.circle.fill",
            isEnabled: true,
            bundleIdentifier: "com.google.antigravity",
            appName: "Antigravity",
            activateApplicationOnSelection: true
        ),
    ]

    @Published private(set) var providers: [HarnessProviderConfiguration]
    @Published private(set) var activeProviderID: HarnessProviderID? {
        didSet {
            guard activeProviderID != oldValue else { return }
            onActiveProviderChange?(activeProviderID)
        }
    }
    var onSelectionRequest: ((HarnessProviderID) -> Bool)?
    /// Runs after the new value is stored. `$activeProviderID` publishes during
    /// `willSet`, so subscribers that read back this object would see the old
    /// Harness.
    var onActiveProviderChange: ((HarnessProviderID?) -> Void)?

    var enabledProviders: [HarnessProviderConfiguration] {
        providers.filter(\.isEnabled)
    }

    var activeProvider: HarnessProviderConfiguration? {
        guard let activeProviderID else { return nil }
        return provider(for: activeProviderID)
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let storedState = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        let storedProviders = Dictionary(
            (storedState?.providers ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        providers = Self.defaultProviders.map { provider in
            guard let stored = storedProviders[provider.id] else { return provider }
            var restored = provider
            restored.isEnabled = stored.isEnabled
            restored.bundleIdentifier = Self.normalized(stored.bundleIdentifier)
            restored.appName = Self.normalized(stored.appName)
            restored.activateApplicationOnSelection = stored.activateApplicationOnSelection
            return restored
        }
        activeProviderID = storedState?.activeProviderID ?? .codex
        reconcileActiveProvider()
    }

    func provider(for id: HarnessProviderID) -> HarnessProviderConfiguration? {
        providers.first { $0.id == id }
    }

    @discardableResult
    func select(_ id: HarnessProviderID) -> Bool {
        guard provider(for: id)?.isEnabled == true else { return false }
        guard activeProviderID != id else { return true }
        activeProviderID = id
        persist()
        return true
    }

    @discardableResult
    func requestSelection(_ id: HarnessProviderID) -> Bool {
        onSelectionRequest?(id) ?? select(id)
    }

    func configure(
        _ id: HarnessProviderID,
        update: (inout HarnessProviderConfiguration) -> Void
    ) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        var updated = providers[index]
        update(&updated)
        updated.bundleIdentifier = Self.normalized(updated.bundleIdentifier)
        updated.appName = Self.normalized(updated.appName)
        guard updated != providers[index] else { return }

        providers[index] = updated
        reconcileActiveProvider()
        persist()
    }

    func match(bundleIdentifier: String?, appName: String?) -> HarnessProviderConfiguration? {
        let enabled = enabledProviders
        if Self.normalized(bundleIdentifier) != nil {
            let bundleMatches = enabled.filter { $0.matchesBundleIdentifier(bundleIdentifier) }
            if bundleMatches.count == 1 {
                return bundleMatches[0]
            }
            if bundleMatches.count > 1 {
                return nil
            }
        }

        let nameMatches = enabled.filter { $0.matchesAppName(appName) }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func reconcileActiveProvider() {
        if let activeProviderID,
           provider(for: activeProviderID)?.isEnabled == true {
            return
        }
        activeProviderID = providers.first(where: \.isEnabled)?.id
    }

    private func persist() {
        let state = PersistedState(
            providers: providers.map(PersistedProvider.init),
            activeProviderID: activeProviderID
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    fileprivate nonisolated static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension HarnessProviderSettings {
    struct PersistedState: Codable {
        var providers: [PersistedProvider]
        var activeProviderID: HarnessProviderID?
    }

    struct PersistedProvider: Codable {
        var id: HarnessProviderID
        var isEnabled: Bool
        var bundleIdentifier: String?
        var appName: String?
        var activateApplicationOnSelection: Bool

        init(_ provider: HarnessProviderConfiguration) {
            id = provider.id
            isEnabled = provider.isEnabled
            bundleIdentifier = provider.bundleIdentifier
            appName = provider.appName
            activateApplicationOnSelection = provider.activateApplicationOnSelection
        }
    }
}
