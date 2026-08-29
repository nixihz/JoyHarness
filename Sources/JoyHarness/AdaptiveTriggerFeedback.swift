import AppKit
import GameController

enum RightTriggerFeedbackEvent: Equatable {
    case lightTouch
    case confirmation
}

struct RightTriggerPressState {
    static let lightTouchPoint: Float = 0.08
    static let resistanceStart: Float = 0.35
    static let releasePoint: Float = 0.72
    static let resistanceStrength: Float = 0.90
    static let resetPoint: Float = 0.18

    private(set) var hasTouched = false
    private(set) var hasConfirmed = false

    mutating func update(value: Float) -> RightTriggerFeedbackEvent? {
        if value <= Self.resetPoint, hasTouched {
            hasTouched = false
            hasConfirmed = false
            return nil
        }
        if value >= Self.releasePoint, !hasConfirmed {
            hasTouched = true
            hasConfirmed = true
            return .confirmation
        }
        if value >= Self.lightTouchPoint, !hasTouched {
            hasTouched = true
            return .lightTouch
        }
        return nil
    }
}

final class AdaptiveTriggerFeedback {
    private weak var trigger: GCDualSenseAdaptiveTrigger?
    private var pressState = RightTriggerPressState()
    private let hidOutput = DualSenseHIDOutput()
    private var backgroundEffectApplied = false
    private var observers: [NSObjectProtocol] = []

    var onFeedback: ((RightTriggerFeedbackEvent) -> Void)?
    var onHomeButtonChange: ((Bool) -> Void)? {
        get { hidOutput.onHomeButtonChange }
        set { hidOutput.onHomeButtonChange = newValue }
    }

    var isAvailable: Bool { trigger != nil }

    init() {
        start()
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.backgroundEffectApplied = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyBackgroundEffectIfNeeded()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyGameControllerEffect()
        })
    }

    func attach(_ controller: GCController?) {
        hidOutput.disconnect()
        trigger?.setModeOff()
        trigger = nil
        pressState = RightTriggerPressState()

        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        let rightTrigger = dualSense.rightTrigger
        trigger = rightTrigger
        _ = hidOutput.connectUSB()
        applyGameControllerEffect()
        print("[agent-deck] DualSense R2 adaptive feedback ready")
    }

    func update(value: Float) {
        guard trigger != nil else { return }
        applyBackgroundEffectIfNeeded()
        if let event = pressState.update(value: value) {
            onFeedback?(event)
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        hidOutput.disconnect()
        trigger?.setModeOff()
        trigger = nil
        pressState = RightTriggerPressState()
        backgroundEffectApplied = false
    }

    private func applyGameControllerEffect() {
        guard let trigger else { return }
        backgroundEffectApplied = false
        trigger.setModeWeaponWithStartPosition(
            RightTriggerPressState.resistanceStart,
            endPosition: RightTriggerPressState.releasePoint,
            resistiveStrength: RightTriggerPressState.resistanceStrength
        )
    }

    private func applyBackgroundEffectIfNeeded() {
        guard trigger != nil,
              !NSRunningApplication.current.isActive,
              !backgroundEffectApplied else { return }
        backgroundEffectApplied = hidOutput.applyWeaponEffect()
    }

    deinit {
        stop()
    }
}
