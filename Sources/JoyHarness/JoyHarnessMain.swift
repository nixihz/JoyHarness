import AppKit
import Foundation
import SwiftUI

@main
struct JoyHarnessApp: App {
    @NSApplicationDelegateAdaptor(JoyHarnessAppDelegate.self) private var appDelegate
    @StateObject private var languageSettings = AppLanguageSettings()
    @StateObject private var settingsCoordinator = SettingsCoordinator()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()

    var body: some Scene {
        WindowGroup("Joy Harness", id: "main") {
            DashboardView(
                store: appDelegate.runtime.dashboard,
                mappingStore: appDelegate.runtime.mappings
            )
                .environmentObject(languageSettings)
                .environmentObject(settingsCoordinator)
                .environment(\.locale, languageSettings.locale)
                .frame(
                    minWidth: 980,
                    idealWidth: 1240,
                    maxWidth: 1440,
                    minHeight: 680,
                    idealHeight: 820,
                    maxHeight: 920
                )
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {}

            CommandGroup(after: .newItem) {
                Button(L10n.text("刷新状态", "Refresh Status")) {
                    appDelegate.runtime.dashboard.perform(.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L10n.text("打开当前任务", "Open Current Task")) {
                    appDelegate.runtime.dashboard.perform(.openThread)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            AppSettingsView(
                mappingStore: appDelegate.runtime.mappings,
                languageSettings: languageSettings,
                launchAtLogin: launchAtLogin,
                scrollDirectionSettings: appDelegate.runtime.scrollDirectionSettings,
                pointerSensitivitySettings: appDelegate.runtime.pointerSensitivitySettings,
                nativeModeSettings: appDelegate.runtime.nativeGamepadAppSettings,
                settingsCoordinator: settingsCoordinator
            )
            .environment(\.locale, languageSettings.locale)
        }
    }
}

@MainActor
final class JoyHarnessAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = JoyHarnessRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        runtime.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

@MainActor
final class JoyHarnessRuntime {
    let dashboard: DashboardStore
    let mappings: ControllerMappingStore
    let scrollDirectionSettings: ScrollDirectionSettings
    let pointerSensitivitySettings: PointerSensitivitySettings
    let nativeGamepadAppSettings: NativeGamepadAppSettings
    private(set) var operationMode: ControllerOperationMode = .mapping
    private var frontmostAppName: String?
    private var frontmostAppBundleID: String?
    private var manuallySuppressedNativeBundleID: String?

    private let home: String
    private let statusURL: URL
    private let socketPath: String
    private let haptics = HapticEngine()
    private let adaptiveTrigger = AdaptiveTriggerFeedback()
    private var xboxTriggerPressState = RightTriggerPressState()
    private let threads = CodexThreadProvider()
    private let buttons: ButtonBridge
    private let mouse = MouseBridge()
    private let rp2040 = RP2040Bridge()
    private let joyConMotion = JoyConHIDMotionManager()
    private var current: PadState = .idle
    private var controllerFamily: ControllerFamily = .generic
    private var joyConSnapshot: JoyConControllerSnapshot?
    private var slotStates = Array(repeating: PadState.idle, count: 6)
    private var slotThreads = Array<CodexThreadSummary?>(repeating: nil, count: 6)
    private var threadStates: [String: PadState] = [:]
    private var lastBatterySnapshot: ControllerBatterySnapshot?
    private var lastJoyConBatterySnapshots: [JoyConSide: ControllerBatterySnapshot] = [:]
    private var lastMotionStatusWriteTime: TimeInterval = 0
    private let motionStatusWriteThrottleInterval: TimeInterval = 0.5
    private var batteryTimer: Timer?
    private var server: SocketServer?
    private var instanceLock: SingleInstanceLock?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var hasStarted = false

    init() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.home = home
        self.statusURL = URL(fileURLWithPath: "\(home)/.agent-deck/status.json")
        self.socketPath = ProcessInfo.processInfo.environment["AGENT_DECK_SOCK"]
            ?? "\(home)/.agent-deck/pad.sock"
        let mappings = ControllerMappingStore()
        self.mappings = mappings
        let scrollDirectionSettings = ScrollDirectionSettings()
        self.scrollDirectionSettings = scrollDirectionSettings
        let pointerSensitivitySettings = PointerSensitivitySettings()
        self.pointerSensitivitySettings = pointerSensitivitySettings
        let nativeGamepadAppSettings = NativeGamepadAppSettings()
        self.nativeGamepadAppSettings = nativeGamepadAppSettings
        self.buttons = ButtonBridge(mappingProvider: { mappings.action(for: $0) })
        self.dashboard = DashboardStore(statusURL: statusURL)
        self.dashboard.onAction = { [weak self] action in
            self?.perform(action) ?? false
        }
        self.mouse.setScrollDirection(scrollDirectionSettings.preference)
        self.mouse.setPointerSensitivities(pointerSensitivitySettings.values)
        scrollDirectionSettings.onChange = { [weak self] preference in
            self?.mouse.setScrollDirection(preference)
        }
        pointerSensitivitySettings.onChange = { [weak self] values in
            self?.mouse.setPointerSensitivities(values)
        }
        nativeGamepadAppSettings.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.checkFrontmostAppMode()
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        guard let instanceLock = SingleInstanceLock(
            path: "\(home)/.agent-deck/joy-harness.lock"
        ) else {
            print("[agent-deck] another Joy Harness instance is already running; exiting")
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock
        hasStarted = true
        configureBridge()
        threads.onUpdate = { [weak self] summaries in
            self?.updateThreads(summaries)
        }

        mouse.start()
        buttons.start()
        joyConMotion.start()
        adaptiveTrigger.start()
        startBatteryMonitoring()
        rp2040.start()
        threads.start()
        writeStatus(.idle, note: "boot")
        startSocketServer()
        dashboard.startMonitoring()

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkFrontmostAppMode()
            }
        }
        checkFrontmostAppMode()

        print("[agent-deck] physical Codex Micro mode; task metadata enabled")
        print("[agent-deck] ready - left stick=pointer, L3=speed boost, touchpad=slow slide, LT+left stick=scroll, LT+face=Codex actions")
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        batteryTimer?.invalidate()
        batteryTimer = nil
        dashboard.stopMonitoring()
        server?.stop()
        server = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        threads.stop()
        joyConMotion.stop()
        buttons.stop()
        mouse.stop()
        adaptiveTrigger.stop()
        haptics.stop()
        rp2040.stop()
        instanceLock = nil
    }

    @discardableResult
    func perform(_ action: DashboardAction) -> Bool {
        switch action {
        case .refresh:
            threads.refresh()
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
        case .toggleFastMode:
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
        buttons.leftStickHandler = { [weak self] x, y, scrolling in
            self?.mouse.updateStick(x: x, y: y, scrolling: scrolling)
        }
        buttons.mouseButtonHandler = { [weak self] button, pressed in
            self?.mouse.setMouseButton(button, pressed: pressed)
        }
        buttons.systemKeyHandler = { [weak self] key, pressed in
            self?.mouse.setSystemKey(key, pressed: pressed)
        }
        buttons.textInputHandler = { [weak self] text in
            self?.mouse.typeText(text) ?? false
        }
        buttons.mouseSpeedBoostHandler = { [weak self] active in
            self?.mouse.setSpeedBoostActive(active)
        }
        buttons.mousePrecisionHandler = { [weak self] active in
            self?.mouse.setPrecisionActive(active)
        }
        buttons.touchpadPointerHandler = { [weak self] x, y in
            self?.mouse.applyPointerDelta(x: x, y: y)
        }
        buttons.openApplicationTargetProvider = { [weak self] input in
            self?.mappings.openApplicationTarget(for: input)
        }
        buttons.recordedShortcutProvider = { [weak self] input in
            self?.mappings.recordedShortcutConfiguration(for: input).shortcut
        }
        buttons.joyConOrientationProvider = { [weak self] in
            self?.mappings.joyConOrientation ?? .horizontal
        }
        mappings.onJoyConOrientationChange = { [weak self] _ in
            self?.buttons.refreshJoyConOrientation()
        }
        buttons.recordedShortcutHandler = { [weak self] shortcut, pressed in
            self?.mouse.setRecordedShortcut(shortcut, pressed: pressed)
        }
        buttons.openApplicationHandler = { [weak self] bundleIdentifier in
            self?.openApplication(bundleIdentifier: bundleIdentifier) ?? false
        }
        buttons.rightTriggerFeedbackHandler = { [weak self] value in
            guard let self else { return }
            if self.controllerFamily == .xbox {
                if let event = self.xboxTriggerPressState.update(value: value) {
                    self.haptics.playXboxTriggerFeedback(event)
                }
            } else {
                self.adaptiveTrigger.update(value: value)
            }
        }
        adaptiveTrigger.onFeedback = { [weak self] event in
            self?.haptics.playAdaptiveTriggerFeedback(event)
        }
        adaptiveTrigger.onHomeButtonChange = { [weak self] isPressed in
            self?.buttons.handleRawHomeButton(isPressed: isPressed)
        }
        buttons.onSlotSelected = { [weak self] index in
            guard let self else { return }
            self.current = self.slotStates[index]
            self.haptics.announceSlot(index, state: self.current)
            self.writeStatus(self.current, note: "slot-selected")
        }
        buttons.onControllerChange = { [weak self] controller, family in
            guard let self else { return }
            self.lastBatterySnapshot = nil
            self.lastJoyConBatterySnapshots.removeAll()
            self.controllerFamily = family
            self.xboxTriggerPressState = RightTriggerPressState()
            self.mappings.setControllerFamily(family)
            self.adaptiveTrigger.attach(controller)
        }
        buttons.onControllerSetChange = { [weak self] controllers in
            self?.haptics.attach(controllers)
        }
        buttons.onJoyConChange = { [weak self] snapshot in
            guard let self else { return }
            self.joyConSnapshot = snapshot
            self.writeStatus(self.current, note: "joycon-mode-change")
        }
        joyConMotion.onMotionChange = { [weak self] _, _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastMotionStatusWriteTime >= self.motionStatusWriteThrottleInterval else { return }
            self.lastMotionStatusWriteTime = now
            self.writeStatus(self.current, note: "joycon-motion")
        }
        joyConMotion.onShoulderChange = { [weak self] side, snapshot in
            self?.buttons.updateJoyConHIDShoulders(side: side, snapshot: snapshot)
        }
        buttons.onAvailableInputsChange = { [weak self] inputs in
            self?.mappings.setAvailableInputs(inputs)
        }
        buttons.onInputStateChange = { [weak self] input, pressed in
            self?.dashboard.setControllerInput(input, pressed: pressed)
        }
        buttons.onOperationModeChange = { [weak self] mode in
            self?.handleOperationModeChanged(mode)
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

    func checkFrontmostAppMode() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier
        let appName = app.localizedName
        self.frontmostAppName = appName
        self.frontmostAppBundleID = bundleID
        guard nativeGamepadAppSettings.autoSwitchEnabled else { return }

        let matches = nativeGamepadAppSettings.matches(runningApp: app)
        if matches {
            if let bundleID, bundleID == manuallySuppressedNativeBundleID {
                return
            }
            if operationMode != .native {
                setOperationMode(.native, note: "auto-switch: \(appName ?? bundleID ?? "native-app")")
            }
        } else {
            manuallySuppressedNativeBundleID = nil
            if operationMode == .native {
                setOperationMode(.mapping, note: "auto-switch: \(appName ?? bundleID ?? "mapping-app")")
            }
        }
    }

    func unfocusFrontmostNativeAppIfNeeded() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        if nativeGamepadAppSettings.matches(runningApp: frontmost) {
            manuallySuppressedNativeBundleID = frontmost.bundleIdentifier
            frontmost.hide()

            let candidates = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular &&
                !app.isHidden &&
                !app.isTerminated &&
                app.bundleIdentifier != frontmost.bundleIdentifier &&
                !self.nativeGamepadAppSettings.matches(runningApp: app)
            }
            if let nextApp = candidates.first(where: { $0.bundleIdentifier != "tech.keli.joyharness" }) ?? candidates.first {
                nextApp.activate(options: .activateIgnoringOtherApps)
                print("[agent-deck] leaving native mode: activated next app \(nextApp.localizedName ?? "")")
            } else if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
                finder.activate(options: .activateIgnoringOtherApps)
            }
            print("[agent-deck] leaving native mode: hiding frontmost native app \(frontmost.localizedName ?? frontmost.bundleIdentifier ?? "")")
        }
    }

    func handleManualModeToggle() {
        let nextMode: ControllerOperationMode = (operationMode == .native ? .mapping : .native)
        setOperationMode(nextMode, note: "manual-toggle")
    }

    private func handleOperationModeChanged(_ mode: ControllerOperationMode) {
        guard mode != operationMode else { return }
        let previousMode = operationMode
        operationMode = mode
        if previousMode == .native && mode == .mapping {
            unfocusFrontmostNativeAppIfNeeded()
        }
        haptics.playOperationModeFeedback(mode)
        writeStatus(current, note: "mode-change: \(mode.rawValue)")
    }

    func setOperationMode(_ mode: ControllerOperationMode, note: String) {
        guard mode != operationMode else { return }
        let previousMode = operationMode
        operationMode = mode
        buttons.setOperationMode(mode)
        if previousMode == .native && mode == .mapping && note.contains("manual") {
            unfocusFrontmostNativeAppIfNeeded()
        }
        haptics.playOperationModeFeedback(mode)
        writeStatus(current, note: note)
        print("[agent-deck] operation mode=\(mode.rawValue) note=\(note)")
    }

    private func tapMicroKey(_ key: String) -> Bool {
        guard rp2040.sendKey(key, action: 1) else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            _ = self?.rp2040.sendKey(key, action: 0)
        }
        return true
    }

    private func openApplication(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            print("[agent-deck] application not found: \(bundleIdentifier)")
            return false
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                print("[agent-deck] failed to open \(bundleIdentifier): \(error.localizedDescription)")
            }
        }
        return true
    }

    private func writeStatus(_ state: PadState, note: String?) {
        let selectedSlot = buttons.selectedSlot
        let audio = ControllerAudioSupport.snapshot(for: controllerFamily)
        let voiceInput = audio.controllerInput
        let battery = buttons.batterySnapshot
        let slots = (0..<6).map { index in
            let thread = slotThreads[index]
            return DashboardSlot(
                slot: index + 1,
                selected: index == selectedSlot,
                threadID: thread?.id ?? "",
                title: thread?.title ?? "",
                state: slotStates[index].rawValue
            )
        }
        let sideBatteries = buttons.joyConBatterySnapshots
        let joyConSticks = joyConSnapshot.map { _ in buttons.joyConSticks }
        let status = DashboardStatus(
            state: state.rawValue,
            selectedSlot: selectedSlot + 1,
            slots: slots,
            controller: haptics.connectedName,
            controllerConnected: haptics.connectedName != "none",
            controllerFamily: controllerFamily.rawValue,
            controllerTouchpad: controllerFamily == .dualSense || controllerFamily == .dualShock,
            controllerBatteryLevel: battery?.level,
            controllerBatteryState: battery?.state.rawValue,
            joyConMode: joyConSnapshot?.mode.rawValue,
            joyConOrientation: joyConSnapshot.flatMap {
                $0.mode == .pair ? nil : mappings.joyConOrientation
            },
            joyConPrimaryStick: joyConSticks?.primary,
            joyConSecondaryStick: joyConSticks?.secondary,
            joyConLeftConnected: joyConSnapshot.map { $0.left != nil },
            joyConRightConnected: joyConSnapshot.map { $0.right != nil },
            joyConLeftBatteryLevel: joyConSnapshot.flatMap { _ in sideBatteries[.left]?.level },
            joyConRightBatteryLevel: joyConSnapshot.flatMap { _ in sideBatteries[.right]?.level },
            joyConLeftBatteryState: joyConSnapshot.flatMap { _ in sideBatteries[.left]?.state.rawValue },
            joyConRightBatteryState: joyConSnapshot.flatMap { _ in sideBatteries[.right]?.state.rawValue },
            joyConLeftHaptics: joyConSnapshot.map { $0.left?.hasHaptics ?? false },
            joyConRightHaptics: joyConSnapshot.map { $0.right?.hasHaptics ?? false },
            joyConLeftMotion: joyConSnapshot.map {
                $0.left?.hasMotion == true || joyConMotion.snapshots[.left] != nil
            },
            joyConRightMotion: joyConSnapshot.map {
                $0.right?.hasMotion == true || joyConMotion.snapshots[.right] != nil
            },
            joyConLeftProfileElements: joyConSnapshot.map { $0.left?.profileElements ?? [] },
            joyConRightProfileElements: joyConSnapshot.map { $0.right?.profileElements ?? [] },
            joyConLeftIMU: joyConSnapshot.flatMap { _ in joyConMotion.snapshots[.left] },
            joyConRightIMU: joyConSnapshot.flatMap { _ in joyConMotion.snapshots[.right] },
            joyConInactiveEndpoints: joyConSnapshot?.inactiveEndpointCount,
            haptics: haptics.hasController,
            accessibility: mouse.isAccessibilityGranted,
            inputMonitoring: mouse.isInputMonitoringGranted,
            microphone: voiceInput != nil,
            voiceInput: voiceInput?.name ?? "",
            voiceInputDefault: voiceInput?.isDefault ?? false,
            voiceInputTransport: voiceInput?.transport ?? "",
            defaultVoiceInput: audio.defaultInputName ?? "",
            rp2040: rp2040.isConnected,
            mode: "physical-codex-micro",
            operationMode: operationMode.rawValue,
            frontmostAppName: frontmostAppName,
            frontmostAppBundleID: frontmostAppBundleID,
            note: note ?? "",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        _ = dashboard.writeStatus(status)
    }

    private func startBatteryMonitoring() {
        lastBatterySnapshot = buttons.batterySnapshot
        lastJoyConBatterySnapshots = buttons.joyConBatterySnapshots
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snapshot = self.buttons.batterySnapshot
                let joyConSnapshots = self.buttons.joyConBatterySnapshots
                let batteryChanged = snapshot != self.lastBatterySnapshot
                    || joyConSnapshots != self.lastJoyConBatterySnapshots
                self.lastBatterySnapshot = snapshot
                self.lastJoyConBatterySnapshots = joyConSnapshots
                self.writeStatus(
                    self.current,
                    note: batteryChanged ? "controller-battery-change" : "status-heartbeat"
                )
            }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func apply(_ state: PadState, note: String?, threadID: String? = nil) {
        let taskID = threadID.flatMap { $0.isEmpty ? nil : $0 }
        let targetSlot = taskID.flatMap { id in
            slotThreads.firstIndex(where: { $0?.id == id })
        } ?? (taskID == nil ? buttons.selectedSlot : nil)
        if let taskID {
            threadStates[taskID] = state
            if targetSlot == nil { threads.refresh() }
        }
        if let targetSlot {
            slotStates[targetSlot] = state
        }
        print("[agent-deck] state=\(state.rawValue)\(note.map { " note=\($0)" } ?? "")")
        if let targetSlot, targetSlot == buttons.selectedSlot {
            current = state
            haptics.apply(state)
        }
        writeStatus(current, note: note)
        if state == .done || state == .error {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let stateIsCurrent = taskID.map { self.threadStates[$0] == state }
                    ?? targetSlot.map { self.slotStates[$0] == state }
                    ?? false
                guard stateIsCurrent else { return }
                self.apply(.idle, note: "auto-idle", threadID: taskID)
            }
        }
    }

    private func updateThreads(_ summaries: [CodexThreadSummary]) {
        let padded = summaries.prefix(6).map(Optional.some)
            + Array(repeating: nil, count: max(0, 6 - summaries.count))
        slotThreads = Array(padded.prefix(6))
        for index in 0..<6 {
            guard let threadID = slotThreads[index]?.id else {
                slotStates[index] = .idle
                continue
            }
            slotStates[index] = threadStates[threadID] ?? .idle
        }
        current = slotStates[buttons.selectedSlot]
        haptics.apply(current)
        writeStatus(current, note: "tasks-refreshed")
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
        if let action = command.action {
            switch action {
            case .ping:
                print("[agent-deck] pong controller=\(haptics.connectedName) haptics=\(haptics.hasController)")
            case .status:
                print("[agent-deck] state=\(current.rawValue) controller=\(haptics.connectedName)")
                writeStatus(current, note: command.note ?? "status-request")
            case .slotsRefresh:
                _ = perform(.refresh)
            case .slotNext:
                buttons.moveSlot(1)
            case .slotPrevious:
                buttons.moveSlot(-1)
            case .slotOpen:
                _ = perform(.openThread)
            }
        }
        if let raw = command.state, let state = PadState.parse(raw) {
            apply(state, note: command.note, threadID: command.threadID)
        }
    }
}
