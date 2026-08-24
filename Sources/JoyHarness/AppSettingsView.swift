import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var mappingStore: ControllerMappingStore
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings
    @ObservedObject var settingsCoordinator: SettingsCoordinator

    var body: some View {
        NavigationSplitView {
            List(SettingsCoordinator.Tab.allCases, selection: $settingsCoordinator.selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            switch settingsCoordinator.selectedTab {
            case .general:
                GeneralSettingsView(
                    languageSettings: languageSettings,
                    launchAtLogin: launchAtLogin,
                    scrollDirectionSettings: scrollDirectionSettings
                )
            case .controllerMapping:
                ControllerMappingSettingsPane(store: mappingStore)
            }
        }
        .frame(width: 620, height: 640)
        .navigationTitle(L10n.text("设置", "Settings"))
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings

    var body: some View {
        Form {
            Section(L10n.text("通用", "General")) {
                Toggle(
                    L10n.text("登录时启动 Joy Harness", "Launch Joy Harness at Login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .disabled(isLaunchAtLoginUnavailable)

                Text(L10n.text(
                    "登录 Mac 后自动打开应用。关闭窗口不会退出，可从程序坞重新打开。",
                    "Open the app automatically after you sign in. Closing the window does not quit the app; reopen it from the Dock."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if case .requiresApproval = launchAtLogin.status {
                    Text(L10n.text(
                        "登录项已注册，但可能需要在系统设置中批准。",
                        "The login item is registered but may need approval in System Settings."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if case .unavailable(let message) = launchAtLogin.status, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let statusMessage = launchAtLogin.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(L10n.text(
                    "使用标准登录项，不会注册系统级 KeepAlive。",
                    "Uses the standard login item and does not register a system-level KeepAlive service."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    L10n.text("滚动方向", "Scroll Direction"),
                    selection: $scrollDirectionSettings.preference
                ) {
                    ForEach(ScrollDirectionPreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)

                Text(scrollDirectionSettings.preference.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(L10n.text(
                    "用于 LT / L2 + 左摇杆滚动网页或文档。可随时切换。",
                    "Applies to LT / L2 + left stick scrolling in browsers and documents. You can change it anytime."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.text("滚动", "Scrolling"))
            }

            Section(L10n.text("语言", "Language")) {
                Picker(
                    L10n.text("应用语言", "App Language"),
                    selection: $languageSettings.preference
                ) {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)

                Text(L10n.text(
                    "跟随系统时，中文系统使用简体中文，其他语言使用 English。",
                    "System Default uses Simplified Chinese for Chinese systems and English otherwise."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("通用", "General"))
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    private var isLaunchAtLoginUnavailable: Bool {
        if case .unavailable = launchAtLogin.status {
            return true
        }
        return false
    }
}
