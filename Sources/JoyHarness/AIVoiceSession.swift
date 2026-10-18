import AppKit
import Combine
import Foundation

enum AIVoicePhase: Equatable {
    case idle, preparing, listening, processing, executing, clarification, result
}

/// The async boundary is injectable so cancellation, release-before-ready and
/// late network replies can be checked without recording or sending user data.
@MainActor
struct AIVoiceSessionServices {
    var prepare: () async throws -> String
    var finish: () throws -> AIVoiceRecording
    var cancelRecording: () -> Void
    var transcribe: (AIVoiceRecording, AIVoiceProviderConfiguration) async throws -> String
    var understand: (String, [AIVoiceCapabilityDescriptor], AIVoiceProviderConfiguration, String?) async throws -> AIVoiceIntent
    var captureCurrentApplication: () -> AIVoiceForegroundApplication?
    var execute: (AIVoiceCommand, UUID, AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult
    var finishAt: ((TimeInterval) throws -> AIVoiceRecording)? = nil
}

@MainActor
final class AIVoiceSession: ObservableObject {
    let settings: AIVoiceSettings
    let registry: AIVoiceCapabilityRegistry
    @Published private(set) var phase: AIVoicePhase = .idle
    @Published private(set) var message = ""
    @Published private(set) var transcript = ""
    @Published private(set) var inputName = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var choices: [AIVoiceCapabilityChoice] = []
    var onCaptureChange: ((Bool) -> Void)?
    var onUserCancel: (() -> Void)?
    var onPresentationChange: (() -> Void)?

    private var services: AIVoiceSessionServices
    private var operation: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var preparationLimit: Task<Void, Never>?
    private let preparationTimeoutNanoseconds: UInt64
    private var resultDismissal: Task<Void, Never>?
    private var generation = UUID()
    private var configuration: AIVoiceProviderConfiguration?
    private var clarificationContext: String?
    private var submittedApplication: AIVoiceForegroundApplication?
    private var recorder: AIVoiceAudioRecorder?
    private static let mediaToggleChoiceID = "confirm-media-play-pause"
    private static let mediaToggleCommand = AIVoiceCommand(
        capabilityID: "media_control", parameters: ["action": "play_pause"]
    )

    var interceptsInput: Bool { phase == .preparing || phase == .listening }
    var isBusy: Bool { interceptsInput || phase == .processing || phase == .executing }
    var isPresented: Bool { phase != .idle }

    init(settings: AIVoiceSettings, registry: AIVoiceCapabilityRegistry, services: AIVoiceSessionServices,
         preparationTimeoutNanoseconds: UInt64 = 30_000_000_000) {
        self.settings = settings
        self.registry = registry
        self.services = services
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
    }

    convenience init(settings: AIVoiceSettings) {
        let recorder = AIVoiceAudioRecorder()
        let provider = AIVoiceProvider()
        let registry = AIVoiceCapabilityRegistry()
        self.init(settings: settings, registry: registry, services: AIVoiceSessionServices(
            prepare: {
                let configuration = try settings.configuration()
                if configuration.route != .cloud {
                    if let reason = AIVoiceProvider.localSpeechAvailability(localeIdentifier: configuration.localeIdentifier) {
                        throw AIVoiceProviderError.localSpeechUnavailable(reason)
                    }
                    guard await AIVoiceProvider.requestLocalSpeechPermission() else {
                        throw AIVoiceProviderError.speechPermission
                    }
                    try Task.checkCancellation()
                }
                guard await AIVoiceAudioRecorder.requestMicrophonePermission() else {
                    throw NSError(domain: "AIVoice", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        L10n.text("麦克风权限未开启。请在系统设置中允许 Joy Harness 使用麦克风。", "Allow Joy Harness to use the microphone in System Settings.")])
                }
                try Task.checkCancellation()
                try recorder.start()
                return recorder.inputName
            },
            finish: { try recorder.finish() },
            cancelRecording: { recorder.cancel() },
            transcribe: { try await provider.transcribe($0, configuration: $1) },
            understand: { try await provider.understand($0, capabilities: $1, configuration: $2, context: $3) },
            captureCurrentApplication: { registry.captureCurrentApplication() },
            execute: { await registry.execute($0, requestID: $1, currentApplication: $2) },
            finishAt: { try recorder.finish(at: $0) }
        ))
        self.recorder = recorder
        recorder.onLevel = { [weak self] value in
            guard self?.phase == .listening else { return }
            self?.level = value
        }
        recorder.onFailure = { [weak self] reason in self?.cancel(reason: reason) }
    }

    func begin() {
        guard settings.isEnabled else { return }
        // A second press while processing never queues or replaces the command.
        guard !isBusy else {
            if phase == .processing || phase == .executing {
                transition(phase, message: L10n.text("上一条指令仍在处理，请稍候。", "The previous command is still processing. Please wait."))
            }
            return
        }
        operation?.cancel()
        resultDismissal?.cancel()
        generation = UUID()
        let id = generation
        let context = phase == .clarification ? clarificationContext : nil
        clarificationContext = context
        if context == nil { submittedApplication = nil }
        choices = []
        transcript = ""
        level = 0
        do {
            configuration = try settings.configuration()
            registry.enabledCapabilityIDs = Set(registry.allDescriptors.map(\.id)).subtracting(settings.disabledCapabilities)
        } catch {
            showResult(error.localizedDescription)
            return
        }
        transition(.preparing, message: L10n.text("正在准备麦克风…", "Preparing microphone…"))
        preparationLimit?.cancel()
        preparationLimit = Task { [weak self] in
            guard let timeout = self?.preparationTimeoutNanoseconds else { return }
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let self, self.generation == id, self.phase == .preparing else { return }
            self.cancel(reason: L10n.text("麦克风准备超时，本次未发送。请检查权限后重试。",
                                         "Microphone preparation timed out. Check permissions and try again. Nothing was sent."))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.services.prepare()
                guard self.generation == id, self.phase == .preparing, !Task.isCancelled else { return }
                self.preparationLimit?.cancel()
                self.preparationLimit = nil
                self.inputName = source
                self.transition(.listening, message: L10n.text("正在聆听，松开 L2 发送", "Listening — release L2 to send"))
                self.recordingLimit = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    self.cancel(reason: L10n.text("已达到 60 秒录音上限，本次未发送。", "Recording reached 60 seconds and was not sent."))
                }
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.services.cancelRecording()
                self.showResult(error.localizedDescription)
            }
        }
    }

    func release(at timestamp: TimeInterval? = nil) {
        guard phase == .listening else {
            if phase == .preparing { cancel(reason: L10n.text("麦克风尚未就绪，本次未发送。", "Microphone was not ready. Nothing was sent.")) }
            return
        }
        recordingLimit?.cancel()
        recordingLimit = nil
        // Freeze the local target when handling submission, before recognition
        // or model latency. A clarification continues the same command and
        // preserves its original target, including a failed (nil) capture.
        // The target is never supplied by the model or added to its prompt.
        if clarificationContext == nil {
            submittedApplication = services.captureCurrentApplication()
        }
        let recording: AIVoiceRecording
        do {
            if let timestamp, let finishAt = services.finishAt { recording = try finishAt(timestamp) }
            else { recording = try services.finish() }
        }
        catch { services.cancelRecording(); showResult(error.localizedDescription); return }
        guard recording.containsAudibleAudio else {
            showResult(L10n.text("没有听到有效语音，请再试一次。", "No speech was heard. Please try again."))
            return
        }
        guard let configuration else { cancel(); return }
        let id = generation
        transition(.processing, message: L10n.text("正在识别…", "Recognizing speech…"))
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.services.transcribe(recording, configuration)
                guard self.generation == id, !Task.isCancelled else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.showResult(L10n.text("没有识别到指令，请再试一次。", "No command was recognized.")); return
                }
                self.transcript = trimmed
                self.transition(.processing, message: L10n.text("正在理解…", "Understanding…"))
                let intent = try await self.services.understand(trimmed, self.registry.descriptors, configuration, self.clarificationContext)
                guard self.generation == id, !Task.isCancelled else { return }
                switch intent.kind {
                case .action:
                    guard let capability = intent.capabilityID else {
                        self.showResult(L10n.text("模型没有返回可执行能力。", "The model did not return an executable capability.")); return
                    }
                    await self.perform(AIVoiceCommand(capabilityID: capability, parameters: intent.arguments), id: id)
                case .clarification:
                    self.askClarification(intent.message)
                case .unsupported:
                    self.showResult(L10n.text("这项指令尚未支持，本次未执行。", "This command is not supported. Nothing was executed.") + " " + intent.message)
                }
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.showResult(error.localizedDescription)
            }
        }
    }

    func choose(_ choice: AIVoiceCapabilityChoice) {
        guard phase == .clarification,
              let selected = choices.first(where: { $0.id == choice.id }) else { return }
        choices = []
        let id = generation
        let confirmedToggle = selected.id == Self.mediaToggleChoiceID && selected.command == Self.mediaToggleCommand
        operation = Task { [weak self] in
            await self?.perform(selected.command, id: id, mediaToggleConfirmed: confirmedToggle)
        }
    }

    private func perform(_ command: AIVoiceCommand, id: UUID, mediaToggleConfirmed: Bool = false) async {
        guard generation == id, !Task.isCancelled else { return }
        switch registry.resolve(command) {
        case .ready(let resolved, let summary):
            if resolved == Self.mediaToggleCommand, !mediaToggleConfirmed, !explicitlyRequestsMediaToggle {
                let prompt = L10n.text(
                    "目前只能切换播放／暂停，无法确认当前播放状态。点选下方按钮，或重新说“切换播放暂停”。",
                    "Only play/pause toggling is available; the current playback state is unknown. Choose the button below or say “toggle play/pause”."
                )
                choices = [.init(id: Self.mediaToggleChoiceID,
                                 title: L10n.text("切换播放／暂停", "Toggle play/pause"),
                                 command: Self.mediaToggleCommand)]
                askClarification(prompt)
                return
            }
            transition(.executing, message: summary)
            let result = await services.execute(resolved, id, submittedApplication)
            guard generation == id, !Task.isCancelled else { return }
            showResult(result.message)
        case .needsChoice(let prompt, let candidates):
            choices = candidates
            askClarification(prompt)
        case .unavailable(let reason):
            showResult(reason)
        }
    }

    private func askClarification(_ prompt: String) {
        let turn = "Previous request: \(transcript)\nQuestion: \(prompt)"
        let context = clarificationContext.map { $0 + "\n" + turn } ?? turn
        guard context.count <= 20_000 else {
            showResult(L10n.text("追问内容过长，请重新说出完整指令。", "Please start again with the complete command; the clarification is too long."))
            return
        }
        clarificationContext = context
        transition(.clarification, message: prompt)
    }

    /// Recognize only explicit toggle phrases. Unknown wording needs the
    /// fixed choice; a model's claim that the user confirmed is not consent.
    private var explicitlyRequestsMediaToggle: Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var phrase = transcript.lowercased().components(separatedBy: separators).joined()
        for prefix in ["请帮我", "帮我", "请", "please"] where phrase.hasPrefix(prefix) {
            phrase.removeFirst(prefix.count)
            break
        }
        if phrase.hasSuffix("一下") { phrase.removeLast(2) }
        return ["切换播放暂停", "播放暂停", "切换播放", "切换暂停", "切换播放状态",
                "toggleplaypause", "toggleplayback", "playpause"].contains(phrase)
    }

    func cancel(reason: String? = nil) {
        guard phase != .idle else { return }
        let executing = phase == .executing
        generation = UUID()
        operation?.cancel()
        operation = nil
        recordingLimit?.cancel()
        recordingLimit = nil
        preparationLimit?.cancel()
        preparationLimit = nil
        services.cancelRecording()
        configuration = nil
        clarificationContext = nil
        choices = []
        level = 0
        showResult(reason ?? (executing
            ? L10n.text("已停止后续处理；已经打开的应用或窗口不会撤回。", "Further work stopped. Apps or windows already opened remain open.")
            : L10n.text("已取消", "Cancelled")))
        // Publish the non-recording phase before consuming the held L2 chord:
        // its cancel callback must not recursively cancel this same session.
        onUserCancel?()
    }

    func settingsChanged() {
        if isBusy || phase == .clarification {
            cancel(reason: L10n.text("配置已变更，本次语音已取消。", "Configuration changed. This voice command was cancelled."))
        }
    }

    func dismiss() {
        if isBusy || phase == .clarification { cancel() }
        resultDismissal?.cancel()
        resultDismissal = nil
        transcript = ""
        clarificationContext = nil
        choices = []
        transition(.idle, message: "")
    }

    func handleInput(_ input: ControllerInput, pressed: Bool) -> Bool {
        // PS is owned by the input state machine. The authoritative HID path
        // independently tracks L2 release even while mapped input is captured.
        guard input != .home, interceptsInput || phase == .clarification else { return false }
        if pressed && (input == .buttonB || input == .functionButtonB) { cancel() }
        return true
    }

    func stop() {
        if phase != .idle { cancel() }
        dismiss()
    }

    private func showResult(_ text: String) {
        preparationLimit?.cancel()
        preparationLimit = nil
        resultDismissal?.cancel()
        configuration = nil
        clarificationContext = nil
        submittedApplication = nil
        choices = []
        level = 0
        transition(.result, message: text.isEmpty ? L10n.text("没有可执行的结果。", "No executable result.") : text)
        let id = generation
        resultDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.generation == id, self.phase == .result else { return }
            self.dismiss()
        }
    }

    private func transition(_ next: AIVoicePhase, message: String) {
        let wasCapturing = interceptsInput
        phase = next
        self.message = message
        if wasCapturing != interceptsInput { onCaptureChange?(interceptsInput) }
        onPresentationChange?()
    }
}
