import AppKit
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
                mappingStore: appDelegate.runtime.mappings
            )
                .environmentObject(languageSettings)
                .environmentObject(settingsCoordinator)
                .environment(\.locale, languageSettings.locale)
                .mainWindowChrome()
                .exposeOpenMainWindow { [runtime = appDelegate.runtime] openMainWindow in
                    runtime.mainWindowOpener = openMainWindow
                }
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
                nativeModeSettings: appDelegate.runtime.nativeGamepadAppSettings,
                harnessProviderSettings: appDelegate.runtime.harnessProviderSettings,
                settingsCoordinator: settingsCoordinator,
                slotShortcutSettings: appDelegate.runtime.slotShortcutSettings
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

    /// SwiftUI leaves a Dock click doing nothing once the Dashboard is
    /// closed, since Joy Harness keeps running; reopen it here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard MainWindow.find(in: NSApp.windows)?.isVisible != true else { return true }
        runtime.showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stopHotkeys()
    }
}

@MainActor
final class JoyHarnessRuntime {
    let slotShortcutSettings = SlotShortcutSettings()
    let dashboard: DashboardStore
    let mappings: ControllerMappingStore
    let scrollDirectionSettings: ScrollDirectionSettings
    let pointerSensitivitySettings: PointerSensitivitySettings
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
        harnessProviderSettings.onSelectionRequest = { [weak self] providerID in
            self?.selectHarness(providerID) ?? false
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
        print("[agent-deck] ready - left stick=pointer, right stick=scroll, L3=speed boost, touchpad=slow slide, LT+left stick=scroll, LT+face=Codex actions")
    }

    private func registerSlotHotkeys() {
        slotShortcutSettings.errors = slotHotkeys.start(shortcuts: slotShortcutSettings.shortcuts)
    }

    func stopHotkeys() {
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
            guard action == 0 || (self.isCodexHarnessActive && !self.harnessSwitcher.isPresented) else {
                return false
            }
            return self.rp2040.sendKey(key, action: action)
        }
        buttons.joystickHandler = { [weak self] angle, distance in
            guard let self else { return false }
            if distance > 0,
               (!self.isCodexHarnessActive || self.harnessSwitcher.isPresented) {
                return true
            }
            return self.rp2040.sendJoystick(angle: angle, distance: distance)
        }
        buttons.leftStickHandler = { [weak self] x, y, scrolling in
            guard let self, !self.harnessSwitcher.isPresented else { return }
            self.mouse.updateStick(x: x, y: y, scrolling: scrolling)
        }
        buttons.rightStickHandler = { [weak self] x, y in
            guard let self, !self.harnessSwitcher.isPresented else { return }
            self.mouse.updateScrollStick(x: x, y: y)
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
            guard let self, !self.harnessSwitcher.isPresented else { return }
            self.mouse.applyPointerDelta(x: x, y: y)
        }
        harnessSwitcher.bind(to: buttons) { [weak self] in
            self?.presentHarnessSwitcher()
        }
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
            self?.mouse.setRecordedShortcut(shortcut, pressed: pressed)
        }
        buttons.openApplicationHandler = { [weak self] bundleIdentifier in
            self?.openApplication(bundleIdentifier: bundleIdentifier) ?? false
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
        buttons.onSlotSelected = { [weak self] index in
            guard let self else { return }
            self.current = self.slotStates[index]
            self.haptics.announceSlot(index, state: self.current)
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

    private func presentHarnessSwitcher() {
        guard !harnessSwitcher.isPresented else { return }
        let runningApplications = NSWorkspace.shared.runningApplications
        let harnessOptions = harnessProviderSettings.enabledProviders.map { provider in
            let runningApplication = runningApplications.first {
                provider.isAssociated(bundleIdentifier: $0.bundleIdentifier, appName: $0.localizedName)
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
                _ = self?.selectHarness(providerID)
            case .mainWindow:
                self?.showMainWindow()
            }
        }
    }

    /// Brings Joy Harness forward with its Dashboard, reopening it when it was
    /// closed. The gamepad pointer can open settings from there.
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = MainWindow.find(in: NSApp.windows) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let mainWindowOpener {
            mainWindowOpener()
        } else {
            print("[agent-deck] main window unavailable: it has not appeared since launch")
        }
    }

    @discardableResult
    private func selectHarness(_ providerID: HarnessProviderID) -> Bool {
        guard harnessProviderSettings.select(providerID),
              let provider = harnessProviderSettings.provider(for: providerID) else { return false }
        if provider.activateApplicationOnSelection,
           let bundleIdentifier = provider.bundleIdentifier {
            _ = openApplication(bundleIdentifier: bundleIdentifier)
        }
        return true
    }

    /// Called after the active Harness is stored, whether it changed through
    /// the switcher, the settings picker, frontmost-app matching or disabling.
    private func applyActiveHarness(_ providerID: HarnessProviderID?) {
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
            appName: appName
        ) {
            _ = harnessProviderSettings.select(matchedProvider.id)
        }
        guard nativeGamepadAppSettings.autoSwitchEnabled else { return }

        let matches = nativeGamepadAppSettings.matches(runningApp: app)
        if matches, let bundleID, bundleID == manuallySuppressedNativeBundleID {
            return
        }
        if !matches {
            manuallySuppressedNativeBundleID = nil
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
        guard mode != operationMode else { return }
        manuallyForcedNativeMode = mode == .native
        let previousMode = operationMode
        operationMode = mode
        xiaomiRemote.setOperationMode(mode)
        xiaomiVoice.enabled = mode == .mapping
        warmUpRemoteMicrophoneIfReady()
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
