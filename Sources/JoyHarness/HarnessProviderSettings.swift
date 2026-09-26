import Combine
import Foundation

enum HarnessProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case pi

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
            id: .pi,
            simplifiedChineseName: "Pi",
            englishName: "Pi",
            systemImage: "function",
            isEnabled: true,
            bundleIdentifier: nil,
            appName: nil,
            activateApplicationOnSelection: false
        ),
    ]

    @Published private(set) var providers: [HarnessProviderConfiguration]
    @Published private(set) var activeProviderID: HarnessProviderID?
    var onSelectionRequest: ((HarnessProviderID) -> Bool)?

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
        let normalizedBundleID = Self.normalized(bundleIdentifier)
        if let normalizedBundleID {
            let bundleMatches = enabled.filter {
                Self.matches($0.bundleIdentifier, normalizedBundleID)
            }
            if bundleMatches.count == 1 {
                return bundleMatches[0]
            }
            if bundleMatches.count > 1 {
                return nil
            }
        }

        guard let normalizedAppName = Self.normalized(appName) else { return nil }
        let nameMatches = enabled.filter {
            Self.matches($0.appName, normalizedAppName)
        }
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

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func matches(_ configuredValue: String?, _ currentValue: String) -> Bool {
        guard let configuredValue = normalized(configuredValue) else { return false }
        return configuredValue.caseInsensitiveCompare(currentValue) == .orderedSame
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
