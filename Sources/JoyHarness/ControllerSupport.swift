import CoreAudio
import Foundation
import GameController

struct ControllerArtworkDescriptor: Equatable {
    let resource: String
    let rotationDegrees: Double
}

enum ControllerFamily: String {
    case dualSense = "dualsense"
    case dualShock = "dualshock"
    case xbox = "xbox"
    case joyConPair = "joycon-pair"
    case joyConLeft = "joycon-left"
    case joyConRight = "joycon-right"
    case xiaomiRemote = "xiaomi-remote"
    case generic = "generic"

    var joyConMode: JoyConMode? {
        switch self {
        case .joyConPair: .pair
        case .joyConLeft: .left
        case .joyConRight: .right
        default: nil
        }
    }

    var isJoyCon: Bool { joyConMode != nil }
    var isXiaomiRemote: Bool { self == .xiaomiRemote }

    var displayName: String {
        switch self {
        case .dualSense: "PS5 DualSense"
        case .dualShock: "PlayStation DualShock"
        case .xbox: "Xbox"
        case .joyConPair: "Nintendo Joy-Con L + R"
        case .joyConLeft: "Nintendo Joy-Con (L)"
        case .joyConRight: "Nintendo Joy-Con (R)"
        case .xiaomiRemote: L10n.text("小米蓝牙遥控器", "Xiaomi Remote")
        case .generic: L10n.text("通用手柄", "Generic Controller")
        }
    }

    func dashboardArtworkDescriptors(
        orientation: JoyConOrientation = .vertical
    ) -> [ControllerArtworkDescriptor] {
        switch self {
        case .dualSense:
            [ControllerArtworkDescriptor(
                resource: "controller-dashboard-dualsense-transparent",
                rotationDegrees: 0
            )]
        case .xbox, .generic:
            [ControllerArtworkDescriptor(resource: "controller-dashboard", rotationDegrees: 0)]
        case .xiaomiRemote:
            [ControllerArtworkDescriptor(resource: "controller-dashboard-xiaomi-remote", rotationDegrees: 0)]
        case .joyConPair:
            [
                ControllerArtworkDescriptor(resource: "controller-dashboard-joycon-left", rotationDegrees: 0),
                ControllerArtworkDescriptor(resource: "controller-dashboard-joycon-right", rotationDegrees: 0),
            ]
        case .joyConLeft:
            [ControllerArtworkDescriptor(
                resource: "controller-dashboard-joycon-left",
                rotationDegrees: orientation == .horizontal ? -90 : 0
            )]
        case .joyConRight:
            [ControllerArtworkDescriptor(
                resource: "controller-dashboard-joycon-right",
                rotationDegrees: orientation == .horizontal ? 90 : 0
            )]
        case .dualShock:
            []
        }
    }

    static func detect(controller: GCController) -> Self {
        if let joyCon = controller.joyConHardwareKind {
            return switch joyCon {
            case .left: .joyConLeft
            case .right: .joyConRight
            case .pair: .joyConPair
            }
        }
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

enum ControllerConnectionSource: String {
    case gameController
    case xiaomiRemote
}

/// A live input device exposed to the settings UI.
///
/// `id` is intentionally scoped to the current process. GameController does
/// not expose a stable hardware identifier for every supported device, so the
/// runtime uses the controller object identity while it is connected.
struct ConnectedControllerDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let family: ControllerFamily
    let source: ControllerConnectionSource
    /// Inputs this device can report. A Joy-Con composition may expose fewer
    /// than its family supports, for example when a stick is unreadable.
    let availableInputs: Set<ControllerInput>

    init(
        id: String,
        name: String,
        family: ControllerFamily,
        source: ControllerConnectionSource,
        availableInputs: Set<ControllerInput>? = nil
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.source = source
        let supported = ControllerInput.availableInputs(for: family)
        self.availableInputs = availableInputs?.intersection(supported) ?? supported
    }

    var displayName: String {
        if name.isEmpty { return family.displayName }
        return name
    }

    /// Picker titles keyed by device ID. Devices with the same name, such as
    /// two identical gamepads, are numbered in list order.
    static func pickerTitles(for devices: [ConnectedControllerDescriptor]) -> [String: String] {
        let counts = Dictionary(devices.map { ($0.displayName, 1) }, uniquingKeysWith: +)
        var ordinals: [String: Int] = [:]
        var titles: [String: String] = [:]
        for device in devices {
            let name = device.displayName
            guard counts[name, default: 0] > 1 else {
                titles[device.id] = name
                continue
            }
            let ordinal = ordinals[name, default: 0] + 1
            ordinals[name] = ordinal
            titles[device.id] = "\(name) \(ordinal)"
        }
        return titles
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
        case kAudioDeviceTransportTypeBluetooth: L10n.text("蓝牙", "Bluetooth")
        case kAudioDeviceTransportTypeBuiltIn: L10n.text("内置", "Built-in")
        case kAudioDeviceTransportTypeVirtual: L10n.text("虚拟", "Virtual")
        default: L10n.text("其他", "Other")
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

enum XiaomiRemoteConstants {
    static let vendorID: Int = 0x2717
    static let productID: Int = 0x32B8
}
