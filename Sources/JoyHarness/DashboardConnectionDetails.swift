import SwiftUI

struct DashboardConnectionDetails: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness, mappingStore: mappingStore)
    }
    private var status: DashboardStatus { store.status }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
            group(
                L10n.text("控制器", "Controller"),
                symbol: "gamecontroller",
                rows: presentation.controllerRows,
                columns: 2
            )
            Divider()
            HStack(alignment: .top, spacing: DashboardStyle.Space.section) {
                group(L10n.text("适配器", "Adapter"), symbol: "memorychip", rows: adapterRows)
                group(L10n.text("运行与权限", "Runtime & Permissions"), symbol: "lock.shield", rows: runtimeRows)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DashboardStyle.Space.medium) { permissionActions }
                VStack(alignment: .leading, spacing: DashboardStyle.Space.small) { permissionActions }
            }
            .font(.caption)
            .buttonStyle(.link)
            Divider()
            group(
                L10n.text("语音输入", "Voice Input"),
                symbol: "mic",
                rows: [
                    (L10n.text("输入设备", "Input Device"), presentation.isFresh ? presentation.voiceInputDescription : presentation.unknown),
                    (L10n.text("录音归属", "Recording Owner"), L10n.text("由 Codex Desktop 管理", "Managed by Codex Desktop")),
                ],
                columns: 2
            )
            Button(L10n.text("打开声音输入设置", "Open Sound Input Settings")) { DashboardSystemSettings.open(.sound) }
                .font(.caption)
                .buttonStyle(.link)
            Divider()
            VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
                Label(L10n.text("震动测试", "Haptic Test"), systemImage: "waveform.path")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: DashboardStyle.Space.small) {
                    ForEach([PadState.busy, .waiting, .done, .error], id: \.rawValue) { state in
                        Button { store.perform(.testHaptics(state)) } label: {
                            Label(state.displayName, systemImage: state.symbolName)
                                .labelStyle(.iconOnly)
                                .frame(minHeight: DashboardStyle.minimumTarget)
                        }
                        .help(L10n.text("测试\(state.displayName)震动", "Test \(state.displayName) haptics"))
                        .accessibilityLabel(L10n.text("测试\(state.displayName)震动", "Test \(state.displayName) haptics"))
                    }
                }.buttonStyle(.bordered).disabled(!presentation.canTestHaptics)
                Text(presentation.canTestHaptics
                     ? L10n.text("短暂测试硬件反馈，不改变任务状态。", "Briefly test hardware feedback without changing task state.")
                     : L10n.text("需要已连接且支持震动的控制器。", "Connect a controller with available haptics to test."))
                    .font(.caption).foregroundStyle(.secondary)
                if !store.actionMessage.isEmpty {
                    Label(store.actionMessage, systemImage: "info.circle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var adapterRows: [(String, String)] {
        [
            (L10n.text("连接", "Connection"), !presentation.isFresh ? presentation.unknown : status.rp2040
                ? L10n.text("已连接", "Connected") : L10n.text("未连接", "Disconnected")),
            (L10n.text("模式", "Mode"), !presentation.isFresh ? presentation.unknown : status.mode == "legacy-app-server"
                ? L10n.text("软件兼容", "Software Compatibility") : L10n.text("适配器连接", "Adapter Connection")),
        ]
    }
    private var runtimeRows: [(String, String)] {
        [
            (L10n.text("输入模式", "Input Mode"), presentation.isFresh ? status.activeOperationMode.displayName : presentation.unknown),
            (L10n.text("辅助功能", "Accessibility"), presentation.authorization(status.accessibility)),
            (L10n.text("输入监控", "Input Monitoring"), presentation.authorization(status.inputMonitoring)),
        ]
    }
    @ViewBuilder private var permissionActions: some View {
        Button(L10n.text("辅助功能", "Accessibility")) {
            DashboardSystemSettings.open(.accessibility)
        }
        Button(L10n.text("输入监控", "Input Monitoring")) {
            DashboardSystemSettings.open(.inputMonitoring)
        }
        Button(L10n.text("在 Finder 中显示", "Show in Finder")) {
            CurrentApplication.revealInFinder()
        }
    }
    private func group(
        _ title: String,
        symbol: String,
        rows: [(String, String)],
        columns: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DashboardStyle.Space.medium, alignment: .topLeading),
                    count: columns
                ),
                alignment: .leading,
                spacing: DashboardStyle.Space.small
            ) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DashboardStyle.Space.tiny) {
                        Text(row.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.1)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
