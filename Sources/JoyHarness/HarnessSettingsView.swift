import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HarnessSettingsPane: View {
    @ObservedObject var settings: HarnessProviderSettings

    var body: some View {
        VStack(spacing: 0) {
            ActiveHarnessPickerBar(settings: settings)

            Divider()

            Form {
                Section {
                    ForEach(settings.providers) { provider in
                        providerRow(provider)
                    }
                } header: {
                    Text(L10n.text("内置 Harness", "Built-in Harnesses"))
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: HarnessProviderConfiguration) -> some View {
        let enableLabel = L10n.text(
            "启用 \(provider.displayName) Harness",
            "Enable \(provider.displayName) Harness"
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle(enableLabel, isOn: enabledBinding(for: provider.id))
                    .labelsHidden()
                    .help(enableLabel)
                    .accessibilityLabel(enableLabel)

                Image(systemName: provider.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if settings.activeProviderID == provider.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help(L10n.text("当前 Harness", "Active Harness"))
                        .accessibilityLabel(L10n.text("当前 Harness", "Active Harness"))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.text("关联应用", "Application"))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)

                    applicationMenu(for: provider)
                }

                GridRow {
                    Color.clear
                        .frame(width: 88, height: 1)

                    Toggle(
                        L10n.text("选择后激活关联应用", "Activate application after selection"),
                        isOn: activationBinding(for: provider.id)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .padding(.leading, 34)
        }
        .padding(.vertical, 3)
    }

    private func applicationMenu(for provider: HarnessProviderConfiguration) -> some View {
        Menu {
            Button {
                browseForApplication(for: provider.id, providerName: provider.displayName)
            } label: {
                Label(L10n.text("浏览应用程序…", "Browse Applications…"), systemImage: "folder")
            }

            if !runningApplications.isEmpty {
                Menu(L10n.text("从运行中的应用选择", "Choose from Running Applications")) {
                    ForEach(runningApplications) { application in
                        Button(application.name) {
                            associate(
                                provider.id,
                                withBundleIdentifier: application.bundleIdentifier,
                                appName: application.name
                            )
                        }
                    }
                }
            }

            if provider.bundleIdentifier != nil || provider.appName != nil {
                Divider()

                Button(L10n.text("清除关联", "Clear Association")) {
                    associate(provider.id, withBundleIdentifier: nil, appName: nil)
                }
            }
        } label: {
            HStack(spacing: 8) {
                AssociatedApplicationIcon(bundleIdentifier: provider.bundleIdentifier)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text(applicationDisplayName(for: provider))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderedButton)
        .frame(maxWidth: .infinity)
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

    private func activationBinding(for id: HarnessProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.provider(for: id)?.activateApplicationOnSelection ?? false },
            set: { shouldActivate in
                settings.configure(id) { provider in
                    provider.activateApplicationOnSelection = shouldActivate
                }
            }
        )
    }

    private func applicationDisplayName(for provider: HarnessProviderConfiguration) -> String {
        if let appName = provider.appName, !appName.isEmpty {
            return appName
        }
        if let bundleIdentifier = provider.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return L10n.text("未关联应用", "No application associated")
    }

    private func associate(
        _ id: HarnessProviderID,
        withBundleIdentifier bundleIdentifier: String?,
        appName: String?
    ) {
        settings.configure(id) { provider in
            provider.bundleIdentifier = bundleIdentifier
            provider.appName = appName
        }
    }

    private func browseForApplication(for id: HarnessProviderID, providerName: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("选择", "Choose")
        panel.message = L10n.text(
            "选择要与 \(providerName) Harness 关联的应用。",
            "Choose the application to associate with the \(providerName) Harness."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        let appName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        associate(id, withBundleIdentifier: bundleIdentifier, appName: appName)
    }

    private struct RunningApplication: Hashable, Identifiable {
        let bundleIdentifier: String?
        let name: String

        var id: String {
            bundleIdentifier ?? "name:\(name)"
        }
    }

    private var runningApplications: [RunningApplication] {
        let applications = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                    $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { application -> RunningApplication? in
                guard let name = application.localizedName, !name.isEmpty else { return nil }
                return RunningApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    name: name
                )
            }
        return Array(Set(applications)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
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
                        _ = settings.requestSelection(id)
                    }
                )
            ) {
                if settings.enabledProviders.isEmpty {
                    Text(L10n.text("没有已启用的 Harness", "No enabled Harnesses"))
                        .tag(nil as HarnessProviderID?)
                }

                ForEach(settings.enabledProviders) { provider in
                    Label(provider.displayName, systemImage: provider.systemImage)
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

private struct AssociatedApplicationIcon: View {
    let bundleIdentifier: String?

    var body: some View {
        if let applicationIcon {
            Image(nsImage: applicationIcon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private var applicationIcon: NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
