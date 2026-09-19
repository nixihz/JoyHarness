import AppKit
import SwiftUI

// Primitive values belong here; views consume the semantic/component aliases below.
enum DashboardStyle {
    enum Space {
        static let tiny: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let inset: CGFloat = 16
        static let section: CGFloat = 22
        static let page: CGFloat = 32
    }
    static let cornerRadius: CGFloat = 7
    static let keyRelease: Double = 0.12
    static let borderWidth: CGFloat = 1
    static let highlightBorderWidth: CGFloat = 2
    static let minimumTarget: CGFloat = 24
    static let iconSize: CGFloat = 18
    static let emptyIconSize: CGFloat = 64
    static let windowMinimumWidth: CGFloat = 620
    static let windowWidth: CGFloat = 744
    static let windowMinimumHeight: CGFloat = 520
    static let windowHeight: CGFloat = 600
    static let compactBreakpoint: CGFloat = 700
    static let artworkWidth: CGFloat = 320
    static let artworkHeight: CGFloat = 220
    static let mappingHeight: CGFloat = 240
    static let feedbackHeight: CGFloat = 48
    static let gripPickerWidth: CGFloat = 180
    static let keyWidth: CGFloat = 116
    static let artworkReferenceWidth: CGFloat = 390
    static let highlightFillOpacity: Double = 0.4

    static let input = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(red: 34 / 255, green: 211 / 255, blue: 238 / 255, alpha: 1)
            : NSColor(red: 8 / 255, green: 117 / 255, blue: 141 / 255, alpha: 1)
    })
}

struct DashboardBadge: View {
    let title: String
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

enum DashboardSystemSettings {
    enum Destination: String {
        case bluetooth = "com.apple.BluetoothSettings"
        case accessibility = "com.apple.preference.security?Privacy_Accessibility"
        case inputMonitoring = "com.apple.preference.security?Privacy_ListenEvent"
        case sound = "com.apple.Sound-Settings.extension?input"
    }

    static func open(_ destination: Destination) {
        guard let url = URL(string: "x-apple.systempreferences:" + destination.rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DashboardSettingsButton: View {
    @EnvironmentObject private var coordinator: SettingsCoordinator
    var tab: SettingsCoordinator.Tab = .controllerMapping

    private var title: String {
        tab == .controllerMapping ? L10n.text("配置按键", "Configure Buttons") : tab == .nativeMode ? L10n.text("原生模式设置", "Native Mode Settings") : L10n.settingsTitle()
    }
    private var symbol: String { tab == .controllerMapping ? "slider.horizontal.3" : "gearshape" }

    var body: some View {
        if #available(macOS 14.0, *) {
            OpenSettingsButton(tab: tab) { Label(title, systemImage: symbol) }
        } else {
            Button {
                coordinator.select(tab)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            } label: {
                Label(title, systemImage: symbol)
            }
        }
    }
}
