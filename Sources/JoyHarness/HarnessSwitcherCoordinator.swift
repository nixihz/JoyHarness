import AppKit
import SwiftUI

@MainActor
final class HarnessSwitcherCoordinator {
    private static let stickActivationThreshold: Float = 0.65
    private static let stickReleaseThreshold: Float = 0.30
    /// App or Space changes this soon after presenting are side effects of the
    /// same Home press (for example the system Game Overlay), not the user
    /// moving focus away.
    static let focusChangeGracePeriod: TimeInterval = 1.0

    private let state = HarnessSwitcherState()
    private let workspaceNotificationCenter: NotificationCenter
    private let clock: () -> TimeInterval
    private var panel: NSPanel?
    private var onCommit: ((HarnessSwitcherTarget) -> Void)?
    private var onDismiss: (() -> Void)?
    private var latchedStickDirection = 0
    private var presentedAt: TimeInterval = 0
    private var focusObservers: [NSObjectProtocol] = []
    private var clickMonitors: [Any] = []

    var isPresented: Bool { state.isPresented }
    var isPanelVisible: Bool { panel?.isVisible == true }
    var panelSize: NSSize? { panel?.frame.size }
    var selectedTarget: HarnessSwitcherTarget? { state.selectedOption?.id }

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.clock = clock
    }

    /// Routes a hub's switcher events to this overlay. The hub remembers which
    /// controller opened it and cancels the overlay when that controller leaves.
    func bind(to hub: ControllerHub, present: @escaping () -> Void) {
        hub.onHarnessSwitcherPresent = present
        hub.onHarnessSwitcherCancel = { [weak self] in
            self?.cancel()
        }
        hub.inputInterceptor = { [weak self] input, pressed in
            self?.handleControllerInput(input, pressed: pressed) ?? false
        }
        hub.overlayStickHandler = { [weak self] x, _ in
            self?.handleLeftStick(x: x) ?? false
        }
        onDismiss = { [weak hub] in
            hub?.finishHarnessSwitcher()
        }
    }

    func present(
        options: [HarnessSwitcherOption],
        current: HarnessProviderID?,
        onCommit: @escaping (HarnessSwitcherTarget) -> Void
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
        layout(panel, itemCount: state.options.count, on: targetScreen())
        panel.orderFrontRegardless()
        installFocusLossDismissal()
        print("[agent-deck] harness switcher presented")
        announce(
            state.selectedOption.map(announcement(for:))
                ?? L10n.text("没有已启用的 Harness", "No enabled Harnesses")
        )
    }

    func move(_ direction: Int) {
        _ = state.move(direction)
        if let option = state.selectedOption {
            print("[agent-deck] harness switcher selected=\(option.id)")
            announce(announcement(for: option))
        }
    }

    /// Home toggles the overlay: the press that opened it is already handled,
    /// so a later Home press dismisses without switching. A confirms, B cancels.
    @discardableResult
    func handleControllerInput(_ input: ControllerInput, pressed: Bool) -> Bool {
        guard state.isPresented else { return false }
        guard pressed else { return true }

        switch input {
        case .dpadLeft, .leftShoulder, .functionDpadLeft, .functionLeftShoulder:
            move(-1)
        case .dpadRight, .rightShoulder, .functionDpadRight, .functionRightShoulder:
            move(1)
        case .buttonA, .functionButtonA:
            commit()
        case .home, .buttonB, .functionButtonB:
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
        let selectedTarget = state.commit()
        let completion = onCommit
        onCommit = nil
        if let selectedName {
            announce(L10n.text("已选择 \(selectedName)", "Selected \(selectedName)"))
        }
        if let selectedTarget {
            completion?(selectedTarget)
        }
        dismissPanel()
        print("[agent-deck] harness switcher committed")
    }

    func cancel() {
        guard state.isPresented else { return }
        latchedStickDirection = 0
        state.cancel()
        onCommit = nil
        announce(L10n.text("已取消 Harness 切换", "Harness switch cancelled"))
        dismissPanel()
        print("[agent-deck] harness switcher cancelled")
    }

    private func dismissPanel() {
        removeFocusLossDismissal()
        panel?.orderOut(nil)
        onDismiss?()
    }

    /// The panel never takes key focus, so "losing focus" means the user
    /// clicked somewhere, switched apps, or changed Space while it was open.
    private func installFocusLossDismissal() {
        removeFocusLossDismissal()
        presentedAt = clock()

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissForFocusLoss("click")
            }
        }) {
            clickMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissForFocusLoss("click")
            }
            return event
        }) {
            clickMonitors.append(monitor)
        }

        let focusChanges: [(Notification.Name, String)] = [
            (NSWorkspace.didActivateApplicationNotification, "app-activated"),
            (NSWorkspace.activeSpaceDidChangeNotification, "space-changed"),
        ]
        focusObservers = focusChanges.map { name, reason in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.clock() - self.presentedAt >= Self.focusChangeGracePeriod else { return }
                    self.dismissForFocusLoss(reason)
                }
            }
        }
    }

    private func removeFocusLossDismissal() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
        focusObservers.forEach { workspaceNotificationCenter.removeObserver($0) }
        focusObservers.removeAll()
    }

    private func dismissForFocusLoss(_ reason: String) {
        guard state.isPresented else { return }
        print("[agent-deck] harness switcher lost focus reason=\(reason)")
        cancel()
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
                width: HarnessSwitcherPanelLayout.width(forItemCount: 0, maximumWidth: .greatestFiniteMagnitude),
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
        let hostingController = NSHostingController(rootView: HarnessSwitcherView(state: state))
        // `layout(_:itemCount:on:)` sizes the panel; the view fills it.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        return panel
    }

    /// Falls back to the screen under the gamepad-driven pointer before
    /// `NSScreen.main`, which is almost never nil and would shadow it.
    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func announcement(for option: HarnessSwitcherOption) -> String {
        "\(option.displayName), \(option.detail)"
    }

    /// Fits every card when the screen allows and centers the panel on it.
    private func layout(_ panel: NSPanel, itemCount: Int, on screen: NSScreen?) {
        let maximumWidth = screen.map {
            $0.visibleFrame.width - HarnessSwitcherPanelLayout.screenMargin * 2
        } ?? .greatestFiniteMagnitude
        let size = NSSize(
            width: HarnessSwitcherPanelLayout.width(forItemCount: itemCount, maximumWidth: maximumWidth),
            height: HarnessSwitcherPanelLayout.height
        )
        guard let screen else {
            panel.setContentSize(size)
            return
        }
        let origin = Self.centeredOrigin(panelSize: size, visibleFrame: screen.visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
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
