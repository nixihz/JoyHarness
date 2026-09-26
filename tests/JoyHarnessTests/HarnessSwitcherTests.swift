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

        #expect(state.selectedOption?.id == .claude)
        #expect(state.move(1) == .cursor)
        #expect(state.move(1) == .codex)
        #expect(state.move(-1) == .cursor)
    }

    @Test func repeatedPresentationReplacesThePreviousSession() {
        let state = HarnessSwitcherState()
        state.present(options: options([.codex, .claude]), current: .codex)
        _ = state.move(1)

        state.present(options: options([.cursor, .pi]), current: .pi)

        #expect(state.isPresented)
        #expect(state.options.map(\.id) == [.cursor, .pi])
        #expect(state.selectedOption?.id == .pi)
    }

    @Test func commitReturnsTheMovedSelectionAndClosesTheSession() {
        let state = HarnessSwitcherState()
        state.present(options: options([.codex, .claude]), current: .codex)
        _ = state.move(1)

        #expect(state.commit() == .claude)
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

    @Test func panelCentersInsideAnOffsetVisibleFrame() {
        let origin = HarnessSwitcherCoordinator.centeredOrigin(
            panelSize: NSSize(width: 568, height: 152),
            visibleFrame: NSRect(x: 300, y: 200, width: 1_600, height: 900)
        )

        #expect(origin == NSPoint(x: 816, y: 574))
    }

    @Test func coordinatorShowsARealPanelAndKeepsItVisibleUntilCommit() {
        let coordinator = HarnessSwitcherCoordinator()
        var committed: HarnessProviderID?

        coordinator.present(
            options: options([.codex, .claude]),
            current: .codex
        ) { committed = $0 }

        #expect(coordinator.isPresented)
        #expect(coordinator.isPanelVisible)
        coordinator.move(1)
        coordinator.commit()
        #expect(committed == .claude)
        #expect(!coordinator.isPresented)
        #expect(!coordinator.isPanelVisible)
    }

    @Test func releasingHomeKeepsThePanelOpenAndShouldersMoveExactlyOneItemPerPress() {
        let coordinator = HarnessSwitcherCoordinator()
        var committed: HarnessProviderID?
        coordinator.present(
            options: options([.codex, .claude, .cursor]),
            current: .codex
        ) { committed = $0 }

        #expect(coordinator.handleControllerInput(.home, pressed: false))
        #expect(coordinator.isPresented)
        #expect(coordinator.isPanelVisible)

        #expect(coordinator.handleControllerInput(.rightShoulder, pressed: true))
        #expect(coordinator.selectedProviderID == .claude)
        #expect(coordinator.handleControllerInput(.rightShoulder, pressed: false))
        #expect(coordinator.selectedProviderID == .claude)

        #expect(coordinator.handleControllerInput(.leftShoulder, pressed: true))
        #expect(coordinator.selectedProviderID == .codex)
        #expect(coordinator.handleControllerInput(.leftShoulder, pressed: false))
        #expect(coordinator.selectedProviderID == .codex)

        #expect(coordinator.handleControllerInput(.buttonA, pressed: true))
        #expect(committed == .codex)
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
        #expect(coordinator.selectedProviderID == .codex)

        #expect(coordinator.handleLeftStick(x: 0.72))
        #expect(coordinator.selectedProviderID == .claude)
        #expect(coordinator.handleLeftStick(x: 1.0))
        #expect(coordinator.selectedProviderID == .claude)
        #expect(coordinator.handleLeftStick(x: 0.40))
        #expect(coordinator.selectedProviderID == .claude)

        #expect(coordinator.handleLeftStick(x: 0.20))
        #expect(coordinator.handleLeftStick(x: 0.72))
        #expect(coordinator.selectedProviderID == .cursor)

        #expect(coordinator.handleLeftStick(x: 0))
        #expect(coordinator.handleLeftStick(x: -0.72))
        #expect(coordinator.selectedProviderID == .claude)
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
            ) { providerID in
                guard settings.select(providerID) else { return }
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
        #expect(mappings.action(for: .leftShoulder) == .disabled)
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
            ) { providerID in
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

        #expect(coordinator.selectedProviderID == .cursor)

        gamepad.leftThumbstick.xAxis.setValue(0.8)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)
        gamepad.leftThumbstick.xAxis.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.leftThumbstick.xAxis)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(coordinator.selectedProviderID == .codex)
        coordinator.cancel()
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
