import AppKit

@MainActor
extension EdgeLightInkView {
    private func seed(_ index: Int, slot: Int) -> Double {
        let value = sin(Double(index * 37 + slot * 91 + 11) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    func drawPetalShower(_ context: CGContext, origin: NSPoint, elapsed: Double, slot: Int, dark: Bool) {
        let colors: [NSColor] = [.init(srgbRed: 1, green: 0.48, blue: 0.68, alpha: 1),
                                 .init(srgbRed: 0.83, green: 0.58, blue: 1, alpha: 1),
                                 .init(srgbRed: 1, green: 0.76, blue: 0.53, alpha: 1),
                                 .init(srgbRed: 1, green: 0.68, blue: 0.83, alpha: 1)]
        for index in 0..<90 {
            let age = elapsed - Double(index) / 30
            guard age >= 0, age < 8 else { continue }
            let variation = seed(index, slot: slot)
            let wind = (variation - 0.5) * 70
            let x = Double(origin.x) + (variation - 0.5) * 32 + wind * age / (1 + age * 0.2)
                + sin(age * 1.5 + variation * 9) * age * 4
            let y = Double(origin.y) + age * (29 + variation * 16) + age * age * 3
            let fade = min(1, age / 0.2) * min(1, (8 - age) / 1.8) * brightness
            context.saveGState()
            context.setAlpha(CGFloat(fade * (dark ? 0.85 : 0.7)))
            context.translateBy(x: x, y: y)
            context.rotate(by: CGFloat(age * (variation - 0.5) * 2 + variation * 6))
            let size = CGFloat(4 + variation * 5)
            let tint = colors[index % colors.count]
            if index % 7 == 0 {
                for petal in 0..<5 {
                    context.saveGState()
                    context.rotate(by: CGFloat(petal) * .pi * 2 / 5)
                    drawPetal(context, size: size, color: tint)
                    context.restoreGState()
                }
                context.setFillColor(NSColor(srgbRed: 1, green: 0.9, blue: 0.58, alpha: 1).cgColor)
                context.fillEllipse(in: NSRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2))
            } else {
                // 侧向翻转让单瓣交替露出宽面和薄边，避免纸片沿直线下落。
                context.scaleBy(x: CGFloat(0.4 + 0.6 * abs(cos(age * 1.8 + variation * 8))), y: 1)
                drawPetal(context, size: size, color: tint)
            }
            context.restoreGState()
        }
    }

    private func drawPetal(_ context: CGContext, size: CGFloat, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 0, y: -size * 1.5), control1: CGPoint(x: -size, y: -size * 0.6),
                      control2: CGPoint(x: -size * 0.75, y: -size * 1.6))
        path.addCurve(to: .zero, control1: CGPoint(x: size * 0.8, y: -size * 1.65),
                      control2: CGPoint(x: size, y: -size * 0.5))
        context.setFillColor(color.cgColor)
        context.addPath(path); context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(0.6)
        context.move(to: .zero); context.addLine(to: CGPoint(x: 0, y: -size)); context.strokePath()
    }

    func drawMorningGlory(_ context: CGContext, origin: NSPoint, elapsed: Double, slot: Int, dark: Bool) {
        guard elapsed >= 0, elapsed < 11 else { return }
        func ease(_ value: Double) -> Double {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        let fade = min(1, (11 - elapsed) / 2) * brightness
        let green = dark ? NSColor(srgbRed: 0.37, green: 0.66, blue: 0.39, alpha: 1)
                         : NSColor(srgbRed: 0.22, green: 0.45, blue: 0.27, alpha: 1)
        let phase = seed(17, slot: slot) * 1.2
        func mainPoint(_ distance: Double) -> CGPoint {
            let sway = sin(elapsed * 0.65 + distance / 110) * pow(distance / 310, 1.5) * 4
            return CGPoint(x: Double(origin.x) + sin(distance / 49 + phase) * 22
                           - sin(phase) * 22 + sin(distance / 97) * 13 - distance * 0.075 + sway,
                           y: Double(origin.y) + distance)
        }
        context.saveGState()
        context.setAlpha(CGFloat(fade))
        // 侧藤从主藤的节点分出，轮廓和节奏不再镜像，枝叶也沿各自节点生长。
        for stem in 0..<2 {
            if stem == 1 && ease(elapsed / 4.8) * 310 < 72 { continue }
            let total = stem == 0 ? 310.0 : 216.0
            let progress = ease((elapsed - (stem == 0 ? 0 : 1.65)) / (stem == 0 ? 4.8 : 4.0))
            let length = progress * total
            guard length > 0.5 else { continue }
            let fork = mainPoint(72)
            func point(_ distance: Double) -> CGPoint {
                if stem == 0 { return mainPoint(distance) }
                return CGPoint(x: Double(fork.x) + distance * 0.21 + sin(distance / 43) * 17
                               + sin(elapsed * 0.7 + distance / 90) * pow(distance / total, 1.5) * 3,
                               y: Double(fork.y) + distance)
            }
            context.setLineCap(.round)
            for step in 0..<90 {
                let start = length * Double(step) / 90
                let end = length * Double(step + 1) / 90
                context.setStrokeColor(green.withAlphaComponent(stem == 0 ? 0.95 : 0.8).cgColor)
                context.setLineWidth(CGFloat((stem == 0 ? 2.1 : 1.6) * (1 - start / total * 0.72)))
                context.move(to: point(start)); context.addLine(to: point(end)); context.strokePath()
            }
            for node in 0..<7 {
                let variation = seed(node + stem * 13, slot: slot)
                let distance = 30 + Double(node) * (stem == 0 ? 39 : 28) + variation * 13
                let growth = ease((length - distance) / 25)
                guard growth > 0 else { continue }
                let anchor = point(distance)
                let side: Double = (node + stem) % 2 == 0 ? -1 : 1
                let leafSize = (14 + variation * 10) * (1 - distance / total * 0.25)
                let leafBase = CGPoint(x: anchor.x + side * 7 * growth, y: anchor.y - 3 * growth)
                context.setStrokeColor(green.withAlphaComponent(0.8).cgColor); context.setLineWidth(0.8)
                context.move(to: anchor); context.addQuadCurve(to: leafBase,
                    control: CGPoint(x: anchor.x + side * 3, y: anchor.y - 5)); context.strokePath()
                context.saveGState()
                context.translateBy(x: leafBase.x, y: leafBase.y)
                context.rotate(by: CGFloat(side * (0.85 + variation * 0.65) + sin(elapsed * 0.75 + distance) * 0.025))
                context.scaleBy(x: CGFloat(growth * (0.78 + variation * 0.2)), y: CGFloat(growth))
                drawLeaf(context, size: CGFloat(leafSize), color: green)
                context.restoreGState()
                if [1, 3, 5].contains(node) {
                    let opening = ease((elapsed - (stem == 0 ? 2.5 : 3.3) - Double(node) * 0.43) / 1.15)
                    guard opening > 0 else { continue }
                    let branchLength = (22 + variation * 15) * growth
                    let flower = CGPoint(x: anchor.x - side * branchLength, y: anchor.y + 7 + variation * 9)
                    context.setStrokeColor(green.cgColor); context.setLineWidth(0.9)
                    context.move(to: anchor)
                    context.addCurve(to: flower, control1: CGPoint(x: anchor.x - side * 14, y: anchor.y - 12),
                                     control2: CGPoint(x: flower.x + side * 5, y: flower.y - 12))
                    context.strokePath()
                    context.saveGState()
                    context.translateBy(x: flower.x, y: flower.y)
                    context.rotate(by: CGFloat(variation * 0.8 - 0.4 + sin(elapsed * 0.65 + distance) * 0.025))
                    context.scaleBy(x: CGFloat(0.18 + opening * 0.82), y: CGFloat(0.35 + opening * 0.65))
                    drawFlower(context, radius: CGFloat(13 + variation * 7), pink: (node + stem) % 3 == 1)
                    context.restoreGState()
                }
            }
            // 卷须从末端的切线延续，避免出现与藤条脱节的钩状尖端。
            let tip = point(length)
            let behind = point(max(0, length - 4))
            let direction = atan2(tip.y - behind.y, tip.x - behind.x)
            context.saveGState()
            context.translateBy(x: tip.x, y: tip.y); context.rotate(by: direction - .pi / 2)
            context.setStrokeColor(green.withAlphaComponent(0.65).cgColor); context.setLineWidth(0.55)
            context.move(to: .zero)
            context.addCurve(to: CGPoint(x: 6, y: 12), control1: CGPoint(x: 0, y: 20), control2: CGPoint(x: 15, y: 23))
            context.addCurve(to: CGPoint(x: 4, y: 15), control1: CGPoint(x: 0, y: 5), control2: CGPoint(x: -2, y: 14))
            context.strokePath(); context.restoreGState()
        }
        context.restoreGState()
    }

    private func drawLeaf(_ context: CGContext, size: CGFloat, color: NSColor) {
        let leaf = CGMutablePath()
        leaf.move(to: .zero)
        leaf.addCurve(to: CGPoint(x: -size * 0.56, y: -size * 0.47),
                      control1: CGPoint(x: -size * 0.12, y: size * 0.3), control2: CGPoint(x: -size * 0.8, y: size * 0.08))
        leaf.addCurve(to: CGPoint(x: size * 0.04, y: -size * 1.35),
                      control1: CGPoint(x: -size * 0.5, y: -size * 0.86), control2: CGPoint(x: -size * 0.09, y: -size * 1.12))
        leaf.addCurve(to: CGPoint(x: size * 0.52, y: -size * 0.4),
                      control1: CGPoint(x: size * 0.15, y: -size * 1.08), control2: CGPoint(x: size * 0.64, y: -size * 0.7))
        leaf.addCurve(to: .zero, control1: CGPoint(x: size * 0.68, y: size * 0.1),
                      control2: CGPoint(x: size * 0.1, y: size * 0.22))
        context.saveGState()
        context.addPath(leaf); context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [color.withAlphaComponent(0.95).cgColor,
                                              color.blended(withFraction: 0.22, of: .white)!.withAlphaComponent(0.8).cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: -size * 0.4, y: -size), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); context.setLineWidth(0.45)
        context.move(to: .zero); context.addQuadCurve(to: CGPoint(x: size * 0.04, y: -size * 1.25), control: CGPoint(x: -size * 0.06, y: -size * 0.7)); context.strokePath()
        for side: CGFloat in [-1, 1] {
            for vein in 1...3 {
                let y = -size * CGFloat(vein) * 0.22
                context.move(to: CGPoint(x: 0, y: y))
                context.addQuadCurve(to: CGPoint(x: side * size * (0.53 - CGFloat(vein) * 0.08), y: y - size * 0.12),
                                     control: CGPoint(x: side * size * 0.23, y: y - size * 0.06)); context.strokePath()
            }
        }
    }

    private func drawFlower(_ context: CGContext, radius: CGFloat, pink: Bool) {
        let rim = CGMutablePath()
        for step in 0...100 {
            let angle = Double(step) / 100 * .pi * 2
            let r = Double(radius) * (1 + 0.045 * cos(angle * 5))
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if step == 0 { rim.move(to: point) } else { rim.addLine(to: point) }
        }
        rim.closeSubpath()
        let tint = pink ? NSColor(srgbRed: 0.94, green: 0.46, blue: 0.72, alpha: 1)
                        : NSColor(srgbRed: 0.52, green: 0.43, blue: 0.88, alpha: 1)
        context.saveGState()
        context.addPath(rim); context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor(srgbRed: 1, green: 0.96, blue: 0.84, alpha: 1).cgColor,
                                              tint.blended(withFraction: 0.18, of: .white)!.cgColor, tint.cgColor] as CFArray,
                                     locations: [0, 0.42, 1]) {
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: radius * 1.12, options: [])
        }
        for vein in 0..<5 {
            let angle = CGFloat(vein) * .pi * 2 / 5
            let stripe = CGMutablePath()
            stripe.move(to: .zero)
            stripe.addLine(to: CGPoint(x: cos(angle - 0.08) * radius * 0.9, y: sin(angle - 0.08) * radius * 0.9))
            stripe.addLine(to: CGPoint(x: cos(angle + 0.08) * radius * 0.9, y: sin(angle + 0.08) * radius * 0.9))
            stripe.closeSubpath()
            context.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            context.addPath(stripe); context.fillPath()
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor); context.setLineWidth(0.5)
        context.addPath(rim); context.strokePath()
        context.setFillColor(NSColor(srgbRed: 1, green: 0.95, blue: 0.63, alpha: 1).cgColor)
        context.fillEllipse(in: NSRect(x: -1.5, y: -1.5, width: 3, height: 3))
    }
}
