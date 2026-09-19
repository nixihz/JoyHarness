import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var mappingStore: ControllerMappingStore
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings
    @ObservedObject var pointerSensitivitySettings: PointerSensitivitySettings
    @ObservedObject var nativeModeSettings: NativeGamepadAppSettings
    @ObservedObject var settingsCoordinator: SettingsCoordinator
    @ObservedObject var slotShortcutSettings: SlotShortcutSettings

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsCoordinator.Tab.allCases, selection: $settingsCoordinator.selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(.gray)
            .accentColor(.gray)
            .frame(width: 170)
            .background(.ultraThinMaterial)

            Divider()

            switch settingsCoordinator.selectedTab {
            case .general:
                GeneralSettingsView(
                    languageSettings: languageSettings,
                    launchAtLogin: launchAtLogin,
                    scrollDirectionSettings: scrollDirectionSettings,
                    pointerSensitivitySettings: pointerSensitivitySettings
                )
            case .controllerMapping:
                ControllerMappingSettingsPane(store: mappingStore)
            case .slotShortcuts:
                SlotShortcutSettingsPane(settings: slotShortcutSettings)
            case .nativeMode:
                NativeModeSettingsPane(settings: nativeModeSettings)
            }
        }
        .frame(width: 620, height: 640)
    }
}

private struct GeneralSettingsView: View {
    @State private var remoteVoiceMessage: String?
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings
    @ObservedObject var pointerSensitivitySettings: PointerSensitivitySettings

    var body: some View {
        Form {
            Section(L10n.text("遥控器麦克风", "Remote Microphone")) {
                Text(L10n.text(
                    "使用 RC003-MS 内置麦克风说话。首次使用时启用 Joy Harness 自带的麦克风组件，之后选择为语音输入。只在按住语音键时接收，不保存录音。",
                    "Use the RC003-MS built-in microphone. Enable the microphone component included with Joy Harness, then select it as your voice input. Audio is received while the voice key is held and is not saved."
                ))
                .font(.caption)
                Button(L10n.text("使用遥控器作为系统麦克风", "Use Remote as System Microphone")) {
                    do {
                        try RemoteMicrophoneOutput.selectAsDefaultInput()
                        remoteVoiceMessage = L10n.text("已选择 Joy Harness 遥控器麦克风；请在语音应用中使用系统默认输入。", "Selected Joy Harness Remote Microphone; use the system default input in your voice app.")
                    } catch { remoteVoiceMessage = error.localizedDescription }
                }
                Text(remoteVoiceMessage ?? (RemoteMicrophoneOutput.installed
                    ? L10n.text("这会切换系统默认输入；可在系统声音设置中切回其他麦克风。", "This changes the default input. Switch back in System Sound settings.")
                    : L10n.text("麦克风组件尚未启用；首次安装需要管理员验证。", "Enable the microphone component first; installation requires administrator authentication.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.text("启用 Joy Harness 麦克风组件", "Enable Joy Harness Microphone")) {
                    guard let installer = Bundle.main.url(forResource: "JoyHarnessMicrophone", withExtension: "pkg") else {
                        remoteVoiceMessage = L10n.text("当前构建缺少麦克风组件，请重新构建应用。", "This build is missing its microphone component. Rebuild the app.")
                        return
                    }
                    NSWorkspace.shared.open(installer)
                }
            }

            Section(L10n.text("当前应用", "Current App")) {
                LabeledContent(L10n.text("版本", "Version"), value: AppVersion.current)
                Text(Bundle.main.bundleURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                Button(L10n.text("在 Finder 中显示当前应用", "Show Current App in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Text(L10n.text(
                    "系统设置中的辅助功能和输入监控权限，请授权给这个应用。",
                    "Grant Accessibility and Input Monitoring to this app in System Settings."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
                sensitivityRow(
                    L10n.text("普通", "Normal"),
                    value: $pointerSensitivitySettings.normal
                )
                sensitivityRow(
                    L10n.text("快速", "Fast"),
                    value: $pointerSensitivitySettings.fast
                )
                sensitivityRow(
                    L10n.text("慢速", "Slow"),
                    value: $pointerSensitivitySettings.slow
                )

                HStack {
                    Text(L10n.text(
                        "普通用于左摇杆，快速用于加速模式，慢速用于精细模式和触控板。",
                        "Normal applies to the left stick, Fast to boost mode, and Slow to precision mode and the touchpad."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button {
                        pointerSensitivitySettings.resetDefaults()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("恢复默认灵敏度", "Restore Default Sensitivity"))
                }
            } header: {
                Text(L10n.text("鼠标灵敏度", "Pointer Sensitivity"))
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

    private func sensitivityRow(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(
                    value: value,
                    in: PointerSensitivitySettings.allowedRange,
                    step: PointerSensitivitySettings.step
                )
                .frame(width: 180)

                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
