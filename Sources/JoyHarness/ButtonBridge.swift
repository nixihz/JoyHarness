import Foundation
import GameController

enum MouseButton: Hashable {
    case left
    case right
    case middle
}

enum SystemKey: Hashable {
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case enter
    case backspace
    case escape
    case rightCommand
    case copy
    case paste
    case closeWindow
    case screenshotTool
    case browserBack
    case browserForward
    case claudePreviousSession
    case claudeNextSession
    case claudeSearch
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

final class JoyConInputRefreshScheduler {
    typealias Enqueue = (@escaping () -> Void) -> Void

    private let enqueue: Enqueue
    private let lock = NSLock()
    private var pendingGenerations: Set<UInt64> = []

    init(enqueue: @escaping Enqueue = { operation in
        DispatchQueue.main.async(execute: operation)
    }) {
        self.enqueue = enqueue
    }

    func schedule(generation: UInt64, operation: @escaping () -> Void) {
        lock.lock()
        let shouldEnqueue = pendingGenerations.insert(generation).inserted
        lock.unlock()
        guard shouldEnqueue else { return }

        enqueue { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingGenerations.remove(generation)
            self.lock.unlock()
            operation()
        }
    }
}

/// Merges the GameController and raw HID reports of one Home button so each
/// physical press yields one press edge, whichever source arrives first, late,
/// or not at all.
struct HomeButtonPressMerger {
    enum Source: CaseIterable {
        case gameController
        case rawHID
    }

    /// How long a press from one source waits for the other source's copy.
    /// GameController Home can trail raw HID by the system gesture delay.
    static let defaultEchoWindow: TimeInterval = 1.0

    let echoWindow: TimeInterval
    private(set) var isPressed = false
    private var pressedSources: Set<Source> = []
    private var echoDeadlines: [Source: [TimeInterval]] = [:]

    init(echoWindow: TimeInterval = Self.defaultEchoWindow) {
        self.echoWindow = echoWindow
    }

    /// Returns the merged edge, or nil when the report repeats a source's
    /// state or duplicates a press the other source already reported.
    mutating func update(
        _ source: Source,
        isPressed sourceIsPressed: Bool,
        at timestamp: TimeInterval
    ) -> Bool? {
        guard sourceIsPressed != pressedSources.contains(source) else { return nil }

        guard sourceIsPressed else {
            pressedSources.remove(source)
            guard isPressed else { return nil }
            // The first release wins and forgets the other source's press, so
            // a source that loses its release can neither hold the merged
            // button down nor ignore its own next press as a repeat.
            pressedSources.removeAll()
            isPressed = false
            return false
        }

        pressedSources.insert(source)
        var pendingEchoes = echoDeadlines[source, default: []].filter { $0 >= timestamp }
        if !pendingEchoes.isEmpty {
            pendingEchoes.removeFirst()
            echoDeadlines[source] = pendingEchoes
            return nil
        }
        echoDeadlines[source] = nil
        guard !isPressed else { return nil }

        isPressed = true
        for other in Source.allCases where other != source {
            echoDeadlines[other] = echoDeadlines[other, default: []]
                .filter { $0 >= timestamp } + [timestamp + echoWindow]
        }
        return true
    }

    mutating func reset() {
        isPressed = false
        pressedSources.removeAll()
        echoDeadlines.removeAll()
    }
}

/// Captured alongside the button event, before delivery to the main queue.
/// The source's current routing policy is filled in before handing it off.
struct MotionJumpInputSnapshot {
    var triggerValue: Float
    var hasConflictingInput: Bool
    var timestamp: TimeInterval
    var allowsGesture: Bool
}

/// Voice owns analog output until each held channel returns to neutral. The
/// timestamp fence also rejects callbacks captured before voice released it.
struct AIVoiceAnalogNeutralGate {
    enum Channel: CaseIterable { case leftStick, rightStick, touchpad }

    private(set) var isCapturing = false
    private var awaitingNeutral: Set<Channel> = []
    private var ignoreEventsThrough: TimeInterval = -.infinity

    mutating func setCaptureActive(
        _ active: Bool,
        at timestamp: TimeInterval,
        neutralChannels: Set<Channel> = []
    ) {
        guard active != isCapturing else { return }
        isCapturing = active
        ignoreEventsThrough = timestamp
        awaitingNeutral = Set(Channel.allCases).subtracting(neutralChannels)
    }

    mutating func permits(_ channel: Channel, isNeutral: Bool, at timestamp: TimeInterval) -> Bool {
        guard !isCapturing, timestamp > ignoreEventsThrough else { return false }
        guard awaitingNeutral.contains(channel) else { return true }
        if isNeutral { awaitingNeutral.remove(channel) }
        // The release belongs to the voice interaction, not a fresh input.
        return false
    }
}

private struct StandardGamepadEventSnapshot {
    let motionJumpInput: MotionJumpInputSnapshot
    let changedButtonPressed: Bool?
    let changedButtonValue: Float?
    let leftStickX: Float
    let leftStickY: Float
    let rightStickX: Float
    let rightStickY: Float
    let touchpadX: Float?
    let touchpadY: Float?
    let secondaryTouching: Bool
    let dpadUp: Bool
    let dpadDown: Bool
    let dpadLeft: Bool
    let dpadRight: Bool

    init(gamepad: GCExtendedGamepad, changedElement: GCControllerElement) {
        motionJumpInput = ButtonBridge.motionJumpSnapshot(gamepad: gamepad)
        changedButtonPressed = (changedElement as? GCControllerButtonInput)?.isPressed
        changedButtonValue = (changedElement as? GCControllerButtonInput)?.value
        leftStickX = gamepad.leftThumbstick.xAxis.value
        leftStickY = gamepad.leftThumbstick.yAxis.value
        rightStickX = gamepad.rightThumbstick.xAxis.value
        rightStickY = gamepad.rightThumbstick.yAxis.value
        let primary = ButtonBridge.touchpadPrimary(for: gamepad)
        touchpadX = primary?.xAxis.value
        touchpadY = primary?.yAxis.value
        secondaryTouching = ButtonBridge.secondaryTouchpadIsActive(for: gamepad)
        dpadUp = gamepad.dpad.up.isPressed
        dpadDown = gamepad.dpad.down.isPressed
        dpadLeft = gamepad.dpad.left.isPressed
        dpadRight = gamepad.dpad.right.isPressed
    }

    func dpadPressed(for input: ControllerInput) -> Bool {
        switch input {
        case .dpadUp: dpadUp
        case .dpadDown: dpadDown
        case .dpadLeft: dpadLeft
        case .dpadRight: dpadRight
        default: false
        }
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
    private var joyConHIDStickSnapshots: [JoyConSide: JoyConHIDStickSnapshot] = [:]
    private var pressedButtons: Set<ObjectIdentifier> = []
    private var controllerInputsByButton: [ObjectIdentifier: ControllerInput] = [:]
    private var publishedInputs: Set<ControllerInput> = []
    private var activeControllerActions: [ObjectIdentifier: ControllerAction] = [:]
    private var activeActionCounts: [ControllerAction: Int] = [:]
    private var functionPressed = false {
        didSet { publishMouseSpeedBoost() }
    }
    private var lastJoystick: (angle: Float, distance: Float)?
    private var mouseSpeedBoostPressed = false {
        didSet { publishMouseSpeedBoost() }
    }
    private var publishedMouseSpeedBoost = false
    private var mousePrecisionPressed = false
    private var controllerFamily: ControllerFamily = .generic
    private var isRemoteControllerActive = false
    private var rightTriggerPressState = AnalogButtonPressState(
        pressPoint: RightTriggerPressState.releasePoint,
        resetPoint: RightTriggerPressState.resetPoint
    )
    private var activeFunctionRightStickDirection: ControllerInput?
    private var pressedDirectionInputs: Set<ControllerInput> = []
    private var activeDirectionActions: [ControllerInput: ControllerAction] = [:]
    private var touchpadTracker = TouchpadPointerTracker()
    private var inputSourceGeneration: UInt64 = 0
    private let joyConInputRefreshScheduler = JoyConInputRefreshScheduler()
    private var controllerObservers: [NSObjectProtocol] = []
    private var overlaySuppressedButtons: Set<ObjectIdentifier> = []
    private var suppressedJoyConModifiers: Set<ControllerInput> = []
    private var motionJumpSuppressesInputUntilNeutral = false
    private var aiVoiceAnalogGate = AIVoiceAnalogNeutralGate()
    private let externalMicrophoneGate = ControllerInputIsolationGate()
    var usesExternalVoiceControls = false

    /// Hardware exclusivity protects other apps; this gate also drops queued
    /// GameController events. It must not cancel the trusted PS/L2 gesture.
    func setExternalAudioCaptureActive(_ active: Bool) {
        guard externalMicrophoneGate.isBlocked != active else { return }
        externalMicrophoneGate.setBlocked(active)
        suspendMappedOutputs()
        if !active {
            overlaySuppressedButtons.removeAll()
            controllerInputsByButton.removeAll()
        }
    }

    func handleExternalAudioPSInput(_ sample: DualSensePSInputSample) {
        handleDualSensePSInput(sample, externalAudio: true)
    }

    func tapExternalVoiceShortcut() {
        guard usesExternalVoiceControls, operationMode == .mapping else { return }
        handleRemoteButton(.menu, isPressed: true)
        handleRemoteButton(.menu, isPressed: false)
    }

    func cancelExternalVoiceInput() {
        guard usesExternalVoiceControls, externalMicrophoneGate.isBlocked,
              operationMode == .mapping else { return }
        // Only overlay cancellation crosses the capture gate. Never dispatch
        // the user's ordinary B mapping while another app owns the controller.
        _ = inputInterceptor?(.buttonB, true)
        _ = inputInterceptor?(.buttonB, false)
    }

    var isRunning: Bool { !controllerObservers.isEmpty }
    var controllerObserverCount: Int { controllerObservers.count }

    private(set) var selectedSlot = 0
    private(set) var operationMode: ControllerOperationMode = .mapping
    var onToggleOperationMode: (() -> Void)?
    var onOperationModeChange: ((ControllerOperationMode) -> Void)?
    var keyHandler: ((String, Int) -> Bool)?
    var joystickHandler: ((Float, Float) -> Bool)?
    var leftStickHandler: ((Float, Float, Bool) -> Void)?
    /// Right stick scrolling. Receives zero while LT turns the right stick into shortcut directions.
    var rightStickHandler: ((Float, Float) -> Void)?
    var overlayStickHandler: ((Float, Float) -> Bool)?
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
    var inputInterceptor: ((ControllerInput, Bool) -> Bool)?
    var onHarnessSwitcherPresent: (() -> Void)?
    var aiVoiceEnabled = false {
        didSet {
            if oldValue && !aiVoiceEnabled { cancelAIVoiceInput() }
        }
    }
    var onAIVoiceBegin: (() -> Void)?
    var onAIVoiceEnd: (() -> Void)?
    var onAIVoiceRelease: ((TimeInterval) -> Void)?
    var onAIVoiceCancel: (() -> Void)?
    /// Return true to consume this device's input while recording or testing.
    var motionJumpInputHandler: ((MotionJumpInputSnapshot) -> Bool)?
    var motionJumpCancelHandler: (() -> Void)?
    var motionJumpIsCapturing: (() -> Bool)?
    var homeButtonClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var mappingProvider: (ControllerInput) -> ControllerMappedAction
    /// Only the physical input owner may replace a new PTT press. Releases
    /// of already active actions bypass resolution and always reach end().
    var shouldSuppressPTTInput: ((ControllerInput) -> Bool)?
    private var lastTrustedBatterySnapshot: ControllerBatterySnapshot?

    var batterySnapshot: ControllerBatterySnapshot? {
        guard !externalMicrophoneGate.isBlocked else { return lastTrustedBatterySnapshot }
        lastTrustedBatterySnapshot = ControllerBatterySnapshot(controller?.battery)
        return lastTrustedBatterySnapshot
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

    init(
        controllerFamily: ControllerFamily = .generic,
        mappingProvider: @escaping (ControllerInput) -> ControllerMappedAction = {
            ControllerMappingStore.defaultMappings[$0] ?? .disabled
        }
    ) {
        self.controllerFamily = controllerFamily
        self.mappingProvider = mappingProvider
    }

    private var functionLeftStickScrolls: Bool {
        functionPressed && controllerFamily.usesSingleJoyConStick
    }

    private func publishMouseSpeedBoost() {
        // L3/custom boost and the dual-stick function layer are independent
        // holds. Releasing either one must not cancel the other or stack speed.
        let active = mouseSpeedBoostPressed ||
            (functionPressed && !controllerFamily.usesSingleJoyConStick)
        guard active != publishedMouseSpeedBoost else { return }
        publishedMouseSpeedBoost = active
        mouseSpeedBoostHandler?(active)
    }

    func start() {
        guard controllerObservers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        controllerObservers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        })
        controllerObservers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidBecomeCurrent,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        })
        controllerObservers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.attachPreferredController()
        })
        attachPreferredController()
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        guard mode != operationMode else { return }
        resetInputState(preservingHomeButtonState: true)
        operationMode = mode
        onOperationModeChange?(mode)
    }

    func toggleOperationMode() {
        let nextMode: ControllerOperationMode = (operationMode == .native ? .mapping : .native)
        setOperationMode(nextMode)
        onToggleOperationMode?()
    }

    func stop() {
        guard !controllerObservers.isEmpty || controller != nil || !observedControllers.isEmpty || isRemoteControllerActive else { return }
        if !controllerObservers.isEmpty {
            GCController.stopWirelessControllerDiscovery()
        }
        for observer in controllerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        controllerObservers.removeAll()
        resetInputState()
        detachObservedHandlers()
        controller = nil
        controllerFamily = .generic
        isRemoteControllerActive = false
        joyConControllersByID.removeAll()
        joyConComposition = joyConCoordinator.reconcile([])
        joyConHIDShoulderSnapshots.removeAll()
        joyConHIDStickSnapshots.removeAll()
        onControllerChange?(nil, .generic)
        onControllerSetChange?([])
        onJoyConChange?(nil)
        onAvailableInputsChange?(ControllerInput.availableInputs(for: .generic))
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

    func rescanControllers() {
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        attachPreferredController()
    }

    /// Attaches one explicitly selected standard GameController endpoint.
    ///
    /// The normal bridge still owns discovery and selection. ControllerHub
    /// uses this entry point for independent per-device input sessions so
    /// multiple standard controllers can remain active at once.
    func attachController(_ selected: GCController) {
        guard selected.joyConHardwareKind == nil,
              selected.extendedGamepad != nil else { return }
        attachStandardController(selected)
    }

    private func attachPreferredController() {
        guard !isRemoteControllerActive else { return }
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
              selected.extendedGamepad != nil else {
            resetInputState()
            detachObservedHandlers()
            controller = nil
            controllerFamily = .generic
            onControllerChange?(nil, .generic)
            onControllerSetChange?([])
            onAvailableInputsChange?(ControllerInput.availableInputs(for: .generic))
            print("[agent-deck] controller unavailable")
            return
        }
        attachStandardController(selected)
    }

    private func attachStandardController(_ selected: GCController) {
        guard let gamepad = selected.extendedGamepad else { return }
        guard controller !== selected else { return }
        resetInputState()
        detachObservedHandlers()
        controller = selected
        lastTrustedBatterySnapshot = nil
        let family = ControllerFamily.detect(controller: selected)
        controllerFamily = family
        let generation = inputSourceGeneration
        let endpointID = ObjectIdentifier(selected)
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            guard let token = self?.externalMicrophoneGate.token() else { return }
            let event = StandardGamepadEventSnapshot(
                gamepad: gamepad,
                changedElement: element
            )
            DispatchQueue.main.async {
                guard let self,
                      self.externalMicrophoneGate.permits(token),
                      self.inputSourceGeneration == generation,
                      let activeController = self.controller,
                      ObjectIdentifier(activeController) == endpointID else { return }
                self.handle(
                    gamepad: gamepad,
                    changedElement: element,
                    event: event
                )
            }
        }
        if let homeButton = gamepad.buttonHome {
            // Home opens the Harness switcher, so ask the system not to hold or
            // swallow it for the Game Overlay. The system may still ignore this
            // preference, which is why DualSense also reads Home over raw HID.
            homeButton.preferredSystemGestureState = .disabled
            homeButton.pressedChangedHandler = { [weak self, weak gamepad] button, _, isPressed in
                guard let token = self?.externalMicrophoneGate.token() else { return }
                guard let gamepad else { return }
                let motionInput = Self.motionJumpSnapshot(gamepad: gamepad)
                DispatchQueue.main.async {
                    guard let self,
                          self.externalMicrophoneGate.permits(token),
                          self.inputSourceGeneration == generation,
                          let activeController = self.controller,
                          ObjectIdentifier(activeController) == endpointID else { return }
                    self.handleHomeButton(isPressed: isPressed, motionInput: motionInput)
                }
            }
        }
        if #available(macOS 14.0, *) {
            selected.physicalInputProfile.valueDidChangeHandler = { [weak self, weak gamepad] profile, element in
                guard let token = self?.externalMicrophoneGate.token() else { return }
                guard let gamepad else { return }
                let homePressed: Bool? = if element.aliases.contains(GCInputButtonHome) {
                    (element as? GCControllerButtonInput)?.isPressed
                } else {
                    nil
                }
                let motionInput = Self.motionJumpSnapshot(gamepad: gamepad)
                DispatchQueue.main.async {
                    guard let self,
                          self.externalMicrophoneGate.permits(token),
                          self.inputSourceGeneration == generation,
                          let activeController = self.controller,
                          ObjectIdentifier(activeController) == endpointID else { return }
                    if let homePressed {
                        self.handleHomeButton(isPressed: homePressed, motionInput: motionInput)
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

        resetInputState()
        detachObservedHandlers()
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
                self?.joyConInputRefreshScheduler.schedule(generation: generation) { [weak self] in
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
        interruptDualSensePSInput()
        rawPSInputIsAuthoritative = false
        motionJumpSuppressesInputUntilNeutral = false
        psChordMotionStartedAt = nil
        psChordMotionBlockThrough = -.infinity
        gcTriggerHeldForPSChord = false
        psChordRawInterrupted = false
        inputSourceGeneration &+= 1
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller?.extendedGamepad?.buttonHome?.pressedChangedHandler = nil
        controller?.extendedGamepad?.buttonHome?.preferredSystemGestureState = .enabled
        if #available(macOS 14.0, *) {
            controller?.physicalInputProfile.valueDidChangeHandler = nil
        }
        for observed in observedControllers {
            observed.extendedGamepad?.valueChangedHandler = nil
            observed.microGamepad?.valueChangedHandler = nil
            observed.physicalInputProfile.valueDidChangeHandler = nil
        }
        homeButtonMerger.reset()
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
                samples.append(projectJoyConSticks(
                    projectJoyConShoulders(sample, side: .left, mode: mode), side: .left, mode: mode
                ))
            }
            if let rightID = joyConComposition.rightID,
               let right = joyConControllersByID[rightID] {
                let sample = JoyConProfileReader.sample(
                    controller: right,
                    kind: .right,
                    paired: mode == .pair,
                    orientation: joyConOrientationProvider?() ?? .horizontal
                )
                samples.append(projectJoyConSticks(
                    projectJoyConShoulders(sample, side: .right, mode: mode), side: .right, mode: mode
                ))
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

    private func projectJoyConSticks(
        _ sample: JoyConProfileSample,
        side: JoyConSide,
        mode: JoyConMode
    ) -> JoyConProfileSample {
        let matchingEndpointCount = joyConControllersByID.values.filter {
            $0.joyConHardwareKind == (side == .left ? .left : .right)
        }.count
        return JoyConHIDStickAdapter.apply(
            matchingEndpointCount == 1 ? joyConHIDStickSnapshots[side] : nil,
            to: sample,
            side: side,
            paired: mode == .pair,
            orientation: joyConOrientationProvider?() ?? .horizontal
        )
    }

    func updateJoyConHIDStick(side: JoyConSide, snapshot: JoyConHIDStickSnapshot?) {
        joyConHIDStickSnapshots[side] = snapshot
        guard joyConComposition.combinedID == nil else { return }
        let sideIsActive = side == .left
            ? joyConComposition.leftID != nil : joyConComposition.rightID != nil
        guard sideIsActive else { return }
        let generation = joyConComposition.generation
        joyConInputRefreshScheduler.schedule(generation: generation) { [weak self] in
            self?.handleJoyConProfiles(generation: generation)
        }
    }

    func refreshJoyConOrientation() {
        resetInputState()
        guard let mode = joyConComposition.mode, mode != .pair else { return }
        handleJoyConProfiles(generation: joyConComposition.generation)
    }

    func applyJoyConSnapshot(_ next: JoyConInputSnapshot) {
        let previous = joyConInputSnapshot
        let allInputs = Set(previous.buttons.keys).union(next.buttons.keys)
        // A Harness change can remap a held modifier before it is released.
        // Clear suppression from physical releases, independent of that mapping.
        suppressedJoyConModifiers = suppressedJoyConModifiers.filter { next.buttons[$0] == true }
        let sticks = voiceFilteredSticks(
            leftX: next.primaryStick.x, leftY: next.primaryStick.y,
            rightX: next.secondaryStick.x, rightY: next.secondaryStick.y,
            timestamp: homeButtonClock()
        )
        let overlayConsumesStick = overlayStickHandler?(
            sticks.leftX,
            sticks.leftY
        ) == true

        if operationMode == .native {
            for input in allInputs {
                let wasPressed = previous.buttons[input] == true
                let isPressed = next.buttons[input] == true
                guard wasPressed != isPressed else { continue }
                if input == .home {
                    handleHomeButton(isPressed: isPressed)
                    continue
                }
                let changed = publishInput(input, pressed: isPressed)
                let consumed = changed && inputInterceptor?(input, isPressed) == true
                guard !consumed else { continue }
                guard !wasPressed && isPressed else { continue }
                if mappingProvider(input) == .toggleOperationMode {
                    toggleOperationMode()
                    break
                }
            }
            joyConInputSnapshot = next
            return
        }

        var modifierActive = false
        for input in allInputs where mappingProvider(input) == .functionModifier {
            let isPressed = next.buttons[input] == true
            if (previous.buttons[input] == true) != isPressed {
                let changed = publishInput(input, pressed: isPressed)
                let consumed = changed && inputInterceptor?(input, isPressed) == true
                if isPressed && consumed { suppressedJoyConModifiers.insert(input) }
            }
            if !isPressed {
                suppressedJoyConModifiers.remove(input)
                joyConActiveInputs.removeValue(forKey: input)
            } else if overlayConsumesStick {
                suppressedJoyConModifiers.insert(input)
            } else if !suppressedJoyConModifiers.contains(input) {
                modifierActive = true
            }
        }
        functionPressed = modifierActive

        for input in allInputs {
            let wasPressed = previous.buttons[input] == true
            let isPressed = next.buttons[input] == true
            guard wasPressed != isPressed else { continue }

            if input == .home {
                handleHomeButton(isPressed: isPressed)
            } else if mappingProvider(input) != .functionModifier {
                handleJoyConButton(input, isPressed: isPressed)
            }
        }

        if !overlayConsumesStick {
            leftStickHandler?(sticks.leftX, sticks.leftY, functionLeftStickScrolls)
        }
        publishRightStickScroll(x: sticks.rightX, y: sticks.rightY)
        updateJoyConJoystick(next)
        updateFunctionRightStick(x: sticks.rightX, y: sticks.rightY)
        joyConInputSnapshot = next
    }

    private func handleJoyConButton(_ input: ControllerInput, isPressed: Bool) {
        let changed = publishInput(input, pressed: isPressed)
        let consumed = changed && inputInterceptor?(input, isPressed) == true
        if !isPressed {
            if let activeInput = joyConActiveInputs.removeValue(forKey: input) {
                handleMappedDirection(
                    activeInput,
                    isPressed: false,
                    allowsInterception: false
                )
            }
            return
        }
        guard !consumed else { return }
        let effectiveInput = functionPressed ? functionInput(for: input) ?? input : input
        joyConActiveInputs[input] = effectiveInput
        handleMappedDirection(
            effectiveInput,
            isPressed: true,
            allowsInterception: false
        )
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
        let x = functionPressed ? 0 : dpadX
        let y = functionPressed ? 0 : dpadY
        publishJoystick(x: x, y: y)
    }

    private func publishRightStickScroll(x: Float, y: Float) {
        rightStickHandler?(functionPressed ? 0 : x, functionPressed ? 0 : y)
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

    private func handle(
        gamepad: GCExtendedGamepad,
        changedElement: GCControllerElement,
        event: StandardGamepadEventSnapshot
    ) {
        if usesExternalVoiceControls {
            if changedElement === gamepad.buttonMenu || changedElement === gamepad.buttonHome { return }
        }
        if let homeButton = gamepad.buttonHome, changedElement === homeButton {
            handleHomeButton(
                isPressed: event.changedButtonPressed ?? homeButton.isPressed,
                motionInput: event.motionJumpInput
            )
            return
        }
        let sticks = voiceFilteredSticks(
            leftX: event.leftStickX, leftY: event.leftStickY,
            rightX: event.rightStickX, rightY: event.rightStickY,
            timestamp: event.motionJumpInput.timestamp
        )
        if routeMotionJumpInput(event.motionJumpInput) { return }
        if Self.isLeftStickElement(changedElement, in: gamepad),
           overlayStickHandler?(
               sticks.leftX,
               sticks.leftY
           ) == true {
            return
        }
        if operationMode == .native {
            var changedElementWasConsumed = false
            if let input = inputForElement(changedElement, in: gamepad),
               let button = changedElement as? GCControllerButtonInput {
                let isPressed = event.changedButtonPressed ?? button.isPressed
                let changed = publishInput(input, pressed: isPressed)
                if changed {
                    changedElementWasConsumed = inputInterceptor?(input, isPressed) == true
                }
            }
            for (input, button) in [
                (ControllerInput.dpadUp, gamepad.dpad.up), (.dpadDown, gamepad.dpad.down),
                (.dpadLeft, gamepad.dpad.left), (.dpadRight, gamepad.dpad.right),
            ] {
                let isPressed = event.dpadPressed(for: input)
                let changed = publishInput(input, pressed: isPressed)
                if changed {
                    let consumed = inputInterceptor?(input, isPressed) == true
                    if changedElement === button { changedElementWasConsumed = consumed }
                }
            }
            if let buttonInput = changedElement as? GCControllerButtonInput,
               event.changedButtonPressed ?? buttonInput.isPressed,
               !changedElementWasConsumed {
                if let input = inputForElement(changedElement, in: gamepad),
                   mappingProvider(input) == .toggleOperationMode {
                    toggleOperationMode()
                    return
                }
            }
            return
        }

        if let x = event.touchpadX, let y = event.touchpadY {
            sampleTouchpadPointer(
                x: x, y: y, secondaryTouching: event.secondaryTouching,
                timestamp: event.motionJumpInput.timestamp
            )
        }

        if changedElement === gamepad.leftTrigger {
            if mappingProvider(.leftTrigger) == .functionModifier {
                var nextFunctionPressed = (event.changedButtonValue ?? gamepad.leftTrigger.value) >= 0.55
                let id = ObjectIdentifier(gamepad.leftTrigger)
                if nextFunctionPressed {
                    if overlaySuppressedButtons.contains(id) {
                        nextFunctionPressed = false
                    } else {
                        controllerInputsByButton[id] = .leftTrigger
                        let changed = publishInput(.leftTrigger, pressed: true)
                        if changed, inputInterceptor?(.leftTrigger, true) == true {
                            overlaySuppressedButtons.insert(id)
                            nextFunctionPressed = false
                        }
                    }
                } else {
                    release(gamepad.leftTrigger)
                }
                functionPressed = nextFunctionPressed
            } else {
                functionPressed = false
                handleMappedButton(gamepad.leftTrigger, input: .leftTrigger)
            }
        }
        leftStickHandler?(
            sticks.leftX,
            sticks.leftY,
            functionLeftStickScrolls
        )
        publishRightStickScroll(
            x: sticks.rightX,
            y: sticks.rightY
        )
        updateJoystick(gamepad)
        updateDPadButtons(
            gamepad,
            event: event
        )
        updateFunctionRightStick(x: sticks.rightX, y: sticks.rightY)
        if changedElement === gamepad.leftTrigger { return }

        let faceButtons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.buttonA, .buttonA, .functionButtonA),
            (gamepad.buttonB, .buttonB, .functionButtonB),
            (gamepad.buttonX, .buttonX, .functionButtonX),
            (gamepad.buttonY, .buttonY, .functionButtonY),
        ]
        for (button, primaryInput, functionInput) in faceButtons where changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? functionInput : primaryInput,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
            return
        }

        let shoulderButtons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.leftShoulder, .leftShoulder, .functionLeftShoulder),
            (gamepad.rightShoulder, .rightShoulder, .functionRightShoulder),
        ]
        for (button, primaryInput, functionInput) in shoulderButtons where changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? functionInput : primaryInput,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
            return
        }

        if changedElement === gamepad.buttonMenu {
            handleMappedButton(
                gamepad.buttonMenu,
                input: .menu,
                isPressed: event.changedButtonPressed ?? gamepad.buttonMenu.isPressed
            )
        } else if let button = gamepad.buttonOptions, changedElement === button {
            handleMappedButton(
                button,
                input: .options,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
        } else if changedElement === gamepad.rightTrigger {
            let value = event.changedButtonValue ?? gamepad.rightTrigger.value
            rightTriggerFeedbackHandler?(value)
            let input: ControllerInput = functionPressed ? .functionRightTrigger : .rightTrigger
            if controllerFamily == .dualSense,
               let isPressed = rightTriggerPressState.update(value: value) {
                handleMappedButton(
                    gamepad.rightTrigger,
                    input: input,
                    isPressed: isPressed
                )
            } else if controllerFamily != .dualSense {
                handleMappedButton(
                    gamepad.rightTrigger,
                    input: input,
                    isPressed: event.changedButtonPressed ?? gamepad.rightTrigger.isPressed
                )
            }
        } else if let button = gamepad.leftThumbstickButton, changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? .functionLeftThumbstickButton : .leftThumbstickButton,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
        } else if let button = gamepad.rightThumbstickButton, changedElement === button {
            handleMappedButton(
                button,
                input: functionPressed ? .functionRightThumbstickButton : .rightThumbstickButton,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
        } else if let button = Self.touchpadButton(for: gamepad), changedElement === button {
            handleMappedButton(
                button,
                input: .touchpadButton,
                isPressed: event.changedButtonPressed ?? button.isPressed
            )
        }
    }

    private static func touchpadButton(for gamepad: GCExtendedGamepad) -> GCControllerButtonInput? {
        if let dualSense = gamepad as? GCDualSenseGamepad { return dualSense.touchpadButton }
        if let dualShock = gamepad as? GCDualShockGamepad { return dualShock.touchpadButton }
        return nil
    }

    private static func isLeftStickElement(
        _ element: GCControllerElement,
        in gamepad: GCExtendedGamepad
    ) -> Bool {
        element === gamepad.leftThumbstick ||
            element === gamepad.leftThumbstick.xAxis ||
            element === gamepad.leftThumbstick.yAxis
    }

    fileprivate static func touchpadPrimary(for gamepad: GCExtendedGamepad) -> GCControllerDirectionPad? {
        if let dualSense = gamepad as? GCDualSenseGamepad { return dualSense.touchpadPrimary }
        if let dualShock = gamepad as? GCDualShockGamepad { return dualShock.touchpadPrimary }
        return nil
    }

    fileprivate static func secondaryTouchpadIsActive(for gamepad: GCExtendedGamepad) -> Bool {
        let secondary: GCControllerDirectionPad?
        if let dualSense = gamepad as? GCDualSenseGamepad { secondary = dualSense.touchpadSecondary }
        else if let dualShock = gamepad as? GCDualShockGamepad { secondary = dualShock.touchpadSecondary }
        else { secondary = nil }
        guard let secondary else { return false }
        return abs(secondary.xAxis.value) > TouchpadPointerTracker.liftEpsilon ||
            abs(secondary.yAxis.value) > TouchpadPointerTracker.liftEpsilon
    }

    static func motionJumpSnapshot(gamepad: GCExtendedGamepad) -> MotionJumpInputSnapshot {
        // allButtons also exposes synthesized stick-direction buttons. Their
        // isPressed threshold is not the pointer's radial dead zone.
        let analogDirections = [gamepad.leftThumbstick, gamepad.rightThumbstick].flatMap {
            [$0.up, $0.down, $0.left, $0.right]
        }
        let otherButtonPressed = gamepad.allButtons.contains {
            let button = $0
            return button !== gamepad.leftTrigger && button.isPressed &&
                !analogDirections.contains(where: { $0 === button })
        }
        // Use the same radial dead zones as pointer/scroll output. Checking
        // each axis separately would miss a diagonal push outside the circle.
        let leftStickActive = hypot(
            gamepad.leftThumbstick.xAxis.value,
            gamepad.leftThumbstick.yAxis.value
        ) > 0.10
        let rightStickActive = hypot(
            gamepad.rightThumbstick.xAxis.value,
            gamepad.rightThumbstick.yAxis.value
        ) > 0.15
        let touchpads: [GCControllerDirectionPad]
        if let dualSense = gamepad as? GCDualSenseGamepad {
            touchpads = [dualSense.touchpadPrimary, dualSense.touchpadSecondary]
        } else if let dualShock = gamepad as? GCDualShockGamepad {
            touchpads = [dualShock.touchpadPrimary, dualShock.touchpadSecondary]
        } else {
            touchpads = []
        }
        let touching = touchpads.contains {
            abs($0.xAxis.value) > TouchpadPointerTracker.liftEpsilon ||
                abs($0.yAxis.value) > TouchpadPointerTracker.liftEpsilon
        }
        return MotionJumpInputSnapshot(
            triggerValue: gamepad.leftTrigger.value,
            hasConflictingInput: otherButtonPressed || leftStickActive || rightStickActive || touching,
            timestamp: ProcessInfo.processInfo.systemUptime,
            allowsGesture: true
        )
    }

    /// Calibration consumes the entire selected endpoint, before Home,
    /// touchpad and stick routing. On exit, held inputs must first return to
    /// neutral; they must not become a fresh mapped press in the next callback.
    private func routeMotionJumpInput(_ captured: MotionJumpInputSnapshot) -> Bool {
        var snapshot = captured
        if captured.triggerValue >= PSButtonGesture.triggerPressThreshold {
            gcTriggerHeldForPSChord = true
        } else if captured.triggerValue <= PSButtonGesture.triggerReleaseThreshold {
            gcTriggerHeldForPSChord = false
        }
        let blockedByPSChord = psChordMotionStartedAt != nil ||
            captured.timestamp <= psChordMotionBlockThrough
        snapshot.hasConflictingInput = snapshot.hasConflictingInput || homeButtonMerger.isPressed ||
            psGesture.isPressed || blockedByPSChord
        if let startedAt = psChordMotionStartedAt, captured.timestamp >= startedAt {
            if gcTriggerHeldForPSChord { psChordSawGCHeld = true }
            psChordSawGCNeutral = psChordSawGCHeld && !gcTriggerHeldForPSChord
            finishPSChordMotionBlockIfNeutral()
        }
        snapshot.allowsGesture = operationMode == .mapping &&
            mappingProvider(.leftTrigger) == .functionModifier &&
            overlaySuppressedButtons.isEmpty
        let consumed = motionJumpInputHandler?(snapshot) == true
        if consumed {
            if !motionJumpSuppressesInputUntilNeutral {
                suspendMotionJumpOutputs(cancellingMotionJump: false)
            }
            motionJumpSuppressesInputUntilNeutral = true
            if snapshot.triggerValue <= 0.1, !snapshot.hasConflictingInput {
                overlaySuppressedButtons.removeAll()
            }
            return true
        }
        guard motionJumpSuppressesInputUntilNeutral else { return false }
        if snapshot.triggerValue <= 0.1, !snapshot.hasConflictingInput {
            motionJumpSuppressesInputUntilNeutral = false
            overlaySuppressedButtons.removeAll()
        }
        // Also consume the final release. It belongs to the calibration, not
        // to an action that was never pressed in normal mapping mode.
        return true
    }

    func suspendMotionJumpInput() {
        suspendMotionJumpOutputs(cancellingMotionJump: true)
        motionJumpSuppressesInputUntilNeutral = true
    }

    private func suspendMotionJumpOutputs(cancellingMotionJump: Bool) {
        suspendMappedOutputs(cancellingMotionJump: cancellingMotionJump)
        rightTriggerPressState = AnalogButtonPressState(
            pressPoint: RightTriggerPressState.releasePoint,
            resetPoint: RightTriggerPressState.resetPoint
        )
        rightTriggerFeedbackHandler?(0)
        controllerInputsByButton.removeAll()
        for input in publishedInputs { onInputStateChange?(input, false) }
        publishedInputs.removeAll()
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

    func sampleTouchpadPointer(
        x: Float, y: Float,
        secondaryTouching: Bool = false,
        timestamp: TimeInterval
    ) {
        let touching = abs(x) > TouchpadPointerTracker.liftEpsilon ||
            abs(y) > TouchpadPointerTracker.liftEpsilon || secondaryTouching
        guard aiVoiceAnalogGate.permits(.touchpad, isNeutral: !touching, at: timestamp) else {
            touchpadTracker.reset()
            return
        }
        if let delta = touchpadTracker.update(x: x, y: y) {
            touchpadPointerHandler?(delta.x, delta.y)
        }
    }

    private func voiceFilteredSticks(
        leftX: Float, leftY: Float, rightX: Float, rightY: Float,
        timestamp: TimeInterval
    ) -> (leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        let permitsLeft = aiVoiceAnalogGate.permits(
            .leftStick, isNeutral: hypot(leftX, leftY) <= 0.10, at: timestamp
        )
        let permitsRight = aiVoiceAnalogGate.permits(
            .rightStick, isNeutral: hypot(rightX, rightY) <= 0.15, at: timestamp
        )
        return (
            permitsLeft ? leftX : 0, permitsLeft ? leftY : 0,
            permitsRight ? rightX : 0, permitsRight ? rightY : 0
        )
    }

    /// This gate is independent of Home routing: physical PS release must
    /// still reach the voice session while all mapped analog output is held.
    func setAIVoiceCaptureActive(_ capturing: Bool) {
        guard capturing != aiVoiceAnalogGate.isCapturing else { return }
        var neutralChannels: Set<AIVoiceAnalogNeutralGate.Channel> = []
        if !capturing, joyConComposition.mode == nil, let gamepad = controller?.extendedGamepad {
            if hypot(gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value) <= 0.10 {
                neutralChannels.insert(.leftStick)
            }
            if hypot(gamepad.rightThumbstick.xAxis.value, gamepad.rightThumbstick.yAxis.value) <= 0.15 {
                neutralChannels.insert(.rightStick)
            }
            let primary = Self.touchpadPrimary(for: gamepad)
            let primaryTouching = abs(primary?.xAxis.value ?? 0) > TouchpadPointerTracker.liftEpsilon ||
                abs(primary?.yAxis.value ?? 0) > TouchpadPointerTracker.liftEpsilon
            if !primaryTouching && !Self.secondaryTouchpadIsActive(for: gamepad) {
                neutralChannels.insert(.touchpad)
            }
        }
        aiVoiceAnalogGate.setCaptureActive(
            capturing, at: homeButtonClock(), neutralChannels: neutralChannels
        )
        suspendMappedOutputs()
    }

    func setExternalMicrophoneIsolation(_ isolated: Bool) {
        guard externalMicrophoneGate.isBlocked != isolated else { return }
        if isolated {
            externalMicrophoneGate.setBlocked(true)
            suspendMappedOutputs()
            interruptDualSensePSInput(allowLegacyFallback: false)
            motionJumpCancelHandler?()
        } else {
            // The owner has confirmed fresh raw neutral after hardware close.
            // GC releases during audio were intentionally discarded, so no
            // previous suppressed ID or highlighted key may survive recovery.
            resetInputState()
            externalMicrophoneGate.setBlocked(false)
        }
    }

    private func handleMappedButton(_ button: GCControllerButtonInput, input: ControllerInput) {
        handleMappedButton(button, input: input, isPressed: button.isPressed)
    }

    private var homeButtonMerger = HomeButtonPressMerger()
    private var psGesture = PSButtonGesture()
    private var rawPSInputIsAuthoritative = false
    private var legacyHomeSuppressedUntil: TimeInterval = 0
    private var psInputTimeout: DispatchWorkItem?
    private var psChordMotionStartedAt: TimeInterval?
    private var psChordSawRawNeutral = false
    private var psChordSawGCHeld = false
    private var psChordSawGCNeutral = false
    private var gcTriggerHeldForPSChord = false
    private var psChordRawInterrupted = false
    private var psChordMotionBlockThrough: TimeInterval = -.infinity

    var hasReliableAIVoiceInput: Bool {
        guard rawPSInputIsAuthoritative, !psGesture.isAwaitingNeutral,
              let last = psGesture.lastTimestamp else { return false }
        return homeButtonClock() - last < PSButtonGesture.maximumReportGap
    }

    /// Full, unfiltered reports are the only authority that may start voice.
    /// GameController Home may be delayed or synthesized by system gestures.
    func handleDualSensePSInput(_ sample: DualSensePSInputSample, externalAudio: Bool = false) {
        guard externalAudio || !externalMicrophoneGate.isBlocked else { return }
        if let last = psGesture.lastTimestamp, sample.timestamp <= last { return }
        if !rawPSInputIsAuthoritative { homeButtonMerger.reset() }
        rawPSInputIsAuthoritative = true
        psChordRawInterrupted = false
        // GameController is the sole authority for motion-jump L2 edges. Raw
        // HID reports may arrive out of order relative to its queued events.
        // PS only cancels a pending jump and queries calibration ownership.
        if sample.isPressed {
            motionJumpCancelHandler?()
            if sample.leftTriggerValue > PSButtonGesture.triggerReleaseThreshold,
               psChordMotionStartedAt == nil {
                psChordMotionStartedAt = sample.timestamp
                psChordSawRawNeutral = false
                psChordSawGCHeld = gcTriggerHeldForPSChord
                psChordSawGCNeutral = false
            }
        }
        if psChordMotionStartedAt != nil {
            psChordSawRawNeutral = !sample.isPressed &&
                sample.leftTriggerValue <= PSButtonGesture.triggerReleaseThreshold
            if psChordSawRawNeutral {
                psChordMotionBlockThrough = max(psChordMotionBlockThrough, sample.timestamp)
            }
            finishPSChordMotionBlockIfNeutral()
        }
        let consumedByMotion = motionJumpIsCapturing?() == true
        let pressEdge = sample.isPressed && !psGesture.isPressed && !psGesture.isAwaitingNeutral
        let releaseEdge = !sample.isPressed && psGesture.isPressed
        var priority = PSButtonGesture.Priority.normal
        if consumedByMotion { priority = .intercepted }
        if pressEdge {
            _ = publishInput(.home, pressed: true)
            if psGesture.acceptsNewPSPress {
                if consumedByMotion || inputInterceptor?(.home, true) == true {
                    priority = .intercepted
                } else if operationMode == .native {
                    priority = .nativeMode
                }
            }
        } else if releaseEdge {
            _ = publishInput(.home, pressed: false)
            _ = inputInterceptor?(.home, false)
        }
        if consumedByMotion { performPSGestureEffects(psGesture.cancel()) }
        let effects = psGesture.ingest(sample, voiceEnabled: aiVoiceEnabled, priority: priority)
        performPSGestureEffects(effects, releaseTimestamp: sample.timestamp)
        if psGesture.needsInputWatchdog { schedulePSInputTimeoutIfNeeded() }
        else {
            psInputTimeout?.cancel()
            psInputTimeout = nil
        }
    }

    func cancelAIVoiceInput() {
        performPSGestureEffects(psGesture.cancel())
    }

    /// Raw and GameController queues can arrive in either order. Keep the
    /// whole L2 cycle conflicted until both sources observed release; the
    /// timestamp fence also rejects older GC events still queued afterward.
    private func finishPSChordMotionBlockIfNeutral() {
        guard psChordSawRawNeutral, psChordSawGCNeutral else { return }
        psChordMotionStartedAt = nil
        psChordSawRawNeutral = false
        psChordSawGCHeld = false
        psChordSawGCNeutral = false
    }

    /// Synthetic releases from resets/disconnection cancel; they never submit.
    func interruptDualSensePSInput(allowLegacyFallback: Bool = true) {
        psInputTimeout?.cancel()
        psInputTimeout = nil
        if psChordMotionStartedAt != nil, !psChordRawInterrupted {
            // Raw HID can disappear while GameController remains connected.
            // Require a new GC release instead of waiting forever for raw
            // neutral. Repeated interruptions must not move this boundary.
            psChordRawInterrupted = true
            let interruptedAt = homeButtonClock()
            psChordMotionStartedAt = interruptedAt
            psChordMotionBlockThrough = max(psChordMotionBlockThrough, interruptedAt)
            psChordSawRawNeutral = true
            psChordSawGCNeutral = false
        }
        if rawPSInputIsAuthoritative {
            legacyHomeSuppressedUntil = homeButtonClock() + HomeButtonPressMerger.defaultEchoWindow
        }
        if allowLegacyFallback { rawPSInputIsAuthoritative = false }
        performPSGestureEffects(psGesture.interrupt())
        if publishedInputs.contains(.home) {
            _ = publishInput(.home, pressed: false)
            _ = inputInterceptor?(.home, false)
        }
    }

    private func schedulePSInputTimeoutIfNeeded() {
        guard psInputTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.psInputTimeout = nil
            guard self.psGesture.needsInputWatchdog, let last = self.psGesture.lastTimestamp else { return }
            if self.homeButtonClock() - last >= PSButtonGesture.maximumReportGap {
                self.interruptDualSensePSInput(allowLegacyFallback: false)
            } else {
                self.schedulePSInputTimeoutIfNeeded()
            }
        }
        psInputTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PSButtonGesture.maximumReportGap, execute: work)
    }

    private func performPSGestureEffects(
        _ effects: [PSButtonGesture.Effect], releaseTimestamp: TimeInterval? = nil
    ) {
        for effect in effects {
            switch effect {
            case .showSwitcher: onHarnessSwitcherPresent?()
            case .restoreMapping: toggleOperationMode()
            case .beginVoice: onAIVoiceBegin?()
            case .submitVoice:
                if let releaseTimestamp, let onAIVoiceRelease { onAIVoiceRelease(releaseTimestamp) }
                else { onAIVoiceEnd?() }
            case .cancelVoice: onAIVoiceCancel?()
            }
        }
    }

    func handleRawHomeButton(isPressed: Bool) {
        updateHomeButton(from: .rawHID, isPressed: isPressed)
    }

    func handleHomeButton(isPressed: Bool, motionInput: MotionJumpInputSnapshot? = nil) {
        updateHomeButton(from: .gameController, isPressed: isPressed, motionInput: motionInput)
    }

    private func updateHomeButton(
        from source: HomeButtonPressMerger.Source,
        isPressed sourceIsPressed: Bool,
        motionInput: MotionJumpInputSnapshot? = nil
    ) {
        guard !externalMicrophoneGate.isBlocked, !usesExternalVoiceControls else { return }
        guard !rawPSInputIsAuthoritative, homeButtonClock() >= legacyHomeSuppressedUntil else { return }
        let edge = homeButtonMerger.update(
            source,
            isPressed: sourceIsPressed,
            at: homeButtonClock()
        )
        var snapshot = motionInput ?? controller?.extendedGamepad.map(Self.motionJumpSnapshot)
            ?? MotionJumpInputSnapshot(
                triggerValue: 0,
                hasConflictingInput: false,
                timestamp: ProcessInfo.processInfo.systemUptime,
                allowsGesture: true
            )
        snapshot.hasConflictingInput = snapshot.hasConflictingInput || sourceIsPressed
        if routeMotionJumpInput(snapshot) { return }
        guard let isPressed = edge else { return }
        print("[agent-deck] Home \(isPressed ? "pressed" : "released") via \(source)")
        _ = publishInput(.home, pressed: isPressed)

        if isPressed {
            guard inputInterceptor?(.home, true) != true else { return }
            // Native mode pauses every mapping, so PS/Home is the way back to
            // mapping mode, as the Xiaomi remote's Home is.
            if operationMode == .native {
                toggleOperationMode()
                return
            }
            // L2 is a physical chord modifier even when its mapping changed.
            if controllerFamily == .dualSense,
               snapshot.triggerValue >= PSButtonGesture.triggerPressThreshold {
                return
            }
            // Untrusted GameController Home can open the switcher immediately,
            // but can never start voice or infer a microphone release.
            onHarnessSwitcherPresent?()
            return
        }
        _ = inputInterceptor?(.home, false)
    }

    private func handleImmediateMappedHomeButton(isPressed: Bool) {
        let fakeID = ObjectIdentifier(self)
        guard isPressed else {
            pressedButtons.remove(fakeID)
            if let action = activeControllerActions.removeValue(forKey: fakeID) {
                end(action)
            }
            return
        }
        guard let action = resolvedAction(for: .home) else { return }
        print("[agent-deck] immediate Home button -> action=\(action)")
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
            overlaySuppressedButtons.remove(id)
            release(button)
            return
        }
        guard !overlaySuppressedButtons.contains(id) else { return }
        if let previousInput = controllerInputsByButton[id], previousInput != input {
            let changed = publishInput(previousInput, pressed: false)
            if changed { _ = inputInterceptor?(previousInput, false) }
        }
        controllerInputsByButton[id] = input
        let changed = publishInput(input, pressed: true)
        if changed, inputInterceptor?(input, true) == true {
            overlaySuppressedButtons.insert(id)
            return
        }
        guard let action = resolvedAction(for: input) else {
            if mappingProvider(input) == .pushToTalk {
                // A routed press remains consumed until its physical release,
                // even if settings/availability change during the hold.
                overlaySuppressedButtons.insert(id)
            }
            return
        }
        print("[agent-deck] button press input=\(input.rawValue) action=\(action)")
        handleControllerAction(button, action: action, isPressed: true)
    }

    private func resolvedAction(for input: ControllerInput) -> ControllerAction? {
        let mapped = mappingProvider(input)
        if mapped == .pushToTalk, shouldSuppressPTTInput?(input) == true { return nil }
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
        case .mousePrecision:
            mousePrecisionPressed = false
            mousePrecisionHandler?(false)
        }
    }

    private func release(_ button: GCControllerButtonInput) {
        let id = ObjectIdentifier(button)
        overlaySuppressedButtons.remove(id)
        if let input = controllerInputsByButton.removeValue(forKey: id) {
            let changed = publishInput(input, pressed: false)
            if changed { _ = inputInterceptor?(input, false) }
        }
        pressedButtons.remove(id)
        if let action = activeControllerActions.removeValue(forKey: id) {
            end(action)
        }
    }

    @discardableResult
    private func publishInput(_ input: ControllerInput, pressed: Bool) -> Bool {
        guard pressed != publishedInputs.contains(input) else { return false }
        if pressed {
            publishedInputs.insert(input)
        } else {
            publishedInputs.remove(input)
        }
        onInputStateChange?(input, pressed)
        return true
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

    private func updateDPadButtons(
        _ gamepad: GCExtendedGamepad,
        event: StandardGamepadEventSnapshot
    ) {
        let buttons: [(GCControllerButtonInput, ControllerInput, ControllerInput)] = [
            (gamepad.dpad.up, .dpadUp, .functionDpadUp),
            (gamepad.dpad.left, .dpadLeft, .functionDpadLeft),
            (gamepad.dpad.down, .dpadDown, .functionDpadDown),
            (gamepad.dpad.right, .dpadRight, .functionDpadRight),
        ]
        for (button, primaryInput, functionInput) in buttons {
            handleMappedButton(
                button,
                input: functionPressed ? functionInput : primaryInput,
                isPressed: event.dpadPressed(for: primaryInput)
            )
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
        let x = functionPressed ? 0 : dpadX
        let y = functionPressed ? 0 : dpadY
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

    private func handleMappedDirection(
        _ input: ControllerInput,
        isPressed: Bool,
        allowsInterception: Bool = true
    ) {
        if !isPressed {
            if allowsInterception { _ = inputInterceptor?(input, false) }
            pressedDirectionInputs.remove(input)
            if let action = activeDirectionActions.removeValue(forKey: input) {
                end(action)
            }
            return
        }
        if allowsInterception, inputInterceptor?(input, true) == true { return }
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

    /// Ends mapped outputs without disturbing the active Home button. Buttons
    /// that are still physically down remain suppressed until their release.
    func suspendMappedOutputs(cancellingMotionJump: Bool = true) {
        if cancellingMotionJump { motionJumpCancelHandler?() }
        overlaySuppressedButtons.formUnion(controllerInputsByButton.keys)
        suppressedJoyConModifiers.formUnion(joyConInputSnapshot.buttons.compactMap { input, pressed in
            pressed && mappingProvider(input) == .functionModifier ? input : nil
        })
        for action in activeControllerActions.values { end(action) }
        for action in activeDirectionActions.values { end(action) }
        pressedButtons.removeAll()
        activeControllerActions.removeAll()
        pressedDirectionInputs.removeAll()
        activeDirectionActions.removeAll()
        activeActionCounts.removeAll()
        functionPressed = false
        activeFunctionRightStickDirection = nil
        mouseSpeedBoostPressed = false
        mousePrecisionPressed = false
        if let lastJoystick, lastJoystick.distance > 0 {
            _ = joystickHandler?(0, 0)
            self.lastJoystick = (0, 0)
        }
        leftStickHandler?(0, 0, false)
        rightStickHandler?(0, 0)
        touchpadTracker.reset()
    }

    func resetInputState(preservingHomeButtonState: Bool = false) {
        interruptDualSensePSInput(allowLegacyFallback: false)
        motionJumpCancelHandler?()
        overlaySuppressedButtons.removeAll()
        suppressedJoyConModifiers.removeAll()
        for action in activeControllerActions.values { end(action) }
        for action in activeDirectionActions.values { end(action) }
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
        if !preservingHomeButtonState {
            homeButtonMerger.reset()
        }
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
        rightStickHandler?(0, 0)
    }

    func setRemoteControllerActive(_ active: Bool) {
        isRemoteControllerActive = active
        if active {
            resetInputState()
            detachObservedHandlers()
            controller = nil
            controllerFamily = .xiaomiRemote
            onControllerChange?(nil, .xiaomiRemote)
            onControllerSetChange?([])
            onAvailableInputsChange?(ControllerInput.availableInputs(for: .xiaomiRemote))
            print("[agent-deck] controller switched to xiaomi-remote")
        } else {
            if controllerFamily == .xiaomiRemote {
                resetInputState()
                attachPreferredController()
            }
        }
    }

    func handleRemoteButton(_ input: ControllerInput, isPressed: Bool) {
        let changed = publishInput(input, pressed: isPressed)
        guard changed else { return }
        let consumed = inputInterceptor?(input, isPressed) == true
        if input == .home {
            if !isPressed {
                handleImmediateMappedHomeButton(isPressed: false)
                return
            }
            guard !consumed else { return }
            if operationMode == .native {
                toggleOperationMode()
            } else {
                handleImmediateMappedHomeButton(isPressed: true)
            }
            return
        }
        if consumed {
            if !isPressed {
                handleMappedDirection(
                    input,
                    isPressed: false,
                    allowsInterception: false
                )
            }
            return
        }
        if operationMode == .native {
            if isPressed, mappingProvider(input) == .toggleOperationMode {
                toggleOperationMode()
            }
            return
        }
        handleMappedDirection(
            input,
            isPressed: isPressed,
            allowsInterception: false
        )
    }
}
