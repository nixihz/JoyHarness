import Foundation
import Testing
@testable import JoyHarness

struct RemoteMicrophoneInstallationTests {
    private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func authorizationPreservesShellMetacharactersInPaths() throws {
        let value = "Joy Harness's \"driver\" $(exit 87) `exit 88` \\ folder\nnext line"
        let command = "/usr/bin/printf '%s' " + RemoteMicrophoneInstallation.shellQuote(value)
        // Execute the same AppleScript escaping without prompting for administrator access.
        let script = RemoteMicrophoneInstallation.authorizationScript(command: command)
            .replacingOccurrences(of: " with administrator privileges", with: "")
        let (status, output) = try run("/usr/bin/osascript", ["-e", script])
        #expect(status == 0, "\(output)")
        // do shell script normalizes LF to CR; osascript appends its own final newline.
        #expect(output.replacingOccurrences(of: "\r", with: "\n") == value + "\n")
    }

    @Test func installationReplacesDriverOnlyAfterSignatureValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source's component")
        let destination = root.appendingPathComponent("HAL")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["JOY_HARNESS_SIGNING_IDENTITY"] = "-"
        let (buildStatus, buildOutput) = try run("/bin/bash", [
            repository.appendingPathComponent("scripts/build_microphone_driver.sh").path,
            source.path, "distribution"
        ], environment: environment)
        #expect(buildStatus == 0, "\(buildOutput)")
        let driver = source.appendingPathComponent("JoyHarnessMicrophone.driver")
        let hash = try RemoteMicrophoneInstallation.codeHash(at: driver)
        let command = RemoteMicrophoneInstallation.installationCommand(driver: driver, codeHash: hash)
            .replacingOccurrences(of: "/Library/Audio/Plug-Ins/HAL", with: destination.path)
            .replacingOccurrences(of: "/usr/sbin/chown -R root:wheel", with: "/usr/bin/true")
            .replacingOccurrences(of: "/usr/bin/pgrep -x coreaudiod", with: "/usr/bin/false")
        let (status, output) = try run("/bin/sh", ["-c", command])
        #expect(status == 0, "\(output)")
        let installed = destination.appendingPathComponent("JoyHarnessMicrophone.driver")
        #expect(try RemoteMicrophoneInstallation.codeHash(at: installed) == hash)
        // Reinstallation exercises replacement of an existing working copy.
        let (replacementStatus, replacementOutput) = try run("/bin/sh", ["-c", command])
        #expect(replacementStatus == 0, "\(replacementOutput)")
        let binary = driver.appendingPathComponent("Contents/MacOS/JoyHarnessMicrophone")
        try Data("corrupt executable".utf8).write(to: binary)
        #expect(throws: (any Error).self) { try RemoteMicrophoneInstallation.codeHash(at: driver) }
        let (rejectedStatus, _) = try run("/bin/sh", ["-c", command])
        #expect(rejectedStatus != 0)
        #expect(try RemoteMicrophoneInstallation.codeHash(at: installed) == hash)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["JoyHarnessMicrophone.driver"])
    }
}
