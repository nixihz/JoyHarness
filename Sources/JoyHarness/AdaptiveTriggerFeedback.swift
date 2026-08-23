import AppKit
import GameController

enum AdaptiveTriggerFeedbackEvent: Equatable {
    case lightTouch
    case confirmation
}

struct AdaptiveTriggerPressState {
    static let lightTouchPoint: Float = 0.08
    static let resistanceStart: Float = 0.35
    static let releasePoint: Float = 0.72
    static let resistanceStrength: Float = 0.90
    static let resetPoint: Float = 0.18

    private(set) var hasTouched = false
    private(set) var hasConfirmed = false

    mutating func update(value: Float) -> AdaptiveTriggerFeedbackEvent? {
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
    private var pressState = AdaptiveTriggerPressState()
    private let hidOutput = DualSenseHIDOutput()
    private var backgroundEffectApplied = false
    private var observers: [NSObjectProtocol] = []

    var onFeedback: ((AdaptiveTriggerFeedbackEvent) -> Void)?

    var isAvailable: Bool { trigger != nil }

    init() {
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
        pressState = AdaptiveTriggerPressState()

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

    private func applyGameControllerEffect() {
        guard let trigger else { return }
        backgroundEffectApplied = false
        trigger.setModeWeaponWithStartPosition(
            AdaptiveTriggerPressState.resistanceStart,
            endPosition: AdaptiveTriggerPressState.releasePoint,
            resistiveStrength: AdaptiveTriggerPressState.resistanceStrength
        )
    }

    private func applyBackgroundEffectIfNeeded() {
        guard trigger != nil,
              !NSRunningApplication.current.isActive,
              !backgroundEffectApplied else { return }
        backgroundEffectApplied = hidOutput.applyWeaponEffect()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        hidOutput.disconnect()
        trigger?.setModeOff()
    }
}
