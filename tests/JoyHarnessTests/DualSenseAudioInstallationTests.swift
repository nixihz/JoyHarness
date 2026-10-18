import Foundation
import Testing
@testable import JoyHarness

/// Execute the real transaction in a temporary filesystem; only privileged
/// system commands are replaced. Assertions concern user-visible artifacts.
struct DualSenseAudioInstallationTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var running: URL { root.appendingPathComponent("running") }
        var daemon: URL { root.appendingPathComponent("Library/Application Support/DualSenseAudio/ds5audiod") }
        var hal: URL { root.appendingPathComponent("Library/Audio/Plug-Ins/HAL") }
        var plist: URL { root.appendingPathComponent("Library/LaunchDaemons/com.psgrok.DualSenseAudio.helper.plist") }
        var source: URL { root.appendingPathComponent("source ' quoted") }
        init() throws {
            for path in [daemon.deletingLastPathComponent(), hal, plist.deletingLastPathComponent(), source] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
            try write("new-driver", to: source.appendingPathComponent("driver"))
            try write("new-helper", to: source.appendingPathComponent("helper"))
            try write("xiaomi-only", to: source.appendingPathComponent("remote"))
            try write("old-driver", to: hal.appendingPathComponent("DualSenseAudio.driver"))
            try write("old-helper", to: daemon)
            try write("old-plist", to: plist)
            try write("old-xiaomi-plus-dualsense", to: hal.appendingPathComponent("JoyHarnessMicrophone.driver"))
            try write("yes", to: running)
            let q = RemoteMicrophoneInstallation.shellQuote(root.path)
            try script("""
            case "$1" in
              print) test -f \(q)/running ;;
              bootout) rm -f \(q)/running ;;
              enable) exit 0 ;;
              bootstrap)
                if [ -f \(q)/fail-bootstrap ]; then rm \(q)/fail-bootstrap; exit 1; fi
                touch \(q)/running ;;
              *) exit 2 ;;
            esac
            """, named: "launchctl")
            try script("test ! -f \(q)/fail-signature", named: "codesign")
            try script("exit 0", named: "chown")
            try script("exit 1", named: "pgrep") // no real audio daemon touched
            try script("exit 0", named: "killall")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func write(_ value: String, to url: URL) throws { try value.write(to: url, atomically: true, encoding: .utf8) }
        func read(_ url: URL) throws -> String { try String(contentsOf: url) }
        func script(_ text: String, named name: String) throws {
            let url = root.appendingPathComponent(name)
            try write("#!/bin/sh\n" + text + "\n", to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        func run(install: Bool = true) throws -> Int32 {
            var command = install ? DualSenseAudioInstallation.command(driver: source.appendingPathComponent("driver").path,
                helper: source.appendingPathComponent("helper").path, remote: source.appendingPathComponent("remote").path,
                driverHash: "123", helperHash: "456", remoteHash: "789") : DualSenseAudioInstallation.command()
            command = command.replacingOccurrences(of: "/Library/", with: root.path + "/Library/")
            for tool in ["/bin/launchctl", "/usr/bin/codesign", "/usr/sbin/chown", "/usr/bin/pgrep", "/usr/bin/killall"] {
                command = command.replacingOccurrences(of: tool, with: RemoteMicrophoneInstallation.shellQuote(root.appendingPathComponent(URL(fileURLWithPath: tool).lastPathComponent).path))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
    }

    @Test func installedAndBundledRemoteVersionsAreComparedDespiteIdenticalBundleIDs() throws {
        let f = try Fixture()
        let bundled = f.root.appendingPathComponent("bundled.driver")
        let installed = f.root.appendingPathComponent("installed.driver")
        for (url, version) in [(bundled, "4"), (installed, "3")] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "tech.keli.joyharness.microphone", "CFBundleVersion": version], format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        #expect(RemoteMicrophoneInstallation.updateRequired(bundledDriver: bundled, installedDriver: installed))
        #expect(!RemoteMicrophoneInstallation.updateRequired(bundledDriver: installed, installedDriver: bundled))
    }

    @Test func migratesInPlaceAndUninstallKeepsXiaomi() throws {
        let f = try Fixture()
        #expect(try f.run() == 0)
        #expect(try f.read(f.daemon) == "new-helper")
        #expect(try f.read(f.hal.appendingPathComponent("DualSenseAudio.driver")) == "new-driver")
        #expect(try f.read(f.hal.appendingPathComponent("JoyHarnessMicrophone.driver")) == "xiaomi-only")
        #expect(FileManager.default.fileExists(atPath: f.running.path))
        #expect(try f.run(install: false) == 0)
        #expect(!FileManager.default.fileExists(atPath: f.daemon.path))
        #expect(!FileManager.default.fileExists(atPath: f.plist.path))
        #expect(!FileManager.default.fileExists(atPath: f.hal.appendingPathComponent("DualSenseAudio.driver").path))
        #expect(try f.read(f.hal.appendingPathComponent("JoyHarnessMicrophone.driver")) == "xiaomi-only")
        #expect(!FileManager.default.fileExists(atPath: f.running.path))
    }
    @Test func failedSignatureDoesNotStopOrReplaceInstalledComponents() throws {
        let f = try Fixture()
        try f.write("fail", to: f.root.appendingPathComponent("fail-signature"))
        #expect(try f.run() != 0)
        #expect(try f.read(f.daemon) == "old-helper")
        #expect(try f.read(f.plist) == "old-plist")
        #expect(FileManager.default.fileExists(atPath: f.running.path))
    }
    @Test func failedServiceStartRollsBackAllComponentsAndRestartsOldService() throws {
        let f = try Fixture()
        try f.write("fail", to: f.root.appendingPathComponent("fail-bootstrap"))
        #expect(try f.run() != 0)
        #expect(try f.read(f.daemon) == "old-helper")
        #expect(try f.read(f.plist) == "old-plist")
        #expect(try f.read(f.hal.appendingPathComponent("DualSenseAudio.driver")) == "old-driver")
        #expect(try f.read(f.hal.appendingPathComponent("JoyHarnessMicrophone.driver")) == "old-xiaomi-plus-dualsense")
        #expect(FileManager.default.fileExists(atPath: f.running.path))
    }
    @Test func unresolvedGameModeLeasePreventsRemoval() throws {
        let f = try Fixture()
        try f.write("1", to: f.daemon.deletingLastPathComponent().appendingPathComponent("game-mode-lease"))
        #expect(try f.run(install: false) != 0)
        #expect(try f.read(f.daemon) == "old-helper")
        #expect(FileManager.default.fileExists(atPath: f.running.path))
    }
}
