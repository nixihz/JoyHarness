import Foundation
import IOKit.hid

struct XiaomiRemoteParsedEvent: Equatable {
    let input: ControllerInput
    let isPressed: Bool
}

final class XiaomiRemoteHIDParser {
    private var activeHatDirections: Set<ControllerInput> = []

    func parse(usagePage: UInt32, usage: UInt32, value: Int) -> [XiaomiRemoteParsedEvent] {
        let isPressed = value != 0

        // 1. Generic Desktop Page (0x01)
        if usagePage == 0x01 {
            switch usage {
            case 0x84, 0x86: // System Context/App Menu
                return [XiaomiRemoteParsedEvent(input: .menu, isPressed: isPressed)]
            case 0x88: // System Menu Exit
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x89: // System Menu Select
                return [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: isPressed)]
            case 0x90:
                return [XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: isPressed)]
            case 0x91:
                return [XiaomiRemoteParsedEvent(input: .dpadDown, isPressed: isPressed)]
            case 0x92:
                return [XiaomiRemoteParsedEvent(input: .dpadRight, isPressed: isPressed)]
            case 0x93:
                return [XiaomiRemoteParsedEvent(input: .dpadLeft, isPressed: isPressed)]
            case 0x85: // System Main Menu
                return [XiaomiRemoteParsedEvent(input: .home, isPressed: isPressed)]
            case 0x39: // Hat Switch
                return parseHatSwitch(value: value)
            default:
                break
            }
        }

        // 2. Consumer Page (0x0C)
        if usagePage == 0x0C {
            switch usage {
            case 0x30: // Power
                return [XiaomiRemoteParsedEvent(input: .home, isPressed: isPressed)]
            case 0x40: // Menu
                return [XiaomiRemoteParsedEvent(input: .menu, isPressed: isPressed)]
            case 0x41, 0xCD: // Menu Pick / Select / Play-Pause -> OK
                return [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: isPressed)]
            case 0x42: // Menu Escape
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x224: // AC Back
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x223: // AC Home
                return [XiaomiRemoteParsedEvent(input: .home, isPressed: isPressed)]
            case 0xCF: // Voice Command -> Mic
                return [XiaomiRemoteParsedEvent(input: .options, isPressed: isPressed)]
            case 0xE9: // Volume Increment
                return [XiaomiRemoteParsedEvent(input: .rightShoulder, isPressed: isPressed)]
            case 0xEA: // Volume Decrement
                return [XiaomiRemoteParsedEvent(input: .leftShoulder, isPressed: isPressed)]
            case 0x194, 0x80, 0x6F: // Custom Keys
                return [XiaomiRemoteParsedEvent(input: .buttonY, isPressed: isPressed)]
            default:
                break
            }
        }

        // 3. Keyboard / Keypad Page (0x07)
        if usagePage == 0x07 {
            switch usage {
            case 0x52: // Up Arrow
                return [XiaomiRemoteParsedEvent(input: .dpadUp, isPressed: isPressed)]
            case 0x51: // Down Arrow
                return [XiaomiRemoteParsedEvent(input: .dpadDown, isPressed: isPressed)]
            case 0x50: // Left Arrow
                return [XiaomiRemoteParsedEvent(input: .dpadLeft, isPressed: isPressed)]
            case 0x4F: // Right Arrow
                return [XiaomiRemoteParsedEvent(input: .dpadRight, isPressed: isPressed)]
            case 0x28: // Return / Enter
                return [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: isPressed)]
            case 0x29: // Escape
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x2A: // Backspace
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0xF1: // RC003-MS Back (captured on the physical remote)
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x65: // Keyboard Application / RC003-MS Menu
                return [XiaomiRemoteParsedEvent(input: .menu, isPressed: isPressed)]
            case 0x81: // Keyboard Volume Down
                return [XiaomiRemoteParsedEvent(input: .leftShoulder, isPressed: isPressed)]
            case 0x80: // Keyboard Volume Up
                return [XiaomiRemoteParsedEvent(input: .rightShoulder, isPressed: isPressed)]
            case 0x35: // RC003-MS custom key (Keyboard Grave)
                return [XiaomiRemoteParsedEvent(input: .buttonY, isPressed: isPressed)]
            case 0x4A: // Keyboard Home / RC003-MS Home
                return [XiaomiRemoteParsedEvent(input: .home, isPressed: isPressed)]
            case 0x3E: // RC003-MS Voice (Keyboard F5, confirmed by a controlled trace)
                return [XiaomiRemoteParsedEvent(input: .options, isPressed: isPressed)]
            default:
                break
            }
        }

        // 4. Button Page (0x09)
        if usagePage == 0x09 {
            switch usage {
            case 1:
                return [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: isPressed)]
            case 2:
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 3:
                return [XiaomiRemoteParsedEvent(input: .options, isPressed: isPressed)]
            case 4:
                return [XiaomiRemoteParsedEvent(input: .buttonY, isPressed: isPressed)]
            default:
                break
            }
        }

        return []
    }

    private func parseHatSwitch(value: Int) -> [XiaomiRemoteParsedEvent] {
        var nextDirections: Set<ControllerInput> = []
        switch value {
        case 0: nextDirections = [.dpadUp]
        case 1: nextDirections = [.dpadUp, .dpadRight]
        case 2: nextDirections = [.dpadRight]
        case 3: nextDirections = [.dpadDown, .dpadRight]
        case 4: nextDirections = [.dpadDown]
        case 5: nextDirections = [.dpadDown, .dpadLeft]
        case 6: nextDirections = [.dpadLeft]
        case 7: nextDirections = [.dpadUp, .dpadLeft]
        default: break // Neutral
        }

        var events: [XiaomiRemoteParsedEvent] = []
        // Released
        for dir in activeHatDirections where !nextDirections.contains(dir) {
            events.append(XiaomiRemoteParsedEvent(input: dir, isPressed: false))
        }
        // Pressed
        for dir in nextDirections where !activeHatDirections.contains(dir) {
            events.append(XiaomiRemoteParsedEvent(input: dir, isPressed: true))
        }

        activeHatDirections = nextDirections
        return events
    }

    func reset() -> [XiaomiRemoteParsedEvent] {
        let events = activeHatDirections.map { XiaomiRemoteParsedEvent(input: $0, isPressed: false) }
        activeHatDirections.removeAll()
        return events
    }
}

final class XiaomiRemoteHIDManager {
    private var manager: IOHIDManager?
    private let parser = XiaomiRemoteHIDParser()
    private(set) var isConnected = false
    private var connectedDevices: Set<ObjectIdentifier> = []
    private let volumeGuard = RemoteVolumeGuard()
    private var operationMode: ControllerOperationMode = .mapping

    func setOperationMode(_ mode: ControllerOperationMode) {
        operationMode = mode
        volumeGuard.update(mapping: isConnected && mode == .mapping)
    }

    var onConnectionChange: ((Bool) -> Void)?
    var onButtonInput: ((ControllerInput, Bool) -> Void)?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchingDict: [String: Any] = [
            kIOHIDVendorIDKey as String: XiaomiRemoteConstants.vendorID,
            kIOHIDProductIDKey as String: XiaomiRemoteConstants.productID,
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, xiaomiRemoteDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, xiaomiRemoteDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, xiaomiRemoteInputValueChanged, context)
        if ProcessInfo.processInfo.environment["JOY_HARNESS_REMOTE_TRACE"] == "1" {
            IOHIDManagerRegisterInputReportCallback(manager, xiaomiRemoteInputReportReceived, context)
        }

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        // Monitor this keyboard/consumer device using Input Monitoring consent.
        // Seizing it can fail with kIOReturnNotPrivileged even after consent.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            let code = String(format: "0x%08x", UInt32(bitPattern: result))
            print("[agent-deck] Xiaomi Remote HID manager open failed: \(result) (\(code))")
            return
        }

        self.manager = manager
        // IOHIDManager may not replay a matching callback for devices that were
        // already connected before the manager was opened. Register those
        // devices explicitly so launch order does not affect detection.
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                deviceMatched(device)
            }
        }
        print("[agent-deck] Xiaomi Remote HID discovery started")
    }

    func stop() {
        volumeGuard.stop()
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        connectedDevices.removeAll()
        if isConnected {
            isConnected = false
            onConnectionChange?(false)
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard connectedDevices.insert(id).inserted else { return }
        volumeGuard.update(mapping: operationMode == .mapping)
        // The guard keeps retrying until the corresponding event service is ready.
        if !isConnected {
            isConnected = true
            print("[agent-deck] Xiaomi Remote connected")
            onConnectionChange?(true)
        }
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        connectedDevices.remove(id)
        if connectedDevices.isEmpty && isConnected {
            volumeGuard.update(mapping: false)
            isConnected = false
            print("[agent-deck] Xiaomi Remote disconnected")
            let resetEvents = parser.reset()
            for event in resetEvents {
                onButtonInput?(event.input, false)
            }
            onConnectionChange?(false)
        }
    }

    fileprivate func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intVal = IOHIDValueGetIntegerValue(value)

        let events = parser.parse(usagePage: usagePage, usage: usage, value: intVal)
        // Keyboard array payloads and rollover elements duplicate the individual
        // key values. Keep diagnostics focused on actual button usages.
        if usage != UInt32.max && !(usagePage == 0x07 && usage <= 0x03) {
            let usageDescription = String(format: "page=0x%02x usage=0x%02x", usagePage, usage)
            let mappedInputs = events.map { "\($0.input.rawValue):\($0.isPressed ? "down" : "up")" }.joined(separator: ",")
            print("[agent-deck] Xiaomi Remote \(usageDescription) value=\(intVal) mapped=\(mappedInputs)")
        }
        for event in events {
            onButtonInput?(event.input, event.isPressed)
        }
    }
}

private func xiaomiRemoteDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceMatched(device)
}

private func xiaomiRemoteDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
    manager.deviceRemoved(device)
}

private func xiaomiRemoteInputValueChanged(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let manager = Unmanaged<XiaomiRemoteHIDManager>.fromOpaque(context).takeUnretainedValue()
    manager.handleValue(value)
}

private func xiaomiRemoteInputReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess, reportLength > 0 else { return }
    let prefix = UnsafeBufferPointer(start: report, count: min(reportLength, 16))
        .map { String(format: "%02x", $0) }.joined(separator: " ")
    print("[agent-deck] Xiaomi Remote report id=\(reportID) length=\(reportLength) prefix=\(prefix)")
}
