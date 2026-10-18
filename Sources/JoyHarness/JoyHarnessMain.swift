import AppKit
import AVFoundation
import Foundation
import SwiftUI

@main
enum JoyHarnessEntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-bundle-resources") {
            let missing = ControllerArtwork.missingResources
            guard AppResources.packagedBundle(in: .main) != nil,
                  AppVersion.current == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  missing.isEmpty else {
                fputs("Packaged resources invalid: version=\(AppVersion.current), missing=\(missing.sorted())\n", stderr)
                exit(1)
            }
            print("Packaged resources verified: \(AppVersion.current) at \(AppResources.bundle.bundleURL.path)")
            return
        }
        if CommandLine.arguments.contains("--remote-volume-guard") {
            RemoteVolumeGuardWorker().run()
        } else {
            JoyHarnessApp.main()
        }
    }
}

struct JoyHarnessApp: App {
    @NSApplicationDelegateAdaptor(JoyHarnessAppDelegate.self) private var appDelegate
    @StateObject private var appearanceSettings = AppearanceSettings()
    @StateObject private var languageSettings = AppLanguageSettings()
    @StateObject private var settingsCoordinator = SettingsCoordinator()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()

    var body: some Scene {
        WindowGroup(MainWindow.title, id: MainWindow.id) {
            DashboardView(
                store: appDelegate.runtime.dashboard,
                mappingStore: appDelegate.runtime.mappings,
                harnessProviderSettings: appDelegate.runtime.harnessProviderSettings
            )
                .environmentObject(languageSettings)
                .environmentObject(settingsCoordinator)
                .environment(\.locale, languageSettings.locale)
                .mainWindowChrome()
                .exposeOpenMainWindow { [runtime = appDelegate.runtime] openMainWindow in
                    runtime.mainWindowOpener = openMainWindow
                }
                .background(AIVoiceSettingsOpener(coordinator: settingsCoordinator) { opener in
                    appDelegate.runtime.aiVoiceSettingsOpener = opener
                })
        }
        .defaultSize(width: DashboardStyle.windowWidth, height: DashboardStyle.windowHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {}

            if appDelegate.updater.isAvailable {
                CommandGroup(after: .appInfo) {
                    Button(L10n.text("检查更新…", "Check for Updates…")) {
                        appDelegate.updater.checkForUpdates()
                    }
                }
            }

            CommandGroup(after: .newItem) {
                Button(L10n.text("刷新状态", "Refresh Status")) {
                    appDelegate.runtime.dashboard.perform(.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            AppSettingsView(
                mappingStore: appDelegate.runtime.mappings,
                appearanceSettings: appearanceSettings,
                languageSettings: languageSettings,
                launchAtLogin: launchAtLogin,
                updater: appDelegate.updater,
                scrollDirectionSettings: appDelegate.runtime.scrollDirectionSettings,
                pointerSensitivitySettings: appDelegate.runtime.pointerSensitivitySettings,
                motionJump: appDelegate.runtime.motionJump,
                nativeModeSettings: appDelegate.runtime.nativeGamepadAppSettings,
                harnessProviderSettings: appDelegate.runtime.harnessProviderSettings,
                settingsCoordinator: settingsCoordinator,
                slotShortcutSettings: appDelegate.runtime.slotShortcutSettings,
                edgeLightSettings: appDelegate.runtime.edgeLightSettings,
                aiVoiceSettings: appDelegate.runtime.aiVoiceSettings,
                aiVoiceSession: appDelegate.runtime.aiVoice,
                aiVoiceInputIssue: { appDelegate.runtime.aiVoiceInputIssue },
                dualSenseMicrophone: appDelegate.runtime.dualSenseMicrophone
            )
            .environment(\.locale, languageSettings.locale)
        }
    }
}

@MainActor
final class JoyHarnessAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = JoyHarnessRuntime()
    let updater = AppUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        updater.start()
        runtime.start()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.configureMainWindow() }
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.title == MainWindow.title }) else { return }
        let defaults = UserDefaults.standard
        let migrationKey = "dashboardCompactWindow.applied"
        guard !defaults.bool(forKey: migrationKey) else { return }
        // SwiftUI restoration can override defaultSize. Apply once after the
        // main window exists, then let subsequent launches restore it normally.
        window.setContentSize(NSSize(width: DashboardStyle.windowWidth, height: DashboardStyle.windowHeight))
        window.saveFrame(usingName: "main-AppWindow-1")
        defaults.set(true, forKey: migrationKey)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime.dualSenseMicrophoneNeedsShutdown else { return .terminateNow }
        Task { @MainActor in
            await runtime.prepareMicrophoneForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// SwiftUI leaves a Dock click doing nothing once the Dashboard is
    /// closed, since Joy Harness keeps running; reopen it here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A restored background launch may not have displayed the Dashboard
        // yet. Allow SwiftUI's default reopen when its opener is not installed.
        !runtime.showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stopHotkeys()
    }
}

@MainActor
final class JoyHarnessRuntime {
    let slotShortcutSettings = SlotShortcutSettings()
    let edgeLightSettings = EdgeLightSettings()
    private let microMirror = CodexMicroMirror()
    private var edgeLights: EdgeLightCoordinator!
    let dashboard: DashboardStore
    let mappings: ControllerMappingStore
    let scrollDirectionSettings: ScrollDirectionSettings
    let pointerSensitivitySettings: PointerSensitivitySettings
    let motionJump = MotionJumpCoordinator()
    let aiVoiceSettings = AIVoiceSettings()
    let externalDualSenseAudio = DualSenseExternalAudio()
    private(set) lazy var aiVoice = AIVoiceSession(settings: aiVoiceSettings)
    private lazy var aiVoiceOverlay = AIVoiceOverlay(session: aiVoice)
    var aiVoiceSettingsOpener: (() -> Void)?
    var aiVoiceInputIssue: String? { buttons.aiVoiceInputIssue }
    private var aiVoiceObservers: [NSObjectProtocol] = []
    private var aiVoiceLockObservers: [NSObjectProtocol] = []
    private var aiVoiceSystemSuspended = false
    let nativeGamepadAppSettings: NativeGamepadAppSettings
    let harnessProviderSettings: HarnessProviderSettings
    /// Opens a new Dashboard window. The main window installs it because only
    /// SwiftUI views can reach `openWindow`.
    var mainWindowOpener: (() -> Void)?
    private(set) var operationMode: ControllerOperationMode = .mapping
    private var frontmostAppName: String?
    private var frontmostAppBundleID: String?
    private var manuallySuppressedNativeBundleID: String?
    private var manuallyForcedNativeMode = false

    private let home: String
    private let statusURL: URL
    private let socketPath: String
    private let haptics = HapticEngine()
    private let harnessSwitcher = HarnessSwitcherCoordinator()
    private let adaptiveTrigger = AdaptiveTriggerFeedback()
    private var xboxTriggerPressState = RightTriggerPressState()
    private let threads = CodexThreadProvider()
    private let buttons: ControllerHub
    private let mouse = MouseBridge()
    private let rp2040 = RP2040Bridge()
    private let slotHotkeys = SlotHotkeys()
    private let joyConMotion = JoyConHIDMotionManager()
    private let xiaomiRemote = XiaomiRemoteHIDManager()
    private let xiaomiVoice = XiaomiRemoteVoice()
    private let remoteMicrophoneOutput = RemoteMicrophoneOutput()
    private let dualSenseAudioOutput = DualSenseSystemAudioOutput()
    private let dualSenseAudioDecoder = DualSenseMicrophoneDecodeQueue()
    private(set) lazy var dualSenseMicrophone = makeDualSenseMicrophone()
    private lazy var dualSenseMicrophoneOverlay = DualSenseMicrophoneOverlay(session: dualSenseMicrophone)
    private var pendingMicrophoneNativeMode: String?
    private var current: PadState = .idle
    private var controllerFamily: ControllerFamily = .generic
    private var lastStatusControllerID: String?
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
    private var hasStarted = false

    init() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.home = home
        self.statusURL = URL(fileURLWithPath: "\(home)/.agent-deck/status.json")
        self.socketPath = ProcessInfo.processInfo.environment["AGENT_DECK_SOCK"]
            ?? "\(home)/.agent-deck/pad.sock"
        let harnessProviderSettings = HarnessProviderSettings()
        self.harnessProviderSettings = harnessProviderSettings
        let mappings = ControllerMappingStore(
            harnessProvider: harnessProviderSettings.activeProviderID ?? .codex
        )
        self.mappings = mappings
        let scrollDirectionSettings = ScrollDirectionSettings()
        self.scrollDirectionSettings = scrollDirectionSettings
        let pointerSensitivitySettings = PointerSensitivitySettings()
        self.pointerSensitivitySettings = pointerSensitivitySettings
        let nativeGamepadAppSettings = NativeGamepadAppSettings()
        self.nativeGamepadAppSettings = nativeGamepadAppSettings
        self.buttons = ControllerHub(
            mappingProvider: { family, input in mappings.action(for: input, family: family) }
        )
        self.dashboard = DashboardStore(statusURL: statusURL)
        edgeLights = EdgeLightCoordinator(settings: edgeLightSettings)
        edgeLights.onOpenSlot = { [weak self] index in self?.openEdgeLightSlot(index) ?? false }
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
        harnessProviderSettings.onActiveProviderChange = { [weak self] providerID in
            self?.applyActiveHarness(providerID)
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
        edgeLights.start()
        microMirror.onSnapshot = { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.edgeLightSettings.isMicroSynchronized = snapshot != nil
                self.edgeLights.update(snapshot?.slots ?? (0..<6).map {
                    EdgeLightSlot(identity: "micro-\($0)", title: L10n.text("未同步", "Not synchronized"), state: nil)
                })
            }
        }
        microMirror.start()
        adaptiveTrigger.startHIDInputMonitoring()
        threads.onUpdate = { [weak self] summaries in
            self?.updateThreads(summaries)
        }

        mouse.start()
        xiaomiRemote.start()
        buttons.start()
        joyConMotion.start()
        startBatteryMonitoring()
        rp2040.start()
        threads.start()
        writeStatus(.idle, note: "boot")
        startSocketServer()
        dashboard.startMonitoring()
        slotHotkeys.onSelectSlot = { [weak self] index in
            self?.dashboard.perform(.selectSlot(index))
        }
        slotShortcutSettings.onChange = { [weak self] in
            self?.registerSlotHotkeys()
        }
        slotShortcutSettings.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording { self.slotHotkeys.stop() }
            else { self.registerSlotHotkeys() }
        }
        registerSlotHotkeys()

        NSWorkspace.shared.notificationCenter.addObserver(
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
        print("[agent-deck] ready - left stick=pointer, right stick=scroll, L3=speed boost, touchpad=slow slide, LT+left stick=speed boost (solo Joy-Con=scroll), LT+face=Codex actions")
    }

    private func registerSlotHotkeys() {
        slotShortcutSettings.errors = slotHotkeys.start(shortcuts: slotShortcutSettings.shortcuts)
    }

    var dualSenseMicrophoneNeedsShutdown: Bool { dualSenseMicrophone.isEngaged }

    func prepareMicrophoneForTermination() async {
        pendingMicrophoneNativeMode = nil
        aiVoiceSystemSuspended = true
        dualSenseMicrophone.stop(reason: "Joy Harness 正在退出，已停止供音。")
        let deadline = ProcessInfo.processInfo.systemUptime + 2.1
        while dualSenseMicrophone.isEngaged, dualSenseMicrophone.phase != .fault,
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func stopHotkeys() {
        dualSenseMicrophone.stop(reason: "Joy Harness 正在退出，已停止供音。")
        dualSenseMicrophoneOverlay.hide()
        aiVoice.stop()
        externalDualSenseAudio.stop()
        aiVoiceOverlay.hide()
        for token in aiVoiceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        aiVoiceObservers.removeAll()
        for token in aiVoiceLockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        aiVoiceLockObservers.removeAll()
        motionJump.stop()
        microMirror.stop()
        edgeLights.stop()
        slotHotkeys.stop()
        xiaomiVoice.stop()
        remoteMicrophoneOutput.stop()
        xiaomiRemote.stop()
    }

    @discardableResult
    func perform(_ action: DashboardAction) -> Bool {
        switch action {
        case .refresh:
            threads.refresh()
            writeStatus(current, note: "status-refreshed")
            return true
        case .selectSlot(let index):
            guard isCodexHarnessActive,
                  (0..<6).contains(index),
                  rp2040.isConnected else { return false }
            buttons.selectSlot(index)
            return true
        case .approve:
            guard isCodexHarnessActive else { return false }
            return tapMicroKey("ACT07")
        case .deny:
            guard isCodexHarnessActive else { return false }
            return tapMicroKey("ACT08")
        case .toggleFastMode:
            guard isCodexHarnessActive else { return false }
            return tapMicroKey("ACT06")
        case .openThread:
            guard isCodexHarnessActive, rp2040.isConnected else { return false }
            buttons.openSelectedSlot()
            return true
        case .testHaptics(let state):
            return haptics.testFeedback(state)
        case .rescanControllers:
            xiaomiRemote.start()
            buttons.rescanControllers()
            writeStatus(current, note: "controller-discovery-started")
            return true
        }
    }

    private var isCodexHarnessActive: Bool {
        harnessProviderSettings.activeProviderID == .codex
    }

    private func configureBridge() {
        buttons.keyHandler = { [weak self] key, action in
            guard let self else { return false }
            guard action == 0 || (self.isCodexHarnessActive && !self.harnessSwitcher.isPresented && !self.aiVoice.interceptsInput) else {
                return false
            }
            return self.rp2040.sendKey(key, action: action)
        }
        buttons.joystickHandler = { [weak self] angle, distance in
            guard let self else { return false }
            if distance > 0,
               (!self.isCodexHarnessActive || self.harnessSwitcher.isPresented || self.aiVoice.interceptsInput) {
                return true
            }
            return self.rp2040.sendJoystick(angle: angle, distance: distance)
        }
        buttons.leftStickHandler = { [weak self] x, y, scrolling in
            guard let self, !self.harnessSwitcher.isPresented, !self.aiVoice.interceptsInput else { return }
            self.mouse.updateStick(x: x, y: y, scrolling: scrolling)
        }
        buttons.rightStickHandler = { [weak self] x, y in
            guard let self, !self.harnessSwitcher.isPresented, !self.aiVoice.interceptsInput else { return }
            self.mouse.updateScrollStick(x: x, y: y)
        }
        buttons.mouseButtonHandler = { [weak self] button, pressed in
            guard !pressed || self?.aiVoice.interceptsInput != true else { return }
            self?.mouse.setMouseButton(button, pressed: pressed)
        }
        buttons.systemKeyHandler = { [weak self] key, pressed in
            guard !pressed || self?.aiVoice.interceptsInput != true else { return }
            self?.mouse.setSystemKey(key, pressed: pressed)
        }
        buttons.textInputHandler = { [weak self] text in
            guard let self, !self.aiVoice.interceptsInput else { return false }
            return self.mouse.typeText(text)
        }
        buttons.mouseSpeedBoostHandler = { [weak self] active in
            self?.mouse.setSpeedBoostActive(active)
        }
        buttons.mousePrecisionHandler = { [weak self] active in
            self?.mouse.setPrecisionActive(active)
        }
        buttons.touchpadPointerHandler = { [weak self] x, y in
            guard let self, !self.harnessSwitcher.isPresented, !self.aiVoice.interceptsInput else { return }
            self.mouse.applyPointerDelta(x: x, y: y)
        }
        buttons.motionJumpInputHandler = { [weak self] id, input in
            guard let self else { return false }
            // Keep physical L2 edges flowing so a release during voice also
            // clears motion ownership. Capture may suppress starts, not edges.
            var input = input
            input.allowsGesture = input.allowsGesture && !self.aiVoice.interceptsInput
            return self.motionJump.handleInput(deviceID: id, input: input)
        }
        buttons.motionJumpCancelHandler = { [weak self] id in self?.motionJump.cancel(deviceID: id) }
        buttons.motionJumpIsCapturing = { [weak self] id in self?.motionJump.isCapturing(deviceID: id) ?? false }
        motionJump.suspendDevice = { [weak self] id in self?.buttons.suspendMotionJumpDevice(id: id) }
        motionJump.capturePointerTarget = { [weak self] in self?.mouse.captureMotionJumpTarget() }
        motionJump.canMovePointer = { [weak self] in self?.mouse.canPerformMotionJump ?? false }
        motionJump.jumpPointer = { [weak self] quadrant, target in
            self?.mouse.performMotionJump(to: quadrant, target: target) ?? false
        }
        harnessSwitcher.bind(to: buttons) { [weak self] in
            self?.presentHarnessSwitcher()
        }
        configureAIVoice()
        configureDualSenseMicrophone()
        configureExternalDualSenseAudio()
        buttons.openApplicationTargetProvider = { [weak self] family, input in
            self?.mappings.openApplicationTarget(for: input, family: family)
        }
        buttons.recordedShortcutProvider = { [weak self] family, input in
            self?.mappings.recordedShortcutConfiguration(for: input, family: family).shortcut
        }
        buttons.joyConOrientationProvider = { [weak self] family in
            self?.mappings.joyConOrientation(for: family) ?? .horizontal
        }
        mappings.onJoyConOrientationChange = { [weak self] _ in
            self?.buttons.refreshJoyConOrientation()
            // Held inputs change meaning with the grip orientation.
            self?.dashboard.clearControllerInputs()
        }
        mappings.onDisplayedDeviceRequest = { [weak self] id in
            self?.buttons.selectController(id: id)
        }
        buttons.recordedShortcutHandler = { [weak self] shortcut, pressed in
            guard !pressed || self?.aiVoice.interceptsInput != true else { return }
            self?.mouse.setRecordedShortcut(shortcut, pressed: pressed)
        }
        buttons.openApplicationHandler = { [weak self] bundleIdentifier in
            guard let self, !self.aiVoice.interceptsInput else { return false }
            return self.openApplication(bundleIdentifier: bundleIdentifier)
        }
        buttons.rightTriggerFeedbackHandler = { [weak self] family, value in
            guard let self else { return }
            if family == .xbox {
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
            self?.buttons.handleRawHomeButton(for: .dualSense, isPressed: isPressed)
        }
        adaptiveTrigger.onPSInputSample = { [weak self] sample in
            guard let self, !(self.externalDualSenseAudio.available && self.externalDualSenseAudio.connected) else { return }
            self.buttons.handleDualSensePSInput(sample)
        }
        adaptiveTrigger.onPSInputInterrupted = { [weak self] in
            guard let self, !(self.externalDualSenseAudio.available && self.externalDualSenseAudio.connected) else { return }
            self.buttons.interruptDualSensePSInput()
        }
        buttons.onSlotSelected = { [weak self] index in
            guard let self else { return }
            self.current = self.slotStates[index]
            self.haptics.announceSlot(index)
            self.writeStatus(self.current, note: "slot-selected")
        }
        buttons.onControllerChange = { [weak self] controller, family in
            guard let self else { return }
            let previousFamily = self.controllerFamily
            let selectedDeviceID = self.buttons.selectedDeviceID
            self.dashboard.clearControllerInputs()
            self.lastBatterySnapshot = nil
            self.lastJoyConBatterySnapshots.removeAll()
            self.controllerFamily = family
            // The hub's selection is the Dashboard's displayed device only.
            // Settings keeps editing its own device, and every connected
            // device keeps its mappings and trigger feedback.
            self.mappings.setDisplayedDevice(selectedDeviceID)
            // A display change does not alter the connected-controller set, so
            // the haptics connection callback is not guaranteed to run. Write
            // immediately so the dashboard reflects the displayed device.
            if self.lastStatusControllerID != selectedDeviceID ||
                previousFamily != family {
                self.writeStatus(self.current, note: "controller-selected")
            }
            self.lastStatusControllerID = selectedDeviceID
        }
        buttons.onControllerSetChange = { [weak self] controllers in
            guard let self else { return }
            self.motionJump.updateControllers(controllers)
            let dualSense = controllers.first {
                ControllerFamily.detect(controller: $0) == .dualSense
            }
            self.adaptiveTrigger.attach(dualSense)
            if !controllers.contains(where: { ControllerFamily.detect(controller: $0) == .xbox }) {
                // Reset only once no Xbox controller remains: switching the
                // displayed device must not replay feedback for a held trigger.
                self.xboxTriggerPressState = RightTriggerPressState()
            }
            self.haptics.attach(controllers)
        }
        buttons.onConnectedDevicesChange = { [weak self] devices in
            self?.mappings.setConnectedDevices(devices)
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
        joyConMotion.onStickChange = { [weak self] side, snapshot in
            self?.buttons.updateJoyConHIDStick(side: side, snapshot: snapshot)
        }
        xiaomiRemote.onConnectionChange = { [weak self] isConnected in
            guard let self else { return }
            if isConnected { self.xiaomiVoice.start() }
            else { self.xiaomiVoice.stop() }
            self.buttons.setRemoteControllerActive(isConnected)
            self.writeStatus(self.current, note: isConnected ? "xiaomi-remote-connected" : "xiaomi-remote-disconnected")
        }
        xiaomiRemote.onButtonInput = { [weak self] input, isPressed in
            guard let self else { return }
            if input == .options {
                if isPressed {
                    self.remoteMicrophoneOutput.prepareForPress()
                } else {
                    // Let the last PCM buffers reach the virtual microphone
                    // before releasing the configured dictation shortcut.
                    self.remoteMicrophoneOutput.releaseWhenFinished { [weak self] in
                        self?.buttons.handleRemoteButton(input, isPressed: false)
                    }
                    return
                }
            }
            self.buttons.handleRemoteButton(input, isPressed: isPressed)
        }
        xiaomiVoice.onStatus = { [weak self] in
            guard let self else { return }
            self.warmUpRemoteMicrophoneIfReady()
            self.writeStatus(self.current, note: "xiaomi-voice")
        }
        xiaomiVoice.onStreamEvent = { [weak self] event in
            guard let self else { return }
            self.remoteMicrophoneOutput.handle(event)
            if event == .cancelled { self.buttons.handleRemoteButton(.options, isPressed: false) }
            self.writeStatus(self.current, note: "xiaomi-voice-stream")
        }
        xiaomiVoice.onSamples = { [weak self] samples in
            self?.remoteMicrophoneOutput.append(samples)
        }
        buttons.onInputStateChange = { [weak self] input, pressed in
            self?.dashboard.setControllerInput(input, pressed: pressed)
        }
        buttons.onOperationModeChange = { [weak self] mode in
            self?.handleOperationModeChanged(mode)
        }
        haptics.onConnectionChange = { [weak self] in
            guard let self else { return }
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

    private func presentHarnessSwitcher() {
        guard !harnessSwitcher.isPresented else { return }
        let runningApplications = NSWorkspace.shared.runningApplications
        let harnessOptions = harnessProviderSettings.enabledProviders.map { provider in
            let runningApplication = runningApplications.first {
                provider.isAssociated(
                    bundleIdentifier: $0.bundleIdentifier,
                    appName: $0.localizedName,
                    applicationPath: $0.bundleURL?.path
                )
            }
            return HarnessSwitcherOption(
                configuration: provider,
                isApplicationConnected: runningApplication != nil,
                applicationIcon: runningApplication?.icon
                    ?? provider.installedApplicationURL().map { NSWorkspace.shared.icon(forFile: $0.path) }
            )
        }

        buttons.suspendMappedOutputs()
        mouse.updateStick(x: 0, y: 0, scrolling: false)
        mouse.updateScrollStick(x: 0, y: 0)
        _ = rp2040.sendJoystick(angle: 0, distance: 0)
        harnessSwitcher.present(
            options: harnessOptions + [.mainWindow(applicationIcon: NSApp.applicationIconImage)],
            current: harnessProviderSettings.activeProviderID
        ) { [weak self] target in
            switch target {
            case let .harness(providerID):
                _ = self?.confirmHarnessFromSwitcher(providerID)
            case .mainWindow:
                self?.showMainWindow()
            }
        }
    }

    private func makeDualSenseMicrophone() -> DualSenseMicrophoneSession {
        let output = dualSenseAudioOutput
        let decoder = dualSenseAudioDecoder
        let hid = adaptiveTrigger.microphoneHID
        return DualSenseMicrophoneSession(services: DualSenseMicrophoneServices(
            requestPermission: { done in
                Task { @MainActor in done(await AIVoiceAudioRecorder.requestMicrophonePermission()) }
            },
            prepareOutput: { generation, done in output.prepare(generation: generation, completion: done) },
            startHardware: { identity, generation, done in
                decoder.begin(identity: identity, generation: generation)
                return hid.beginMicrophone(identity: identity, sessionGeneration: generation, completion: done)
            },
            stopHardware: { generation, done in hid.endMicrophone(sessionGeneration: generation, completion: done) },
            finishIsolation: { hid.finishMicrophoneIsolation(identity: $0) },
            append: { pcm, generation in output.append(pcm, generation: generation) },
            drain: { generation, cutoff, done in
                decoder.freeze(generation: generation, at: cutoff) {
                    output.drain(generation: generation, completion: done)
                }
            },
            stopOutput: { generation in
                decoder.cancel(generation: generation)
                output.stop(generation: generation)
            },
            lastPacketTime: { decoder.lastPacketTime },
            setIsolation: { [weak self] isolated in
                guard let self else { return }
                self.buttons.setDualSenseMicrophoneIsolation(isolated)
                self.adaptiveTrigger.setMicrophoneIsolation(isolated)
                self.motionJump.setDualSenseMicrophoneIsolation(isolated)
                if isolated { self.harnessSwitcher.cancel() }
            },
            sendPTT: { [weak self] pressed in
                guard let self, !pressed || self.isCodexHarnessActive else { return false }
                return self.rp2040.sendKey("ACT10", action: pressed ? 1 : 0)
            },
            startIssue: { [weak self] in
                guard let self else { return "应用正在退出。" }
                guard !self.externalDualSenseAudio.available else { return "当前使用 DualSense Audio 驱动，请直接在语音应用开始录音。" }
                guard DualSenseMicrophoneFeature.isEnabled else { return "系统麦克风仍在开发验证阶段。" }
                guard self.operationMode == .mapping, !self.aiVoiceSystemSuspended else {
                    return "请返回映射模式并解锁屏幕后开始供音。"
                }
                guard !self.aiVoice.interceptsInput else { return "请先结束 Joy Harness 内部 AI 语音。" }
                guard DualSenseSystemAudioOutput.installed else { return "请先安装或更新 Joy Harness 麦克风组件。" }
                return nil
            },
            pttIssue: { [weak self] in
                guard let self, DualSenseMicrophoneFeature.isEnabled,
                      self.isCodexHarnessActive, self.rp2040.isConnected,
                      self.operationMode == .mapping, !self.harnessSwitcher.isPresented,
                      !self.aiVoice.interceptsInput, !self.aiVoiceSystemSuspended,
                      hid.microphoneAvailability.identity != nil,
                      self.buttons.connectedDevices.filter({ $0.family == .dualSense }).count == 1 else {
                    return "请切换到 Codex Harness 并连接 RP2040。"
                }
                return nil
            },
            pttInputs: { [weak self] in
                guard let self else { return [] }
                return Set(ControllerInput.allCases.filter {
                    DualSenseMicrophoneSession.supportedPTTInputs.contains($0) &&
                        self.mappings.action(for: $0, family: .dualSense) == .pushToTalk
                })
            },
            permissionGranted: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        ))
    }

    private func configureDualSenseMicrophone() {
        let session = dualSenseMicrophone
        let hid = adaptiveTrigger.microphoneHID
        hid.onMicrophoneAvailabilityChange = { [weak session] in session?.updateAvailability($0) }
        hid.onTrustedControlSample = { [weak self, weak session] sample in
            guard self?.externalDualSenseAudio.available != true else { return }
            session?.handleControl(sample)
        }
        hid.onMicrophonePacket = { [decoder = dualSenseAudioDecoder] in decoder.receive($0) }
        hid.onMicrophoneInterrupted = { [weak self, weak session] in
            guard self?.externalDualSenseAudio.available != true else { return }
            session?.recoverUnexpectedAudio()
        }
        dualSenseAudioDecoder.onPCM = { [weak session] pcm, generation, time in
            session?.receivePCM(pcm, generation: generation, timestamp: time)
        }
        dualSenseAudioDecoder.onFailure = { [weak session] generation, message in
            session?.outputFailed(generation: generation, message: message)
        }
        dualSenseAudioOutput.onFailure = dualSenseAudioDecoder.onFailure
        buttons.shouldRouteDualSensePTT = { [weak self, weak session] input in
            guard let self, let session else { return false }
            return DualSenseMicrophoneFeature.isEnabled && session.pttEnabled &&
                self.isCodexHarnessActive && hid.microphoneAvailability.identity != nil &&
                DualSenseMicrophoneSession.supportedPTTInputs.contains(input) &&
                self.mappings.action(for: input, family: .dualSense) == .pushToTalk
        }
        session.onStateChange = { [weak self] in
            guard let self else { return }
            self.dualSenseMicrophoneOverlay.update()
            if self.dualSenseMicrophone.phase == .idle, let note = self.pendingMicrophoneNativeMode {
                self.pendingMicrophoneNativeMode = nil
                self.setOperationMode(.native, note: note)
            }
        }
        session.updateAvailability(hid.microphoneAvailability)
    }

    private func configureExternalDualSenseAudio() {
        externalDualSenseAudio.onState = { [weak self] available, capturing in
            guard let self else { return }
            self.buttons.setExternalAudioState(available: available, capturing: capturing)
            self.adaptiveTrigger.setMicrophoneIsolation(capturing)
            self.motionJump.setDualSenseMicrophoneIsolation(capturing)
            if capturing { self.harnessSwitcher.cancel() }
        }
        externalDualSenseAudio.onControl = { [weak self] effect in
            guard let self else { return }
            if self.aiVoiceSystemSuspended {
                self.buttons.interruptDualSensePSInput(); return
            }
            self.buttons.handleExternalAudioControl(effect)
        }
        externalDualSenseAudio.start()
    }

    private func configureAIVoice() {
        buttons.aiVoiceEnabled = aiVoiceSettings.isEnabled
        buttons.onAIVoiceBegin = { [weak self] in
            guard let self else { return }
            guard !self.aiVoiceSystemSuspended, !self.dualSenseMicrophone.isEngaged else {
                self.buttons.cancelAIVoiceInput(); return
            }
            self.aiVoice.begin()
        }
        buttons.onAIVoiceEnd = { [weak self] in self?.aiVoice.release() }
        buttons.onAIVoiceRelease = { [weak self] timestamp in self?.aiVoice.release(at: timestamp) }
        buttons.onAIVoiceCancel = { [weak self] in
            guard let self, self.aiVoice.interceptsInput else { return }
            self.aiVoice.cancel(reason: L10n.text("手柄输入已中断，本次未发送。", "Controller input was interrupted. Nothing was sent."))
        }
        aiVoice.onUserCancel = { [weak self] in self?.buttons.cancelAIVoiceInput() }
        aiVoice.onPresentationChange = { [weak self] in self?.aiVoiceOverlay.update() }
        aiVoice.onCaptureChange = { [weak self] capturing in
            guard let self else { return }
            self.buttons.setAIVoiceCaptureActive(capturing)
            self.mouse.updateStick(x: 0, y: 0, scrolling: false)
            self.mouse.updateScrollStick(x: 0, y: 0)
            if capturing { self.harnessSwitcher.cancel() }
        }
        aiVoiceOverlay.onOpenSettings = { [weak self] in self?.aiVoiceSettingsOpener?() }
        aiVoiceSettings.onChange = { [weak self] in
            guard let self else { return }
            self.aiVoice.settingsChanged()
            self.buttons.aiVoiceEnabled = self.aiVoiceSettings.isEnabled
        }
        let switcherInput = buttons.inputInterceptor
        buttons.inputInterceptor = { [weak self] input, pressed in
            if switcherInput?(input, pressed) == true { return true }
            return self?.aiVoice.handleInput(input, pressed: pressed) ?? false
        }
        let switcherStick = buttons.overlayStickHandler
        buttons.overlayStickHandler = { [weak self] x, y in
            if self?.aiVoice.interceptsInput == true { return true }
            return switcherStick?(x, y) ?? false
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            aiVoiceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.aiVoiceSystemSuspended = true
                    self?.dualSenseMicrophone.interrupt(reason: "系统会话已暂停，已停止系统麦克风供音。")
                    self?.buttons.cancelAIVoiceInput()
                    self?.aiVoice.cancel(reason: L10n.text("系统会话已暂停，语音操作已取消。", "System session paused. Voice command cancelled."))
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            aiVoiceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                    self?.aiVoiceSystemSuspended = session?["CGSSessionScreenIsLocked"] as? Bool == true
                }
            })
        }
        aiVoiceLockObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.aiVoiceSystemSuspended = true
                self?.dualSenseMicrophone.interrupt(reason: "屏幕已锁定，已停止系统麦克风供音。")
                self?.buttons.cancelAIVoiceInput()
                self?.aiVoice.cancel(reason: L10n.text("屏幕已锁定，语音操作已取消。", "Screen locked. Voice command cancelled."))
            }
        })
        aiVoiceLockObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiVoiceSystemSuspended = false }
        })
    }

    /// Brings Joy Harness forward with its Dashboard, reopening it when it was
    /// closed. The gamepad pointer can open settings from there.
    @discardableResult
    func showMainWindow() -> Bool {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = MainWindow.find(in: NSApp.windows) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return true
        } else if let mainWindowOpener {
            mainWindowOpener()
            return true
        } else {
            return false
        }
    }

    @discardableResult
    private func confirmHarnessFromSwitcher(_ providerID: HarnessProviderID) -> Bool {
        guard harnessProviderSettings.select(providerID),
              let provider = harnessProviderSettings.provider(for: providerID) else { return false }
        if let url = provider.installedApplicationURL() {
            _ = openApplication(at: url)
        }
        return true
    }

    /// Called after the active Harness is stored, whether it changed through
    /// the switcher, the settings picker, frontmost-app matching or disabling.
    private func applyActiveHarness(_ providerID: HarnessProviderID?) {
        if dualSenseMicrophone.isPTTSession { dualSenseMicrophone.stop(reason: "Harness 已变化，已停止联动供音。") }
        // Held outputs and radial input belong to the previous mapping profile.
        buttons.suspendMappedOutputs()
        _ = rp2040.sendJoystick(angle: 0, distance: 0)
        if let providerID {
            mappings.setHarnessProvider(providerID)
        }
        print("[agent-deck] harness=\(providerID?.rawValue ?? "none")")
        guard hasStarted else { return }
        writeStatus(current, note: "harness-change: \(providerID?.rawValue ?? "none")")
    }

    func checkFrontmostAppMode() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier
        let appName = app.localizedName
        nativeGamepadAppSettings.revealDefaultApp(runningWithBundleIdentifier: bundleID)
        self.frontmostAppName = appName
        self.frontmostAppBundleID = bundleID
        if let matchedProvider = harnessProviderSettings.match(
            bundleIdentifier: bundleID,
            appName: appName,
            applicationPath: app.bundleURL?.path
        ) {
            _ = harnessProviderSettings.select(matchedProvider.id)
        }
        guard nativeGamepadAppSettings.autoSwitchEnabled else {
            if pendingMicrophoneNativeMode?.hasPrefix("auto-switch:") == true {
                pendingMicrophoneNativeMode = nil
            }
            return
        }

        let matches = nativeGamepadAppSettings.matches(runningApp: app)
        if matches, let bundleID, bundleID == manuallySuppressedNativeBundleID {
            return
        }
        if !matches {
            manuallySuppressedNativeBundleID = nil
            if pendingMicrophoneNativeMode?.hasPrefix("auto-switch:") == true {
                pendingMicrophoneNativeMode = nil
            }
        }
        guard let nextMode = OperationModeAutoSwitchPolicy.targetMode(
            currentMode: operationMode,
            frontmostMatches: matches,
            manuallyForcedNative: manuallyForcedNativeMode
        ) else {
            return
        }
        setOperationMode(
            nextMode,
            note: "auto-switch: \(appName ?? bundleID ?? (matches ? "native-app" : "mapping-app"))"
        )
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

    private func handleOperationModeChanged(_ mode: ControllerOperationMode) {
        if mode == .mapping { pendingMicrophoneNativeMode = nil }
        guard mode != operationMode else { return }
        if mode == .native, dualSenseMicrophone.isEngaged {
            manuallyForcedNativeMode = true
            // ControllerHub already changed its sessions before notifying us.
            // Restore mapping until the microphone's close barrier completes.
            buttons.setOperationMode(operationMode)
            pendingMicrophoneNativeMode = "mode-change: native"
            dualSenseMicrophone.stop(reason: "正在停止麦克风，以进入原生手柄模式。")
            return
        }
        if mode == .native { aiVoice.cancel() }
        manuallyForcedNativeMode = mode == .native
        let previousMode = operationMode
        operationMode = mode
        xiaomiRemote.setOperationMode(mode)
        motionJump.setOperationMode(mode)
        xiaomiVoice.enabled = mode == .mapping
        warmUpRemoteMicrophoneIfReady()
        if previousMode == .native && mode == .mapping {
            unfocusFrontmostNativeAppIfNeeded()
        }
        haptics.playOperationModeFeedback(mode)
        writeStatus(current, note: "mode-change: \(mode.rawValue)")
    }

    func setOperationMode(_ mode: ControllerOperationMode, note: String) {
        if mode == .mapping { pendingMicrophoneNativeMode = nil }
        guard mode != operationMode else { return }
        if mode == .native, dualSenseMicrophone.isEngaged {
            pendingMicrophoneNativeMode = note
            dualSenseMicrophone.stop(reason: "正在停止麦克风，以进入原生手柄模式。")
            return
        }
        if mode == .native { aiVoice.cancel() }
        let previousMode = operationMode
        operationMode = mode
        motionJump.setOperationMode(mode)
        xiaomiRemote.setOperationMode(mode)
        xiaomiVoice.enabled = mode == .mapping
        warmUpRemoteMicrophoneIfReady()
        buttons.setOperationMode(mode)
        if previousMode == .native && mode == .mapping && note.contains("manual") {
            unfocusFrontmostNativeAppIfNeeded()
        }
        haptics.playOperationModeFeedback(mode)
        writeStatus(current, note: note)
        print("[agent-deck] operation mode=\(mode.rawValue) note=\(note)")
    }

    private func warmUpRemoteMicrophoneIfReady(attemptsRemaining: Int = 4) {
        guard operationMode == .mapping, xiaomiVoice.isReady else { return }
        if RemoteMicrophoneOutput.installed {
            remoteMicrophoneOutput.warmUp()
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.warmUpRemoteMicrophoneIfReady(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func tapMicroKey(_ key: String) -> Bool {
        guard isCodexHarnessActive else { return false }
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
        return openApplication(at: url)
    }

    private func openApplication(at url: URL) -> Bool {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                print("[agent-deck] failed to open \(url.path): \(error.localizedDescription)")
            }
        }
        return true
    }

    private func writeStatus(_ state: PadState, note: String?) {
        let selectedSlot = buttons.selectedSlot
        let audio = ControllerAudioSupport.snapshot(for: controllerFamily)
        let remoteMicrophoneAvailable = controllerFamily == .xiaomiRemote && xiaomiVoice.isReady && RemoteMicrophoneOutput.installed
        let voiceInput = remoteMicrophoneAvailable
            ? ControllerVoiceInput(name: RemoteMicrophoneOutput.deviceName, isDefault: RemoteMicrophoneOutput.selected, transport: "BLE")
            : audio.controllerInput
        let remoteVoiceStatus: String
        if !xiaomiVoice.isReady {
            remoteVoiceStatus = xiaomiVoice.status
        } else if let failure = remoteMicrophoneOutput.failure {
            remoteVoiceStatus = failure
        } else if !RemoteMicrophoneOutput.installed {
            remoteVoiceStatus = "遥控器麦克风已连接；请在设置中启用麦克风组件"
        } else if !RemoteMicrophoneOutput.selected {
            remoteVoiceStatus = "遥控器麦克风已连接；请在设置中选择语音输入"
        } else {
            remoteVoiceStatus = xiaomiVoice.status + "（Joy Harness）"
        }
        let battery = buttons.batterySnapshot
        let slotPayload: [[String: Any]] = (0..<6).map { index in
            let thread = slotThreads[index]
            return [
                "slot": index + 1,
                "selected": index == selectedSlot,
                "thread_id": thread?.id ?? "",
                "title": thread?.title ?? "",
                "state": slotStates[index].rawValue,
            ]
        }
        let connectedDevices = buttons.connectedDevices
        let controllerConnected = !connectedDevices.isEmpty || haptics.connectedName != "none"
        let controllerName = connectedDevices.map(\.displayName).joined(separator: " + ")
            .isEmpty ? haptics.connectedName : connectedDevices.map(\.displayName).joined(separator: " + ")
        var payload: [String: Any] = [
            "edge_lights": edgeLights.diagnostics,
            "app_path": Bundle.main.bundleURL.path,
            "app_version": AppVersion.current,
            "app_pid": ProcessInfo.processInfo.processIdentifier,
            "state": state.rawValue,
            "selected_slot": selectedSlot + 1,
            "slots": slotPayload,
            "controller": controllerName,
            "controller_connected": controllerConnected,
            "controller_family": controllerFamily.rawValue,
            "controller_devices": connectedDevices.map { device in
                [
                    "id": device.id,
                    "name": device.name,
                    "family": device.family.rawValue,
                    "source": device.source.rawValue,
                    "selected": device.id == buttons.selectedDeviceID,
                ]
            },
            "controller_adaptive_trigger": adaptiveTrigger.isAvailable,
            "controller_impulse_trigger": haptics.hasRightTriggerFeedback,
            "controller_touchpad": controllerFamily == .dualSense || controllerFamily == .dualShock,
            "haptics": haptics.hasController,
            "accessibility": mouse.isAccessibilityGranted,
            "input_monitoring": mouse.isInputMonitoringGranted,
            "microphone": voiceInput != nil,
            "voice_input": voiceInput?.name ?? "",
            "voice_input_default": voiceInput?.isDefault ?? false,
            "voice_input_transport": voiceInput?.transport ?? "",
            "default_voice_input": audio.defaultInputName ?? "",
            "remote_voice_status": remoteVoiceStatus,
            "rp2040": rp2040.isConnected,
            "mode": "physical-codex-micro",
            "operation_mode": operationMode.rawValue,
            "active_harness": harnessProviderSettings.activeProviderID?.rawValue ?? "",
            "active_harness_name": harnessProviderSettings.activeProvider?.displayName ?? "",
            "frontmost_app_name": frontmostAppName ?? "",
            "frontmost_app_bundle_id": frontmostAppBundleID ?? "",
            "note": note ?? "",
            "ts": ISO8601DateFormatter().string(from: Date()),
        ]
        if let battery {
            payload["controller_battery_level"] = battery.level
            payload["controller_battery_state"] = battery.state.rawValue
        }
        if controllerFamily == .xiaomiRemote, let level = xiaomiVoice.batteryLevel {
            payload["controller_battery_level"] = level
            payload["controller_battery_state"] = "unknown"
        }
        if let joyConSnapshot {
            payload["joycon_mode"] = joyConSnapshot.mode.rawValue
            if joyConSnapshot.mode != .pair {
                payload["joycon_orientation"] = mappings.joyConOrientation(
                    for: joyConSnapshot.mode.controllerFamily
                ).rawValue
            }
            let sticks = buttons.joyConSticks
            payload["joycon_primary_stick"] = stickPayload(sticks.primary)
            payload["joycon_secondary_stick"] = stickPayload(sticks.secondary)
            payload["joycon_left_connected"] = joyConSnapshot.left != nil
            payload["joycon_right_connected"] = joyConSnapshot.right != nil
            payload["joycon_left_haptics"] = joyConSnapshot.left?.hasHaptics ?? false
            payload["joycon_right_haptics"] = joyConSnapshot.right?.hasHaptics ?? false
            payload["joycon_left_motion"] = joyConSnapshot.left?.hasMotion == true
                || joyConMotion.snapshots[.left] != nil
            payload["joycon_right_motion"] = joyConSnapshot.right?.hasMotion == true
                || joyConMotion.snapshots[.right] != nil
            payload["joycon_left_profile_elements"] = joyConSnapshot.left?.profileElements ?? []
            payload["joycon_right_profile_elements"] = joyConSnapshot.right?.profileElements ?? []
            payload["joycon_inactive_endpoints"] = joyConSnapshot.inactiveEndpointCount
            let sideBatteries = buttons.joyConBatterySnapshots
            if let left = sideBatteries[.left] {
                payload["joycon_left_battery_level"] = left.level
                payload["joycon_left_battery_state"] = left.state.rawValue
            }
            if let right = sideBatteries[.right] {
                payload["joycon_right_battery_level"] = right.level
                payload["joycon_right_battery_state"] = right.state.rawValue
            }
            if let left = joyConMotion.snapshots[.left] {
                payload["joycon_left_imu"] = motionPayload(left)
            }
            if let left = joyConMotion.stickSnapshots[.left] {
                payload["joycon_left_stick_calibration_source"] = left.calibrationSource.rawValue
            }
            if let right = joyConMotion.stickSnapshots[.right] {
                payload["joycon_right_stick_calibration_source"] = right.calibrationSource.rawValue
            }
            if let right = joyConMotion.snapshots[.right] {
                payload["joycon_right_imu"] = motionPayload(right)
            }
        }
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

    private func motionPayload(_ snapshot: JoyConHIDMotionSnapshot) -> [String: Any] {
        [
            "acceleration_g": vectorPayload(snapshot.accelerationG),
            "rotation_rate_dps": vectorPayload(snapshot.rotationRateDPS),
            "calibration_source": snapshot.calibrationSource.rawValue,
        ]
    }

    private func vectorPayload(_ vector: JoyConVector3) -> [String: Double] {
        ["x": vector.x, "y": vector.y, "z": vector.z]
    }

    private func stickPayload(_ stick: JoyConStick) -> [String: Double] {
        ["x": Double(stick.x), "y": Double(stick.y)]
    }

    private func startBatteryMonitoring() {
        lastBatterySnapshot = buttons.batterySnapshot
        lastJoyConBatterySnapshots = buttons.joyConBatterySnapshots
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snapshot = self.buttons.batterySnapshot
                let joyConSnapshots = self.buttons.joyConBatterySnapshots
                guard snapshot != self.lastBatterySnapshot ||
                        joyConSnapshots != self.lastJoyConBatterySnapshots else { return }
                self.lastBatterySnapshot = snapshot
                self.lastJoyConBatterySnapshots = joyConSnapshots
                self.writeStatus(self.current, note: "controller-battery-change")
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

    private func openEdgeLightSlot(_ index: Int) -> Bool {
        guard (0..<6).contains(index), edgeLightSettings.isMicroSynchronized, rp2040.isConnected else { return false }
        rp2040.tapSlot(index, twice: true)
        return true
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
            slotStates[index] = threadStates[threadID] ?? slotThreads[index]?.observedState ?? .idle
        }
        current = slotStates[buttons.selectedSlot]
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
            // CLI 主动请求使用有限反馈，任务状态刷新本身不驱动震动。
            if command.threadID == nil, state != .idle {
                _ = haptics.testFeedback(state)
            }
        }
    }
}

enum OperationModeAutoSwitchPolicy {
    static func targetMode(
        currentMode: ControllerOperationMode,
        frontmostMatches: Bool,
        manuallyForcedNative: Bool
    ) -> ControllerOperationMode? {
        guard !manuallyForcedNative else { return nil }
        let target: ControllerOperationMode = frontmostMatches ? .native : .mapping
        return target == currentMode ? nil : target
    }
}
