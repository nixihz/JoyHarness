import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct DualSenseMicrophoneSessionTests {
    @Test(arguments: [ControllerInput.home, .leftTrigger, .rightTrigger, .functionButtonA, .joyConSL])
    func unsupportedPTTMappingsCannotRequestPermissionOrOpenTheMicrophone(input: ControllerInput) throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.probe.pttInputs = [input]
        f.session.pttEnabled = true
        f.control([input])

        #expect(f.session.phase == .idle)
        #expect(f.probe.permissions.isEmpty)
        #expect(f.probe.hardwareStarts.isEmpty)
        #expect(f.probe.isolation.isEmpty)
        #expect(f.probe.ptt.isEmpty)
    }

    @Test func releaseWhilePermissionIsPendingCannotOpenHardwareWhenAuthorizationReturns() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.pressPTT()
        let permission = try #require(f.probe.permissions.first)
        f.control([])
        #expect(f.session.phase == .idle)
        permission(true)

        #expect(f.probe.preparations.isEmpty)
        #expect(f.probe.hardwareStarts.isEmpty)
        #expect(f.probe.ptt.isEmpty)
        #expect(f.probe.audio.isEmpty)
        #expect(f.probe.isolation == [true, false])
    }

    @Test func releasedPreparationCannotStartANewerSessionWithItsLateCompletion() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.pressPTT()
        f.grantPermission()
        let oldPreparation = try #require(f.probe.preparations.first)
        let oldGeneration = f.session.generation
        f.control([])
        #expect(f.session.phase == .idle)

        f.control([]) // re-arm from a fresh neutral report
        f.session.startManual()
        let current = f.session.generation
        #expect(current != oldGeneration)
        f.grantPermission()
        oldPreparation.completion(.success(()))
        #expect(f.probe.hardwareStarts.isEmpty)
        #expect(f.session.phase == .preparing)
        let preparation = try #require(f.probe.preparations.last)
        preparation.completion(.success(()))
        #expect(f.probe.hardwareStarts.map(\.generation) == [current])
        #expect(f.probe.ptt.isEmpty)
    }

    @Test func releaseDuringHardwareStartRejectsLateSuccessAndDecodedFrames() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.pressPTT()
        f.grantPermission()
        try f.prepareOutput()
        let start = try #require(f.probe.hardwareStarts.first)
        let generation = f.session.generation
        f.control([])
        #expect(f.session.phase == .stopping)
        #expect(f.probe.hardwareStops.map(\.generation) == [generation])
        start.completion(.success(()))
        f.session.receivePCM([0.25, -0.25], generation: generation, timestamp: f.probe.now)

        #expect(f.session.phase == .stopping)
        #expect(f.probe.ptt.isEmpty)
        #expect(f.probe.audio.isEmpty)
        #expect(f.probe.stoppedOutputs == [generation])
    }

    @Test(arguments: [false, true])
    func pttDownPrecedesTheFirstAudioRegardlessOfHardwareAndPCMCompletionOrder(hardwareFirst: Bool) throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.pressPTT()
        f.grantPermission()
        try f.prepareOutput()
        let start = try #require(f.probe.hardwareStarts.first)
        let generation = f.session.generation
        let pcm: [Float] = [0.125, -0.25, 0.5]
        if hardwareFirst {
            start.completion(.success(()))
            #expect(f.probe.ptt.isEmpty && f.probe.audio.isEmpty)
            f.session.receivePCM(pcm, generation: generation, timestamp: f.probe.now)
        } else {
            f.session.receivePCM(pcm, generation: generation, timestamp: f.probe.now)
            #expect(f.probe.ptt.isEmpty && f.probe.audio.isEmpty)
            start.completion(.success(()))
        }

        #expect(f.session.phase == .streaming)
        #expect(f.probe.deliveryEffects == [.ptt(true), .audio(generation, pcm)])
        f.session.receivePCM([0.75], generation: generation, timestamp: f.probe.now)
        #expect(f.probe.ptt == [true])
        #expect(f.probe.audio.last?.pcm == [0.75])
    }

    @Test func hardwareStopStallCannotKeepPTTHeldPastTheDrainDeadline() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.control([])
        let drain = try #require(f.probe.drains.first)
        let close = try #require(f.probe.hardwareStops.first)
        #expect(drain.cutoff == f.probe.now)
        #expect(f.probe.ptt == [true])
        f.probe.now += 0.14
        f.control([]) // keep controls alive while the hardware close is stalled
        f.probe.now += 0.149
        f.session.tick()
        #expect(f.probe.ptt == [true])
        f.probe.now += 0.002
        f.session.tick()
        #expect(f.probe.ptt == [true, false])
        #expect(f.probe.stoppedOutputs == [generation])

        close.completion(.failure(DualSenseHIDMicrophoneError.writeFailed))
        drain.completion() // delayed playback must not send a second release
        #expect(f.session.phase == .fault)
        #expect(f.probe.ptt == [true, false])
        #expect(f.probe.isolation == [true])
    }

    @Test func failedHardwareCloseReleasesPTTWithoutWaitingForPlayback() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        f.control([])
        let close = try #require(f.probe.hardwareStops.first)
        close.completion(.failure(DualSenseHIDMicrophoneError.writeFailed))

        #expect(f.session.phase == .fault)
        #expect(f.probe.ptt == [true, false])
        #expect(!f.probe.stoppedOutputs.isEmpty)
        #expect(f.probe.finishedIsolation.isEmpty)
    }

    @Test func interruptionDuringDrainImmediatelyDiscardsPendingSpeechAndReleasesPTT() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.control([])
        let cutoff = f.probe.now
        let drain = try #require(f.probe.drains.first)
        let deliveries = f.probe.audio
        #expect(f.probe.ptt == [true])

        f.session.interrupt(reason: "Screen locked")
        #expect(f.probe.ptt == [true, false])
        #expect(f.probe.stoppedOutputs == [generation])
        #expect(f.session.phase == .stopping)
        #expect(f.probe.hardwareStops.count == 1)
        #expect(f.probe.finishedIsolation.isEmpty)
        f.session.receivePCM([0.75], generation: generation, timestamp: cutoff - 0.005)
        drain.completion()
        #expect(f.probe.audio == deliveries)
        #expect(f.probe.ptt == [true, false])
        try f.confirmCloseAndNeutral()
        #expect(f.session.phase == .idle)
    }

    @Test func changingTheSourceMappingDuringDrainDiscardsTheTailAndReleasesPTT() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.control([])
        let cutoff = f.probe.now
        let deliveredAudio = f.probe.audio
        f.probe.pttInputs = []
        f.session.tick()

        #expect(f.probe.stoppedOutputs == [generation])
        #expect(f.probe.ptt == [true, false])
        f.session.receivePCM([0.75], generation: generation, timestamp: cutoff - 0.005)
        #expect(f.probe.audio == deliveredAudio)
        #expect(f.probe.hardwareStops.count == 1)
    }

    @Test func lossOfControlReportsDuringDrainReleasesBeforeTheAudioDrainDeadline() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.control([])
        f.probe.now += 0.251
        f.session.tick()

        #expect(f.probe.stoppedOutputs == [generation])
        #expect(f.probe.ptt == [true, false])
        #expect(f.session.phase == .stopping)
        #expect(f.probe.finishedIsolation.isEmpty)
    }

    @Test func aFreshReleaseCannotHideAControlGapAndTurnAnInterruptionIntoNormalDrain() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        // The main queue receives a fresh sample before its delayed timer fires.
        // The report itself is recent, but continuity from the prior report was lost.
        f.probe.now += 0.3
        f.control([])

        #expect(f.session.phase == .stopping)
        #expect(f.probe.drains.isEmpty)
        #expect(f.probe.stoppedOutputs == [generation])
        #expect(f.probe.ptt == [true, false])
    }

    @Test func manualSupplyIgnoresPTTMappingChangesAndCodexConnectionLoss() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.session.startManual()
        try f.makeReady()
        f.probe.pttInputs = []
        f.probe.pttIssue = "Codex Micro disconnected"
        f.session.tick()

        #expect(f.session.phase == .streaming)
        #expect(f.probe.ptt.isEmpty)
        #expect(f.probe.stoppedOutputs.isEmpty)
    }

    @Test func recoveryCloseIsStillRequestedWhenReconnectionPrecedesTheOldCloseFailure() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        f.session.updateAvailability(.unavailable("Disconnected"))
        let oldClose = try #require(f.probe.hardwareStops.first)
        let nextIdentity = DualSenseHIDEndpointIdentity(registryID: 19, connectionGeneration: 4)
        f.session.updateAvailability(.available(nextIdentity))
        oldClose.completion(.failure(DualSenseHIDMicrophoneError.cancelled))

        #expect(f.probe.hardwareStops.count == 2)
        #expect(f.probe.hardwareStops.last?.generation != oldClose.generation)
        #expect(f.session.phase == .stopping)
        #expect(f.probe.hardwareStarts.count == 1) // recovery must not resume capture
        #expect(f.probe.ptt == [true, false])
        #expect(f.probe.isolation.allSatisfy { $0 })
    }

    @Test(arguments: [false, true])
    func staleCloseResultCannotChangeANewerRecoveryAttemptOnTheSameConnection(oldSucceeded: Bool) throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.session.stop()
        let oldClose = try #require(f.probe.hardwareStops.first)
        f.probe.now += 2.01
        f.session.tick()
        #expect(f.session.phase == .fault)

        f.session.recoverUnexpectedAudio()
        #expect(f.session.generation == generation)
        #expect(f.probe.hardwareStops.count == 2)
        let recoveryClose = try #require(f.probe.hardwareStops.last)
        f.probe.now += 0.11
        f.control([])
        f.session.tick()
        #expect(f.session.phase == .stopping)

        // A stale success must not restore mappings, and a stale failure must
        // not fault the retry. Both callbacks have the current generation.
        oldClose.completion(oldSucceeded ? .success(()) : .failure(DualSenseHIDMicrophoneError.cancelled))
        #expect(f.session.phase == .stopping)
        #expect(f.probe.finishedIsolation.isEmpty)
        #expect(f.probe.ptt == [true, false])
        recoveryClose.completion(.success(()))
        #expect(f.session.phase == .idle)
        #expect(f.probe.finishedIsolation == [f.identity])
        #expect(f.probe.hardwareStarts.count == 1)
    }

    @Test func manualSupplyNeverUsesPTTEvenWhenTheMappingIsEnabled() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.session.pttEnabled = true
        f.session.startManual()
        try f.makeReady()
        #expect(f.session.phase == .streaming)
        #expect(!f.probe.audio.isEmpty)
        #expect(f.probe.ptt.isEmpty)
        f.control([.rightTrigger])
        f.control([])
        #expect(f.session.phase == .streaming) // other physical releases do not own manual supply
        f.session.stop()
        try f.confirmCloseAndNeutral()
        #expect(f.session.phase == .idle)
        #expect(f.probe.ptt.isEmpty)
    }

    @Test func permissionDialogPendingIsNotMistakenForPermissionRevocationOrAudioTimeout() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.session.startManual()
        f.probe.now += 5
        f.session.tick()
        #expect(f.session.phase == .preparing)
        #expect(f.probe.hardwareStarts.isEmpty)
        #expect(f.probe.stoppedOutputs.isEmpty)

        f.grantPermission()
        try f.prepareOutput()
        let start = try #require(f.probe.hardwareStarts.first)
        start.completion(.success(()))
        f.session.receivePCM([0.2, -0.2], generation: f.session.generation, timestamp: f.probe.now)
        #expect(f.session.phase == .streaming)
        #expect(f.probe.ptt.isEmpty)
        f.probe.permissionGranted = false
        f.session.tick()
        #expect(f.session.phase == .stopping)
        #expect(f.probe.stoppedOutputs == [f.session.generation])
    }

    @Test func preparationFailureReleasesIsolationWithoutSendingAHardwareCloseOrPTT() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.session.startManual()
        f.grantPermission()
        let preparation = try #require(f.probe.preparations.first)
        preparation.completion(.failure(NSError(domain: "HAL unavailable", code: 1)))

        #expect(f.session.phase == .idle)
        #expect(f.probe.hardwareStarts.isEmpty)
        #expect(f.probe.hardwareStops.isEmpty)
        #expect(f.probe.ptt.isEmpty)
        #expect(f.probe.isolation == [true, false])
        #expect(f.probe.stoppedOutputs == [f.session.generation])
    }

    @Test func failedPTTDownCannotPublishBufferedSpeechOrCreateAReleaseObligation() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        f.probe.pttDownSucceeds = false
        try f.beginReadyPTT()

        #expect(f.session.phase == .stopping)
        #expect(f.probe.ptt == [true])
        #expect(f.probe.audio.isEmpty)
        #expect(f.probe.hardwareStops.count == 1)
        f.probe.now += 2.1
        f.session.tick()
        #expect(f.probe.ptt == [true])
    }

    @Test func callbacksFromAnOldSessionCannotReleaseOrContaminateTheNextRecording() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let oldGeneration = f.session.generation
        f.control([])
        let oldDrain = try #require(f.probe.drains.first)
        let oldClose = try #require(f.probe.hardwareStops.first)
        oldDrain.completion()
        try f.confirmCloseAndNeutral()
        #expect(f.session.phase == .idle)
        f.pressPTT()
        try f.makeReady()
        let newGeneration = f.session.generation
        #expect(newGeneration != oldGeneration)
        let deliveries = f.probe.deliveryEffects
        let stoppedOutputs = f.probe.stoppedOutputs

        // The system input/reader remains the same; these delayed callbacks
        // belong to its previous source session, not the currently held key.
        oldDrain.completion()
        oldClose.completion(.failure(DualSenseHIDMicrophoneError.writeFailed))
        f.session.outputFailed(generation: oldGeneration, message: "late output failure")
        f.session.receivePCM([0.9], generation: oldGeneration, timestamp: f.probe.now)
        #expect(f.session.phase == .streaming)
        #expect(f.probe.deliveryEffects == deliveries)
        #expect(f.probe.stoppedOutputs == stoppedOutputs)
        f.session.receivePCM([0.375], generation: newGeneration, timestamp: f.probe.now)
        #expect(f.probe.audio.last == DualSenseSessionProbe.Audio(generation: newGeneration, pcm: [0.375]))
    }

    @Test func queuedPreReleaseAudioDrainsButPacketsReceivedAfterReleaseDoNotReachTheSystemInput() throws {
        let f = try DualSenseSessionFixture()
        defer { f.cleanup() }
        try f.beginReadyPTT()
        let generation = f.session.generation
        f.control([])
        let cutoff = f.probe.now
        let before = f.probe.audio.count
        f.session.receivePCM([0.125], generation: generation, timestamp: cutoff - 0.005)
        f.session.receivePCM([0.75], generation: generation, timestamp: cutoff + 0.005)
        #expect(f.probe.audio.count == before + 1)
        #expect(f.probe.audio.last?.pcm == [0.125])
        let drain = try #require(f.probe.drains.first)
        drain.completion()
        f.session.receivePCM([0.5], generation: generation, timestamp: cutoff - 0.003)
        #expect(f.probe.audio.count == before + 1)
        #expect(f.probe.ptt == [true, false])
    }
}

private enum DualSenseSessionEffect: Equatable {
    case ptt(Bool)
    case audio(UInt64, [Float])
}

@MainActor
private final class DualSenseSessionProbe {
    struct Pending {
        let generation: UInt64
        let completion: (Result<Void, Error>) -> Void
    }
    struct Drain {
        let generation: UInt64
        let cutoff: TimeInterval
        let completion: () -> Void
    }
    struct Audio: Equatable {
        let generation: UInt64
        let pcm: [Float]
    }
    var now: TimeInterval = 100
    var permissionGranted = false
    var pttDownSucceeds = true
    var pttUpSucceeds = true
    var pttInputs: Set<ControllerInput> = [.buttonA]
    var pttIssue: String?
    var permissions: [(Bool) -> Void] = []
    var preparations: [Pending] = []
    var hardwareStarts: [Pending] = []
    var hardwareStops: [Pending] = []
    var drains: [Drain] = []
    var audio: [Audio] = []
    var ptt: [Bool] = []
    var isolation: [Bool] = []
    var stoppedOutputs: [UInt64] = []
    var finishedIsolation: [DualSenseHIDEndpointIdentity] = []
    var deliveryEffects: [DualSenseSessionEffect] = []

    func services() -> DualSenseMicrophoneServices {
        DualSenseMicrophoneServices(
            requestPermission: { self.permissions.append($0) },
            prepareOutput: { self.preparations.append(.init(generation: $0, completion: $1)) },
            startHardware: { _, generation, completion in
                self.hardwareStarts.append(.init(generation: generation, completion: completion))
                return true
            },
            stopHardware: { self.hardwareStops.append(.init(generation: $0, completion: $1)) },
            finishIsolation: { self.finishedIsolation.append($0); return true },
            append: { pcm, generation in
                self.audio.append(.init(generation: generation, pcm: pcm))
                self.deliveryEffects.append(.audio(generation, pcm))
            },
            drain: { self.drains.append(.init(generation: $0, cutoff: $1, completion: $2)) },
            stopOutput: { self.stoppedOutputs.append($0) },
            lastPacketTime: { nil },
            setIsolation: { self.isolation.append($0) },
            sendPTT: { pressed in
                self.ptt.append(pressed)
                self.deliveryEffects.append(.ptt(pressed))
                return pressed ? self.pttDownSucceeds : self.pttUpSucceeds
            },
            startIssue: { nil },
            pttIssue: { self.pttIssue },
            pttInputs: { self.pttInputs },
            permissionGranted: { self.permissionGranted },
            clock: { self.now }
        )
    }
}

@MainActor
private final class DualSenseSessionFixture {
    let probe: DualSenseSessionProbe
    let identity = DualSenseHIDEndpointIdentity(registryID: 17, connectionGeneration: 3)
    let defaults: UserDefaults
    let suiteName: String
    let session: DualSenseMicrophoneSession

    init() throws {
        let probe = DualSenseSessionProbe()
        let suiteName = "DualSenseMicrophoneSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        self.probe = probe
        self.suiteName = suiteName
        self.defaults = defaults
        self.session = DualSenseMicrophoneSession(services: probe.services(), defaults: defaults, automaticTimer: false)
        session.updateAvailability(.available(identity))
        control([])
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }

    func control(_ pressed: Set<ControllerInput>) {
        probe.now += 0.01
        session.handleControl(.init(identity: identity, pressedInputs: pressed, timestamp: probe.now,
            isNeutral: pressed.isEmpty, microphoneMuted: false,
            leftTriggerValue: pressed.contains(.leftTrigger) ? 1 : 0,
            rightTriggerValue: pressed.contains(.rightTrigger) ? 1 : 0))
    }

    func pressPTT() {
        session.pttEnabled = true
        control([.buttonA])
    }

    func grantPermission() {
        probe.permissionGranted = true
        probe.permissions.removeFirst()(true)
    }

    func prepareOutput() throws {
        let pending = try #require(probe.preparations.last)
        pending.completion(.success(()))
    }

    func makeReady() throws {
        grantPermission()
        try prepareOutput()
        let pending = try #require(probe.hardwareStarts.last)
        pending.completion(.success(()))
        session.receivePCM([0.25, -0.25], generation: session.generation, timestamp: probe.now)
    }

    func beginReadyPTT() throws {
        pressPTT()
        try makeReady()
    }

    func confirmCloseAndNeutral() throws {
        let pending = try #require(probe.hardwareStops.last)
        pending.completion(.success(()))
        probe.now += 0.11
        control([])
        session.tick()
    }
}
