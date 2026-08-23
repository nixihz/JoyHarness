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

    var displayName: String {
        switch self {
        case .buttonA: "A"
        case .buttonB: "B"
        case .buttonX: "X"
        case .buttonY: "Y"
        case .leftShoulder: "LB"
        case .rightShoulder: "RB"
        case .leftTrigger: "LT"
        case .menu: "Menu"
        case .options: "Options / View"
        case .home: "Home"
        case .rightTrigger: "RT"
        case .leftThumbstickButton: "L3"
        case .rightThumbstickButton: "R3"
        case .dpadUp: "十字键 上"
        case .dpadLeft: "十字键 左"
        case .dpadDown: "十字键 下"
        case .dpadRight: "十字键 右"
        case .functionButtonA: "LT + A"
        case .functionButtonB: "LT + B"
        case .functionButtonX: "LT + X"
        case .functionButtonY: "LT + Y"
        case .functionLeftShoulder: "LT + LB"
        case .functionRightShoulder: "LT + RB"
        case .functionDpadUp: "LT + 十字键 上"
        case .functionDpadLeft: "LT + 十字键 左"
        case .functionDpadDown: "LT + 十字键 下"
        case .functionDpadRight: "LT + 十字键 右"
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
    static let defaultMappings: [ControllerInput: ControllerMappedAction] = [
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
        .dpadUp: .radialInput,
        .dpadLeft: .radialInput,
        .dpadDown: .radialInput,
        .dpadRight: .radialInput,
        .functionButtonA: .approve,
        .functionButtonB: .deny,
        .functionButtonX: .quickAction,
        .functionButtonY: .splitThread,
        .functionLeftShoulder: .slot5,
        .functionRightShoulder: .slot6,
        .functionDpadUp: .slot1,
        .functionDpadLeft: .slot2,
        .functionDpadDown: .slot3,
        .functionDpadRight: .slot4,
    ]

    @Published private(set) var mappings: [ControllerInput: ControllerMappedAction]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "controllerMappings.v1"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.mappings = Self.loadMappings(from: userDefaults, key: storageKey)
    }

    func action(for input: ControllerInput) -> ControllerMappedAction {
        mappings[input] ?? Self.defaultMappings[input] ?? .disabled
    }

    func setAction(_ newAction: ControllerMappedAction, for input: ControllerInput) {
        guard input.availableActions.contains(newAction), action(for: input) != newAction else { return }
        mappings[input] = newAction
        persist()
    }

    func resetDefaults() {
        mappings = Self.defaultMappings
        persist()
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value.rawValue) })
        userDefaults.set(encoded, forKey: storageKey)
    }

    private static func loadMappings(
        from userDefaults: UserDefaults,
        key: String
    ) -> [ControllerInput: ControllerMappedAction] {
        guard let stored = userDefaults.dictionary(forKey: key) as? [String: String] else {
            return defaultMappings
        }
        var result = defaultMappings
        for (inputValue, actionValue) in stored {
            guard let input = ControllerInput(rawValue: inputValue),
                  let action = ControllerMappedAction(rawValue: actionValue),
                  input.availableActions.contains(action) else { continue }
            result[input] = action
        }
        return result
    }
}
