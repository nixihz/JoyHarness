import AppKit
import Darwin
import IOKit

/// DDC/CI wire format, independently implemented from the protocol and checked
/// against a real Redmi 27 NU reply. No method in this type performs device I/O.
/// Reference implementations (MIT):
/// https://github.com/waydabber/m1ddc
/// https://github.com/MonitorControl/MonitorControl
/// Their historical Get VCP checksum omits 0x51. This implementation includes
/// that source address; the resulting 82 01 10 AC request works on the tested
/// AppleDCPMCDP29XX bridge, while 82 01 10 FD returned invalid data.
enum AIVoiceDDCProtocol {
    struct Brightness: Equatable, Sendable {
        let current: UInt16
        let maximum: UInt16
        var normalized: Double { Double(current) / Double(maximum) }
    }

    static func getBrightnessRequest() -> [UInt8] {
        packet([0x82, 0x01, 0x10])
    }

    static func setBrightnessRequest(_ value: UInt16) -> [UInt8] {
        packet([0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xff)])
    }

    private static func packet(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(UInt8(0x6e ^ 0x51), ^)]
    }

    static func decodeBrightnessReply(_ bytes: [UInt8]) -> Brightness? {
        // Get VCP Feature Reply: source, length, opcode, result, feature, type,
        // maximum[2], current[2], checksum. A zero IOKit return is insufficient:
        // the tested bridge also reports success for garbage and null replies.
        guard bytes.count == 11,
              bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0, bytes[4] == 0x10, bytes[5] == 0,
              bytes.reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return Brightness(current: current, maximum: maximum)
    }

    /// Deliberately conservative. The IORegistry traversal order used by some
    /// tools is not proof that a proxy belongs to a particular framebuffer.
    /// Until an exact multi-display association is available, reject ambiguity.
    static func uniqueProxy(displayID: CGDirectDisplayID,
                            externalDisplayIDs: [CGDirectDisplayID],
                            externalProxyIDs: [UInt64]) -> UInt64? {
        guard externalDisplayIDs == [displayID], externalProxyIDs.count == 1 else { return nil }
        return externalProxyIDs[0]
    }
}

/// Hardware DDC/CI brightness for an unambiguously identified external screen.
/// The current implementation supports exactly one physical external display
/// and one external DCP proxy. It never guesses among multiple monitors.
@MainActor
final class AIVoiceDDCBrightness: AIVoiceBrightnessHardware {
    let name: String
    private let displayID: CGDirectDisplayID
    private let identity: Identity
    private let proxyID: UInt64
    private let chipAddress: UInt32
    private let service: UnsafeRawPointer
    private let functions: Functions

    private struct Identity: Equatable {
        let uuid: String
        let location: String
        let adapterID: UInt64
        let edidUUID: String
        let alphanumericSerial: String
    }

    private struct Proxy {
        let port: io_service_t
        let id: UInt64
    }

    static func make(displayID: CGDirectDisplayID, name: String) throws -> AIVoiceDDCBrightness {
        let functions = try Functions()
        let identity = try displayIdentity(displayID, functions: functions)
        let displays = try externalDisplays(functions: functions)
        let proxies = try externalProxies()
        defer { proxies.forEach { IOObjectRelease($0.port) } }
        guard let proxyID = AIVoiceDDCProtocol.uniqueProxy(
            displayID: displayID, externalDisplayIDs: displays,
            externalProxyIDs: proxies.map(\.id)),
              let proxy = proxies.first(where: { $0.id == proxyID }) else {
            throw AIVoiceSystemControlError("无法唯一匹配外接显示器的亮度控制通道；未修改屏幕。")
        }
        guard let service = functions.create(nil, proxy.port) else {
            throw AIVoiceSystemControlError("无法打开 \(name) 的硬件亮度控制通道。")
        }
        let chipAddress = isMCDP29XX(proxy.port) ? UInt32(0xb7) : UInt32(0x37)
        return AIVoiceDDCBrightness(displayID: displayID, name: name, identity: identity,
                                   proxyID: proxyID, chipAddress: chipAddress,
                                   service: service, functions: functions)
    }

    private init(displayID: CGDirectDisplayID, name: String, identity: Identity,
                 proxyID: UInt64, chipAddress: UInt32, service: UnsafeRawPointer,
                 functions: Functions) {
        self.displayID = displayID
        self.name = name
        self.identity = identity
        self.proxyID = proxyID
        self.chipAddress = chipAddress
        self.service = service
        self.functions = functions
    }

    deinit {
        Unmanaged<CFTypeRef>.fromOpaque(service).release()
    }

    func brightness() async throws -> AIVoiceScalarControlState {
        let value = try await readBrightness()
        // A successful Get proves that VCP 0x10 exists. Actual write support is
        // established by the caller's post-write readback, never by IOKit alone.
        return .init(values: [value.normalized], isSettable: true)
    }

    func setBrightness(_ value: Double) async throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw AIVoiceSystemControlError("亮度必须在 0% 到 100% 之间，未修改屏幕。")
        }
        let before = try await readBrightness()
        let target = UInt16((value * Double(before.maximum)).rounded())
        if target == before.current { return }
        try validateIdentity()
        try await send(AIVoiceDDCProtocol.setBrightnessRequest(target))
        // The controller verifies the requested value with a separate Get VCP.
        // Do not report success merely because the transport accepted the write.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func readBrightness() async throws -> AIVoiceDDCProtocol.Brightness {
        try validateIdentity()
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await send(AIVoiceDDCProtocol.getBrightnessRequest())
            // HDMI bridges need at least 50 ms before a meaningful reply.
            try await Task.sleep(nanoseconds: 50_000_000)
            try validateIdentity()
            var bytes = [UInt8](repeating: 0, count: 11)
            let result = bytes.withUnsafeMutableBytes { buffer in
                functions.read(service, chipAddress, 0, buffer.baseAddress!, UInt32(buffer.count))
            }
            if result == 0, let value = AIVoiceDDCProtocol.decodeBrightnessReply(bytes) {
                return value
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        throw AIVoiceSystemControlError("\(name) 未返回有效的硬件亮度读数，请检查显示器的 DDC/CI 设置或连接方式。")
    }

    private func send(_ packet: [UInt8]) async throws {
        // Some display controllers require the identical transaction twice.
        // Set VCP writes an absolute value, so repeating it is idempotent.
        for _ in 0..<2 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
            // Awaiting permits cancellation and hot-plug events to be handled;
            // revalidate immediately before this individual I2C transaction.
            try validateIdentity()
            var bytes = packet
            let result = bytes.withUnsafeMutableBytes { buffer in
                functions.write(service, chipAddress, 0x51, buffer.baseAddress!, UInt32(buffer.count))
            }
            guard result == 0 else {
                throw AIVoiceSystemControlError("\(name) 的亮度控制通信失败（\(result)）。")
            }
        }
    }

    private func validateIdentity() throws {
        try Task.checkCancellation()
        guard try Self.displayIdentity(displayID, functions: functions) == identity else {
            throw AIVoiceSystemControlError("显示器连接已变化，已停止亮度操作。")
        }
        let displays = try Self.externalDisplays(functions: functions)
        let proxies = try Self.externalProxies()
        defer { proxies.forEach { IOObjectRelease($0.port) } }
        guard AIVoiceDDCProtocol.uniqueProxy(displayID: displayID,
            externalDisplayIDs: displays, externalProxyIDs: proxies.map(\.id)) == proxyID else {
            throw AIVoiceSystemControlError("显示器连接已变化或存在多个控制通道，已停止亮度操作。")
        }
    }

    private static func externalDisplays(functions: Functions) throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw AIVoiceSystemControlError("无法读取已连接的显示器。")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw AIVoiceSystemControlError("无法读取已连接的显示器。")
        }
        var external: [CGDirectDisplayID] = []
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
            guard let dictionary = functions.displayInfo(id) else {
                throw AIVoiceSystemControlError("无法确认显示器身份，未修改屏幕。")
            }
            if (dictionary["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue == true
                || (dictionary["kCGDisplayIsAirPlay"] as? NSNumber)?.boolValue == true {
                continue
            }
            guard dictionary["IODisplayLocation"] is String else {
                throw AIVoiceSystemControlError("无法确认外接显示器的硬件连接，未修改屏幕。")
            }
            external.append(id)
        }
        return external
    }

    private static func displayIdentity(_ id: CGDirectDisplayID, functions: Functions) throws -> Identity {
        guard CGDisplayIsBuiltin(id) == 0,
              let dictionary = functions.displayInfo(id),
              let uuid = dictionary["kCGDisplayUUID"] as? String, !uuid.isEmpty,
              let location = dictionary["IODisplayLocation"] as? String, !location.isEmpty else {
            throw AIVoiceSystemControlError("无法确认外接显示器身份，未修改屏幕。")
        }
        let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard adapter != IO_OBJECT_NULL else {
            throw AIVoiceSystemControlError("显示器硬件连接已断开。")
        }
        defer { IOObjectRelease(adapter) }
        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS,
              let edid = property(adapter, "EDID UUID") as? String, !edid.isEmpty,
              let attributes = property(adapter, "DisplayAttributes") as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let vendor = product["LegacyManufacturerID"] as? NSNumber,
              let model = product["ProductID"] as? NSNumber,
              vendor.uint32Value == CGDisplayVendorNumber(id),
              model.uint32Value == CGDisplayModelNumber(id) else {
            throw AIVoiceSystemControlError("显示器硬件身份不一致，未修改屏幕。")
        }
        return Identity(uuid: uuid, location: location, adapterID: adapterID, edidUUID: edid,
                        alphanumericSerial: product["AlphanumericSerialNumber"] as? String ?? "")
    }

    private static func externalProxies() throws -> [Proxy] {
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else {
            throw AIVoiceSystemControlError("系统未提供外接屏幕亮度通道。")
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw AIVoiceSystemControlError("无法查询外接屏幕亮度通道。")
        }
        defer { IOObjectRelease(iterator) }
        var proxies: [Proxy] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            guard property(entry, "Location") as? String == "External" else {
                IOObjectRelease(entry)
                continue
            }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                proxies.forEach { IOObjectRelease($0.port) }
                throw AIVoiceSystemControlError("无法确认屏幕控制通道身份，未修改屏幕。")
            }
            proxies.append(Proxy(port: entry, id: id))
        }
        return proxies
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func isMCDP29XX(_ proxy: io_service_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return property(parent, "EPICProviderClass") as? String == "AppleDCPMCDP29XX"
    }

    /// Raw pointers avoid introducing a bridging header for private CF types.
    /// Both libraries remain loaded until after the owned IOAVService is freed.
    private final class Functions {
        typealias Create = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeRawPointer?
        typealias Transfer = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
        typealias CopyInfo = @convention(c) (CGDirectDisplayID) -> UnsafeRawPointer?
        let create: Create
        let read: Transfer
        let write: Transfer
        private let copyInfo: CopyInfo
        private let ioHandle: UnsafeMutableRawPointer
        private let displayHandle: UnsafeMutableRawPointer

        init() throws {
            guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else {
                throw AIVoiceSystemControlError("当前系统未提供 DDC/CI 控制接口。")
            }
            guard let display = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL) else {
                dlclose(io)
                throw AIVoiceSystemControlError("当前系统未提供显示器身份接口。")
            }
            guard let create = dlsym(io, "IOAVServiceCreateWithService"),
                  let read = dlsym(io, "IOAVServiceReadI2C"),
                  let write = dlsym(io, "IOAVServiceWriteI2C"),
                  let copyInfo = dlsym(display, "CoreDisplay_DisplayCreateInfoDictionary") else {
                dlclose(display)
                dlclose(io)
                throw AIVoiceSystemControlError("当前系统缺少外接屏幕亮度控制接口。")
            }
            self.ioHandle = io
            self.displayHandle = display
            self.create = unsafeBitCast(create, to: Create.self)
            self.read = unsafeBitCast(read, to: Transfer.self)
            self.write = unsafeBitCast(write, to: Transfer.self)
            self.copyInfo = unsafeBitCast(copyInfo, to: CopyInfo.self)
        }

        func displayInfo(_ id: CGDirectDisplayID) -> NSDictionary? {
            guard let pointer = copyInfo(id) else { return nil }
            return Unmanaged<CFDictionary>.fromOpaque(pointer).takeRetainedValue() as NSDictionary
        }

        deinit {
            dlclose(displayHandle)
            dlclose(ioHandle)
        }
    }
}
