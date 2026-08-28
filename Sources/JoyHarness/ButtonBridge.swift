import Foundation
import GameController

enum MouseButton: Hashable {
    case left
    case right
    case middle
}

enum SystemKey: Hashable {
    case enter
    case backspace
    case escape
    case rightCommand
    case copy
    case paste
    case screenshotTool
    case browserBack
    case browserForward
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
    case textInput(String)
    case microKey(String)
    case slotOffset(Int)
    case selectSlot(Int)
    case mouseSpeedBoost
    case mousePrecision
    case openApplication(String)
    case recordedShortcut(RecordedKeyboardShortcut)
    case toggleOperationMode
}

enum StickDirection: Hashable {
    case up
    case left
    case down
    case right
}

struct AnalogButtonPressState {
    let pressPoint: Float
    let resetPoint: Float

    private(set) var isPressed = false

    mutating func update(value: Float) -> Bool? {
        if !isPressed, value >= pressPoint {
            isPressed = true
            return true
        }
        if isPressed, value <= resetPoint {
            isPressed = false
            return false
        }
        return nil
    }
}

/// Converts DualSense/DualShock absolute touchpad samples into relative pointer deltas.
struct TouchpadPointerTracker {
    /// Pixels per normalized touchpad unit. Sized for slow, precise aiming.
    nonisolated static let sensitivity: CGFloat = 240
    nonisolated static let liftEpsilon: Float = 0.002

    private var lastSample: CGPoint?

    mutating func update(x: Float, y: Float) -> CGPoint? {
        let touching = abs(x) > Self.liftEpsilon || abs(y) > Self.liftEpsilon
        guard touching else {
            lastSample = nil
            return nil
        }

        let sample = CGPoint(x: CGFloat(x), y: CGFloat(y))
        defer { lastSample = sample }
        guard let lastSample else { return nil }

        let delta = CGPoint(
            x: (sample.x - lastSample.x) * Self.sensitivity,
            // Touchpad Y matches stick Y: positive is up, screen Y grows downward.
            y: -(sample.y - lastSample.y) * Self.sensitivity
        )
        guard abs(delta.x) >= 0.01 || abs(delta.y) >= 0.01 else { return nil }
        return delta
    }

    mutating func reset() {
        lastSample = nil
    }
}

final class ButtonBridge {
    private weak var controller: GCController?
    private var observedControllers: [GCController] = []
    private var joyConControllersByID: [String: GCController] = [:]
    private var joyConCoordinator = JoyConCompositionCoordinator()
    private var joyConComposition = JoyConComposition.disconnected
    private var joyConInputSnapshot = JoyConInputSnapshot.neutral
    private var joyConActiveInputs: [ControllerInput: ControllerInput] = [:]
    private var joyConHIDShoulderSnapshots: [JoyConSide: JoyConHIDShoulderSnapshot] = [:]
    private var pressedButtons: Set<ObjectIdentifier> = []
    private var controllerInputsByButton: [ObjectIdentifier: ControllerInput] = [:]
    private var publishedInputs: Set<ControllerInput> = []
    private var activeControllerActions: [ObjectIdentifier: ControllerAction] = [:]
    private var activeActionCounts: [ControllerAction: Int] = [:]
    private var functionPressed = false
    private var lastJoystick: (angle: Float, distance: Float)?
    private var mouseSpeedBoostPressed = false
    private var mousePrecisionPressed = false
    private var controllerFamily: ControllerFamily = .generic
    private var rightTriggerPressState = AnalogButtonPressState(
        pressPoint: RightTriggerPressState.releasePoint,
        resetPoint: RightTriggerPressState.resetPoint
    )
    private var activeFunctionRightStickDirection: ControllerInput?
    private var pressedDirectionInputs: Set<ControllerInput> = []
    private var activeDirectionActions: [ControllerInput: ControllerAction] = [:]
    private var touchpadTracker = TouchpadPointerTracker()
    private var inputSourceGeneration: UInt64 = 0

    private(set) var selectedSlot = 0
    private(set) var operationMode: ControllerOperationMode = .mapping
    var onToggleOperationMode: (() -> Void)?
    var onOperationModeChange: ((ControllerOperationMode) -> Void)?
    var keyHandler: ((String, Int) -> Bool)?
    var joystickHandler: ((Float, Float) -> Bool)?
    var leftStickHandler: ((Float, Float, Bool) -> Void)?
    var touchpadPointerHandler: ((CGFloat, CGFloat) -> Void)?
    var mouseButtonHandler: ((MouseButton, Bool) -> Void)?
    var systemKeyHandler: ((SystemKey, Bool) -> Void)?
    var textInputHandler: ((String) -> Bool)?
    var mouseSpeedBoostHandler: ((Bool) -> Void)?
    var mousePrecisionHandler: ((Bool) -> Void)?
    var openApplicationHandler: ((String) -> Bool)?
    var openApplicationTargetProvider: ((ControllerInput) -> String?)?
    var recordedShortcutProvider: ((ControllerInput) -> RecordedKeyboardShortcut?)?
    var recordedShortcutHandler: ((RecordedKeyboardShortcut, Bool) -> Void)?
    var joyConOrientationProvider: (() -> JoyConOrientation)?
    var rightTriggerFeedbackHandler: ((Float) -> Void)?
    var onSlotSelected: ((Int) -> Void)?
    var onControllerChange: ((GCController?, ControllerFamily) -> Void)?
    var onControllerSetChange: (([GCController]) -> Void)?
    var onJoyConChange: ((JoyConControllerSnapshot?) -> Void)?
    var onAvailableInputsChange: ((Set<ControllerInput>) -> Void)?
    var onInputStateChange: ((ControllerInput, Bool) -> Void)?
    var mappingProvider: (ControllerInput) -> ControllerMappedAction

    var batterySnapshot: ControllerBatterySnapshot? {
        ControllerBatterySnapshot(controller?.battery)
    }

    var joyConSticks: JoyConStickProjection {
        JoyConStickProjection(
            primary: joyConInputSnapshot.primaryStick,
            secondary: joyConInputSnapshot.secondaryStick
        )
    }

    var joyConBatterySnapshots: [JoyConSide: ControllerBatterySnapshot] {
        guard let mode = joyConComposition.mode else { return [:] }
        var result: [JoyConSide: ControllerBatterySnapshot] = [:]
        if mode == .pair || mode == .left,
           let id = joyConComposition.leftID,
           let snapshot = ControllerBatterySnapshot(joyConControllersByID[id]?.battery) {
            result[.left] = snapshot
        }
        if mode == .pair || mode == .right,
           let id = joyConComposition.rightID,
           let snapshot = ControllerBatterySnapshot(joyConControllersByID[id]?.battery) {
            result[.right] = snapshot
        }
        return result
    }

    init(mappingProvider: @escaping (ControllerInput) -> ControllerMappedAction = {
        ControllerMappingStore.defaultMappings[$0] ?? .disabled
    }) {
        self.mappingProvider = mappingProvider
    }

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidBecomeCurrent,
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

    func setOperationMode(_ mode: ControllerOperationMode) {
        guard mode != operationMode else { return }
        resetInputState()
        operationMode = mode
        onOperationModeChange?(mode)
    }

    func toggleOperationMode() {
        let nextMode: ControllerOperationMode = (operationMode == .native ? .mapping : .native)
        setOperationMode(nextMode)
        onToggleOperationMode?()
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
        let allControllers = GCController.controllers()
        let joyConControllers = allControllers.filter { $0.joyConHardwareKind != nil }
        let nonJoyConControllers = allControllers.filter {
            $0.joyConHardwareKind == nil && $0.extendedGamepad != nil
        }
        let currentController = GCController.current.flatMap { current in
            allControllers.first(where: { $0 === current })
        }
        let attachedController = controller.flatMap { attached in
            allControllers.first(where: { $0 === attached })
        }
        let currentPrefersJoyCon = currentController?.joyConHardwareKind != nil
        let currentPrefersStandard = currentController.map {
            $0.joyConHardwareKind == nil && $0.extendedGamepad != nil
        } == true
        let attachedIsJoyCon = attachedController?.joyConHardwareKind != nil
        let shouldUseJoyCon = JoyConControllerSelectionPolicy.shouldUseJoyCon(
            hasJoyCon: !joyConControllers.isEmpty,
            hasStandardController: !nonJoyConControllers.isEmpty,
            currentIsJoyCon: currentPrefersJoyCon,
            currentIsStandardController: currentPrefersStandard,
            attachedIsJoyCon: attachedIsJoyCon
        )
        if shouldUseJoyCon {
            attachJoyConControllers(joyConControllers)
            return
        }

        joyConComposition = joyConCoordinator.reconcile([])
        joyConControllersByID.removeAll()
        onJoyConChange?(nil)
        let controllers = nonJoyConControllers
        let selectedController = GCController.current.flatMap { current in
            controllers.first(where: { $0 === current })
        } ?? controller.flatMap { attached in
            controllers.first(where: { $0 === attached })
        } ?? controllers.first
        guard let selected = selectedController,
              let gamepad = selected.extendedGamepad else {
            detachObservedHandlers()
            resetInputState()
            controller = nil
            controllerFamily = .generic
            onControllerChange?(nil, .generic)
            onControllerSetChange?([])
            onAvailableInputsChange?(ControllerInput.availableInputs(for: .generic))
            print("[agent-deck] controller unavailable")
            return
        }
        guard controller !== selected else { return }
        detachObservedHandlers()
        resetInputState()
        controller = selected
        let family = ControllerFamily.detect(controller: selected)
        controllerFamily = family
        let generation = inputSourceGeneration
        let endpointID = ObjectIdentifier(selected)
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            DispatchQueue.main.async {
                guard let self,
                      self.inputSourceGeneration == generation,
                      let activeController = self.controller,
                      ObjectIdentifier(activeController) == endpointID else { return }
                self.handle(gamepad: gamepad, changedElement: element)
            }
        }
        if let homeButton = gamepad.buttonHome {
            homeButton.pressedChangedHandler = { [weak self] button, _, isPressed in
                DispatchQueue.main.async {
                    guard let self,
                          self.inputSourceGeneration == generation,
                          let activeController = self.controller,
                          ObjectIdentifier(activeController) == endpointID else { return }
                    self.handleHomeButton(isPressed: isPressed)
                }
            }
        }
        if #available(macOS 14.0, *) {
            selected.physicalInputProfile.valueDidChangeHandler = { [weak self] profile, element in
                DispatchQueue.main.async {
                    guard let self,
                          self.inputSourceGeneration == generation,
                          let activeController = self.controller,
                          ObjectIdentifier(activeController) == endpointID else { return }
                    if element.aliases.contains(GCInputButtonHome),
                       let button = element as? GCControllerButtonInput {
                        self.handleHomeButton(isPressed: button.isPressed)
                    }
                }
            }
        }
        onControllerChange?(selected, family)
        onControllerSetChange?([selected])
        onAvailableInputsChange?(ControllerInput.availableInputs(for: family))
        print("[agent-deck] controller ready on \(selected.vendorName ?? selected.productCategory)")
    }

    private func attachJoyConControllers(_ controllers: [GCController]) {
        let endpoints = controllers.compactMap { controller -> JoyConEndpointDescriptor? in
            guard let kind = controller.joyConHardwareKind else { return nil }
            return JoyConEndpointDescriptor(
                id: controller.joyConEndpointID,
                kind: kind,
                capabilities: controller.joyConCapabilities
            )
        }
        let previous = joyConComposition
        let next = joyConCoordinator.reconcile(endpoints)
        joyConControllersByID = Dictionary(uniqueKeysWithValues: controllers.map {
            ($0.joyConEndpointID, $0)
        })
        guard let mode = next.mode else {
            attachPreferredController()
            return
        }
        if next.generation == previous.generation {
            joyConComposition = next
            handleJoyConProfiles(generation: next.generation)
            onJoyConChange?(makeJoyConControllerSnapshot(mode: mode, composition: next))
            return
        }

        detachObservedHandlers()
        resetInputState()
        joyConInputSnapshot = .neutral
        joyConActiveInputs.removeAll()
        joyConComposition = next

        let activeIDs = [next.combinedID, next.leftID, next.rightID].compactMap { $0 }
        observedControllers = activeIDs.compactMap { joyConControllersByID[$0] }
        controller = observedControllers.first
        controllerFamily = mode.controllerFamily
        let generation = next.generation
        for observed in observedControllers {
            let endpointID = observed.joyConEndpointID
            let kind = observed.joyConHardwareKind ?? .pair
            let sample = JoyConProfileReader.sample(
                controller: observed,
                kind: kind,
                paired: mode == .pair,
                orientation: joyConOrientationProvider?() ?? .horizontal
            )
            let inputs = sample.availableInputs.map(\.rawValue).sorted().joined(separator: ",")
            let elements = observed.joyConCapabilities.profileElements.joined(separator: ",")
            let backend = sample.availableInputs.isEmpty ? "hid-fallback-required" : "gamecontroller"
            print("[agent-deck] Joy-Con diagnostic side=\(String(describing: kind)) backend=\(backend) category=\(observed.productCategory) inputs=\(inputs) elements=\(elements)")
            let callbackSources = JoyConInputMonitoringPolicy.sources(
                kind: kind,
                hasMicroGamepad: observed.microGamepad != nil,
                hasExtendedGamepad: observed.extendedGamepad != nil
            )
            let publishChange = { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          self.joyConComposition.accepts(
                              endpointID: endpointID,
                              generation: generation
                          ) else { return }
                    self.handleJoyConProfiles(generation: generation)
                }
            }
            if callbackSources.contains(.physicalProfile) {
                observed.physicalInputProfile.valueDidChangeHandler = { _, _ in publishChange() }
            }
            if callbackSources.contains(.microGamepad) {
                observed.microGamepad?.valueChangedHandler = { _, _ in publishChange() }
            }
            if callbackSources.contains(.extendedGamepad) {
                observed.extendedGamepad?.valueChangedHandler = { _, _ in publishChange() }
            }
        }

        let logicalSnapshot = makeJoyConControllerSnapshot(mode: mode, composition: next)
        onControllerChange?(controller, mode.controllerFamily)
        onControllerSetChange?(observedControllers)
        handleJoyConProfiles(generation: generation)
        onJoyConChange?(logicalSnapshot)
        print("[agent-deck] Joy-Con mode=\(mode.rawValue) endpoints=\(activeIDs.joined(separator: ",")) inactive=\(next.inactiveIDs.count)")
    }

    private func detachObservedHandlers() {
        inputSourceGeneration &+= 1
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller?.extendedGamepad?.buttonHome?.pressedChangedHandler = nil
        if #available(macOS 14.0, *) {
            controller?.physicalInputProfile.valueDidChangeHandler = nil
        }
        for observed in observedControllers {
            observed.extendedGamepad?.valueChangedHandler = nil
            observed.microGamepad?.valueChangedHandler = nil
            observed.physicalInputProfile.valueDidChangeHandler = nil
        }
        isHomeButtonPressed = false
        observedControllers.removeAll()
    }

    private func makeJoyConControllerSnapshot(
        mode: JoyConMode,
        composition: JoyConComposition
    ) -> JoyConControllerSnapshot {
        let combinedCapabilities = composition.combinedID.flatMap {
            joyConControllersByID[$0]?.joyConCapabilities
        }
        return JoyConControllerSnapshot(
            mode: mode,
            left: composition.leftID.flatMap { joyConControllersByID[$0]?.joyConCapabilities }
                ?? combinedCapabilities,
            right: composition.rightID.flatMap { joyConControllersByID[$0]?.joyConCapabilities }
                ?? combinedCapabilities,
            inactiveEndpointCount: composition.inactiveIDs.count
        )
    }

    private func handleJoyConProfiles(generation: UInt64) {
        guard let mode = joyConComposition.mode,
              joyConComposition.generation == generation else { return }
        var samples: [JoyConProfileSample] = []
        if let combinedID = joyConComposition.combinedID,
           let combined = joyConControllersByID[combinedID] {
            samples.append(JoyConProfileReader.sample(controller: combined, kind: .pair, paired: true))
        } else {
            if let leftID = joyConComposition.leftID,
               let left = joyConControllersByID[leftID] {
                let sample = JoyConProfileReader.sample(
                    controller: left,
                    kind: .left,
                    paired: mode == .pair,
                    orientation: joyConOrientationProvider?() ?? .horizontal
                )
                samples.append(projectJoyConShoulders(sample, side: .left, mode: mode))
            }
            if let rightID = joyConComposition.rightID,
               let right = joyConControllersByID[rightID] {
                let sample = JoyConProfileReader.sample(
                    controller: right,
                    kind: .right,
                    paired: mode == .pair,
                    orientation: joyConOrientationProvider?() ?? .horizontal
                )
                samples.append(projectJoyConShoulders(sample, side: .right, mode: mode))
            }
        }
        let next = samples.reduce(JoyConInputSnapshot.neutral) { $0.merging($1.snapshot) }
        let baseAvailable = samples.reduce(into: Set<ControllerInput>()) {
            $0.formUnion($1.availableInputs)
        }
        let available = JoyConProfileReader.expandedAvailableInputs(
            from: baseAvailable,
            hasSecondaryStick: mode == .pair
        )
        applyJoyConSnapshot(next)
        let supported = ControllerInput.availableInputs(for: mode.controllerFamily)
        onAvailableInputsChange?(available.intersection(supported))
    }

    private func projectJoyConShoulders(
        _ sample: JoyConProfileSample,
        side: JoyConSide,
        mode: JoyConMode
    ) -> JoyConProfileSample {
        guard let hidSnapshot = joyConHIDShoulderSnapshots[side] else {
            return mode == .pair
                ? JoyConPairedShoulderAdapter.suppressAmbiguousShoulders(in: sample, side: side)
                : JoyConSingleShoulderAdapter.suppressAmbiguousShoulders(in: sample)
        }
        if mode == .pair {
            return JoyConPairedShoulderAdapter.apply(hidSnapshot, to: sample, side: side)
        }
        return JoyConSingleShoulderAdapter.apply(
            hidSnapshot,
            to: sample,
            side: side,
            orientation: joyConOrientationProvider?() ?? .horizontal
        )
    }

    func updateJoyConHIDShoulders(
        side: JoyConSide,
        snapshot: JoyConHIDShoulderSnapshot?
    ) {
        if let snapshot {
            joyConHIDShoulderSnapshots[side] = snapshot
        } else {
            joyConHIDShoulderSnapshots.removeValue(forKey: side)
        }
        let matchingEndpointCount = joyConControllersByID.values.filter {
            $0.joyConHardwareKind == (side == .left ? .left : .right)
        }.count
        guard snapshot == nil || matchingEndpointCount <= 1 else { return }
        guard let mode = joyConComposition.mode else { return }
        let sideIsActive = switch side {
        case .left: joyConComposition.leftID != nil
        case .right: joyConComposition.rightID != nil
        }
        guard sideIsActive,
              joyConComposition.combinedID == nil,
              mode == .pair || mode == (side == .left ? .left : .right) else { return }
        handleJoyConProfiles(generation: joyConComposition.generation)
    }

    func refreshJoyConOrientation() {
        resetInputState()
        guard let mode = joyConComposition.mode, mode != .pair else { return }
        handleJoyConProfiles(generation: joyConComposition.generation)
    }

    func applyJoyConSnapshot(_ next: JoyConInputSnapshot) {
        let previous = joyConInputSnapshot
        let allInputs = Set(previous.buttons.keys).union(next.buttons.keys)

        if operationMode == .native {
            for input in allInputs {
                let wasPressed = previous.buttons[input] == true
                let isPressed = next.buttons[input] == true
                guard !wasPressed && isPressed else { continue }
                if input == .home || mappingProvider(input) == .toggleOperationMode {
                    toggleOperationMode()
                    break
                }
            }
            joyConInputSnapshot = next
            return
        }

        var modifierActive = false
        for input in allInputs where mappingProvider(input) == .functionModifier {
            if next.buttons[input] == true {
                modifierActive = true
            }
        }
        functionPressed = modifierActive

        for input in allInputs {
            let wasPressed = previous.buttons[input] == true
            let isPressed = next.buttons[input] == true
            guard wasPressed != isPressed else { continue }

            publishInput(input, pressed: isPressed)
            if mappingProvider(input) == .functionModifier {
                if !isPressed {
                    joyConActiveInputs.removeValue(forKey: input)
                }
            } else {
                handleJoyConButton(input, isPressed: isPressed)
            }
        }

        leftStickHandler?(next.primaryStick.x, next.primaryStick.y, functionPressed)
        updateJoyConJoystick(next)
        updateFunctionRightStick(x: next.secondaryStick.x, y: next.secondaryStick.y)
        joyConInputSnapshot = next
    }

    private func handleJoyConButton(_ input: ControllerInput, isPressed: Bool) {
        publishInput(input, pressed: isPressed)
        if !isPressed {
            if let activeInput = joyConActiveInputs.removeValue(forKey: input) {
                handleMappedDirection(activeInput, isPressed: false)
            }
            return
        }
        let effectiveInput = functionPressed ? functionInput(for: input) ?? input : input
        joyConActiveInputs[input] = effectiveInput
        handleMappedDirection(effectiveInput, isPressed: true)
    }

    private func functionInput(for input: ControllerInput) -> ControllerInput? {
        switch input {
        case .buttonA: .functionButtonA
        case .buttonB: .functionButtonB
        case .buttonX: .functionButtonX
        case .buttonY: .functionButtonY
        case .leftShoulder: .functionLeftShoulder
        case .rightShoulder: .functionRightShoulder
        case .rightTrigger: .functionRightTrigger
        case .leftThumbstickButton: .functionLeftThumbstickButton
        case .rightThumbstickButton: .functionRightThumbstickButton
        case .dpadUp: .functionDpadUp
        case .dpadLeft: .functionDpadLeft
        case .dpadDown: .functionDpadDown
        case .dpadRight: .functionDpadRight
        default: nil
        }
    }

    private func updateJoyConJoystick(_ snapshot: JoyConInputSnapshot) {
        let dpadX: Float = if snapshot.buttons[.dpadRight] == true &&
            mappingProvider(.dpadRight) == .radialInput {
            1
        } else if snapshot.buttons[.dpadLeft] == true &&
            mappingProvider(.dpadLeft) == .radialInput {
            -1
        } else {
            0
        }
        let dpadY: Float = if snapshot.buttons[.dpadUp] == true &&
            mappingProvider(.dpadUp) == .radialInput {
            1
        } else if snapshot.buttons[.dpadDown] == true &&
            mappingProvider(.dpadDown) == .radialInput {
            -1
        } else {
            0
        }
        let x = !functionPressed && abs(dpadX) > 0.1 ? dpadX
            : (functionPressed ? 0 : snapshot.secondaryStick.x)
        let y = !functionPressed && abs(dpadY) > 0.1 ? dpadY
            : (functionPressed ? 0 : snapshot.secondaryStick.y)
        publishJoystick(x: x, y: y)
    }

    private func publishJoystick(x: Float, y: Float) {
        let distance = min(sqrt(x * x + y * y), 1)
        let angle = distance < 0.08 ? 0 : Self.radialAngle(x: x, y: y)
        let changed = lastJoystick == nil ||
            abs(lastJoystick!.angle - angle) > 0.01 ||
            abs(lastJoystick!.distance - distance) > 0.01
        guard changed else { return }
        _ = joystickHandler?(angle, distance)
        lastJoystick = (angle, distance)
    }

    private func handle(gamepad: GCExtendedGamepad, changedElement: GCControllerElement) {
        if let homeButton = gamepad.buttonHome, changedElement === homeButton {
            handleHomeButton(isPressed: homeButton.isPressed)
            return
        }
        if operationMode == .native {
            if let buttonInput = changedElement as? GCControllerButtonInput, buttonInput.isPressed {
                if let input = inputForElement(changedElement, in: gamepad),
                   mappingProvider(input) == .toggleOperationMode {
                    toggleOperationMode()
                    return
                }
            }
            return
        }

        sampleTouchpadPointer(from: gamepad)

        if changedElement === gamepad.leftTrigger {
            if mappingProvider(.leftTrigger) == .functionModifier {
                functionPressed = gamepad.leftTrigger.value >= 0.55
                let id = ObjectIdentifier(gamepad.leftTrigger)
                if functionPressed {
                    controllerInputsByButton[id] = .leftTrigger
                    publishInput(.leftTrigger, pressed: true)
                } else {
                    release(gamepad.leftTrigger)
                }
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
        updateFunctionRightStick(gamepad)
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
        } else if changedElement === gamepad.rightTrigger {
            rightTriggerFeedbackHandler?(gamepad.rightTrigger.value)
            let input: ControllerInput = functionPressed ? .functionRightTrigger : .rightTrigger
            if controllerFamily == .dualSense,
               let isPressed = rightTriggerPressState.update(value: gamepad.rightTrigger.value) {
                handleMappedButton(
                    gamepad.rightTrigger,
                    input: input,
                    isPressed: isPressed
                )
            } else if controllerFamily != .dualSense {
                handleMappedButton(gamepad.rightTrigger, input: input)
            }
        } else if let button = gamepad.leftThumbstickButton, changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? .functionLeftThumbstickButton : .leftThumbstickButton
            )
        } else if let button = gamepad.rightThumbstickButton, changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? .functionRightThumbstickButton : .rightThumbstickButton
            )
        } else if let button = Self.touchpadButton(for: gamepad), changedElement === button {
            handleMappedButton(button, input: .touchpadButton)
        }
    }

    private static func touchpadButton(for gamepad: GCExtendedGamepad) -> GCControllerButtonInput? {
        if let dualSense = gamepad as? GCDualSenseGamepad { return dualSense.touchpadButton }
        if let dualShock = gamepad as? GCDualShockGamepad { return dualShock.touchpadButton }
        return nil
    }

    private static func touchpadPrimary(for gamepad: GCExtendedGamepad) -> GCControllerDirectionPad? {
        if let dualSense = gamepad as? GCDualSenseGamepad { return dualSense.touchpadPrimary }
        if let dualShock = gamepad as? GCDualShockGamepad { return dualShock.touchpadPrimary }
        return nil
    }

    private func inputForElement(_ element: GCControllerElement, in gamepad: GCExtendedGamepad) -> ControllerInput? {
        if element === gamepad.buttonA { return .buttonA }
        if element === gamepad.buttonB { return .buttonB }
        if element === gamepad.buttonX { return .buttonX }
        if element === gamepad.buttonY { return .buttonY }
        if element === gamepad.leftShoulder { return .leftShoulder }
        if element === gamepad.rightShoulder { return .rightShoulder }
        if element === gamepad.leftTrigger { return .leftTrigger }
        if element === gamepad.rightTrigger { return .rightTrigger }
        if element === gamepad.buttonMenu { return .menu }
        if element === gamepad.buttonOptions { return .options }
        if element === gamepad.buttonHome { return .home }
        if element === gamepad.leftThumbstickButton { return .leftThumbstickButton }
        if element === gamepad.rightThumbstickButton { return .rightThumbstickButton }
        if let touchpad = Self.touchpadButton(for: gamepad), element === touchpad { return .touchpadButton }
        if #available(macOS 14.0, *) {
            if element.aliases.contains(GCInputButtonHome) { return .home }
            if element.aliases.contains(GCInputButtonMenu) { return .menu }
            if element.aliases.contains(GCInputButtonOptions) { return .options }
        }
        return nil
    }

    private func sampleTouchpadPointer(from gamepad: GCExtendedGamepad) {
        guard let primary = Self.touchpadPrimary(for: gamepad) else { return }
        if let delta = touchpadTracker.update(
            x: primary.xAxis.value,
            y: primary.yAxis.value
        ) {
            touchpadPointerHandler?(delta.x, delta.y)
        }
    }

    private func handleMappedButton(_ button: GCControllerButtonInput, input: ControllerInput) {
        handleMappedButton(button, input: input, isPressed: button.isPressed)
    }

    private var isHomeButtonPressed = false

    func handleRawHomeButton(isPressed: Bool) {
        handleHomeButton(isPressed: isPressed)
    }

    func handleHomeButton(isPressed: Bool) {
        guard isPressed != isHomeButtonPressed else { return }
        isHomeButtonPressed = isPressed

        if operationMode == .native {
            if isPressed {
                toggleOperationMode()
            }
            return
        }
        handleMappedHomeButton(isPressed: isPressed)
    }

    private func handleMappedHomeButton(isPressed: Bool) {
        let fakeID = ObjectIdentifier(self)
        guard isPressed else {
            if let input = controllerInputsByButton.removeValue(forKey: fakeID) {
                publishInput(input, pressed: false)
            }
            pressedButtons.remove(fakeID)
            if let action = activeControllerActions.removeValue(forKey: fakeID) {
                end(action)
            }
            return
        }
        if let previousInput = controllerInputsByButton[fakeID], previousInput != .home {
            publishInput(previousInput, pressed: false)
        }
        controllerInputsByButton[fakeID] = .home
        publishInput(.home, pressed: true)
        guard let action = resolvedAction(for: .home) else { return }
        print("[agent-deck] direct DualSense PS button -> action=\(action)")
        if pressedButtons.insert(fakeID).inserted {
            if begin(action) {
                activeControllerActions[fakeID] = action
            } else {
                pressedButtons.remove(fakeID)
            }
        }
    }

    private func handleMappedButton(
        _ button: GCControllerButtonInput,
        input: ControllerInput,
        isPressed: Bool
    ) {
        let id = ObjectIdentifier(button)
        guard isPressed else {
            release(button)
            return
        }
        if let previousInput = controllerInputsByButton[id], previousInput != input {
            publishInput(previousInput, pressed: false)
        }
        controllerInputsByButton[id] = input
        publishInput(input, pressed: true)
        guard let action = resolvedAction(for: input) else {
            return
        }
        print("[agent-deck] button press input=\(input.rawValue) action=\(action)")
        handleControllerAction(button, action: action, isPressed: true)
    }

    private func resolvedAction(for input: ControllerInput) -> ControllerAction? {
        let mapped = mappingProvider(input)
        if mapped == .openApplication {
            guard let bundleIdentifier = openApplicationTargetProvider?(input)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty else {
                return nil
            }
            return .openApplication(bundleIdentifier)
        }
        if mapped == .recordedShortcut {
            guard let shortcut = recordedShortcutProvider?(input) else { return nil }
            return .recordedShortcut(shortcut)
        }
        return mapped.controllerAction
    }

    static func faceAction(for button: FaceButton, functionPressed: Bool) -> ControllerAction {
        if functionPressed {
            switch button {
            case .a: return .microKey("ACT07")
            case .b: return .microKey("ACT08")
            case .x: return .textInput("no")
            case .y: return .textInput("yes")
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
        action: ControllerAction,
        isPressed: Bool
    ) {
        let id = ObjectIdentifier(button)
        if isPressed {
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
        case .textInput(let text):
            succeeded = textInputHandler?(text) == true
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
        case .mousePrecision:
            mousePrecisionPressed = true
            mousePrecisionHandler?(true)
            succeeded = true
        case .openApplication(let bundleIdentifier):
            succeeded = openApplicationHandler?(bundleIdentifier) == true
        case .recordedShortcut(let shortcut):
            recordedShortcutHandler?(shortcut, true)
            succeeded = true
        case .toggleOperationMode:
            toggleOperationMode()
            return true
        }
        if succeeded { activeActionCounts[action] = 1 }
        return succeeded
    }

    private func end(_ action: ControllerAction) {
        switch action {
        case .slotOffset, .selectSlot, .toggleOperationMode:
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
        case .textInput, .openApplication, .toggleOperationMode:
            break
        case .recordedShortcut(let shortcut):
            recordedShortcutHandler?(shortcut, false)
        case .microKey(let key):
            _ = keyHandler?(key, 0)
        case .slotOffset, .selectSlot:
            break
        case .mouseSpeedBoost:
            mouseSpeedBoostPressed = false
            mouseSpeedBoostHandler?(false)
        case .mousePrecision:
            mousePrecisionPressed = false
            mousePrecisionHandler?(false)
        }
    }

    private func release(_ button: GCControllerButtonInput) {
        let id = ObjectIdentifier(button)
        if let input = controllerInputsByButton.removeValue(forKey: id) {
            publishInput(input, pressed: false)
        }
        pressedButtons.remove(id)
        if let action = activeControllerActions.removeValue(forKey: id) {
            end(action)
        }
    }

    private func publishInput(_ input: ControllerInput, pressed: Bool) {
        guard pressed != publishedInputs.contains(input) else { return }
        if pressed {
            publishedInputs.insert(input)
        } else {
            publishedInputs.remove(input)
        }
        onInputStateChange?(input, pressed)
    }

    func selectSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
        onSlotSelected?(slot)
        tap(agentKey(for: slot))
    }

    func syncSelectedSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
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
        let rightX = functionPressed ? 0 : gamepad.rightThumbstick.xAxis.value
        let rightY = functionPressed ? 0 : gamepad.rightThumbstick.yAxis.value
        let x = !functionPressed && abs(dpadX) > 0.1
            ? dpadX : rightX
        let y = !functionPressed && abs(dpadY) > 0.1
            ? dpadY : rightY
        publishJoystick(x: x, y: y)
    }

    private func updateFunctionRightStick(_ gamepad: GCExtendedGamepad) {
        updateFunctionRightStick(
            x: gamepad.rightThumbstick.xAxis.value,
            y: gamepad.rightThumbstick.yAxis.value
        )
    }

    private func updateFunctionRightStick(x: Float, y: Float) {
        let nextInput: ControllerInput?
        if functionPressed {
            nextInput = Self.functionRightStickInput(
                x: x,
                y: y,
                current: activeFunctionRightStickDirection
            )
        } else {
            nextInput = nil
        }

        if activeFunctionRightStickDirection != nextInput {
            if let activeFunctionRightStickDirection {
                handleMappedDirection(activeFunctionRightStickDirection, isPressed: false)
            }
            if let nextInput {
                handleMappedDirection(nextInput, isPressed: true)
            }
            activeFunctionRightStickDirection = nextInput
        }
    }

    private func handleMappedDirection(_ input: ControllerInput, isPressed: Bool) {
        if !isPressed {
            pressedDirectionInputs.remove(input)
            if let action = activeDirectionActions.removeValue(forKey: input) {
                end(action)
            }
            return
        }
        guard pressedDirectionInputs.insert(input).inserted else { return }
        guard let action = resolvedAction(for: input) else {
            pressedDirectionInputs.remove(input)
            return
        }
        guard begin(action) else {
            pressedDirectionInputs.remove(input)
            return
        }
        activeDirectionActions[input] = action
    }

    static func dominantStickDirection(
        x: Float,
        y: Float,
        pressThreshold: Float = 0.55
    ) -> StickDirection? {
        let absX = abs(x)
        let absY = abs(y)
        guard max(absX, absY) >= pressThreshold else { return nil }
        if absX > absY {
            return x > 0 ? .right : .left
        }
        return y > 0 ? .up : .down
    }

    static func functionRightStickInput(
        x: Float,
        y: Float,
        current: ControllerInput?,
        pressThreshold: Float = 0.55,
        releaseThreshold: Float = 0.35
    ) -> ControllerInput? {
        let inputForDirection: (StickDirection) -> ControllerInput = { direction in
            switch direction {
            case .up: .functionRightStickUp
            case .left: .functionRightStickLeft
            case .down: .functionRightStickDown
            case .right: .functionRightStickRight
            }
        }

        if let current,
           let currentDirection = stickDirection(for: current) {
            let currentValue = axisValue(for: currentDirection, x: x, y: y)
            if currentValue >= releaseThreshold,
               dominantStickDirection(x: x, y: y, pressThreshold: releaseThreshold) == currentDirection {
                return current
            }
        }

        return dominantStickDirection(x: x, y: y, pressThreshold: pressThreshold)
            .map(inputForDirection)
    }

    private static func stickDirection(for input: ControllerInput) -> StickDirection? {
        switch input {
        case .functionRightStickUp: .up
        case .functionRightStickLeft: .left
        case .functionRightStickDown: .down
        case .functionRightStickRight: .right
        default: nil
        }
    }

    private static func axisValue(for direction: StickDirection, x: Float, y: Float) -> Float {
        switch direction {
        case .up: y
        case .down: -y
        case .right: x
        case .left: -x
        }
    }

    static func radialAngle(x: Float, y: Float) -> Float {
        let turns = atan2(-y, x) / (2 * Float.pi)
        return turns >= 0 ? turns : turns + 1
    }

    func resetInputState() {
        for action in activeControllerActions.values { end(action) }
        for action in activeDirectionActions.values { end(action) }
        if mouseSpeedBoostPressed { mouseSpeedBoostHandler?(false) }
        if mousePrecisionPressed { mousePrecisionHandler?(false) }
        pressedButtons.removeAll()
        controllerInputsByButton.removeAll()
        activeControllerActions.removeAll()
        pressedDirectionInputs.removeAll()
        activeDirectionActions.removeAll()
        activeActionCounts.removeAll()
        functionPressed = false
        if let lastJoystick, lastJoystick.distance > 0 {
            _ = joystickHandler?(0, 0)
        }
        lastJoystick = nil
        mouseSpeedBoostPressed = false
        mousePrecisionPressed = false
        activeFunctionRightStickDirection = nil
        joyConActiveInputs.removeAll()
        joyConInputSnapshot = .neutral
        touchpadTracker.reset()
        rightTriggerPressState = AnalogButtonPressState(
            pressPoint: RightTriggerPressState.releasePoint,
            resetPoint: RightTriggerPressState.resetPoint
        )
        for input in publishedInputs {
            onInputStateChange?(input, false)
        }
        publishedInputs.removeAll()
        leftStickHandler?(0, 0, false)
    }
}
