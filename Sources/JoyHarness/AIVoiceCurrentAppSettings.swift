import AppKit
import ApplicationServices
import Foundation

struct AIVoiceForegroundApplication: Equatable, Sendable {
    let processID: Int32
    let bundleID: String
    let launchDate: Date
    let name: String

    fileprivate var hasUsableIdentity: Bool {
        processID > 0 && !bundleID.isEmpty && launchDate.timeIntervalSince1970.isFinite
    }

    fileprivate func isSameProcess(as other: Self) -> Bool {
        processID == other.processID && bundleID == other.bundleID && launchDate == other.launchDate
    }
}

@MainActor
protocol AIVoiceCurrentAppSettingsOpening {
    func captureTarget() -> AIVoiceForegroundApplication?
    func execute(target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult
}

@MainActor
protocol AIVoiceCurrentAppSettingsEnvironment {
    func frontmostApplication() -> AIVoiceForegroundApplication?
    var canPostEvents: Bool { get }
    func makeSettingsEvents() -> (down: CGEvent, up: CGEvent)?
    func postSettingsEvents(_ events: (down: CGEvent, up: CGEvent), to processID: Int32)
}

/// The submit-time target is immutable across transcription and model latency.
/// An app switch or process restart must not redirect the user's shortcut.
@MainActor
final class AIVoiceMacCurrentAppSettings: AIVoiceCurrentAppSettingsOpening {
    private let environment: any AIVoiceCurrentAppSettingsEnvironment

    init(environment: (any AIVoiceCurrentAppSettingsEnvironment)? = nil) {
        self.environment = environment ?? AIVoiceMacCurrentAppSettingsEnvironment()
    }

    func captureTarget() -> AIVoiceForegroundApplication? {
        guard let target = environment.frontmostApplication(), target.hasUsableIdentity else { return nil }
        return target
    }

    func execute(target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult {
        guard !Task.isCancelled else { return cancelled() }
        guard let target, target.hasUsableIdentity else {
            return .init(status: .failed, message: "提交语音时未能确定当前应用，本次未发送设置快捷键。")
        }
        guard isStillFrontmost(target) else { return targetChanged() }
        guard environment.canPostEvents else { return permissionDenied() }
        guard let events = environment.makeSettingsEvents() else {
            return .init(status: .failed, message: "无法构造完整的设置快捷键，本次未发送。")
        }
        // Recheck after constructing both packets, then keep the final check
        // and the complete key pair synchronous, without a suspension point.
        guard !Task.isCancelled else { return cancelled() }
        guard environment.canPostEvents else { return permissionDenied() }
        guard isStillFrontmost(target) else { return targetChanged() }
        environment.postSettingsEvents(events, to: target.processID)
        let name = target.name.isEmpty ? target.bundleID : target.name
        return .init(status: .unconfirmed,
                     message: "已向“\(name)”发送 Command＋逗号；尚无法确认设置窗口是否打开，应用也可能不支持此快捷键。")
    }

    private func isStillFrontmost(_ target: AIVoiceForegroundApplication) -> Bool {
        guard let current = environment.frontmostApplication(), current.hasUsableIdentity else { return false }
        return target.isSameProcess(as: current)
    }

    private func targetChanged() -> AIVoiceExecutionResult {
        .init(status: .failed, message: "当前应用已切换或重新启动，本次未发送设置快捷键。请回到目标应用后重新发起语音。")
    }

    private func permissionDenied() -> AIVoiceExecutionResult {
        .init(status: .failed, message: "缺少辅助功能权限，未发送设置快捷键；请在系统设置中允许 Joy Harness 控制电脑。")
    }

    private func cancelled() -> AIVoiceExecutionResult {
        .init(status: .cancelled, message: "已取消，未发送设置快捷键。")
    }
}

@MainActor
final class AIVoiceMacCurrentAppSettingsEnvironment: AIVoiceCurrentAppSettingsEnvironment {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func frontmostApplication() -> AIVoiceForegroundApplication? {
        guard let application = workspace.frontmostApplication, !application.isTerminated,
              application.processIdentifier > 0,
              let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
              let launchDate = application.launchDate else { return nil }
        return .init(processID: application.processIdentifier, bundleID: bundleID,
                     launchDate: launchDate, name: application.localizedName ?? bundleID)
    }

    var canPostEvents: Bool { CGPreflightPostEventAccess() }

    func makeSettingsEvents() -> (down: CGEvent, up: CGEvent)? { Self.settingsEvents() }

    static func settingsEvents() -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 43, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 43, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }
        return (down, up)
    }

    func postSettingsEvents(_ events: (down: CGEvent, up: CGEvent), to processID: Int32) {
        // PID-directed delivery avoids sending to a different app if focus
        // changes after the identity check. It does not activate the target or
        // prove that its settings window opened. Always finish the key pair.
        events.down.postToPid(processID)
        events.up.postToPid(processID)
    }
}
