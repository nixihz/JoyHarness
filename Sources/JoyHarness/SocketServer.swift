import Foundation

final class SocketServer {
    private let path: String
    private var fd: Int32 = -1
    private let onCommand: (PadCommand) -> Void
    private var source: DispatchSourceRead?

    init(path: String, onCommand: @escaping (PadCommand) -> Void) {
        self.path = path
        self.onCommand = onCommand
    }

    func start() throws {
        unlink(path)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let bytes = path.utf8.map { CChar(bitPattern: $0) }
        guard bytes.count <= maxLen else { throw ServerError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            for (i, b) in bytes.enumerated() {
                ptr.advanced(by: i).pointee = b
            }
        }

        let len = socklen_t(
            MemoryLayout<sockaddr_un>.size
        )
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, len)
            }
        }
        guard bindResult == 0 else { throw ServerError.bind }
        guard listen(fd, 8) == 0 else { throw ServerError.listen }
        chmod(path, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        src.resume()
        source = src
        print("[agent-deck] listening on \(path)")
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handle(client: client)
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 64_000 { break }
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            if let data = raw.data(using: .utf8),
               let cmd = try? JSONDecoder().decode(PadCommand.self, from: data) {
                DispatchQueue.main.async { self.onCommand(cmd) }
                continue
            }
            if let state = PadState.parse(raw) {
                DispatchQueue.main.async {
                    self.onCommand(PadCommand(
                        state: state.rawValue,
                        action: nil,
                        note: nil
                    ))
                }
            }
        }
        _ = "ok\n".withCString { write(client, $0, 3) }
    }

    enum ServerError: Error {
        case socket, bind, listen, pathTooLong
    }
}
