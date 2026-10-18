import Combine
import Foundation

@MainActor
final class SettingsCoordinator: ObservableObject {
    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case general
        case harness
        case controllerMapping
        case slotShortcuts
        case nativeMode
        case aiVoice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                L10n.text("通用", "General")
            case .harness:
                "Harness"
            case .controllerMapping:
                L10n.text("按键映射", "Key Mapping")
            case .slotShortcuts:
                L10n.text("槽位快捷键", "Slot Shortcuts")
            case .nativeMode:
                L10n.text("原生模式", "Native Mode")
            case .aiVoice:
                L10n.text("AI 语音", "AI Voice")
            }
        }

        var systemImage: String {
            switch self {
            case .general:
                "gearshape"
            case .harness:
                "square.grid.2x2"
            case .controllerMapping:
                "slider.horizontal.3"
            case .slotShortcuts:
                "keyboard"
            case .nativeMode:
                "gamecontroller.fill"
            case .aiVoice:
                "mic.fill"
            }
        }
    }

    @Published var selectedTab: Tab = .general

    func select(_ tab: Tab) {
        selectedTab = tab
    }
}
