import CoreAudio
import Foundation
import GameController

enum ControllerFamily: String {
    case dualSense = "dualsense"
    case dualShock = "dualshock"
    case xbox = "xbox"
    case generic = "generic"

    var displayName: String {
        switch self {
        case .dualSense: "PS5 DualSense"
        case .dualShock: "PlayStation DualShock"
        case .xbox: "Xbox"
        case .generic: "通用手柄"
        }
    }

    var dashboardArtworkResource: String? {
        switch self {
        case .dualSense: "controller-dashboard-dualsense-transparent"
        case .xbox, .generic: "controller-dashboard"
        case .dualShock: nil
        }
    }

    static func detect(controller: GCController) -> Self {
        if controller.extendedGamepad is GCDualSenseGamepad ||
            controller.productCategory == GCProductCategoryDualSense {
            return .dualSense
        }
        if controller.extendedGamepad is GCDualShockGamepad {
            return .dualShock
        }
        let identity = "\(controller.vendorName ?? "") \(controller.productCategory)".lowercased()
        return identity.contains("xbox") ? .xbox : .generic
    }
}

enum ControllerBatteryState: String, Equatable {
    case unknown
    case discharging
    case charging
    case full
}

struct ControllerBatterySnapshot: Equatable {
    let level: Float
    let state: ControllerBatteryState

    var percentage: Int {
        Int((min(max(level, 0), 1) * 100).rounded())
    }

    init(level: Float, state: ControllerBatteryState) {
        self.level = min(max(level, 0), 1)
        self.state = state
    }

    init?(_ battery: GCDeviceBattery?) {
        guard let battery else { return nil }
        let state: ControllerBatteryState = switch battery.batteryState {
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        self.init(level: battery.batteryLevel, state: state)
    }
}

struct ControllerVoiceInput: Equatable {
    let name: String
    let isDefault: Bool
    let transport: String
}

struct ControllerAudioSnapshot: Equatable {
    let controllerInput: ControllerVoiceInput?
    let defaultInputName: String?
}

enum ControllerAudioSupport {
    static func snapshot(for family: ControllerFamily) -> ControllerAudioSnapshot {
        let devices = inputDevices()
        let defaultInput = defaultInputDeviceID()
        let defaultInputName = devices.first(where: { $0.id == defaultInput })?.name
        let controllerInput: ControllerVoiceInput? = if family == .dualSense {
            devices.first(where: { matchesDualSenseAudioDevice($0.name) }).map {
                ControllerVoiceInput(
                    name: $0.name,
                    isDefault: $0.id == defaultInput,
                    transport: transportDescription($0.transport)
                )
            }
        } else {
            nil
        }
        return ControllerAudioSnapshot(
            controllerInput: controllerInput,
            defaultInputName: defaultInputName
        )
    }

    static func findVoiceInput(for family: ControllerFamily) -> ControllerVoiceInput? {
        snapshot(for: family).controllerInput
    }

    static func matchesDualSenseAudioDevice(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("dualsense") || normalized.contains("wireless controller")
    }

    static func transportDescription(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth: "蓝牙"
        case kAudioDeviceTransportTypeBuiltIn: "内置"
        case kAudioDeviceTransportTypeVirtual: "虚拟"
        default: "其他"
        }
    }

    private static func inputDevices() -> [(id: AudioDeviceID, name: String, transport: UInt32)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return [] }

        return devices.compactMap { device in
            guard hasInputStreams(device),
                  let name = deviceName(device),
                  let transport = deviceTransport(device) else { return nil }
            return (device, name, transport)
        }
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>? = nil
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &name) == noErr else {
            return nil
        }
        return name?.takeUnretainedValue() as String?
    }

    private static func deviceTransport(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &dataSize, &transport
        ) == noErr else { return nil }
        return transport
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &device
        ) == noErr else { return nil }
        return device
    }
}
