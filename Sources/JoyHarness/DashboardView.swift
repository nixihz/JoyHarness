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

                Divider()

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

            VStack(alignment: .leading, spacing: 6) {
                Label("LT + 方向键 / LB / RB", systemImage: "gamecontroller")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("手柄与界面共享同一组槽位")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
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

    var body: some View {
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

            ControllerMap(mappingStore: mappingStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(22)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
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
        .background(state.color.opacity(0.11))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(state.color.opacity(0.24), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
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
            .buttonStyle(.borderedProminent)
            .tint(waiting ? .orange : .accentColor)
            .help("批准当前待处理请求")

            Button {
                store.perform(.deny)
            } label: {
                Label("拒绝", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .help("拒绝当前待处理请求")

            Button {
                store.perform(.quickAction)
            } label: {
                Label("快捷操作", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .help("触发 Codex Micro 快捷操作")

            Button {
                store.perform(.openThread)
            } label: {
                Label("打开任务", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .help("在 Codex 中打开当前任务")
        }
        .controlSize(.large)
    }
}

private struct ControllerMap: View {
    @ObservedObject var mappingStore: ControllerMappingStore

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("控制映射", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
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

                Text("Xbox / Codex Micro")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    MappingLabel(key: "LT + ↑", title: title(for: .functionDpadUp))
                    MappingLabel(key: "LT + ←", title: title(for: .functionDpadLeft))
                    MappingLabel(key: "LB", title: title(for: .leftShoulder))
                    MappingLabel(key: "RB", title: title(for: .rightShoulder))
                    MappingLabel(key: "Menu", title: title(for: .menu))
                    MappingLabel(key: "D-Pad", title: dpadSummary)
                    MappingLabel(key: "LT", title: title(for: .leftTrigger))
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
                } else {
                    Label("手柄资源加载失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 12) {
                    MappingLabel(key: "A", title: title(for: .buttonA))
                    MappingLabel(key: "B", title: title(for: .buttonB))
                    MappingLabel(key: "X", title: title(for: .buttonX))
                    MappingLabel(key: "Y", title: title(for: .buttonY))
                    MappingLabel(key: "LT + A", title: title(for: .functionButtonA))
                    MappingLabel(key: "LT + B", title: title(for: .functionButtonB))
                    MappingLabel(key: "RT", title: title(for: .rightTrigger))
                    MappingLabel(key: "R3", title: title(for: .rightThumbstickButton))
                }
                .frame(width: 132, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("左摇杆移动鼠标，按住 LT 切换纵向 / 横向滚动；A/B 点击，X 退格，Y 返回")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.34))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var controllerArtwork: NSImage? {
        let url = Bundle.main.url(
            forResource: "controller-dashboard",
            withExtension: "png"
        ) ?? Bundle.module.url(
            forResource: "controller-dashboard",
            withExtension: "png"
        )
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private func title(for input: ControllerInput) -> String {
        mappingStore.action(for: input).displayName
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
                connected: status.haptics,
                rows: [
                    ("设备", status.controller),
                    ("震动", status.haptics ? "可用" : "不可用"),
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
                    ("麦克风", "由 Codex Micro 管理"),
                ]
            )

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
