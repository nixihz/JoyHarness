import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var mappingStore: ControllerMappingStore
    @ObservedObject var appearanceSettings: AppearanceSettings
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var updater: AppUpdater
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings
    @ObservedObject var pointerSensitivitySettings: PointerSensitivitySettings
    @ObservedObject var motionJump: MotionJumpCoordinator
    @ObservedObject var nativeModeSettings: NativeGamepadAppSettings
    @ObservedObject var harnessProviderSettings: HarnessProviderSettings
    @ObservedObject var settingsCoordinator: SettingsCoordinator
    @ObservedObject var slotShortcutSettings: SlotShortcutSettings
    @ObservedObject var edgeLightSettings: EdgeLightSettings
    @ObservedObject var aiVoiceSettings: AIVoiceSettings
    @ObservedObject var aiVoiceSession: AIVoiceSession
    var aiVoiceInputIssue: () -> String?
    @ObservedObject var dualSenseMicrophone: DualSenseMicrophoneSession

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
                    appearanceSettings: appearanceSettings,
                    languageSettings: languageSettings,
                    launchAtLogin: launchAtLogin,
                    updater: updater,
                    scrollDirectionSettings: scrollDirectionSettings,
                    pointerSensitivitySettings: pointerSensitivitySettings,
                    motionJump: motionJump,
                    edgeLightSettings: edgeLightSettings,
                    dualSenseMicrophone: dualSenseMicrophone
                )
            case .harness:
                HarnessSettingsPane(settings: harnessProviderSettings)
            case .controllerMapping:
                ControllerMappingSettingsPane(
                    store: mappingStore,
                    harnessProviderSettings: harnessProviderSettings
                )
            case .slotShortcuts:
                SlotShortcutSettingsPane(settings: slotShortcutSettings)
            case .nativeMode:
                NativeModeSettingsPane(settings: nativeModeSettings)
            case .aiVoice:
                AIVoiceSettingsPane(settings: aiVoiceSettings, session: aiVoiceSession, inputIssue: aiVoiceInputIssue)
            }
        }
        .frame(width: 620, height: 640)
    }
}

private struct GeneralSettingsView: View {
    @State private var remoteVoiceMessage: String?
    @State private var installingMicrophone = false
    @State private var remoteComponentInstalled = false
    @State private var remoteComponentNeedsUpdate = false
    @ObservedObject var appearanceSettings: AppearanceSettings
    @ObservedObject var languageSettings: AppLanguageSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var updater: AppUpdater
    @ObservedObject var scrollDirectionSettings: ScrollDirectionSettings
    @ObservedObject var pointerSensitivitySettings: PointerSensitivitySettings
    @ObservedObject var motionJump: MotionJumpCoordinator
    @ObservedObject var edgeLightSettings: EdgeLightSettings
    @ObservedObject var dualSenseMicrophone: DualSenseMicrophoneSession

    var body: some View {
        Form {
            Section(L10n.text("屏幕状态灯", "Screen Status Lights")) {
                Toggle(L10n.text("显示 Codex 光缝", "Show Codex Edge Lights"), isOn: $edgeLightSettings.isEnabled)
                LabeledContent(L10n.text("灯光亮度", "Light Brightness")) {
                    HStack(spacing: 10) {
                        Slider(value: $edgeLightSettings.brightness, in: EdgeLightSettings.brightnessRange, step: 0.05)
                            .frame(width: 180)
                            .accessibilityLabel(L10n.text("灯光亮度", "Light Brightness"))
                        Text(edgeLightSettings.brightness.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!edgeLightSettings.isEnabled)
                Picker(L10n.text("完成特效", "Completion Effect"), selection: $edgeLightSettings.completionEffect) {
                    ForEach(EdgeLightCompletionEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                .disabled(!edgeLightSettings.isEnabled)
                Button(L10n.text("预览特效", "Preview Effect")) { edgeLightSettings.onPreview?() }
                    .disabled(!edgeLightSettings.isEnabled || edgeLightSettings.placement.edge != .top)
                Text(L10n.text("特效仅在顶部播放；点击灯条或会话已读会收起。预览无需连接设备；随机特效每次从四种动画中选择一种。", "Effects play at the top edge. Click the light or read the conversation to dismiss. Preview works without a device; Random Effect chooses one of the four animations each time."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("六个状态灯贴在屏幕边缘。移入鼠标显示编号，拖动到任意一边，点击打开对应任务。", "Six status lights at the screen edge. Hover for numbers, drag to any edge, and click to open the task."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("蓝色：运行中 · 绿色跳动：完成未读 · 白色：空闲／已读\n橙色：等待回应或批准 · 红色：错误 · 熄灭：未分配\n顶部新完成时播放所选特效。", "Blue: working · Green bounce: complete, unread · White: idle / read\nOrange: waiting for input or approval · Red: error · Off: unassigned\nNew completion at the top edge plays the selected effect."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(edgeLightSettings.isMicroSynchronized
                     ? L10n.text("已同步 Micro 键盘的 1–6 槽位和颜色。", "Synced with Micro keyboard slots 1–6 and colors.")
                     : L10n.text("尚未同步：请连接已更新固件的 Joy Harness RP2040。虚线表示未知状态。", "Not synced: connect Joy Harness RP2040 with updated firmware. Dashed lights indicate unknown status."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DualSenseAudioSettingsSection()
            Section(L10n.text("遥控器麦克风", "Remote Microphone")) {
                Text(L10n.text(
                    "使用 RC003-MS 内置麦克风说话。首次使用时启用 Joy Harness 自带的麦克风组件，之后选择为语音输入。只在按住语音键时接收，不保存录音。",
                    "Use the RC003-MS built-in microphone. Enable the microphone component included with Joy Harness, then select it as your voice input. Audio is received while the voice key is held and is not saved."
                ))
                .font(.caption)
                Button(L10n.text("检查麦克风权限", "Check Microphone Permission")) {
                    Task { @MainActor in
                        let allowed = await AIVoiceAudioRecorder.requestMicrophonePermission()
                        remoteVoiceMessage = allowed
                            ? L10n.text("麦克风权限已就绪；可再次按遥控器语音键。", "Microphone permission is ready. Press the remote voice key again.")
                            : L10n.text("请在系统设置 → 隐私与安全性 → 麦克风中允许 Joy Harness。", "Allow Joy Harness in System Settings → Privacy & Security → Microphone.")
                    }
                }
                Button(L10n.text("使用遥控器作为系统麦克风", "Use Remote as System Microphone")) {
                    do {
                        try RemoteMicrophoneOutput.selectAsDefaultInput()
                        remoteVoiceMessage = L10n.text("已选择 Joy Harness 遥控器麦克风；请在语音应用中使用系统默认输入。", "Selected Joy Harness Remote Microphone; use the system default input in your voice app.")
                    } catch { remoteVoiceMessage = error.localizedDescription }
                }
                .disabled(installingMicrophone)
                Text(remoteVoiceMessage ?? (remoteComponentNeedsUpdate
                    ? L10n.text("麦克风组件有更新；安装需要管理员验证，并会短暂中断声音。", "A microphone component update is available. Installation requires administrator authentication and briefly interrupts audio.")
                    : remoteComponentInstalled
                        ? L10n.text("这会切换系统默认输入；可在系统声音设置中切回其他麦克风。", "This changes the default input. Switch back in System Sound settings.")
                        : L10n.text("麦克风组件尚未启用；安装需要管理员验证，并会短暂中断声音。", "Enable the microphone component first; installation requires administrator authentication and briefly interrupts audio.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(remoteComponentNeedsUpdate
                    ? L10n.text("更新 Joy Harness 麦克风组件", "Update Joy Harness Microphone")
                    : L10n.text("启用 Joy Harness 麦克风组件", "Enable Joy Harness Microphone")) {
                    installingMicrophone = true
                    remoteVoiceMessage = L10n.text("正在启用麦克风组件，请完成管理员验证；声音会短暂中断。", "Enabling the microphone; authenticate as an administrator. Audio will briefly stop.")
                    Task { @MainActor in
                        defer { installingMicrophone = false }
                        do {
                            try await RemoteMicrophoneInstallation.install()
                            remoteVoiceMessage = L10n.text("麦克风组件已安装，音频服务正在重新加载。稍后点击“使用遥控器作为系统麦克风”。", "Microphone installed; the audio service is reloading. Select Use Remote as System Microphone shortly.")
                        } catch is CancellationError {
                            remoteVoiceMessage = L10n.text("已取消启用麦克风组件。", "Microphone installation cancelled.")
                        } catch {
                            remoteVoiceMessage = L10n.text("启用失败：", "Installation failed: ") + error.localizedDescription
                        }
                    }
                }
                .disabled(installingMicrophone)
                if installingMicrophone {
                    ProgressView().controlSize(.small)
                }
            }

            Section(L10n.text("当前应用", "Current App")) {
                LabeledContent(L10n.text("版本", "Version"), value: AppVersion.current)
                Text(CurrentApplication.bundleURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                Text(L10n.text(
                    "系统设置中的辅助功能和输入监控权限，请授权给这个应用。",
                    "Grant Accessibility and Input Monitoring to this app in System Settings."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if updater.isAvailable {
                Section(L10n.text("更新", "Updates")) {
                    Toggle(
                        L10n.text("自动检查更新", "Automatically Check for Updates"),
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecksForUpdates($0) }
                        )
                    )
                }
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
                        "普通用于左摇杆；按住 L3，或双摇杆手柄的 LT / L2 功能层键使用快速；慢速用于精细模式和触控板。",
                        "Normal applies to the left stick. Hold L3 or the LT / L2 function modifier on a dual-stick controller for Fast. Slow applies to precision mode and the touchpad."
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

            MotionJumpSettingsView(coordinator: motionJump, settings: motionJump.settings)

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
                    "用于右摇杆滚动网页或文档，也适用于单只 Joy-Con 的功能层 + 摇杆滚动。可随时切换。",
                    "Applies to right-stick scrolling in browsers and documents, and function modifier + stick scrolling on a single Joy-Con. You can change it anytime."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(L10n.text("滚动", "Scrolling"))
            }

            Section(L10n.text("外观", "Appearance")) {
                Picker(
                    L10n.text("主题", "Theme"),
                    selection: $appearanceSettings.preference
                ) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
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
            updater.refresh()
        }
        .task {
            while !Task.isCancelled {
                remoteComponentInstalled = RemoteMicrophoneOutput.installed
                remoteComponentNeedsUpdate = RemoteMicrophoneInstallation.updateRequired
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
        .onDisappear { motionJump.stopSession() }
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
