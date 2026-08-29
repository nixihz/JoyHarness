import Foundation
import GameController
import CoreHaptics

final class HapticEngine {
    private var engines: [CHHapticEngine] = []
    private var rightTriggerEngine: CHHapticEngine?
    private var activePlayers: [UUID: CHHapticPatternPlayer] = [:]
    private var pulseTimer: Timer?
    private var feedbackTimer: Timer?
    private var controllerName: String = "none"

    var onConnectionChange: (() -> Void)?

    private var engine: CHHapticEngine? { engines.first }

    var hasController: Bool { !engines.isEmpty }
    var connectedName: String { controllerName }

    func attach(_ controller: GCController?) {
        attach(controller.map { [$0] } ?? [])
    }

    func attach(_ controllers: [GCController]) {
        detach()
        guard !controllers.isEmpty else {
            print("[agent-deck] no game controller connected")
            return
        }
        controllerName = controllers.map { $0.vendorName ?? $0.productCategory }.joined(separator: " + ")
        for controller in controllers {
            attachHaptics(for: controller)
        }
        if engines.isEmpty {
            print("[agent-deck] connected \(controllerName) (no haptics)")
            onConnectionChange?()
            return
        }
        if controllers.count == 1, let controller = controllers.first, let haptics = controller.haptics {
            attachXboxRightTriggerEngine(haptics, controller: controller)
        }
        onConnectionChange?()
    }

    private func attachHaptics(for controller: GCController) {
        guard let haptics = controller.haptics else { return }
        let localities = haptics.supportedLocalities
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: ",")
        print("[agent-deck] controller category=\(controller.productCategory) haptic-localities=\(localities)")
        guard let created = haptics.createEngine(withLocality: .all) else {
            print("[agent-deck] connected \(controllerName) (haptic engine unavailable)")
            return
        }
        do {
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true
            created.stoppedHandler = { reason in
                print("[agent-deck] haptic engine stopped: \(reason.rawValue)")
            }
            created.resetHandler = { [weak created] in
                try? created?.start()
            }
            try created.start()
            engines.append(created)
            print("[agent-deck] haptics ready on \(controller.vendorName ?? controller.productCategory)")
        } catch {
            print("[agent-deck] failed to start haptics: \(error)")
        }
    }

    private func detach() {
        let wasConnected = controllerName != "none"
        stopAll()
        rightTriggerEngine?.stop(completionHandler: nil)
        rightTriggerEngine = nil
        for engine in engines { engine.stop(completionHandler: nil) }
        engines.removeAll()
        controllerName = "none"
        if wasConnected {
            onConnectionChange?()
        }
    }

    func stop() {
        detach()
    }

    func apply(_ state: PadState) {
        stopAll()
        switch state {
        case .idle:
            break
        case .busy:
            startPulse(interval: 0.85, intensity: 0.28, sharpness: 0.35, duration: 0.12)
        case .waiting:
            startPulse(interval: 0.45, intensity: 0.72, sharpness: 0.85, duration: 0.12)
        case .done:
            playBurst(events: [
                (0.0, 0.55, 0.4, 0.08),
                (0.12, 0.35, 0.2, 0.06),
            ])
        case .error:
            playBurst(events: [
                (0.0, 1.0, 1.0, 0.12),
                (0.16, 0.9, 0.9, 0.12),
                (0.32, 1.0, 1.0, 0.16),
            ])
        }
    }

    func announceSlot(_ index: Int, state: PadState) {
        stopAll()
        let count = min(max(index + 1, 1), 6)
        let events = (0..<count).map { pulse in
            (TimeInterval(pulse) * 0.11, Float(0.42), Float(0.75), TimeInterval(0.045))
        }
        playBurst(events: events)
        guard state == .busy || state == .waiting else { return }
        let delay = TimeInterval(count) * 0.11 + 0.12
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.apply(state)
        }
    }

    func playAdaptiveTriggerFeedback(_ event: RightTriggerFeedbackEvent) {
        switch event {
        case .lightTouch:
            playOneShot(intensity: 0.22, sharpness: 0.75, duration: 0.025)
        case .confirmation:
            playBurst(events: [
                (0.0, 0.95, 0.95, 0.055),
                (0.065, 0.58, 0.55, 0.045),
            ])
        }
    }

    func playXboxTriggerFeedback(_ event: RightTriggerFeedbackEvent) {
        let targetEngine = rightTriggerEngine ?? engine
        let usesDedicatedTrigger = rightTriggerEngine != nil
        switch event {
        case .lightTouch:
            playOneShot(
                on: targetEngine,
                intensity: usesDedicatedTrigger ? 0.18 : 0.10,
                sharpness: 0.72,
                duration: 0.018
            )
        case .confirmation:
            playOneShot(
                on: targetEngine,
                intensity: usesDedicatedTrigger ? 0.42 : 0.20,
                sharpness: 0.88,
                duration: 0.035
            )
        }
    }

    func playOperationModeFeedback(_ mode: ControllerOperationMode) {
        stopAll()
        switch mode {
        case .native:
            playBurst(events: [
                (0.0, 0.65, 0.75, 0.05),
                (0.12, 0.65, 0.75, 0.05),
            ])
        case .mapping:
            playBurst(events: [
                (0.0, 0.75, 0.85, 0.08),
            ])
        }
    }

    private func startPulse(interval: TimeInterval, intensity: Float, sharpness: Float, duration: TimeInterval) {
        playOneShot(intensity: intensity, sharpness: sharpness, duration: duration)
        pulseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playOneShot(intensity: intensity, sharpness: sharpness, duration: duration)
        }
    }

    private func playOneShot(intensity: Float, sharpness: Float, duration: TimeInterval) {
        guard !engines.isEmpty else {
            print("[agent-deck] rumble skipped (no haptic engine) intensity=\(intensity)")
            return
        }
        for engine in engines {
            playOneShot(on: engine, intensity: intensity, sharpness: sharpness, duration: duration)
        }
    }

    private func playOneShot(
        on targetEngine: CHHapticEngine?,
        intensity: Float,
        sharpness: Float,
        duration: TimeInterval
    ) {
        guard let targetEngine else {
            print("[agent-deck] rumble skipped (no haptic engine) intensity=\(intensity)")
            return
        }
        do {
            let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0,
                duration: duration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try targetEngine.makePlayer(with: pattern)
            retain(player, for: duration)
            try player.start(atTime: 0)
        } catch {
            print("[agent-deck] haptic play failed: \(error)")
        }
    }

    private func playBurst(events: [(TimeInterval, Float, Float, TimeInterval)]) {
        guard !engines.isEmpty else {
            print("[agent-deck] burst skipped (no haptic engine)")
            return
        }
        for engine in engines { playBurst(events: events, on: engine) }
    }

    private func playBurst(
        events: [(TimeInterval, Float, Float, TimeInterval)],
        on engine: CHHapticEngine
    ) {
        do {
            let hapticEvents: [CHHapticEvent] = events.map { start, intensity, sharpness, duration in
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    ],
                    relativeTime: start,
                    duration: duration
                )
            }
            let pattern = try CHHapticPattern(events: hapticEvents, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            let totalDuration = events.map { $0.0 + $0.3 }.max() ?? 0
            retain(player, for: totalDuration)
            try player.start(atTime: 0)
        } catch {
            print("[agent-deck] burst failed: \(error)")
        }
    }

    private func retain(_ player: CHHapticPatternPlayer, for duration: TimeInterval) {
        let id = UUID()
        activePlayers[id] = player
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            self?.activePlayers[id] = nil
        }
    }

    private func attachXboxRightTriggerEngine(
        _ haptics: GCDeviceHaptics,
        controller: GCController
    ) {
        guard ControllerFamily.detect(controller: controller) == .xbox else { return }
        guard haptics.supportedLocalities.contains(.rightTrigger),
              let triggerEngine = haptics.createEngine(withLocality: .rightTrigger) else {
            print("[agent-deck] Xbox RT haptics using all-locality fallback")
            return
        }
        do {
            triggerEngine.playsHapticsOnly = true
            triggerEngine.isAutoShutdownEnabled = true
            triggerEngine.stoppedHandler = { reason in
                print("[agent-deck] Xbox RT haptic engine stopped: \(reason.rawValue)")
            }
            triggerEngine.resetHandler = { [weak self] in
                try? self?.rightTriggerEngine?.start()
            }
            try triggerEngine.start()
            rightTriggerEngine = triggerEngine
            print("[agent-deck] Xbox RT impulse haptics ready")
        } catch {
            print("[agent-deck] Xbox RT haptics unavailable, using all-locality fallback: \(error)")
            rightTriggerEngine = nil
        }
    }

    private func stopAll() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        for player in activePlayers.values {
            try? player.stop(atTime: 0)
        }
        activePlayers.removeAll()
    }
}
