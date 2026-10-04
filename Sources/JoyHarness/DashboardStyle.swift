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

    enum Radius {
        /// Glass cards; concentric with the 16 pt window inset.
        static let card: CGFloat = 14
        /// Wells and rows nested inside a card.
        static let inner: CGFloat = 8
        static let keycap: CGFloat = 6
    }

    /// Durations and curves. Built-in easings are too soft for UI feedback, so
    /// release and entry share one strong ease-out curve.
    enum Motion {
        static let keyRelease: Double = 0.12
        static let noticeEnter: Double = 0.2

        static func easeOut(_ duration: Double) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: duration)
        }
    }

    static let cornerRadius: CGFloat = 7
    static let borderWidth: CGFloat = 1
    static let highlightBorderWidth: CGFloat = 2
    static let minimumTarget: CGFloat = 24
    static let emptyIconSize: CGFloat = 40
    static let emptyIconWell: CGFloat = 88
    static let emptyMessageWidth: CGFloat = 420
    static let deviceGlyphSize: CGFloat = 40
    static let toolbarAppIconSize: CGFloat = 16
    static let windowWidth: CGFloat = 744
    static let windowHeight: CGFloat = 600
    static let detailsColumnWidth: CGFloat = 360
    static let stageWidth: CGFloat = 284
    static let readoutHeight: CGFloat = 44
    static let gripPickerWidth: CGFloat = 180
    static let keyWidth: CGFloat = 104
    static let rowHeight: CGFloat = 30
    static let artworkReferenceWidth: CGFloat = 390
    static let highlightFillOpacity: Double = 0.4
    static let activeRowOpacity: Double = 0.14
    static let glassStrokeOpacity: Double = 0.08
    static let noticeTintOpacity: Double = 0.10
    static let ambientGlowOpacity: Double = 0.06

    static let input = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(red: 34 / 255, green: 211 / 255, blue: 238 / 255, alpha: 1)
            : NSColor(red: 8 / 255, green: 117 / 255, blue: 141 / 255, alpha: 1)
    })

    /// Text drawn on an `input` fill: white on the light teal, near-black on the dark cyan.
    static let onInput = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.08, alpha: 1)
            : .white
    })

    /// Soft purple used only for the ambient canvas wash.
    static let brandGlow = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(red: 192 / 255, green: 132 / 255, blue: 252 / 255, alpha: 1)
            : NSColor(red: 147 / 255, green: 51 / 255, blue: 234 / 255, alpha: 1)
    })
}

// MARK: - Surfaces

/// Liquid Glass on macOS 26 and later, a translucent material before it.
/// Increased contrast drops translucency for an opaque, outlined card.
struct DashboardGlassSurface: ViewModifier {
    var tint: Color?
    var cornerRadius: CGFloat = DashboardStyle.Radius.card
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(tint ?? Color.primary, lineWidth: DashboardStyle.borderWidth) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                tint.map { Glass.regular.tint($0.opacity(DashboardStyle.noticeTintOpacity)) } ?? .regular,
                in: shape
            )
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(DashboardStyle.noticeTintOpacity), in: shape)
                .overlay {
                    shape.strokeBorder(
                        (tint ?? .primary).opacity(tint == nil ? DashboardStyle.glassStrokeOpacity : 0.25),
                        lineWidth: DashboardStyle.borderWidth
                    )
                }
        }
    }
}

extension View {
    func dashboardGlass(tint: Color? = nil, cornerRadius: CGFloat = DashboardStyle.Radius.card) -> some View {
        modifier(DashboardGlassSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

/// Window canvas with a faint brand wash so glass has something to refract.
struct DashboardAmbientCanvas: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if contrast != .increased {
                RadialGradient(
                    colors: [DashboardStyle.brandGlow.opacity(DashboardStyle.ambientGlowOpacity), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 520
                )
                RadialGradient(
                    colors: [DashboardStyle.input.opacity(DashboardStyle.ambientGlowOpacity), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 480
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Components

/// A physical input name drawn as a key. Pressing fills it with the input color.
struct DashboardKeycap: View {
    let title: String
    var active = false

    var body: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(active ? DashboardStyle.onInput : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DashboardStyle.Space.small)
            .padding(.vertical, DashboardStyle.Space.tiny / 2)
            .frame(minWidth: DashboardStyle.minimumTarget)
            .background {
                RoundedRectangle(cornerRadius: DashboardStyle.Radius.keycap, style: .continuous)
                    .fill(active ? AnyShapeStyle(DashboardStyle.input) : AnyShapeStyle(.quaternary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.Radius.keycap, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0 : DashboardStyle.glassStrokeOpacity),
                                  lineWidth: DashboardStyle.borderWidth)
            }
    }
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
        .font(.callout)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

enum DashboardNoticeSeverity {
    case info
    case attention
    case blocked

    var color: Color {
        switch self {
        case .info: .accentColor
        case .attention: .orange
        case .blocked: .red
        }
    }
}

/// A status that needs the user's attention: icon, title, explanation and the
/// nearest recovery action in one group.
struct DashboardNotice<Action: View>: View {
    let severity: DashboardNoticeSeverity
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: DashboardStyle.Space.medium) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(severity.color)
                .frame(width: DashboardStyle.minimumTarget)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DashboardStyle.Space.tiny / 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            action().buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, DashboardStyle.Space.medium)
        .padding(.vertical, DashboardStyle.Space.small)
        .dashboardGlass(tint: severity.color)
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
                .help(title)
        } else {
            Button {
                coordinator.select(tab)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            } label: {
                Label(title, systemImage: symbol)
            }
            .help(title)
        }
    }
}
