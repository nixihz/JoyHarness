import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    let tab: SettingsCoordinator.Tab
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            settingsCoordinator.select(tab)
            openSettings()
        } label: {
            label()
        }
    }
}

@available(macOS 14.0, *)
struct OpenSettingsLink: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    let tab: SettingsCoordinator.Tab
    let title: String

    var body: some View {
        Button {
            settingsCoordinator.select(tab)
            openSettings()
        } label: {
            Label(title, systemImage: "gearshape")
        }
        .buttonStyle(.link)
    }
}
