import Foundation

struct DualSenseHIDEndpointIdentity: Hashable {
    let registryID: UInt64
    let connectionGeneration: UInt64
}

enum DualSenseMicrophoneAvailability: Equatable {
    case unavailable(String)
    case available(DualSenseHIDEndpointIdentity)

    var identity: DualSenseHIDEndpointIdentity? {
        guard case let .available(identity) = self else { return nil }
        return identity
    }
}

struct DualSenseHIDControlSample: Equatable {
    let identity: DualSenseHIDEndpointIdentity
    let pressedInputs: Set<ControllerInput>
    let timestamp: TimeInterval
    let isNeutral: Bool
    let microphoneMuted: Bool
    let leftTriggerValue: Float
    let rightTriggerValue: Float
}

struct DualSenseHIDMicrophonePacket {
    let identity: DualSenseHIDEndpointIdentity
    let sessionGeneration: UInt64
    let payload: Data
    let sequence: UInt8
    let timestamp: TimeInterval
}

enum DualSenseHIDMicrophoneError: LocalizedError, Equatable {
    case unavailable, cancelled, writeFailed, missingControlState, recoveryRequired

    var errorDescription: String? {
        switch self {
        case .unavailable: "请仅通过蓝牙连接一只 DualSense。"
        case .cancelled: "手柄音频操作已取消。"
        case .writeFailed: "无法向 DualSense 写入音频控制，请关闭手柄后重新连接。"
        case .missingControlState: "尚未收到可信的 DualSense 控制状态。"
        case .recoveryRequired: "手柄关闭状态尚未确认，请停止供音或重新连接。"
        }
    }
}

/// At most one main-queue drain is pending. Preserve both ends of every
/// unchanged run, so a stalled UI cannot turn a brief press into a held key.
final class DualSenseHIDControlMailbox {
    struct Batch {
        let samples: [DualSenseHIDControlSample]
        let overflowed: Bool
    }

    private let lock = NSLock()
    private let capacity: Int
    private var samples: [DualSenseHIDControlSample] = []
    private var scheduled = false
    private var overflowed = false

    init(capacity: Int = 128) { self.capacity = max(2, capacity) }

    func append(_ sample: DualSenseHIDControlSample) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !overflowed {
            if samples.count >= 2,
               sameState(samples[samples.count - 2], sample),
               sameState(samples[samples.count - 1], sample),
               sample.timestamp - samples[samples.count - 1].timestamp < 0.25 {
                samples[samples.count - 1] = sample
            } else if samples.count < capacity {
                samples.append(sample)
            } else {
                samples.removeAll(keepingCapacity: true)
                overflowed = true
            }
        }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func drain() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        let batch = Batch(samples: samples, overflowed: overflowed)
        samples.removeAll(keepingCapacity: true)
        overflowed = false
        scheduled = false
        return batch
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        overflowed = false
        scheduled = false
    }

    private func sameState(_ a: DualSenseHIDControlSample, _ b: DualSenseHIDControlSample) -> Bool {
        a.identity == b.identity && a.pressedInputs == b.pressedInputs &&
            a.isNeutral == b.isNeutral && a.microphoneMuted == b.microphoneMuted
    }
}

/// One serial owner for blocking IOHID writes. Cancellation invalidates the
/// token immediately; an already-running driver call must finish before the
/// queued close can execute. No caller waits on this queue.
final class DualSenseHIDWriteCoordinator {
    typealias Completion = (Result<Void, Error>) -> Void

    private struct Attachment {
        let generation: UInt64
        let bluetooth: Bool
        let write: ([UInt8]) -> Bool
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var attachment: Attachment?
    private var epoch: UInt64 = 0
    private var session: UInt64?
    private var isolated = false
    private var closeSucceeded = false
    // Only accessed on the serial write queue, including across reconnections.
    private var sequence: UInt8 = 0

    init(queue: DispatchQueue = DispatchQueue(label: "tech.keli.joyharness.dualsense-output")) {
        self.queue = queue
    }

    func attach(generation: UInt64, bluetooth: Bool, write: @escaping ([UInt8]) -> Bool) {
        lock.lock()
        attachment = Attachment(generation: generation, bluetooth: bluetooth, write: write)
        epoch &+= 1
        session = nil
        isolated = false
        closeSucceeded = false
        lock.unlock()
    }

    /// Feature reads also run on the same queue as output reports.
    func prepareInput(_ operation: @escaping () -> Void) {
        lock.lock()
        let generation = attachment?.generation
        lock.unlock()
        guard let generation else { return }
        queue.async { [self] in
            guard isAttached(generation) else { return }
            operation()
        }
    }

    func enqueueTrigger(_ report: [UInt8]) -> Bool {
        lock.lock()
        guard let attachment, !isolated else { lock.unlock(); return false }
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let allowed = self.attachment?.generation == attachment.generation && !isolated
            lock.unlock()
            guard allowed else { return }
            _ = attachment.write(attachment.bluetooth ? sequenced(report) : report)
        }
        return true
    }

    func begin(connection: UInt64, session newSession: UInt64, muted: Bool,
               completion: @escaping Completion) -> Bool {
        lock.lock()
        guard let attachment, attachment.generation == connection, attachment.bluetooth else {
            lock.unlock(); complete(completion, .failure(DualSenseHIDMicrophoneError.unavailable)); return false
        }
        guard !isolated else {
            lock.unlock(); complete(completion, .failure(DualSenseHIDMicrophoneError.recoveryRequired)); return false
        }
        epoch &+= 1
        let token = epoch
        session = newSession
        isolated = true
        closeSucceeded = false
        lock.unlock()
        queue.async { [self] in
            let builders: [(UInt8) -> [UInt8]] = [
                { DualSenseBluetoothAudioProtocol.audioInitializationReport(sequence: $0) },
                { DualSenseBluetoothAudioProtocol.microphoneStateReport(active: true, muted: muted, sequence: $0) },
                { DualSenseBluetoothAudioProtocol.microphoneStreamReport(active: true, sequence: $0) },
            ]
            for makeReport in builders {
                guard isCurrent(connection: connection, token: token) else {
                    complete(completion, .failure(DualSenseHIDMicrophoneError.cancelled)); return
                }
                guard attachment.write(makeReport(nextSequence())) else {
                    complete(completion, .failure(DualSenseHIDMicrophoneError.writeFailed)); return
                }
            }
            completeCurrent(completion, .success(()), connection: connection, token: token)
        }
        return true
    }

    /// May also close a connection with no active session (startup recovery).
    @discardableResult
    func end(connection: UInt64, session stoppedSession: UInt64,
             completion: @escaping Completion) -> Bool {
        lock.lock()
        guard let attachment, attachment.generation == connection, attachment.bluetooth,
              session == nil || session == stoppedSession else {
            lock.unlock(); complete(completion, .failure(DualSenseHIDMicrophoneError.cancelled)); return false
        }
        epoch &+= 1
        let token = epoch
        session = stoppedSession
        isolated = true
        closeSucceeded = false
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(connection: connection, token: token) else {
                complete(completion, .failure(DualSenseHIDMicrophoneError.cancelled)); return
            }
            // Closing the stream preserves the user's reported mute state.
            let succeeded = attachment.write(DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                active: false, sequence: nextSequence()
            ))
            lock.lock()
            let current = self.attachment?.generation == connection && epoch == token
            if current { closeSucceeded = succeeded }
            lock.unlock()
            let result: Result<Void, Error> = !current ? .failure(DualSenseHIDMicrophoneError.cancelled)
                : succeeded ? .success(()) : .failure(DualSenseHIDMicrophoneError.writeFailed)
            completeCurrent(completion, result, connection: connection, token: token)
        }
        return true
    }

    func finishIsolation(connection: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard attachment?.generation == connection, isolated, closeSucceeded else { return false }
        epoch &+= 1
        isolated = false
        session = nil
        return true
    }

    /// Keep the old handle alive until all in-flight calls and the final close
    /// have returned. A blocked driver cannot cause a false close completion.
    func detach(triggerOff: [UInt8]?, completion: @escaping () -> Void) {
        lock.lock()
        let retired = attachment
        attachment = nil
        epoch &+= 1
        session = nil
        isolated = false
        closeSucceeded = false
        lock.unlock()
        queue.async { [self] in
            if let retired {
                if retired.bluetooth {
                    _ = retired.write(DualSenseBluetoothAudioProtocol.microphoneStreamReport(
                        active: false, sequence: nextSequence()
                    ))
                }
                if let triggerOff { _ = retired.write(retired.bluetooth ? sequenced(triggerOff) : triggerOff) }
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func isAttached(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attachment?.generation == generation
    }

    private func isCurrent(connection: UInt64, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attachment?.generation == connection && epoch == token
    }

    private func nextSequence() -> UInt8 {
        let current = sequence
        sequence = (sequence &+ 1) & 0x0f
        return current
    }

    private func sequenced(_ report: [UInt8]) -> [UInt8] {
        guard report.count >= 6 else { return report }
        var result = report
        result[1] = (nextSequence() << 4) | (result[1] & 0x0f)
        let offset = result.count - 4
        let crc = DualSenseBluetoothAudioProtocol.outputCRC(for: Array(result[..<offset]))
        for index in 0..<4 { result[offset + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
        return result
    }

    private func complete(_ completion: @escaping Completion, _ result: Result<Void, Error>) {
        DispatchQueue.main.async { completion(result) }
    }

    private func completeCurrent(_ completion: @escaping Completion, _ result: Result<Void, Error>,
                                 connection: UInt64, token: UInt64) {
        DispatchQueue.main.async { [self] in
            completion(isCurrent(connection: connection, token: token)
                ? result : .failure(DualSenseHIDMicrophoneError.cancelled))
        }
    }
}
