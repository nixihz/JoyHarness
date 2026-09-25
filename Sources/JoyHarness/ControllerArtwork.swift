import AppKit
import SwiftUI

struct ControllerArtwork: View {
    let family: ControllerFamily
    let orientation: JoyConOrientation
    let pressedInputs: Set<ControllerInput>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var resourceNames: Set<String> {
        let families: [ControllerFamily] = [.dualSense, .dualShock, .xbox, .generic, .xiaomiRemote, .joyConLeft, .joyConRight, .joyConPair]
        return Set(families.flatMap { $0.dashboardArtworkDescriptors().map(\.resource) })
    }

    static var missingResources: Set<String> {
        var missing = resourceNames.subtracting(images.keys)
        if xiaomiWordmark == nil { missing.insert("xiaomi-wordmark") }
        return missing
    }

    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in resourceNames {
            let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? AppResources.bundle.url(forResource: name, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) { result[name] = image }
        }
        return result
    }()

    private static let xiaomiWordmark: NSImage? = {
        let url = Bundle.main.url(forResource: "xiaomi-wordmark", withExtension: "svg")
            ?? AppResources.bundle.url(forResource: "xiaomi-wordmark", withExtension: "svg")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        GeometryReader { proxy in
            let descriptors = family.dashboardArtworkDescriptors(orientation: orientation)
            if family == .generic || descriptors.isEmpty || descriptors.contains(where: { Self.images[$0.resource] == nil }) {
                Image(systemName: "gamecontroller.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(pressedInputs.isEmpty ? Color.secondary : DashboardStyle.input)
                    .padding(DashboardStyle.Space.page)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                let canvas = canvasSize(in: proxy.size)
                ZStack {
                    HStack(spacing: 0) {
                        ForEach(Array(descriptors.enumerated()), id: \.offset) { _, descriptor in
                            if let image = Self.images[descriptor.resource] {
                                let rotated = descriptor.rotationDegrees != 0
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(width: rotated ? canvas.height : canvas.width / CGFloat(descriptors.count),
                                           height: rotated ? canvas.width : canvas.height)
                                    .rotationEffect(.degrees(descriptor.rotationDegrees))
                                    .frame(width: canvas.width / CGFloat(descriptors.count), height: canvas.height)
                            }
                        }
                    }
                    xiaomiWordmarkOverlay(canvas: canvas)
                    if let brandMark {
                        Image(systemName: brandMark.symbolName)
                            .resizable()
                            .scaledToFit()
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(brandMark.color)
                            .frame(
                                width: canvas.width * brandMark.widthRatio,
                                height: canvas.width * brandMark.heightRatio
                            )
                            .position(
                                x: canvas.width * brandMark.center.x,
                                y: canvas.height * brandMark.center.y
                            )
                    }
                    ForEach(highlights) { highlight in
                        marker(highlight, canvas: canvas)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }

    private var highlights: [ControllerInputHighlightModel] {
        ControllerInputHighlightModel.layout(for: family, orientation: orientation).values.sorted { $0.input.rawValue < $1.input.rawValue }
    }

    private struct BrandMark {
        let symbolName: String
        let center: CGPoint
        let widthRatio: CGFloat
        let heightRatio: CGFloat
        let color: Color
    }

    private enum XiaomiWordmarkLayout {
        static let center = CGPoint(x: 0.50, y: 0.9193)
        static let texturePatchSize = CGSize(width: 0.370, height: 0.021)
        static let textureSourceOffsetRatio = 0.0293
        static let wordmarkWidthRatio = 0.335
        static let wordmarkHeightRatio = 0.056
    }

    private var brandMark: BrandMark? {
        guard let homeCenter = ControllerInputHighlightModel.layout(
            for: family,
            orientation: orientation
        )[.home]?.center else { return nil }

        return switch family {
        case .xbox:
            BrandMark(
                symbolName: "xbox.logo",
                center: homeCenter,
                widthRatio: 0.042,
                heightRatio: 0.042,
                color: Color.white.opacity(0.90)
            )
        case .dualSense:
            BrandMark(
                symbolName: "playstation.logo",
                center: homeCenter,
                widthRatio: 0.034,
                heightRatio: 0.026,
                color: Color.black.opacity(0.72)
            )
        default:
            nil
        }
    }

    @ViewBuilder
    private func xiaomiWordmarkOverlay(canvas: CGSize) -> some View {
        if family == .xiaomiRemote,
           let remoteArtwork = Self.images["controller-dashboard-xiaomi-remote"] {
            Image(nsImage: remoteArtwork)
                .resizable()
                .scaledToFit()
                .frame(width: canvas.width, height: canvas.height)
                .offset(y: canvas.height * XiaomiWordmarkLayout.textureSourceOffsetRatio)
                .mask {
                    Rectangle()
                        .frame(
                            width: canvas.width * XiaomiWordmarkLayout.texturePatchSize.width,
                            height: canvas.height * XiaomiWordmarkLayout.texturePatchSize.height
                        )
                        .position(
                            x: canvas.width * XiaomiWordmarkLayout.center.x,
                            y: canvas.height * XiaomiWordmarkLayout.center.y
                        )
                }
                .accessibilityHidden(true)

            if let wordmark = Self.xiaomiWordmark {
                Image(nsImage: wordmark)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.black.opacity(0.60))
                    .frame(
                        width: canvas.width * XiaomiWordmarkLayout.wordmarkWidthRatio,
                        height: canvas.width * XiaomiWordmarkLayout.wordmarkHeightRatio
                    )
                    .position(
                        x: canvas.width * XiaomiWordmarkLayout.center.x,
                        y: canvas.height * XiaomiWordmarkLayout.center.y
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private func canvasSize(in available: CGSize) -> CGSize {
        let ratio: CGFloat
        switch family {
        case .xiaomiRemote: ratio = 520 / 2051
        case .joyConLeft, .joyConRight: ratio = orientation == .horizontal ? 1.5 : 2 / 3
        case .joyConPair: ratio = 4 / 3
        default: ratio = 1.5
        }
        let width = min(available.width, available.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
    private func marker(_ highlight: ControllerInputHighlightModel, canvas: CGSize) -> some View {
        let active = pressedInputs.contains { $0.physicalInput == highlight.input }
        // Marker sizes use the original 390pt reference; remote positions use its portrait canvas.
        let referenceDimension: CGFloat = switch family {
        case .xiaomiRemote: canvas.height
        case .joyConPair: canvas.width / 2
        case .joyConLeft, .joyConRight: orientation == .horizontal ? canvas.height : canvas.width
        default: canvas.width
        }
        let scale = min(referenceDimension / DashboardStyle.artworkReferenceWidth, 1)
        return RoundedRectangle(cornerRadius: highlight.cornerRadius * scale)
            .fill(DashboardStyle.input.opacity(DashboardStyle.highlightFillOpacity))
            .overlay(RoundedRectangle(cornerRadius: highlight.cornerRadius * scale)
                .stroke(DashboardStyle.input, lineWidth: DashboardStyle.highlightBorderWidth))
            .frame(width: highlight.size.width * scale, height: highlight.size.height * scale)
            .opacity(active ? 1 : 0)
            .animation(reduceMotion || active ? nil : .easeOut(duration: DashboardStyle.keyRelease), value: active)
            .position(x: highlight.center.x * canvas.width, y: highlight.center.y * canvas.height)
    }
}
