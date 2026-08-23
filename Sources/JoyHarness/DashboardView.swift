import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SlotSidebar(store: store)
                    .frame(width: 224)

                Divider()

                TaskDetail(store: store, mappingStore: mappingStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ConnectionInspector(status: store.status, store: store)
                    .frame(width: 252)
            }

            Divider()
            ActivityBar(status: store.status, message: store.actionMessage)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Joy Harness")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.perform(.refresh)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新任务和连接状态")

                Button {
                    store.perform(.openThread)
                } label: {
                    Label("打开任务", systemImage: "arrow.up.forward.app")
                }
                .help("在 Codex 中打开当前任务")
            }

            ToolbarItem {
                HealthIndicator(status: store.status)
            }
        }
    }
}

private struct SlotSidebar: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("任务槽位")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider()

            ForEach(store.status.slots) { slot in
                Button {
                    store.perform(.selectSlot(slot.slot - 1))
                } label: {
                    SlotRow(slot: slot, isSelected: slot.slot == store.status.selectedSlot)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("槽位 \(slot.slot)，\(slot.displayTitle)，\(slot.padState.displayName)")
            }

            Spacer(minLength: 12)
        }
        .background(.regularMaterial)
    }
}

private struct SlotRow: View {
    let slot: DashboardSlot
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(slot.slot)")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(isSelected ? slot.padState.color.opacity(0.22) : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(slot.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(slot.padState.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)
            Circle()
                .fill(slot.padState.color)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct TaskDetail: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore

    private var status: DashboardStatus { store.status }
    private var slot: DashboardSlot? { status.selected }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            StateBanner(state: status.padState)
                .padding(16)
                .padding(.bottom, 0)

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot?.displayTitle ?? "空槽位")
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Text("任务槽位 \(status.selectedSlot)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                CommandButtons(store: store, waiting: status.padState == .waiting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ControllerMap(status: status, mappingStore: mappingStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(22)
        }
    }
}

private struct StateBanner: View {
    let state: PadState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 22, weight: .semibold))
            Text(state.displayName)
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Text(state.shortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 18)
        .frame(height: 62)
        .dashboardGlassSurface(cornerRadius: 7, tint: state.color)
    }
}

private struct CommandButtons: View {
    @ObservedObject var store: DashboardStore
    let waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.perform(.approve)
            } label: {
                Label("批准", systemImage: "checkmark")
            }
            .dashboardPrimaryButtonStyle()
            .tint(waiting ? .orange : .accentColor)
            .help("批准当前待处理请求")

            Button {
                store.perform(.deny)
            } label: {
                Label("拒绝", systemImage: "xmark")
            }
            .dashboardSecondaryButtonStyle()
            .help("拒绝当前待处理请求")

            Button {
                store.perform(.quickAction)
            } label: {
                Label("快捷操作", systemImage: "bolt.fill")
            }
            .dashboardSecondaryButtonStyle()
            .help("触发 Codex Micro 快捷操作")

            Button {
                store.perform(.openThread)
            } label: {
                Label("打开任务", systemImage: "arrow.up.forward.app")
            }
            .dashboardSecondaryButtonStyle()
            .help("在 Codex 中打开当前任务")
        }
        .controlSize(.large)
    }
}

private struct ControllerMap: View {
    let status: DashboardStatus
    @ObservedObject var mappingStore: ControllerMappingStore

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("控制映射", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                if status.controllerConnected == true {
                    ControllerBatteryIndicator(
                        level: status.controllerBatteryLevel,
                        state: status.controllerBatteryState
                    )
                }
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Label("自定义按键", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("打开按键映射设置")
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    } label: {
                        Label("自定义按键", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("打开按键映射设置")
                }

                Text("\(mappingStore.controllerFamily.displayName) / Codex Micro")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    MappingLabel(key: key(for: .functionDpadUp), title: title(for: .functionDpadUp))
                    MappingLabel(key: key(for: .functionDpadLeft), title: title(for: .functionDpadLeft))
                    MappingLabel(key: key(for: .leftShoulder), title: title(for: .leftShoulder))
                    MappingLabel(key: key(for: .rightShoulder), title: title(for: .rightShoulder))
                    MappingLabel(key: key(for: .menu), title: title(for: .menu))
                    if mappingStore.controllerFamily == .dualSense || mappingStore.controllerFamily == .dualShock {
                        MappingLabel(key: key(for: .touchpadButton), title: title(for: .touchpadButton))
                    }
                    MappingLabel(key: "D-Pad", title: dpadSummary)
                    MappingLabel(key: key(for: .leftTrigger), title: title(for: .leftTrigger))
                    MappingLabel(key: "L3", title: title(for: .leftThumbstickButton))
                }
                .frame(width: 176, alignment: .leading)

                if let controllerArtwork {
                    Image(nsImage: controllerArtwork)
                        .resizable()
                        .scaledToFit()
                        .frame(minWidth: 220, maxWidth: 390, maxHeight: 270)
                        .accessibilityHidden(true)
                        .frame(minWidth: 220, maxWidth: .infinity)
                } else if usesPlayStationLayout {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 112, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: 270)
                        .accessibilityLabel(mappingStore.controllerFamily.displayName)
                } else {
                    Label("手柄资源加载失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 12) {
                    MappingLabel(key: key(for: .buttonA), title: title(for: .buttonA))
                    MappingLabel(key: key(for: .buttonB), title: title(for: .buttonB))
                    MappingLabel(key: key(for: .buttonX), title: title(for: .buttonX))
                    MappingLabel(key: key(for: .buttonY), title: title(for: .buttonY))
                    MappingLabel(key: key(for: .functionButtonA), title: title(for: .functionButtonA))
                    MappingLabel(key: key(for: .functionButtonB), title: title(for: .functionButtonB))
                    MappingLabel(key: key(for: .functionButtonX), title: title(for: .functionButtonX))
                    MappingLabel(key: key(for: .functionButtonY), title: title(for: .functionButtonY))
                    MappingLabel(key: key(for: .rightTrigger), title: title(for: .rightTrigger))
                    MappingLabel(key: "R3", title: title(for: .rightThumbstickButton))
                }
                .frame(width: 132, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .padding(18)
        .dashboardGlassSurface(cornerRadius: 7)
    }

    private var controllerArtwork: NSImage? {
        guard let resource = mappingStore.controllerFamily.dashboardArtworkResource else {
            return nil
        }
        let url = Bundle.main.url(
            forResource: resource,
            withExtension: "png"
        ) ?? Bundle.module.url(
            forResource: resource,
            withExtension: "png"
        )
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private var usesPlayStationLayout: Bool {
        mappingStore.controllerFamily == .dualSense || mappingStore.controllerFamily == .dualShock
    }

    private func title(for input: ControllerInput) -> String {
        mappingStore.action(for: input).displayName
    }

    private func key(for input: ControllerInput) -> String {
        mappingStore.displayName(for: input)
    }

    private var dpadSummary: String {
        let actions = [
            mappingStore.action(for: .dpadUp),
            mappingStore.action(for: .dpadLeft),
            mappingStore.action(for: .dpadDown),
            mappingStore.action(for: .dpadRight),
        ]
        return Set(actions).count == 1 ? actions[0].displayName : "自定义"
    }
}

private struct ControllerBatteryIndicator: View {
    let level: Float?
    let state: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: batterySymbol)
                .symbolRenderingMode(.hierarchical)
            Text(percentageText)
                .monospacedDigit()
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(indicatorColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
    }

    private var percentage: Int? {
        level.map { Int((min(max($0, 0), 1) * 100).rounded()) }
    }

    private var percentageText: String {
        percentage.map { "\($0)%" } ?? "--%"
    }

    private var isCharging: Bool {
        state == ControllerBatteryState.charging.rawValue ||
            state == ControllerBatteryState.full.rawValue
    }

    private var batterySymbol: String {
        guard let percentage else { return "battery.0" }
        switch percentage {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    private var indicatorColor: Color {
        guard let percentage else { return .secondary }
        if isCharging { return .green }
        if percentage <= 20 { return .red }
        if percentage <= 40 { return .orange }
        return .secondary
    }

    private var accessibilityText: String {
        guard let percentage else { return "手柄电量未知" }
        let stateDescription = switch state {
        case ControllerBatteryState.charging.rawValue: "，正在充电"
        case ControllerBatteryState.full.rawValue: "，已充满"
        default: ""
        }
        return "手柄电量 \(percentage)%\(stateDescription)"
    }
}

private struct MappingLabel: View {
    let key: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(minWidth: 28, minHeight: 24)
                .padding(.horizontal, 3)
                .background(Color.secondary.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
    }
}

private struct ConnectionInspector: View {
    let status: DashboardStatus
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连接与诊断")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider()

            InspectorSection(
                title: "控制器",
                systemImage: "gamecontroller",
                connected: status.controllerConnected ??
                    (status.controller != "none" && status.controller != "No controller"),
                rows: [
                    ("设备", status.controller),
                    ("类型", controllerFamilyName),
                    ("震动", status.haptics ? "可用" : "不可用"),
                    ("触控板", status.controllerTouchpad == true ? "可映射" : "不可用"),
                    ("R2 扳机", status.controllerFamily == ControllerFamily.dualSense.rawValue
                        ? "自适应强反馈" : "标准输入"),
                ]
            )
            Divider().padding(.leading, 16)
            InspectorSection(
                title: "Codex Micro",
                systemImage: "memorychip",
                connected: status.rp2040,
                rows: [
                    ("RP2040", status.rp2040 ? "已连接" : "未连接"),
                    ("模式", status.mode == "legacy-app-server" ? "软件兼容" : "物理 Micro"),
                ]
            )
            Divider().padding(.leading, 16)
            InspectorSection(
                title: "运行模式",
                systemImage: "lock.shield",
                connected: status.mode == "physical-codex-micro",
                rows: [
                    ("辅助功能", status.accessibility ? "已授权" : "鼠标控制未授权"),
                    ("输入监控", status.inputMonitoring == true ? "已授权" : "后台手柄未授权"),
                    ("语音输入", voiceInputDescription),
                    ("录音", "由 Codex Desktop 管理"),
                ]
            )
            if status.controllerFamily == ControllerFamily.dualSense.rawValue {
                Button {
                    openSoundInputSettings()
                } label: {
                    Label("打开声音输入设置", systemImage: "mic")
                }
                .buttonStyle(.link)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Spacer()
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("震动测试")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach([PadState.busy, .waiting, .done, .error], id: \.rawValue) { state in
                        Button {
                            store.perform(.testState(state))
                        } label: {
                            Image(systemName: state.symbolName)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(state.color)
                        .help("测试\(state.displayName)震动")
                    }
                }
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }

    private var controllerFamilyName: String {
        guard let raw = status.controllerFamily,
              let family = ControllerFamily(rawValue: raw) else { return "通用手柄" }
        return family.displayName
    }

    private var voiceInputDescription: String {
        guard status.microphone, let name = status.voiceInput, !name.isEmpty else {
            guard let defaultInput = status.defaultVoiceInput, !defaultInput.isEmpty else {
                return status.controllerFamily == ControllerFamily.dualSense.rawValue
                    ? "手柄未提供；系统也无可用输入" : "系统无可用输入"
            }
            return status.controllerFamily == ControllerFamily.dualSense.rawValue
                ? "手柄未提供；当前用 \(defaultInput)" : "当前用 \(defaultInput)"
        }
        let transport = status.voiceInputTransport.flatMap { $0.isEmpty ? nil : $0 } ?? "未知连接"
        return status.voiceInputDefault == true
            ? "\(name)（\(transport)，默认）"
            : "\(name)（\(transport)，未选中）"
    }

    private func openSoundInputSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct InspectorSection: View {
    let title: String
    let systemImage: String
    let connected: Bool
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(connected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
            }
        }
        .padding(16)
    }
}

private struct HealthIndicator: View {
    let status: DashboardStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.rp2040 && status.haptics ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(status.rp2040 && status.haptics ? "链路正常" : "检查连接")
                .font(.caption)
        }
    }
}

private struct ActivityBar: View {
    let status: DashboardStatus
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Label("活动", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
            Divider().frame(height: 16)
            Text(message.isEmpty ? activityText : message)
                .font(.caption)
                .foregroundStyle(message.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
            Spacer()
            Text(formattedTimestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private var activityText: String {
        status.note.isEmpty ? "等待事件" : status.note
    }

    private var formattedTimestamp: String {
        guard let date = ISO8601DateFormatter().date(from: status.timestamp) else { return "--:--:--" }
        return date.formatted(date: .omitted, time: .standard)
    }
}

private extension View {
    func dashboardGlassSurface(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        modifier(DashboardGlassSurface(cornerRadius: cornerRadius, tint: tint))
    }

    func dashboardPrimaryButtonStyle() -> some View {
        modifier(DashboardPrimaryButtonStyle())
    }

    func dashboardSecondaryButtonStyle() -> some View {
        modifier(DashboardSecondaryButtonStyle())
    }
}

private struct DashboardGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(
                    .regular.tint(tint.opacity(0.18)),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.regularMaterial, in: fallbackShape)
                .background((tint ?? .clear).opacity(0.1), in: fallbackShape)
                .overlay {
                    fallbackShape.stroke(
                        tint?.opacity(0.24) ?? Color.primary.opacity(0.1),
                        lineWidth: 1
                    )
                }
        }
    }

    private var fallbackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

private struct DashboardPrimaryButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct DashboardSecondaryButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension PadState {
    var displayName: String {
        switch self {
        case .idle: return "就绪"
        case .busy: return "执行中"
        case .waiting: return "等待批准"
        case .done: return "已完成"
        case .error: return "发生错误"
        }
    }

    var shortDescription: String {
        switch self {
        case .idle: return "等待下一项操作"
        case .busy: return "任务正在处理"
        case .waiting: return "需要你的决定"
        case .done: return "任务已结束"
        case .error: return "请检查活动记录"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "circle.dotted"
        case .busy: return "waveform.path.ecg"
        case .waiting: return "hourglass"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .busy: return .cyan
        case .waiting: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
}
