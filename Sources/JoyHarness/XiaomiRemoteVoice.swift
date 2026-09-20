import CoreBluetooth
import Foundation

enum RemoteVoiceStreamEvent {
    case started, ended, cancelled
}

final class XiaomiRemoteVoice: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let transmit = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private static let information = CBUUID(string: "180A")
    private static let modelNumber = CBUUID(string: "2A24")
    private static let battery = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var remote: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var notifications: Set<CBUUID> = []
    private var capabilities: RemoteVoiceCapabilities?
    private var confirmedModel = false
    private var requestedCapabilities = false
    private var wanted = false
    private var microphoneOpen = false
    private var stream = RemoteVoiceStream()
    private var enhancer = RemoteVoiceEnhancer()
    private var timeout: DispatchWorkItem?
    var enabled = true {
        didSet { if !enabled { closeMicrophone() } }
    }
    var onStatus: (() -> Void)?
    var onSamples: (([Int16]) -> Void)?
    var onStreamEvent: ((RemoteVoiceStreamEvent) -> Void)?
    private(set) var isReady = false
    private(set) var status = "遥控器麦克风未连接"
    private(set) var batteryLevel: Float?

    private func report(_ text: String) {
        status = text
        print("[agent-deck] Xiaomi voice: \(text)")
        onStatus?()
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        report("正在连接遥控器麦克风")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        wanted = false
        timeout?.cancel()
        closeMicrophone()
        central?.stopScan()
        if let remote { central?.cancelPeripheralConnection(remote) }
        remote?.delegate = nil
        remote = nil
        central?.delegate = nil
        central = nil
        clearConnection()
        report("遥控器麦克风未连接")
    }

    private func clearConnection() {
        isReady = false
        transmit = nil
        notifications.removeAll()
        capabilities = nil
        confirmedModel = false
        requestedCapabilities = false
        microphoneOpen = false
        batteryLevel = nil
        finishStream(cancelled: true)
    }

    private func discover() {
        guard wanted, let central, central.state == .poweredOn, remote == nil else { return }
        let candidates = central.retrieveConnectedPeripherals(withServices: [Self.service])
            .filter { Self.matchesName($0.name) }
        if candidates.count == 1, let candidate = candidates.first {
            connect(candidate)
        } else if candidates.count > 1 {
            report("发现多个小米遥控器，无法确定语音设备")
        } else {
            central.scanForPeripherals(withServices: [Self.service])
            report("正在寻找遥控器语音服务")
        }
    }

    static func matchesName(_ name: String?) -> Bool {
        guard let name else { return false }
        return ["MI RC", "小米蓝牙语音遥控器", "Xiaomi Bluetooth Voice Remote"].contains(name)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard remote == nil, wanted else { return }
        central?.stopScan()
        // A nil remote is already clean (initial state or cleared on disconnect).
        // Resetting here would cancel a HID press that woke the BLE connection.
        remote = peripheral
        peripheral.delegate = self
        central?.connect(peripheral)
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, self.remote === peripheral, !self.isReady else { return }
            self.report("遥控器麦克风连接超时；请按键唤醒")
            self.central?.cancelPeripheralConnection(peripheral)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func write(_ bytes: [UInt8]) {
        guard let remote, let transmit else { return }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.write) ? .withResponse : .withoutResponse
        remote.writeValue(Data(bytes), for: transmit, type: type)
    }

    private func initialize() {
        guard confirmedModel, notifications.contains(Self.audio), notifications.contains(Self.control),
              transmit != nil, !requestedCapabilities else { return }
        requestedCapabilities = true
        write([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    }

    private func closeMicrophone() {
        if microphoneOpen { write([0x0D, stream.session ?? 0]) }
        microphoneOpen = false
        finishStream(cancelled: true)
    }

    private func finishStream(cancelled: Bool) {
        guard stream.session != nil else {
            if cancelled { onStreamEvent?(.cancelled) }
            return
        }
        print("[agent-deck] Xiaomi voice PCM samples=\(stream.sampleCount) peak=\(stream.peak) rate=16000")
        stream.stop()
        enhancer.reset()
        onStreamEvent?(cancelled ? .cancelled : .ended)
        if isReady { report("遥控器麦克风已连接") }
    }

    private func receiveControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first else { return }
        print("[agent-deck] Xiaomi voice control opcode=\(String(format: "0x%02x", opcode)) bytes=\(bytes.count)")
        if opcode == 0x0B {
            guard requestedCapabilities, !isReady, let caps = RemoteVoiceCapabilities(data) else {
                report("遥控器语音协议不受支持")
                return
            }
            capabilities = caps
            isReady = true
            timeout?.cancel()
            report("遥控器麦克风已连接")
            print("[agent-deck] Xiaomi voice ATVV version=\(caps.version) frame=\(caps.frameBytes) rate=16000")
            return
        }
        guard isReady else { return }
        switch opcode {
        case 0x08 where enabled:
            guard !microphoneOpen else { return }
            microphoneOpen = true
            write([0x0C, 0x00])
        case 0x04 where enabled:
            guard bytes.count >= 4, bytes[2] == 2 else {
                closeMicrophone()
                report("遥控器返回了不受支持的语音格式")
                return
            }
            guard stream.session != bytes[3] else { return }
            // Starting the replacement output clears old buffers/completions;
            // do not cancel a new HID press that may already have arrived.
            if stream.session != nil { finishStream(cancelled: false) }
            // RC003 can initiate AUDIO_START directly on a physical voice press,
            // without sending START_SEARCH or waiting for a host MIC_OPEN.
            microphoneOpen = true
            stream.start(session: bytes[3])
            report("正在接收遥控器麦克风")
            onStreamEvent?(.started)
        case 0x00:
            microphoneOpen = false
            finishStream(cancelled: false)
        case 0x0A where stream.session != nil:
            guard bytes.count >= 7, bytes[6] <= 88 else { closeMicrophone(); return }
            let bits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            stream.synchronize(sample: Int16(bitPattern: bits), index: Int(bytes[6]))
            enhancer.reset()
        default:
            break
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, wanted else { return }
        if central.state == .poweredOn { discover() }
        else {
            timeout?.cancel()
            remote?.delegate = nil
            remote = nil
            clearConnection()
            report(central.state == .unauthorized ? "请允许 Joy Harness 使用蓝牙" : "蓝牙暂不可用")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, Self.matchesName(peripheral.name) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, remote === peripheral, wanted else { return }
        peripheral.discoverServices([Self.service, Self.information, Self.battery])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, remote === peripheral else { return }
        timeout?.cancel()
        peripheral.delegate = nil
        remote = nil
        clearConnection()
        report("遥控器麦克风已断开，等待重连")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.discover() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard remote === peripheral, wanted else { return }
        guard error == nil else { report("读取遥控器语音服务失败"); return }
        for service in peripheral.services ?? [] {
            if service.uuid == Self.service { peripheral.discoverCharacteristics([Self.transmit, Self.audio, Self.control], for: service) }
            if service.uuid == Self.information { peripheral.discoverCharacteristics([Self.modelNumber], for: service) }
            if service.uuid == Self.battery { peripheral.discoverCharacteristics([Self.batteryLevel], for: service) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard remote === peripheral, wanted, error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.transmit:
                guard !characteristic.properties.intersection([.write, .writeWithoutResponse]).isEmpty else { continue }
                transmit = characteristic
            case Self.audio, Self.control:
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.modelNumber:
                peripheral.readValue(for: characteristic)
            case Self.batteryLevel:
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            default: break
            }
        }
        initialize()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, wanted else { return }
        if characteristic.uuid == Self.batteryLevel {
            if let error { print("[agent-deck] Xiaomi battery notifications unavailable: \(error.localizedDescription)") }
            return
        }
        guard error == nil, characteristic.isNotifying else {
            closeMicrophone()
            report("遥控器语音通知订阅失败")
            return
        }
        notifications.insert(characteristic.uuid)
        initialize()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, let error else { return }
        microphoneOpen = false
        finishStream(cancelled: true)
        report("遥控器语音命令失败：\(error.localizedDescription)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard remote === peripheral, wanted, error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.batteryLevel:
            guard let level = Self.normalizedBatteryLevel(data) else { return }
            if batteryLevel != level {
                batteryLevel = level
                print("[agent-deck] Xiaomi battery level=\(Int((level * 100).rounded()))%")
                onStatus?()
            }
        case Self.modelNumber:
            let model = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            confirmedModel = model == "RC003" || model == "RC003-MS"
            guard confirmedModel else { report("语音设备型号不是 RC003-MS"); return }
            print("[agent-deck] Xiaomi voice model=\(model ?? "")")
            initialize()
        case Self.control:
            receiveControl(data)
        case Self.audio:
            guard enabled, isReady, microphoneOpen, let capabilities else { return }
            let pcm = stream.append(data, frameBytes: capabilities.frameBytes)
            // Enhance immediately after BLE/ADPCM decoding so every live
            // recognition consumer receives the cleaned PCM. The virtual HAL
            // only forwards these samples and never performs file post-processing.
            if !pcm.isEmpty { onSamples?(enhancer.processInt16(pcm)) }
        default: break
        }
    }

    static func normalizedBatteryLevel(_ data: Data) -> Float? {
        guard let raw = data.first, raw <= 100 else { return nil }
        return Float(raw) / 100
    }
}
