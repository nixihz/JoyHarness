import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var mappingStore: ControllerMappingStore
    @EnvironmentObject private var languageSettings: AppLanguageSettings

    var body: some View {
        HStack(spacing: 0) {
            SlotSidebar(store: store)
                .frame(width: 224)

            Divider()

            TaskDetail(store: store, mappingStore: mappingStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ConnectionInspector(status: store.status, store: store, mappingStore: mappingStore)
                .frame(width: 252)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .id(languageSettings.preference)
    }
}

private struct SlotSidebar: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("任务槽位", "Task Slots"))
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
                .taskSlotFocusEffectDisabled()
                .accessibilityLabel(
                    "\(L10n.text("槽位", "Slot")) \(slot.slot), \(slot.displayTitle), \(slot.padState.displayName)"
                )
            }

            Spacer(minLength: 12)
        }
        .background(.regularMaterial)
    }
}

private extension View {
    @ViewBuilder
    func taskSlotFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            focusable(false)
        }
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
                    Text(slot?.displayTitle ?? L10n.text("空槽位", "Empty Slot"))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Text("\(L10n.text("任务槽位", "Task Slot")) \(status.selectedSlot)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ControllerMap(
                status: status,
                pressedInputs: store.pressedControllerInputs,
                mappingStore: mappingStore
            )
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

private struct ControllerMap: View {
    let status: DashboardStatus
    let pressedInputs: Set<ControllerInput>
    @ObservedObject var mappingStore: ControllerMappingStore
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L10n.text("控制映射", "Key Mapping"), systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                if status.controllerConnected == true {
                    ControllerBatteryIndicator(
                        level: status.controllerBatteryLevel,
                        state: status.controllerBatteryState
                    )
                }
                if #available(macOS 14.0, *) {
                    OpenSettingsButton(tab: .controllerMapping) {
                        Label(L10n.text("自定义按键", "Customize Buttons"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("打开按键映射设置", "Open key mapping settings"))
                } else {
                    Button {
                        settingsCoordinator.select(.controllerMapping)
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    } label: {
                        Label(L10n.text("自定义按键", "Customize Buttons"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("打开按键映射设置", "Open key mapping settings"))
                }

                Text("\(mappingStore.controllerFamily.displayName) / Codex Micro")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if status.isNativeMode {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(.white)
                    Text(L10n.text("原生手柄模式（映射已暂停）", "Native Gamepad Mode (Mapping Paused)"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if let app = status.frontmostAppName, !app.isEmpty {
                        Text("• \(app)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Text(L10n.text("按 PS / Home 键切回映射模式", "Press PS / Home to switch back"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if isSingleJoyCon {
                HStack(spacing: 10) {
                    Text(L10n.text("握持方向", "Grip Orientation"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Picker(
                        L10n.text("握持方向", "Grip Orientation"),
                        selection: joyConOrientationBinding
                    ) {
                        ForEach(JoyConOrientation.allCases) { orientation in
                            Text(orientation.displayName).tag(orientation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    inputLabel(.functionDpadUp)
                    inputLabel(.functionDpadLeft)
                    inputLabel(.leftShoulder)
                    inputLabel(.rightShoulder)
                    inputLabel(.options)
                    inputLabel(.menu)
                    inputLabel(.home)
                    if mappingStore.controllerFamily == .dualSense || mappingStore.controllerFamily == .dualShock {
                        MappingLabel(key: key(for: .touchpadButton), title: title(for: .touchpadButton))
                    }
                    if mappingStore.availableInputs.contains(.dpadUp) {
                        MappingLabel(key: "D-Pad", title: dpadSummary)
                    }
                    inputLabel(.leftTrigger)
                    inputLabel(.leftThumbstickButton)
                    inputLabel(.functionLeftThumbstickButton)
                }
                .frame(width: 176, alignment: .leading)

                if let controllerArtwork {
                    ControllerArtwork(
                        items: controllerArtwork,
                        family: mappingStore.controllerFamily,
                        orientation: mappingStore.joyConOrientation,
                        pressedInputs: pressedInputs
                    )
                        .frame(minWidth: 220, maxWidth: 390, maxHeight: 270)
                        .accessibilityHidden(true)
                        .frame(minWidth: 220, maxWidth: .infinity)
                } else if usesControllerSymbol {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 112, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(pressedInputs.isEmpty ? Color.secondary : Color.accentColor)
                        .shadow(
                            color: pressedInputs.isEmpty ? .clear : Color.accentColor.opacity(0.65),
                            radius: 12
                        )
                        .animation(.easeOut(duration: 0.12), value: pressedInputs.isEmpty)
                        .frame(minWidth: 220, maxWidth: .infinity, maxHeight: 270)
                        .accessibilityLabel(mappingStore.controllerFamily.displayName)
                } else {
                    Label(
                        L10n.text("手柄资源加载失败", "Controller artwork failed to load"),
                        systemImage: "exclamationmark.triangle"
                    )
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 12) {
                    inputLabel(.buttonA)
                    inputLabel(.buttonB)
                    inputLabel(.buttonX)
                    inputLabel(.buttonY)
                    inputLabel(.functionButtonA)
                    inputLabel(.functionButtonB)
                    inputLabel(.functionButtonX)
                    inputLabel(.functionButtonY)
                    inputLabel(.rightTrigger)
                    inputLabel(.rightThumbstickButton)
                    inputLabel(.functionRightThumbstickButton)
                }
                .frame(width: 132, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .padding(18)
        .dashboardGlassSurface(cornerRadius: 7)
    }

    private var controllerArtwork: [LoadedControllerArtwork]? {
        let descriptors = mappingStore.controllerFamily.dashboardArtworkDescriptors(
            orientation: mappingStore.joyConOrientation
        )
        guard !descriptors.isEmpty else { return nil }
        let items = descriptors.compactMap { descriptor -> LoadedControllerArtwork? in
            let url = Bundle.main.url(
                forResource: descriptor.resource,
                withExtension: "png"
            ) ?? Bundle.module.url(
                forResource: descriptor.resource,
                withExtension: "png"
            )
            guard let url, let image = NSImage(contentsOf: url) else { return nil }
            return LoadedControllerArtwork(
                image: image,
                rotationDegrees: descriptor.rotationDegrees
            )
        }
        return items.count == descriptors.count ? items : nil
    }

    private var usesControllerSymbol: Bool {
        mappingStore.controllerFamily == .dualSense ||
            mappingStore.controllerFamily == .dualShock ||
            mappingStore.controllerFamily.isJoyCon
    }

    private var isSingleJoyCon: Bool {
        mappingStore.controllerFamily == .joyConLeft ||
            mappingStore.controllerFamily == .joyConRight
    }

    private var joyConOrientationBinding: Binding<JoyConOrientation> {
        Binding(
            get: { mappingStore.joyConOrientation },
            set: { mappingStore.setJoyConOrientation($0) }
        )
    }

    @ViewBuilder
    private func inputLabel(_ input: ControllerInput) -> some View {
        if mappingStore.availableInputs.contains(input) {
            MappingLabel(key: key(for: input), title: title(for: input))
        }
    }

    private func title(for input: ControllerInput) -> String {
        mappingStore.mappedActionDisplayName(for: input)
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
        return Set(actions).count == 1
            ? actions[0].displayName
            : L10n.text("自定义", "Custom")
    }
}

private struct ControllerArtwork: View {
    let items: [LoadedControllerArtwork]
    let family: ControllerFamily
    let orientation: JoyConOrientation
    let pressedInputs: Set<ControllerInput>

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Image(nsImage: item.image)
                            .resizable()
                            .scaledToFit()
                            .rotationEffect(.degrees(item.rotationDegrees))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                ForEach(activeHighlights) { highlight in
                    ControllerInputHighlight(highlight: highlight)
                        .scaleEffect(min(proxy.size.width / 390, 1))
                        .position(
                            x: highlight.center.x * proxy.size.width,
                            y: highlight.center.y * proxy.size.height
                        )
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: activeHighlights)
        }
        .aspectRatio(3 / 2, contentMode: .fit)
    }

    private var activeHighlights: [ControllerInputHighlightModel] {
        let physicalInputs = Set(pressedInputs.map(\.physicalInput))
        return physicalInputs.compactMap { input in
            ControllerInputHighlightModel.layout(for: family, orientation: orientation)[input]
        }.sorted { $0.input.rawValue < $1.input.rawValue }
    }
}

private struct LoadedControllerArtwork {
    let image: NSImage
    let rotationDegrees: Double
}

private struct ControllerInputHighlight: View {
    let highlight: ControllerInputHighlightModel
    
    var body: some View {
        RoundedRectangle(cornerRadius: highlight.cornerRadius, style: .continuous)
            .fill(Color.accentColor.opacity(0.36))
            .overlay {
                RoundedRectangle(cornerRadius: highlight.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
            }
            .shadow(color: Color.accentColor.opacity(0.9), radius: 9)
            .frame(width: highlight.size.width, height: highlight.size.height)
    }
}

struct ControllerInputHighlightModel: Identifiable, Equatable {
    let input: ControllerInput
    let center: CGPoint
    let size: CGSize
    let cornerRadius: CGFloat

    var id: ControllerInput { input }

    static func layout(
        for family: ControllerFamily,
        orientation: JoyConOrientation = .vertical
    ) -> [ControllerInput: Self] {
        switch family {
        case .dualSense, .dualShock: playStationLayout
        case .xbox, .generic: xboxLayout
        case .joyConPair: joyConPairLayout
        case .joyConLeft:
            orientation == .horizontal ? joyConLeftHorizontalLayout : joyConLeftVerticalLayout
        case .joyConRight:
            orientation == .horizontal ? joyConRightHorizontalLayout : joyConRightVerticalLayout
        }
    }

    private static func marker(
        _ input: ControllerInput,
        _ x: CGFloat,
        _ y: CGFloat,
        size: CGSize = CGSize(width: 31, height: 31),
        cornerRadius: CGFloat = 16
    ) -> Self {
        Self(input: input, center: CGPoint(x: x, y: y), size: size, cornerRadius: cornerRadius)
    }

    private static let xboxLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.75, 0.40), marker(.buttonB, 0.82, 0.30),
        marker(.buttonX, 0.68, 0.30), marker(.buttonY, 0.75, 0.20),
        marker(.dpadUp, 0.37, 0.45), marker(.dpadLeft, 0.33, 0.51),
        marker(.dpadDown, 0.37, 0.57), marker(.dpadRight, 0.41, 0.51),
        marker(.leftThumbstickButton, 0.24, 0.29, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.rightThumbstickButton, 0.63, 0.50, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.menu, 0.58, 0.30, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.options, 0.42, 0.30, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.home, 0.50, 0.38, size: CGSize(width: 32, height: 20), cornerRadius: 8),
        marker(.leftShoulder, 0.27, 0.07, size: CGSize(width: 64, height: 22), cornerRadius: 9),
        marker(.rightShoulder, 0.73, 0.07, size: CGSize(width: 64, height: 22), cornerRadius: 9),
        marker(.leftTrigger, 0.24, 0.035, size: CGSize(width: 58, height: 18), cornerRadius: 8),
        marker(.rightTrigger, 0.76, 0.035, size: CGSize(width: 58, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let playStationLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.78, 0.37), marker(.buttonB, 0.85, 0.27),
        marker(.buttonX, 0.72, 0.27), marker(.buttonY, 0.78, 0.16),
        marker(.dpadUp, 0.21, 0.20), marker(.dpadLeft, 0.15, 0.27),
        marker(.dpadDown, 0.21, 0.34), marker(.dpadRight, 0.27, 0.27),
        marker(.leftThumbstickButton, 0.34, 0.45, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.rightThumbstickButton, 0.66, 0.45, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.menu, 0.72, 0.12, size: CGSize(width: 25, height: 31), cornerRadius: 10),
        marker(.options, 0.28, 0.12, size: CGSize(width: 25, height: 31), cornerRadius: 10),
        marker(.home, 0.50, 0.54, size: CGSize(width: 31, height: 18), cornerRadius: 8),
        marker(.touchpadButton, 0.50, 0.18, size: CGSize(width: 126, height: 68), cornerRadius: 12),
        marker(.leftShoulder, 0.24, 0.065, size: CGSize(width: 64, height: 20), cornerRadius: 8),
        marker(.rightShoulder, 0.76, 0.065, size: CGSize(width: 64, height: 20), cornerRadius: 8),
        marker(.leftTrigger, 0.20, 0.025, size: CGSize(width: 55, height: 18), cornerRadius: 8),
        marker(.rightTrigger, 0.80, 0.025, size: CGSize(width: 55, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let joyConPairLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.leftThumbstickButton, 0.28, 0.35, size: CGSize(width: 44, height: 44), cornerRadius: 22),
        marker(.dpadUp, 0.28, 0.55, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.dpadLeft, 0.22, 0.61, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.dpadDown, 0.28, 0.67, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.dpadRight, 0.34, 0.61, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.options, 0.36, 0.20, size: CGSize(width: 24, height: 16), cornerRadius: 8),
        marker(.leftShoulder, 0.23, 0.08, size: CGSize(width: 52, height: 20), cornerRadius: 9),
        marker(.leftTrigger, 0.19, 0.03, size: CGSize(width: 48, height: 16), cornerRadius: 8),

        marker(.buttonA, 0.72, 0.41, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.buttonB, 0.78, 0.35, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.buttonX, 0.66, 0.35, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.buttonY, 0.72, 0.29, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.rightThumbstickButton, 0.72, 0.55, size: CGSize(width: 44, height: 44), cornerRadius: 22),
        marker(.menu, 0.64, 0.20, size: CGSize(width: 24, height: 24), cornerRadius: 12),
        marker(.home, 0.65, 0.72, size: CGSize(width: 24, height: 24), cornerRadius: 12),
        marker(.rightShoulder, 0.77, 0.08, size: CGSize(width: 52, height: 20), cornerRadius: 9),
        marker(.rightTrigger, 0.81, 0.03, size: CGSize(width: 48, height: 16), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let joyConLeftVerticalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.leftThumbstickButton, 0.50, 0.35, size: CGSize(width: 50, height: 50), cornerRadius: 25),
        marker(.buttonA, 0.42, 0.60, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonB, 0.50, 0.68, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonX, 0.50, 0.52, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonY, 0.58, 0.60, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.menu, 0.60, 0.20, size: CGSize(width: 26, height: 18), cornerRadius: 9),
        marker(.options, 0.58, 0.78, size: CGSize(width: 24, height: 24), cornerRadius: 12),
        marker(.leftShoulder, 0.43, 0.08, size: CGSize(width: 58, height: 22), cornerRadius: 10),
        marker(.rightShoulder, 0.37, 0.03, size: CGSize(width: 54, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let joyConLeftHorizontalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.leftThumbstickButton, 0.35, 0.50, size: CGSize(width: 50, height: 50), cornerRadius: 25),
        marker(.buttonA, 0.59, 0.50, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonB, 0.65, 0.64, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonX, 0.65, 0.36, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonY, 0.71, 0.50, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.leftShoulder, 0.42, 0.09, size: CGSize(width: 38, height: 20), cornerRadius: 10),
        marker(.rightShoulder, 0.58, 0.09, size: CGSize(width: 38, height: 20), cornerRadius: 10),
        marker(.menu, 0.20, 0.38, size: CGSize(width: 26, height: 18), cornerRadius: 9),
        marker(.options, 0.78, 0.38, size: CGSize(width: 24, height: 24), cornerRadius: 12),
    ].map { ($0.input, $0) })

    private static let joyConRightVerticalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.50, 0.43, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonB, 0.58, 0.35, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonX, 0.42, 0.35, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonY, 0.50, 0.27, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.leftThumbstickButton, 0.50, 0.57, size: CGSize(width: 50, height: 50), cornerRadius: 25),
        marker(.menu, 0.40, 0.20, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.options, 0.42, 0.78, size: CGSize(width: 24, height: 24), cornerRadius: 12),
        marker(.leftShoulder, 0.63, 0.03, size: CGSize(width: 54, height: 18), cornerRadius: 8),
        marker(.rightShoulder, 0.57, 0.08, size: CGSize(width: 58, height: 22), cornerRadius: 10),
    ].map { ($0.input, $0) })

    private static let joyConRightHorizontalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.35, 0.64, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonB, 0.41, 0.50, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonX, 0.29, 0.50, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonY, 0.35, 0.36, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.leftThumbstickButton, 0.65, 0.50, size: CGSize(width: 50, height: 50), cornerRadius: 25),
        marker(.leftShoulder, 0.42, 0.09, size: CGSize(width: 38, height: 20), cornerRadius: 10),
        marker(.rightShoulder, 0.58, 0.09, size: CGSize(width: 38, height: 20), cornerRadius: 10),
        marker(.menu, 0.80, 0.38, size: CGSize(width: 26, height: 26), cornerRadius: 13),
        marker(.options, 0.22, 0.38, size: CGSize(width: 24, height: 24), cornerRadius: 12),
    ].map { ($0.input, $0) })
}

private extension ControllerInput {
    var physicalInput: ControllerInput {
        switch self {
        case .functionButtonA: .buttonA
        case .functionButtonB: .buttonB
        case .functionButtonX: .buttonX
        case .functionButtonY: .buttonY
        case .functionLeftShoulder: .leftShoulder
        case .functionRightShoulder: .rightShoulder
        case .functionRightTrigger: .rightTrigger
        case .functionLeftThumbstickButton: .leftThumbstickButton
        case .functionRightThumbstickButton: .rightThumbstickButton
        case .functionDpadUp: .dpadUp
        case .functionDpadLeft: .dpadLeft
        case .functionDpadDown: .dpadDown
        case .functionDpadRight: .dpadRight
        case .functionRightStickUp, .functionRightStickLeft,
             .functionRightStickDown, .functionRightStickRight: .rightThumbstickButton
        default: self
        }
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
        guard let percentage else { return L10n.text("手柄电量未知", "Controller battery level unknown") }
        let stateDescription = switch state {
        case ControllerBatteryState.charging.rawValue: L10n.text("，正在充电", ", charging")
        case ControllerBatteryState.full.rawValue: L10n.text("，已充满", ", fully charged")
        default: ""
        }
        return "\(L10n.text("手柄电量", "Controller battery")) \(percentage)%\(stateDescription)"
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
    @ObservedObject var mappingStore: ControllerMappingStore
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("链路状态", "Connection Status"))
                    .font(.headline)

                Spacer(minLength: 8)

                HealthIndicator(status: status)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            InspectorSection(
                title: L10n.text("控制器", "Controller"),
                systemImage: "gamecontroller",
                connected: status.controllerConnected ??
                    (status.controller != "none" && status.controller != "No controller"),
                rows: controllerRows
            )
            Divider().padding(.leading, 16)
            InspectorSection(
                title: "Codex Micro",
                systemImage: "memorychip",
                connected: status.rp2040,
                rows: [
                    ("RP2040", status.rp2040
                        ? L10n.text("已连接", "Connected") : L10n.text("未连接", "Disconnected")),
                    (L10n.text("模式", "Mode"), status.mode == "legacy-app-server"
                        ? L10n.text("软件兼容", "Software Compatibility")
                        : L10n.text("物理 Micro", "Physical Micro")),
                ]
            )
            Divider().padding(.leading, 16)
            InspectorSection(
                title: L10n.text("运行模式", "Runtime"),
                systemImage: "lock.shield",
                connected: status.mode == "physical-codex-micro",
                rows: [
                    (L10n.text("手柄模式", "Gamepad Mode"), status.isNativeMode
                        ? "\(status.activeOperationMode.displayName)\(status.frontmostAppName.map { " (\($0))" } ?? "")"
                        : status.activeOperationMode.displayName),
                    (L10n.text("辅助功能", "Accessibility"), status.accessibility
                        ? L10n.text("已授权", "Authorized")
                        : L10n.text("鼠标控制未授权", "Pointer control unauthorized")),
                    (L10n.text("输入监控", "Input Monitoring"), status.inputMonitoring == true
                        ? L10n.text("已授权", "Authorized")
                        : L10n.text("后台手柄未授权", "Background controller unauthorized")),
                    (L10n.text("语音输入", "Voice Input"), voiceInputDescription),
                    (L10n.text("录音", "Recording"), L10n.text(
                        "由 Codex Desktop 管理", "Managed by Codex Desktop"
                    )),
                ]
            )
            if status.controllerFamily == ControllerFamily.dualSense.rawValue {
                Button {
                    openSoundInputSettings()
                } label: {
                    Label(L10n.text("打开声音输入设置", "Open Sound Input Settings"), systemImage: "mic")
                }
                .buttonStyle(.link)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Spacer()
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("震动测试", "Haptic Test"))
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
                        .help(L10n.text("测试\(state.displayName)震动", "Test \(state.displayName) haptics"))
                    }
                }
            }
            .padding(16)

            HStack {
                if #available(macOS 14.0, *) {
                    OpenSettingsLink(
                        tab: .general,
                        title: L10n.settingsTitle()
                    )
                } else {
                    Button {
                        settingsCoordinator.select(.general)
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    } label: {
                        Label(L10n.settingsTitle(), systemImage: "gearshape")
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                Text(AppVersion.displayName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
    }

    private var controllerFamilyName: String {
        guard let raw = status.controllerFamily,
              let family = ControllerFamily(rawValue: raw) else {
            return L10n.text("通用手柄", "Generic Controller")
        }
        return family.displayName
    }

    private var controllerRows: [(String, String)] {
        var rows: [(String, String)] = [
            (L10n.text("设备", "Device"), status.controller),
            (L10n.text("类型", "Type"), controllerFamilyName),
            (L10n.text("震动", "Haptics"), status.haptics
                ? L10n.text("可用", "Available") : L10n.text("不可用", "Unavailable")),
            (L10n.text("触控板", "Touchpad"), status.controllerTouchpad == true
                ? L10n.text("可映射", "Mappable") : L10n.text("不可用", "Unavailable")),
            (L10n.text("RT / R2 扳机", "RT / R2 Trigger"), rightTriggerDescription),
        ]
        if let mode = status.joyConMode {
            let modeName = switch JoyConMode(rawValue: mode) {
            case .pair: L10n.text("双支组合", "Paired")
            case .left: "\(L10n.text("左单支", "Left Solo")) · \(mappingStore.joyConOrientation.displayName)"
            case .right: "\(L10n.text("右单支", "Right Solo")) · \(mappingStore.joyConOrientation.displayName)"
            case nil: mode
            }
            rows.append((L10n.text("Joy-Con 模式", "Joy-Con Mode"), modeName))
            rows.append(("Joy-Con L", joyConSideDescription(
                connected: status.joyConLeftConnected,
                battery: status.joyConLeftBatteryLevel,
                haptics: status.joyConLeftHaptics,
                motion: status.joyConLeftMotion
            )))
            rows.append(("Joy-Con R", joyConSideDescription(
                connected: status.joyConRightConnected,
                battery: status.joyConRightBatteryLevel,
                haptics: status.joyConRightHaptics,
                motion: status.joyConRightMotion
            )))
            appendMotionRows(status.joyConLeftIMU, side: "L", to: &rows)
            appendMotionRows(status.joyConRightIMU, side: "R", to: &rows)
        }
        return rows
    }

    private func appendMotionRows(
        _ snapshot: JoyConHIDMotionSnapshot?,
        side: String,
        to rows: inout [(String, String)]
    ) {
        guard let snapshot else { return }
        rows.append((
            "Joy-Con \(side) " + L10n.text("加速度 (g)", "Acceleration (g)"),
            vectorDescription(snapshot.accelerationG)
        ))
        rows.append((
            "Joy-Con \(side) " + L10n.text("角速度 (°/s)", "Rotation (°/s)"),
            vectorDescription(snapshot.rotationRateDPS)
                + " · " + calibrationDescription(snapshot.calibrationSource)
        ))
    }

    private func vectorDescription(_ vector: JoyConVector3) -> String {
        String(format: "X %.2f · Y %.2f\nZ %.2f", vector.x, vector.y, vector.z)
    }

    private func calibrationDescription(_ source: JoyConIMUCalibrationSource) -> String {
        switch source {
        case .user: L10n.text("用户校准", "User calibration")
        case .factory: L10n.text("工厂校准", "Factory calibration")
        case .default: L10n.text("默认校准", "Default calibration")
        }
    }

    private func joyConSideDescription(
        connected: Bool?,
        battery: Float?,
        haptics: Bool?,
        motion: Bool?
    ) -> String {
        guard connected == true else { return L10n.text("未连接", "Disconnected") }
        var details: [String] = []
        if let battery { details.append("\(Int((battery * 100).rounded()))%") }
        if haptics == true { details.append(L10n.text("震动", "Haptics")) }
        if motion == true { details.append(L10n.text("体感", "Motion")) }
        return details.isEmpty ? L10n.text("已连接", "Connected") : details.joined(separator: " · ")
    }

    private var rightTriggerDescription: String {
        switch status.controllerFamily.flatMap(ControllerFamily.init(rawValue:)) {
        case .dualSense:
            L10n.text("自适应强反馈", "Strong Adaptive Feedback")
        case .xbox where status.haptics:
            L10n.text("Impulse Trigger 细微反馈", "Subtle Impulse Trigger Feedback")
        default:
            L10n.text("标准输入", "Standard Input")
        }
    }

    private var voiceInputDescription: String {
        guard status.microphone, let name = status.voiceInput, !name.isEmpty else {
            guard let defaultInput = status.defaultVoiceInput, !defaultInput.isEmpty else {
                return status.controllerFamily == ControllerFamily.dualSense.rawValue
                    ? L10n.text(
                        "手柄未提供；系统也无可用输入",
                        "Controller input unavailable; no system input available"
                    )
                    : L10n.text("系统无可用输入", "No system input available")
            }
            return status.controllerFamily == ControllerFamily.dualSense.rawValue
                ? L10n.text(
                    "手柄未提供；当前用 \(defaultInput)",
                    "Controller input unavailable; using \(defaultInput)"
                )
                : L10n.text("当前用 \(defaultInput)", "Using \(defaultInput)")
        }
        let transport = status.voiceInputTransport.flatMap { $0.isEmpty ? nil : $0 }
            ?? L10n.text("未知连接", "Unknown connection")
        return status.voiceInputDefault == true
            ? L10n.text("\(name)（\(transport)，默认）", "\(name) (\(transport), default)")
            : L10n.text("\(name)（\(transport)，未选中）", "\(name) (\(transport), not selected)")
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
                Text(connected
                    ? L10n.text("已连接", "Connected")
                    : L10n.text("未连接", "Disconnected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
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
            Text(status.rp2040 && status.haptics
                ? L10n.text("链路正常", "Connections Ready")
                : L10n.text("检查连接", "Check Connections"))
                .font(.caption)
        }
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
        case .idle: return L10n.text("就绪", "Ready")
        case .busy: return L10n.text("执行中", "Running")
        case .waiting: return L10n.text("等待批准", "Waiting for Approval")
        case .done: return L10n.text("已完成", "Completed")
        case .error: return L10n.text("发生错误", "Error")
        }
    }

    var shortDescription: String {
        switch self {
        case .idle: return L10n.text("等待下一项操作", "Waiting for the next action")
        case .busy: return L10n.text("任务正在处理", "Task in progress")
        case .waiting: return L10n.text("需要你的决定", "Your decision is required")
        case .done: return L10n.text("任务已结束", "Task finished")
        case .error: return L10n.text("请检查活动记录", "Check the activity log")
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
