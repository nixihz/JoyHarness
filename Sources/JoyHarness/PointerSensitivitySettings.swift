import Combine
import CoreGraphics
import Foundation

struct PointerSensitivityValues: Equatable {
    static let defaults = PointerSensitivityValues(normal: 1, fast: 1.8, slow: 0.32)

    let normal: CGFloat
    let fast: CGFloat
    let slow: CGFloat
}

final class PointerSensitivitySettings: ObservableObject {
    static let allowedRange = 0.1...3.0
    static let step = 0.05

    @Published var normal: Double {
        didSet { persist(normal, key: Self.normalStorageKey, oldValue: oldValue) }
    }

    @Published var fast: Double {
        didSet { persist(fast, key: Self.fastStorageKey, oldValue: oldValue) }
    }

    @Published var slow: Double {
        didSet { persist(slow, key: Self.slowStorageKey, oldValue: oldValue) }
    }

    var values: PointerSensitivityValues {
        PointerSensitivityValues(
            normal: CGFloat(normal),
            fast: CGFloat(fast),
            slow: CGFloat(slow)
        )
    }

    var onChange: ((PointerSensitivityValues) -> Void)?

    private static let normalStorageKey = "pointerSensitivity.normal"
    private static let fastStorageKey = "pointerSensitivity.fast"
    private static let slowStorageKey = "pointerSensitivity.slow"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        normal = Self.load(
            key: Self.normalStorageKey,
            defaultValue: Double(PointerSensitivityValues.defaults.normal),
            userDefaults: userDefaults
        )
        fast = Self.load(
            key: Self.fastStorageKey,
            defaultValue: Double(PointerSensitivityValues.defaults.fast),
            userDefaults: userDefaults
        )
        slow = Self.load(
            key: Self.slowStorageKey,
            defaultValue: Double(PointerSensitivityValues.defaults.slow),
            userDefaults: userDefaults
        )
    }

    func resetDefaults() {
        normal = Double(PointerSensitivityValues.defaults.normal)
        fast = Double(PointerSensitivityValues.defaults.fast)
        slow = Double(PointerSensitivityValues.defaults.slow)
    }

    private func persist(_ value: Double, key: String, oldValue: Double) {
        guard value != oldValue else { return }
        let clamped = min(max(value, Self.allowedRange.lowerBound), Self.allowedRange.upperBound)
        if clamped != value {
            switch key {
            case Self.normalStorageKey: normal = clamped
            case Self.fastStorageKey: fast = clamped
            case Self.slowStorageKey: slow = clamped
            default: break
            }
            return
        }
        userDefaults.set(value, forKey: key)
        onChange?(values)
    }

    private static func load(
        key: String,
        defaultValue: Double,
        userDefaults: UserDefaults
    ) -> Double {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return min(
            max(userDefaults.double(forKey: key), allowedRange.lowerBound),
            allowedRange.upperBound
        )
    }
}
