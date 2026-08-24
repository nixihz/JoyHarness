import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case general
        case controllerMapping

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                L10n.text("通用", "General")
            case .controllerMapping:
                L10n.text("按键映射", "Key Mapping")
            }
        }

        var systemImage: String {
            switch self {
            case .general:
                "gearshape"
            case .controllerMapping:
                "gamecontroller"
            }
        }
    }

    @Published var selectedTab: Tab = .general

    func select(_ tab: Tab) {
        selectedTab = tab
    }
}
