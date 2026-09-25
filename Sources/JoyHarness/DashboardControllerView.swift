import SwiftUI

struct DashboardControllerView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var functionLayer = false

    private var presentation: DashboardPresentation {
        DashboardPresentation(status: store.status, freshness: store.freshness)
    }
    /// The displayed device's family. Settings may be editing another
    /// device's profile at the same time.
    private var family: ControllerFamily { presentation.family }
    private var displayedInputs: Set<ControllerInput> { mappingStore.displayedInputs(for: family) }
    private var inputs: [ControllerInput] {
        ControllerInput.allCases.filter {
            displayedInputs.contains($0) && (($0.group == .functionLayer) == functionLayer)
        }
    }
    private var activeInputs: Set<ControllerInput> {
        presentation.connected == true ? store.pressedControllerInputs : []
    }
    private var hasFunctionLayer: Bool { displayedInputs.contains { $0.group == .functionLayer } }

    var body: some View {
        if presentation.connected != true {
            VStack(spacing: DashboardStyle.Space.inset) {
                Image(systemName: "gamecontroller").font(.system(size: DashboardStyle.emptyIconSize)).foregroundStyle(.secondary)
                Text(presentation.connected == nil ? L10n.text("等待设备状态", "Waiting for device status") : L10n.text("连接你的输入设备", "Connect your input device")).font(.title2)
                Text(presentation.connected == nil
                     ? L10n.text("尚未确认设备是否连接。刷新状态后，将显示对应设备和按键映射。", "The device connection has not been confirmed. Refresh status to see the device and its mappings.")
                     : L10n.text("通过蓝牙或 USB 连接遥控器、PlayStation、Xbox 或 Joy-Con。连接后显示对应按键与映射。", "Connect a remote, PlayStation, Xbox or Joy-Con via Bluetooth or USB to see its buttons and mappings."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: DashboardStyle.Space.medium) {
                    Button(L10n.text("重新扫描控制器", "Rescan Controllers")) { store.perform(.rescanControllers) }
                    Button(L10n.text("打开蓝牙设置", "Open Bluetooth Settings")) { DashboardSystemSettings.open(.bluetooth) }
                }.buttonStyle(.bordered)
                actionFeedback
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DashboardStyle.Space.page)
        } else {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: DashboardStyle.Space.section))
                : AnyLayout(HStackLayout(alignment: .top, spacing: DashboardStyle.Space.section))
            let profile = mappingStore.profile(for: family)
            layout {
                device(profile).frame(maxWidth: .infinity)
                mapping(profile).frame(maxWidth: .infinity)
            }
            .onChange(of: family) { _ in functionLayer = false }
        }
    }

    private func device(_ profile: ControllerMappingProfile) -> some View {
        VStack(spacing: DashboardStyle.Space.medium) {
            if family == .joyConLeft || family == .joyConRight {
                Picker(L10n.text("握持方向", "Grip Orientation"), selection: Binding(
                    get: { mappingStore.joyConOrientation(for: family) },
                    set: { mappingStore.setJoyConOrientation($0, for: family) }
                )) {
                    ForEach(JoyConOrientation.allCases, id: \.rawValue) { orientation in
                        Text(orientation.displayName).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: DashboardStyle.gripPickerWidth)
            }
            ControllerArtwork(family: family, orientation: profile.joyConOrientation,
                pressedInputs: activeInputs)
                .frame(maxWidth: DashboardStyle.artworkWidth)
                .frame(height: DashboardStyle.artworkHeight)
                .accessibilityHidden(true)
            VStack(spacing: DashboardStyle.Space.small) {
                Label(inputTitle(profile), systemImage: activeInputs.isEmpty ? "hand.tap" : "smallcircle.filled.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(activeInputs.isEmpty ? Color.secondary : DashboardStyle.input)
                Text(store.status.isNativeMode
                     ? L10n.text("仅显示物理输入 · 映射已暂停", "Physical input only · Mappings paused")
                     : L10n.text("按下设备按键，查看实时反馈", "Press a button to see live input feedback"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: DashboardStyle.feedbackHeight)
            .accessibilityElement(children: .combine)
        }
    }

    private func inputTitle(_ profile: ControllerMappingProfile) -> String {
        let current = activeInputs.isEmpty ? store.lastControllerInputs : activeInputs
        guard !current.isEmpty else { return L10n.text("等待输入", "Waiting for input") }
        let names = Set(current.map { profile.displayName(for: $0) }).sorted().joined(separator: " + ")
        return names + " · " + (activeInputs.isEmpty ? L10n.text("已释放", "Released") : L10n.text("按下", "Pressed"))
    }

    private func mapping(_ profile: ControllerMappingProfile) -> some View {
        VStack(alignment: .leading, spacing: DashboardStyle.Space.medium) {
            HStack {
                Text(L10n.text("按键映射", "Button Mappings")).font(.headline)
                Spacer()
                Text(L10n.text("\(inputs.count) 项", "\(inputs.count) inputs")).font(.caption).foregroundStyle(.secondary)
            }
            if hasFunctionLayer {
                Picker(L10n.text("映射层", "Mapping Layer"), selection: $functionLayer) {
                    Text(L10n.text("基础按键", "Base Buttons")).tag(false)
                    Text(L10n.text("功能层", "Function Layer")).tag(true)
                }.pickerStyle(.segmented)
            }
            if store.status.isNativeMode {
                Label(L10n.text("映射已暂停，以下仅供参考", "Mappings paused; shown for reference"), systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(inputs, id: \.rawValue) { input in
                        mappingRow(input, profile: profile)
                        Divider()
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .frame(height: DashboardStyle.mappingHeight)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DashboardStyle.cornerRadius))
        }
    }

    private func mappingRow(_ input: ControllerInput, profile: ControllerMappingProfile) -> some View {
        let active = activeInputs.contains(input) && !presentation.mappingPaused
        let actionTitle = Self.actionTitle(input, profile: profile)
        return HStack(alignment: .firstTextBaseline, spacing: DashboardStyle.Space.small) {
            Text(profile.displayName(for: input))
                .font(.body.weight(.medium))
                .frame(width: DashboardStyle.keyWidth, alignment: .leading)
            Image(systemName: active ? "smallcircle.filled.circle" : "arrow.right")
                .foregroundStyle(active ? DashboardStyle.input : .secondary).accessibilityHidden(true)
            Text(actionTitle).frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DashboardStyle.Space.small)
        .frame(minHeight: DashboardStyle.minimumTarget)
        .background(active ? DashboardStyle.input.opacity(DashboardStyle.highlightFillOpacity) : .clear)
        .animation(reduceMotion || active ? nil : .easeOut(duration: DashboardStyle.keyRelease), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.displayName(for: input) + ", " + actionTitle)
        .accessibilityValue(active ? L10n.text("输入按下", "Input pressed") : "")
    }

    static func actionTitle(_ input: ControllerInput, profile: ControllerMappingProfile) -> String {
        if !profile.isReservedForHarnessSwitcher(input),
           profile.action(for: input) == .openApplication,
           let name = profile.openApplicationDisplayName(for: input) {
            return L10n.text("打开 ", "Open ") + name
        }
        return profile.mappedActionDisplayName(for: input)
    }

    @ViewBuilder private var actionFeedback: some View {
        if !store.actionMessage.isEmpty { Text(store.actionMessage).font(.caption).foregroundStyle(.secondary) }
    }
}
