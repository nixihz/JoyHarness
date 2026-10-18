import CoreGraphics
import Foundation
import Testing
@testable import JoyHarness

private final class RecordedMotionSource: MotionJumpSensorSource {
    let id: String
    let name = "Recorded DualSense"
    var triggerValue: Float = 0
    var receive: ((MotionJumpSample) -> Void)?
    var starts = 0
    var stops = 0

    init(id: String = UUID().uuidString) { self.id = id }
    func start(receive: @escaping (MotionJumpSample) -> Void) {
        starts += 1
        self.receive = receive
    }
    func stop() { stops += 1; receive = nil }
    func emit(_ timestamp: TimeInterval, _ rotation: SIMD3<Double>) {
        receive?(.init(timestamp: timestamp, rotation: rotation))
    }
}

@MainActor
struct MotionJumpCoordinatorTests {
    @MainActor private final class Rig {
        let suite = "MotionJumpCoordinatorTests.\(UUID().uuidString)"
        let settings: MotionJumpSettings
        let coordinator: MotionJumpCoordinator
        let source = RecordedMotionSource()
        var time = ProcessInfo.processInfo.systemUptime + 60
        var target = MotionJumpPointerTarget(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800))
        var jumps: [(MotionJumpQuadrant, MotionJumpPointerTarget)] = []

        init(withProfile: Bool = true) {
            let defaults = UserDefaults(suiteName: suite)!
            settings = MotionJumpSettings(userDefaults: defaults)
            if withProfile { settings.apply(profile: MotionJumpCoordinatorTests.profile) }
            coordinator = MotionJumpCoordinator(settings: settings)
            coordinator.capturePointerTarget = { [weak self] in self?.target }
            coordinator.jumpPointer = { [weak self] quadrant, target in
                self?.jumps.append((quadrant, target))
                return true
            }
            coordinator.updateSources([source])
        }

        deinit {
            coordinator.stop()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        @discardableResult
        func input(_ down: Bool, source: RecordedMotionSource? = nil, conflict: Bool = false) -> Bool {
            let source = source ?? self.source
            source.triggerValue = down ? 1 : 0
            return coordinator.handleInput(deviceID: source.id, input: .init(
                triggerValue: source.triggerValue, hasConflictingInput: conflict,
                timestamp: time, allowsGesture: true
            ))
        }

        func begin(source: RecordedMotionSource? = nil) {
            let source = source ?? self.source
            source.emit(time, .zero)
            input(true, source: source)
        }

        /// Labels are explicitly supplied by the intended task, never by the
        /// recognizer. The vectors are an independent, fixed sensor fixture.
        func gesture(_ label: MotionJumpQuadrant?, source: RecordedMotionSource? = nil,
                     speed: Double = 1.8, corrupt: Bool = false, release: Bool = true) {
            let source = source ?? self.source
            begin(source: source)
            stroke(label, source: source, speed: speed, corrupt: corrupt)
            if release { input(false, source: source); time += 0.1 }
        }

        func stroke(_ label: MotionJumpQuadrant?, source: RecordedMotionSource? = nil,
                    speed: Double = 1.8, corrupt: Bool = false) {
            let source = source ?? self.source
            let start = time
            for index in 1...18 {
                time = start + Double(index) * 0.02
                var velocity = label.map { MotionJumpCoordinatorTests.direction($0) * (index <= 11 ? speed : 0) } ?? .zero
                if corrupt && index == 8 { velocity.x = .nan }
                source.emit(time, velocity)
            }
        }

        func completeTest() {
            for label in coordinator.testPrompts { gesture(label) }
        }

        func recordReferences(lastDirection: MotionJumpQuadrant = .lowerRight) {
            coordinator.startCalibration()
            gesture(nil)
            gesture(.upperLeft)
            gesture(.upperRight)
            gesture(.lowerLeft)
            gesture(lastDirection)
        }
    }

    private static func direction(_ label: MotionJumpQuadrant) -> SIMD3<Double> {
        let component = 1 / sqrt(2.0)
        switch label {
        case .upperLeft: return SIMD3(-component, component, 0)
        case .upperRight: return SIMD3(component, component, 0)
        case .lowerLeft: return SIMD3(-component, -component, 0)
        case .lowerRight: return SIMD3(component, -component, 0)
        }
    }

    private static var profile: MotionJumpProfile {
        .init(parameters: .init(minimumAngle: 0.12, minimumPeakSpeed: 0.5,
            maximumDuration: 1.5, directionTolerance: 25, minimumMargin: 0.15),
            templates: Dictionary(uniqueKeysWithValues: MotionJumpQuadrant.allCases.map { ($0, direction($0)) }))
    }

    @Test func pointerWaitsForReleaseAndKeepsTheDisplayChosenAtPress() {
        let rig = Rig()
        let originalTarget = rig.target
        rig.gesture(.upperRight, release: false)
        #expect(rig.jumps.isEmpty)
        rig.target = .init(displayID: 2, bounds: CGRect(x: -1400, y: 100, width: 1400, height: 900))
        rig.input(false)
        #expect(rig.jumps.count == 1)
        #expect(rig.jumps.first?.0 == .upperRight)
        #expect(rig.jumps.first?.1 == originalTarget)
        rig.input(false)
        #expect(rig.jumps.count == 1)
    }

    @Test func conflictDuringHoldCancelsUntilRelease() {
        let rig = Rig()
        rig.begin()
        rig.input(true, conflict: true)
        rig.stroke(.upperLeft)
        rig.input(false)
        #expect(rig.jumps.isEmpty)
        rig.time += 0.1
        rig.gesture(.upperLeft)
        #expect(rig.jumps.map(\.0) == [.upperLeft])
    }

    @Test func disconnectNativeModeAndStopCancelPendingPointerJumps() {
        for interruption in 0..<3 {
            let rig = Rig()
            rig.gesture(.lowerRight, release: false)
            switch interruption {
            case 0: rig.coordinator.updateSources([])
            case 1: rig.coordinator.setOperationMode(.native)
            default: rig.coordinator.stop()
            }
            rig.input(false)
            #expect(rig.jumps.isEmpty)
            #expect(rig.source.stops == 1)
            if interruption == 1 {
                rig.coordinator.setOperationMode(.mapping)
                rig.time += 0.1
                rig.gesture(.lowerLeft)
                #expect(rig.jumps.map(\.0) == [.lowerLeft])
            }
        }
    }

    @Test func oldSubscriptionCannotSupplySamplesAfterADeviceReplacement() throws {
        let rig = Rig()
        let oldReceive = try #require(rig.source.receive)
        let replacement = RecordedMotionSource(id: rig.source.id)
        rig.coordinator.updateSources([replacement])
        oldReceive(.init(timestamp: rig.time, rotation: .zero))
        // If a queued sample from the retired source leaked through, this
        // press plus the following valid samples would incorrectly jump.
        rig.input(true, source: replacement)
        rig.stroke(.upperLeft, source: replacement)
        rig.input(false, source: replacement)
        #expect(rig.jumps.isEmpty)
        rig.time += 0.1
        rig.gesture(.upperLeft, source: replacement)
        #expect(rig.jumps.map(\.0) == [.upperLeft])
        #expect(rig.source.stops == 1)
    }

    @Test func enteringMappingModeWithL2HeldRequiresAFreshPress() {
        let rig = Rig()
        rig.coordinator.setOperationMode(.native)
        rig.source.triggerValue = 1
        rig.coordinator.setOperationMode(.mapping)
        rig.gesture(.upperLeft)
        #expect(rig.jumps.isEmpty)
        rig.gesture(.upperLeft)
        #expect(rig.jumps.map(\.0) == [.upperLeft])
    }

    @Test func oneOrdinaryPressAndFourReferencesCanBeAppliedWithoutAnExam() {
        let rig = Rig(withProfile: false)
        rig.coordinator.startCalibration()
        rig.gesture(nil)
        for label in MotionJumpQuadrant.allCases { rig.gesture(label) }
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.draft != nil)
        #expect(rig.coordinator.canApply)
        #expect(rig.settings.profile == nil)
        #expect(rig.jumps.isEmpty)
        let recordedDraft = rig.coordinator.draft
        rig.coordinator.applyCalibration()
        #expect(rig.settings.profile == recordedDraft)
        #expect(rig.settings.enabled)
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.previewQuadrant == nil)
        #expect(rig.coordinator.lastResultText.isEmpty)
    }

    @Test func changingParametersKeepsAValidDraftApplicableAndDisarmsActualPointerTest() {
        let rig = Rig()
        rig.coordinator.startTesting()
        rig.completeTest()
        #expect(rig.coordinator.canApply)
        rig.coordinator.isTestingActualPointer = true
        var changed = Self.profile.parameters
        changed.minimumAngle = 0.16
        rig.coordinator.updateParameters(changed)
        #expect(rig.coordinator.canApply)
        #expect(rig.coordinator.phase == .idle)
        #expect(!rig.coordinator.isTestingActualPointer)
        #expect(rig.settings.profile?.parameters.minimumAngle == 0.12)
        rig.coordinator.applyCalibration()
        #expect(rig.settings.profile?.parameters.minimumAngle == 0.16)
    }

    @Test func overlappingReferenceCanBeReplacedWithoutRepeatingOtherDirections() throws {
        let rig = Rig(withProfile: false)
        // The final label was accidentally recorded with the same movement as upper-left.
        rig.recordReferences(lastDirection: .upperLeft)
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.draft == nil)
        #expect(!rig.coordinator.canApply)
        #expect(rig.coordinator.recordedQuadrants == Set(MotionJumpQuadrant.allCases))
        #expect(rig.coordinator.hasOrdinarySample)

        rig.coordinator.rerecordGesture(.lowerRight)
        rig.gesture(.lowerRight)
        let profile = try #require(rig.coordinator.draft)
        for quadrant in MotionJumpQuadrant.allCases {
            let actual = try #require(profile.templates[quadrant])
            #expect(abs(actual.x - Self.direction(quadrant).x) < 0.001)
            #expect(abs(actual.y - Self.direction(quadrant).y) < 0.001)
        }
        #expect(rig.coordinator.canApply)
        rig.coordinator.applyCalibration()
        #expect(rig.settings.profile == profile)
    }

    @Test func corruptRerecordKeepsCurrentStepAndOtherReferences() throws {
        let rig = Rig(withProfile: false)
        rig.recordReferences()
        let original = try #require(rig.coordinator.draft)
        rig.coordinator.rerecordGesture(.upperRight)
        let progress = rig.coordinator.progressText
        rig.gesture(.upperRight, corrupt: true)
        #expect(rig.coordinator.phase == .recording)
        #expect(rig.coordinator.progressText == progress)
        #expect(rig.coordinator.recordedQuadrants == Set(MotionJumpQuadrant.allCases))
        #expect(rig.coordinator.draft == original)
        #expect(!rig.coordinator.canApply)
        rig.gesture(.upperRight, speed: 1.5)
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.canApply)
        #expect(rig.coordinator.draft?.templates[.lowerLeft] == original.templates[.lowerLeft])
    }

    @Test func missingDirectionMovementRetriesOnlyThatStep() {
        let rig = Rig(withProfile: false)
        rig.coordinator.startCalibration()
        rig.gesture(nil)
        let directionPrompt = rig.coordinator.progressText
        rig.gesture(nil)
        #expect(rig.coordinator.progressText == directionPrompt)
        #expect(rig.coordinator.hasOrdinarySample)
        #expect(rig.coordinator.recordedQuadrants.isEmpty)
        for direction in MotionJumpQuadrant.allCases { rig.gesture(direction) }
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.canApply)
    }

    @Test func ordinaryReferenceCanBeReplacedWithoutRepeatingDirections() throws {
        let rig = Rig(withProfile: false)
        rig.recordReferences()
        let original = try #require(rig.coordinator.draft)
        rig.coordinator.rerecordGesture(nil)
        rig.gesture(nil)
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.hasOrdinarySample)
        #expect(rig.coordinator.draft?.templates == original.templates)
        #expect(rig.coordinator.canApply)
    }

    @Test func cancellingRerecordWithL2HeldPreservesDraftAndCancelsPendingJump() throws {
        let rig = Rig()
        let appliedProfile = rig.settings.profile
        rig.recordReferences()
        let originalDraft = try #require(rig.coordinator.draft)
        rig.coordinator.rerecordGesture(.upperRight)
        rig.gesture(.lowerRight, release: false)
        rig.coordinator.cancelRecording()
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.draft == originalDraft)
        #expect(rig.coordinator.canApply)
        #expect(rig.coordinator.recordedQuadrants == Set(MotionJumpQuadrant.allCases))
        #expect(rig.coordinator.hasOrdinarySample)
        #expect(rig.settings.profile == appliedProfile)
        rig.input(false)
        #expect(rig.jumps.isEmpty)
        rig.time += 0.1
        rig.gesture(.upperLeft)
        #expect(rig.jumps.map(\.0) == [.upperLeft])
    }

    @Test func cancellingANewRecordingStillDiscardsItsIncompleteDraft() {
        let rig = Rig()
        let appliedProfile = rig.settings.profile
        rig.coordinator.startCalibration()
        rig.gesture(nil)
        rig.coordinator.cancelRecording()
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.coordinator.draft == nil)
        #expect(rig.coordinator.recordedQuadrants.isEmpty)
        #expect(!rig.coordinator.hasOrdinarySample)
        #expect(rig.settings.profile == appliedProfile)
    }

    @Test func testMistakesAndEndingATestDoNotDiscardOrLockTheDraft() throws {
        let rig = Rig(withProfile: false)
        rig.recordReferences()
        let original = try #require(rig.coordinator.draft)
        rig.coordinator.startTesting()
        #expect(rig.coordinator.canApply)
        rig.coordinator.isTestingActualPointer = true
        // Every requested gesture receives an intentionally wrong direction.
        for label in rig.coordinator.testPrompts {
            rig.gesture(label == .lowerRight ? .upperLeft : .lowerRight)
        }
        #expect(rig.coordinator.isTestComplete)
        #expect(rig.coordinator.canApply)
        #expect(!rig.coordinator.validationSummary.isEmpty)
        rig.coordinator.endTesting()
        #expect(rig.coordinator.phase == .idle)
        #expect(!rig.coordinator.isTestingActualPointer)
        #expect(rig.coordinator.draft == original)
        #expect(rig.settings.profile == nil)
        rig.coordinator.applyCalibration()
        #expect(rig.settings.profile == original)
    }

    @Test func triggerPressureChangesDoNotSplitOneRecordedGesture() {
        let rig = Rig(withProfile: false)
        rig.coordinator.startCalibration()
        rig.gesture(nil)
        rig.begin()
        let progress = rig.coordinator.progressText
        rig.stroke(.upperLeft)
        for pressure in [Float(0.54), 0.4, 0.56] {
            rig.source.triggerValue = pressure
            _ = rig.coordinator.handleInput(deviceID: rig.source.id, input: .init(
                triggerValue: pressure, hasConflictingInput: false,
                timestamp: rig.time, allowsGesture: true
            ))
            #expect(rig.coordinator.progressText == progress)
            #expect(rig.coordinator.recordedQuadrants.isEmpty)
        }
        rig.source.triggerValue = 0.05
        _ = rig.coordinator.handleInput(deviceID: rig.source.id, input: .init(
            triggerValue: 0.05, hasConflictingInput: false,
            timestamp: rig.time, allowsGesture: true
        ))
        #expect(rig.coordinator.recordedQuadrants == [.upperLeft])
        #expect(rig.coordinator.progressText != progress)
    }

    @Test func partiallyHeldTriggerAtSensorStartRequiresAFullRelease() {
        let rig = Rig(withProfile: false)
        rig.source.triggerValue = 0.4
        rig.coordinator.startCalibration()
        rig.begin()
        rig.stroke(nil)
        rig.input(false)
        #expect(!rig.coordinator.hasOrdinarySample)
        rig.time += 0.1
        rig.gesture(nil)
        #expect(rig.coordinator.hasOrdinarySample)
    }

    @Test func anotherControllerUsesAppliedProfileWhileSelectedControllerTestsADraft() {
        let rig = Rig()
        let other = RecordedMotionSource()
        rig.coordinator.updateSources([rig.source, other])
        var stricter = Self.profile.parameters
        stricter.minimumAngle = 2
        rig.coordinator.updateParameters(stricter)
        rig.coordinator.startTesting()
        rig.gesture(.upperRight, source: other)
        #expect(rig.jumps.map(\.0) == [.upperRight])
        #expect(rig.coordinator.progressText.contains("1 / 6"))
    }

    @Test func invalidNegativeTrialMustBeRetriedWithoutAdvancingThePrompt() throws {
        let rig = Rig()
        rig.coordinator.startTesting()
        let prompts = rig.coordinator.testPrompts
        let ordinaryIndex = try #require(prompts.firstIndex { $0 == nil })
        for label in prompts.prefix(ordinaryIndex) { rig.gesture(label) }
        let progressBefore = rig.coordinator.progressText
        rig.gesture(nil, corrupt: true)
        #expect(rig.coordinator.progressText == progressBefore)
        #expect(rig.coordinator.canApply)
        rig.gesture(nil)
        #expect(rig.coordinator.lastResultText.contains("Correct") || rig.coordinator.lastResultText.contains("正确"))
        for label in prompts.dropFirst(ordinaryIndex + 1) { rig.gesture(label) }
        #expect(rig.coordinator.canApply)
    }

    @Test func actualPointerTestReportsUnavailableDisplayInsteadOfClaimingItMoved() throws {
        let rig = Rig()
        rig.coordinator.capturePointerTarget = { nil }
        rig.coordinator.startTesting()
        rig.coordinator.isTestingActualPointer = true
        let prompts = rig.coordinator.testPrompts
        let directionIndex = try #require(prompts.firstIndex { $0 != nil })
        for label in prompts.prefix(directionIndex) { rig.gesture(label) }
        rig.gesture(prompts[directionIndex])
        #expect(rig.jumps.isEmpty)
        #expect(rig.coordinator.previewQuadrant == prompts[directionIndex])
        #expect(rig.coordinator.lastResultText.contains("无法移动光标") ||
                rig.coordinator.lastResultText.contains("could not move the pointer"))
    }

    @Test func wrongDirectionShowsExpectedAndObservedLabelsAndStopClearsThePreview() throws {
        let rig = Rig()
        rig.coordinator.startTesting()
        let prompts = rig.coordinator.testPrompts
        let directionIndex = try #require(prompts.firstIndex { $0 != nil })
        for label in prompts.prefix(directionIndex) { rig.gesture(label) }
        let expected = try #require(prompts[directionIndex])
        let wrong: MotionJumpQuadrant = expected == .lowerRight ? .upperLeft : .lowerRight
        rig.gesture(wrong)
        #expect(rig.coordinator.lastResultText.contains(expected.displayName))
        #expect(rig.coordinator.lastResultText.contains(wrong.displayName))
        #expect(rig.coordinator.previewQuadrant == wrong)
        rig.coordinator.isTestingActualPointer = true
        rig.coordinator.stopSession()
        #expect(rig.coordinator.previewQuadrant == nil)
        #expect(rig.coordinator.lastResultText.isEmpty)
        #expect(!rig.coordinator.isTestingActualPointer)
    }

    @Test func microphoneIsolationStopsSensorsAndRejectsOldGenerationGyroAfterRecovery() throws {
        let rig = Rig()
        let oldDelivery = try #require(rig.source.receive)
        #expect(rig.source.starts == 1)
        rig.coordinator.setDualSenseMicrophoneIsolation(true)
        #expect(rig.source.stops == 1)
        #expect(rig.source.receive == nil)
        rig.coordinator.startCalibration()
        #expect(rig.coordinator.phase == .idle)
        #expect(rig.source.starts == 1)
        rig.coordinator.setDualSenseMicrophoneIsolation(false)
        #expect(rig.source.starts == 2)

        // An obsolete OS callback arrives after recovery with a future stamp.
        // If accepted, it makes the next genuine L2 edge fail the freshness
        // check and poisons the stationary bias used by that gesture.
        oldDelivery(.init(timestamp: rig.time + 100, rotation: SIMD3(100, -100, 100)))
        rig.gesture(.upperLeft)
        #expect(rig.jumps.map(\.0) == [.upperLeft])
    }
}
