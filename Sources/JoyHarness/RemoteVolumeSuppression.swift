import Foundation

struct RemoteKeyMapping: Codable, Hashable {
    let source: UInt64
    let destination: UInt64
}

/// Filter the verified RC003 keyboard usages while mappings are active.
/// Raw IOHID input and BLE microphone notifications remain available.
enum RemoteVolumeSuppression {
    // Keep the existing guard/journal name so prior installations can restore
    // their mappings. Native arrows, Return, Menu, Home and F5 must not accompany
    // the mapped action. The unverified power key is deliberately excluded.
    static let sources: [UInt64] = [
        0x52, 0x51, 0x50, 0x4F, // up, down, left, right
        0x28, 0xF1, 0x65, 0x4A, // confirm, back, menu, home
        0x80, 0x81, 0x3E, 0x35, // volume +/-, voice, custom
    ].map { 0x700000000 | $0 }

    static func suppress(_ original: [RemoteKeyMapping]) -> [RemoteKeyMapping] {
        original.filter { !sources.contains($0.source) }
            + sources.map { RemoteKeyMapping(source: $0, destination: 0) }
    }

    static func restore(_ current: [RemoteKeyMapping], original: [RemoteKeyMapping]) -> [RemoteKeyMapping] {
        // Another utility may have edited mappings while we owned the keys.
        // Restore only entries that still contain our suppression value.
        let owned = sources.filter { source in
            current.filter { $0.source == source } == [.init(source: source, destination: 0)]
        }
        return current.filter { !owned.contains($0.source) }
            + original.filter { owned.contains($0.source) }
    }
}

/// A separate process owns the temporary system mapping. Closing stdin (including
/// when the GUI crashes or is killed during a rebuild) restores the saved mapping.
final class RemoteVolumeGuard {
    private var process: Process?
    private var input: FileHandle?

    func update(mapping: Bool) {
        do {
            if process?.isRunning != true {
                try input?.close()
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                child.arguments = ["--remote-volume-guard"]
                let pipe = Pipe()
                child.standardInput = pipe
                try child.run()
                try pipe.fileHandleForReading.close()
                _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                process = child
                input = pipe.fileHandleForWriting
            }
            try input?.write(contentsOf: Data((mapping ? "mapping\n" : "native\n").utf8))
        } catch {
            print("[agent-deck] remote volume guard failed: \(error)")
        }
    }

    func stop() {
        try? input?.close()
        input = nil
        process?.waitUntilExit()
        process = nil
    }

    deinit { try? input?.close() }
}

private struct RemoteVolumeSnapshot: Codable {
    let registryID: UInt64
    let matching: [String: UInt64]
    let original: [RemoteKeyMapping]
}

/// Uses the system utility instead of private IOHIDEventSystem APIs or root access.
enum RemoteVolumeGuardWorker {
    static func run() {
        setbuf(stdout, nil)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-deck")
        // A replacement GUI may start before the previous guard finishes restoring.
        var lock: SingleInstanceLock?
        for _ in 0..<150 {
            lock = SingleInstanceLock(path: directory.appendingPathComponent("remote-volume.lock").path)
            if lock != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let lock else {
            print("[agent-deck] remote volume guard already running")
            return
        }
        withExtendedLifetime(lock) {
            let journal = directory.appendingPathComponent("remote-volume-restore.json")
            do {
                var snapshots: [RemoteVolumeSnapshot] = []
                if FileManager.default.fileExists(atPath: journal.path) {
                    snapshots = try JSONDecoder().decode([RemoteVolumeSnapshot].self, from: Data(contentsOf: journal))
                }
                // Recover even if both the previous GUI and guard were interrupted.
                try restore(&snapshots, journal: journal)
                while let command = readLine() {
                    do {
                        if command == "mapping" {
                            try suppress(&snapshots, journal: journal)
                        } else if command == "native" {
                            try restore(&snapshots, journal: journal)
                        }
                    } catch {
                        print("[agent-deck] remote volume mapping failed: \(error)")
                        try restore(&snapshots, journal: journal)
                    }
                }
                try restore(&snapshots, journal: journal)
            } catch {
                print("[agent-deck] remote volume restore failed (recovery journal retained): \(error)")
            }
        }
    }

    private static func hidutil(_ arguments: [String]) throws -> Data {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        command.arguments = arguments
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw NSError(domain: "RemoteVolumeHID", code: Int(command.terminationStatus))
        }
        return data
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }

    static func serviceMatchingJSON(_ matching: [String: UInt64]) throws -> String {
        // hidutil reports Bluetooth service LocationID as a signed number.
        // Preserve that value for matching, including when restoring old journals
        // that stored its UInt64 bit pattern. A widened value matches no service.
        try json(matching.mapValues { Int64(bitPattern: $0) })
    }

    private static func services() throws -> [[String: Any]] {
        let match = ["VendorID": XiaomiRemoteConstants.vendorID, "ProductID": XiaomiRemoteConstants.productID]
        let output = try hidutil(["list", "--ndjson", "--matching", json(match)])
        return try String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return record?["type"] as? String == "service" ? record : nil
        }
    }

    private static func mappingsByService() throws -> [UInt64: [RemoteKeyMapping]] {
        let data = try hidutil(["dump", "services", "-f", "xml"])
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let records = plist?["ServiceRecords"] as? [[String: Any]] else {
            throw NSError(domain: "RemoteVolumeHID.invalidDump", code: 1)
        }
        var result: [UInt64: [RemoteKeyMapping]] = [:]
        for record in records {
            guard let id = record["IORegistryEntryID"] as? NSNumber,
                  let filters = record["ServiceFilterDebug"] as? [[String: Any]],
                  let keyboard = filters.first(where: { $0["name"] as? String == "com.apple.iokit.hid.IOHIDKeyboardFilter" }),
                  let plugin = keyboard["plugin"] as? [String: Any],
                  let entries = plugin["UserKeyMapping"] as? [[String: Any]] else { continue }
            result[id.uint64Value] = try entries.map { entry in
                guard let src = entry["Src"] as? NSNumber, let dst = entry["Dst"] as? NSNumber else {
                    throw NSError(domain: "RemoteVolumeHID.invalidMapping", code: 1)
                }
                return RemoteKeyMapping(source: src.uint64Value, destination: dst.uint64Value)
            }
        }
        return result
    }

    private static func write(_ mappings: [RemoteKeyMapping], matching: [String: UInt64]) throws {
        let entries = mappings.map { ["HIDKeyboardModifierMappingSrc": $0.source, "HIDKeyboardModifierMappingDst": $0.destination] }
        _ = try hidutil(["property", "--matching", serviceMatchingJSON(matching), "--set", json(["UserKeyMapping": entries])])
    }

    private static func save(_ snapshots: [RemoteVolumeSnapshot], journal: URL) throws {
        try JSONEncoder().encode(snapshots).write(to: journal, options: .atomic)
    }

    private static func suppress(_ snapshots: inout [RemoteVolumeSnapshot], journal: URL) throws {
        let devices = try services()
        let pending = devices.filter { device in
            guard let id = device["IORegistryEntryID"] as? NSNumber else { return false }
            return !snapshots.contains { $0.registryID == id.uint64Value }
        }
        guard !pending.isEmpty else { return }
        let mappings = try mappingsByService()
        for device in pending {
            guard let id = device["IORegistryEntryID"] as? NSNumber,
                  let original = mappings[id.uint64Value] else { continue }
            let keys = ["VendorID", "ProductID", "LocationID", "PrimaryUsagePage", "PrimaryUsage"]
            var matching: [String: UInt64] = [:]
            for key in keys { matching[key] = (device[key] as? NSNumber)?.uint64Value }
            // Never issue a broad/global write when device identity is incomplete
            // or cannot distinguish multiple services.
            guard matching.count == keys.count,
                  devices.filter({ candidate in matching.allSatisfy { key, value in
                      (candidate[key] as? NSNumber)?.uint64Value == value
                  }}).count == 1 else { continue }
            let snapshot = RemoteVolumeSnapshot(registryID: id.uint64Value, matching: matching, original: original)
            snapshots.append(snapshot)
            try save(snapshots, journal: journal)
            try write(RemoteVolumeSuppression.suppress(original), matching: matching)
            guard Set(try mappingsByService()[id.uint64Value] ?? []) == Set(RemoteVolumeSuppression.suppress(original)) else {
                throw NSError(domain: "RemoteVolumeHID.suppressionNotApplied", code: 1)
            }
            print("[agent-deck] Xiaomi Remote native mapped keys suppressed service=\(id)")
        }
    }

    private static func restore(_ snapshots: inout [RemoteVolumeSnapshot], journal: URL) throws {
        guard !snapshots.isEmpty else { return }
        let connected = try services()
        let current = try mappingsByService()
        for snapshot in snapshots {
            // Registry IDs change on reconnect. A new service has no mapping to undo.
            guard connected.contains(where: { ($0["IORegistryEntryID"] as? NSNumber)?.uint64Value == snapshot.registryID }) else { continue }
            guard let mappings = current[snapshot.registryID] else {
                throw NSError(domain: "RemoteVolumeHID.missingKeyboardFilter", code: 1)
            }
            try write(RemoteVolumeSuppression.restore(mappings, original: snapshot.original), matching: snapshot.matching)
            print("[agent-deck] Xiaomi Remote native mapped keys restored service=\(snapshot.registryID)")
        }
        snapshots.removeAll()
        try save(snapshots, journal: journal)
    }
}
