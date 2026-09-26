import AppKit
import SwiftUI

@MainActor
final class HarnessSwitcherCoordinator {
    private static let stickActivationThreshold: Float = 0.65
    private static let stickReleaseThreshold: Float = 0.30

    private let state = HarnessSwitcherState()
    private var panel: NSPanel?
    private var onCommit: ((HarnessProviderID) -> Void)?
    private var latchedStickDirection = 0

    var isPresented: Bool { state.isPresented }
    var isPanelVisible: Bool { panel?.isVisible == true }
    var selectedProviderID: HarnessProviderID? { state.selectedOption?.id }

    func present(
        options: [HarnessSwitcherOption],
        current: HarnessProviderID?,
        onCommit: @escaping (HarnessProviderID) -> Void
    ) {
        latchedStickDirection = 0
        state.present(options: options, current: current)

        guard state.isPresented else {
            self.onCommit = nil
            panel?.orderOut(nil)
            return
        }

        self.onCommit = onCommit
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, on: targetScreen())
        panel.orderFrontRegardless()
        print("[agent-deck] harness switcher presented")
        announce(
            state.selectedOption.map(announcement(for:))
                ?? L10n.text("没有已启用的 Harness", "No enabled Harnesses")
        )
    }

    func move(_ direction: Int) {
        _ = state.move(direction)
        if let option = state.selectedOption {
            print("[agent-deck] harness switcher selected=\(option.id.rawValue)")
            announce(announcement(for: option))
        }
    }

    @discardableResult
    func handleControllerInput(_ input: ControllerInput, pressed: Bool) -> Bool {
        guard state.isPresented else { return false }
        guard pressed else { return true }

        switch input {
        case .dpadLeft, .leftShoulder, .functionDpadLeft, .functionLeftShoulder:
            move(-1)
        case .dpadRight, .rightShoulder, .functionDpadRight, .functionRightShoulder:
            move(1)
        case .home, .buttonA, .functionButtonA:
            commit()
        case .buttonB, .functionButtonB:
            cancel()
        default:
            break
        }
        return true
    }

    @discardableResult
    func handleLeftStick(x: Float) -> Bool {
        guard state.isPresented else {
            latchedStickDirection = 0
            return false
        }

        let direction = if x >= Self.stickActivationThreshold {
            1
        } else if x <= -Self.stickActivationThreshold {
            -1
        } else {
            0
        }
        if direction != 0, direction != latchedStickDirection {
            latchedStickDirection = direction
            move(direction)
        } else if abs(x) <= Self.stickReleaseThreshold {
            latchedStickDirection = 0
        }
        return true
    }

    func commit() {
        guard state.isPresented else { return }
        latchedStickDirection = 0
        let selectedName = state.selectedOption?.displayName
        let selectedProvider = state.commit()
        let completion = onCommit
        onCommit = nil
        if let selectedName {
            announce(L10n.text("已选择 \(selectedName)", "Selected \(selectedName)"))
        }
        if let selectedProvider {
            completion?(selectedProvider)
        }
        panel?.orderOut(nil)
        print("[agent-deck] harness switcher committed")
    }

    func cancel() {
        guard state.isPresented else { return }
        latchedStickDirection = 0
        state.cancel()
        onCommit = nil
        announce(L10n.text("已取消 Harness 切换", "Harness switch cancelled"))
        panel?.orderOut(nil)
        print("[agent-deck] harness switcher cancelled")
    }

    private func announce(_ message: String) {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func makePanel() -> NSPanel {
        let contentRect = NSRect(
            origin: .zero,
            size: NSSize(
                width: HarnessSwitcherPanelLayout.width,
                height: HarnessSwitcherPanelLayout.height
            )
        )
        let panel = HarnessSwitcherPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.title = L10n.text("Harness 切换", "Harness Switcher")
        panel.contentViewController = NSHostingController(rootView: HarnessSwitcherView(state: state))
        return panel
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    private func announcement(for option: HarnessSwitcherOption) -> String {
        "\(option.displayName), \(option.applicationStatus.localizedDescription)"
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let origin = Self.centeredOrigin(
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
    }

    static func centeredOrigin(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        )
    }
}

private final class HarnessSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
