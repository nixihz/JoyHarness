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
            case 0x41, 0xCD: // Menu Pick / Select / Play-Pause -> OK
                return [XiaomiRemoteParsedEvent(input: .buttonA, isPressed: isPressed)]
            case 0x224: // AC Back
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
            case 0x223: // AC Home
                return [XiaomiRemoteParsedEvent(input: .home, isPressed: isPressed)]
            case 0xCF, 0x42: // Voice Command / Speech / Options -> Mic
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
            case 0x29, 0x2A: // Escape / Backspace
                return [XiaomiRemoteParsedEvent(input: .buttonB, isPressed: isPressed)]
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

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            print("[agent-deck] Xiaomi Remote HID manager open failed: \(result)")
            return
        }

        self.manager = manager
        print("[agent-deck] Xiaomi Remote HID discovery started")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
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
        connectedDevices.insert(id)
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
