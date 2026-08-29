import Foundation
import Testing
@testable import JoyHarness

@Suite("Codex thread provider recovery")
struct CodexThreadProviderTests {
    @Test
    func successfulInitializationBecomesHealthy() throws {
        var recovery = CodexThreadRecoveryStateMachine()

        recovery.start()
        recovery.beginRequest(id: 1, kind: .initialization, deadline: Date(timeIntervalSince1970: 5))
        let matched = recovery.receiveResponse(id: 1, succeeded: true)

        #expect(matched == .initialization)
        #expect(recovery.health == .healthy)
        #expect(recovery.pendingRequest == nil)
    }

    @Test
    func listTimeoutClearsPendingStateAndSchedulesRecovery() {
        var recovery = CodexThreadRecoveryStateMachine()
        recovery.start()
        recovery.beginRequest(id: 1, kind: .initialization, deadline: Date(timeIntervalSince1970: 5))
        _ = recovery.receiveResponse(id: 1, succeeded: true)
        recovery.beginRequest(id: 2, kind: .threadList, deadline: Date(timeIntervalSince1970: 10))

        let restartDelay = recovery.handleTimeout(at: Date(timeIntervalSince1970: 11))

        #expect(restartDelay == 0.25)
        #expect(recovery.health == .degraded)
        #expect(recovery.pendingRequest == nil)
    }

    @Test
    func restartBackoffIsBoundedAndRecoveryResetsIt() {
        var recovery = CodexThreadRecoveryStateMachine(
            initialRestartDelay: 0.25,
            maximumRestartDelay: 1
        )
        recovery.start()

        #expect(recovery.fail() == 0.25)
        let firstRestart = recovery.beginRestart()
        #expect(firstRestart)
        #expect(recovery.health == .starting)
        #expect(recovery.fail() == 0.5)
        let secondRestart = recovery.beginRestart()
        #expect(secondRestart)
        #expect(recovery.fail() == 1)
        let thirdRestart = recovery.beginRestart()
        #expect(thirdRestart)
        #expect(recovery.fail() == 1)

        let recoveryRestart = recovery.beginRestart()
        #expect(recoveryRestart)
        recovery.beginRequest(id: 9, kind: .initialization, deadline: .distantFuture)
        _ = recovery.receiveResponse(id: 9, succeeded: true)
        #expect(recovery.fail() == 0.25)
    }

    @Test
    func stopClearsPendingStateAndSuppressesRestart() {
        var recovery = CodexThreadRecoveryStateMachine()
        recovery.start()
        recovery.beginRequest(id: 1, kind: .initialization, deadline: .distantFuture)

        recovery.stop()

        #expect(recovery.health == .stopped)
        #expect(recovery.pendingRequest == nil)
        #expect(recovery.fail() == nil)
        let restarted = recovery.beginRestart()
        #expect(!restarted)
        #expect(recovery.receiveResponse(id: 1, succeeded: true) == nil)
    }

    @Test
    func mismatchedResponseDoesNotCompleteThePendingRequest() {
        var recovery = CodexThreadRecoveryStateMachine()
        recovery.start()
        recovery.beginRequest(id: 7, kind: .initialization, deadline: .distantFuture)

        #expect(recovery.receiveResponse(id: 99, succeeded: true) == nil)
        #expect(recovery.pendingRequest?.id == 7)
        #expect(recovery.health == .starting)
    }

    @Test
    func diagnosticBufferRetainsOnlyTheNewestBytes() {
        var diagnostics = CodexDiagnosticBuffer(capacity: 8)

        diagnostics.append(Data("12345".utf8))
        diagnostics.append(Data("67890".utf8))

        #expect(diagnostics.text == "34567890")
        #expect(diagnostics.byteCount == 8)
    }

    @Test
    func explicitStartAfterStopBeginsWithFreshBackoff() {
        var recovery = CodexThreadRecoveryStateMachine()
        recovery.start()
        #expect(recovery.fail() == 0.25)
        recovery.stop()

        recovery.start()

        #expect(recovery.fail() == 0.25)
    }

    @Test
    func launchWriteAndExitFailuresUseTheRecoveryStateMachine() {
        for failure in CodexProcessFailure.allCases {
            var recovery = CodexThreadRecoveryStateMachine()
            recovery.start()

            #expect(recovery.handleProcessFailure(failure) == 0.25)
            #expect(recovery.health == .failed)
            #expect(recovery.pendingRequest == nil)
        }
    }
}
