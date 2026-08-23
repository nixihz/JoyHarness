import Combine
import Foundation

enum ControllerInputGroup: String, CaseIterable, Identifiable {
    case primary = "基础按键"
    case dpad = "十字键"
    case functionLayer = "LT 功能层"

    var id: Self { self }
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
        case .touchpadButton: "触控板按键"
        case .dpadUp: "十字键 上"
        case .dpadLeft: "十字键 左"
        case .dpadDown: "十字键 下"
        case .dpadRight: "十字键 右"
        case .functionButtonA: playStation ? "L2 + ×" : "LT + A"
        case .functionButtonB: playStation ? "L2 + ○" : "LT + B"
        case .functionButtonX: playStation ? "L2 + □" : "LT + X"
        case .functionButtonY: playStation ? "L2 + △" : "LT + Y"
        case .functionLeftShoulder: playStation ? "L2 + L1" : "LT + LB"
        case .functionRightShoulder: playStation ? "L2 + R1" : "LT + RB"
        case .functionDpadUp: playStation ? "L2 + 十字键 上" : "LT + 十字键 上"
        case .functionDpadLeft: playStation ? "L2 + 十字键 左" : "LT + 十字键 左"
        case .functionDpadDown: playStation ? "L2 + 十字键 下" : "LT + 十字键 下"
        case .functionDpadRight: playStation ? "L2 + 十字键 右" : "LT + 十字键 右"
        }
    }

    var group: ControllerInputGroup {
        switch self {
        case .dpadUp, .dpadLeft, .dpadDown, .dpadRight:
            .dpad
        case .functionButtonA, .functionButtonB, .functionButtonX, .functionButtonY,
             .functionLeftShoulder, .functionRightShoulder,
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
    case backspace
    case escape
    case answerYes
    case answerNo
    case approve
    case deny
    case quickAction
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
        case .disabled: "不执行操作"
        case .radialInput: "Codex 径向输入"
        case .functionModifier: "LT 功能层与滚动"
        case .mouseLeft: "鼠标左键"
        case .mouseRight: "鼠标右键"
        case .mouseMiddle: "鼠标中键"
        case .backspace: "退格"
        case .escape: "Esc"
        case .answerYes: "输入 yes"
        case .answerNo: "输入 no"
        case .approve: "批准"
        case .deny: "拒绝"
        case .quickAction: "快捷操作"
        case .splitThread: "拆分任务"
        case .pushToTalk: "按住说话"
        case .focusCodex: "聚焦 Codex"
        case .previousSlot: "上一个槽位"
        case .nextSlot: "下一个槽位"
        case .slot1: "选择槽位 1"
        case .slot2: "选择槽位 2"
        case .slot3: "选择槽位 3"
        case .slot4: "选择槽位 4"
        case .slot5: "选择槽位 5"
        case .slot6: "选择槽位 6"
        case .mouseSpeedBoost: "按住加速鼠标"
        }
    }

    var controllerAction: ControllerAction? {
        switch self {
        case .disabled, .radialInput, .functionModifier: nil
        case .mouseLeft: .mouseButton(.left)
        case .mouseRight: .mouseButton(.right)
        case .mouseMiddle: .mouseButton(.middle)
        case .backspace: .systemKey(.backspace)
        case .escape: .systemKey(.escape)
        case .answerYes: .textInput("yes")
        case .answerNo: .textInput("no")
        case .approve: .microKey("ACT07")
        case .deny: .microKey("ACT08")
        case .quickAction: .microKey("ACT06")
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
        .options: .disabled,
        .home: .disabled,
        .rightTrigger: .focusCodex,
        .leftThumbstickButton: .mouseSpeedBoost,
        .rightThumbstickButton: .mouseMiddle,
        .touchpadButton: .pushToTalk,
        .dpadUp: .radialInput,
        .dpadLeft: .radialInput,
        .dpadDown: .radialInput,
        .dpadRight: .radialInput,
        .functionButtonA: .approve,
        .functionButtonB: .deny,
        .functionButtonX: .answerNo,
        .functionButtonY: .answerYes,
        .functionLeftShoulder: .slot5,
        .functionRightShoulder: .slot6,
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
           mappings[.functionButtonX] == .quickAction,
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
