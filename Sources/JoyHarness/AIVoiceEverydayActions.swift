import AppKit
import ApplicationServices
import IOKit.pwr_mgt

enum AIVoiceWindowAction: String, Sendable {
    case minimize, fullscreen, exitFullscreen = "exit_fullscreen", hide

    var title: String {
        switch self {
        case .minimize: "最小化当前窗口"
        case .fullscreen: "当前窗口进入全屏"
        case .exitFullscreen: "当前窗口退出全屏"
        case .hide: "隐藏当前应用"
        }
    }
}

enum AIVoiceEverydayAction: Equatable, Sendable {
    case window(AIVoiceWindowAction)
    case searchFiles(String)
    case lockScreen
    case sleepSystem
}

enum AIVoiceEverydayCommands {
    static let descriptors: [AIVoiceCapabilityDescriptor] = [
        .init(id: "control_window", summary: "控制提交语音时的前台应用；执行时操作该应用的当前窗口。action 必填，只能minimize（最小化当前窗口）、fullscreen（进入全屏）、exit_fullscreen（退出全屏）、hide（隐藏当前应用）。目标由本机捕获，处理期间切换应用则不操作；不接受应用名、PID、自定义快捷键。不支持关闭、退出、强制结束、调整窗口位置。", parameterNames: ["action"], examples: ["最小化当前窗口", "当前窗口进入全屏", "退出全屏", "隐藏当前应用"]),
        .init(id: "search_files", summary: "打开本机Spotlight聚焦搜索。query 必填，为用户提供的文件名或搜索关键词（最多256字），缺少内容要追问。只展示搜索界面，不读取文件内容、不保证找到结果，不自动打开、修改或删除文件。打开访达可使用open_application(application=com.apple.finder)。", parameterNames: ["query"], examples: ["在电脑上查找预算表", "搜索本机文件 项目计划"]),
        .init(id: "lock_screen", summary: "请求锁定Mac屏幕，无参数。仅用户明确要求锁屏或锁定电脑时使用；通过一次固定Control+Command+Q快捷键请求，不代表注销、睡眠、重启或关机。", parameterNames: [], examples: ["锁定电脑", "锁屏"]),
        .init(id: "sleep_system", summary: "请求Mac进入睡眠，无参数。仅用户明确要求电脑睡眠时使用；不代表锁屏、关闭显示器、重启或关机，也不保证系统电源策略允许立即睡眠。", parameterNames: [], examples: ["让电脑睡眠", "Mac 进入睡眠"]),
    ]

    static func resolve(_ command: AIVoiceCommand) -> AIVoiceBuiltInResolution {
        switch command.capabilityID {
        case "control_window":
            guard Set(command.parameters.keys) == ["action"], let value = command.parameters["action"],
                  let action = AIVoiceWindowAction(rawValue: value) else {
                return .invalid("请指定最小化窗口、进入全屏、退出全屏或隐藏当前应用。")
            }
            return .ready(.everyday(.window(action)), summary: action.title)
        case "search_files":
            guard Set(command.parameters.keys) == ["query"],
                  let query = command.parameters["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.count <= 256,
                  query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return .invalid("请提供要在本机搜索的文件名或关键词（最多 256 字）。")
            }
            return .ready(.everyday(.searchFiles(query)), summary: "在本机搜索“\(query)”")
        case "lock_screen":
            guard command.parameters.isEmpty else { return .invalid("锁屏不接受额外参数。") }
            return .ready(.everyday(.lockScreen), summary: "锁定电脑屏幕")
        case "sleep_system":
            guard command.parameters.isEmpty else { return .invalid("电脑睡眠不接受额外参数。") }
            return .ready(.everyday(.sleepSystem), summary: "让电脑进入睡眠")
        default: return .unknown
        }
    }
}

@MainActor
protocol AIVoiceEverydayActing {
    func execute(_ action: AIVoiceEverydayAction, target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult
}

@MainActor
protocol AIVoiceEverydayEnvironment {
    func frontmostApplication() -> AIVoiceForegroundApplication?
    var canControlWindows: Bool { get }
    func focusedWindow(processID: Int32) -> AXUIElement?
    func readWindowFlag(_ attribute: String, window: AXUIElement) -> Bool?
    func setWindowFlag(_ attribute: String, value: Bool, window: AXUIElement) -> Bool
    func hideApplication(_ target: AIVoiceForegroundApplication) -> Bool
    func isApplicationHidden(_ target: AIVoiceForegroundApplication) -> Bool
    func searchFiles(_ query: String) -> Bool
    func postLockScreenShortcut() -> Bool
    func sleepSystem() -> Bool
}

@MainActor
final class AIVoiceMacEverydayActions: AIVoiceEverydayActing {
    private let environment: any AIVoiceEverydayEnvironment

    init(environment: (any AIVoiceEverydayEnvironment)? = nil) {
        self.environment = environment ?? AIVoiceMacEverydayEnvironment()
    }

    func execute(_ action: AIVoiceEverydayAction, target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult {
        guard !Task.isCancelled else { return .init(status: .cancelled, message: "已取消，未执行操作。") }
        switch action {
        case .searchFiles(let query):
            guard environment.searchFiles(query) else { return .init(status: .failed, message: "系统没有接受本机搜索请求。") }
            return .init(status: .unconfirmed, message: "已请求在聚焦中搜索“\(query)”，尚未确认搜索结果。")
        case .lockScreen:
            guard environment.postLockScreenShortcut() else {
                return .init(status: .failed, message: "无法发送锁屏快捷键，请检查 Joy Harness 的辅助功能权限。")
            }
            return .init(status: .unconfirmed, message: "已发送锁屏快捷键，尚未确认屏幕是否锁定。")
        case .sleepSystem:
            guard environment.sleepSystem() else {
                return .init(status: .failed, message: "系统没有接受睡眠请求。")
            }
            return .init(status: .unconfirmed, message: "系统已接受睡眠请求，尚未确认是否进入睡眠。")
        case .window(let action):
            return await controlWindow(action, target: target)
        }
    }

    private func controlWindow(_ action: AIVoiceWindowAction, target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult {
        guard let target, target.hasUsableIdentity, stillFrontmost(target) else { return changedTarget() }
        if action == .hide {
            guard environment.hideApplication(target) else {
                return .init(status: .failed, message: "无法隐藏目标应用。")
            }
            let hidden = await waitForState { environment.isApplicationHidden(target) }
            return .init(status: hidden ? .succeeded : .unconfirmed,
                         message: hidden ? "已隐藏\(target.name)。" : "已请求隐藏\(target.name)，尚未确认结果。")
        }
        guard environment.canControlWindows else {
            return .init(status: .failed, message: "缺少辅助功能权限，未操作窗口；请在系统设置中允许 Joy Harness 控制电脑。")
        }
        guard let window = environment.focusedWindow(processID: target.processID) else {
            return .init(status: .failed, message: "未找到目标应用的当前窗口。")
        }
        let attribute = action == .minimize ? kAXMinimizedAttribute : "AXFullScreen"
        let desired = action != .exitFullscreen
        guard let initial = environment.readWindowFlag(attribute, window: window) else {
            return .init(status: .failed, message: "当前窗口不支持这项操作。")
        }
        guard stillFrontmost(target) else { return changedTarget() }
        if initial == desired { return .init(status: .succeeded, message: "当前窗口已处于请求的状态。") }
        guard !Task.isCancelled, environment.canControlWindows else {
            return .init(status: .failed, message: "窗口操作已停止，未修改窗口。")
        }
        guard stillFrontmost(target) else { return changedTarget() }
        guard environment.setWindowFlag(attribute, value: desired, window: window) else {
            return .init(status: .failed, message: "应用没有接受窗口操作。")
        }
        let verified = await waitForState { environment.readWindowFlag(attribute, window: window) == desired }
        return .init(status: verified ? .succeeded : .unconfirmed,
                     message: verified ? "已完成：\(action.title)。" : "已请求\(action.title)，尚未确认窗口状态。")
    }

    private func waitForState(_ check: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            if Task.isCancelled { return false }
            if check() { return true }
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return false
            }
        } while ContinuousClock.now < deadline
        return check()
    }

    private func stillFrontmost(_ target: AIVoiceForegroundApplication) -> Bool {
        guard let current = environment.frontmostApplication(), current.hasUsableIdentity else { return false }
        return target.isSameProcess(as: current)
    }

    private func changedTarget() -> AIVoiceExecutionResult {
        .init(status: .failed, message: "未能确定提交时的应用，或应用已切换／重新启动；请回到目标应用重新发起语音。")
    }
}

@MainActor
final class AIVoiceMacEverydayEnvironment: AIVoiceEverydayEnvironment {
    func frontmostApplication() -> AIVoiceForegroundApplication? {
        AIVoiceMacCurrentAppSettingsEnvironment().frontmostApplication()
    }

    var canControlWindows: Bool { AXIsProcessTrusted() }

    func focusedWindow(processID: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func readWindowFlag(_ attribute: String, window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    func setWindowFlag(_ attribute: String, value: Bool, window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(window, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    private func application(_ target: AIVoiceForegroundApplication) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: target.processID), !app.isTerminated,
              app.bundleIdentifier == target.bundleID, app.launchDate == target.launchDate else { return nil }
        return app
    }

    func hideApplication(_ target: AIVoiceForegroundApplication) -> Bool { application(target)?.hide() ?? false }
    func isApplicationHidden(_ target: AIVoiceForegroundApplication) -> Bool { application(target)?.isHidden ?? false }
    func searchFiles(_ query: String) -> Bool { NSWorkspace.shared.showSearchResults(forQueryString: query) }

    func postLockScreenShortcut() -> Bool {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = [.maskCommand, .maskControl]
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func sleepSystem() -> Bool {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != IO_OBJECT_NULL else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }
}
