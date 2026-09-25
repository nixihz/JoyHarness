import AppKit
import Combine
import Foundation

enum ControllerOperationMode: String, Codable, CaseIterable, Identifiable {
    case mapping = "mapping"
    case native = "native"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .mapping: L10n.text("按键映射模式", "Mapping Mode")
        case .native: L10n.text("原生手柄模式", "Native Gamepad Mode")
        }
    }

    var shortDisplayName: String {
        switch self {
        case .mapping: L10n.text("映射模式", "Mapping")
        case .native: L10n.text("原生手柄", "Native")
        }
    }

    var iconName: String {
        switch self {
        case .mapping: "keyboard"
        case .native: "gamecontroller.fill"
        }
    }
}

struct NativeGamepadApp: Identifiable, Codable, Hashable {
    var id: UUID
    var bundleIdentifier: String
    var appName: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
    }

    func matches(bundleIdentifier currentBundleID: String?, localizedName currentName: String?) -> Bool {
        guard isEnabled else { return false }
        if let currentBundleID = currentBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentBundleID.isEmpty,
           !bundleIdentifier.isEmpty,
           currentBundleID.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
            return true
        }
        if let currentName = currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentName.isEmpty,
           !appName.isEmpty,
           currentName.caseInsensitiveCompare(appName) == .orderedSame {
            return true
        }
        return false
    }

    func matches(runningApp: NSRunningApplication) -> Bool {
        matches(
            bundleIdentifier: runningApp.bundleIdentifier,
            localizedName: runningApp.localizedName
        )
    }

    func representsSameApplication(as other: NativeGamepadApp) -> Bool {
        if !bundleIdentifier.isEmpty, !other.bundleIdentifier.isEmpty {
            return bundleIdentifier.caseInsensitiveCompare(other.bundleIdentifier) == .orderedSame
        }

        return !appName.isEmpty &&
            !other.appName.isEmpty &&
            appName.caseInsensitiveCompare(other.appName) == .orderedSame
    }
}

final class NativeGamepadAppSettings: ObservableObject {
    static let storageKey = "nativeGamepadAppSettings.v1"
    private static let defaultCatalogVersionKey = "\(storageKey).defaultCatalogVersion"
    private static let defaultCatalogVersion = 3

    private static let defaultAppDefinitions: [(app: NativeGamepadApp, introducedInVersion: Int)] = [
        (
            NativeGamepadApp(
                bundleIdentifier: "com.joydsh.desktop",
                appName: "JoyDSH",
                isEnabled: true
            ),
            1
        ),
        (
            NativeGamepadApp(
                bundleIdentifier: "com.google.antigravity",
                appName: "Antigravity",
                isEnabled: false
            ),
            2
        ),
    ]
    static let defaultApps = defaultAppDefinitions.map { $0.app }

    @Published var autoSwitchEnabled: Bool {
        didSet {
            persist()
            onChange?()
        }
    }

    @Published var apps: [NativeGamepadApp] {
        didSet {
            persist()
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private let userDefaults: UserDefaults
    private let isApplicationInstalled: (String) -> Bool
    private var unavailableDefaultApps: [NativeGamepadApp]

    init(
        userDefaults: UserDefaults = .standard,
        isApplicationInstalled: @escaping (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    ) {
        let loadedApps = Self.loadApps(
            from: userDefaults,
            key: "\(Self.storageKey).apps",
            isApplicationInstalled: isApplicationInstalled
        )
        self.userDefaults = userDefaults
        self.isApplicationInstalled = isApplicationInstalled
        self.unavailableDefaultApps = loadedApps.unavailableDefaults
        let storedAutoSwitch = userDefaults.object(forKey: "\(Self.storageKey).autoSwitch") as? Bool
        self.autoSwitchEnabled = storedAutoSwitch ?? true
        self.apps = loadedApps.visible
    }

    func addApp(bundleIdentifier: String, appName: String) {
        let trimmedBundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty || !trimmedName.isEmpty else { return }
        let incomingApp = NativeGamepadApp(
            bundleIdentifier: trimmedBundleID,
            appName: trimmedName
        )

        unavailableDefaultApps.removeAll { $0.representsSameApplication(as: incomingApp) }

        if let index = apps.firstIndex(where: { $0.representsSameApplication(as: incomingApp) }) {
            var updated = apps[index]
            if !trimmedBundleID.isEmpty { updated.bundleIdentifier = trimmedBundleID }
            if !trimmedName.isEmpty { updated.appName = trimmedName }
            updated.isEnabled = true
            apps[index] = updated
            return
        }

        let newApp = NativeGamepadApp(
            bundleIdentifier: trimmedBundleID,
            appName: trimmedName.isEmpty ? trimmedBundleID : trimmedName,
            isEnabled: true
        )
        apps.append(newApp)
    }

    func removeApp(id: UUID) {
        apps.removeAll { $0.id == id }
    }

    func toggleApp(id: UUID) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].isEnabled.toggle()
    }

    func setAppEnabled(id: UUID, isEnabled: Bool) {
        guard let index = apps.firstIndex(where: { $0.id == id }), apps[index].isEnabled != isEnabled else { return }
        apps[index].isEnabled = isEnabled
    }

    func matches(bundleIdentifier: String?, localizedName: String?) -> Bool {
        guard autoSwitchEnabled else { return false }
        return apps.contains { $0.matches(bundleIdentifier: bundleIdentifier, localizedName: localizedName) }
    }

    func matches(runningApp: NSRunningApplication) -> Bool {
        guard autoSwitchEnabled else { return false }
        return apps.contains { $0.matches(runningApp: runningApp) }
    }

    func resetDefaults() {
        let loadedDefaults = Self.partitionApps(
            Self.defaultApps,
            isApplicationInstalled: isApplicationInstalled
        )
        unavailableDefaultApps = loadedDefaults.unavailableDefaults
        apps = loadedDefaults.visible
        autoSwitchEnabled = true
    }

    func refreshInstalledDefaultApps() {
        let loadedApps = Self.partitionApps(
            apps + unavailableDefaultApps,
            isApplicationInstalled: isApplicationInstalled
        )
        guard loadedApps.visible != apps ||
              loadedApps.unavailableDefaults != unavailableDefaultApps else { return }
        unavailableDefaultApps = loadedApps.unavailableDefaults
        apps = loadedApps.visible
    }

    /// A running app is installed, so its hidden default entry can be shown
    /// without the LaunchServices lookups of a full refresh. This runs on
    /// every app activation.
    func revealDefaultApp(runningWithBundleIdentifier bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let index = unavailableDefaultApps.firstIndex(where: {
                  $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
              }) else { return }
        let app = unavailableDefaultApps.remove(at: index)
        apps.append(app)
    }

    private func persist() {
        userDefaults.set(autoSwitchEnabled, forKey: "\(Self.storageKey).autoSwitch")
        if let data = try? JSONEncoder().encode(apps + unavailableDefaultApps) {
            userDefaults.set(data, forKey: "\(Self.storageKey).apps")
        }
    }

    private struct LoadedApps {
        let visible: [NativeGamepadApp]
        let unavailableDefaults: [NativeGamepadApp]
    }

    private static func loadApps(
        from userDefaults: UserDefaults,
        key: String,
        isApplicationInstalled: (String) -> Bool
    ) -> LoadedApps {
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NativeGamepadApp].self, from: data) else {
            userDefaults.set(defaultCatalogVersion, forKey: defaultCatalogVersionKey)
            return partitionApps(defaultApps, isApplicationInstalled: isApplicationInstalled)
        }

        var configuredApps = normalizedApps(decoded)
        let storedCatalogVersion = userDefaults.object(forKey: defaultCatalogVersionKey) as? Int ?? 1
        if storedCatalogVersion == 2 {
            // Version 2 enabled Antigravity by default before it gained its
            // own Harness mappings. Existing development installs need the
            // same opt-in default as fresh installs.
            for index in configuredApps.indices where
                configuredApps[index].bundleIdentifier.caseInsensitiveCompare("com.google.antigravity") == .orderedSame &&
                configuredApps[index].appName.caseInsensitiveCompare("Antigravity") == .orderedSame {
                configuredApps[index].isEnabled = false
            }
        }
        if storedCatalogVersion < defaultCatalogVersion {
            for definition in defaultAppDefinitions where definition.introducedInVersion > storedCatalogVersion {
                let app = definition.app
                guard !configuredApps.contains(where: { $0.representsSameApplication(as: app) }) else { continue }
                configuredApps.append(app)
            }
        }

        if storedCatalogVersion < defaultCatalogVersion || configuredApps != decoded {
            if let migratedData = try? JSONEncoder().encode(configuredApps) {
                userDefaults.set(migratedData, forKey: key)
            }
        }

        if storedCatalogVersion < defaultCatalogVersion {
            userDefaults.set(defaultCatalogVersion, forKey: defaultCatalogVersionKey)
        }

        return partitionApps(configuredApps, isApplicationInstalled: isApplicationInstalled)
    }

    private static func normalizedApps(_ configuredApps: [NativeGamepadApp]) -> [NativeGamepadApp] {
        var result: [NativeGamepadApp] = []

        for configuredApp in configuredApps {
            var candidate = configuredApp
            if candidate.bundleIdentifier.isEmpty,
               let defaultApp = defaultApps.first(where: { $0.representsSameApplication(as: candidate) }) {
                candidate.bundleIdentifier = defaultApp.bundleIdentifier
                if candidate.appName.isEmpty {
                    candidate.appName = defaultApp.appName
                }
            }

            if let existingIndex = result.firstIndex(where: { $0.representsSameApplication(as: candidate) }) {
                if result[existingIndex].bundleIdentifier.isEmpty {
                    result[existingIndex].bundleIdentifier = candidate.bundleIdentifier
                }
                if result[existingIndex].appName.isEmpty {
                    result[existingIndex].appName = candidate.appName
                }
                continue
            }

            result.append(candidate)
        }

        return result
    }

    private static func partitionApps(
        _ configuredApps: [NativeGamepadApp],
        isApplicationInstalled: (String) -> Bool
    ) -> LoadedApps {
        let defaultBundleIdentifiers = Set(defaultApps.map { $0.bundleIdentifier.lowercased() })
        var visible: [NativeGamepadApp] = []
        var unavailableDefaults: [NativeGamepadApp] = []
        for app in configuredApps {
            if defaultBundleIdentifiers.contains(app.bundleIdentifier.lowercased()),
               !isApplicationInstalled(app.bundleIdentifier) {
                unavailableDefaults.append(app)
            } else {
                visible.append(app)
            }
        }
        return LoadedApps(visible: visible, unavailableDefaults: unavailableDefaults)
    }
}
