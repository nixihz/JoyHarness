import Foundation
import Security

enum RemoteMicrophoneInstallation {
    static var updateRequired: Bool {
        guard let bundledDriver = Bundle.main.builtInPlugInsURL?.appendingPathComponent("JoyHarnessMicrophone.driver") else {
            return false
        }
        let installedDriver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/JoyHarnessMicrophone.driver")
        guard let bundledVersion = Bundle(url: bundledDriver)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let installedVersion = Bundle(url: installedDriver)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return false
        }
        return bundledVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    static func install() async throws {
        guard let driver = Bundle.main.builtInPlugInsURL?.appendingPathComponent("JoyHarnessMicrophone.driver"),
              FileManager.default.fileExists(atPath: driver.path) else {
            throw failure(L10n.text("当前应用缺少麦克风组件，请重新安装 Joy Harness。", "The microphone component is missing. Reinstall Joy Harness."))
        }
        // Pin the staged copy to the exact signed code selected before authorization.
        let hash = try codeHash(at: driver)
        let script = authorizationScript(command: installationCommand(driver: driver, codeHash: hash))
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

    static func codeHash(at driver: URL) throws -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(driver as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw signatureFailure(status) }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else { throw signatureFailure(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == "tech.keli.joyharness.microphone",
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
