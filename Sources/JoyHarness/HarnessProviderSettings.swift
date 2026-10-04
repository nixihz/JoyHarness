import Combine
import Foundation

struct HarnessProviderID: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    static let codex = Self(rawValue: "codex")
    static let claude = Self(rawValue: "claude")
    static let cursor = Self(rawValue: "cursor")
    static let antigravity = Self(rawValue: "antigravity")
    static let builtIns: [Self] = [.codex, .claude, .cursor, .antigravity]

    var id: Self { self }
    var isBuiltIn: Bool { Self.builtIns.contains(self) }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Keep the v1 string representation so existing preferences and mapping
    // storage keys remain valid as user-added Harnesses gain their own IDs.
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct HarnessProviderConfiguration: Identifiable, Equatable, Sendable {
    let id: HarnessProviderID
    let simplifiedChineseName: String
    let englishName: String
    let systemImage: String
    var isEnabled: Bool
    var bundleIdentifier: String?
    var appName: String?
    var applicationPath: String? = nil

    var displayName: String {
        displayName(language: L10n.language)
    }

    func displayName(language: SupportedLanguage) -> String {
        if !id.isBuiltIn, let appName { return appName }
        return language == .simplifiedChinese ? simplifiedChineseName : englishName
    }

    var hasAssociatedApplication: Bool {
        bundleIdentifier != nil || appName != nil || applicationPath != nil
    }

    func matchesBundleIdentifier(_ value: String?) -> Bool {
        Self.matches(bundleIdentifier, value)
    }

    func matchesAppName(_ value: String?) -> Bool {
        Self.matches(appName, value)
    }

    func matchesApplicationPath(_ value: String?) -> Bool {
        guard let configuredPath = HarnessProviderSettings.normalized(applicationPath),
              let currentPath = HarnessProviderSettings.normalized(value) else { return false }
        return URL(fileURLWithPath: configuredPath).standardizedFileURL
            == URL(fileURLWithPath: currentPath).standardizedFileURL
    }

    /// Strong identities take precedence: another app with the same name must
    /// not inherit this Harness's status, icon, or mappings.
    func isAssociated(bundleIdentifier: String?, appName: String?, applicationPath: String? = nil) -> Bool {
        if HarnessProviderSettings.normalized(self.bundleIdentifier) != nil,
           HarnessProviderSettings.normalized(bundleIdentifier) != nil {
            return matchesBundleIdentifier(bundleIdentifier)
        }
        if HarnessProviderSettings.normalized(self.applicationPath) != nil,
           HarnessProviderSettings.normalized(applicationPath) != nil {
            return matchesApplicationPath(applicationPath)
        }
        return matchesAppName(appName)
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
            appName: "Codex"
        ),
        HarnessProviderConfiguration(
            id: .claude,
            simplifiedChineseName: "Claude",
            englishName: "Claude",
            systemImage: "brain.head.profile",
            isEnabled: true,
            bundleIdentifier: "com.anthropic.claudefordesktop",
            appName: "Claude"
        ),
        HarnessProviderConfiguration(
            id: .cursor,
            simplifiedChineseName: "Cursor",
            englishName: "Cursor",
            systemImage: "cursorarrow.rays",
            isEnabled: true,
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            appName: "Cursor"
        ),
        HarnessProviderConfiguration(
            id: .antigravity,
            simplifiedChineseName: "Antigravity",
            englishName: "Antigravity",
            systemImage: "arrow.up.circle.fill",
            isEnabled: true,
            bundleIdentifier: "com.google.antigravity",
            appName: "Antigravity"
        ),
    ]

    @Published private(set) var providers: [HarnessProviderConfiguration]
    @Published private(set) var activeProviderID: HarnessProviderID? {
        didSet {
            guard activeProviderID != oldValue else { return }
            onActiveProviderChange?(activeProviderID)
        }
    }
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
            restored.applicationPath = Self.normalized(stored.applicationPath)
            return restored
        }
        var restoredIDs = Set(providers.map(\.id))
        for stored in storedState?.providers ?? [] where restoredIDs.insert(stored.id).inserted {
            guard let name = Self.normalized(stored.name)
                ?? Self.normalized(stored.appName)
                ?? Self.normalized(stored.bundleIdentifier) else { continue }
            providers.append(HarnessProviderConfiguration(
                id: stored.id,
                simplifiedChineseName: name,
                englishName: name,
                systemImage: "app.dashed",
                isEnabled: stored.isEnabled,
                bundleIdentifier: Self.normalized(stored.bundleIdentifier),
                appName: Self.normalized(stored.appName),
                applicationPath: Self.normalized(stored.applicationPath)
            ))
        }
        activeProviderID = storedState?.activeProviderID ?? .codex
        reconcileActiveProvider()
    }

    func provider(for id: HarnessProviderID) -> HarnessProviderConfiguration? {
        providers.first { $0.id == id }
    }

    /// Re-adding an app enables its existing Harness without replacing its
    /// identity or mappings. Bundle IDs distinguish
    /// different apps that happen to have the same display name.
    @discardableResult
    func addApplication(
        bundleIdentifier: String?,
        appName: String?,
        applicationPath: String? = nil
    ) -> HarnessProviderID? {
        let bundleIdentifier = Self.normalized(bundleIdentifier)
        let appName = Self.normalized(appName)
        let applicationPath = Self.normalized(applicationPath)
        guard let name = appName ?? bundleIdentifier else { return nil }

        if let existing = matchingProviders(
            in: providers, bundleIdentifier: bundleIdentifier, appName: appName, applicationPath: applicationPath
        ).first {
            configure(existing.id) { provider in
                provider.isEnabled = true
                if let bundleIdentifier { provider.bundleIdentifier = bundleIdentifier }
                if let appName { provider.appName = appName }
                if let applicationPath { provider.applicationPath = applicationPath }
            }
            return existing.id
        }

        let id = HarnessProviderID(rawValue: "custom.\(UUID().uuidString.lowercased())")
        providers.append(HarnessProviderConfiguration(
            id: id,
            simplifiedChineseName: name,
            englishName: name,
            systemImage: "app.dashed",
            isEnabled: true,
            bundleIdentifier: bundleIdentifier,
            appName: appName ?? name,
            applicationPath: applicationPath
        ))
        reconcileActiveProvider()
        persist()
        return id
    }

    func removeApplication(_ id: HarnessProviderID) {
        guard !id.isBuiltIn, providers.contains(where: { $0.id == id }) else { return }
        providers.removeAll { $0.id == id }
        reconcileActiveProvider()
        persist()
    }

    /// Changes the active mappings without opening or activating any app.
    /// Application activation belongs to confirmation in the PS/Home switcher.
    @discardableResult
    func select(_ id: HarnessProviderID) -> Bool {
        guard provider(for: id)?.isEnabled == true else { return false }
        guard activeProviderID != id else { return true }
        activeProviderID = id
        persist()
        return true
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
        updated.applicationPath = Self.normalized(updated.applicationPath)
        guard updated != providers[index] else { return }

        providers[index] = updated
        reconcileActiveProvider()
        persist()
    }

    func match(
        bundleIdentifier: String?, appName: String?, applicationPath: String? = nil
    ) -> HarnessProviderConfiguration? {
        let matches = matchingProviders(
            in: enabledProviders, bundleIdentifier: bundleIdentifier, appName: appName, applicationPath: applicationPath
        )
        return matches.count == 1 ? matches[0] : nil
    }

    private func matchingProviders(
        in candidates: [HarnessProviderConfiguration],
        bundleIdentifier: String?, appName: String?, applicationPath: String?
    ) -> [HarnessProviderConfiguration] {
        let matches = candidates.filter {
            $0.isAssociated(bundleIdentifier: bundleIdentifier, appName: appName, applicationPath: applicationPath)
        }
        let bundleMatches = matches.filter { $0.matchesBundleIdentifier(bundleIdentifier) }
        if !bundleMatches.isEmpty { return bundleMatches }
        let pathMatches = matches.filter { $0.matchesApplicationPath(applicationPath) }
        return pathMatches.isEmpty ? matches : pathMatches
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
        var name: String?
        var applicationPath: String?

        init(_ provider: HarnessProviderConfiguration) {
            id = provider.id
            isEnabled = provider.isEnabled
            bundleIdentifier = provider.bundleIdentifier
            appName = provider.appName
            name = provider.id.isBuiltIn ? nil : provider.displayName(language: .english)
            applicationPath = provider.applicationPath
        }
    }
}
