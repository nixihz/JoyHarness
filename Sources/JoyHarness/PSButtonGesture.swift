import Foundation

/// One unfiltered DualSense report. L2 and PS belong to the same physical device
/// and report; timestamp is captured on the HID queue, before the UI queue.
struct DualSensePSInputSample: Equatable {
    let isPressed: Bool
    let leftTriggerValue: Float
    let timestamp: TimeInterval
    var allowsVoiceStart: Bool = true
}

/// PS opens the switcher immediately. Holding L2 while tapping PS starts
/// voice; only a real L2 release submits, so PS never needs to stay held.
struct PSButtonGesture {
    enum Effect: Equatable {
        case showSwitcher, restoreMapping, beginVoice, submitVoice, cancelVoice
    }

    enum Priority {
        case normal, intercepted, nativeMode
    }

    private enum Phase {
        case awaitingNeutral, idle, recording, consumed
    }

    static let triggerPressThreshold: Float = 0.55
    static let triggerReleaseThreshold: Float = 0.10
    static let maximumReportGap: TimeInterval = 0.25
    private var phase: Phase = .awaitingNeutral
    private(set) var isPressed = false
    private var leftTriggerValue: Float = 0
    private(set) var lastTimestamp: TimeInterval?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isAwaitingNeutral: Bool {
        if case .awaitingNeutral = phase { return true }
        return false
    }

    var acceptsNewPSPress: Bool {
        if case .idle = phase { return !isPressed }
        return false
    }

    var needsInputWatchdog: Bool {
        isPressed || leftTriggerValue > Self.triggerReleaseThreshold || isRecording
    }

    mutating func ingest(
        _ sample: DualSensePSInputSample,
        voiceEnabled: Bool,
        priority: Priority = .normal
    ) -> [Effect] {
        if let lastTimestamp, sample.timestamp <= lastTimestamp { return [] }
        var effects: [Effect] = []
        if let lastTimestamp, needsInputWatchdog,
           sample.timestamp - lastTimestamp > Self.maximumReportGap {
            effects = interrupt()
        }
        lastTimestamp = sample.timestamp
        let wasPressed = isPressed
        isPressed = sample.isPressed
        leftTriggerValue = sample.leftTriggerValue
        let triggerReleased = leftTriggerValue <= Self.triggerReleaseThreshold
        let neutral = !isPressed && triggerReleased

        switch phase {
        case .awaitingNeutral, .consumed:
            if neutral { phase = .idle }
        case .recording:
            if !voiceEnabled {
                phase = neutral ? .idle : .awaitingNeutral
                effects.append(.cancelVoice)
            } else if triggerReleased {
                phase = neutral ? .idle : .consumed
                effects.append(.submitVoice)
            }
        case .idle:
            guard isPressed, !wasPressed else { return effects }
            // Commit the branch on PS down. A stale chord is consumed here;
            // later fresh heartbeats must never start a delayed microphone.
            phase = .consumed
            switch priority {
            case .intercepted:
                break
            case .nativeMode:
                effects.append(.restoreMapping)
            case .normal:
                if leftTriggerValue >= Self.triggerPressThreshold {
                    if voiceEnabled && sample.allowsVoiceStart {
                        phase = .recording
                        effects.append(.beginVoice)
                    }
                } else {
                    effects.append(.showSwitcher)
                }
            }
        }
        return effects
    }

    /// Cancellation consumes the complete PS/L2 chord, including retries
    /// while only PS has been released. Both inputs must return to neutral.
    mutating func cancel() -> [Effect] {
        let effects: [Effect] = isRecording ? [.cancelVoice] : []
        phase = .awaitingNeutral
        return effects
    }

    /// Disconnection, reset, sleep and missing reports never count as submit.
    mutating func interrupt() -> [Effect] {
        let effects: [Effect] = isRecording ? [.cancelVoice] : []
        phase = .awaitingNeutral
        isPressed = false
        leftTriggerValue = 0
        lastTimestamp = nil
        return effects
    }
}

/// Batches reports while the main queue is busy, preserving each press/release
/// edge and its time. A fresh PS down may start only while the rest of its
/// uninterrupted batch still holds L2; a completed/expired chord never starts.
final class DualSensePSInputMailbox {
    private let lock = NSLock()
    private var samples: [DualSensePSInputSample] = []
    private var scheduled = false
    private var lastAppendedTimestamp: TimeInterval?
    private var lastVoiceInterruptionTimestamp: TimeInterval?

    func append(_ sample: DualSensePSInputSample) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let gap = lastAppendedTimestamp.map { sample.timestamp - $0 }
        if sample.leftTriggerValue <= PSButtonGesture.triggerReleaseThreshold ||
            gap.map({ $0 <= 0 || $0 > PSButtonGesture.maximumReportGap }) == true {
            lastVoiceInterruptionTimestamp = max(
                lastVoiceInterruptionTimestamp ?? -.infinity,
                max(sample.timestamp, lastAppendedTimestamp ?? -.infinity)
            )
        }
        lastAppendedTimestamp = max(lastAppendedTimestamp ?? -.infinity, sample.timestamp)
        // Keep heartbeat samples as evidence of continuity. If the UI is
        // stalled for seconds, drop the old batch: the resulting gap cancels
        // the gesture instead of inventing a held button or retaining forever.
        if samples.count >= 2_048 { samples.removeAll(keepingCapacity: true) }
        samples.append(sample)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func drain(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [DualSensePSInputSample] {
        lock.lock()
        defer { lock.unlock() }
        var result = samples
        samples.removeAll(keepingCapacity: true)
        scheduled = false
        var heldContinuously = true
        var nextTimestamp: TimeInterval?
        for index in result.indices.reversed() {
            let sample = result[index]
            heldContinuously = heldContinuously &&
                sample.leftTriggerValue > PSButtonGesture.triggerReleaseThreshold
            if let nextTimestamp {
                let gap = nextTimestamp - sample.timestamp
                heldContinuously = heldContinuously && gap > 0 && gap <= PSButtonGesture.maximumReportGap
            }
            let age = now - sample.timestamp
            result[index].allowsVoiceStart = sample.allowsVoiceStart && heldContinuously &&
                age >= 0 && age <= PSButtonGesture.maximumReportGap &&
                sample.timestamp > (lastVoiceInterruptionTimestamp ?? -.infinity)
            nextTimestamp = sample.timestamp
        }
        return result
    }

    /// Recheck immediately before delivery: an earlier UI callback may have
    /// blocked, or the HID queue may have observed L2 release after draining.
    func canStartVoice(
        _ sample: DualSensePSInputSample,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let age = now - sample.timestamp
        return age >= 0 && age <= PSButtonGesture.maximumReportGap &&
            sample.timestamp > (lastVoiceInterruptionTimestamp ?? -.infinity)
    }

    func reset(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        lastAppendedTimestamp = nil
        lastVoiceInterruptionTimestamp = now
        scheduled = false
    }
}
