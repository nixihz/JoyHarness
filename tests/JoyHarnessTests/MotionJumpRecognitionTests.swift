import Foundation
import Testing
@testable import JoyHarness

struct MotionJumpRecognitionTests {
    @Test
    func recognizesOutwardDirectionAfterReboundAndReleaseAtTheStartingPose() {
        let trace = stroke(direction: unit(-1, 1), speed: 1.8, reboundSpeed: 1.8)
        let result = MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile)
        #expect(result.quadrant == .upperLeft)
        #expect(result.failure == nil)
    }

    @Test
    func aFasterReboundDoesNotBecomeTheOppositeTarget() {
        let trace = stroke(direction: unit(1, -1), speed: 1.8, reboundSpeed: 2.7)
        #expect(MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile).quadrant == .lowerRight)
    }

    @Test
    func aMuchLargerReturnIsCancelledInsteadOfBecomingTheOppositeTarget() {
        let trace = stroke(direction: unit(-1, 1), speed: 1.8, reboundSpeed: 12)
        let result = MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile)
        #expect(result.quadrant == nil)
        #expect(result.failure == .conflictingMotion)
    }

    @Test
    func usesElapsedSecondsInsteadOfNumberOfCallbacks() {
        let sparse = stroke(direction: unit(1, 1), speed: 1.8, step: 0.04)
        let dense = stroke(direction: unit(1, 1), speed: 1.8, step: 0.008)
        #expect(MotionJumpRecognizer.recognize(trace: sparse, profile: fixtureProfile).quadrant == .upperRight)
        #expect(MotionJumpRecognizer.recognize(trace: dense, profile: fixtureProfile).quadrant == .upperRight)
    }

    @Test
    func rejectsButtonPressWobbleEvenWhenItHasAClearDirection() {
        let trace = stroke(direction: unit(-1, -1), speed: 0.12)
        let result = MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile)
        #expect(result.quadrant == nil)
        #expect(result.failure == .insufficientAngle)
    }

    @Test
    func rejectsSlowDriftThatAccumulatesEnoughAngle() {
        let trace = MotionJumpTrace(samples: (0...50).map {
            .init(timestamp: Double($0) * 0.02, rotation: unit(-1, 1) * 0.25)
        })
        #expect(MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile).failure == .insufficientSpeed)
    }

    @Test
    func rejectsTheBoundaryBetweenTwoTargetsRatherThanGuessing() {
        var profile = fixtureProfile
        profile.parameters.directionTolerance = 60
        let trace = stroke(direction: unit(0, 1), speed: 1.8)
        #expect(MotionJumpRecognizer.recognize(trace: trace, profile: profile).failure == .unclearDirection)
    }

    @Test
    func rejectsDataGapsAndNonMonotonicTimestamps() {
        var interrupted = stroke(direction: unit(1, 1), speed: 1.8)
        interrupted.samples.removeAll { $0.timestamp > 0.16 && $0.timestamp < 0.34 }
        #expect(MotionJumpRecognizer.recognize(trace: interrupted, profile: fixtureProfile).failure == .dataGap)
        var duplicate = stroke(direction: unit(1, 1), speed: 1.8)
        duplicate.samples[8].timestamp = duplicate.samples[7].timestamp
        #expect(MotionJumpRecognizer.recognize(trace: duplicate, profile: fixtureProfile).failure == .invalidData)
    }

    @Test
    func rejectsNonFiniteSamplesAndExcessivelyLongHolds() {
        var corrupt = stroke(direction: unit(1, 1), speed: 1.8)
        corrupt.samples[5].rotation.x = .nan
        #expect(MotionJumpRecognizer.recognize(trace: corrupt, profile: fixtureProfile).failure == .invalidData)
        let overlong = MotionJumpTrace(samples: (0...300).map {
            .init(timestamp: Double($0) * 0.02, rotation: .zero)
        })
        #expect(MotionJumpRecognizer.recognize(trace: overlong, profile: fixtureProfile).failure == .tooLong)
    }

    @Test
    func rejectsTwoDeliberateStrokesInDifferentDirections() {
        let trace = MotionJumpTrace(samples: (0...50).map { index in
            let time = Double(index) * 0.02
            let velocity: SIMD3<Double>
            if time >= 0.08 && time < 0.32 {
                velocity = unit(-1, 1) * 1.8
            } else if time >= 0.5 && time < 0.74 {
                velocity = unit(1, 1) * 1.8
            } else {
                velocity = .zero
            }
            return .init(timestamp: time, rotation: velocity)
        })
        #expect(MotionJumpRecognizer.recognize(trace: trace, profile: fixtureProfile).failure == .conflictingMotion)
    }

    @Test
    func learnsLabelsFromRecordedMotionInsteadOfAssumingSensorAxes() throws {
        // These labels deliberately do not follow the default XY screen directions.
        let learnedDirections: [MotionJumpQuadrant: SIMD3<Double>] = [
            .upperLeft: unit(1, 0, 1), .upperRight: unit(-1, 0, 1),
            .lowerLeft: unit(1, 0, -1), .lowerRight: unit(-1, 0, -1)
        ]
        let positives = learnedDirections.mapValues { direction in
            [1.4, 1.6, 1.8].map { stroke(direction: direction, speed: $0, reboundSpeed: $0) }
        }
        let profile = try MotionJumpCalibrator.calibrate(positives: positives, negatives: ordinaryPresses)
        let freshTrace = stroke(direction: unit(1, 0.03, 1), speed: 1.5, reboundSpeed: 1.6, step: 0.016)
        #expect(MotionJumpRecognizer.recognize(trace: freshTrace, profile: profile).quadrant == .upperLeft)
        #expect(profile.templates[.upperLeft]!.z > 0.6)
    }

    @Test
    func calibrationAllowsANaturalTwentyDegreeVariationInsideTheSameQuadrant() throws {
        let profile = try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: ordinaryPresses)
        // The recorded upper-left reference is 135°. A fresh 115° movement remains
        // clearly upper-left; repeating the same training pose must not narrow its region.
        let angle = 115.0 * Double.pi / 180
        let freshTrace = stroke(direction: unit(cos(angle), sin(angle)), speed: 1.5)
        #expect(MotionJumpRecognizer.recognize(trace: freshTrace, profile: profile).quadrant == .upperLeft)
    }

    @Test
    func calibrationDoesNotRequireRepeatingTheRecordedL2PressAndReleaseTiming() throws {
        let positives = fixtureProfile.templates.mapValues { direction in
            [1.4, 1.6, 1.8].map {
                heldMovement(direction: direction, speed: $0, holdDuration: 0.4, movementStart: 0.08, movementEnd: 0.32)
            }
        }
        let profile = try MotionJumpCalibrator.calibrate(positives: positives, negatives: ordinaryPresses)
        // The same brief movement after taking time to aim and before releasing L2.
        let freshTrace = heldMovement(direction: unit(1, -1), speed: 1.5,
                                      holdDuration: 1.6, movementStart: 0.6, movementEnd: 0.84)
        #expect(MotionJumpRecognizer.recognize(trace: freshTrace, profile: profile).quadrant == .lowerRight)
    }

    @Test
    func oneOrdinaryPressAndOneReferencePerDirectionCanCreateACalibration() throws {
        let positives = fixtureProfile.templates.mapValues { direction in
            [stroke(direction: direction, speed: 1.4)]
        }
        let profile = try MotionJumpCalibrator.calibrate(positives: positives, negatives: [ordinaryPresses[0]])
        let freshTrace = stroke(direction: unit(0.9, 1), speed: 1.3)
        #expect(MotionJumpRecognizer.recognize(trace: freshTrace, profile: profile).quadrant == .upperRight)
    }

    @Test
    func allFourRegionsAllowThirtyDegreeVariationFromTheRecordedReference() throws {
        let profile = try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: ordinaryPresses)
        let freshDirections: [(MotionJumpQuadrant, SIMD3<Double>)] = [
            (.upperLeft, unit(-0.258819, 0.965926)),
            (.upperRight, unit(0.965926, 0.258819)),
            (.lowerLeft, unit(-0.965926, -0.258819)),
            (.lowerRight, unit(0.258819, -0.965926))
        ]
        for (expected, direction) in freshDirections {
            let trace = stroke(direction: direction, speed: 1.5)
            #expect(MotionJumpRecognizer.recognize(trace: trace, profile: profile).quadrant == expected)
        }
    }

    @Test
    func aLargeFastDemonstrationDoesNotRequireLaterMovementsToBeLargeOrFast() throws {
        let positives = fixtureProfile.templates.mapValues { direction in
            [stroke(direction: direction, speed: 2.4)]
        }
        let profile = try MotionJumpCalibrator.calibrate(positives: positives, negatives: [ordinaryPresses[2]])
        // A deliberate, slower movement totals about 8.6°, versus 33° during recording.
        let trace = heldMovement(direction: unit(1, 1), speed: 0.25,
                                 holdDuration: 1.2, movementStart: 0.2, movementEnd: 0.8)
        #expect(MotionJumpRecognizer.recognize(trace: trace, profile: profile).quadrant == .upperRight)
    }

    @Test
    func broaderCalibrationStillRejectsStillnessOrdinaryWobbleAndEqualDirectionBoundaries() throws {
        let profile = try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: ordinaryPresses)
        let still = heldMovement(direction: unit(1, 1), speed: 0,
                                 holdDuration: 1.2, movementStart: 0.2, movementEnd: 0.8)
        #expect(MotionJumpRecognizer.recognize(trace: still, profile: profile).failure == .insufficientAngle)
        let ordinary = stroke(direction: unit(0.95, 1), speed: 0.07)
        #expect(MotionJumpRecognizer.recognize(trace: ordinary, profile: profile).quadrant == nil)
        let boundary = stroke(direction: unit(0, 1), speed: 1.5)
        #expect(MotionJumpRecognizer.recognize(trace: boundary, profile: profile).failure == .unclearDirection)
    }

    @Test
    func existingProfilesKeepTheirExplicitThresholdsWhenDecoded() throws {
        var original = fixtureProfile
        original.parameters.directionTolerance = 8
        let decoded = try JSONDecoder().decode(MotionJumpProfile.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let angle = 115.0 * Double.pi / 180
        let outsideSavedTolerance = stroke(direction: unit(cos(angle), sin(angle)), speed: 1.5)
        #expect(MotionJumpRecognizer.recognize(trace: outsideSavedTolerance, profile: decoded).failure == .unclearDirection)
        let belowSavedSpeed = heldMovement(direction: unit(-1, 1), speed: 0.25,
                                           holdDuration: 1.2, movementStart: 0.2, movementEnd: 1)
        #expect(MotionJumpRecognizer.recognize(trace: belowSavedSpeed, profile: decoded).failure == .insufficientSpeed)
    }

    @Test
    func individualReferenceValidationRejectsMotionlessDirectionsButAcceptsOrdinaryStillness() throws {
        let still = heldMovement(direction: unit(1, 1), speed: 0,
                                 holdDuration: 0.6, movementStart: 0.1, movementEnd: 0.4)
        try MotionJumpCalibrator.validateSample(trace: still, quadrant: nil)
        #expect(throws: MotionJumpCalibrationError.invalidSample(.insufficientAngle)) {
            try MotionJumpCalibrator.validateSample(trace: still, quadrant: .upperLeft)
        }
        // A direction label never imposes a hard-coded sensor orientation.
        try MotionJumpCalibrator.validateSample(trace: stroke(direction: unit(0, 0, -1), speed: 0.5), quadrant: .upperLeft)
    }

    @Test
    func individualReferenceValidationRejectsGapsBeforeCalibrationCompletes() {
        var interrupted = stroke(direction: unit(1, 1), speed: 1.5)
        interrupted.samples.removeAll { $0.timestamp > 0.16 && $0.timestamp < 0.34 }
        #expect(throws: MotionJumpCalibrationError.invalidSample(.dataGap)) {
            try MotionJumpCalibrator.validateSample(trace: interrupted, quadrant: .upperRight)
        }
    }

    @Test
    func calibrationFailsWhenTwoDirectionLabelsContainTheSameMotion() {
        var positives = calibrationTraces
        positives[.upperRight] = positives[.upperLeft]
        #expect(throws: MotionJumpCalibrationError.overlappingDirections) {
            try MotionJumpCalibrator.calibrate(positives: positives, negatives: ordinaryPresses)
        }
    }

    @Test
    func calibrationFailsWhenAnOrdinaryPressLooksLikeARecordedGesture() {
        let negative = stroke(direction: unit(-1, 1), speed: 1.6, reboundSpeed: 1.6)
        #expect(throws: MotionJumpCalibrationError.overlappingOrdinaryMovement) {
            try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: [negative, negative, negative])
        }
    }

    @Test
    func calibrationDoesNotAcceptBriefOrMissingOrdinaryPressRecordings() {
        let tooShort = MotionJumpTrace(samples: [
            .init(timestamp: 0, rotation: .zero), .init(timestamp: 0.02, rotation: .zero)
        ])
        #expect(throws: MotionJumpCalibrationError.invalidSample(.insufficientSamples)) {
            try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: [tooShort, tooShort, tooShort])
        }
        #expect(throws: MotionJumpCalibrationError.missingSamples) {
            try MotionJumpCalibrator.calibrate(positives: calibrationTraces, negatives: [])
        }
    }

    private var fixtureProfile: MotionJumpProfile {
        MotionJumpProfile(parameters: .init(minimumAngle: 0.15, minimumPeakSpeed: 0.6,
            maximumDuration: 2, directionTolerance: 25, minimumMargin: 0.15), templates: [
                .upperLeft: unit(-1, 1), .upperRight: unit(1, 1),
                .lowerLeft: unit(-1, -1), .lowerRight: unit(1, -1)
            ])
    }

    private var calibrationTraces: [MotionJumpQuadrant: [MotionJumpTrace]] {
        fixtureProfile.templates.mapValues { direction in
            [1.4, 1.6, 1.8].map { stroke(direction: direction, speed: $0, reboundSpeed: $0) }
        }
    }

    private var ordinaryPresses: [MotionJumpTrace] {
        [0.04, 0.06, 0.08].map { stroke(direction: unit(-1, 1), speed: $0) }
    }

    private func unit(_ x: Double, _ y: Double, _ z: Double = 0) -> SIMD3<Double> {
        SIMD3(x, y, z) / sqrt(x * x + y * y + z * z)
    }

    private func heldMovement(direction: SIMD3<Double>, speed: Double, holdDuration: Double,
                              movementStart: Double, movementEnd: Double) -> MotionJumpTrace {
        MotionJumpTrace(samples: (0...Int(holdDuration / 0.02)).map { index in
            let time = Double(index) * 0.02
            let velocity = time >= movementStart && time < movementEnd ? direction * speed : .zero
            return .init(timestamp: time, rotation: velocity)
        })
    }

    /// A known outward pulse, optional natural return, then release while still.
    private func stroke(direction: SIMD3<Double>, speed: Double,
                        reboundSpeed: Double = 0, step: Double = 0.02) -> MotionJumpTrace {
        MotionJumpTrace(samples: (0...Int(0.9 / step)).map { index in
            let time = Double(index) * step
            let velocity: SIMD3<Double>
            if time >= 0.08 && time < 0.32 {
                velocity = direction * speed
            } else if time >= 0.42 && time < 0.66 {
                velocity = -direction * reboundSpeed
            } else {
                velocity = .zero
            }
            return .init(timestamp: time, rotation: velocity)
        })
    }
}
