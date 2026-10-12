import Foundation

struct CodexRolloutStateReader {
    private struct Cursor {
        var offset: UInt64 = 0
        var partial = Data()
        var state: PadState?
        var fileID: UInt64?
        var searchOffset: UInt64?
        var searchSuffix = Data()
    }
    private var cursors: [String: Cursor] = [:]
    private let maximumRead = 262_144

    mutating func retain(paths: Set<String>) { cursors = cursors.filter { paths.contains($0.key) } }

    mutating func state(at path: String) -> PadState? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let file = FileHandle(forReadingAtPath: path) else {
            cursors.removeValue(forKey: path)
            return nil
        }
        defer { try? file.close() }
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        var cursor = cursors[path] ?? Cursor()
        if cursor.offset > size || cursor.fileID != fileID { cursor = Cursor(fileID: fileID) }
        do {
            // 首次只扫描有界尾部，后续增量读取，避免历史长会话阻塞主线程。
            if size - cursor.offset > UInt64(maximumRead) {
                cursor.offset = size - UInt64(maximumRead)
                cursor.state = nil
                cursor.searchOffset = cursor.offset
                cursor.partial.removeAll()
                try file.seek(toOffset: cursor.offset)
                let tail = try file.read(upToCount: maximumRead) ?? Data()
                cursor.offset += UInt64(tail.count)
                if let newline = tail.firstIndex(of: 0x0A) {
                    cursor.searchSuffix = Data(tail.prefix(through: newline))
                    cursor.partial.append(tail.suffix(from: tail.index(after: newline)))
                }
            } else {
                try file.seek(toOffset: cursor.offset)
                let data = try file.read(upToCount: maximumRead) ?? Data()
                cursor.offset += UInt64(data.count)
                cursor.partial.append(data)
            }
            while let newline = cursor.partial.firstIndex(of: 0x0A) {
                let line = Data(cursor.partial[..<newline])
                cursor.partial.removeSubrange(...newline)
                if let state = Self.stateEvent(in: line) { cursor.state = state }
            }
            if cursor.partial.count > maximumRead { cursor.partial.removeAll() }
            // 长回合的开始事件可能远离文件尾部；后台逐块向前查找，找到最近的状态事件即停止。
            if cursor.state == nil {
                for _ in 0..<8 {
                    guard let end = cursor.searchOffset, end > 0 else { break }
                    let start = end > UInt64(maximumRead) ? end - UInt64(maximumRead) : 0
                    try file.seek(toOffset: start)
                    let block = try file.read(upToCount: Int(end - start)) ?? Data()
                    var lines = (block + cursor.searchSuffix).split(separator: 0x0A)
                    cursor.searchSuffix.removeAll()
                    if start > 0, !lines.isEmpty {
                        let partial = lines.removeFirst()
                        if partial.count <= maximumRead * 8 {
                            cursor.searchSuffix = Data(partial) + Data([0x0A])
                        }
                    }
                    cursor.searchOffset = start
                    if let state = lines.reversed().compactMap({ Self.stateEvent(in: Data($0)) }).first {
                        cursor.state = state
                        break
                    }
                }
            }
            cursors[path] = cursor
            return cursor.state
        } catch {
            cursors.removeValue(forKey: path)
            return nil
        }
    }

    static func stateEvent(in data: Data) -> PadState? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return nil }
        switch type {
        case "task_started": return .busy
        case "task_complete": return .done
        case "turn_aborted": return .idle
        default: return nil
        }
    }
}
