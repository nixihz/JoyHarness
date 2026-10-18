import AppKit
import CoreAudio
import Darwin
import IOKit.graphics

/// Percentages and percentage points, never arbitrary system commands.
enum AIVoiceSystemControlAction: Equatable, Sendable {
    case volumeRead
    case volumeSet(Int)
    case volumeAdjust(Int)
    case muteSet(Bool)
    case brightnessRead
    case brightnessSet(Int)
    case brightnessAdjust(Int)
}

@MainActor
protocol AIVoiceSystemControlling {
    func execute(_ action: AIVoiceSystemControlAction) async -> AIVoiceExecutionResult
}

struct AIVoiceScalarControlState: Equatable, Sendable {
    let values: [Double]
    let isSettable: Bool
}

struct AIVoiceMuteControlState: Equatable, Sendable {
    let values: [Bool]
    let isSettable: Bool
}

/// Device objects retain the selected identity throughout write and readback.
/// Every channel must be readable/writable; a partial stereo update is not success.
@MainActor
protocol AIVoiceAudioOutputHardware {
    var name: String { get }
    func volume() throws -> AIVoiceScalarControlState
    func setVolume(_ values: [Double]) throws
    func mute() throws -> AIVoiceMuteControlState?
    func setMute(_ value: Bool) throws
}

@MainActor
protocol AIVoiceBrightnessHardware {
    var name: String { get }
    func brightness() async throws -> AIVoiceScalarControlState
    func setBrightness(_ value: Double) async throws
}

@MainActor
protocol AIVoiceSystemControlHardware {
    func defaultAudioOutput() throws -> any AIVoiceAudioOutputHardware
    func brightnessDisplay() async throws -> any AIVoiceBrightnessHardware
}

struct AIVoiceSystemControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

@MainActor
final class AIVoiceMacSystemControls: AIVoiceSystemControlling {
    private let hardware: any AIVoiceSystemControlHardware
    private let verificationAttempts: Int
    private let verificationDelayNanoseconds: UInt64
    private let tolerance = 0.011 // Allow one percent of hardware quantization.

    init(hardware: (any AIVoiceSystemControlHardware)? = nil,
         verificationAttempts: Int = 3, verificationDelayNanoseconds: UInt64 = 80_000_000) {
        self.hardware = hardware ?? AIVoiceMacSystemControlHardware()
        self.verificationAttempts = max(1, min(verificationAttempts, 5))
        self.verificationDelayNanoseconds = min(verificationDelayNanoseconds, 200_000_000)
    }

    func execute(_ action: AIVoiceSystemControlAction) async -> AIVoiceExecutionResult {
        do {
            try Task.checkCancellation()
            try validate(action)
            switch action {
            case .volumeRead, .volumeSet, .volumeAdjust:
                return try await volume(action, output: hardware.defaultAudioOutput())
            case .muteSet(let muted):
                return try await mute(muted, output: hardware.defaultAudioOutput())
            case .brightnessRead, .brightnessSet, .brightnessAdjust:
                let display = try await hardware.brightnessDisplay()
                return try await brightness(action, display: display)
            }
        } catch is CancellationError {
            return .init(status: .cancelled, message: "操作已取消。")
        } catch {
            return .init(status: .failed, message: error.localizedDescription)
        }
    }

    private func validate(_ action: AIVoiceSystemControlAction) throws {
        switch action {
        case .volumeSet(let value), .brightnessSet(let value):
            guard (0...100).contains(value) else {
                throw AIVoiceSystemControlError("百分比必须是 0 到 100 的整数，未修改设备。")
            }
        case .volumeAdjust(let delta), .brightnessAdjust(let delta):
            guard (-100...100).contains(delta) else {
                throw AIVoiceSystemControlError("调整幅度必须是 -100 到 100 的整数百分点，未修改设备。")
            }
        default: break
        }
    }

    private func checked(_ state: AIVoiceScalarControlState) throws -> AIVoiceScalarControlState {
        guard !state.values.isEmpty, state.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AIVoiceSystemControlError("设备返回了无效读数，无法确认当前状态。")
        }
        return state
    }

    private func checkedMute(_ state: AIVoiceMuteControlState?) throws -> AIVoiceMuteControlState? {
        if let state, state.values.isEmpty {
            throw AIVoiceSystemControlError("设备返回了无效静音状态。")
        }
        return state
    }

    private func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    private func volumeDescription(_ name: String, _ state: AIVoiceScalarControlState,
                                   _ mute: AIVoiceMuteControlState?) -> String {
        let level = percent(state.values.max()!)
        let channelNote = (state.values.max()! - state.values.min()!) > tolerance ? "（最高声道）" : ""
        let muteNote: String
        if let mute {
            if mute.values.allSatisfy({ $0 }) { muteNote = "，已静音" }
            else if mute.values.contains(true) { muteNote = "，部分声道已静音" }
            else { muteNote = "，未静音" }
        } else { muteNote = "；设备未提供静音状态" }
        return "\(name)音量为 \(level)%\(channelNote)\(muteNote)。"
    }

    private func volume(_ action: AIVoiceSystemControlAction,
                        output: any AIVoiceAudioOutputHardware) async throws -> AIVoiceExecutionResult {
        let before = try checked(output.volume())
        let beforeMute = try checkedMute(output.mute())
        if action == .volumeRead || action == .volumeAdjust(0) {
            return .init(status: .succeeded, message: volumeDescription(output.name, before, beforeMute))
        }
        let target: Double
        let shouldUnmute: Bool
        switch action {
        case .volumeSet(let value):
            target = Double(value) / 100
            shouldUnmute = value > 0
        case .volumeAdjust(let delta):
            target = min(1, max(0, before.values.max()! + Double(delta) / 100))
            shouldUnmute = delta > 0
        default: preconditionFailure("Non-volume action")
        }
        // Preserve the channel balance while changing the master-equivalent
        // maximum. At silence there is no recoverable ratio, so use all channels.
        let previousMaximum = before.values.max()!
        let targets = before.values.map { previousMaximum > 0 ? $0 / previousMaximum * target : target }
        let needsVolume = zip(before.values, targets).contains { pair in abs(pair.0 - pair.1) > 0.0001 }
        let needsUnmute = shouldUnmute && (beforeMute?.values.contains(true) == true)
        guard !needsVolume || before.isSettable else {
            throw AIVoiceSystemControlError("\(output.name)的音量只读，无法调整；未修改设备。")
        }
        guard !needsUnmute || beforeMute?.isSettable == true else {
            throw AIVoiceSystemControlError("\(output.name)当前已静音且不支持解除静音，未调整音量。")
        }
        guard needsVolume || needsUnmute else {
            return .init(status: .succeeded, message: volumeDescription(output.name, before, beforeMute))
        }
        return await mutateAndVerify(target: "\(output.name)的音量") {
            if needsVolume { try output.setVolume(targets) }
            if needsUnmute { try output.setMute(false) }
        } verify: {
            let after = try self.checked(output.volume())
            let afterMute = try self.checkedMute(output.mute())
            guard after.values.count == before.values.count,
                  zip(after.values, targets).allSatisfy({ pair in abs(pair.0 - pair.1) <= self.tolerance }) else { return nil }
            if needsUnmute {
                guard let afterMute, afterMute.values.allSatisfy({ !$0 }) else { return nil }
            } else if let beforeMute {
                guard afterMute?.values == beforeMute.values else { return nil }
            }
            return self.volumeDescription(output.name, after, afterMute)
        }
    }

    private func mute(_ muted: Bool, output: any AIVoiceAudioOutputHardware) async throws -> AIVoiceExecutionResult {
        guard let before = try checkedMute(output.mute()) else {
            throw AIVoiceSystemControlError("\(output.name)未提供硬件静音控制，未修改设备。")
        }
        let message = muted ? "\(output.name)已静音。" : "\(output.name)已取消静音；音量数值保持不变。"
        guard !before.values.allSatisfy({ $0 == muted }) else {
            return .init(status: .succeeded, message: message)
        }
        guard before.isSettable else {
            throw AIVoiceSystemControlError("\(output.name)的静音状态只读，无法修改。")
        }
        return await mutateAndVerify(target: "\(output.name)的静音状态") {
            try output.setMute(muted)
        } verify: {
            guard let after = try self.checkedMute(output.mute()),
                  after.values.count == before.values.count,
                  after.values.allSatisfy({ $0 == muted }) else { return nil }
            return message
        }
    }

    private func brightness(_ action: AIVoiceSystemControlAction,
                            display: any AIVoiceBrightnessHardware) async throws -> AIVoiceExecutionResult {
        let before = try checked(await display.brightness())
        try Task.checkCancellation()
        guard before.values.count == 1 else {
            throw AIVoiceSystemControlError("\(display.name)返回了不明确的屏幕亮度，未修改设备。")
        }
        let description: (Double) -> String = { "\(display.name)屏幕亮度为 \(self.percent($0))%。" }
        if action == .brightnessRead { return .init(status: .succeeded, message: description(before.values[0])) }
        let target: Double
        switch action {
        case .brightnessSet(let value): target = Double(value) / 100
        case .brightnessAdjust(let delta): target = min(1, max(0, before.values[0] + Double(delta) / 100))
        default: preconditionFailure("Non-brightness action")
        }
        if abs(target - before.values[0]) < 0.0001 {
            return .init(status: .succeeded, message: description(before.values[0]))
        }
        guard before.isSettable else {
            throw AIVoiceSystemControlError("\(display.name)的屏幕亮度只读，无法调整。")
        }
        return await mutateAndVerify(target: "\(display.name)的屏幕亮度") {
            try await display.setBrightness(target)
        } verify: {
            let after = try self.checked(await display.brightness())
            guard after.values.count == 1, abs(after.values[0] - target) <= self.tolerance else { return nil }
            return description(after.values[0])
        }
    }

    private func mutateAndVerify(target: String, write: () async throws -> Void,
                                 verify: () async throws -> String?) async -> AIVoiceExecutionResult {
        guard !Task.isCancelled else { return .init(status: .cancelled, message: "已取消，未修改设备。") }
        do {
            try await write()
            var lastError: Error?
            for attempt in 0..<verificationAttempts {
                try Task.checkCancellation()
                if attempt > 0, verificationDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: verificationDelayNanoseconds)
                }
                do {
                    if let message = try await verify() {
                        try Task.checkCancellation()
                        return .init(status: .succeeded, message: message)
                    }
                } catch is CancellationError { throw CancellationError() }
                  catch { lastError = error }
            }
            let detail = lastError.map { "（\($0.localizedDescription)）" } ?? "（读回值与请求不一致）"
            return .init(status: .unconfirmed, message: "已尝试修改\(target)，但未能确认结果\(detail)。")
        } catch is CancellationError {
            return .init(status: .cancelled, message: "已停止核对\(target)；已执行的设备修改可能仍然生效。")
        } catch {
            // A channel or unmute operation may fail after another write succeeds.
            return .init(status: .unconfirmed, message: "修改\(target)时失败，设备可能已部分变化：\(error.localizedDescription)")
        }
    }
}

@MainActor
private final class AIVoiceMacSystemControlHardware: AIVoiceSystemControlHardware {
    func defaultAudioOutput() throws -> any AIVoiceAudioOutputHardware {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw AIVoiceSystemControlError("没有可用的系统默认音频输出设备。")
        }
        return AIVoiceCoreAudioOutput(device: device)
    }

    func brightnessDisplay() async throws -> any AIVoiceBrightnessHardware {
        let screens = NSScreen.screens
        let screen = screens.first { screen in
            guard let id = Self.displayID(screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? screens.first { Self.displayID($0) == CGMainDisplayID() }
        guard let screen, let id = Self.displayID(screen) else {
            throw AIVoiceSystemControlError("未找到可用的内建屏或主屏。")
        }
        if let display = AIVoiceDisplayServicesBrightness(displayID: id, name: screen.localizedName),
           (try? await display.brightness()) != nil { return display }
        do {
            return try AIVoiceDDCBrightness.make(displayID: id, name: screen.localizedName)
        } catch {
            throw AIVoiceSystemControlError("\(screen.localizedName)暂时无法控制硬件亮度：\(error.localizedDescription)")
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
private final class AIVoiceCoreAudioOutput: AIVoiceAudioOutputHardware {
    private let device: AudioDeviceID
    let name: String

    init(device: AudioDeviceID) {
        self.device = device
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        // kAudioObjectPropertyName transfers a retained CFString to the caller.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, bytes.baseAddress!)
        }
        if status == noErr, let value {
            name = value.takeRetainedValue() as String
        } else { name = "系统默认输出" }
    }

    func volume() throws -> AIVoiceScalarControlState {
        let elements = try controlElements(kAudioDevicePropertyVolumeScalar)
        guard !elements.isEmpty else {
            throw AIVoiceSystemControlError("\(name)不支持系统音量读取或调节；HDMI／数字输出可能需要使用设备自身音量控制。")
        }
        let values: [Double] = try elements.map { element in
            var value: Float32 = 0
            try read(kAudioDevicePropertyVolumeScalar, element: element, into: &value)
            return Double(value)
        }
        return .init(values: values, isSettable: try elements.allSatisfy { try isSettable(kAudioDevicePropertyVolumeScalar, $0) })
    }

    func setVolume(_ values: [Double]) throws {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw AIVoiceSystemControlError("无效音量。")
        }
        let elements = try controlElements(kAudioDevicePropertyVolumeScalar)
        guard elements.count == values.count, try elements.allSatisfy({ try isSettable(kAudioDevicePropertyVolumeScalar, $0) }) else {
            throw AIVoiceSystemControlError("\(name)不支持音量写入。")
        }
        for (element, value) in zip(elements, values) {
            var scalar = Float32(value)
            try write(kAudioDevicePropertyVolumeScalar, element: element, value: &scalar)
        }
    }

    func mute() throws -> AIVoiceMuteControlState? {
        let elements = try controlElements(kAudioDevicePropertyMute)
        guard !elements.isEmpty else { return nil }
        let values: [Bool] = try elements.map { element in
            var value: UInt32 = 0
            try read(kAudioDevicePropertyMute, element: element, into: &value)
            return value != 0
        }
        return .init(values: values, isSettable: try elements.allSatisfy { try isSettable(kAudioDevicePropertyMute, $0) })
    }

    func setMute(_ value: Bool) throws {
        let elements = try controlElements(kAudioDevicePropertyMute)
        guard !elements.isEmpty, try elements.allSatisfy({ try isSettable(kAudioDevicePropertyMute, $0) }) else {
            throw AIVoiceSystemControlError("\(name)不支持静音写入。")
        }
        for element in elements {
            var muted: UInt32 = value ? 1 : 0
            try write(kAudioDevicePropertyMute, element: element, value: &muted)
        }
    }

    private func address(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func controlElements(_ selector: AudioObjectPropertySelector) throws -> [UInt32] {
        var master = address(selector, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &master) { return [kAudioObjectPropertyElementMain] }
        var configuration = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &configuration, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= 1_048_576 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &configuration, 0, nil, &size, buffer) == noErr else { return [] }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(list.pointee.mNumberBuffers) <= (Int(size) - offset) / MemoryLayout<AudioBuffer>.stride else { return [] }
        let channels = UnsafeMutableAudioBufferListPointer(list).reduce(UInt64(0)) { $0 + UInt64($1.mNumberChannels) }
        guard channels > 0, channels <= 256 else { return [] }
        let elements = (1...UInt32(channels)).filter { element in
            var property = address(selector, element)
            return AudioObjectHasProperty(device, &property)
        }
        // Controlling only one of several channels would misrepresent the result.
        return elements.count == Int(channels) ? elements : []
    }

    private func isSettable(_ selector: AudioObjectPropertySelector, _ element: UInt32) throws -> Bool {
        var property = address(selector, element)
        var writable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &property, &writable)
        guard status == noErr else { throw AIVoiceSystemControlError("无法读取\(name)的控制权限（\(status)）。") }
        return writable.boolValue
    }

    private func read<T>(_ selector: AudioObjectPropertySelector, element: UInt32, into value: inout T) throws {
        var property = address(selector, element)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr, size == MemoryLayout<T>.size else {
            throw AIVoiceSystemControlError("无法读取\(name)的设备状态（\(status)）。")
        }
    }

    private func write<T>(_ selector: AudioObjectPropertySelector, element: UInt32, value: inout T) throws {
        var property = address(selector, element)
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        guard status == noErr else { throw AIVoiceSystemControlError("\(name)拒绝设备修改（\(status)）。") }
    }
}

@MainActor
private final class AIVoiceDisplayServicesBrightness: AIVoiceBrightnessHardware {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let handle: UnsafeMutableRawPointer
    private let get: GetBrightness
    private let set: SetBrightness?
    private let displayID: CGDirectDisplayID
    let name: String

    init?(displayID: CGDirectDisplayID, name: String) {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { dlclose(handle); return nil }
        self.handle = handle
        get = unsafeBitCast(symbol, to: GetBrightness.self)
        set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        self.displayID = displayID
        self.name = name
    }

    deinit { dlclose(handle) }

    func brightness() async throws -> AIVoiceScalarControlState {
        var value: Float = 0
        let status = get(displayID, &value)
        guard status == 0, value.isFinite, (0...1).contains(value) else {
            throw AIVoiceSystemControlError("无法读取\(name)的硬件亮度（\(status)）。")
        }
        return .init(values: [Double(value)], isSettable: set != nil)
    }

    func setBrightness(_ value: Double) async throws {
        guard value.isFinite, (0...1).contains(value), let set else {
            throw AIVoiceSystemControlError("\(name)不支持硬件亮度写入。")
        }
        let status = set(displayID, Float(value))
        guard status == 0 else { throw AIVoiceSystemControlError("\(name)拒绝硬件亮度修改（\(status)）。") }
    }
}
