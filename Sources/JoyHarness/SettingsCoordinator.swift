import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case general
        case controllerMapping
        case nativeMode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                L10n.text("通用", "General")
            case .controllerMapping:
                L10n.text("按键映射", "Key Mapping")
            case .nativeMode:
                L10n.text("原生模式", "Native Mode")
            }
        }

        var systemImage: String {
            switch self {
            case .general:
                "gearshape"
            case .controllerMapping:
                "slider.horizontal.3"
            case .nativeMode:
                "gamecontroller.fill"
            }
        }
    }

    @Published var selectedTab: Tab = .general

    func select(_ tab: Tab) {
        selectedTab = tab
    }
}
