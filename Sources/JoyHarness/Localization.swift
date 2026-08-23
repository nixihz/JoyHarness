import Combine
import Foundation

enum SupportedLanguage: String, Equatable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
}

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: Self { self }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> SupportedLanguage {
        switch self {
        case .system:
            let preferred = preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        }
    }

    var displayName: String {
        switch self {
        case .system: L10n.text("跟随系统", "System Default")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

final class AppLanguageSettings: ObservableObject {
    static let storageKey = "appLanguagePreference"

    @Published var preference: AppLanguagePreference {
        didSet {
            userDefaults.set(preference.rawValue, forKey: Self.storageKey)
            if updatesLocalizer {
                L10n.language = preference.resolved()
            }
        }
    }

    var locale: Locale {
        Locale(identifier: preference.resolved().rawValue)
    }

    private let userDefaults: UserDefaults
    private let updatesLocalizer: Bool

    init(userDefaults: UserDefaults = .standard, updatesLocalizer: Bool = true) {
        self.userDefaults = userDefaults
        self.updatesLocalizer = updatesLocalizer
        let storedPreference = userDefaults.string(forKey: Self.storageKey)
            .flatMap(AppLanguagePreference.init(rawValue:))
        preference = storedPreference ?? .system
        if updatesLocalizer {
            L10n.language = preference.resolved()
        }
    }
}

enum L10n {
    static var language = AppLanguagePreference.system.resolved()

    static func text(
        _ simplifiedChinese: String,
        _ english: String,
        language: SupportedLanguage = language
    ) -> String {
        language == .simplifiedChinese ? simplifiedChinese : english
    }
}
