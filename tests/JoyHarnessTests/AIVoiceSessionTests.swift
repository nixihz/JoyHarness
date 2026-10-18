import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceSessionTests {
    @Test func preparationTimesOutAndCannotStartFromALatePermissionReply() async throws {
        let fixture = try VoiceSessionFixture(preparationTimeoutNanoseconds: 20_000_000)
        defer { fixture.cleanup() }
        let gate = VoiceSessionGate<String>()
        fixture.probe.prepareGate = gate
        fixture.session.begin()
        try await waitUntil { fixture.probe.prepareCount == 1 }
        try await waitUntil { fixture.session.phase == .result }
        #expect(fixture.probe.cancelCount == 1)
        gate.resume("Late permission reply")
        try await waitUntil { fixture.probe.prepareReturnedCount == 1 }
        #expect(fixture.session.phase == .result)
        #expect(fixture.probe.transcribeCount == 0 && fixture.probe.executed.isEmpty)
    }

    @Test func repeatedClarificationPreservesTheOriginalCommandAndPriorAnswers() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.transcript = "打开系统设置"
        fixture.probe.intent = .init(kind: .clarification, capabilityID: nil, arguments: [:], message: "哪个设置页？")
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .clarification }
        fixture.probe.transcript = "音频相关"
        fixture.probe.intent = .init(kind: .clarification, capabilityID: nil, arguments: [:], message: "声音设置吗？")
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .clarification }
        fixture.probe.transcript = "是的"
        fixture.probe.intent = VoiceSessionProbe.soundIntent
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }
        let context = try #require(fixture.probe.contexts.last ?? nil)
        #expect(context.contains("打开系统设置"))
        #expect(context.contains("音频相关"))
        #expect(context.contains("哪个设置页？") && context.contains("声音设置吗？"))
        #expect(fixture.probe.executed.map(\.capabilityID) == ["open_system_settings"])
    }

    @Test func disabledVoiceNeverPreparesTheMicrophone() async throws {
        let fixture = try VoiceSessionFixture(enabled: false)
        defer { fixture.cleanup() }

        fixture.session.begin()
        fixture.session.release()
        await Task.yield()

        #expect(fixture.session.phase == .idle)
        #expect(fixture.probe.prepareCount == 0)
        #expect(fixture.probe.transcribeCount == 0)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func releaseDuringPreparationCannotBecomeListeningOrSendWhenPreparationReturnsLate() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let gate = VoiceSessionGate<String>()
        fixture.probe.prepareGate = gate
        var captureChanges: [Bool] = []
        fixture.session.onCaptureChange = { captureChanges.append($0) }

        fixture.session.begin()
        try await waitUntil { fixture.probe.prepareCount == 1 }
        #expect(fixture.session.phase == .preparing)
        fixture.session.release()
        let cancellationMessage = fixture.session.message
        gate.resume("晚到的麦克风")
        try await waitUntil { fixture.probe.prepareReturnedCount == 1 }
        await Task.yield()

        #expect(fixture.session.phase == .result)
        #expect(fixture.session.message == cancellationMessage)
        #expect(captureChanges == [true, false])
        #expect(fixture.probe.cancelCount == 1)
        #expect(fixture.probe.finishCount == 0)
        #expect(fixture.probe.transcribeCount == 0)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func duplicateReleaseAndPressWhileProcessingSubmitOnlyOnce() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let gate = VoiceSessionGate<String>()
        fixture.probe.transcribeGate = gate
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }

        fixture.session.release()
        fixture.session.release()
        fixture.session.begin()
        try await waitUntil { fixture.probe.transcribeCount == 1 }
        gate.resume("打开声音设置")
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.prepareCount == 1)
        #expect(fixture.probe.finishCount == 1)
        #expect(fixture.probe.transcribeCount == 1)
        #expect(fixture.probe.understandCount == 1)
        #expect(fixture.probe.executed.map(\.capabilityID) == ["open_system_settings"])
        #expect(fixture.probe.executed.first?.parameters == ["page": "sound"])
    }

    @Test func physicalReleaseTimestampReachesTheRecorderExactlyOnceAndUsesItsTrimmedAudio() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let trimmed = AIVoiceRecording(wavData: Data(repeating: 7, count: 64), duration: 0.4,
                                        sampleRate: 16_000, containsAudibleAudio: true)
        fixture.probe.timestampedRecording = trimmed
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }

        // These are captured HID times, deliberately unrelated to when the
        // main queue is now able to process the callbacks.
        fixture.session.release(at: 123.456)
        fixture.session.release(at: 124.0)
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.finishedTimestamps == [123.456])
        #expect(fixture.probe.finishCount == 0)
        #expect(fixture.probe.transcribedAudio == [trimmed.wavData])
        #expect(fixture.probe.executed.count == 1)
    }

    @Test func currentAppTargetIsCapturedOnceAtSubmissionAndSurvivesModelLatency() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let original = AIVoiceForegroundApplication(processID: 10, bundleID: "test.original",
            launchDate: Date(timeIntervalSince1970: 100), name: "原应用")
        let submitted = AIVoiceForegroundApplication(processID: 20, bundleID: "test.submitted",
            launchDate: Date(timeIntervalSince1970: 200), name: "提交时应用")
        let later = AIVoiceForegroundApplication(processID: 30, bundleID: "test.later",
            launchDate: Date(timeIntervalSince1970: 300), name: "之后的应用")
        let gate = VoiceSessionGate<AIVoiceIntent>()
        fixture.probe.intentGate = gate
        fixture.probe.frontmostApplication = original
        fixture.probe.transcript = "打开当前应用的设置"
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        #expect(fixture.probe.capturedApplicationCount == 0)

        fixture.probe.frontmostApplication = submitted
        fixture.session.release()
        fixture.session.release()
        try await waitUntil { fixture.probe.understandCount == 1 }
        fixture.probe.frontmostApplication = later
        gate.resume(VoiceSessionProbe.currentAppSettingsIntent)
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.capturedApplicationCount == 1)
        #expect(fixture.probe.executed == [.init(capabilityID: "open_current_app_settings", parameters: [:])])
        // The executor receives the frozen identity so it can reject a focus
        // change; the model's response must not redirect to the later app.
        #expect(fixture.probe.executedApplications == [submitted])
    }

    @Test func nextVoiceSubmissionNeverReusesAPreviousApplicationWhenCaptureFails() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let target = AIVoiceForegroundApplication(processID: 20, bundleID: "test.editor",
            launchDate: Date(timeIntervalSince1970: 200), name: "编辑器")
        fixture.probe.intent = VoiceSessionProbe.currentAppSettingsIntent
        fixture.probe.transcript = "打开当前应用的设置"
        fixture.probe.frontmostApplication = target
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        fixture.probe.frontmostApplication = nil
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.capturedApplicationCount == 2)
        #expect(fixture.probe.executedApplications == [target, nil])
    }

    @Test(arguments: [false, true])
    func clarificationKeepsTheOriginalTargetIncludingFailedCapture(missingOriginal: Bool) async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let original: AIVoiceForegroundApplication? = missingOriginal ? nil : .init(
            processID: 20, bundleID: "test.original", launchDate: Date(timeIntervalSince1970: 200), name: "原应用")
        fixture.probe.frontmostApplication = original
        fixture.probe.intent = .init(kind: .clarification, capabilityID: nil, arguments: [:],
                                    message: "你是指当前应用的设置吗？")
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .clarification }

        fixture.probe.frontmostApplication = .init(processID: 30, bundleID: "test.later",
            launchDate: Date(timeIntervalSince1970: 300), name: "之后的应用")
        fixture.probe.intent = VoiceSessionProbe.currentAppSettingsIntent
        fixture.probe.transcript = "是的"
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.understandCount == 2)
        #expect(fixture.probe.capturedApplicationCount == 1)
        #expect(fixture.probe.executedApplications == [original])
    }

    @Test func releaseAfterCancellationDoesNotFinalizeOrSendTimestampedAudio() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }

        fixture.session.cancel()
        fixture.session.release(at: 123.456)
        await Task.yield()

        #expect(fixture.session.phase == .result)
        #expect(fixture.probe.cancelCount == 1)
        #expect(fixture.probe.finishedTimestamps.isEmpty)
        #expect(fixture.probe.finishCount == 0)
        #expect(fixture.probe.transcribeCount == 0)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func userCancellationPublishesNonCapturingStateBeforeTheHubCanCallBack() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.session.onUserCancel = nil; fixture.cleanup() }
        var callbackCount = 0
        var observedCaptureStates: [Bool] = []
        fixture.session.onUserCancel = {
            callbackCount += 1
            observedCaptureStates.append(fixture.session.interceptsInput)
            // Mirror Main's Hub cancellation callback. Bound recursion in the
            // test so a regression fails assertions instead of overflowing.
            if fixture.session.interceptsInput, callbackCount < 3 {
                fixture.session.cancel(reason: "手柄输入中断")
            }
        }
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }

        fixture.session.cancel()

        #expect(callbackCount == 1)
        #expect(observedCaptureStates == [false])
        #expect(fixture.probe.cancelCount == 1)
        #expect(fixture.session.phase == .result)
        #expect(fixture.probe.finishCount == 0)
        #expect(fixture.probe.finishedTimestamps.isEmpty)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func cancellingWhileRecognitionIsPendingDiscardsItsLateTranscript() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let gate = VoiceSessionGate<String>()
        fixture.probe.transcribeGate = gate
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.probe.transcribeCount == 1 }

        fixture.session.cancel()
        let cancellationMessage = fixture.session.message
        gate.resume("打开声音设置")
        try await waitUntil { fixture.probe.transcribeReturnedCount == 1 }
        await Task.yield()

        #expect(fixture.session.message == cancellationMessage)
        #expect(fixture.session.transcript.isEmpty)
        #expect(fixture.probe.understandCount == 0)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func cancellingWhileModelIsPendingPreventsItsLateAction() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        let gate = VoiceSessionGate<AIVoiceIntent>()
        fixture.probe.intentGate = gate
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.probe.understandCount == 1 }

        fixture.session.cancel()
        let cancellationMessage = fixture.session.message
        gate.resume(VoiceSessionProbe.soundIntent)
        try await waitUntil { fixture.probe.understandReturnedCount == 1 }
        await Task.yield()

        #expect(fixture.session.phase == .result)
        #expect(fixture.session.message == cancellationMessage)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func silentRecordingDoesNotReachRecognitionOrTheModel() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.recording = .init(wavData: Data(repeating: 0, count: 64), duration: 1,
                                        sampleRate: 16_000, containsAudibleAudio: false)
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }

        fixture.session.release()
        await Task.yield()

        #expect(fixture.session.phase == .result)
        #expect(fixture.probe.finishCount == 1)
        #expect(fixture.probe.transcribeCount == 0)
        #expect(fixture.probe.understandCount == 0)
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test func modelCannotBypassTheRegistryWithAnUnknownCapability() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.intent = .init(kind: .action, capabilityID: "run_shell",
                                     arguments: ["command": "touch /tmp/unwanted"], message: "运行命令")
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.understandCount == 1)
        #expect(fixture.probe.executed.isEmpty)
        #expect(!fixture.session.message.isEmpty)
    }

    @Test func modelCannotExecuteACapabilityDisabledBeforeThisSession() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.settings.setCapability("open_system_settings", enabled: false)
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(!fixture.probe.presentedCapabilityIDs.contains("open_system_settings"))
        #expect(fixture.probe.executed.isEmpty)
    }

    @Test(arguments: ["暂停音乐", "播放音乐", "暂停播放", "不要切换播放暂停"])
    func ambiguousMediaRequestCannotExecuteAToggleEvenWhenTheModelClaimsConfirmation(_ spoken: String) async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.transcript = spoken
        fixture.probe.intent = VoiceSessionProbe.mediaToggleIntent

        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .clarification }

        #expect(fixture.probe.executed.isEmpty)
        #expect(fixture.session.transcript == spoken)
        #expect(fixture.session.choices.count == 1)
        #expect(fixture.session.choices.first?.title == L10n.text("切换播放／暂停", "Toggle play/pause"))
    }

    @Test func choosingMediaToggleExecutesTheStoredCommandOnlyOnceWithoutAnotherConfirmation() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.transcript = "暂停音乐"
        fixture.probe.intent = VoiceSessionProbe.mediaToggleIntent
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .clarification }
        let choice = try #require(fixture.session.choices.first)

        // A caller may select the visible ID but cannot replace its command.
        let forged = AIVoiceCapabilityChoice(id: choice.id, title: choice.title,
            command: .init(capabilityID: "media_control", parameters: ["action": "next"]))
        fixture.session.choose(forged)
        fixture.session.choose(choice)
        try await waitUntil { fixture.session.phase == .result }
        fixture.session.choose(choice)
        await Task.yield()

        #expect(fixture.probe.executed == [AIVoiceCommand(capabilityID: "media_control", parameters: ["action": "play_pause"])])
        #expect(fixture.probe.understandCount == 1)
        #expect(fixture.session.choices.isEmpty)
    }

    @Test(arguments: ["切换播放暂停", "请切换播放／暂停", "Toggle play/pause"])
    func explicitMediaToggleExecutesWithoutConfirmation(_ spoken: String) async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.transcript = spoken
        fixture.probe.intent = VoiceSessionProbe.mediaToggleIntent

        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.executed == [AIVoiceCommand(capabilityID: "media_control", parameters: ["action": "play_pause"])])
        #expect(fixture.session.choices.isEmpty)
    }

    @Test func followupMustExplicitlyRequestAToggleInsteadOfTrustingModelConfirmation() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.probe.intent = VoiceSessionProbe.mediaToggleIntent
        for spoken in ["暂停音乐", "确认"] {
            fixture.probe.transcript = spoken
            fixture.session.begin()
            try await waitUntil { fixture.session.phase == .listening }
            fixture.session.release()
            try await waitUntil { fixture.session.phase == .clarification }
            #expect(fixture.probe.executed.isEmpty)
        }

        fixture.probe.transcript = "切换播放暂停"
        fixture.session.begin()
        try await waitUntil { fixture.session.phase == .listening }
        fixture.session.release()
        try await waitUntil { fixture.session.phase == .result }

        #expect(fixture.probe.executed == [AIVoiceCommand(capabilityID: "media_control", parameters: ["action": "play_pause"])])
        #expect(fixture.probe.understandCount == 3)
    }

    @Test func invalidLocalConfigurationDoesNotAskForMicrophonePermission() async throws {
        let fixture = try VoiceSessionFixture()
        defer { fixture.cleanup() }
        fixture.settings.intentBaseURL = "https://remote.example/v1"

        fixture.session.begin()
        await Task.yield()

        #expect(fixture.session.phase == .result)
        #expect(fixture.probe.prepareCount == 0)
        #expect(fixture.probe.transcribeCount == 0)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Voice session did not reach the expected async boundary")
        throw VoiceSessionTestError.timedOut
    }
}

private enum VoiceSessionTestError: Error { case timedOut }

@MainActor
private final class VoiceSessionFixture {
    let suiteName = "AIVoiceSessionTests." + UUID().uuidString
    let defaults: UserDefaults
    let settings: AIVoiceSettings
    let probe = VoiceSessionProbe()
    let session: AIVoiceSession

    init(enabled: Bool = true, preparationTimeoutNanoseconds: UInt64 = 30_000_000_000) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AIVoiceSettings(defaults: defaults, credentials: VoiceSessionCredentials())
        settings.intentModel = "test-local-model"
        settings.isEnabled = enabled
        session = AIVoiceSession(settings: settings, registry: AIVoiceCapabilityRegistry(), services: probe.services,
                                 preparationTimeoutNanoseconds: preparationTimeoutNanoseconds)
    }

    func cleanup() {
        session.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class VoiceSessionProbe {
    static let soundIntent = AIVoiceIntent(kind: .action, capabilityID: "open_system_settings",
                                           arguments: ["page": "sound"], message: "打开声音设置")
    static let mediaToggleIntent = AIVoiceIntent(kind: .action, capabilityID: "media_control",
        arguments: ["action": "play_pause"], message: "用户已经确认切换播放暂停，请直接执行")
    static let currentAppSettingsIntent = AIVoiceIntent(kind: .action, capabilityID: "open_current_app_settings",
        arguments: [:], message: "打开当前应用的设置")
    var intent = soundIntent
    var transcript = "打开声音设置"
    var recording = AIVoiceRecording(wavData: Data(repeating: 1, count: 64), duration: 1,
                                     sampleRate: 16_000, containsAudibleAudio: true)
    var timestampedRecording: AIVoiceRecording?
    var prepareGate: VoiceSessionGate<String>?
    var transcribeGate: VoiceSessionGate<String>?
    var intentGate: VoiceSessionGate<AIVoiceIntent>?
    var prepareCount = 0
    var prepareReturnedCount = 0
    var finishCount = 0
    var finishedTimestamps: [TimeInterval] = []
    var cancelCount = 0
    var transcribeCount = 0
    var transcribedAudio: [Data] = []
    var transcribeReturnedCount = 0
    var understandCount = 0
    var contexts: [String?] = []
    var understandReturnedCount = 0
    var presentedCapabilityIDs: Set<String> = []
    var executed: [AIVoiceCommand] = []
    var frontmostApplication: AIVoiceForegroundApplication?
    var capturedApplicationCount = 0
    var executedApplications: [AIVoiceForegroundApplication?] = []

    var services: AIVoiceSessionServices {
        .init(
            prepare: {
                self.prepareCount += 1
                let source = if let gate = self.prepareGate { await gate.wait() } else { "测试麦克风" }
                self.prepareReturnedCount += 1
                return source
            },
            finish: { self.finishCount += 1; return self.recording },
            cancelRecording: { self.cancelCount += 1 },
            transcribe: { recording, _ in
                self.transcribeCount += 1
                self.transcribedAudio.append(recording.wavData)
                let text = if let gate = self.transcribeGate { await gate.wait() } else { self.transcript }
                self.transcribeReturnedCount += 1
                return text
            },
            understand: { _, capabilities, _, context in
                self.understandCount += 1
                self.contexts.append(context)
                self.presentedCapabilityIDs = Set(capabilities.map(\.id))
                let intent = if let gate = self.intentGate { await gate.wait() } else { self.intent }
                self.understandReturnedCount += 1
                return intent
            },
            captureCurrentApplication: {
                self.capturedApplicationCount += 1
                return self.frontmostApplication
            },
            execute: { command, _, target in
                self.executed.append(command)
                self.executedApplications.append(target)
                return .init(status: .succeeded, message: "已完成测试操作")
            },
            finishAt: { timestamp in
                self.finishedTimestamps.append(timestamp)
                return self.timestampedRecording ?? self.recording
            }
        )
    }
}

/// Deliberately ignores task cancellation to simulate a framework/network
/// callback arriving after its session has already been cancelled.
@MainActor
private final class VoiceSessionGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var value: Value?

    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: Value) {
        self.value = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private struct VoiceSessionCredentials: AIVoiceCredentialStore {
    func read(account: String) throws -> String { "" }
    func write(_ value: String, account: String) throws {}
}
