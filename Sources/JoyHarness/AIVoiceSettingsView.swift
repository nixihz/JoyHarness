import AVFoundation
import Speech
import SwiftUI

struct AIVoiceSettingsPane: View {
    @ObservedObject var settings: AIVoiceSettings
    @ObservedObject var session: AIVoiceSession
    var inputIssue: () -> String? = { nil }
    @State private var intentKey = ""
    @State private var speechKey = ""
    @State private var notice = ""
    @State private var requestingPermissions = false
    @State private var controllerIssue: String?

    var body: some View {
        Form {
            Section(L10n.text("独立 AI 语音", "Joy Harness AI Voice")) {
                Toggle(L10n.text("启用 AI 语音", "Enable AI Voice"), isOn: $settings.isEnabled)
                Text(L10n.text(
                    "按住 L2，再点一下 PS 开始语音。PS 可以立即松开；继续按住 L2，看到“正在聆听”后说话，松开 L2 发送。",
                    "Hold L2, then tap PS to start voice. Release PS immediately; keep holding L2, speak after Listening appears, then release L2 to send."
                )).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("单独按 PS 立即打开 Harness 切换浮层。语音无需长按 PS，避免触发手柄关机。", "Press PS alone to open the Harness switcher immediately. Voice does not require holding PS, which can turn off the controller."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("目前使用单只 DualSense 的可靠输入；原生模式下 PS 仍返回映射模式。", "Uses reliable input from one DualSense. In Native Mode, PS still returns to Mapping Mode."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let issue = controllerIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Picker(L10n.text("处理方式", "Processing"), selection: $settings.routeID) {
                    Text(L10n.text("请选择", "Choose a route")).tag("")
                    ForEach(AIVoiceProcessingRoute.allCases, id: \.rawValue) { route in
                        Text(route.displayName).tag(route.rawValue)
                    }
                }
                if let route = settings.route {
                    Text(route.dataNotice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("不会自动切换处理方式；原始录音与转写不保存到历史记录。", "No automatic route switching. Recordings and transcripts are not saved in a history."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.text("麦克风与语言", "Microphone & Language")) {
                LabeledContent(L10n.text("输入", "Input"), value: ControllerAudioSupport.snapshot(for: .generic).defaultInputName ?? L10n.text("无可用输入", "No input available"))
                Text(L10n.text("使用系统默认麦克风；录音中设备变化会取消。蓝牙 DualSense 只负责按键。", "Uses the system default microphone. Device changes cancel recording. A Bluetooth DualSense supplies buttons only."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("选择系统麦克风…", "Choose System Microphone…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                Picker(L10n.text("识别语言", "Speech Language"), selection: $settings.localeIdentifier) {
                    Text("简体中文").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                }
                if settings.route != .cloud,
                   let issue = AIVoiceProvider.localSpeechAvailability(localeIdentifier: settings.localeIdentifier) {
                    Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("检查录音权限", "Check Recording Permissions")) { requestPermissions() }
                    .disabled(requestingPermissions)
                if requestingPermissions { ProgressView().controlSize(.small) }
            }

            if settings.route != nil {
                Section(L10n.text("理解指令的模型", "Command Model")) {
                    TextField(L10n.text("API 基础地址", "API Base URL"), text: $settings.intentBaseURL, prompt: Text(settings.route == .local ? "http://localhost:1234/v1" : "https://…/v1"))
                    TextField(L10n.text("模型名称", "Model Name"), text: $settings.intentModel)
                    credentialRow(key: $intentKey, kind: .intent)
                    Text(L10n.text("支持 Chat Completions 兼容接口；模型需按要求返回 JSON。本地方式仅允许本机回环地址。", "Uses a Chat Completions-compatible endpoint. The model must return JSON. Local mode allows only loopback addresses."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("默认地址仅为示例，请填写实际服务地址和模型名。不需要鉴权的本机服务可留空 API Key；转发到其他模型的配置可留在你的服务端。", "The default URL is an example. Enter your server URL and model. API Key is optional for a local server without authentication. Configure upstream routing on your server."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if settings.route == .cloud {
                Section(L10n.text("语音识别服务", "Speech Service")) {
                    TextField(L10n.text("API 基础地址", "API Base URL"), text: $settings.transcriptionBaseURL, prompt: Text("https://…/v1"))
                    TextField(L10n.text("模型名称", "Model Name"), text: $settings.transcriptionModel)
                    credentialRow(key: $speechKey, kind: .transcription)
                    Text(L10n.text("支持 audio/transcriptions 兼容接口；仅在松开 L2 后发送本次录音。", "Uses an audio/transcriptions-compatible endpoint. Audio is sent only after releasing L2."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let issue = settings.configurationIssue {
                Section { Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            if !notice.isEmpty {
                Section { Text(notice).font(.caption).textSelection(.enabled) }
            }
            ForEach(capabilityGroups.indices, id: \.self) { index in
                Section(capabilityGroups[index].title) {
                    ForEach(session.registry.allDescriptors.filter { capabilityGroups[index].ids.contains($0.id) }, id: \.id) { descriptor in
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(capabilityTitle(descriptor.id), isOn: Binding(
                                get: { !settings.disabledCapabilities.contains(descriptor.id) },
                                set: { settings.setCapability(descriptor.id, enabled: $0) }
                            ))
                            Text(descriptor.examples.prefix(2).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Section(L10n.text("使用说明", "Using Voice Commands")) {
                Text(L10n.text("“打开当前应用的设置”会向提交语音时的前台应用发送 Command + 逗号；处理期间请保持该应用在前台。", "“Open the current app’s settings” sends Command-comma to the app in front when the command is submitted. Keep that app in front while processing."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("可说“打开日间模式”“打开夜间模式”或“跟随系统”，切换 macOS 浅色、深色或自动外观。", "Say “turn on Light mode,” “turn on Dark mode,” or “follow system” to set macOS appearance to Light, Dark, or Auto."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("音量和亮度默认每次调整 10 个百分点，也可说“设为50%”。亮度优先控制内建屏，没有内建屏则控制主屏；外接屏需要支持硬件调光。", "Volume and brightness change by 10 percentage points by default. You can also say “set to 50%.” Brightness targets the built-in display, or the main display when none is built in. External displays must support hardware brightness control."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("每次处理一项操作。目标不明确时会询问；设备不支持或结果无法确认时会如实提示。媒体播放/暂停是切换操作，截屏由系统工具中的选择完成。", "One action is handled at a time. Ambiguous targets prompt a question; unsupported devices and unverified results are reported. Play/pause toggles playback; screenshots are completed in the system capture tool."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { controllerIssue = inputIssue() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controllerIssue = inputIssue()
        }
    }

    private var capabilityGroups: [(title: String, ids: Set<String>)] {
        [
            (L10n.text("声音", "Sound"), ["adjust_volume", "set_volume", "set_mute", "get_volume"]),
            (L10n.text("显示器", "Display"), ["adjust_brightness", "set_brightness", "get_brightness"]),
            (L10n.text("应用与系统", "Apps and System"), ["open_application", "open_system_settings", "open_wetype_settings", "open_folder", "open_screenshot_tool", "set_system_appearance", "open_current_app_settings"]),
            (L10n.text("媒体与查询", "Media and Information"), ["media_control", "get_datetime", "get_battery"]),
        ]
    }

    private func capabilityTitle(_ id: String) -> String {
        switch id {
        case "open_application": L10n.text("打开已安装的应用", "Open Installed Apps")
        case "open_system_settings": L10n.text("打开常用系统设置页", "Open System Settings Pages")
        case "open_wetype_settings": L10n.text("打开微信输入法设置", "Open WeChat Input Settings")
        case "open_current_app_settings": L10n.text("打开当前应用的设置", "Open Current App Settings")
        case "adjust_volume": L10n.text("调大／调小音量", "Adjust Volume")
        case "set_volume": L10n.text("设置音量百分比", "Set Volume Percentage")
        case "set_mute": L10n.text("静音／取消静音", "Mute / Unmute")
        case "get_volume": L10n.text("查询当前音量", "Check Volume")
        case "adjust_brightness": L10n.text("调高／调低屏幕亮度", "Adjust Display Brightness")
        case "set_brightness": L10n.text("设置亮度百分比", "Set Brightness Percentage")
        case "get_brightness": L10n.text("查询当前亮度", "Check Brightness")
        case "set_system_appearance": L10n.text("macOS 日间／夜间／自动外观", "macOS Light / Dark / Auto Appearance")
        case "media_control": L10n.text("媒体播放切换与切歌", "Toggle Playback and Skip Tracks")
        case "open_folder": L10n.text("打开常用文件夹", "Open Common Folders")
        case "open_screenshot_tool": L10n.text("打开截屏工具", "Open Screenshot Tool")
        case "get_datetime": L10n.text("查询日期和时间", "Check Date and Time")
        case "get_battery": L10n.text("查询电脑电量", "Check Mac Battery")
        default: id
        }
    }

    private func credentialRow(key: Binding<String>, kind: AIVoiceSettings.Credential) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(L10n.text("API 密钥（保存在钥匙串）", "API Key (stored in Keychain)"), text: key)
            HStack {
                Button(L10n.text("保存密钥", "Save Key")) {
                    do {
                        try settings.storeCredential(key.wrappedValue, for: kind)
                        key.wrappedValue = ""
                        notice = L10n.text("密钥已保存到当前服务地址的钥匙串项。", "Key saved in Keychain for this service URL.")
                    } catch { notice = error.localizedDescription }
                }.disabled(key.wrappedValue.isEmpty)
                Button(L10n.text("移除密钥", "Remove Key")) {
                    do {
                        try settings.storeCredential("", for: kind)
                        key.wrappedValue = ""
                        notice = L10n.text("已移除当前服务地址的密钥。", "Key removed for this service URL.")
                    } catch { notice = error.localizedDescription }
                }
            }
        }
    }

    private func requestPermissions() {
        requestingPermissions = true
        Task { @MainActor in
            let microphone = await AIVoiceAudioRecorder.requestMicrophonePermission()
            let speech = settings.route == .cloud ? true : await AIVoiceProvider.requestLocalSpeechPermission()
            requestingPermissions = false
            notice = microphone && speech
                ? L10n.text("录音权限已就绪。请确认处理方式和模型服务配置。", "Recording permissions are ready. Check your processing route and model configuration.")
                : L10n.text("请在系统设置 → 隐私与安全性中允许麦克风和所需的语音识别权限。", "Allow Microphone and, when needed, Speech Recognition in System Settings → Privacy & Security.")
        }
    }
}
