import Combine
import Foundation

enum DashboardAction: Equatable {
    case refresh
    case selectSlot(Int)
    case approve
    case deny
    case quickAction
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
        if !threadID.isEmpty { return "任务 \(threadID.suffix(8))" }
        return "Micro 槽位"
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
    let haptics: Bool
    let accessibility: Bool
    let microphone: Bool
    let rp2040: Bool
    let mode: String
    let note: String
    let timestamp: String

    var padState: PadState { PadState.parse(state) ?? .idle }
    var selected: DashboardSlot? { slots.first(where: { $0.slot == selectedSlot }) }

    enum CodingKeys: String, CodingKey {
        case state, slots, controller, haptics, accessibility, microphone, rp2040, mode, note
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
        haptics: false,
        accessibility: false,
        microphone: false,
        rp2040: false,
        mode: "physical-codex-micro",
        note: "正在读取状态",
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
        actionMessage = succeeded ? successMessage(for: action) : "操作未执行，请检查连接状态"
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.actionMessage = ""
        }
    }

    private func successMessage(for action: DashboardAction) -> String {
        switch action {
        case .refresh: return "状态已刷新"
        case .selectSlot(let index): return "已切换到槽位 \(index + 1)"
        case .approve: return "已发送批准"
        case .deny: return "已发送拒绝"
        case .quickAction: return "已发送快捷操作"
        case .openThread: return "正在打开任务"
        case .testState(let state): return "已测试 \(state.displayName) 反馈"
        }
    }
}
