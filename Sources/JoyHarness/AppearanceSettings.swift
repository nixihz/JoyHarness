import AppKit
import Combine
import Foundation

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:
            L10n.text("跟随系统", "System")
        case .light:
            L10n.text("日间", "Light")
        case .dark:
            L10n.text("夜间", "Dark")
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let storageKey = "appearancePreference"

    @Published var preference: AppAppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            userDefaults.set(preference.rawValue, forKey: Self.storageKey)
            applyAppearance(preference)
        }
    }

    private let userDefaults: UserDefaults
    private let applyAppearance: @MainActor (AppAppearancePreference) -> Void

    init(
        userDefaults: UserDefaults = .standard,
        applyAppearance: @escaping @MainActor (AppAppearancePreference) -> Void = ApplicationAppearanceBridge.apply
    ) {
        self.userDefaults = userDefaults
        self.applyAppearance = applyAppearance
        let stored = userDefaults.string(forKey: Self.storageKey)
            .flatMap(AppAppearancePreference.init(rawValue:))
        preference = stored ?? .system
        applyAppearance(preference)
    }
}

@MainActor
private enum ApplicationAppearanceBridge {
    static func apply(_ preference: AppAppearancePreference) {
        let appearance = preference.appearanceName.flatMap(NSAppearance.init(named:))
        NSApplication.shared.appearance = appearance
    }
}
