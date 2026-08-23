import Combine
import Foundation

enum DashboardAction: Equatable {
    case refresh
    case selectSlot(Int)
    case approve
    case deny
    case toggleFastMode
    case openThread
    case testState(PadState)
}

struct DashboardSlot: Decodable, Identifiable, Equatable {
    let slot: Int
    let selected: Bool
    let threadID: String
    let title: String
    let state: String

    var id: Int { slot }
    var padState: PadState { PadState.parse(state) ?? .idle }
    var hasTask: Bool { !threadID.isEmpty || !title.isEmpty }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !threadID.isEmpty {
            return "\(L10n.text("任务", "Task")) \(threadID.suffix(8))"
        }
        return L10n.text("Micro 槽位", "Micro Slot")
    }

    enum CodingKeys: String, CodingKey {
        case slot, selected, title, state
        case threadID = "thread_id"
    }
}

struct DashboardStatus: Decodable, Equatable {
    let state: String
    let selectedSlot: Int
    let slots: [DashboardSlot]
    let controller: String
    let controllerConnected: Bool?
    let controllerFamily: String?
    let controllerTouchpad: Bool?
    let controllerBatteryLevel: Float?
    let controllerBatteryState: String?
    let haptics: Bool
    let accessibility: Bool
    let inputMonitoring: Bool?
    let microphone: Bool
    let voiceInput: String?
    let voiceInputDefault: Bool?
    let voiceInputTransport: String?
    let defaultVoiceInput: String?
    let rp2040: Bool
    let mode: String
    let note: String
    let timestamp: String

    var padState: PadState { PadState.parse(state) ?? .idle }
    var selected: DashboardSlot? { slots.first(where: { $0.slot == selectedSlot }) }

    enum CodingKeys: String, CodingKey {
        case state, slots, controller, haptics, accessibility, microphone, rp2040, mode, note
        case inputMonitoring = "input_monitoring"
        case controllerConnected = "controller_connected"
        case controllerFamily = "controller_family"
        case controllerTouchpad = "controller_touchpad"
        case controllerBatteryLevel = "controller_battery_level"
        case controllerBatteryState = "controller_battery_state"
        case voiceInput = "voice_input"
        case voiceInputDefault = "voice_input_default"
        case voiceInputTransport = "voice_input_transport"
        case defaultVoiceInput = "default_voice_input"
        case selectedSlot = "selected_slot"
        case timestamp = "ts"
    }

    static let empty = DashboardStatus(
        state: PadState.idle.rawValue,
        selectedSlot: 1,
        slots: (1...6).map {
            DashboardSlot(
                slot: $0,
                selected: $0 == 1,
                threadID: "",
                title: "",
                state: PadState.idle.rawValue
            )
        },
        controller: "No controller",
        controllerConnected: false,
        controllerFamily: nil,
        controllerTouchpad: false,
        controllerBatteryLevel: nil,
        controllerBatteryState: nil,
        haptics: false,
        accessibility: false,
        inputMonitoring: false,
        microphone: false,
        voiceInput: nil,
        voiceInputDefault: false,
        voiceInputTransport: nil,
        defaultVoiceInput: nil,
        rp2040: false,
        mode: "physical-codex-micro",
        note: L10n.text("正在读取状态", "Reading status"),
        timestamp: ""
    )
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var status = DashboardStatus.empty
    @Published private(set) var actionMessage = ""

    var onAction: ((DashboardAction) -> Bool)?

    private let statusURL: URL
    private var timer: Timer?

    init(statusURL: URL) {
        self.statusURL = statusURL
        reload()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: statusURL),
              let decoded = try? JSONDecoder().decode(DashboardStatus.self, from: data),
              decoded.slots.count == 6
        else { return }
        if decoded != status { status = decoded }
    }

    func perform(_ action: DashboardAction) {
        let succeeded = onAction?(action) == true
        actionMessage = succeeded
            ? successMessage(for: action)
            : L10n.text("操作未执行，请检查连接状态", "Action failed. Check the connection.")
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.actionMessage = ""
        }
    }

    private func successMessage(for action: DashboardAction) -> String {
        switch action {
        case .refresh: return L10n.text("状态已刷新", "Status refreshed")
        case .selectSlot(let index):
            return "\(L10n.text("已切换到槽位", "Switched to slot")) \(index + 1)"
        case .approve: return L10n.text("已发送批准", "Approval sent")
        case .deny: return L10n.text("已发送拒绝", "Denial sent")
        case .toggleFastMode: return L10n.text("已切换 Fast 模式", "Fast Mode toggled")
        case .openThread: return L10n.text("正在打开任务", "Opening task")
        case .testState(let state):
            return L10n.text("已测试 \(state.displayName) 反馈", "Tested \(state.displayName) feedback")
        }
    }
}
