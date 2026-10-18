import Foundation
import GameController

/// A motion-capable endpoint. Deliver samples on the main queue and restore
/// any sensor ownership acquired by start when stop is called.
protocol MotionJumpSensorSource: AnyObject {
    var id: String { get }
    var name: String { get }
    var triggerValue: Float { get }
    func start(receive: @escaping (MotionJumpSample) -> Void)
    func stop()
}

final class GameControllerMotionJumpSensorSource: MotionJumpSensorSource {
    private let controller: GCController
    private let motion: GCMotion
    private var previousHandler: GCMotionValueChangedHandler?
    private var wasActive = false
    private var generation: UUID?

    var id: String { ControllerHub.motionJumpDeviceID(controller) }
    var name: String { controller.vendorName ?? "DualSense" }
    var triggerValue: Float { controller.extendedGamepad?.leftTrigger.value ?? 0 }

    init?(_ controller: GCController) {
        guard ControllerFamily.detect(controller: controller) == .dualSense,
              let motion = controller.motion, motion.hasRotationRate else { return nil }
        self.controller = controller
        self.motion = motion
    }

    func belongs(to controller: GCController) -> Bool { self.controller === controller }

    func start(receive: @escaping (MotionJumpSample) -> Void) {
        guard generation == nil else { return }
        let generation = UUID()
        self.generation = generation
        let previous = motion.valueChangedHandler
        previousHandler = previous
        wasActive = motion.sensorsActive
        motion.valueChangedHandler = { [weak self] motion in
            let rate = motion.rotationRate
            let sample = MotionJumpSample(
                timestamp: ProcessInfo.processInfo.systemUptime,
                rotation: SIMD3(rate.x, rate.y, rate.z)
            )
            previous?(motion)
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == generation else { return }
                receive(sample)
            }
        }
        if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
    }

    func stop() {
        guard generation != nil else { return }
        generation = nil
        motion.valueChangedHandler = previousHandler
        previousHandler = nil
        if motion.sensorsRequireManualActivation { motion.sensorsActive = wasActive }
    }

    deinit { stop() }
}
