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
             .functionDpadUp, .functionDpadLeft, .functionDpadDown, .functionDpadRight:
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
        }
    }

    var controllerAction: ControllerAction? {
        switch self {
        case .disabled, .radialInput, .functionModifier: nil
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
        }
    }
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
        .touchpadButton: .pushToTalk,
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
    ]

    static let defaultMappings = defaultMappings(for: .xbox)

    static func defaultMappings(for _: ControllerFamily) -> [ControllerInput: ControllerMappedAction] {
        baseDefaultMappings
    }

    @Published private(set) var mappings: [ControllerInput: ControllerMappedAction]
    @Published private(set) var controllerFamily: ControllerFamily

    private let userDefaults: UserDefaults
    private let storageKey: String

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
        migrateYesNoFaceButtonsIfNeeded()
        migrateUnifiedFaceButtonLayoutIfNeeded()
        migrateDPadUpToRightCommandIfNeeded()
        migrateClipboardAndScreenshotDefaultsIfNeeded()
        migrateClipboardToThumbsticksIfNeeded()
    }

    func action(for input: ControllerInput) -> ControllerMappedAction {
        mappings[input] ?? Self.defaultMappings[input] ?? .disabled
    }

    func displayName(for input: ControllerInput) -> String {
        input.displayName(for: controllerFamily)
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
}
