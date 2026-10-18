import CoreAudio
import Foundation

/// Manages the validated driver in place: keep its UID and launchd identity so
/// existing audio-app selections survive migration from the standalone build.
enum DualSenseAudioInstallation {
    static let uid = "com.psgrok.DualSenseAudio.Microphone"
    static let label = "com.psgrok.DualSenseAudio.helper"
    static let helperIdentifier = "tech.keli.joyharness.dualsense-helper"
    static let driverIdentifier = "com.psgrok.DualSenseAudio"
    static let support = "/Library/Application Support/DualSenseAudio"
    static let hal = "/Library/Audio/Plug-Ins/HAL"
    static var driver: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/DualSenseAudio.driver") }
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/ds5audiod") }
    static var remote: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/JoyHarnessMicrophone.driver") }
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "\(support)/ds5audiod") ||
        FileManager.default.fileExists(atPath: "\(hal)/DualSenseAudio.driver") ||
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
    }
    static var prerequisiteIssue: String? {
        #if !arch(arm64)
        return L10n.text("手柄无线麦克风目前需要 Apple 芯片 Mac。", "Wireless controller audio currently requires Apple silicon.")
        #else
        guard #available(macOS 26, *) else {
            return L10n.text("手柄无线麦克风目前需要 macOS 26 或更新版本。", "Wireless controller audio currently requires macOS 26 or later.")
        }
        guard FileManager.default.isExecutableFile(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl") else {
            return L10n.text("请先在“应用程序”中安装 Xcode；麦克风需要其中的 Game Mode 工具。", "Install Xcode in Applications first; the microphone requires its Game Mode tool.")
        }
        guard FileManager.default.fileExists(atPath: driver.path), FileManager.default.isExecutableFile(atPath: helper.path) else {
            return L10n.text("当前应用缺少手柄麦克风组件，请重新安装 Joy Harness。", "Controller audio components are missing. Reinstall Joy Harness.")
        }
        return nil
        #endif
    }
    static var needsUpdate: Bool {
        guard installed else { return false }
        let pairs = [(driver, URL(fileURLWithPath: "\(hal)/DualSenseAudio.driver"), driverIdentifier),
                     (helper, URL(fileURLWithPath: "\(support)/ds5audiod"), helperIdentifier)]
        for (source, target, identifier) in pairs {
            guard let a = try? RemoteMicrophoneInstallation.codeHash(at: source, identifier: identifier),
                  let b = try? RemoteMicrophoneInstallation.codeHash(at: target, identifier: identifier), a == b else { return true }
        }
        return RemoteMicrophoneInstallation.updateRequired
    }
    static func deviceID(uid: String = uid) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let wanted = uid as CFString
        var reference = Unmanaged.passUnretained(wanted)
        var result = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(wanted) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout.size(ofValue: reference)), &reference, &size, &result)
        }
        return status == noErr && result != 0 ? result : nil
    }
    static var selected: Bool {
        guard let id = deviceID() else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &current) == noErr && current == id
    }
    static func selectInput() throws {
        guard var id = deviceID() else { throw failure(L10n.text("麦克风尚未就绪，请等待音频服务恢复后重试。", "The microphone is not ready. Wait for audio services to recover.")) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr, selected else {
            throw failure(L10n.text("切换输入失败，请在系统声音设置中选择 DualSense Microphone。", "Select DualSense Microphone in System Sound settings."))
        }
    }
    static func install() async throws {
        if let issue = prerequisiteIssue { throw failure(issue) }
        let driverHash = try RemoteMicrophoneInstallation.codeHash(at: driver, identifier: driverIdentifier)
        let helperHash = try RemoteMicrophoneInstallation.codeHash(at: helper, identifier: helperIdentifier)
        let remoteHash = try RemoteMicrophoneInstallation.codeHash(at: remote)
        try await RemoteMicrophoneInstallation.authorize(command: command(
            driver: driver.path, helper: helper.path, remote: remote.path,
            driverHash: driverHash, helperHash: helperHash, remoteHash: remoteHash))
        guard installed, !needsUpdate else { throw failure(L10n.text("文件已更新，但组件核对未通过，请重试。", "Component verification failed after installation. Try again.")) }
    }
    static func uninstall() async throws {
        try await RemoteMicrophoneInstallation.authorize(command: command())
        guard !installed else { throw failure(L10n.text("卸载未完成，请重试。", "Uninstall did not finish. Try again.")) }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "DualSenseAudioInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Pure command construction permits failure-injection tests in an isolated
    /// filesystem. Never executes a script from the user-writable app as root.
    static func command(driver: String? = nil, helper: String = "", remote: String = "",
                        driverHash: String = "", helperHash: String = "", remoteHash: String = "") -> String {
        let quote = RemoteMicrophoneInstallation.shellQuote
        let targets = ["\(hal)/DualSenseAudio.driver", "\(support)/ds5audiod",
                       "/Library/LaunchDaemons/\(label).plist", "\(hal)/JoyHarnessMicrophone.driver"]
        var setup = ""
        if let driver {
            for (index, source, hash) in [(0, driver, driverHash), (1, helper, helperHash), (3, remote, remoteHash)] {
                setup += """
                /usr/bin/ditto \(quote(source)) "$stage/new\(index)"
                /usr/bin/codesign --verify --strict -R \(quote("=cdhash H\"" + hash + "\"")) "$stage/new\(index)"
                /usr/sbin/chown -R root:wheel "$stage/new\(index)"
                /bin/chmod -R u+rwX,go+rX,go-w "$stage/new\(index)"

                """
            }
            setup += """
            /bin/cat > "$stage/new2" <<'JH_PLIST'
            \(launchDaemonPlist)
            JH_PLIST
            /bin/chmod 644 "$stage/new2"

            """
        }
        var rollback = "", replace = ""
        for (index, target) in targets.enumerated() {
            // Upgrade the remote component only if it already exists. It drops
            // the obsolete DualSense UID while preserving Xiaomi's UID/stream.
            if index == 3 && driver == nil { continue }
            rollback += """
            if [ "$changed\(index)" = 1 ]; then
                /bin/rm -rf \(quote(target))
                if [ -e "$stage/old\(index)" ]; then /bin/mv "$stage/old\(index)" \(quote(target)); fi
            fi

            """
            if index == 3 { replace += "if [ -e \(quote(target)) ]; then\n" }
            replace += """
            if [ -e \(quote(target)) ] || [ -L \(quote(target)) ]; then /bin/mv \(quote(target)) "$stage/old\(index)"; fi
            changed\(index)=1

            """
            if driver != nil { replace += "/bin/mv \"$stage/new\(index)\" \(quote(target))\n" }
            if index == 3 { replace += "fi\n" }
        }
        return """
        set -eu
        /bin/mkdir -p \(quote(hal)) \(quote(support))
        stage=$(/usr/bin/mktemp -d '/Library/Application Support/.JoyHarnessAudio.XXXXXX')
        /bin/chmod 700 "$stage"
        changed0=0; changed1=0; changed2=0; changed3=0
        stopped=0; was_running=0; committed=0
        if /bin/launchctl print system/\(label) >/dev/null 2>&1; then was_running=1; fi
        cleanup() {
            result=$?
            trap - EXIT
            if [ "$committed" = 0 ]; then
                if [ "$stopped" = 1 ]; then /bin/launchctl bootout system/\(label) 2>/dev/null || true; fi
                \(rollback)
                if [ "$stopped" = 1 ] && [ "$was_running" = 1 ]; then
                    /bin/launchctl bootstrap system /Library/LaunchDaemons/\(label).plist || true
                fi
            fi
            /bin/rm -rf "$stage"
            exit "$result"
        }
        trap cleanup EXIT
        \(setup)
        if [ "$was_running" = 1 ]; then
            /bin/launchctl bootout system/\(label)
            stopped=1
            count=0
            while /bin/launchctl print system/\(label) >/dev/null 2>&1; do
                count=$((count + 1))
                if [ "$count" -ge 150 ]; then echo 'Audio helper did not stop; no files replaced.' >&2; exit 1; fi
                /bin/sleep 0.2
            done
        fi
        if [ -e \(quote(support + "/game-mode-lease")) ]; then
            echo 'Game Mode restoration is pending. Keep the helper installed and retry.' >&2; exit 1
        fi
        stopped=1
        \(replace)
        \(driver != nil ? "/bin/launchctl enable system/" + label + "\n/bin/launchctl bootstrap system /Library/LaunchDaemons/" + label + ".plist\n/bin/launchctl print system/" + label + " >/dev/null" : "")
        if /usr/bin/pgrep -x coreaudiod >/dev/null; then /usr/bin/killall -TERM coreaudiod; fi
        committed=1
        """
    }
    static let launchDaemonPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>com.psgrok.DualSenseAudio.helper</string>
    <key>ProgramArguments</key><array><string>/Library/Application Support/DualSenseAudio/ds5audiod</string></array>
    <key>MachServices</key><dict><key>com.psgrok.DualSenseAudio.helper</key><true/><key>tech.keli.joyharness.dualsense.controls</key><true/></dict>
    <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    </dict></plist>
    """
}
