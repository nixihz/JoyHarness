import Darwin
import Foundation

final class RP2040Bridge {
    var onConnectionChange: ((Bool) -> Void)?
    var onMessage: ((String) -> Void)?

    private let queue = DispatchQueue(label: "tech.agentdeck.rp2040")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?
    private var readBuffer = Data()
    private var connectedPath: String?
    private var rejectedUntil: [String: Date] = [:]
    private let lock = NSLock()
    private var connected = false

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.reconnectTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.connectIfNeeded() }
            self.reconnectTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.reconnectTimer?.cancel()
            self?.reconnectTimer = nil
            self?.disconnect()
        }
    }

    @discardableResult
    func sendKey(_ key: String, action: Int, agent: Int? = nil) -> Bool {
        guard isConnected else { return false }
        let safeKey = key.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard !safeKey.isEmpty else { return false }
        send("H \(safeKey) \(action) \(agent ?? -1)\n")
        return true
    }

    @discardableResult
    func sendJoystick(angle: Float, distance: Float) -> Bool {
        guard isConnected else { return false }
        let angleValue = Int((min(max(angle, 0), 1) * 1000).rounded())
        let distanceValue = Int((min(max(distance, 0), 1) * 1000).rounded())
        send("J \(angleValue) \(distanceValue)\n")
        return true
    }

    func tapSlot(_ index: Int, twice: Bool = false) {
        guard (0..<6).contains(index) else { return }
        let key = String(format: "AG%02d", index)
        tap(key)
        if twice {
            queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.tap(key) }
        }
    }

    private func tap(_ key: String) {
        _ = sendKey(key, action: 1)
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            _ = self?.sendKey(key, action: 0)
        }
    }

    private func send(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in self?.write(data) }
    }

    private func connectIfNeeded() {
        guard descriptor < 0 else { return }
        let now = Date()
        rejectedUntil = rejectedUntil.filter { $0.value > now }
        for path in candidatePaths() {
            guard rejectedUntil[path] == nil else { continue }
            let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else { continue }
            configure(fd)
            descriptor = fd
            connectedPath = path
            readBuffer.removeAll(keepingCapacity: true)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
            print("[agent-deck] probing RP2040 bridge at \(path)")
            write(Data("P\n".utf8))
            queue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self,
                      self.descriptor == fd,
                      !self.isConnected else { return }
                self.rejectedUntil[path] = Date().addingTimeInterval(5)
                print("[agent-deck] ignored non-Joy Harness serial device at \(path)")
                self.disconnect()
            }
            return
        }
    }

    private func candidatePaths() -> [String] {
        if let override = ProcessInfo.processInfo.environment["AGENT_DECK_RP2040_PORT"],
           !override.isEmpty {
            return [override]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    private func configure(_ fd: Int32) {
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { return }
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cc.16 = 1 // VMIN
        settings.c_cc.17 = 0 // VTIME
        _ = tcsetattr(fd, TCSANOW, &settings)
    }

    private func write(_ data: Data) {
        guard descriptor >= 0 else { return }
        let result = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, base, bytes.count)
        }
        if result < 0, errno != EAGAIN { disconnect() }
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count == 0 {
            disconnect()
            return
        }
        if count < 0 {
            if errno != EAGAIN { disconnect() }
            return
        }
        readBuffer.append(contentsOf: bytes.prefix(count))
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if Self.isReadyLine(line), !isConnected {
                setConnected(true)
                print("[agent-deck] RP2040 bridge connected at \(connectedPath ?? "unknown")")
            }
            print("[agent-deck] RP2040: \(line)")
            DispatchQueue.main.async { [weak self] in self?.onMessage?(line) }
        }
    }

    static func isReadyLine(_ line: String) -> Bool {
        let supportedFirmwareNames = ["agentdeck-rp2040", "codexpad-rp2040"]
        return supportedFirmwareNames.contains { name in
            line == "READY \(name)" || line.hasPrefix("READY \(name) ")
        }
    }

    private func disconnect() {
        guard descriptor >= 0 else { return }
        let previousPath = connectedPath
        descriptor = -1
        connectedPath = nil
        source?.cancel()
        source = nil
        readBuffer.removeAll(keepingCapacity: true)
        setConnected(false)
        print("[agent-deck] RP2040 bridge disconnected\(previousPath.map { " from \($0)" } ?? "")")
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        let changed = connected != value
        connected = value
        lock.unlock()
        if changed {
            DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(value) }
        }
    }
}
