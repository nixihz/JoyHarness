import Foundation

enum SerialWriteAttempt: Equatable {
    case written(Int)
    case wouldBlock
    case interrupted
    case failed
}

enum SerialDrainResult: Equatable {
    case empty
    case pending
    case failed
}

struct SerialOutputBuffer {
    private let capacity: Int
    private var storage = Data()
    private var offset = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var pendingByteCount: Int {
        storage.count - offset
    }

    mutating func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= capacity - pendingByteCount else { return false }
        compactIfNeeded()
        storage.append(data)
        return true
    }

    mutating func drain(
        using writer: (Data) -> SerialWriteAttempt
    ) -> SerialDrainResult {
        while pendingByteCount > 0 {
            let pending = Data(storage[offset...])
            switch writer(pending) {
            case let .written(count):
                guard count > 0, count <= pending.count else {
                    removeAll()
                    return .failed
                }
                offset += count
            case .wouldBlock:
                return .pending
            case .interrupted:
                continue
            case .failed:
                removeAll()
                return .failed
            }
        }
        removeAll()
        return .empty
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        offset = 0
    }

    private mutating func compactIfNeeded() {
        guard offset > 0 else { return }
        storage.removeFirst(offset)
        offset = 0
    }
}
