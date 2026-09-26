import Combine
import Foundation

enum HarnessApplicationStatus: Equatable {
    case connected
    case notRunning
    case notAssociated

    var localizedDescription: String {
        switch self {
        case .connected:
            L10n.text("应用已连接", "App connected")
        case .notRunning:
            L10n.text("应用未运行", "App not running")
        case .notAssociated:
            L10n.text("未关联应用", "No associated app")
        }
    }
}

struct HarnessSwitcherOption: Identifiable, Equatable {
    let id: HarnessProviderID
    let displayName: String
    let systemImage: String
    let applicationStatus: HarnessApplicationStatus

    init(
        configuration: HarnessProviderConfiguration,
        isApplicationConnected: Bool,
        language: SupportedLanguage = L10n.language
    ) {
        id = configuration.id
        displayName = configuration.displayName(language: language)
        systemImage = configuration.systemImage
        if isApplicationConnected {
            applicationStatus = .connected
        } else if configuration.bundleIdentifier != nil || configuration.appName != nil {
            applicationStatus = .notRunning
        } else {
            applicationStatus = .notAssociated
        }
    }

    init(
        id: HarnessProviderID,
        displayName: String,
        systemImage: String,
        isApplicationConnected: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        applicationStatus = isApplicationConnected ? .connected : .notRunning
    }
}

@MainActor
final class HarnessSwitcherState: ObservableObject {
    @Published private(set) var options: [HarnessSwitcherOption] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isPresented = false

    var selectedOption: HarnessSwitcherOption? {
        guard options.indices.contains(selectedIndex) else { return nil }
        return options[selectedIndex]
    }

    func present(options: [HarnessSwitcherOption], current: HarnessProviderID?) {
        self.options = options
        selectedIndex = current
            .flatMap { current in options.firstIndex { $0.id == current } }
            ?? options.startIndex
        isPresented = true
    }

    @discardableResult
    func move(_ direction: Int) -> HarnessProviderID? {
        guard isPresented, !options.isEmpty, direction != 0 else {
            return selectedOption?.id
        }

        let count = options.count
        let offset = direction % count
        selectedIndex = (selectedIndex + offset + count) % count
        return selectedOption?.id
    }

    @discardableResult
    func commit() -> HarnessProviderID? {
        guard isPresented else { return nil }
        isPresented = false
        return selectedOption?.id
    }

    func cancel() {
        isPresented = false
    }
}
