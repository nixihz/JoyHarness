import Combine
import Foundation

final class MotionJumpSettings: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            if enabled && profile == nil { enabled = false; return }
            guard enabled != oldValue else { return }
            userDefaults.set(enabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    @Published private(set) var profile: MotionJumpProfile?
    @Published private(set) var previousProfile: MotionJumpProfile?

    var canRestorePreviousCalibration: Bool { previousProfile != nil }
    var onChange: (() -> Void)?

    private static let profileKey = "motionJump.dualSense.profile"
    private static let previousProfileKey = "motionJump.dualSense.previousProfile"
    private static let enabledKey = "motionJump.dualSense.enabled"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let loadedProfile = Self.load(key: Self.profileKey, from: userDefaults)
        profile = loadedProfile
        previousProfile = Self.load(key: Self.previousProfileKey, from: userDefaults)
        enabled = loadedProfile != nil && userDefaults.bool(forKey: Self.enabledKey)
    }

    /// Commits the whole valid draft. Invalid input cannot replace a working calibration.
    func apply(profile newProfile: MotionJumpProfile) {
        guard newProfile.isValid, let encoded = try? JSONEncoder().encode(newProfile) else { return }
        if let profile, profile != newProfile {
            previousProfile = profile
            if let previousData = try? JSONEncoder().encode(profile) {
                userDefaults.set(previousData, forKey: Self.previousProfileKey)
            }
        }
        profile = newProfile
        userDefaults.set(encoded, forKey: Self.profileKey)
        enabled = true
        onChange?()
    }

    func updateParameters(_ parameters: MotionJumpParameters) {
        guard var draft = profile, parameters.isValid else { return }
        draft.parameters = parameters
        apply(profile: draft)
    }

    func restorePreviousCalibration() {
        guard let previousProfile else { return }
        apply(profile: previousProfile)
    }

    func clearCalibration() {
        enabled = false
        profile = nil
        previousProfile = nil
        userDefaults.removeObject(forKey: Self.profileKey)
        userDefaults.removeObject(forKey: Self.previousProfileKey)
        onChange?()
    }

    private static func load(key: String, from defaults: UserDefaults) -> MotionJumpProfile? {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(MotionJumpProfile.self, from: data), profile.isValid else { return nil }
        return profile
    }
}
