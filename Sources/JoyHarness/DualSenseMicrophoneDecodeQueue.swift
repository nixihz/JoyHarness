import Foundation

/// Counts work until main has consumed it, bounding both the codec queue and
/// pending UI deliveries. Four-bit sequence gaps alone do not prove lost audio.
final class DualSenseMicrophoneDecodeQueue {
    private let queue = DispatchQueue(label: "tech.keli.joyharness.dualsense-opus")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var identity: DualSenseHIDEndpointIdentity?
    private var accepting = false
    private var cutoff: TimeInterval?
    private var pending = 0
    private var latestTime: TimeInterval?
    private var decoder: DualSenseOpusDecoder?
    private var previous: DualSenseHIDMicrophonePacket?
    var onPCM: (([Float], UInt64, TimeInterval) -> Void)?
    var onFailure: ((UInt64, String) -> Void)?

    var lastPacketTime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return latestTime
    }

    func begin(identity: DualSenseHIDEndpointIdentity, generation: UInt64) {
        lock.lock()
        self.identity = identity
        self.generation = generation
        accepting = true
        cutoff = nil
        pending = 0
        latestTime = nil
        queue.async { [self] in
            previous = nil
            do { decoder = try DualSenseOpusDecoder() }
            catch { decoder = nil; reportFailure(generation, error.localizedDescription) }
        }
        lock.unlock()
    }

    func receive(_ packet: DualSenseHIDMicrophonePacket) {
        lock.lock()
        guard packet.identity == identity, packet.sessionGeneration == generation else { lock.unlock(); return }
        latestTime = packet.timestamp
        guard accepting, cutoff.map({ packet.timestamp <= $0 }) ?? true else { lock.unlock(); return }
        guard pending < 10 else {
            accepting = false
            lock.unlock()
            reportFailure(packet.sessionGeneration, "手柄音频处理积压，已停止供音。")
            return
        }
        pending += 1
        queue.async { [self] in
            let result: Result<[Float], Error>
            do {
                if let previous, previous.sequence == packet.sequence, previous.payload == packet.payload,
                   packet.timestamp - previous.timestamp >= 0, packet.timestamp - previous.timestamp < 0.005 {
                    complete(packet, result: .success([]))
                    return
                }
                guard let decoder else { throw DualSenseHIDMicrophoneError.unavailable }
                result = .success(try decoder.decode(packet.payload))
                previous = packet
            } catch { result = .failure(error) }
            complete(packet, result: result)
        }
        lock.unlock()
    }

    private func complete(_ packet: DualSenseHIDMicrophonePacket, result: Result<[Float], Error>) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let valid = generation == packet.sessionGeneration && accepting &&
                (cutoff.map { packet.timestamp <= $0 } ?? true)
            if generation == packet.sessionGeneration { pending -= 1 }
            lock.unlock()
            guard valid else { return }
            switch result {
            case .success(let pcm):
                if !pcm.isEmpty { onPCM?(pcm, packet.sessionGeneration, packet.timestamp) }
            case .failure(let error): onFailure?(packet.sessionGeneration, error.localizedDescription)
            }
        }
    }

    /// Finish queued pre-release decoding before the output starts draining.
    func freeze(generation: UInt64, at timestamp: TimeInterval, completion: @escaping () -> Void) {
        lock.lock()
        if self.generation == generation { cutoff = timestamp }
        queue.async { DispatchQueue.main.async(execute: completion) }
        lock.unlock()
    }

    func cancel(generation: UInt64) {
        lock.lock()
        if self.generation == generation { accepting = false }
        lock.unlock()
    }

    private func reportFailure(_ generation: UInt64, _ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(generation, message) }
    }
}
