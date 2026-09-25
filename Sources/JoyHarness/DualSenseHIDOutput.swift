import Foundation
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
        guard report.count > homeButtonIndex, report[0] == reportID else { return nil }
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
    private static let sonyVendorID = 0x054c
    private static let dualSenseProductID = 0x0ce6
    private static let buttonUsagePage = UInt32(kHIDPage_Button)
    private static let homeButtonUsage: UInt32 = 13

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var transport: DualSenseHIDTransport?
    private var inputBuffer = [UInt8](repeating: 0, count: 78)
    private var homeButtonFilter = DualSenseHomeButtonFilter()
    private var homeReleaseWorkItem: DispatchWorkItem?

    var onHomeButtonChange: ((Bool) -> Void)?

    func connect() -> Bool {
        disconnect()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.sonyVendorID,
            kIOHIDProductIDKey as String: Self.dualSenseProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        let connections = devices.compactMap { device -> (IOHIDDevice, DualSenseHIDTransport)? in
            let rawValue = IOHIDDeviceGetProperty(
                device,
                kIOHIDTransportKey as CFString
            )
            guard let value = rawValue as? String,
                let transport = DualSenseHIDTransport(ioKitValue: value) else { return nil }
            return (device, transport)
        }
        guard let connection = connections.first(where: { $0.1 == .usb }) ?? connections.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        let (device, transport) = connection
        self.manager = manager
        self.device = device
        self.transport = transport
        let context = Unmanaged.passUnretained(self).toOpaque()
        inputBuffer.withUnsafeMutableBufferPointer { ptr in
            if let base = ptr.baseAddress {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    base,
                    ptr.count,
                    Self.inputReportCallback,
                    context
                )
            }
        }
        IOHIDDeviceRegisterInputValueCallback(device, Self.inputValueCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        print("[agent-deck] DualSense \(transport.rawValue) HID background trigger ready")
        return true
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
        guard let context else { return }
        let instance = Unmanaged<DualSenseHIDOutput>.fromOpaque(context).takeUnretainedValue()
        instance.handleInputReport(report: report, length: reportLength)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, result, sender, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == DualSenseHIDOutput.buttonUsagePage,
              IOHIDElementGetUsage(element) == DualSenseHIDOutput.homeButtonUsage else { return }
        let instance = Unmanaged<DualSenseHIDOutput>.fromOpaque(context).takeUnretainedValue()
        let isPressed = IOHIDValueGetIntegerValue(value) != 0
        instance.publishHomeButton(isPressed: isPressed)
    }

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard let transport,
              let isPressed = DualSenseInputReport.isHomeButtonPressed(
                  in: UnsafeBufferPointer(start: report, count: length),
                  transport: transport
              ) else { return }
        publishHomeButton(isPressed: isPressed)
    }

    private func publishHomeButton(isPressed: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.processHomeButton(isPressed: isPressed)
        }
    }

    private func processHomeButton(isPressed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let event = homeButtonFilter.ingest(isPressed: isPressed, at: now) {
            onHomeButtonChange?(event)
        }
        flushHomeButtonRelease(at: now)
    }

    /// Streaming reports flush a due release themselves; the timer only covers
    /// a device that stops reporting while the release is pending.
    private func flushHomeButtonRelease(at now: TimeInterval) {
        if let event = homeButtonFilter.flush(at: now) {
            onHomeButtonChange?(event)
        }
        guard let releaseDeadline = homeButtonFilter.releaseDeadline else {
            homeReleaseWorkItem?.cancel()
            homeReleaseWorkItem = nil
            return
        }
        guard homeReleaseWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.homeReleaseWorkItem = nil
            self.flushHomeButtonRelease(at: ProcessInfo.processInfo.systemUptime)
        }
        homeReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.001, releaseDeadline - now),
            execute: workItem
        )
    }

    func disconnect() {
        homeReleaseWorkItem?.cancel()
        homeReleaseWorkItem = nil
        if let device {
            if let report = offReport() {
                _ = send(report)
            }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 0)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 0, nil, nil)
            buffer.deallocate()
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        }
        device = nil
        transport = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        homeButtonFilter.reset()
    }

    func applyWeaponEffect() -> Bool {
        let report: [UInt8]
        switch transport {
        case .usb:
            report = DualSenseUSBOutputReport.weapon(
                startPosition: RightTriggerPressState.resistanceStart,
                endPosition: RightTriggerPressState.releasePoint,
                strength: RightTriggerPressState.resistanceStrength
            )
        case .bluetooth:
            report = DualSenseBluetoothOutputReport.weapon(
                startPosition: RightTriggerPressState.resistanceStart,
                endPosition: RightTriggerPressState.releasePoint,
                strength: RightTriggerPressState.resistanceStrength
            )
        case nil:
            return false
        }
        let succeeded = send(report)
        if succeeded {
            print("[agent-deck] DualSense R2 background effect restored")
        }
        return succeeded
    }

    private func send(_ report: [UInt8]) -> Bool {
        guard let device, let transport else { return false }
        let result = report.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(report[0]),
                baseAddress,
                report.count
            )
        }
        if result != kIOReturnSuccess {
            print("[agent-deck] DualSense \(transport.rawValue) HID trigger write failed: \(result)")
        }
        return result == kIOReturnSuccess
    }

    private func offReport() -> [UInt8]? {
        switch transport {
        case .usb: DualSenseUSBOutputReport.off()
        case .bluetooth: DualSenseBluetoothOutputReport.off()
        case nil: nil
        }
    }
}
