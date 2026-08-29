import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct StatusRepositoryTests {
    @Test
    func classifiesCurrentPayloadAsFreshAndRecordsReadTime() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let statusURL = directory.appendingPathComponent("status.json")
        let status = makeStatus(timestamp: timestamp(readAt, fractionalSeconds: true))
        try JSONEncoder().encode(status).write(to: statusURL)

        let repository = StatusRepository(
            statusURL: statusURL,
            freshnessInterval: 2,
            now: { readAt }
        )
        let snapshot = repository.read()

        #expect(snapshot.freshness == .fresh)
        #expect(snapshot.status == status)
        #expect(snapshot.lastSuccessfulRead == readAt)
        #expect(snapshot.error == nil)
    }

    @Test
    func classifiesOldPayloadAsStale() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadDate = Date(timeIntervalSince1970: 1_800_000_000)
        let statusURL = directory.appendingPathComponent("status.json")
        try JSONEncoder().encode(makeStatus(timestamp: timestamp(payloadDate))).write(to: statusURL)

        let repository = StatusRepository(
            statusURL: statusURL,
            freshnessInterval: 2,
            now: { payloadDate.addingTimeInterval(3) }
        )
        let snapshot = repository.read()

        #expect(snapshot.freshness == .stale)
        #expect(snapshot.status?.timestamp == timestamp(payloadDate))
        #expect(snapshot.lastSuccessfulRead == payloadDate.addingTimeInterval(3))
        #expect(snapshot.error == nil)
    }

    @Test
    func missingPayloadIsUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusURL = directory.appendingPathComponent("missing.json")
        let repository = StatusRepository(statusURL: statusURL)

        let snapshot = repository.read()

        #expect(snapshot.freshness == .unavailable)
        #expect(snapshot.status == nil)
        #expect(snapshot.lastSuccessfulRead == nil)
        guard case .missingFile(let path) = snapshot.error else {
            Issue.record("expected missing-file error")
            return
        }
        #expect(path == statusURL.path)
    }

    @Test
    func malformedPayloadBecomesUnavailableWithoutLosingLastReadTime() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let statusURL = directory.appendingPathComponent("status.json")
        try JSONEncoder().encode(makeStatus(timestamp: timestamp(readAt))).write(to: statusURL)
        let repository = StatusRepository(statusURL: statusURL, now: { readAt })
        #expect(repository.read().freshness == .fresh)

        try Data("{not-json".utf8).write(to: statusURL)
        let snapshot = repository.read()

        #expect(snapshot.freshness == .unavailable)
        #expect(snapshot.status == nil)
        #expect(snapshot.lastSuccessfulRead == readAt)
        guard case .decode = snapshot.error else {
            Issue.record("expected decode error")
            return
        }
    }

    @Test
    func invalidTimestampIsUnavailable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusURL = directory.appendingPathComponent("status.json")
        try JSONEncoder().encode(makeStatus(timestamp: "not-a-date")).write(to: statusURL)

        let snapshot = StatusRepository(statusURL: statusURL).read()

        #expect(snapshot.freshness == .unavailable)
        #expect(snapshot.status == nil)
        #expect(snapshot.error == .invalidTimestamp("not-a-date"))
    }

    @Test
    func writeCreatesDirectoryAndPersistsSharedCodablePayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusURL = directory
            .appendingPathComponent("nested")
            .appendingPathComponent("status.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = makeStatus(timestamp: timestamp(date))
        let repository = StatusRepository(statusURL: statusURL, now: { date })

        #expect(repository.write(status))
        #expect(repository.lastError == nil)
        #expect(repository.read().status == status)
    }

    @Test
    func writeFailuresAreStoredAndReported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var diagnostics: [String] = []

        let parentFile = directory.appendingPathComponent("parent-file")
        try Data().write(to: parentFile)
        let directoryFailure = StatusRepository(
            statusURL: parentFile.appendingPathComponent("status.json"),
            reportError: { diagnostics.append($0) }
        )
        #expect(!directoryFailure.write(makeStatus(timestamp: timestamp(Date()))))
        guard case .createDirectory = directoryFailure.lastError else {
            Issue.record("expected create-directory error")
            return
        }

        let encodingFailure = StatusRepository(
            statusURL: directory.appendingPathComponent("encoding.json"),
            reportError: { diagnostics.append($0) }
        )
        let nonFiniteStatus = makeStatus(
            timestamp: timestamp(Date()),
            controllerBatteryLevel: .nan
        )
        #expect(!encodingFailure.write(nonFiniteStatus))
        guard case .encode = encodingFailure.lastError else {
            Issue.record("expected encoding error")
            return
        }

        let destinationDirectory = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let atomicWriteFailure = StatusRepository(
            statusURL: destinationDirectory,
            reportError: { diagnostics.append($0) }
        )
        #expect(!atomicWriteFailure.write(makeStatus(timestamp: timestamp(Date()))))
        guard case .atomicWrite = atomicWriteFailure.lastError else {
            Issue.record("expected atomic-write error")
            return
        }

        #expect(diagnostics.count == 3)
        #expect(diagnostics.allSatisfy { $0.hasPrefix("[joy-harness] ") })
    }

    @MainActor
    @Test
    func dashboardDoesNotPresentOldStatusAfterReadFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let statusURL = directory.appendingPathComponent("status.json")
        let liveStatus = makeStatus(timestamp: timestamp(now))
        try JSONEncoder().encode(liveStatus).write(to: statusURL)
        let store = DashboardStore(repository: StatusRepository(statusURL: statusURL, now: { now }))
        #expect(store.status == liveStatus)
        #expect(store.freshness == .fresh)

        try FileManager.default.removeItem(at: statusURL)
        store.reload()

        #expect(store.status == .empty)
        #expect(store.freshness == .unavailable)
        #expect(store.lastSuccessfulRead == now)
        guard case .missingFile = store.statusError else {
            Issue.record("expected missing-file error")
            return
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joy-harness-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func timestamp(_ date: Date, fractionalSeconds: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeStatus(
        timestamp: String,
        controllerBatteryLevel: Float? = 0.75
    ) -> DashboardStatus {
        DashboardStatus(
            state: PadState.busy.rawValue,
            selectedSlot: 2,
            slots: (1...6).map {
                DashboardSlot(
                    slot: $0,
                    selected: $0 == 2,
                    threadID: $0 == 2 ? "thread-2" : "",
                    title: $0 == 2 ? "Status test" : "",
                    state: $0 == 2 ? PadState.busy.rawValue : PadState.idle.rawValue
                )
            },
            controller: "Test Controller",
            controllerConnected: true,
            controllerFamily: "xbox",
            controllerTouchpad: false,
            controllerBatteryLevel: controllerBatteryLevel,
            controllerBatteryState: "discharging",
            joyConMode: "pair",
            joyConLeftBatteryLevel: 0.8,
            joyConRightBatteryLevel: 0.7,
            joyConLeftBatteryState: "charging",
            joyConRightBatteryState: "discharging",
            joyConLeftProfileElements: ["buttonA", "directionPad"],
            joyConRightProfileElements: ["buttonB", "directionPad"],
            haptics: true,
            accessibility: true,
            inputMonitoring: true,
            microphone: false,
            voiceInput: nil,
            voiceInputDefault: false,
            voiceInputTransport: nil,
            defaultVoiceInput: nil,
            rp2040: true,
            mode: "physical-codex-micro",
            note: "test",
            timestamp: timestamp
        )
    }
}
