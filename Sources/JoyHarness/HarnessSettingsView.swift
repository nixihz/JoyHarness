import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HarnessSettingsPane: View {
    @ObservedObject var settings: HarnessProviderSettings
    @State private var removalCandidate: HarnessProviderConfiguration?
    @State private var addedProviderID: HarnessProviderID?
    @State private var runningApplications: [ApplicationPresentation.RunningApplication] = []

    private static let iconSize: CGFloat = 32
    private static let menuIconSize: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ActiveHarnessPickerBar(settings: settings)

            Divider()

            HStack(spacing: 12) {
                Text(L10n.text(
                    "添加应用，为它配置独立的按键映射。",
                    "Add an application to customize its own key mappings."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)
                addApplicationMenu(runningApplications: runningApplications)
            }
            .padding(16)

            ScrollViewReader { proxy in
                Form {
                    ForEach(settings.providers) { provider in
                        Section {
                            providerHeader(provider, runningApplications: runningApplications)

                            if !provider.id.isBuiltIn {
                                Button(L10n.text("移除应用…", "Remove Application…"), role: .destructive) {
                                    removalCandidate = provider
                                }
                            }
                        } footer: {
                            if provider.id == settings.providers.last?.id {
                                Text(L10n.text(
                                    "停用的 Harness 不会出现在切换器中。",
                                    "Disabled Harnesses do not appear in the switcher."
                                ))
                            }
                        }
                        .id(provider.id)
                    }
                }
                .formStyle(.grouped)
                .onChange(of: addedProviderID) { id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .top)
                    addedProviderID = nil
                }
            }
        }
        .onAppear(perform: refreshRunningApplications)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApplications()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshRunningApplications()
        }
        .confirmationDialog(
            L10n.text("移除应用？", "Remove application?"),
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { provider in
            Button(L10n.text("移除应用", "Remove Application"), role: .destructive) {
                settings.removeApplication(provider.id)
                removalCandidate = nil
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {
                removalCandidate = nil
            }
        } message: { provider in
            Text(L10n.text(
                "将从 Harness 列表和切换器中移除 \(provider.displayName)。重新添加时使用默认映射；应用本身不会被卸载。",
                "Remove \(provider.displayName) from the Harness list and switcher. Adding it again starts with default mappings. The application stays installed."
            ))
        }
    }

    private func refreshRunningApplications() {
        runningApplications = ApplicationPresentation.runningApplications()
    }

    private func addApplicationMenu(
        runningApplications: [ApplicationPresentation.RunningApplication]
    ) -> some View {
        Menu {
            Button {
                browseForApplication()
            } label: {
                Label(L10n.text("浏览应用程序…", "Browse Applications…"), systemImage: "folder")
            }

            if !runningApplications.isEmpty {
                Menu(L10n.text("从运行中的应用选择", "Choose from Running Applications")) {
                    ForEach(runningApplications) { application in
                        Button {
                            addedProviderID = settings.addApplication(
                                bundleIdentifier: application.bundleIdentifier,
                                appName: application.name,
                                applicationPath: application.url?.path
                            )
                        } label: {
                            runningApplicationLabel(application)
                        }
                    }
                }
            }
        } label: {
            Label(L10n.text("添加应用", "Add Application"), systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private func providerHeader(
        _ provider: HarnessProviderConfiguration,
        runningApplications: [ApplicationPresentation.RunningApplication]
    ) -> some View {
        let enableLabel = L10n.text(
            "启用 \(provider.displayName) Harness",
            "Enable \(provider.displayName) Harness"
        )
        return HStack(spacing: 12) {
            Image(nsImage: ApplicationPresentation.icon(
                forApplicationAt: provider.installedApplicationURL(),
                size: Self.iconSize
            ))
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
            .opacity(provider.isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.headline)
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if settings.activeProviderID == provider.id {
                        activeBadge
                    }
                }

                statusLabel(for: provider, runningApplications: runningApplications)
            }

            Spacer(minLength: 8)

            Toggle(enableLabel, isOn: enabledBinding(for: provider.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(enableLabel)
                .accessibilityLabel(enableLabel)
        }
    }

    private var activeBadge: some View {
        Text(L10n.text("当前", "Active"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
            .help(L10n.text("当前 Harness", "Active Harness"))
            .accessibilityLabel(L10n.text("当前 Harness", "Active Harness"))
    }

    private func statusLabel(
        for provider: HarnessProviderConfiguration,
        runningApplications: [ApplicationPresentation.RunningApplication]
    ) -> some View {
        let symbol: String
        let color: Color
        let text: String
        if !provider.isEnabled {
            (symbol, color, text) = ("minus.circle", .secondary, L10n.text("已停用", "Disabled"))
        } else {
            let status = provider.applicationStatus(runningApplications: runningApplications)
            text = status.localizedDescription
            switch status {
            case .connected:
                (symbol, color) = ("checkmark.circle.fill", .green)
            case .notRunning:
                (symbol, color) = ("pause.circle", .secondary)
            case .notAssociated:
                (symbol, color) = ("exclamationmark.triangle.fill", .orange)
            }
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func runningApplicationLabel(_ application: ApplicationPresentation.RunningApplication) -> some View {
        Label {
            Text(application.name)
        } icon: {
            Image(nsImage: ApplicationPresentation.icon(
                forApplicationAt: application.url,
                size: Self.menuIconSize
            ))
        }
    }

    private func enabledBinding(for id: HarnessProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.provider(for: id)?.isEnabled ?? false },
            set: { isEnabled in
                settings.configure(id) { provider in
                    provider.isEnabled = isEnabled
                }
            }
        )
    }

    private func browseForApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("添加", "Add")
        panel.message = L10n.text(
            "选择要添加到 Harness 的应用。添加后可配置独立的按键映射。",
            "Choose an application to add to Harness and customize its key mappings."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        addedProviderID = settings.addApplication(
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
            appName: ApplicationPresentation.name(forApplicationAt: url),
            applicationPath: url.path
        )
    }
}

struct ActiveHarnessPickerBar: View {
    @ObservedObject var settings: HarnessProviderSettings

    var body: some View {
        HStack(spacing: 12) {
            Label(L10n.text("当前 Harness", "Active Harness"), systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Picker(
                L10n.text("当前 Harness", "Active Harness"),
                selection: Binding(
                    get: { settings.activeProviderID },
                    set: { id in
                        guard let id else { return }
                        _ = settings.select(id)
                    }
                )
            ) {
                if settings.enabledProviders.isEmpty {
                    Text(L10n.text("没有已启用的 Harness", "No enabled Harnesses"))
                        .tag(nil as HarnessProviderID?)
                }

                ForEach(settings.enabledProviders) { provider in
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        Image(nsImage: ApplicationPresentation.icon(
                            forApplicationAt: provider.installedApplicationURL(),
                            size: 16
                        ))
                    }
                    .tag(Optional(provider.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 150, maxWidth: 230)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
