import Foundation
import IOKit.hid

struct JoyConVector3: Codable, Equatable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = JoyConVector3(x: 0, y: 0, z: 0)

    subscript(index: Int) -> Double {
        switch index {
        case 0: x
        case 1: y
        default: z
        }
    }
}

enum JoyConIMUCalibrationSource: String, Codable, Equatable {
    case user
    case factory
    case `default`
}

struct JoyConIMUAxisCalibration: Equatable {
    let offset: JoyConVector3
    let scale: JoyConVector3
}

struct JoyConIMUCalibration: Equatable {
    let accelerometer: JoyConIMUAxisCalibration
    let gyroscope: JoyConIMUAxisCalibration
    let source: JoyConIMUCalibrationSource

    static let `default` = JoyConIMUCalibration(
        accelerometer: JoyConIMUAxisCalibration(
            offset: .zero,
            scale: JoyConVector3(x: 16_384, y: 16_384, z: 16_384)
        ),
        gyroscope: JoyConIMUAxisCalibration(
            offset: .zero,
            scale: JoyConVector3(x: 13_371, y: 13_371, z: 13_371)
        ),
        source: .default
    )

    init(
        accelerometer: JoyConIMUAxisCalibration,
        gyroscope: JoyConIMUAxisCalibration,
        source: JoyConIMUCalibrationSource
    ) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.source = source
    }

    init?(data: [UInt8], source: JoyConIMUCalibrationSource) {
        guard data.count >= 24 else { return nil }
        let values = stride(from: 0, to: 24, by: 2).map { offset in
            Double(JoyConIMUReportParser.int16(data, at: offset))
        }
        self.init(
            accelerometer: JoyConIMUAxisCalibration(
                offset: JoyConVector3(x: values[0], y: values[1], z: values[2]),
                scale: JoyConVector3(x: values[3], y: values[4], z: values[5])
            ),
            gyroscope: JoyConIMUAxisCalibration(
                offset: JoyConVector3(x: values[6], y: values[7], z: values[8]),
                scale: JoyConVector3(x: values[9], y: values[10], z: values[11])
            ),
            source: source
        )
    }
}

struct JoyConIMUSample: Codable, Equatable {
    let accelerationG: JoyConVector3
    let rotationRateDPS: JoyConVector3
}

struct JoyConHIDShoulderSnapshot: Codable, Equatable {
    let sl: Bool
    let sr: Bool
    let outerShoulder: Bool
    let outerTrigger: Bool
    let capture: Bool
    let home: Bool
    let minus: Bool
    let plus: Bool
    let up: Bool
    let down: Bool
    let left: Bool
    let right: Bool

    init(
        sl: Bool,
        sr: Bool,
        outerShoulder: Bool,
        outerTrigger: Bool,
        capture: Bool = false,
        home: Bool = false,
        minus: Bool = false,
        plus: Bool = false,
        up: Bool = false,
        down: Bool = false,
        left: Bool = false,
        right: Bool = false
    ) {
        self.sl = sl
        self.sr = sr
        self.outerShoulder = outerShoulder
        self.outerTrigger = outerTrigger
        self.capture = capture
        self.home = home
        self.minus = minus
        self.plus = plus
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }
}

enum JoyConHIDSnapshotResolver {
    static func unambiguous<Value>(
        for side: JoyConSide,
        candidates: [(side: JoyConSide, snapshot: Value?)]
    ) -> Value? {
        let matching = candidates.filter { $0.side == side }
        guard matching.count == 1 else { return nil }
        return matching[0].snapshot
    }
}

enum JoyConHIDInputReportParser {
    static let subcommandReplyReportID: UInt8 = 0x21
    static let fullInputReportID: UInt8 = 0x30

    private static let buttonStatusOffset = 3
    private static let rightButtonStatusOffset = buttonStatusOffset
    private static let sharedButtonStatusOffset = buttonStatusOffset + 1
    private static let leftButtonStatusOffset = buttonStatusOffset + 2
    private static let srMask: UInt8 = 1 << 4
    private static let slMask: UInt8 = 1 << 5
    private static let outerShoulderMask: UInt8 = 1 << 6
    private static let outerTriggerMask: UInt8 = 1 << 7

    private static let dDownMask: UInt8 = 1 << 0
    private static let dUpMask: UInt8 = 1 << 1
    private static let dRightMask: UInt8 = 1 << 2
    private static let dLeftMask: UInt8 = 1 << 3

    private static let yMask: UInt8 = 1 << 0
    private static let xMask: UInt8 = 1 << 1
    private static let bMask: UInt8 = 1 << 2
    private static let aMask: UInt8 = 1 << 3

    private static let minusMask: UInt8 = 1 << 0
    private static let plusMask: UInt8 = 1 << 1
    private static let homeMask: UInt8 = 1 << 4
    private static let captureMask: UInt8 = 1 << 5

    static func shoulders(
        from report: [UInt8],
        side: JoyConSide
    ) -> JoyConHIDShoulderSnapshot? {
        guard let reportID = report.first,
              reportID == subcommandReplyReportID || reportID == fullInputReportID,
              report.count > leftButtonStatusOffset else { return nil }

        // The 24-bit status stores R controls in byte 0, shared controls in byte 1, and L controls in byte 2.
        let buttons = report[
            side == .left ? leftButtonStatusOffset : rightButtonStatusOffset
        ]
        let sharedButtons = report[sharedButtonStatusOffset]
        return JoyConHIDShoulderSnapshot(
            sl: buttons & slMask != 0,
            sr: buttons & srMask != 0,
            outerShoulder: buttons & outerShoulderMask != 0,
            outerTrigger: buttons & outerTriggerMask != 0,
            capture: side == .left ? (sharedButtons & captureMask != 0) : false,
            home: side == .right ? (sharedButtons & homeMask != 0) : false,
            minus: side == .left ? (sharedButtons & minusMask != 0) : false,
            plus: side == .right ? (sharedButtons & plusMask != 0) : false,
            up: side == .left ? (buttons & dUpMask != 0) : (buttons & xMask != 0),
            down: side == .left ? (buttons & dDownMask != 0) : (buttons & bMask != 0),
            left: side == .left ? (buttons & dLeftMask != 0) : (buttons & yMask != 0),
            right: side == .left ? (buttons & dRightMask != 0) : (buttons & aMask != 0)
        )
    }
}

enum JoyConIMUReportParser {
    static let reportID: UInt8 = 0x30
    static let reportLength = 49
    static let sampleOffset = 13
    static let sampleLength = 12
    static let sampleCount = 3

    static func samples(
        from report: [UInt8],
        side: JoyConSide,
        calibration: JoyConIMUCalibration
    ) -> [JoyConIMUSample]? {
        guard report.count >= reportLength, report[0] == reportID else { return nil }
        return (0..<sampleCount).map { index in
            let offset = sampleOffset + index * sampleLength
            let rawAcceleration = (0..<3).map {
                Double(int16(report, at: offset + $0 * 2))
            }
            let rawRotation = (0..<3).map {
                Double(int16(report, at: offset + 6 + $0 * 2))
            }
            var acceleration = calibratedAcceleration(
                rawAcceleration,
                calibration: calibration.accelerometer
            )
            var rotation = calibratedRotation(
                rawRotation,
                calibration: calibration.gyroscope
            )
            if side == .right {
                acceleration = JoyConVector3(
                    x: acceleration.x,
                    y: -acceleration.y,
                    z: -acceleration.z
                )
                rotation = JoyConVector3(x: rotation.x, y: -rotation.y, z: -rotation.z)
            }
            return JoyConIMUSample(accelerationG: acceleration, rotationRateDPS: rotation)
        }
    }

    static func int16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return Int16(bitPattern: raw)
    }

    private static func calibratedAcceleration(
        _ raw: [Double],
        calibration: JoyConIMUAxisCalibration
    ) -> JoyConVector3 {
        vector(raw.indices.map { index in
            let divisor = nonzero(calibration.scale[index] - calibration.offset[index])
            return raw[index] * calibration.scale[index] / divisor / 4_096
        })
    }

    private static func calibratedRotation(
        _ raw: [Double],
        calibration: JoyConIMUAxisCalibration
    ) -> JoyConVector3 {
        vector(raw.indices.map { index in
            let divisor = nonzero(calibration.scale[index] - calibration.offset[index])
            return (raw[index] - calibration.offset[index]) * calibration.scale[index]
                / divisor / 14.247
        })
    }

    private static func vector(_ values: [Double]) -> JoyConVector3 {
        JoyConVector3(x: values[0], y: values[1], z: values[2])
    }

    private static func nonzero(_ value: Double) -> Double {
        value == 0 ? 1 : value
    }
}

enum JoyConHIDSubcommand {
    private static let neutralRumble: [UInt8] = [
        0x00, 0x01, 0x40, 0x40,
        0x00, 0x01, 0x40, 0x40,
    ]

    static func report(packetNumber: UInt8, id: UInt8, data: [UInt8]) -> [UInt8] {
        [0x01, packetNumber & 0x0f] + neutralRumble + [id] + data
    }

    static func spiRead(packetNumber: UInt8, address: UInt32, length: UInt8) -> [UInt8] {
        report(packetNumber: packetNumber, id: 0x10, data: [
            UInt8(address & 0xff),
            UInt8((address >> 8) & 0xff),
            UInt8((address >> 16) & 0xff),
            UInt8((address >> 24) & 0xff),
            length,
        ])
    }
}

struct JoyConHIDMotionSnapshot: Codable, Equatable {
    let accelerationG: JoyConVector3
    let rotationRateDPS: JoyConVector3
    let calibrationSource: JoyConIMUCalibrationSource

    enum CodingKeys: String, CodingKey {
        case accelerationG = "acceleration_g"
        case rotationRateDPS = "rotation_rate_dps"
        case calibrationSource = "calibration_source"
    }
}

final class JoyConHIDMotionManager {
    private static let nintendoVendorID = 0x057e
    private static let leftProductID = 0x2006
    private static let rightProductID = 0x2007

    private var manager: IOHIDManager?
    private var endpoints: [ObjectIdentifier: JoyConHIDMotionEndpoint] = [:]
    private var motionSnapshotsByEndpoint: [ObjectIdentifier: JoyConHIDMotionSnapshot] = [:]
    private var shoulderSnapshotsByEndpoint: [ObjectIdentifier: JoyConHIDShoulderSnapshot] = [:]
    private(set) var snapshots: [JoyConSide: JoyConHIDMotionSnapshot] = [:]
    private(set) var shoulderSnapshots: [JoyConSide: JoyConHIDShoulderSnapshot] = [:]

    var onMotionChange: ((JoyConSide, JoyConHIDMotionSnapshot?) -> Void)?
    var onShoulderChange: ((JoyConSide, JoyConHIDShoulderSnapshot?) -> Void)?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [Self.leftProductID, Self.rightProductID].map { productID in
            [
                kIOHIDVendorIDKey as String: Self.nintendoVendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDTransportKey as String: "Bluetooth",
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            joyConHIDDeviceMatched,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            joyConHIDDeviceRemoved,
            Unmanaged.passUnretained(self).toOpaque()
        )
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
            print("[agent-deck] Joy-Con HID motion manager open failed: \(result)")
            return
        }
        self.manager = manager
        print("[agent-deck] Joy-Con HID motion discovery started")
    }

    func stop() {
        for endpoint in endpoints.values { endpoint.close() }
        endpoints.removeAll()
        motionSnapshotsByEndpoint.removeAll()
        shoulderSnapshotsByEndpoint.removeAll()
        snapshots.removeAll()
        shoulderSnapshots.removeAll()
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func add(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard endpoints[id] == nil,
              let productID = (IOHIDDeviceGetProperty(
                device,
                kIOHIDProductIDKey as CFString
              ) as? NSNumber)?.intValue,
              let side = side(for: productID) else { return }
        let endpoint = JoyConHIDMotionEndpoint(
            device: device,
            side: side,
            onSample: { [weak self] sample, source in
                guard let self, self.endpoints[id] != nil else { return }
                let snapshot = JoyConHIDMotionSnapshot(
                    accelerationG: sample.accelerationG,
                    rotationRateDPS: sample.rotationRateDPS,
                    calibrationSource: source
                )
                self.motionSnapshotsByEndpoint[id] = snapshot
                self.publishMotionSnapshot(for: side)
            },
            onShoulderChange: { [weak self] snapshot in
                guard let self, self.endpoints[id] != nil else { return }
                self.shoulderSnapshotsByEndpoint[id] = snapshot
                self.publishShoulderSnapshot(for: side)
            }
        )
        guard endpoint.open() else { return }
        endpoints[id] = endpoint
        publishMotionSnapshot(for: side)
        publishShoulderSnapshot(for: side)
    }

    fileprivate func remove(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard let endpoint = endpoints.removeValue(forKey: id) else { return }
        endpoint.close()
        motionSnapshotsByEndpoint.removeValue(forKey: id)
        shoulderSnapshotsByEndpoint.removeValue(forKey: id)
        publishMotionSnapshot(for: endpoint.side)
        publishShoulderSnapshot(for: endpoint.side)
    }

    private func publishMotionSnapshot(for side: JoyConSide) {
        let next = JoyConHIDSnapshotResolver.unambiguous(
            for: side,
            candidates: endpoints.map { id, endpoint in
                (endpoint.side, motionSnapshotsByEndpoint[id])
            }
        )
        guard snapshots[side] != next else { return }
        snapshots[side] = next
        onMotionChange?(side, next)
    }

    private func publishShoulderSnapshot(for side: JoyConSide) {
        let next = JoyConHIDSnapshotResolver.unambiguous(
            for: side,
            candidates: endpoints.map { id, endpoint in
                (endpoint.side, shoulderSnapshotsByEndpoint[id])
            }
        )
        guard shoulderSnapshots[side] != next else { return }
        shoulderSnapshots[side] = next
        onShoulderChange?(side, next)
    }

    private func side(for productID: Int) -> JoyConSide? {
        switch productID {
        case Self.leftProductID: .left
        case Self.rightProductID: .right
        default: nil
        }
    }
}

private final class JoyConHIDMotionEndpoint {
    private enum Stage: Equatable {
        case idle
        case userMagic
        case calibration(address: UInt32, source: JoyConIMUCalibrationSource)
        case enablingIMU
        case settingReportMode
        case streaming
        case closed
    }

    private static let inputBufferLength = 362
    private static let userMagicAddress: UInt32 = 0x8026
    private static let userCalibrationAddress: UInt32 = 0x8028
    private static let factoryCalibrationAddress: UInt32 = 0x6020
    private static let calibrationLength: UInt8 = 24
    private static let publishInterval: TimeInterval = 0.1

    let side: JoyConSide
    private let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferLength)
    private let onSample: (JoyConIMUSample, JoyConIMUCalibrationSource) -> Void
    private let onShoulderChange: (JoyConHIDShoulderSnapshot) -> Void
    private var stage = Stage.idle
    private var calibration = JoyConIMUCalibration.default
    private var packetNumber: UInt8 = 0
    private var lastPublishedAt: TimeInterval = 0
    private var lastShoulderSnapshot: JoyConHIDShoulderSnapshot?
    private var timeoutGeneration: UInt64 = 0

    init(
        device: IOHIDDevice,
        side: JoyConSide,
        onSample: @escaping (JoyConIMUSample, JoyConIMUCalibrationSource) -> Void,
        onShoulderChange: @escaping (JoyConHIDShoulderSnapshot) -> Void
    ) {
        self.device = device
        self.side = side
        self.onSample = onSample
        self.onShoulderChange = onShoulderChange
        inputBuffer.initialize(repeating: 0, count: Self.inputBufferLength)
    }

    deinit {
        close()
        inputBuffer.deinitialize(count: Self.inputBufferLength)
        inputBuffer.deallocate()
    }

    func open() -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            print("[agent-deck] Joy-Con \(side.rawValue) HID motion open failed: \(result)")
            return false
        }
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            Self.inputBufferLength,
            joyConHIDInputReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        requestUserCalibrationMagic()
        return true
    }

    func close() {
        guard stage != .closed else { return }
        timeoutGeneration &+= 1
        stage = .closed
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 0, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    fileprivate func receive(reportID: CFIndex, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard stage != .closed, length > 0 else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        let id = UInt8(truncatingIfNeeded: reportID)
        if bytes.first != id { bytes.insert(id, at: 0) }
        handleShoulderReport(bytes)
        switch id {
        case 0x21:
            handleSubcommandReply(bytes)
        case JoyConIMUReportParser.reportID:
            handleIMUReport(bytes)
        default:
            break
        }
    }

    private func handleShoulderReport(_ report: [UInt8]) {
        guard let snapshot = JoyConHIDInputReportParser.shoulders(from: report, side: side),
              snapshot != lastShoulderSnapshot else { return }
        lastShoulderSnapshot = snapshot
        onShoulderChange(snapshot)
    }

    private func requestUserCalibrationMagic() {
        stage = .userMagic
        sendSPIRead(address: Self.userMagicAddress, length: 2)
        scheduleFallback(for: .userMagic) { [weak self] in
            self?.requestCalibration(address: Self.factoryCalibrationAddress, source: .factory)
        }
    }

    private func requestCalibration(address: UInt32, source: JoyConIMUCalibrationSource) {
        stage = .calibration(address: address, source: source)
        sendSPIRead(address: address, length: Self.calibrationLength)
        scheduleFallback(for: stage) { [weak self] in
            self?.calibration = .default
            self?.enableIMU()
        }
    }

    private func enableIMU() {
        stage = .enablingIMU
        send(id: 0x40, data: [0x01])
        scheduleFallback(for: .enablingIMU) { [weak self] in
            self?.setFullReportMode()
        }
    }

    private func setFullReportMode() {
        stage = .settingReportMode
        send(id: 0x03, data: [JoyConIMUReportParser.reportID])
        scheduleFallback(for: .settingReportMode) { [weak self] in
            self?.stage = .streaming
        }
    }

    private func handleSubcommandReply(_ report: [UInt8]) {
        guard report.count >= 15, report[13] & 0x80 != 0 else { return }
        let subcommand = report[14]
        switch (stage, subcommand) {
        case (.userMagic, 0x10):
            guard let reply = spiReply(report), reply.address == Self.userMagicAddress else { return }
            let hasUserCalibration = reply.data.starts(with: [0xb2, 0xa1])
            requestCalibration(
                address: hasUserCalibration
                    ? Self.userCalibrationAddress : Self.factoryCalibrationAddress,
                source: hasUserCalibration ? .user : .factory
            )
        case let (.calibration(address, source), 0x10):
            guard let reply = spiReply(report), reply.address == address else { return }
            calibration = JoyConIMUCalibration(data: reply.data, source: source) ?? .default
            enableIMU()
        case (.enablingIMU, 0x40):
            setFullReportMode()
        case (.settingReportMode, 0x03):
            stage = .streaming
            print("[agent-deck] Joy-Con \(side.rawValue) HID IMU ready calibration=\(calibration.source.rawValue)")
        default:
            break
        }
    }

    private func handleIMUReport(_ report: [UInt8]) {
        guard stage == .streaming,
              let sample = JoyConIMUReportParser.samples(
                from: report,
                side: side,
                calibration: calibration
              )?.last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishedAt >= Self.publishInterval else { return }
        lastPublishedAt = now
        onSample(sample, calibration.source)
    }

    private func spiReply(_ report: [UInt8]) -> (address: UInt32, data: [UInt8])? {
        guard report.count >= 20 else { return nil }
        let address = UInt32(report[15])
            | (UInt32(report[16]) << 8)
            | (UInt32(report[17]) << 16)
            | (UInt32(report[18]) << 24)
        let length = Int(report[19])
        guard length > 0, report.count >= 20 + length else { return nil }
        return (address, Array(report[20..<(20 + length)]))
    }

    private func sendSPIRead(address: UInt32, length: UInt8) {
        send(JoyConHIDSubcommand.spiRead(
            packetNumber: nextPacketNumber(),
            address: address,
            length: length
        ))
    }

    private func send(id: UInt8, data: [UInt8]) {
        send(JoyConHIDSubcommand.report(
            packetNumber: nextPacketNumber(),
            id: id,
            data: data
        ))
    }

    private func send(_ report: [UInt8]) {
        let result = report.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
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
            print("[agent-deck] Joy-Con \(side.rawValue) HID subcommand write failed: \(result)")
        }
    }

    private func nextPacketNumber() -> UInt8 {
        defer { packetNumber = (packetNumber + 1) & 0x0f }
        return packetNumber
    }

    private func scheduleFallback(for expectedStage: Stage, action: @escaping () -> Void) {
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self,
                  self.timeoutGeneration == generation,
                  self.stage == expectedStage else { return }
            action()
        }
    }
}

private func joyConHIDDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<JoyConHIDMotionManager>.fromOpaque(context).takeUnretainedValue().add(device)
}

private func joyConHIDDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<JoyConHIDMotionManager>.fromOpaque(context).takeUnretainedValue().remove(device)
}

private func joyConHIDInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<JoyConHIDMotionEndpoint>.fromOpaque(context).takeUnretainedValue().receive(
        reportID: CFIndex(reportID),
        report: report,
        length: reportLength
    )
}
