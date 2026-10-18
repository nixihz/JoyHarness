import AVFoundation
import CoreAudio
import Foundation

struct AIVoiceRecording: Sendable {
    let wavData: Data
    let duration: TimeInterval
    let sampleRate: Int
    let containsAudibleAudio: Bool
}

enum AIVoiceAudioError: LocalizedError {
    case microphonePermission, unavailableInput, conversionFailed, noAudio, inputChanged, tooLong
    case untrustedTiming, memoryLimit

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "请在系统设置中允许 Joy Harness 使用麦克风。"
        case .unavailableInput: "当前系统默认麦克风不可用。"
        case .conversionFailed: "无法处理麦克风音频，请重新选择系统输入设备。"
        case .noAudio: "没有收到有效声音，请看到聆听提示后再说话。"
        case .inputChanged: "麦克风配置已变化，本次录音已取消，请松开 L2 后重新按住，再点一下 PS。"
        case .tooLong: "录音已达到 60 秒，本次已取消。"
        case .untrustedTiming: "无法可靠确定录音与松开时间，本次已取消且不会上传。"
        case .memoryLimit: "麦克风数据超过录音内存上限，本次已取消，请选择较低采样率的输入设备。"
        }
    }
}

/// The recorder has no network or file output. It follows the system default
/// input and cancels when that input changes instead of silently switching.
@MainActor
final class AIVoiceAudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var inputName = "系统默认麦克风"

    private var engine: AVAudioEngine?
    private var accumulator: AIVoiceAudioAccumulator?
    private var configurationObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var generation = UUID()

    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        cancel()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AIVoiceAudioError.microphonePermission
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw AIVoiceAudioError.unavailableInput
        }
        inputName = Self.defaultInputName() ?? "系统默认麦克风"
        let accumulator = AIVoiceAudioAccumulator(converter: converter, output: output, requiresTimestamps: true)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
            // AVAudioTime host time is the mach absolute monotonic clock used
            // by ProcessInfo.systemUptime and the input-event timestamps.
            let capturedAt = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            let update = accumulator.append(buffer, at: capturedAt)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration, self.engine != nil else { return }
                if let error = update.error {
                    self.cancel()
                    self.onFailure?(error.localizedDescription)
                } else if let level = update.level {
                    self.onLevel?(level)
                }
            }
        }
        self.engine = engine
        self.accumulator = accumulator
        do {
            engine.prepare()
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.inputDidChange(generation: currentGeneration) }
            }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.inputDidChange(generation: currentGeneration) }
            }
            var address = Self.defaultInputAddress
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, listener) == noErr {
                deviceListener = listener
            } else {
                throw AIVoiceAudioError.unavailableInput
            }
        } catch {
            cancel()
            throw error
        }
    }

    /// Pass the release timestamp captured on the HID/GC source queue, in
    /// ProcessInfo.systemUptime seconds. Do not replace it with main-queue time.
    func finish(at releaseTime: TimeInterval? = nil) throws -> AIVoiceRecording {
        guard let accumulator else { throw AIVoiceAudioError.noAudio }
        let cutoff = releaseTime ?? ProcessInfo.processInfo.systemUptime
        guard cutoff.isFinite, cutoff >= 0,
              cutoff <= ProcessInfo.processInfo.systemUptime + 0.002 else {
            cancel()
            throw AIVoiceAudioError.untrustedTiming
        }
        let result = accumulator.finish(at: cutoff)
        stopEngine()
        return try result.get()
    }

    func cancel() {
        accumulator?.discard()
        stopEngine()
    }

    private func stopEngine() {
        generation = UUID()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        if let listener = deviceListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, .main, listener)
        }
        deviceListener = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        accumulator = nil
        onLevel?(0)
    }

    private func inputDidChange(generation: UUID) {
        guard self.generation == generation, engine != nil else { return }
        cancel()
        onFailure?(AIVoiceAudioError.inputChanged.localizedDescription)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                          0, nil, &size, &device) == noErr, device != 0 else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }
}

/// Keeps source PCM and its capture boundaries until the release timestamp is
/// known. Cropping before resampling prevents the converter's look-ahead from
/// mixing post-release speech into otherwise pre-release output samples.
final class AIVoiceAudioAccumulator: @unchecked Sendable {
    static let maximumBufferedBytes = 64 * 1_024 * 1_024

    private struct Block {
        let buffer: AVAudioPCMBuffer
        let startTime: TimeInterval?
    }

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let requiresTimestamps: Bool
    private let memoryLimitBytes: Int
    private var blocks: [Block] = []
    private var bufferedBytes = 0
    private var frameCount = 0
    private var accepting = true
    private var failure: AIVoiceAudioError?

    init(converter: AVAudioConverter, output: AVAudioFormat,
         requiresTimestamps: Bool = false,
         memoryLimitBytes: Int = AIVoiceAudioAccumulator.maximumBufferedBytes) {
        self.converter = converter
        self.output = output
        self.requiresTimestamps = requiresTimestamps
        self.memoryLimitBytes = memoryLimitBytes
        // The normal prime method has zero output latency. Finish supplies
        // silence for the resampler tail, never samples after the cutoff.
        converter.primeMethod = .normal
    }

    func append(_ buffer: AVAudioPCMBuffer,
                at capturedAt: TimeInterval? = nil) -> (level: Float?, error: AIVoiceAudioError?) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return (nil, nil) }
        guard buffer.frameLength > 0 else { return (nil, nil) }
        guard buffer.format.isEqual(converter.inputFormat) else { return fail(.inputChanged) }
        if requiresTimestamps && capturedAt == nil { return fail(.untrustedTiming) }
        if let capturedAt {
            guard capturedAt.isFinite, capturedAt >= 0 else { return fail(.untrustedTiming) }
            if let previous = blocks.last, let previousStart = previous.startTime {
                let expected = previousStart + Double(previous.buffer.frameLength) / previous.buffer.format.sampleRate
                // Small hardware-clock drift is normal; a gap/overlap larger
                // than 2 ms is not a reliable continuous command recording.
                guard capturedAt >= previousStart, abs(capturedAt - expected) <= 0.002 else {
                    return fail(.untrustedTiming)
                }
            }
        }
        guard frameCount + Int(buffer.frameLength) <= Int(buffer.format.sampleRate * 60) else {
            return fail(.tooLong)
        }
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let byteCount = source.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard byteCount <= memoryLimitBytes - bufferedBytes else { return fail(.memoryLimit) }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return fail(.conversionFailed)
        }
        copy.frameLength = buffer.frameLength
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard destination.count == source.count else { return fail(.conversionFailed) }
        var peak: Float = 0
        for index in 0..<source.count {
            guard let input = source[index].mData, let target = destination[index].mData,
                  destination[index].mDataByteSize == source[index].mDataByteSize else {
                return fail(.conversionFailed)
            }
            memcpy(target, input, Int(source[index].mDataByteSize))
            let count = Int(source[index].mDataByteSize)
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let values = UnsafeBufferPointer(start: input.assumingMemoryBound(to: Float.self), count: count / 4)
                peak = max(peak, values.reduce(0) { max($0, abs($1)) })
            case .pcmFormatFloat64:
                let values = UnsafeBufferPointer(start: input.assumingMemoryBound(to: Double.self), count: count / 8)
                peak = max(peak, Float(values.reduce(0) { max($0, abs($1)) }))
            case .pcmFormatInt16:
                let values = UnsafeBufferPointer(start: input.assumingMemoryBound(to: Int16.self), count: count / 2)
                peak = max(peak, values.reduce(0) { max($0, abs(Float($1)) / 32_768) })
            case .pcmFormatInt32:
                let values = UnsafeBufferPointer(start: input.assumingMemoryBound(to: Int32.self), count: count / 4)
                peak = max(peak, values.reduce(0) { max($0, abs(Float($1)) / 2_147_483_648) })
            default: return fail(.conversionFailed)
            }
        }
        blocks.append(Block(buffer: copy, startTime: capturedAt))
        bufferedBytes += byteCount
        frameCount += Int(buffer.frameLength)
        return (min(1, peak), nil)
    }

    func finish(at releaseTime: TimeInterval? = nil) -> Result<AIVoiceRecording, Error> {
        lock.lock()
        accepting = false
        let captured = blocks
        let failure = failure
        blocks.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        self.failure = .noAudio
        lock.unlock()
        if let failure { return .failure(failure) }
        if let releaseTime {
            guard releaseTime.isFinite, releaseTime >= 0,
                  captured.allSatisfy({ $0.startTime != nil }) else {
                return .failure(AIVoiceAudioError.untrustedTiming)
            }
        } else if requiresTimestamps {
            return .failure(AIVoiceAudioError.untrustedTiming)
        }
        var retainedFrames = 0
        var retained: [AVAudioPCMBuffer] = []
        for block in captured {
            var length = Int(block.buffer.frameLength)
            if let releaseTime, let start = block.startTime {
                let duration = Double(length) / block.buffer.format.sampleRate
                if releaseTime <= start { continue }
                if releaseTime < start + duration {
                    // Keep only frames whose entire duration is before release.
                    length = max(0, Int(floor((releaseTime - start) * block.buffer.format.sampleRate)))
                }
            }
            guard length > 0 else { continue }
            block.buffer.frameLength = AVAudioFrameCount(length)
            retained.append(block.buffer)
            retainedFrames += length
        }
        guard retainedFrames > 0 else { return .failure(AIVoiceAudioError.noAudio) }
        let expectedOutputFrames = Int(floor(Double(retainedFrames) * output.sampleRate / converter.inputFormat.sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(expectedOutputFrames)
        converter.reset()
        for buffer in retained {
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                return .failure(AIVoiceAudioError.conversionFailed)
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, status != .error, let channel = converted.int16ChannelData?[0] else {
                return .failure(AIVoiceAudioError.conversionFailed)
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        }
        if let tail = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1_024) {
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if error != nil || status == .error { return .failure(AIVoiceAudioError.conversionFailed) }
            if let channel = tail.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(tail.frameLength)))
            }
        }
        // Synthetic converter padding must not extend the recording past the
        // retained source duration, including when the cutoff bisects a block.
        if samples.count > expectedOutputFrames { samples.removeLast(samples.count - expectedOutputFrames) }
        guard !samples.isEmpty else { return .failure(AIVoiceAudioError.noAudio) }
        return .success(AIVoiceWAV.recording(samples: samples, sampleRate: Int(output.sampleRate)))
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        failure = .noAudio
        blocks.removeAll(keepingCapacity: false)
        bufferedBytes = 0
    }

    private func fail(_ error: AIVoiceAudioError) -> (level: Float?, error: AIVoiceAudioError?) {
        accepting = false
        failure = error
        blocks.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        return (nil, error)
    }
}

enum AIVoiceWAV {
    static func recording(samples: [Int16], sampleRate: Int) -> AIVoiceRecording {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); integer(UInt32(36 + samples.count * 2)); ascii("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
        integer(UInt16(2)); integer(UInt16(16)); ascii("data"); integer(UInt32(samples.count * 2))
        for sample in samples { integer(sample) }
        // This rejects empty/silent captures, not language or background noise.
        let energeticSamples = samples.lazy.filter { abs(Int($0)) >= 100 }.prefix(sampleRate / 10).count
        return AIVoiceRecording(wavData: data,
                                duration: Double(samples.count) / Double(sampleRate),
                                sampleRate: sampleRate,
                                containsAudibleAudio: energeticSamples >= sampleRate / 10)
    }
}
