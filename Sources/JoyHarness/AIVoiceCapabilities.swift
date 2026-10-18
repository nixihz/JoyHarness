import AppKit
import ApplicationServices

/// Model output is data: only registered identifiers and validated parameters
/// can reach an executor. Neither paths, URLs nor code are accepted as actions.
struct AIVoiceCommand: Codable, Equatable, Sendable {
    let capabilityID: String
    let parameters: [String: String]
}

struct AIVoiceCapabilityChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let command: AIVoiceCommand
}

enum AIVoiceCapabilityResolution: Equatable, Sendable {
    case ready(AIVoiceCommand, summary: String)
    case needsChoice(prompt: String, choices: [AIVoiceCapabilityChoice])
    case unavailable(String)
}

struct AIVoiceExecutionResult: Equatable, Sendable {
    enum Status: String, Sendable {
        case succeeded, failed, unconfirmed, cancelled
    }

    let status: Status
    let message: String
}

struct AIVoiceInstalledApplication: Equatable, Sendable {
    let bundleID: String
    let name: String
    let aliases: [String]
    let url: URL
}

struct AIVoiceWeTypeInstallation: Equatable, Sendable {
    let applicationVersion: String
    let settingsVersion: String?
    let settingsURL: URL?
}

@MainActor
protocol AIVoiceCapabilityEnvironment {
    func installedApplications() -> [AIVoiceInstalledApplication]
    func weTypeInstallation() -> AIVoiceWeTypeInstallation?
    func openApplication(at url: URL) async throws -> Int32
    func hasVisibleWindow(processID: Int32) -> Bool
    func openSystemSettings(_ page: AIVoiceSystemSettingsPage) -> Bool
    func hasVisibleSystemSettingsPage(_ page: AIVoiceSystemSettingsPage) -> Bool
    var canVerifySystemSettings: Bool { get }
}

@MainActor
final class AIVoiceCapabilityRegistry {
    nonisolated static let openApplicationID = "open_application"
    nonisolated static let openSystemSettingsID = "open_system_settings"
    nonisolated static let openWeTypeSettingsID = "open_wetype_settings"
    nonisolated static let allCapabilityIDs: Set<String> = Set([
        openApplicationID, openSystemSettingsID, openWeTypeSettingsID,
    ]).union(AIVoiceBuiltInCommands.ids)

    var enabledCapabilityIDs: Set<String>
    private let environment: any AIVoiceCapabilityEnvironment
    private let systemControls: any AIVoiceSystemControlling
    private let desktopActions: any AIVoiceDesktopActing
    private let systemAppearance: any AIVoiceSystemAppearanceControlling
    private let currentAppSettings: any AIVoiceCurrentAppSettingsOpening
    private let verificationTimeout: TimeInterval
    private let pollingNanoseconds: UInt64
    private struct Request {
        let command: AIVoiceCommand
        var result: AIVoiceExecutionResult?
    }
    private var requests: [UUID: Request] = [:]

    init(
        enabledCapabilityIDs: Set<String> = AIVoiceCapabilityRegistry.allCapabilityIDs,
        environment: (any AIVoiceCapabilityEnvironment)? = nil,
        systemControls: (any AIVoiceSystemControlling)? = nil,
        desktopActions: (any AIVoiceDesktopActing)? = nil,
        systemAppearance: (any AIVoiceSystemAppearanceControlling)? = nil,
        currentAppSettings: (any AIVoiceCurrentAppSettingsOpening)? = nil,
        verificationTimeout: TimeInterval = 4,
        pollingNanoseconds: UInt64 = 120_000_000
    ) {
        self.enabledCapabilityIDs = enabledCapabilityIDs
        self.environment = environment ?? AIVoiceMacCapabilityEnvironment()
        self.systemControls = systemControls ?? AIVoiceMacSystemControls()
        self.desktopActions = desktopActions ?? AIVoiceMacDesktopActions()
        self.systemAppearance = systemAppearance ?? AIVoiceMacSystemAppearance()
        self.currentAppSettings = currentAppSettings ?? AIVoiceMacCurrentAppSettings()
        self.verificationTimeout = verificationTimeout
        self.pollingNanoseconds = pollingNanoseconds
    }

    var descriptors: [AIVoiceCapabilityDescriptor] {
        allDescriptors.filter { enabledCapabilityIDs.contains($0.id) }
    }

    func captureCurrentApplication() -> AIVoiceForegroundApplication? {
        currentAppSettings.captureTarget()
    }

    var allDescriptors: [AIVoiceCapabilityDescriptor] {
        [
            AIVoiceCapabilityDescriptor(
                id: Self.openApplicationID,
                summary: "打开已安装应用。application 必须是应用名称或 bundle ID；不支持网页、路径、下载或设置修改。",
                parameterNames: ["application"], examples: ["打开微信", "启动 Safari"]
            ),
            AIVoiceCapabilityDescriptor(
                id: Self.openSystemSettingsID,
                summary: "打开系统设置的指定页面。page 只能为：" + AIVoiceSystemSettingsPage.allCases.map { "\($0.rawValue)（\($0.title)）" }.joined(separator: "、") + "。仅打开页面，不开关Wi-Fi、蓝牙或修改隐私权限等设置。",
                parameterNames: ["page"], examples: ["打开蓝牙设置", "打开显示器设置", "打开软件更新"]
            ),
            AIVoiceCapabilityDescriptor(
                id: Self.openWeTypeSettingsID,
                summary: "打开微信输入法设置，当前适配 WeType 3.0.0。它不是微信聊天应用设置；只说微信设置时必须先澄清。没有参数。",
                parameterNames: [], examples: ["打开微信输入法设置", "打开 WeType 设置"]
            ),
        ] + AIVoiceBuiltInCommands.descriptors
    }

    func resolve(_ command: AIVoiceCommand) -> AIVoiceCapabilityResolution {
        guard Self.allCapabilityIDs.contains(command.capabilityID) else {
            return .unavailable("这项操作尚未登记，Joy Harness 没有执行它。")
        }
        guard enabledCapabilityIDs.contains(command.capabilityID) else {
            return .unavailable("这项能力已停用，请在 AI 语音设置中启用后重试。")
        }
        switch command.capabilityID {
        case Self.openApplicationID:
            guard Set(command.parameters.keys) == ["application"],
                  let name = command.parameters["application"], !name.isEmpty, name.count <= 256 else {
                return .unavailable("请指定要打开的应用名称。")
            }
            let candidates = applicationCandidates(named: name)
            guard !candidates.isEmpty else { return .unavailable("未找到已安装的应用“\(name)”。") }
            if candidates.count > 1 {
                return .needsChoice(prompt: "找到多个应用，请选择要打开的目标。", choices: candidates.map { app in
                    .init(id: app.bundleID, title: "\(app.name)（\(app.bundleID)）", command: applicationCommand(app.bundleID))
                })
            }
            return .ready(applicationCommand(candidates[0].bundleID), summary: "打开\(candidates[0].name)")

        case Self.openSystemSettingsID:
            guard Set(command.parameters.keys) == ["page"],
                  let value = command.parameters["page"],
                  let page = AIVoiceSystemSettingsPage(rawValue: value) else {
                return .unavailable("请指定已支持的系统设置页面，例如 Wi-Fi、蓝牙、声音、显示器或键盘。")
            }
            return .ready(command, summary: "打开\(page.title)设置")

        case Self.openWeTypeSettingsID:
            guard command.parameters.isEmpty else { return .unavailable("微信输入法设置不接受额外参数。") }
            guard let installation = environment.weTypeInstallation() else {
                return .unavailable("未找到微信输入法；没有打开微信聊天应用或系统输入法列表。")
            }
            guard installation.applicationVersion == "3.0.0",
                  installation.settingsVersion == "3.0.0", installation.settingsURL != nil else {
                return .unavailable("微信输入法 \(installation.applicationVersion) 的设置入口尚未验证；目前适配 3.0.0，未执行打开操作。")
            }
            return .ready(command, summary: "打开微信输入法设置")
        default:
            switch AIVoiceBuiltInCommands.resolve(command) {
            case .ready(_, let summary): return .ready(command, summary: summary)
            case .invalid(let reason): return .unavailable(reason)
            case .unknown: return .unavailable("这项操作尚未支持。")
            }
        }
    }

    /// Explicit local command matching, not an LLM. Unknown wording is never
    /// interpreted as a shell command or sent to a different app.
    func parseLocal(_ transcript: String) -> AIVoiceCapabilityResolution {
        let normalized = Self.normalize(transcript)
        let prefixes = ["请帮我打开", "帮我打开", "请打开", "打开", "启动", "pleaseopen", "launch", "open"]
        guard let prefix = prefixes.first(where: { normalized.hasPrefix($0) }) else {
            return .unavailable("本地指令支持“打开应用名称”或“打开设置名称”；更自由的表达需要配置 AI 服务。")
        }
        let target = String(normalized.dropFirst(prefix.count))
        if ["微信设置", "wechat设置", "wechatsettings"].contains(target) {
            let command = AIVoiceCommand(capabilityID: Self.openWeTypeSettingsID, parameters: [:])
            guard case .ready = resolve(command) else {
                return .unavailable("请明确是微信输入法设置还是微信聊天应用设置；后者尚未适配。")
            }
            return .needsChoice(
                prompt: "你是指微信输入法设置吗？微信聊天应用设置尚未适配。",
                choices: [.init(id: Self.openWeTypeSettingsID, title: "微信输入法设置", command: command)]
            )
        }
        if ["微信输入法设置", "wetype设置", "wetypesettings", "微信键盘设置"].contains(target) {
            return resolve(.init(capabilityID: Self.openWeTypeSettingsID, parameters: [:]))
        }
        if let page = AIVoiceSystemSettingsPage.allCases.first(where: {
            $0.aliases.map(Self.normalize).contains(target)
        }) {
            return resolve(.init(capabilityID: Self.openSystemSettingsID, parameters: ["page": page.rawValue]))
        }
        return resolve(.init(capabilityID: Self.openApplicationID, parameters: ["application": target]))
    }

    /// One release owns one request ID. Re-entry returns the recorded outcome;
    /// changing the command under the same ID cannot trigger another operation.
    func execute(_ command: AIVoiceCommand, requestID: UUID,
                 currentApplication: AIVoiceForegroundApplication? = nil) async -> AIVoiceExecutionResult {
        if let prior = requests[requestID] {
            guard prior.command == command else {
                return .init(status: .failed, message: "本次指令已提交，不能替换为另一项操作。")
            }
            return prior.result ?? .init(status: .unconfirmed, message: "本次操作正在处理，没有重复执行。")
        }
        requests[requestID] = Request(command: command)
        guard !Task.isCancelled else {
            let result = AIVoiceExecutionResult(status: .cancelled, message: "已取消，未执行操作。")
            requests[requestID]?.result = result
            return result
        }
        let resolution = resolve(command)
        guard case .ready(let validated, _) = resolution else {
            let message: String
            switch resolution {
            case .unavailable(let reason): message = reason
            case .needsChoice(let prompt, _): message = prompt
            case .ready: message = "无法确认操作目标。"
            }
            let result = AIVoiceExecutionResult(status: .failed, message: message)
            requests[requestID]?.result = result
            return result
        }
        let result = await perform(validated, currentApplication: currentApplication)
        requests[requestID]?.result = result
        return result
    }

    private func perform(_ command: AIVoiceCommand,
                         currentApplication: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult {
        do {
            try Task.checkCancellation()
            switch command.capabilityID {
            case Self.openApplicationID:
                guard let bundleID = command.parameters["application"],
                      let app = environment.installedApplications().first(where: { $0.bundleID == bundleID }) else {
                    return .init(status: .failed, message: "目标应用已不可用，请重新发出指令。")
                }
                let pid = try await environment.openApplication(at: app.url)
                let visible = try await waitForVerification { self.environment.hasVisibleWindow(processID: pid) }
                return .init(status: visible ? .succeeded : .unconfirmed, message: visible
                    ? "已打开\(app.name)。" : "已发起打开\(app.name)，但尚无法确认应用窗口。")
            case Self.openWeTypeSettingsID:
                guard let installation = environment.weTypeInstallation(),
                      installation.applicationVersion == "3.0.0", installation.settingsVersion == "3.0.0",
                      let settingsURL = installation.settingsURL else {
                    return .init(status: .failed, message: "微信输入法设置入口已变化，请重新检查安装版本。")
                }
                let pid = try await environment.openApplication(at: settingsURL)
                let visible = try await waitForVerification { self.environment.hasVisibleWindow(processID: pid) }
                return .init(status: visible ? .succeeded : .unconfirmed, message: visible
                    ? "已打开微信输入法设置。" : "已发起打开微信输入法设置，但尚无法确认设置窗口。")
            case Self.openSystemSettingsID:
                guard let value = command.parameters["page"], let page = AIVoiceSystemSettingsPage(rawValue: value),
                      environment.openSystemSettings(page) else {
                    return .init(status: .failed, message: "系统没有接受打开设置的请求。")
                }
                guard environment.canVerifySystemSettings else {
                    return .init(status: .unconfirmed, message: "已发起打开\(page.title)设置；缺少辅助功能权限，尚无法确认目标页面。")
                }
                let visible = try await waitForVerification { self.environment.hasVisibleSystemSettingsPage(page) }
                return .init(status: visible ? .succeeded : .unconfirmed, message: visible
                    ? "已打开\(page.title)设置。" : "已发起打开\(page.title)设置，但尚无法确认目标页面。")
            default:
                guard case .ready(let action, _) = AIVoiceBuiltInCommands.resolve(command) else {
                    return .init(status: .failed, message: "这项操作的参数无法执行。")
                }
                switch action {
                case .system(let action): return await systemControls.execute(action)
                case .desktop(let action): return await desktopActions.execute(action)
                case .systemAppearance(let mode): return await systemAppearance.execute(mode)
                case .currentAppSettings: return await currentAppSettings.execute(target: currentApplication)
                }
            }
        } catch is CancellationError {
            return .init(status: .cancelled, message: "已停止后续处理；已发起的操作可能仍会完成。")
        } catch let error as URLError where error.code == .timedOut {
            return .init(status: .unconfirmed, message: "打开请求已超时，尚无法确认结果；没有自动重试。")
        } catch {
            return .init(status: .failed, message: "操作失败：\(error.localizedDescription)")
        }
    }

    private func waitForVerification(_ verify: () -> Bool) async throws -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            try Task.checkCancellation()
            if verify() { return true }
            guard ProcessInfo.processInfo.systemUptime - start < verificationTimeout else { return false }
            try await Task.sleep(nanoseconds: pollingNanoseconds)
        } while true
    }

    private func applicationCommand(_ bundleID: String) -> AIVoiceCommand {
        .init(capabilityID: Self.openApplicationID, parameters: ["application": bundleID])
    }

    private func applicationCandidates(named name: String) -> [AIVoiceInstalledApplication] {
        let target = Self.normalize(name)
        guard !target.isEmpty else { return [] }
        var seen: Set<String> = []
        let apps = environment.installedApplications().filter { seen.insert($0.bundleID).inserted }
        // An exact bundle identifier is unambiguous, even when another app's
        // display name happens to equal it.
        if let exactID = apps.first(where: { $0.bundleID.caseInsensitiveCompare(name) == .orderedSame }) {
            return [exactID]
        }
        return apps.filter { ([ $0.name ] + $0.aliases).map(Self.normalize).contains(target) }
            .sorted { $0.bundleID < $1.bundleID }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
    }
}

@MainActor
final class AIVoiceMacCapabilityEnvironment: AIVoiceCapabilityEnvironment {
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let applicationDirectories: [URL]

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default, applicationDirectories: [URL]? = nil) {
        self.workspace = workspace
        self.fileManager = fileManager
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    func installedApplications() -> [AIVoiceInstalledApplication] {
        var applications: [AIVoiceInstalledApplication] = []
        var seen: Set<String> = []
        for root in applicationDirectories {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                // Safari's /Applications link carries Finder's hidden flag on
                // current macOS. Skipping every hidden resource loses a real
                // installed app; only ignore dot directories/files here.
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
                // Do not recursively scan arbitrary documents or application data.
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
                      let id = bundle.bundleIdentifier, seen.insert(id).inserted,
                      let executable = bundle.executableURL,
                      fileManager.isExecutableFile(atPath: executable.path) else { continue }
                let fileName = url.deletingPathExtension().lastPathComponent
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? fileName
                var aliases = [fileName]
                if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String { aliases.append(bundleName) }
                if id == "com.tencent.xinWeChat" { aliases += ["微信", "WeChat"] }
                if id == "com.apple.systempreferences" { aliases += ["系统设置", "System Settings"] }
                applications.append(.init(bundleID: id, name: name, aliases: aliases, url: url))
            }
        }
        return applications.sorted { $0.bundleID < $1.bundleID }
    }

    func weTypeInstallation() -> AIVoiceWeTypeInstallation? {
        let possible = [
            URL(fileURLWithPath: "/Library/Input Methods/WeType.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/WeType.app"),
            workspace.urlForApplication(withBundleIdentifier: "com.tencent.inputmethod.wetype"),
        ].compactMap { $0 }
        guard let url = possible.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.tencent.inputmethod.wetype" }),
              let parent = Bundle(url: url) else { return nil }
        let version = parent.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知版本"
        // This is the actual nested app shipped by WeType 3.0.0, verified from
        // its resources. The parent input-method app is never used as fallback.
        let settingsURL = url.appendingPathComponent("Contents/MacOS/WeTypeSettings.app")
        guard let child = Bundle(url: settingsURL), child.bundleIdentifier == "com.tencent.WeTypeSettings",
              let executable = child.executableURL, fileManager.isExecutableFile(atPath: executable.path) else {
            return .init(applicationVersion: version, settingsVersion: nil, settingsURL: nil)
        }
        return .init(applicationVersion: version,
                     settingsVersion: child.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                     settingsURL: settingsURL)
    }

    func openApplication(at url: URL) async throws -> Int32 {
        let request = AIVoiceApplicationLaunch()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                workspace.openApplication(at: url, configuration: configuration) { app, error in
                    Task { @MainActor in
                        if let error { request.complete(.failure(error)) }
                        else if let app { request.complete(.success(app.processIdentifier)) }
                        else { request.complete(.failure(CocoaError(.executableNotLoadable))) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in request.complete(.failure(CancellationError())) }
        }
    }

    func hasVisibleWindow(processID: Int32) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
            return (bounds["Width"]?.doubleValue ?? 0) > 20 && (bounds["Height"]?.doubleValue ?? 0) > 20
        }
    }

    var canVerifySystemSettings: Bool { AXIsProcessTrusted() }

    func openSystemSettings(_ page: AIVoiceSystemSettingsPage) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:" + page.extensionIdentifier) else { return false }
        return workspace.open(url)
    }

    func hasVisibleSystemSettingsPage(_ page: AIVoiceSystemSettingsPage) -> Bool {
        guard canVerifySystemSettings,
              let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }),
              hasVisibleWindow(processID: app.processIdentifier) else { return false }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return false }
        // Match the actual window title, never sidebar text: all settings
        // categories appear in the sidebar even when their page is not open.
        return windows.contains { window in
            var title: CFTypeRef?
            var main: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &main) == .success,
                  (main as? Bool) == true,
                  let text = title as? String else { return false }
            return page.verificationTitles.contains(text)
        }
    }
}

/// A checked continuation with a finite deadline. Cancellation ends our wait,
/// but cannot retract a launch request already handed to Launch Services.
@MainActor
private final class AIVoiceApplicationLaunch {
    private var continuation: CheckedContinuation<Int32, Error>?
    private var result: Result<Int32, Error>?
    private var deadline: Task<Void, Never>?

    func begin(_ continuation: CheckedContinuation<Int32, Error>) {
        if let result { continuation.resume(with: result); return }
        self.continuation = continuation
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            self?.complete(.failure(URLError(.timedOut)))
        }
    }

    func complete(_ result: Result<Int32, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
