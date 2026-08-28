import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControllerMappingSettingsPane: View {
    @ObservedObject var store: ControllerMappingStore
    @State private var isResetConfirmationPresented = false
    @State private var recordingInput: ControllerInput?
    private var joyConOrientationBinding: Binding<JoyConOrientation> {
        Binding(
            get: { store.joyConOrientation },
            set: { store.setJoyConOrientation($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.controllerFamily == .joyConLeft || store.controllerFamily == .joyConRight {
                HStack(spacing: 12) {
                    Text(L10n.text("握持方向", "Grip Orientation"))
                        .font(.subheadline.weight(.medium))
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
                    .frame(width: 180)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()
            }

            Form {
                ForEach(ControllerInputGroup.allCases) { group in
                    Section(group.displayName) {
                        ForEach(inputs(in: group)) { input in
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(store.displayName(for: input), selection: binding(for: input)) {
                                    ForEach(input.availableActions) { action in
                                        Text(action.displayName).tag(action)
                                    }
                                }
                                .pickerStyle(.menu)

                                if store.action(for: input) == .openApplication {
                                    configurationDivider
                                    openApplicationRow(for: input)
                                }
                                if store.action(for: input) == .recordedShortcut {
                                    configurationDivider
                                    recordedShortcutRows(for: input)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label(L10n.text("恢复默认映射", "Restore Default Mappings"), systemImage: "arrow.counterclockwise")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(.bar)
        }
        .alert(L10n.text("恢复默认映射？", "Restore Default Mappings?"), isPresented: $isResetConfirmationPresented) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("恢复默认", "Restore Defaults"), role: .destructive) {
                store.resetDefaults()
            }
        } message: {
            Text(L10n.text(
                "当前的所有自定义按键设置将被替换。",
                "All custom button mappings will be replaced."
            ))
        }
    }

    @ViewBuilder
    private func openApplicationRow(for input: ControllerInput) -> some View {
        HStack(spacing: 12) {
            configurationLabel(L10n.text("应用", "Application"))

            HStack(spacing: 8) {
                Text(
                    store.openApplicationDisplayName(for: input)
                        ?? L10n.text("未选择应用", "No application selected")
                )
                .foregroundStyle(store.openApplicationTarget(for: input) == nil ? .secondary : .primary)
                .lineLimit(1)

                Spacer(minLength: 8)

                Button(L10n.text("选择…", "Choose…")) {
                    chooseApplication(for: input)
                }
                .controlSize(.small)

                if store.openApplicationTarget(for: input) != nil {
                    clearButton(
                        help: L10n.text("清除所选应用", "Clear selected application")
                    ) {
                        store.setOpenApplicationTarget(nil, for: input)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.leading, 12)
        .padding(.bottom, 2)
    }

    private func inputs(in group: ControllerInputGroup) -> [ControllerInput] {
        ControllerInput.allCases.filter { input in
            input.group == group && store.availableInputs.contains(input)
        }
    }

    @ViewBuilder
    private func recordedShortcutRows(for input: ControllerInput) -> some View {
        let configuration = store.recordedShortcutConfiguration(for: input)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                configurationLabel(L10n.text("快捷键", "Shortcut"))

                HStack(spacing: 10) {
                    ShortcutRecorderButton(
                        shortcut: configuration.shortcut,
                        isRecording: Binding(
                            get: { recordingInput == input },
                            set: { recordingInput = $0 ? input : nil }
                        )
                    ) { shortcut in
                        store.setRecordedShortcut(shortcut, for: input)
                        recordingInput = nil
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)

                    if configuration.shortcut != nil {
                        clearButton(
                            help: L10n.text("清除已录制的快捷键", "Clear recorded shortcut")
                        ) {
                            store.setRecordedShortcut(nil, for: input)
                        }
                    }
                }
            }

            GridRow {
                configurationLabel(L10n.text("备注", "Note"))

                TextField(
                    "",
                    text: Binding(
                        get: { store.recordedShortcutConfiguration(for: input).note },
                        set: { store.setRecordedShortcutNote($0, for: input) }
                    ),
                    prompt: Text(L10n.text("例如：打开搜索", "For example: Open Search"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: .infinity)
            }
        }
        .font(.caption)
        .padding(.leading, 12)
        .padding(.bottom, 2)
    }

    private var configurationDivider: some View {
        Divider()
            .padding(.leading, 12)
    }

    private func configurationLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private func clearButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 24)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func binding(for input: ControllerInput) -> Binding<ControllerMappedAction> {
        Binding(
            get: { store.action(for: input) },
            set: { store.setAction($0, for: input) }
        )
    }

    private func chooseApplication(for input: ControllerInput) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("选择", "Choose")
        panel.message = L10n.text(
            "选择要由此按键打开的应用。",
            "Choose the application this input should open."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
            ?? FileManager.default.displayName(atPath: url.path)
        store.setOpenApplicationTarget(bundleIdentifier, for: input)
        if store.action(for: input) != .openApplication {
            store.setAction(.openApplication, for: input)
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    let shortcut: RecordedKeyboardShortcut?
    @Binding var isRecording: Bool
    let onRecord: (RecordedKeyboardShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onActivate = { context.coordinator.setRecording(true) }
        button.onRecord = { context.coordinator.record($0) }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.parent = self
        button.isRecording = isRecording
        button.title = if isRecording {
            L10n.text("请按下按键…", "Press shortcut…")
        } else {
            shortcut?.recorderDisplayName ?? L10n.text("点击录制", "Click to Record")
        }
        button.bezelColor = isRecording ? .controlAccentColor : nil
        button.contentTintColor = isRecording ? .white : .labelColor
        button.font = shortcut == nil || isRecording
            ? .systemFont(ofSize: 11, weight: .medium)
            : .monospacedSystemFont(ofSize: 12, weight: .medium)
        if isRecording, button.window?.firstResponder !== button {
            DispatchQueue.main.async {
                button.window?.makeFirstResponder(button)
            }
        }
    }

    final class Coordinator {
        var parent: ShortcutRecorderButton

        init(parent: ShortcutRecorderButton) {
            self.parent = parent
        }

        func setRecording(_ recording: Bool) {
            parent.isRecording = recording
        }

        func record(_ event: NSEvent) {
            parent.onRecord(RecordedKeyboardShortcut(event: event))
        }
    }

    final class RecorderButton: NSButton {
        var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                if isRecording {
                    startEventTap()
                } else {
                    stopEventTap()
                }
            }
        }
        var onActivate: (() -> Void)?
        var onRecord: ((NSEvent) -> Void)?
        private var eventTap: CFMachPort?
        private var eventTapSource: CFRunLoopSource?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            controlSize = .small
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(activateRecording)
            focusRingType = .exterior
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            stopEventTap()
        }

        override var acceptsFirstResponder: Bool { true }

        @objc private func activateRecording() {
            isRecording = true
            window?.makeFirstResponder(self)
            onActivate?()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            capture(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            capture(event)
            return true
        }

        private func capture(_ event: NSEvent) {
            guard event.type == .keyDown, !event.isARepeat else { return }
            isRecording = false
            onRecord?(event)
        }

        private func startEventTap() {
            guard eventTap == nil else { return }
            let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: keyDownMask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let button = Unmanaged<RecorderButton>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    return button.handleEventTap(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            eventTap = tap
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        private func stopEventTap() {
            if let source = eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            eventTapSource = nil
            eventTap = nil
        }

        private func handleEventTap(
            type: CGEventType,
            event: CGEvent
        ) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if isRecording, let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            guard let keyEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            capture(keyEvent)
            return nil
        }
    }
}
