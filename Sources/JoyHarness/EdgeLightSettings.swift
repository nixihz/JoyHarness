import AppKit
import Combine

enum EdgeLightCompletionEffect: String, CaseIterable, Identifiable {
    case greenInk, rainbowInk, petals, morningGlory, random
    static let animations: [Self] = [.greenInk, .rainbowInk, .petals, .morningGlory]
    func resolved(chooseRandom: () -> Self = { Self.animations.randomElement()! }) -> Self {
        self == .random ? chooseRandom() : self
    }
    var id: Self { self }
    var displayName: String {
        switch self {
        case .random: L10n.text("随机特效", "Random Effect")
        case .greenInk: L10n.text("绿色颜料", "Green Ink")
        case .rainbowInk: L10n.text("多彩颜料", "Rainbow Ink")
        case .petals: L10n.text("天女散花", "Petal Shower")
        case .morningGlory: L10n.text("藤蔓牵牛花", "Morning Glory Vines")
        }
    }
}

@MainActor
final class EdgeLightSettings: ObservableObject {
    static let effectKey = "edgeLights.completionEffect"
    static let enabledKey = "edgeLights.enabled"
    static let brightnessKey = "edgeLights.brightness"
    static let brightnessRange = 0.2...1.0
    static let defaultBrightness = 0.85
    static let placementKey = "edgeLights.placement"
    @Published var completionEffect: EdgeLightCompletionEffect {
        didSet {
            guard completionEffect != oldValue else { return }
            defaults.set(completionEffect.rawValue, forKey: Self.effectKey)
            onEffectChange?(completionEffect)
        }
    }
    var onEffectChange: ((EdgeLightCompletionEffect) -> Void)?
    var onPreview: (() -> Void)?
    @Published var isMicroSynchronized = false
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    @Published var brightness: Double {
        didSet {
            let normalized = Self.normalizedBrightness(brightness)
            if normalized != brightness {
                brightness = normalized
            }
            guard brightness != oldValue else { return }
            defaults.set(brightness, forKey: Self.brightnessKey)
            onBrightnessChange?(brightness)
        }
    }
    var onBrightnessChange: ((Double) -> Void)?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completionEffect = defaults.string(forKey: Self.effectKey).flatMap(EdgeLightCompletionEffect.init(rawValue:)) ?? .greenInk
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        brightness = defaults.object(forKey: Self.brightnessKey) == nil
            ? Self.defaultBrightness : Self.normalizedBrightness(defaults.double(forKey: Self.brightnessKey))
    }

    private static func normalizedBrightness(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBrightness }
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, value))
    }

    var placement: EdgeLightPlacement {
        get {
            guard let data = defaults.data(forKey: Self.placementKey),
                  let value = try? JSONDecoder().decode(EdgeLightPlacement.self, from: data),
                  value.fraction.isFinite else { return EdgeLightPlacement() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.placementKey)
            }
        }
    }
}

enum ScreenEdge: String, Codable, CaseIterable {
    case top, right, bottom, left
    var isHorizontal: Bool { self == .top || self == .bottom }
}

struct EdgeLightPlacement: Codable, Equatable {
    var edge: ScreenEdge = .top
    var fraction: Double = 0.72
    var displayID: UInt32?

    func frame(in screen: NSRect, expanded: Bool) -> NSRect {
        let length = min(EdgeLightMetrics.length, edge.isHorizontal ? screen.width : screen.height)
        let depth = expanded ? EdgeLightMetrics.expandedDepth : EdgeLightMetrics.collapsedDepth
        let fraction = min(1, max(0, fraction))
        switch edge {
        case .top:
            return NSRect(x: screen.minX + (screen.width - length) * fraction,
                          y: screen.maxY - depth, width: length, height: depth)
        case .bottom:
            return NSRect(x: screen.minX + (screen.width - length) * fraction,
                          y: screen.minY, width: length, height: depth)
        case .left:
            return NSRect(x: screen.minX, y: screen.maxY - length - (screen.height - length) * fraction,
                          width: depth, height: length)
        case .right:
            return NSRect(x: screen.maxX - depth, y: screen.maxY - length - (screen.height - length) * fraction,
                          width: depth, height: length)
        }
    }

    static func snapped(to point: NSPoint, in screen: NSRect, displayID: UInt32?) -> Self {
        let distances: [(ScreenEdge, CGFloat)] = [
            (.top, abs(screen.maxY - point.y)), (.right, abs(screen.maxX - point.x)),
            (.bottom, abs(point.y - screen.minY)), (.left, abs(point.x - screen.minX)),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        let length = min(EdgeLightMetrics.length, edge.isHorizontal ? screen.width : screen.height)
        let travel = (edge.isHorizontal ? screen.width : screen.height) - length
        let offset = edge.isHorizontal ? point.x - screen.minX - length / 2
            : screen.maxY - point.y - length / 2
        return Self(edge: edge, fraction: travel > 0 ? min(1, max(0, offset / travel)) : 0,
                    displayID: displayID)
    }
}

enum EdgeLightMetrics {
    static let length: CGFloat = 240
    static let collapsedDepth: CGFloat = 12
    static let expandedDepth: CGFloat = 32
    static let slotCount = 6
    static let dragThreshold: CGFloat = 5
}

struct EdgeLightSlot: Equatable {
    var identity: String
    var title: String
    var state: PadState?
    var lightingRGB: UInt32?
    var isOff = false

    var colorRGB: UInt32 {
        if let lightingRGB { return lightingRGB }
        return switch state {
        case .busy: 0x304FFE
        case .done: 0x00FF4C
        case .waiting: 0xFF6D00
        case .error: 0xFF0033
        case .idle, nil: 0xFFFFFF
        }
    }
}

struct EdgeLightPointerGesture {
    private var origin: NSPoint?
    private var pressedSlot: Int?
    private(set) var isDragging = false

    mutating func begin(at point: NSPoint, slot: Int?) {
        origin = point
        pressedSlot = slot
        isDragging = false
    }

    mutating func move(to point: NSPoint) -> Bool {
        guard let origin else { return false }
        if hypot(point.x - origin.x, point.y - origin.y) >= EdgeLightMetrics.dragThreshold { isDragging = true }
        return isDragging
    }

    mutating func end(over slot: Int?) -> Int? {
        defer { origin = nil; pressedSlot = nil; isDragging = false }
        guard origin != nil, !isDragging, slot == pressedSlot else { return nil }
        return slot
    }
}
