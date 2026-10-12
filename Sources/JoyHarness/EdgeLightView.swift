import AppKit

@MainActor
final class EdgeLightView: NSView {
    var brightness: Double = EdgeLightSettings.defaultBrightness { didSet { needsDisplay = true } }
    var slots: [EdgeLightSlot] = [] { didSet { refreshAnimation(); refreshAccessibility(); needsDisplay = true } }
    var edge: ScreenEdge = .top { didSet { needsDisplay = true; refreshAccessibility() } }
    var isHovered = false { didSet { needsDisplay = true } }
    var onHover: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onClick: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var gesture = EdgeLightPointerGesture()
    private var unavailableSlot: Int?
    private var accessibilityButtons: [EdgeLightAccessibilityButton] = []
    private let animationEpoch = ProcessInfo.processInfo.systemUptime

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        guard !gesture.isDragging else { return }
        isHovered = false
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        gesture.begin(at: NSEvent.mouseLocation, slot: slotIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if gesture.move(to: point) { onDrag?(point) }
    }

    override func mouseUp(with event: NSEvent) {
        if gesture.isDragging {
            onDragEnd?(NSEvent.mouseLocation)
            _ = gesture.end(over: nil)
        } else if let index = gesture.end(over: slotIndex(at: convert(event.locationInWindow, from: nil))) {
            onClick?(index)
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshAccessibility()
    }

    func stopAnimation() { animationTimer?.invalidate(); animationTimer = nil }

    func showUnavailable(_ index: Int) {
        unavailableSlot = index
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: L10n.text("任务暂时无法打开，请检查 Codex 连接。", "Unable to open the task. Check the Codex connection."),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.unavailableSlot = nil
            self?.needsDisplay = true
        }
    }

    private func refreshAnimation() {
        let animated = slots.contains { $0.state == .busy || $0.state == .done }
        guard animated else { stopAnimation(); return }
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 系统减少动态效果开启时不重绘动画，仍保留静态颜色和状态描述。
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.needsDisplay = true }
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func slotIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point), !slots.isEmpty else { return nil }
        let along = edge.isHorizontal ? point.x : point.y
        let length = edge.isHorizontal ? bounds.width : bounds.height
        guard length > 0 else { return nil }
        return min(slots.count - 1, max(0, Int(along / length * CGFloat(slots.count))))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isHovered {
            (dark ? NSColor.windowBackgroundColor : NSColor.controlBackgroundColor).withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let length = edge.isHorizontal ? bounds.width : bounds.height
        let stride = length / CGFloat(EdgeLightMetrics.slotCount)
        let time = ProcessInfo.processInfo.systemUptime - animationEpoch
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, slot) in slots.enumerated() {
            let along = CGFloat(index) * stride + 4
            var rect: NSRect
            switch edge {
            case .top: rect = NSRect(x: along, y: 1, width: stride - 8, height: 3)
            case .bottom: rect = NSRect(x: along, y: bounds.height - 4, width: stride - 8, height: 3)
            case .left: rect = NSRect(x: 1, y: along, width: 3, height: stride - 8)
            case .right: rect = NSRect(x: bounds.width - 4, y: along, width: 3, height: stride - 8)
            }
            let rgb = slot.colorRGB
            let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                green: CGFloat((rgb >> 8) & 255) / 255,
                                blue: CGFloat(rgb & 255) / 255, alpha: 1)
            var alpha: CGFloat = 1
            if !reduceMotion {
                if slot.state == .busy { alpha = 0.45 + 0.55 * CGFloat((sin(time * 2 * .pi / 2.6) + 1) / 2) }
                if slot.state == .done {
                    let phase = time.truncatingRemainder(dividingBy: 2.4)
                    let jump = phase < 0.5 ? CGFloat(abs(sin(phase * 4 * .pi))) * 2 : 0
                    // 灯条只向屏幕内侧轻跳，避免被窗口或显示器边界裁掉。
                    switch edge {
                    case .top: rect.origin.y += jump
                    case .bottom: rect.origin.y -= jump
                    case .left: rect.origin.x += jump
                    case .right: rect.origin.x -= jump
                    }
                }
            }
            NSGraphicsContext.saveGraphicsState()
            if !slot.isOff && slot.state != nil && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                let shadow = NSShadow()
                shadow.shadowColor = color.withAlphaComponent(0.65 * alpha * CGFloat(brightness))
                shadow.shadowBlurRadius = 7
                shadow.set()
            }
            color.withAlphaComponent(alpha * CGFloat(brightness)).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            if !dark && slot.state != nil && !slot.isOff {
                // 白色空闲灯在日间背景上仍需可辨识的轮廓。
                NSColor.black.withAlphaComponent(0.22 * CGFloat(brightness)).setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
            if slot.state == nil && slot.lightingRGB == nil {
                color.withAlphaComponent(CGFloat(brightness)).setStroke()
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.stroke()
            } else if !slot.isOff { path.fill() }
            NSGraphicsContext.restoreGraphicsState()
            if isHovered {
                let label = unavailableSlot == index ? "!" : "\(index + 1)"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                          .foregroundColor: NSColor.labelColor]
                let size = (label as NSString).size(withAttributes: attrs)
                var center = NSPoint(x: along + (stride - 8) / 2, y: bounds.midY + 3)
                switch edge {
                case .bottom: center.y = bounds.midY - 3
                case .left: center = NSPoint(x: bounds.midX + 3, y: along + (stride - 8) / 2)
                case .right: center = NSPoint(x: bounds.midX - 3, y: along + (stride - 8) / 2)
                case .top: break
                }
                (label as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    private func refreshAccessibility() {
        setAccessibilityElement(false)
        accessibilityButtons = slots.enumerated().map { index, slot in
            let button = EdgeLightAccessibilityButton()
            button.onPress = { [weak self] in self?.onClick?(index) }
            button.setAccessibilityRole(.button)
            button.setAccessibilityParent(self)
            let state = slot.isOff ? L10n.text("未分配", "Unassigned") : slot.state?.displayName ?? L10n.text("状态未知", "Status Unknown")
            button.setAccessibilityLabel(L10n.text("槽位 \(index + 1)", "Slot \(index + 1)") + "，" + slot.title + "，" + state)
            button.setAccessibilityHelp(L10n.text("点击打开任务，拖动到屏幕任意边缘。", "Click to open the task; drag to any screen edge."))
            let count = CGFloat(EdgeLightMetrics.slotCount)
            let rect = edge.isHorizontal
                ? NSRect(x: CGFloat(index) * bounds.width / count, y: 0, width: bounds.width / count, height: bounds.height)
                : NSRect(x: 0, y: CGFloat(index) * bounds.height / count, width: bounds.width, height: bounds.height / count)
            button.setAccessibilityFrame(window?.convertToScreen(convert(rect, to: nil)) ?? .zero)
            return button
        }
        setAccessibilityChildren(accessibilityButtons)
    }
}

private final class EdgeLightAccessibilityButton: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
