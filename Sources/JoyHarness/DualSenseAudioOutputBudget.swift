import Foundation

/// Reservations cover both work waiting on the audio worker and buffers already
/// scheduled on its player. A fresh epoch protects repeated generation values
/// as well as the normal monotonically increasing session generations.
final class DualSenseAudioOutputBudget: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let generation: UInt64
        fileprivate let epoch: UInt64
    }

    struct Reservation: Equatable, Sendable {
        let token: Token
        fileprivate let id: UInt64
    }

    enum Admission: Equatable, Sendable {
        case reserved(Reservation)
        case rejected(Token)
        case ignored
    }

    private let lock = NSLock()
    private let maximumFrames: Int
    private var epoch: UInt64 = 0
    private var nextReservation: UInt64 = 0
    private var current: Token?
    private var accepting = false
    private var live = false
    private var reservedFrames = 0
    private var reservations: [UInt64: (token: Token, frames: Int, scheduled: Bool)] = [:]

    init(maximumFrames: Int = 4_800) {
        precondition(maximumFrames > 0)
        self.maximumFrames = maximumFrames
    }

    func begin(generation: UInt64) -> Token {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        let token = Token(generation: generation, epoch: epoch)
        current = token
        accepting = true
        live = true
        // Retired sessions still consume memory until their queued jobs or
        // stopped player release it. A restart must not bypass the capacity.
        return token
    }

    func reserve(generation: UInt64, frames: Int) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard let token = current, token.generation == generation, accepting, live else { return .ignored }
        guard frames > 0, frames <= maximumFrames - reservedFrames else {
            cancelLocked()
            return .rejected(token)
        }
        nextReservation &+= 1
        reservations[nextReservation] = (token, frames, false)
        reservedFrames += frames
        return .reserved(Reservation(token: token, id: nextReservation))
    }

    /// Each reservation can be returned once. Old callbacks cannot refund a new
    /// session's capacity, and cancellation never creates negative accounting.
    func release(_ reservation: Reservation) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = reservations[reservation.id], entry.token == reservation.token else { return nil }
        reservations.removeValue(forKey: reservation.id)
        reservedFrames -= entry.frames
        guard current == reservation.token, live else { return nil }
        return framesLocked(reservation.token)
    }

    /// Transfer ownership from a queued PCM job to the player immediately
    /// before scheduling. Stopping the player cannot release queued jobs.
    func markScheduled(_ reservation: Reservation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == reservation.token, live,
              var entry = reservations[reservation.id], entry.token == reservation.token else { return false }
        entry.scheduled = true
        reservations[reservation.id] = entry
        return true
    }

    func isLive(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == token && live
    }

    func remainingFrames(_ token: Token) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return current == token && live ? framesLocked(token) : nil
    }

    /// Close admission while allowing all already-reserved buffers to drain.
    func beginDrain(generation: UInt64) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard let token = current, token.generation == generation, live else { return nil }
        accepting = false
        return token
    }

    @discardableResult
    func cancel(generation: UInt64) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard let token = current, token.generation == generation else { return nil }
        cancelLocked()
        return token
    }

    @discardableResult
    func cancel(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == token else { return false }
        cancelLocked()
        return true
    }

    private func cancelLocked() {
        accepting = false
        live = false
    }

    /// Called after stopping the token's player. Queued jobs retain their
    /// reservations until they execute, including those behind a failing job.
    func retire(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        let retired = reservations.filter { $0.value.token == token && $0.value.scheduled }
        for (id, entry) in retired {
            reservedFrames -= entry.frames
            reservations.removeValue(forKey: id)
        }
    }

    var outstandingFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return reservedFrames
    }

    private func framesLocked(_ token: Token) -> Int {
        reservations.values.reduce(0) { $0 + ($1.token == token ? $1.frames : 0) }
    }
}
