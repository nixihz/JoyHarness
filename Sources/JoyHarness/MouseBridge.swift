import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct SystemKeyEventDescriptor {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

extension RecordedKeyboardShortcut {
    var eventDescriptor: SystemKeyEventDescriptor {
        let flags = modifiers.reduce(into: CGEventFlags()) { result, modifier in
            switch modifier {
            case .control: result.insert(.maskControl)
            case .option: result.insert(.maskAlternate)
            case .shift: result.insert(.maskShift)
            case .command: result.insert(.maskCommand)
            case .function: result.insert(.maskSecondaryFn)
            }
        }
        return SystemKeyEventDescriptor(keyCode: CGKeyCode(keyCode), flags: flags)
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
            return SystemKeyEventDescriptor(keyCode: 0x08, flags: .maskCommand)
        case .paste:
            return SystemKeyEventDescriptor(keyCode: 0x09, flags: .maskCommand)
        case .screenshotTool:
            return SystemKeyEventDescriptor(keyCode: 0x00, flags: [.maskCommand, .maskShift])
        case .browserBack:
            return SystemKeyEventDescriptor(keyCode: 0x21, flags: .maskCommand)
        case .browserForward:
            return SystemKeyEventDescriptor(keyCode: 0x1E, flags: .maskCommand)
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

@MainActor
final class MouseBridge: NSObject {
    private var targetVelocity = CGPoint.zero
    private var smoothedVelocity = CGPoint.zero
    private var fractionalDelta = CGPoint.zero
    private var fractionalTouchDelta = CGPoint.zero
    private var stickInput = CGPoint.zero
    private var scrolling = false
    private var speedBoostActive = false
    private var precisionActive = false
    private var scrollDirection: ScrollDirectionPreference = .traditional
    private var lastTickTime: TimeInterval?
    private var movementTimer: Timer?
    private var pressedMouseButtons: Set<MouseButton> = []
    private var mouseClickSequence = MouseClickSequenceTracker()
    private var pressedSystemKeys: Set<SystemKey> = []
    private var keyRepeatDelayTimer: Timer?
    private var keyRepeatTimer: Timer?
    private var lastPermissionState = false
    private var cachedDisplayBounds: [CGRect] = []
    private var cachedDisplayBoundsAt: TimeInterval = 0

    /// Optional mapped “hold for precise pointer” multiplier (not used by default bindings).
    nonisolated static let precisionSpeedMultiplier: CGFloat = 0.32
    nonisolated static let boostSpeedMultiplier: CGFloat = 1.8

    var onPermissionChange: (() -> Void)?

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    func start() {
        guard movementTimer == nil else { return }
        lastPermissionState = isAccessibilityGranted
        requestAccessibilityPermission()

        let timer = Timer(
            timeInterval: 1.0 / 120.0,
            target: self,
            selector: #selector(handleMovementTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        movementTimer = timer
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
        let accumulated = CGPoint(
            x: fractionalTouchDelta.x + x,
            y: fractionalTouchDelta.y + y
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
        postPointerMove(delta: whole)
    }

    func setScrollDirection(_ direction: ScrollDirectionPreference) {
        guard direction != scrollDirection else { return }
        scrollDirection = direction
        updateTargetVelocity()
    }

    func setMouseButton(_ button: MouseButton, pressed: Bool) {
        guard pressed != pressedMouseButtons.contains(button) else { return }
        guard isAccessibilityGranted else {
            pressedMouseButtons.remove(button)
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
        let descriptor = shortcut.eventDescriptor
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
        guard !characters.isEmpty,
              let textDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let textUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        characters.withUnsafeBufferPointer { buffer in
            textDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            textUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        for event in [textDown, textUp] {
            event.post(tap: .cghidEventTap)
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
        speedBoostActive: Bool
    ) -> CGFloat {
        if precisionActive { return precisionSpeedMultiplier }
        if speedBoostActive { return boostSpeedMultiplier }
        return 1
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

    @objc private func handleMovementTimer() {
        movePointer(at: ProcessInfo.processInfo.systemUptime)
    }

    private func movePointer(at now: TimeInterval) {
        updatePermissionState()
        guard let previousTick = lastTickTime else {
            lastTickTime = now
            return
        }
        lastTickTime = now
        let deltaTime = CGFloat(min(max(now - previousTick, 0), 1.0 / 30.0))

        guard isAccessibilityGranted else {
            resetMotion()
            return
        }

        let responseTime: CGFloat = targetVelocity == .zero ? 0.028 : 0.05
        let smoothing = Self.smoothingFactor(
            deltaTime: deltaTime,
            responseTime: responseTime
        )
        smoothedVelocity.x += (targetVelocity.x - smoothedVelocity.x) * smoothing
        smoothedVelocity.y += (targetVelocity.y - smoothedVelocity.y) * smoothing

        if targetVelocity == .zero, hypot(smoothedVelocity.x, smoothedVelocity.y) < 1 {
            resetMotion()
            return
        }

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
        guard wholeDelta != .zero else { return }

        if scrolling {
            postScroll(delta: wholeDelta)
            return
        }

        postPointerMove(delta: wholeDelta)
    }

    private func postPointerMove(delta: CGPoint) {
        guard let rawLocation = CGEvent(source: nil)?.location else { return }
        let displays = displayBounds()
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
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func displayBounds(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [CGRect] {
        if now - cachedDisplayBoundsAt < 1, !cachedDisplayBounds.isEmpty {
            return cachedDisplayBounds
        }
        let bounds = Self.fetchActiveDisplayBounds()
        cachedDisplayBounds = bounds
        cachedDisplayBoundsAt = now
        return bounds
    }

    private static func fetchActiveDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        return displays.prefix(Int(displayCount)).map(CGDisplayBounds)
    }

    private func postScroll(delta: CGPoint) {
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
        smoothedVelocity = .zero
        fractionalDelta = .zero
        fractionalTouchDelta = .zero
    }

    private func updateTargetVelocity() {
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
                    speedBoostActive: speedBoostActive
                )
            )
        }
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
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted
        onPermissionChange?()
    }
}
