import Foundation

extension SystemKey {
    var repeatsWhileHeld: Bool {
        switch self {
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .backspace: true
        default: false
        }
    }
}

/// Each held key owns its repeat task; releasing another key cannot stop it.
@MainActor
final class SystemKeyRepeater {
    private var tasks: [SystemKey: Task<Void, Never>] = [:]
    private let initialDelay: UInt64
    private let interval: UInt64
    private let onRepeat: (SystemKey) -> Void

    init(initialDelay: UInt64 = 450_000_000, interval: UInt64 = 50_000_000,
         onRepeat: @escaping (SystemKey) -> Void) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.onRepeat = onRepeat
    }

    func start(_ key: SystemKey) {
        guard key.repeatsWhileHeld, tasks[key] == nil else { return }
        let initialDelay = initialDelay, interval = interval, onRepeat = onRepeat
        tasks[key] = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: initialDelay)
                while !Task.isCancelled {
                    onRepeat(key)
                    try await Task.sleep(nanoseconds: interval)
                }
            } catch is CancellationError {
                // Release, disconnect, mode change, or shutdown cancels the hold.
            } catch {
                assertionFailure("Unexpected key repeat failure: \(error)")
            }
        }
    }

    func stop(_ key: SystemKey) { tasks.removeValue(forKey: key)?.cancel() }

    func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    deinit { for task in tasks.values { task.cancel() } }
}
