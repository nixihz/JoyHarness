import Foundation

enum MotionJumpQuadrant: String, CaseIterable, Codable, Identifiable {
    case upperLeft, upperRight, lowerLeft, lowerRight

    var id: String { rawValue }
    var title: String { displayName }
    var displayName: String {
        switch self {
        case .upperLeft: return L10n.text("左上", "Upper left")
        case .upperRight: return L10n.text("右上", "Upper right")
        case .lowerLeft: return L10n.text("左下", "Lower left")
        case .lowerRight: return L10n.text("右下", "Lower right")
        }
    }
}

struct MotionJumpSample: Equatable {
    var timestamp: TimeInterval
    /// Angular velocity in radians per second, in the controller's coordinate system.
    var rotation: SIMD3<Double>
}

struct MotionJumpTrace: Equatable {
    var samples: [MotionJumpSample]
}

struct MotionJumpParameters: Codable, Equatable {
    // These are input bounds, not a prevalidated gesture preset.
    static let minimumAngleRange = 0.005...Double.pi
    static let minimumPeakSpeedRange = 0.02...30.0
    static let maximumDurationRange = 0.1...5.0
    static let directionToleranceRange = 1.0...80.0
    static let minimumMarginRange = 0.001...1.0

    var minimumAngle: Double
    var minimumPeakSpeed: Double
    var maximumDuration: TimeInterval
    /// Maximum angle from a learned direction, in degrees.
    var directionTolerance: Double
    /// Required difference between the best and second-best cosine similarity.
    var minimumMargin: Double

    var isValid: Bool {
        Self.minimumAngleRange.contains(minimumAngle)
            && Self.minimumPeakSpeedRange.contains(minimumPeakSpeed)
            && Self.maximumDurationRange.contains(maximumDuration)
            && Self.directionToleranceRange.contains(directionTolerance)
            && Self.minimumMarginRange.contains(minimumMargin)
    }
}

struct MotionJumpProfile: Codable, Equatable {
    var version: Int = 1
    var parameters: MotionJumpParameters
    var templates: [MotionJumpQuadrant: SIMD3<Double>]

    var isValid: Bool {
        version == 1 && parameters.isValid
            && templates.count == MotionJumpQuadrant.allCases.count
            && MotionJumpQuadrant.allCases.allSatisfy { quadrant in
                guard let direction = templates[quadrant] else { return false }
                let magnitude = motionLength(direction)
                return magnitude.isFinite && abs(magnitude - 1) < 0.001
            }
    }
}

enum MotionJumpFailure: String, Error, Equatable {
    case insufficientSamples, invalidData, dataGap, tooLong
    case insufficientAngle, insufficientSpeed, unclearDirection, conflictingMotion, invalidProfile

    var message: String {
        switch self {
        case .insufficientSamples: return L10n.text("按住 L2 的时间太短，请重新录制。", "Hold L2 a little longer and try again.")
        case .invalidData: return L10n.text("体感数据无效，请重新录制。", "Motion data was invalid. Try again.")
        case .dataGap: return L10n.text("体感数据中断，本次已取消。", "Motion data was interrupted. This gesture was cancelled.")
        case .tooLong: return L10n.text("本次动作时间过长。", "This gesture took too long.")
        case .insufficientAngle: return L10n.text("动作幅度不足。", "The movement was too small.")
        case .insufficientSpeed: return L10n.text("动作速度不足。", "The movement was too slow.")
        case .unclearDirection: return L10n.text("方向不明确，请重新尝试。", "The direction was unclear. Try again.")
        case .conflictingMotion: return L10n.text("检测到多个冲突方向，本次已取消。", "Conflicting movements were detected. This gesture was cancelled.")
        case .invalidProfile: return L10n.text("请先录制并应用个人校准。", "Record and apply your calibration first.")
        }
    }
}

struct MotionJumpRecognition: Equatable {
    let quadrant: MotionJumpQuadrant?
    let failure: MotionJumpFailure?

    var message: String {
        if let quadrant {
            return L10n.text("已识别为\(quadrant.displayName)", "Recognized as \(quadrant.displayName)")
        }
        return failure?.message ?? MotionJumpFailure.unclearDirection.message
    }
}

enum MotionJumpRecognizer {
    static let maximumSampleGap: TimeInterval = 0.12
    static let minimumTraceDuration: TimeInterval = 0.1
    static let maximumTraceDuration: TimeInterval = 5

    static func recognize(trace: MotionJumpTrace, profile: MotionJumpProfile) -> MotionJumpRecognition {
        guard profile.isValid else { return .init(quadrant: nil, failure: .invalidProfile) }
        do {
            let feature = try MotionJumpFeature.extract(trace)
            let parameters = profile.parameters
            guard feature.duration <= parameters.maximumDuration else { throw MotionJumpFailure.tooLong }
            guard feature.angle >= parameters.minimumAngle else { throw MotionJumpFailure.insufficientAngle }
            guard feature.peakSpeed >= parameters.minimumPeakSpeed else { throw MotionJumpFailure.insufficientSpeed }
            guard !feature.hasConflictingMotion else { throw MotionJumpFailure.conflictingMotion }
            let scores = MotionJumpQuadrant.allCases.map { quadrant in
                (quadrant, motionDot(feature.direction, profile.templates[quadrant]!))
            }.sorted { $0.1 > $1.1 }
            let tolerance = cos(parameters.directionTolerance * .pi / 180)
            guard scores[0].1 >= tolerance,
                  scores[0].1 - scores[1].1 >= parameters.minimumMargin else {
                throw MotionJumpFailure.unclearDirection
            }
            return .init(quadrant: scores[0].0, failure: nil)
        } catch let failure as MotionJumpFailure {
            return .init(quadrant: nil, failure: failure)
        } catch {
            return .init(quadrant: nil, failure: .invalidData)
        }
    }
}

enum MotionJumpCalibrationError: Error, LocalizedError, Equatable {
    case missingSamples
    case invalidSample(MotionJumpFailure)
    case inconsistentDirection(MotionJumpQuadrant)
    case overlappingDirections
    case overlappingOrdinaryMovement

    var errorDescription: String? { message }
    var message: String {
        switch self {
        case .missingSamples:
            return L10n.text("请为四个方向和普通 L2 按放分别录制一次。", "Record one reference for each direction and one ordinary L2 press.")
        case .invalidSample(let failure): return failure.message
        case .inconsistentDirection(let quadrant):
            return L10n.text("\(quadrant.displayName)的动作差异较大，请重新录制这一组。", "The \(quadrant.displayName) gestures differ too much. Record this group again.")
        case .overlappingDirections:
            return L10n.text("几个方向的动作太接近，暂时无法可靠区分，请重新录制。", "Some directions are too similar to distinguish reliably. Record again.")
        case .overlappingOrdinaryMovement:
            return L10n.text("甩动与普通按放太接近，无法生成可靠阈值，请重新录制。", "Gestures are too similar to ordinary presses to suggest reliable thresholds. Record again.")
        }
    }
}

enum MotionJumpCalibrator {
    static let requiredSamplesPerDirection = 1
    static let requiredNegativeSamples = 1

    /// Validate a recording immediately, before replacing the previous reference.
    /// The quadrant is a user-provided label, not a prescribed controller axis.
    static func validateSample(trace: MotionJumpTrace, quadrant: MotionJumpQuadrant?) throws {
        do {
            let feature = try MotionJumpFeature.extract(trace)
            if quadrant != nil {
                guard feature.angle >= MotionJumpParameters.minimumAngleRange.lowerBound else {
                    throw MotionJumpFailure.insufficientAngle
                }
                guard !feature.hasConflictingMotion else { throw MotionJumpFailure.conflictingMotion }
            }
        } catch let failure as MotionJumpFailure {
            throw MotionJumpCalibrationError.invalidSample(failure)
        }
    }

    static func calibrate(
        positives: [MotionJumpQuadrant: [MotionJumpTrace]],
        negatives: [MotionJumpTrace]
    ) throws -> MotionJumpProfile {
        guard negatives.count >= requiredNegativeSamples,
              MotionJumpQuadrant.allCases.allSatisfy({ (positives[$0]?.count ?? 0) >= requiredSamplesPerDirection }) else {
            throw MotionJumpCalibrationError.missingSamples
        }
        var features: [MotionJumpQuadrant: [MotionJumpFeature]] = [:]
        var negativeFeatures: [MotionJumpFeature] = []
        do {
            for quadrant in MotionJumpQuadrant.allCases {
                try positives[quadrant]!.forEach { try validateSample(trace: $0, quadrant: quadrant) }
                features[quadrant] = try positives[quadrant]!.map(MotionJumpFeature.extract)
            }
            negativeFeatures = try negatives.map(MotionJumpFeature.extract)
        } catch let failure as MotionJumpFailure {
            throw MotionJumpCalibrationError.invalidSample(failure)
        }

        var templates: [MotionJumpQuadrant: SIMD3<Double>] = [:]
        var maximumDeviation = 0.0
        for quadrant in MotionJumpQuadrant.allCases {
            let group = features[quadrant]!
            let sum = group.reduce(SIMD3<Double>.zero) { $0 + $1.direction }
            guard motionLength(sum) > 0.1,
                  group.allSatisfy({ !$0.hasConflictingMotion && $0.angle > 0 }) else {
                throw MotionJumpCalibrationError.inconsistentDirection(quadrant)
            }
            let template = sum / motionLength(sum)
            templates[quadrant] = template
            let deviation = group.map { acos(motionClampCosine(motionDot($0.direction, template))) * 180 / .pi }.max()!
            guard deviation <= 35 else { throw MotionJumpCalibrationError.inconsistentDirection(quadrant) }
            maximumDeviation = max(maximumDeviation, deviation)
        }

        let directions = MotionJumpQuadrant.allCases
        var minimumSeparation = 180.0
        for index in directions.indices {
            for other in directions.indices where other > index {
                let cosine = motionDot(templates[directions[index]]!, templates[directions[other]]!)
                minimumSeparation = min(minimumSeparation, acos(motionClampCosine(cosine)) * 180 / .pi)
            }
        }
        // Leave room for a fresh gesture to vary without accepting the boundary between labels.
        guard minimumSeparation > maximumDeviation * 2 + 10 else {
            throw MotionJumpCalibrationError.overlappingDirections
        }

        let allPositiveFeatures = directions.flatMap { features[$0]! }
        let minimumAngle = allPositiveFeatures.map(\.angle).min()!
        let minimumSpeed = allPositiveFeatures.map(\.peakSpeed).min()!
        let maximumNegativeAngle = negativeFeatures.map(\.angle).max()!
        let maximumNegativeSpeed = negativeFeatures.map(\.peakSpeed).max()!
        func threshold(positive: Double, negative: Double, floor: Double,
                       reserve: Double, range: ClosedRange<Double>) -> Double {
            // Learn how much movement is ordinary noise. A large demonstration must
            // not require subsequent gestures to be equally large or equally fast.
            // Keep a positive-sample margin, then check ordinary presses below so
            // overlapping recordings fail explicitly rather than raising the threshold.
            let candidate = min(max(floor, negative * 1.5 + reserve), positive * 0.8)
            return min(max(candidate, range.lowerBound), range.upperBound)
        }
        let minimumPositiveMargin = directions.flatMap { quadrant in
            features[quadrant]!.map { feature in
                let correctScore = motionDot(feature.direction, templates[quadrant]!)
                let alternateScore = directions.filter { $0 != quadrant }.map { motionDot(feature.direction, templates[$0]!) }.max()!
                return correctScore - alternateScore
            }
        }.min()!
        let directionMargin = 0.03
        guard minimumPositiveMargin > directionMargin * 2 else {
            throw MotionJumpCalibrationError.overlappingDirections
        }
        let profile = MotionJumpProfile(parameters: .init(
            minimumAngle: threshold(positive: minimumAngle, negative: maximumNegativeAngle,
                                    floor: 0.015, reserve: 0.005, range: MotionJumpParameters.minimumAngleRange),
            minimumPeakSpeed: threshold(positive: minimumSpeed, negative: maximumNegativeSpeed,
                                        floor: 0.08, reserve: 0.02, range: MotionJumpParameters.minimumPeakSpeedRange),
            // L2 timing is not part of the direction reference. Keep the global safety
            // cap, but allow time to aim before moving and to settle before release.
            maximumDuration: MotionJumpRecognizer.maximumTraceDuration,
            directionTolerance: 70,
            minimumMargin: directionMargin
        ), templates: templates)

        for quadrant in directions {
            guard positives[quadrant]!.allSatisfy({ MotionJumpRecognizer.recognize(trace: $0, profile: profile).quadrant == quadrant }) else {
                throw MotionJumpCalibrationError.inconsistentDirection(quadrant)
            }
        }
        // This is a consistency check of the training set, never an accuracy measurement.
        guard negatives.allSatisfy({ MotionJumpRecognizer.recognize(trace: $0, profile: profile).quadrant == nil }) else {
            throw MotionJumpCalibrationError.overlappingOrdinaryMovement
        }
        return profile
    }
}

private struct MotionJumpFeature {
    let direction: SIMD3<Double>
    let angle: Double
    let peakSpeed: Double
    let duration: TimeInterval
    let hasConflictingMotion: Bool

    private struct Stroke {
        var displacement = SIMD3<Double>.zero
        var peakSpeed = 0.0
        var angle: Double { motionLength(displacement) }
    }

    static func extract(_ trace: MotionJumpTrace) throws -> MotionJumpFeature {
        let samples = trace.samples
        guard samples.count >= 3 else { throw MotionJumpFailure.insufficientSamples }
        guard samples.allSatisfy({ $0.timestamp.isFinite && $0.rotation.x.isFinite && $0.rotation.y.isFinite && $0.rotation.z.isFinite }) else {
            throw MotionJumpFailure.invalidData
        }
        let duration = samples.last!.timestamp - samples.first!.timestamp
        guard duration >= MotionJumpRecognizer.minimumTraceDuration else { throw MotionJumpFailure.insufficientSamples }
        guard duration <= MotionJumpRecognizer.maximumTraceDuration else { throw MotionJumpFailure.tooLong }
        var strokes: [Stroke] = []
        var current = Stroke()
        var idleDuration = 0.0
        for index in 1..<samples.count {
            let dt = samples[index].timestamp - samples[index - 1].timestamp
            guard dt > 0 else { throw MotionJumpFailure.invalidData }
            guard dt <= MotionJumpRecognizer.maximumSampleGap else { throw MotionJumpFailure.dataGap }
            let velocity = (samples[index - 1].rotation + samples[index].rotation) / 2
            let speed = motionLength(velocity)
            guard speed.isFinite else { throw MotionJumpFailure.invalidData }
            // Integrate actual timestamp intervals. A reversal starts a separate stroke;
            // integrating to release would erase the outward movement on natural rebound.
            if current.angle > 0.000001 && speed > 0.000001
                && motionDot(velocity, current.displacement) < speed * current.angle * 0.3 {
                strokes.append(current)
                current = Stroke()
            }
            if speed < 0.000001 {
                idleDuration += dt
                if idleDuration >= 0.1 && current.angle > 0 {
                    strokes.append(current)
                    current = Stroke()
                }
            } else {
                idleDuration = 0
            }
            current.displacement += velocity * dt
            current.peakSpeed = max(current.peakSpeed, speed)
        }
        if current.angle > 0 { strokes.append(current) }
        guard let largest = strokes.map(\.angle).max(), largest > 0 else {
            return .init(direction: .zero, angle: 0, peakSpeed: 0, duration: duration, hasConflictingMotion: false)
        }
        let peak = strokes.map(\.peakSpeed).max()!
        // Ignore tiny button-press noise, then retain the first substantial outward stroke.
        // Later, opposite strokes are recoil, never a new target direction.
        guard let primaryIndex = strokes.firstIndex(where: { $0.angle >= largest * 0.2 && $0.peakSpeed >= peak * 0.2 }) else {
            throw MotionJumpFailure.insufficientAngle
        }
        let primary = strokes[primaryIndex]
        let direction = primary.displacement / primary.angle
        var returnAngle = 0.0
        // A very large return can dwarf the outward stroke. Never reinterpret that
        // return as the intended target merely because the relative noise gate skipped
        // the earlier stroke; cancel when there is evidence of an opposite movement.
        var conflicting = strokes.prefix(primaryIndex).contains { stroke in
            stroke.angle >= MotionJumpParameters.minimumAngleRange.lowerBound
                && motionDot(direction, stroke.displacement / stroke.angle) < -0.7
        }
        for stroke in strokes.dropFirst(primaryIndex + 1) where stroke.angle >= primary.angle * 0.6 {
            let alignment = motionDot(direction, stroke.displacement / stroke.angle)
            if alignment < -0.7 {
                returnAngle += stroke.angle
                if returnAngle > primary.angle * 1.75 { conflicting = true }
            } else {
                // A second large outward or sideways action is not a natural return.
                conflicting = true
            }
        }
        return .init(direction: direction, angle: primary.angle, peakSpeed: primary.peakSpeed, duration: duration, hasConflictingMotion: conflicting)
    }
}

private func motionDot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func motionLength(_ vector: SIMD3<Double>) -> Double {
    sqrt(motionDot(vector, vector))
}

private func motionClampCosine(_ value: Double) -> Double { min(1, max(-1, value)) }
