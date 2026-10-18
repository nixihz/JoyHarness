import Foundation

/// Stamp callbacks before enqueueing UI work. A begin/end isolation cycle
/// invalidates already queued events as well as events received during audio.
final class ControllerInputIsolationGate {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var blocked = false

    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func token() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return blocked ? nil : epoch
    }

    func permits(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !blocked && token == epoch
    }

    func setBlocked(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard blocked != value else { return }
        epoch &+= 1
        blocked = value
    }
}
