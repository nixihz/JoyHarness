import Foundation
import IOKit
import IOKit.hid

enum DualSenseHIDTransport: String {
    case usb = "USB"
    case bluetooth = "Bluetooth"

    init?(ioKitValue: String) {
        switch ioKitValue.lowercased() {
        case "usb": self = .usb
        case "bluetooth": self = .bluetooth
        default: return nil
        }
    }
}

enum DualSenseUSBOutputReport {
    static let length = 48

    static func weapon(
        startPosition: Float,
        endPosition: Float,
        strength: Float
    ) -> [UInt8] {
        let start = min(max(Int((startPosition * 9).rounded()), 2), 7)
        let end = min(max(Int((endPosition * 9).rounded()), start + 1), 8)
        let force = min(max(Int((strength * 8).rounded()), 1), 8)
        let zones = UInt16((1 << start) | (1 << end))

        var report = [UInt8](repeating: 0, count: length)
        report[0] = 0x02
        report[1] = 0x04
        report[11] = 0x25
        report[12] = UInt8(zones & 0xff)
        report[13] = UInt8((zones >> 8) & 0xff)
        report[14] = UInt8(force - 1)
        return report
    }

    static func off() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = 0x02
        report[1] = 0x04
        report[11] = 0x05
        return report
    }
}

enum DualSenseBluetoothOutputReport {
    static let length = 78
    private static let crcOffset = length - MemoryLayout<UInt32>.size

    static func weapon(
        startPosition: Float,
        endPosition: Float,
        strength: Float
    ) -> [UInt8] {
        wrap(effect: DualSenseUSBOutputReport.weapon(
            startPosition: startPosition,
            endPosition: endPosition,
            strength: strength
        ))
    }

    static func off() -> [UInt8] {
        wrap(effect: DualSenseUSBOutputReport.off())
    }

    private static func wrap(effect: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: length)
        report[0] = 0x31
        report[2] = 0x10

        // USB byte zero is its report ID. The remaining bytes are the shared
        // DualSense effects payload, shifted by the Bluetooth envelope.
        let payload = effect.dropFirst()
        report.replaceSubrange(3..<(3 + payload.count), with: payload)

        let checksum = crc32([0xa2] + report[0..<crcOffset])
        for byte in 0..<MemoryLayout<UInt32>.size {
            report[crcOffset + byte] = UInt8(truncatingIfNeeded: checksum >> (byte * 8))
        }
        return report
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var checksum = UInt32.max
        for byte in bytes {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(checksum & 1))
                checksum = (checksum >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return ~checksum
    }
}

enum DualSenseInputReport {
    static func psInputSample(
        in report: UnsafeBufferPointer<UInt8>,
        transport: DualSenseHIDTransport,
        timestamp: TimeInterval
    ) -> DualSensePSInputSample? {
        guard let pressed = isHomeButtonPressed(in: report, transport: transport) else { return nil }
        let triggerIndex = transport == .usb ? 5 : 6
        return DualSensePSInputSample(
            isPressed: pressed,
            leftTriggerValue: Float(report[triggerIndex]) / 255,
            timestamp: timestamp
        )
    }

    /// USB report 0x01 and Bluetooth extended report 0x31 share the input
    /// state layout; Bluetooth adds one header byte after the report ID.
    /// Other reports, such as the short Bluetooth 0x01 report sent before
    /// extended mode is enabled, place buttons elsewhere and are ignored.
    static func isHomeButtonPressed(
        in report: UnsafeBufferPointer<UInt8>,
        transport: DualSenseHIDTransport
    ) -> Bool? {
        let (reportID, homeButtonIndex): (UInt8, Int) = switch transport {
        case .usb: (0x01, 10)
        case .bluetooth: (0x31, 11)
        }
        guard report.count == (transport == .usb ? 64 : 78), report[0] == reportID else { return nil }
        if transport == .bluetooth, report[1] & 0x0f != 0x01 { return nil }
        return report[homeButtonIndex] & 0x01 != 0
    }
}

struct DualSenseHomeButtonFilter {
    static let defaultReleaseDelay: TimeInterval = 0.2

    let releaseDelay: TimeInterval
    private(set) var isPressed = false
    private(set) var releaseDeadline: TimeInterval?

    init(releaseDelay: TimeInterval = Self.defaultReleaseDelay) {
        self.releaseDelay = releaseDelay
    }

    mutating func ingest(isPressed nextPressed: Bool, at timestamp: TimeInterval) -> Bool? {
        if nextPressed {
            releaseDeadline = nil
            guard !isPressed else { return nil }
            isPressed = true
            return true
        }

        guard isPressed else { return nil }
        // Reports keep streaming while the button stays up, so only the first
        // released sample starts the countdown; later ones must not extend it.
        if releaseDeadline == nil {
            releaseDeadline = timestamp + releaseDelay
        }
        return nil
    }

    mutating func flush(at timestamp: TimeInterval) -> Bool? {
        guard let releaseDeadline, timestamp >= releaseDeadline else { return nil }
        self.releaseDeadline = nil
        guard isPressed else { return nil }
        isPressed = false
        return false
    }

    mutating func reset() {
        isPressed = false
        releaseDeadline = nil
    }
}

final class DualSenseHIDOutput {
    private final class InputContext {
        weak var owner: DualSenseHIDOutput?
        let generation: UInt64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_024)

        init(owner: DualSenseHIDOutput, generation: UInt64) {
            self.owner = owner
            self.generation = generation
        }

        deinit { buffer.deallocate() }
    }

    private struct InputConfiguration {
        let transport: DualSenseHIDTransport
        let identity: DualSenseHIDEndpointIdentity
        var isolated = false
        var sessionGeneration: UInt64?
        var latestControl: DualSenseHIDControlSample?
        var lastAudioTimestamp: TimeInterval = -.infinity
        var closeTimestamp: TimeInterval?
    }

    private static let sonyVendorID = 0x054c
    private static let dualSenseProductID = 0x0ce6
    private static let buttonUsagePage = UInt32(kHIDPage_Button)
    private static let homeButtonUsage: UInt32 = 13

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var transport: DualSenseHIDTransport?
    private var homeButtonFilter = DualSenseHomeButtonFilter()
    private var homeReleaseWorkItem: DispatchWorkItem?
    private let inputQueue = DispatchQueue(label: "tech.keli.joyharness.dualsense-input")
    private let inputConfigurationLock = NSLock()
    private var inputConfiguration: InputConfiguration?
    private var inputGeneration: UInt64 = 0
    private let psInputMailbox = DualSensePSInputMailbox()
    private let controlMailbox = DualSenseHIDControlMailbox()
    private let output = DualSenseHIDWriteCoordinator()
    private var microphonePacketHandler: ((DualSenseHIDMicrophonePacket) -> Void)?

    // Public operations and callbacks are main-queue-only, except the bounded
    // microphone packet callback, which runs on the HID input queue.
    var onHomeButtonChange: ((Bool) -> Void)?
    var onPSInputSample: ((DualSensePSInputSample) -> Void)?
    var onPSInputInterrupted: (() -> Void)?
    var onTrustedControlSample: ((DualSenseHIDControlSample) -> Void)?
    var onMicrophoneInterrupted: (() -> Void)?
    var onMicrophoneAvailabilityChange: ((DualSenseMicrophoneAvailability) -> Void)?
    private(set) var microphoneAvailability: DualSenseMicrophoneAvailability = .unavailable("未连接 DualSense。")

    var onMicrophonePacket: ((DualSenseHIDMicrophonePacket) -> Void)? {
        get {
            inputConfigurationLock.lock(); defer { inputConfigurationLock.unlock() }
            return microphonePacketHandler
        }
        set {
            inputConfigurationLock.lock(); defer { inputConfigurationLock.unlock() }
            microphonePacketHandler = newValue
        }
    }

    var isMicrophoneInputIsolated: Bool {
        inputConfigurationLock.lock(); defer { inputConfigurationLock.unlock() }
        return inputConfiguration?.isolated ?? false
    }

    func connectIfNeeded() -> Bool {
        if device != nil { refreshMicrophoneAvailability(); return true }
        return connect()
    }

    func connect() -> Bool {
        disconnect()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.sonyVendorID,
            kIOHIDProductIDKey as String: Self.dualSenseProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        let connections = devices.compactMap { device -> (IOHIDDevice, DualSenseHIDTransport)? in
            guard let value = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  let transport = DualSenseHIDTransport(ioKitValue: value) else { return nil }
            return (device, transport)
        }
        // Preserve ordinary trigger behavior. Microphone availability below
        // separately rejects USB, unknown identities and multiple endpoints.
        guard let (device, transport) = connections.first(where: { $0.1 == .usb }) ?? connections.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        var registryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let identity = DualSenseHIDEndpointIdentity(registryID: registryID, connectionGeneration: inputGeneration)
        self.manager = manager
        self.device = device
        self.transport = transport
        inputConfigurationLock.lock()
        inputConfiguration = InputConfiguration(transport: transport, identity: identity)
        inputConfigurationLock.unlock()
        output.attach(generation: inputGeneration, bluetooth: transport == .bluetooth) { report in
            Self.write(report, to: device)
        }
        if transport == .bluetooth {
            // Reading calibration selects enhanced reports without opening the
            // mic. A failure is not treated as valid control/identity evidence.
            output.prepareInput {
                var bytes = [UInt8](repeating: 0, count: 41)
                bytes[0] = 0x05
                var length = CFIndex(bytes.count)
                _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, &bytes, &length)
            }
        }
        let inputContext = InputContext(owner: self, generation: inputGeneration)
        let retainedContext = Unmanaged.passRetained(inputContext)
        let context = retainedContext.toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputContext.buffer, 1_024, Self.inputReportCallback, context)
        IOHIDDeviceRegisterInputValueCallback(device, Self.inputValueCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovalCallback, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, context)
        IOHIDManagerSetDispatchQueue(manager, inputQueue)
        let retainedManager = Unmanaged.passRetained(manager)
        IOHIDManagerSetCancelHandler(manager) {
            IOHIDManagerClose(retainedManager.takeUnretainedValue(), IOOptionBits(kIOHIDOptionsTypeNone))
            retainedContext.release()
            retainedManager.release()
        }
        IOHIDManagerActivate(manager)
        refreshMicrophoneAvailability()
        print("[agent-deck] DualSense \(transport.rawValue) HID background trigger ready")
        return true
    }

    private func refreshMicrophoneAvailability() {
        let next: DualSenseMicrophoneAvailability
        let devices = manager.flatMap { IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> } ?? []
        inputConfigurationLock.lock()
        let configuration = inputConfiguration
        inputConfigurationLock.unlock()
        if devices.count > 1 {
            next = .unavailable("检测到多只或多个 DualSense 端点，请只保留一只蓝牙手柄。")
        } else if let configuration, configuration.transport == .usb {
            next = .unavailable("请拔掉 DualSense 的 USB 数据线并通过蓝牙连接。")
        } else if devices.count == 1, let configuration,
                  configuration.transport == .bluetooth, configuration.identity.registryID != 0 {
            next = .available(configuration.identity)
        } else {
            next = .unavailable("尚未确认唯一的 DualSense 蓝牙端点。")
        }
        guard next != microphoneAvailability else { return }
        microphoneAvailability = next
        onMicrophoneAvailabilityChange?(next)
        if next.identity == nil, isMicrophoneInputIsolated { onMicrophoneInterrupted?() }
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, result, _, type, reportID, report, reportLength in
        guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
              reportLength > 0, reportLength <= 1_024 else { return }
        let input = Unmanaged<InputContext>.fromOpaque(context).takeUnretainedValue()
        input.owner?.handleInputReport(reportID: reportID, bytes: Array(UnsafeBufferPointer(start: report, count: reportLength)),
                                       generation: input.generation)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, result, _, value in
        guard let context, result == kIOReturnSuccess else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == DualSenseHIDOutput.buttonUsagePage,
              IOHIDElementGetUsage(element) == DualSenseHIDOutput.homeButtonUsage else { return }
        let input = Unmanaged<InputContext>.fromOpaque(context).takeUnretainedValue()
        input.owner?.publishHomeButton(isPressed: IOHIDValueGetIntegerValue(value) != 0, generation: input.generation)
    }

    private static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, removed in
        guard let context else { return }
        let input = Unmanaged<InputContext>.fromOpaque(context).takeUnretainedValue()
        let generation = input.generation
        DispatchQueue.main.async { [weak instance = input.owner] in
            guard let instance, instance.inputGeneration == generation else { return }
            if instance.device == removed { instance.disconnect() }
            else { instance.refreshMicrophoneAvailability() }
        }
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let input = Unmanaged<InputContext>.fromOpaque(context).takeUnretainedValue()
        let generation = input.generation
        DispatchQueue.main.async { [weak instance = input.owner] in
            guard let instance, instance.inputGeneration == generation else { return }
            instance.refreshMicrophoneAvailability()
        }
    }

    private func handleInputReport(reportID: UInt32, bytes: [UInt8], generation: UInt64) {
        inputConfigurationLock.lock()
        let configuration = inputConfiguration
        inputConfigurationLock.unlock()
        guard let configuration, configuration.identity.connectionGeneration == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch configuration.transport {
        case .usb:
            // USB HID can likewise include or omit the separate report ID.
            guard reportID == 0x01 else { return }
            let normalized = bytes.count == 63 ? [UInt8(0x01)] + bytes : bytes
            guard let sample = normalized.withUnsafeBufferPointer({
                DualSenseInputReport.psInputSample(in: $0, transport: .usb, timestamp: now)
            }) else { return }
            enqueuePS(sample, generation: generation)
        case .bluetooth:
            switch DualSenseBluetoothAudioProtocol.classifyInput(reportID: reportID, bytes: bytes) {
            case .unknown:
                // No controls, heartbeat, highlights, motion or audio from an
                // unknown/truncated/bad-CRC report.
                return
            case .microphone(let packet):
                inputConfigurationLock.lock()
                guard var current = inputConfiguration, current.identity == configuration.identity else {
                    inputConfigurationLock.unlock(); return
                }
                let unexpected = !current.isolated
                current.isolated = true
                current.lastAudioTimestamp = now
                inputConfiguration = current
                let handler = microphonePacketHandler
                inputConfigurationLock.unlock()
                if unexpected {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.inputGeneration == generation else { return }
                        self.onPSInputInterrupted?()
                        self.onMicrophoneInterrupted?()
                    }
                }
                handler?(DualSenseHIDMicrophonePacket(identity: current.identity,
                    sessionGeneration: current.sessionGeneration ?? 0, payload: packet.opusPayload,
                    sequence: packet.sequence, timestamp: now))
            case .control(let frame):
                let control = Self.controlSample(frame, identity: configuration.identity, timestamp: now)
                inputConfigurationLock.lock()
                guard var current = inputConfiguration, current.identity == configuration.identity else {
                    inputConfigurationLock.unlock(); return
                }
                current.latestControl = control
                inputConfiguration = current
                let isolated = current.isolated
                let shouldDrain = controlMailbox.append(control)
                inputConfigurationLock.unlock()
                if shouldDrain {
                    DispatchQueue.main.async { [weak self] in self?.drainControls(generation: generation) }
                }
                if !isolated {
                    enqueuePS(DualSensePSInputSample(isPressed: frame.buttons2 & 1 != 0,
                        leftTriggerValue: Float(frame.leftTrigger) / 255, timestamp: now), generation: generation)
                }
            }
        }
    }

    private func drainControls(generation: UInt64) {
        guard inputGeneration == generation else { return }
        let batch = controlMailbox.drain()
        if batch.overflowed {
            onPSInputInterrupted?()
            onMicrophoneInterrupted?()
            return
        }
        for sample in batch.samples {
            guard inputGeneration == generation else { return }
            onTrustedControlSample?(sample)
        }
    }

    static func controlSample(_ frame: DualSenseBluetoothControlFrame,
                              identity: DualSenseHIDEndpointIdentity, timestamp: TimeInterval) -> DualSenseHIDControlSample {
        var pressed = Set<ControllerInput>()
        let buttons: [(UInt8, UInt8, ControllerInput)] = [
            (frame.buttons0, 0x10, .buttonX), (frame.buttons0, 0x20, .buttonA),
            (frame.buttons0, 0x40, .buttonB), (frame.buttons0, 0x80, .buttonY),
            (frame.buttons1, 0x01, .leftShoulder), (frame.buttons1, 0x02, .rightShoulder),
            (frame.buttons1, 0x10, .options), (frame.buttons1, 0x20, .menu),
            (frame.buttons1, 0x40, .leftThumbstickButton), (frame.buttons1, 0x80, .rightThumbstickButton),
            (frame.buttons2, 0x01, .home), (frame.buttons2, 0x02, .touchpadButton),
        ]
        for (byte, mask, input) in buttons where byte & mask != 0 { pressed.insert(input) }
        switch frame.buttons0 & 0x0f {
        case 0: pressed.insert(.dpadUp)
        case 1: pressed.formUnion([.dpadUp, .dpadRight])
        case 2: pressed.insert(.dpadRight)
        case 3: pressed.formUnion([.dpadRight, .dpadDown])
        case 4: pressed.insert(.dpadDown)
        case 5: pressed.formUnion([.dpadDown, .dpadLeft])
        case 6: pressed.insert(.dpadLeft)
        case 7: pressed.formUnion([.dpadLeft, .dpadUp])
        default: break
        }
        // Triggers are not supported PTT keys; still preserve their reported
        // digital bits for neutral-state and diagnostics consumers.
        if frame.buttons1 & 0x04 != 0 { pressed.insert(.leftTrigger) }
        if frame.buttons1 & 0x08 != 0 { pressed.insert(.rightTrigger) }
        return DualSenseHIDControlSample(identity: identity, pressedInputs: pressed, timestamp: timestamp,
            isNeutral: frame.isNeutral, microphoneMuted: frame.microphoneMuted,
            leftTriggerValue: Float(frame.leftTrigger) / 255, rightTriggerValue: Float(frame.rightTrigger) / 255)
    }

    private func enqueuePS(_ sample: DualSensePSInputSample, generation: UInt64) {
        inputConfigurationLock.lock()
        guard let configuration = inputConfiguration,
              configuration.identity.connectionGeneration == generation, !configuration.isolated else {
            inputConfigurationLock.unlock(); return
        }
        let shouldDrain = psInputMailbox.append(sample)
        inputConfigurationLock.unlock()
        if shouldDrain {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputGeneration == generation, !self.isMicrophoneInputIsolated else { return }
                for var sample in self.psInputMailbox.drain() {
                    guard self.inputGeneration == generation, !self.isMicrophoneInputIsolated else { return }
                    sample.allowsVoiceStart = sample.allowsVoiceStart && self.psInputMailbox.canStartVoice(sample)
                    self.onPSInputSample?(sample)
                    self.processHomeButton(isPressed: sample.isPressed)
                }
            }
        }
    }

    private func publishHomeButton(isPressed: Bool, generation: UInt64) {
        inputConfigurationLock.lock()
        let allowed = inputConfiguration?.identity.connectionGeneration == generation &&
            inputConfiguration?.isolated == false && inputConfiguration?.transport == .usb
        inputConfigurationLock.unlock()
        // Bluetooth value events do not retain report provenance. Use only
        // validated raw control frames, even before a microphone session.
        guard allowed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inputGeneration == generation, !self.isMicrophoneInputIsolated else { return }
            self.processHomeButton(isPressed: isPressed)
        }
    }

    @discardableResult
    func beginMicrophone(identity: DualSenseHIDEndpointIdentity, sessionGeneration: UInt64,
                         completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        refreshMicrophoneAvailability()
        guard microphoneAvailability.identity == identity else {
            completion(.failure(DualSenseHIDMicrophoneError.unavailable)); return false
        }
        inputConfigurationLock.lock()
        guard var configuration = inputConfiguration, configuration.identity == identity, !configuration.isolated else {
            inputConfigurationLock.unlock()
            completion(.failure(DualSenseHIDMicrophoneError.recoveryRequired)); return false
        }
        guard let control = configuration.latestControl,
              ProcessInfo.processInfo.systemUptime - control.timestamp <= 0.25 else {
            inputConfigurationLock.unlock()
            completion(.failure(DualSenseHIDMicrophoneError.missingControlState)); return false
        }
        configuration.isolated = true
        configuration.sessionGeneration = sessionGeneration
        configuration.closeTimestamp = nil
        inputConfiguration = configuration
        psInputMailbox.reset()
        inputConfigurationLock.unlock()
        homeReleaseWorkItem?.cancel(); homeReleaseWorkItem = nil
        homeButtonFilter.reset()
        onPSInputInterrupted?()
        return output.begin(connection: identity.connectionGeneration, session: sessionGeneration,
                            muted: control.microphoneMuted, completion: completion)
    }

    func endMicrophone(sessionGeneration: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        inputConfigurationLock.lock()
        guard var configuration = inputConfiguration, configuration.transport == .bluetooth,
              configuration.sessionGeneration == nil || configuration.sessionGeneration == sessionGeneration else {
            inputConfigurationLock.unlock()
            completion(.failure(DualSenseHIDMicrophoneError.cancelled)); return
        }
        configuration.isolated = true
        configuration.sessionGeneration = sessionGeneration
        configuration.closeTimestamp = nil
        inputConfiguration = configuration
        psInputMailbox.reset()
        inputConfigurationLock.unlock()
        let identity = configuration.identity
        output.end(connection: identity.connectionGeneration, session: sessionGeneration) { [weak self] result in
            guard let self else { completion(.failure(DualSenseHIDMicrophoneError.cancelled)); return }
            self.inputConfigurationLock.lock()
            let current = self.inputConfiguration?.identity == identity &&
                self.inputConfiguration?.sessionGeneration == sessionGeneration
            if current, case .success = result {
                self.inputConfiguration?.closeTimestamp = ProcessInfo.processInfo.systemUptime
            }
            self.inputConfigurationLock.unlock()
            completion(current ? result : .failure(DualSenseHIDMicrophoneError.cancelled))
        }
    }

    /// The close write alone is insufficient. Require a newer neutral control
    /// frame, recent control continuity and at least 100 ms without audio.
    @discardableResult
    func finishMicrophoneIsolation(identity: DualSenseHIDEndpointIdentity) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        inputConfigurationLock.lock()
        guard var configuration = inputConfiguration, configuration.identity == identity,
              let closed = configuration.closeTimestamp, let control = configuration.latestControl,
              control.isNeutral, control.timestamp >= closed, now - control.timestamp <= 0.25,
              now - configuration.lastAudioTimestamp >= 0.1,
              output.finishIsolation(connection: identity.connectionGeneration) else {
            inputConfigurationLock.unlock(); return false
        }
        configuration.isolated = false
        configuration.sessionGeneration = nil
        configuration.closeTimestamp = nil
        inputConfiguration = configuration
        psInputMailbox.reset()
        inputConfigurationLock.unlock()
        return true
    }

    private func processHomeButton(isPressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let event = homeButtonFilter.ingest(isPressed: isPressed, at: now) { onHomeButtonChange?(event) }
        flushHomeButtonRelease(at: now)
    }

    private func flushHomeButtonRelease(at now: TimeInterval) {
        if let event = homeButtonFilter.flush(at: now) { onHomeButtonChange?(event) }
        guard let releaseDeadline = homeButtonFilter.releaseDeadline else {
            homeReleaseWorkItem?.cancel(); homeReleaseWorkItem = nil; return
        }
        guard homeReleaseWorkItem == nil else { return }
        let generation = inputGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.inputGeneration == generation, !self.isMicrophoneInputIsolated else { return }
            self.homeReleaseWorkItem = nil
            self.flushHomeButtonRelease(at: ProcessInfo.processInfo.systemUptime)
        }
        homeReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, releaseDeadline - now), execute: workItem)
    }

    func disconnect() {
        let wasConnected = device != nil
        let retiredManager = manager
        let off = offReport()
        inputConfigurationLock.lock()
        inputConfiguration = nil
        inputGeneration &+= 1
        psInputMailbox.reset()
        controlMailbox.reset()
        inputConfigurationLock.unlock()
        device = nil
        transport = nil
        manager = nil
        homeReleaseWorkItem?.cancel(); homeReleaseWorkItem = nil
        homeButtonFilter.reset()
        output.detach(triggerOff: off) {
            if let retiredManager { IOHIDManagerCancel(retiredManager) }
        }
        microphoneAvailability = .unavailable("未连接 DualSense。")
        onMicrophoneAvailabilityChange?(microphoneAvailability)
        if wasConnected {
            onPSInputInterrupted?()
            onMicrophoneInterrupted?()
        }
    }

    /// Returns whether work was accepted, not an IOHID acknowledgement.
    func applyWeaponEffect() -> Bool {
        guard !isMicrophoneInputIsolated else { return false }
        let report: [UInt8]
        switch transport {
        case .usb:
            report = DualSenseUSBOutputReport.weapon(startPosition: RightTriggerPressState.resistanceStart,
                endPosition: RightTriggerPressState.releasePoint, strength: RightTriggerPressState.resistanceStrength)
        case .bluetooth:
            report = DualSenseBluetoothOutputReport.weapon(startPosition: RightTriggerPressState.resistanceStart,
                endPosition: RightTriggerPressState.releasePoint, strength: RightTriggerPressState.resistanceStrength)
        case nil: return false
        }
        return output.enqueueTrigger(report)
    }

    private static func write(_ report: [UInt8], to device: IOHIDDevice) -> Bool {
        guard let reportID = report.first else { return false }
        let result = report.withUnsafeBytes { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID),
                                 buffer.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        if result != kIOReturnSuccess { print("[agent-deck] DualSense HID output failed: \(result)") }
        return result == kIOReturnSuccess
    }

    private func offReport() -> [UInt8]? {
        switch transport {
        case .usb: DualSenseUSBOutputReport.off()
        case .bluetooth: DualSenseBluetoothOutputReport.off()
        case nil: nil
        }
    }

    deinit { disconnect() }
}
