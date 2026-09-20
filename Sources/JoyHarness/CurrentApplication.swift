import AppKit

enum CurrentApplication {
    static var bundleURL: URL { Bundle.main.bundleURL }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }
}
