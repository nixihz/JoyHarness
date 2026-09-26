import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates = false

    let isAvailable: Bool
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        isAvailable = info["JoyHarnessUpdaterEnabled"] as? Bool == true
            && (info["SUFeedURL"] as? String)?.isEmpty == false
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false
    }

    func start() {
        guard isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        refresh()
    }

    func refresh() {
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
