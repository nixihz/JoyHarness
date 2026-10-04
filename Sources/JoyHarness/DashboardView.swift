import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    @ObservedObject var harnessProviderSettings: HarnessProviderSettings
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsPresented = false

    init(
        store: DashboardStore,
        mappingStore: ControllerMappingStore,
        harnessProviderSettings: HarnessProviderSettings,
        detailsPresented: Bool = false
    ) {
        self.store = store
        self.mappingStore = mappingStore
        self.harnessProviderSettings = harnessProviderSettings
        _detailsPresented = State(initialValue: detailsPresented)
    }

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness, mappingStore: mappingStore)
    }

    var body: some View {
        let _ = languageSettings.preference
        // The inspector toggles instantly: it is often opened from the keyboard.
        HStack(spacing: 0) {
            mainContent
            if detailsPresented {
                Divider()
                detailsInspector
                    .frame(width: DashboardStyle.detailsColumnWidth, height: DashboardStyle.windowHeight)
            }
        }
        .fixedSize()
        .background(DashboardAmbientCanvas())
        .background(DashboardWindowVisibilityBridge(detailsPresented: detailsPresented))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                harnessLabel
                detailsButton
                DashboardSettingsButton(tab: .general).labelStyle(.iconOnly)
            }
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.medium) {
            header
            notices
            DashboardControllerView(store: store, mappingStore: mappingStore, compact: false)
                .frame(maxHeight: .infinity)
        }
        .padding([.horizontal, .bottom], DashboardStyle.Space.inset)
        .padding(.top, DashboardStyle.Space.small)
        .frame(width: DashboardStyle.windowWidth, height: DashboardStyle.windowHeight)
    }

    // MARK: Toolbar

    /// Read-only: the current Harness decides which mappings are shown.
    /// PS/Home or Settings change it.
    private var harnessLabel: some View {
        let provider = harnessProviderSettings.activeProvider
        let name = provider?.displayName ?? L10n.text("未启用 Harness", "No Active Harness")
        let applicationURL = provider?.installedApplicationURL()
        let hint = L10n.text("当前 Harness：\(name)。按 PS/Home 键切换。", "Current Harness: \(name). Press PS/Home to switch.")
        return Label {
            Text(name)
        } icon: {
            Image(nsImage: ApplicationPresentation.icon(
                forApplicationAt: applicationURL,
                size: DashboardStyle.toolbarAppIconSize
            ))
            .renderingMode(applicationURL == nil ? .template : .original)
            .resizable()
            .scaledToFit()
            .frame(width: DashboardStyle.toolbarAppIconSize, height: DashboardStyle.toolbarAppIconSize)
        }
        .labelStyle(.titleAndIcon)
        .font(.callout.weight(.medium))
        .padding(.horizontal, DashboardStyle.Space.small)
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hint)
    }

    private var detailsButton: some View {
        let title = detailsPresented
            ? L10n.text("隐藏连接详情", "Hide Connection Details")
            : L10n.text("显示连接详情", "Show Connection Details")
        return Button {
            detailsPresented.toggle()
        } label: {
            Label(title, systemImage: "sidebar.trailing")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(detailsPresented ? Color.accentColor : Color.primary)
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(title)
        .accessibilityValue(detailsPresented
            ? L10n.text("已展开", "Expanded")
            : L10n.text("已收起", "Collapsed"))
    }

    // MARK: Header

    private var headerTitle: String {
        guard presentation.connected == true else { return L10n.text("控制器与输入", "Controller & Input") }
        return DashboardPresentation.headerTitle(
            devices: mappingStore.connectedDevices,
            displayedID: mappingStore.displayedDeviceID,
            fallback: store.status.controller
        )
    }

    private var deviceSymbol: String {
        guard presentation.connected == true else { return "gamecontroller" }
        return presentation.family == .xiaomiRemote ? "appletvremote.gen4.fill" : "gamecontroller.fill"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DashboardStyle.Space.medium) {
            Image(systemName: deviceSymbol)
                .font(.title2)
                .foregroundStyle(presentation.connected == true ? Color.primary : Color.secondary)
                .frame(width: DashboardStyle.deviceGlyphSize, height: DashboardStyle.deviceGlyphSize)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DashboardStyle.Space.tiny) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DashboardStyle.Space.medium) { summaryBadges }
                    VStack(alignment: .leading, spacing: DashboardStyle.Space.tiny) { summaryBadges }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: DashboardStyle.Space.small)
            deviceSwitcher
        }
        .padding(DashboardStyle.Space.medium)
        .dashboardGlass()
    }

    /// Shown only with several devices connected. The selection also follows
    /// the device that was pressed last. It only changes what the Dashboard
    /// shows; Settings keeps its own device to configure.
    @ViewBuilder private var deviceSwitcher: some View {
        if mappingStore.connectedDevices.count > 1 {
            ViewThatFits(in: .horizontal) {
                devicePicker.pickerStyle(.segmented).fixedSize()
                devicePicker.pickerStyle(.menu).fixedSize()
            }
        }
    }

    private var devicePicker: some View {
        // The title already names the device; the switcher uses short family names.
        let titles = ConnectedControllerDescriptor.pickerTitles(for: mappingStore.connectedDevices, name: \.family.displayName)
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

    private static var deviceSwitcherHintText: String {
        L10n.text("按下任一设备的按键即可切换到该设备", "Press a button on any device to show it")
    }

    @ViewBuilder private var summaryBadges: some View {
        DashboardBadge(
            title: presentation.connectionTitle,
            symbol: presentation.connectionSymbol,
            color: presentation.connected == true ? .green : .secondary
        )
        DashboardBadge(
            title: presentation.isFresh ? store.status.activeOperationMode.displayName : L10n.text("模式未知", "Mode unknown"),
            symbol: store.status.isNativeMode ? "gamecontroller" : "keyboard",
            color: store.status.isNativeMode && presentation.isFresh ? .accentColor : .secondary
        )
        DashboardBadge(
            title: presentation.permissionSummary,
            symbol: permissionsGranted ? "lock.shield.fill" : "lock.shield",
            color: permissionsGranted ? .green : presentation.isFresh ? .orange : .secondary
        )
        if presentation.connected == true,
           let symbol = presentation.batterySymbol(store.status.controllerBatteryLevel) {
            DashboardBadge(title: presentation.batteryDescription(store.status.controllerBatteryLevel), symbol: symbol)
        }
    }

    private var permissionsGranted: Bool {
        presentation.isFresh && store.status.accessibility && store.status.inputMonitoring == true
    }

    // MARK: Notices

    private var notices: some View {
        let kinds = presentation.notices
        return VStack(spacing: DashboardStyle.Space.small) {
            ForEach(kinds, id: \.self) { kind in
                notice(kind)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : DashboardStyle.Motion.easeOut(DashboardStyle.Motion.noticeEnter), value: kinds)
    }

    @ViewBuilder private func notice(_ kind: DashboardNoticeKind) -> some View {
        switch kind {
        case .stale:
            DashboardNotice(
                severity: .attention,
                symbol: "exclamationmark.triangle.fill",
                title: L10n.text("设备状态尚未更新", "Device status is out of date"),
                message: L10n.text("刷新状态以重新读取连接与权限信息。", "Refresh to read connections and permissions again.")
            ) {
                Button(L10n.text("刷新状态", "Refresh Status")) { store.perform(.refresh) }
            }
        case .nativeMode:
            DashboardNotice(
                severity: .info,
                symbol: "pause.circle.fill",
                title: L10n.text("映射已暂停 · 原生手柄模式", "Mappings paused · Native gamepad mode")
                    + (store.status.frontmostAppName.map { " · " + $0 } ?? ""),
                message: L10n.text("按 PS/Home 键恢复映射，或调整原生模式设置。", "Press PS/Home to resume mappings, or adjust Native Mode settings.")
            ) {
                DashboardSettingsButton(tab: .nativeMode).labelStyle(.titleOnly)
            }
        case .accessibility:
            DashboardNotice(
                severity: .attention,
                symbol: "hand.raised.fill",
                title: L10n.text("辅助功能未授权", "Accessibility is not authorized"),
                message: L10n.text("鼠标控制受限。打开系统设置以允许 Joy Harness 控制指针。", "Pointer control is limited. Allow Joy Harness in System Settings.")
            ) {
                Button(L10n.text("开启权限", "Open Permissions")) { DashboardSystemSettings.open(.accessibility) }
            }
        case .inputMonitoring:
            DashboardNotice(
                severity: .attention,
                symbol: "keyboard",
                title: L10n.text("输入监控未授权", "Input Monitoring is not authorized"),
                message: L10n.text("后台手柄输入受限。在系统设置中添加当前应用。", "Background controller input is limited. Add this app in System Settings.")
            ) {
                HStack(spacing: DashboardStyle.Space.small) {
                    Button {
                        CurrentApplication.revealInFinder()
                    } label: {
                        Label(L10n.text("在 Finder 中显示当前应用", "Show Current App in Finder"), systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("在 Finder 中显示当前应用", "Show Current App in Finder"))
                    Button(L10n.text("打开输入监控设置", "Open Input Monitoring")) { DashboardSystemSettings.open(.inputMonitoring) }
                }
            }
        case .adapter:
            DashboardNotice(
                severity: .attention,
                symbol: "cable.connector",
                title: L10n.text("适配器未连接", "Adapter disconnected"),
                message: L10n.text("需要适配器的映射暂不可用。通过 USB 连接 RP2040 适配器。", "Mappings that require it are unavailable. Connect the RP2040 adapter over USB.")
            ) {
                EmptyView()
            }
        }
    }

    // MARK: Inspector

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

            ScrollView {
                DashboardConnectionDetails(store: store, mappingStore: mappingStore)
                    .padding(DashboardStyle.Space.inset)
            }
        }
        .background(.thinMaterial)
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
