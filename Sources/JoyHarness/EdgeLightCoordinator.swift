import AppKit

@MainActor
final class EdgeLightCoordinator {
    private let settings: EdgeLightSettings
    private let ink = EdgeLightInkOverlay()
    private var panel: EdgeLightPanel?
    private var lightView: EdgeLightView?
    private var observers: [NSObjectProtocol] = []
    private var slots = (0..<6).map { EdgeLightSlot(identity: "slot-\($0)", title: "", state: nil) }
    private var dragging = false
    var onOpenSlot: ((Int) -> Bool)?

    init(settings: EdgeLightSettings) { self.settings = settings }

    var diagnostics: [String: Any] {
        let frame = panel?.frame ?? .zero
        return [
            "completion_effect": settings.completionEffect.rawValue,
            "ink_plumes": ink.activeCount,
            "source": "micro-feature-report",
            "synchronized": settings.isMicroSynchronized,
            "enabled": settings.isEnabled,
            "brightness": settings.brightness,
            "visible": panel?.isVisible ?? false,
            "window_id": panel?.windowNumber ?? -1,
            "edge": settings.placement.edge.rawValue,
            "hovered": lightView?.isHovered ?? false,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "states": slots.map { $0.state?.rawValue ?? "unknown" },
        ]
    }

    func start() {
        ink.effect = settings.completionEffect
        settings.onEffectChange = { [weak self] effect in self?.ink.effect = effect }
        settings.onPreview = { [weak self] in
            guard let self, self.settings.isEnabled else { return }
            self.ink.preview()
        }
        settings.onChange = { [weak self] in self?.refreshVisibility() }
        settings.onBrightnessChange = { [weak self] brightness in
            self?.lightView?.brightness = brightness
            self?.ink.brightness = brightness
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layout() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layout()
                if self?.settings.isEnabled == true { self?.panel?.orderFrontRegardless() }
            }
        })
        refreshVisibility()
    }

    func stop() {
        settings.onEffectChange = nil
        settings.onPreview = nil
        settings.onChange = nil
        settings.onBrightnessChange = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        ink.stop()
        lightView?.stopAnimation()
        panel?.orderOut(nil)
        panel = nil
        lightView = nil
    }

    func update(_ slots: [EdgeLightSlot]) {
        guard slots.count == EdgeLightMetrics.slotCount else { return }
        self.slots = slots
        ink.update(slots, enabled: settings.isEnabled && !dragging)
        guard settings.isEnabled else { return }
        lightView?.slots = self.slots
    }

    private func refreshVisibility() {
        guard settings.isEnabled else {
            ink.cancel()
            lightView?.stopAnimation()
            panel?.orderOut(nil)
            return
        }
        if panel == nil { makePanel() }
        lightView?.isHovered = false
        layout()
        lightView?.slots = slots
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let panel = EdgeLightPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        panel.title = L10n.text("Codex 屏幕状态灯", "Codex Screen Lights")
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        let view = EdgeLightView()
        view.brightness = settings.brightness
        view.slots = slots
        view.onHover = { [weak self] in
            guard self?.dragging != true else { return }
            self?.layout()
        }
        view.onDrag = { [weak self] point in self?.drag(to: point) }
        view.onDragEnd = { [weak self] point in
            self?.drag(to: point)
            self?.dragging = false
            self?.lightView?.isHovered = false
            self?.layout()
        }
        view.onClick = { [weak self] index in
            guard let self else { return }
            if self.onOpenSlot?(index) == true {
                // 点击即停止颜料，不必等待原生已读回传；灯色仍由原生状态决定。
                self.ink.acknowledge(slot: index)
            } else {
                self.lightView?.showUnavailable(index)
            }
        }
        panel.contentView = view
        self.panel = panel
        lightView = view
    }

    private func screen() -> NSScreen? {
        NSScreen.screens.first { Self.displayID($0) == settings.placement.displayID }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    private func layout() {
        guard let screen = screen(), let panel, let lightView else { return }
        let placement = settings.placement
        ink.brightness = settings.brightness
        lightView.edge = placement.edge
        panel.setFrame(placement.frame(in: screen.visibleFrame, expanded: lightView.isHovered), display: true)
        ink.place(source: panel.frame, screen: screen.visibleFrame, edge: placement.edge)
    }

    private func drag(to point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? screen() else { return }
        ink.cancel()
        dragging = true
        settings.placement = .snapped(to: point, in: screen.visibleFrame, displayID: Self.displayID(screen))
        lightView?.isHovered = true
        layout()
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class EdgeLightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
