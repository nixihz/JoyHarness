import Foundation
import Security

enum RemoteMicrophoneInstallation {
    static var updateRequired: Bool {
        guard let bundledDriver = Bundle.main.builtInPlugInsURL?.appendingPathComponent("JoyHarnessMicrophone.driver") else {
            return false
        }
        let installedDriver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/JoyHarnessMicrophone.driver")
        return updateRequired(bundledDriver: bundledDriver, installedDriver: installedDriver)
    }

    static func updateRequired(bundledDriver: URL, installedDriver: URL) -> Bool {
        // CFBundle may cache identical identifiers from different locations.
        // Read metadata directly so the bundled v4 and installed v3 coexist.
        func version(_ driver: URL) -> String? {
            guard let data = try? Data(contentsOf: driver.appendingPathComponent("Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return plist["CFBundleVersion"] as? String
        }
        guard let bundledVersion = version(bundledDriver) else { return false }
        guard FileManager.default.fileExists(atPath: installedDriver.path) else { return false }
        guard let installedVersion = version(installedDriver) else { return true }
        return bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    static func install() async throws {
        guard let driver = Bundle.main.builtInPlugInsURL?.appendingPathComponent("JoyHarnessMicrophone.driver"),
              FileManager.default.fileExists(atPath: driver.path) else {
            throw failure(L10n.text("当前应用缺少麦克风组件，请重新安装 Joy Harness。", "The microphone component is missing. Reinstall Joy Harness."))
        }
        // Pin the staged copy to the exact signed code selected before authorization.
        let hash = try codeHash(at: driver)
        try await authorize(command: installationCommand(driver: driver, codeHash: hash))
    }

    @MainActor private static var isAuthorizing = false

    @MainActor static func authorize(command: String) async throws {
        guard !isAuthorizing else { throw failure(L10n.text("另一项组件操作尚未完成，请稍后重试。", "Another component operation is still running. Try again later.")) }
        isAuthorizing = true
        defer { isAuthorizing = false }
        let script = authorizationScript(command: command)
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardError = output
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.contains("(-128)") { throw CancellationError() }
                throw failure(detail)
            }
        }.value
    }

    static func codeHash(at driver: URL, identifier: String = "tech.keli.joyharness.microphone") throws -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(driver as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw signatureFailure(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else { throw signatureFailure(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == identifier,
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw signatureFailure(status)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func installationCommand(driver: URL, codeHash: String) -> String {
        // Everything runs from fixed system executables, never a script from the writable app.
        // Stage and verify before replacing the existing driver; retain it if replacement fails.
        """
        set -eu
        /bin/mkdir -p /Library/Audio/Plug-Ins/HAL
        stage=$(/usr/bin/mktemp -d /Library/Audio/Plug-Ins/HAL/.JoyHarnessMicrophone.XXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        /usr/bin/ditto \(shellQuote(driver.path)) "$stage/JoyHarnessMicrophone.driver"
        /usr/bin/codesign --verify --strict -R \(shellQuote("=cdhash H\"" + codeHash + "\"")) "$stage/JoyHarnessMicrophone.driver"
        /usr/sbin/chown -R root:wheel "$stage/JoyHarnessMicrophone.driver"
        /bin/chmod -R u+rwX,go+rX,go-w "$stage/JoyHarnessMicrophone.driver"
        target=/Library/Audio/Plug-Ins/HAL/JoyHarnessMicrophone.driver
        if [ -e "$target" ] || [ -L "$target" ]; then
            /bin/mv "$target" "$stage/previous.driver"
        fi
        if ! /bin/mv "$stage/JoyHarnessMicrophone.driver" "$target"; then
            if [ -e "$stage/previous.driver" ] || [ -L "$stage/previous.driver" ]; then
                /bin/mv "$stage/previous.driver" "$target" || { trap - EXIT; exit 1; }
            fi
            exit 1
        fi
        if /usr/bin/pgrep -x coreaudiod >/dev/null; then
            /usr/bin/killall -TERM coreaudiod
        fi
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func authorizationScript(command: String) -> String {
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(literal)\" with administrator privileges"
    }

    private static func signatureFailure(_ status: OSStatus) -> NSError {
        failure(L10n.text("麦克风组件签名校验失败，请重新安装 Joy Harness。", "Microphone signature verification failed. Reinstall Joy Harness.") + " (\(status))")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RemoteMicrophoneInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
