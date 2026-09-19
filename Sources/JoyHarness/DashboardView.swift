import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @State private var detailsExpanded = true

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness, orientation: mappingStore.joyConOrientation)
    }

    var body: some View {
        let _ = languageSettings.preference
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DashboardStyle.Space.section) {
                    header
                    notices
                    DashboardControllerView(store: store, mappingStore: mappingStore,
                        compact: geometry.size.width < DashboardStyle.compactBreakpoint)
                    Divider()
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        DashboardConnectionDetails(store: store, mappingStore: mappingStore,
                            compact: geometry.size.width < DashboardStyle.compactBreakpoint)
                            .padding(.top, DashboardStyle.Space.inset)
                    } label: {
                        Label(L10n.text("连接详情", "Connection Details"), systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                    }
                    Divider()
                    HStack {
                        DashboardSettingsButton(tab: .general).buttonStyle(.borderless)
                        Spacer()
                        Text(AppVersion.displayName).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(DashboardStyle.Space.section)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.medium) {
            HStack(alignment: .top, spacing: DashboardStyle.Space.inset) {
                Text(presentation.connected == true ? store.status.controller : L10n.text("控制器与输入", "Controller & Input"))
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                DashboardSettingsButton().buttonStyle(.borderedProminent).fixedSize()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DashboardStyle.Space.inset) { summaryBadges }
                VStack(alignment: .leading, spacing: DashboardStyle.Space.small) { summaryBadges }
            }
        }
    }

    @ViewBuilder private var summaryBadges: some View {
        DashboardBadge(title: presentation.connectionTitle, symbol: presentation.connectionSymbol,
            color: presentation.connected == true ? .green : .secondary)
        DashboardBadge(title: presentation.isFresh ? store.status.activeOperationMode.displayName : L10n.text("模式未知", "Mode unknown"),
            symbol: store.status.isNativeMode ? "gamecontroller" : "keyboard")
        DashboardBadge(title: presentation.permissionSummary, symbol: "lock.shield")
        if presentation.connected == true, store.status.controllerBatteryLevel != nil {
            DashboardBadge(title: presentation.batteryDescription(store.status.controllerBatteryLevel), symbol: "battery.100")
        }
    }

    @ViewBuilder private var notices: some View {
        if !presentation.isFresh {
            notice("exclamationmark.triangle", L10n.text("设备状态尚未更新。刷新状态以重新读取连接与权限信息。", "Device status is unavailable or out of date. Refresh to read connections and permissions.")) {
                Button(L10n.text("刷新状态", "Refresh Status")) { store.perform(.refresh) }
            }
        } else if store.status.isNativeMode {
            notice("pause.circle", L10n.text("映射已暂停 · 原生手柄模式", "Mappings paused · Native gamepad mode") +
                (store.status.frontmostAppName.map { " · " + $0 } ?? "") + "\n" +
                L10n.text("使用模式切换按键恢复映射，或调整原生模式设置。", "Use your mode switch button to resume mappings, or adjust Native Mode settings.")) {
                DashboardSettingsButton(tab: .nativeMode)
            }
        }
        if presentation.isFresh && !store.status.isNativeMode {
            if !store.status.accessibility {
                notice("hand.raised", L10n.text("辅助功能未授权，鼠标控制受限。", "Accessibility is not authorized. Pointer control is limited.")) {
                    Button(L10n.text("开启权限", "Open Permissions")) { DashboardSystemSettings.open(.accessibility) }
                }
            }
            if store.status.inputMonitoring == false {
                notice("keyboard", L10n.text("输入监控未授权，后台手柄输入受限。", "Input Monitoring is not authorized. Background controller input is limited.")) {
                    Button(L10n.text("开启权限", "Open Permissions")) { DashboardSystemSettings.open(.inputMonitoring) }
                }
            }
            if !store.status.rp2040 {
                notice("cable.connector", L10n.text("适配器未连接，需要适配器的映射暂不可用。请连接适配器。", "Adapter disconnected. Mappings that require it are unavailable. Connect the adapter.")) {
                    EmptyView()
                }
            }
        }
    }

    private func notice<Action: View>(_ symbol: String, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: DashboardStyle.Space.medium) {
            Image(systemName: symbol).foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action().buttonStyle(.bordered)
        }
        .padding(DashboardStyle.Space.medium)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DashboardStyle.cornerRadius))
    }
}
