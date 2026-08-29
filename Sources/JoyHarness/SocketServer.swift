import Darwin
import Foundation

final class SocketServer {
    private let path: String
    private let requestTimeout: TimeInterval
    private let maximumRequestBytes: Int
    private var fd: Int32 = -1
    private let onCommand: (PadCommand) -> Void
    private var source: DispatchSourceRead?
    private var socketIdentity: SocketFileIdentity?
    private let lifecycleLock = NSLock()
    private var activeClients: Set<Int32> = []
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = false

    var activeClientCount: Int {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return activeClients.count
    }

    init(
        path: String,
        requestTimeout: TimeInterval = 1.0,
        maximumRequestBytes: Int = 64_000,
        onCommand: @escaping (PadCommand) -> Void
    ) {
        self.path = path
        self.requestTimeout = requestTimeout
        self.maximumRequestBytes = maximumRequestBytes
        self.onCommand = onCommand
    }

    deinit {
        stop()
    }

    func start() throws {
        guard fd < 0 else { return }
        try removeStaleSocketIfPresent()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let listeningFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listeningFD >= 0 else { throw ServerError.socket }
        fd = listeningFD

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
            let bytes = path.utf8.map { CChar(bitPattern: $0) }
            guard bytes.count <= maxLength else { throw ServerError.pathTooLong }
            withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                for (index, byte) in bytes.enumerated() {
                    pointer.advanced(by: index).pointee = byte
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        listeningFD,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else { throw ServerError.bind }
            socketIdentity = Self.fileIdentity(at: path)
            guard listen(listeningFD, 8) == 0 else { throw ServerError.listen }
            guard chmod(path, 0o600) == 0 else { throw ServerError.permissions }
        } catch {
            close(listeningFD)
            fd = -1
            removeOwnedSocket()
            throw error
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: listeningFD, queue: .main)
        readSource.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        readSource.setCancelHandler {
            close(listeningFD)
        }
        source = readSource
        lifecycleLock.lock()
        lifecycleGeneration &+= 1
        isRunning = true
        lifecycleLock.unlock()
        readSource.resume()
        print("[agent-deck] listening on \(path)")
    }

    func stop() {
        lifecycleLock.lock()
        isRunning = false
        for client in activeClients {
            shutdown(client, SHUT_RDWR)
        }
        lifecycleLock.unlock()

        guard fd >= 0 else { return }
        fd = -1
        let readSource = source
        source = nil
        removeOwnedSocket()
        readSource?.cancel()
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        lifecycleLock.lock()
        guard isRunning else {
            lifecycleLock.unlock()
            close(client)
            return
        }
        let generation = lifecycleGeneration
        activeClients.insert(client)
        lifecycleLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                close(client)
                return
            }
            self.handle(client: client, generation: generation)
        }
    }

    private func handle(client: Int32, generation: UInt64) {
        var noSignal = Int32(1)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )

        switch readRequestLine(client: client) {
        case let .success(data):
            switch decodeCommand(data) {
            case let .success(command):
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        close(client)
                        return
                    }
                    if self.isActive(client: client, generation: generation) {
                        self.onCommand(command)
                        self.writeResponse(#"{"ok":true}"#, to: client)
                    }
                    self.finish(client: client)
                }
                return
            case let .failure(error):
                writeError(error.rawValue, to: client)
            }
        case let .failure(error):
            writeError(error.rawValue, to: client)
        }
        finish(client: client)
    }

    private func isActive(client: Int32, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isRunning && lifecycleGeneration == generation && activeClients.contains(client)
    }

    private func finish(client: Int32) {
        lifecycleLock.lock()
        activeClients.remove(client)
        lifecycleLock.unlock()
        close(client)
    }

    private func readRequestLine(client: Int32) -> Result<Data, RequestError> {
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(requestTimeout, 0) * 1_000_000_000)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .failure(.timeout) }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, Int32(min(remainingMilliseconds, Int(Int32.max))))
            if pollResult == 0 { return .failure(.timeout) }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return .failure(.readFailed)
            }

            let count = Darwin.read(client, &chunk, chunk.count)
            if count == 0 { return .failure(.incompleteRequest) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failure(.readFailed)
            }

            let bytes = chunk.prefix(count)
            if let newline = bytes.firstIndex(of: 0x0A) {
                let line = bytes.prefix(upTo: newline)
                guard request.count + line.count <= maximumRequestBytes else {
                    return .failure(.requestTooLarge)
                }
                request.append(contentsOf: line)
                return request.isEmpty ? .failure(.emptyRequest) : .success(request)
            }
            guard request.count + bytes.count <= maximumRequestBytes else {
                return .failure(.requestTooLarge)
            }
            request.append(contentsOf: bytes)
        }
    }

    private func decodeCommand(_ data: Data) -> Result<PadCommand, RequestError> {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.emptyRequest) }

        if let state = PadState.parse(raw) {
            return .success(PadCommand(state: state.rawValue, action: nil, note: nil, threadID: nil))
        }

        if let jsonData = raw.data(using: .utf8) {
            let command: PadCommand
            do {
                command = try JSONDecoder().decode(PadCommand.self, from: jsonData)
            } catch PadCommand.CommandDecodingError.invalidAction {
                return .failure(.invalidAction)
            } catch {
                if raw.first == "{" || raw.first == "[" {
                    return .failure(.invalidJSON)
                }
                return .failure(.invalidCommand)
            }
            guard command.state != nil || command.action != nil else {
                return .failure(.invalidCommand)
            }
            if let state = command.state, PadState.parse(state) == nil {
                return .failure(.invalidState)
            }
            return .success(command)
        }

        if raw.first == "{" || raw.first == "[" {
            return .failure(.invalidJSON)
        }
        return .failure(.invalidCommand)
    }

    private func writeError(_ error: String, to client: Int32) {
        writeResponse(#"{"ok":false,"error":"\#(error)"}"#, to: client)
    }

    private func writeResponse(_ response: String, to client: Int32) {
        let data = Data("\(response)\n".utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(client, baseAddress.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    enum ServerError: Error {
        case socket, bind, listen, pathTooLong, pathOccupied, permissions
    }

    private enum RequestError: String, Error {
        case emptyRequest = "empty_request"
        case incompleteRequest = "incomplete_request"
        case invalidAction = "invalid_action"
        case invalidCommand = "invalid_command"
        case invalidJSON = "invalid_json"
        case invalidState = "invalid_state"
        case invalidUTF8 = "invalid_utf8"
        case readFailed = "read_failed"
        case requestTooLarge = "request_too_large"
        case timeout
    }

    private struct SocketFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private func removeStaleSocketIfPresent() throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw ServerError.bind
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw ServerError.pathOccupied
        }
        guard unlink(path) == 0 else { throw ServerError.bind }
    }

    private func removeOwnedSocket() {
        guard let socketIdentity,
              Self.fileIdentity(at: path) == socketIdentity else {
            self.socketIdentity = nil
            return
        }
        unlink(path)
        self.socketIdentity = nil
    }

    private static func fileIdentity(at path: String) -> SocketFileIdentity? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return SocketFileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}
