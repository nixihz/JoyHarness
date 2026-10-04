import SwiftUI

struct DashboardConnectionDetails: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness, mappingStore: mappingStore)
    }
    private var status: DashboardStatus { store.status }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.inset) {
            section(L10n.text("控制器", "Controller"), symbol: "gamecontroller") {
                ForEach(Array(presentation.controllerRows.enumerated()), id: \.offset) { _, row in
                    DashboardDetailRow(label: row.0, value: row.1)
                }
            }
            section(L10n.text("适配器", "Adapter"), symbol: "memorychip") {
                DashboardDetailRow(
                    label: L10n.text("连接", "Connection"),
                    value: !presentation.isFresh ? presentation.unknown : status.rp2040
                        ? L10n.text("已连接", "Connected") : L10n.text("未连接", "Disconnected"),
                    state: rowState(presentation.isFresh ? status.rp2040 : nil)
                )
                DashboardDetailRow(
                    label: L10n.text("模式", "Mode"),
                    value: !presentation.isFresh ? presentation.unknown : status.mode == "legacy-app-server"
                        ? L10n.text("软件兼容", "Software Compatibility") : L10n.text("适配器连接", "Adapter Connection")
                )
            }
            section(L10n.text("运行与权限", "Runtime & Permissions"), symbol: "lock.shield") {
                DashboardDetailRow(
                    label: L10n.text("输入模式", "Input Mode"),
                    value: presentation.isFresh ? status.activeOperationMode.displayName : presentation.unknown
                )
                DashboardDetailRow(
                    label: L10n.text("辅助功能", "Accessibility"),
                    value: presentation.authorization(status.accessibility),
                    state: rowState(presentation.isFresh ? status.accessibility : nil)
                ) {
                    if presentation.isFresh && !status.accessibility {
                        Button(L10n.text("打开", "Open")) { DashboardSystemSettings.open(.accessibility) }
                    }
                }
                DashboardDetailRow(
                    label: L10n.text("输入监控", "Input Monitoring"),
                    value: presentation.authorization(status.inputMonitoring),
                    state: rowState(presentation.isFresh ? status.inputMonitoring : nil)
                ) {
                    if presentation.isFresh && status.inputMonitoring == false {
                        Button(L10n.text("打开", "Open")) { DashboardSystemSettings.open(.inputMonitoring) }
                    }
                }
                Button(L10n.text("在 Finder 中显示当前应用", "Show Current App in Finder")) {
                    CurrentApplication.revealInFinder()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            section(L10n.text("语音输入", "Voice Input"), symbol: "mic") {
                DashboardDetailRow(
                    label: L10n.text("输入设备", "Input Device"),
                    value: presentation.isFresh ? presentation.voiceInputDescription : presentation.unknown
                )
                DashboardDetailRow(
                    label: L10n.text("录音归属", "Recording Owner"),
                    value: L10n.text("由 Codex Desktop 管理", "Managed by Codex Desktop")
                )
                Button(L10n.text("打开声音输入设置", "Open Sound Input Settings")) { DashboardSystemSettings.open(.sound) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            section(L10n.text("震动测试", "Haptic Test"), symbol: "waveform.path") {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DashboardStyle.Space.small), count: 2),
                    spacing: DashboardStyle.Space.small
                ) {
                    ForEach([PadState.busy, .waiting, .done, .error], id: \.rawValue) { state in
                        Button { store.perform(.testHaptics(state)) } label: {
                            Label(state.displayName, systemImage: state.symbolName)
                                .frame(maxWidth: .infinity, minHeight: DashboardStyle.minimumTarget)
                        }
                        .help(L10n.text("测试\(state.displayName)震动", "Test \(state.displayName) haptics"))
                        .accessibilityLabel(L10n.text("测试\(state.displayName)震动", "Test \(state.displayName) haptics"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!presentation.canTestHaptics)
                Text(presentation.canTestHaptics
                     ? L10n.text("短暂测试硬件反馈，不改变任务状态。", "Briefly test hardware feedback without changing task state.")
                     : L10n.text("需要已连接且支持震动的控制器。", "Connect a controller with available haptics to test."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.actionMessage.isEmpty {
                    Label(store.actionMessage, systemImage: "info.circle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(AppVersion.displayName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func rowState(_ value: Bool?) -> DashboardDetailState {
        guard let value else { return .unknown }
        return value ? .ok : .attention
    }

    private func section<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
                content()
            }
            .padding(DashboardStyle.Space.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardGlass(cornerRadius: DashboardStyle.Radius.inner)
        }
    }
}

enum DashboardDetailState {
    case none
    case ok
    case attention
    case unknown
}

/// One label/value pair. A status icon accompanies values that report a
/// state, and a recovery action sits on the row it fixes.
struct DashboardDetailRow<Action: View>: View {
    let label: String
    let value: String
    var state: DashboardDetailState = .none
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DashboardStyle.Space.small) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DashboardStyle.Space.small)
            HStack(alignment: .firstTextBaseline, spacing: DashboardStyle.Space.tiny) {
                stateIcon
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            action()
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var stateIcon: some View {
        switch state {
        case .none: EmptyView()
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .attention: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

extension DashboardDetailRow where Action == EmptyView {
    init(label: String, value: String, state: DashboardDetailState = .none) {
        self.init(label: label, value: value, state: state) { EmptyView() }
    }
}
