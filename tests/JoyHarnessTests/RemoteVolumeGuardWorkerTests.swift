import Foundation
import Testing
@testable import JoyHarness

struct RemoteVolumeGuardWorkerTests {
    @Test(arguments: [false, true])
    func lateServicesAreSuppressedAndRestoredOnNativeModeOrEOF(nativeMode: Bool) async throws {
        let device = FakeRemoteHID(readyAfter: 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
            retryMilliseconds: 20, hidutil: device.execute)
        let task = Task.detached { worker.run() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        await waitUntil { device.mappings == RemoteVolumeSuppression.suppress(device.original) }
        #expect(device.mappings == RemoteVolumeSuppression.suppress(device.original))
        #expect(device.locationID == -496_656_494)
        let queries = device.queries
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(device.queries == queries) // Successful suppression stops retries.
        if nativeMode {
            try pipe.fileHandleForWriting.write(contentsOf: Data("native\n".utf8))
            await waitUntil { device.mappings == device.original }
        }
        try pipe.fileHandleForWriting.close()
        await task.value
        #expect(device.mappings == device.original)
        let journal = try Data(contentsOf: directory.appendingPathComponent("remote-volume-restore.json"))
        #expect(try JSONSerialization.jsonObject(with: journal) as? [AnyHashable] == [])
    }

    @Test func nativeModeCancelsDiscoveryRetriesBeforeServiceAppears() async throws {
        let device = FakeRemoteHID(readyAfter: .max)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        let worker = RemoteVolumeGuardWorker(directory: directory, input: pipe.fileHandleForReading,
            retryMilliseconds: 20, hidutil: device.execute)
        let task = Task.detached { worker.run() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("mapping\n".utf8))
        await waitUntil { device.queries >= 3 }
        #expect(device.queries >= 3)
        try pipe.fileHandleForWriting.write(contentsOf: Data("native\n".utf8))
        try await Task.sleep(nanoseconds: 60_000_000)
        let queries = device.queries
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(device.queries == queries)
        try pipe.fileHandleForWriting.close()
        await task.value
        #expect(device.mappings == device.original)
    }

    private func waitUntil(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeRemoteHID: @unchecked Sendable {
    let original = [RemoteKeyMapping(source: 0x700000035, destination: 0x7000000E7)]
    private let lock = NSLock()
    private let readyAfter: Int
    private var queryCount = 0
    private var current: [RemoteKeyMapping]
    private var matchedLocationID: Int64?
    var mappings: [RemoteKeyMapping] { lock.withLock { current } }
    var queries: Int { lock.withLock { queryCount } }
    var locationID: Int64? { lock.withLock { matchedLocationID } }

    init(readyAfter: Int) {
        self.readyAfter = readyAfter
        current = original
    }

    func execute(_ arguments: [String]) throws -> Data {
        try lock.withLock {
            switch arguments[0] {
            case "list":
                queryCount += 1
                guard queryCount >= readyAfter else { return Data() }
                return try JSONSerialization.data(withJSONObject: [
                    "type": "service", "IORegistryEntryID": 123,
                    "VendorID": 10007, "ProductID": 12984, "LocationID": -496_656_494,
                    "PrimaryUsagePage": 1, "PrimaryUsage": 6,
                ])
            case "dump":
                return try PropertyListSerialization.data(fromPropertyList: ["ServiceRecords": [[
                    "IORegistryEntryID": 123,
                    "ServiceFilterDebug": [[
                        "name": "com.apple.iokit.hid.IOHIDKeyboardFilter",
                        "plugin": ["UserKeyMapping": current.map { ["Src": $0.source, "Dst": $0.destination] }],
                    ]],
                ]]], format: .xml, options: 0)
            case "property":
                let match = try JSONDecoder().decode([String: Int64].self, from: Data(arguments[2].utf8))
                matchedLocationID = match["LocationID"]
                let payload = try JSONDecoder().decode([String: [[String: UInt64]]].self, from: Data(arguments[4].utf8))
                current = try #require(payload["UserKeyMapping"]).map {
                    RemoteKeyMapping(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                }
                return Data()
            default:
                throw NSError(domain: "UnexpectedHIDCommand", code: 1)
            }
        }
    }
}
