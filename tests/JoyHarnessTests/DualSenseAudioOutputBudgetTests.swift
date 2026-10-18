import Foundation
import Testing
@testable import JoyHarness

struct DualSenseAudioOutputBudgetTests {
    private typealias Budget = DualSenseAudioOutputBudget

    @Test func concurrentProducersCannotOverfillABlockedWorker() throws {
        let budget = Budget()
        let token = budget.begin(generation: 1)
        let results = AdmissionResults()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            results.append(budget.reserve(generation: 1, frames: 480))
        }
        let reservations = results.values.compactMap { admission -> Budget.Reservation? in
            guard case .reserved(let reservation) = admission else { return nil }
            return reservation
        }
        #expect(reservations.count == 10)
        #expect(budget.outstandingFrames == 4_800)
        #expect(!budget.isLive(token))
        // Stopping an empty player cannot free PCM closures still in the queue.
        budget.retire(token)
        #expect(budget.outstandingFrames == 4_800)
        DispatchQueue.concurrentPerform(iterations: reservations.count) { index in
            _ = budget.release(reservations[index])
        }
        #expect(budget.outstandingFrames == 0)
    }

    @Test func workerFailureRetiresPlaybackButKeepsLaterQueuedPCMCharged() throws {
        let budget = Budget(maximumFrames: 960)
        let old = budget.begin(generation: 1)
        let playing = try reserve(budget, generation: 1)
        let queued = try reserve(budget, generation: 1)
        #expect(budget.markScheduled(playing))
        budget.cancel(old)
        budget.retire(old)
        #expect(budget.outstandingFrames == 480)

        let current = budget.begin(generation: 2)
        let fresh = try reserve(budget, generation: 2)
        #expect(budget.outstandingFrames == 960)
        #expect(budget.release(playing) == nil) // late callback after player.stop
        #expect(budget.remainingFrames(current) == 480)
        #expect(!budget.markScheduled(queued))
        #expect(budget.release(queued) == nil) // the old queued closure exits
        #expect(budget.outstandingFrames == 480)
        #expect(budget.release(fresh) == 0)
    }

    @Test func cancellationRejectsConcurrentCallersBeforeWorkerStops() throws {
        let budget = Budget()
        let token = budget.begin(generation: 1)
        let waiting = try reserve(budget, generation: 1)
        budget.cancel(generation: 1)
        let results = AdmissionResults()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            results.append(budget.reserve(generation: 1, frames: 480))
        }
        #expect(results.values.allSatisfy { $0 == .ignored })
        #expect(!budget.markScheduled(waiting))
        #expect(!budget.isLive(token))
        #expect(budget.outstandingFrames == 480)
        #expect(budget.release(waiting) == nil)
        #expect(budget.outstandingFrames == 0)
    }

    @Test func repeatedRestartCannotResetCapacityWhileOldJobsRemainQueued() throws {
        let budget = Budget(maximumFrames: 960)
        let first = budget.begin(generation: 1)
        let one = try reserve(budget, generation: 1)
        budget.cancel(first)
        let second = budget.begin(generation: 2)
        let two = try reserve(budget, generation: 2)
        budget.cancel(second)
        let third = budget.begin(generation: 3)
        #expect(budget.reserve(generation: 3, frames: 480) == .rejected(third))
        #expect(budget.outstandingFrames == 960)
        _ = budget.release(one)
        _ = budget.release(two)
        let fourth = budget.begin(generation: 4)
        _ = try reserve(budget, generation: 4)
        #expect(budget.remainingFrames(fourth) == 480)
    }

    @Test func reusedGenerationAndDuplicateCallbacksCannotRefundNewAudio() throws {
        let budget = Budget()
        let old = budget.begin(generation: 7)
        let stale = try reserve(budget, generation: 7)
        #expect(budget.markScheduled(stale))
        budget.cancel(old)
        let current = budget.begin(generation: 7)
        let fresh = try reserve(budget, generation: 7)
        #expect(old != current)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            _ = budget.release(stale)
        }
        #expect(budget.remainingFrames(current) == 480)
        #expect(budget.outstandingFrames == 480)
        #expect(!budget.cancel(old))
        #expect(budget.isLive(current))
        #expect(budget.release(fresh) == 0)
    }

    @Test func drainKeepsPendingPlaybackLiveWhileClosingAdmission() throws {
        let budget = Budget()
        let token = budget.begin(generation: 1)
        let playing = try reserve(budget, generation: 1)
        let queued = try reserve(budget, generation: 1)
        #expect(budget.markScheduled(playing))
        #expect(budget.beginDrain(generation: 1) == token)
        #expect(budget.reserve(generation: 1, frames: 480) == .ignored)
        #expect(budget.markScheduled(queued))
        #expect(budget.release(playing) == 480)
        #expect(budget.release(queued) == 0)
        #expect(budget.isLive(token))
    }

    private func reserve(_ budget: Budget, generation: UInt64) throws -> Budget.Reservation {
        var reservation: Budget.Reservation?
        if case .reserved(let value) = budget.reserve(generation: generation, frames: 480) {
            reservation = value
        }
        return try #require(reservation)
    }

    private final class AdmissionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Budget.Admission] = []

        func append(_ admission: Budget.Admission) {
            lock.lock(); defer { lock.unlock() }
            storage.append(admission)
        }

        var values: [Budget.Admission] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
