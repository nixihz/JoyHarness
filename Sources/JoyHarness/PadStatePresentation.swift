import SwiftUI

extension PadState {
    var displayName: String {
        switch self {
        case .idle: return L10n.text("就绪", "Ready")
        case .busy: return L10n.text("执行中", "Running")
        case .waiting: return L10n.text("等待批准", "Waiting for Approval")
        case .done: return L10n.text("已完成", "Completed")
        case .error: return L10n.text("发生错误", "Error")
        }
    }

    var shortDescription: String {
        switch self {
        case .idle: return L10n.text("等待下一项操作", "Waiting for the next action")
        case .busy: return L10n.text("任务正在处理", "Task in progress")
        case .waiting: return L10n.text("需要你的决定", "Your decision is required")
        case .done: return L10n.text("任务已结束", "Task finished")
        case .error: return L10n.text("请检查活动记录", "Check the activity log")
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "circle.dotted"
        case .busy: return "waveform.path.ecg"
        case .waiting: return "hourglass"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .busy: return .cyan
        case .waiting: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
}
