import Foundation

struct CodexThreadSummary: Equatable {
    let id: String
    let title: String
    let status: String
}

@MainActor
final class CodexThreadProvider {
    var onUpdate: (([CodexThreadSummary]) -> Void)?
    var onHealthChange: ((CodexProviderHealth) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var outputBuffer = Data()
    private var refreshTimer: Timer?
    private var requestDeadlineTimer: DispatchSourceTimer?
    private var restartTimer: DispatchSourceTimer?
    private var nextRequestID = 2
    private let requestTimeout: TimeInterval
    private var recovery = CodexThreadRecoveryStateMachine()
    private var diagnosticBuffer: CodexDiagnosticBuffer

    private(set) var health: CodexProviderHealth = .stopped
    var stderrDiagnostics: String { diagnosticBuffer.text }

    init(requestTimeout: TimeInterval = 3, diagnosticCapacity: Int = 16_384) {
        self.requestTimeout = max(0.01, requestTimeout)
        self.diagnosticBuffer = CodexDiagnosticBuffer(capacity: diagnosticCapacity)
    }

    func start() {
        guard health == .stopped else { return }
        recovery.start()
        publishHealth()
        launch()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        guard health != .stopped else { return }
        recovery.stop()
        publishHealth()
        refreshTimer?.invalidate()
        refreshTimer = nil
        requestDeadlineTimer?.cancel()
        requestDeadlineTimer = nil
        restartTimer?.cancel()
        restartTimer = nil
        cleanupProcess(terminate: true)
        outputBuffer.removeAll(keepingCapacity: true)
    }

    func refresh() {
        guard health == .healthy, recovery.pendingRequest == nil else { return }
        let requestID = nextRequestID
        nextRequestID += 1
        sendRequest([
            "id": requestID,
            "method": "thread/list",
            "params": [
                "limit": 6,
                "archived": false,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "useStateDbOnly": true,
            ],
        ], id: requestID, kind: .threadList)
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
                .first(where: { !$0.isEmpty }) ?? L10n.text("未命名任务", "Untitled Task")
            let status = (thread["status"] as? [String: Any])?["type"] as? String ?? "notLoaded"
            return CodexThreadSummary(id: id, title: title, status: status)
        }
    }

    private func launch() {
        guard health != .stopped else { return }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        let executable = codexExecutable()

        process.executableURL = executable.url
        process.arguments = executable.arguments + ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            Task { @MainActor in
                guard let self,
                      let process,
                      self.process === process,
                      self.health != .stopped else { return }
                self.handleFailure(
                    .exit,
                    reason: "app-server exited with status \(terminatedProcess.terminationStatus)"
                )
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.appendDiagnostic(data) }
        }

        do {
            try process.run()
            self.process = process
            stdin = input.fileHandleForWriting
            stdout = output.fileHandleForReading
            stderr = errorOutput.fileHandleForReading
            sendRequest([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "joy-harness",
                        "title": "Joy Harness",
                        "version": AppVersion.current,
                    ],
                ],
            ], id: 1, kind: .initialization)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            close(input.fileHandleForWriting, named: "stdin")
            close(output.fileHandleForReading, named: "stdout")
            close(errorOutput.fileHandleForReading, named: "stderr")
            appendDiagnostic("unable to start Codex task metadata client: \(error)\n")
            scheduleRecovery(after: recovery.handleProcessFailure(.launch))
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

    private func sendRequest(_ message: [String: Any], id: Int, kind: CodexRequestKind) {
        recovery.beginRequest(
            id: id,
            kind: kind,
            deadline: Date().addingTimeInterval(requestTimeout)
        )
        do {
            try write(message)
            armRequestDeadline()
        } catch {
            appendDiagnostic("app-server write failed: \(error)\n")
            handleFailure(.write, reason: "app-server write failed")
        }
    }

    private func sendNotification(_ message: [String: Any]) -> Bool {
        do {
            try write(message)
            return true
        } catch {
            appendDiagnostic("app-server write failed: \(error)\n")
            handleFailure(.write, reason: "app-server write failed")
            return false
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let stdin else { throw ProviderError.stdinUnavailable }
        let data = try JSONSerialization.data(withJSONObject: message)
        try stdin.write(contentsOf: data + Data("\n".utf8))
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

        let succeeded = message["result"] != nil && message["error"] == nil
        guard let kind = recovery.receiveResponse(id: id, succeeded: succeeded) else { return }
        requestDeadlineTimer?.cancel()
        requestDeadlineTimer = nil
        publishHealth()

        guard succeeded else {
            appendDiagnostic("app-server request \(id) failed\n")
            handleRequestFailure("app-server request failed")
            return
        }

        switch kind {
        case .initialization:
            guard sendNotification(["method": "initialized", "params": [:]]) else { return }
            refresh()
        case .threadList:
            if let threads = Self.decodeThreads(from: data) {
                onUpdate?(threads)
            }
        }
    }

    private func armRequestDeadline() {
        requestDeadlineTimer?.cancel()
        guard let pendingRequest = recovery.pendingRequest else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, pendingRequest.deadline.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.requestTimedOut() }
        }
        requestDeadlineTimer = timer
        timer.resume()
    }

    private func requestTimedOut() {
        requestDeadlineTimer?.cancel()
        requestDeadlineTimer = nil
        guard let delay = recovery.handleTimeout(at: Date()) else {
            armRequestDeadline()
            return
        }
        appendDiagnostic("app-server request timed out\n")
        cleanupProcess(terminate: true)
        publishHealth()
        scheduleRestart(after: delay)
    }

    private func handleFailure(_ failure: CodexProcessFailure, reason: String) {
        guard health != .stopped else { return }
        appendDiagnostic("\(reason)\n")
        cleanupProcess(terminate: true)
        scheduleRecovery(after: recovery.handleProcessFailure(failure))
    }

    private func handleRequestFailure(_ reason: String) {
        guard health != .stopped else { return }
        appendDiagnostic("\(reason)\n")
        cleanupProcess(terminate: true)
        scheduleRecovery(after: recovery.fail())
    }

    private func scheduleRecovery(after delay: TimeInterval?) {
        publishHealth()
        guard let delay else { return }
        scheduleRestart(after: delay)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.recovery.beginRestart() else { return }
                self.restartTimer?.cancel()
                self.restartTimer = nil
                self.publishHealth()
                self.launch()
            }
        }
        restartTimer = timer
        timer.resume()
    }

    private func cleanupProcess(terminate: Bool) {
        let process = self.process
        self.process = nil
        requestDeadlineTimer?.cancel()
        requestDeadlineTimer = nil
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        close(stdin, named: "stdin")
        close(stdout, named: "stdout")
        close(stderr, named: "stderr")
        stdin = nil
        stdout = nil
        stderr = nil
        outputBuffer.removeAll(keepingCapacity: true)
        if terminate, process?.isRunning == true {
            process?.terminate()
        }
    }

    private func close(_ handle: FileHandle?, named name: String) {
        guard let handle else { return }
        do {
            try handle.close()
        } catch {
            appendDiagnostic("unable to close app-server \(name): \(error)\n")
        }
    }

    private func appendDiagnostic(_ data: Data) {
        diagnosticBuffer.append(data)
    }

    private func appendDiagnostic(_ message: String) {
        diagnosticBuffer.append(Data(message.utf8))
        fputs("[agent-deck] \(message)", Foundation.stderr)
    }

    private func publishHealth() {
        let updatedHealth = recovery.health
        guard health != updatedHealth else { return }
        health = updatedHealth
        onHealthChange?(updatedHealth)
    }

    private enum ProviderError: Error {
        case stdinUnavailable
    }
}
