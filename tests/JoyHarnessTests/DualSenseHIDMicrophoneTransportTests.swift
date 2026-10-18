import Foundation
import XCTest
@testable import JoyHarness

private final class HIDWriteRecorder {
    private let lock = NSLock()
    private var storage: [[UInt8]] = []
    func append(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(bytes)
    }
    var reports: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class DualSenseHIDMicrophoneTransportTests: XCTestCase {
    private let identity = DualSenseHIDEndpointIdentity(registryID: 42, connectionGeneration: 7)

    private func sample(_ inputs: Set<ControllerInput>, time: TimeInterval) -> DualSenseHIDControlSample {
        DualSenseHIDControlSample(identity: identity, pressedInputs: inputs, timestamp: time,
            isNeutral: inputs.isEmpty, microphoneMuted: false, leftTriggerValue: 0, rightTriggerValue: 0)
    }

    func testLegacyPSParserNeverTreatsMicBytesAsPSOrL2() {
        // These bytes intentionally look like PS + fully pressed L2 if parsed
        // at control offsets, but their header identifies microphone/unknown.
        for subtype: UInt8 in [0x02, 0x03, 0x0f] {
            var report = [UInt8](repeating: 0, count: 78)
            report[0] = 0x31; report[1] = 0xa0 | subtype
            report[6] = 255; report[11] = 1
            let result = report.withUnsafeBufferPointer {
                DualSenseInputReport.psInputSample(in: $0, transport: .bluetooth, timestamp: 5)
            }
            XCTAssertNil(result)
        }
        var truncated = [UInt8](repeating: 0, count: 12)
        truncated[0] = 0x31; truncated[1] = 1; truncated[11] = 1
        XCTAssertNil(truncated.withUnsafeBufferPointer {
            DualSenseInputReport.isHomeButtonPressed(in: $0, transport: .bluetooth)
        })
    }

    func testRawPTTMappingDistinguishesOptionsAndCreateAndPreservesRelease() {
        // Sony state byte 8: bit 4 Create, bit 5 Options. JoyHarness's menu
        // binding is Options; its options binding is Create.
        func frame(_ buttons: UInt8) -> DualSenseBluetoothControlFrame {
            DualSenseBluetoothControlFrame(leftStickX: 128, leftStickY: 128,
                rightStickX: 128, rightStickY: 128, leftTrigger: 0, rightTrigger: 0,
                buttons0: 8, buttons1: buttons, buttons2: 0, microphoneMuted: false)
        }
        XCTAssertEqual(DualSenseHIDOutput.controlSample(frame(0x20), identity: identity, timestamp: 1).pressedInputs, [.menu])
        XCTAssertEqual(DualSenseHIDOutput.controlSample(frame(0x10), identity: identity, timestamp: 2).pressedInputs, [.options])
        let released = DualSenseHIDOutput.controlSample(frame(0), identity: identity, timestamp: 3)
        XCTAssertTrue(released.pressedInputs.isEmpty)
        XCTAssertTrue(released.isNeutral)
    }

    func testBusyMainQueueRetainsBothEdgesOfBriefPressWithBoundedHeartbeats() {
        let mailbox = DualSenseHIDControlMailbox(capacity: 8)
        XCTAssertTrue(mailbox.append(sample([], time: 0)))
        for index in 1...1_000 {
            XCTAssertFalse(mailbox.append(sample([.menu], time: Double(index) / 1_000)))
        }
        XCTAssertFalse(mailbox.append(sample([], time: 1.001)))
        let batch = mailbox.drain()
        XCTAssertFalse(batch.overflowed)
        XCTAssertEqual(batch.samples.map(\.timestamp), [0, 0.001, 1, 1.001])
        XCTAssertEqual(batch.samples.map(\.pressedInputs), [[], [.menu], [.menu], []])
        XCTAssertTrue(mailbox.append(sample([], time: 1.002)))
    }

    func testMailboxOverflowReportsDiscontinuityInsteadOfInventingRelease() {
        let mailbox = DualSenseHIDControlMailbox(capacity: 4)
        for index in 0..<7 {
            _ = mailbox.append(sample(index.isMultiple(of: 2) ? [.menu] : [], time: Double(index)))
        }
        let batch = mailbox.drain()
        XCTAssertTrue(batch.overflowed)
        XCTAssertTrue(batch.samples.isEmpty)
        _ = mailbox.append(sample([], time: 8))
        XCTAssertFalse(mailbox.drain().overflowed)
    }

    @MainActor
    func testCancelledQueuedEnableNeverReachesHardware() async {
        let queue = DispatchQueue(label: "test.dualsense.cancel-queued")
        let writes = HIDWriteRecorder()
        let coordinator = DualSenseHIDWriteCoordinator(queue: queue)
        coordinator.attach(generation: 1, bluetooth: true) { writes.append($0); return true }
        let cancelled = expectation(description: "queued start cancelled")
        let closed = expectation(description: "close completed")
        queue.suspend()
        XCTAssertTrue(coordinator.begin(connection: 1, session: 9, muted: false) { result in
            if case let .failure(error) = result {
                XCTAssertEqual(error as? DualSenseHIDMicrophoneError, .cancelled)
            } else { XCTFail("Cancelled start must not succeed") }
            cancelled.fulfill()
        })
        coordinator.end(connection: 1, session: 9) { result in
            if case .failure(let error) = result { XCTFail("Close failed: \(error)") }
            closed.fulfill()
        }
        queue.resume()
        await fulfillment(of: [cancelled, closed], timeout: 2)
        XCTAssertEqual(writes.reports.count, 1)
        XCTAssertEqual(writes.reports.first?[0], 0x32)
        XCTAssertEqual(writes.reports.first?[4], 0xfe)
        XCTAssertTrue(coordinator.finishIsolation(connection: 1))
    }

    @MainActor
    func testInFlightWriteKeepsIsolationUntilRealCloseAndSkipsRemainingEnable() async {
        let writes = HIDWriteRecorder()
        let entered = expectation(description: "driver call entered")
        let gate = DispatchSemaphore(value: 0)
        let coordinator = DualSenseHIDWriteCoordinator()
        coordinator.attach(generation: 2, bluetooth: true) { report in
            writes.append(report)
            if writes.reports.count == 1 {
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 3)
            }
            return true
        }
        let cancelled = expectation(description: "in-flight start cancelled")
        XCTAssertTrue(coordinator.begin(connection: 2, session: 10, muted: false) { result in
            if case .success = result { XCTFail("Start finished after cancellation") }
            cancelled.fulfill()
        })
        await fulfillment(of: [entered], timeout: 2)
        let closed = expectation(description: "real close completed")
        coordinator.end(connection: 2, session: 10) { result in
            if case .failure(let error) = result { XCTFail("Close failed: \(error)") }
            closed.fulfill()
        }
        XCTAssertFalse(coordinator.finishIsolation(connection: 2))
        XCTAssertFalse(coordinator.enqueueTrigger([0x31, 0, 0x10, 0, 0, 0]))
        XCTAssertEqual(writes.reports.count, 1)
        gate.signal()
        await fulfillment(of: [cancelled, closed], timeout: 2)
        // Initialization entered before cancellation; mic state and open did
        // not. Only the close command follows the unblocked driver call.
        XCTAssertEqual(writes.reports.map { $0[2] }, [0x90, 0x91])
        XCTAssertEqual(writes.reports.last?[4], 0xfe)
        XCTAssertTrue(coordinator.finishIsolation(connection: 2))
    }

    @MainActor
    func testWrongSessionCannotCloseAnotherOwnerAndFailedCloseDoesNotRestoreInputs() async {
        let coordinator = DualSenseHIDWriteCoordinator()
        coordinator.attach(generation: 3, bluetooth: true) { report in
            !(report[0] == 0x32 && report[2] == 0x91 && report[4] == 0xfe)
        }
        let opened = expectation(description: "start completed")
        _ = coordinator.begin(connection: 3, session: 11, muted: true) { _ in opened.fulfill() }
        await fulfillment(of: [opened], timeout: 2)
        let wrong = expectation(description: "wrong owner rejected")
        XCTAssertFalse(coordinator.end(connection: 3, session: 12) { result in
            if case .success = result { XCTFail("Wrong owner closed another session") }
            wrong.fulfill()
        })
        let failed = expectation(description: "close failure reported")
        coordinator.end(connection: 3, session: 11) { result in
            if case let .failure(error) = result {
                XCTAssertEqual(error as? DualSenseHIDMicrophoneError, .writeFailed)
            } else { XCTFail("Failed driver write reported success") }
            failed.fulfill()
        }
        await fulfillment(of: [wrong, failed], timeout: 2)
        XCTAssertFalse(coordinator.finishIsolation(connection: 3))
        XCTAssertFalse(coordinator.begin(connection: 3, session: 12, muted: false) { _ in })
    }
}
