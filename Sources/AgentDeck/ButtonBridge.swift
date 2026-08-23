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

enum ControllerAction: Equatable {
    case mouseButton(MouseButton)
    case systemKey(SystemKey)
    case microKey(String)
}

final class ButtonBridge {
    private weak var controller: GCController?
    private var pressedButtons: Set<ObjectIdentifier> = []
    private var activeKeys: [ObjectIdentifier: String] = [:]
    private var pressedSlotControls: Set<ObjectIdentifier> = []
    private var activeControllerActions: [ObjectIdentifier: ControllerAction] = [:]
    private var functionPressed = false
    private var lastJoystick: (angle: Float, distance: Float)?
    private var mouseSpeedBoostPressed = false

    private(set) var selectedSlot = 0
    var keyHandler: ((String, Int) -> Bool)?
    var joystickHandler: ((Float, Float) -> Bool)?
    var mouseStickHandler: ((Float, Float) -> Void)?
    var mouseButtonHandler: ((MouseButton, Bool) -> Void)?
    var systemKeyHandler: ((SystemKey, Bool) -> Void)?
    var mouseSpeedBoostHandler: ((Bool) -> Void)?
    var onSlotSelected: ((Int) -> Void)?

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
        mouseStickHandler?(
            gamepad.leftThumbstick.xAxis.value,
            gamepad.leftThumbstick.yAxis.value
        )

        if changedElement === gamepad.leftTrigger {
            functionPressed = gamepad.leftTrigger.value >= 0.55
        }
        updateModifiedSlotSelection(gamepad)
        updateJoystick(gamepad)
        if changedElement === gamepad.leftTrigger { return }

        let faceButtons: [(GCControllerButtonInput, FaceButton)] = [
            (gamepad.buttonA, .a),
            (gamepad.buttonB, .b),
            (gamepad.buttonX, .x),
            (gamepad.buttonY, .y),
        ]
        for (button, faceButton) in faceButtons where changedElement === button {
            handleControllerAction(
                button,
                action: Self.faceAction(for: faceButton, functionPressed: functionPressed)
            )
            return
        }

        let slotStepButtons: [(GCControllerButtonInput, Int)] = [
            (gamepad.leftShoulder, -1),
            (gamepad.rightShoulder, 1),
        ]
        for (button, offset) in slotStepButtons where changedElement === button {
            if !functionPressed { handleSlotStepButton(button, offset: offset) }
            return
        }

        if changedElement === gamepad.buttonMenu {
            handleKeyButton(gamepad.buttonMenu, key: "ACT10")
        } else if changedElement === gamepad.rightTrigger {
            handleKeyButton(gamepad.rightTrigger, key: "ACT12")
        } else if let button = gamepad.leftThumbstickButton, changedElement === button {
            mouseSpeedBoostPressed = button.isPressed
            mouseSpeedBoostHandler?(mouseSpeedBoostPressed)
        } else if let button = gamepad.rightThumbstickButton, changedElement === button {
            handleControllerAction(button, action: .mouseButton(.middle))
        }
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
        switch action {
        case .mouseButton(let button):
            mouseButtonHandler?(button, true)
            return true
        case .systemKey(let key):
            systemKeyHandler?(key, true)
            return true
        case .microKey(let key):
            return keyHandler?(key, 1) == true
        }
    }

    private func end(_ action: ControllerAction) {
        switch action {
        case .mouseButton(let button):
            mouseButtonHandler?(button, false)
        case .systemKey(let key):
            systemKeyHandler?(key, false)
        case .microKey(let key):
            _ = keyHandler?(key, 0)
        }
    }

    private func handleSlotStepButton(_ button: GCControllerButtonInput, offset: Int) {
        let id = ObjectIdentifier(button)
        if button.isPressed {
            guard pressedButtons.insert(id).inserted else { return }
            selectedSlot = (selectedSlot + offset + 6) % 6
            onSlotSelected?(selectedSlot)
            let key = agentKey(for: selectedSlot)
            if keyHandler?(key, 1) == true { activeKeys[id] = key }
        } else {
            release(button)
        }
    }

    private func handleKeyButton(_ button: GCControllerButtonInput, key: String) {
        let id = ObjectIdentifier(button)
        if button.isPressed {
            guard pressedButtons.insert(id).inserted else { return }
            if keyHandler?(key, 1) == true { activeKeys[id] = key }
        } else {
            release(button)
        }
    }

    private func release(_ button: GCControllerButtonInput) {
        let id = ObjectIdentifier(button)
        pressedButtons.remove(id)
        if let action = activeControllerActions.removeValue(forKey: id) {
            end(action)
        }
        if let key = activeKeys.removeValue(forKey: id) {
            _ = keyHandler?(key, 0)
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

    private func updateModifiedSlotSelection(_ gamepad: GCExtendedGamepad) {
        guard functionPressed else {
            pressedSlotControls.removeAll()
            return
        }

        let slotControls: [(GCControllerButtonInput, Int)] = [
            (gamepad.dpad.up, 0),
            (gamepad.dpad.down, 1),
            (gamepad.dpad.left, 2),
            (gamepad.dpad.right, 3),
            (gamepad.leftShoulder, 4),
            (gamepad.rightShoulder, 5),
        ]
        for (button, slot) in slotControls {
            let id = ObjectIdentifier(button)
            if button.isPressed {
                guard pressedSlotControls.insert(id).inserted else { continue }
                selectSlot(slot)
            } else {
                pressedSlotControls.remove(id)
            }
        }
    }

    private func updateJoystick(_ gamepad: GCExtendedGamepad) {
        let dpadX = gamepad.dpad.xAxis.value
        let dpadY = gamepad.dpad.yAxis.value
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
        for key in activeKeys.values { _ = keyHandler?(key, 0) }
        for action in activeControllerActions.values { end(action) }
        if mouseSpeedBoostPressed { mouseSpeedBoostHandler?(false) }
        pressedButtons.removeAll()
        activeKeys.removeAll()
        activeControllerActions.removeAll()
        pressedSlotControls.removeAll()
        functionPressed = false
        lastJoystick = nil
        mouseSpeedBoostPressed = false
        mouseStickHandler?(0, 0)
    }
}
