import AppKit
import Combine
import Foundation

enum ControllerInputGroup: String, CaseIterable, Identifiable {
    case primary = "基础按键"
    case dpad = "十字键"
    case functionLayer = "LT 功能层"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .primary: L10n.text("基础按键", "Primary Buttons")
        case .dpad: L10n.text("十字键", "D-Pad")
        case .functionLayer: L10n.text("LT 功能层", "LT Function Layer")
        }
    }
}

enum ControllerInput: String, CaseIterable, Codable, Identifiable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case menu
    case options
    case home
    case rightTrigger
    case leftThumbstickButton
    case rightThumbstickButton
    case touchpadButton
    case dpadUp
    case dpadLeft
    case dpadDown
    case dpadRight
    case functionButtonA
    case functionButtonB
    case functionButtonX
    case functionButtonY
    case functionLeftShoulder
    case functionRightShoulder
    case functionRightTrigger
    case functionLeftThumbstickButton
    case functionRightThumbstickButton
    case functionDpadUp
    case functionDpadLeft
    case functionDpadDown
    case functionDpadRight
    case functionRightStickUp
    case functionRightStickLeft
    case functionRightStickDown
    case functionRightStickRight

    var id: Self { self }

    func displayName(for family: ControllerFamily = .xbox) -> String {
        let playStation = family == .dualSense || family == .dualShock
        return switch self {
        case .buttonA: playStation ? "×" : "A"
        case .buttonB: playStation ? "○" : "B"
        case .buttonX: playStation ? "□" : "X"
        case .buttonY: playStation ? "△" : "Y"
        case .leftShoulder: playStation ? "L1" : "LB"
        case .rightShoulder: playStation ? "R1" : "RB"
        case .leftTrigger: playStation ? "L2" : "LT"
        case .menu: playStation ? "Options" : "Menu"
        case .options: playStation ? "Create" : "Options / View"
        case .home: playStation ? "PS" : "Home"
        case .rightTrigger: playStation ? "R2" : "RT"
        case .leftThumbstickButton: "L3"
        case .rightThumbstickButton: "R3"
        case .touchpadButton: L10n.text("触控板按键", "Touchpad Button")
        case .dpadUp: L10n.text("十字键 上", "D-Pad Up")
        case .dpadLeft: L10n.text("十字键 左", "D-Pad Left")
        case .dpadDown: L10n.text("十字键 下", "D-Pad Down")
        case .dpadRight: L10n.text("十字键 右", "D-Pad Right")
        case .functionButtonA: playStation ? "L2 + ×" : "LT + A"
        case .functionButtonB: playStation ? "L2 + ○" : "LT + B"
        case .functionButtonX: playStation ? "L2 + □" : "LT + X"
        case .functionButtonY: playStation ? "L2 + △" : "LT + Y"
        case .functionLeftShoulder: playStation ? "L2 + L1" : "LT + LB"
        case .functionRightShoulder: playStation ? "L2 + R1" : "LT + RB"
        case .functionRightTrigger: playStation ? "L2 + R2" : "LT + RT"
        case .functionLeftThumbstickButton: playStation ? "L2 + L3" : "LT + L3"
        case .functionRightThumbstickButton: playStation ? "L2 + R3" : "LT + R3"
        case .functionDpadUp: playStation
            ? L10n.text("L2 + 十字键 上", "L2 + D-Pad Up")
            : L10n.text("LT + 十字键 上", "LT + D-Pad Up")
        case .functionDpadLeft: playStation
            ? L10n.text("L2 + 十字键 左", "L2 + D-Pad Left")
            : L10n.text("LT + 十字键 左", "LT + D-Pad Left")
        case .functionDpadDown: playStation
            ? L10n.text("L2 + 十字键 下", "L2 + D-Pad Down")
            : L10n.text("LT + 十字键 下", "LT + D-Pad Down")
        case .functionDpadRight: playStation
            ? L10n.text("L2 + 十字键 右", "L2 + D-Pad Right")
            : L10n.text("LT + 十字键 右", "LT + D-Pad Right")
        case .functionRightStickUp: playStation
            ? L10n.text("L2 + 右摇杆 上", "L2 + Right Stick Up")
            : L10n.text("LT + 右摇杆 上", "LT + Right Stick Up")
        case .functionRightStickLeft: playStation
            ? L10n.text("L2 + 右摇杆 左", "L2 + Right Stick Left")
            : L10n.text("LT + 右摇杆 左", "LT + Right Stick Left")
        case .functionRightStickDown: playStation
            ? L10n.text("L2 + 右摇杆 下", "L2 + Right Stick Down")
            : L10n.text("LT + 右摇杆 下", "LT + Right Stick Down")
        case .functionRightStickRight: playStation
            ? L10n.text("L2 + 右摇杆 右", "L2 + Right Stick Right")
            : L10n.text("LT + 右摇杆 右", "LT + Right Stick Right")
        }
    }

    var group: ControllerInputGroup {
        switch self {
        case .dpadUp, .dpadLeft, .dpadDown, .dpadRight:
            .dpad
        case .functionButtonA, .functionButtonB, .functionButtonX, .functionButtonY,
             .functionLeftShoulder, .functionRightShoulder,
             .functionRightTrigger,
             .functionLeftThumbstickButton, .functionRightThumbstickButton,
             .functionDpadUp, .functionDpadLeft, .functionDpadDown, .functionDpadRight,
             .functionRightStickUp, .functionRightStickLeft,
             .functionRightStickDown, .functionRightStickRight:
            .functionLayer
        default:
            .primary
        }
    }

    var availableActions: [ControllerMappedAction] {
        ControllerMappedAction.allCases.filter { action in
            if action == .radialInput { return group == .dpad }
            if action == .functionModifier { return self == .leftTrigger }
            return true
        }
    }
}

enum ControllerMappedAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    case radialInput
    case functionModifier
    case mouseLeft
    case mouseRight
    case mouseMiddle
    case enter
    case backspace
    case escape
    case rightCommand
    case copy
    case paste
    case screenshotTool
    case answerYes
    case answerNo
    case approve
    case deny
    case toggleFastMode = "quickAction"
    case splitThread
    case pushToTalk
    case focusCodex
    case previousSlot
    case nextSlot
    case slot1
    case slot2
    case slot3
    case slot4
    case slot5
    case slot6
    case mouseSpeedBoost
    case mousePrecision
    case browserBack
    case browserForward
    case openApplication
    case recordedShortcut

    var id: Self { self }

    var displayName: String {
        switch self {
        case .disabled: L10n.text("不执行操作", "No Action")
        case .radialInput: L10n.text("Codex 径向输入", "Codex Radial Input")
        case .functionModifier: L10n.text("LT 功能层与滚动", "LT Function Layer and Scroll")
        case .mouseLeft: L10n.text("鼠标左键", "Left Mouse Button")
        case .mouseRight: L10n.text("鼠标右键", "Right Mouse Button")
        case .mouseMiddle: L10n.text("鼠标中键", "Middle Mouse Button")
        case .enter: L10n.text("回车", "Enter")
        case .backspace: L10n.text("退格", "Backspace")
        case .escape: "Esc"
        case .rightCommand: L10n.text("右侧 Command", "Right Command")
        case .copy: L10n.text("复制", "Copy")
        case .paste: L10n.text("粘贴", "Paste")
        case .screenshotTool: L10n.text("飞书截图", "Feishu Screenshot")
        case .answerYes: L10n.text("输入 yes", "Type yes")
        case .answerNo: L10n.text("输入 no", "Type no")
        case .approve: L10n.text("批准", "Approve")
        case .deny: L10n.text("拒绝", "Deny")
        case .toggleFastMode: L10n.text("切换 Fast 模式", "Toggle Fast Mode")
        case .splitThread: L10n.text("拆分任务", "Split Task")
        case .pushToTalk: L10n.text("按住说话", "Push to Talk")
        case .focusCodex: L10n.text("聚焦 Codex", "Focus Codex")
        case .previousSlot: L10n.text("上一个槽位", "Previous Slot")
        case .nextSlot: L10n.text("下一个槽位", "Next Slot")
        case .slot1: L10n.text("选择槽位 1", "Select Slot 1")
        case .slot2: L10n.text("选择槽位 2", "Select Slot 2")
        case .slot3: L10n.text("选择槽位 3", "Select Slot 3")
        case .slot4: L10n.text("选择槽位 4", "Select Slot 4")
        case .slot5: L10n.text("选择槽位 5", "Select Slot 5")
        case .slot6: L10n.text("选择槽位 6", "Select Slot 6")
        case .mouseSpeedBoost: L10n.text("按住加速鼠标", "Hold for Faster Pointer")
        case .mousePrecision: L10n.text("按住精细鼠标", "Hold for Precise Pointer")
        case .browserBack: L10n.text("网页上一页", "Browser Back")
        case .browserForward: L10n.text("网页下一页", "Browser Forward")
        case .openApplication: L10n.text("打开应用…", "Open Application…")
        case .recordedShortcut: L10n.text("录制按键…", "Record Shortcut…")
        }
    }

    var controllerAction: ControllerAction? {
        switch self {
        case .disabled, .radialInput, .functionModifier, .openApplication, .recordedShortcut: nil
        case .mouseLeft: .mouseButton(.left)
        case .mouseRight: .mouseButton(.right)
        case .mouseMiddle: .mouseButton(.middle)
        case .enter: .systemKey(.enter)
        case .backspace: .systemKey(.backspace)
        case .escape: .systemKey(.escape)
        case .rightCommand: .systemKey(.rightCommand)
        case .copy: .systemKey(.copy)
        case .paste: .systemKey(.paste)
        case .screenshotTool: .systemKey(.screenshotTool)
        case .browserBack: .systemKey(.browserBack)
        case .browserForward: .systemKey(.browserForward)
        case .answerYes: .textInput("yes")
        case .answerNo: .textInput("no")
        case .approve: .microKey("ACT07")
        case .deny: .microKey("ACT08")
        case .toggleFastMode: .microKey("ACT06")
        case .splitThread: .microKey("ACT09")
        case .pushToTalk: .microKey("ACT10")
        case .focusCodex: .microKey("ACT12")
        case .previousSlot: .slotOffset(-1)
        case .nextSlot: .slotOffset(1)
        case .slot1: .selectSlot(0)
        case .slot2: .selectSlot(1)
        case .slot3: .selectSlot(2)
        case .slot4: .selectSlot(3)
        case .slot5: .selectSlot(4)
        case .slot6: .selectSlot(5)
        case .mouseSpeedBoost: .mouseSpeedBoost
        case .mousePrecision: .mousePrecision
        }
    }
}

enum RecordedShortcutModifier: String, CaseIterable, Codable, Hashable {
    case control
    case option
    case shift
    case command
    case function

    var displayName: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        case .function: .function
        }
    }
}

struct RecordedKeyboardShortcut: Codable, Hashable {
    let keyCode: UInt16
    let keyName: String
    let modifiers: [RecordedShortcutModifier]

    init(keyCode: UInt16, keyName: String, modifiers: [RecordedShortcutModifier]) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.modifiers = RecordedShortcutModifier.allCases.filter(modifiers.contains)
    }

    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            keyName: Self.keyName(for: event),
            modifiers: RecordedShortcutModifier.allCases.filter {
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains($0.eventFlag)
            }
        )
    }

    var displayName: String {
        modifiers.map(\.displayName).joined() + keyName
    }

    var recorderDisplayName: String {
        (modifiers.map(\.displayName) + [keyName]).joined(separator: " ")
    }

    private static func keyName(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            71: "Clear", 76: "⌅", 117: "⌦", 115: "↖", 119: "↘",
            116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        if let specialKey = specialKeys[event.keyCode] { return specialKey }
        if let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
           !characters.isEmpty {
            return characters.uppercased()
        }
        return String(format: "Key 0x%02X", event.keyCode)
    }
}

struct RecordedShortcutConfiguration: Codable, Hashable {
    var shortcut: RecordedKeyboardShortcut?
    var note: String
}

final class ControllerMappingStore: ObservableObject {
    private static let baseDefaultMappings: [ControllerInput: ControllerMappedAction] = [
        .buttonA: .mouseLeft,
        .buttonB: .mouseRight,
        .buttonX: .backspace,
        .buttonY: .escape,
        .leftShoulder: .previousSlot,
        .rightShoulder: .nextSlot,
        .leftTrigger: .functionModifier,
        .menu: .pushToTalk,
        .options: .screenshotTool,
        .home: .disabled,
        .rightTrigger: .focusCodex,
        .leftThumbstickButton: .mouseSpeedBoost,
        .rightThumbstickButton: .mouseMiddle,
        .touchpadButton: .mouseLeft,
        .dpadUp: .rightCommand,
        .dpadLeft: .radialInput,
        .dpadDown: .radialInput,
        .dpadRight: .radialInput,
        .functionButtonA: .approve,
        .functionButtonB: .deny,
        .functionButtonX: .answerNo,
        .functionButtonY: .answerYes,
        .functionLeftShoulder: .slot5,
        .functionRightShoulder: .slot6,
        .functionRightTrigger: .enter,
        .functionLeftThumbstickButton: .copy,
        .functionRightThumbstickButton: .paste,
        .functionDpadUp: .slot1,
        .functionDpadLeft: .slot2,
        .functionDpadDown: .slot3,
        .functionDpadRight: .slot4,
        .functionRightStickUp: .disabled,
        .functionRightStickLeft: .browserBack,
        .functionRightStickDown: .disabled,
        .functionRightStickRight: .browserForward,
    ]

    static let defaultMappings = defaultMappings(for: .xbox)

    static func defaultMappings(for _: ControllerFamily) -> [ControllerInput: ControllerMappedAction] {
        baseDefaultMappings
    }

    @Published private(set) var mappings: [ControllerInput: ControllerMappedAction]
    @Published private(set) var controllerFamily: ControllerFamily
    @Published private(set) var openApplicationTargets: [ControllerInput: String]
    @Published private(set) var recordedShortcutConfigurations: [ControllerInput: RecordedShortcutConfiguration]

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var openApplicationStorageKey: String { "\(storageKey).openApplications" }
    private var recordedShortcutsStorageKey: String { "\(storageKey).recordedShortcuts" }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "controllerMappings.v1"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let storedFamily = userDefaults.string(forKey: "\(storageKey).controllerFamily")
            .flatMap(ControllerFamily.init(rawValue:)) ?? .xbox
        self.controllerFamily = storedFamily
        self.mappings = Self.loadMappings(
            from: userDefaults,
            key: storageKey,
            defaults: Self.defaultMappings(for: storedFamily)
        )
        self.openApplicationTargets = Self.loadOpenApplicationTargets(
            from: userDefaults,
            key: "\(storageKey).openApplications"
        )
        self.recordedShortcutConfigurations = Self.loadRecordedShortcutConfigurations(
            from: userDefaults,
            key: "\(storageKey).recordedShortcuts"
        )
        migrateYesNoFaceButtonsIfNeeded()
        migrateUnifiedFaceButtonLayoutIfNeeded()
        migrateDPadUpToRightCommandIfNeeded()
        migrateClipboardAndScreenshotDefaultsIfNeeded()
        migrateClipboardToThumbsticksIfNeeded()
        migrateFunctionRightStickBrowserDefaultsIfNeeded()
        migrateLeftThumbstickBoostRestoredIfNeeded()
        migrateTouchpadMouseLeftDefaultIfNeeded()
    }

    func action(for input: ControllerInput) -> ControllerMappedAction {
        mappings[input] ?? Self.defaultMappings[input] ?? .disabled
    }

    func displayName(for input: ControllerInput) -> String {
        input.displayName(for: controllerFamily)
    }

    func openApplicationTarget(for input: ControllerInput) -> String? {
        openApplicationTargets[input]
    }

    func openApplicationDisplayName(for input: ControllerInput) -> String? {
        guard let bundleIdentifier = openApplicationTargets[input] else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let name = FileManager.default.displayName(atPath: url.path)
            if !name.isEmpty {
                return name.replacingOccurrences(of: ".app", with: "")
            }
        }
        return bundleIdentifier
    }

    func setOpenApplicationTarget(_ bundleIdentifier: String?, for input: ControllerInput) {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            openApplicationTargets[input] = trimmed
        } else {
            openApplicationTargets.removeValue(forKey: input)
        }
        persistOpenApplicationTargets()
    }

    func recordedShortcutConfiguration(for input: ControllerInput) -> RecordedShortcutConfiguration {
        recordedShortcutConfigurations[input] ?? RecordedShortcutConfiguration(shortcut: nil, note: "")
    }

    func mappedActionDisplayName(for input: ControllerInput) -> String {
        let mappedAction = action(for: input)
        guard mappedAction == .recordedShortcut else { return mappedAction.displayName }
        let configuration = recordedShortcutConfiguration(for: input)
        let note = configuration.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        return configuration.shortcut?.displayName ?? mappedAction.displayName
    }

    func setRecordedShortcut(_ shortcut: RecordedKeyboardShortcut?, for input: ControllerInput) {
        var configuration = recordedShortcutConfiguration(for: input)
        configuration.shortcut = shortcut
        setRecordedShortcutConfiguration(configuration, for: input)
    }

    func setRecordedShortcutNote(_ note: String, for input: ControllerInput) {
        var configuration = recordedShortcutConfiguration(for: input)
        configuration.note = note
        setRecordedShortcutConfiguration(configuration, for: input)
    }

    func setControllerFamily(_ family: ControllerFamily) {
        guard family != controllerFamily else { return }
        let previousDefaults = Self.defaultMappings(for: controllerFamily)
        let newDefaults = Self.defaultMappings(for: family)
        for input in ControllerInput.allCases where mappings[input] == previousDefaults[input] {
            mappings[input] = newDefaults[input]
        }
        controllerFamily = family
        userDefaults.set(family.rawValue, forKey: "\(storageKey).controllerFamily")
        persist()
    }

    func setAction(_ newAction: ControllerMappedAction, for input: ControllerInput) {
        guard input.availableActions.contains(newAction), action(for: input) != newAction else { return }
        mappings[input] = newAction
        persist()
    }

    func resetDefaults() {
        mappings = Self.defaultMappings(for: controllerFamily)
        persist()
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value.rawValue) })
        userDefaults.set(encoded, forKey: storageKey)
    }

    private func persistOpenApplicationTargets() {
        let encoded = Dictionary(
            uniqueKeysWithValues: openApplicationTargets.map { ($0.key.rawValue, $0.value) }
        )
        userDefaults.set(encoded, forKey: openApplicationStorageKey)
    }

    private func setRecordedShortcutConfiguration(
        _ configuration: RecordedShortcutConfiguration,
        for input: ControllerInput
    ) {
        if configuration.shortcut == nil && configuration.note.isEmpty {
            recordedShortcutConfigurations.removeValue(forKey: input)
        } else {
            recordedShortcutConfigurations[input] = configuration
        }
        persistRecordedShortcutConfigurations()
    }

    private func persistRecordedShortcutConfigurations() {
        guard let data = try? JSONEncoder().encode(recordedShortcutConfigurations) else { return }
        userDefaults.set(data, forKey: recordedShortcutsStorageKey)
    }

    private func migrateYesNoFaceButtonsIfNeeded() {
        let migrationKey = "\(storageKey).yesNoFaceButtonsMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }
        if mappings[.functionButtonA] == .approve,
           mappings[.functionButtonB] == .deny,
           mappings[.functionButtonX] == .toggleFastMode,
           mappings[.functionButtonY] == .splitThread {
            let defaults = Self.defaultMappings(for: controllerFamily)
            for input in [
                ControllerInput.functionButtonA,
                .functionButtonB,
                .functionButtonX,
                .functionButtonY,
            ] {
                mappings[input] = defaults[input]
            }
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateUnifiedFaceButtonLayoutIfNeeded() {
        let migrationKey = "\(storageKey).unifiedFaceButtonLayoutMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        let currentFaceMappings = [
            mappings[.functionButtonA],
            mappings[.functionButtonB],
            mappings[.functionButtonX],
            mappings[.functionButtonY],
        ]
        let oldXboxDefaults: [ControllerMappedAction?] = [.approve, .deny, .answerYes, .answerNo]
        let oldPlayStationDefaults: [ControllerMappedAction?] = [.approve, .answerNo, .deny, .answerYes]

        if currentFaceMappings == oldXboxDefaults || currentFaceMappings == oldPlayStationDefaults {
            for input in [
                ControllerInput.functionButtonA,
                .functionButtonB,
                .functionButtonX,
                .functionButtonY,
            ] {
                mappings[input] = Self.baseDefaultMappings[input]
            }
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateDPadUpToRightCommandIfNeeded() {
        let migrationKey = "\(storageKey).dpadUpRightCommandMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }
        if mappings[.dpadUp] == .radialInput {
            mappings[.dpadUp] = .rightCommand
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateClipboardAndScreenshotDefaultsIfNeeded() {
        let migrationKey = "\(storageKey).clipboardAndScreenshotDefaultsMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        var changed = false
        if mappings[.options] == .disabled {
            mappings[.options] = .screenshotTool
            changed = true
        }
        if changed { persist() }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateClipboardToThumbsticksIfNeeded() {
        let migrationKey = "\(storageKey).clipboardThumbstickDefaultsMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        if mappings[.functionButtonX] == .copy,
           mappings[.functionButtonY] == .paste {
            mappings[.functionButtonX] = .answerNo
            mappings[.functionButtonY] = .answerYes
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateFunctionRightStickBrowserDefaultsIfNeeded() {
        let migrationKey = "\(storageKey).functionRightStickBrowserDefaultsMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        var changed = false
        if mappings[.functionRightStickLeft] == .disabled {
            mappings[.functionRightStickLeft] = .browserBack
            changed = true
        }
        if mappings[.functionRightStickRight] == .disabled {
            mappings[.functionRightStickRight] = .browserForward
            changed = true
        }
        if changed { persist() }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateLeftThumbstickBoostRestoredIfNeeded() {
        let migrationKey = "\(storageKey).leftThumbstickBoostRestoredMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        // Undo the brief L3→precision default; Xbox L3 stays speed boost.
        // Slow aiming is DualSense/DualShock touchpad sliding only.
        if mappings[.leftThumbstickButton] == .mousePrecision {
            mappings[.leftThumbstickButton] = .mouseSpeedBoost
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private func migrateTouchpadMouseLeftDefaultIfNeeded() {
        let migrationKey = "\(storageKey).touchpadMouseLeftDefaultMigrated"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        if mappings[.touchpadButton] == .pushToTalk {
            mappings[.touchpadButton] = .mouseLeft
            persist()
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    private static func loadMappings(
        from userDefaults: UserDefaults,
        key: String,
        defaults: [ControllerInput: ControllerMappedAction]
    ) -> [ControllerInput: ControllerMappedAction] {
        guard let stored = userDefaults.dictionary(forKey: key) as? [String: String] else {
            return defaults
        }
        var result = defaults
        for (inputValue, actionValue) in stored {
            guard let input = ControllerInput(rawValue: inputValue),
                  let action = ControllerMappedAction(rawValue: actionValue),
                  input.availableActions.contains(action) else { continue }
            result[input] = action
        }
        return result
    }

    private static func loadOpenApplicationTargets(
        from userDefaults: UserDefaults,
        key: String
    ) -> [ControllerInput: String] {
        guard let stored = userDefaults.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }
        var result: [ControllerInput: String] = [:]
        for (inputValue, bundleIdentifier) in stored {
            guard let input = ControllerInput(rawValue: inputValue) else { continue }
            let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[input] = trimmed
        }
        return result
    }

    private static func loadRecordedShortcutConfigurations(
        from userDefaults: UserDefaults,
        key: String
    ) -> [ControllerInput: RecordedShortcutConfiguration] {
        guard let data = userDefaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(
                  [ControllerInput: RecordedShortcutConfiguration].self,
                  from: data
              ) else {
            return [:]
        }
        return stored
    }
}
