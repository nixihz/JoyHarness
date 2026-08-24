import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus = .disabled
    @Published private(set) var statusMessage: String?

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    init() {
        refresh()
    }

    func refresh() {
        statusMessage = nil
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .requiresApproval
            case .notRegistered, .notFound:
                status = .disabled
            @unknown default:
                status = .disabled
            }
            return
        }
        status = .unavailable(
            L10n.text("需要 macOS 13 或更高版本", "Requires macOS 13 or later")
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            status = .unavailable(
                L10n.text("需要 macOS 13 或更高版本", "Requires macOS 13 or later")
            )
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = error.localizedDescription
        }
    }
}
