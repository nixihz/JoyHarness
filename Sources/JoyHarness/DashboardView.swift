import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @State private var detailsPresented = false

    init(
        store: DashboardStore,
        mappingStore: ControllerMappingStore,
        detailsPresented: Bool = false
    ) {
        self.store = store
        self.mappingStore = mappingStore
        _detailsPresented = State(initialValue: detailsPresented)
    }

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness, mappingStore: mappingStore)
    }

    var body: some View {
        let _ = languageSettings.preference
        HStack(spacing: 0) {
            mainContent
            if detailsPresented {
                Divider()
                detailsInspector
                    .frame(width: DashboardStyle.detailsColumnWidth, height: DashboardStyle.windowHeight)
            }
        }
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
        .background(DashboardWindowVisibilityBridge(detailsPresented: detailsPresented))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                detailsButton
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.inset) {
            header
            notices
            DashboardControllerView(store: store, mappingStore: mappingStore, compact: false)
                .frame(maxHeight: .infinity)
            Divider()
            HStack {
                DashboardSettingsButton(tab: .general).buttonStyle(.borderless)
                Spacer()
                Text(AppVersion.displayName).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(DashboardStyle.Space.section)
        .frame(width: DashboardStyle.windowWidth, height: DashboardStyle.windowHeight)
    }

    private var detailsButton: some View {
        Button {
            detailsPresented.toggle()
        } label: {
            Label(
                detailsPresented
                    ? L10n.text("隐藏连接详情", "Hide Connection Details")
                    : L10n.text("显示连接详情", "Show Connection Details"),
                systemImage: "sidebar.trailing"
            )
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(detailsPresented ? Color.accentColor : Color.primary)
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(detailsPresented
            ? L10n.text("隐藏连接详情", "Hide Connection Details")
            : L10n.text("显示连接详情", "Show Connection Details"))
        .accessibilityValue(detailsPresented
            ? L10n.text("已展开", "Expanded")
            : L10n.text("已收起", "Collapsed"))
    }

    private var detailsInspector: some View {
        VStack(spacing: 0) {
            Label(
                L10n.text("连接详情", "Connection Details"),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DashboardStyle.Space.inset)
            .padding(.vertical, DashboardStyle.Space.medium)

            Divider()

            ViewThatFits(in: .vertical) {
                connectionDetails.fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    connectionDetails
                }
            }
            .padding(DashboardStyle.Space.inset)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var connectionDetails: some View {
        DashboardConnectionDetails(store: store, mappingStore: mappingStore)
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
            deviceSwitcher
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DashboardStyle.Space.inset) { summaryBadges }
                VStack(alignment: .leading, spacing: DashboardStyle.Space.small) { summaryBadges }
            }
        }
    }

    /// Shown only with several devices connected. The selection also follows
    /// the device that was pressed last. It only changes what the Dashboard
    /// shows; Settings keeps its own device to configure.
    @ViewBuilder private var deviceSwitcher: some View {
        if mappingStore.connectedDevices.count > 1 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DashboardStyle.Space.medium) {
                    devicePicker.pickerStyle(.segmented).fixedSize()
                    deviceSwitcherHint
                    Spacer(minLength: 0)
                }
                HStack(spacing: DashboardStyle.Space.medium) {
                    devicePicker.pickerStyle(.segmented).fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(spacing: DashboardStyle.Space.medium) {
                    devicePicker.pickerStyle(.menu).fixedSize()
                    deviceSwitcherHint
                    Spacer(minLength: 0)
                }
                HStack(spacing: DashboardStyle.Space.medium) {
                    devicePicker.pickerStyle(.menu).fixedSize()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var devicePicker: some View {
        let titles = ConnectedControllerDescriptor.pickerTitles(for: mappingStore.connectedDevices)
        return Picker(
            L10n.text("显示设备", "Displayed Device"),
            selection: Binding(
                get: { mappingStore.displayedDeviceID },
                set: { mappingStore.requestDisplayedDevice($0) }
            )
        ) {
            ForEach(mappingStore.connectedDevices) { device in
                Text(titles[device.id] ?? device.displayName).tag(device.id)
            }
        }
        .labelsHidden()
        .help(Self.deviceSwitcherHintText)
        .accessibilityHint(Self.deviceSwitcherHintText)
    }

    private var deviceSwitcherHint: some View {
        Label(Self.deviceSwitcherHintText, systemImage: "hand.tap")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private static var deviceSwitcherHintText: String {
        L10n.text("按下任一设备的按键即可切换到该设备", "Press a button on any device to show it")
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

    private var notices: some View {
        VStack(spacing: DashboardStyle.Space.small) {
            noticeItems
        }
    }

    @ViewBuilder private var noticeItems: some View {
        if !presentation.isFresh {
            notice("exclamationmark.triangle", L10n.text("设备状态尚未更新。刷新状态以重新读取连接与权限信息。", "Device status is unavailable or out of date. Refresh to read connections and permissions.")) {
                Button(L10n.text("刷新状态", "Refresh Status")) { store.perform(.refresh) }
            }
        } else if store.status.isNativeMode {
            notice("pause.circle", L10n.text("映射已暂停 · 原生手柄模式", "Mappings paused · Native gamepad mode") +
                (store.status.frontmostAppName.map { " · " + $0 } ?? "") + "\n" +
                L10n.text("按 PS/Home 键恢复映射，或调整原生模式设置。", "Press PS/Home to resume mappings, or adjust Native Mode settings.")) {
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
                    VStack(alignment: .trailing, spacing: DashboardStyle.Space.small) {
                        Button {
                            DashboardSystemSettings.open(.inputMonitoring)
                        } label: {
                            Label(L10n.text("打开输入监控设置", "Open Input Monitoring"), systemImage: "gearshape")
                        }
                        Button {
                            CurrentApplication.revealInFinder()
                        } label: {
                            Label(L10n.text("在 Finder 中显示当前应用", "Show Current App in Finder"), systemImage: "folder")
                        }
                    }
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

private struct DashboardWindowVisibilityBridge: NSViewRepresentable {
    let detailsPresented: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard detailsPresented else { return }
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window, let screen = window.screen else { return }
            let frame = window.frame
            let visibleFrame = screen.visibleFrame
            let maximumX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
            let maximumY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
            let origin = NSPoint(
                x: min(max(frame.minX, visibleFrame.minX), maximumX),
                y: min(max(frame.minY, visibleFrame.minY), maximumY)
            )
            guard origin != frame.origin else { return }
            window.setFrameOrigin(origin)
        }
    }
}
