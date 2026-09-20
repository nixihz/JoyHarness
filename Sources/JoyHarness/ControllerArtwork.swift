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

    static var missingResources: Set<String> { resourceNames.subtracting(images.keys) }

    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in resourceNames {
            let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? AppResources.bundle.url(forResource: name, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) { result[name] = image }
        }
        return result
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
