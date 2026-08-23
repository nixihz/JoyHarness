import AppKit
import Foundation
import SwiftUI

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(AgentDeckAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AgentDeck", id: "main") {
            DashboardView(store: appDelegate.runtime.dashboard)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新状态") {
                    appDelegate.runtime.dashboard.perform(.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("打开当前任务") {
                    appDelegate.runtime.dashboard.perform(.openThread)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AgentDeckAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AgentDeckRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        runtime.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class AgentDeckRuntime {
    let dashboard: DashboardStore

    private let home: String
    private let statusURL: URL
    private let socketPath: String
    private let haptics = HapticEngine()
    private let buttons = ButtonBridge()
    private let mouse = MouseBridge()
    private let rp2040 = RP2040Bridge()
    private var current: PadState = .idle
    private var slotStates = Array(repeating: PadState.idle, count: 6)
    private var server: SocketServer?
    private var hasStarted = false

    init() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.home = home
        self.statusURL = URL(fileURLWithPath: "\(home)/.agent-deck/status.json")
        self.socketPath = ProcessInfo.processInfo.environment["AGENT_DECK_SOCK"]
            ?? "\(home)/.agent-deck/pad.sock"
        self.dashboard = DashboardStore(statusURL: statusURL)
        self.dashboard.onAction = { [weak self] action in
            self?.perform(action) ?? false
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        configureBridge()

        haptics.startWatching()
        mouse.start()
        buttons.start()
        rp2040.start()
        writeStatus(.idle, note: "boot")
        startSocketServer()
        dashboard.startMonitoring()

        print("[agent-deck] physical Codex Micro mode; app-server disabled")
        print("[agent-deck] ready - A/B=clicks, X=backspace, Y=escape, LT+face=Codex actions")
    }

    @discardableResult
    func perform(_ action: DashboardAction) -> Bool {
        switch action {
        case .refresh:
            writeStatus(current, note: "status-refreshed")
            return true
        case .selectSlot(let index):
            guard (0..<6).contains(index), rp2040.isConnected else { return false }
            buttons.selectSlot(index)
            return true
        case .approve:
            return tapMicroKey("ACT07")
        case .deny:
            return tapMicroKey("ACT08")
        case .quickAction:
            return tapMicroKey("ACT06")
        case .openThread:
            guard rp2040.isConnected else { return false }
            buttons.openSelectedSlot()
            return true
        case .testState(let state):
            apply(state, note: "dashboard-test")
            return true
        }
    }

    private func configureBridge() {
        buttons.keyHandler = { [weak self] key, action in
            self?.rp2040.sendKey(key, action: action) ?? false
        }
        buttons.joystickHandler = { [weak self] angle, distance in
            self?.rp2040.sendJoystick(angle: angle, distance: distance) ?? false
        }
        buttons.mouseStickHandler = { [weak self] x, y in
            self?.mouse.updateStick(x: x, y: y)
        }
        buttons.mouseButtonHandler = { [weak self] button, pressed in
            self?.mouse.setMouseButton(button, pressed: pressed)
        }
        buttons.systemKeyHandler = { [weak self] key, pressed in
            self?.mouse.setSystemKey(key, pressed: pressed)
        }
        buttons.mouseSpeedBoostHandler = { [weak self] active in
            self?.mouse.setSpeedBoostActive(active)
        }
        buttons.onSlotSelected = { [weak self] index in
            guard let self else { return }
            self.current = self.slotStates[index]
            self.haptics.announceSlot(index, state: self.current)
            self.writeStatus(self.current, note: "slot-selected")
        }
        haptics.onConnectionChange = { [weak self] in
            guard let self else { return }
            self.haptics.apply(self.current)
            self.writeStatus(self.current, note: "controller-change")
        }
        rp2040.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.writeStatus(
                self.current,
                note: connected ? "rp2040-connected" : "rp2040-disconnected"
            )
        }
        mouse.onPermissionChange = { [weak self] in
            guard let self else { return }
            self.writeStatus(self.current, note: "accessibility-change")
        }
    }

    private func tapMicroKey(_ key: String) -> Bool {
        guard rp2040.sendKey(key, action: 1) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            _ = self?.rp2040.sendKey(key, action: 0)
        }
        return true
    }

    private func writeStatus(_ state: PadState, note: String?) {
        let selectedSlot = buttons.selectedSlot
        let slotPayload: [[String: Any]] = (0..<6).map { index in
            [
                "slot": index + 1,
                "selected": index == selectedSlot,
                "thread_id": "",
                "title": "",
                "state": slotStates[index].rawValue,
            ]
        }
        let payload: [String: Any] = [
            "state": state.rawValue,
            "selected_slot": selectedSlot + 1,
            "slots": slotPayload,
            "controller": haptics.connectedName,
            "haptics": haptics.hasController,
            "accessibility": mouse.isAccessibilityGranted,
            "microphone": false,
            "rp2040": rp2040.isConnected,
            "mode": "physical-codex-micro",
            "note": note ?? "",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? FileManager.default.createDirectory(
            atPath: "\(home)/.agent-deck",
            withIntermediateDirectories: true
        )
        try? data.write(to: statusURL, options: .atomic)
        dashboard.reload()
    }

    private func apply(_ state: PadState, note: String?) {
        current = state
        slotStates[buttons.selectedSlot] = state
        print("[agent-deck] state=\(state.rawValue)\(note.map { " note=\($0)" } ?? "")")
        haptics.apply(state)
        writeStatus(state, note: note)
        if state == .done || state == .error {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.current == state else { return }
                self.apply(.idle, note: "auto-idle")
            }
        }
    }

    private func startSocketServer() {
        let server = SocketServer(path: socketPath) { [weak self] command in
            self?.handle(command)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            fputs("[agent-deck] failed to listen: \(error)\n", stderr)
            apply(.error, note: "socket-listen-failed")
        }
    }

    private func handle(_ command: PadCommand) {
        if let action = command.action?.lowercased() {
            switch action {
            case "ping":
                print("[agent-deck] pong controller=\(haptics.connectedName) haptics=\(haptics.hasController)")
            case "status":
                print("[agent-deck] state=\(current.rawValue) controller=\(haptics.connectedName)")
            case "slots-refresh":
                _ = perform(.refresh)
            case "slot-next":
                buttons.moveSlot(1)
            case "slot-previous":
                buttons.moveSlot(-1)
            case "slot-open":
                _ = perform(.openThread)
            default:
                print("[agent-deck] unknown action=\(action)")
            }
        }
        if let raw = command.state, let state = PadState.parse(raw) {
            apply(state, note: command.note)
        }
    }
}
