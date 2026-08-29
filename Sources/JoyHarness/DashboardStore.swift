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

struct DashboardSlot: Codable, Identifiable, Equatable {
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

struct DashboardStatus: Codable, Equatable {
    let state: String
    let selectedSlot: Int
    let slots: [DashboardSlot]
    let controller: String
    let controllerConnected: Bool?
    let controllerFamily: String?
    let controllerTouchpad: Bool?
    let controllerBatteryLevel: Float?
    let controllerBatteryState: String?
    let joyConMode: String?
    let joyConOrientation: JoyConOrientation?
    let joyConPrimaryStick: JoyConStick?
    let joyConSecondaryStick: JoyConStick?
    let joyConLeftConnected: Bool?
    let joyConRightConnected: Bool?
    let joyConLeftBatteryLevel: Float?
    let joyConRightBatteryLevel: Float?
    let joyConLeftBatteryState: String?
    let joyConRightBatteryState: String?
    let joyConLeftHaptics: Bool?
    let joyConRightHaptics: Bool?
    let joyConLeftMotion: Bool?
    let joyConRightMotion: Bool?
    let joyConLeftProfileElements: [String]?
    let joyConRightProfileElements: [String]?
    let joyConLeftIMU: JoyConHIDMotionSnapshot?
    let joyConRightIMU: JoyConHIDMotionSnapshot?
    let joyConInactiveEndpoints: Int?
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
    let operationMode: String?
    let frontmostAppName: String?
    let frontmostAppBundleID: String?
    let note: String
    let timestamp: String

    var padState: PadState { PadState.parse(state) ?? .idle }
    var selected: DashboardSlot? { slots.first(where: { $0.slot == selectedSlot }) }
    var activeOperationMode: ControllerOperationMode {
        operationMode.flatMap(ControllerOperationMode.init(rawValue:)) ?? .mapping
    }
    var isNativeMode: Bool { activeOperationMode == .native }

    enum CodingKeys: String, CodingKey {
        case state, slots, controller, haptics, accessibility, microphone, rp2040, mode, note
        case operationMode = "operation_mode"
        case frontmostAppName = "frontmost_app_name"
        case frontmostAppBundleID = "frontmost_app_bundle_id"
        case inputMonitoring = "input_monitoring"
        case controllerConnected = "controller_connected"
        case controllerFamily = "controller_family"
        case controllerTouchpad = "controller_touchpad"
        case controllerBatteryLevel = "controller_battery_level"
        case controllerBatteryState = "controller_battery_state"
        case joyConMode = "joycon_mode"
        case joyConOrientation = "joycon_orientation"
        case joyConPrimaryStick = "joycon_primary_stick"
        case joyConSecondaryStick = "joycon_secondary_stick"
        case joyConLeftConnected = "joycon_left_connected"
        case joyConRightConnected = "joycon_right_connected"
        case joyConLeftBatteryLevel = "joycon_left_battery_level"
        case joyConRightBatteryLevel = "joycon_right_battery_level"
        case joyConLeftBatteryState = "joycon_left_battery_state"
        case joyConRightBatteryState = "joycon_right_battery_state"
        case joyConLeftHaptics = "joycon_left_haptics"
        case joyConRightHaptics = "joycon_right_haptics"
        case joyConLeftMotion = "joycon_left_motion"
        case joyConRightMotion = "joycon_right_motion"
        case joyConLeftProfileElements = "joycon_left_profile_elements"
        case joyConRightProfileElements = "joycon_right_profile_elements"
        case joyConLeftIMU = "joycon_left_imu"
        case joyConRightIMU = "joycon_right_imu"
        case joyConInactiveEndpoints = "joycon_inactive_endpoints"
        case voiceInput = "voice_input"
        case voiceInputDefault = "voice_input_default"
        case voiceInputTransport = "voice_input_transport"
        case defaultVoiceInput = "default_voice_input"
        case selectedSlot = "selected_slot"
        case timestamp = "ts"
    }

    init(
        state: String,
        selectedSlot: Int,
        slots: [DashboardSlot],
        controller: String,
        controllerConnected: Bool?,
        controllerFamily: String?,
        controllerTouchpad: Bool?,
        controllerBatteryLevel: Float?,
        controllerBatteryState: String?,
        joyConMode: String? = nil,
        joyConOrientation: JoyConOrientation? = nil,
        joyConPrimaryStick: JoyConStick? = nil,
        joyConSecondaryStick: JoyConStick? = nil,
        joyConLeftConnected: Bool? = nil,
        joyConRightConnected: Bool? = nil,
        joyConLeftBatteryLevel: Float? = nil,
        joyConRightBatteryLevel: Float? = nil,
        joyConLeftBatteryState: String? = nil,
        joyConRightBatteryState: String? = nil,
        joyConLeftHaptics: Bool? = nil,
        joyConRightHaptics: Bool? = nil,
        joyConLeftMotion: Bool? = nil,
        joyConRightMotion: Bool? = nil,
        joyConLeftProfileElements: [String]? = nil,
        joyConRightProfileElements: [String]? = nil,
        joyConLeftIMU: JoyConHIDMotionSnapshot? = nil,
        joyConRightIMU: JoyConHIDMotionSnapshot? = nil,
        joyConInactiveEndpoints: Int? = nil,
        haptics: Bool,
        accessibility: Bool,
        inputMonitoring: Bool?,
        microphone: Bool,
        voiceInput: String?,
        voiceInputDefault: Bool?,
        voiceInputTransport: String?,
        defaultVoiceInput: String?,
        rp2040: Bool,
        mode: String,
        operationMode: String? = nil,
        frontmostAppName: String? = nil,
        frontmostAppBundleID: String? = nil,
        note: String,
        timestamp: String
    ) {
        self.state = state
        self.selectedSlot = selectedSlot
        self.slots = slots
        self.controller = controller
        self.controllerConnected = controllerConnected
        self.controllerFamily = controllerFamily
        self.controllerTouchpad = controllerTouchpad
        self.controllerBatteryLevel = controllerBatteryLevel
        self.controllerBatteryState = controllerBatteryState
        self.joyConMode = joyConMode
        self.joyConOrientation = joyConOrientation
        self.joyConPrimaryStick = joyConPrimaryStick
        self.joyConSecondaryStick = joyConSecondaryStick
        self.joyConLeftConnected = joyConLeftConnected
        self.joyConRightConnected = joyConRightConnected
        self.joyConLeftBatteryLevel = joyConLeftBatteryLevel
        self.joyConRightBatteryLevel = joyConRightBatteryLevel
        self.joyConLeftBatteryState = joyConLeftBatteryState
        self.joyConRightBatteryState = joyConRightBatteryState
        self.joyConLeftHaptics = joyConLeftHaptics
        self.joyConRightHaptics = joyConRightHaptics
        self.joyConLeftMotion = joyConLeftMotion
        self.joyConRightMotion = joyConRightMotion
        self.joyConLeftProfileElements = joyConLeftProfileElements
        self.joyConRightProfileElements = joyConRightProfileElements
        self.joyConLeftIMU = joyConLeftIMU
        self.joyConRightIMU = joyConRightIMU
        self.joyConInactiveEndpoints = joyConInactiveEndpoints
        self.haptics = haptics
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.microphone = microphone
        self.voiceInput = voiceInput
        self.voiceInputDefault = voiceInputDefault
        self.voiceInputTransport = voiceInputTransport
        self.defaultVoiceInput = defaultVoiceInput
        self.rp2040 = rp2040
        self.mode = mode
        self.operationMode = operationMode
        self.frontmostAppName = frontmostAppName
        self.frontmostAppBundleID = frontmostAppBundleID
        self.note = note
        self.timestamp = timestamp
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
        joyConMode: nil,
        joyConOrientation: nil,
        joyConPrimaryStick: nil,
        joyConSecondaryStick: nil,
        joyConLeftConnected: nil,
        joyConRightConnected: nil,
        joyConLeftBatteryLevel: nil,
        joyConRightBatteryLevel: nil,
        joyConLeftBatteryState: nil,
        joyConRightBatteryState: nil,
        joyConLeftHaptics: nil,
        joyConRightHaptics: nil,
        joyConLeftMotion: nil,
        joyConRightMotion: nil,
        joyConLeftProfileElements: nil,
        joyConRightProfileElements: nil,
        joyConLeftIMU: nil,
        joyConRightIMU: nil,
        joyConInactiveEndpoints: nil,
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
        operationMode: "mapping",
        frontmostAppName: nil,
        frontmostAppBundleID: nil,
        note: L10n.text("正在读取状态", "Reading status"),
        timestamp: ""
    )
}

enum StatusFreshness: Equatable {
    case fresh
    case stale
    case unavailable
}

enum StatusRepositoryError: Error, Equatable, CustomStringConvertible {
    case missingFile(String)
    case read(String)
    case decode(String)
    case invalidSlotCount(Int)
    case invalidTimestamp(String)
    case createDirectory(String)
    case encode(String)
    case atomicWrite(String)

    var description: String {
        switch self {
        case .missingFile(let path):
            return "status file is missing: \(path)"
        case .read(let message):
            return "failed to read status: \(message)"
        case .decode(let message):
            return "failed to decode status: \(message)"
        case .invalidSlotCount(let count):
            return "status has \(count) slots; expected 6"
        case .invalidTimestamp(let value):
            return "status has an invalid timestamp: \(value)"
        case .createDirectory(let message):
            return "failed to create status directory: \(message)"
        case .encode(let message):
            return "failed to encode status: \(message)"
        case .atomicWrite(let message):
            return "failed to atomically write status: \(message)"
        }
    }
}

struct StatusRepositorySnapshot: Equatable {
    let status: DashboardStatus?
    let freshness: StatusFreshness
    let lastSuccessfulRead: Date?
    let error: StatusRepositoryError?
}

final class StatusRepository {
    private let statusURL: URL
    private let freshnessInterval: TimeInterval
    private let now: () -> Date
    private let reportError: (String) -> Void

    private(set) var lastSuccessfulRead: Date?
    private(set) var lastError: StatusRepositoryError?

    init(
        statusURL: URL,
        freshnessInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        reportError: @escaping (String) -> Void = StatusRepository.writeToStandardError
    ) {
        self.statusURL = statusURL
        self.freshnessInterval = freshnessInterval
        self.now = now
        self.reportError = reportError
    }

    func read() -> StatusRepositorySnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: statusURL)
        } catch {
            let repositoryError: StatusRepositoryError
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError
            {
                repositoryError = .missingFile(statusURL.path)
            } else {
                repositoryError = .read(error.localizedDescription)
            }
            return unavailable(repositoryError)
        }

        let status: DashboardStatus
        do {
            status = try JSONDecoder().decode(DashboardStatus.self, from: data)
        } catch {
            return unavailable(.decode(error.localizedDescription))
        }

        guard status.slots.count == 6 else {
            return unavailable(.invalidSlotCount(status.slots.count))
        }
        guard let payloadDate = Self.parseTimestamp(status.timestamp) else {
            return unavailable(.invalidTimestamp(status.timestamp))
        }

        let readAt = now()
        lastSuccessfulRead = readAt
        lastError = nil
        let freshness: StatusFreshness = abs(readAt.timeIntervalSince(payloadDate)) <= freshnessInterval
            ? .fresh
            : .stale
        return StatusRepositorySnapshot(
            status: status,
            freshness: freshness,
            lastSuccessfulRead: readAt,
            error: nil
        )
    }

    @discardableResult
    func write(_ status: DashboardStatus) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: statusURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return failWrite(.createDirectory(error.localizedDescription))
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(status)
        } catch {
            return failWrite(.encode(error.localizedDescription))
        }

        do {
            try data.write(to: statusURL, options: .atomic)
        } catch {
            return failWrite(.atomicWrite(error.localizedDescription))
        }

        lastError = nil
        return true
    }

    private func unavailable(_ error: StatusRepositoryError) -> StatusRepositorySnapshot {
        lastError = error
        return StatusRepositorySnapshot(
            status: nil,
            freshness: .unavailable,
            lastSuccessfulRead: lastSuccessfulRead,
            error: error
        )
    }

    private func failWrite(_ error: StatusRepositoryError) -> Bool {
        lastError = error
        reportError("[joy-harness] \(error.description)")
        return false
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func writeToStandardError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var status = DashboardStatus.empty
    @Published private(set) var freshness = StatusFreshness.unavailable
    @Published private(set) var lastSuccessfulRead: Date?
    @Published private(set) var statusError: StatusRepositoryError?
    @Published private(set) var actionMessage = ""
    @Published private(set) var pressedControllerInputs: Set<ControllerInput> = []

    var onAction: ((DashboardAction) -> Bool)?

    private let repository: StatusRepository
    private var timer: Timer?

    init(statusURL: URL) {
        self.repository = StatusRepository(statusURL: statusURL)
        reload()
    }

    init(repository: StatusRepository) {
        self.repository = repository
        reload()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        let snapshot = repository.read()
        freshness = snapshot.freshness
        lastSuccessfulRead = snapshot.lastSuccessfulRead
        statusError = snapshot.error
        let decoded = snapshot.status ?? .empty
        if decoded != status { status = decoded }
    }

    func setControllerInput(_ input: ControllerInput, pressed: Bool) {
        if pressed {
            pressedControllerInputs.insert(input)
        } else {
            pressedControllerInputs.remove(input)
        }
    }

    func clearControllerInputs() {
        pressedControllerInputs.removeAll()
    }

    @discardableResult
    func writeStatus(_ status: DashboardStatus) -> Bool {
        let succeeded = repository.write(status)
        statusError = repository.lastError
        if succeeded { reload() }
        return succeeded
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
