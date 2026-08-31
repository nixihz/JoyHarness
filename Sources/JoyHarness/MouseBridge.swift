import ApplicationServices
import AppKit
import CoreGraphics
import CoreVideo
import Foundation

struct SystemKeyEventDescriptor {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

extension RecordedKeyboardShortcut {
    func eventDescriptor(pressed: Bool) -> SystemKeyEventDescriptor {
        let pressedFlags = modifiers.reduce(into: CGEventFlags()) { result, modifier in
            switch modifier {
            case .control: result.insert(.maskControl)
            case .option: result.insert(.maskAlternate)
            case .shift: result.insert(.maskShift)
            case .command: result.insert(.maskCommand)
            case .function: result.insert(.maskSecondaryFn)
            }
        }
        return SystemKeyEventDescriptor(
            keyCode: CGKeyCode(keyCode),
            flags: pressed ? pressedFlags : []
        )
    }
}

extension SystemKey {
    func eventDescriptor(pressed: Bool) -> SystemKeyEventDescriptor {
        switch self {
        case .enter:
            return SystemKeyEventDescriptor(keyCode: 0x24, flags: [])
        case .backspace:
            return SystemKeyEventDescriptor(keyCode: 51, flags: [])
        case .escape:
            return SystemKeyEventDescriptor(keyCode: 53, flags: [])
        case .rightCommand:
            // IOLLEvent.h defines 0x10 as NX_DEVICERCMDKEYMASK (0x08 is left Command).
            let rightCommandDeviceFlag = CGEventFlags(rawValue: 0x10)
            let flags: CGEventFlags = pressed ? [.maskCommand, rightCommandDeviceFlag] : []
            return SystemKeyEventDescriptor(keyCode: 0x36, flags: flags)
        case .copy:
            return SystemKeyEventDescriptor(keyCode: 0x08, flags: pressed ? .maskCommand : [])
        case .paste:
            return SystemKeyEventDescriptor(keyCode: 0x09, flags: pressed ? .maskCommand : [])
        case .screenshotTool:
            let flags: CGEventFlags = [.maskCommand, .maskShift]
            return SystemKeyEventDescriptor(keyCode: 0x00, flags: pressed ? flags : [])
        case .browserBack:
            return SystemKeyEventDescriptor(keyCode: 0x21, flags: pressed ? .maskCommand : [])
        case .browserForward:
            return SystemKeyEventDescriptor(keyCode: 0x1E, flags: pressed ? .maskCommand : [])
        }
    }
}

struct MouseClickSequenceTracker {
    private struct ButtonState {
        var activeClickCount: Int64 = 1
        var lastClickLocation: CGPoint?
        var lastReleaseTime: TimeInterval?
    }

    private var buttonStates: [MouseButton: ButtonState] = [:]

    mutating func clickCount(
        for button: MouseButton,
        pressed: Bool,
        at timestamp: TimeInterval,
        location: CGPoint,
        doubleClickInterval: TimeInterval,
        movementTolerance: CGFloat = 4
    ) -> Int64 {
        var state = buttonStates[button] ?? ButtonState()

        if pressed {
            let elapsed = state.lastReleaseTime.map { timestamp - $0 }
            let distanceSquared = state.lastClickLocation.map {
                let deltaX = location.x - $0.x
                let deltaY = location.y - $0.y
                return deltaX * deltaX + deltaY * deltaY
            }
            let continuesSequence = elapsed.map {
                $0 >= 0 && $0 <= doubleClickInterval
            } == true && distanceSquared.map {
                $0 <= movementTolerance * movementTolerance
            } == true

            state.activeClickCount = continuesSequence ? state.activeClickCount + 1 : 1
            state.lastClickLocation = location
        } else {
            state.lastReleaseTime = timestamp
        }

        buttonStates[button] = state
        return state.activeClickCount
    }
}

struct MotionTimeAccumulator {
    private(set) var pendingDuration: TimeInterval = 0

    mutating func consume(
        elapsed: TimeInterval,
        frameDuration: TimeInterval
    ) -> TimeInterval {
        let validFrameDuration = max(frameDuration, 1.0 / 240.0)
        guard elapsed >= 0, elapsed <= 0.25 else {
            pendingDuration = 0
            return validFrameDuration
        }
        // Repay a missed frame gradually so motion keeps its distance without one large jump.
        pendingDuration += elapsed
        let consumed = min(pendingDuration, validFrameDuration * 1.5)
        pendingDuration -= consumed
        return consumed
    }

    mutating func reset() {
        pendingDuration = 0
    }
}

struct PointerMotionClockWatchdog {
    private(set) var lastCallbackTime: TimeInterval?

    mutating func recordCallback(at time: TimeInterval) {
        lastCallbackTime = time
    }

    mutating func reset() {
        lastCallbackTime = nil
    }

    func needsRecovery(
        at time: TimeInterval,
        displayLinkRunning: Bool,
        timeout: TimeInterval = 1
    ) -> Bool {
        guard displayLinkRunning, let lastCallbackTime else { return true }
        let elapsed = time - lastCallbackTime
        return elapsed < 0 || elapsed > timeout
    }
}

private struct PointerDisplay: Sendable {
    let id: CGDirectDisplayID
    let bounds: CGRect
}

private struct PointerMotionFrame: Sendable {
    let delta: CGPoint
    let scrolling: Bool
    let pressedMouseButtons: Set<MouseButton>
    let displays: [PointerDisplay]
}

private final class PointerMotionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var targetVelocity = CGPoint.zero
    private var smoothedVelocity = CGPoint.zero
    private var fractionalDelta = CGPoint.zero
    private var timeAccumulator = MotionTimeAccumulator()
    private var clockWatchdog = PointerMotionClockWatchdog()
    private var lastTickTime: TimeInterval?
    private var scrolling = false
    private var accessibilityGranted = false
    private var pressedMouseButtons: Set<MouseButton> = []
    private var displays: [PointerDisplay] = []

    func start(at time: TimeInterval) {
        lock.lock()
        lastTickTime = time
        clockWatchdog.recordCallback(at: time)
        timeAccumulator.reset()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        targetVelocity = .zero
        lastTickTime = nil
        clockWatchdog.reset()
        resetMotionLocked()
        lock.unlock()
    }

    func setTargetVelocity(_ velocity: CGPoint, scrolling: Bool) {
        lock.lock()
        if scrolling != self.scrolling {
            resetMotionLocked()
            self.scrolling = scrolling
        }
        targetVelocity = velocity
        lock.unlock()
    }

    func setAccessibilityGranted(_ granted: Bool) {
        lock.lock()
        accessibilityGranted = granted
        if !granted { resetMotionLocked() }
        lock.unlock()
    }

    func setPressedMouseButtons(_ buttons: Set<MouseButton>) {
        lock.lock()
        pressedMouseButtons = buttons
        lock.unlock()
    }

    func setDisplays(_ displays: [PointerDisplay]) {
        lock.lock()
        self.displays = displays
        lock.unlock()
    }

    func resetMotion() {
        lock.lock()
        resetMotionLocked()
        lock.unlock()
    }

    func needsClockRecovery(at time: TimeInterval, displayLinkRunning: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clockWatchdog.needsRecovery(
            at: time,
            displayLinkRunning: displayLinkRunning
        )
    }

    func tickAndPost(
        at now: TimeInterval,
        frameDuration: TimeInterval
    ) -> CGDirectDisplayID? {
        guard let frame = advance(at: now, frameDuration: frameDuration) else { return nil }
        if frame.scrolling {
            MouseBridge.postScroll(delta: frame.delta)
            return nil
        }
        guard let location = MouseBridge.postPointerMove(
            delta: frame.delta,
            pressedMouseButtons: frame.pressedMouseButtons,
            displays: frame.displays.map(\.bounds)
        ) else { return nil }
        return frame.displays.first(where: { $0.bounds.contains(location) })?.id
    }

    private func advance(
        at now: TimeInterval,
        frameDuration: TimeInterval
    ) -> PointerMotionFrame? {
        lock.lock()
        defer { lock.unlock() }
        clockWatchdog.recordCallback(at: now)
        guard let previousTick = lastTickTime else {
            lastTickTime = now
            return nil
        }
        lastTickTime = now
        guard accessibilityGranted else {
            resetMotionLocked()
            return nil
        }

        if targetVelocity == .zero, hypot(smoothedVelocity.x, smoothedVelocity.y) < 1 {
            resetMotionLocked()
            return nil
        }

        let deltaTime = CGFloat(timeAccumulator.consume(
            elapsed: now - previousTick,
            frameDuration: frameDuration
        ))
        let responseTime: CGFloat = targetVelocity == .zero ? 0.028 : 0.05
        let smoothing = MouseBridge.smoothingFactor(
            deltaTime: deltaTime,
            responseTime: responseTime
        )
        smoothedVelocity.x += (targetVelocity.x - smoothedVelocity.x) * smoothing
        smoothedVelocity.y += (targetVelocity.y - smoothedVelocity.y) * smoothing

        let accumulatedDelta = CGPoint(
            x: fractionalDelta.x + smoothedVelocity.x * deltaTime,
            y: fractionalDelta.y + smoothedVelocity.y * deltaTime
        )
        let wholeDelta = CGPoint(
            x: accumulatedDelta.x.rounded(.towardZero),
            y: accumulatedDelta.y.rounded(.towardZero)
        )
        fractionalDelta = CGPoint(
            x: accumulatedDelta.x - wholeDelta.x,
            y: accumulatedDelta.y - wholeDelta.y
        )
        guard wholeDelta != .zero else { return nil }
        return PointerMotionFrame(
            delta: wholeDelta,
            scrolling: scrolling,
            pressedMouseButtons: pressedMouseButtons,
            displays: displays
        )
    }

    private func resetMotionLocked() {
        smoothedVelocity = .zero
        fractionalDelta = .zero
        timeAccumulator.reset()
    }
}

@MainActor
final class MouseBridge: NSObject {
    private var fractionalTouchDelta = CGPoint.zero
    private var stickInput = CGPoint.zero
    private var scrolling = false
    private var speedBoostActive = false
    private var precisionActive = false
    private var scrollDirection: ScrollDirectionPreference = .traditional
    private var pointerSensitivities = PointerSensitivityValues.defaults
    private let motionEngine = PointerMotionEngine()
    private let fallbackMovementQueue = DispatchQueue(
        label: "tech.agentdeck.pointer-motion",
        qos: .userInteractive
    )
    private var displayLink: CVDisplayLink?
    private var fallbackMovementTimer: DispatchSourceTimer?
    private var permissionTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var pressedMouseButtons: Set<MouseButton> = []
    private var mouseClickSequence = MouseClickSequenceTracker()
    private var pressedSystemKeys: Set<SystemKey> = []
    private var keyRepeatDelayTimer: Timer?
    private var keyRepeatTimer: Timer?
    private var lastPermissionState = false
    private var activeDisplays: [PointerDisplay] = []

    /// Optional mapped “hold for precise pointer” multiplier (not used by default bindings).
    nonisolated static let precisionSpeedMultiplier = PointerSensitivityValues.defaults.slow
    nonisolated static let boostSpeedMultiplier = PointerSensitivityValues.defaults.fast

    var onPermissionChange: (() -> Void)?

    var isRunning: Bool { displayLink != nil || fallbackMovementTimer != nil }
    var isObservingScreenChanges: Bool { screenParametersObserver != nil }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    func start() {
        guard !isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastPermissionState = isAccessibilityGranted
        requestAccessibilityPermission()
        refreshActiveDisplays()
        motionEngine.start(at: now)
        startMovementClock()
        startPermissionMonitoring()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChange()
            }
        }
    }

    func stop() {
        stopMovementClock()
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        keyRepeatDelayTimer?.invalidate()
        keyRepeatDelayTimer = nil
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        for button in Array(pressedMouseButtons) {
            setMouseButton(button, pressed: false)
        }
        for key in pressedSystemKeys {
            postSystemKey(key, pressed: false)
        }
        pressedMouseButtons.removeAll()
        pressedSystemKeys.removeAll()
        stickInput = .zero
        motionEngine.setPressedMouseButtons([])
        motionEngine.stop()
        resetMotion()
    }

    func updateStick(x: Float, y: Float, scrolling: Bool = false) {
        if scrolling != self.scrolling {
            resetMotion()
            self.scrolling = scrolling
        }
        stickInput = CGPoint(x: CGFloat(x), y: CGFloat(y))
        updateTargetVelocity()
    }

    func setSpeedBoostActive(_ active: Bool) {
        guard active != speedBoostActive else { return }
        speedBoostActive = active
        updateTargetVelocity()
    }

    func setPrecisionActive(_ active: Bool) {
        guard active != precisionActive else { return }
        precisionActive = active
        updateTargetVelocity()
    }

    /// Applies a one-shot relative pointer nudge (e.g. DualSense touchpad slide).
    func applyPointerDelta(x: CGFloat, y: CGFloat) {
        guard x != 0 || y != 0 else { return }
        guard isAccessibilityGranted else {
            requestAccessibilityPermission()
            return
        }
        let sensitivityScale = Self.touchpadSensitivityScale(
            slowSensitivity: pointerSensitivities.slow
        )
        let accumulated = CGPoint(
            x: fractionalTouchDelta.x + x * sensitivityScale,
            y: fractionalTouchDelta.y + y * sensitivityScale
        )
        let whole = CGPoint(
            x: accumulated.x.rounded(.towardZero),
            y: accumulated.y.rounded(.towardZero)
        )
        fractionalTouchDelta = CGPoint(
            x: accumulated.x - whole.x,
            y: accumulated.y - whole.y
        )
        guard whole != .zero else { return }
        Self.postPointerMove(
            delta: whole,
            pressedMouseButtons: pressedMouseButtons,
            displays: activeDisplays.map(\.bounds)
        )
    }

    func setScrollDirection(_ direction: ScrollDirectionPreference) {
        guard direction != scrollDirection else { return }
        scrollDirection = direction
        updateTargetVelocity()
    }

    func setPointerSensitivities(_ values: PointerSensitivityValues) {
        guard values != pointerSensitivities else { return }
        pointerSensitivities = values
        updateTargetVelocity()
    }

    func setMouseButton(_ button: MouseButton, pressed: Bool) {
        guard pressed != pressedMouseButtons.contains(button) else { return }
        guard isAccessibilityGranted else {
            pressedMouseButtons.remove(button)
            motionEngine.setPressedMouseButtons(pressedMouseButtons)
            requestAccessibilityPermission()
            return
        }
        guard let location = CGEvent(source: nil)?.location else { return }
        let clickCount = mouseClickSequence.clickCount(
            for: button,
            pressed: pressed,
            at: ProcessInfo.processInfo.systemUptime,
            location: location,
            doubleClickInterval: NSEvent.doubleClickInterval
        )
        guard let event = Self.mouseButtonEvent(
            button: button,
            pressed: pressed,
            location: location,
            clickCount: clickCount
        ) else { return }
        event.post(tap: .cghidEventTap)
        if pressed {
            pressedMouseButtons.insert(button)
        } else {
            pressedMouseButtons.remove(button)
        }
        motionEngine.setPressedMouseButtons(pressedMouseButtons)
    }

    nonisolated static func mouseButtonEvent(
        button: MouseButton,
        pressed: Bool,
        location: CGPoint,
        clickCount: Int64
    ) -> CGEvent? {
        let eventType: CGEventType
        let cgButton: CGMouseButton
        switch (button, pressed) {
        case (.left, true): (eventType, cgButton) = (.leftMouseDown, .left)
        case (.left, false): (eventType, cgButton) = (.leftMouseUp, .left)
        case (.right, true): (eventType, cgButton) = (.rightMouseDown, .right)
        case (.right, false): (eventType, cgButton) = (.rightMouseUp, .right)
        case (.middle, true): (eventType, cgButton) = (.otherMouseDown, .center)
        case (.middle, false): (eventType, cgButton) = (.otherMouseUp, .center)
        }
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: location,
            mouseButton: cgButton
        )
        event?.setIntegerValueField(.mouseEventClickState, value: max(clickCount, 1))
        return event
    }

    func setSystemKey(_ key: SystemKey, pressed: Bool) {
        guard pressed != pressedSystemKeys.contains(key) else { return }
        guard isAccessibilityGranted else {
            pressedSystemKeys.remove(key)
            stopKeyRepeat(for: key)
            requestAccessibilityPermission()
            return
        }
        postSystemKey(key, pressed: pressed)
        if pressed {
            pressedSystemKeys.insert(key)
            if key == .backspace { startKeyRepeat(for: key) }
        } else {
            pressedSystemKeys.remove(key)
            stopKeyRepeat(for: key)
        }
    }

    func setRecordedShortcut(_ shortcut: RecordedKeyboardShortcut, pressed: Bool) {
        guard isAccessibilityGranted else {
            requestAccessibilityPermission()
            return
        }
        let descriptor = shortcut.eventDescriptor(pressed: pressed)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: descriptor.keyCode,
            keyDown: pressed
        ) else { return }
        event.flags = descriptor.flags
        event.post(tap: .cghidEventTap)
    }

    @discardableResult
    func typeText(_ text: String) -> Bool {
        guard isAccessibilityGranted else {
            requestAccessibilityPermission()
            return false
        }
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return false }
        let eventSource = CGEventSource(stateID: .hidSystemState)
        for charCode in characters {
            var char = charCode
            guard let textDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let textUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                continue
            }
            textDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
            textUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
            textDown.post(tap: .cghidEventTap)
            textUp.post(tap: .cghidEventTap)
        }
        return true
    }

    nonisolated static func pointerVelocity(
        x: CGFloat,
        y: CGFloat,
        speedMultiplier: CGFloat = 1
    ) -> CGPoint {
        let deadZone: CGFloat = 0.15
        // Lower near-center speed keeps small stick travel usable for UI chrome.
        let precisionSpeed: CGFloat = 55
        let maximumSpeed: CGFloat = 1_250
        let magnitude = min(hypot(x, y), 1)
        guard magnitude > deadZone else { return .zero }

        let normalizedMagnitude = (magnitude - deadZone) / (1 - deadZone)
        // Steeper curve: more of the stick range stays in the fine-control band.
        let speed = precisionSpeed * normalizedMagnitude
            + (maximumSpeed - precisionSpeed) * pow(normalizedMagnitude, 2.8)
        return CGPoint(
            x: x / magnitude * speed * speedMultiplier,
            y: -y / magnitude * speed * speedMultiplier
        )
    }

    nonisolated static func pointerSpeedMultiplier(
        precisionActive: Bool,
        speedBoostActive: Bool,
        sensitivities: PointerSensitivityValues = .defaults
    ) -> CGFloat {
        if precisionActive { return sensitivities.slow }
        if speedBoostActive { return sensitivities.fast }
        return sensitivities.normal
    }

    nonisolated static func touchpadSensitivityScale(slowSensitivity: CGFloat) -> CGFloat {
        slowSensitivity / precisionSpeedMultiplier
    }

    nonisolated static func scrollVelocity(
        x: CGFloat,
        y: CGFloat,
        direction: ScrollDirectionPreference = .traditional
    ) -> CGPoint {
        let deadZone: CGFloat = 0.15
        let minimumSpeed: CGFloat = 32
        let maximumSpeed: CGFloat = 1_400
        let magnitude = min(hypot(x, y), 1)
        guard magnitude > deadZone else { return .zero }

        let normalizedMagnitude = (magnitude - deadZone) / (1 - deadZone)
        let speed = minimumSpeed * normalizedMagnitude
            + (maximumSpeed - minimumSpeed) * pow(normalizedMagnitude, 1.65)
        let polarity: CGFloat = direction == .natural ? -1 : 1
        return CGPoint(
            x: x / magnitude * speed * polarity,
            y: y / magnitude * speed * polarity
        )
    }

    nonisolated static func smoothingFactor(
        deltaTime: CGFloat,
        responseTime: CGFloat
    ) -> CGFloat {
        guard deltaTime > 0, responseTime > 0 else { return 1 }
        return 1 - exp(-deltaTime / responseTime)
    }

    /// Keeps synthetic pointer events on a real display.
    ///
    /// `CGEvent` absolute moves can accept coordinates past the screen edge; the
    /// visible cursor stops, but the HID location keeps drifting. Reversing the
    /// stick then has to travel that off-screen debt before the cursor moves again.
    nonisolated static func clampPointerLocation(
        _ point: CGPoint,
        displays: [CGRect]
    ) -> CGPoint {
        guard !displays.isEmpty else { return point }
        for bounds in displays where bounds.contains(point) {
            return point
        }

        var nearest = point
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for bounds in displays {
            // CGRect.contains treats maxX/maxY as exclusive; stay on the last pixel.
            let clamped = CGPoint(
                x: min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX - 1)),
                y: min(max(point.y, bounds.minY), max(bounds.minY, bounds.maxY - 1))
            )
            let dx = point.x - clamped.x
            let dy = point.y - clamped.y
            let distance = dx * dx + dy * dy
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = clamped
            }
        }
        return nearest
    }

    private func startMovementClock() {
        guard !startDisplayLink() else { return }
        startFallbackMovementTimer()
    }

    private func startDisplayLink() -> Bool {
        var candidate: CVDisplayLink?
        let displayID = currentPointerDisplayID() ?? CGMainDisplayID()
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &candidate) == kCVReturnSuccess,
              let candidate else {
            return false
        }
        let engine = motionEngine
        guard CVDisplayLinkSetOutputHandler(candidate, { displayLink, _, _, _, _ in
            let frameDuration = Self.displayLinkFrameDuration(displayLink)
            let targetDisplayID = engine.tickAndPost(
                at: ProcessInfo.processInfo.systemUptime,
                frameDuration: frameDuration
            )
            if let targetDisplayID,
               targetDisplayID != CVDisplayLinkGetCurrentCGDisplay(displayLink) {
                _ = CVDisplayLinkSetCurrentCGDisplay(displayLink, targetDisplayID)
            }
            return kCVReturnSuccess
        }) == kCVReturnSuccess,
              CVDisplayLinkStart(candidate) == kCVReturnSuccess else {
            return false
        }
        displayLink = candidate
        return true
    }

    private func startFallbackMovementTimer() {
        let frameRate = min(max(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60, 60), 120)
        let frameDuration = 1.0 / Double(frameRate)
        let timer = DispatchSource.makeTimerSource(queue: fallbackMovementQueue)
        let engine = motionEngine
        timer.schedule(
            deadline: .now(),
            repeating: frameDuration,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler {
            _ = engine.tickAndPost(
                at: ProcessInfo.processInfo.systemUptime,
                frameDuration: frameDuration
            )
        }
        fallbackMovementTimer = timer
        timer.resume()
    }

    private func stopMovementClock() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        fallbackMovementTimer?.cancel()
        fallbackMovementTimer = nil
    }

    private func startPermissionMonitoring() {
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handlePermissionTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    @objc private func handlePermissionTimer() {
        updatePermissionState()
        recoverMovementClockIfNeeded()
    }

    private func handleScreenParametersChange() {
        refreshActiveDisplays()
        stopMovementClock()
        motionEngine.start(at: ProcessInfo.processInfo.systemUptime)
        startMovementClock()
    }

    private func recoverMovementClockIfNeeded(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let displayLink else { return }
        guard motionEngine.needsClockRecovery(
            at: now,
            displayLinkRunning: CVDisplayLinkIsRunning(displayLink)
        ) else { return }

        stopMovementClock()
        motionEngine.start(at: now)
        startFallbackMovementTimer()
        print("[agent-deck] pointer display clock stalled; switched to fallback timer")
    }

    private func refreshActiveDisplays() {
        activeDisplays = Self.fetchActiveDisplays()
        motionEngine.setDisplays(activeDisplays)
    }

    private func currentPointerDisplayID() -> CGDirectDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        return activeDisplays.first(where: { $0.bounds.contains(location) })?.id
    }

    private nonisolated static func displayLinkFrameDuration(
        _ displayLink: CVDisplayLink
    ) -> TimeInterval {
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink)
        guard period.timeValue > 0, period.timeScale > 0 else { return 1.0 / 60.0 }
        return Double(period.timeValue) / Double(period.timeScale)
    }

    @discardableResult
    nonisolated static func postPointerMove(
        delta: CGPoint,
        pressedMouseButtons: Set<MouseButton>,
        displays: [CGRect]
    ) -> CGPoint? {
        guard let rawLocation = CGEvent(source: nil)?.location else { return nil }
        let location = Self.clampPointerLocation(rawLocation, displays: displays)
        let nextLocation = Self.clampPointerLocation(
            CGPoint(x: location.x + delta.x, y: location.y + delta.y),
            displays: displays
        )
        let drag: (CGEventType, CGMouseButton)
        if pressedMouseButtons.contains(.left) {
            drag = (.leftMouseDragged, .left)
        } else if pressedMouseButtons.contains(.right) {
            drag = (.rightMouseDragged, .right)
        } else if pressedMouseButtons.contains(.middle) {
            drag = (.otherMouseDragged, .center)
        } else {
            drag = (.mouseMoved, .left)
        }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: drag.0,
            mouseCursorPosition: nextLocation,
            mouseButton: drag.1
        ) else { return nil }
        event.post(tap: .cghidEventTap)
        return nextLocation
    }

    private nonisolated static func fetchActiveDisplays() -> [PointerDisplay] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            let id = CGMainDisplayID()
            return [PointerDisplay(id: id, bounds: CGDisplayBounds(id))]
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            let id = CGMainDisplayID()
            return [PointerDisplay(id: id, bounds: CGDisplayBounds(id))]
        }
        return displays.prefix(Int(displayCount)).map {
            PointerDisplay(id: $0, bounds: CGDisplayBounds($0))
        }
    }

    nonisolated static func postScroll(delta: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(delta.y),
            wheel2: Int32(delta.x),
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postSystemKey(_ key: SystemKey, pressed: Bool, isRepeat: Bool = false) {
        let descriptor = key.eventDescriptor(pressed: pressed)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: descriptor.keyCode,
            keyDown: pressed
        ) else { return }
        event.flags = descriptor.flags
        if isRepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    private func startKeyRepeat(for key: SystemKey) {
        stopKeyRepeat(for: key)
        let delayTimer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pressedSystemKeys.contains(key) else { return }
                let repeatTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.pressedSystemKeys.contains(key) else { return }
                        self.postSystemKey(key, pressed: true, isRepeat: true)
                    }
                }
                RunLoop.main.add(repeatTimer, forMode: .common)
                self.keyRepeatTimer = repeatTimer
            }
        }
        RunLoop.main.add(delayTimer, forMode: .common)
        keyRepeatDelayTimer = delayTimer
    }

    private func stopKeyRepeat(for key: SystemKey) {
        guard key == .backspace else { return }
        keyRepeatDelayTimer?.invalidate()
        keyRepeatDelayTimer = nil
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
    }

    private func resetMotion() {
        motionEngine.resetMotion()
        fractionalTouchDelta = .zero
    }

    private func updateTargetVelocity() {
        let targetVelocity: CGPoint
        if scrolling {
            targetVelocity = Self.scrollVelocity(
                x: stickInput.x,
                y: stickInput.y,
                direction: scrollDirection
            )
        } else {
            targetVelocity = Self.pointerVelocity(
                x: stickInput.x,
                y: stickInput.y,
                speedMultiplier: Self.pointerSpeedMultiplier(
                    precisionActive: precisionActive,
                    speedBoostActive: speedBoostActive,
                    sensitivities: pointerSensitivities
                )
            )
        }
        motionEngine.setTargetVelocity(targetVelocity, scrolling: scrolling)
    }

    private func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updatePermissionState()
    }

    private func updatePermissionState() {
        let granted = isAccessibilityGranted
        motionEngine.setAccessibilityGranted(granted)
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted
        onPermissionChange?()
    }
}
