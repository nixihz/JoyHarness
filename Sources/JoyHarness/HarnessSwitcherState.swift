import AppKit
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

/// What confirming a switcher card does: activate a Harness, or bring up the
/// Joy Harness main window from the trailing card.
enum HarnessSwitcherTarget: Hashable, CustomStringConvertible {
    case harness(HarnessProviderID)
    case mainWindow

    var description: String {
        switch self {
        case let .harness(providerID):
            providerID.rawValue
        case .mainWindow:
            "main-window"
        }
    }
}

struct HarnessSwitcherOption: Identifiable, Equatable {
    let id: HarnessSwitcherTarget
    let displayName: String
    let systemImage: String
    /// The associated app's own icon; `systemImage` is the fallback for
    /// Harnesses without an installed app.
    let applicationIcon: NSImage?
    /// `nil` for the main-window card, which opens Joy Harness itself.
    let applicationStatus: HarnessApplicationStatus?

    /// The line under the name: the app status of a Harness, or the product
    /// whose window the main-window card opens.
    var detail: String {
        applicationStatus?.localizedDescription ?? "Joy Harness"
    }

    init(
        configuration: HarnessProviderConfiguration,
        isApplicationConnected: Bool,
        applicationIcon: NSImage? = nil,
        language: SupportedLanguage = L10n.language
    ) {
        id = .harness(configuration.id)
        displayName = configuration.displayName(language: language)
        systemImage = configuration.systemImage
        self.applicationIcon = applicationIcon
        if isApplicationConnected {
            applicationStatus = .connected
        } else if configuration.hasAssociatedApplication {
            applicationStatus = .notRunning
        } else {
            applicationStatus = .notAssociated
        }
    }

    init(
        id: HarnessProviderID,
        displayName: String,
        systemImage: String,
        applicationIcon: NSImage? = nil,
        isApplicationConnected: Bool
    ) {
        self.id = .harness(id)
        self.displayName = displayName
        self.systemImage = systemImage
        self.applicationIcon = applicationIcon
        applicationStatus = isApplicationConnected ? .connected : .notRunning
    }

    private init(mainWindowIn language: SupportedLanguage, applicationIcon: NSImage?) {
        id = .mainWindow
        displayName = L10n.text("主窗口", "Main Window", language: language)
        systemImage = "macwindow"
        self.applicationIcon = applicationIcon
        applicationStatus = nil
    }

    /// The card that brings up the Joy Harness main window, from which
    /// settings open; it always follows the Harnesses.
    static func mainWindow(
        applicationIcon: NSImage? = nil,
        language: SupportedLanguage = L10n.language
    ) -> HarnessSwitcherOption {
        HarnessSwitcherOption(mainWindowIn: language, applicationIcon: applicationIcon)
    }
}

extension HarnessProviderConfiguration {
    static var defaultApplicationDirectories: [URL] {
        FileManager.default.urls(
            for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask, .systemDomainMask]
        )
    }

    /// Finds the associated app on disk so the switcher can show its real icon
    /// while it is not running. The bundle identifier wins; the configured
    /// name covers apps that were associated by name only.
    func installedApplicationURL(
        urlForBundleIdentifier: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationDirectories: [URL] = HarnessProviderConfiguration.defaultApplicationDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        if let bundleIdentifier = Self.trimmed(bundleIdentifier),
           let url = urlForBundleIdentifier(bundleIdentifier) {
            return url
        }
        guard let appName = Self.trimmed(appName) else { return nil }
        let bundleName = appName.lowercased().hasSuffix(".app") ? appName : "\(appName).app"
        return applicationDirectories
            .map { $0.appendingPathComponent(bundleName, isDirectory: true) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
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
            .flatMap { current in options.firstIndex { $0.id == .harness(current) } }
            ?? options.startIndex
        isPresented = true
    }

    @discardableResult
    func move(_ direction: Int) -> HarnessSwitcherTarget? {
        guard isPresented, !options.isEmpty, direction != 0 else {
            return selectedOption?.id
        }

        let count = options.count
        let offset = direction % count
        selectedIndex = (selectedIndex + offset + count) % count
        return selectedOption?.id
    }

    @discardableResult
    func commit() -> HarnessSwitcherTarget? {
        guard isPresented else { return nil }
        isPresented = false
        return selectedOption?.id
    }

    func cancel() {
        isPresented = false
    }
}
