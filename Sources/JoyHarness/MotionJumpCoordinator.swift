import AppKit
import Combine
import GameController

struct MotionJumpDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum MotionJumpPhase { case idle, recording, testing }

/// Owns sensor subscriptions and the draft calibration. All input is delivered
/// on the main queue, just like ButtonBridge's mapped input.
final class MotionJumpCoordinator: ObservableObject {
    let settings: MotionJumpSettings
    @Published private(set) var devices: [MotionJumpDevice] = []
    @Published var selectedDeviceID: String? {
        didSet { if oldValue != selectedDeviceID { stopSession() } }
    }
    @Published private(set) var phase: MotionJumpPhase = .idle
    @Published private(set) var statusText = L10n.text("先录制四个方向的手势，建立个人校准。", "Record your four gestures to create a personal calibration.")
    @Published private(set) var progressText = ""
    @Published private(set) var lastResultText = ""
    @Published private(set) var previewQuadrant: MotionJumpQuadrant?
    @Published private(set) var draft: MotionJumpProfile?
    @Published private(set) var canApply = false
    @Published private(set) var recordedQuadrants: Set<MotionJumpQuadrant> = []
    @Published private(set) var hasOrdinarySample = false
    @Published private(set) var validationSummary = ""
    @Published var isTestingActualPointer = false {
        didSet { if oldValue != isTestingActualPointer { cancelAll() } }
    }

    var suspendDevice: ((String) -> Void)?
    var capturePointerTarget: (() -> MotionJumpPointerTarget?)?
    var jumpPointer: ((MotionJumpQuadrant, MotionJumpPointerTarget) -> Bool)?
    var canMovePointer: () -> Bool = { true }

    var isTestComplete: Bool {
        phase == .testing && !testPrompts.isEmpty && step >= testPrompts.count
    }

    /// A read-only ownership query for independent button transports. They
    /// must not replay L2 edges already delivered through GameController.
    func isCapturing(deviceID: String) -> Bool {
        phase != .idle && selectedDeviceID == deviceID && mappingMode
    }

    private struct Sensor {
        let source: any MotionJumpSensorSource
        let generation: UUID
    }
    private struct Capture {
        let startedAt: TimeInterval
        let bias: SIMD3<Double>
        let target: MotionJumpPointerTarget?
        var samples: [MotionJumpSample]
    }
    private var sources: [String: any MotionJumpSensorSource] = [:]
    private var sensors: [String: Sensor] = [:]
    private var latest: [String: MotionJumpSample] = [:]
    private var idleSamples: [String: [MotionJumpSample]] = [:]
    private var captures: [String: Capture] = [:]
    private var held: Set<String> = []
    private var blockedUntilRelease: Set<String> = []
    private var mappingMode = true
    private var microphoneIsolated = false
    private var positiveSamples: [MotionJumpQuadrant: [MotionJumpTrace]] = [:]
    private var negativeSamples: [MotionJumpTrace] = []
    private var recordingPrompts: [MotionJumpQuadrant?] = []
    private var isRerecordingReference = false
    private(set) var testPrompts: [MotionJumpQuadrant?] = []
    private var step = 0
    private var testCorrect = 0
    private var testWrong = 0
    private var testMissed = 0
    private var testFalseTriggers = 0
    private weak var sessionWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var watchdog: Timer?

    init(settings: MotionJumpSettings = MotionJumpSettings()) {
        self.settings = settings
        subscription = settings.objectWillChange.sink { [weak self] _ in
            self?.cancelAll()
            DispatchQueue.main.async { [weak self] in self?.refreshSensors() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.phase != .idle,
                  let window = note.object as? NSWindow, window === self.sessionWindow else { return }
            self.stopSession()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard self?.phase != .idle else { return }
            self?.stopSession()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelAll()
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        watchdog?.invalidate()
        for sensor in sensors.values { sensor.source.stop() }
    }

    func updateControllers(_ available: [GCController]) {
        let availableSources = available.compactMap { controller -> (any MotionJumpSensorSource)? in
            let id = ControllerHub.motionJumpDeviceID(controller)
            if let existing = sources[id] as? GameControllerMotionJumpSensorSource,
               existing.belongs(to: controller) { return existing }
            return GameControllerMotionJumpSensorSource(controller)
        }
        updateSources(availableSources)
    }

    func updateSources(_ available: [any MotionJumpSensorSource]) {
        sources = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        held.formIntersection(sources.keys)
        blockedUntilRelease.formIntersection(sources.keys)
        devices = available.enumerated().map { index, source in
            MotionJumpDevice(id: source.id, name: "\(source.name)\(available.count > 1 ? " · \(index + 1)" : "")")
        }
        if !devices.contains(where: { $0.id == selectedDeviceID }) { selectedDeviceID = devices.first?.id }
        refreshSensors()
    }

    func setOperationMode(_ mode: ControllerOperationMode) {
        mappingMode = mode == .mapping
        if !mappingMode { stopSession() }
        cancelAll()
        refreshSensors()
    }

    /// DualSense audio also reaches GameController's motion decoder. Stop its
    /// independent source subscriptions, invalidate queued samples and discard
    /// bias history; cancelling only the gesture would retain audio-derived
    /// gyro values for the next capture.
    func setDualSenseMicrophoneIsolation(_ isolated: Bool) {
        guard microphoneIsolated != isolated else { return }
        microphoneIsolated = isolated
        cancelAll()
        latest.removeAll()
        idleSamples.removeAll()
        held.removeAll()
        blockedUntilRelease.removeAll()
        if isolated { stopSession() }
        refreshSensors()
    }

    func stop() {
        stopSession()
        sources.removeAll()
        devices = []
        selectedDeviceID = nil
        refreshSensors()
    }

    /// Returns true only while this device belongs to the calibration/test UI.
    func handleInput(deviceID: String, input: MotionJumpInputSnapshot) -> Bool {
        guard !microphoneIsolated else { return true }
        guard sources[deviceID] != nil else { return false }
        let consuming = phase != .idle && selectedDeviceID == deviceID
        let wasDown = held.contains(deviceID)
        // Keep one capture alive as finger pressure varies. Only a full release
        // commits the gesture; crossing the press threshold again must not split it.
        let down = wasDown ? input.triggerValue > 0.1 : input.triggerValue >= 0.55
        if down { held.insert(deviceID) } else { held.remove(deviceID) }

        if !input.allowsGesture || input.hasConflictingInput || !mappingMode || !canMovePointer() {
            cancel(deviceID: deviceID)
            if consuming, down {
                lastResultText = input.hasConflictingInput
                    ? L10n.text("本次使用了其他按键、摇杆或触控板，已取消。", "Cancelled: another button, stick, or touchpad was used.")
                    : L10n.text("请使用映射模式，并将 L2 设为功能层；拖拽时不能定位。", "Use Mapping mode with L2 as the function modifier. Release any mouse drag.")
            }
        }
        if !down {
            defer { blockedUntilRelease.remove(deviceID) }
            if wasDown, let capture = captures.removeValue(forKey: deviceID), !blockedUntilRelease.contains(deviceID) {
                finish(capture, deviceID: deviceID, releasedAt: input.timestamp)
            }
            return consuming
        }
        guard !wasDown, !blockedUntilRelease.contains(deviceID), input.allowsGesture,
              !input.hasConflictingInput, mappingMode, canMovePointer(),
              consuming || (settings.enabled && settings.profile != nil) else { return consuming }
        guard let sample = latest[deviceID], input.timestamp - sample.timestamp <= MotionJumpRecognizer.maximumSampleGap,
              input.timestamp >= sample.timestamp else {
            blockedUntilRelease.insert(deviceID)
            if consuming { lastResultText = L10n.text("正在等待体感数据，请松开 L2 后重试。", "Waiting for motion data. Release L2 and try again.") }
            return consuming
        }
        let bias = stationaryBias(deviceID: deviceID)
        captures[deviceID] = Capture(startedAt: input.timestamp, bias: bias,
            target: capturePointerTarget?(), samples: [MotionJumpSample(timestamp: input.timestamp, rotation: sample.rotation - bias)])
        previewQuadrant = nil
        return consuming
    }

    func cancel(deviceID: String) {
        captures.removeValue(forKey: deviceID)
        if held.contains(deviceID) { blockedUntilRelease.insert(deviceID) }
    }

    func cancelAll() {
        captures.removeAll()
        blockedUntilRelease.formUnion(held)
    }

    func startCalibration() {
        guard beginSession() else { return }
        positiveSamples = [:]
        negativeSamples = []
        recordedQuadrants = []
        hasOrdinarySample = false
        recordingPrompts = [nil] + MotionJumpQuadrant.allCases.map(Optional.some)
        isRerecordingReference = false
        draft = nil
        canApply = false
        phase = .recording
        step = 0
        updatePrompt()
        refreshSensors()
    }

    /// Replace just one reference. Keep the previous sample until a valid
    /// replacement arrives, so a sensor interruption never loses other work.
    func rerecordGesture(_ quadrant: MotionJumpQuadrant?) {
        guard !positiveSamples.isEmpty || !negativeSamples.isEmpty,
              beginSession() else { return }
        recordingPrompts = [quadrant]
        isRerecordingReference = true
        step = 0
        canApply = false
        phase = .recording
        updatePrompt()
        refreshSensors()
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        guard isRerecordingReference else {
            stopSession()
            return
        }
        cancelAll()
        phase = .idle
        isRerecordingReference = false
        isTestingActualPointer = false
        sessionWindow = nil
        previewQuadrant = nil
        progressText = ""
        lastResultText = ""
        canApply = draft?.isValid == true
        statusText = L10n.text("已取消本次补录，之前的参考和调整已保留。", "Re-recording cancelled. Your previous references and adjustments are preserved.")
        refreshSensors()
    }

    func startTesting() {
        guard (recordedQuadrants.isEmpty && !hasOrdinarySample) || draft != nil else {
            statusText = L10n.text("请先补录需要调整的方向；其他参考已保留。", "Re-record the direction that needs adjusting. Your other references are preserved.")
            return
        }
        guard let profile = draft ?? settings.profile else {
            statusText = L10n.text("请先录制四个方向。", "Record the four directions first.")
            return
        }
        guard beginSession() else { return }
        isTestingActualPointer = false
        draft = profile
        canApply = profile.isValid
        testPrompts = (MotionJumpQuadrant.allCases.map { Optional($0) } + [nil, nil]).shuffled()
        step = 0
        testCorrect = 0; testWrong = 0; testMissed = 0; testFalseTriggers = 0
        phase = .testing
        updatePrompt()
        refreshSensors()
    }

    func endTesting() {
        guard phase == .testing else { return }
        cancelAll()
        phase = .idle
        isTestingActualPointer = false
        sessionWindow = nil
        previewQuadrant = nil
        progressText = ""
        canApply = draft?.isValid == true
        statusText = L10n.text("测试已结束。可以调整、补录或应用当前校准。", "Test ended. Adjust, re-record, or apply the current calibration.")
        refreshSensors()
    }

    func stopSession() {
        cancelAll()
        phase = .idle
        isTestingActualPointer = false
        sessionWindow = nil
        canApply = false
        draft = nil
        positiveSamples = [:]; negativeSamples = []
        isRerecordingReference = false
        recordedQuadrants = []; hasOrdinarySample = false
        progressText = ""
        validationSummary = ""
        previewQuadrant = nil
        lastResultText = ""
        statusText = settings.profile == nil
            ? L10n.text("调试已结束。请录制并应用个人校准。", "Session ended. Record and apply a personal calibration.")
            : L10n.text("调试已结束，继续使用已应用的校准。", "Session ended. The applied calibration remains active.")
        refreshSensors()
    }

    func updateParameters(_ parameters: MotionJumpParameters) {
        guard phase != .recording, var profile = draft ?? settings.profile else { return }
        profile.parameters = parameters
        draft = profile
        canApply = profile.isValid
        validationSummary = L10n.text("参数已调整，之前的测试结果已清除。可以再次试用，也可以直接应用。", "Parameters changed; previous test results were cleared. Try them again or apply directly.")
        cancelAll()
        isTestingActualPointer = false
        statusText = L10n.text("参数已调整，点击“应用校准”保存。", "Parameters changed. Choose Apply Calibration to save them.")
        if phase == .testing {
            phase = .idle
            previewQuadrant = nil
            lastResultText = ""
            progressText = ""
            refreshSensors()
        }
    }

    func applyCalibration() {
        guard canApply, let draft else { return }
        settings.apply(profile: draft)
        stopSession()
        statusText = L10n.text("已应用校准。按住 L2 甩向目标方向，松开后定位。", "Calibration applied. Hold L2, gesture toward a quadrant, then release to jump.")
    }

    func restorePreviousCalibration() {
        stopSession()
        settings.restorePreviousCalibration()
        statusText = L10n.text("已恢复上次校准。", "Previous calibration restored.")
    }

    func clearCalibration() {
        stopSession()
        settings.clearCalibration()
        statusText = L10n.text("个人校准已清除，快移已停用。请重新录制。", "Calibration cleared and quick jump disabled. Record again to enable it.")
    }

    private func beginSession() -> Bool {
        guard !microphoneIsolated else {
            statusText = L10n.text("请先停止 DualSense 麦克风供音，再录制或测试体感。", "Stop DualSense microphone supply before recording or testing motion.")
            return false
        }
        guard mappingMode, let id = selectedDeviceID, sources[id] != nil else {
            statusText = L10n.text("请连接支持体感的 DualSense，并切换到映射模式。", "Connect a motion-capable DualSense and use Mapping mode.")
            return false
        }
        cancelAll()
        suspendDevice?(id)
        sessionWindow = NSApp?.keyWindow
        previewQuadrant = nil
        lastResultText = ""
        validationSummary = ""
        return true
    }

    private func updatePrompt() {
        let prompts = phase == .recording ? recordingPrompts : testPrompts
        guard step < prompts.count else { return }
        let prefix = phase == .recording ? L10n.text("录制", "Record") : L10n.text("测试", "Test")
        progressText = "\(prefix) \(step + 1) / \(prompts.count)"
        if let quadrant = prompts[step] {
            statusText = L10n.text("按住 L2，大致朝\(quadrant.displayName)转动手柄，再完全松开。", "Hold L2, turn the controller roughly toward \(quadrant.displayName), then release fully.")
        } else {
            statusText = L10n.text("自然握持，按住 L2 片刻再松开，可轻微调整握姿；不要甩动。", "Hold naturally. Press L2 briefly and release, with a small grip adjustment but no gesture.")
        }
    }

    private func finish(_ capture: Capture, deviceID: String, releasedAt: TimeInterval) {
        guard let last = capture.samples.last,
              releasedAt - last.timestamp <= MotionJumpRecognizer.maximumSampleGap,
              releasedAt - capture.startedAt <= MotionJumpRecognizer.maximumTraceDuration,
              capture.samples.count >= 3,
              last.timestamp - capture.startedAt >= MotionJumpRecognizer.minimumTraceDuration else {
            if phase != .idle { lastResultText = L10n.text("按住时间过短、过长或数据中断，请重试当前动作。", "Hold was too short, too long, or motion data was interrupted. Retry this step.") }
            return
        }
        let trace = MotionJumpTrace(samples: capture.samples)
        if phase == .recording, selectedDeviceID == deviceID {
            guard step < recordingPrompts.count else { return }
            let quadrant = recordingPrompts[step]
            do {
                try MotionJumpCalibrator.validateSample(trace: trace, quadrant: quadrant)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                lastResultText = L10n.text("\(message) 只需重试当前动作，其他参考已保留。", "\(message) Retry only this step; your other references are preserved.")
                return
            }
            if let quadrant {
                positiveSamples[quadrant] = [trace]
                recordedQuadrants.insert(quadrant)
            } else {
                negativeSamples = [trace]
                hasOrdinarySample = true
            }
            step += 1
            lastResultText = L10n.text("已录制。", "Recorded.")
            if step == recordingPrompts.count {
                phase = .idle
                isRerecordingReference = false
                progressText = ""
                do {
                    draft = try MotionJumpCalibrator.calibrate(positives: positiveSamples, negatives: negativeSamples)
                    canApply = draft?.isValid == true
                    statusText = L10n.text("四个参考方向已就绪。可以直接应用校准，也可以先测试手感。", "Your four reference directions are ready. Apply calibration, or test how it feels first.")
                } catch {
                    draft = nil
                    canApply = false
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    statusText = L10n.text("\(message) 其他参考已保留，可在下方单独重录。", "\(message) Your references are preserved; re-record individual gestures below.")
                }
                refreshSensors()
            } else { updatePrompt() }
            return
        }
        let isSelectedTest = phase == .testing && selectedDeviceID == deviceID
        guard let profile = isSelectedTest ? draft : settings.profile else { return }
        let result = MotionJumpRecognizer.recognize(trace: trace, profile: profile)
        if isSelectedTest {
            guard step < testPrompts.count else { return }
            let expected = testPrompts[step]
            previewQuadrant = result.quadrant
            if let failure = result.failure,
               [.invalidData, .dataGap, .invalidProfile, .insufficientSamples, .tooLong].contains(failure) {
                lastResultText = L10n.text("\(failure.message) 请重试当前动作。", "\(failure.message) Retry this step.")
                return
            }
            // A rejected deliberate direction is a miss. For an ordinary
            // press, only a valid trace below the amplitude/speed threshold
            // proves the intended no-trigger behavior; ambiguous or conflicting
            // gestures need a fresh ordinary press rather than a free pass.
            if expected == nil, result.quadrant == nil,
               result.failure != .insufficientAngle, result.failure != .insufficientSpeed {
                lastResultText = L10n.text("请只按放 L2、不要甩动，重试当前动作。", "Press and release L2 without a gesture, then retry this step.")
                return
            }
            if expected == nil, result.quadrant == nil {
                lastResultText = L10n.text("正确：普通 L2 按放未触发定位。", "Correct: the ordinary L2 press did not trigger a jump.")
            } else if let expected, let actual = result.quadrant, expected != actual {
                lastResultText = L10n.text("目标是\(expected.displayName)，识别为\(actual.displayName)。", "Expected \(expected.displayName); recognized \(actual.displayName).")
            } else {
                lastResultText = result.message
            }
            if expected == result.quadrant { testCorrect += 1 }
            else if expected == nil { testFalseTriggers += 1 }
            else if result.quadrant == nil { testMissed += 1 }
            else { testWrong += 1 }
            if isTestingActualPointer, let quadrant = result.quadrant {
                let moved = capture.target.map { jumpPointer?(quadrant, $0) == true } ?? false
                if !moved {
                    lastResultText = L10n.text("已识别，但无法移动光标。请检查辅助功能权限、拖拽状态和显示器。", "Recognized, but could not move the pointer. Check Accessibility permission, mouse buttons, and displays.")
                }
            }
            step += 1
            validationSummary = L10n.text("正确 \(testCorrect) · 错向 \(testWrong) · 未触发 \(testMissed) · 误触 \(testFalseTriggers)", "Correct \(testCorrect) · Wrong direction \(testWrong) · Missed \(testMissed) · False trigger \(testFalseTriggers)")
            if step == testPrompts.count {
                canApply = draft?.isValid == true
                statusText = L10n.text("本轮测试完成。可按结果调整或补录，也可以应用当前校准。", "Test complete. Adjust or re-record based on the results, or apply the current calibration.")
                // Keep owning the device until Apply/Cancel, so held inputs do
                // not leak to shortcuts while the user reviews the results.
                progressText = L10n.text("测试完成", "Test complete")
            } else { updatePrompt() }
        } else if settings.enabled, let quadrant = result.quadrant, let target = capture.target {
            _ = jumpPointer?(quadrant, target)
        }
    }

    private func refreshSensors() {
        let wanted = mappingMode && !microphoneIsolated ? Set(sources.keys.filter {
            (phase != .idle && $0 == selectedDeviceID) || (settings.enabled && settings.profile != nil)
        }) : []
        for id in Array(sensors.keys) where !wanted.contains(id) || sensors[id]?.source !== sources[id] {
            guard let sensor = sensors.removeValue(forKey: id) else { continue }
            sensor.source.stop()
            latest.removeValue(forKey: id); idleSamples.removeValue(forKey: id)
            cancel(deviceID: id)
            if sources[id] == nil { held.remove(id); blockedUntilRelease.remove(id) }
        }
        for id in wanted where sensors[id] == nil {
            guard let source = sources[id] else { continue }
            let generation = UUID()
            sensors[id] = Sensor(source: source, generation: generation)
            if source.triggerValue > 0.1 {
                held.insert(id); blockedUntilRelease.insert(id)
            }
            source.start { [weak self] sample in
                guard let self, self.sensors[id]?.generation == generation else { return }
                self.receive(sample, deviceID: id)
            }
        }
        if sensors.isEmpty { watchdog?.invalidate(); watchdog = nil }
        else if watchdog == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkStaleInput() }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }
    }

    private func receive(_ sample: MotionJumpSample, deviceID: String) {
        guard !microphoneIsolated else { return }
        latest[deviceID] = sample
        if var capture = captures[deviceID] {
            guard canMovePointer(), sample.timestamp - capture.startedAt <= MotionJumpRecognizer.maximumTraceDuration,
                  let previous = capture.samples.last, sample.timestamp > previous.timestamp,
                  sample.timestamp - previous.timestamp <= MotionJumpRecognizer.maximumSampleGap else {
                cancel(deviceID: deviceID)
                if phase != .idle { lastResultText = L10n.text("动作超时、数据中断或正在拖拽，已取消；请松开后重试。", "Cancelled due to timeout, interrupted data, or dragging. Release and retry.") }
                return
            }
            capture.samples.append(MotionJumpSample(timestamp: sample.timestamp, rotation: sample.rotation - capture.bias))
            captures[deviceID] = capture
        } else if !held.contains(deviceID) {
            idleSamples[deviceID, default: []].append(sample)
            idleSamples[deviceID] = idleSamples[deviceID]?.filter { sample.timestamp - $0.timestamp <= 0.4 }
        }
    }

    private func stationaryBias(deviceID: String) -> SIMD3<Double> {
        guard let samples = idleSamples[deviceID], samples.count >= 8,
              let last = latest[deviceID], let first = samples.first,
              last.timestamp - first.timestamp >= 0.2,
              samples.allSatisfy({ $0.rotation.x.isFinite && $0.rotation.y.isFinite && $0.rotation.z.isFinite && sqrt(($0.rotation * $0.rotation).sum()) < 0.08 }) else { return .zero }
        return samples.reduce(SIMD3<Double>.zero) { $0 + $1.rotation } / Double(samples.count)
    }

    private func checkStaleInput() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, capture) in captures where now - (capture.samples.last?.timestamp ?? 0) > MotionJumpRecognizer.maximumSampleGap
            || now - capture.startedAt > MotionJumpRecognizer.maximumTraceDuration {
            cancel(deviceID: id)
        }
    }
}
