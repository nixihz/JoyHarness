import AppKit
import SwiftUI

/// The Dashboard window. Joy Harness keeps running after it closes, so the
/// Dock icon and the Harness switcher must be able to bring it back.
@MainActor
enum MainWindow {
    static let id = "main"
    static let title = "Joy Harness"

    /// The open Dashboard window, minimized or not. A closed SwiftUI window
    /// can linger in `NSApp.windows` after its content is gone, so it does
    /// not count; the Settings window and the switcher panel have other titles.
    static func find(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.title == title && ($0.isVisible || $0.isMiniaturized) }
    }

    static func applyChrome(to window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
    }
}

extension View {
    /// Styles the Dashboard window whenever SwiftUI creates it: at launch and
    /// each time it is reopened after being closed. SwiftUI reapplies its own
    /// titlebar appearance on every scene phase change, such as a minimize,
    /// so the transparent titlebar is declared to it as well.
    func mainWindowChrome() -> some View {
        toolbarBackground(.hidden, for: .windowToolbar)
            .background(MainWindowChromeView())
    }

    /// Hands this scene's `openWindow` action to AppKit code, such as the
    /// Harness switcher and Dock reopen, that has no SwiftUI environment.
    func exposeOpenMainWindow(to install: @escaping (@escaping () -> Void) -> Void) -> some View {
        background(OpenMainWindowCapture(install: install))
    }
}

private struct MainWindowChromeView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowAttachmentView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowAttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainWindow.applyChrome(to: window)
        }
    }
}

private struct OpenMainWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    let install: (@escaping () -> Void) -> Void

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear {
                let openWindow = openWindow
                install { openWindow(id: MainWindow.id) }
            }
    }
}
