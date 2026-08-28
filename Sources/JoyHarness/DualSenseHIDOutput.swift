import Foundation
import IOKit.hid

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

final class DualSenseHIDOutput {
    private static let sonyVendorID = 0x054c
    private static let dualSenseProductID = 0x0ce6

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = [UInt8](repeating: 0, count: 64)
    private var lastPSPressed = false

    var onHomeButtonChange: ((Bool) -> Void)?

    func connectUSB() -> Bool {
        disconnect()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.sonyVendorID,
            kIOHIDProductIDKey as String: Self.dualSenseProductID,
            kIOHIDTransportKey as String: "USB",
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return false
        }
        self.manager = manager
        self.device = device
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
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        print("[agent-deck] DualSense USB HID background trigger ready")
        return true
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
        guard let context else { return }
        let instance = Unmanaged<DualSenseHIDOutput>.fromOpaque(context).takeUnretainedValue()
        instance.handleInputReport(report: report, length: reportLength)
    }

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 10 else { return }
        let bytes = UnsafeBufferPointer(start: report, count: length)
        let ps = (bytes[10] & 0x01) != 0
        if ps != lastPSPressed {
            lastPSPressed = ps
            DispatchQueue.main.async { [weak self] in
                self?.onHomeButtonChange?(ps)
            }
        }
    }

    func disconnect() {
        if let device {
            _ = send(DualSenseUSBOutputReport.off())
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 0)
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 0, nil, nil)
            buffer.deallocate()
        }
        device = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        lastPSPressed = false
    }

    func applyWeaponEffect() -> Bool {
        let report = DualSenseUSBOutputReport.weapon(
            startPosition: RightTriggerPressState.resistanceStart,
            endPosition: RightTriggerPressState.releasePoint,
            strength: RightTriggerPressState.resistanceStrength
        )
        let succeeded = send(report)
        if succeeded {
            print("[agent-deck] DualSense R2 background effect restored")
        }
        return succeeded
    }

    private func send(_ report: [UInt8]) -> Bool {
        guard let device else { return false }
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
            print("[agent-deck] DualSense USB HID trigger write failed: \(result)")
        }
        return result == kIOReturnSuccess
    }
}
