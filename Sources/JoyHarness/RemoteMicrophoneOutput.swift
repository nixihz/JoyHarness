import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

protocol RemoteMicrophonePlayback: AnyObject {
    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool
    func recoverFromInterruption() -> Bool
    func stop()
}

extension RemoteMicrophonePlayback {
    func recoverFromInterruption() -> Bool { false }
}

/// A dedicated loopback output, never the user's speakers. Codex (or another
/// dictation client) records Joy Harness's own input as a normal microphone.
final class RemoteMicrophoneOutput {
    static let deviceName = "Joy Harness 遥控器麦克风"
    static let deviceUID = "tech.keli.joyharness.microphone.device"
    private static let maximumQueuedSamples = 8_000
    private static let maximumScheduledBuffers = 4
    private let makePlayback: () throws -> RemoteMicrophonePlayback
    private let streamEndTimeout: TimeInterval
    private var playback: RemoteMicrophonePlayback?
    private var generation = 0
    private var buttonPressed = false
    private var buttonGeneration: Int?
    private var bufferedPCM: [[Int16]] = []
    private var scheduledBufferCount = 0
    private(set) var queuedSamples = 0
    private var accepting = false
    private var draining = false
    private var drainCompletions: [() -> Void] = []
    private var releaseTimeout: DispatchWorkItem?
    private var drainTimeout: DispatchWorkItem?
    private var drainCompletion: DispatchWorkItem?
    private(set) var deliveredSamples = 0
    private(set) var droppedSamples = 0
    private(set) var failure: String?

    init(
        streamEndTimeout: TimeInterval = 1,
        makePlayback: @escaping () throws -> RemoteMicrophonePlayback = { try CoreAudioRemoteMicrophonePlayback() }
    ) {
        self.streamEndTimeout = streamEndTimeout
        self.makePlayback = makePlayback
    }

    static var installed: Bool { deviceID() != nil }
    static var selected: Bool {
        guard let device = deviceID() else { return false }
        return defaultInput() == device
    }

    static func selectAsDefaultInput() throws {
        guard var device = deviceID() else { throw outputError("请先启用 Joy Harness 麦克风组件") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        guard result == noErr else { throw outputError("无法选择遥控器语音输入（\(result)）") }
    }

    func warmUp() {
        guard playback == nil, !accepting, !draining else { return }
        do {
            playback = try makePlayback()
            failure = nil
            print("[agent-deck] Xiaomi voice output prepared")
        } catch {
            failure = error.localizedDescription
            print("[agent-deck] Xiaomi voice output: \(error.localizedDescription)")
        }
    }

    func begin() {
        if accepting || draining || queuedSamples > 0 || scheduledBufferCount > 0 || !drainCompletions.isEmpty {
            stop()
        }
        generation += 1
        queuedSamples = 0
        deliveredSamples = 0
        droppedSamples = 0
        failure = nil
        do {
            if playback == nil { playback = try makePlayback() }
            accepting = true
            if buttonPressed, buttonGeneration == nil { buttonGeneration = generation }
        } catch {
            failure = error.localizedDescription
            print("[agent-deck] Xiaomi voice output: \(error.localizedDescription)")
        }
    }

    func append(_ pcm: [Int16]) {
        guard accepting, playback != nil, !pcm.isEmpty else { return }
        // Bound latency; stale speech must never spill into the next recording.
        var retained = pcm
        var overflow = max(0, queuedSamples + retained.count - Self.maximumQueuedSamples)
        let wasTrimming = droppedSamples > 0
        while overflow > 0, !bufferedPCM.isEmpty {
            let count = min(overflow, bufferedPCM[0].count)
            bufferedPCM[0].removeFirst(count)
            if bufferedPCM[0].isEmpty { bufferedPCM.removeFirst() }
            queuedSamples -= count
            droppedSamples += count
            overflow -= count
        }
        if overflow > 0 {
            let count = min(overflow, retained.count)
            retained.removeFirst(count)
            droppedSamples += count
        }
        if !wasTrimming, droppedSamples > 0 {
            print("[agent-deck] Xiaomi voice output backlog trimming started pending=\(queuedSamples)")
        }
        guard !retained.isEmpty else { return }
        bufferedPCM.append(retained)
        queuedSamples += retained.count
        scheduleBufferedAudio()
    }

    private func scheduleBufferedAudio() {
        guard let playback else { return }
        while scheduledBufferCount < Self.maximumScheduledBuffers, !bufferedPCM.isEmpty {
            let pcm = bufferedPCM.removeFirst()
            let current = generation
            scheduledBufferCount += 1
            let completion = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    self.scheduledBufferCount -= 1
                    self.queuedSamples -= pcm.count
                    self.deliveredSamples += pcm.count
                    self.scheduleBufferedAudio()
                    self.completeDrainIfReady()
                }
            }
            let scheduled = playback.schedule(pcm, completion: completion)
            guard !scheduled else { continue }
            guard playback.recoverFromInterruption(),
                  playback.schedule(pcm, completion: completion) else {
                stop()
                failure = "无法写入遥控器音频"
                return
            }
            print("[agent-deck] Xiaomi voice output resumed after audio device reconfiguration")
        }
    }

    /// HID release and BLE AUDIO_STOP travel independently. Keep accepting the
    /// current stream until AUDIO_STOP, then release the key after playback.
    func releaseWhenFinished(completion: @escaping () -> Void) {
        let releasedGeneration = buttonGeneration
        buttonPressed = false
        buttonGeneration = nil
        guard playback != nil, releasedGeneration == generation, accepting || draining else {
            completion()
            return
        }
        drainCompletions.append(completion)
        guard accepting, releaseTimeout == nil else { return }
        let current = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.end() // A missing BLE stop must not leave Command held forever.
        }
        releaseTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + streamEndTimeout, execute: timeout)
    }

    func handle(_ event: RemoteVoiceStreamEvent) {
        switch event {
        case .started: begin()
        case .ended: end()
        case .cancelled:
            buttonPressed = false
            buttonGeneration = nil
            stop()
        }
    }

    func end() {
        guard playback != nil, !draining else { return }
        releaseTimeout?.cancel()
        releaseTimeout = nil
        draining = true
        accepting = false
        let current = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.failure = "遥控器音频输出超时"
            self.stop()
        }
        drainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
        completeDrainIfReady()
    }

    private func completeDrainIfReady() {
        guard draining, queuedSamples == 0, drainCompletion == nil else { return }
        let current = generation
        let completion = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            print("[agent-deck] Xiaomi voice output played_samples=\(self.deliveredSamples) dropped_samples=\(self.droppedSamples) pending=0")
            self.finishSession()
        }
        drainCompletion = completion
        // Allow the virtual input to consume the final output buffers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: completion)
    }

    func prepareForPress() {
        if draining || !drainCompletions.isEmpty { stop() }
        buttonPressed = true
        buttonGeneration = accepting || draining ? generation : nil
    }

    func stop() {
        generation += 1
        playback?.stop()
        playback = nil
        finishSession()
    }

    private func finishSession() {
        accepting = false
        releaseTimeout?.cancel()
        releaseTimeout = nil
        drainTimeout?.cancel()
        drainTimeout = nil
        drainCompletion?.cancel()
        drainCompletion = nil
        bufferedPCM.removeAll()
        scheduledBufferCount = 0
        queuedSamples = 0
        draining = false
        let completions = drainCompletions
        drainCompletions.removeAll()
        for completion in completions { completion() }
    }

    fileprivate static func outputError(_ message: String) -> NSError {
        NSError(domain: "RemoteMicrophoneOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func defaultInput() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    fileprivate static func deviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            var name: Unmanaged<CFString>?
            var count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &count, &name) == noErr,
                  let name, name.takeRetainedValue() as String == deviceUID else { return false }
            for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                    mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &count) == noErr, count > 0 else { return false }
            }
            return true
        }
    }
}

private final class CoreAudioRemoteMicrophonePlayback: RemoteMicrophonePlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    init() throws {
        try selectOutputDevice()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func selectOutputDevice() throws {
        guard var device = RemoteMicrophoneOutput.deviceID() else {
            throw RemoteMicrophoneOutput.outputError("请在设置中启用 Joy Harness 麦克风组件")
        }
        guard let unit = engine.outputNode.audioUnit else { throw RemoteMicrophoneOutput.outputError("音频输出不可用") }
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw RemoteMicrophoneOutput.outputError("无法打开 Joy Harness 麦克风（\(result)）") }
    }

    func schedule(_ pcm: [Int16], completion: @escaping () -> Void) -> Bool {
        guard engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let samples = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        for (index, value) in pcm.enumerated() { samples[index] = Float(value) / 32768 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        return true
    }

    func recoverFromInterruption() -> Bool {
        do {
            if !engine.isRunning {
                try selectOutputDevice()
                engine.prepare()
                try engine.start()
                player.play()
            } else if !player.isPlaying {
                player.play()
            }
            return engine.isRunning
        } catch {
            print("[agent-deck] Xiaomi voice output resume failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
