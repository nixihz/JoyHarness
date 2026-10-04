import SwiftUI

struct DashboardControllerView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var functionLayer = false
    @State private var pendingScrollInput: ControllerInput?

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
    private var sections: [(group: ControllerInputGroup, inputs: [ControllerInput])] {
        ControllerInputGroup.allCases.compactMap { group in
            let members = inputs.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }
    private var activeInputs: Set<ControllerInput> {
        presentation.connected == true ? store.pressedControllerInputs : []
    }
    private var hasFunctionLayer: Bool { displayedInputs.contains { $0.group == .functionLayer } }

    var body: some View {
        if presentation.connected != true {
            emptyState
        } else {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: DashboardStyle.Space.medium))
                : AnyLayout(HStackLayout(alignment: .top, spacing: DashboardStyle.Space.medium))
            let profile = mappingStore.profile(for: family)
            layout {
                stage(profile)
                    .frame(width: compact ? nil : DashboardStyle.stageWidth)
                    .frame(maxHeight: .infinity)
                mappingCard(profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: family) { _ in
                // A press can select a different controller and its layer in
                // the same update. Do not clear that press's scroll target.
                guard activeInputs.isEmpty else { return }
                functionLayer = false
                pendingScrollInput = nil
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: DashboardStyle.Space.inset) {
            Image(systemName: presentation.connected == nil ? "questionmark" : "gamecontroller")
                .font(.system(size: DashboardStyle.emptyIconSize))
                .foregroundStyle(.secondary)
                .frame(width: DashboardStyle.emptyIconWell, height: DashboardStyle.emptyIconWell)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: DashboardStyle.Space.small) {
                Text(presentation.connected == nil
                     ? L10n.text("等待设备状态", "Waiting for device status")
                     : L10n.text("连接你的输入设备", "Connect your input device"))
                    .font(.title2.weight(.semibold))
                Text(presentation.connected == nil
                     ? L10n.text("尚未确认设备是否连接。刷新状态后，将显示对应设备和按键映射。", "The device connection has not been confirmed. Refresh status to see the device and its mappings.")
                     : L10n.text("通过蓝牙或 USB 连接遥控器、PlayStation、Xbox 或 Joy-Con。连接后显示对应按键与映射。", "Connect a remote, PlayStation, Xbox or Joy-Con via Bluetooth or USB to see its buttons and mappings."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: DashboardStyle.emptyMessageWidth)
            HStack(spacing: DashboardStyle.Space.medium) {
                Button(L10n.text("重新扫描控制器", "Rescan Controllers")) { store.perform(.rescanControllers) }
                    .buttonStyle(.borderedProminent)
                Button(L10n.text("打开蓝牙设置", "Open Bluetooth Settings")) { DashboardSystemSettings.open(.bluetooth) }
                    .buttonStyle(.bordered)
            }
            if !store.actionMessage.isEmpty {
                Text(store.actionMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(DashboardStyle.Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dashboardGlass()
    }

    // MARK: Stage

    private func stage(_ profile: ControllerMappingProfile) -> some View {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            readout(profile)
        }
        .padding(DashboardStyle.Space.medium)
        .dashboardGlass()
    }

    /// Live input feedback. It swaps instantly: inputs arrive many times a minute.
    private func readout(_ profile: ControllerMappingProfile) -> some View {
        let pressed = !activeInputs.isEmpty
        let current = ControllerInput.allCases.filter((pressed ? activeInputs : store.lastControllerInputs).contains)
        return HStack(spacing: DashboardStyle.Space.small) {
            if current.isEmpty {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text(L10n.text("按下设备按键，查看实时反馈", "Press a button to see live feedback"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(current.prefix(3), id: \.rawValue) { input in
                    DashboardKeycap(title: profile.displayName(for: input), active: pressed)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(readoutAction(current, profile: profile))
                    .foregroundStyle(pressed ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, DashboardStyle.Space.small)
        .frame(minHeight: DashboardStyle.readoutHeight)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readoutAccessibilityLabel(current, pressed: pressed, profile: profile))
    }

    private func readoutAction(_ current: [ControllerInput], profile: ControllerMappingProfile) -> String {
        if store.status.isNativeMode { return L10n.text("映射已暂停", "Mappings paused") }
        guard current.count == 1, let input = current.first else {
            return L10n.text("\(current.count) 个输入", "\(current.count) inputs")
        }
        return Self.actionTitle(input, profile: profile)
    }

    private func readoutAccessibilityLabel(_ current: [ControllerInput], pressed: Bool, profile: ControllerMappingProfile) -> String {
        guard !current.isEmpty else { return L10n.text("等待输入", "Waiting for input") }
        let names = current.map { profile.displayName(for: $0) }.joined(separator: " + ")
        return names + ", " + readoutAction(current, profile: profile) + ", "
            + (pressed ? L10n.text("按下", "Pressed") : L10n.text("已释放", "Released"))
    }

    // MARK: Mappings

    private func mappingCard(_ profile: ControllerMappingProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DashboardStyle.Space.small) {
                HStack(alignment: .firstTextBaseline, spacing: DashboardStyle.Space.small) {
                    Text(L10n.text("按键映射", "Button Mappings")).font(.headline)
                    Text(L10n.text("\(inputs.count) 项", "\(inputs.count) inputs"))
                        .font(.caption).foregroundStyle(.secondary)
                    if store.status.isNativeMode {
                        Label(L10n.text("已暂停", "Paused"), systemImage: "pause.circle")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                    DashboardSettingsButton()
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                }
                if hasFunctionLayer {
                    Picker(L10n.text("映射层", "Mapping Layer"), selection: $functionLayer) {
                        Text(L10n.text("基础按键", "Base Buttons")).tag(false)
                        Text(L10n.text("功能层", "Function Layer")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(DashboardStyle.Space.medium)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.group) { section in
                            if sections.count > 1 {
                                Text(section.group.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, DashboardStyle.Space.medium)
                                    .padding(.top, DashboardStyle.Space.medium)
                                    .padding(.bottom, DashboardStyle.Space.tiny)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(section.inputs, id: \.rawValue) { input in
                                mappingRow(input, profile: profile).id(input)
                            }
                        }
                    }
                    .padding(.vertical, DashboardStyle.Space.tiny)
                    .accessibilityElement(children: .contain)
                }
                // Bring a pressed input into view without animation: presses
                // are frequent and the highlight must appear immediately.
                .onChange(of: activeInputs) { [previous = activeInputs] pressed in
                    guard let input = DashboardPresentation.inputToReveal(
                        pressed: pressed, previous: previous, displayed: displayedInputs
                    ) else { return }
                    let needsFunctionLayer = input.group == .functionLayer
                    if functionLayer == needsFunctionLayer {
                        pendingScrollInput = nil
                        proxy.scrollTo(input)
                    } else {
                        pendingScrollInput = input
                        functionLayer = needsFunctionLayer
                    }
                }
                .onChange(of: inputs) { visibleInputs in
                    // The destination row exists only after its layer renders.
                    guard let input = pendingScrollInput, visibleInputs.contains(input) else { return }
                    proxy.scrollTo(input)
                    pendingScrollInput = nil
                }
            }
        }
        .dashboardGlass()
    }

    private func mappingRow(_ input: ControllerInput, profile: ControllerMappingProfile) -> some View {
        let active = activeInputs.contains(input) && !presentation.mappingPaused
        let actionTitle = Self.actionTitle(input, profile: profile)
        return HStack(alignment: .center, spacing: DashboardStyle.Space.medium) {
            DashboardKeycap(title: profile.displayName(for: input), active: active)
                .frame(width: DashboardStyle.keyWidth, alignment: .leading)
            Text(actionTitle)
                .foregroundStyle(presentation.mappingPaused ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DashboardStyle.Space.small)
        .padding(.vertical, DashboardStyle.Space.tiny)
        .frame(minHeight: DashboardStyle.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: DashboardStyle.Radius.inner, style: .continuous)
                .fill(DashboardStyle.input.opacity(active ? DashboardStyle.activeRowOpacity : 0))
        }
        .padding(.horizontal, DashboardStyle.Space.tiny)
        // Press shows at once; release fades out within the budget.
        .animation(reduceMotion || active ? nil : DashboardStyle.Motion.easeOut(DashboardStyle.Motion.keyRelease), value: active)
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
}
