import Foundation
import IOKit.hid

struct CodexMicroSnapshot {
    static let reportID: CFIndex = 7
    let slots: [EdgeLightSlot]

    init?(report: [UInt8]) {
        guard report.count == 64, Array(report.prefix(4)) == [7, 0x4A, 0x48, 1], report[4] & 0xC0 == 0 else { return nil }
        slots = (0..<6).map { index in
            let offset = 6 + index * 7
            let rgb = UInt32(report[offset + 4]) << 16 | UInt32(report[offset + 5]) << 8 | UInt32(report[offset + 6])
            let seen = report[4] & (1 << index) != 0
            let off = seen && (report[offset] == 0 || report[offset + 1] == 0)
            let mapped: PadState? = switch rgb {
            case 0x304FFE: .busy
            case 0x00FF4C: .done
            case 0xFFFFFF: .idle
            case 0xFF6D00: .waiting
            case 0xFF0033: .error
            default: nil
            }
            let state = !seen || off ? nil : mapped
            return EdgeLightSlot(identity: "micro-\(index)", title: "Micro \(index + 1)", state: state,
                                 lightingRGB: seen && !off ? rgb : nil, isOff: off)
        }
    }

}

// Feature 与原生 RPC 使用不同 Report ID，读取不会消费 ChatGPT 的响应。
final class CodexMicroMirror {
    private let queue = DispatchQueue(label: "tech.keli.joyharness.micro-mirror")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    var onSnapshot: ((CodexMicroSnapshot?) -> Void)?

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x303A, kIOHIDProductIDKey: 0x8360,
                                                  kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 1] as CFDictionary)
            // 调度设备发现，固件重启或重新插拔后才能更新设备集合与描述符。
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                self.deliver(nil); return
            }
            self.manager = manager
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(400), leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel(); self.timer = nil
            self.device = nil
            if let manager = self.manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self.manager = nil
        }
    }

    private func poll() {
        guard let manager else { return }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        // 只接受能返回协议签名的设备，旧固件不会被误认为已同步。
        let candidates = device.map { devices.contains($0) ? [$0] : [] } ?? Array(devices)
        for candidate in candidates {
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = 7
            var length = report.count
            let result = report.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(candidate, kIOHIDReportTypeFeature, CodexMicroSnapshot.reportID, $0.baseAddress!, &length)
            }
            if result == kIOReturnSuccess, length == 64, let snapshot = CodexMicroSnapshot(report: report) {
                device = candidate
                deliver(snapshot)
                return
            }
        }
        device = nil
        deliver(nil)
    }

    private func deliver(_ snapshot: CodexMicroSnapshot?) {
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }
}
