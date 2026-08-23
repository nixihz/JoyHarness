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
        print("[agent-deck] DualSense USB HID background trigger ready")
        return true
    }

    func disconnect() {
        if device != nil {
            _ = send(DualSenseUSBOutputReport.off())
        }
        device = nil
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
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
