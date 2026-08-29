import Darwin
import Foundation

final class RP2040Bridge {
    var onConnectionChange: ((Bool) -> Void)?
    var onMessage: ((String) -> Void)?

    private let queue = DispatchQueue(label: "tech.agentdeck.rp2040")
    private let queueKey = DispatchSpecificKey<Void>()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var reconnectTimer: DispatchSourceTimer?
    private var readBuffer = Data()
    private var connectedPath: String?
    private var rejectedUntil: [String: Date] = [:]
    private let lock = NSLock()
    private var connected = false
    private var outputBuffer = SerialOutputBuffer(capacity: 64_000)

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    var isRunning: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return reconnectTimer != nil
        }
        return queue.sync { reconnectTimer != nil }
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
        let cleanup = {
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            self.disconnect()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    @discardableResult
    func sendKey(_ key: String, action: Int, agent: Int? = nil) -> Bool {
        guard !key.isEmpty,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return false
        }
        return send("H \(key) \(action) \(agent ?? -1)\n")
    }

    @discardableResult
    func sendJoystick(angle: Float, distance: Float) -> Bool {
        let angleValue = Int((min(max(angle, 0), 1) * 1000).rounded())
        let distanceValue = Int((min(max(distance, 0), 1) * 1000).rounded())
        return send("J \(angleValue) \(distanceValue)\n")
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

    private func send(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8) else { return false }
        lock.lock()
        let accepted = connected && outputBuffer.enqueue(data)
        lock.unlock()
        if accepted {
            queue.async { [weak self] in self?.drainWrites() }
        }
        return accepted
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
            self.source = source
            source.resume()
            print("[agent-deck] probing RP2040 bridge at \(path)")
            lock.lock()
            _ = outputBuffer.enqueue(Data("P\n".utf8))
            lock.unlock()
            drainWrites()
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

    private func drainWrites() {
        guard descriptor >= 0 else { return }
        let currentDescriptor = descriptor
        lock.lock()
        let result = outputBuffer.drain { data in
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(currentDescriptor, baseAddress, bytes.count)
            }
            if written > 0 { return .written(written) }
            if written < 0, errno == EINTR { return .interrupted }
            if written == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
            return .failed
        }
        lock.unlock()

        switch result {
        case .empty:
            writeSource?.cancel()
            writeSource = nil
        case .pending:
            armWriteSource(for: currentDescriptor)
        case .failed:
            disconnect()
        }
    }

    private func armWriteSource(for fileDescriptor: Int32) {
        guard writeSource == nil, descriptor == fileDescriptor else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drainWrites() }
        writeSource = source
        source.resume()
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
        lock.lock()
        let connectionChanged = connected
        connected = false
        outputBuffer.removeAll()
        lock.unlock()

        let disconnectedDescriptor = descriptor
        let previousPath = connectedPath
        descriptor = -1
        connectedPath = nil
        writeSource?.cancel()
        writeSource = nil
        source?.cancel()
        source = nil
        close(disconnectedDescriptor)
        readBuffer.removeAll(keepingCapacity: true)
        if connectionChanged {
            DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(false) }
        }
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
