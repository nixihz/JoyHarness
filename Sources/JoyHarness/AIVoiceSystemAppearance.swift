import Foundation

enum AIVoiceSystemAppearance: String, CaseIterable, Sendable {
    case light, dark
    case automatic = "auto"

    var title: String {
        switch self {
        case .light: L10n.text("日间（浅色）", "Light")
        case .dark: L10n.text("夜间（深色）", "Dark")
        case .automatic: L10n.text("自动", "Auto")
        }
    }
}

struct AIVoiceSystemAppearanceState: Equatable, Sendable {
    let isAutomatic: Bool
    let isDark: Bool

    var mode: AIVoiceSystemAppearance {
        isAutomatic ? .automatic : (isDark ? .dark : .light)
    }
}

@MainActor
protocol AIVoiceSystemAppearanceEnvironment {
    func read() throws -> AIVoiceSystemAppearanceState
    func setAutomatic(_ enabled: Bool) throws
    func setDark(_ dark: Bool) throws
}

@MainActor
protocol AIVoiceSystemAppearanceControlling {
    func execute(_ mode: AIVoiceSystemAppearance) async -> AIVoiceExecutionResult
}

/// Changes the user's macOS appearance preference, independently of the app's
/// own light/dark override. Automatic is a mode, not a snapshot of today's color.
@MainActor
final class AIVoiceMacSystemAppearance: AIVoiceSystemAppearanceControlling {
    private let environment: any AIVoiceSystemAppearanceEnvironment
    private let verificationAttempts: Int
    private let verificationDelayNanoseconds: UInt64

    init(environment: (any AIVoiceSystemAppearanceEnvironment)? = nil,
         verificationAttempts: Int = 5, verificationDelayNanoseconds: UInt64 = 100_000_000) {
        self.environment = environment ?? AIVoiceMacAppearanceEnvironment()
        self.verificationAttempts = max(1, min(verificationAttempts, 10))
        self.verificationDelayNanoseconds = min(verificationDelayNanoseconds, 200_000_000)
    }

    func execute(_ mode: AIVoiceSystemAppearance) async -> AIVoiceExecutionResult {
        var attemptedWrite = false
        do {
            try Task.checkCancellation()
            let before = try environment.read()
            if before.mode == mode { return success(mode) }
            attemptedWrite = true
            switch mode {
            case .automatic:
                try environment.setAutomatic(true)
            case .light, .dark:
                if before.isAutomatic { try environment.setAutomatic(false) }
                // Always establish the explicit color after disabling Auto,
                // even if Auto happened to display the requested color already.
                try environment.setDark(mode == .dark)
            }
            var lastError: Error?
            for attempt in 0..<verificationAttempts {
                try Task.checkCancellation()
                if attempt > 0, verificationDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: verificationDelayNanoseconds)
                }
                do {
                    if try environment.read().mode == mode {
                        try Task.checkCancellation()
                        return success(mode)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error }
            }
            let detail = lastError.map { "（\($0.localizedDescription)）" } ?? ""
            return .init(status: .unconfirmed, message: "已请求修改 macOS 外观，但尚未确认已切换为\(mode.title)\(detail)。")
        } catch is CancellationError {
            return .init(status: .cancelled, message: attemptedWrite
                ? "已停止核对 macOS 外观，已执行的修改可能仍然生效。" : "已取消，未修改 macOS 外观。")
        } catch {
            return .init(status: attemptedWrite ? .unconfirmed : .failed, message: attemptedWrite
                ? "修改 macOS 外观时失败，设置可能已部分变化：\(error.localizedDescription)"
                : "无法读取 macOS 外观，本次未修改：\(error.localizedDescription)")
        }
    }

    private func success(_ mode: AIVoiceSystemAppearance) -> AIVoiceExecutionResult {
        let message = mode == .automatic
            ? L10n.text("macOS 外观已设为自动，浅色／深色由系统按时间切换。", "macOS appearance is set to Auto and will switch between Light and Dark on its schedule.")
            : L10n.text("macOS 已设为\(mode.title)模式。", "macOS appearance is set to \(mode.title).")
        return .init(status: .succeeded, message: message)
    }
}
