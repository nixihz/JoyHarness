import Combine
import Foundation

struct DualSenseMicrophoneServices {
    var requestPermission: (@escaping (Bool) -> Void) -> Void
    var prepareOutput: (UInt64, @escaping (Result<Void, Error>) -> Void) -> Void
    var startHardware: (DualSenseHIDEndpointIdentity, UInt64, @escaping (Result<Void, Error>) -> Void) -> Bool
    var stopHardware: (UInt64, @escaping (Result<Void, Error>) -> Void) -> Void
    var finishIsolation: (DualSenseHIDEndpointIdentity) -> Bool
    var append: ([Float], UInt64) -> Void
    var drain: (UInt64, TimeInterval, @escaping () -> Void) -> Void
    var stopOutput: (UInt64) -> Void
    var lastPacketTime: () -> TimeInterval?
    var setIsolation: (Bool) -> Void
    var sendPTT: (Bool) -> Bool
    var startIssue: () -> String?
    var pttIssue: () -> String?
    var pttInputs: () -> Set<ControllerInput>
    var permissionGranted: () -> Bool
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
}

/// Owns supply to a system microphone, not the consumer's recording or
/// transcription. All decisions run on main; HID, decoding and render work do not.
@MainActor
final class DualSenseMicrophoneSession: ObservableObject {
    enum Phase: String { case idle, preparing, streaming, stopping, fault }
    enum Owner: Equatable { case manual, pushToTalk(ControllerInput) }
    static let supportedPTTInputs: Set<ControllerInput> = [
        .buttonA, .buttonB, .buttonX, .buttonY, .leftShoulder, .rightShoulder,
        .options, .menu, .leftThumbstickButton, .rightThumbstickButton, .touchpadButton,
        .dpadUp, .dpadRight, .dpadDown, .dpadLeft,
    ]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "尚未供音；请完成上方设置后开始。"
    @Published private(set) var deviceIssue: String? = "尚未检测到可用的蓝牙手柄。"
    @Published private(set) var level: Float = 0
    @Published private(set) var decodedFrames = 0
    @Published var pttEnabled: Bool {
        didSet {
            defaults.set(pttEnabled, forKey: Self.pttKey)
            onSettingsChange?()
            if !pttEnabled, case .pushToTalk = owner { stop(reason: "按住说话联动已关闭。") }
        }
    }
    var onSettingsChange: (() -> Void)?
    var onStateChange: (() -> Void)?
    private(set) var generation: UInt64 = 0
    private(set) var owner: Owner?
    private let services: DualSenseMicrophoneServices
    private let defaults: UserDefaults
    private static let pttKey = "dualsense.systemMicrophone.pushToTalk"
    private var availableIdentity: DualSenseHIDEndpointIdentity?
    private var identity: DualSenseHIDEndpointIdentity?
    private var latestControl: DualSenseHIDControlSample?
    private var previousPressed: Set<ControllerInput> = []
    private var sawNeutral = false
    private var hardwareRequested = false
    private var hardwareReady = false
    private var closeSucceeded = false
    private var closeAttempt: UInt64 = 0
    private var outputStopped = true
    private var pttDownSent = false
    private var releaseOutstanding = false
    private var startedAt: TimeInterval = 0
    private var stoppedAt: TimeInterval = 0
    private var lastPCMAt: TimeInterval?
    private var startupPCM: [Float] = []
    private var releaseCutoff: TimeInterval?
    private var timer: Timer?

    var isEngaged: Bool { phase != .idle }
    var isSupplying: Bool { phase == .preparing || phase == .streaming }
    var isPTTSession: Bool { if case .pushToTalk = owner { return true }; return false }

    init(services: DualSenseMicrophoneServices, defaults: UserDefaults = .standard, automaticTimer: Bool = true) {
        self.services = services
        self.defaults = defaults
        pttEnabled = defaults.bool(forKey: Self.pttKey)
        if automaticTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    func updateAvailability(_ availability: DualSenseMicrophoneAvailability) {
        let old = availableIdentity
        availableIdentity = availability.identity
        if case let .unavailable(reason) = availability { deviceIssue = reason }
        else { deviceIssue = nil }
        guard old != availableIdentity else { return }
        latestControl = nil
        previousPressed = []
        sawNeutral = false
        if isSupplying || phase == .stopping { stop(reason: "手柄连接已变化，已停止供音。") }
        // A new physical connection gets an explicit close/recovery pass, not
        // an automatic restart of recording.
        if (phase == .fault || phase == .stopping), let availableIdentity,
           phase == .fault || identity != availableIdentity {
            // Supersede an old connection's pending close. Its late callback
            // must not strand a newly connected controller in fault.
            if identity != availableIdentity { generation &+= 1 }
            identity = availableIdentity
            hardwareRequested = true
            outputStopped = true
            closeSucceeded = false
            stoppedAt = services.clock()
            transition(.stopping, "正在确认重连后的麦克风已关闭…")
            closeHardware(generation)
        }
    }

    func startManual() { start(owner: .manual) }

    func handleControl(_ sample: DualSenseHIDControlSample) {
        guard sample.identity == availableIdentity else { return }
        guard latestControl == nil || sample.timestamp > latestControl!.timestamp else { return }
        let controlGap = latestControl.map { sample.timestamp - $0.timestamp >= 0.25 } ?? false
        let oldPressed = previousPressed
        latestControl = sample
        previousPressed = sample.pressedInputs
        if controlGap { sawNeutral = sample.isNeutral }
        if sample.isNeutral { sawNeutral = true }
        guard services.clock() - sample.timestamp < 0.25 else { return }
        if controlGap, isPTTSession, isSupplying || (phase == .stopping && !outputStopped) {
            stop(reason: "手柄控制报告已中断，已丢弃待发送尾音。")
            return
        }
        if phase == .stopping, !outputStopped, sample.microphoneMuted {
            stop(reason: "手柄麦克风已静音，已丢弃待发送尾音。")
            return
        }
        if isSupplying, sample.identity == identity {
            if sample.microphoneMuted { stop(reason: "手柄麦克风已静音，已停止供音。"); return }
            if case let .pushToTalk(input) = owner, !sample.pressedInputs.contains(input) {
                stop(normalRelease: phase == .streaming, cutoff: sample.timestamp,
                     reason: "已停止供音；Codex 的录音状态请在 Codex 中确认。")
            }
        } else if phase == .idle, pttEnabled, sawNeutral, sample.pressedInputs.count == 1 {
            let edges = sample.pressedInputs.subtracting(oldPressed)
                .intersection(services.pttInputs()).intersection(Self.supportedPTTInputs)
            if edges.count == 1, let input = edges.first, services.pttIssue() == nil {
                start(owner: .pushToTalk(input))
            }
        }
    }

    private func start(owner: Owner) {
        guard phase == .idle else { return }
        if let issue = services.startIssue() { message = issue; return }
        guard let availableIdentity else { message = deviceIssue ?? "请通过蓝牙连接一只 DualSense。"; return }
        guard let control = latestControl, control.identity == availableIdentity,
              services.clock() - control.timestamp < 0.25 else {
            message = "尚未收到可信手柄状态，请松开按键后重试。"; return
        }
        guard !control.microphoneMuted else { message = "请先用手柄的静音键解除麦克风静音。"; return }
        if releaseOutstanding {
            guard services.sendPTT(false) else { message = "Codex Micro 上次释放尚未确认，请连接 RP2040 后重试。"; return }
            releaseOutstanding = false
        }
        generation &+= 1
        let current = generation
        self.owner = owner
        identity = availableIdentity
        hardwareRequested = false
        hardwareReady = false
        closeSucceeded = false
        outputStopped = false
        lastPCMAt = nil
        startupPCM.removeAll(keepingCapacity: true)
        releaseCutoff = nil
        decodedFrames = 0
        level = 0
        startedAt = services.clock()
        services.setIsolation(true)
        transition(.preparing, "正在准备 DualSense 系统麦克风…")
        services.requestPermission { [weak self] granted in
            guard let self, self.generation == current, self.phase == .preparing else { return }
            guard granted else { self.stop(reason: "麦克风权限未授权，本次未供音。"); return }
            self.services.prepareOutput(current) { [weak self] result in
                guard let self, self.generation == current, self.phase == .preparing else { return }
                switch result {
                case .failure(let error): self.stop(reason: error.localizedDescription)
                case .success:
                    self.hardwareRequested = true
                    self.startedAt = self.services.clock()
                    let accepted = self.services.startHardware(availableIdentity, current) { [weak self] result in
                        guard let self, self.generation == current, self.phase == .preparing else { return }
                        switch result {
                        case .failure(let error): self.stop(reason: error.localizedDescription)
                        case .success:
                            self.hardwareReady = true
                            self.becomeReady()
                        }
                    }
                    if !accepted { self.stop(reason: "无法开启手柄麦克风，请重新连接后重试。") }
                }
            }
        }
    }

    func receivePCM(_ pcm: [Float], generation: UInt64, timestamp: TimeInterval) {
        guard self.generation == generation else { return }
        if phase == .stopping, !outputStopped, let releaseCutoff, timestamp <= releaseCutoff {
            services.append(pcm, generation)
            return
        }
        guard isSupplying else { return }
        guard !pcm.isEmpty, pcm.allSatisfy(\.isFinite), services.clock() - timestamp < 0.5 else {
            stop(reason: "手柄音频延迟或数据异常，已停止供音。"); return
        }
        lastPCMAt = timestamp
        decodedFrames += pcm.count
        level = min(1, sqrt(pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count)) * 5)
        if phase == .preparing {
            guard startupPCM.count + pcm.count <= 4_800 else {
                stop(reason: "麦克风准备超时，已丢弃本次缓冲。"); return
            }
            startupPCM.append(contentsOf: pcm)
            becomeReady()
        } else {
            services.append(pcm, generation)
        }
    }

    private func becomeReady() {
        guard phase == .preparing, hardwareReady, !startupPCM.isEmpty else { return }
        if case let .pushToTalk(input) = owner {
            guard let control = latestControl, control.pressedInputs.contains(input),
                  services.clock() - control.timestamp < 0.25, services.pttIssue() == nil,
                  services.pttInputs().contains(input) else {
                stop(reason: "按键或 Codex 状态已变化，本次未开始联动。"); return
            }
            guard services.sendPTT(true) else { stop(reason: "Codex Micro 未连接，本次未发送按住说话。"); return }
            pttDownSent = true
        }
        transition(.streaming, "正在向系统麦克风供音；请使用 Codex 或录音应用的语音入口。")
        let pcm = startupPCM
        startupPCM.removeAll(keepingCapacity: true)
        services.append(pcm, generation)
    }

    func stop(normalRelease: Bool = false, cutoff: TimeInterval? = nil,
              reason: String = "已停止供音；外部应用已接收的声音不会被撤回。") {
        if phase == .stopping, !normalRelease {
            releaseCutoff = nil
            services.stopOutput(generation)
            outputStopped = true
            releasePTT()
            message = reason
            onStateChange?()
            return
        }
        guard phase == .preparing || phase == .streaming else { return }
        let current = generation
        stoppedAt = services.clock()
        sawNeutral = false
        level = 0
        startupPCM.removeAll(keepingCapacity: true)
        transition(.stopping, reason)
        if normalRelease && pttDownSent {
            releaseCutoff = cutoff ?? stoppedAt
            services.drain(current, releaseCutoff!) { [weak self] in
                guard let self, self.generation == current else { return }
                self.outputStopped = true
                self.releasePTT()
            }
        } else {
            services.stopOutput(current)
            outputStopped = true
            releasePTT()
        }
        if hardwareRequested { closeHardware(current) }
        else {
            closeSucceeded = true
            finishIfSafe()
        }
    }

    private func closeHardware(_ current: UInt64) {
        closeAttempt &+= 1
        let attempt = closeAttempt
        services.stopHardware(current) { [weak self] result in
            guard let self, self.generation == current, self.closeAttempt == attempt,
                  self.phase == .stopping else { return }
            switch result {
            case .success: self.closeSucceeded = true; self.finishIfSafe()
            case .failure: self.enterFault("手柄麦克风停止状态未确认，请关闭手柄后重新连接。")
            }
        }
    }

    private func releasePTT() {
        guard pttDownSent else { return }
        pttDownSent = false
        releaseOutstanding = !services.sendPTT(false)
        if releaseOutstanding { message = "已停止供音，但 Codex Micro 释放未确认；请重新连接 RP2040。" }
    }

    func tick() {
        let now = services.clock()
        if releaseOutstanding, services.pttIssue() == nil, services.sendPTT(false) { releaseOutstanding = false }
        if isSupplying {
            if hardwareRequested, !services.permissionGranted() {
                stop(reason: "麦克风权限已撤销，已停止供音。"); return
            }
            if case let .pushToTalk(input) = owner {
                if services.pttIssue() != nil || !services.pttInputs().contains(input) ||
                    now - (latestControl?.timestamp ?? 0) >= 0.25 {
                    stop(reason: "按键或 Codex 连接已中断，已停止供音。"); return
                }
            }
            if phase == .preparing, hardwareRequested, now - startedAt >= 1.5 {
                stop(reason: "未收到有效的手柄麦克风声音，本次已停止。"); return
            }
            if phase == .streaming, now - (lastPCMAt ?? startedAt) >= 0.5 {
                stop(reason: "手柄音频已停流，已停止供音。"); return
            }
        }
        if phase == .stopping {
            let lostPTT: Bool
            if case let .pushToTalk(input) = owner {
                lostPTT = services.pttIssue() != nil || !services.pttInputs().contains(input) ||
                    now - (latestControl?.timestamp ?? 0) >= 0.25
            } else { lostPTT = false }
            if !outputStopped, (!services.permissionGranted() || lostPTT) {
                stop(reason: "录音权限或 Codex 状态已变化，已丢弃待发送尾音。")
            }
            if !outputStopped, now - stoppedAt >= 0.3 {
                services.stopOutput(generation)
                outputStopped = true
                releasePTT()
            }
            finishIfSafe()
            if phase == .stopping, now - stoppedAt >= 2 {
                enterFault("手柄麦克风停止或中立状态未确认，请松开按键，必要时关闭手柄重连。")
            }
        }
    }

    private func finishIfSafe() {
        guard phase == .stopping, outputStopped, closeSucceeded else { return }
        if hardwareRequested {
            guard let identity, availableIdentity == identity, let control = latestControl,
                  control.identity == identity, control.timestamp >= stoppedAt, control.isNeutral,
                  services.clock() - control.timestamp < 0.25,
                  services.clock() - max(stoppedAt, services.lastPacketTime() ?? stoppedAt) >= 0.1,
                  services.finishIsolation(identity) else { return }
        }
        owner = nil
        identity = nil
        services.setIsolation(false)
        transition(.idle, message)
    }

    func interrupt(reason: String) {
        if isSupplying || phase == .stopping { stop(reason: reason) }
    }

    func recoverUnexpectedAudio() {
        if isSupplying || phase == .stopping {
            stop(reason: "手柄原始输入已中断，已停止供音。"); return
        }
        guard phase == .idle || phase == .fault, let availableIdentity else { return }
        if identity != availableIdentity { generation &+= 1 }
        identity = availableIdentity
        hardwareRequested = true
        outputStopped = true
        closeSucceeded = false
        stoppedAt = services.clock()
        services.setIsolation(true)
        transition(.stopping, "正在关闭遗留的手柄麦克风流…")
        closeHardware(generation)
    }

    func outputFailed(generation: UInt64, message: String) {
        guard generation == self.generation else { return }
        if phase == .idle {
            // Output teardown is asynchronous; retain a late flush failure
            // instead of leaving the settings page claiming a clean stop.
            self.message = message
            onStateChange?()
            return
        }
        stop(reason: message)
    }

    private func enterFault(_ message: String) {
        services.stopOutput(generation)
        outputStopped = true
        releasePTT()
        transition(.fault, message)
    }

    private func transition(_ phase: Phase, _ message: String) {
        self.phase = phase
        self.message = message
        onStateChange?()
    }

    deinit { timer?.invalidate() }
}
