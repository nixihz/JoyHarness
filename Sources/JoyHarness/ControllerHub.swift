import Foundation
import GameController

/// Coordinates independent input sessions for all currently connected
/// controllers.
///
/// `ButtonBridge` contains the detailed state machine for one endpoint. A
/// separate instance per endpoint keeps modifier state, touchpad tracking,
/// trigger hysteresis, and held actions isolated while the existing action
/// handlers remain shared by the application.
final class ControllerHub {
    typealias FamilyMappingProvider = (ControllerFamily, ControllerInput) -> ControllerMappedAction
    typealias FamilyTargetProvider = (ControllerFamily, ControllerInput) -> String?
    typealias FamilyShortcutProvider = (ControllerFamily, ControllerInput) -> RecordedKeyboardShortcut?

    private struct StickState: Equatable {
        var x: Float
        var y: Float
        var scrolling: Bool
    }

    private struct JoystickState: Equatable {
        var angle: Float
        var distance: Float
    }

    private let mappingProvider: FamilyMappingProvider
    private var sessions: [String: ButtonBridge] = [:]
    private var controllers: [String: GCController] = [:]
    private var families: [String: ControllerFamily] = [:]
    private var remoteSession: ButtonBridge?
    private var observerTokens: [NSObjectProtocol] = []
    private var selectedControllerID: String?
    private var isRefreshing = false
    private var suppressModeCallback = false
    private var keySources: [String: Set<String>] = [:]
    private var mouseButtonSources: [MouseButton: Set<String>] = [:]
    private var systemKeySources: [SystemKey: Set<String>] = [:]
    private var recordedShortcutSources: [RecordedKeyboardShortcut: Set<String>] = [:]
    private var inputSources: [ControllerInput: Set<String>] = [:]
    private var stickStates: [String: StickState] = [:]
    private var joystickStates: [String: JoystickState] = [:]
    private var speedBoostSources: Set<String> = []
    private var precisionSources: Set<String> = []
    private var lastPublishedStick: StickState?
    private var lastPublishedJoystick: JoystickState?

    private(set) var selectedSlot = 0
    private(set) var operationMode: ControllerOperationMode = .mapping
    private(set) var connectedDevices: [ConnectedControllerDescriptor] = []

    /// The process-scoped identifier of the device currently shown in the
    /// dashboard/settings profile. This is intentionally an ID rather than a
    /// family: two controllers of the same family can be connected at once.
    var selectedDeviceID: String? { selectedControllerID }

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
    var recordedShortcutHandler: ((RecordedKeyboardShortcut, Bool) -> Void)?
    var joyConOrientationProvider: (() -> JoyConOrientation)?
    var rightTriggerFeedbackHandler: ((ControllerFamily, Float) -> Void)?

    var openApplicationTargetProvider: FamilyTargetProvider?
    var recordedShortcutProvider: FamilyShortcutProvider?

    var onSlotSelected: ((Int) -> Void)?
    var onControllerChange: ((GCController?, ControllerFamily) -> Void)?
    var onControllerSetChange: (([GCController]) -> Void)?
    var onJoyConChange: ((JoyConControllerSnapshot?) -> Void)?
    var onAvailableInputsChange: ((Set<ControllerInput>) -> Void)?
    var onInputStateChange: ((ControllerInput, Bool) -> Void)?
    var onOperationModeChange: ((ControllerOperationMode) -> Void)?
    var onConnectedDevicesChange: (([ConnectedControllerDescriptor]) -> Void)?

    var batterySnapshot: ControllerBatterySnapshot? {
        selectedSession?.batterySnapshot
    }

    var joyConSticks: JoyConStickProjection {
        selectedSession?.joyConSticks ?? JoyConStickProjection(primary: .neutral, secondary: .neutral)
    }

    var joyConBatterySnapshots: [JoyConSide: ControllerBatterySnapshot] {
        selectedSession?.joyConBatterySnapshots ?? [:]
    }

    var isRunning: Bool { !observerTokens.isEmpty }

    private var hasAggregatedInputState: Bool {
        !keySources.isEmpty ||
            !mouseButtonSources.isEmpty ||
            !systemKeySources.isEmpty ||
            !recordedShortcutSources.isEmpty ||
            !inputSources.isEmpty ||
            !stickStates.isEmpty ||
            !joystickStates.isEmpty ||
            !speedBoostSources.isEmpty ||
            !precisionSources.isEmpty
    }

    init(
        mappingProvider: @escaping FamilyMappingProvider
    ) {
        self.mappingProvider = mappingProvider
    }

    func start() {
        guard observerTokens.isEmpty else {
            refreshControllers()
            return
        }

        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshControllers()
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidBecomeCurrent,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshControllers(preferCurrent: true)
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshControllers()
        })
        refreshControllers()
    }

    func stop() {
        guard !observerTokens.isEmpty || !sessions.isEmpty || remoteSession != nil ||
            joyConFallback != nil || hasAggregatedInputState else { return }
        if !observerTokens.isEmpty {
            GCController.stopWirelessControllerDiscovery()
        }
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        for session in sessions.values {
            session.stop()
        }
        for id in sessions.keys { releaseSourceState(id) }
        sessions.removeAll()
        controllers.removeAll()
        families.removeAll()
        remoteSession?.stop()
        releaseSourceState(Self.remoteID)
        remoteSession = nil
        joyConFallback?.stop()
        releaseSourceState(Self.joyConFallbackID)
        releaseSourceState(Self.hubSourceID)
        joyConFallback = nil
        joyConFallbackFamily = .generic
        selectedControllerID = nil
        selectedSlot = 0
        connectedDevices = []
        onControllerChange?(nil, .generic)
        onControllerSetChange?([])
        onAvailableInputsChange?(ControllerInput.availableInputs(for: .generic))
        publishConnectedDevices()
    }

    func rescanControllers() {
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refreshControllers()
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        guard mode != operationMode else { return }
        operationMode = mode
        suppressModeCallback = true
        for session in sessions.values { session.setOperationMode(mode) }
        remoteSession?.setOperationMode(mode)
        suppressModeCallback = false
        onOperationModeChange?(mode)
    }

    func moveSlot(_ offset: Int) {
        selectSlot((selectedSlot + offset + 6) % 6)
    }

    func selectSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
        for session in sessions.values { session.syncSelectedSlot(slot) }
        remoteSession?.syncSelectedSlot(slot)
        onSlotSelected?(slot)
        // A single tap is enough; ButtonBridge's double-tap helper is reserved
        // for opening a task explicitly.
        _ = sendMicroKey(String(format: "AG%02d", slot), action: 1)
        DispatchQueue.main.async { [weak self] in
            _ = self?.sendMicroKey(String(format: "AG%02d", slot), action: 0)
        }
    }

    func syncSelectedSlot(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
        for session in sessions.values { session.syncSelectedSlot(slot) }
        remoteSession?.syncSelectedSlot(slot)
    }

    func openSelectedSlot() {
        if let selectedSession {
            selectedSession.openSelectedSlot()
        } else if let session = sessions.values.first {
            session.openSelectedSlot()
        } else {
            remoteSession?.openSelectedSlot()
        }
    }

    func handleRawHomeButton(isPressed: Bool) {
        selectedSession?.handleRawHomeButton(isPressed: isPressed)
    }

    func updateJoyConHIDShoulders(side: JoyConSide, snapshot: JoyConHIDShoulderSnapshot?) {
        selectedSession?.updateJoyConHIDShoulders(side: side, snapshot: snapshot)
    }

    func refreshJoyConOrientation() {
        selectedSession?.refreshJoyConOrientation()
    }

    func setRemoteControllerActive(_ active: Bool) {
        if active {
            guard remoteSession == nil else { return }
            let remote = makeSession(id: Self.remoteID, family: .xiaomiRemote)
            remoteSession = remote
            remote.setRemoteControllerActive(true)
            remote.setOperationMode(operationMode)
        } else {
            remoteSession?.stop()
            releaseSourceState(Self.remoteID)
            remoteSession = nil
        }
        refreshConnectedDeviceList()
        emitSelectedControllerIfNeeded()
    }

    func handleRemoteButton(_ input: ControllerInput, isPressed: Bool) {
        remoteSession?.handleRemoteButton(input, isPressed: isPressed)
    }

    /// Selects which connected device supplies the dashboard/settings profile.
    /// This does not disable any session or interrupt another device's input.
    func selectController(id: String) {
        guard controllers[id] != nil || id == Self.remoteID || id == Self.joyConFallbackID,
              connectedDevices.contains(where: { $0.id == id }) else { return }
        guard selectedControllerID != id else { return }
        selectedControllerID = id
        emitSelectedControllerIfNeeded(force: true)
    }

    private var selectedSession: ButtonBridge? {
        if let selectedControllerID, let session = sessions[selectedControllerID] {
            return session
        }
        if selectedControllerID == Self.remoteID {
            return remoteSession
        }
        if selectedControllerID == Self.joyConFallbackID {
            return joyConFallback
        }
        return sessions.values.first ?? remoteSession
    }

    private func refreshControllers(preferCurrent: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let all = GCController.controllers()
        let joyCons = all.filter { $0.joyConHardwareKind != nil }
        if !joyCons.isEmpty {
            // Preserve the battle-tested Joy-Con composition path. Standard
            // controllers remain available again as soon as the Joy-Con
            // composition disappears.
            switchToJoyConFallback()
            refreshConnectedDeviceList()
            // Refreshing the list may replace a disconnected standard
            // controller selection with the Joy-Con composition ID. Emit only
            // after that selection is settled, otherwise the old ID can cause
            // a transient generic profile to overwrite the Joy-Con profile.
            emitSelectedControllerIfNeeded()
            return
        }

        stopJoyConFallbackIfNeeded()
        let standard = all.filter {
            $0.joyConHardwareKind == nil && $0.extendedGamepad != nil
        }
        let liveIDs = Set(standard.map(Self.controllerID))

        // Collect stale IDs first. Mutating a dictionary while iterating its
        // key view can trap at runtime when a controller disconnects.
        let staleIDs = controllers.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            sessions[id]?.stop()
            releaseSourceState(id)
            sessions.removeValue(forKey: id)
            controllers.removeValue(forKey: id)
            families.removeValue(forKey: id)
        }

        for controller in standard {
            let id = Self.controllerID(controller)
            if sessions[id] == nil {
                let family = ControllerFamily.detect(controller: controller)
                let session = makeSession(id: id, family: family)
                sessions[id] = session
                controllers[id] = controller
                families[id] = family
                session.attachController(controller)
                session.setOperationMode(operationMode)
                session.syncSelectedSlot(selectedSlot)
            }
        }

        // A manual picker selection is sticky. The GameController "current"
        // notification fires as soon as another pad is used, so following it
        // here would unexpectedly change the profile shown in Settings.
        if preferCurrent, selectedControllerID == nil, let current = GCController.current {
            let id = Self.controllerID(current)
            if sessions[id] != nil { selectedControllerID = id }
        }
        if selectedControllerID == nil || !hasLiveSession(for: selectedControllerID) {
            selectedControllerID = standard
                .first(where: { $0 === GCController.current })
                .map(Self.controllerID)
                ?? standard.first.map(Self.controllerID)
        }

        onControllerSetChange?(Array(controllers.values))
        refreshConnectedDeviceList()
        emitSelectedControllerIfNeeded()
    }

    private func switchToJoyConFallback() {
        if !sessions.isEmpty {
            onControllerSetChange?([])
            for session in sessions.values { session.stop() }
            for id in sessions.keys { releaseSourceState(id) }
            sessions.removeAll()
            controllers.removeAll()
            families.removeAll()
        }
        guard joyConFallback == nil else { return }
        let fallback = ButtonBridge(mappingProvider: { [weak self] input in
            let family = self?.joyConFallbackFamily ?? .generic
            return self?.mappingProvider(family, input) ?? .disabled
        })
        bind(
            fallback,
            id: Self.joyConFallbackID,
            family: .joyConPair,
            familyProvider: { [weak self] in self?.joyConFallbackFamily ?? .joyConPair }
        )
        joyConFallback = fallback
        fallback.start()
    }

    private func stopJoyConFallbackIfNeeded() {
        guard let fallback = joyConFallback else { return }
        fallback.stop()
        releaseSourceState(Self.joyConFallbackID)
        joyConFallback = nil
        joyConFallbackFamily = .generic
    }

    private var joyConFallback: ButtonBridge?
    private var joyConFallbackFamily: ControllerFamily = .generic

    private func makeSession(id: String, family: ControllerFamily) -> ButtonBridge {
        let session = ButtonBridge(mappingProvider: { [weak self] input in
            self?.mappingProvider(family, input) ?? .disabled
        })
        bind(session, id: id, family: family)
        return session
    }

    private func bind(
        _ session: ButtonBridge,
        id: String,
        family: ControllerFamily,
        familyProvider: (() -> ControllerFamily)? = nil
    ) {
        let currentFamily = { familyProvider?() ?? family }
        session.keyHandler = { [weak self] key, action in
            self?.handleKey(source: id, key: key, action: action) ?? false
        }
        session.joystickHandler = { [weak self] angle, distance in
            self?.handleJoystick(source: id, angle: angle, distance: distance) ?? false
        }
        session.leftStickHandler = { [weak self] x, y, scrolling in
            self?.handleStick(source: id, x: x, y: y, scrolling: scrolling)
        }
        session.touchpadPointerHandler = { [weak self] x, y in self?.touchpadPointerHandler?(x, y) }
        session.mouseButtonHandler = { [weak self] button, pressed in
            self?.handleMouseButton(source: id, button: button, pressed: pressed)
        }
        session.systemKeyHandler = { [weak self] key, pressed in
            self?.handleSystemKey(source: id, key: key, pressed: pressed)
        }
        session.textInputHandler = { [weak self] text in self?.textInputHandler?(text) ?? false }
        session.mouseSpeedBoostHandler = { [weak self] active in
            self?.handleSpeedBoost(source: id, active: active)
        }
        session.mousePrecisionHandler = { [weak self] active in
            self?.handlePrecision(source: id, active: active)
        }
        session.openApplicationHandler = { [weak self] bundleID in self?.openApplicationHandler?(bundleID) ?? false }
        session.recordedShortcutHandler = { [weak self] shortcut, pressed in
            self?.handleRecordedShortcut(source: id, shortcut: shortcut, pressed: pressed)
        }
        session.joyConOrientationProvider = { [weak self] in self?.joyConOrientationProvider?() ?? .horizontal }
        session.openApplicationTargetProvider = { [weak self] input in
            self?.openApplicationTargetProvider?(currentFamily(), input)
        }
        session.recordedShortcutProvider = { [weak self] input in
            self?.recordedShortcutProvider?(currentFamily(), input)
        }
        session.rightTriggerFeedbackHandler = { [weak self] value in
            self?.rightTriggerFeedbackHandler?(currentFamily(), value)
        }
        session.onInputStateChange = { [weak self] input, pressed in
            self?.handleInputState(source: id, input: input, pressed: pressed)
        }
        session.onAvailableInputsChange = { [weak self] inputs in
            guard let self, self.selectedControllerID == id || id == Self.joyConFallbackID else { return }
            self.onAvailableInputsChange?(inputs)
        }
        session.onControllerSetChange = { [weak self] controllers in
            guard id == Self.joyConFallbackID else { return }
            self?.onControllerSetChange?(controllers)
        }
        session.onSlotSelected = { [weak self] slot in
            self?.handleSlotSelected(slot)
        }
        session.onOperationModeChange = { [weak self] mode in
            self?.handleSessionModeChange(mode)
        }
        session.onControllerChange = { [weak self] controller, nextFamily in
            guard let self, id == Self.joyConFallbackID else { return }
            self.joyConFallbackFamily = nextFamily
            self.emitSelectedControllerIfNeeded(force: true, controller: controller, family: nextFamily)
        }
        session.onJoyConChange = { [weak self] snapshot in
            self?.onJoyConChange?(snapshot)
        }
    }

    private func handleKey(source: String, key: String, action: Int) -> Bool {
        guard action == 0 || action == 1 else {
            return keyHandler?(key, action) ?? false
        }

        var sources = keySources[key] ?? []
        if action == 1 {
            guard !sources.contains(source) else { return true }
            if sources.isEmpty, keyHandler?(key, 1) != true { return false }
            sources.insert(source)
            keySources[key] = sources
            return true
        }

        guard sources.remove(source) != nil else { return true }
        if sources.isEmpty {
            keySources.removeValue(forKey: key)
            _ = keyHandler?(key, 0)
        } else {
            keySources[key] = sources
        }
        return true
    }

    private func handleMouseButton(source: String, button: MouseButton, pressed: Bool) {
        var sources = mouseButtonSources[button] ?? []
        if pressed {
            guard sources.insert(source).inserted else { return }
            mouseButtonSources[button] = sources
            if sources.count == 1 { mouseButtonHandler?(button, true) }
            return
        }

        guard sources.remove(source) != nil else { return }
        if sources.isEmpty {
            mouseButtonSources.removeValue(forKey: button)
            mouseButtonHandler?(button, false)
        } else {
            mouseButtonSources[button] = sources
        }
    }

    private func handleSystemKey(source: String, key: SystemKey, pressed: Bool) {
        var sources = systemKeySources[key] ?? []
        if pressed {
            guard sources.insert(source).inserted else { return }
            systemKeySources[key] = sources
            if sources.count == 1 { systemKeyHandler?(key, true) }
            return
        }

        guard sources.remove(source) != nil else { return }
        if sources.isEmpty {
            systemKeySources.removeValue(forKey: key)
            systemKeyHandler?(key, false)
        } else {
            systemKeySources[key] = sources
        }
    }

    private func handleRecordedShortcut(
        source: String,
        shortcut: RecordedKeyboardShortcut,
        pressed: Bool
    ) {
        var sources = recordedShortcutSources[shortcut] ?? []
        if pressed {
            guard sources.insert(source).inserted else { return }
            recordedShortcutSources[shortcut] = sources
            if sources.count == 1 { recordedShortcutHandler?(shortcut, true) }
            return
        }

        guard sources.remove(source) != nil else { return }
        if sources.isEmpty {
            recordedShortcutSources.removeValue(forKey: shortcut)
            recordedShortcutHandler?(shortcut, false)
        } else {
            recordedShortcutSources[shortcut] = sources
        }
    }

    private func handleSpeedBoost(source: String, active: Bool) {
        if active {
            guard speedBoostSources.insert(source).inserted else { return }
            if speedBoostSources.count == 1 { mouseSpeedBoostHandler?(true) }
        } else {
            guard speedBoostSources.remove(source) != nil else { return }
            if speedBoostSources.isEmpty { mouseSpeedBoostHandler?(false) }
        }
    }

    private func handlePrecision(source: String, active: Bool) {
        if active {
            guard precisionSources.insert(source).inserted else { return }
            if precisionSources.count == 1 { mousePrecisionHandler?(true) }
        } else {
            guard precisionSources.remove(source) != nil else { return }
            if precisionSources.isEmpty { mousePrecisionHandler?(false) }
        }
    }

    private func handleInputState(source: String, input: ControllerInput, pressed: Bool) {
        var sources = inputSources[input] ?? []
        if pressed {
            guard sources.insert(source).inserted else { return }
            inputSources[input] = sources
            if sources.count == 1 { onInputStateChange?(input, true) }
            return
        }

        guard sources.remove(source) != nil else { return }
        if sources.isEmpty {
            inputSources.removeValue(forKey: input)
            onInputStateChange?(input, false)
        } else {
            inputSources[input] = sources
        }
    }

    private func handleStick(source: String, x: Float, y: Float, scrolling: Bool) {
        stickStates[source] = StickState(x: x, y: y, scrolling: scrolling)
        publishAggregatedStick()
    }

    private func publishAggregatedStick() {
        let next = stickStates.values.reduce(
            into: StickState(x: 0, y: 0, scrolling: false)
        ) { result, state in
            result.x += state.x
            result.y += state.y
            result.scrolling = result.scrolling || state.scrolling
        }
        let bounded = StickState(
            x: min(max(next.x, -1), 1),
            y: min(max(next.y, -1), 1),
            scrolling: next.scrolling
        )
        guard bounded != lastPublishedStick else { return }
        lastPublishedStick = bounded
        leftStickHandler?(bounded.x, bounded.y, bounded.scrolling)
    }

    private func handleJoystick(source: String, angle: Float, distance: Float) -> Bool {
        joystickStates[source] = JoystickState(angle: angle, distance: distance)
        return publishAggregatedJoystick()
    }

    @discardableResult
    private func publishAggregatedJoystick() -> Bool {
        var x: Double = 0
        var y: Double = 0
        for state in joystickStates.values where state.distance > 0 {
            let radians = Double(state.angle) * 2 * Double.pi
            x += cos(radians) * Double(state.distance)
            y -= sin(radians) * Double(state.distance)
        }
        let distance = min(Float(hypot(x, y)), 1)
        let next = if distance < 0.08 {
            JoystickState(angle: 0, distance: 0)
        } else {
            JoystickState(
                angle: ButtonBridge.radialAngle(x: Float(x), y: Float(y)),
                distance: distance
            )
        }
        guard next != lastPublishedJoystick else { return true }
        lastPublishedJoystick = next
        return joystickHandler?(next.angle, next.distance) ?? false
    }

    /// Releases any held output owned by a session that is being removed.
    /// ButtonBridge normally emits these releases itself, but keeping this
    /// cleanup at the hub boundary also covers abrupt controller removal.
    private func releaseSourceState(_ source: String) {
        let keys = keySources.keys.filter { keySources[$0]?.contains(source) == true }
        for key in keys {
            guard var sources = keySources[key], sources.remove(source) != nil else { continue }
            if sources.isEmpty {
                keySources.removeValue(forKey: key)
                _ = keyHandler?(key, 0)
            } else {
                keySources[key] = sources
            }
        }

        let mouseButtons = mouseButtonSources.keys.filter {
            mouseButtonSources[$0]?.contains(source) == true
        }
        for button in mouseButtons {
            guard var sources = mouseButtonSources[button], sources.remove(source) != nil else { continue }
            if sources.isEmpty {
                mouseButtonSources.removeValue(forKey: button)
                mouseButtonHandler?(button, false)
            } else {
                mouseButtonSources[button] = sources
            }
        }

        let systemKeys = systemKeySources.keys.filter {
            systemKeySources[$0]?.contains(source) == true
        }
        for key in systemKeys {
            guard var sources = systemKeySources[key], sources.remove(source) != nil else { continue }
            if sources.isEmpty {
                systemKeySources.removeValue(forKey: key)
                systemKeyHandler?(key, false)
            } else {
                systemKeySources[key] = sources
            }
        }

        let shortcuts = recordedShortcutSources.keys.filter {
            recordedShortcutSources[$0]?.contains(source) == true
        }
        for shortcut in shortcuts {
            guard var sources = recordedShortcutSources[shortcut], sources.remove(source) != nil else { continue }
            if sources.isEmpty {
                recordedShortcutSources.removeValue(forKey: shortcut)
                recordedShortcutHandler?(shortcut, false)
            } else {
                recordedShortcutSources[shortcut] = sources
            }
        }

        let inputs = inputSources.keys.filter { inputSources[$0]?.contains(source) == true }
        for input in inputs {
            guard var sources = inputSources[input], sources.remove(source) != nil else { continue }
            if sources.isEmpty {
                inputSources.removeValue(forKey: input)
                onInputStateChange?(input, false)
            } else {
                inputSources[input] = sources
            }
        }

        if speedBoostSources.remove(source) != nil, speedBoostSources.isEmpty {
            mouseSpeedBoostHandler?(false)
        }
        if precisionSources.remove(source) != nil, precisionSources.isEmpty {
            mousePrecisionHandler?(false)
        }

        if stickStates.removeValue(forKey: source) != nil {
            publishAggregatedStick()
        }
        if joystickStates.removeValue(forKey: source) != nil {
            _ = publishAggregatedJoystick()
        }
    }

    private func handleSlotSelected(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        selectedSlot = slot
        for session in sessions.values { session.syncSelectedSlot(slot) }
        remoteSession?.syncSelectedSlot(slot)
        joyConFallback?.syncSelectedSlot(slot)
        onSlotSelected?(slot)
    }

    private func handleSessionModeChange(_ mode: ControllerOperationMode) {
        guard !suppressModeCallback, mode != operationMode else { return }
        setOperationMode(mode)
    }

    private func sendMicroKey(_ key: String, action: Int) -> Bool {
        handleKey(source: Self.hubSourceID, key: key, action: action)
    }

    private func refreshConnectedDeviceList() {
        var devices = controllers.keys.compactMap { id -> ConnectedControllerDescriptor? in
            guard let controller = controllers[id], let family = families[id] else { return nil }
            return ConnectedControllerDescriptor(
                id: id,
                name: controller.vendorName ?? controller.productCategory,
                family: family,
                source: .gameController
            )
        }
        if joyConFallback != nil {
            let family = joyConFallbackFamily
            devices.append(ConnectedControllerDescriptor(
                id: Self.joyConFallbackID,
                name: family.displayName,
                family: family,
                source: .gameController
            ))
        }
        if remoteSession != nil {
            devices.append(ConnectedControllerDescriptor(
                id: Self.remoteID,
                name: ControllerFamily.xiaomiRemote.displayName,
                family: .xiaomiRemote,
                source: .xiaomiRemote
            ))
        }
        devices.sort {
            switch $0.name.localizedCaseInsensitiveCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.id < $1.id
            }
        }
        connectedDevices = devices
        if selectedControllerID == nil || !devices.contains(where: { $0.id == selectedControllerID }) {
            selectedControllerID = devices.first(where: { $0.source == .gameController })?.id ?? devices.first?.id
        }
        publishConnectedDevices()
    }

    private func publishConnectedDevices() {
        onConnectedDevicesChange?(connectedDevices)
    }

    private func hasLiveSession(for id: String?) -> Bool {
        guard let id else { return false }
        return sessions[id] != nil ||
            (id == Self.remoteID && remoteSession != nil) ||
            (id == Self.joyConFallbackID && joyConFallback != nil)
    }

    private func emitSelectedControllerIfNeeded(
        force: Bool = false,
        controller: GCController? = nil,
        family: ControllerFamily? = nil
    ) {
        let resolvedID = selectedControllerID
        let resolvedController = controller
            ?? resolvedID.flatMap { controllers[$0] }
        let resolvedFamily = family
            ?? resolvedID.flatMap { families[$0] }
            ?? (resolvedID == Self.remoteID ? .xiaomiRemote : joyConFallbackFamily)
        guard force || resolvedController != nil || resolvedFamily == .xiaomiRemote || joyConFallback != nil else {
            onControllerChange?(nil, .generic)
            onAvailableInputsChange?(ControllerInput.availableInputs(for: .generic))
            return
        }
        onControllerChange?(resolvedController, resolvedFamily)
        if resolvedID == Self.remoteID {
            onAvailableInputsChange?(ControllerInput.availableInputs(for: .xiaomiRemote))
        } else if let session = resolvedID.flatMap({ sessions[$0] }) {
            onAvailableInputsChange?(ControllerInput.availableInputs(for: resolvedFamily))
            _ = session
        } else if let fallback = joyConFallback {
            onAvailableInputsChange?(ControllerInput.availableInputs(for: resolvedFamily))
            _ = fallback
        }
    }

    private static let remoteID = "xiaomi-remote"
    private static let joyConFallbackID = "joycon-composition"
    private static let hubSourceID = "hub-actions"

    private static func controllerID(_ controller: GCController) -> String {
        "gamecontroller-\(ObjectIdentifier(controller))"
    }
}
