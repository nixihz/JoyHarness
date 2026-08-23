import Foundation

struct CodexThreadSummary: Equatable {
    let id: String
    let title: String
    let status: String
}

@MainActor
final class CodexThreadProvider {
    var onUpdate: (([CodexThreadSummary]) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var outputBuffer = Data()
    private var refreshTimer: Timer?
    private var initialized = false
    private var refreshPending = false
    private var nextRequestID = 2

    func start() {
        guard process == nil else { return }
        launch()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard initialized, !refreshPending else { return }
        refreshPending = true
        let requestID = nextRequestID
        nextRequestID += 1
        send([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "limit": 6,
                "archived": false,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
            ],
        ])
    }

    nonisolated static func decodeThreads(from response: Data) -> [CodexThreadSummary]? {
        guard let message = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = message["result"] as? [String: Any],
              let data = result["data"] as? [[String: Any]]
        else { return nil }

        return data.compactMap { thread in
            guard let id = thread["id"] as? String, !id.isEmpty else { return nil }
            let name = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (thread["preview"] as? String)?
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [name, preview]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty }) ?? "未命名任务"
            let status = (thread["status"] as? [String: Any])?["type"] as? String ?? "notLoaded"
            return CodexThreadSummary(id: id, title: title, status: status)
        }
    }

    private func launch() {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let executable = codexExecutable()

        process.executableURL = executable.url
        process.arguments = executable.arguments + ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.stdin = nil
                self?.initialized = false
                self?.refreshPending = false
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }

        do {
            try process.run()
            self.process = process
            stdin = input.fileHandleForWriting
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "joy-harness",
                        "title": "Joy Harness",
                        "version": "0.1.0",
                    ],
                ],
            ])
        } catch {
            print("[agent-deck] unable to start Codex task metadata client: \(error)")
        }
    }

    private func codexExecutable() -> (url: URL, arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["CODEX_BIN"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ].compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (URL(fileURLWithPath: path), [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["codex"])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let newline = "\n".data(using: .utf8)
        else { return }
        try? stdin?.write(contentsOf: data + newline)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            consumeLine(Data(line))
        }
    }

    private func consumeLine(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = message["id"] as? Int
        else { return }
        if id == 1 {
            initialized = message["result"] != nil
            if initialized {
                send(["method": "initialized", "params": [:]])
                refresh()
            }
            return
        }
        refreshPending = false
        if let threads = Self.decodeThreads(from: data) {
            onUpdate?(threads)
        }
    }
}
