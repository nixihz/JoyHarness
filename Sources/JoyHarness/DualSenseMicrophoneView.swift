import AppKit
import SwiftUI

enum DualSenseMicrophoneFeature {
    // M0 needs physical audio/CRC and Codex evidence before normal release.
    static let isEnabled = false // Retired: the managed DualSense Audio driver owns capture.
}

struct DualSenseMicrophoneSettingsSection: View {
    @ObservedObject var session: DualSenseMicrophoneSession
    @State private var installing = false
    @State private var setupMessage: String?
    @State private var componentInstalled = false
    @State private var defaultInputSelected = false

    var body: some View {
        Section(L10n.text("DualSense 系统麦克风 · 开发验证", "DualSense System Microphone · Preview")) {
            Text(L10n.text(
                "通过蓝牙把手柄内置麦克风提供给 Codex 等应用。无需启用 AI 语音；本机无线录音尚待验收。供音期间暂停该手柄的桌面操作。",
                "Supply the controller's Bluetooth microphone to Codex and other apps. AI Voice is not required. Hardware recording is pending validation; controller desktop actions pause while supplying audio."
            )).font(.caption)
            Text(session.deviceIssue ?? L10n.text("蓝牙端点可用", "Bluetooth endpoint available"))
                .foregroundStyle(session.deviceIssue == nil ? .secondary : .primary)
            Text(componentInstalled
                ? L10n.text("组件已安装 · DualSense 专用输入可用", "Component installed · DualSense input available")
                : L10n.text("组件未安装或需要更新", "Component missing or update required"))
                .font(.caption)
            Text(defaultInputSelected
                ? L10n.text("已设为系统默认输入；外部应用的音源设置仍需在应用内确认。", "Selected as system default. Confirm the consumer app's own input setting.")
                : L10n.text("尚未确认此设备为系统默认输入。", "This device is not confirmed as the system default input."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("检查麦克风权限", "Check Microphone Permission")) {
                    Task { @MainActor in
                        let granted = await AIVoiceAudioRecorder.requestMicrophonePermission()
                        setupMessage = granted
                            ? L10n.text("Joy Harness 麦克风权限已就绪；Codex 仍需自己的录音权限。", "Joy Harness is authorized. Codex needs its own microphone permission.")
                            : L10n.text("请在系统隐私设置中允许 Joy Harness 使用麦克风。", "Allow Joy Harness to access the microphone in System Settings.")
                    }
                }
                Button(L10n.text("安装或更新组件", "Install or Update Component")) {
                    installing = true
                    Task { @MainActor in
                        defer { installing = false }
                        do {
                            try await RemoteMicrophoneInstallation.install()
                            setupMessage = L10n.text("组件已安装。音频服务恢复后，可选择 DualSense 系统麦克风。", "Component installed. Select the DualSense input after audio services reload.")
                        } catch { setupMessage = error.localizedDescription }
                    }
                }.disabled(installing || session.isEngaged)
            }
            Text(L10n.text("组件安装需要管理员验证，并会短暂中断系统声音。", "Installation requires administrator authentication and briefly interrupts system audio."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("使用 DualSense 作为系统麦克风", "Use DualSense as System Microphone")) {
                do {
                    try DualSenseSystemAudioOutput.selectAsDefaultInput()
                    setupMessage = L10n.text("已切换系统默认输入。请在 Codex 使用系统默认麦克风，或在支持音源选择的应用内选择此设备。", "System input changed. Use the default microphone in Codex, or select this device in apps with an input picker.")
                } catch { setupMessage = error.localizedDescription }
            }.disabled(installing || !componentInstalled)
            Text(L10n.text("此操作修改系统默认输入；可在系统声音设置中切回。选择设备不会自动收音。", "This changes the system default input. Switch back in Sound settings. Selecting the device does not start capture."))
                .font(.caption).foregroundStyle(.secondary)
            Link(L10n.text("打开系统声音设置", "Open Sound Settings"),
                 destination: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
            if let setupMessage { Text(setupMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Text(session.message).fixedSize(horizontal: false, vertical: true)
            if session.phase == .streaming {
                ProgressView(value: Double(session.level))
                    .accessibilityLabel(L10n.text("手柄麦克风电平", "Controller microphone level"))
            }
            HStack {
                Button(L10n.text("开始向系统麦克风供音", "Start Supplying Audio")) { session.startManual() }
                    .disabled(session.isEngaged || installing || !componentInstalled || session.deviceIssue != nil)
                Button(L10n.text("停止供音", "Stop Supplying Audio")) { session.stop() }
                    .disabled(!session.isSupplying && session.phase != .stopping)
                if session.phase == .fault {
                    Button(L10n.text("重试停止", "Retry Stop")) { session.recoverUnexpectedAudio() }
                }
            }
            Text(L10n.text(
                "手动供音无需按手柄键。开始供音后，请在 Codex 点击麦克风按钮开始录音。",
                "Manual audio supply needs no controller button. After starting audio supply, click the microphone button in Codex to start recording."
            )).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("Codex 按住说话联动", "Coordinate Codex Push to Talk"), isOn: $session.pttEnabled)
            Text(L10n.text(
                "需要通过手柄按住说话时，启用此联动，并在 Codex Harness 中将面键、L1/R1、方向键、摇杆按键、触控板按键或 Menu/Options 设为“按住说话”。保持按下，音频就绪后才发出 Codex Micro 操作。PS、L2/R2 和组合键暂不支持；现有映射不会自动更改。",
                "To use controller push to talk, enable this coordination and map a face button, L1/R1, D-pad, stick click, touchpad click or Menu/Options to Push to Talk in the Codex Harness. Hold it while audio prepares; the Micro action follows readiness. PS, L2/R2 and chords are not supported. Existing mappings are not changed automatically."
            )).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("停止仅停止供音；外部应用已收到的声音无法撤回，其录音和提交状态请在应用内确认。", "Stopping ends audio supply. Audio already received cannot be recalled; check recording and submission in the consumer app."))
                .font(.caption).foregroundStyle(.secondary)
        }.task {
            while !Task.isCancelled {
                componentInstalled = DualSenseSystemAudioOutput.installed
                defaultInputSelected = DualSenseSystemAudioOutput.isDefaultInput
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }
}

@MainActor
final class DualSenseMicrophoneOverlay {
    private let session: DualSenseMicrophoneSession
    private var panel: NSPanel?
    init(session: DualSenseMicrophoneSession) { self.session = session }

    func update() {
        guard session.isEngaged else { hide(); return }
        if panel == nil {
            let panel = DualSenseMicrophonePanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 160),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: DualSenseMicrophoneStatusView(session: session))
            self.panel = panel
        }
        if let panel, !panel.isVisible {
            if let frame = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 390, y: frame.minY + 30))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel?.orderOut(nil) }
}

private final class DualSenseMicrophonePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DualSenseMicrophoneStatusView: View {
    @ObservedObject var session: DualSenseMicrophoneSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DualSense → " + L10n.text("系统麦克风", "System Microphone"), systemImage: "mic.fill")
                .font(.headline)
            Text(session.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            if session.phase == .streaming {
                ProgressView(value: Double(session.level))
                    .accessibilityLabel(L10n.text("麦克风电平", "Microphone level"))
            }
            Button(L10n.text("停止供音", "Stop Supplying Audio")) { session.stop() }
                .disabled(!session.isSupplying && session.phase != .stopping)
        }
        .padding(16)
        .frame(width: 370, height: 160, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
