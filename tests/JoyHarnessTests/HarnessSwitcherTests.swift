import AppKit
import GameController
import Testing
@testable import JoyHarness

@MainActor
struct HarnessSwitcherTests {
    @Test func selectionStartsAtCurrentProviderAndWrapsInBothDirections() {
        let state = HarnessSwitcherState()
        state.present(
            options: options([.codex, .claude, .cursor]),
            current: .claude
        )

        #expect(state.selectedOption?.id == .harness(.claude))
        #expect(state.move(1) == .harness(.cursor))
        #expect(state.move(1) == .harness(.codex))
        #expect(state.move(-1) == .harness(.cursor))
    }

    @Test func repeatedPresentationReplacesThePreviousSession() {
        let state = HarnessSwitcherState()
        state.present(options: options([.codex, .claude]), current: .codex)
        _ = state.move(1)

        state.present(options: options([.cursor, .antigravity]), current: .antigravity)

        #expect(state.isPresented)
        #expect(state.options.map(\.id) == [.harness(.cursor), .harness(.antigravity)])
        #expect(state.selectedOption?.id == .harness(.antigravity))
    }

    @Test func commitReturnsTheMovedSelectionAndClosesTheSession() {
        let state = HarnessSwitcherState()
        state.present(options: options([.codex, .claude]), current: .codex)
        _ = state.move(1)

        #expect(state.commit() == .harness(.claude))
        #expect(!state.isPresented)
        #expect(state.commit() == nil)
    }

    @Test func cancelPreventsACommitFromEscaping() {
        let state = HarnessSwitcherState()
        state.present(options: options([.codex, .claude]), current: .codex)

        state.cancel()

        #expect(!state.isPresented)
        #expect(state.commit() == nil)
    }

    @Test func emptyOptionsOpenAClosableEmptyState() {
        let state = HarnessSwitcherState()

        state.present(options: [], current: .codex)

        #expect(state.isPresented)
        #expect(state.selectedOption == nil)
        #expect(state.commit() == nil)
        #expect(!state.isPresented)
    }

    @Test func mainWindowCardSitsBetweenTheLastAndFirstHarnessAndCommitsMainWindow() {
        let state = HarnessSwitcherState()
        state.present(
            options: options([.codex, .claude]) + [.mainWindow()],
            current: .claude
        )

        #expect(state.move(1) == .mainWindow)
        #expect(state.move(1) == .harness(.codex))
        #expect(state.move(-1) == .mainWindow)
        #expect(state.commit() == .mainWindow)
    }

    @Test func mainWindowCardStaysReachableWithoutEnabledHarnesses() {
        let state = HarnessSwitcherState()

        state.present(options: [.mainWindow()], current: .codex)

        #expect(state.selectedOption?.id == .mainWindow)
        #expect(state.commit() == .mainWindow)
    }

    @Test func mainWindowLookupSkipsClosedDashboardsAndTheSettingsWindow() {
        func window(titled title: String) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.title = title
            return window
        }
        let settings = window(titled: "Joy Harness Settings")
        let closedDashboard = window(titled: MainWindow.title)
        let dashboard = window(titled: MainWindow.title)
        settings.orderFrontRegardless()
        defer { settings.orderOut(nil); dashboard.orderOut(nil) }
        let windows = [settings, closedDashboard, dashboard]

        // Nothing but Settings is on screen: the Dashboard must be reopened.
        #expect(MainWindow.find(in: windows) == nil)

        dashboard.orderFrontRegardless()
        #expect(MainWindow.find(in: windows) === dashboard)
    }

    @Test func panelCentersInsideAnOffsetVisibleFrame() {
        let origin = HarnessSwitcherCoordinator.centeredOrigin(
            panelSize: NSSize(width: 568, height: 152),
            visibleFrame: NSRect(x: 300, y: 200, width: 1_600, height: 900)
        )

        #expect(origin == NSPoint(x: 816, y: 574))
    }

    @Test func panelFitsEveryCardInsteadOfClippingTheOuterOnes() throws {
        let coordinator = HarnessSwitcherCoordinator()
        let ids = HarnessProviderID.allCases
        coordinator.present(options: options(ids), current: .codex) { _ in }
        defer { coordinator.cancel() }

        let size = try #require(coordinator.panelSize)
        let count = CGFloat(ids.count)
        let cardsWidth = count * HarnessSwitcherPanelLayout.itemWidth
            + (count - 1) * HarnessSwitcherPanelLayout.itemSpacing
            + HarnessSwitcherPanelLayout.contentPadding * 2

        #expect(size.width >= cardsWidth)
    }

    @Test func panelWidthStopsAtTheScreenLimit() {
        #expect(HarnessSwitcherPanelLayout.width(forItemCount: 20, maximumWidth: 800) == 800)
    }

    @Test func coordinatorShowsARealPanelAndKeepsItVisibleUntilCommit() {
        let coordinator = HarnessSwitcherCoordinator()
        var committed: HarnessSwitcherTarget?

        coordinator.present(
            options: options([.codex, .claude]),
            current: .codex
        ) { committed = $0 }

        #expect(coordinator.isPresented)
        #expect(coordinator.isPanelVisible)
        coordinator.move(1)
        coordinator.commit()
        #expect(committed == .harness(.claude))
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
    }

    @Test func releasingHomeKeepsThePanelOpenAndShouldersMoveExactlyOneItemPerPress() {
        let coordinator = HarnessSwitcherCoordinator()
        var committed: HarnessSwitcherTarget?
        coordinator.present(
            options: options([.codex, .claude, .cursor]),
            current: .codex
        ) { committed = $0 }

        #expect(coordinator.handleControllerInput(.home, pressed: false))
        #expect(coordinator.isPresented)
        #expect(coordinator.isPanelVisible)

        #expect(coordinator.handleControllerInput(.rightShoulder, pressed: true))
        #expect(coordinator.selectedTarget == .harness(.claude))
        #expect(coordinator.handleControllerInput(.rightShoulder, pressed: false))
        #expect(coordinator.selectedTarget == .harness(.claude))

        #expect(coordinator.handleControllerInput(.leftShoulder, pressed: true))
        #expect(coordinator.selectedTarget == .harness(.codex))
        #expect(coordinator.handleControllerInput(.leftShoulder, pressed: false))
        #expect(coordinator.selectedTarget == .harness(.codex))

        #expect(coordinator.handleControllerInput(.buttonA, pressed: true))
        #expect(committed == .harness(.codex))
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
    }

    @Test func leftStickUsesActivationAndReleaseThresholdsWithoutOvershooting() {
        let coordinator = HarnessSwitcherCoordinator()
        coordinator.present(
            options: options([.codex, .claude, .cursor]),
            current: .codex
        ) { _ in }

        #expect(coordinator.handleLeftStick(x: 0.60))
        #expect(coordinator.selectedTarget == .harness(.codex))

        #expect(coordinator.handleLeftStick(x: 0.72))
        #expect(coordinator.selectedTarget == .harness(.claude))
        #expect(coordinator.handleLeftStick(x: 1.0))
        #expect(coordinator.selectedTarget == .harness(.claude))
        #expect(coordinator.handleLeftStick(x: 0.40))
        #expect(coordinator.selectedTarget == .harness(.claude))

        #expect(coordinator.handleLeftStick(x: 0.20))
        #expect(coordinator.handleLeftStick(x: 0.72))
        #expect(coordinator.selectedTarget == .harness(.cursor))

        #expect(coordinator.handleLeftStick(x: 0))
        #expect(coordinator.handleLeftStick(x: -0.72))
        #expect(coordinator.selectedTarget == .harness(.claude))
    }

    @Test func controllerConfirmationChangesTheActiveHarnessAndMappingProfile() throws {
        let suiteName = "HarnessSwitcherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        let mappings = ControllerMappingStore(
            userDefaults: defaults,
            storageKey: "controllerMappings.test",
            harnessProvider: .codex
        )
        let coordinator = HarnessSwitcherCoordinator()
        let bridge = ButtonBridge { input in mappings.action(for: input) }

        bridge.onHarnessSwitcherPresent = {
            coordinator.present(
                options: self.options([.codex, .claude, .cursor]),
                current: settings.activeProviderID
            ) { target in
                guard case let .harness(providerID) = target,
                      settings.select(providerID) else { return }
                mappings.setHarnessProvider(providerID)
            }
        }
        bridge.inputInterceptor = { input, pressed in
            coordinator.handleControllerInput(input, pressed: pressed)
        }

        bridge.applyJoyConSnapshot(snapshot(pressing: .home))
        bridge.applyJoyConSnapshot(.neutral)
        bridge.applyJoyConSnapshot(snapshot(pressing: .rightShoulder))
        bridge.applyJoyConSnapshot(.neutral)
        bridge.applyJoyConSnapshot(snapshot(pressing: .buttonA))

        #expect(!coordinator.isPresented)
        #expect(settings.activeProviderID == .claude)
        #expect(mappings.harnessProvider == .claude)
        #expect(mappings.action(for: .leftShoulder) == .claudePreviousSession)
    }

    @Test func standardGameControllerShoulderAndFaceButtonCommitTheSelection() async throws {
        let suiteName = "HarnessSwitcherTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HarnessProviderSettings(userDefaults: defaults)
        let coordinator = HarnessSwitcherCoordinator()
        let bridge = ButtonBridge()
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        var interceptedInputs: [(ControllerInput, Bool)] = []

        bridge.onHarnessSwitcherPresent = {
            coordinator.present(
                options: self.options([.codex, .claude, .cursor]),
                current: settings.activeProviderID
            ) { target in
                guard case let .harness(providerID) = target else { return }
                _ = settings.select(providerID)
            }
        }
        bridge.inputInterceptor = { input, pressed in
            interceptedInputs.append((input, pressed))
            return coordinator.handleControllerInput(input, pressed: pressed)
        }
        bridge.attachController(controller)

        bridge.handleRawHomeButton(isPressed: true)
        bridge.handleRawHomeButton(isPressed: false)
        gamepad.rightShoulder.setValue(1)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightShoulder)
        gamepad.rightShoulder.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.rightShoulder)
        gamepad.buttonA.setValue(1)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)
        gamepad.buttonA.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonA)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(!coordinator.isPresented)
        #expect(settings.activeProviderID == .claude)
        #expect(interceptedInputs.contains { $0 == (.rightShoulder, true) })
        #expect(interceptedInputs.contains { $0 == (.buttonA, true) })
    }

    @Test func standardControllerStickReversalMovesWithoutReturningToCenter() async throws {
        let coordinator = HarnessSwitcherCoordinator()
        let bridge = ButtonBridge()
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        bridge.onHarnessSwitcherPresent = {
            coordinator.present(
                options: self.options([.codex, .claude, .cursor]),
                current: .codex
            ) { _ in }
        }
        bridge.inputInterceptor = { input, pressed in
            coordinator.handleControllerInput(input, pressed: pressed)
        }
        bridge.overlayStickHandler = { x, _ in
            coordinator.handleLeftStick(x: x)
        }
        bridge.attachController(controller)

        bridge.handleRawHomeButton(isPressed: true)
        bridge.handleRawHomeButton(isPressed: false)
        gamepad.leftThumbstick.xAxis.setValue(-0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(coordinator.selectedTarget == .harness(.cursor))

        gamepad.leftThumbstick.xAxis.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(coordinator.selectedTarget == .harness(.codex))
        coordinator.cancel()
    }

    @Test func disconnectingTheOwningControllerClosesTheBoundPanel() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        defer { hub.stop() }
        let coordinator = HarnessSwitcherCoordinator()
        coordinator.bind(to: hub) {
            coordinator.present(options: self.options([.codex, .claude]), current: .codex) { _ in }
        }
        hub.setRemoteControllerActive(true)

        hub.handleRawHomeButton(isPressed: true)
        #expect(coordinator.isPresented)
        #expect(coordinator.isPanelVisible)

        hub.setRemoteControllerActive(false)

        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
    }

    @Test func homeTogglesTheBoundPanelAndOnlyAConfirms() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        defer { hub.stop() }
        let coordinator = HarnessSwitcherCoordinator(workspaceNotificationCenter: NotificationCenter())
        var presentations = 0
        var committed: [HarnessSwitcherTarget] = []
        coordinator.bind(to: hub) {
            presentations += 1
            coordinator.present(options: self.options([.codex, .claude]), current: .codex) {
                committed.append($0)
            }
        }
        hub.setRemoteControllerActive(true)

        hub.handleRawHomeButton(isPressed: true)
        hub.handleRawHomeButton(isPressed: false)
        hub.handleRemoteButton(.buttonA, isPressed: true)
        hub.handleRemoteButton(.buttonA, isPressed: false)

        #expect(committed == [.harness(.codex)])
        #expect(!coordinator.isPresented)

        hub.handleRawHomeButton(isPressed: true)
        hub.handleRawHomeButton(isPressed: false)

        #expect(presentations == 2)
        #expect(coordinator.isPresented)

        // The next Home press closes the panel without switching.
        hub.handleRawHomeButton(isPressed: true)
        hub.handleRawHomeButton(isPressed: false)

        #expect(presentations == 2)
        #expect(committed == [.harness(.codex)])
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)

        hub.handleRawHomeButton(isPressed: true)

        #expect(presentations == 3)
        #expect(coordinator.isPresented)
        coordinator.cancel()
    }

    @Test func leftShoulderFromTheFirstHarnessReachesTheMainWindowCardAndAOpensIt() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        defer { hub.stop() }
        let coordinator = HarnessSwitcherCoordinator(workspaceNotificationCenter: NotificationCenter())
        var committed: [HarnessSwitcherTarget] = []
        coordinator.bind(to: hub) {
            coordinator.present(
                options: self.options([.codex, .claude]) + [.mainWindow()],
                current: .codex
            ) {
                committed.append($0)
            }
        }
        hub.setRemoteControllerActive(true)

        hub.handleRawHomeButton(isPressed: true)
        hub.handleRawHomeButton(isPressed: false)
        hub.handleRemoteButton(.leftShoulder, isPressed: true)
        hub.handleRemoteButton(.leftShoulder, isPressed: false)

        #expect(coordinator.selectedTarget == .mainWindow)

        hub.handleRemoteButton(.buttonA, isPressed: true)
        hub.handleRemoteButton(.buttonA, isPressed: false)

        #expect(committed == [.mainWindow])
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
    }

    @Test func dualSenseRawHomeOpensThePanelBeforeGameControllerListsThePad() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        defer { hub.stop() }
        let coordinator = HarnessSwitcherCoordinator(workspaceNotificationCenter: NotificationCenter())
        coordinator.bind(to: hub) {
            coordinator.present(options: self.options([.codex, .claude]), current: .codex) { _ in }
        }
        hub.setRemoteControllerActive(true)

        hub.handleRawHomeButton(for: .dualSense, isPressed: true)

        #expect(coordinator.isPresented)
        coordinator.cancel()
    }

    @Test func switchingAppsClosesThePanelOnlyAfterTheOpeningPressSettles() {
        let hub = ControllerHub { family, input in
            ControllerMappingStore.defaultMappings(for: family)[input] ?? .disabled
        }
        defer { hub.stop() }
        let workspace = NotificationCenter()
        var now: TimeInterval = 100
        let coordinator = HarnessSwitcherCoordinator(
            workspaceNotificationCenter: workspace,
            clock: { now }
        )
        var presentations = 0
        var committed: [HarnessSwitcherTarget] = []
        coordinator.bind(to: hub) {
            presentations += 1
            coordinator.present(options: self.options([.codex, .claude]), current: .codex) {
                committed.append($0)
            }
        }
        hub.setRemoteControllerActive(true)

        hub.handleRawHomeButton(isPressed: true)
        hub.handleRawHomeButton(isPressed: false)

        // The Home press itself may bring up the system game overlay.
        now += 0.3
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(coordinator.isPresented)

        now += HarnessSwitcherCoordinator.focusChangeGracePeriod
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
        #expect(committed.isEmpty)

        // Dismissal releases the hub, so the next Home press reopens it.
        hub.handleRawHomeButton(isPressed: true)
        #expect(presentations == 2)
        #expect(coordinator.isPresented)

        // Observers from the dismissed presentation are gone; a late
        // notification is judged against the new presentation's grace period.
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(coordinator.isPresented)
        coordinator.cancel()
    }

    @Test func installedApplicationIsFoundByBundleIdentifierThenByName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSwitcherTests.\(UUID().uuidString)", isDirectory: true)
        let claudeApp = directory.appendingPathComponent("Claude.app", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registered = URL(fileURLWithPath: "/Registered/Claude.app", isDirectory: true)

        var claude = try #require(HarnessProviderSettings.defaultProviders.first { $0.id == .claude })
        claude.bundleIdentifier = " com.anthropic.claudefordesktop "

        #expect(claude.installedApplicationURL(
            urlForBundleIdentifier: { $0 == "com.anthropic.claudefordesktop" ? registered : nil },
            applicationDirectories: [directory]
        ) == registered)

        // Launch Services does not know it; the configured name still does.
        #expect(claude.installedApplicationURL(
            urlForBundleIdentifier: { _ in nil },
            applicationDirectories: [directory]
        ) == claudeApp)

        claude.appName = "Claude Beta"
        #expect(claude.installedApplicationURL(
            urlForBundleIdentifier: { _ in nil },
            applicationDirectories: [directory]
        ) == nil)

        var unassociated = try #require(HarnessProviderSettings.defaultProviders.first { $0.id == .cursor })
        unassociated.bundleIdentifier = nil
        unassociated.appName = nil
        #expect(unassociated.installedApplicationURL(
            urlForBundleIdentifier: { _ in registered },
            applicationDirectories: [directory]
        ) == nil)
    }

    private func snapshot(pressing input: ControllerInput) -> JoyConInputSnapshot {
        JoyConInputSnapshot(
            buttons: [input: true],
            primaryStick: .neutral,
            secondaryStick: .neutral
        )
    }

    private func options(_ ids: [HarnessProviderID]) -> [HarnessSwitcherOption] {
        ids.map {
            HarnessSwitcherOption(
                id: $0,
                displayName: $0.rawValue.capitalized,
                systemImage: "circle",
                isApplicationConnected: true
            )
        }
    }
}
