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
}

final class NativeGamepadAppSettings: ObservableObject {
    static let storageKey = "nativeGamepadAppSettings.v1"

    static let defaultApps: [NativeGamepadApp] = [
        NativeGamepadApp(
            bundleIdentifier: "com.joydsh.desktop",
            appName: "JoyDSH",
            isEnabled: true
        )
    ]

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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let storedAutoSwitch = userDefaults.object(forKey: "\(Self.storageKey).autoSwitch") as? Bool
        self.autoSwitchEnabled = storedAutoSwitch ?? true
        self.apps = Self.loadApps(from: userDefaults, key: "\(Self.storageKey).apps")
    }

    func addApp(bundleIdentifier: String, appName: String) {
        let trimmedBundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty || !trimmedName.isEmpty else { return }

        if let index = apps.firstIndex(where: {
            (!trimmedBundleID.isEmpty && $0.bundleIdentifier.caseInsensitiveCompare(trimmedBundleID) == .orderedSame) ||
            (!trimmedName.isEmpty && $0.appName.caseInsensitiveCompare(trimmedName) == .orderedSame)
        }) {
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
        autoSwitchEnabled = true
        apps = Self.defaultApps
    }

    private func persist() {
        userDefaults.set(autoSwitchEnabled, forKey: "\(Self.storageKey).autoSwitch")
        if let data = try? JSONEncoder().encode(apps) {
            userDefaults.set(data, forKey: "\(Self.storageKey).apps")
        }
    }

    private static func loadApps(from userDefaults: UserDefaults, key: String) -> [NativeGamepadApp] {
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NativeGamepadApp].self, from: data) else {
            return defaultApps
        }
        return decoded
    }
}
