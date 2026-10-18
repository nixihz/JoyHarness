import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct MotionJumpSettingsTests {
    @Test
    func requiresPersonalCalibrationAndPersistsAppliedProfileAndEnabledState() throws {
        let suite = "MotionJumpSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MotionJumpSettings(userDefaults: defaults)
        settings.enabled = true
        #expect(!settings.enabled)
        #expect(settings.profile == nil)
        settings.apply(profile: fixtureProfile)
        let restored = MotionJumpSettings(userDefaults: defaults)
        #expect(restored.enabled)
        #expect(restored.profile == fixtureProfile)
        restored.enabled = false
        #expect(!MotionJumpSettings(userDefaults: defaults).enabled)
        #expect(MotionJumpSettings(userDefaults: defaults).profile != nil)
    }

    @Test
    func restoringPreviousCalibrationRestoresWholeProfileAcrossLaunches() throws {
        let suite = "MotionJumpSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MotionJumpSettings(userDefaults: defaults)
        settings.apply(profile: fixtureProfile)
        var revised = fixtureProfile
        revised.parameters.minimumAngle = 0.4
        revised.parameters.minimumPeakSpeed = 1.2
        settings.apply(profile: revised)
        let relaunched = MotionJumpSettings(userDefaults: defaults)
        #expect(relaunched.canRestorePreviousCalibration)
        relaunched.restorePreviousCalibration()
        #expect(relaunched.profile == fixtureProfile)
        #expect(MotionJumpSettings(userDefaults: defaults).profile == fixtureProfile)
    }

    @Test
    func clearingPersonalCalibrationDisablesAndRemovesSavedProfiles() throws {
        let suite = "MotionJumpSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MotionJumpSettings(userDefaults: defaults)
        settings.apply(profile: fixtureProfile)
        var second = fixtureProfile
        second.parameters.minimumAngle = 0.4
        settings.apply(profile: second)
        settings.clearCalibration()
        let restored = MotionJumpSettings(userDefaults: defaults)
        #expect(!restored.enabled)
        #expect(restored.profile == nil)
        #expect(!restored.canRestorePreviousCalibration)
    }

    @Test
    func invalidParameterDraftCannotReplaceWorkingCalibration() throws {
        let suite = "MotionJumpSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MotionJumpSettings(userDefaults: defaults)
        settings.apply(profile: fixtureProfile)
        var broken = fixtureProfile
        broken.parameters.minimumAngle = .nan
        settings.apply(profile: broken)
        #expect(settings.profile == fixtureProfile)
        broken = fixtureProfile
        broken.templates.removeValue(forKey: .upperLeft)
        settings.apply(profile: broken)
        #expect(MotionJumpSettings(userDefaults: defaults).profile == fixtureProfile)
    }

    private var fixtureProfile: MotionJumpProfile {
        MotionJumpProfile(parameters: .init(minimumAngle: 0.2, minimumPeakSpeed: 0.6,
            maximumDuration: 2, directionTolerance: 25, minimumMargin: 0.15), templates: [
                .upperLeft: SIMD3(-1, 0, 0), .upperRight: SIMD3(1, 0, 0),
                .lowerLeft: SIMD3(0, -1, 0), .lowerRight: SIMD3(0, 1, 0)
            ])
    }
}
