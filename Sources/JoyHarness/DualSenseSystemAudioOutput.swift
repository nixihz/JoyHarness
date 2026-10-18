import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// The DualSense has its own HAL device. It never writes to the speakers or
/// to the Xiaomi device, even when either becomes the system default.
final class DualSenseSystemAudioOutput {
    static let deviceUID = "tech.keli.joyharness.dualsense.microphone.device"
    static let deviceName = "Joy Harness DualSense 麦克风"
    static let flushSelector: AudioObjectPropertySelector = 0x6a68666c
    private let queue = DispatchQueue(label: "tech.keli.joyharness.dualsense-audio-output")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var device: AudioDeviceID?
    private var configurationObserver: NSObjectProtocol?
    private typealias Token = DualSenseAudioOutputBudget.Token
    // Makes admission + queue submission one ordered operation across callers.
    private let submissionLock = NSLock()
    private let budget = DualSenseAudioOutputBudget()
    private var activeToken: Token?
    private var lastFailureToken: Token?
    private var draining: (token: Token, completion: () -> Void)?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var onFailure: ((UInt64, String) -> Void)?

    static var installed: Bool { deviceID() != nil }
    static var isDefaultInput: Bool {
        guard let device = deviceID() else { return false }
        var current: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &current) == noErr && current == device
    }

    static func selectAsDefaultInput() throws {
        guard var device = deviceID() else { throw failure("请先安装或更新 Joy Harness 麦克风组件。") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr, isDefaultInput else {
            throw failure("未能选择 DualSense 系统麦克风，请在系统声音设置中选择。")
        }
    }

    func prepare(generation: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        submissionLock.lock()
        let token = budget.begin(generation: generation)
        queue.async { [self] in
            let retiredToken = activeToken
            let cleanupError = stopOnQueue()
            if let cleanupError, let retiredToken { reportFailure(retiredToken, cleanupError.localizedDescription) }
            guard budget.isLive(token) else {
                DispatchQueue.main.async { completion(.failure(Self.failure("本次音频准备已取消。"))) }
                return
            }
            activeToken = token
            do {
                if let cleanupError { throw cleanupError }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    throw Self.failure("请先允许 Joy Harness 使用麦克风。")
                }
                guard let device = Self.deviceID() else {
                    throw Self.failure("请先安装或更新 Joy Harness 麦克风组件。")
                }
                try Self.flush(device)
                let engine = AVAudioEngine()
                guard let unit = engine.outputNode.audioUnit else { throw Self.failure("系统音频输出不可用。") }
                var target = device
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                    throw Self.failure("无法打开 DualSense 专用音频设备。")
                }
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereo)
                self.device = device
                self.engine = engine
                self.player = player
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in
                    guard let self, self.budget.cancel(token) else { return }
                    self.queue.async {
                        self.fail(token, "系统音频设备配置已变化，已停止供音；请重新开始。")
                    }
                }
                engine.prepare()
                guard budget.isLive(token) else { throw Self.failure("本次音频准备已取消。") }
                try engine.start()
                player.play()
                guard isDedicatedRoute(engine, device: device) else {
                    throw Self.failure("专用麦克风音频路由已变化，未向其他设备供音。")
                }
                guard budget.isLive(token) else { throw Self.failure("本次音频准备已取消。") }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                budget.cancel(token)
                if let cleanupError = stopOnQueue() {
                    reportFailure(token, cleanupError.localizedDescription)
                }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        submissionLock.unlock()
    }

    func append(_ pcm: [Float], generation: UInt64) {
        submissionLock.lock()
        // Validate the count before scanning or capturing the array in a job.
        // A rejected reservation cancels admission immediately, even when the
        // audio worker is blocked inside a Core Audio operation.
        let valid = !pcm.isEmpty && pcm.count <= 4_800 && pcm.allSatisfy { $0.isFinite }
        let admission = budget.reserve(generation: generation, frames: valid ? pcm.count : 0)
        switch admission {
        case .ignored:
            break
        case .rejected(let token):
            queue.async { [self] in fail(token, "手柄音频积压或数据异常，本次已停止供音。") }
        case .reserved(let reservation):
            queue.async { [self] in
                let token = reservation.token
                var scheduled = false
                defer { if !scheduled { _ = budget.release(reservation) } }
                guard activeToken == token, budget.isLive(token), let player, let engine else {
                    return
                }
                guard let device, isDedicatedRoute(engine, device: device) else {
                    fail(token, "专用麦克风音频路由已变化，已停止供音。")
                    return
                }
                guard engine.isRunning, player.isPlaying else {
                    fail(token, "系统音频设备已中断，本次已停止供音。")
                    return
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
                      let samples = buffer.floatChannelData?[0] else {
                    fail(token, "无法准备手柄音频缓冲，本次已停止供音。")
                    return
                }
                buffer.frameLength = AVAudioFrameCount(pcm.count)
                pcm.withUnsafeBufferPointer { source in samples.update(from: source.baseAddress!, count: source.count) }
                // Recheck after allocation. An already-running schedule/render
                // can race cancellation and is stopped by the next worker job.
                guard budget.markScheduled(reservation) else { return }
                scheduled = true
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        let remaining = self.budget.release(reservation)
                        guard self.activeToken == token, let remaining else { return }
                        if remaining == 0, self.draining?.token == token {
                            // This is a bounded grace interval, not proof that
                            // every external HAL consumer has read the tail.
                            self.queue.asyncAfter(deadline: .now() + 0.02) { self.finishDrain(token) }
                        }
                    }
                }
            }
        }
        submissionLock.unlock()
    }

    /// Only a normal PTT release drains. Cancellation discards queued audio.
    func drain(generation: UInt64, completion: @escaping () -> Void) {
        submissionLock.lock()
        guard let token = budget.beginDrain(generation: generation) else {
            submissionLock.unlock()
            DispatchQueue.main.async(execute: completion)
            return
        }
        queue.async { [self] in
            guard activeToken == token, budget.isLive(token) else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            if let previous = draining { DispatchQueue.main.async(execute: previous.completion) }
            draining = (token, completion)
            if budget.remainingFrames(token) == 0 {
                queue.asyncAfter(deadline: .now() + 0.02) { self.finishDrain(token) }
            }
            queue.asyncAfter(deadline: .now() + 0.3) { self.finishDrain(token) }
        }
        submissionLock.unlock()
    }

    func stop(generation: UInt64) {
        submissionLock.lock()
        // Revoke synchronously. Queued append work and new callers cannot add
        // more audio while stop waits for the serial worker.
        guard let token = budget.cancel(generation: generation) else { submissionLock.unlock(); return }
        queue.async { [self] in
            guard activeToken == token else { return }
            if let error = stopOnQueue() { reportFailure(token, error.localizedDescription) }
        }
        submissionLock.unlock()
    }

    private func finishDrain(_ token: Token) {
        guard activeToken == token, draining?.token == token else { return }
        budget.cancel(token)
        if let error = stopOnQueue() { reportFailure(token, error.localizedDescription) }
    }

    /// Always retire the producer before reporting a flush failure. An onFailure
    /// callback may call stop again; there is no remaining device to retry then.
    @discardableResult
    private func stopOnQueue() -> Error? {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        player?.stop()
        engine?.stop()
        var error: Error?
        if let device {
            do { try Self.flush(device) }
            catch let failure { error = failure }
        }
        let completion = draining?.completion
        if let activeToken { budget.retire(activeToken) }
        player = nil
        engine = nil
        device = nil
        activeToken = nil
        draining = nil
        if let completion { DispatchQueue.main.async(execute: completion) }
        return error
    }

    private func fail(_ token: Token, _ message: String) {
        guard activeToken == token else { return }
        budget.cancel(token)
        let cleanupError = stopOnQueue()
        let details = cleanupError.map { "\(message) \($0.localizedDescription)" } ?? message
        reportFailure(token, details)
    }

    private func reportFailure(_ token: Token, _ message: String) {
        guard lastFailureToken != token else { return }
        lastFailureToken = token
        DispatchQueue.main.async { [weak self] in self?.onFailure?(token.generation, message) }
    }

    private func isDedicatedRoute(_ engine: AVAudioEngine, device: AudioDeviceID) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var actual: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actual, &size) == noErr && actual == device
    }

    private static func flush(_ device: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: flushSelector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // HAL custom properties cross coreaudiod as CFPropertyList objects.
        let number: CFNumber = NSNumber(value: UInt32(1))
        var token = Unmanaged.passUnretained(number).toOpaque()
        let result = withExtendedLifetime(number) {
            AudioObjectSetPropertyData(device, &address, 0, nil,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &token)
        }
        guard result == noErr else {
            throw failure("麦克风组件需要更新，无法安全清空旧音频。")
        }
    }

    private static func deviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { id in
            var uid: Unmanaged<CFString>?
            var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &uid) == noErr,
                  let uid, uid.takeRetainedValue() as String == deviceUID else { return false }
            property.mSelector = flushSelector
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(id, &property, &settable) == noErr,
                  settable.boolValue else { return false }
            for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                    mScope: scope, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return false }
            }
            return true
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DualSenseSystemAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
