import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// A dedicated loopback output, never the user's speakers. Codex (or another
/// dictation client) records Joy Harness's own input as a normal microphone.
final class RemoteMicrophoneOutput {
    static let deviceName = "Joy Harness 遥控器麦克风"
    static let deviceUID = "tech.keli.joyharness.microphone.device"
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = 0
    private var queuedSamples = 0
    private var accepting = false
    private var draining = false
    private var drainCompletions: [() -> Void] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private(set) var deliveredSamples = 0
    private(set) var failure: String?

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

    func begin() {
        stop()
        generation += 1
        queuedSamples = 0
        deliveredSamples = 0
        failure = nil
        accepting = false
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        do {
            guard var device = Self.deviceID() else { throw Self.outputError("请在设置中启用 Joy Harness 麦克风组件") }
            let engine = AVAudioEngine()
            guard let unit = engine.outputNode.audioUnit else { throw Self.outputError("音频输出不可用") }
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw Self.outputError("无法打开 Joy Harness 麦克风（\(result)）") }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            accepting = true
        } catch {
            failure = error.localizedDescription
            print("[agent-deck] Xiaomi voice output: \(error.localizedDescription)")
        }
    }

    func append(_ pcm: [Int16]) {
        guard accepting, let player, let engine, engine.isRunning, !pcm.isEmpty else { return }
        // Bound latency; stale speech must never spill into the next recording.
        guard queuedSamples + pcm.count <= 8_000 else {
            stop()
            failure = "语音输出积压，已停止本次录音"
            print("[agent-deck] Xiaomi voice output backlog exceeded")
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        for (index, value) in pcm.enumerated() { samples[index] = Float(value) / 32768 }
        queuedSamples += pcm.count
        let current = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.queuedSamples -= pcm.count
                self.deliveredSamples += pcm.count
            }
        }
    }

    func end(completion: @escaping () -> Void = {}) {
        guard player != nil else { completion(); return }
        drainCompletions.append(completion)
        guard !draining else { return }
        draining = true
        accepting = false
        let current = generation
        let delay = Double(queuedSamples) / 16_000 + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == current else { return }
            print("[agent-deck] Xiaomi voice output played_samples=\(self.deliveredSamples) pending=\(self.queuedSamples)")
            self.stop()
        }
    }

    func finishPreviousSessionIfDraining() {
        if draining { stop() }
    }

    func stop() {
        accepting = false
        generation += 1
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        queuedSamples = 0
        draining = false
        let completions = drainCompletions
        drainCompletions.removeAll()
        for completion in completions { completion() }
    }

    private static func outputError(_ message: String) -> NSError {
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

    private static func deviceID() -> AudioDeviceID? {
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
