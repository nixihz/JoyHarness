import Combine
import Foundation

enum ScrollDirectionPreference: String, CaseIterable, Identifiable, Codable {
    case natural
    case traditional

    var id: Self { self }

    var displayName: String {
        switch self {
        case .natural:
            L10n.text("自然滚动", "Natural Scrolling")
        case .traditional:
            L10n.text("传统滚动", "Traditional Scrolling")
        }
    }

    var detailText: String {
        switch self {
        case .natural:
            L10n.text(
                "内容跟随摇杆移动，类似 Mac 触控板默认方向。",
                "Content follows the stick, like the default Mac trackpad direction."
            )
        case .traditional:
            L10n.text(
                "类似 Windows 鼠标滚轮方向，与自然滚动相反。",
                "Like a classic Windows mouse wheel, opposite of natural scrolling."
            )
        }
    }
}

final class ScrollDirectionSettings: ObservableObject {
    static let storageKey = "scrollDirectionPreference"

    @Published var preference: ScrollDirectionPreference {
        didSet {
            guard preference != oldValue else { return }
            userDefaults.set(preference.rawValue, forKey: Self.storageKey)
            onChange?(preference)
        }
    }

    var onChange: ((ScrollDirectionPreference) -> Void)?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.string(forKey: Self.storageKey)
            .flatMap(ScrollDirectionPreference.init(rawValue:))
        preference = stored ?? .traditional
    }
}
