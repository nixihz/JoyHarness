import Foundation
import GameController

enum MouseButton: Hashable {
    case left
    case right
    case middle
}

enum SystemKey: Hashable {
    case backspace
    case escape
}

enum FaceButton {
    case a
    case b
    case x
    case y
}

enum DPadDirection {
    case up
    case left
    case down
    case right
}

enum ControllerAction: Hashable {
    case mouseButton(MouseButton)
    case systemKey(SystemKey)
    case microKey(String)
    case slotOffset(Int)
    case selectSlot(Int)
    case mouseSpeedBoost
}

final class ButtonBridge {
    private weak var controller: GCController?
    private var pressedButtons: Set<ObjectIdentifier> = []
    private var activeControllerActions: [ObjectIdentifier: ControllerAction] = [:]
    private var activeActionCounts: [ControllerAction: Int] = [:]
    private var functionPressed = false
    private var lastJoystick: (angle: Float, distance: Float)?
    private var mouseSpeedBoostPressed = false

    private(set) var selectedSlot = 0
    var keyHandler: ((String, Int) -> Bool)?
    var joystickHandler: ((Float, Float) -> Bool)?
    var leftStickHandler: ((Float, Float, Bool) -> Void)?
    var mouseButtonHandler: ((MouseButton, Bool) -> Void)?
    var systemKeyHandler: ((SystemKey, Bool) -> Void)?
    var mouseSpeedBoostHandler: ((Bool) -> Void)?
    var onSlotSelected: ((Int) -> Void)?
    var mappingProvider: (ControllerInput) -> ControllerMappedAction

    init(mappingProvider: @escaping (ControllerInput) -> ControllerMappedAction = {
        ControllerMappingStore.defaultMappings[$0] ?? .disabled
    }) {
        self.mappingProvider = mappingProvider
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        }
        attachPreferredController()
    }

    func moveSlot(_ offset: Int) {
        selectSlot((selectedSlot + offset + 6) % 6)
    }

    func openSelectedSlot() {
        tap(agentKey(for: selectedSlot))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.tap(self.agentKey(for: self.selectedSlot))
        }
    }

    private func attachPreferredController() {
        guard let selected = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let gamepad = selected.extendedGamepad else {
            resetInputState()
            controller = nil
            print("[agent-deck] controller unavailable")
            return
        }
        guard controller !== selected else { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        resetInputState()
        controller = selected
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            DispatchQueue.main.async {
                self?.handle(gamepad: gamepad, changedElement: element)
            }
        }
        print("[agent-deck] controller ready on \(selected.vendorName ?? selected.productCategory)")
    }

    private func handle(gamepad: GCExtendedGamepad, changedElement: GCControllerElement) {
        if changedElement === gamepad.leftTrigger {
            if mappingProvider(.leftTrigger) == .functionModifier {
                functionPressed = gamepad.leftTrigger.value >= 0.55
                if !gamepad.leftTrigger.isPressed { release(gamepad.leftTrigger) }
            } else {
                functionPressed = false
                handleMappedButton(gamepad.leftTrigger, input: .leftTrigger)
            }
        }
        leftStickHandler?(
            gamepad.leftThumbstick.xAxis.value,
            gamepad.leftThumbstick.yAxis.value,
            functionPressed
        )
        updateJoystick(gamepad)
        updateDPadButtons(gamepad)
        if changedElement === gamepad.leftTrigger { return }

        let faceButtons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.buttonA, .buttonA, .functionButtonA),
            (gamepad.buttonB, .buttonB, .functionButtonB),
            (gamepad.buttonX, .buttonX, .functionButtonX),
            (gamepad.buttonY, .buttonY, .functionButtonY),
        ]
        for (button, primaryInput, functionInput) in faceButtons where changedElement === button {
            handleMappedButton(button, input: functionPressed ? functionInput : primaryInput)
            return
        }

        let shoulderButtons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.leftShoulder, .leftShoulder, .functionLeftShoulder),
            (gamepad.rightShoulder, .rightShoulder, .functionRightShoulder),
        ]
        for (button, primaryInput, functionInput) in shoulderButtons where changedElement === button {
            handleMappedButton(button, input: functionPressed ? functionInput : primaryInput)
            return
        }

        if changedElement === gamepad.buttonMenu {
            handleMappedButton(gamepad.buttonMenu, input: .menu)
        } else if let button = gamepad.buttonOptions, changedElement === button {
            handleMappedButton(button, input: .options)
        } else if let button = gamepad.buttonHome, changedElement === button {
            handleMappedButton(button, input: .home)
        } else if changedElement === gamepad.rightTrigger {
            handleMappedButton(gamepad.rightTrigger, input: .rightTrigger)
        } else if let button = gamepad.leftThumbstickButton, changedElement === button {
            handleMappedButton(button, input: .leftThumbstickButton)
        } else if let button = gamepad.rightThumbstickButton, changedElement === button {
            handleMappedButton(button, input: .rightThumbstickButton)
        }
    }

    private func handleMappedButton(_ button: GCControllerButtonInput, input: ControllerInput) {
        guard let action = mappingProvider(input).controllerAction else {
            if !button.isPressed { release(button) }
            return
        }
        handleControllerAction(button, action: action)
    }

    static func faceAction(for button: FaceButton, functionPressed: Bool) -> ControllerAction {
        if functionPressed {
            switch button {
            case .a: return .microKey("ACT07")
            case .b: return .microKey("ACT08")
            case .x: return .microKey("ACT06")
            case .y: return .microKey("ACT09")
            }
        }
        switch button {
        case .a: return .mouseButton(.left)
        case .b: return .mouseButton(.right)
        case .x: return .systemKey(.backspace)
        case .y: return .systemKey(.escape)
        }
    }

    static func slot(for direction: DPadDirection) -> Int {
        switch direction {
        case .up: return 0
        case .left: return 1
        case .down: return 2
        case .right: return 3
        }
    }

    private func handleControllerAction(
        _ button: GCControllerButtonInput,
        action: ControllerAction
    ) {
        let id = ObjectIdentifier(button)
        if button.isPressed {
            guard pressedButtons.insert(id).inserted else { return }
            guard begin(action) else {
                pressedButtons.remove(id)
                return
            }
            activeControllerActions[id] = action
        } else {
            release(button)
        }
    }

    private func begin(_ action: ControllerAction) -> Bool {
        if let count = activeActionCounts[action] {
            activeActionCounts[action] = count + 1
            return true
        }

        let succeeded: Bool
        switch action {
        case .mouseButton(let button):
            mouseButtonHandler?(button, true)
            succeeded = true
        case .systemKey(let key):
            systemKeyHandler?(key, true)
            succeeded = true
        case .microKey(let key):
            succeeded = keyHandler?(key, 1) == true
        case .slotOffset(let offset):
            moveSlot(offset)
            return true
        case .selectSlot(let slot):
            selectSlot(slot)
            return true
        case .mouseSpeedBoost:
            mouseSpeedBoostPressed = true
            mouseSpeedBoostHandler?(true)
            succeeded = true
        }
        if succeeded { activeActionCounts[action] = 1 }
        return succeeded
    }

    private func end(_ action: ControllerAction) {
        switch action {
        case .slotOffset, .selectSlot:
            return
        default:
            break
        }
        guard let count = activeActionCounts[action] else { return }
        if count > 1 {
            activeActionCounts[action] = count - 1
            return
        }
        activeActionCounts.removeValue(forKey: action)

        switch action {
        case .mouseButton(let button):
            mouseButtonHandler?(button, false)
        case .systemKey(let key):
            systemKeyHandler?(key, false)
        case .microKey(let key):
            _ = keyHandler?(key, 0)
        case .slotOffset, .selectSlot:
            break
        case .mouseSpeedBoost:
            mouseSpeedBoostPressed = false
            mouseSpeedBoostHandler?(false)
        }
    }

    private func release(_ button: GCControllerButtonInput) {
        let id = ObjectIdentifier(button)
        pressedButtons.remove(id)
        if let action = activeControllerActions.removeValue(forKey: id) {
            end(action)
        }
    }

    func selectSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
        onSlotSelected?(slot)
        tap(agentKey(for: slot))
    }

    private func agentKey(for slot: Int) -> String {
        String(format: "AG%02d", slot)
    }

    private func tap(_ key: String) {
        guard keyHandler?(key, 1) == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            _ = self?.keyHandler?(key, 0)
        }
    }

    private func updateDPadButtons(_ gamepad: GCExtendedGamepad) {
        let buttons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.dpad.up, .dpadUp, .functionDpadUp),
            (gamepad.dpad.left, .dpadLeft, .functionDpadLeft),
            (gamepad.dpad.down, .dpadDown, .functionDpadDown),
            (gamepad.dpad.right, .dpadRight, .functionDpadRight),
        ]
        for (button, primaryInput, functionInput) in buttons {
            handleMappedButton(button, input: functionPressed ? functionInput : primaryInput)
        }
    }

    private func updateJoystick(_ gamepad: GCExtendedGamepad) {
        let rawDpadX = gamepad.dpad.xAxis.value
        let rawDpadY = gamepad.dpad.yAxis.value
        let dpadX: Float = if rawDpadX > 0.1 && mappingProvider(.dpadRight) == .radialInput {
            rawDpadX
        } else if rawDpadX < -0.1 && mappingProvider(.dpadLeft) == .radialInput {
            rawDpadX
        } else {
            0
        }
        let dpadY: Float = if rawDpadY > 0.1 && mappingProvider(.dpadUp) == .radialInput {
            rawDpadY
        } else if rawDpadY < -0.1 && mappingProvider(.dpadDown) == .radialInput {
            rawDpadY
        } else {
            0
        }
        let x = !functionPressed && abs(dpadX) > 0.1
            ? dpadX : gamepad.rightThumbstick.xAxis.value
        let y = !functionPressed && abs(dpadY) > 0.1
            ? dpadY : gamepad.rightThumbstick.yAxis.value
        let distance = min(sqrt(x * x + y * y), 1)
        let angle = distance < 0.08 ? 0 : Self.radialAngle(x: x, y: y)
        let changed = lastJoystick == nil ||
            abs(lastJoystick!.angle - angle) > 0.01 ||
            abs(lastJoystick!.distance - distance) > 0.01
        guard changed else { return }
        _ = joystickHandler?(angle, distance)
        lastJoystick = (angle, distance)
    }

    static func radialAngle(x: Float, y: Float) -> Float {
        let turns = atan2(-y, x) / (2 * Float.pi)
        return turns >= 0 ? turns : turns + 1
    }

    private func resetInputState() {
        for action in activeControllerActions.values { end(action) }
        if mouseSpeedBoostPressed { mouseSpeedBoostHandler?(false) }
        pressedButtons.removeAll()
        activeControllerActions.removeAll()
        activeActionCounts.removeAll()
        functionPressed = false
        lastJoystick = nil
        mouseSpeedBoostPressed = false
        leftStickHandler?(0, 0, false)
    }
}
