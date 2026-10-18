import SwiftUI

struct DualSenseAudioSettingsSection: View {
    @State private var installed = false
    @State private var needsUpdate = false
    @State private var ready = false
    @State private var selected = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingRemoval = false

    var body: some View {
        Section(L10n.text("PS5 手柄麦克风", "PS5 Controller Microphone")) {
            Text(L10n.text("用 DualSense 内置麦克风进行外部语音输入或 AI 语音。录音时自动开启 Game Mode，采音结束后恢复。", "Use the DualSense microphone for dictation or AI Voice. Game Mode turns on while audio is captured and restores afterward."))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent(L10n.text("组件", "Component"), value: installed
                ? (needsUpdate ? L10n.text("需要更新", "Update available") : L10n.text("已安装", "Installed"))
                : L10n.text("未安装", "Not installed"))
            if installed {
                LabeledContent(L10n.text("系统输入", "System Input"), value: ready
                    ? (selected ? L10n.text("DualSense Microphone · 当前默认", "DualSense Microphone · Default") : "DualSense Microphone")
                    : L10n.text("等待组件或手柄连接", "Waiting for the component or controller"))
                Button(L10n.text("设为系统麦克风", "Use as System Microphone")) {
                    do {
                        try DualSenseAudioInstallation.selectInput()
                        message = L10n.text("已选择 DualSense Microphone；请在语音软件中使用系统默认输入。", "Selected DualSense Microphone. Use the system default input in your voice app.")
                    } catch { message = error.localizedDescription }
                    refresh()
                }
                .disabled(busy || !ready || selected)
            }
            if let issue = DualSenseAudioInstallation.prerequisiteIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(installed ? L10n.text("更新／修复组件", "Update / Repair") : L10n.text("启用手柄麦克风", "Enable Controller Microphone")) {
                    run(remove: false)
                }
                .disabled(busy || DualSenseAudioInstallation.prerequisiteIssue != nil)
                if installed {
                    Button(L10n.text("卸载手柄麦克风", "Uninstall Controller Microphone"), role: .destructive) {
                        confirmingRemoval = true
                    }
                    .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            Text(L10n.text("安装、更新和卸载需要管理员验证，会短暂中断系统声音。更新会清理旧版手柄音源，保留小米遥控器麦克风。", "Installation, updates and removal require administrator authentication and briefly interrupt audio. Updating removes the old controller input and preserves the Xiaomi microphone."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("Options 绑定语音软件的切换录音快捷键：按一次开始，再按一次结束。内置 AI：按住 L2、短点 PS 开始，松开 L2 结束。", "Bind Options to your voice app's recording toggle: press once to start, again to stop. AI Voice: hold L2, tap PS to start, release L2 to finish."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("系统声音设置的输入电平表也会持续采音。停止所有采音后，Game Mode 才会恢复原来的设置。", "The input meter in System Sound settings also captures audio. Game Mode restores after all capture stops."))
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .confirmationDialog(L10n.text("卸载 PS5 手柄麦克风？", "Uninstall the PS5 microphone?"), isPresented: $confirmingRemoval) {
            Button(L10n.text("卸载", "Uninstall"), role: .destructive) { run(remove: true) }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("DualSense Microphone 将从系统移除，手柄无线语音将不可用；普通手柄控制和小米麦克风会保留。之后可在此重新启用。", "DualSense Microphone will be removed and wireless controller voice will stop working. Controller controls and the Xiaomi microphone remain. You can enable it again here."))
        }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
            }
        }
    }
    private func refresh() {
        installed = DualSenseAudioInstallation.installed
        needsUpdate = DualSenseAudioInstallation.needsUpdate
        ready = DualSenseAudioInstallation.deviceID() != nil
        selected = DualSenseAudioInstallation.selected
    }
    private func run(remove: Bool) {
        busy = true
        message = L10n.text("请完成系统管理员验证。", "Complete the system administrator prompt.")
        Task { @MainActor in
            defer { busy = false; refresh() }
            do {
                if remove { try await DualSenseAudioInstallation.uninstall() }
                else { try await DualSenseAudioInstallation.install() }
                message = remove
                    ? L10n.text("手柄麦克风已卸载。", "Controller microphone uninstalled.")
                    : L10n.text("组件已更新，音频服务正在恢复；就绪后可设为系统麦克风。", "Components updated. Audio services are recovering; select the microphone when ready.")
            } catch is CancellationError {
                message = L10n.text("已取消，未完成组件更改。", "Cancelled. Component changes were not completed.")
            } catch { message = error.localizedDescription }
        }
    }
}
