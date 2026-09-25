import AppKit
import SwiftUI
import Testing
@testable import JoyHarness

// Explicit opt-in visual audit. Fixtures never enter the app or the user's defaults.
@Suite(.serialized)
struct DashboardRenderingTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DASHBOARD_RENDER_DIR"] != nil))
    func renderDeviceMatrix() throws {
        guard let output = ProcessInfo.processInfo.environment["DASHBOARD_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "dashboard-render-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousLanguage = L10n.language
        defer { L10n.language = previousLanguage }
        let language = AppLanguageSettings(userDefaults: defaults, updatesLocalizer: false)
        let coordinator = SettingsCoordinator()
        let families: [ControllerFamily] = [.xiaomiRemote, .dualSense, .dualShock, .xbox, .joyConLeft, .joyConRight, .joyConPair, .generic, .generic, .generic]
        for (index, family) in families.enumerated() {
            for compact in [false, true] {
                L10n.language = compact ? .english : .simplifiedChinese
                let mapping = ControllerMappingStore(userDefaults: defaults)
                mapping.setControllerFamily(family)
                mapping.setJoyConOrientation(compact ? .vertical : .horizontal)
                // Several connected devices show the header device switcher;
                // four devices exercise its narrower fallbacks.
                if index == 0 || index == 4 {
                    let shown = ConnectedControllerDescriptor(
                        id: "shown", name: "", family: family,
                        source: family == .xiaomiRemote ? .xiaomiRemote : .gameController
                    )
                    let dualSense = ConnectedControllerDescriptor(
                        id: "dualsense", name: "DualSense Wireless Controller", family: .dualSense, source: .gameController
                    )
                    let xboxes = index == 4 ? ["xbox-a", "xbox-b"].map {
                        ConnectedControllerDescriptor(id: $0, name: "Xbox Wireless Controller", family: .xbox, source: .gameController)
                    } : []
                    mapping.setConnectedDevices([shown, dualSense] + xboxes)
                    mapping.setDisplayedDevice(shown.id)
                    // Settings configures another device; the Dashboard must
                    // still show the displayed device's artwork and mappings.
                    mapping.selectConnectedDevice(dualSense.id)
                }
                let statusURL = directory.appendingPathComponent("fixture.json")
                var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(DashboardStatus.empty)) as? [String: Any])
                json["controller"] = family.displayName
                json["controller_family"] = family.rawValue
                json["controller_connected"] = true
                json["accessibility"] = true
                json["input_monitoring"] = index != 7
                json["rp2040"] = true
                json["haptics"] = family != .xiaomiRemote
                json["ts"] = ISO8601DateFormatter().string(from: Date())
                json["controller_battery_level"] = 0.72
                json["operation_mode"] = index == 3 ? "native" : "mapping"
                json["default_voice_input"] = "MacBook Pro Microphone"
                if family.isJoyCon {
                    json["joycon_mode"] = family.joyConMode?.rawValue
                    json["joycon_left_connected"] = family != .joyConRight
                    json["joycon_right_connected"] = family != .joyConLeft
                }
                if index >= 8 {
                    json["controller_connected"] = false
                    json["controller"] = "none"
                    json["rp2040"] = false
                    json["haptics"] = false
                    if index == 9 { json["ts"] = "2020-01-01T00:00:00Z" }
                }
                try JSONSerialization.data(withJSONObject: json).write(to: statusURL)
                let store = DashboardStore(statusURL: statusURL)
                store.setControllerInput(.buttonA, pressed: true)
                let showsDetails = compact && index == 0
                let size = NSSize(
                    width: DashboardStyle.windowWidth + (showsDetails ? DashboardStyle.detailsColumnWidth + 1 : 0),
                    height: DashboardStyle.windowHeight
                )
                let view = DashboardView(store: store, mappingStore: mapping, detailsPresented: showsDetails)
                    .environmentObject(language).environmentObject(coordinator)
                    .environment(\.colorScheme, compact ? .dark : .light)
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = NSAppearance(named: compact ? .accessibilityHighContrastDarkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = showsDetails ? "xiaomi-remote-details" : index == 7 ? "input-monitoring-required" : index == 8 ? "disconnected" : index == 9 ? "stale" : family.rawValue
                try png.write(to: directory.appendingPathComponent("\(name)-\(compact ? "compact-dark-en" : "wide-light-zh").png"))
            }
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("fixture.json"))
    }
}
