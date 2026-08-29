import Foundation

struct CodexDiagnosticBuffer {
    private let capacity: Int
    private var data = Data()

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var byteCount: Int { data.count }
    var text: String { String(decoding: data, as: UTF8.self) }

    mutating func append(_ newData: Data) {
        guard capacity > 0, !newData.isEmpty else { return }
        data.append(newData)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    mutating func removeAll() {
        data.removeAll(keepingCapacity: true)
    }
}

enum CodexProviderHealth: Equatable {
    case stopped
    case starting
    case healthy
    case degraded
    case failed
}

enum CodexRequestKind: Equatable {
    case initialization
    case threadList
}

enum CodexProcessFailure: CaseIterable {
    case launch
    case write
    case exit
}

struct CodexPendingRequest: Equatable {
    let id: Int
    let kind: CodexRequestKind
    let deadline: Date
}

struct CodexThreadRecoveryStateMachine {
    private let initialRestartDelay: TimeInterval
    private let maximumRestartDelay: TimeInterval
    private(set) var health: CodexProviderHealth = .stopped
    private(set) var pendingRequest: CodexPendingRequest?
    private var restartAttempt = 0
    private var wasHealthy = false

    init(initialRestartDelay: TimeInterval = 0.25, maximumRestartDelay: TimeInterval = 8) {
        self.initialRestartDelay = initialRestartDelay
        self.maximumRestartDelay = maximumRestartDelay
    }

    mutating func start() {
        pendingRequest = nil
        restartAttempt = 0
        wasHealthy = false
        health = .starting
    }

    mutating func stop() {
        pendingRequest = nil
        health = .stopped
    }

    @discardableResult
    mutating func beginRestart() -> Bool {
        guard health != .stopped else { return false }
        health = .starting
        return true
    }

    mutating func beginRequest(id: Int, kind: CodexRequestKind, deadline: Date) {
        guard health != .stopped else { return }
        pendingRequest = CodexPendingRequest(id: id, kind: kind, deadline: deadline)
    }

    mutating func receiveResponse(id: Int, succeeded: Bool) -> CodexRequestKind? {
        guard health != .stopped,
              let pendingRequest,
              pendingRequest.id == id else { return nil }
        self.pendingRequest = nil
        if pendingRequest.kind == .initialization, succeeded {
            health = .healthy
            wasHealthy = true
            restartAttempt = 0
        }
        return pendingRequest.kind
    }

    mutating func handleTimeout(at now: Date) -> TimeInterval? {
        guard let pendingRequest, now >= pendingRequest.deadline else { return nil }
        return fail()
    }

    mutating func handleProcessFailure(_ failure: CodexProcessFailure) -> TimeInterval? {
        fail()
    }

    mutating func fail() -> TimeInterval? {
        guard health != .stopped else { return nil }
        pendingRequest = nil
        health = wasHealthy ? .degraded : .failed
        let multiplier = pow(2, Double(min(restartAttempt, 30)))
        let delay = min(initialRestartDelay * multiplier, maximumRestartDelay)
        restartAttempt += 1
        return delay
    }
}
