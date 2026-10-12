import AppKit

struct EdgeLightInkPlume: Equatable {
    let slot: Int
    let identity: String
    let startedAt: TimeInterval
    var effect: EdgeLightCompletionEffect? = nil
    static let emissionDuration: TimeInterval = 3
    static let lifetime: TimeInterval = emissionDuration + particleLifetime
    static let particleLifetime: TimeInterval = 8
    static let emissionInterval: TimeInterval = 0.13

    func particles(at elapsed: TimeInterval) -> [(index: Int, emission: Double, age: Double)] {
        guard elapsed.isFinite, elapsed >= 0, elapsed < Self.lifetime else { return [] }
        let newest = min(Int(floor(elapsed / Self.emissionInterval)), Int(ceil(Self.emissionDuration / Self.emissionInterval)) - 1)
        let oldest = max(0, Int(floor((elapsed - Self.particleLifetime) / Self.emissionInterval)))
        guard oldest <= newest else { return [] }
        return (oldest...newest).compactMap { index in
            let emission = Double(index) * Self.emissionInterval
            let age = elapsed - emission
            return age < Self.particleLifetime ? (index, emission, age) : nil
        }
    }

    static func emitterOffsets(width: CGFloat) -> [CGFloat] {
        (0..<5).map { (CGFloat($0) + 0.5) / 5 * width - width / 2 }
    }

}

struct EdgeLightInkState {
    private var dismissed: Set<String> = []
    private var previous: [EdgeLightSlot] = []
    private(set) var plumes: [EdgeLightInkPlume] = []

    mutating func update(_ slots: [EdgeLightSlot], enabled: Bool, edge: ScreenEdge,
                         reduceMotion: Bool, now: TimeInterval,
                         effect: EdgeLightCompletionEffect = .greenInk,
                         chooseRandom: () -> EdgeLightCompletionEffect = { EdgeLightCompletionEffect.animations.randomElement()! }) {
        defer { previous = slots }
        dismissed.formIntersection(slots.filter { $0.state == .done }.map(\.identity))
        guard enabled, edge == .top, !reduceMotion else { cancel(); return }
        plumes.removeAll { plume in
            now - plume.startedAt >= EdgeLightInkPlume.lifetime ||
            !slots.indices.contains(plume.slot) || slots[plume.slot].identity != plume.identity ||
            slots[plume.slot].state != .done
        }
        for (index, slot) in slots.enumerated() where slot.state == .done && !slot.isOff && !dismissed.contains(slot.identity) {
            guard previous.indices.contains(index), previous[index].identity == slot.identity,
                  let before = previous[index].state, before != .done else { continue }
            // 以状态边沿触发，启动时的旧未读与轮询中的同一完成都不重复泄露。
            plumes.removeAll { $0.slot == index }
            plumes.append(EdgeLightInkPlume(slot: index, identity: slot.identity, startedAt: now, effect: effect.resolved(chooseRandom: chooseRandom)))
        }
    }

    mutating func expire(at now: TimeInterval) {
        plumes.removeAll { now - $0.startedAt >= EdgeLightInkPlume.lifetime }
    }

    mutating func acknowledge(slot: Int) {
        guard previous.indices.contains(slot) else { return }
        let identity = previous[slot].identity
        dismissed.insert(identity)
        plumes.removeAll { $0.identity == identity }
    }

    mutating func cancel() { plumes.removeAll() }
}

@MainActor
final class EdgeLightInkOverlay {
    private var state = EdgeLightInkState()
    private var previewPlumes: [EdgeLightInkPlume] = []
    private var panel: EdgeLightInkPanel?
    private var view: EdgeLightInkView?
    private var timer: Timer?
    private var sourceFrame: NSRect = .zero
    private var screenFrame: NSRect = .zero
    private var edge: ScreenEdge = .top
    var brightness = EdgeLightSettings.defaultBrightness
    var effect: EdgeLightCompletionEffect = .greenInk { didSet { view?.effect = effect; view?.needsDisplay = true } }
    var activeCount: Int { state.plumes.count + previewPlumes.count }

    func preview() {
        guard edge == .top, sourceFrame.width > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        previewPlumes = [EdgeLightInkPlume(slot: 2, identity: "preview", startedAt: ProcessInfo.processInfo.systemUptime, effect: effect.resolved())]
        present()
    }

    func place(source: NSRect, screen: NSRect, edge: ScreenEdge) {
        if self.edge != edge || sourceFrame.minX != source.minX || sourceFrame.maxY != source.maxY || screenFrame != screen {
            cancel()
        }
        sourceFrame = source
        screenFrame = screen
        self.edge = edge
    }

    func update(_ slots: [EdgeLightSlot], enabled: Bool) {
        state.update(slots, enabled: enabled, edge: edge,
                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     now: ProcessInfo.processInfo.systemUptime, effect: effect)
        present()
    }

    private func present() {
        if activeCount == 0 { stopRendering(); return }
        if panel == nil { makePanel() }
        let width = min(screenFrame.width, 760)
        let height = min(screenFrame.height, 650)
        let x = min(screenFrame.maxX - width, max(screenFrame.minX, sourceFrame.midX - width / 2))
        let frame = NSRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
        panel?.setFrame(frame, display: true)
        view?.sourceOrigin = NSPoint(x: sourceFrame.minX - frame.minX, y: frame.maxY - sourceFrame.maxY + 4)
        view?.sourceWidth = sourceFrame.width
        panel?.orderFrontRegardless()
        redraw()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func acknowledge(slot: Int) {
        state.acknowledge(slot: slot)
        previewPlumes.removeAll { $0.slot == slot }
        if activeCount == 0 { stopRendering() } else { redraw() }
    }

    func cancel() { state.cancel(); previewPlumes.removeAll(); stopRendering() }

    func stop() {
        cancel()
        panel = nil
        view = nil
    }

    private func tick() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { cancel(); return }
        state.expire(at: ProcessInfo.processInfo.systemUptime)
        previewPlumes.removeAll { ProcessInfo.processInfo.systemUptime - $0.startedAt >= EdgeLightInkPlume.lifetime }
        guard activeCount > 0 else { stopRendering(); return }
        redraw()
    }

    private func redraw() {
        view?.plumes = state.plumes + previewPlumes
        view?.effect = effect
        view?.brightness = brightness
        view?.time = ProcessInfo.processInfo.systemUptime
        view?.needsDisplay = true
    }

    private func stopRendering() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        view?.plumes = []
    }

    private func makePanel() {
        let panel = EdgeLightInkPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        panel.title = L10n.text("光缝颜料", "Edge Light Ink")
        // 装饰层位于交互灯条下方，整块区域穿透点击，避免挡住桌面操作。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        let view = EdgeLightInkView()
        panel.contentView = view
        self.panel = panel
        self.view = view
    }
}

private final class EdgeLightInkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class EdgeLightInkView: NSView {
    var effect: EdgeLightCompletionEffect = .greenInk
    var plumes: [EdgeLightInkPlume] = []
    var sourceOrigin = NSPoint.zero
    var sourceWidth: CGFloat = EdgeLightMetrics.length
    var time: TimeInterval = 0
    var brightness: Double = EdgeLightSettings.defaultBrightness
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(srgbRed: 0, green: 1, blue: 0.298, alpha: 1)
                         : NSColor(srgbRed: 0, green: 0.62, blue: 0.185, alpha: 1)
        for plume in plumes {
            let elapsed = time - plume.startedAt
            guard elapsed >= 0 else { continue }
            let origin = NSPoint(x: sourceOrigin.x + sourceWidth / 6 * (CGFloat(plume.slot) + 0.5), y: sourceOrigin.y)
            // 随机结果保存在单次动画上，避免重绘或原生轮询导致中途换风格。
            let animation = plume.effect ?? effect
            let palette: [NSColor] = animation == .rainbowInk
                ? [NSColor(srgbRed: 0.12, green: 0.7, blue: 1, alpha: 1),
                   NSColor(srgbRed: 0.53, green: 0.3, blue: 0.95, alpha: 1),
                   NSColor(srgbRed: 1, green: 0.25, blue: 0.55, alpha: 1),
                   NSColor(srgbRed: 1, green: 0.65, blue: 0.12, alpha: 1), color]
                : [color]
            let gradients = palette.compactMap { tint in
                CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [tint.withAlphaComponent(0.22).cgColor, tint.withAlphaComponent(0.1).cgColor,
                                    tint.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.38, 1])
            }
            guard gradients.count == palette.count else { continue }
            switch animation {
            case .greenInk, .rainbowInk, .random:
                drawPlume(context, gradients: gradients, palette: palette, origin: origin, elapsed: elapsed,
                          plume: plume, emitterWidth: max(1, sourceWidth / 6 - 8))
            case .petals: drawPetalShower(context, origin: origin, elapsed: elapsed, slot: plume.slot, dark: dark)
            case .morningGlory: drawMorningGlory(context, origin: origin, elapsed: elapsed, slot: plume.slot, dark: dark)
            }
        }
    }

    private func drawPlume(_ context: CGContext, gradients: [CGGradient], palette: [NSColor], origin: NSPoint,
                           elapsed: Double, plume: EdgeLightInkPlume, emitterWidth: CGFloat) {
        let slot = plume.slot
        // 连续释放的浓度团在水阻力下沉，横向扩散与涡旋随团龄增长，避免自由落体观感。
        // 多个相邻源覆盖整段灯条，三秒后停止补充，剩余颜料继续在水中散开。
        for particle in plume.particles(at: elapsed) {
            let packet = particle.index
            let emission = particle.emission
            let age = particle.age
            let endFade = min(1, max(0, (EdgeLightInkPlume.particleLifetime - age) / 2))
            let release = (0.65 + 0.35 * sin(emission * 1.1 + Double(slot))) * min(1, age / 0.15)
            let spread = Double(emitterWidth) / 10 + age * 5 + age * age * 1.8
            let fall = age * 26 + age * age * 4.2
            let phase = Double(slot) * 1.7 + emission * 1.3
            let drift = sin(age * 0.85 + phase) * spread * 0.65
            let density = exp(-age * 0.23) * endFade * release * brightness
            for (lane, offset) in EdgeLightInkPlume.emitterOffsets(width: emitterWidth).enumerated() {
                let color = palette[lane % palette.count]
                let gradient = gradients[lane % gradients.count]
                let side = Double(lane - 2) / 2
                let expansion = min(1, age / 1.5)
                let curl = age * 1.8 + phase + side * 1.9
                let x = Double(origin.x + offset) + (drift + side * spread * 0.78 + sin(curl) * spread * 0.32) * expansion
                let y = Double(origin.y) + fall + cos(curl) * spread * 0.23 * expansion
                let radius = spread * (lane == 2 ? 1 : 1 - 0.22 * expansion)
                context.saveGState()
                context.setAlpha(CGFloat(density * (lane == 2 ? 0.5 : 0.5 - 0.14 * expansion)))
                context.translateBy(x: x, y: y)
                context.scaleBy(x: CGFloat(radius), y: CGFloat(radius * (1.1 + age * 0.03)))
                context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                           endCenter: .zero, endRadius: 1, options: [])
                context.restoreGState()
                if lane != 2 && packet % 11 == 3 && age > 0.6 {
                    let fold = CGMutablePath()
                    for step in 0...28 {
                        let progress = Double(step) / 28
                        let angle = curl + emission * 2.7 + side * progress * .pi * 1.3
                        let r = radius * 0.58 * (1 - progress * 0.75) * (1 + sin(progress * 8 + emission * 4) * 0.12)
                        let point = CGPoint(x: x + cos(angle) * r,
                                            y: y + sin(angle) * r * 0.8 + radius * 0.2)
                        if step == 0 { fold.move(to: point) } else { fold.addLine(to: point) }
                    }
                    context.saveGState()
                    context.setAlpha(CGFloat(density * 0.08))
                    context.setStrokeColor(color.cgColor)
                    context.setLineWidth(CGFloat(max(0.6, radius * 0.025)))
                    context.setLineCap(.round)
                    context.setShadow(offset: .zero, blur: 3, color: color.withAlphaComponent(0.35).cgColor)
                    context.addPath(fold)
                    context.strokePath()
                    context.restoreGState()
                }
                // 边缘的小涡旋打破圆形轮廓，让下沉云团逐渐分成细丝与羽状散边。
                for wisp in 0..<3 {
                    let angle = curl + Double(wisp) * 2.094
                    let wispRadius = radius * (0.34 + age * 0.015)
                    context.saveGState()
                    context.setAlpha(CGFloat(density * 0.2))
                    context.translateBy(x: x + cos(angle) * radius * 0.8,
                                        y: y + sin(angle) * radius * 0.55)
                    context.scaleBy(x: CGFloat(wispRadius), y: CGFloat(wispRadius * 1.7))
                    context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                               endCenter: .zero, endRadius: 1, options: [])
                    context.restoreGState()
                }
            }
        }
    }
}
